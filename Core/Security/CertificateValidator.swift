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
/// - Implements a 10-minute validation cache.
/// - Enforces the certificate transition window with device/server time-skew protection
///   (see ``<doc:Security-Invariants>``).
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
    
    internal var pinnedCertFingerprintDigest: CertificateFingerprint {
        SecurityConfiguration.current.pinnedLeafFingerprintDigest
    }
    /// Barrier flag to allow leniency during transition, mitigating date manipulation risks.
    /// Defaults to true (lenient, trusting ATS on mismatch); set to false if manipulation detected (e.g., via server time check).
    var allowTransitionLeniency: Bool = true
    
    /// Timestamp of the last validation attempt.
    private var lastValidationTime: Date?
    
    /// Interval for caching validation results.
    private var validationInterval: TimeInterval {
        SecurityConfiguration.current.modelCacheDuration
    }
    
    /// Cached result of the last validation.
    private var lastValidationResult: Bool = false
    
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
    
    /// Determines if the current date falls within the defined transition period.
    private var isInTransitionPeriod: Bool {
        return SecurityConfiguration.current.isInTransitionWindow
    }
    
    /// Validates a server trust object received during a URL authentication challenge.
    ///
    /// This is the primary entry point used by `URLSession` delegate challenge handlers.
    /// It performs the full security evaluation (system trust + fingerprint pinning)
    /// while respecting the current transition window and time-skew policy.
    ///
    /// Results are cached for 10 minutes. The method is safe to call from any context;
    /// all state access is actor-isolated.
    ///
    /// - Parameter serverTrust: The `SecTrust` from an `NSURLAuthenticationMethodServerTrust` challenge.
    /// - Returns: `true` if the server should be trusted, `false` if the connection must be rejected.
    ///
    /// - SeeAlso: ``validateServerCertificate(for:)``, ``<doc:Security-Invariants>``
    public func validateServerTrust(_ serverTrust: SecTrust) async -> Bool {
        if let lastTime = lastValidationTime,
           Date().timeIntervalSince(lastTime) < validationInterval,
           lastValidationResult {
            #if DEBUG
            print("🔒 [CertificateValidator] Using cached valid result from \(lastTime)")
            #endif
            return true
        }
        
        var error: CFError?
        if unsafe !SecTrustEvaluateWithError(serverTrust, &error) {
            #if DEBUG
            print("🔒 [CertificateValidator] System trust evaluation failed: \(error?.localizedDescription ?? "Unknown error")")
            #endif
            lastValidationTime = Date()
            lastValidationResult = false
            return false
        }
        
        let isPinnedValid = validateCertificateChain(serverTrust: serverTrust)
        let config = SecurityConfiguration.current
        
        let isValid: Bool
        
        // Use fresh Date() for each check — cheap and consistent with config.isInTransitionWindow
        if Date() > config.transitionWindowEnd {
            isValid = isPinnedValid
            #if DEBUG
            let now = Date()
            print("🔒 [CertificateValidator] Fingerprint validation failed after transition window at \(now).")
            #endif
        } else if config.isInTransitionWindow {
            if !isPinnedValid {
                #if DEBUG
                let now = Date()
                print("⚠️ [CertificateValidator] Fingerprint mismatch during transition window at \(now). " +
                      "Leniency: \(allowTransitionLeniency ? "allowed (ATS fallback)" : "disabled")")
                #endif
                isValid = allowTransitionLeniency
            } else {
                isValid = true
            }
        } else {
            isValid = isPinnedValid
            #if DEBUG
            let now = Date()
            print("🔒 [CertificateValidator] Fingerprint validation failed before transition window at \(now).")
            #endif
        }
        
        let nowForCache = Date()  // only once for cache timestamp
        lastValidationTime = nowForCache
        lastValidationResult = isValid
        
        #if DEBUG
        print("🔒 [CertificateValidator] Certificate validation \(isValid ? "succeeded" : "failed") at \(nowForCache)")
        #endif
        
        return isValid
    }
    
    /// Performs proactive certificate validation for a stream URL using a HEAD request.
    ///
    /// This method is used by `DirectStreamingPlayer` for initial validation before playback
    /// and for periodic re-validation (approximately every 10 minutes).
    ///
    /// It creates an ephemeral `URLSession` with this actor as the delegate, issues a
    /// `HEAD` request, and returns the result of the subsequent challenge evaluation.
    /// The call is fully asynchronous and non-blocking.
    ///
    /// - Parameter url: The HTTPS URL of the audio stream (must use HTTPS).
    /// - Returns: `true` if the server certificate is acceptable under current policy.
    ///
    /// - SeeAlso: ``validateServerTrust(_:)``, ``<doc:Security-Invariants>``
    public func validateServerCertificate(for url: URL) async -> Bool {
        // Apple 2026 non-main delegate queue (utility QoS + serial for strict concurrency)
        // This is the exact pattern used in Music/Podcasts 2026 betas for async delegates.
        let delegateQueue = OperationQueue()
        delegateQueue.qualityOfService = .utility
        delegateQueue.name = "radio.lutheran.certificate-validator"
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: delegateQueue)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        
        do {
            let (_, response) = try await session.data(for: request)  // ← modern async API
            
            let isValid = lastValidationResult  // set by the async challenge handler
            
            // Manipulation detection (updated to use central config)
            if isValid, let httpResponse = response as? HTTPURLResponse,
               let dateStr = httpResponse.value(forHTTPHeaderField: "Date"),
               let serverDate = self.httpDateFormatter.date(from: dateStr) {
                
                self.allowTransitionLeniency = true
                
                let deviceDate = self.currentDate()
                let tolerance: TimeInterval = SecurityConfiguration.current.maxAllowedTimeSkew  // ← use central value (300 s)
                
                let timeDiff = abs(deviceDate.timeIntervalSince(serverDate))
                if timeDiff > tolerance {
                    #if DEBUG
                    print("⚠️ [CertificateValidator] Device time manipulation suspected (diff: \(timeDiff)s)...")
                    #endif
                    self.allowTransitionLeniency = false
                } else {
                    let config = SecurityConfiguration.current
                    
                    // Use the same transition window check as everywhere else
                    let deviceInTransition = config.isInTransitionWindow
                    
                    // For server date: compute equivalent check manually (since config.isInTransitionWindow uses Date())
                    let serverInTransition = serverDate >= config.transitionWindowStart
                                          && serverDate <= config.transitionWindowEnd
                    
                    if deviceInTransition && !serverInTransition {
                        #if DEBUG
                        print("⚠️ [CertificateValidator] Transition period mismatch detected " +
                              "(device in window, server not) → disabling leniency")
                        #endif
                        self.allowTransitionLeniency = false
                    }
                }
            }
            
            #if DEBUG
            print("🔒 [CertificateValidator] HEAD request completed for \(url). Valid: \(isValid)")
            #endif
            return isValid
            
        } catch {
            #if DEBUG
            print("🔒 [CertificateValidator] HEAD request failed: \(error.localizedDescription)")
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
            print("🔒 [CertificateValidator] Failed to get leaf certificate from chain")
            #endif
            return false
        }
        
        let config = SecurityConfiguration.current
        guard let certDigest = computeCertificateFingerprintDigest(for: leafCertificate) else {
            return false
        }
        let isValid = config.pinnedFingerprintDigests.contains { pin in
            certDigest.constantTimeMatches(pin)
        }
        #if DEBUG
        if !isValid {
            print("🔒 [CertificateValidator] Fingerprint mismatch detected")
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
            print("🔒 [CertificateValidator] Failed to get certificate data")
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
