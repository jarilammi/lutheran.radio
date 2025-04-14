//
//  StreamingSessionDelegate.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 4.3.2025.
//

import Foundation
import AVFoundation

class StreamingSessionDelegate: NSObject, URLSessionDelegate, URLSessionDataDelegate {
    private var loadingRequest: AVAssetResourceLoadingRequest // Removed weak to avoid nullability issues
    private var bytesReceived = 0
    private var receivedResponse = false
    var onError: ((Error) -> Void)? // Add error callback
    
    init(loadingRequest: AVAssetResourceLoadingRequest) {
        self.loadingRequest = loadingRequest
        super.init()
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            if (error as NSError).domain != NSURLErrorDomain || (error as NSError).code != NSURLErrorCancelled {
                #if DEBUG
                print("📡 Streaming task failed: \(error.localizedDescription)")
                #endif
                // Add specific error handling
                if let urlError = error as? URLError {
                    switch urlError.code {
                    case .notConnectedToInternet:
                        // Handle no internet connection
                        onError?(URLError(.notConnectedToInternet))
                    case .cannotFindHost:
                        // Handle host not found
                        onError?(URLError(.cannotFindHost))
                    case .serverCertificateUntrusted:
                        #if DEBUG
                        print("🔒 Pinning failure detected: Certificate untrusted")
                        #endif
                        onError?(URLError(.serverCertificateUntrusted))
                    default:
                        onError?(error)
                    }
                } else {
                    onError?(error)
                }
                loadingRequest.finishLoading(with: error)
            } else {
                #if DEBUG
                print("📡 Streaming task cancelled")
                #endif
            }
        } else {
            #if DEBUG
            print("📡 Streaming task completed normally")
            #endif
            // Do not call finishLoading() here for streaming
        }
        session.invalidateAndCancel()
    }
    
    // Handle HTTP response
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
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
            case 429: // Too Many Requests
                error = .resourceUnavailable // Treat as permanent to avoid overloading servers during rate limiting
                #if DEBUG
                print("📡 Detected 429 Too Many Requests - treating as permanent error to protect servers")
                #endif
            case 503:
                error = .resourceUnavailable // Treat as permanent to avoid retries during server maintenance/overloads
                #if DEBUG
                print("📡 Detected 503 Service Unavailable - treating as permanent error to protect servers")
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
        
        // Process content type and length for the loading request
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
    
    // Handle incoming data chunks
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard receivedResponse else {
            return
        }
        
        bytesReceived += data.count
        #if DEBUG
        print("📡 Received chunk of \(data.count) bytes (total: \(bytesReceived))")
        #endif
        
        // Pass the data to the loading request
        loadingRequest.dataRequest?.respond(with: data)
        
        // DO NOT call finishLoading() - we want to keep the connection open for streaming
    }
    
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }
}
