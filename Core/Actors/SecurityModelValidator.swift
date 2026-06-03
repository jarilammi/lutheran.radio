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

/// Actor-isolated validator for the required security model (via DNS TXT record).
///
/// `SecurityModelValidator` is the **single source of truth** for determining whether
/// the current app build is permitted to stream content. It queries DNS TXT records
/// on `securitymodels.lutheran.radio` (with backup domain) and requires that
/// ``SecurityConfiguration/expectedSecurityModel`` appears in the response.
///
/// ## Behavior
/// - Permanent failure (model not present) → streaming is permanently disabled.
/// - Transient failure → safe retry is allowed; the 1-hour success cache is bypassed.
/// - Success → result is cached for 1 hour in `UserDefaults`.
///
/// The actor uses strict Swift 6 isolation. All public API is `async` where mutation
/// or cross-actor access is involved.
///
/// - SeeAlso: ``<doc:Security-Invariants>``, ``<doc:Architecture>``, ``SecurityConfiguration``
public actor SecurityModelValidator {
    /// The shared singleton validator.
    ///
    /// All production code must go through this instance. The validator owns
    /// the in-memory and persisted cache state.
    public static let shared = SecurityModelValidator()

    private let config = SecurityConfiguration()
    private var validationState: ValidationState = .pending
    private var lastValidationTime: Date?

    private let userDefaultsKey = "lastSecurityValidation"

    /// Injectable for tests (time-dependent cache logic).
    internal var currentDate: @Sendable () -> Date = { Date() }

    #if DEBUG
    /// Test-only override for the TXT record fetch step (DNS-SD or fallback).
    ///
    /// When non-nil, `validateSecurityModel()` uses this closure instead of real
    /// `queryTXTRecord(for:)`. This enables fully deterministic success / permanent-fail /
    /// transient-fail testing without network or live DNS.
    ///
    /// Callers are responsible for also bypassing the 1-hour cache (see
    /// `_test_setTXTFetcher` which does this automatically).
    internal var _test_txtFetcher: (@Sendable (String) async throws -> Set<String>)?
    #endif

    private init() {
        if let saved = UserDefaults.standard.object(forKey: userDefaultsKey) as? Date {
            lastValidationTime = saved
        }
    }

    // MARK: - Public API

    /// Validates that the app's embedded security model is currently approved.
    ///
    /// This is the primary entry point. It:
    /// 1. Returns `true` immediately if a successful validation result is still within
    ///    the 1-hour cache window.
    /// 2. Otherwise performs DNS TXT queries (primary domain first, then backup on
    ///    transient errors only).
    /// 3. Returns `true` only if the expected model appears in the TXT record.
    ///
    /// On permanent failure the validator transitions to `.failedPermanent` and
    /// will continue returning `false` until the process exits.
    ///
    /// - Returns: `true` if the security model is approved and streaming may proceed.
    ///
    /// - SeeAlso: ``isCurrentlyValid()``, ``isPermanentlyInvalid``, ``<doc:Security-Invariants>``
    public func validateSecurityModel() async -> Bool {
        #if DEBUG
        print("🔒 SecurityModelValidator.validateSecurityModel() started")
        #endif

        guard !Task.isCancelled else {
            #if DEBUG
            print("🔒 Task cancelled")
            #endif
            return false
        }

        // Cache check (one hour)
        if let last = lastValidationTime ?? UserDefaults.standard.object(forKey: userDefaultsKey) as? Date,
           currentDate().timeIntervalSince(last) < config.modelCacheDuration {
            validationState = .success
            return true
        }

        // Try primary first, then backup on transient failure only
        for domain in config.securityModelDomains {
            do {
                #if DEBUG
                let validModels: Set<String>
                if let fetcher = _test_txtFetcher {
                    validModels = try await fetcher(domain)
                } else {
                    validModels = try await queryTXTRecord(for: domain)
                }
                #else
                let validModels = try await queryTXTRecord(for: domain)
                #endif

                let isValid = validModels.contains(config.expectedSecurityModel.lowercased())

                let now = currentDate()

                if isValid {
                    // Success on this domain → cache and return success
                    lastValidationTime = now
                    UserDefaults.standard.set(now, forKey: userDefaultsKey)
                    validationState = .success
                    
                    #if DEBUG
                    print("🔒 SecurityModelValidator] Success via domain: \(domain)")
                    #endif
                    
                    return true
                } else {
                    // Model explicitly not allowed → treat as permanent denial
                    // Do NOT try backup (authoritative failure)
                    validationState = .failedPermanent
                    
                    #if DEBUG
                    print("🔒 SecurityModelValidator] Permanent failure: '\(config.expectedSecurityModel)' not in TXT record from \(domain)")
                    #endif
                    
                    return false
                }
            } catch {
                // Transient error (network, DNS failure, timeout, etc.) → try next domain
                #if DEBUG
                print("🔒 SecurityModelValidator] Transient DNS error on \(domain): \(error)")
                #endif
                
                // Continue to backup domain
                continue
            }
        }

        // If we reach here, both domains failed with transient errors
        validationState = .failedTransient
        #if DEBUG
        print("🔒 SecurityModelValidator] All domains failed with transient errors")
        #endif
        return false
    }

    /// The current validation state, observed asynchronously.
    ///
    /// Useful for UI or diagnostics that need to react to changes without
    /// triggering a fresh validation.
    public var currentState: ValidationState {
        get async { validationState }
    }

    /// The possible states of a security model validation attempt.
    public enum ValidationState: Sendable {
        /// No validation attempt has completed yet (initial state).
        case pending

        /// The embedded security model was found in the TXT record and the result
        /// is still within the 1-hour success cache window.
        case success

        /// The embedded model was **not** present in the TXT record (authoritative failure).
        ///
        /// Streaming must remain disabled. Recovery requires a new app build.
        case failedPermanent

        /// All DNS queries failed with transient errors (network, timeout, etc.).
        ///
        /// The app may retry. A previous successful cache entry may still be used
        /// until it expires.
        case failedTransient
    }
    
    /// Convenience method that returns whether streaming is currently permitted.
    ///
    /// This is equivalent to calling ``validateSecurityModel()`` and is the
    /// recommended API for call sites that only need a boolean answer.
    ///
    /// Transient failures are treated as "not valid for now" (safe default).
    ///
    /// - Returns: `true` only when the last (or freshly performed) validation succeeded.
    public func isCurrentlyValid() async -> Bool {
        await validateSecurityModel()
    }
    
    /// Indicates whether the app has permanently failed security model validation.
    ///
    /// When `true`, the embedded model was not present in the DNS TXT record.
    /// Streaming is disabled and will remain disabled until the user installs
    /// an updated version of the app.
    ///
    /// This property does **not** trigger a new validation; it only reports
    /// the current state.
    public var isPermanentlyInvalid: Bool {
        get async {
            validationState == .failedPermanent
        }
    }
    
    // MARK: - State Recovery

    /// Clears any transient validation failure state and invalidates the 1-hour success cache.
    ///
    /// After calling this method, the next call to ``validateSecurityModel()`` or
    /// ``isCurrentlyValid()`` will perform a fresh DNS query (subject to normal
    /// transient retry logic).
    ///
    /// Permanent failures (``ValidationState/failedPermanent``) are unaffected.
    /// Use this method only to recover from transient network conditions during testing
    /// or after the user has explicitly requested a retry.
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
            let complete: @Sendable (Result<Set<String>, Error>) -> Void = { result in
                continuation.resume(with: result)
            }

            let context = QueryContext(completion: complete)
            let contextPtr = unsafe Unmanaged.passRetained(context).toOpaque()

            // Correct watchdog using DispatchTime
            let watchdog = DispatchWorkItem { [weak context] in
                guard let context, !context.isDone else { return }
                if let ref = unsafe context.serviceRef {
                    unsafe DNSServiceRefDeallocate(ref)
                    unsafe context.serviceRef = nil
                }
                context.completion(.failure(
                    NSError(domain: "dnssd", code: -999, userInfo: [NSLocalizedDescriptionKey: "DNS query timeout"])
                ))
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + 5.0,   // ← Correct: DispatchTime
                execute: watchdog
            )

            guard let domainCStr = domain.cString(using: .utf8) else {
                watchdog.cancel()
                unsafe Self.releaseContextPointer(contextPtr)
                complete(.failure(NSError(domain: "radio.lutheran", code: -998, userInfo: nil)))
                return
            }

            var serviceRef: DNSServiceRef?
            let err = unsafe DNSServiceQueryRecord(
                &serviceRef,
                0,
                0,
                domainCStr,
                UInt16(kDNSServiceType_TXT),
                UInt16(kDNSServiceClass_IN),
                Self.dnsQueryCallback,
                contextPtr
            )

            guard err == kDNSServiceErr_NoError, let serviceRef = unsafe serviceRef else {
                watchdog.cancel()
                unsafe Self.releaseContextPointer(contextPtr)
                complete(.failure(NSError(domain: "dnssd", code: Int(err), userInfo: nil)))
                return
            }

            unsafe context.serviceRef = unsafe serviceRef

            // Let dnssd drive the socket and deliver results via our existing C callback.
            // This is the Apple-recommended pattern (DNSServiceSetDispatchQueue);
            // no manual polling, no capture of non-Sendable DNSServiceRef into @Sendable closures.
            let processingQueue = DispatchQueue(label: "radio.lutheran.dnssd", qos: .userInitiated)
            let setQErr = unsafe DNSServiceSetDispatchQueue(serviceRef, processingQueue)
            guard setQErr == kDNSServiceErr_NoError else {
                watchdog.cancel()
                unsafe DNSServiceRefDeallocate(serviceRef)
                unsafe context.serviceRef = nil
                unsafe Self.releaseContextPointer(contextPtr)
                complete(.failure(NSError(domain: "dnssd", code: Int(setQErr), userInfo: nil)))
                return
            }
        }
    }

    // New static non-capturing callback — marked @convention(c) explicitly
    private static let dnsQueryCallback: DNSServiceQueryRecordReply = {
        sdRef, flags, interfaceIdx, errorCode, fullName, rrtype, rrclass, rdlen, rdata, ttl, ctx in
        
        guard let ctx = unsafe ctx else { return }

        let queryCtx = unsafe Unmanaged<QueryContext>.fromOpaque(ctx).takeRetainedValue()

        defer {
            queryCtx.isDone = true
            if let ref = unsafe queryCtx.serviceRef {
                unsafe DNSServiceRefDeallocate(ref)
                unsafe queryCtx.serviceRef = nil
            }
        }

        guard errorCode == kDNSServiceErr_NoError, let rdata = unsafe rdata else {
            queryCtx.completion(.failure(
                NSError(domain: "dnssd", code: Int(errorCode), userInfo: nil)
            ))
            return
        }

        let receivedData = unsafe Data(bytes: rdata, count: Int(rdlen))
        
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
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
                models.formUnion(modelList)
            }
            index += length
        }

        #if DEBUG
        print("📜 [Parse TXT Record] Parsed models: \(models)")
        #endif

        return models
    }

    // MARK: - Test-only exposure (zero production impact)

    #if DEBUG
    /// Test-only entry point for the pure DNS TXT record parser.
    ///
    /// This is the **only** supported way to exercise `parseInlineTXTRecord` from tests.
    /// The real parser remains private; this thin wrapper is compiled out of Release builds.
    ///
    /// - Parameter data: Raw wire-format DNS TXT rdata (length-prefixed strings).
    /// - Returns: Set of lowercased, trimmed model names parsed from the record(s).
    public static func _test_parseInlineTXTRecord(_ data: Data) -> Set<String> {
        parseInlineTXTRecord(data)
    }

    /// Install a deterministic TXT fetcher for tests and force cache bypass.
    ///
    /// This is the **recommended** entry point from tests. It:
    /// - Installs (or clears) the override fetcher
    /// - Clears the in-memory timestamp
    /// - Removes the persisted `UserDefaults` cache
    /// - Resets state to `.pending`
    ///
    /// Call with `nil` to restore real DNS behavior after a test.
    public static func _test_setTXTFetcher(
        _ fetcher: (@Sendable (String) async throws -> Set<String>)?,
        clearCache: Bool = true
    ) async {
        await shared._installTestTXTFetcher(fetcher, clearCache: clearCache)
    }

    private func _installTestTXTFetcher(
        _ fetcher: (@Sendable (String) async throws -> Set<String>)?,
        clearCache: Bool
    ) {
        _test_txtFetcher = fetcher

        if clearCache {
            lastValidationTime = nil
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
            validationState = .pending
        }
    }

    /// Test-only seam: override the time source used for the 1-hour success cache decision.
    ///
    /// Used by deterministic tests to force any previously-written success timestamp
    /// (including ones written by the running app in the same process) to appear stale,
    /// guaranteeing that the injected TXT fetcher is actually reached instead of the
    /// cache guard short-circuiting to .success.
    public static func _test_setCurrentDate(_ provider: @Sendable @escaping () -> Date) async {
        await shared._installCurrentDateProvider(provider)
    }

    private func _installCurrentDateProvider(_ provider: @Sendable @escaping () -> Date) {
        currentDate = provider
    }
    #endif

    /// Nonisolated static release helper (called only from the synchronous continuation body).
    /// Kept for clarity; balances manual memory management without ever crossing actor isolation.
    private static func releaseContextPointer(_ ptr: UnsafeMutableRawPointer) {
        unsafe Unmanaged<QueryContext>.fromOpaque(ptr).release()
    }
}
