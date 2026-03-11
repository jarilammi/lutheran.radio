//
//  StreamingSessionDelegate.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 4.3.2025.
//

import Foundation
import AVFoundation
@preconcurrency import Security

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
final class StreamingSessionDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    
    /// The AVAssetResourceLoadingRequest being fulfilled by this delegate.
    internal var loadingRequest: AVAssetResourceLoadingRequest
    
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
    
    // MARK: - Modern async delegate (WWDC 2025 / Swift 6 recommendation)
    
    /// Handles server trust authentication challenges using the 2026 async API.
    /// Delegates validation to CertificateValidator (now actor-isolated + async).
    /// On failure, immediately notifies the AVAssetResourceLoadingRequest (exact same behaviour as before).
    nonisolated func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        
        let isValid = await CertificateValidator.shared.validateServerTrust(serverTrust)
        
        if isValid {
            return (.useCredential, URLCredential(trust: serverTrust))
        } else {
            #if DEBUG
            print("🔒 [StreamingSessionDelegate] Certificate validation failed – cancelling stream")
            #endif
            self.onError?(URLError(.serverCertificateUntrusted))
            self.loadingRequest.finishLoading(with: URLError(.serverCertificateUntrusted))
            return (.cancelAuthenticationChallenge, nil)
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
        #if DEBUG
        if let httpResponse = response as? HTTPURLResponse {
            print("📡 [StreamingDelegate] Received response: \(httpResponse.statusCode) – Content-Type: \(httpResponse.allHeaderFields["Content-Type"] ?? "nil")")
        }
        #endif
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
        if let urlError = error as? URLError, urlError.code == .cancelled {
            // Cancelled → treat as clean EOF (common practice for live streams)
            #if DEBUG
            print("📡 [StreamingDelegate] Task cancelled → finishLoading() (clean EOF)")
            #endif
            loadingRequest.finishLoading()
        } else if let error = error {
            #if DEBUG
            print("❌ [StreamingDelegate] Task completed with error: \(error.localizedDescription)")
            #endif
            onError?(error)
            loadingRequest.finishLoading(with: error)
        } else {
            #if DEBUG
            print("✅ [StreamingDelegate] Task completed successfully – finishLoading()")
            #endif
            loadingRequest.finishLoading()
        }
    }
    
    /// Deinitializer to ensure cleanup on deallocation.
    deinit {
        cancel()
    }
}
