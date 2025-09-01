//
//  CertificateValidator.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 24.6.2025.
//

import Foundation
import Security
import CommonCrypto

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
///
/// Usage:
/// - Access via `CertificateValidator.shared`.
/// - Call `validateServerCertificate(for:completion:)` for initial/periodic HEAD-based validation.
/// - Implements `URLSessionDelegate` for challenge-based validation during sessions.
class CertificateValidator: NSObject, URLSessionDelegate {
    /// Shared singleton instance for global access.
    static let shared = CertificateValidator()
    
    /// The pinned SHA-256 fingerprint of the full certificate (DER representation), formatted as hex (uppercase, colon-separated).
    ///
    /// Generated via: `openssl s_client -connect livestream.lutheran.radio:8443 | openssl x509 -fingerprint -sha256 -noout`.
    /// Update this value post-certificate expiry/rotation via app release.
    internal var pinnedCertFingerprint: String {
        "CC:F7:8E:09:EF:F3:3D:9A:5D:8B:B0:5C:74:28:0D:F6:BE:14:1C:C4:47:F9:69:C2:90:2C:43:97:66:8B:3D:CC" // openssl s_client -connect livestream.lutheran.radio:8443 | openssl x509 -fingerprint -sha256 -noout
    }
    
    /// The start date for the certificate transition period (July 27, 2026).
    static let transitionStartDate = Date(timeIntervalSince1970: 1785110400)
    
    /// The expiry date of the current certificate (August 26, 2026, 23:59:59).
    static let certificateExpiryDate = Date(timeIntervalSince1970: 1787788799)
    
    /// Barrier flag to allow leniency during transition, mitigating date manipulation risks.
    /// Defaults to true (lenient, trusting ATS on mismatch); set to false if manipulation detected (e.g., via server time check).
    var allowTransitionLeniency: Bool = true
    
    /// Timestamp of the last validation attempt.
    private var lastValidationTime: Date?
    
    /// Interval for caching validation results (10 minutes).
    private let validationInterval: TimeInterval = 600 // 10 minutes
    
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
    internal var currentDate: () -> Date = { Date() }
    
    /// Determines if the current date falls within the defined transition period.
    private var isInTransitionPeriod: Bool {
        let now = currentDate()
        return now >= Self.transitionStartDate && now <= Self.certificateExpiryDate
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
    func validateServerTrust(_ serverTrust: SecTrust, completion: @escaping (Bool) -> Void) {
        if let lastTime = lastValidationTime, Date().timeIntervalSince(lastTime) < validationInterval, lastValidationResult {
            #if DEBUG
            print("🔒 [CertificateValidator] Using cached valid result from \(lastTime)")
            #endif
            completion(true)
            return
        }
        
        // Perform system trust evaluation (includes ATS pinning and chain validation)
        var error: CFError?
        if !SecTrustEvaluateWithError(serverTrust, &error) {
            #if DEBUG
            print("🔒 [CertificateValidator] System trust evaluation failed: \(error?.localizedDescription ?? "Unknown error")")
            #endif
            lastValidationTime = Date()
            lastValidationResult = false
            completion(false)
            return
        }
        
        let isPinnedValid = validateCertificateChain(serverTrust: serverTrust)
        let now = currentDate()
        let isValid: Bool
        
        if now > Self.certificateExpiryDate {
            // After expiry, strictly enforce pinned fingerprint
            isValid = isPinnedValid
            if !isValid {
                #if DEBUG
                print("🔒 [CertificateValidator] Certificate fingerprint validation failed after expiry at \(now). Expected: \(pinnedCertFingerprint)")
                #endif
            }
        } else if isInTransitionPeriod {
            // During transition, apply barrier on fingerprint failure
            if !isPinnedValid {
                #if DEBUG
                print("⚠️ [CertificateValidator] Warning: Certificate fingerprint validation failed during transition period at \(now). Trusting ATS only if leniency allowed. Expected: \(pinnedCertFingerprint)")
                #endif
                isValid = allowTransitionLeniency  // Barrier controls leniency (defaults to false, enforcing strict fingerprint)
            } else {
                isValid = true  // Fingerprint matches, no issue
            }
        } else {
            // Before transition, enforce pinned fingerprint
            isValid = isPinnedValid
            if !isValid {
                #if DEBUG
                print("🔒 [CertificateValidator] Certificate fingerprint validation failed before transition at \(now). Expected: \(pinnedCertFingerprint)")
                #endif
            }
        }
        
        lastValidationTime = now
        lastValidationResult = isValid
        #if DEBUG
        print("🔒 [CertificateValidator] Certificate validation \(isValid ? "succeeded" : "failed") at \(now)")
        #endif
        completion(isValid)
    }
    
    /// Performs certificate validation for a given URL via a HEAD request.
    ///
    /// This method creates an ephemeral URLSession to issue a HEAD request, triggering SSL validation.
    /// It relies on the session delegate (`self`) to handle authentication challenges.
    ///
    /// - Parameters:
    ///   - url: The stream URL to validate (must be HTTPS).
    ///   - completion: Callback with the validation result (true if valid and no error).
    func validateServerCertificate(for url: URL, completion: @escaping (Bool) -> Void) {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let task = session.dataTask(with: request) { [weak self] _, response, error in
            guard let self = self else { completion(false); return }
            let isValid = error == nil && self.lastValidationResult
            
            // Manipulation detection on success
            if isValid, let httpResponse = response as? HTTPURLResponse,
               let dateStr = httpResponse.value(forHTTPHeaderField: "Date"),
               let serverDate = self.httpDateFormatter.date(from: dateStr) {
                
                self.allowTransitionLeniency = true  // Reset to true at start
                
                let deviceDate = self.currentDate()
                let tolerance: TimeInterval = 300  // 5 minutes for skew
                
                // Check for significant discrepancy indicating manipulation
                let timeDiff = abs(deviceDate.timeIntervalSince(serverDate))
                if timeDiff > tolerance {
                    #if DEBUG
                    print("⚠️ [CertificateValidator] Device time manipulation suspected: Device \(deviceDate), Server \(serverDate), Diff \(timeDiff)s")
                    #endif
                    self.allowTransitionLeniency = false
                } else {
                    // Specific transition mismatch check
                    let deviceInTransition = deviceDate >= Self.transitionStartDate && deviceDate <= Self.certificateExpiryDate
                    let serverInTransition = serverDate >= Self.transitionStartDate && serverDate <= Self.certificateExpiryDate
                    if deviceInTransition && !serverInTransition {
                        #if DEBUG
                        print("⚠️ [CertificateValidator] Transition mismatch detected: Device in transition but server not. Disabling leniency.")
                        #endif
                        self.allowTransitionLeniency = false
                    }
                }
            } else if isValid {
                #if DEBUG
                print("⚠️ [CertificateValidator] Skipping manipulation check: No valid Date header in response.")
                #endif
                // Optionally: Fallback to true or handle as potential issue
            }
            
            #if DEBUG
            print("🔒 [CertificateValidator] HEAD request completed for \(url). Valid: \(isValid), Error: \(error?.localizedDescription ?? "None")")
            #endif
            completion(isValid)
        }
        task.resume()
    }
    
    // MARK: - URLSessionDelegate
    
    /// Handles server trust authentication challenges during URLSession tasks.
    ///
    /// This delegate method is called when a server trust challenge occurs (e.g., during HEAD requests).
    /// It defers to `validateServerTrust` for evaluation and either uses the credential or cancels the challenge.
    ///
    /// - Parameters:
    ///   - session: The URLSession instance.
    ///   - challenge: The authentication challenge.
    ///   - completionHandler: Callback to disposition the challenge (use credential or cancel).
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            lastValidationResult = false
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        validateServerTrust(serverTrust) { isValid in
            if isValid {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
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
        
        if let certFingerprint = computeCertificateFingerprint(for: leafCertificate) {
            let isValid = certFingerprint == pinnedCertFingerprint
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
