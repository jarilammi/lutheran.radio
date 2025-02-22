//
//  CertificatePinningDelegate.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 22.2.2025.
//

import Foundation
import Security
import CommonCrypto
import AVFoundation

class CertificatePinningDelegate: NSObject, URLSessionDelegate, AVAssetResourceLoaderDelegate {
    // Hardcoded certificate hash (SHA256)
    private let pinnedCertificateHash = "mm31qgyBr2aXX8NzxmX/OeKzrUeOtxim4foWmxL4TZY="
    
    private var secureSession: URLSession!
    
    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        secureSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    
    // URLSessionDelegate method
    func urlSession(_ session: URLSession,
                   didReceive challenge: URLAuthenticationChallenge,
                   completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        
        guard let serverTrust = challenge.protectionSpace.serverTrust,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        // Get the server's certificate chain
        guard let certificates = SecTrustCopyCertificateChain(serverTrust),
              CFArrayGetCount(certificates) > 0,
              let serverCertificate = CFArrayGetValueAtIndex(certificates, 0) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        // Extract the public key from the certificate
        let certificate = serverCertificate as! SecCertificate
        guard let publicKey = SecCertificateCopyKey(certificate),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as? Data else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        // Calculate the hash of the public key
        let serverCertificateHash = publicKeyData.sha256().base64EncodedString()
        
        // Compare the hash with our pinned hash
        if serverCertificateHash == pinnedCertificateHash {
            // Certificate matches, proceed with the connection
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            // Certificate doesn't match, reject the connection
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    
    // AVAssetResourceLoaderDelegate methods
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                       shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        // Handle the resource loading request
        guard let url = loadingRequest.request.url else {
            loadingRequest.finishLoading(with: NSError(domain: "", code: -1, userInfo: nil))
            return false
        }
        
        // Create a URL session task to load the resource
        let request = URLRequest(url: url)
        let task = secureSession.dataTask(with: request) { data, response, error in
            if let error = error {
                loadingRequest.finishLoading(with: error)
                return
            }
            
            if let data = data {
                loadingRequest.dataRequest?.respond(with: data)
                loadingRequest.finishLoading()
            }
        }
        task.resume()
        
        return true
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                       didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        // Handle cancelled requests if needed
    }
}

// Extension to calculate SHA256 hash
extension Data {
    func sha256() -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(count), &hash)
        }
        return Data(hash)
    }
}
