//
//  ViewController.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.10.2024.
//

import UIKit
import AVFoundation
import MediaPlayer

class ViewController: UIViewController, AVPlayerItemMetadataOutputPushDelegate {
    // AVPlayer instance
    var player: AVPlayer?
    var isPlaying: Bool = false // Tracks playback state
    var isManualPause: Bool = false // Tracks if pause was triggered manually
    private var metadataOutput: AVPlayerItemMetadataOutput?
    
    // Title label
    let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "Lutheran Radio"
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 24, weight: .bold)
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    // Play/Pause button
    let playPauseButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(weight: .bold)
        button.setImage(UIImage(systemName: "play.fill", withConfiguration: config), for: .normal)
        button.tintColor = .tintColor
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    // Status label
    let statusLabel: UILabel = {
        let label = UILabel()
        label.text = "Connecting…"
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 18, weight: .medium)
        label.backgroundColor = .systemYellow
        label.textColor = .black
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    // Volume slider
    let volumeSlider: UISlider = {
        let slider = UISlider()
        slider.minimumValue = 0.0
        slider.maximumValue = 1.0
        slider.value = 0.5 // Default volume
        slider.minimumTrackTintColor = .tintColor
        slider.maximumTrackTintColor = .tertiaryLabel
        slider.translatesAutoresizingMaskIntoConstraints = false
        return slider
    }()
    
    let metadataLabel: UILabel = {
        let label = UILabel()
        label.text = "No track information"
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 16)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        
        // Register for appearance changes using the system notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppearanceChange),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        
        // Setup UI
        setupUI()
        setupControls()
        setupAVPlayer()
        setupNowPlaying()
    }
    
    private func setupControls() {
        // Configure play/pause button action
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        playPauseButton.accessibilityIdentifier = "playPauseButton"
        volumeSlider.addTarget(self, action: #selector(volumeChanged(_:)), for: .valueChanged) // Add action for volume slider
        volumeSlider.accessibilityIdentifier = "volumeSlider"
    }
    
    private func setupAVPlayer() {
        // Set up the AVPlayer with the stream URL and ICY metadata header
        let streamURL = URL(string: "https://livestream.lutheran.radio:8443/lutheranradio.mp3")!
        let headers = ["Icy-MetaData": "1"]
        let asset = AVURLAsset(url: streamURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let playerItem = AVPlayerItem(asset: asset)
        
        // Setup metadata output
        metadataOutput = AVPlayerItemMetadataOutput(identifiers: nil)
        if let metadataOutput = metadataOutput {
            metadataOutput.setDelegate(self, queue: DispatchQueue.main)
            playerItem.add(metadataOutput)
        }
        
        player = AVPlayer(playerItem: playerItem)

        // Set initial status before playback starts
        statusLabel.text = "Connecting…"
        statusLabel.backgroundColor = .systemYellow
        statusLabel.textColor = .black

        player?.play()
        isPlaying = true

        let interval = CMTime(seconds: 1, preferredTimescale: 1)
        player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            if self.player?.currentItem?.status == .readyToPlay, self.isPlaying, !self.isManualPause {
                self.updateStatusLabel(isPlaying: true)
            }
        }
    }
    
    // AVPlayerItemMetadataOutputPushDelegate method
    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                       didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                       from track: AVPlayerItemTrack?) {
        guard let group = groups.first else {
            print("No metadata group found")
            return
        }
        
        let items = group.items
        if items.isEmpty {
            print("No metadata items found")
            return
        }
        
        var songInfo: [String] = []
        
        for item in items {
            print("Metadata item found:")
            print("- Identifier: \(String(describing: item.identifier))")
            print("- Key: \(String(describing: item.key))")
            
            // Using modern API to get string value
            guard let value = item.value(forKeyPath: "stringValue") as? String else {
                continue
            }
            
            print("- Value: \(value)")
            
            // Process metadata with valid stream title
            if item.identifier == AVMetadataIdentifier("icy/StreamTitle") {
                songInfo.append(value)
            } else if let key = item.key as? String,
                      key == "StreamTitle" {
                songInfo.append(value)
            }
            
            // Fallback if we haven't caught it yet but have a valid value
            if songInfo.isEmpty && !value.isEmpty {
                songInfo.append(value)
            }
        }
        
        DispatchQueue.main.async { [weak self] in
            if songInfo.isEmpty {
                self?.metadataLabel.text = "No track information"
                print("No song info found in metadata")
            } else {
                self?.metadataLabel.text = songInfo[0]
                print("Updated metadata label with: \(songInfo)")
                
                // Update lock screen now playing info
                var nowPlayingInfo = [String: Any]()
                nowPlayingInfo[MPMediaItemPropertyTitle] = songInfo[0]
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            }
        }
    }
    
    private func setupNowPlaying() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.player?.play()
            self?.isPlaying = true
            self?.updatePlayPauseButton(isPlaying: true)
            self?.updateStatusLabel(isPlaying: true)
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.player?.pause()
            self?.isPlaying = false
            self?.updatePlayPauseButton(isPlaying: false)
            self?.updateStatusLabel(isPlaying: false)
            return .success
        }
    }
    
    private func setupUI() {
        view.addSubview(titleLabel)

        // StackView for horizontal layout of play/pause button and status label
        let controlsStackView = UIStackView(arrangedSubviews: [playPauseButton, statusLabel])
        controlsStackView.axis = .horizontal
        controlsStackView.spacing = 20
        controlsStackView.alignment = .center
        controlsStackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controlsStackView)

        // Volume slider
        view.addSubview(volumeSlider)
        view.addSubview(metadataLabel)

        // Title label constraints
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            
            controlsStackView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 20),
            controlsStackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            controlsStackView.heightAnchor.constraint(equalToConstant: 50),
            
            statusLabel.widthAnchor.constraint(equalToConstant: 120),
            statusLabel.heightAnchor.constraint(equalToConstant: 40),
            playPauseButton.widthAnchor.constraint(equalToConstant: 50),
            playPauseButton.heightAnchor.constraint(equalToConstant: 50),
            
            volumeSlider.topAnchor.constraint(equalTo: controlsStackView.bottomAnchor, constant: 20),
            volumeSlider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            volumeSlider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            
            metadataLabel.topAnchor.constraint(equalTo: volumeSlider.bottomAnchor, constant: 20),
            metadataLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            metadataLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
    }

    // Play/Pause button tapped
    @objc private func playPauseTapped() {
        guard let player = player else { return }

        if isPlaying {
            player.pause()
            isPlaying = false
            isManualPause = true // Track manual pause
            updatePlayPauseButton(isPlaying: false)
            updateStatusLabel(isPlaying: false)
        } else {
            player.play()
            isPlaying = true
            isManualPause = false // Reset manual pause flag
            updatePlayPauseButton(isPlaying: true)
            updateStatusLabel(isPlaying: true)
        }
    }

    // Volume slider value changed
    @objc private func volumeChanged(_ sender: UISlider) {
        player?.volume = sender.value
    }

    // Update the play/pause button appearance
    private func updatePlayPauseButton(isPlaying: Bool) {
        let config = UIImage.SymbolConfiguration(weight: .bold)
        let symbolName = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: symbolName, withConfiguration: config), for: .normal)
    }

    // Update the status label
    private func updateStatusLabel(isPlaying: Bool) {
        if isPlaying {
            statusLabel.text = "Playing"
            statusLabel.backgroundColor = .systemGreen
            statusLabel.textColor = .black
        } else {
            statusLabel.text = "Paused"
            statusLabel.backgroundColor = .systemGray
            statusLabel.textColor = .white
        }
    }
    
    // Handle system appearance changes
    @objc private func handleAppearanceChange() {
        // Update status label colors based on current state
        if isPlaying {
            updateStatusLabel(isPlaying: true)
        } else {
            updateStatusLabel(isPlaying: false)
        }
        
        // Re-apply connecting state if needed
        if player?.currentItem?.status != .readyToPlay {
            statusLabel.backgroundColor = .systemYellow
            statusLabel.textColor = .black
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        if let playerItem = player?.currentItem {
            playerItem.remove(metadataOutput!)
        }
    }
}
