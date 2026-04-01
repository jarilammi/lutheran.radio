//
//  CertificateValidator.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 24.6.2025.
//

import Foundation
import CommonCrypto
@preconcurrency import Security

/// - Article: SSL Certificate Pinning and Validation
///
/// `CertificateValidator` enforces runtime SSL security through full certificate fingerprint pinning (SHA-256), integrated with App Transport Security (ATS). It's used by `StreamingSessionDelegate.swift` for per-session challenges and `DirectStreamingPlayer.swift` for periodic HEAD checks.
///
/// Key Mechanics:
/// - **Validation Process**: Checks system trust, then leaf certificate fingerprint against a pinned value; caches results for 10 minutes.
/// - **Transition Period**: Allows leniency during certificate rotations (July 27 to August 26, 2026) with device/server time checks to detect manipulation.
/// - **Integration**: Singleton accessed via `shared`; handles challenges in `URLSessionDelegate` conformance.
/// - **Privacy/Security**: Prevents MITM attacks; no data logging beyond debug prints.
///
/// For streaming usage, see `validateServerCertificate` in `DirectStreamingPlayer.swift`. Testable via injectable `currentDate` for date-based logic.
/// 
/// Singleton class responsible for managing periodic SSL certificate validation with support for a transition period during certificate rotations.
///
/// This class performs runtime certificate pinning by validating the full SHA-256 fingerprint of the server's leaf certificate against a pinned value.
/// It integrates with App Transport Security (ATS) for baseline trust evaluation and includes caching to optimize performance.
/// During the defined transition period, fingerprint mismatches are allowed (falling back to ATS trust) to enable smooth certificate updates without disrupting service.
///
/// Key Features:
/// - Centralized validation logic used by both per-request (e.g., StreamingSessionDelegate) and periodic checks (e.g., DirectStreamingPlayer).
/// - Caches validation results for 10 minutes to reduce overhead.
/// - Logs warnings during transition for debugging (visible in DEBUG builds).
/// - Enforces strict pinning outside the transition period.
/// - **Non-blocking**: `validateServerCertificate(for:completion:)` is always
///   asynchronous and **no longer blocks** `DirectStreamingPlayer.play()`.
///   Playback starts optimistically; validation runs in the background and
///   aborts playback only if it fails (2026 concurrency model).
///
/// Usage:
/// - Access via `CertificateValidator.shared`.
/// - Call `validateServerCertificate(for:completion:)` for initial/periodic HEAD-based validation.
/// - Implements `URLSessionDelegate` for challenge-based validation during sessions.
public actor CertificateValidator: NSObject, URLSessionTaskDelegate {
    /// Shared singleton instance for global access.
    public static let shared = CertificateValidator()
    
    internal var pinnedCertFingerprint: String {
        SecurityConfiguration().pinnedLeafFingerprint
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
    
    /// Validates the server trust chain, respecting the transition period and caching results.
    ///
    /// Process:
    /// 1. Checks cache: Returns cached result if valid and recent.
    /// 2. Performs system trust evaluation via `SecTrustEvaluateWithError` (includes ATS pinning and chain validation).
    /// 3. If system trust passes, validates the leaf certificate's full fingerprint.
    /// 4. Applies transition logic:
    ///    - After expiry: Strictly enforce fingerprint.
    ///    - During transition: Warn on fingerprint failure but trust ATS (return true).
    ///    - Before transition: Enforce fingerprint.
    /// 5. Caches the final result and calls completion.
    ///
    /// - Parameters:
    ///   - serverTrust: The `SecTrust` object from the authentication challenge.
    ///   - completion: Callback with the validation result (true if valid/trusted).
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
        if !SecTrustEvaluateWithError(serverTrust, &error) {
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
    
    /// Performs certificate validation for a given URL via a HEAD request.
    /// Now fully async/await (2026 pattern). Uses the async task delegate above.
    ///
    /// This method creates an ephemeral URLSession to issue a HEAD request, triggering SSL validation.
    /// It relies on the session delegate (`self`) to handle authentication challenges.
    ///
    /// - Parameters:
    ///   - url: The stream URL to validate (must be HTTPS).
    ///   - completion: Callback with the validation result (true if valid and no error).
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
    
    /// Handles server trust authentication challenges during URLSession tasks.
    ///
    /// This delegate method is called when a server trust challenge occurs (e.g., during HEAD requests).
    /// It defers to `validateServerTrust` for evaluation and either uses the credential or cancels the challenge.
    ///
    /// - Parameters:
    ///   - session: The URLSession instance.
    ///   - challenge: The authentication challenge.
    ///   - completionHandler: Callback to disposition the challenge (use credential or cancel).
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
        if let certFingerprint = computeCertificateFingerprint(for: leafCertificate) {
            let isValid = config.pinnedFingerprints.contains(certFingerprint)
            #if DEBUG
            if !isValid {
                print("🔒 [CertificateValidator] Fingerprint mismatch detected")
            }
            #endif
            return isValid
        }
        return false
    }
    
    /// Computes the SHA-256 fingerprint of a certificate's DER representation.
    ///
    /// - Parameter certificate: The `SecCertificate` to fingerprint.
    /// - Returns: The hex-formatted fingerprint (uppercase, colon-separated), or nil on failure.
    internal func computeCertificateFingerprint(for certificate: SecCertificate) -> String? {
        guard let certData = SecCertificateCopyData(certificate) as Data? else {
            #if DEBUG
            print("🔒 [CertificateValidator] Failed to get certificate data")
            #endif
            return nil
        }
        var fingerprint = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        certData.withUnsafeBytes { dataBytes in
            _ = CC_SHA256(dataBytes.baseAddress, CC_LONG(certData.count), &fingerprint)
        }
        // Convert to hex, uppercase, colon-separated to match OpenSSL format
        return fingerprint.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
