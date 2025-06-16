//
//  StreamingSessionDelegate.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 4.3.2025.
//
//  Enhanced with SSL Certificate Pinning and Strategic Transition Support

/// - Article: Streaming Session Delegate Overview
///
/// This class handles streaming session delegation for Lutheran Radio, managing URL sessions and data tasks.
import Foundation
import AVFoundation
import Security
import CommonCrypto

class StreamingSessionDelegate: NSObject, URLSessionDataDelegate {
    
    // MARK: - Certificate Configuration
    
    // CURRENT CERTIFICATE (valid until Aug 20, 2025)
    private static let currentSPKIHash = "mm31qgyBr2aXX8NzxmX/OeKzrUeOtxim4foWmxL4TZY=" // openssl s_client -connect livestream.lutheran.radio:8443 -servername livestream.lutheran.radio < /dev/null 2>/dev/null | openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | base64
    private static let currentCertHash = "fKLbUQeMgiD3tYfzBXll4nQsbL5yR2lRtP5+cuLThsw=" // openssl s_client -connect livestream.lutheran.radio:8443 -servername livestream.lutheran.radio < /dev/null 2>/dev/null | openssl x509 -outform DER | openssl dgst -sha256 -binary | base64
    
    // TRANSITION CONFIGURATION
    static let transitionStartDate = Date(timeIntervalSince1970: 1753055999) // July 20, 2025 (1 month before expiry)
    static let certificateExpiryDate = Date(timeIntervalSince1970: 1755734399) // Aug 20, 2025 23:59:59
    
    // SHIELDING VARIABLE - Enable only during actual certificate transitions
    // CRITICAL SECURITY: Set to true ONLY during certificate renewal periods to prevent date manipulation attacks
    // During stable production period (Aug 2025 - July 2026), this MUST remain false
    static let isTransitionSupportEnabled = false // ⚠️ CHANGE TO TRUE ONLY DURING RENEWAL PERIOD
    
    /// Determines if we're currently in the certificate transition period
    static var isInTransitionPeriod: Bool {
        guard isTransitionSupportEnabled else {
            #if DEBUG
            print("🔒 [Transition] Support disabled by shielding variable")
            #endif
            return false
        }
        let now = Date()
        let inPeriod = now >= transitionStartDate && now <= certificateExpiryDate
        #if DEBUG
        print("🔒 [Transition] Current time: \(now), in period: \(inPeriod)")
        #endif
        return inPeriod
    }
    
    private static let enableCustomPinning = true
    static var hasSuccessfulPinningCheck = false
    
    /// Callback for transition state notifications
    var onTransitionDetected: (() -> Void)?
    
    /// The loading request for the AV asset resource.
    private var loadingRequest: AVAssetResourceLoadingRequest
    /// Tracks the total bytes received during the streaming session.
    private var bytesReceived = 0
    /// Indicates whether a response has been received.
    private var receivedResponse = false
    /// The URL session for managing streaming tasks.
    var session: URLSession?
    /// The data task for the streaming session.
    var dataTask: URLSessionDataTask?
    /// A closure to handle errors during the streaming session.
    var onError: ((Error) -> Void)?
    /// The original hostname before DNS override (for SSL validation)
    var originalHostname: String?
    
    private let connectionStartTime = Date()
    private var sslChallengeReceived = false
    private var firstDataReceived = false
    
    init(loadingRequest: AVAssetResourceLoadingRequest) {
        self.loadingRequest = loadingRequest
        super.init() // Call NSObject.init instead
        #if DEBUG
        print("🔒 [SSL Debug] StreamingSessionDelegate initialized")
        print("🔒 [Lifecycle] Connection created at: \(connectionStartTime)")
        #endif
    }
    
    func cancel() {
        let connectionAge = Date().timeIntervalSince(connectionStartTime)
        #if DEBUG
        print("🔒 [SSL Debug] StreamingSessionDelegate cancelling after \(connectionAge)s...")
        #endif
        dataTask?.cancel()
        session?.invalidateAndCancel()
        session = nil
        dataTask = nil
    }
    
    // MARK: - Enhanced SSL Challenge Handling with Transition Support
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        
        sslChallengeReceived = true
        let connectionAge = Date().timeIntervalSince(connectionStartTime)
        
        #if DEBUG
        print("🔒 ============ SSL CHALLENGE RECEIVED! ============")
        print("🔒 Connection age: \(connectionAge)s")
        print("🔒 Challenge host: \(challenge.protectionSpace.host)")
        print("🔒 Original hostname: \(originalHostname ?? "nil")")
        print("🔒 Current SPKI hash: \(Self.currentSPKIHash)")
        print("🔒 Current cert hash: \(Self.currentCertHash)")
        print("🔒 Transition support enabled: \(Self.isTransitionSupportEnabled)")
        print("🔒 In transition period: \(Self.isInTransitionPeriod)")
        print("🔒 ============================================")
        #endif
        
        // Verify it's a server trust challenge
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            #if DEBUG
            print("🔒 ❌ Not a server trust challenge")
            #endif
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            #if DEBUG
            print("🔒 ❌ No server trust available")
            #endif
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        guard let originalHost = self.originalHostname else {
            #if DEBUG
            print("🔒 ❌ No original hostname available")
            #endif
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        // Only validate lutheran.radio domains
        guard originalHost.hasSuffix("lutheran.radio") else {
            #if DEBUG
            print("🔒 ⚠️ Host \(originalHost) not in lutheran.radio domain")
            #endif
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        // Basic certificate validation first
        let cfHostname: CFString = originalHost as CFString
        let policy = SecPolicyCreateSSL(true, cfHostname)
        SecTrustSetPolicies(serverTrust, policy)
        
        var error: CFError?
        let basicValidationResult = SecTrustEvaluateWithError(serverTrust, &error)
        
        #if DEBUG
        print("🔒 📋 Basic certificate validation: \(basicValidationResult)")
        #endif
        
        guard basicValidationResult else {
            #if DEBUG
            print("🔒 ❌ BASIC CERTIFICATE VALIDATION FAILED")
            #endif
            handleValidationFailure(serverTrust: serverTrust, completionHandler: completionHandler)
            return
        }
        
        // Enhanced certificate pinning validation
        if validateCurrentCertificatePinning(serverTrust: serverTrust) {
            #if DEBUG
            print("🔒 ✅ ✅ ✅ CURRENT CERTIFICATE VALIDATION SUCCEEDED")
            #endif
            Self.hasSuccessfulPinningCheck = true
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
        } else {
            #if DEBUG
            print("🔒 ❌ ❌ ❌ CURRENT CERTIFICATE VALIDATION FAILED")
            #endif
            handleValidationFailure(serverTrust: serverTrust, completionHandler: completionHandler)
        }
    }
    
    // MARK: - Validation Failure Handling with Transition Support
    private func handleValidationFailure(serverTrust: SecTrust, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        
        // Check if we're in transition period and can gracefully handle the failure
        if Self.isInTransitionPeriod {
            #if DEBUG
            print("🔒 🔄 TRANSITION PERIOD DETECTED - Allowing connection despite validation failure")
            print("🔒 🔄 Certificate likely renewed on servers - user should update app")
            #endif
            
            // Notify about transition state for UI updates
            DispatchQueue.main.async { [weak self] in
                self?.onTransitionDetected?()
            }
            
            // Allow connection to proceed during transition
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
            
        } else {
            #if DEBUG
            print("🔒 ❌ OUTSIDE TRANSITION PERIOD - Denying connection")
            #endif
            
            // Normal security failure - deny connection
            onError?(URLError(.serverCertificateUntrusted))
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    
    // MARK: - Current Certificate Validation (Strategic Single-Point Validation)
    private func validateCurrentCertificatePinning(serverTrust: SecTrust) -> Bool {
        #if DEBUG
        print("🔒 [Current Cert] Starting strategic certificate validation")
        #endif
        
        guard let certificateChain = SecTrustCopyCertificateChain(serverTrust) else {
            #if DEBUG
            print("🔒 [Current Cert] ❌ Failed to get certificate chain")
            #endif
            return false
        }
        
        let certificateCount = CFArrayGetCount(certificateChain)
        #if DEBUG
        print("🔒 [Current Cert] Certificate chain contains \(certificateCount) certificates")
        #endif
        
        // Check each certificate in the chain for current hashes
        for i in 0..<certificateCount {
            guard let certificate = CFArrayGetValueAtIndex(certificateChain, i) else { continue }
            let secCertificate = Unmanaged<SecCertificate>.fromOpaque(certificate).takeUnretainedValue()
            
            #if DEBUG
            print("🔒 [Current Cert] Checking certificate \(i)")
            #endif
            
            // Method 1: Check SPKI hash
            if let spkiHash = computeOptimizedSPKIHash(for: secCertificate) {
                #if DEBUG
                print("🔒 [Current Cert] SPKI hash: \(spkiHash)")
                #endif
                
                if spkiHash == Self.currentSPKIHash {
                    #if DEBUG
                    print("🔒 [Current Cert] ✅ Found matching current SPKI hash (cert \(i))")
                    #endif
                    return true
                }
            }
            
            // Method 2: Check certificate hash
            let certificateData = SecCertificateCopyData(secCertificate)
            let data = CFDataGetBytePtr(certificateData)!
            let length = CFDataGetLength(certificateData)
            
            var hash = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
            _ = hash.withUnsafeMutableBytes { hashBytes in
                CC_SHA256(data, CC_LONG(length), hashBytes.bindMemory(to: UInt8.self).baseAddress)
            }
            
            let certHash = hash.base64EncodedString()
            #if DEBUG
            print("🔒 [Current Cert] Certificate \(i) hash: \(certHash)")
            #endif
            
            if certHash == Self.currentCertHash {
                #if DEBUG
                print("🔒 [Current Cert] ✅ Found matching current certificate hash (cert \(i))")
                #endif
                return true
            }
        }
        
        #if DEBUG
        print("🔒 [Current Cert] ❌ No matching current certificate found")
        print("🔒 [Current Cert] Expected SPKI hash: \(Self.currentSPKIHash)")
        print("🔒 [Current Cert] Expected cert hash: \(Self.currentCertHash)")
        #endif
        return false
    }
    
    // MARK: - Optimized SPKI Hash Computation
    private func computeOptimizedSPKIHash(for certificate: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(certificate),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) else {
            return nil
        }
        
        // Try EC P-256 SPKI format first (most common)
        let ecHeader: [UInt8] = [
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86,
            0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
            0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
            0x42, 0x00
        ]
        
        var spkiData = Data(ecHeader)
        spkiData.append(publicKeyData as Data)
        
        let ecHash = computeSHA256Hash(data: spkiData)
        if ecHash == Self.currentSPKIHash {
            return ecHash
        }
        
        // Try RSA SPKI format if EC didn't match
        let rsaHeader: [UInt8] = [
            0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09,
            0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01,
            0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00
        ]
        
        var rsaSpkiData = Data(rsaHeader)
        rsaSpkiData.append(publicKeyData as Data)
        
        return computeSHA256Hash(data: rsaSpkiData)
    }
    
    private func computeSHA256Hash(data: Data) -> String {
        var hash = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = hash.withUnsafeMutableBytes { hashBytes in
            data.withUnsafeBytes { dataBytes in
                CC_SHA256(dataBytes.bindMemory(to: UInt8.self).baseAddress,
                         CC_LONG(data.count),
                         hashBytes.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        return hash.base64EncodedString()
    }
    
    // MARK: - Transition Period Utilities
    
    /// Returns human-readable transition period information for debugging
    static var transitionPeriodInfo: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        
        let startStr = formatter.string(from: transitionStartDate)
        let endStr = formatter.string(from: certificateExpiryDate)
        
        return """
        Transition Period: \(startStr) - \(endStr)
        Support Enabled: \(isTransitionSupportEnabled)
        Currently In Period: \(isInTransitionPeriod)
        """
    }
    
    // MARK: - Keep all existing response handling methods unchanged
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let connectionAge = Date().timeIntervalSince(connectionStartTime)
        
        #if DEBUG
        print("📡 [SSL Debug] Received response after \(connectionAge)s")
        #endif
        
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        
        let statusCode = httpResponse.statusCode
        #if DEBUG
        print("📡 ✅ HTTP Status: \(statusCode)")
        #endif
        
        if statusCode == 403 {
            #if DEBUG
            print("📡 ❌ Access denied (403): Invalid security model")
            #endif
            onError?(URLError(.userAuthenticationRequired))
            loadingRequest.finishLoading(with: URLError(.userAuthenticationRequired))
            completionHandler(.cancel)
            return
        }
        
        if (400...599).contains(statusCode) {
            let error: URLError.Code = statusCode == 404 ? .fileDoesNotExist : .badServerResponse
            onError?(URLError(error))
            loadingRequest.finishLoading(with: URLError(error))
            completionHandler(.cancel)
            return
        }
        
        if let contentType = httpResponse.allHeaderFields["Content-Type"] as? String {
            loadingRequest.contentInformationRequest?.contentType = contentType
        }
        
        loadingRequest.contentInformationRequest?.contentLength = -1
        loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = false
        
        receivedResponse = true
        completionHandler(.allow)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard receivedResponse else { return }
        bytesReceived += data.count
        loadingRequest.dataRequest?.respond(with: data)
        
        if !firstDataReceived {
            firstDataReceived = true
            #if DEBUG
            print("📡 ✅ FIRST DATA RECEIVED - Streaming started successfully!")
            #endif
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let connectionAge = Date().timeIntervalSince(connectionStartTime)
        
        if let error = error {
            #if DEBUG
            print("📡 ❌ Session completed with error after \(connectionAge)s: \(error.localizedDescription)")
            #endif
            onError?(error)
        } else {
            #if DEBUG
            print("📡 ✅ Session completed successfully after \(connectionAge)s")
            #endif
        }
    }
    
    deinit {
        #if DEBUG
        let connectionAge = Date().timeIntervalSince(connectionStartTime)
        print("🧹 [Deinit] StreamingSessionDelegate deallocating after \(connectionAge)s")
        #endif
        
        // Cancel and clean up session
        dataTask?.cancel()
        session?.invalidateAndCancel()
        
        // Clear references
        session = nil
        dataTask = nil
        onError = nil
        originalHostname = nil
        onTransitionDetected = nil
        
        #if DEBUG
        print("🧹 StreamingSessionDelegate deinit completed")
        #endif
    }
}
