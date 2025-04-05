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

// MARK: - Parallax Effect Extension
extension UIView {
    func addParallaxEffect(intensity: CGFloat) {
        // Remove any existing motion effects to avoid conflicts
        motionEffects.forEach { removeMotionEffect($0) }
        
        // Horizontal tilt effect
        let horizontalMotion = UIInterpolatingMotionEffect(
            keyPath: "center.x",
            type: .tiltAlongHorizontalAxis
        )
        horizontalMotion.minimumRelativeValue = -intensity
        horizontalMotion.maximumRelativeValue = intensity
        
        // Vertical tilt effect
        let verticalMotion = UIInterpolatingMotionEffect(
            keyPath: "center.y",
            type: .tiltAlongVerticalAxis
        )
        verticalMotion.minimumRelativeValue = -intensity
        verticalMotion.maximumRelativeValue = intensity
        
        // Group the effects
        let motionGroup = UIMotionEffectGroup()
        motionGroup.motionEffects = [horizontalMotion, verticalMotion]
        
        // Apply to the view
        addMotionEffect(motionGroup)
    }
}

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
    
    private let backgroundImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = UIColor.gray
        imageView.alpha = 0.1
        return imageView
    }()
    
    private let backgroundImages: [String: String] = [
        "en": "north_america",
        "de": "germany",
        "fi": "finland",
        "sv": "sweden",
        "ee": "estonia"
    ]
    private var backgroundConstraints: [NSLayoutConstraint] = []
    
    private var isInitialSetupComplete = false
    private var isInitialScrollLocked = true
    
    // New streaming player
    private var streamingPlayer: DirectStreamingPlayer
    private let audioQueue = DispatchQueue(label: "radio.lutheran.audio", qos: .userInitiated)
    
    // Add initializer for testing
    init(streamingPlayer: DirectStreamingPlayer = DirectStreamingPlayer()) {
        self.streamingPlayer = streamingPlayer
        super.init(nibName: nil, bundle: nil)
        self.streamingPlayer.setDelegate(self)
    }
    
    required init?(coder: NSCoder) {
        self.streamingPlayer = DirectStreamingPlayer()
        super.init(coder: coder)
        self.streamingPlayer.setDelegate(self)
    }
    
    private var isPlaying = false
    private var isManualPause = false
    private var hasPermanentPlaybackError = false
    private var networkMonitor: NWPathMonitor?
    private var networkMonitorHandler: ((NWPath) -> Void)? // Store handler to clear it
    private var hasInternetConnection = true
    private var connectivityCheckTimer: Timer?
    private var lastConnectionAttemptTime: Date?
    private var didInitialLayout = false
    private var didPositionNeedle = false
    private let audioEngine = AVAudioEngine()
    private var tuningPlayerNode: AVAudioPlayerNode?
    private var tuningBuffer: AVAudioPCMBuffer?
    private var isTuningSoundPlaying = false
    private var streamSwitchTimer: Timer?
    private var pendingStreamIndex: Int?
    private var lastPlaybackAttempt: Date?
    private let minPlaybackInterval: TimeInterval = 1.0 // 1 second
    private var isDeallocating = false // Flag to prevent operations during deallocation
    
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
        let languageCode = currentLocale.language.languageCode?.identifier ?? "en"
        let initialIndex = DirectStreamingPlayer.availableStreams.firstIndex(where: { $0.languageCode == languageCode }) ?? 0
        #if DEBUG
        print("📱 viewDidLoad: Locale languageCode=\(languageCode), initialIndex=\(initialIndex), stream=\(DirectStreamingPlayer.availableStreams[initialIndex].language)")
        #endif
        
        streamingPlayer.setStream(to: DirectStreamingPlayer.availableStreams[initialIndex])
        updateBackground(for: DirectStreamingPlayer.availableStreams[initialIndex])
        
        if let layout = languageCollectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            layout.scrollDirection = .horizontal
            layout.minimumLineSpacing = 10
            layout.minimumInteritemSpacing = 0
        }
        
        languageCollectionView.reloadData()
        languageCollectionView.layoutIfNeeded()
        
        let indexPath = IndexPath(item: initialIndex, section: 0)
        languageCollectionView.selectItem(at: indexPath, animated: false, scrollPosition: .centeredHorizontally)
        centerCollectionViewContent()
        languageCollectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: false)
        updateSelectionIndicator(to: initialIndex, isInitial: true)
        
        // Defer unlocking until layout is complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.isInitialScrollLocked = false
            #if DEBUG
            print("📱 Initial scroll lock released")
            #endif
        }
        
        #if DEBUG
        if let selectedIndexPath = languageCollectionView.indexPathsForSelectedItems?.first {
            print("📱 viewDidLoad: Selected indexPath=\(selectedIndexPath.item), expected=\(initialIndex)")
        } else {
            print("📱 viewDidLoad: No selected item after initialization")
        }
        print("📱 viewDidLoad: Selection indicator center.x=\(selectionIndicator.center.x)")
        #endif
        
        setupControls()
        setupNetworkMonitoring()
        setupBackgroundAudioControls()
        setupInterruptionHandling()
        setupRouteChangeHandling()
        setupStreamingCallbacks()
        setupAudioEngine()
        
        isInitialSetupComplete = true // Mark setup complete after all UI updates
        setupBackgroundParallax()

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
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                let indexPath = IndexPath(item: initialIndex, section: 0)
                self.languageCollectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: true)
                // Ensure indicator stays put
                self.updateSelectionIndicator(to: initialIndex, isInitial: true)
            }
        }
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Remove notification observers early to prevent them from firing during deallocation
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
    }
    
    private func setupStreamingCallbacks() {
        streamingPlayer.onStatusChange = { [weak self] isPlaying, statusText in
            guard let self = self else {
                #if DEBUG
                print("📱 onStatusChange: ViewController is nil, skipping callback")
                #endif
                return
            }
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
            guard let self = self else {
                #if DEBUG
                print("📱 onMetadataChange: ViewController is nil, skipping callback")
                #endif
                return
            }
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
        guard languageCollectionView.bounds.width > 0, DirectStreamingPlayer.availableStreams.count > 0 else {
            #if DEBUG
            print("📱 centerCollectionViewContent: Invalid bounds or no streams, width=\(languageCollectionView.bounds.width)")
            #endif
            return
        }
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
        #if DEBUG
        print("📱 centerCollectionViewContent: totalCellWidth=\(totalCellWidth), collectionViewWidth=\(collectionViewWidth), inset=\(inset)")
        #endif
    }
    
    private func setupNetworkMonitoring() {
        networkMonitor?.cancel()
        networkMonitor = nil
        networkMonitor = NWPathMonitor()
        #if DEBUG
        print("📱 Setting up network monitoring")
        #endif
        networkMonitorHandler = { [weak self] path in
            guard let self = self else {
                #if DEBUG
                print("📱 pathUpdateHandler: ViewController is nil, skipping callback")
                #endif
                return
            }
            let isConnected = path.status == .satisfied
            DispatchQueue.main.async {
                let wasConnected = self.hasInternetConnection
                self.hasInternetConnection = isConnected
                #if DEBUG
                print("📱 Network path update: status=\(path.status), isExpensive=\(path.isExpensive), isConstrained=\(path.isConstrained)")
                #endif
                if isConnected != wasConnected {
                    #if DEBUG
                    print("📱 Network status changed: \(isConnected ? "Connected" : "Disconnected")")
                    print("📱 isManualPause: \(self.isManualPause)")
                    #endif
                }
                if isConnected && !wasConnected {
                    #if DEBUG
                    print("📱 Network monitor detected reconnection")
                    #endif
                    self.stopTuningSound()
                    self.handleNetworkReconnection()
                } else if !isConnected && wasConnected {
                    #if DEBUG
                    print("📱 Network disconnected - stopping playback and tuning sound")
                    #endif
                    self.stopTuningSound()
                    let wasPlayingBeforeDisconnect = self.isPlaying
                    self.stopPlayback()
                    self.updateUIForNoInternet()
                    self.isManualPause = self.isManualPause && !wasPlayingBeforeDisconnect
                    self.audioEngine.pause()
                }
            }
        }
        networkMonitor?.pathUpdateHandler = networkMonitorHandler
        let monitorQueue = DispatchQueue(label: "NetworkMonitor", qos: .utility)
        networkMonitor?.start(queue: monitorQueue)
        setupConnectivityCheckTimer()
    }
    
    private func setupInterruptionHandling() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil)
    }
    
    @objc private func handleInterruption(_ notification: Notification) {
        guard !isDeallocating else {
            #if DEBUG
            print("📱 handleInterruption: ViewController is deallocating, skipping")
            #endif
            return
        }
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
        guard !isDeallocating else {
            #if DEBUG
            print("📱 handleRouteChange: ViewController is deallocating, skipping")
            #endif
            return
        }
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
        guard !isDeallocating else { return }
        connectivityCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else {
                #if DEBUG
                print("📱 connectivityCheckTimer: ViewController is nil, skipping callback")
                #endif
                return
            }
            self.performActiveConnectivityCheck()
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
            guard let self = self else {
                #if DEBUG
                print("📱 performActiveConnectivityCheck: ViewController is nil, skipping callback")
                #endif
                return
            }
            let success = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                if success && !self.hasInternetConnection {
                    #if DEBUG
                    print("📱 Active check detected internet connection")
                    #endif
                    self.hasInternetConnection = true
                    self.handleNetworkReconnection()
                }
            }
        }
        task.resume()
    }
    
    private func handleNetworkReconnection() {
        if !isManualPause && !hasPermanentPlaybackError {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self = self else {
                    #if DEBUG
                    print("📱 handleNetworkReconnection: ViewController is nil, skipping callback")
                    #endif
                    return
                }
                if self.hasInternetConnection && !self.isPlaying && !self.isManualPause && !self.hasPermanentPlaybackError {
                    #if DEBUG
                    print("📱 Auto-restarting playback after reconnection")
                    #endif
                    self.isTuningSoundPlaying = false
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
            guard let self = self else {
                #if DEBUG
                print("📱 playCommand: ViewController is nil, skipping callback")
                #endif
                return .commandFailed
            }
            DispatchQueue.main.async { self.startPlayback() }
            return .success
        }
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
            guard let self = self else {
                #if DEBUG
                print("📱 pauseCommand: ViewController is nil, skipping callback")
                #endif
                return .commandFailed
            }
            DispatchQueue.main.async { self.pausePlayback() }
            return .success
        }
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
            guard let self = self else {
                #if DEBUG
                print("📱 togglePlayPauseCommand: ViewController is nil, skipping callback")
                #endif
                return .commandFailed
            }
            DispatchQueue.main.async {
                if self.isPlaying { self.pausePlayback() } else { self.startPlayback() }
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
        #if DEBUG
        print("📱 startPlayback called - hasInternet: \(hasInternetConnection), isManualPause: \(isManualPause), isTuningSoundPlaying: \(isTuningSoundPlaying)")
        #endif
        
        if !hasInternetConnection {
            updateUIForNoInternet()
            stopTuningSound()
            performActiveConnectivityCheck()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self else {
                    #if DEBUG
                    print("📱 startPlayback (asyncAfter): ViewController is nil, skipping callback")
                    #endif
                    return
                }
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
            #if DEBUG
            print("📱 Aborting playback attempt \(attempt) - no internet, manually paused, or previous permanent error")
            #endif
            if hasPermanentPlaybackError { streamingPlayer.onStatusChange?(false, String(localized: "status_stream_unavailable")) }
            return
        }
        let now = Date()
        if let lastAttempt = lastPlaybackAttempt, now.timeIntervalSince(lastAttempt) < minPlaybackInterval {
            DispatchQueue.main.asyncAfter(deadline: .now() + minPlaybackInterval) { [weak self] in
                guard let self = self else {
                    #if DEBUG
                    print("📱 attemptPlaybackWithRetry (asyncAfter): ViewController is nil, skipping callback")
                    #endif
                    return
                }
                self.attemptPlaybackWithRetry(attempt: attempt, maxAttempts: maxAttempts)
            }
            return
        }
        
        lastPlaybackAttempt = now
        #if DEBUG
        print("📱 Playback attempt \(attempt)/\(maxAttempts)")
        #endif
        let delay = pow(2.0, Double(attempt-1))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else {
                #if DEBUG
                print("📱 attemptPlaybackWithRetry (asyncAfter): ViewController is nil, skipping callback")
                #endif
                return
            }
            self.streamingPlayer.setVolume(self.volumeSlider.value)
            self.streamingPlayer.play { [weak self] success in
                guard let self = self else {
                    #if DEBUG
                    print("📱 play (completion): ViewController is nil, skipping callback")
                    #endif
                    return
                }
                if success {
                    #if DEBUG
                    print("📱 Playback succeeded on attempt \(attempt)")
                    #endif
                } else {
                    if self.streamingPlayer.isLastErrorPermanent() {
                        #if DEBUG
                        print("📱 Permanent error detected - stopping retries")
                        #endif
                        self.hasPermanentPlaybackError = true
                        self.streamingPlayer.onStatusChange?(false, String(localized: "status_stream_unavailable"))
                        self.statusLabel.text = String(localized: "status_stream_unavailable")
                        self.statusLabel.backgroundColor = .systemOrange
                        self.statusLabel.textColor = .white
                    } else if attempt < maxAttempts {
                        #if DEBUG
                        print("📱 Playback attempt \(attempt) failed, retrying...")
                        #endif
                        self.attemptPlaybackWithRetry(attempt: attempt + 1, maxAttempts: maxAttempts)
                    } else {
                        #if DEBUG
                        print("📱 Max attempts (\(maxAttempts)) reached - giving up")
                        #endif
                        self.streamingPlayer.onStatusChange?(false, String(localized: "alert_connection_failed_title"))
                        self.statusLabel.text = String(localized: "alert_connection_failed_title")
                        self.statusLabel.backgroundColor = .systemRed
                        self.statusLabel.textColor = .white
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
    
    private func setupBackgroundParallax() {
        backgroundImageView.addParallaxEffect(intensity: 10.0)
    }
    
    private func updateBackground(for stream: DirectStreamingPlayer.Stream) {
        guard let imageName = backgroundImages[stream.languageCode],
              let baseImage = UIImage(named: imageName) else {
            print("Error: Background image not found for \(stream.languageCode)")
            backgroundImageView.image = nil
            return
        }

        var finalImage: UIImage = baseImage

        if let ciImage = CIImage(image: baseImage) {
            var processedImage = ciImage
            let context = CIContext(options: nil) // Explicit context for rendering

            #if DEBUG
            print("Processing image for \(stream.languageCode), mode: \(traitCollection.userInterfaceStyle == .dark ? "dark" : "light")")
            #endif

            if traitCollection.userInterfaceStyle == .dark {
                // Dark mode: Invert colors, then adjust brightness and contrast
                if let invertFilter = CIFilter(name: "CIColorInvert") {
                    invertFilter.setValue(processedImage, forKey: kCIInputImageKey)
                    if let outputImage = invertFilter.outputImage {
                        processedImage = outputImage
                        #if DEBUG
                        print("Dark mode: Applied CIColorInvert - extent: \(processedImage.extent)")
                        #endif
                    } else {
                        #if DEBUG
                        print("Dark mode: Failed to apply CIColorInvert")
                        #endif
                    }
                }

                if let controlsFilter = CIFilter(name: "CIColorControls") {
                    controlsFilter.setValue(processedImage, forKey: kCIInputImageKey)
                    controlsFilter.setValue(1.3, forKey: kCIInputContrastKey) // Increase contrast
                    controlsFilter.setValue(0.2, forKey: kCIInputBrightnessKey) // Boost brightness
                    if let outputImage = controlsFilter.outputImage {
                        processedImage = outputImage
                        #if DEBUG
                        print("Dark mode: Applied CIColorControls - extent: \(processedImage.extent)")
                        #endif
                    } else {
                        #if DEBUG
                        print("Dark mode: Failed to apply CIColorControls")
                        #endif
                    }
                }

                if let dilateFilter = CIFilter(name: "CIMorphologyMaximum") {
                    dilateFilter.setValue(processedImage, forKey: kCIInputImageKey)
                    dilateFilter.setValue(4.0, forKey: kCIInputRadiusKey)
                    if let outputImage = dilateFilter.outputImage {
                        processedImage = outputImage
                        #if DEBUG
                        print("Dark mode: Applied CIMorphologyMaximum - extent: \(processedImage.extent)")
                        #endif
                    } else {
                        #if DEBUG
                        print("Dark mode: Failed to apply CIMorphologyMaximum")
                        #endif
                    }
                }
            } else {
                if let controlsFilter = CIFilter(name: "CIColorControls") {
                    controlsFilter.setValue(processedImage, forKey: kCIInputImageKey)
                    controlsFilter.setValue(1.3, forKey: kCIInputContrastKey) // Increase contrast
                    controlsFilter.setValue(-0.2, forKey: kCIInputBrightnessKey) // Reduce brightness
                    if let outputImage = controlsFilter.outputImage {
                        processedImage = outputImage
                        #if DEBUG
                        print("Light mode: Applied CIColorControls - extent: \(processedImage.extent)")
                        #endif
                    } else {
                        #if DEBUG
                        print("Light mode: Failed to apply CIColorControls")
                        #endif
                    }
                }

                if let dilateFilter = CIFilter(name: "CIMorphologyMaximum") {
                    dilateFilter.setValue(processedImage, forKey: kCIInputImageKey)
                    dilateFilter.setValue(5.0, forKey: kCIInputRadiusKey) // Increased radius for more thickening
                    if let outputImage = dilateFilter.outputImage {
                        processedImage = outputImage
                        #if DEBUG
                        print("Light mode: Applied CIMorphologyMaximum - extent: \(processedImage.extent)")
                        #endif
                    } else {
                        #if DEBUG
                        print("Light mode: Failed to apply CIMorphologyMaximum")
                        #endif
                    }
                }

                if let erodeFilter = CIFilter(name: "CIMorphologyMinimum") {
                    erodeFilter.setValue(processedImage, forKey: kCIInputImageKey)
                    erodeFilter.setValue(1.0, forKey: kCIInputRadiusKey) // Light refinement
                    if let outputImage = erodeFilter.outputImage {
                        processedImage = outputImage
                        #if DEBUG
                        print("Light mode: Applied CIMorphologyMinimum - extent: \(processedImage.extent)")
                        #endif
                    } else {
                        #if DEBUG
                        print("Light mode: Failed to apply CIMorphologyMinimum")
                        #endif
                    }
                }
            }

            // Convert back to UIImage
            if let cgImage = context.createCGImage(processedImage, from: processedImage.extent) {
                finalImage = UIImage(cgImage: cgImage)
                #if DEBUG
                print("Successfully converted processed image to UIImage - size: \(finalImage.size)")
                #endif
            } else {
                #if DEBUG
                print("Failed to convert CIImage to CGImage - using base image as fallback")
                #endif
                finalImage = baseImage // Fallback to base image
            }
        } else {
            #if DEBUG
            print("Failed to create CIImage from baseImage - using base image as fallback")
            #endif
        }

        // Adjust for smaller screens
        let screenSize = UIScreen.main.bounds.size
        let isSmallScreen = screenSize.height < 1600
        backgroundImageView.contentMode = .scaleAspectFill
        backgroundImageView.image = finalImage
        
        if isSmallScreen {
            let imageSize = baseImage.size
            let screenAspect = screenSize.width / screenSize.height
            let imageAspect = imageSize.width / imageSize.height
            let scaleFactor = min(0.85, screenAspect / imageAspect) // Cap at 85% to avoid over-thinning
            backgroundImageView.transform = CGAffineTransform(scaleX: scaleFactor, y: scaleFactor)
        } else {
            backgroundImageView.transform = .identity
        }
        
        // Reapply parallax effect after updating the image
        backgroundImageView.addParallaxEffect(intensity: 10.0)

        // Adjust alpha based on mode for better visibility
        UIView.transition(with: backgroundImageView, duration: 0.5, options: .transitionCrossDissolve, animations: {
            self.backgroundImageView.alpha = self.traitCollection.userInterfaceStyle == .dark ? 0.3 : 0.15
        }, completion: { _ in
            #if DEBUG
            print("Background update completed - alpha: \(self.backgroundImageView.alpha), image: \(self.backgroundImageView.image != nil ? "set" : "nil")")
            #endif
        })
    }
    
    private func setupUI() {
        view.addSubview(backgroundImageView)
        backgroundConstraints = [
            backgroundImageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: -20),
            backgroundImageView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: 20),
            backgroundImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: -20),
            backgroundImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 20)
        ]
        NSLayoutConstraint.activate(backgroundConstraints)
        backgroundImageView.layer.zPosition = -1
        
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
        
        #if DEBUG
        print("🎵 Setting up audio engine - current state: isRunning=\(audioEngine.isRunning)")
        #endif
        
        // Pre-generate tuning sound buffer with shortwave-like effect
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let duration: Float = 0.5 // 0.5 seconds total duration
        let frameCount = AVAudioFrameCount(Double(duration) * format.sampleRate) // Convert duration to Double
        tuningBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        tuningBuffer?.frameLength = frameCount
        
        let sampleRate = Float(format.sampleRate)
        let amplitude = Float(0.1)
        let audioBuffer = tuningBuffer!.floatChannelData!
        
        // Divide the buffer into short segments (e.g., 0.012 seconds each) with random frequencies
        let segmentDuration: Float = 0.012 // 12ms segments
        let framesPerSegment = Int(segmentDuration * sampleRate)
        let totalSegments = Int(frameCount) / framesPerSegment
        
        for segment in 0..<totalSegments {
            let startFrame = segment * framesPerSegment
            let endFrame = min(startFrame + framesPerSegment, Int(frameCount))
            let frequency = Float.random(in: 500...1500) // Random frequency per segment
            
            for frame in startFrame..<endFrame {
                let time = Float(frame) / sampleRate
                let noise = Float.random(in: -0.05...0.05)
                let value = sinf(2.0 * .pi * frequency * time) * amplitude + noise
                for channel in 0..<Int(format.channelCount) {
                    audioBuffer[channel][frame] = value
                }
            }
        }
        
        // Fill any remaining frames (if frameCount isn't perfectly divisible by framesPerSegment)
        let lastSegmentEnd = totalSegments * framesPerSegment
        if lastSegmentEnd < Int(frameCount) {
            let frequency = Float.random(in: 500...1500)
            for frame in lastSegmentEnd..<Int(frameCount) {
                let time = Float(frame) / sampleRate
                let noise = Float.random(in: -0.05...0.05)
                let value = sinf(2.0 * .pi * frequency * time) * amplitude + noise
                for channel in 0..<Int(format.channelCount) {
                    audioBuffer[channel][frame] = value
                }
            }
        }
        
        do {
            try audioEngine.start()
            #if DEBUG
            print("🎵 Audio engine started successfully")
            #endif
        } catch {
            #if DEBUG
            print("🎵 Failed to start audio engine: \(error.localizedDescription)")
            #endif
        }
    }
    
    private func playTuningSound() {
        #if DEBUG
        print("🎵 playTuningSound called - isTuningSoundPlaying: \(isTuningSoundPlaying), hasInternetConnection: \(hasInternetConnection), audioEngine.isRunning: \(audioEngine.isRunning)")
        #endif
        
        guard !isTuningSoundPlaying, hasInternetConnection else {
            #if DEBUG
            print("🎵 Skipping tuning sound: already playing (\(isTuningSoundPlaying)) or offline (\(!hasInternetConnection))")
            #endif
            return
        }
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else {
                #if DEBUG
                print("🎵 playTuningSound (workItem): ViewController is nil, skipping")
                #endif
                return
            }
            
            #if DEBUG
            print("🎵 Executing tuning sound work item - audioEngine.isRunning: \(self.audioEngine.isRunning)")
            #endif
            
            if !self.audioEngine.isRunning {
                do {
                    try self.audioEngine.start()
                    #if DEBUG
                    print("🎵 Audio engine started successfully")
                    #endif
                } catch {
                    #if DEBUG
                    print("🎵 Failed to start audio engine: \(error.localizedDescription)")
                    #endif
                    return
                }
            }
            
            self.isTuningSoundPlaying = true
            #if DEBUG
            print("🎵 Tuning sound marked as playing")
            #endif
            
            // Cleanup existing node if present
            if let existingNode = self.tuningPlayerNode {
                self.audioEngine.disconnectNodeOutput(existingNode)
                self.audioEngine.detach(existingNode)
            }
            
            let playerNode = AVAudioPlayerNode()
            self.tuningPlayerNode = playerNode
            
            #if DEBUG
            print("🎵 Attaching and connecting tuning player node")
            #endif
            self.audioEngine.attach(playerNode)
            self.audioEngine.connect(playerNode, to: self.audioEngine.mainMixerNode, format: self.tuningBuffer!.format)
            playerNode.volume = 0.5
            
            guard let buffer = self.tuningBuffer else {
                #if DEBUG
                print("🎵 Tuning buffer is nil, aborting")
                #endif
                self.isTuningSoundPlaying = false
                return
            }
            
            playerNode.scheduleBuffer(buffer, completionHandler: { [weak self] in
                guard let self = self else { return }
                self.stopTuningSound()
            })
            
            #if DEBUG
            print("🎵 Playing tuning sound")
            #endif
            playerNode.play()
        }
        
        #if DEBUG
        print("🎵 Queuing tuning sound work item on audioQueue")
        #endif
        audioQueue.async(execute: workItem)
    }
    
    private func stopTuningSound() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else {
                #if DEBUG
                print("🎵 stopTuningSound: ViewController is nil, skipping")
                #endif
                return
            }
            
            #if DEBUG
            print("🎵 stopTuningSound called - isTuningSoundPlaying: \(self.isTuningSoundPlaying), hasNode: \(self.tuningPlayerNode != nil), audioEngine.isRunning: \(self.audioEngine.isRunning)")
            #endif
            
            guard self.isTuningSoundPlaying, let node = self.tuningPlayerNode else {
            #if DEBUG
                print("🎵 stopTuningSound: Not playing or no node, skipping cleanup")
            #endif
                return
            }
            
            node.stop()
            self.audioEngine.disconnectNodeOutput(node)
            self.audioEngine.detach(node)
            self.isTuningSoundPlaying = false
            self.tuningPlayerNode = nil
            
            #if DEBUG
            print("🎵 Tuning sound stopped and cleaned up")
            #endif
            
            if !self.isPlaying && !self.isDeallocating && self.audioEngine.isRunning && !self.hasInternetConnection {
                self.audioEngine.stop()
                #if DEBUG
                print("🎵 Audio engine stopped (no streaming active and offline)")
                #endif
            }
        }
        
        #if DEBUG
        print("🎵 Queuing stopTuningSound work item on audioQueue")
        #endif
        audioQueue.async(execute: workItem)
    }
    
    // MARK: - Selection Indicator
    private func updateSelectionIndicator(to index: Int, isInitial: Bool = false) {
        guard index >= 0 && index < DirectStreamingPlayer.availableStreams.count else {
            #if DEBUG
            print("📱 updateSelectionIndicator: Invalid index \(index), streams count=\(DirectStreamingPlayer.availableStreams.count)")
            #endif
            return
        }
        let indexPath = IndexPath(item: index, section: 0)
        languageCollectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: !isInitial)
        languageCollectionView.layoutIfNeeded()
        if let layoutAttributes = languageCollectionView.layoutAttributesForItem(at: indexPath) {
            let cellFrame = layoutAttributes.frame
            let cellCenterX = cellFrame.midX
            #if DEBUG
            print("📱 updateSelectionIndicator: Moving to index=\(index), cellCenterX=\(cellCenterX), cellFrame=\(cellFrame), isInitial=\(isInitial), caller=\(Thread.callStackSymbols[1])")
            #endif
            UIView.animate(withDuration: isInitial ? 0.0 : 0.3) {
                self.selectionIndicator.center.x = cellCenterX
                self.selectionIndicator.transform = isInitial ? .identity : CGAffineTransform(scaleX: 1.5, y: 1.0)
            } completion: { _ in
                if !isInitial {
                    UIView.animate(withDuration: 0.1) {
                        self.selectionIndicator.transform = .identity
                    }
                }
                #if DEBUG
                print("📱 updateSelectionIndicator: Animation completed, final center.x=\(self.selectionIndicator.center.x)")
                #endif
            }
        } else {
            #if DEBUG
            print("📱 updateSelectionIndicator: No layout attributes for indexPath=\(indexPath)")
            #endif
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
        guard !isDeallocating else { return }
        #if DEBUG
        print("📱 collectionView:didSelectItemAt called for index \(indexPath.item)")
        #endif
        let stream = DirectStreamingPlayer.availableStreams[indexPath.item]
        updateBackground(for: stream)
        streamSwitchTimer?.invalidate()
        pendingStreamIndex = indexPath.item
        streamSwitchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self = self, let index = self.pendingStreamIndex else {
                #if DEBUG
                print("📱 streamSwitchTimer: ViewController is nil, skipping")
                #endif
                return
            }
            #if DEBUG
            print("📱 streamSwitchTimer: Fired for index \(index)")
            #endif
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            self.playTuningSound()
            self.streamingPlayer.setStream(to: DirectStreamingPlayer.availableStreams[index])
            self.hasPermanentPlaybackError = false
            if self.isPlaying || !self.isManualPause { self.startPlayback() }
            self.updateSelectionIndicator(to: index)
            collectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: true)
            self.pendingStreamIndex = nil
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
        isDeallocating = true
        networkMonitor?.pathUpdateHandler = nil
        networkMonitorHandler = nil
        networkMonitor?.cancel()
        networkMonitor = nil
        
        connectivityCheckTimer?.invalidate()
        connectivityCheckTimer = nil
        streamSwitchTimer?.invalidate()
        streamSwitchTimer = nil
        
        streamingPlayer.clearCallbacks()
        streamingPlayer.stop()
        
        if audioEngine.isRunning {
            audioEngine.stop()
            #if DEBUG
            print("🎵 Audio engine stopped in deinit")
            #endif
        }
        if let node = tuningPlayerNode {
            audioEngine.detach(node)
            tuningPlayerNode = nil
        }
    }
}

extension ViewController {
    // MARK: - ScrollView Delegate
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard !isInitialScrollLocked else {
            #if DEBUG
            print("📱 scrollViewWillEndDragging: Scroll locked during initial setup")
            #endif
            return
        }
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
            #if DEBUG
            print("📱 scrollViewWillEndDragging: Scroll ended at index \(indexPath.item), centered at \(centerX)")
            #endif
        }
    }
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard !isInitialScrollLocked else {
            #if DEBUG
            print("📱 scrollViewDidEndDecelerating: Scroll locked during initial setup")
            #endif
            return
        }
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
            let stream = DirectStreamingPlayer.availableStreams[closestIndex]
            updateBackground(for: stream)
            languageCollectionView.selectItem(at: indexPath, animated: true, scrollPosition: .centeredHorizontally)
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            playTuningSound()
            updateSelectionIndicator(to: closestIndex)
            let selectedStream = DirectStreamingPlayer.availableStreams[closestIndex]
            streamingPlayer.setStream(to: selectedStream)
            hasPermanentPlaybackError = false
            if isPlaying || !isManualPause { startPlayback() }
            #if DEBUG
            print("📱 scrollViewDidEndDecelerating: Selected closest index \(closestIndex), centerX=\(centerX)")
            #endif
        }
    }
    
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scrollViewDidEndDecelerating(scrollView)
    }
}
