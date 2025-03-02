//
//  DirectStreamingPlayer.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 25.2.2025.
//

import Foundation
import Security
import CommonCrypto
import AVFoundation

class DirectStreamingPlayer: NSObject {
    struct Stream {
        let title: String
        let url: URL
        let language: String
        let languageCode: String
    }

    static let availableStreams = [
        Stream(title: NSLocalizedString("lutheran_radio_title", comment: "Title for Lutheran Radio") + " - " +
               NSLocalizedString("language_english", comment: "English language option"),
               url: URL(string: "https://liveenglish.lutheran.radio:8443/english/stream.mp3")!,
               language: NSLocalizedString("language_english", comment: "English language option"),
               languageCode: "en"),
        Stream(title: NSLocalizedString("lutheran_radio_title", comment: "Title for Lutheran Radio") + " - " +
               NSLocalizedString("language_finnish", comment: "Finnish language option"),
               url: URL(string: "https://livestream.lutheran.radio:8443/lutheranradio.mp3")!,
               language: NSLocalizedString("language_finnish", comment: "Finnish language option"),
               languageCode: "fi"),
        Stream(title: NSLocalizedString("lutheran_radio_title", comment: "Title for Lutheran Radio") + " - " +
               NSLocalizedString("language_swedish", comment: "Swedish language option"),
               url: URL(string: "https://liveswedish.lutheran.radio:8443/swedish/stream.mp3")!,
               language: NSLocalizedString("language_swedish", comment: "Swedish language option"),
               languageCode: "sv")
    ]
    
    public enum PlaybackState {
            case unknown
            case readyToPlay
            case failed(Error?)
        }
    
    private var lastError: Error?
    
    public func getPlaybackState() -> PlaybackState {
        switch playerItem?.status {
        case .unknown:
            return .unknown
        case .readyToPlay:
            return .readyToPlay
        case .failed:
            return .failed(playerItem?.error)
        default:
            return .unknown
        }
    }
    
    // Current selected stream
    private var selectedStream: Stream {
        didSet {
            // Update metadata when stream changes
            onMetadataChange?(selectedStream.title)
        }
    }
    
    // Player components
    var player: AVPlayer?
    var playerItem: AVPlayerItem?
    var hasPermanentError: Bool = false
    private var statusObserver: NSKeyValueObservation?
    private var timeObserver: Any?
    
    // Keep track of which observers are active
    private var isObservingBuffer = false
    
    // Certificate pinning hash
    private let pinnedPublicKeyHash = "rMadBtyLpBp0ybRQW6+WGcFm6wGG7OldSI6pA/eRVQy/xnpjBsDu897E1HcGZPB+mZQhUkfswZVVvWF9YPALFQ=="
    private let pinningDelegate = CertificatePinningDelegate()
    private var securityLockActive = false
    
    // Status callbacks
    var onStatusChange: ((Bool, String) -> Void)?
    var onMetadataChange: ((String?) -> Void)?
    
    override init() {
        let currentLocale = Locale.current
        let languageCode = currentLocale.language.languageCode?.identifier
        
        if let stream = DirectStreamingPlayer.availableStreams.first(where: { $0.languageCode == languageCode }) {
            selectedStream = stream
        } else {
            selectedStream = DirectStreamingPlayer.availableStreams[0] // Default to English
        }
        super.init()
        setupAudioSession()
        pinningDelegate.onPinningFailure = { [weak self] in
            self?.handleSecurityFailure()
        }
    }
    
    func handleSecurityFailure() {
        // Lock streaming for security reasons
        securityLockActive = true
        
        // Stop any current playback
        stop()
        
        // Notify UI of security issue
        onStatusChange?(false, "Connection cannot be verified. Please try again later.")
    }
    
    func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            
            // First deactivate any existing session
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            
            // Basic configuration for streaming audio
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            
            print("🔊 Audio session successfully configured")
        } catch {
            print("🔊 Audio session setup failed: \(error.localizedDescription)")
        }
    }
    
    func play(completion: @escaping (Bool) -> Void) {
        if securityLockActive {
            onStatusChange?(false, "Connection cannot be verified. Please try again later.")
            return
        }
        stop()
        hasPermanentError = false // Reset on each play attempt
        print("▶️ Starting direct playback for \(selectedStream.language)")

        let asset = AVURLAsset(url: selectedStream.url)
        asset.resourceLoader.setDelegate(self, queue: DispatchQueue(label: "radio.lutheran.resourceloader"))
        playerItem = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: playerItem)
        addObservers()
        player?.play()

        var tempStatusObserver: NSKeyValueObservation?
        tempStatusObserver = playerItem?.observe(\.status, options: [.new]) { item, _ in
            if item.status == .readyToPlay {
                completion(true)
                tempStatusObserver?.invalidate()
            } else if item.status == .failed {
                completion(false)
                tempStatusObserver?.invalidate()
            }
        }
    }
    
    func setStream(to stream: Stream) {
        stop() // Stop current playback
        selectedStream = stream
        play { [weak self] success in
            if success {
                print("Stream switched successfully")
                self?.onStatusChange?(true, String(localized: "status_playing"))
            } else {
                print("Failed to switch stream")
                self?.onStatusChange?(false, String(localized: "status_stream_unavailable"))
            }
        }
    }
    
    private func addObservers() {
        statusObserver = playerItem?.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                print("🎵 Player item status: \(item.status.rawValue)")
                switch item.status {
                case .readyToPlay:
                    print("🎵 Player item ready to play!")
                    self.onStatusChange?(true, String(localized: "status_playing"))
                case .failed:
                    let errorMessage = item.error?.localizedDescription ?? "unknown error"
                    print("🎵 Player item failed: \(errorMessage)")
                    self.lastError = item.error
                    if let error = item.error as NSError?, error.domain == NSURLErrorDomain && error.code == -1003 {
                        print("📡 Permanent error detected: DNS resolution failed")
                        self.hasPermanentError = true
                        self.onStatusChange?(false, String(localized: "status_stream_unavailable"))
                    } else {
                        self.onStatusChange?(false, String(localized: "status_buffering"))
                    }
                    self.removeObservers() // Remove observers instead of calling stop()
                    if let error = item.error as NSError? {
                        print("🎵 Error details - Domain: \(error.domain), Code: \(error.code)")
                    }
                case .unknown:
                    self.onStatusChange?(false, String(localized: "status_buffering"))
                @unknown default:
                    break
                }
            }
        }
        
        // Add KVO observers safely
        if let playerItem = playerItem {
            playerItem.addObserver(self, forKeyPath: "playbackBufferEmpty", options: .new, context: nil)
            playerItem.addObserver(self, forKeyPath: "playbackLikelyToKeepUp", options: .new, context: nil)
            playerItem.addObserver(self, forKeyPath: "playbackBufferFull", options: .new, context: nil)
            isObservingBuffer = true
        }
        
        // Time observer to check if playback is actually progressing
        let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            if self?.player?.rate ?? 0 > 0 {
                // Player is playing
                self?.onStatusChange?(true, String(localized: "status_playing"))
            }
        }
        
        // Add metadata observation
        let metadataOutput = AVPlayerItemMetadataOutput(identifiers: nil)
        metadataOutput.setDelegate(self, queue: .main)
        playerItem?.add(metadataOutput)
    }
    
    // Handle KVO notifications for buffering state
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard let keyPath = keyPath, let playerItem = object as? AVPlayerItem else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if keyPath == "playbackBufferEmpty" {
                if playerItem.isPlaybackBufferEmpty {
                    print("⏳ Playback buffer is empty - buffering...")
                    self.onStatusChange?(false, String(localized: "status_buffering"))
                }
            } else if keyPath == "playbackLikelyToKeepUp" {
                if playerItem.isPlaybackLikelyToKeepUp && playerItem.status == .readyToPlay {
                    print("✅ Playback is likely to keep up - ready to play")
                    self.player?.play()
                    self.onStatusChange?(true, String(localized: "status_playing"))
                }
            } else if keyPath == "playbackBufferFull" {
                if playerItem.isPlaybackBufferFull {
                    print("✅ Playback buffer is full")
                    self.player?.play()
                    self.onStatusChange?(true, String(localized: "status_playing"))
                }
            }
        }
    }
    
    private func removeObservers() {
        // Remove status observer
        statusObserver?.invalidate()
        statusObserver = nil
        
        // Remove time observer
        if let timeObserver = timeObserver, let player = player {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        
        // Only try to remove KVO observers if we added them
        if isObservingBuffer, let playerItem = playerItem {
            // Remove observers with safety checks
            playerItem.removeObserver(self, forKeyPath: "playbackBufferEmpty")
            playerItem.removeObserver(self, forKeyPath: "playbackLikelyToKeepUp")
            playerItem.removeObserver(self, forKeyPath: "playbackBufferFull")
            isObservingBuffer = false
            print("📊 Removed buffer observers successfully")
        }
    }
    
    func isLastErrorPermanent() -> Bool {
        if let error = lastError as NSError?, error.domain == NSURLErrorDomain && error.code == -1003 {
            return true
        }
        return false
    }
    
    func stop() {
        removeObservers()
        player?.pause()
        player = nil
        playerItem = nil
        if !hasPermanentError {
            onStatusChange?(false, String(localized: "status_stopped"))
        }
    }
    
    deinit {
        stop()
    }
}


// MARK: - Metadata Handling
extension DirectStreamingPlayer: AVPlayerItemMetadataOutputPushDelegate {
    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                       didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                       from track: AVPlayerItemTrack?) {
        
        guard let item = groups.first?.items.first,
              let value = item.value(forKeyPath: "stringValue") as? String,
              !value.isEmpty else { return }
        
        let songTitle = (item.identifier == AVMetadataIdentifier("icy/StreamTitle") ||
                       (item.key as? String) == "StreamTitle") ? value : nil
        
        onMetadataChange?(songTitle)
    }
}

extension DirectStreamingPlayer {
    func handleNetworkInterruption() {
        // Reset player and observers in case they're in a bad state
        stop()
        
        // Add a small delay before returning to ready state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.onStatusChange?(false, String(localized: "alert_retry"))
        }
    }
}

// MARK: - DirectStreamingPlayer Extension
extension DirectStreamingPlayer {
    func setVolume(_ volume: Float) {
        player?.volume = volume
    }
}

extension DirectStreamingPlayer: AVAssetResourceLoaderDelegate {
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                       shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url else {
            loadingRequest.finishLoading(with: NSError(domain: "radio.lutheran", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return false
        }

        let sessionConfig = URLSessionConfiguration.default
        let session = URLSession(configuration: sessionConfig, delegate: pinningDelegate, delegateQueue: nil)
        let streamingDelegate = StreamingSessionDelegate(loadingRequest: loadingRequest, pinningDelegate: pinningDelegate)
        streamingDelegate.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.handleLoadingError(error)
            }
        }
        
        let task = session.dataTask(with: url)
        task.delegate = streamingDelegate
        task.resume()
        return true
    }
    
    private func handleLoadingError(_ error: Error) {
        print("📡 Loading error: \(error.localizedDescription)")
        if let nsError = error as NSError?, nsError.domain == NSURLErrorDomain, nsError.code == -1003 {
            print("📡 DNS resolution failed")
            hasPermanentError = true
        }
        onStatusChange?(false, String(localized: "status_stream_unavailable"))
        stop()
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                       didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        // Handle cancellation if needed
        print("Resource loading cancelled")
    }
}
