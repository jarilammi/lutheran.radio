//
//  ViewController.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.10.2024.
//

import UIKit
import AVFoundation
import MediaPlayer
import AVKit
import Network

class ViewController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSource, UIScrollViewDelegate {
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
    
    let languageCollectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.showsHorizontalScrollIndicator = false
        cv.backgroundColor = .systemBackground
        return cv
    }()

    let selectionIndicator: UIView = {
        let view = UIView()
        view.backgroundColor = .red
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    
    let playPauseButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(weight: .bold)
        button.setImage(UIImage(systemName: "play.fill", withConfiguration: config), for: .normal)
        button.tintColor = .tintColor
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

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
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

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
    
    let airplayButton: AVRoutePickerView = {
        let view = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        view.tintColor = .tintColor
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    
    // New streaming player
    private var streamingPlayer: DirectStreamingPlayer
    
    // Add initializer for testing
    init(streamingPlayer: DirectStreamingPlayer = DirectStreamingPlayer()) {
        self.streamingPlayer = streamingPlayer
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        self.streamingPlayer = DirectStreamingPlayer()
        super.init(coder: coder)
    }
    
    private var isPlaying = false
    private var isManualPause = false
    private var hasPermanentPlaybackError = false
    private var networkMonitor: NWPathMonitor?
    private var hasInternetConnection = true
    private var connectivityCheckTimer: Timer?
    private var lastConnectionAttemptTime: Date?
    
    // Testable accessors
    @objc var isPlayingState: Bool {
        get { isPlaying }
    }
    
    @objc var hasInternet: Bool {
        get { hasInternetConnection }
        set { hasInternetConnection = newValue } // Allow setting for test setup
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        setupUI()
        languageCollectionView.delegate = self
        languageCollectionView.dataSource = self
        languageCollectionView.register(LanguageCell.self, forCellWithReuseIdentifier: "LanguageCell")

        let currentLocale = Locale.current
        let languageCode = currentLocale.language.languageCode?.identifier
        let initialIndex = DirectStreamingPlayer.availableStreams.firstIndex(where: { $0.languageCode == languageCode }) ?? 0
        streamingPlayer.setStream(to: DirectStreamingPlayer.availableStreams[initialIndex])
        languageCollectionView.reloadData()
            
        // Ensure initial positioning
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.languageCollectionView.scrollToItem(
                at: IndexPath(item: initialIndex, section: 0),
                at: .centeredHorizontally,
                animated: false
            )
            self.updateSelectionIndicator(to: initialIndex)
            self.languageCollectionView.selectItem(
                at: IndexPath(item: initialIndex, section: 0),
                animated: false,
                scrollPosition: .centeredHorizontally
            )
        }
        
        streamingPlayer.setStream(to: DirectStreamingPlayer.availableStreams[initialIndex])
        languageCollectionView.reloadData() // Force reload
        languageCollectionView.selectItem(at: IndexPath(item: initialIndex, section: 0), animated: false, scrollPosition: .centeredHorizontally)

        setupControls()
        setupNetworkMonitoring()
        setupBackgroundAudioControls()
        setupInterruptionHandling()
        setupRouteChangeHandling()
        setupStreamingCallbacks()

        if hasInternetConnection && !isManualPause {
            startPlayback()
        }
    }
    
    private func setupStreamingCallbacks() {
        streamingPlayer.onStatusChange = { [weak self] isPlaying, statusText in
            guard let self = self else { return }
            
            // Update the playing state and play/pause button
            self.isPlaying = isPlaying
            self.updatePlayPauseButton(isPlaying: isPlaying)
            
            // Set the status text
            if isPlaying {
                self.statusLabel.text = String(localized: "status_playing")
            } else {
                self.statusLabel.text = statusText
            }
            
            // Get the current status text
            let currentText = self.statusLabel.text ?? ""
            
            // Define the active statuses to merge
            let activeStatuses = [
                String(localized: "status_playing"),
                String(localized: "status_buffering"),
                String(localized: "status_connecting")
            ]
            
            // Apply colors based on the current status
            if activeStatuses.contains(currentText) {
                self.statusLabel.backgroundColor = .systemGreen
                self.statusLabel.textColor = .black
            } else if currentText == String(localized: "status_stream_unavailable") {
                self.statusLabel.backgroundColor = .systemOrange
                self.statusLabel.textColor = .white
            } else if currentText == String(localized: "alert_retry") {
                // keep the previous color scheme, very brief duration
            } else {
                self.statusLabel.backgroundColor = self.isManualPause ? .systemGray : .systemRed
                self.statusLabel.textColor = .white
            }
            
            // Update additional UI elements
            self.updateNowPlayingInfo()
        }
        
        // Update metadata when track changes
        streamingPlayer.onMetadataChange = { [weak self] metadata in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if let metadata = metadata {
                    self.metadataLabel.text = metadata
                    self.updateNowPlayingInfo(title: metadata)
                } else {
                    self.metadataLabel.text = String(localized: "no_track_info")
                    self.updateNowPlayingInfo()
                }
            }
        }
    }
    
    private func setupControls() {
        // Configure play/pause button action
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        playPauseButton.accessibilityIdentifier = "playPauseButton"
        volumeSlider.addTarget(self, action: #selector(volumeChanged(_:)), for: .valueChanged)
        volumeSlider.accessibilityIdentifier = "volumeSlider"
    }
    
    private func setupNetworkMonitoring() {
        // Cancel existing monitor if any
        networkMonitor?.cancel()
        networkMonitor = nil
        
        // Create a dedicated monitor that will persist
        networkMonitor = NWPathMonitor()
        
        print("📱 Setting up network monitoring")
        
        // Add persistent reference to prevent deallocation
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            
            let isConnected = path.status == .satisfied
            
            DispatchQueue.main.async {
                // Store previous connection state
                let wasConnected = self.hasInternetConnection
                
                // Update current connection state
                self.hasInternetConnection = isConnected
                
                // Log connection state changes
                print("📱 Network path update: status=\(path.status), isExpensive=\(path.isExpensive), isConstrained=\(path.isConstrained)")
                
                if isConnected != wasConnected {
                    print("📱 Network status changed: \(isConnected ? "Connected" : "Disconnected")")
                    print("📱 isManualPause: \(self.isManualPause)")
                }
                
                // Handle connection state transitions
                if isConnected && !wasConnected {
                    // Network reconnected
                    print("📱 Network monitor detected reconnection")
                    self.handleNetworkReconnection()
                } else if !isConnected && wasConnected {
                    // Network disconnected
                    print("📱 Network disconnected - stopping playback")
                    
                    // Save current playing state
                    let wasPlayingBeforeDisconnect = self.isPlaying
                    
                    // Stop playback and update UI
                    self.stopPlayback()
                    self.updateUIForNoInternet()
                    
                    // Preserve manual pause only if user explicitly paused
                    self.isManualPause = self.isManualPause && !wasPlayingBeforeDisconnect
                }
            }
        }
        
        // Use a dedicated serial queue for network monitoring
        let monitorQueue = DispatchQueue(label: "NetworkMonitor", qos: .utility)
        networkMonitor?.start(queue: monitorQueue)
        
        // Also set up a backup connectivity check
        setupConnectivityCheckTimer()
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
            if isPlaying {
                stopPlayback()
            }
            
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            
            try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            
            if options.contains(.shouldResume) && !isManualPause {
                startPlayback()
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
            if isPlaying {
                stopPlayback()
            }
            
        case .newDeviceAvailable:
            // New route available (headphones connected, etc)
            try? AVAudioSession.sharedInstance().setActive(true)
            if !isManualPause {
                startPlayback()
            }
            
        case .categoryChange:
            // Handle category changes if needed
            try? AVAudioSession.sharedInstance().setActive(true)
            
        default:
            break
        }
    }
    
    private func setupConnectivityCheckTimer() {
        // Cancel any existing timer
        connectivityCheckTimer?.invalidate()
        
        // Create a new timer that checks connectivity periodically
        connectivityCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.performActiveConnectivityCheck()
        }
    }
    
    private func performActiveConnectivityCheck() {
        // Only perform the check if we think we're offline
        guard !hasInternetConnection else { return }
        
        // Don't check too frequently
        if let lastAttempt = lastConnectionAttemptTime,
           Date().timeIntervalSince(lastAttempt) < 10.0 {
            return
        }
        
        lastConnectionAttemptTime = Date()
        
        // Set up a simple URL session configuration
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 5.0
        let session = URLSession(configuration: config)
        
        // Try to connect to a reliable endpoint (Apple's captive portal detection)
        let url = URL(string: "https://www.apple.com/library/test/success.html")!
        let task = session.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            
            let success = error == nil &&
                         (response as? HTTPURLResponse)?.statusCode == 200
            
            DispatchQueue.main.async {
                if success && !self.hasInternetConnection {
                    print("📱 Active check detected internet connection")
                    self.hasInternetConnection = true
                    self.handleNetworkReconnection()
                }
            }
        }
        
        task.resume()
    }
    
    private func handleNetworkReconnection() {
        if !isManualPause && !hasPermanentPlaybackError { // Check permanent error flag
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                if self.hasInternetConnection && !self.isPlaying && !self.isManualPause && !self.hasPermanentPlaybackError {
                    print("📱 Auto-restarting playback after reconnection")
                    self.startPlayback()
                }
            }
        }
    }
    
    private func setupBackgroundAudioControls() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Clear existing handlers
        [commandCenter.playCommand,
         commandCenter.pauseCommand,
         commandCenter.togglePlayPauseCommand,
         commandCenter.stopCommand].forEach { $0.removeTarget(nil) }
        
        // Configure play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
            DispatchQueue.main.async {
                self?.startPlayback()
            }
            return .success
        }
        
        // Configure pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
            DispatchQueue.main.async {
                self?.pausePlayback()
            }
            return .success
        }
        
        // Configure toggle command
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
            DispatchQueue.main.async {
                if self?.isPlaying == true {
                    self?.pausePlayback()
                } else {
                    self?.startPlayback()
                }
            }
            return .success
        }
    }
    
    private func updateNowPlayingInfo(title: String? = nil) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title ?? "Lutheran Radio Live",
            MPMediaItemPropertyArtist: "Lutheran Radio",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPMediaItemPropertyMediaType: MPMediaType.anyAudio.rawValue
        ]
        
        if let image = UIImage(named: "radio-placeholder") {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            info[MPMediaItemPropertyArtwork] = artwork
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    private func updateUIForNoInternet() {
        statusLabel.text = String(localized: "status_no_internet")
        statusLabel.backgroundColor = .systemGray
        statusLabel.textColor = .white
        metadataLabel.text = String(localized: "no_track_info")
        updatePlayPauseButton(isPlaying: false)
    }
    
    // MARK: - Playback Control
    
    private func startPlayback() {
        print("📱 startPlayback called - hasInternet: \(hasInternetConnection), isManualPause: \(isManualPause)")
        
        // Double check connectivity with an active test
        performActiveConnectivityCheck()
        
        if !hasInternetConnection {
            updateUIForNoInternet()
            
            // Schedule a retry in case network is in transition
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if !self.isPlaying && !self.isManualPause {
                    print("📱 Retry playback after network check")
                    self.startPlayback()
                }
            }
            return
        }
        
        isManualPause = false
        statusLabel.text = String(localized: "status_connecting")
        statusLabel.backgroundColor = .systemYellow
        statusLabel.textColor = .black
        
        // If we've had network issues, reset the player first
        streamingPlayer.handleNetworkInterruption()
        
        // Wait a moment then start playback with exponential retry
        attemptPlaybackWithRetry(attempt: 1, maxAttempts: 3)
    }

    private func attemptPlaybackWithRetry(attempt: Int, maxAttempts: Int) {
        guard hasInternetConnection && !isManualPause && !hasPermanentPlaybackError else {
            print("📱 Aborting playback attempt \(attempt) - no internet, manually paused, or previous permanent error")
            if hasPermanentPlaybackError {
                streamingPlayer.onStatusChange?(false, String(localized: "status_stream_unavailable"))
            }
            return
        }
        
        print("📱 Playback attempt \(attempt)/\(maxAttempts)")
        let delay = pow(2.0, Double(attempt-1)) // Exponential backoff
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.streamingPlayer.setVolume(self.volumeSlider.value)
            self.streamingPlayer.play { [weak self] success in
                guard let self = self else { return }
                if success {
                    print("📱 Playback succeeded on attempt \(attempt)")
                } else {
                    if self.streamingPlayer.isLastErrorPermanent() {
                        print("📱 Permanent error detected - stopping retries")
                        self.hasPermanentPlaybackError = true
                        self.streamingPlayer.onStatusChange?(false, String(localized: "status_stream_unavailable"))
                    } else if attempt < maxAttempts {
                        print("📱 Playback attempt \(attempt) failed, retrying...")
                        self.attemptPlaybackWithRetry(attempt: attempt + 1, maxAttempts: maxAttempts)
                    } else {
                        print("📱 Max attempts (\(maxAttempts)) reached - giving up")
                        self.streamingPlayer.onStatusChange?(false, String(localized: "alert_connection_failed_title"))
                    }
                }
            }
        }
    }
    
    private func pausePlayback() {
        isManualPause = true
        streamingPlayer.stop()
        
        statusLabel.text = String(localized: "status_paused")
        statusLabel.backgroundColor = .systemGray
        statusLabel.textColor = .white
        
        isPlaying = false
        updatePlayPauseButton(isPlaying: false)
        updateNowPlayingInfo()
    }
    
    private func stopPlayback() {
        streamingPlayer.stop()
        isPlaying = false
        updatePlayPauseButton(isPlaying: false)
    }
    
    @objc func playPauseTapped() {
        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        
        // Animation
        UIView.animate(withDuration: 0.1, animations: {
            self.playPauseButton.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        }) { _ in
            UIView.animate(withDuration: 0.1) {
                self.playPauseButton.transform = .identity
            }
        }
        
        // Toggle playback
        if isPlaying {
            pausePlayback()
        } else {
            hasPermanentPlaybackError = false // Reset on manual play
            startPlayback()
        }
    }
        
    @objc private func volumeChanged(_ sender: UISlider) {
        streamingPlayer.setVolume(sender.value)
    }
    
    private func updatePlayPauseButton(isPlaying: Bool) {
        let config = UIImage.SymbolConfiguration(weight: .bold)
        let symbolName = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: symbolName, withConfiguration: config), for: .normal)
    }
    
    // UI setup code (use your existing implementation)
    private func setupUI() {
        view.addSubview(titleLabel)
        view.addSubview(languageCollectionView)

        let controlsStackView = UIStackView(arrangedSubviews: [playPauseButton, statusLabel])
        controlsStackView.axis = .horizontal
        controlsStackView.spacing = 20
        controlsStackView.alignment = .center
        controlsStackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controlsStackView)
        
        view.addSubview(volumeSlider)
        view.addSubview(metadataLabel)
        view.addSubview(airplayButton)
        languageCollectionView.addSubview(selectionIndicator)
        view.bringSubviewToFront(selectionIndicator)
        
        NSLayoutConstraint.activate([
            // Title Label
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            // Controls Stack View
            controlsStackView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 20),
            controlsStackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            controlsStackView.heightAnchor.constraint(equalToConstant: 50),

            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.4),
            statusLabel.heightAnchor.constraint(equalToConstant: 40),
            playPauseButton.widthAnchor.constraint(equalToConstant: 50),
            playPauseButton.heightAnchor.constraint(equalToConstant: 50),

            // Volume Slider
            volumeSlider.topAnchor.constraint(equalTo: controlsStackView.bottomAnchor, constant: 20),
            volumeSlider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            volumeSlider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),

            // Metadata Label
            metadataLabel.topAnchor.constraint(equalTo: volumeSlider.bottomAnchor, constant: 20),
            metadataLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            metadataLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            // Language Collection View
            languageCollectionView.topAnchor.constraint(equalTo: metadataLabel.bottomAnchor, constant: 20),
            languageCollectionView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            languageCollectionView.widthAnchor.constraint(equalTo: view.widthAnchor),
            languageCollectionView.heightAnchor.constraint(equalToConstant: 50),
            
            // Selection Indicator (needle)
            selectionIndicator.widthAnchor.constraint(equalToConstant: 2),
            selectionIndicator.heightAnchor.constraint(equalTo: languageCollectionView.heightAnchor),
            selectionIndicator.topAnchor.constraint(equalTo: languageCollectionView.topAnchor),
            
            // AirPlay Button
            airplayButton.topAnchor.constraint(equalTo: selectionIndicator.bottomAnchor, constant: 20),
            airplayButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            airplayButton.widthAnchor.constraint(equalToConstant: 44),
            airplayButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }
    
    // MARK: - UIPickerView DataSource
    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        return 1
    }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        return DirectStreamingPlayer.availableStreams.count
    }

    // MARK: - UIPickerView Delegate
    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        return DirectStreamingPlayer.availableStreams[row].language
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        let selectedStream = DirectStreamingPlayer.availableStreams[row]
        streamingPlayer.setStream(to: selectedStream)
        hasPermanentPlaybackError = false // Reset on stream change
        if isPlaying || !isManualPause {
            startPlayback()
        }
    }

    // MARK: - UICollectionView DataSource
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return DirectStreamingPlayer.availableStreams.count
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "LanguageCell", for: indexPath) as! LanguageCell
        let stream = DirectStreamingPlayer.availableStreams[indexPath.item]
        cell.configure(with: stream)
        return cell
    }

    // MARK: - UICollectionView Delegate
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        streamingPlayer.setStream(to: DirectStreamingPlayer.availableStreams[indexPath.item])
        hasPermanentPlaybackError = false
        if isPlaying || !isManualPause {
            startPlayback()
        }
        updateSelectionIndicator(to: indexPath.item)
        collectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: true)
    }

    // MARK: - UICollectionViewDelegateFlowLayout
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        // Fixed size for consistency
        return CGSize(width: 80, height: 50) // Adjust width as needed
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
        let totalCellWidth = CGFloat(DirectStreamingPlayer.availableStreams.count) * 80 // Using fixed width from above
        let totalSpacingWidth = CGFloat(DirectStreamingPlayer.availableStreams.count - 1) * 10 // minimumLineSpacing
        let totalWidth = totalCellWidth + totalSpacingWidth
        let inset = max((collectionView.bounds.width - totalWidth) / 2, 0)
        return UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat {
        return 10 // Add spacing between cells
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        networkMonitor?.cancel()
        connectivityCheckTimer?.invalidate()
        connectivityCheckTimer = nil
    }
}

extension ViewController {
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        _ = languageCollectionView.collectionViewLayout as! UICollectionViewFlowLayout
        var offset = targetContentOffset.pointee.x + scrollView.contentInset.left
        var cumulativeWidth: CGFloat = 0
        var selectedIndex = 0
        
        for (index, stream) in DirectStreamingPlayer.availableStreams.enumerated() {
            let text = "\(stream.flag) \(stream.language)"
            let font = UIFont.systemFont(ofSize: 18)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let textSize = (text as NSString).boundingRect(with: CGSize(width: scrollView.bounds.width, height: 100), options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
            let cellWidth = ceil(textSize.width) + 40
            let cellEnd = cumulativeWidth + cellWidth
            if offset <= cellEnd {
                selectedIndex = index
                offset = cumulativeWidth
                break
            }
            cumulativeWidth += cellWidth + 10 // Include minimumLineSpacing
        }
        
        targetContentOffset.pointee = CGPoint(x: offset - scrollView.contentInset.left, y: -scrollView.contentInset.top)
        updateSelectionIndicator(to: selectedIndex)
    }
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        let centerX = languageCollectionView.bounds.midX
        let centerPoint = CGPoint(x: centerX, y: languageCollectionView.bounds.midY)
        if let indexPath = languageCollectionView.indexPathForItem(at: centerPoint) {
            languageCollectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
            let selectedStream = DirectStreamingPlayer.availableStreams[indexPath.item]
            streamingPlayer.setStream(to: selectedStream)
            hasPermanentPlaybackError = false
            if isPlaying || !isManualPause {
                startPlayback()
            }
            updateSelectionIndicator(to: indexPath.item)
        }
    }
    
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scrollViewDidEndDecelerating(scrollView)
    }
    
    private func updateSelectionIndicator(to index: Int) {
        guard index >= 0 && index < DirectStreamingPlayer.availableStreams.count else { return }
        
        // Get the cell at the index path
        if let cell = languageCollectionView.cellForItem(at: IndexPath(item: index, section: 0)) {
            // Convert cell's center to collection view coordinates
            let cellCenterInCollection = languageCollectionView.convert(cell.center, from: cell.superview)
            
            // Update indicator position
            UIView.animate(withDuration: 0.3) {
                self.selectionIndicator.center.x = cellCenterInCollection.x
            }
            
            // Center the selected cell in the collection view
            languageCollectionView.scrollToItem(
                at: IndexPath(item: index, section: 0),
                at: .centeredHorizontally,
                animated: true
            )
        }
    }
}
