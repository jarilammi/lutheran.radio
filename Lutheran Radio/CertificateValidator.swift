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
    static let shared = CertificateValidator(pinnedCertHash: "fKLbUQeMgiD3tYfzBXll4nQsbL5yR2lRtP5+cuLThsw=")
    
    /// The pinned certificate hash.
    private let pinnedCertHash: String
    
    /// The start date for the certificate transition period (July 20, 2025).
    static let transitionStartDate = Date(timeIntervalSince1970: 1753055999)
    
    /// The expiry date of the current certificate (August 20, 2025, 23:59:59).
    static let certificateExpiryDate = Date(timeIntervalSince1970: 1755734399)
    
    private var lastValidationTime: Date?
    private let validationInterval: TimeInterval = 600 // 10 minutes
    private var lastValidationResult: Bool = false
    
    private init(pinnedCertHash: String) {
        self.pinnedCertHash = pinnedCertHash
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
            print("🔒 [Validation] Using cached valid result from \(lastTime)")
            #endif
            completion(true)
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
                print("🔒 [Validation] Certificate hash validation failed after expiry at \(now)")
                #endif
            }
        } else if isInTransitionPeriod {
            // During transition, warn on hash failure but trust ATS
            if !isPinnedValid {
                #if DEBUG
                print("🔒 [Validation] Warning: Certificate hash validation failed during transition period at \(now). Trusting ATS.")
                #endif
            }
            isValid = true // Trust ATS during transition
        } else {
            // Before transition, enforce pinned hash
            isValid = isPinnedValid
            if !isValid {
                #if DEBUG
                print("🔒 [Validation] Certificate hash validation failed before transition at \(now)")
                #endif
            }
        }
        
        lastValidationTime = now
        lastValidationResult = isValid
        #if DEBUG
        print("🔒 [Validation] Certificate validation \(isValid ? "succeeded" : "failed") at \(now)")
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
        guard let certificateChain = SecTrustCopyCertificateChain(serverTrust) else { return false }
        for i in 0..<CFArrayGetCount(certificateChain) {
            guard let certificate = CFArrayGetValueAtIndex(certificateChain, i) else { continue }
            let secCertificate = Unmanaged<SecCertificate>.fromOpaque(certificate).takeUnretainedValue()
            if let certHash = computeCertificateHash(for: secCertificate), certHash == pinnedCertHash {
                return true
            }
        }
        return false
    }
    
    private func computeCertificateHash(for certificate: SecCertificate) -> String? {
        guard let certData = SecCertificateCopyData(certificate) as Data? else { return nil }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        certData.withUnsafeBytes { dataBytes in
            _ = CC_SHA256(dataBytes.baseAddress, CC_LONG(certData.count), &hash)
        }
        return Data(hash).base64EncodedString()
    }
}
