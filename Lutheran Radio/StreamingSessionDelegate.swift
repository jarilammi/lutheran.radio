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
    // lutheran.radio pinned certificate SPKI hash (same as in Info.plist)
    private static let pinnedSPKIHash = "mm31qgyBr2aXX8NzxmX/OeKzrUeOtxim4foWmxL4TZY="
    
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
    
    init(loadingRequest: AVAssetResourceLoadingRequest) {
        self.loadingRequest = loadingRequest
        super.init() // Call NSObject.init instead
    }
    
    func cancel() {
        dataTask?.cancel()
        session?.invalidateAndCancel()
        session = nil
        dataTask = nil
        #if DEBUG
        print("📡 StreamingSessionDelegate canceled")
        #endif
    }
    
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            #if DEBUG
            print("🔒 No server trust available")
            #endif
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        // Use the stored original hostname for validation
        guard let originalHost = self.originalHostname else {
            #if DEBUG
            print("🔒 No original hostname available")
            #endif
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        // Only validate lutheran.radio domains
        guard originalHost.hasSuffix("lutheran.radio") else {
            #if DEBUG
            print("🔒 Host \(originalHost) not in lutheran.radio domain")
            #endif
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        // Set policy for hostname verification
        let policy = SecPolicyCreateSSL(true, originalHost as CFString)
        SecTrustSetPolicies(serverTrust, [policy] as CFArray)
        
        // First, validate basic certificate chain
        var error: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &error) else {
            #if DEBUG
            print("🔒 Basic certificate validation failed for \(originalHost): \(error?.localizedDescription ?? "Unknown error")")
            #endif
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        // Now perform SPKI pinning validation
        if validateCertificatePinning(serverTrust: serverTrust, pinnedHash: Self.pinnedSPKIHash) {
            #if DEBUG
            print("🔒 Certificate pinning validation succeeded for \(originalHost)")
            #endif
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
        } else {
            #if DEBUG
            print("🔒 Certificate pinning validation failed for \(originalHost)")
            #endif
            onError?(URLError(.serverCertificateUntrusted))
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    
    private func validateCertificatePinning(serverTrust: SecTrust, pinnedHash: String) -> Bool {
        // Get certificate chain using modern API
        guard let certificateChain = SecTrustCopyCertificateChain(serverTrust) else {
            #if DEBUG
            print("🔒 Failed to get certificate chain")
            #endif
            return false
        }
        
        let certificateCount = CFArrayGetCount(certificateChain)
        
        // Check each certificate in the chain
        for i in 0..<certificateCount {
            guard let certificate = CFArrayGetValueAtIndex(certificateChain, i) else {
                continue
            }
            
            let secCertificate = Unmanaged<SecCertificate>.fromOpaque(certificate).takeUnretainedValue()
            
            // Try multiple validation approaches for robustness
            if validateSPKIHash(for: secCertificate, againstPinnedHash: pinnedHash) ||
               validateCertificateHash(for: secCertificate, againstPinnedHash: pinnedHash) {
                #if DEBUG
                print("🔒 Found matching pinned certificate at index \(i)")
                #endif
                return true
            }
        }
        
        #if DEBUG
        print("🔒 No matching pinned certificate found in chain")
        #endif
        return false
    }
    
    // Primary method: SPKI hash validation (matches Info.plist)
    private func validateSPKIHash(for certificate: SecCertificate, againstPinnedHash pinnedHash: String) -> Bool {
        guard let computedHash = computeSPKIHash(for: certificate) else {
            return false
        }
        return computedHash == pinnedHash
    }
    
    // Fallback method: Certificate hash validation
    private func validateCertificateHash(for certificate: SecCertificate, againstPinnedHash pinnedHash: String) -> Bool {
        let certificateData = SecCertificateCopyData(certificate)
        let data = CFDataGetBytePtr(certificateData)!
        let length = CFDataGetLength(certificateData)
        
        var hash = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = hash.withUnsafeMutableBytes { hashBytes in
            CC_SHA256(data, CC_LONG(length), hashBytes.bindMemory(to: UInt8.self).baseAddress)
        }
        
        let certHash = hash.base64EncodedString()
        #if DEBUG
        print("🔒 Certificate hash: \(certHash)")
        #endif
        
        return certHash == pinnedHash
    }
    
    private func computeSPKIHash(for certificate: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(certificate) else {
            return nil
        }
        
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) else {
            return nil
        }
        
        // Get key attributes to determine key type
        guard let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any],
              let keyType = attributes[kSecAttrKeyType as String] as? String else {
            return nil
        }
        
        // Create appropriate ASN.1 DER header based on key type
        let spkiData: Data
        
        if keyType == kSecAttrKeyTypeRSA as String {
            // RSA public key header
            let rsaHeader: [UInt8] = [
                0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09,
                0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01,
                0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00
            ]
            var data = Data(rsaHeader)
            data.append(publicKeyData as Data)
            spkiData = data
        } else if keyType == kSecAttrKeyTypeECSECPrimeRandom as String {
            // EC public key header (P-256)
            let ecHeader: [UInt8] = [
                0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86,
                0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
                0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
                0x42, 0x00
            ]
            var data = Data(ecHeader)
            data.append(publicKeyData as Data)
            spkiData = data
        } else {
            // Fallback: use raw public key data (less standard but may work)
            spkiData = publicKeyData as Data
        }
        
        // Compute SHA-256 hash
        var hash = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = hash.withUnsafeMutableBytes { hashBytes in
            spkiData.withUnsafeBytes { spkiBytes in
                CC_SHA256(spkiBytes.bindMemory(to: UInt8.self).baseAddress,
                         CC_LONG(spkiData.count),
                         hashBytes.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        
        return hash.base64EncodedString()
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let httpResponse = response as? HTTPURLResponse else {
            #if DEBUG
            print("📡 Failed to process response: invalid response type")
            #endif
            completionHandler(.cancel)
            return
        }
        
        #if DEBUG
        print("📡 Received HTTP response with status code: \(httpResponse.statusCode)")
        #endif
        
        let statusCode = httpResponse.statusCode
        if statusCode == 403 {
            #if DEBUG
            print("📡 Access denied: Invalid security model")
            #endif
            onError?(URLError(.userAuthenticationRequired))
            loadingRequest.finishLoading(with: URLError(.userAuthenticationRequired))
            completionHandler(.cancel)
            return
        }
        
        if (400...599).contains(statusCode) {
            let error: URLError.Code
            switch statusCode {
            case 502:
                error = .badServerResponse
                #if DEBUG
                print("📡 Detected 502 Bad Gateway - treating as permanent error")
                #endif
            case 404:
                error = .fileDoesNotExist
                #if DEBUG
                print("📡 Detected 404 Not Found - treating as permanent error")
                #endif
            case 429:
                error = .resourceUnavailable
                #if DEBUG
                print("📡 Detected 429 Too Many Requests - treating as permanent error")
                #endif
            case 503:
                error = .resourceUnavailable
                #if DEBUG
                print("📡 Detected 503 Service Unavailable - treating as permanent error")
                #endif
            default:
                error = .badServerResponse
                #if DEBUG
                print("📡 Unhandled HTTP status code: \(statusCode)")
                #endif
            }
            onError?(URLError(error))
            loadingRequest.finishLoading(with: URLError(error))
            completionHandler(.cancel)
            return
        }
        
        if let contentType = httpResponse.allHeaderFields["Content-Type"] as? String {
            #if DEBUG
            print("📡 Content-Type: \(contentType)")
            #endif
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
        #if DEBUG
        print("📡 Received chunk of \(data.count) bytes (total: \(bytesReceived))")
        #endif
        loadingRequest.dataRequest?.respond(with: data)
    }
}
