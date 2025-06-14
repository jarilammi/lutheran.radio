//
//  StreamingSessionDelegate.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 4.3.2025.
//
//  Enhanced with SSL Certificate Pinning

/// - Article: Streaming Session Delegate Overview
///
/// This class handles streaming session delegation for Lutheran Radio, managing URL sessions and data tasks.
import Foundation
import AVFoundation
import Security
import CommonCrypto

class StreamingSessionDelegate: NSObject, URLSessionDataDelegate {
    
    // openssl s_client -connect livestream.lutheran.radio:8443 -servername livestream.lutheran.radio < /dev/null 2>/dev/null | openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | base64
    private static let pinnedSPKIHash = "mm31qgyBr2aXX8NzxmX/OeKzrUeOtxim4foWmxL4TZY="
    
    // FALLBACK: Add the other certificate hashes for redundancy
    private static let fallbackSPKIHashes = [
        "mm31qgyBr2aXX8NzxmX/OeKzrUeOtxim4foWmxL4TZY="
    ]
    
    // CERTIFICATE HASH FALLBACK: Use full certificate hashes as backup
    private static let pinnedCertificateHashes = [
        "fKLbUQeMgiD3tYfzBXll4nQsbL5yR2lRtP5+cuLThsw=" // openssl s_client -connect livestream.lutheran.radio:8443 -servername livestream.lutheran.radio < /dev/null 2>/dev/null | openssl x509 -outform DER | openssl dgst -sha256 -binary | base64
    ]
    
    private static let enableCustomPinning = true // Enable SSL pinning
    static var hasSuccessfulPinningCheck = false
    
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
    
    // MARK: - SSL Challenge Handling with Updated Hashes
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        
        sslChallengeReceived = true
        let connectionAge = Date().timeIntervalSince(connectionStartTime)
        
        #if DEBUG
        print("🔒 ============ SSL CHALLENGE RECEIVED! ============")
        print("🔒 Connection age: \(connectionAge)s")
        print("🔒 Challenge host: \(challenge.protectionSpace.host)")
        print("🔒 Original hostname: \(originalHostname ?? "nil")")
        print("🔒 Primary SPKI hash: \(Self.pinnedSPKIHash)")
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
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        // Now perform enhanced certificate pinning
        if validateEnhancedCertificatePinning(serverTrust: serverTrust) {
            #if DEBUG
            print("🔒 ✅ ✅ ✅ CERTIFICATE PINNING VALIDATION SUCCEEDED")
            #endif
            Self.hasSuccessfulPinningCheck = true
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
        } else {
            #if DEBUG
            print("🔒 ❌ ❌ ❌ CERTIFICATE PINNING VALIDATION FAILED")
            #endif
            onError?(URLError(.serverCertificateUntrusted))
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    
    // MARK: - Enhanced Certificate Pinning with Multiple Validation Methods
    private func validateEnhancedCertificatePinning(serverTrust: SecTrust) -> Bool {
        #if DEBUG
        print("🔒 [SPKI] Starting enhanced certificate pinning validation")
        #endif
        
        guard let certificateChain = SecTrustCopyCertificateChain(serverTrust) else {
            #if DEBUG
            print("🔒 [SPKI] ❌ Failed to get certificate chain")
            #endif
            return false
        }
        
        let certificateCount = CFArrayGetCount(certificateChain)
        #if DEBUG
        print("🔒 [SPKI] Certificate chain contains \(certificateCount) certificates")
        #endif
        
        let allAcceptableSPKIHashes = [Self.pinnedSPKIHash] + Self.fallbackSPKIHashes
        
        // Check each certificate in the chain
        for i in 0..<certificateCount {
            guard let certificate = CFArrayGetValueAtIndex(certificateChain, i) else { continue }
            let secCertificate = Unmanaged<SecCertificate>.fromOpaque(certificate).takeUnretainedValue()
            
            #if DEBUG
            print("🔒 [SPKI] Checking certificate \(i)")
            #endif
            
            // Method 1: Try multiple SPKI hash computation methods
            let spkiMethods = [
                computeECSPKIHash(for: secCertificate),
                computeRSASPKIHash(for: secCertificate),
                computeRawSPKIHash(for: secCertificate)
            ]
            
            for (methodIndex, spkiHash) in spkiMethods.enumerated() {
                guard let hash = spkiHash else { continue }
                
                #if DEBUG
                print("🔒 [SPKI] Method \(methodIndex) hash: \(hash)")
                #endif
                
                if allAcceptableSPKIHashes.contains(hash) {
                    #if DEBUG
                    print("🔒 [SPKI] ✅ Found matching SPKI hash (method \(methodIndex), cert \(i))")
                    #endif
                    return true
                }
            }
            
            // Method 2: Certificate hash fallback
            let certificateData = SecCertificateCopyData(secCertificate)
            let data = CFDataGetBytePtr(certificateData)!
            let length = CFDataGetLength(certificateData)
            
            var hash = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
            _ = hash.withUnsafeMutableBytes { hashBytes in
                CC_SHA256(data, CC_LONG(length), hashBytes.bindMemory(to: UInt8.self).baseAddress)
            }
            
            let certHash = hash.base64EncodedString()
            #if DEBUG
            print("🔒 [SPKI] Certificate \(i) hash: \(certHash)")
            #endif
            
            if Self.pinnedCertificateHashes.contains(certHash) {
                #if DEBUG
                print("🔒 [SPKI] ✅ Found matching certificate hash (cert \(i))")
                #endif
                return true
            }
        }
        
        #if DEBUG
        print("🔒 [SPKI] ❌ No matching pinned certificate found")
        print("🔒 [SPKI] Expected SPKI hashes: \(allAcceptableSPKIHashes)")
        print("🔒 [SPKI] Expected cert hashes: \(Self.pinnedCertificateHashes)")
        #endif
        return false
    }
    
    // MARK: - Multiple SPKI Hash Computation Methods
    private func computeECSPKIHash(for certificate: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(certificate),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) else {
            return nil
        }
        
        // EC P-256 SPKI format
        let ecHeader: [UInt8] = [
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86,
            0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
            0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
            0x42, 0x00
        ]
        
        var spkiData = Data(ecHeader)
        spkiData.append(publicKeyData as Data)
        
        return computeSHA256Hash(data: spkiData)
    }
    
    private func computeRSASPKIHash(for certificate: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(certificate),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) else {
            return nil
        }
        
        // RSA SPKI format
        let rsaHeader: [UInt8] = [
            0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09,
            0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01,
            0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00
        ]
        
        var spkiData = Data(rsaHeader)
        spkiData.append(publicKeyData as Data)
        
        return computeSHA256Hash(data: spkiData)
    }
    
    private func computeRawSPKIHash(for certificate: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(certificate),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) else {
            return nil
        }
        
        return computeSHA256Hash(data: publicKeyData as Data)
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
    
    // MARK: - Keep all your existing response handling methods unchanged
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
        
        #if DEBUG
        print("🧹 StreamingSessionDelegate deinit completed")
        #endif
    }
}
