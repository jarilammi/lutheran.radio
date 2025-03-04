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
                print("📡 Streaming task failed: \(error.localizedDescription)")
                // Log pinning failure for debugging
                if let urlError = error as? URLError, urlError.code == .serverCertificateUntrusted {
                    print("🔒 Pinning failure detected: Certificate untrusted")
                }
                onError?(error) // Notify DirectStreamingPlayer of the error
                loadingRequest?.finishLoading(with: error)
            } else {
                print("📡 Streaming task cancelled")
            }
        } else {
            print("📡 Streaming task completed normally")
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
    
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }
}
