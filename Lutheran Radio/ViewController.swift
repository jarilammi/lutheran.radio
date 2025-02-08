//
//  ViewController.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.10.2024.
//

import UIKit
import AVFoundation
import MediaPlayer
import Network

class ViewController: UIViewController, AVPlayerItemMetadataOutputPushDelegate {
    // AVPlayer instance
    var player: AVPlayer?
    var isPlaying: Bool = false // Tracks playback state
    var isManualPause: Bool = false // Tracks if pause was triggered manually
    private var previouslyPlaying = false
    private var wasPlayingBeforeInterruption = false
    private var metadataOutput: AVPlayerItemMetadataOutput?
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var itemStatusObserver: NSKeyValueObservation?
    private var networkMonitor: NWPathMonitor?
    internal var hasInternetConnection = true
    
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
        
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to set audio session category: \(error)")
        }
        
        // Setup UI
        setupUI()
        setupControls()
        setupNetworkMonitoring()
        setupInterruptionHandling()
        setupNowPlaying()
    }
    
    private func setupControls() {
        // Configure play/pause button action
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        playPauseButton.accessibilityIdentifier = "playPauseButton"
        volumeSlider.addTarget(self, action: #selector(volumeChanged(_:)), for: .valueChanged) // Add action for volume slider
        volumeSlider.accessibilityIdentifier = "volumeSlider"
    }
    
    private func setupNetworkMonitoring() {
        networkMonitor = NWPathMonitor()
        
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            let isConnected = path.status == .satisfied && path.supportsDNS
            print("Network path changed:")
            print("- Status: \(path.status)")
            print("- Connected: \(isConnected)")
            print("- Interfaces: \(path.availableInterfaces)")
            print("- Supports DNS: \(path.supportsDNS)")
            
            DispatchQueue.main.async {
                self?.hasInternetConnection = isConnected
                self?.handleNetworkStatusChange()
            }
        }
        
        let monitorQueue = DispatchQueue(label: "NetworkMonitor")
        networkMonitor?.start(queue: monitorQueue)
    }

    private func testConnectivity(completion: @escaping (Bool) -> Void) {
        // Test connection to our actual stream URL
        let url = URL(string: "https://livestream.lutheran.radio:8443/lutheranradio.mp3")!
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"  // Only get headers, don't download content
        
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let httpResponse = response as? HTTPURLResponse {
                completion(httpResponse.statusCode == 200)
            } else {
                completion(false)
            }
        }
        task.resume()
    }
    
    private func handleNetworkStatusChange() {
        print("Network status changed - hasInternet: \(hasInternetConnection)")
        if !hasInternetConnection {
            cleanupStreamResources()
            updateUIForNoInternet()
        }
    }
    
    private func cleanupStreamResources() {
        if let playerItem = player?.currentItem {
            playerItem.remove(metadataOutput!)
        }
        player = nil
        isPlaying = false
        isManualPause = false
    }
    
    private func updateUIForNoInternet() {
        statusLabel.text = "Stopped"
        statusLabel.backgroundColor = .systemGray
        statusLabel.textColor = .white
        metadataLabel.text = "No track information"
        updatePlayPauseButton(isPlaying: false)
    }
    
    private func setupAVPlayer() {
        statusLabel.text = "Connecting…"  // This will show while we attempt connection
        statusLabel.backgroundColor = .systemYellow
        statusLabel.textColor = .black
        
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
        
        itemStatusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                self?.handlePlayerItemStatusChange(item)
            }
        }
        
        timeControlStatusObserver = player?.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                self?.handleTimeControlStatusChange(player)
            }
        }

        player?.play()
        isPlaying = true
        updatePlayPauseButton(isPlaying: true)
    }
    
    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                       didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                       from track: AVPlayerItemTrack?) {
        guard let item = groups.first?.items.first,
              let value = item.value(forKeyPath: "stringValue") as? String,
              !value.isEmpty else { return }
        
        let songTitle = (item.identifier == AVMetadataIdentifier("icy/StreamTitle") ||
                        (item.key as? String) == "StreamTitle") ? value : nil
        
        DispatchQueue.main.async { [weak self] in
            self?.metadataLabel.text = songTitle ?? "No track information"
            if let songTitle {
                self?.updateNowPlayingInfo(title: songTitle)
            }
        }
    }
    
    private func setupInterruptionHandling() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }
    
    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            player?.pause()
            isPlaying = false
            updatePlayPauseButton(isPlaying: false)
            updateStatusLabel(isPlaying: false)
            
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            
            try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            
            if options.contains(.shouldResume) && wasPlayingBeforeInterruption {
                player?.play()
                isPlaying = true
                updatePlayPauseButton(isPlaying: true)
                updateStatusLabel(isPlaying: true)
            }
            
        @unknown default:
            break
        }
    }
    
    private func setupNowPlaying() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.handlePlayCommand()
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.handlePauseCommand()
            return .success
        }
    }
    
    private func updateNowPlayingInfo(title: String) {
        // Create a basic placeholder image
        let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 120, height: 120)) { size in
            // Return the app icon or a placeholder image
            return UIImage(named: "radio-placeholder") ?? UIImage()
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Lutheran Radio",
            MPMediaItemPropertyArtwork: artwork
        ]
    }
    
    private func handlePlayCommand() {
        if player == nil {
            setupAVPlayer()
        } else {
            player?.play()
        }
        isPlaying = true
        isManualPause = false
        updatePlayPauseButton(isPlaying: true)
        updateStatusLabel(isPlaying: true)
    }
    
    private func handlePauseCommand() {
        player?.pause()
        isPlaying = false
        isManualPause = true
        updatePlayPauseButton(isPlaying: false)
        updateStatusLabel(isPlaying: false)
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
        
        view.addSubview(volumeSlider)
        view.addSubview(metadataLabel)
        
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

    @objc private func playPauseTapped() {
        print("Play tapped - hasInternet: \(hasInternetConnection), isPlaying: \(isPlaying), player: \(player != nil)")
        
        if isPlaying {
            handlePauseCommand()
        } else {
            if player == nil {
                print("Setting up new player")
                setupAVPlayer()
            } else {
                handlePlayCommand()
            }
        }
    }

    @objc private func volumeChanged(_ sender: UISlider) {
        player?.volume = sender.value
    }

    private func updatePlayPauseButton(isPlaying: Bool) {
        let config = UIImage.SymbolConfiguration(weight: .bold)
        let symbolName = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: symbolName, withConfiguration: config), for: .normal)
    }

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
    
    @objc private func handleAppearanceChange() {
        if !hasInternetConnection {
            updateUIForNoInternet()
        } else if isPlaying {
            updateStatusLabel(isPlaying: true)
        } else {
            updateStatusLabel(isPlaying: false)
        }
    }
    
    private func handlePlayerItemStatusChange(_ item: AVPlayerItem) {
        switch item.status {
        case .failed:
            cleanupStreamResources()
            updateUIForNoInternet()
        case .readyToPlay:
            if isPlaying && !isManualPause {
                updateStatusLabel(isPlaying: true)
            }
        default:
            break
        }
    }
    
    private func handleTimeControlStatusChange(_ player: AVPlayer) {
        switch player.timeControlStatus {
        case .waitingToPlayAtSpecifiedRate:
            statusLabel.text = "Buffering..."
            statusLabel.backgroundColor = .systemYellow
            statusLabel.textColor = .black
        case .paused:
            if !isManualPause && hasInternetConnection {
                cleanupStreamResources()
                updateUIForNoInternet()
            }
        case .playing:
            if isPlaying && !isManualPause {
                updateStatusLabel(isPlaying: true)
            }
        @unknown default:
            break
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        networkMonitor?.cancel()
        cleanupStreamResources()
        timeControlStatusObserver?.invalidate()
        itemStatusObserver?.invalidate()
    }
}
