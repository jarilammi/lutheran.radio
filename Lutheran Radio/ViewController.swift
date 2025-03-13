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
        view.backgroundColor = .systemRed.withAlphaComponent(0.7)
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
    private var didInitialLayout = false
    private var didPositionNeedle = false
    private let audioEngine = AVAudioEngine()
    private var tuningSoundNode: AVAudioSourceNode?
    private var isTuningSoundPlaying = false
    private var streamSwitchTimer: Timer?
    private var pendingStreamIndex: Int?
    private var lastPlaybackAttempt: Date?
    private let minPlaybackInterval: TimeInterval = 1.0 // 1 second
    
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
        
        if let layout = languageCollectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            layout.scrollDirection = .horizontal
            layout.minimumLineSpacing = 10
            layout.minimumInteritemSpacing = 0
        }

        languageCollectionView.reloadData()
        
        selectionIndicator.center.x = view.bounds.width / 2
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let indexPath = IndexPath(item: initialIndex, section: 0)
            self.languageCollectionView.selectItem(at: indexPath, animated: false, scrollPosition: .centeredHorizontally)
            self.centerCollectionViewContent()
            self.updateSelectionIndicator(to: initialIndex)
            self.languageCollectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: false)
        }

        streamingPlayer.setStream(to: DirectStreamingPlayer.availableStreams[initialIndex])
        languageCollectionView.reloadData()
        languageCollectionView.collectionViewLayout.invalidateLayout()
        languageCollectionView.selectItem(at: IndexPath(item: initialIndex, section: 0), animated: false, scrollPosition: .centeredHorizontally)

        setupControls()
        setupNetworkMonitoring()
        setupBackgroundAudioControls()
        setupInterruptionHandling()
        setupRouteChangeHandling()
        setupStreamingCallbacks()
        setupAudioEngine()

        if hasInternetConnection && !isManualPause {
            startPlayback()
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if !didInitialLayout {
            didInitialLayout = true
            selectionIndicator.center.x = view.bounds.width / 2
            
            let currentLocale = Locale.current
            let languageCode = currentLocale.language.languageCode?.identifier
            let initialIndex = DirectStreamingPlayer.availableStreams.firstIndex(where: { $0.languageCode == languageCode }) ?? 0
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let indexPath = IndexPath(item: initialIndex, section: 0)
                self.languageCollectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: true)
            }
        }
    }
    
    private func setupStreamingCallbacks() {
        streamingPlayer.onStatusChange = { [weak self] isPlaying, statusText in
            guard let self = self else { return }
            self.isPlaying = isPlaying
            self.updatePlayPauseButton(isPlaying: isPlaying)
            if isPlaying {
                self.statusLabel.text = String(localized: "status_playing")
            } else {
                self.statusLabel.text = statusText
            }
            let currentText = self.statusLabel.text ?? ""
            let activeStatuses = [
                String(localized: "status_playing"),
                String(localized: "status_buffering"),
                String(localized: "status_connecting")
            ]
            if activeStatuses.contains(currentText) {
                self.statusLabel.backgroundColor = .systemGreen
                self.statusLabel.textColor = .black
            } else if currentText == String(localized: "status_stream_unavailable") {
                self.statusLabel.backgroundColor = .systemOrange
                self.statusLabel.textColor = .white
            } else if currentText == String(localized: "alert_retry") {
            } else {
                self.statusLabel.backgroundColor = self.isManualPause ? .systemGray : .systemRed
                self.statusLabel.textColor = .white
            }
            self.updateNowPlayingInfo()
        }
        
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
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        playPauseButton.accessibilityIdentifier = "playPauseButton"
        volumeSlider.addTarget(self, action: #selector(volumeChanged(_:)), for: .valueChanged)
        volumeSlider.accessibilityIdentifier = "volumeSlider"
    }
    
    private func centerCollectionViewContent() {
        guard languageCollectionView.bounds.width > 0, DirectStreamingPlayer.availableStreams.count > 0 else { return }
        languageCollectionView.layoutIfNeeded()
        let layout = languageCollectionView.collectionViewLayout as! UICollectionViewFlowLayout
        let totalItems = DirectStreamingPlayer.availableStreams.count
        let cellWidth: CGFloat = 50
        let spacing: CGFloat = 10
        let totalCellWidth = (cellWidth * CGFloat(totalItems)) + (spacing * CGFloat(totalItems - 1))
        let collectionViewWidth = languageCollectionView.bounds.width
        let inset = max((collectionViewWidth - totalCellWidth) / 2, 0)
        layout.sectionInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        languageCollectionView.collectionViewLayout.invalidateLayout()
        print("Centered content with insets: \(inset)")
    }
    
    private func setupNetworkMonitoring() {
        networkMonitor?.cancel()
        networkMonitor = nil
        networkMonitor = NWPathMonitor()
        print("📱 Setting up network monitoring")
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let isConnected = path.status == .satisfied
            DispatchQueue.main.async {
                let wasConnected = self.hasInternetConnection
                self.hasInternetConnection = isConnected
                print("📱 Network path update: status=\(path.status), isExpensive=\(path.isExpensive), isConstrained=\(path.isConstrained)")
                if isConnected != wasConnected {
                    print("📱 Network status changed: \(isConnected ? "Connected" : "Disconnected")")
                    print("📱 isManualPause: \(self.isManualPause)")
                }
                if isConnected && !wasConnected {
                    print("📱 Network monitor detected reconnection")
                    self.stopTuningSound() // Ensure tuning sound stops on reconnect
                    self.handleNetworkReconnection()
                } else if !isConnected && wasConnected {
                    print("📱 Network disconnected - stopping playback and tuning sound")
                    self.stopTuningSound() // Stop tuning sound immediately
                    let wasPlayingBeforeDisconnect = self.isPlaying
                    self.stopPlayback()
                    self.updateUIForNoInternet()
                    self.isManualPause = self.isManualPause && !wasPlayingBeforeDisconnect
                    self.audioEngine.pause() // Pause audio engine to prevent overload
                }
            }
        }
        let monitorQueue = DispatchQueue(label: "NetworkMonitor", qos: .utility)
        networkMonitor?.start(queue: monitorQueue)
        setupConnectivityCheckTimer()
    }
    
    private func setupInterruptionHandling() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil)
    }
    
    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            if isPlaying { stopPlayback() }
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            if options.contains(.shouldResume) && !isManualPause { startPlayback() }
        @unknown default:
            break
        }
    }
    
    private func setupRouteChangeHandling() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleRouteChange), name: AVAudioSession.routeChangeNotification, object: nil)
    }
    
    @objc private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            if isPlaying { stopPlayback() }
        case .newDeviceAvailable:
            try? AVAudioSession.sharedInstance().setActive(true)
            if !isManualPause { startPlayback() }
        case .categoryChange:
            try? AVAudioSession.sharedInstance().setActive(true)
        default:
            break
        }
    }
    
    private func setupConnectivityCheckTimer() {
        connectivityCheckTimer?.invalidate()
        connectivityCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.performActiveConnectivityCheck()
        }
    }
    
    private func performActiveConnectivityCheck() {
        guard !hasInternetConnection else { return }
        if let lastAttempt = lastConnectionAttemptTime, Date().timeIntervalSince(lastAttempt) < 10.0 { return }
        lastConnectionAttemptTime = Date()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 5.0
        let session = URLSession(configuration: config)
        let url = URL(string: "https://www.apple.com/library/test/success.html")!
        let task = session.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            let success = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
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
        if !isManualPause && !hasPermanentPlaybackError {
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
        [commandCenter.playCommand, commandCenter.pauseCommand, commandCenter.togglePlayPauseCommand, commandCenter.stopCommand].forEach { $0.removeTarget(nil) }
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
            DispatchQueue.main.async { self?.startPlayback() }
            return .success
        }
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
            DispatchQueue.main.async { self?.pausePlayback() }
            return .success
        }
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
            DispatchQueue.main.async {
                if self?.isPlaying == true { self?.pausePlayback() } else { self?.startPlayback() }
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
        
        if !hasInternetConnection {
            updateUIForNoInternet()
            stopTuningSound() // Stop tuning sound if offline
            performActiveConnectivityCheck()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if !self.hasInternetConnection {
                    self.updateUIForNoInternet()
                    return
                }
                if !self.isPlaying && !self.isManualPause {
                    self.startPlayback()
                }
            }
            return
        }
        
        isManualPause = false
        statusLabel.text = String(localized: "status_connecting")
        statusLabel.backgroundColor = .systemYellow
        statusLabel.textColor = .black
        
        streamingPlayer.handleNetworkInterruption()
        attemptPlaybackWithRetry(attempt: 1, maxAttempts: 3)
    }

    private func attemptPlaybackWithRetry(attempt: Int, maxAttempts: Int) {
        guard hasInternetConnection && !isManualPause && !hasPermanentPlaybackError else {
            print("📱 Aborting playback attempt \(attempt) - no internet, manually paused, or previous permanent error")
            if hasPermanentPlaybackError { streamingPlayer.onStatusChange?(false, String(localized: "status_stream_unavailable")) }
            return
        }
        let now = Date()
        if let lastAttempt = lastPlaybackAttempt, now.timeIntervalSince(lastAttempt) < minPlaybackInterval {
            DispatchQueue.main.asyncAfter(deadline: .now() + minPlaybackInterval) {
                self.attemptPlaybackWithRetry(attempt: attempt, maxAttempts: maxAttempts)
            }
            return
        }
        
        lastPlaybackAttempt = now
        print("📱 Playback attempt \(attempt)/\(maxAttempts)")
        let delay = pow(2.0, Double(attempt-1))
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
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        UIView.animate(withDuration: 0.1, animations: {
            self.playPauseButton.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        }) { _ in
            UIView.animate(withDuration: 0.1) {
                self.playPauseButton.transform = .identity
            }
        }
        if isPlaying {
            pausePlayback()
        } else {
            hasPermanentPlaybackError = false
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
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            controlsStackView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 20),
            controlsStackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            controlsStackView.heightAnchor.constraint(equalToConstant: 50),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.4),
            statusLabel.heightAnchor.constraint(equalToConstant: 40),
            playPauseButton.widthAnchor.constraint(equalToConstant: 50),
            playPauseButton.heightAnchor.constraint(equalToConstant: 50),
            volumeSlider.topAnchor.constraint(equalTo: controlsStackView.bottomAnchor, constant: 20),
            volumeSlider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            volumeSlider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            metadataLabel.topAnchor.constraint(equalTo: volumeSlider.bottomAnchor, constant: 20),
            metadataLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            metadataLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            languageCollectionView.topAnchor.constraint(equalTo: metadataLabel.bottomAnchor, constant: 20),
            languageCollectionView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            languageCollectionView.widthAnchor.constraint(equalTo: view.widthAnchor),
            languageCollectionView.heightAnchor.constraint(equalToConstant: 50),
            selectionIndicator.widthAnchor.constraint(equalToConstant: 4),
            selectionIndicator.heightAnchor.constraint(equalTo: languageCollectionView.heightAnchor, multiplier: 0.8),
            selectionIndicator.centerYAnchor.constraint(equalTo: languageCollectionView.centerYAnchor),
            airplayButton.topAnchor.constraint(equalTo: selectionIndicator.bottomAnchor, constant: 20),
            airplayButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            airplayButton.widthAnchor.constraint(equalToConstant: 44),
            airplayButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }
    
    // MARK: - Audio Setup
    private func setupAudioEngine() {
        let mainMixer = audioEngine.mainMixerNode
        mainMixer.volume = 1.0
        do {
            try audioEngine.start()
            print("🎵 Audio engine started successfully")
        } catch {
            print("🎵 Failed to start audio engine: \(error.localizedDescription)")
        }
    }

    private func playTuningSound() {
        guard !isTuningSoundPlaying, hasInternetConnection else { return } // Only play if online
        
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
                print("🎵 Audio engine restarted successfully")
            } catch {
                print("🎵 Failed to restart audio engine: \(error.localizedDescription)")
                return
            }
        }
        
        isTuningSoundPlaying = true
        
        if let existingNode = tuningSoundNode {
            audioEngine.disconnectNodeOutput(existingNode)
            audioEngine.detach(existingNode)
        }
        
        tuningSoundNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self, self.hasInternetConnection else { return noErr } // Stop processing if offline
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let sampleRate = self.audioEngine.mainMixerNode.outputFormat(forBus: 0).sampleRate
            let frequency = Float.random(in: 500...1500)
            let amplitude = Float(0.1)
            for frame in 0..<Int(frameCount) {
                let time = Float(frame) / Float(sampleRate)
                let noise = Float.random(in: -0.05...0.05)
                let value = sinf(2.0 * .pi * frequency * time) * amplitude + noise
                for buffer in ablPointer {
                    let buf: UnsafeMutableBufferPointer<Float> = UnsafeMutableBufferPointer(buffer)
                    buf[frame] = value
                }
            }
            return noErr
        }
        
        audioEngine.attach(tuningSoundNode!)
        audioEngine.connect(tuningSoundNode!, to: audioEngine.mainMixerNode, format: nil)
        tuningSoundNode!.volume = 0.5
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.stopTuningSound()
        }
    }

    private func stopTuningSound() {
        guard isTuningSoundPlaying, let node = tuningSoundNode else { return }
        audioEngine.disconnectNodeOutput(node)
        audioEngine.detach(node)
        isTuningSoundPlaying = false
        tuningSoundNode = nil
        if !isPlaying && audioEngine.isRunning { audioEngine.stop() }
    }
    
    // MARK: - Selection Indicator
    private func updateSelectionIndicator(to index: Int) {
        guard index >= 0 && index < DirectStreamingPlayer.availableStreams.count else { return }
        let indexPath = IndexPath(item: index, section: 0)
        languageCollectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: true)
        languageCollectionView.layoutIfNeeded()
        if let layoutAttributes = languageCollectionView.layoutAttributesForItem(at: indexPath) {
            let cellFrame = layoutAttributes.frame
            let cellCenterX = cellFrame.midX
            UIView.animate(withDuration: 0.3) {
                self.selectionIndicator.center.x = cellCenterX
                self.selectionIndicator.transform = CGAffineTransform(scaleX: 1.5, y: 1.0)
            } completion: { _ in
                UIView.animate(withDuration: 0.1) {
                    self.selectionIndicator.transform = .identity
                }
            }
        }
    }
    
    // MARK: - UIPickerView DataSource
    func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        DirectStreamingPlayer.availableStreams.count
    }

    // MARK: - UIPickerView Delegate
    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        DirectStreamingPlayer.availableStreams[row].language
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        let selectedStream = DirectStreamingPlayer.availableStreams[row]
        streamingPlayer.setStream(to: selectedStream)
        hasPermanentPlaybackError = false
        if isPlaying || !isManualPause { startPlayback() }
    }

    // MARK: - UICollectionView DataSource
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        DirectStreamingPlayer.availableStreams.count
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "LanguageCell", for: indexPath) as! LanguageCell
        let stream = DirectStreamingPlayer.availableStreams[indexPath.item]
        cell.configure(with: stream)
        return cell
    }

    // MARK: - UICollectionView Delegate
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        streamSwitchTimer?.invalidate()
        pendingStreamIndex = indexPath.item
        streamSwitchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self = self, let index = self.pendingStreamIndex else { return }
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            self.playTuningSound()
            self.streamingPlayer.setStream(to: DirectStreamingPlayer.availableStreams[index])
            self.hasPermanentPlaybackError = false
            if self.isPlaying || !self.isManualPause { self.startPlayback() }
            self.updateSelectionIndicator(to: index)
            collectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: true)
            self.pendingStreamIndex = nil  // Reset after execution
        }
    }

    // MARK: - UICollectionViewDelegateFlowLayout
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let cellWidth: CGFloat = 50
        print("Cell size for item \(indexPath.item): width = \(cellWidth), height = 50")
        return CGSize(width: cellWidth, height: 50)
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat {
        let spacing = 10.0
        print("Minimum line spacing for section \(section): \(spacing)")
        return spacing
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        networkMonitor?.cancel()
        connectivityCheckTimer?.invalidate()
        connectivityCheckTimer = nil
        stopTuningSound()
        audioEngine.stop()
        if let node = tuningSoundNode { audioEngine.detach(node) }
    }
}

extension ViewController {
    // MARK: - ScrollView Delegate
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let centerX = languageCollectionView.bounds.midX
        let centerPoint = CGPoint(x: centerX, y: languageCollectionView.bounds.midY)
        if let indexPath = languageCollectionView.indexPathForItem(at: centerPoint) {
            targetContentOffset.pointee = CGPoint(x: centerX - languageCollectionView.contentInset.left, y: 0)
            languageCollectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            playTuningSound()
            let selectedStream = DirectStreamingPlayer.availableStreams[indexPath.item]
            streamingPlayer.setStream(to: selectedStream)
            hasPermanentPlaybackError = false
            if isPlaying || !isManualPause { startPlayback() }
            updateSelectionIndicator(to: indexPath.item)
            print("Scroll ended at index \(indexPath.item), centered at \(centerX)")
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        let centerX = languageCollectionView.bounds.midX + languageCollectionView.contentOffset.x
        var closestCell: UICollectionViewCell?
        var closestDistance: CGFloat = CGFloat.greatestFiniteMagnitude
        var closestIndex = 0
        for i in 0..<DirectStreamingPlayer.availableStreams.count {
            if let cell = languageCollectionView.cellForItem(at: IndexPath(item: i, section: 0)) {
                let cellCenterX = cell.frame.midX
                let distance = abs(centerX - cellCenterX)
                if distance < closestDistance {
                    closestDistance = distance
                    closestCell = cell
                    closestIndex = i
                }
            }
        }
        if closestCell != nil {
            let indexPath = IndexPath(item: closestIndex, section: 0)
            languageCollectionView.selectItem(at: indexPath, animated: true, scrollPosition: .centeredHorizontally)
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            playTuningSound()
            updateSelectionIndicator(to: closestIndex)
            let selectedStream = DirectStreamingPlayer.availableStreams[closestIndex]
            streamingPlayer.setStream(to: selectedStream)
            hasPermanentPlaybackError = false
            if isPlaying || !isManualPause { startPlayback() }
        }
    }
    
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scrollViewDidEndDecelerating(scrollView)
    }
}
