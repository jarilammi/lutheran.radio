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
//  Why the callback buffers: `dns_sd.h` delivers DNSSEC status separately from
//  the TXT RRset. A status callback is `kDNSServiceFlagsValidate` +
//  `kDNSServiceFlagsAdd` with zero-length rdata. The Validate bit means
//  "status is available", not "validation succeeded". Acceptance is
//  `kDNSServiceFlagsSecure` only. A watchdog with zero callbacks is not a
//  delivered status: the actor then verifies the TXT RRset locally. A callback
//  that already arrived is never replaced by that path.
//  See ``<doc:Security-Invariants>`` Invariant 1.
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
///
/// `bufferedModels` holds TXT names already parsed from non-status callbacks.
/// The pointer `rdata` is only valid for the duration of that callback, so the
/// set is copied out under the mutex before the lock is released. A later
/// zero-length status callback does not replace this set.
private struct DNSQuerySession: ~Copyable {
    var didFinish = false
    var serviceRefBits: UInt?
    var watchdog: SendableWatchdog?
    /// Parsed allow-list tokens from data callbacks. Empty until the first one.
    var bufferedModels = Set<String>()
    /// `kDNSServiceFlagsSecure` was observed and has not been invalidated by a removal.
    var sawSecureStatus = false
    /// Callbacks that took the mutex before the session finished.
    /// Zero when the watchdog claims means the system validator never called back.
    var callbackCount = 0
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
/// - Important: Parse `rdata` while the mutex is held, before returning, and
///   before any claim deallocates the service. `Span` cannot keep `rdata` alive.
///   Data callbacks do **not** claim the session. Claim-once runs when a status
///   callback accepts or rejects the buffer, or on transport error, timeout, or
///   setup failure — one winner deallocates and resumes.
/// - Note: `passRetained` at query start is balanced **exactly once**: the
///   finishing callback consumes via `takeRetainedValue`, timeout-win `release`s
///   on `processingQueue` (so a queued callback can still `takeUnretainedValue`),
///   setup-failure `release`s on the setup thread. Callbacks that only buffer
///   rdata must not release.
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
    /// Data callbacks must not call this. They buffer parsed TXT names and wait
    /// for the DNSSEC status callback. The status path, transport errors, the
    /// watchdog, and setup failure share this claim so only one of them
    /// deallocates and resumes.
    ///
    /// - Returns: ``SessionFinishClaim/won(serviceRefBits:)`` exactly once per
    ///   instance; thereafter ``SessionFinishClaim/alreadyFinished``.
    func claimFinish() -> SessionFinishClaim {
        session.withLock { state in
            takeFinishClaim(&state)
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

    /// Distinguishes a watchdog that won before any callback from one that won after.
    ///
    /// Does not deallocate or resume. ``handleTimeout()`` does that outside the mutex.
    func claimTimeout() -> TimeoutClaim {
        session.withLock { state in
            if state.didFinish {
                return TimeoutClaim.alreadyFinished
            }
            let silence = state.callbackCount == 0
            switch takeFinishClaim(&state) {
            case .alreadyFinished:
                return TimeoutClaim.alreadyFinished
            case .won(let bits):
                if silence {
                    return TimeoutClaim.silence(serviceRefBits: bits)
                }
                return TimeoutClaim.afterCallbacks(serviceRefBits: bits)
            }
        }
    }

    /// Timeout-win path. Zero callbacks resume ``SystemDNSSECValidatorSilence``.
    /// A timeout after any callback stays transient `dnssd` / `-999` and is not verified locally.
    /// Deallocate and resume run outside the mutex. `Unmanaged` is balanced on `processingQueue`.
    func handleTimeout() {
        let failure: Error
        let bits: UInt?
        switch claimTimeout() {
        case .alreadyFinished:
            return
        case .afterCallbacks(let serviceBits):
            bits = serviceBits
            failure = NSError(domain: "dnssd", code: -999, userInfo: [NSLocalizedDescriptionKey: "DNS query timeout"])
        case .silence(let serviceBits):
            bits = serviceBits
            failure = SystemDNSSECValidatorSilence()
        }
        deallocateDNSServiceRef(bits: bits)
        completion(.failure(failure))
        // Hop `Unmanaged.release` onto the dns_sd queue so a callback already
        // queued there can still `takeUnretainedValue` and observe alreadyFinished.
        processingQueue.async { [self] in
            unsafe Unmanaged.passUnretained(self).release()
        }
    }

    /// Folds one dns_sd callback into the session while the mutex is held.
    ///
    /// `rdata` is borrowed only inside this call. The returned value tells the
    /// caller whether it won claim-once and must deallocate and resume outside
    /// the lock.
    ///
    /// - Parameters:
    ///   - flags: Callback `DNSServiceFlags`. Do not treat Validate as success.
    ///   - errorCode: Non-zero is a transport failure and finishes the session.
    ///   - rdlen: Byte length of `rdata`. Zero with Validate+Add is status, not data.
    ///   - rdata: Borrowed TXT rdata, or `nil` when `rdlen` is 0.
    /// - Returns: ``SessionIngest`` describing wait, lose, or the single finish.
    func ingestDNSCallback(
        flags: UInt32,
        errorCode: DNSServiceErrorType,
        rdlen: Int,
        rdata: UnsafeRawPointer?
    ) -> SessionIngest {
        session.withLock { state in
            if state.didFinish {
                return SessionIngest.alreadyFinished
            }
            state.callbackCount += 1
            if errorCode != kDNSServiceErr_NoError {
                return finishClaim(&state, .failure(.dnssd(errorCode)))
            }
            if isValidationStatusDelivery(flags: flags, rdlen: rdlen) {
                return reduceValidationStatus(&state, flags: flags)
            }

            // SAFETY: `rdata` is valid for `rdlen` bytes only for this callback
            // (dns_sd contract). The mutex is held, so the watchdog cannot
            // `DNSServiceRefDeallocate` until this closure returns. `Span` borrows
            // the pointer and must not escape; parsing finishes before the lock drops.
            let models: Set<String>
            if rdlen == 0 {
                models = []
            } else if let rdata = unsafe rdata {
                let rdataStart = unsafe rdata.assumingMemoryBound(to: UInt8.self)
                models = SecurityModelValidator.parseInlineTXTRecord(
                    span: unsafe Span(_unsafeStart: rdataStart, count: rdlen)
                )
            } else {
                // `errorCode` is already `kDNSServiceErr_NoError` here; rdata was missing.
                return finishClaim(&state, .failure(.dnssd(errorCode)))
            }
            return reduceRecord(&state, flags: flags, models: models)
        }
    }

    /// Test and status-path entry that already holds parsed models (no `rdata` borrow).
    func ingestPrepared(_ prepared: PreparedDNSCallback) -> SessionIngest {
        session.withLock { state in
            if state.didFinish {
                return SessionIngest.alreadyFinished
            }
            state.callbackCount += 1
            switch prepared {
            case .transportError(let code):
                return finishClaim(&state, .failure(.dnssd(code)))
            case .validationStatus(let flags):
                return reduceValidationStatus(&state, flags: flags)
            case .record(let flags, let models):
                return reduceRecord(&state, flags: flags, models: models)
            }
        }
    }

    /// Claim-once winner side effect: deallocate and resume. No-op unless `ingest` finished.
    func deliver(_ ingest: SessionIngest) {
        guard case .finish(let bits, let result) = ingest else { return }
        deallocateDNSServiceRef(bits: bits)
        switch result {
        case .models(let models):
            completion(.success(models))
        case .failure(let failure):
            completion(.failure(nsError(for: failure)))
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

/// Watchdog claim. `silence` means `callbackCount` was still zero.
private enum TimeoutClaim: Sendable {
    case alreadyFinished
    case silence(serviceRefBits: UInt?)
    case afterCallbacks(serviceRefBits: UInt?)
}

/// The system validator closed the 5 s watchdog without delivering any callback.
/// This is not `dnssd` / `-999`. The host walk may verify the RRset locally.
struct SystemDNSSECValidatorSilence: Error {}

/// Result of the system TXT query before local verification is considered.
enum SystemTXTOutcome: Sendable {
    case authoritative(Set<String>)
    case transient(NSError)
    case noCallback
}

/// Why a DNS-SD callback failed. Transport errors stay on `dnssd`. Missing or
/// non-Secure DNSSEC status stays on `dnssec` / `-1` (transient for the host walk).
private enum DNSCallbackFailure: Sendable {
    case dnssd(DNSServiceErrorType)
    case dnssecNotSecure
}

/// Outcome of the single claim-once finish. `models` is an authoritative TXT set,
/// including an empty set when Secure status arrived with no records.
private enum IngestResult: Sendable {
    case models(Set<String>)
    case failure(DNSCallbackFailure)
}

/// What the callback must do after the mutex is released.
///
/// `.waiting` keeps the `DNSServiceRef` alive for a later status or rdata callback.
/// `.finish` is the one claim-once winner. `.alreadyFinished` must not deallocate
/// or resume.
private enum SessionIngest: Sendable {
    case waiting
    case alreadyFinished
    case finish(serviceRefBits: UInt?, result: IngestResult)
}

/// Callback facts after `rdata` has been parsed (or when there is no rdata to parse).
///
/// Status deliveries are not records. A zero-length status callback must use
/// `.validationStatus` so it cannot be stored as an empty allow-list by itself
/// before the Secure check.
private enum PreparedDNSCallback: Sendable {
    case transportError(DNSServiceErrorType)
    case validationStatus(flags: UInt32)
    case record(flags: UInt32, models: Set<String>)
}

/// Marks the session finished. Caller must already have observed `didFinish == false`
/// or must ignore ``SessionFinishClaim/alreadyFinished``.
private func takeFinishClaim(_ state: inout DNSQuerySession) -> SessionFinishClaim {
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

/// Claims the session and packages the result for delivery outside the lock.
private func finishClaim(_ state: inout DNSQuerySession, _ result: IngestResult) -> SessionIngest {
    switch takeFinishClaim(&state) {
    case .alreadyFinished:
        return .alreadyFinished
    case .won(let bits):
        return .finish(serviceRefBits: bits, result: result)
    }
}

/// Output flags that may sit beside a DNSSEC status code. Mask these before
/// comparing to `kDNSServiceFlagsSecure` and the other status constants.
///
/// Do not mask `0x10` / `0x20` / `0x40` / `0x80`. Those bits are the status
/// code (`kDNSServiceFlagsShared` overlaps Secure's low bit only as a numeric
/// coincidence; Secure is `Validate | 0x10`, value `0x200010`).
private func dnssecStatusCode(from flags: UInt32) -> UInt32 {
    let accompanyingOutput = UInt32(kDNSServiceFlagsMoreComing)
        | UInt32(kDNSServiceFlagsAdd)
        | UInt32(kDNSServiceFlagAnsweredFromCache)
    return flags & ~accompanyingOutput
}

/// `kDNSServiceFlagsSecure` after masking MoreComing, Add, and the cache bit.
///
/// A nonzero test against `kDNSServiceFlagsSecure` is wrong: that constant is
/// `0x200010`, and the Validate bit alone (`0x200000`) is a subset of the mask.
/// Validate means "status is available" (`dns_sd.h`), not "validated".
/// An expired answer is rejected even when the Secure code is also present.
private func isSecureDNSSECStatus(_ flags: UInt32) -> Bool {
    if (flags & UInt32(kDNSServiceFlagsExpiredAnswer)) != 0 {
        return false
    }
    return dnssecStatusCode(from: flags) == UInt32(kDNSServiceFlagsSecure)
}

/// Insecure, bogus, or indeterminate after the same mask. These are not Secure.
private func isNonSecureDNSSECStatus(_ flags: UInt32) -> Bool {
    let code = dnssecStatusCode(from: flags)
    return code == UInt32(kDNSServiceFlagsInsecure)
        || code == UInt32(kDNSServiceFlagsBogus)
        || code == UInt32(kDNSServiceFlagsIndeterminate)
}

/// Status delivery from `dns_sd.h`: Validate + Add and zero-length rdata.
///
/// This callback is the validation signal for the whole RRSet. It is not an
/// empty TXT record. Empty authoritative data is a separate data callback that
/// lacks this shape, accepted only after Secure status.
private func isValidationStatusDelivery(flags: UInt32, rdlen: Int) -> Bool {
    rdlen == 0
        && (flags & UInt32(kDNSServiceFlagsValidate)) != 0
        && (flags & UInt32(kDNSServiceFlagsAdd)) != 0
}

private func hasMoreComing(_ flags: UInt32) -> Bool {
    (flags & UInt32(kDNSServiceFlagsMoreComing)) != 0
}

/// Applies a zero-length status callback. Does not read or replace `bufferedModels`
/// except to publish them when Secure status is complete.
///
/// Why: `dns_sd.h` says validation results may arrive separately from the RRset,
/// marked with Validate + Add and zero-length rdata. Accept only Secure.
/// Insecure, bogus, indeterminate, and Validate-without-a-status-code are
/// transient (``<doc:Security-Invariants>`` Invariant 1). `MoreComing` means
/// another callback is already queued — usually the RRset — so Secure does not
/// finish until that burst ends.
private func reduceValidationStatus(_ state: inout DNSQuerySession, flags: UInt32) -> SessionIngest {
    if isSecureDNSSECStatus(flags) {
        state.sawSecureStatus = true
        if hasMoreComing(flags) {
            return .waiting
        }
        return finishClaim(&state, .models(state.bufferedModels))
    }
    return finishClaim(&state, .failure(.dnssecNotSecure))
}

/// Applies one TXT data callback. Unions into the buffer. Does not finish unless
/// Secure status was already observed and this callback ends the burst.
///
/// A removal (`Add` clear) drops the prior Secure mark. `dns_sd.h`: when Add is
/// not set, DNSSEC status of the RRSet delivered so far is no longer valid.
private func reduceRecord(_ state: inout DNSQuerySession, flags: UInt32, models: Set<String>) -> SessionIngest {
    let isAdd = (flags & UInt32(kDNSServiceFlagsAdd)) != 0
    if !isAdd {
        state.sawSecureStatus = false
        state.bufferedModels.subtract(models)
        return .waiting
    }
    if isNonSecureDNSSECStatus(flags) || (flags & UInt32(kDNSServiceFlagsExpiredAnswer)) != 0 {
        return finishClaim(&state, .failure(.dnssecNotSecure))
    }
    state.bufferedModels.formUnion(models)
    if isSecureDNSSECStatus(flags) {
        state.sawSecureStatus = true
    }
    if state.sawSecureStatus && !hasMoreComing(flags) {
        return finishClaim(&state, .models(state.bufferedModels))
    }
    return .waiting
}

private func nsError(for failure: DNSCallbackFailure) -> NSError {
    switch failure {
    case .dnssd(let code):
        return NSError(domain: "dnssd", code: Int(code), userInfo: nil)
    case .dnssecNotSecure:
        return NSError(
            domain: "dnssec",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "DNSSEC validation failed or not available"]
        )
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
/// Queries are performed with `kDNSServiceFlagsValidate` (strict, not `ValidateOptional`).
/// `dns_sd.h` may deliver the TXT RRset and the DNSSEC status in separate callbacks.
/// A status callback is `kDNSServiceFlagsValidate` + `kDNSServiceFlagsAdd` with
/// **zero-length rdata**. That callback is the validation signal, not an empty RRset.
/// The Validate bit means "status is available". The callback buffers parsed TXT
/// names and **accepts them only when `kDNSServiceFlagsSecure` is set**.
/// Insecure, bogus, indeterminate, expired, and missing status are transient
/// failures. An empty set accepted under Secure is still an authoritative answer.
/// This provides DNSSEC-backed integrity for the allow-list without new dependencies.
///
/// Why: treating the echoed Validate bit on the first callback as success drops
/// signed answers. Live zones return the allow-list first (no Secure bit yet) and
/// the status afterward. See ``<doc:Security-Invariants>`` Invariant 1.
///
/// ## Behavior
/// Ordered ``securityModelDomains`` walk (AGENT NOTE — single contract with
/// ``<doc:Security-Invariants>`` Invariant 1):
/// 1. **Authoritative answer** = DNSSEC-validated TXT rdata accepted by the callback (including empty set).
/// 2. **Contains expected model** → success; **stop** (later hosts not queried).
/// 3. **Does not contain it** → permanent fail; **stop** (no fall-through).
/// 4. **Transient** (error, timeout, missing or non-Secure DNSSEC status, etc.) → next host; that host is
///    **fully trusted** if it returns an authoritative allow-list containing the expected model.
/// - Success (model present **and** DNSSEC-validated) → result is cached for 1 hour in `UserDefaults`.
///   A timestamp ahead of the device clock is discarded (it is not a cache hit).
/// - Permanent failure → streaming is permanently disabled for the process lifetime.
///   The success timestamp is removed and cannot revive `.failedPermanent`.
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
    /// When set, replaces the system TXT query. `.noCallback` runs local verification.
    internal var _test_systemTXT: (@Sendable (String) -> SystemTXTOutcome)?
    /// When set, local verification reads this fetcher instead of pinned DoH.
    internal var _test_wireFetcher: (any DNSWireFetching)?
    /// When set, replaces ``SecurityConfiguration/ianaRootTrustAnchors`` for local verification.
    internal var _test_trustAnchors: [DNSSECTrustAnchor]?
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
    /// 1. Returns `false` immediately when this process has already recorded
    ///    ``ValidationState/failedPermanent``. A stored success timestamp cannot revive it.
    /// 2. Returns `true` immediately if a successful validation result is still within
    ///    the 1-hour cache window. A timestamp ahead of the device clock is discarded.
    /// 3. Otherwise performs DNS TXT queries in ``securityModelDomains`` order
    ///    (authoritative answer stops the walk; only transient advances — see type-level
    ///    Behavior list and ``<doc:Security-Invariants>`` Invariant 1).
    /// 4. Returns `true` only if the expected model appears in an authoritative TXT set.
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

        // Permanent denial outranks the success cache. Checking the cache first
        // would let a clock step back into the stored hour undo an authoritative
        // "model not in TXT" result (Invariant 1: process lifetime).
        if validationState == .failedPermanent {
            return false
        }

        if isSuccessCacheFresh() {
            validationState = .success
            return true
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
    ///
    /// A timestamp ahead of ``currentDate`` is discarded. `timeIntervalSince` is
    /// negative in that case, and `age < modelCacheDuration` would stay true until
    /// the device clock catches the future instant — longer than the 1-hour
    /// success window in ``<doc:Security-Invariants>`` Invariant 1.
    ///
    /// ``ValidationState/failedPermanent`` is never a cache hit.
    private func isSuccessCacheFresh() -> Bool {
        if validationState == .failedPermanent {
            return false
        }

        guard let last = lastValidationTime ?? UserDefaults.standard.object(forKey: userDefaultsKey) as? Date else {
            return false
        }

        let age = currentDate().timeIntervalSince(last)
        if age < 0 {
            discardSuccessCacheTimestamp()
            return false
        }
        return age < config.modelCacheDuration
    }

    /// Drops the in-memory and `UserDefaults` success timestamp.
    ///
    /// Used when the stored instant is ahead of the device clock, when an
    /// authoritative TXT answer does not contain the model, and when a transient
    /// retry explicitly invalidates the cache.
    private func discardSuccessCacheTimestamp() {
        lastValidationTime = nil
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
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
                    // Drop the previous success timestamp so a later clock step
                    // cannot treat that hour as still authoritative.
                    validationState = .failedPermanent
                    discardSuccessCacheTimestamp()
                    
                    #if DEBUG
                    print("[SecurityModelValidator] Permanent failure: '\(config.expectedSecurityModel)' not in TXT record from \(domain)")
                    #endif
                    
                    return false
                }
            } catch {
                // Transient (error, timeout, missing or non-Secure DNSSEC status) → next host.
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
    /// transient retry logic). The persisted `lastSecurityValidation` timestamp is
    /// removed, not only the in-memory copy. Leaving it in `UserDefaults` would
    /// let a clock step backward satisfy the success-cache check.
    ///
    /// Permanent failures (``ValidationState/failedPermanent``) are unaffected.
    /// Use this method only to recover from transient network conditions during testing
    /// or after the user has explicitly requested a retry.
    public func resetTransientState() {
        if validationState == .failedTransient {
            validationState = .pending
            discardSuccessCacheTimestamp()
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
    /// - Important: The call passes `kDNSServiceFlagsValidate`. The callback buffers
    ///   TXT rdata until a separate status callback and accepts it only when
    ///   `kDNSServiceFlagsSecure` is set. The Validate bit is not success.
    ///   Failures (including insecure, bogus, indeterminate, or missing status)
    ///   are thrown and treated as transient by the caller. A Secure empty set
    ///   is returned, not thrown — the caller treats it as an authoritative answer.
    /// - Important: A watchdog with zero callbacks throws ``SystemDNSSECValidatorSilence``
    ///   from ``systemDNSQuery(for:)``. This method then verifies the TXT RRset locally.
    ///   A timeout after any callback stays `dnssd` / `-999` and does not verify locally.
    ///   A delivered non-Secure status is not replaced.
    /// - SeeAlso: ``<doc:Security-Invariants>`` (Invariant 1), ``DNSSECWalk``
    private func queryTXTRecord(for domain: String) async throws -> Set<String> {
        let outcome: SystemTXTOutcome
        #if DEBUG
        if let probe = _test_systemTXT {
            outcome = probe(domain)
        } else {
            outcome = await systemTXTOutcome(for: domain)
        }
        #else
        outcome = await systemTXTOutcome(for: domain)
        #endif
        switch outcome {
        case .authoritative(let models):
            return models
        case .transient(let error):
            throw error
        case .noCallback:
            return try await locallyVerifiedTXTModels(for: domain)
        }
    }

    /// Maps the DNS-SD query onto the three outcomes the host walk understands.
    private func systemTXTOutcome(for domain: String) async -> SystemTXTOutcome {
        do {
            return .authoritative(try await systemDNSQuery(for: domain))
        } catch is SystemDNSSECValidatorSilence {
            return .noCallback
        } catch {
            return .transient(error as NSError)
        }
    }

    /// Verifies the TXT RRset from DNS wire data. Failure is transient `dnssec` / `-2`.
    ///
    /// A present, signed RRset is returned, including one whose text parses to no
    /// names, so the host walk can treat that set as an authoritative answer.
    /// ``DNSSECWalk/txtModels(name:)`` returns failure when the TXT records are
    /// missing. There is no NSEC or NSEC3 proof of absence, so a missing set stays
    /// a temporary failure and the next host is tried. `-UITestMode` does not open DoH.
    /// The walk uses ``RetiredRootAnchorStore/shared``, so a self-revoked root digest
    /// stays suppressed for this process. That store is not `lastSecurityValidation`.
    private func locallyVerifiedTXTModels(for domain: String) async throws -> Set<String> {
        if ProcessInfo.processInfo.arguments.contains("-UITestMode") {
            throw NSError(
                domain: "dnssec",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "DNSSEC local verification skipped"]
            )
        }
        guard let name = DNSName(presentation: domain) else {
            throw NSError(
                domain: "dnssec",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "DNS name rejected"]
            )
        }
        let fetcher: any DNSWireFetching
        #if DEBUG
        if let injected = _test_wireFetcher {
            fetcher = injected
        } else {
            fetcher = PinnedDoHFetcher()
        }
        #else
        fetcher = PinnedDoHFetcher()
        #endif
        let anchors: [DNSSECTrustAnchor]
        #if DEBUG
        anchors = _test_trustAnchors ?? config.ianaRootTrustAnchors
        #else
        anchors = config.ianaRootTrustAnchors
        #endif
        let walk = DNSSECWalk(
            fetcher: fetcher,
            anchors: anchors,
            now: currentDate(),
            retiredAnchors: RetiredRootAnchorStore.shared
        )
        switch await walk.txtModels(name: name) {
        case .verified(let models):
            return models
        case .failed:
            throw NSError(
                domain: "dnssec",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "DNSSEC local verification failed"]
            )
        }
    }

    /// Performs the low-level DNS-SD TXT query using `DNSServiceQueryRecord`.
    ///
    /// The 5 s watchdog, callback, and setup-failure paths finish through `QueryContext`.
    /// Zero callbacks resume ``SystemDNSSECValidatorSilence``. Any callback before the
    /// watchdog keeps the historical `dnssd` / `-999` timeout.
    private func systemDNSQuery(for domain: String) async throws -> Set<String> {
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
            // SECURITY: Request strict DNSSEC validation via kDNSServiceFlagsValidate (not Optional).
            // The request bit is not the result. dns_sd.h delivers status separately: a later
            // callback with Validate + Add and zero-length rdata carries Secure, Insecure, Bogus,
            // or Indeterminate. Accept the buffered TXT set only for kDNSServiceFlagsSecure.
            // Unvalidated, insecure, bogus, and indeterminate answers are transient failures.
            // See <doc:Security-Invariants> Invariant 1. No new dependencies.
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

    // Static non-capturing callback — `@convention(c)` via `DNSServiceQueryRecordReply`.
    //
    // SECURITY: Enforcement point for DNSSEC on the TXT allow-list. `dns_sd.h` may
    // deliver the RRset and the validation status as separate callbacks. Buffer parsed
    // TXT names until a callback carries status (Validate + Add + zero-length rdata).
    // Accept only `kDNSServiceFlagsSecure`. The Validate bit means status is available,
    // not that validation succeeded. Insecure, bogus, indeterminate, expired, and a
    // Validate bit with no status code are transient (`dnssec` / -1). A zero-length
    // status callback is not an empty allow-list. An empty set under Secure is an
    // authoritative answer and is returned, not thrown. Why: signed zones often deliver
    // the TXT first and Secure afterward; finishing on the first callback treats a live
    // allow-list as a transient failure. See <doc:Security-Invariants> Invariant 1.
    // All test hooks bypass this path via `_test_txtFetcher`.
    //
    // Claim-once: `takeUnretainedValue` does not consume `passRetained`. Only the
    // finishing callback `takeRetainedValue`s. A callback that only buffers returns
    // without deallocating or resuming. Parse runs inside `ingestDNSCallback` while
    // the mutex is held, before any loser can `DNSServiceRefDeallocate`.
    private static let dnsQueryCallback: DNSServiceQueryRecordReply = {
        sdRef, flags, interfaceIdx, errorCode, fullName, rrtype, rrclass, rdlen, rdata, ttl, ctx in

        guard let ctx = unsafe ctx else { return }

        // SAFETY: `QueryContext` stays alive while Unmanaged's `passRetained` is
        // outstanding and/or the watchdog / processing-queue release hop holds it.
        // `fromOpaque` / `takeUnretainedValue` / `takeRetainedValue` are `Unmanaged`
        // (unsafe C-interop retain). `takeUnretainedValue` does not consume that
        // retain; only the claim-once winner balances it.
        let unmanaged = unsafe Unmanaged<QueryContext>.fromOpaque(ctx)
        let queryCtx = unsafe unmanaged.takeUnretainedValue()

        #if DEBUG
        let statusDelivery = isValidationStatusDelivery(flags: flags, rdlen: Int(rdlen))
        let secure = isSecureDNSSECStatus(flags)
        print("[SecurityModelValidator] DNS response: secure=\(secure) statusDelivery=\(statusDelivery) flags=0x\(String(flags, radix: 16)) rdlen=\(rdlen) errorCode=\(errorCode)")
        #endif

        // SAFETY: `rdata` is an optional C pointer valid only for this callback.
        // `ingestDNSCallback` borrows it under the session mutex and does not store it.
        let ingest = unsafe queryCtx.ingestDNSCallback(
            flags: flags,
            errorCode: errorCode,
            rdlen: Int(rdlen),
            rdata: rdata
        )
        switch ingest {
        case .waiting, .alreadyFinished:
            return
        case .finish:
            // Consume `passRetained`. Timeout-win must not also release.
            _ = unsafe unmanaged.takeRetainedValue()
            queryCtx.deliver(ingest)
        }
    }

    /// Pure parsing logic – `static` (implicitly nonisolated on an actor) so it can be called
    /// safely from the C callback (background thread, non-isolated context).
    /// No actor state access, no `self.`, no isolation violations.
    static func parseInlineTXTRecord(_ data: Data) -> Set<String> {
        parseInlineTXTRecord(span: data.span)
    }

    /// Length-prefixed DNS TXT rdata parser using `Span<UInt8>` views (no per-label `subdata`).
    ///
    /// `span` must not escape the caller's scope. Production DNS-SD callbacks borrow `rdata`
    /// in place (zero-copy); tests may borrow via `Data.span`.
    ///
    /// `fileprivate` so ``QueryContext`` can parse while the session mutex is held.
    /// The parser stays in this file. It does not touch actor state.
    fileprivate static func parseInlineTXTRecord(span: Span<UInt8>) -> Set<String> {
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
        _test_systemTXT = nil
        _test_wireFetcher = nil
        _test_trustAnchors = nil

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

    /// One synthetic dns_sd callback. Flag bits stay inside Core so tests do not
    /// re-encode `kDNSServiceFlagsSecure` (`0x200010`).
    ///
    /// - SeeAlso: ``<doc:Security-Invariants>`` Invariant 1
    public enum _TestDNSSECEvent: Sendable {
        /// TXT data callback. `includeValidateBit` sets Validate without Secure.
        case record(Set<String>, moreComing: Bool, includeValidateBit: Bool)
        /// Removal (`Add` clear). Invalidates a Secure mark that has not yet finished the session.
        case removal(Set<String>)
        case secureStatus(moreComing: Bool)
        case secureCachedStatus
        case expiredSecureStatus
        case insecureStatus
        case bogusStatus
        case indeterminateStatus
        /// Validate + Add + zero-length rdata, and none of the four status codes.
        case statusBitOnly
        case transportError(Int32)
    }

    /// Disposition of one synthetic callback after the mutex is released.
    public enum _TestDNSSECStep: Sendable, Equatable {
        case waiting
        case alreadyFinished
        case success(Set<String>)
        case failure(domain: String, code: Int)
    }

    /// Steps plus how many times the session resumed the continuation.
    ///
    /// `completionCount` must be 1 after a finish and 0 while still waiting.
    /// A second finish is a claim-once break.
    public struct _TestDNSSECTrace: Sendable, Equatable {
        public var steps: [_TestDNSSECStep]
        public var completionCount: Int
    }

    /// Drives the DNSSEC buffer and Secure-bit check with no `DNSServiceRef`.
    ///
    /// Protects the callback contract in ``<doc:Security-Invariants>`` Invariant 1:
    /// rdata without Secure does not finish; a later Secure status accepts the
    /// buffered set; a zero-length status callback is not empty data; insecure,
    /// bogus, indeterminate, expired, and Validate-without-a-status-code are
    /// transient; claim-once resumes once.
    ///
    /// - Parameter events: Callbacks in delivery order.
    /// - Returns: One step per event, and the number of continuation resumes.
    public static func _test_driveDNSSECCallbacks(_ events: [_TestDNSSECEvent]) -> _TestDNSSECTrace {
        let completionCount = Mutex(0)
        let context = QueryContext { _ in
            completionCount.withLock { count in
                count += 1
            }
        }
        var steps: [_TestDNSSECStep] = []
        steps.reserveCapacity(events.count)
        for event in events {
            let ingest = context.ingestPrepared(preparedDNSCallback(for: event))
            switch ingest {
            case .waiting:
                steps.append(.waiting)
            case .alreadyFinished:
                steps.append(.alreadyFinished)
            case .finish(_, let result):
                context.deliver(ingest)
                switch result {
                case .models(let models):
                    steps.append(.success(models))
                case .failure(let failure):
                    let error = nsError(for: failure)
                    steps.append(.failure(domain: error.domain, code: error.code))
                }
            }
        }
        let count = completionCount.withLock { $0 }
        return _TestDNSSECTrace(steps: steps, completionCount: count)
    }

    /// Maps a synthetic event onto the prepared callback the production reducer uses.
    private static func preparedDNSCallback(for event: _TestDNSSECEvent) -> PreparedDNSCallback {
        switch event {
        case .record(let models, let moreComing, let includeValidateBit):
            var flags = UInt32(kDNSServiceFlagsAdd)
            if moreComing {
                flags |= UInt32(kDNSServiceFlagsMoreComing)
            }
            if includeValidateBit {
                flags |= UInt32(kDNSServiceFlagsValidate)
            }
            return .record(flags: flags, models: models)
        case .removal(let models):
            return .record(flags: 0, models: models)
        case .secureStatus(let moreComing):
            var flags = UInt32(kDNSServiceFlagsSecure) | UInt32(kDNSServiceFlagsAdd)
            if moreComing {
                flags |= UInt32(kDNSServiceFlagsMoreComing)
            }
            return .validationStatus(flags: flags)
        case .secureCachedStatus:
            let flags = UInt32(kDNSServiceFlagsSecure)
                | UInt32(kDNSServiceFlagsAdd)
                | UInt32(kDNSServiceFlagAnsweredFromCache)
            return .validationStatus(flags: flags)
        case .expiredSecureStatus:
            let flags = UInt32(kDNSServiceFlagsSecure)
                | UInt32(kDNSServiceFlagsAdd)
                | UInt32(kDNSServiceFlagsExpiredAnswer)
            return .validationStatus(flags: flags)
        case .insecureStatus:
            return .validationStatus(
                flags: UInt32(kDNSServiceFlagsInsecure) | UInt32(kDNSServiceFlagsAdd)
            )
        case .bogusStatus:
            return .validationStatus(
                flags: UInt32(kDNSServiceFlagsBogus) | UInt32(kDNSServiceFlagsAdd)
            )
        case .indeterminateStatus:
            return .validationStatus(
                flags: UInt32(kDNSServiceFlagsIndeterminate) | UInt32(kDNSServiceFlagsAdd)
            )
        case .statusBitOnly:
            return .validationStatus(
                flags: UInt32(kDNSServiceFlagsValidate) | UInt32(kDNSServiceFlagsAdd)
            )
        case .transportError(let code):
            return .transportError(code)
        }
    }

    /// Installs the system-query probe. Does not clear ``_test_wireFetcher``.
    ///
    /// Call ``_test_setTXTFetcher(_:)`` first when a test needs a clean cache: that reset
    /// clears this probe.
    static func _test_setSystemTXT(_ probe: (@Sendable (String) -> SystemTXTOutcome)?) async {
        await shared._installSystemTXT(probe)
    }

    /// Installs the DNS wire fetcher used after a zero-callback outcome.
    static func _test_setWireFetcher(_ fetcher: (any DNSWireFetching)?) async {
        await shared._installWireFetcher(fetcher)
    }

    /// Replaces the root trust anchors for the next local verification in this process.
    static func _test_setTrustAnchors(_ anchors: [DNSSECTrustAnchor]?) async {
        await shared._installTrustAnchors(anchors)
    }

    /// Watchdog classification without `DNSServiceRef` and without resuming the silence path.
    ///
    /// Empty `events` is silence. A record that does not finish the session is `afterCallbacks`.
    /// A Secure status that finishes the session is `alreadyFinished`.
    public static func _test_timeoutKind(after events: [_TestDNSSECEvent]) -> _TestTimeoutKind {
        let context = QueryContext { _ in }
        for event in events {
            let ingest = context.ingestPrepared(preparedDNSCallback(for: event))
            if case .finish = ingest {
                context.deliver(ingest)
            }
        }
        switch context.claimTimeout() {
        case .silence:
            return .silence
        case .afterCallbacks:
            return .afterCallbacks
        case .alreadyFinished:
            return .alreadyFinished
        }
    }

    /// Classification returned by ``_test_timeoutKind(after:)``.
    public enum _TestTimeoutKind: Sendable, Equatable {
        case silence
        case afterCallbacks
        case alreadyFinished
    }

    private func _installSystemTXT(_ probe: (@Sendable (String) -> SystemTXTOutcome)?) {
        _test_systemTXT = probe
    }

    private func _installWireFetcher(_ fetcher: (any DNSWireFetching)?) {
        _test_wireFetcher = fetcher
    }

    private func _installTrustAnchors(_ anchors: [DNSSECTrustAnchor]?) {
        _test_trustAnchors = anchors
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
