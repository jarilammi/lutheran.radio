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
class CertificatePinningDelegate: NSObject, URLSessionDelegate {
    // SHA-512 is used here for fast integrity checks
    private let pinnedPublicKeyHash = "rMadBtyLpBp0ybRQW6+WGcFm6wGG7OldSI6pA/eRVQy/xnpjBsDu897E1HcGZPB+mZQhUkfswZVVvWF9YPALFQ=="
    
    // Keeps track of active sessions to prevent deallocation
    private var activeSessions = [URLSession]()
    
    // URLSessionDelegate method for certificate validation
    func urlSession(_ session: URLSession,
                   didReceive challenge: URLAuthenticationChallenge,
                   completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        
        print("🔒 Certificate verification started")
        
        guard let serverTrust = challenge.protectionSpace.serverTrust,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            print("🔒 Invalid authentication method")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        // FIXED: Use updated iOS 15+ API for certificate extraction
        guard let certificates = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let certificate = certificates.first else {
            print("🔒 No certificates found")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        // FIXED: Use updated iOS 12+ API for key extraction
        guard let publicKey = SecCertificateCopyKey(certificate) else {
            print("🔒 Failed to extract public key")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        // Get external representation safely
        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            print("🔒 Failed to get key external representation: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        // Calculate the hash safely
        let serverPublicKeyHash = publicKeyData.sha512().base64EncodedString()
        
        print("🔒 Server hash: \(serverPublicKeyHash)")
        print("🔒 Pinned hash: \(pinnedPublicKeyHash)")
        
        // Compare the hash with our pinned hash
        if serverPublicKeyHash == pinnedPublicKeyHash {
            print("✅ Certificate verification passed: Public key hash matches")
            // Certificate matches, proceed with the connection
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            print("❌ Certificate verification failed: Public key hash mismatch")
            // Certificate doesn't match, reject the connection
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    
    // AVAssetResourceLoaderDelegate implementation for streaming
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                       shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        print("📡 Resource loader called with URL: \(loadingRequest.request.url?.absoluteString ?? "nil")")
        
        // Check if this is our custom URL scheme
        guard let url = loadingRequest.request.url,
              let urlScheme = url.scheme,
              urlScheme == "streaming" else {
            print("📡 Resource loader rejected: Wrong scheme \(loadingRequest.request.url?.scheme ?? "nil")")
            loadingRequest.finishLoading(with: NSError(domain: "InvalidScheme", code: -1, userInfo: nil))
            return false
        }
        
        // Convert the custom scheme URL to an HTTPS URL
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = "https"
        
        guard let httpsURL = components.url else {
            print("📡 Resource loader failed: URL conversion failed")
            loadingRequest.finishLoading(with: NSError(domain: "URLConversion", code: -1, userInfo: nil))
            return false
        }
        
        print("📡 Converting URL scheme from streaming to https: \(httpsURL)")
        
        // Use a dedicated configuration for streaming with longer timeout
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 120 // Longer resource timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        
        // Create a custom data delegate that will handle both security and streaming
        let streamingDelegate = StreamingSessionDelegate(loadingRequest: loadingRequest, pinningDelegate: self)
        
        // Create a session with the streaming delegate
        let session = URLSession(configuration: config, delegate: streamingDelegate, delegateQueue: nil)
        activeSessions.append(session)
        
        print("📡 Creating request to \(httpsURL)")
        var request = URLRequest(url: httpsURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.addValue("*/*", forHTTPHeaderField: "Accept")
        request.addValue("identity", forHTTPHeaderField: "Accept-Encoding") // Don't compress audio
        request.addValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        
        print("📡 Starting data task")
        let task = session.dataTask(with: request)
        task.resume()
        
        // Set up cleanup when this resource loader is cancelled
        loadingRequest.contentInformationRequest?.contentType = "audio/mpeg" // Default content type
        
        return true
    }
    
    // Handle cancellation of resource loading
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                       didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        print("📡 Resource loader request canceled")
        // The session will be cleaned up by the StreamingSessionDelegate
    }
    
    deinit {
        // Clean up all active sessions
        for session in activeSessions {
            session.invalidateAndCancel()
        }
        activeSessions.removeAll()
    }
}

/**
 * Combined delegate that handles both certificate validation and streaming data.
 * This avoids the need for complex notification observation.
 */
class StreamingSessionDelegate: NSObject, URLSessionDelegate, URLSessionDataDelegate {
    private weak var loadingRequest: AVAssetResourceLoadingRequest?
    private weak var pinningDelegate: CertificatePinningDelegate?
    private var bytesReceived = 0
    private var receivedResponse = false
    
    init(loadingRequest: AVAssetResourceLoadingRequest, pinningDelegate: CertificatePinningDelegate) {
        self.loadingRequest = loadingRequest
        self.pinningDelegate = pinningDelegate
        super.init()
    }
    
    // Forward certificate challenges to the pinning delegate
    func urlSession(_ session: URLSession,
                   didReceive challenge: URLAuthenticationChallenge,
                   completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        pinningDelegate?.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }
    
    // Handle HTTP response
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                   didReceive response: URLResponse,
                   completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        
        guard let loadingRequest = loadingRequest,
              let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        
        print("📡 Received HTTP response with status code: \(httpResponse.statusCode)")
        
        // Process content type and length for the loading request
        if let contentType = httpResponse.allHeaderFields["Content-Type"] as? String {
            print("📡 Content-Type: \(contentType)")
            loadingRequest.contentInformationRequest?.contentType = contentType
        }
        
        // For streaming media, we typically don't know the total content length
        loadingRequest.contentInformationRequest?.contentLength = -1
        loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = false
        
        receivedResponse = true
        completionHandler(.allow)
    }
    
    // Handle incoming data chunks
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let loadingRequest = loadingRequest, receivedResponse else {
            return
        }
        
        bytesReceived += data.count
        print("📡 Received chunk of \(data.count) bytes (total: \(bytesReceived))")
        
        // Pass the data to the loading request
        loadingRequest.dataRequest?.respond(with: data)
        
        // DO NOT call finishLoading() - we want to keep the connection open for streaming
    }
    
    // Handle task completion (could be error or normal completion)
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            // Only report non-cancellation errors
            if (error as NSError).domain != NSURLErrorDomain ||
               (error as NSError).code != NSURLErrorCancelled {
                print("📡 Streaming task failed: \(error.localizedDescription)")
                loadingRequest?.finishLoading(with: error)
            } else {
                print("📡 Streaming task cancelled")
            }
        } else {
            print("📡 Streaming task completed normally")
            // We don't finish loading on normal completion for streaming
        }
        
        // Invalidate the session when done with it
        session.invalidateAndCancel()
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
