//
//  CertificateValidator.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 24.6.2025.
//

import Foundation
@unsafe @preconcurrency import Security

/// Actor responsible for runtime full-certificate SHA-256 DER fingerprint pinning.
///
/// `CertificateValidator` provides an independent security layer on top of App Transport
/// Security (ATS). It validates the exact leaf certificate presented by the server
/// against the authoritative fingerprints stored in ``SecurityConfiguration``.
///
/// ## Key Responsibilities
/// - Performs system trust evaluation (includes ATS SPKI pinning and chain validation).
/// - Verifies the leaf certificate's full DER SHA-256 fingerprint.
/// - Caches **pin matches** for ``SecurityConfiguration/certificateValidationCacheDuration``
///   (10 minutes). A transition-window leniency accept is not a cache hit: the next
///   challenge re-checks the leaf. This cache is separate from the 1-hour DNS TXT
///   model cache (``SecurityConfiguration/modelCacheDuration``). A cached pin timestamp
///   ahead of the device clock is not reused.
/// - Enforces the certificate transition window with device/server time-skew protection
///   (see ``<doc:Security-Invariants>``). ``allowTransitionLeniency`` starts `true` and
///   latches `false` for the rest of the process; a later `Date` header must not turn it back on.
///
/// ## Concurrency
/// The validator is an `actor`, making all state mutations (cache, leniency flag) isolated.
/// The `URLSessionTaskDelegate` conformance uses the modern `async` challenge handler.
///
/// ## Usage
/// Access the shared instance via ``shared``. Call ``validateServerCertificate(for:)``
/// for proactive HEAD-based checks (used by `DirectStreamingPlayer`) or rely on
/// automatic challenge handling when the validator is installed as a `URLSession` delegate.
///
/// - SeeAlso: ``<doc:Architecture>``, ``<doc:Security-Invariants>``, ``SecurityConfiguration``
public actor CertificateValidator: NSObject, URLSessionTaskDelegate {
    /// The shared singleton instance.
    ///
    /// All production code must use this instance. The validator maintains internal
    /// caches and transition state that would be lost with additional instances.
    public static let shared = CertificateValidator()
    
    /// Process-lifetime latch for transition-window ATS fallback.
    ///
    /// Starts `true`. ``noteServerDateForTransitionLeniency(serverDate:)`` sets it
    /// `false` when device/server skew exceeds ``SecurityConfiguration/maxAllowedTimeSkew``
    /// or the device clock is inside the window while the server clock is not.
    /// Nothing sets it back to `true`. Invariant 4 in ``<doc:Security-Invariants>``.
    var allowTransitionLeniency: Bool = true
    
    /// Timestamp of the last **pin-match** cache entry (or of a hard failure).
    ///
    /// A leniency accept does not refresh this. Combined with ``lastValidationResult``,
    /// the early return in ``validateServerTrust(_:)`` reuses only pin matches whose
    /// age is in `0 ..< certificateValidationCacheDuration`.
    private var lastValidationTime: Date?
    
    /// How long a successful pin result may be reused without re-evaluation.
    ///
    /// AGENT NOTE: Single source of truth is
    /// ``SecurityConfiguration/certificateValidationCacheDuration``. Never point this at
    /// ``SecurityConfiguration/modelCacheDuration`` (DNS TXT only).
    private var validationInterval: TimeInterval {
        SecurityConfiguration.current.certificateValidationCacheDuration
    }
    
    /// `true` only after a leaf digest matched ``SecurityConfiguration/pinnedFingerprintDigests``.
    ///
    /// Leniency accepts leave this `false` so they cannot satisfy the pin-result cache.
    private var lastValidationResult: Bool = false
    
    /// Outcome of the most recent ``validateServerTrust(_:)`` call, including leniency.
    ///
    /// ``validateServerCertificate(for:)`` must read this rather than ``lastValidationResult``.
    /// The HEAD `Date` header is not available until after the challenge, and a leniency
    /// accept is intentionally absent from the pin-result cache.
    private var lastChallengeAccepted = false
    
    /// Formatter for parsing HTTP Date headers (RFC 7231 format: "EEE, dd MMM yyyy HH:mm:ss zzz").
    private lazy var httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
    
    /// Internal initializer to enforce singleton pattern.
    internal override init() {
        super.init()
    }
    
    /// Creates a validator for use in unit tests (DEBUG builds only).
    ///
    /// This initializer allows injection of a custom date provider so that transition
    /// window and time-skew logic can be tested deterministically without waiting for
    /// real-world clock changes.
    ///
    /// - Parameter currentDate: A closure that returns the "current" date for all
    ///   time-based decisions inside the validator.
    ///
    /// - Important: This initializer is compiled out of Release builds and has no
    ///   effect on production behavior.
    #if DEBUG
    public init(currentDate: @escaping @Sendable () -> Date = { Date() }) {
        self.currentDate = currentDate
        super.init()
    }
    #endif
    
    /// Injectable closure for the current date, used for testing time-dependent logic (e.g., transition periods).
    ///
    /// Defaults to system date. In tests, override to mock dates:
    /// ```
    /// validator.currentDate = { Date(timeIntervalSince1970: someTimestamp) }
    /// ```
    /// - Important: Do not change in production.
    internal var currentDate: @Sendable () -> Date = { Date() }
    
    /// Validates a server trust object received during a URL authentication challenge.
    ///
    /// This is the primary entry point used by `URLSession` delegate challenge handlers.
    /// It performs the full security evaluation (system trust + fingerprint pinning)
    /// while respecting the current transition window and time-skew policy.
    ///
    /// Pin matches are cached for ``SecurityConfiguration/certificateValidationCacheDuration``
    /// (10 minutes). Transition-window leniency accepts are not cached. The device
    /// clock is ``currentDate`` (production: `Date()`), including for the window test
    /// ``SecurityConfiguration/isInTransitionWindow(at:)``. The method is safe to call
    /// from any context; all state access is actor-isolated.
    ///
    /// - Parameter serverTrust: The `SecTrust` from an `NSURLAuthenticationMethodServerTrust` challenge.
    /// - Returns: `true` if the server should be trusted, `false` if the connection must be rejected.
    ///
    /// - SeeAlso: ``validateServerCertificate(for:)``, ``<doc:Security-Invariants>``,
    ///   ``SecurityConfiguration/certificateValidationCacheDuration``
    public func validateServerTrust(_ serverTrust: SecTrust) async -> Bool {
        // `currentDate` is the device clock for this actor (production: `Date()`).
        // A negative age means the cached instant is ahead of that clock; reusing it
        // would stretch the 10-minute pin cache until the clock catches up.
        let now = currentDate()
        if let lastTime = lastValidationTime {
            let age = now.timeIntervalSince(lastTime)
            if age >= 0, age < validationInterval, lastValidationResult {
                #if DEBUG
                print("[CertificateValidator] Using cached pin match from \(lastTime)")
                #endif
                lastChallengeAccepted = true
                return true
            }
        }
        
        var error: CFError?
        if unsafe !SecTrustEvaluateWithError(serverTrust, &error) {
            #if DEBUG
            print("[CertificateValidator] System trust evaluation failed: \(error?.localizedDescription ?? "Unknown error")")
            #endif
            lastValidationTime = now
            lastValidationResult = false
            lastChallengeAccepted = false
            return false
        }
        
        let isPinnedValid = validateCertificateChain(serverTrust: serverTrust)
        let config = SecurityConfiguration.current
        
        let isValid: Bool
        
        if now > config.transitionWindowEnd {
            isValid = isPinnedValid
            #if DEBUG
            if !isPinnedValid {
                print("[CertificateValidator] Fingerprint validation failed after transition window at \(now).")
            }
            #endif
        } else if config.isInTransitionWindow(at: now) {
            if !isPinnedValid {
                #if DEBUG
                print("[CertificateValidator] Fingerprint mismatch during transition window at \(now). " +
                      "Leniency: \(allowTransitionLeniency ? "allowed (ATS fallback)" : "disabled")")
                #endif
                isValid = allowTransitionLeniency
            } else {
                isValid = true
            }
        } else {
            isValid = isPinnedValid
            #if DEBUG
            if !isPinnedValid {
                print("[CertificateValidator] Fingerprint validation failed before transition window at \(now).")
            }
            #endif
        }
        
        lastChallengeAccepted = isValid
        if isPinnedValid {
            // Invariant 3: cache pin matches only. A leniency accept must be
            // re-checked on the next challenge so a latched-off flag takes effect
            // inside the 10-minute window.
            lastValidationTime = now
            lastValidationResult = true
        } else {
            lastValidationResult = false
            if !isValid {
                lastValidationTime = now
            }
        }
        
        #if DEBUG
        print("[CertificateValidator] Certificate validation \(isValid ? "succeeded" : "failed") at \(now)")
        #endif
        
        return isValid
    }
    
    /// Performs proactive certificate validation for a stream URL using a HEAD request.
    ///
    /// This method is used by `DirectStreamingPlayer` for initial validation before playback
    /// and for periodic re-validation on the cadence of
    /// ``SecurityConfiguration/certificateValidationCacheDuration`` (10 minutes).
    ///
    /// It obtains a secure `URLSessionConfiguration` (via ``SecurityConfiguration/makeSecureEphemeralConfiguration()``)
    /// that enforces ``SecurityConfiguration/requiresDNSSECValidationForStreaming`` for the resolution step,
    /// then creates an ephemeral `URLSession` with this actor as the delegate, issues a
    /// `HEAD` request, and returns the result of the subsequent challenge evaluation.
    /// The call is fully asynchronous and non-blocking.
    ///
    /// DNS resolution for the target host is authenticated via DNSSEC (when the policy is enabled)
    /// before the TLS challenge is even delivered to this validator.
    ///
    /// When the response carries an HTTP `Date` header, that instant is applied to the
    /// one-way leniency latch. The returned bool is the challenge outcome. A latched-off
    /// flag does not by itself reject a leaf that matched ``pinnedFingerprintDigests``.
    ///
    /// - Parameter url: The HTTPS URL of the audio stream (must use HTTPS).
    /// - Returns: `true` if the server certificate is acceptable under current policy.
    ///
    /// - SeeAlso: ``validateServerTrust(_:)``, ``<doc:Security-Invariants>``,
    ///   ``SecurityConfiguration/applySecureNetworkingRequirements(to:)``,
    ///   ``SecurityConfiguration/certificateValidationCacheDuration``
    public func validateServerCertificate(for url: URL) async -> Bool {
        // Apple 2026 non-main delegate queue (utility QoS + serial for strict concurrency)
        // This is the exact pattern used in Music/Podcasts 2026 betas for async delegates.
        let delegateQueue = OperationQueue()
        delegateQueue.qualityOfService = .utility
        delegateQueue.name = "radio.lutheran.certificate-validator"
        delegateQueue.maxConcurrentOperationCount = 1
        
        // Obtain configuration through Core single source of truth so that DNSSEC requirement
        // (and future secure networking policy) is applied uniformly for the HEAD validation
        // of the streaming endpoint.
        let config = SecurityConfiguration.makeSecureEphemeralConfiguration()
        let session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        
        do {
            let (_, response) = try await session.data(for: request)  // ← modern async API
            
            // Challenge outcome, including a one-shot leniency accept. Do not read
            // `lastValidationResult` here: that flag is pin-match cache state and
            // stays false when leniency allowed this handshake.
            let challengeAccepted = lastChallengeAccepted
            
            if challengeAccepted, let httpResponse = response as? HTTPURLResponse,
               let dateStr = httpResponse.value(forHTTPHeaderField: "Date"),
               let serverDate = self.httpDateFormatter.date(from: dateStr) {
                _ = self.noteServerDateForTransitionLeniency(serverDate: serverDate)
            }
            
            #if DEBUG
            print("[CertificateValidator] HEAD request completed for \(url). Valid: \(challengeAccepted)")
            #endif
            return challengeAccepted
            
        } catch {
            #if DEBUG
            print("[CertificateValidator] HEAD request failed: \(error.localizedDescription)")
            #endif
            return false
        }
    }
    
    // MARK: - Modern async delegate (WWDC 2025 / Swift 6 recommendation)
    
    /// Handles server trust authentication challenges (modern async `URLSessionTaskDelegate`).
    ///
    /// This is the Swift 6+ async challenge handler. It is invoked automatically by
    /// `URLSession` when a server trust challenge occurs. The implementation delegates
    /// to ``validateServerTrust(_:)`` and either supplies credentials or cancels the challenge.
    ///
    /// - Note: This method is `nonisolated` because it is part of the `URLSessionTaskDelegate`
    ///   protocol contract, but it immediately hops to the actor via the `await` call.
    public nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        
        let isValid = await validateServerTrust(serverTrust)
        if isValid {
            return (.useCredential, URLCredential(trust: serverTrust))
        } else {
            return (.cancelAuthenticationChallenge, nil)
        }
    }
    
    // MARK: - Internal Methods
    
    /// Applies one HTTP `Date` observation to the process-lifetime leniency latch.
    ///
    /// Leniency starts enabled. Skew above ``SecurityConfiguration/maxAllowedTimeSkew``,
    /// or a device clock inside the transition window while the server clock is
    /// outside, sets ``allowTransitionLeniency`` to `false`. Later observations
    /// never set it back to `true` (Invariant 4).
    ///
    /// The device instant is ``currentDate``, not a second `Date()` call, so the
    /// skew comparison and ``SecurityConfiguration/isInTransitionWindow(at:)``
    /// share one clock.
    ///
    /// - Parameter serverDate: Parsed HTTP `Date` header.
    /// - Returns: `allowTransitionLeniency` after this observation.
    /// - SeeAlso: ``<doc:Security-Invariants>`` Invariant 4, ``validateServerCertificate(for:)``
    func noteServerDateForTransitionLeniency(serverDate: Date) -> Bool {
        guard allowTransitionLeniency else { return false }
        
        let config = SecurityConfiguration.current
        let deviceDate = currentDate()
        let skew = abs(deviceDate.timeIntervalSince(serverDate))
        if skew > config.maxAllowedTimeSkew {
            #if DEBUG
            print("[CertificateValidator] Device time manipulation suspected (diff: \(skew)s)...")
            #endif
            allowTransitionLeniency = false
            return false
        }
        
        let deviceInTransition = config.isInTransitionWindow(at: deviceDate)
        let serverInTransition = config.isInTransitionWindow(at: serverDate)
        if deviceInTransition && !serverInTransition {
            #if DEBUG
            print("[CertificateValidator] Transition period mismatch detected " +
                  "(device in window, server not) → disabling leniency")
            #endif
            allowTransitionLeniency = false
        }
        return allowTransitionLeniency
    }
    
    /// Validates the certificate chain by checking the leaf certificate's fingerprint.
    ///
    /// Focuses on the leaf (server) certificate at index 0.
    /// Computes the SHA-256 fingerprint of its DER data and compares to the pinned value.
    ///
    /// - Parameter serverTrust: The `SecTrust` chain to validate.
    /// - Returns: True if the computed fingerprint matches the pinned fingerprint.
    internal func validateCertificateChain(serverTrust: SecTrust) -> Bool {
        // Focus on leaf certificate (index 0) as per SSL pinning document
        guard let certificateChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              !certificateChain.isEmpty,
              let leafCertificate = certificateChain.first else {
            #if DEBUG
            print("[CertificateValidator] Failed to get leaf certificate from chain")
            #endif
            return false
        }
        
        let config = SecurityConfiguration.current
        guard let certDigest = computeCertificateFingerprintDigest(for: leafCertificate) else {
            return false
        }
        // Compare every configured pin (no short-circuit on match) — see SecurityConfiguration pinning notes.
        var isValid = false
        for pin in config.pinnedFingerprintDigests {
            isValid = isValid || certDigest.constantTimeMatches(pin)
        }
        #if DEBUG
        if !isValid {
            print("[CertificateValidator] Fingerprint mismatch detected")
        }
        #endif
        return isValid
    }
    
    /// Computes the SHA-256 digest of a certificate's DER representation.
    ///
    /// - Parameter certificate: The `SecCertificate` to fingerprint.
    /// - Returns: Raw 32-byte digest, or nil on failure.
    internal func computeCertificateFingerprintDigest(for certificate: SecCertificate) -> CertificateFingerprint? {
        guard let certData = SecCertificateCopyData(certificate) as Data? else {
            #if DEBUG
            print("[CertificateValidator] Failed to get certificate data")
            #endif
            return nil
        }
        return CertificateFingerprint.sha256DERDigest(of: certData)
    }
    
    /// OpenSSL-style colon-hex fingerprint (tests and operator tooling only).
    internal func computeCertificateFingerprint(for certificate: SecCertificate) -> String? {
        computeCertificateFingerprintDigest(for: certificate)?.colonHexUppercase
    }
}
