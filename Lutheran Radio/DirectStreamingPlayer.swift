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
    // The URL to stream
    private let streamURL = URL(string: "https://livestream.lutheran.radio:8443/lutheranradio.mp3")!
    
    // Player components
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
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
        super.init()
        setupAudioSession()
        
        // Configure certificate pinning callback
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
    
    func play() {
        // Check if security lock is active
        if securityLockActive {
            onStatusChange?(false, "Connection cannot be verified. Please try again later.")
            return
        }
        
        // Stop any existing playback first
        stop()
        
        print("▶️ Starting direct playback")
        
        // Create the player directly
        let asset = AVURLAsset(url: streamURL)
        playerItem = AVPlayerItem(asset: asset)
        
        // Create player before adding observers
        player = AVPlayer(playerItem: playerItem)
        
        // Now add observers
        addObservers()
        
        // Start playback
        player?.play()
        
        // Set initial status
        onStatusChange?(false, "Connecting...")
    }
    
    private func addObservers() {
        // Player item status observer
        statusObserver = playerItem?.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                print("🎵 Player item status: \(item.status.rawValue)")
                
                switch item.status {
                case .readyToPlay:
                    print("🎵 Player item ready to play!")
                    self.onStatusChange?(true, "Playing")
                    
                case .failed:
                    let errorMessage = item.error?.localizedDescription ?? "unknown error"
                    print("🎵 Player item failed: \(errorMessage)")
                    self.onStatusChange?(false, "Playback failed: \(errorMessage)")
                    
                case .unknown:
                    // Still loading/buffering
                    self.onStatusChange?(false, "Buffering...")
                    
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
                self?.onStatusChange?(true, "Playing")
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
                    self.onStatusChange?(false, "Buffering...")
                }
            } else if keyPath == "playbackLikelyToKeepUp" {
                if playerItem.isPlaybackLikelyToKeepUp && playerItem.status == .readyToPlay {
                    print("✅ Playback is likely to keep up - ready to play")
                    self.player?.play()
                    self.onStatusChange?(true, "Playing")
                }
            } else if keyPath == "playbackBufferFull" {
                if playerItem.isPlaybackBufferFull {
                    print("✅ Playback buffer is full")
                    self.player?.play()
                    self.onStatusChange?(true, "Playing")
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
    
    func stop() {
        // First remove all observers
        removeObservers()
        
        // Then release player resources
        player?.pause()
        player = nil
        playerItem = nil
        
        onStatusChange?(false, "Stopped")
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
            self.onStatusChange?(false, "Ready to reconnect")
        }
    }
}

// MARK: - DirectStreamingPlayer Extension
extension DirectStreamingPlayer {
    func setVolume(_ volume: Float) {
        player?.volume = volume
    }
}
