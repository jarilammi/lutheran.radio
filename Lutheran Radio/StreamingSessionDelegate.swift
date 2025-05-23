//
//  StreamingSessionDelegate.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 4.3.2025.
//

/// - Article: Streaming Session Delegate Overview
///
/// This class handles streaming session delegation for Lutheran Radio, managing URL sessions and data tasks.
import Foundation
import AVFoundation

class StreamingSessionDelegate: CustomDNSURLSessionDelegate, URLSessionDataDelegate {
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
    
    init(loadingRequest: AVAssetResourceLoadingRequest, hostnameToIP: [String: String]) {
        self.loadingRequest = loadingRequest
        super.init(hostnameToIP: hostnameToIP)
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
    
    override func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            if (error as NSError).domain != NSURLErrorDomain || (error as NSError).code != NSURLErrorCancelled {
                #if DEBUG
                print("📡 Streaming task failed with error: \(error)")
                #endif
                if let urlError = error as? URLError {
                    switch urlError.code {
                    case .notConnectedToInternet, .cannotFindHost, .serverCertificateUntrusted:
                        #if DEBUG
                        if urlError.code == .serverCertificateUntrusted {
                            print("🔒 Pinning failure detected: Certificate untrusted")
                        }
                        #endif
                        if let onError = onError {
                            DispatchQueue.main.async {
                                onError(urlError)
                            }
                        } else {
                            onError?(urlError)
                        }
                    default:
                        if let onError = onError {
                            DispatchQueue.main.async {
                                onError(error)
                            }
                        } else {
                            onError?(error)
                        }
                    }
                } else {
                    if let onError = onError {
                        DispatchQueue.main.async {
                            onError(error)
                        }
                    } else {
                        onError?(error)
                    }
                }
                loadingRequest.finishLoading(with: error) // Safe on main queue
            } else {
                #if DEBUG
                print("📡 Streaming task cancelled")
                #endif
            }
        } else {
            #if DEBUG
            print("📡 Streaming task completed normally")
            #endif
        }
        session.invalidateAndCancel()
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
        loadingRequest.dataRequest?.respond(with: data) // Safe on main queue
    }
    
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Check if this is a server trust challenge
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            guard let serverTrust = challenge.protectionSpace.serverTrust else {
                #if DEBUG
                print("🔒 No server trust available, cancelling challenge")
                #endif
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            
            // Use the stored original hostname if available
            if let originalHost = self.originalHostname {
                // Create an SSL policy using the original hostname
                let policy = SecPolicyCreateSSL(true, originalHost as CFString)
                SecTrustSetPolicies(serverTrust, [policy] as CFArray)
                
                // Evaluate the trust
                var error: CFError?
                if SecTrustEvaluateWithError(serverTrust, &error) {
                    #if DEBUG
                    print("🔒 Certificate validation succeeded for host: \(originalHost)")
                    #endif
                    let credential = URLCredential(trust: serverTrust)
                    completionHandler(.useCredential, credential)
                } else {
                    #if DEBUG
                    print("🔒 Certificate validation failed for host \(originalHost): \(error?.localizedDescription ?? "Unknown error")")
                    #endif
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            } else if let originalHost = loadingRequest.request.allHTTPHeaderFields?["Host"] {
                // Fallback: Extract from Host header
                #if DEBUG
                print("🔒 Using Host header for validation: \(originalHost)")
                #endif
                let policy = SecPolicyCreateSSL(true, originalHost as CFString)
                SecTrustSetPolicies(serverTrust, [policy] as CFArray)
                
                var error: CFError?
                if SecTrustEvaluateWithError(serverTrust, &error) {
                    let credential = URLCredential(trust: serverTrust)
                    completionHandler(.useCredential, credential)
                } else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            } else {
                #if DEBUG
                print("🔒 No hostname available for SSL validation, using default handling")
                #endif
                completionHandler(.performDefaultHandling, nil)
            }
        } else {
            #if DEBUG
            print("🔒 Non-server trust challenge received, using default handling")
            #endif
            completionHandler(.performDefaultHandling, nil)
        }
    }
    
    // Handle redirects with DNS override
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Apply DNS override to redirects as well
        if let url = request.url, let host = url.host, let ipAddress = hostnameToIP[host] {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.host = ipAddress
            if let newURL = components?.url {
                var modifiedRequest = request
                modifiedRequest.url = newURL
                modifiedRequest.setValue(host, forHTTPHeaderField: "Host")
                #if DEBUG
                print("📡 [Redirect] Overriding DNS for \(host) to \(ipAddress)")
                #endif
                completionHandler(modifiedRequest)
                return
            }
        }
        completionHandler(request)
    }
}
