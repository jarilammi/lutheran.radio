//
//  CertificateValidator.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 24.6.2025.
//

import Foundation
import Security
import CommonCrypto

/// Manages periodic certificate validation with transition period support.
class CertificateValidator: NSObject, URLSessionDelegate {
    static let shared = CertificateValidator()
    
    /// The pinned certificate SHA-256 hash (hex, uppercase, colon-separated).
    private let pinnedCertHash = "7C:A2:DB:51:07:8C:82:20:F7:B5:87:F3:05:79:65:E2:74:2C:6C:BE:72:47:69:51:B4:FE:7E:72:E2:D3:86:CC"
    
    /// The start date for the certificate transition period (July 20, 2025).
    static let transitionStartDate = Date(timeIntervalSince1970: 1753055999)
    
    /// The expiry date of the current certificate (August 20, 2025, 23:59:59).
    static let certificateExpiryDate = Date(timeIntervalSince1970: 1755734399)
    
    private var lastValidationTime: Date?
    private let validationInterval: TimeInterval = 600 // 10 minutes
    private var lastValidationResult: Bool = false
    
    private override init() {
        super.init()
    }
    
    /// Checks if the current date is within the transition period.
    private var isInTransitionPeriod: Bool {
        let now = Date()
        return now >= Self.transitionStartDate && now <= Self.certificateExpiryDate
    }
    
    /// Validates server trust, respecting transition period and caching results.
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
        let now = Date()
        let isValid: Bool
        
        if now > Self.certificateExpiryDate {
            // After expiry, strictly enforce pinned hash
            isValid = isPinnedValid
            if !isValid {
                #if DEBUG
                print("🔒 [CertificateValidator] Certificate hash validation failed after expiry at \(now). Expected: \(pinnedCertHash)")
                #endif
            }
        } else if isInTransitionPeriod {
            // During transition, warn on hash failure but trust ATS
            if !isPinnedValid {
                #if DEBUG
                print("⚠️ [CertificateValidator] Warning: Certificate hash validation failed during transition period at \(now). Trusting ATS. Expected: \(pinnedCertHash)")
                #endif
            }
            isValid = true // Trust ATS during transition
        } else {
            // Before transition, enforce pinned hash
            isValid = isPinnedValid
            if !isValid {
                #if DEBUG
                print("🔒 [CertificateValidator] Certificate hash validation failed before transition at \(now). Expected: \(pinnedCertHash)")
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
    
    /// Validates certificate for a URL via HEAD request.
    func validateServerCertificate(for url: URL, completion: @escaping (Bool) -> Void) {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let task = session.dataTask(with: request) { [weak self] _, _, error in
            guard let self = self else { completion(false); return }
            let isValid = error == nil && self.lastValidationResult
            #if DEBUG
            print("🔒 [CertificateValidator] HEAD request completed for \(url). Valid: \(isValid), Error: \(error?.localizedDescription ?? "None")")
            #endif
            completion(isValid)
        }
        task.resume()
    }
    
    // MARK: - URLSessionDelegate
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
    
    // MARK: - Private
    private func validateCertificateChain(serverTrust: SecTrust) -> Bool {
        // Focus on leaf certificate (index 0) as per SSL pinning document
        guard let certificateChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              !certificateChain.isEmpty,
              let leafCertificate = certificateChain.first else {
            #if DEBUG
            print("🔒 [CertificateValidator] Failed to get leaf certificate from chain")
            #endif
            return false
        }
        
        if let certHash = computeCertificateHash(for: leafCertificate) {
            let isValid = certHash == pinnedCertHash
            #if DEBUG
            if !isValid {
                print("🔒 [CertificateValidator] Hash mismatch. Computed: \(certHash), Expected: \(pinnedCertHash)")
            }
            #endif
            return isValid
        }
        return false
    }
    
    private func computeCertificateHash(for certificate: SecCertificate) -> String? {
        guard let certData = SecCertificateCopyData(certificate) as Data? else {
            #if DEBUG
            print("🔒 [CertificateValidator] Failed to get certificate data")
            #endif
            return nil
        }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        certData.withUnsafeBytes { dataBytes in
            _ = CC_SHA256(dataBytes.baseAddress, CC_LONG(certData.count), &hash)
        }
        // Convert to hex, uppercase, colon-separated to match OpenSSL format
        return hash.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
