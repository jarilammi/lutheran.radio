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

/**
 * Certificate pinning delegate for securing network connections.
 * Validates servers by comparing their public key hash against a known value
 * to prevent MITM attacks.
 */
class CertificatePinningDelegate: NSObject, URLSessionDelegate, AVAssetResourceLoaderDelegate {
    // Hash of the server's public key, generated using:
    // $ openssl s_client -connect livestream.lutheran.radio:8443 \
    //   -servername livestream.lutheran.radio < /dev/null \
    //   | openssl x509 -outform pem \
    //   | openssl x509 -pubkey -noout \
    //   | openssl dgst -sha512 -binary \
    //   | base64
    
    // SHA-512 is used here for fast integrity checks
    private let pinnedPublicKeyHash = "G7lfOgLOyYZNMoltoAIbB8fd8kMJSUvetPXAAEk6uHivMTP5pnMy+rYLapGaLsn7EryZstIUSh2Ee28alLzqLA=="
    
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
        let serverPublicKeyHash = publicKeyData.sha512().base64EncodedString()
        
        // Compare the hash with our pinned hash
        if serverPublicKeyHash == pinnedPublicKeyHash {
            // Certificate matches, proceed with the connection
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            // Certificate doesn't match, reject the connection
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    
    // Prevent redirects since we use fixed endpoint
    func urlSession(_ session: URLSession,
                   task: URLSessionTask,
                   willPerformHTTPRedirection response: HTTPURLResponse,
                   newRequest request: URLRequest,
                   completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
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

// Extension to calculate SHA512 hash
extension Data {
    func sha512() -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        withUnsafeBytes { buffer in
            _ = CC_SHA512(buffer.baseAddress, CC_LONG(count), &hash)
        }
        return Data(hash)
    }
}
