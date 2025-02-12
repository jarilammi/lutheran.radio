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
import AVKit

class ViewController: UIViewController, AVPlayerItemMetadataOutputPushDelegate {
    // AVPlayer instance
    var player: AVPlayer?
    var isPlaying: Bool = false // Tracks playback state
    var isManualPause: Bool = false // Tracks if pause was triggered manually
    private var previouslyPlaying = false
    private var wasPlayingBeforeInterruption = false
    private var wasPlayingBeforeRouteChange = false
    private var metadataOutput: AVPlayerItemMetadataOutput?
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var itemStatusObserver: NSKeyValueObservation?
    private var networkMonitor: NWPathMonitor?
    internal var hasInternetConnection = true
    // Retry configuration
    private let maxRetryAttempts = 5
    private let baseRetryInterval: TimeInterval = 2.0
    private let maxRetryInterval: TimeInterval = 64.0
    private var currentRetryAttempt = 0
    private var retryTimer: Timer?
    // Add new properties for metadata optimization
    private var lastMetadataUpdate: Date?
    private let minimumMetadataInterval: TimeInterval = 5.0 // Minimum seconds between metadata updates
    private var currentMetadata: String?
    private var metadataTimer: Timer?
    private let metadataQueue = DispatchQueue(label: "radio.lutheran.metadata", qos: .utility)
    
    // Title label
    let titleLabel: UILabel = {
        let label = UILabel()
        label.text = String(localized: "lutheran_radio_title")
        label.textAlignment = .center
        label.font = UIFont.preferredFont(forTextStyle: .title1)
        label.adjustsFontForContentSizeCategory = true
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
        label.text = String(localized: "status_connecting")
        label.textAlignment = .center
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
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
        label.text = String(localized: "no_track_info")
        label.textAlignment = .center
        label.font = UIFont.preferredFont(forTextStyle: .callout)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    private let airplayButton: AVRoutePickerView = {
        let view = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        view.tintColor = .tintColor
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        
        // Enable background audio
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            updateNowPlayingInfo()  // Set default info on launch
        } catch {
            print("Failed to set up background audio: \(error)")
        }
        
        // Register for appearance changes using the system notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppearanceChange),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        
        setupEnhancedAudioSession()
        
        // Setup UI
        setupUI()
        setupControls()
        setupNetworkMonitoring()
        setupInterruptionHandling()
        setupRouteChangeHandling()
        setupNowPlaying()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        // Ensure route picker is visible after layout
        if let routePickerButton = airplayButton.subviews.first(where: { $0 is UIButton }) as? UIButton {
            routePickerButton.isHidden = false
            routePickerButton.tintColor = .tintColor
        }
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
        } else if !isManualPause {
            // Network is back and we weren't manually paused
            resetRetryCount()  // Reset retry counter for fresh start
            setupAVPlayer()    // Attempt to reconnect
        }
    }
    
    private func cleanupStreamResources() {
        if let playerItem = player?.currentItem {
            playerItem.remove(metadataOutput!)
        }
        player = nil
        isPlaying = false
        isManualPause = false
        metadataTimer?.invalidate()
        metadataTimer = nil
        currentMetadata = nil
        lastMetadataUpdate = nil
    }
    
    private func updateUIForNoInternet() {
        statusLabel.text = String(localized: "status_stopped")
        statusLabel.backgroundColor = .systemGray
        statusLabel.textColor = .white
        metadataLabel.text = String(localized: "no_track_info")
        updatePlayPauseButton(isPlaying: false)
    }
    
    private func setupAVPlayer() {
        if currentRetryAttempt == 0 {
            statusLabel.text = "Connecting…"
            statusLabel.backgroundColor = .systemYellow
            statusLabel.textColor = .black
        }
        
        let streamURL = URL(string: "https://livestream.lutheran.radio:8443/lutheranradio.mp3")!
        
        // Optimize headers to only request metadata when needed
        var headers: [String: String] = [:]
        if metadataOutput != nil {
            headers["Icy-MetaData"] = "1"
        }
        
        let asset = AVURLAsset(url: streamURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let playerItem = AVPlayerItem(asset: asset)
        
        // Setup metadata output with optimization
        if metadataOutput == nil {
            metadataOutput = AVPlayerItemMetadataOutput(identifiers: nil)
            if let metadataOutput = metadataOutput {
                metadataOutput.setDelegate(self, queue: metadataQueue)
            }
        }
        
        if let metadataOutput = metadataOutput {
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
        updateNowPlayingInfo()
    }
    
    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                       didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                       from track: AVPlayerItemTrack?) {
        
        // Check if enough time has passed since last update
        if let lastUpdate = lastMetadataUpdate,
           Date().timeIntervalSince(lastUpdate) < minimumMetadataInterval {
            return
        }
        
        guard let item = groups.first?.items.first,
              let value = item.value(forKeyPath: "stringValue") as? String,
              !value.isEmpty else { return }
        
        let songTitle = (item.identifier == AVMetadataIdentifier("icy/StreamTitle") ||
                        (item.key as? String) == "StreamTitle") ? value : nil
        
        // Only update if the metadata has actually changed
        if songTitle != currentMetadata {
            currentMetadata = songTitle
            lastMetadataUpdate = Date()
            
            // Schedule UI update on main thread
            DispatchQueue.main.async { [weak self] in
                self?.updateMetadataUI(songTitle: songTitle)
            }
        }
    }
    
    private func updateMetadataUI(songTitle: String?) {
        metadataLabel.text = songTitle ?? "No track information"
        if let songTitle = songTitle {
            updateNowPlayingInfo(title: songTitle)
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
    
    private func setupRouteChangeHandling() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }
    
    @objc private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        switch reason {
        case .oldDeviceUnavailable:
            // Headphones unplugged or Bluetooth disconnected
            wasPlayingBeforeRouteChange = isPlaying
            player?.pause()
            isPlaying = false
            updatePlayPauseButton(isPlaying: false)
            updateStatusLabel(isPlaying: false)
            
            // Optionally show an alert or update UI
            DispatchQueue.main.async {
                self.metadataLabel.text = String(localized: "audio_disconnected")
            }
            
        case .newDeviceAvailable:
            // New route available (headphones connected, etc)
            try? AVAudioSession.sharedInstance().setActive(true)
            if wasPlayingBeforeRouteChange && !isManualPause {
                player?.play()
                isPlaying = true
                updatePlayPauseButton(isPlaying: true)
                updateStatusLabel(isPlaying: true)
            }
            
        case .categoryChange:
            // Handle category changes if needed
            try? AVAudioSession.sharedInstance().setActive(true)
            
        default:
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
    
    private func updateNowPlayingInfo(title: String? = nil) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title ?? "Lutheran Radio Live",  // Provide a default title
            MPMediaItemPropertyArtist: "Lutheran Radio",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPMediaItemPropertyMediaType: MPMediaType.anyAudio.rawValue,
            MPNowPlayingInfoPropertyAvailableLanguageOptions: [], // Enable language options menu
            MPNowPlayingInfoPropertyAssetURL: URL(string: "https://livestream.lutheran.radio:8443/lutheranradio.mp3")! // Enable proper routing
        ]
        
        // Add description for better context when no track info
        if title == nil {
            info[MPMediaItemPropertyComments] = "Christian radio station"
            // You could also use these fields for additional context:
            // info[MPMediaItemPropertyAlbumTitle] = "Live Stream"
            // info[MPMediaItemPropertyGenre] = "Christian Radio"
        }
        
        // Always ensure we have artwork
        if let image = UIImage(named: "radio-placeholder") {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            info[MPMediaItemPropertyArtwork] = artwork
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
        if let currentTitle = metadataLabel.text, currentTitle != String(localized: "no_track_info") {
            updateNowPlayingInfo(title: currentTitle)
        } else {
            updateNowPlayingInfo()
        }
    }
    
    private func handlePauseCommand() {
        player?.pause()
        isPlaying = false
        isManualPause = true
        updatePlayPauseButton(isPlaying: false)
        updateStatusLabel(isPlaying: false)
        updateNowPlayingInfo()
    }
    
    private func setupEnhancedAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .default,
                policy: .longFormAudio,
                options: [.allowAirPlay, .allowBluetooth, .allowBluetoothA2DP, .duckOthers]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            
            // Configure audio session for background playback
            try session.setActive(true)
            UIApplication.shared.beginReceivingRemoteControlEvents()
            setupBackgroundAudioControls()
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }
    
    private func setupBackgroundAudioControls() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Clear existing handlers first
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if !self.isPlaying {
                self.handlePlayCommand()
                return .success
            }
            return .commandFailed
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.isPlaying {
                self.handlePauseCommand()
                return .success
            }
            return .commandFailed
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
        
        view.addSubview(volumeSlider)
        view.addSubview(metadataLabel)
        view.addSubview(airplayButton)
        
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
            metadataLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            // Add constraints for airplayButton
            airplayButton.topAnchor.constraint(equalTo: metadataLabel.bottomAnchor, constant: 20),
            airplayButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            airplayButton.widthAnchor.constraint(equalToConstant: 44),
            airplayButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    @objc private func playPauseTapped() {
        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        
        // Scale animation
        UIView.animate(withDuration: 0.1, animations: {
            self.playPauseButton.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        }) { _ in
            UIView.animate(withDuration: 0.1) {
                self.playPauseButton.transform = .identity
            }
        }
        
        // Existing play/pause logic
        if isPlaying {
            handlePauseCommand()
        } else {
            if player == nil {
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
            statusLabel.text = String(localized: "status_playing")
            statusLabel.backgroundColor = .systemGreen
            statusLabel.textColor = .black
        } else {
            statusLabel.text = String(localized: "status_paused")
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
            handleStreamError(item.error)
        case .readyToPlay:
            resetRetryCount() // Reset retry count on successful connection
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
            statusLabel.text = String(localized: "status_buffering")
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
    
    private func calculateRetryInterval() -> TimeInterval {
        // Calculate exponential backoff: baseInterval * 2^attempt
        let interval = baseRetryInterval * pow(2.0, Double(currentRetryAttempt - 1))
        // Add some jitter (±20%) to prevent thundering herd problem
        let jitter = interval * Double.random(in: -0.2...0.2)
        // Clamp the final interval to maxRetryInterval
        return min(interval + jitter, maxRetryInterval)
    }
    
    private func handleStreamError(_ error: Error?) {
        if currentRetryAttempt < maxRetryAttempts {
            currentRetryAttempt += 1
            
            // Update UI to show retry attempt
            statusLabel.text = String(format: String(localized: "status_reconnect_format"), currentRetryAttempt, maxRetryAttempts)
            statusLabel.backgroundColor = .systemYellow
            statusLabel.textColor = .black
            
            // Schedule retry
            retryTimer?.invalidate()
            let nextRetryInterval = calculateRetryInterval()
            statusLabel.text = String(format: String(localized: "status_reconnect_countdown_format"), Int(nextRetryInterval), currentRetryAttempt, maxRetryAttempts)

            retryTimer = Timer.scheduledTimer(withTimeInterval: nextRetryInterval, repeats: false) { [weak self] _ in
                self?.setupAVPlayer()
            }
        } else {
            // Max retries reached, update UI and clean up
            cleanupStreamResources()
            statusLabel.text = String(localized: "alert_connection_failed_title")
            statusLabel.backgroundColor = .systemRed
            statusLabel.textColor = .white
            
            // Show error alert to user
            let alert = UIAlertController(
                title: String(localized: "alert_connection_failed_title"),
                message: String(localized: "alert_connection_failed_message"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "alert_retry"), style: .default) { [weak self] _ in
                self?.resetRetryCount()
                self?.setupAVPlayer()
            })
            alert.addAction(UIAlertAction(title: String(localized: "alert_ok"), style: .cancel))
            present(alert, animated: true)
        }
    }
    
    private func resetRetryCount() {
        currentRetryAttempt = 0
        retryTimer?.invalidate()
        retryTimer = nil
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        networkMonitor?.cancel()
        cleanupStreamResources()
        timeControlStatusObserver?.invalidate()
        itemStatusObserver?.invalidate()
        retryTimer?.invalidate()
    }
}
