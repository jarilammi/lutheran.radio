//
//  StreamingSessionDelegate.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 4.3.2025.
//

import Foundation
import AVFoundation

/// Custom URLSession delegate for managing audio streaming sessions with integrated SSL certificate pinning validation.
///
/// This class handles data tasks for streaming audio content using AVFoundation, ensuring secure connections through
/// runtime certificate validation. It acts as a bridge between AVAssetResourceLoadingRequest and URLSession, processing
/// incoming data and responding to the loading request.
///
/// Key Features:
/// - Implements `URLSessionDataDelegate` for handling streaming data in chunks.
/// - Implements `URLSessionDelegate` for server trust challenges, deferring to `CertificateValidator` for pinning checks.
/// - Supports cancellation of ongoing sessions.
/// - Logs debug information in DEBUG builds for troubleshooting.
/// - Handles HTTP responses, content types, and errors appropriately for streaming.
///
/// Usage:
/// - Initialize with an `AVAssetResourceLoadingRequest` from AVFoundation.
/// - Set as the delegate for a URLSession handling streaming requests.
/// - Call `cancel()` to stop ongoing data tasks and invalidate the session.
class StreamingSessionDelegate: NSObject, URLSessionDataDelegate {
    
    /// The AVAssetResourceLoadingRequest being fulfilled by this delegate.
    private var loadingRequest: AVAssetResourceLoadingRequest
    
    /// Tracks the total bytes received during the streaming session.
    private var bytesReceived = 0
    
    /// Flag indicating if an HTTP response has been received.
    private var receivedResponse = false
    
    /// The URLSession instance managing the data task.
    var session: URLSession?
    
    /// The active URLSessionDataTask for streaming.
    var dataTask: URLSessionDataTask?
    
    /// Optional callback for error handling during the session.
    var onError: ((Error) -> Void)?
    
    /// The original hostname for SSL validation (used in certificate pinning).
    var originalHostname: String?
    
    /// Timestamp when the connection started (for debugging/performance tracking).
    private let connectionStartTime = Date()
    
    /// Initializes the delegate with the given loading request.
    ///
    /// - Parameter loadingRequest: The AVAssetResourceLoadingRequest to fulfill.
    init(loadingRequest: AVAssetResourceLoadingRequest) {
        self.loadingRequest = loadingRequest
        super.init()
        #if DEBUG
        print("🔒 [SSL Debug] StreamingSessionDelegate initialized")
        #endif
    }
    
    /// Cancels the ongoing data task and invalidates the session.
    func cancel() {
        dataTask?.cancel()
        session?.invalidateAndCancel()
        session = nil
        dataTask = nil
    }
    
    /// Handles server trust authentication challenges.
    ///
    /// This method is called when a server trust challenge occurs. It uses `CertificateValidator` to validate the trust,
    /// and either proceeds with the credential or cancels the challenge (triggering an error).
    ///
    /// - Parameters:
    ///   - session: The URLSession instance.
    ///   - challenge: The authentication challenge.
    ///   - completionHandler: Callback to disposition the challenge (use credential or cancel).
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        CertificateValidator.shared.validateServerTrust(serverTrust) { isValid in
            if isValid {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                self.onError?(URLError(.serverCertificateUntrusted))
                self.loadingRequest.finishLoading(with: URLError(.serverCertificateUntrusted))
            }
        }
    }
    
    /// Handles receipt of the HTTP response.
    ///
    /// Validates the response status code, sets content information on the loading request, and decides whether to allow
    /// or cancel the response disposition.
    ///
    /// - Parameters:
    ///   - session: The URLSession instance.
    ///   - dataTask: The data task that received the response.
    ///   - response: The URLResponse received.
    ///   - completionHandler: Callback to allow or cancel the response.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let statusCode = httpResponse.statusCode
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
    
    /// Handles incoming data from the streaming task.
    ///
    /// Responds to the loading request with the received data chunk, but only if a valid response has been received.
    ///
    /// - Parameters:
    ///   - session: The URLSession instance.
    ///   - dataTask: The data task that received the data.
    ///   - data: The data chunk received.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard receivedResponse else { return }
        bytesReceived += data.count
        loadingRequest.dataRequest?.respond(with: data)
    }
    
    /// Handles completion of the data task.
    ///
    /// Finishes the loading request with success or error, and invokes the onError callback if applicable.
    ///
    /// - Parameters:
    ///   - session: The URLSession instance.
    ///   - task: The completed task.
    ///   - error: Optional error from the task.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            onError?(error)
            loadingRequest.finishLoading(with: error)
        } else {
            loadingRequest.finishLoading()
        }
    }
    
    /// Deinitializer to ensure cleanup on deallocation.
    deinit {
        cancel()
    }
}
