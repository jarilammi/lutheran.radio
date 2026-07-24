//
//  DirectStreamingPlayer+ResourceLoader.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 24.7.2026.
//
//  AVAssetResourceLoaderDelegate for lutheran.radio HTTPS: DNSSEC sessions, StreamingSessionDelegate, Icecast headers, and loading-request hard timeout.
//
//  Behavior-preserving domain split from DirectStreamingPlayer.swift.
//  DirectStreamingPlayer remains the public façade; this file owns one domain.
//
//  AGENT NOTE: Members used across files are `internal` (Swift `private` is
//  file-scoped). Prefer this domain file over re-implementing attach / recovery
//  / catalog logic in call sites.
//
//  - SeeAlso: DirectStreamingPlayer.swift, StreamingSessionDelegate.swift, SecurityConfiguration.makeSecureEphemeralConfiguration(),
//    CODING_AGENT.md (Single Source of Truth Principles).
//

import Foundation
import Core
import WidgetSurface
@unsafe @preconcurrency import AVFoundation

// MARK: - Extensions for Delegates and Helpers
/// Handles custom resource loading for secure streaming.
///
/// All actual data transport for lutheran.radio hosts goes through URLSessions
/// configured via ``SecurityConfiguration/makeSecureEphemeralConfiguration()`` (DNSSEC
/// + cache hardening). The resource loader exists to let us supply our own
/// `URLSession` + `StreamingSessionDelegate` (which in turn uses `CertificateValidator`
/// for the TLS challenge). This gives us full control over both DNSSEC resolution
/// and certificate pinning for the media bytes.
///
/// - Note: We do **not** use a custom URL scheme for the AVURLAsset itself
///   (previous attempts were removed for simplicity). The DNS resolution that
///   matters (the one that actually carries audio) is the one performed by the
///   controlled `URLSession` inside `shouldWaitForLoadingOfRequestedResource`.
extension DirectStreamingPlayer: AVAssetResourceLoaderDelegate {
    /// Determines if the loader should handle the request.
    /// - Parameters:
    ///   - resourceLoader: The requesting loader.
    ///   - loadingRequest: The resource request.
    /// - Returns: `true` if handling (for lutheran.radio HTTPS URLs).
    /// - Note: Enforces HTTPS and domain checks; sets up pinned + DNSSEC-protected sessions.
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url else {
            #if DEBUG
            print("[DirectStreamingPlayer] [Resource Loader] No URL in loading request")
            #endif
            loadingRequest.finishLoading(with: NSError(domain: "radio.lutheran", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return false
        }
        
        #if DEBUG
        print("[DirectStreamingPlayer] [Resource Loader] ===== NEW REQUEST =====")
        print("[DirectStreamingPlayer] [Resource Loader] Received URL: \(url)")
        print("[DirectStreamingPlayer] [Resource Loader] URL scheme: \(url.scheme ?? "nil")")
        print("[DirectStreamingPlayer] [Resource Loader] URL host: \(url.host ?? "nil")")
        #endif
        
        // FIXED: Only handle HTTPS URLs for lutheran.radio domains
        guard url.scheme == "https",
              let host = url.host,
              host.hasSuffix("lutheran.radio") else {
            #if DEBUG
            print("[DirectStreamingPlayer] [Resource Loader] Not a lutheran.radio HTTPS URL, letting system handle it")
            #endif
            return false  // Let the system handle non-lutheran.radio URLs
        }
        
        // Store the original hostname for SSL validation
        let originalHostname = host
        #if DEBUG
        print("[DirectStreamingPlayer] [Resource Loader] Handling lutheran.radio HTTPS URL: \(url)")
        print("[DirectStreamingPlayer] [Resource Loader] Original hostname for SSL: \(originalHostname)")
        #endif
        
        // Create clean request with the HTTPS URL (no conversion needed)
        var modifiedRequest = URLRequest(url: url)
        modifiedRequest.timeoutInterval = 60.0
        
        // Apply Icecast/Liquidsoap compatibility headers (centralised & future-proof)
        modifiedRequest = self.requestWithIcecastHeaders(from: modifiedRequest)
        
        #if DEBUG
        print("[DirectStreamingPlayer] [Resource Loader] Final request headers: \(modifiedRequest.allHTTPHeaderFields ?? [:])")
        #endif
        
        // Create streaming delegate
        let streamingDelegate = StreamingSessionDelegate(loadingRequest: loadingRequest)
        streamingDelegate.originalHostname = originalHostname
        
        #if DEBUG
        print("[DirectStreamingPlayer] [Resource Loader] StreamingSessionDelegate created for hostname: \(originalHostname)")
        #endif
        
        // Enhanced configuration for SSL pinning + DNSSEC-protected name resolution.
        // All policy for secure networking flows through SecurityConfiguration (Core/ single source of truth).
        let config = SecurityConfiguration.makeSecureEphemeralConfiguration()
        config.timeoutIntervalForRequest = 60.0
        config.timeoutIntervalForResource = 120.0
        
        // Additional streaming-specific tunables (DNSSEC + cache hardening already applied by factory).
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 1
        
        let operationQueue = OperationQueue()
        operationQueue.qualityOfService = .userInitiated
        operationQueue.maxConcurrentOperationCount = 1
        
        #if DEBUG
        print("[DirectStreamingPlayer] [Resource Loader] Creating URLSession with SSL-forcing config")
        #endif
        
        streamingDelegate.session = URLSession(configuration: config,
                                               delegate: streamingDelegate,
                                               delegateQueue: operationQueue)
        
        streamingDelegate.dataTask = streamingDelegate.session?.dataTask(with: modifiedRequest)
        
        streamingDelegate.onError = { [weak self, weak streamingDelegate] error in
            guard let self = self, let delegate = streamingDelegate else { return }
            
            #if DEBUG
            print("[DirectStreamingPlayer] [Resource Loader] Streaming error occurred: \(error.localizedDescription)")
            #endif
            
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.activeResourceLoaders.removeValue(forKey: delegate.loadingRequest)
                self.loadingTimeoutWorkItem?.cancel()
                if self.currentLoadingDelegate === delegate {
                    self.currentLoadingDelegate = nil
                }
                
                // Early-window transients recover via secured recreate without full stop.
                // Permanent and post-window failures go through handleLoadingError.
                let errType = StreamErrorType.from(error: error)
                if !errType.isPermanent {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if await self.attemptEarlyWindowTransientRecovery(
                            reason: "resourceLoader-transient",
                            allowWhileDeferringFirstPlayKick: true
                        ) {
                            return
                        }
                        await self.handleLoadingError(error)
                    }
                    return
                }
                
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.handleLoadingError(error)
                }
            }
        }
        
        activeResourceLoaders[loadingRequest] = streamingDelegate
        
        #if DEBUG
        print("[DirectStreamingPlayer] [Resource Loader] Starting data task with Icecast-compatible headers…")
        #endif
        streamingDelegate.dataTask?.resume()
        self.currentLoadingDelegate = streamingDelegate
        self.startLoadingRequestTimeout(for: streamingDelegate)
        
        #if DEBUG
        print("[DirectStreamingPlayer] [Resource Loader] Resource loader setup complete")
        print("[DirectStreamingPlayer] [Resource Loader] ===== END REQUEST SETUP =====")
        #endif
        
        return true
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        #if DEBUG
        print("[DirectStreamingPlayer] [SSL Debug] Resource loading cancelled for request")
        #endif
        
        if let delegate = activeResourceLoaders.removeValue(forKey: loadingRequest) {
            delegate.cancel()
            loadingTimeoutWorkItem?.cancel()
            if currentLoadingDelegate === delegate {
                currentLoadingDelegate = nil
            }
        }
    }
}

// MARK: - Icecast / Liquidsoap Compatibility
extension DirectStreamingPlayer {
    /// Adds headers required by Icecast2 and Liquidsoap servers.
    /// Must be called for every AVAssetResourceLoadingRequest before creating the URLSession data task.
    /// - Parameter originalRequest: The request coming from AVFoundation.
    /// - Returns: A new request with the mandatory Icecast headers.
    func requestWithIcecastHeaders(from originalRequest: URLRequest) -> URLRequest {
        var request = originalRequest
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        request.setValue("Lutheran Radio/2.0 (iOS; LutheranRadioApp)", forHTTPHeaderField: "User-Agent")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        return request
    }
}


extension DirectStreamingPlayer {
    // MARK: - Loading Request Hard Timeout (prevents eternal .unknown status)

    func startLoadingRequestTimeout(for delegate: StreamingSessionDelegate) {
        loadingTimeoutWorkItem?.cancel()
        
        let work = DispatchWorkItem { [weak self, weak delegate] in
            guard let self = self,
                  let delegate = delegate,
                  !delegate.loadingRequest.isFinished else { return }
            
            #if DEBUG
            print("⏰ [Hard Timeout] Completing hung loading request after 15s – this should never happen only on unresponsive servers")
            #endif
            
            delegate.loadingRequest.finishLoading(with: URLError(.timedOut))
            // Note: no need to call delegate.onError – finishLoading(with:) already triggers failure path
            self.activeResourceLoaders.removeValue(forKey: delegate.loadingRequest)
            self.currentLoadingDelegate = nil
        }
        
        loadingTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: work)
    }
}
