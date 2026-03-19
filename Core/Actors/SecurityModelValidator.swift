//
//  SecurityModelValidator.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 19.3.2026.
//

import Foundation
import dnssd

/// Low-level context for the DNS-SD TXT query callback.
///
/// `@unchecked Sendable` is **necessary and explicitly justified** (and the *only* place it is used):
/// - The instance is passed as an opaque `UnsafeMutableRawPointer` to the C API (`DNSServiceQueryRecord`).
/// - The callback executes on an arbitrary background thread managed by the dns_sd library.
/// - Lifetime is strictly manual (Unmanaged.passRetained + takeRetainedValue) with a one-shot callback + watchdog flag.
/// - No actor state or other types are involved; this is the standard, minimal pattern for Bonjour C callbacks in Swift 6.
private final class QueryContext: @unchecked Sendable {
    let completion: @Sendable (Result<Set<String>, Error>) -> Void
    var serviceRef: DNSServiceRef?
    var isDone = false

    init(completion: @escaping @Sendable (Result<Set<String>, Error>) -> Void) {
        self.completion = completion
    }
}

/// Actor-isolated validator for the required security/protocol model (via DNS TXT record).
/// Serves as the single, concurrency-safe source of truth for enforcing the app's
/// current compatibility and security expectations.
/// Implemented with Swift 6+ strict actor isolation and modern async/await patterns
/// for robust thread safety and Sendable compliance.
public actor SecurityModelValidator {
    public static let shared = SecurityModelValidator()

    private let config = SecurityConfiguration()
    private var validationState: ValidationState = .pending
    private var lastValidationTime: Date?

    private let userDefaultsKey = "lastSecurityValidation"

    /// Injectable for tests (time-dependent cache logic).
    internal var currentDate: @Sendable () -> Date = { Date() }

    private init() {
        if let saved = UserDefaults.standard.object(forKey: userDefaultsKey) as? Date {
            lastValidationTime = saved
        }
    }

    // MARK: - Public API

    public func validateSecurityModel() async -> Bool {
        guard !Task.isCancelled else { return false }

        if let last = lastValidationTime ?? UserDefaults.standard.object(forKey: userDefaultsKey) as? Date,
           currentDate().timeIntervalSince(last) < config.modelCacheDuration {
            validationState = .success
            return true
        }

        do {
            let validModels = try await queryTXTRecord(for: config.txtRecordDomain)
            let isValid = validModels.contains(config.expectedSecurityModel.lowercased())

            let now = currentDate()
            if isValid {
                lastValidationTime = now
                UserDefaults.standard.set(now, forKey: userDefaultsKey)
                validationState = .success
                return true
            } else {
                validationState = .failedPermanent
                #if DEBUG
                print("🔒 SecurityModelValidator] Permanent failure: '\(config.expectedSecurityModel)' not in DNS TXT")
                #endif
                return false
            }
        } catch {
            #if DEBUG
            print("🔒 SecurityModelValidator] Transient DNS error: \(error)")
            #endif
            validationState = .failedTransient
            return false
        }
    }

    public var currentState: ValidationState {
        get async { validationState }
    }

    public enum ValidationState {
        case pending, success, failedPermanent, failedTransient
    }
    
    /// Returns whether the current security model is considered valid right now.
    /// Treats transient failures as "not valid for now" (safe default).
    public func isCurrentlyValid() async -> Bool {
        await validateSecurityModel()
    }
    
    public var isPermanentlyInvalid: Bool {
        get async {
            validationState == .failedPermanent
            // or: await currentState == .failedPermanent
        }
    }
    
    // MARK: - State Recovery

    /// Clears transient validation failures and invalidates the cache,
    /// allowing the next validation attempt to perform a fresh check.
    ///
    /// Permanent validation failures (e.g. model mismatch) are not affected
    /// and require either a new app build or updated configuration to resolve.
    public func resetTransientState() {
        if validationState == .failedTransient {
            validationState = .pending
            lastValidationTime = nil
            #if DEBUG
            print("🔄 Reset transient state → pending, cache invalidated")
            #endif
        }
    }
    
    // MARK: - Private implementation

    private func queryTXTRecord(for domain: String) async throws -> Set<String> {
            try await withCheckedThrowingContinuation { continuation in
                let complete: @Sendable (Result<Set<String>, Error>) -> Void = {
                    continuation.resume(with: $0)
                }

                let context = QueryContext(completion: complete)
                let contextPtr = Unmanaged.passRetained(context).toOpaque()

                // Watchdog unchanged
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5.0) { [weak context] in
                    guard let context, !context.isDone else { return }
                    if let ref = context.serviceRef {
                        DNSServiceRefDeallocate(ref)
                        context.serviceRef = nil
                    }
                }

                guard let domainCStr = domain.cString(using: .utf8) else {
                    complete(.failure(
                        NSError(domain: "radio.lutheran", code: -998, userInfo: [NSLocalizedDescriptionKey: "Invalid domain encoding"])
                    ))
                    Self.releaseContextPointer(contextPtr)
                    return
                }

                var serviceRef: DNSServiceRef?
                let err = DNSServiceQueryRecord(
                    &serviceRef,
                    0,
                    0,
                    domainCStr,
                    UInt16(kDNSServiceType_TXT),
                    UInt16(kDNSServiceClass_IN),

                    // ────────────────────────────────────────────────────────────────
                    // Key change: use a static function instead of inline closure literal
                    Self.dnsQueryCallback as DNSServiceQueryRecordReply,
                    contextPtr
                )

                if err == kDNSServiceErr_NoError, let serviceRef {
                    context.serviceRef = serviceRef
                } else {
                    complete(.failure(NSError(domain: "dnssd", code: Int(err), userInfo: nil)))
                    Self.releaseContextPointer(contextPtr)
                }
            }
        }

        // New static non-capturing callback — marked @convention(c) explicitly
    private static let dnsQueryCallback: DNSServiceQueryRecordReply = {
        sdRef, flags, interfaceIdx, errorCode, fullName, rrtype, rrclass, rdlen, rdata, ttl, ctx in
        
        guard let ctx else { return }

        let queryCtx = Unmanaged<QueryContext>.fromOpaque(ctx).takeRetainedValue()

        defer {
            queryCtx.isDone = true
            if let ref = queryCtx.serviceRef {
                DNSServiceRefDeallocate(ref)
                queryCtx.serviceRef = nil
            }
        }

        guard errorCode == kDNSServiceErr_NoError, let rdata else {
            queryCtx.completion(.failure(
                NSError(domain: "dnssd", code: Int(errorCode), userInfo: nil)
            ))
            return
        }

        let receivedData = Data(bytes: rdata, count: Int(rdlen))
        
        // Key change: SecurityModelValidator.parseInlineTXTRecord instead of Self.
        let models = SecurityModelValidator.parseInlineTXTRecord(receivedData)
        
        queryCtx.completion(.success(models))
    }

    /// Pure parsing logic – `static` (implicitly nonisolated on an actor) so it can be called
    /// safely from the C callback (background thread, non-isolated context).
    /// No actor state access, no `self.`, no isolation violations.
    private static func parseInlineTXTRecord(_ data: Data) -> Set<String> {
        var models = Set<String>()
        var index = 0
        while index < data.count {
            let length = Int(data[index])
            guard length > 0 && length <= 255 else { break }
            index += 1

            guard index + length <= data.count else { break }

            let strData = data.subdata(in: index..<index + length)
            if let str = String(data: strData, encoding: .utf8) {
                let modelList = str.split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
                models.formUnion(modelList)
            }
            index += length
        }

        #if DEBUG
        print("📜 [Parse TXT Record] Parsed models: \(models)")
        #endif

        return models
    }

    /// Nonisolated static release helper (called only from the synchronous continuation body).
    /// Kept for clarity; balances manual memory management without ever crossing actor isolation.
    private static func releaseContextPointer(_ ptr: UnsafeMutableRawPointer) {
        Unmanaged<QueryContext>.fromOpaque(ptr).release()
    }
}
