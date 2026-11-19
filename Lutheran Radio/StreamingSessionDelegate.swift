//
//  StreamingSessionDelegate.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 4.3.2025.
//

import Foundation
import AVFoundation
@unsafe @preconcurrency import Security
import Core

/// Custom URLSession delegate for the Icecast resource loader.
///
/// AVFoundation asks this delegate for media bytes. The session follows redirects,
/// and ATS `NSPinnedDomains` covers only the media apex, so the TLS challenge
/// must name the host. An empty host cancels. Any other server trust goes through
/// ``CertificateValidator/validateStreamingServerTrust(_:host:)`` (media SPKI,
/// then the leaf digest). ``CertificateValidator/validateServerTrust(_:)`` alone
/// can accept an unpinned leaf during the transition window.
///
/// Key Features:
/// - Implements `URLSessionDataDelegate` for handling streaming data in chunks.
/// - Implements `URLSessionTaskDelegate` for server-trust challenges.
/// - Supports cancellation of ongoing sessions.
/// - Logs debug information in DEBUG builds for troubleshooting.
/// - Handles HTTP responses, content types, and errors appropriately for streaming.
///
/// - SeeAlso: ``CertificateValidator/validateStreamingServerTrust(_:host:)``,
///   ``<doc:Security-Invariants>`` Invariant 3
///
/// Usage:
/// - Initialize with an `AVAssetResourceLoadingRequest` from AVFoundation.
/// - Set as the delegate for a URLSession handling streaming requests.
/// - Call `cancel()` to stop ongoing data tasks and invalidate the session.
final class StreamingSessionDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    
    /// The AVAssetResourceLoadingRequest being fulfilled by this delegate.
    internal var loadingRequest: AVAssetResourceLoadingRequest
    
    /// Flag indicating if an HTTP response has been received.
    private var receivedResponse = false
    
    /// The URLSession instance managing the data task.
    var session: URLSession?
    
    /// The active URLSessionDataTask for streaming.
    var dataTask: URLSessionDataTask?
    
    /// Optional callback for error handling during the session.
    var onError: ((Error) -> Void)?

    /// When set, one pre-response failure may start a replacement task before the loading request finishes.
    ///
    /// Return `true` when a new task is running. `nil` keeps completion synchronous for existing callers.
    /// The closure is `@Sendable` because completion hops off the delegate queue to await address verification.
    var retryBeforeResponse: (@Sendable (NSError) async -> Bool)?

    /// The one pre-response retry has been offered. A second failure finishes the loading request.
    private var attemptedPreResponseRetry = false
    
    /// Initializes the delegate with the given loading request.
    ///
    /// - Parameter loadingRequest: The AVAssetResourceLoadingRequest to fulfill.
    init(loadingRequest: AVAssetResourceLoadingRequest) {
        self.loadingRequest = loadingRequest
        super.init()
        #if DEBUG
        print("[StreamingSessionDelegate] [SSL Debug] StreamingSessionDelegate initialized")
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
    
    /// Handles the Icecast resource-loader TLS challenge.
    ///
    /// An empty host cancels. This session follows redirects, and ATS
    /// `NSPinnedDomains` covers only the media apex, so a missing name must
    /// not fall through to the leaf check. Any other server trust calls
    /// ``CertificateValidator/validateStreamingServerTrust(_:host:)``, which
    /// requires ``SecurityConfiguration/pinnedMediaLeafSPKISHA256Base64`` for a
    /// host under ``preferredStreamingDomainSuffixes`` before the leaf digest.
    /// A failure reports ``URLError.serverCertificateUntrusted``, finishes the
    /// loading request, and cancels the challenge. A challenge that is not
    /// server trust keeps default handling.
    ///
    /// - Parameters:
    ///   - session: Resource-loader session. The decision does not read it.
    ///   - task: Task that received the challenge. The decision does not read it.
    ///   - challenge: URLSession server-trust challenge, including the peer name.
    /// - Returns: Use-credential when the host and pins accept the trust; cancel
    ///   when the host is empty or the pins reject it; default handling otherwise.
    /// - SeeAlso: ``CertificateValidator/validateStreamingServerTrust(_:host:)``,
    ///   ``<doc:Security-Invariants>`` Invariant 3
    nonisolated func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }

        // An empty host is not a protected streaming name. Fail closed rather
        // than accepting the leaf pin with no SPKI host check.
        let host = challenge.protectionSpace.host
        guard !host.isEmpty else {
            return (.cancelAuthenticationChallenge, nil)
        }

        let isValid = await CertificateValidator.shared.validateStreamingServerTrust(serverTrust, host: host)

        if isValid {
            return (.useCredential, URLCredential(trust: serverTrust))
        } else {
            #if DEBUG
            print("[StreamingSessionDelegate] Certificate validation failed – cancelling stream")
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
            print("[StreamingSessionDelegate] [StreamingDelegate] Received response: \(httpResponse.statusCode) – Content-Type: \(httpResponse.allHeaderFields["Content-Type"] ?? "nil")")
        }
        #endif
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let statusCode = httpResponse.statusCode
        
        // HTTP 403 on a stream URL that already carries the embedded model excludes
        // that production cluster for this process. One other cluster may be tried.
        // When none remain, visual and intent lock. A 403 whose query is not the
        // embedded model still takes the older visual lock (`setSecurityLocked`).
        // SECURITY: the query value is never replaced with a previous model name.
        if statusCode == 403, let requestURL = self.loadingRequest.request.url {
            let disposition = DirectStreamingPlayer.shared.noteEmbeddedSecurityModelRejection(
                url: requestURL,
                statusCode: statusCode
            )
            switch disposition {
            case .notThisFailure:
                if requestURL.query?.contains("security_model=") == true {
                    #if DEBUG
                    print("[StreamingSessionDelegate] Server returned 403 on security_model= URL that is not the embedded model → visual security lock")
                    #endif
                    Task { @MainActor in
                        await SharedPlayerManager.shared.setSecurityLocked()
                    }
                    loadingRequest.finishLoading(with: URLError(.badServerResponse))
                    completionHandler(.cancel)
                    return
                }
            case .failoverOnce(_):
                #if DEBUG
                print("[StreamingSessionDelegate] Embedded-model 403 → one failover onto the other cluster")
                #endif
                loadingRequest.finishLoading(with: URLError(.badServerResponse))
                completionHandler(.cancel)
                Task { @MainActor in
                    await DirectStreamingPlayer.shared.performEmbeddedSecurityModelClusterFailover()
                }
                return
            case .waitForInFlightFailover:
                #if DEBUG
                print("[StreamingSessionDelegate] Embedded-model 403 → failover already scheduled; not opening this cluster again")
                #endif
                loadingRequest.finishLoading(with: URLError(.badServerResponse))
                completionHandler(.cancel)
                return
            case .terminalLock:
                #if DEBUG
                print("[StreamingSessionDelegate] Embedded-model 403 → no production cluster remains")
                #endif
                loadingRequest.finishLoading(with: URLError(.badServerResponse))
                completionHandler(.cancel)
                Task { @MainActor in
                    await DirectStreamingPlayer.shared.finishBecauseEveryProductionClusterRejectedEmbeddedSecurityModel()
                }
                return
            }
        }
        
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
            print("[StreamingSessionDelegate] [StreamingDelegate] Task cancelled → finishLoading() (clean EOF)")
            #endif
            loadingRequest.finishLoading()
        } else if let error = error {
            #if DEBUG
            print("[StreamingSessionDelegate] [StreamingDelegate] Task completed with error: \(error.localizedDescription)")
            #endif
            if !receivedResponse, !attemptedPreResponseRetry, retryBeforeResponse != nil {
                attemptedPreResponseRetry = true
                let queue = OperationQueue.current
                // NSError is Sendable. The hop back onto the delegate queue finishes the loading request.
                let nsError = error as NSError
                Task { [weak self] in
                    guard let self else { return }
                    let retried = await self.retryBeforeResponse?(nsError) ?? false
                    let finish: @Sendable () -> Void = { [weak self] in
                        guard let self else { return }
                        if !retried {
                            self.onError?(nsError)
                            self.loadingRequest.finishLoading(with: nsError)
                        }
                    }
                    if let queue {
                        queue.addOperation(finish)
                    } else {
                        DispatchQueue.main.async(execute: finish)
                    }
                }
                return
            }
            onError?(error)
            loadingRequest.finishLoading(with: error)
        } else {
            #if DEBUG
            print("[StreamingSessionDelegate] [StreamingDelegate] Task completed successfully – finishLoading()")
            #endif
            loadingRequest.finishLoading()
        }
    }
    
    /// Deinitializer to ensure cleanup on deallocation.
    deinit {
        cancel()
    }
}
