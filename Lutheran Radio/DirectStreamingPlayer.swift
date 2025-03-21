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
        let flag: String
    }

    static let availableStreams = [
        Stream(title: NSLocalizedString("lutheran_radio_title", comment: "Title for Lutheran Radio") + " - " +
               NSLocalizedString("language_english", comment: "English language option"),
               url: URL(string: "https://liveenglish.lutheran.radio:8443/lutheranradio.mp3")!,
               language: NSLocalizedString("language_english", comment: "English language option"),
               languageCode: "en",
               flag: "🇺🇸"),
        Stream(title: NSLocalizedString("lutheran_radio_title", comment: "Title for Lutheran Radio") + " - " +
               NSLocalizedString("language_german", comment: "German language option"),
               url: URL(string: "https://livedeutsch.lutheran.radio:8443/lutheranradio.mp3")!,
               language: NSLocalizedString("language_german", comment: "German language option"),
               languageCode: "de",
               flag: "🇩🇪"),
        Stream(title: NSLocalizedString("lutheran_radio_title", comment: "Title for Lutheran Radio") + " - " +
               NSLocalizedString("language_finnish", comment: "Finnish language option"),
               url: URL(string: "https://livefinnish.lutheran.radio:8443/lutheranradio.mp3")!,
               language: NSLocalizedString("language_finnish", comment: "Finnish language option"),
               languageCode: "fi",
               flag: "🇫🇮"),
        Stream(title: NSLocalizedString("lutheran_radio_title", comment: "Title for Lutheran Radio") + " - " +
               NSLocalizedString("language_swedish", comment: "Swedish language option"),
               url: URL(string: "https://liveswedish.lutheran.radio:8443/lutheranradio.mp3")!,
               language: NSLocalizedString("language_swedish", comment: "Swedish language option"),
               languageCode: "sv",
               flag: "🇸🇪"),
        Stream(title: NSLocalizedString("lutheran_radio_title", comment: "Title for Lutheran Radio") + " - " +
               NSLocalizedString("language_estonian", comment: "Estonian language option"),
               url: URL(string: "https://liveestonian.lutheran.radio:8443/lutheranradio.mp3")!,
               language: NSLocalizedString("language_estonian", comment: "Estonian language option"),
               languageCode: "ee",
               flag: "🇪🇪"),
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
    }
        
    func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            #if DEBUG
            print("🔊 Audio session successfully configured")
            #endif
        } catch {
            #if DEBUG
            print("🔊 Audio session setup failed: \(error.localizedDescription)")
            #endif
        }
    }
    
    func play(completion: @escaping (Bool) -> Void) {
        stop()
        hasPermanentError = false
        #if DEBUG
        print("▶️ Starting direct playback for \(selectedStream.language)")
        #endif
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
            } else if item.status == .failed {
                completion(false)
            }
            tempStatusObserver?.invalidate()
        }
    }
    
    func setStream(to stream: Stream) {
        stop()
        selectedStream = stream
        play { [weak self] success in
            if success {
                #if DEBUG
                print("Stream switched successfully")
                #endif
                self?.onStatusChange?(true, String(localized: "status_playing"))
            } else {
                #if DEBUG
                print("Failed to switch stream")
                #endif
                self?.onStatusChange?(false, String(localized: "status_stream_unavailable"))
            }
        }
    }
    
    func setVolume(_ volume: Float) {
        player?.volume = volume
    }
    
    func addObservers() {
        removeObservers()
        
        statusObserver = playerItem?.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                #if DEBUG
                print("🎵 Player item status: \(item.status.rawValue)")
                #endif
                switch item.status {
                case .readyToPlay:
                    self.onStatusChange?(true, String(localized: "status_playing"))
                case .failed:
                    self.lastError = item.error
                    if let error = item.error {
                        let nsError = error as NSError
                        #if DEBUG
                        print("🎵 Player item failed with error: \(error.localizedDescription), code: \(nsError.code), domain: \(nsError.domain)")
                        #endif
                    } else {
                        #if DEBUG
                        print("🎵 Player item failed with no error details")
                        #endif
                    }
                    let errorType = StreamErrorType.from(error: item.error)
                    self.hasPermanentError = errorType.isPermanent
                    self.onStatusChange?(false, errorType.statusString)
                    self.removeObservers()
                case .unknown:
                    self.onStatusChange?(false, String(localized: "status_buffering"))
                @unknown default:
                    break
                }
            }
        }
        
        if let playerItem = playerItem {
            playerItem.addObserver(self, forKeyPath: "playbackBufferEmpty", options: .new, context: nil)
            playerItem.addObserver(self, forKeyPath: "playbackLikelyToKeepUp", options: .new, context: nil)
            playerItem.addObserver(self, forKeyPath: "playbackBufferFull", options: .new, context: nil)
            isObservingBuffer = true
        }
        
        let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            if self?.player?.rate ?? 0 > 0 {
                self?.onStatusChange?(true, String(localized: "status_playing"))
            }
        }
        
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
                    #if DEBUG
                    print("⏳ Playback buffer is empty - buffering...")
                    #endif
                    self.onStatusChange?(false, String(localized: "status_buffering"))
                }
            } else if keyPath == "playbackLikelyToKeepUp" {
                if playerItem.isPlaybackLikelyToKeepUp && playerItem.status == .readyToPlay {
                    #if DEBUG
                    print("✅ Playback is likely to keep up - ready to play")
                    #endif
                    self.player?.play()
                    self.onStatusChange?(true, String(localized: "status_playing"))
                }
            } else if keyPath == "playbackBufferFull" {
                if playerItem.isPlaybackBufferFull {
                    #if DEBUG
                    print("✅ Playback buffer is full")
                    #endif
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
            #if DEBUG
            print("📊 Removed buffer observers successfully")
            #endif
        }
    }
    
    func isLastErrorPermanent() -> Bool {
        StreamErrorType.from(error: lastError).isPermanent
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
extension DirectStreamingPlayer: AVAssetResourceLoaderDelegate {
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                       shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url else {
            loadingRequest.finishLoading(with: NSError(domain: "radio.lutheran", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return false
        }

        let streamingDelegate = StreamingSessionDelegate(loadingRequest: loadingRequest)
        let session = URLSession(configuration: .default, delegate: streamingDelegate, delegateQueue: nil)
        let task = session.dataTask(with: url)
        streamingDelegate.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.handleLoadingError(error)
            }
        }
        task.resume()
        return true
    }
    
    private func handleLoadingError(_ error: Error) {
        #if DEBUG
        print("📡 Loading error: \(error.localizedDescription)")
        #endif
        let errorType = StreamErrorType.from(error: error)
        hasPermanentError = errorType.isPermanent
        if let urlError = error as? URLError {
            switch urlError.code {
            case .serverCertificateUntrusted, .secureConnectionFailed:
                #if DEBUG
                print("🔒 SSL error: Connection cannot be verified")
                #endif
                onStatusChange?(false, String(localized: "status_security_failed"))
            case .cannotFindHost, .fileDoesNotExist, .badServerResponse: // Include 502
                #if DEBUG
                print("📡 Permanent error: \(urlError.code == .cannotFindHost ? "Host not found" : urlError.code == .fileDoesNotExist ? "File not found" : "Bad server response")")
                #endif
                onStatusChange?(false, String(localized: "status_stream_unavailable"))
            default:
                #if DEBUG
                print("📡 Generic loading error: \(urlError.code)")
                #endif
                onStatusChange?(false, String(localized: "status_buffering"))
            }
        } else {
            #if DEBUG
            print("📡 Non-URL error encountered")
            #endif
            onStatusChange?(false, String(localized: "status_buffering"))
        }
        stop()
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                       didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        // Handle cancellation if needed
        #if DEBUG
        print("Resource loading cancelled")
        #endif
    }
}

extension DirectStreamingPlayer {
    enum StreamErrorType {
        case securityFailure
        case permanentFailure
        case transientFailure
        case unknown
        
        static func from(error: Error?) -> StreamErrorType {
            guard let nsError = error as NSError?, nsError.domain == NSURLErrorDomain else {
                return .unknown
            }
            
            switch nsError.code {
            case URLError.Code.secureConnectionFailed.rawValue, // -1200
                 URLError.Code.serverCertificateUntrusted.rawValue: // -1202
                return .securityFailure
            case URLError.Code.cannotFindHost.rawValue, // -1003
                 URLError.Code.resourceUnavailable.rawValue, // -1008
                 URLError.Code.fileDoesNotExist.rawValue, // -1100
                 URLError.Code.cannotConnectToHost.rawValue, // -1004
                 URLError.Code.badServerResponse.rawValue: // -1011 (for 502)
                return .permanentFailure
            default:
                return .transientFailure
            }
        }
        
        var statusString: String {
            switch self {
            case .securityFailure:
                return String(localized: "status_security_failed")
            case .permanentFailure:
                return String(localized: "status_stream_unavailable")
            case .transientFailure:
                return String(localized: "status_buffering")
            case .unknown:
                return String(localized: "status_connecting")
            }
        }
        
        var isPermanent: Bool {
            switch self {
            case .securityFailure, .permanentFailure:
                return true
            default:
                return false
            }
        }
    }
}
