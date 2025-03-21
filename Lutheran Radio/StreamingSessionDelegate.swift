//
//  StreamingSessionDelegate.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 4.3.2025.
//

import Foundation
import AVFoundation

class StreamingSessionDelegate: NSObject, URLSessionDelegate, URLSessionDataDelegate {
    private weak var loadingRequest: AVAssetResourceLoadingRequest?
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
                // Log pinning failure for debugging
                if let urlError = error as? URLError, urlError.code == .serverCertificateUntrusted {
                    #if DEBUG
                    print("🔒 Pinning failure detected: Certificate untrusted")
                    #endif
                }
                onError?(error) // Notify DirectStreamingPlayer of the error
                loadingRequest?.finishLoading(with: error)
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
        guard let loadingRequest = loadingRequest,
              let httpResponse = response as? HTTPURLResponse else {
            #if DEBUG
            print("📡 Failed to process response: invalid loading request or response type")
            #endif
            completionHandler(.cancel)
            return
        }
        
        #if DEBUG
        print("📡 Received HTTP response with status code: \(httpResponse.statusCode)")
        #endif
        
        let statusCode = httpResponse.statusCode
        if (400...599).contains(statusCode) {
            let error: URLError.Code
            switch statusCode {
            case 502:
                error = .badServerResponse
                #if DEBUG
                print("📡 Detected 502 Bad Gateway - treating as permanent error")
                #endif
                onError?(URLError(error))
                loadingRequest.finishLoading(with: URLError(error))
                completionHandler(.cancel)
                return
            case 404: // Not Found
                error = .fileDoesNotExist
                onError?(URLError(error))
                loadingRequest.finishLoading(with: URLError(error))
                completionHandler(.cancel)
                return
            case 403: // Forbidden
                error = .resourceUnavailable // Using this as a reasonable proxy for permission denial
                #if DEBUG
                print("📡 Detected 403 Forbidden - treating as permanent error")
                #endif
                onError?(URLError(error))
                loadingRequest.finishLoading(with: URLError(error))
                completionHandler(.cancel)
                return
            default:
                #if DEBUG
                print("📡 Unhandled HTTP status code: \(statusCode)")
                #endif
            }
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
        guard let loadingRequest = loadingRequest, receivedResponse else {
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
