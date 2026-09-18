//
//  SecurityModelValidator.swift
//  Core
//
//  DNS TXT security-model validation (``<doc:Security-Invariants>`` Invariant 1).
//  The actor owns cache, `validationState`, and in-flight coalescing. The DNS-SD
//  C callback and 5 s watchdog are outside the actor: `QueryContext` uses
//  `Mutex` claim-once teardown so they cannot both `DNSServiceRefDeallocate`,
//  `continuation.resume`, or parse `rdata` after the service is gone.
//
//  Created by Jari Lammi on 19.3.2026.
//

import Foundation
import Synchronization
import dnssd

/// Result of a claim-once finish attempt on a DNS-SD TXT query session.
///
/// `serviceRefBits` is the opaque `DNSServiceRef` identifier (or `nil` if none
/// was stored). The winner deallocates outside the mutex.
private enum SessionFinishClaim: Sendable {
    case alreadyFinished
    case won(serviceRefBits: UInt?)
}

/// SAFETY: `DispatchWorkItem` is not `Sendable`. This wrapper is shared between
/// the setup path (`asyncAfter`) and the claim-once mutex; the only cross-thread
/// operation is thread-safe `cancel()`.
private struct SendableWatchdog: @unchecked Sendable {
    let item: DispatchWorkItem
    func cancel() { item.cancel() }
}

/// Mutable DNS-SD session state. `~Copyable` so it can live inside `Mutex` as
/// the unique owner of “who may finish this query”.
///
/// `serviceRefBits` stores the `DNSServiceRef` (`OpaquePointer`) bit pattern as
/// a `Sendable` identifier — not a Swift-owned object. The claim-once winner is
/// the only caller that may reconstruct the pointer and `DNSServiceRefDeallocate`.
private struct DNSQuerySession: ~Copyable {
    var didFinish = false
    var serviceRefBits: UInt?
    var watchdog: SendableWatchdog?
}

/// Low-level context for the DNS-SD TXT query callback and timeout watchdog.
///
/// The validator is an `actor`, but this session cannot be actor-isolated: the
/// dns_sd callback runs on `radio.lutheran.dnssd` and the 5 s watchdog runs on
/// a global queue. `Mutex` serializes who may finish the session (claim-once).
///
/// Mutable fields live in ``DNSQuerySession`` inside `session`. `completion` is
/// `@Sendable` and `processingQueue` is immutable after init, so this class is
/// `Sendable` without `@unchecked`.
///
/// - Important: `DNSServiceRefDeallocate` and `completion` / `continuation.resume`
///   run **outside** `Mutex.withLock`. The mutex is not recursive; deallocate may
///   deliver work on the dns_sd queue, which would deadlock if the callback
///   tried the same mutex while it was still held.
/// - Important: Parse `rdata` only after winning the claim and **before**
///   deallocating the service. `Span` cannot keep `rdata` alive.
/// - Note: `passRetained` at query start is balanced **exactly once**: callback
///   win consumes via `takeRetainedValue`, timeout-win `release`s on
///   `processingQueue` (so a queued callback can still `takeUnretainedValue`),
///   setup-failure `release`s on the setup thread.
/// - SeeAlso: ``<doc:Security-Invariants>`` (Invariant 1), ``SecurityModelValidator``
@safe
private final class QueryContext: Sendable {
    let completion: @Sendable (Result<Set<String>, Error>) -> Void
    let session: Mutex<DNSQuerySession>
    let processingQueue: DispatchQueue

    init(completion: @escaping @Sendable (Result<Set<String>, Error>) -> Void) {
        self.completion = completion
        self.session = Mutex(DNSQuerySession())
        self.processingQueue = DispatchQueue(label: "radio.lutheran.dnssd", qos: .userInitiated)
    }

    /// First caller wins the session; later callers are no-ops.
    ///
    /// The winner receives the stored `DNSServiceRef` bit pattern (if any) and
    /// the watchdog is cancelled under the lock (`cancel()` only sets a flag).
    ///
    /// - Returns: ``SessionFinishClaim/won(serviceRefBits:)`` exactly once per
    ///   instance; thereafter ``SessionFinishClaim/alreadyFinished``.
    func claimFinish() -> SessionFinishClaim {
        session.withLock { state in
            if state.didFinish {
                return SessionFinishClaim.alreadyFinished
            }
            state.didFinish = true
            state.watchdog?.cancel()
            state.watchdog = nil
            let bits = state.serviceRefBits
            state.serviceRefBits = nil
            return SessionFinishClaim.won(serviceRefBits: bits)
        }
    }

    func storeWatchdog(_ watchdog: SendableWatchdog) {
        session.withLock { state in
            if !state.didFinish {
                state.watchdog = watchdog
            }
        }
    }

    /// Stores the service ref for later claim-once teardown.
    ///
    /// - Returns: `false` if the session already finished (caller must deallocate
    ///   `ref` itself). `true` if this instance now owns deallocate duty.
    func storeServiceRef(_ ref: DNSServiceRef) -> Bool {
        // SAFETY: `DNSServiceRef` is an opaque C pointer identifier. Storing the
        // bit pattern keeps `DNSQuerySession` `Sendable` inside `Mutex` without
        // wrapping `OpaquePointer`. Reconstruct only to `DNSServiceRefDeallocate`.
        let bits = unsafe UInt(bitPattern: UnsafeRawPointer(ref))
        return session.withLock { state in
            if state.didFinish { return false }
            state.serviceRefBits = bits
            return true
        }
    }

    /// Timeout-win path: claim, deallocate, resume as transient `dnssd` / `-999`,
    /// then balance `Unmanaged` on `processingQueue`.
    func handleTimeout() {
        switch claimFinish() {
        case .alreadyFinished:
            return
        case .won(let bits):
            deallocateDNSServiceRef(bits: bits)
            completion(.failure(
                NSError(domain: "dnssd", code: -999, userInfo: [NSLocalizedDescriptionKey: "DNS query timeout"])
            ))
            // Hop `Unmanaged.release` onto the dns_sd queue so a callback already
            // queued there can still `takeUnretainedValue` and observe alreadyFinished.
            processingQueue.async { [self] in
                unsafe Unmanaged.passUnretained(self).release()
            }
        }
    }
}

/// Reconstructs a `DNSServiceRef` from the mutex-stored bit pattern and deallocates it.
///
/// When `bits` is non-nil it is the stored identifier (do not also deallocate `extra`).
/// When `bits` is nil, `extra` is a locally created ref that was never stored.
///
/// - Parameters:
///   - bits: Claimed `DNSServiceRef` bit pattern, or `nil`.
///   - extra: Setup-path ref not yet stored in the session, or `nil`.
private func deallocateDNSServiceRef(bits: UInt?, extra: DNSServiceRef? = nil) {
    // SAFETY: `DNSServiceRef` is an opaque C pointer (`OpaquePointer`). Stored
    // sessions reconstruct from the bit pattern; setup-path `extra` is a ref
    // that was never stored. Never deallocate both (bits take precedence).
    if let bits, let ref = unsafe OpaquePointer(bitPattern: bits) {
        unsafe DNSServiceRefDeallocate(ref)
        return
    }
    if let extra = unsafe extra {
        unsafe DNSServiceRefDeallocate(extra)
    }
}

/// Actor-isolated validator for the required security model (via DNS TXT record).
///
/// `SecurityModelValidator` is the **single source of truth** for determining whether
/// the current app build is permitted to stream content. It queries DNS TXT records
/// in ``SecurityConfiguration/securityModelDomains`` order (today:
/// `securitymodels.siikkari.net` → `securitymodels.lutheranradio.eu` →
/// `securitymodels.lutheranradio.sk`) and requires that
/// ``SecurityConfiguration/expectedSecurityModel`` appears in the response.
///
/// ## Security Hardening
/// Queries are performed with `kDNSServiceFlagsValidate`. The callback **requires**
/// the echoed validation bit in `flags` before parsing or accepting any rdata.
/// Unvalidated responses are failures (transient). This provides DNSSEC-backed
/// integrity/authenticity for the allow-list without new dependencies.
///
/// ## Behavior
/// Ordered ``securityModelDomains`` walk (AGENT NOTE — single contract with
/// ``<doc:Security-Invariants>`` Invariant 1):
/// 1. **Authoritative answer** = DNSSEC-validated TXT rdata accepted by the callback (including empty set).
/// 2. **Contains expected model** → success; **stop** (later hosts not queried).
/// 3. **Does not contain it** → permanent fail; **stop** (no fall-through).
/// 4. **Transient** (error, timeout, no validate bit, etc.) → next host; that host is
///    **fully trusted** if it returns an authoritative allow-list containing the expected model.
/// - Success (model present **and** DNSSEC-validated) → result is cached for 1 hour in `UserDefaults`.
/// - Permanent failure → streaming is permanently disabled for the process lifetime.
///
/// The actor uses strict Swift 6 isolation. All public API is `async` where mutation
/// or cross-actor access is involved. DNS-SD callback vs watchdog teardown is
/// serialized by `QueryContext` `Mutex` claim-once — not by replacing this actor.
///
/// - SeeAlso: ``<doc:Security-Invariants>`` (Invariant 1 ordered host walk), ``<doc:Architecture>``, ``SecurityConfiguration``
public actor SecurityModelValidator {
    /// The shared singleton validator.
    ///
    /// All production code must go through this instance. The validator owns
    /// the in-memory and persisted cache state.
    public static let shared = SecurityModelValidator()

    private var config: SecurityConfiguration { SecurityConfiguration.current }
    private var validationState: ValidationState = .pending
    private var lastValidationTime: Date?
    /// Coalesces overlapping ``validateSecurityModel()`` calls (e.g. init Task + cold-launch ``play()``).
    private var inFlightValidation: Task<Bool, Never>?

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
    /// 2. Otherwise performs DNS TXT queries in ``securityModelDomains`` order
    ///    (authoritative answer stops the walk; only transient advances — see type-level
    ///    Behavior list and ``<doc:Security-Invariants>`` Invariant 1).
    /// 3. Returns `true` only if the expected model appears in an authoritative TXT set.
    ///
    /// On permanent failure the validator transitions to `.failedPermanent` and
    /// will continue returning `false` until the process exits.
    ///
    /// - Returns: `true` if the security model is approved and streaming may proceed.
    ///
    /// - SeeAlso: ``isCurrentlyValid()``, ``isPermanentlyInvalid``, ``<doc:Security-Invariants>``
    public func validateSecurityModel() async -> Bool {
        guard !Task.isCancelled else {
            #if DEBUG
            print("[SecurityModelValidator] Task cancelled")
            #endif
            return false
        }

        if isSuccessCacheFresh() {
            validationState = .success
            return true
        }

        if validationState == .failedPermanent {
            return false
        }

        if let inFlight = inFlightValidation {
            return await inFlight.value
        }

        let task = Task { await self.performFreshValidation() }
        inFlightValidation = task
        let result = await task.value
        inFlightValidation = nil
        return result
    }

    /// Returns whether a successful validation is still within the 1-hour cache window.
    private func isSuccessCacheFresh() -> Bool {
        if validationState == .success,
           let last = lastValidationTime,
           currentDate().timeIntervalSince(last) < config.modelCacheDuration {
            return true
        }

        if let last = lastValidationTime ?? UserDefaults.standard.object(forKey: userDefaultsKey) as? Date,
           currentDate().timeIntervalSince(last) < config.modelCacheDuration {
            return true
        }

        return false
    }

    /// Performs DNS TXT validation when cache is stale or absent. DEBUG "started" logs only here.
    private func performFreshValidation() async -> Bool {
        #if DEBUG
        print("[SecurityModelValidator] validateSecurityModel() started")
        #endif

        guard !Task.isCancelled else {
            #if DEBUG
            print("[SecurityModelValidator] Task cancelled")
            #endif
            return false
        }

        // Ordered host walk: authoritative answer stops; only transient advances
        // (Security-Invariants Invariant 1 — four-point contract).
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

                // Authoritative answer (validated TXT set, including empty).
                let isValid = validModels.contains(config.expectedSecurityModel.lowercased())

                let now = currentDate()

                if isValid {
                    // Contains expected model → success; stop (later hosts not queried).
                    lastValidationTime = now
                    UserDefaults.standard.set(now, forKey: userDefaultsKey)
                    validationState = .success
                    
                    #if DEBUG
                    print("[SecurityModelValidator] Success via domain: \(domain)")
                    #endif
                    
                    return true
                } else {
                    // Does not contain it → permanent fail; stop (no fall-through).
                    validationState = .failedPermanent
                    
                    #if DEBUG
                    print("[SecurityModelValidator] Permanent failure: '\(config.expectedSecurityModel)' not in TXT record from \(domain)")
                    #endif
                    
                    return false
                }
            } catch {
                // Transient (error, timeout, no validate bit, etc.) → next host.
                #if DEBUG
                print("[SecurityModelValidator] Transient DNS error on \(domain): \(error)")
                #endif
                
                continue
            }
        }

        // All hosts failed with transient errors only.
        validationState = .failedTransient
        #if DEBUG
        print("[SecurityModelValidator] All domains failed with transient errors")
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
            print("[SecurityModelValidator] Reset transient state → pending, cache invalidated")
            #endif
        }
    }
    
    // MARK: - Private implementation

    /// Performs the low-level DNS-SD TXT query using `DNSServiceQueryRecord`.
    ///
    /// Sets up `QueryContext` (Mutex claim-once session), a 5 s watchdog, and
    /// `DNSServiceSetDispatchQueue` on `radio.lutheran.dnssd`. Watchdog, callback,
    /// and setup-failure paths finish through `QueryContext.claimFinish()`.
    ///
    /// - Important: The call passes `kDNSServiceFlagsValidate` and the callback enforces
    ///   the bit before trusting rdata. Failures (including lack of DNSSEC validation)
    ///   are thrown and treated as transient by the caller.
    /// - Important: Do not parse on the watchdog path. Timeout is transient (`dnssd` / `-999`).
    /// - SeeAlso: ``<doc:Security-Invariants>`` (Invariant 1)
    private func queryTXTRecord(for domain: String) async throws -> Set<String> {
        try await withCheckedThrowingContinuation { continuation in
            let complete: @Sendable (Result<Set<String>, Error>) -> Void = { result in
                continuation.resume(with: result)
            }

            let context = QueryContext(completion: complete)
            let contextPtr = unsafe Unmanaged.passRetained(context).toOpaque()

            let watchdog = DispatchWorkItem { [context] in
                context.handleTimeout()
            }
            context.storeWatchdog(SendableWatchdog(item: watchdog))
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + 5.0,
                execute: watchdog
            )

            /// Setup-path failure: claim-once so a racing timeout cannot also resume.
            /// `createdRef` is a local `DNSServiceRef` that may or may not already
            /// be stored in the session (`refWasStored`).
            func failSetup(_ error: Error, createdRef: DNSServiceRef? = nil, refWasStored: Bool = false) {
                switch context.claimFinish() {
                case .alreadyFinished:
                    // SAFETY: Local `DNSServiceRef` never stored in the session.
                    if let createdRef = unsafe createdRef, !refWasStored {
                        unsafe DNSServiceRefDeallocate(createdRef)
                    }
                    return
                case .won(let bits):
                    // SAFETY: May pass a setup-path `DNSServiceRef` that was never
                    // stored (`extra`); `deallocateDNSServiceRef` is implicitly
                    // `@unsafe` because of that C pointer parameter.
                    unsafe deallocateDNSServiceRef(bits: bits, extra: createdRef)
                    unsafe Self.releaseContextPointer(contextPtr)
                    context.completion(.failure(error))
                }
            }

            guard let domainCStr = domain.cString(using: .utf8) else {
                failSetup(NSError(domain: "radio.lutheran", code: -998, userInfo: nil))
                return
            }

            var serviceRef: DNSServiceRef?
            // SECURITY: Enable strict DNSSEC validation via kDNSServiceFlagsValidate (not Optional).
            // mDNSResponder will attempt validation for signed zones and set the bit in the callback
            // `flags` parameter **only** on successful validation. We refuse unvalidated rdata for
            // the security model allow-list (data integrity + authenticity). See
            // <doc:Security-Invariants> Invariant 1 and README "Why DNS TXT Records?".
            // This is a minimal hardening step; no new dependencies.
            let err = unsafe DNSServiceQueryRecord(
                &serviceRef,
                UInt32(kDNSServiceFlagsValidate),
                0,
                domainCStr,
                UInt16(kDNSServiceType_TXT),
                UInt16(kDNSServiceClass_IN),
                Self.dnsQueryCallback,
                contextPtr
            )

            guard err == kDNSServiceErr_NoError, let created = unsafe serviceRef else {
                failSetup(NSError(domain: "dnssd", code: Int(err), userInfo: nil))
                return
            }

            // SAFETY: `storeServiceRef` takes a `DNSServiceRef` (opaque C pointer)
            // and immediately stores only its bit pattern.
            if unsafe !context.storeServiceRef(created) {
                // Timeout already claimed (no stored ref). Do not resume again.
                unsafe DNSServiceRefDeallocate(created)
                return
            }

            // Let dnssd drive the socket and deliver results via our existing C callback.
            // This is the Apple-recommended pattern (DNSServiceSetDispatchQueue);
            // no manual polling, no capture of non-Sendable DNSServiceRef into @Sendable closures.
            let setQErr = unsafe DNSServiceSetDispatchQueue(created, context.processingQueue)
            guard setQErr == kDNSServiceErr_NoError else {
                // SAFETY: `failSetup` is implicitly `@unsafe` (`DNSServiceRef?` parameter).
                unsafe failSetup(
                    NSError(domain: "dnssd", code: Int(setQErr), userInfo: nil),
                    createdRef: created,
                    refWasStored: true
                )
                return
            }
        }
    }

    // Static non-capturing callback — marked @convention(c) explicitly
    //
    // SECURITY: This is the enforcement point for DNSSEC validation. The `flags` bit check
    // must succeed before any rdata is parsed via parseInlineTXTRecord. All test hooks
    // bypass this path via `_test_txtFetcher`.
    //
    // Claim-once: `takeUnretainedValue` does not consume `passRetained`. Only the
    // winner `takeRetainedValue`s; a loser returns without parsing, completing, or
    // deallocating. Parse happens only after win and before `DNSServiceRefDeallocate`.
    private static let dnsQueryCallback: DNSServiceQueryRecordReply = {
        sdRef, flags, interfaceIdx, errorCode, fullName, rrtype, rrclass, rdlen, rdata, ttl, ctx in

        guard let ctx = unsafe ctx else { return }

        // SAFETY: `QueryContext` stays alive while Unmanaged's `passRetained` is
        // outstanding and/or the watchdog / processing-queue release hop holds it.
        // `fromOpaque` / `takeUnretainedValue` / `takeRetainedValue` are `Unmanaged`
        // (unsafe C-interop retain). `takeUnretainedValue` does not consume that
        // retain; `claimFinish` decides who balances it.
        let unmanaged = unsafe Unmanaged<QueryContext>.fromOpaque(ctx)
        let queryCtx = unsafe unmanaged.takeUnretainedValue()

        switch queryCtx.claimFinish() {
        case .alreadyFinished:
            return
        case .won(let bits):
            // Consume `passRetained`. Timeout-win must not also release.
            _ = unsafe unmanaged.takeRetainedValue()

            func deallocateClaimed() {
                deallocateDNSServiceRef(bits: bits)
            }

            guard errorCode == kDNSServiceErr_NoError else {
                deallocateClaimed()
                queryCtx.completion(.failure(
                    NSError(domain: "dnssd", code: Int(errorCode), userInfo: nil)
                ))
                return
            }

            // SECURITY: Require that the response was DNSSEC-validated by the system.
            // When kDNSServiceFlagsValidate was passed to DNSServiceQueryRecord, the returned
            // `flags` will contain the bit only if validation succeeded. Unvalidated responses
            // are treated as transient failures (performFreshValidation falls back to backup
            // domain or marks .failedTransient). Never silently accept unvalidated data here.
            let wasValidated = (flags & UInt32(kDNSServiceFlagsValidate)) != 0
            #if DEBUG
            print("[SecurityModelValidator] DNS response: validated=\(wasValidated) flags=0x\(String(flags, radix: 16)) errorCode=\(errorCode)")
            #endif
            guard wasValidated else {
                deallocateClaimed()
                queryCtx.completion(.failure(
                    NSError(domain: "dnssec", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "DNSSEC validation failed or not available"
                    ])
                ))
                return
            }

            let byteCount = Int(rdlen)
            let models: Set<String>
            if byteCount == 0 {
                models = []
            } else if let rdata = unsafe rdata {
                // SAFETY: `rdata` is valid for `byteCount` bytes only for this callback
                // (dns_sd contract), and only because this callback won the claim before
                // anyone deallocated the service. `Span` borrows the pointer and must
                // not escape; parsing completes before deallocate and completion.
                let rdataStart = unsafe rdata.assumingMemoryBound(to: UInt8.self)
                models = SecurityModelValidator.parseInlineTXTRecord(
                    span: unsafe Span(_unsafeStart: rdataStart, count: byteCount)
                )
            } else {
                deallocateClaimed()
                queryCtx.completion(.failure(
                    NSError(domain: "dnssd", code: Int(errorCode), userInfo: nil)
                ))
                return
            }

            deallocateClaimed()
            queryCtx.completion(.success(models))
        }
    }

    /// Pure parsing logic – `static` (implicitly nonisolated on an actor) so it can be called
    /// safely from the C callback (background thread, non-isolated context).
    /// No actor state access, no `self.`, no isolation violations.
    private static func parseInlineTXTRecord(_ data: Data) -> Set<String> {
        parseInlineTXTRecord(span: data.span)
    }

    /// Length-prefixed DNS TXT rdata parser using `Span<UInt8>` views (no per-label `subdata`).
    ///
    /// `span` must not escape the caller's scope. Production DNS-SD callbacks borrow `rdata`
    /// in place (zero-copy); tests may borrow via `Data.span`.
    private static func parseInlineTXTRecord(span: Span<UInt8>) -> Set<String> {
        var models = Set<String>()
        var index = 0
        while index < span.count {
            let length = Int(span[index])
            guard length > 0, length <= 255 else { break }
            index += 1

            let labelEnd = index + length
            guard labelEnd <= span.count else { break }

            let labelSpan = span.extracting(index..<labelEnd)
            index = labelEnd

            if let str = utf8String(from: labelSpan) {
                models.formUnion(modelsFromTXTLabel(str))
            }
        }

        #if DEBUG
        print("[SecurityModelValidator] Parsed TXT models: \(models)")
        #endif

        return models
    }

    /// Validates UTF-8 in-place over a borrowed label span, then materializes a `String`.
    private static func utf8String(from labelSpan: Span<UInt8>) -> String? {
        do {
            let utf8 = try UTF8Span(validating: labelSpan)
            return String(copying: utf8)
        } catch {
            return nil
        }
    }

    private static func modelsFromTXTLabel(_ label: String) -> Set<String> {
        Set(
            label.split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
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
            inFlightValidation?.cancel()
            inFlightValidation = nil
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

    /// Sequential claim-once: first `claimFinish` wins, the second is already finished.
    ///
    /// No `DNSServiceRef` or live DNS. Protects the Mutex session invariant that
    /// watchdog and callback cannot both finish the same `QueryContext`.
    ///
    /// - Returns: `(firstWon: true, secondAlreadyFinished: true)` on a correct session.
    /// - SeeAlso: ``<doc:Security-Invariants>`` Invariant 1
    public static func _test_queryContextClaimFinishIsOnce() -> (firstWon: Bool, secondAlreadyFinished: Bool) {
        let context = QueryContext(completion: { _ in })
        let firstWon: Bool
        if case .won = context.claimFinish() {
            firstWon = true
        } else {
            firstWon = false
        }
        let secondAlreadyFinished: Bool
        if case .alreadyFinished = context.claimFinish() {
            secondAlreadyFinished = true
        } else {
            secondAlreadyFinished = false
        }
        return (firstWon, secondAlreadyFinished)
    }

    /// Concurrent claim-once: exactly one winner among racing callers.
    ///
    /// - Parameter iterations: Number of concurrent `claimFinish` attempts.
    /// - Returns: Count of `.won` results (must be `1`).
    /// - SeeAlso: ``<doc:Security-Invariants>`` Invariant 1
    public static func _test_queryContextConcurrentClaimWinnerCount(iterations: Int = 32) -> Int {
        let context = QueryContext(completion: { _ in })
        let winnerCount = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            if case .won = context.claimFinish() {
                winnerCount.withLock { count in
                    count += 1
                }
            }
        }
        return winnerCount.withLock { $0 }
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
