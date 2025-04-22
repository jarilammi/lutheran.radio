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
import CoreImage

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
    
    private static let imageProcessingContext = CIContext(options: nil)
    
    private let backgroundImages: [String: String] = [
        "en": "north_america",
        "de": "germany",
        "fi": "finland",
        "sv": "sweden",
        "ee": "estonia"
    ]
    private var backgroundConstraints: [NSLayoutConstraint] = []
    private var selectedStreamIndex: Int = 0
    private var lastRotationTime: Date? // To debounce rapid rotations
    private let rotationDebounceInterval: TimeInterval = 0.1 // 100ms
    
    private var isInitialSetupComplete = false
    private var isInitialScrollLocked = true
    private var hasShownDataUsageNotification = false
    private let hasDismissedDataUsageNotificationKey = "hasDismissedDataUsageNotification"
    
    let speakerImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isHidden = true // Hidden by default
        imageView.layer.cornerRadius = 10
        imageView.clipsToBounds = true
        return imageView
    }()
    
    private var speakerImageHeightConstraint: NSLayoutConstraint!
    
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
    private static var cachedTuningBuffer: AVAudioPCMBuffer?
    private var isTuningSoundPlaying = false
    private var streamSwitchTimer: Timer?
    private var streamSwitchWorkItem: DispatchWorkItem?
    private var lastStreamSwitchTime: Date?
    private let streamSwitchDebounceInterval: TimeInterval = 1.0
    private var pendingStreamIndex: Int?
    private var pendingPlaybackWorkItem: DispatchWorkItem?
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
    
    // MARK: - Lifecycle
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
        selectedStreamIndex = initialIndex // Set initial index
        streamingPlayer.setStream(to: DirectStreamingPlayer.availableStreams[initialIndex])
        updateBackground(for: DirectStreamingPlayer.availableStreams[initialIndex])
        
        languageCollectionView.reloadData()
        languageCollectionView.layoutIfNeeded()
        
        let indexPath = IndexPath(item: initialIndex, section: 0)
        languageCollectionView.selectItem(at: indexPath, animated: false, scrollPosition: .centeredHorizontally)
        centerCollectionViewContent()
        languageCollectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: false)
        updateSelectionIndicator(to: initialIndex, isInitial: true)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.isInitialScrollLocked = false
        }
        
        setupControls()
        setupNetworkMonitoring()
        setupBackgroundAudioControls()
        setupInterruptionHandling()
        setupRouteChangeHandling()
        setupStreamingCallbacks()
        setupAudioEngine()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        
        isInitialSetupComplete = true
        setupBackgroundParallax()

        // Defer playback until after initial validation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.hasInternetConnection && !self.isManualPause else { return }
            self.startPlayback()
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
                self.statusLabel.backgroundColor = .systemGreen
                self.statusLabel.textColor = .black
            } else {
                self.statusLabel.text = statusText
                if statusText == String(localized: "status_security_failed") {
                    self.hasPermanentPlaybackError = true
                    self.isManualPause = true
                    self.statusLabel.backgroundColor = .systemRed
                    self.statusLabel.textColor = .white
                    self.showSecurityModelAlert()
                } else if statusText == String(localized: "status_no_internet") {
                    self.statusLabel.backgroundColor = .systemGray
                    self.statusLabel.textColor = .white
                    self.updateUIForNoInternet()
                } else if statusText == String(localized: "status_stream_unavailable") {
                    self.statusLabel.backgroundColor = .systemOrange
                    self.statusLabel.textColor = .white
                    // Show alert if not already presenting
                    if self.presentedViewController == nil {
                        let alert = UIAlertController(
                            title: String(localized: "stream_unavailable_title"),
                            message: String(localized: "stream_unavailable_message"),
                            preferredStyle: .alert
                        )
                        alert.addAction(UIAlertAction(title: String(localized: "alert_retry"), style: .default) { _ in
                            self.hasPermanentPlaybackError = false
                            self.startPlayback()
                        })
                        alert.addAction(UIAlertAction(title: String(localized: "ok"), style: .cancel, handler: nil))
                        self.present(alert, animated: true)
                    }
                } else {
                    self.statusLabel.backgroundColor = self.isManualPause ? .systemGray : .systemYellow
                    self.statusLabel.textColor = .black
                }
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
                    
                    // Extract potential speaker names using regex
                    let regex = try? NSRegularExpression(pattern: "\\b[A-Z][a-z]+(?:\\s[A-Z][a-z]+)*\\b")
                    let matches = regex?.matches(in: metadata, range: NSRange(metadata.startIndex..., in: metadata))
                    let potentialNames = matches?.compactMap { match in
                        Range(match.range, in: metadata).map { String(metadata[$0]) }
                    }
                    
                    // Check for specific speakers or "Lutheran Radio"
                    let specificSpeakers = Set(["Jari Lammi"])
                    let matchedSpeaker = potentialNames?.first(where: { specificSpeakers.contains($0) })
                    
                    if let speaker = matchedSpeaker, let image = UIImage(named: speaker.lowercased().replacingOccurrences(of: " ", with: "_") + "_photo") {
                            UIView.transition(with: self.speakerImageView, duration: 0.3, options: .transitionCrossDissolve, animations: {
                                self.speakerImageView.image = image
                                self.speakerImageView.isHidden = false
                                self.speakerImageHeightConstraint.constant = 100
                                self.speakerImageView.accessibilityLabel = "Photo of \(speaker)"
                            }, completion: { _ in
                                #if DEBUG
                                print("Speaker image frame: \(self.speakerImageView.frame)")
                                print("Language collection view frame: \(self.languageCollectionView.frame)")
                                #endif
                            })
                        } else if potentialNames?.contains("Lutheran Radio") == true, let image = UIImage(named: "radio-placeholder") {
                            UIView.transition(with: self.speakerImageView, duration: 0.3, options: .transitionCrossDissolve, animations: {
                            self.speakerImageView.image = image
                            self.speakerImageView.isHidden = false
                            self.speakerImageHeightConstraint.constant = 100
                            self.speakerImageView.accessibilityLabel = "Lutheran Radio Logo"
                        }, completion: { _ in
                            #if DEBUG
                            print("Speaker image frame: \(self.speakerImageView.frame)")
                            print("Language collection view frame: \(self.languageCollectionView.frame)")
                            #endif
                        })
                    } else {
                        self.speakerImageView.isHidden = true
                    }
                } else {
                    self.metadataLabel.text = String(localized: "no_track_info")
                    self.updateNowPlayingInfo()
                    self.speakerImageView.isHidden = true
                }
            }
        }
    }
    
    private func showSecurityModelAlert() {
        let alert = UIAlertController(
            title: String(localized: "security_model_error_title"),
            message: String(localized: "security_model_error_message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "alert_retry"), style: .default, handler: { [weak self] _ in
            self?.streamingPlayer.resetTransientErrors()
            self?.streamingPlayer.validateSecurityModelAsync { isValid in
                if isValid {
                    self?.startPlayback()
                } else {
                    self?.showSecurityModelAlert()
                }
            }
        }))
        alert.addAction(UIAlertAction(title: String(localized: "ok"), style: .cancel, handler: nil))
        present(alert, animated: true, completion: nil)
    }
    
    private func setupControls() {
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        playPauseButton.accessibilityIdentifier = "playPauseButton"
        playPauseButton.accessibilityHint = String(localized: "accessibility_hint_play_pause")
        volumeSlider.addTarget(self, action: #selector(volumeChanged(_:)), for: .valueChanged)
        volumeSlider.accessibilityIdentifier = "volumeSlider"
        volumeSlider.accessibilityHint = String(localized: "accessibility_hint_volume")
        
        // Add AirPlay button tap feedback
        airplayButton.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(airplayTapped)))
    }

    @objc private func airplayTapped() {
        UIView.animate(withDuration: 0.1, animations: {
            self.airplayButton.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        }) { _ in
            UIView.animate(withDuration: 0.1) {
                self.airplayButton.transform = .identity
            }
        }
    }
    
    private func centerCollectionViewContent() {
        guard languageCollectionView.bounds.width > 0, DirectStreamingPlayer.availableStreams.count > 0 else {
            #if DEBUG
            print("📱 centerCollectionViewContent: Invalid bounds or no streams, width=\(languageCollectionView.bounds.width)")
            #endif
            return
        }
        languageCollectionView.layoutIfNeeded()
        guard let layout = languageCollectionView.collectionViewLayout as? UICollectionViewFlowLayout else {
            #if DEBUG
            print("📱 centerCollectionViewContent: Invalid layout, aborting")
            #endif
            return
        }
        let totalItems = DirectStreamingPlayer.availableStreams.count
        let cellWidth: CGFloat = 50
        let spacing: CGFloat = 10
        let totalCellWidth = (cellWidth * CGFloat(totalItems)) + (spacing * CGFloat(totalItems - 1))
        let collectionViewWidth = languageCollectionView.bounds.width
        let inset = max((collectionViewWidth - totalCellWidth) / 2, 0)
        layout.sectionInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        layout.invalidateLayout()
        
        #if DEBUG
        print("📱 centerCollectionViewContent: totalCellWidth=\(totalCellWidth), collectionViewWidth=\(collectionViewWidth), inset=\(inset), bounds=\(languageCollectionView.bounds)")
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
            let isExpensive = path.isExpensive
            DispatchQueue.main.async {
                // Mobile data notification logic
                if isConnected && isExpensive && !self.hasShownDataUsageNotification && !UserDefaults.standard.bool(forKey: self.hasDismissedDataUsageNotificationKey) {
                    self.showDataUsageNotification()
                    self.hasShownDataUsageNotification = true
                }

                // Existing network status handling
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
    
    private func showDataUsageNotification() {
        let alert = UIAlertController(
            title: String(localized: "mobile_data_usage_title"),
            message: String(localized: "mobile_data_usage_message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "ok"), style: .default, handler: nil))
        alert.addAction(UIAlertAction(title: String(localized: "dont_show_again"), style: .default, handler: { _ in
            UserDefaults.standard.set(true, forKey: self.hasDismissedDataUsageNotificationKey)
        }))
        present(alert, animated: true, completion: nil)
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
        hasInternetConnection = true
        #if DEBUG
        print("📱 Network reconnected - checking validation state")
        #endif
        streamingPlayer.validationState = .pending // Reset to allow retry
        streamingPlayer.hasPermanentError = false
        streamingPlayer.validateSecurityModelAsync { [weak self] isValid in
            guard let self = self else { return }
            if isValid {
                #if DEBUG
                print("📱 Validation succeeded after reconnection - attempting playback")
                #endif
                self.streamingPlayer.play { success in
                    if success {
                        self.streamingPlayer.onStatusChange?(true, String(localized: "status_playing"))
                    } else {
                        self.streamingPlayer.onStatusChange?(false, String(localized: "status_stream_unavailable"))
                    }
                }
            } else {
                #if DEBUG
                print("📱 Security model validation failed after reconnection")
                #endif
                self.streamingPlayer.onStatusChange?(false, String(localized: self.streamingPlayer.validationState == .failedPermanent ? "status_security_failed" : "status_no_internet"))
                // Show alert only if not already presenting
                if self.presentedViewController == nil {
                    let alert = UIAlertController(
                        title: String(localized: "security_model_error_title"),
                        message: String(localized: "security_model_error_message"),
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: String(localized: "ok"), style: .default))
                    self.present(alert, animated: true)
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
        if !hasInternetConnection {
            updateUIForNoInternet()
            stopTuningSound()
            performActiveConnectivityCheck()
            return
        }

        // Cancel any pending playback
        pendingPlaybackWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            isManualPause = false
            statusLabel.text = String(localized: "status_connecting")
            statusLabel.backgroundColor = .systemYellow
            statusLabel.textColor = .black

            streamingPlayer.validateSecurityModelAsync { isValid in
                if isValid {
                    self.streamingPlayer.resetTransientErrors()
                    self.streamingPlayer.play { success in
                        if success {
                            self.isPlaying = true
                            self.updatePlayPauseButton(isPlaying: true)
                            self.statusLabel.text = String(localized: "status_playing")
                            self.statusLabel.backgroundColor = .systemGreen
                        } else if self.streamingPlayer.isLastErrorPermanent() {
                            self.hasPermanentPlaybackError = true
                            self.statusLabel.text = String(localized: "status_stream_unavailable")
                            self.statusLabel.backgroundColor = .systemOrange
                            self.statusLabel.textColor = .white
                        } else {
                            self.attemptPlaybackWithRetry(attempt: 1, maxAttempts: 3)
                        }
                    }
                } else {
                    self.statusLabel.text = self.streamingPlayer.isLastErrorPermanent() ? String(localized: "status_security_failed") : String(localized: "status_no_internet")
                    self.statusLabel.backgroundColor = self.streamingPlayer.isLastErrorPermanent() ? .systemRed : .systemGray
                    self.statusLabel.textColor = .white
                    self.hasPermanentPlaybackError = self.streamingPlayer.isLastErrorPermanent()
                    if self.streamingPlayer.isLastErrorPermanent() {
                        self.showSecurityModelAlert()
                    }
                }
            }
        }
        pendingPlaybackWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
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
            let context = Self.imageProcessingContext

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
        
        view.addSubview(speakerImageView)
        let contentStackView = UIStackView(arrangedSubviews: [metadataLabel])
        contentStackView.axis = .vertical
        contentStackView.alignment = .center
        contentStackView.spacing = 10
        contentStackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentStackView)
        
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
            contentStackView.topAnchor.constraint(equalTo: volumeSlider.bottomAnchor, constant: 20),
            contentStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            contentStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            languageCollectionView.topAnchor.constraint(equalTo: contentStackView.bottomAnchor, constant: 20),
            languageCollectionView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            languageCollectionView.widthAnchor.constraint(equalTo: view.widthAnchor),
            languageCollectionView.heightAnchor.constraint(equalToConstant: 50),
            speakerImageView.topAnchor.constraint(equalTo: languageCollectionView.bottomAnchor, constant: 20),
            speakerImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            speakerImageView.widthAnchor.constraint(equalToConstant: 100),
            selectionIndicator.widthAnchor.constraint(equalToConstant: 4),
            selectionIndicator.heightAnchor.constraint(equalTo: languageCollectionView.heightAnchor, multiplier: 0.8),
            selectionIndicator.centerYAnchor.constraint(equalTo: languageCollectionView.centerYAnchor),
            airplayButton.topAnchor.constraint(equalTo: speakerImageView.bottomAnchor, constant: 20),
            airplayButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            airplayButton.widthAnchor.constraint(equalToConstant: 44),
            airplayButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        speakerImageHeightConstraint = speakerImageView.heightAnchor.constraint(equalToConstant: 50)
        speakerImageHeightConstraint.isActive = true
    }
    
    @objc private func handleMemoryWarning() {
        #if DEBUG
        print("🧹 Clearing cached tuning buffer due to memory warning")
        #endif
        Self.cachedTuningBuffer = nil
    }
    
    // MARK: - Audio Setup
    private func setupAudioEngine() {
        // Check for cached buffer first
        if let cachedBuffer = Self.cachedTuningBuffer {
            #if DEBUG
            print("🎵 Using cached tuning buffer")
            #endif
            tuningBuffer = cachedBuffer
            return
        }
        
        #if DEBUG
        print("🎵 Generating new tuning buffer")
        #endif
        
        let mainMixer = audioEngine.mainMixerNode
        mainMixer.volume = 1.0
        
        // Pre-generate tuning sound buffer with shortwave-like effect
        let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)! // Mono, 22.05kHz
        let duration: Float = 0.5 // 0.5 seconds total duration
        let frameCount = AVAudioFrameCount(Double(duration) * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            #if DEBUG
            print("🎵 Failed to create tuning buffer")
            #endif
            return
        }
        buffer.frameLength = frameCount
        
        let sampleRate = Float(format.sampleRate)
        let amplitude = Float(0.1)
        guard let audioBuffer = buffer.floatChannelData?.pointee else {
            #if DEBUG
            print("🎵 Failed to access audio buffer data")
            #endif
            return
        }
        
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
                audioBuffer[frame] = value
            }
        }
        
        // Fill any remaining frames
        let lastSegmentEnd = totalSegments * framesPerSegment
        if lastSegmentEnd < Int(frameCount) {
            let frequency = Float.random(in: 500...1500)
            for frame in lastSegmentEnd..<Int(frameCount) {
                let time = Float(frame) / sampleRate
                let noise = Float.random(in: -0.05...0.05)
                let value = sinf(2.0 * .pi * frequency * time) * amplitude + noise
                audioBuffer[frame] = value
            }
        }
        
        // Cache and assign buffer
        Self.cachedTuningBuffer = buffer
        tuningBuffer = buffer
        
        #if DEBUG
        print("🎵 Cached tuning buffer for future use")
        print("🎵 Setting up audio engine - current state: isRunning=\(audioEngine.isRunning)")
        #endif
    }
    
    private func playTuningSound() {
        guard let buffer = tuningBuffer, hasInternetConnection, !isTuningSoundPlaying else {
            #if DEBUG
            print("🎵 Skipping tuning sound: buffer=\(tuningBuffer != nil ? "present" : "nil"), hasInternetConnection=\(hasInternetConnection), isTuningSoundPlaying=\(isTuningSoundPlaying)")
            #endif
            return
        }
        
        audioQueue.async { [weak self] in
            guard let self = self else {
                #if DEBUG
                print("🎵 playTuningSound: ViewController is nil, skipping")
                #endif
                return
            }
            
            // Stop streaming player to avoid conflicts
            self.streamingPlayer.stop()
            
            // Prepare audio engine
            if !audioEngine.isRunning {
                do {
                    try audioEngine.start()
                    #if DEBUG
                    print("🎵 Audio engine started successfully")
                    #endif
                } catch {
                    #if DEBUG
                    print("🎵 Failed to start audio engine: \(error.localizedDescription)")
                    #endif
                    if self.isPlaying && !self.isManualPause {
                        self.streamingPlayer.play { _ in }
                    }
                    return
                }
            } else {
                #if DEBUG
                print("🎵 Audio engine already running")
                #endif
            }
            
            // Create or reuse player node
            if tuningPlayerNode == nil {
                let node = AVAudioPlayerNode()
                audioEngine.attach(node)
                audioEngine.connect(node, to: audioEngine.mainMixerNode, format: buffer.format)
                tuningPlayerNode = node
                #if DEBUG
                print("🎵 Created and connected new tuning player node")
                #endif
            }
            
            guard let playerNode = tuningPlayerNode else {
                #if DEBUG
                print("🎵 Tuning player node is nil, aborting")
                #endif
                if self.isPlaying && !self.isManualPause {
                    self.streamingPlayer.play { _ in }
                }
                return
            }
            
            #if DEBUG
            print("🎵 Scheduling cached tuning buffer")
            #endif
            
            playerNode.volume = 0.5
            playerNode.scheduleBuffer(buffer, completionHandler: { [weak self] in
                guard let self = self else { return }
                self.stopTuningSound()
                #if DEBUG
                print("🎵 Tuning sound completed")
                #endif
                // Resume playback if stream was playing
                if self.isPlaying && !self.isManualPause {
                    self.streamingPlayer.play { success in
                        if success {
                            self.streamingPlayer.onStatusChange?(true, String(localized: "status_playing"))
                        } else {
                            self.streamingPlayer.onStatusChange?(false, String(localized: "status_stream_unavailable"))
                        }
                    }
                }
            })
            
            playerNode.play()
            isTuningSoundPlaying = true
            #if DEBUG
            print("🎵 Tuning sound started")
            #endif
        }
    }
    
    private func stopTuningSound() {
        audioQueue.async { [weak self] in
            guard let self = self else {
                #if DEBUG
                print("🎵 stopTuningSound: ViewController is nil, skipping")
                #endif
                return
            }
            
            // Stop the tuning player node
            if let playerNode = tuningPlayerNode {
                playerNode.stop()
                #if DEBUG
                print("🎵 Tuning player node stopped")
                #endif
            }
            
            // Stop the audio engine
            if audioEngine.isRunning {
                audioEngine.stop()
                audioEngine.reset()
                #if DEBUG
                print("🎵 Audio engine stopped and reset")
                #endif
            }
            
            isTuningSoundPlaying = false
            #if DEBUG
            print("🎵 Tuning sound stopped, isTuningSoundPlaying set to false")
            #endif
        }
    }
    
    // MARK: - languageCollectionView
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        
        // Debounce rapid rotations
        let now = Date()
        if let lastTime = lastRotationTime, now.timeIntervalSince(lastTime) < rotationDebounceInterval {
            #if DEBUG
            print("📱 viewWillTransition: Debouncing rotation, time since last: \(now.timeIntervalSince(lastTime))s")
            #endif
            return
        }
        lastRotationTime = now
        
        #if DEBUG
        print("📱 viewWillTransition to size: \(size)")
        #endif
        
        // Verify selectedStreamIndex against the player's current stream
        if let currentStreamIndex = DirectStreamingPlayer.availableStreams.firstIndex(where: { $0.url == streamingPlayer.selectedStream.url }) {
            if currentStreamIndex != selectedStreamIndex {
                #if DEBUG
                print("📱 viewWillTransition: Correcting selectedStreamIndex from \(selectedStreamIndex) to \(currentStreamIndex)")
                #endif
                selectedStreamIndex = currentStreamIndex
            }
        }
        
        // Invalidate layout to prepare for new size
        languageCollectionView.collectionViewLayout.invalidateLayout()
        
        // Update layout during animation
        coordinator.animate(alongsideTransition: { [weak self] _ in
            guard let self = self else { return }
            self.centerCollectionViewContent()
            let indexPath = IndexPath(item: self.selectedStreamIndex, section: 0)
            self.languageCollectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: false)
            self.updateSelectionIndicator(to: self.selectedStreamIndex, isInitial: false)
        }, completion: { [weak self] _ in
            guard let self = self else { return }
            // Reload data after animation to ensure cells are up-to-date
            self.languageCollectionView.reloadData()
            self.languageCollectionView.layoutIfNeeded()
            self.updateSelectionIndicator(to: self.selectedStreamIndex, isInitial: false)
            #if DEBUG
            print("📱 Rotation completed, selected index: \(self.selectedStreamIndex)")
            #endif
        })
    }
    
    // MARK: - Selection Indicator
    private func updateSelectionIndicator(to index: Int, isInitial: Bool = false) {
        guard !isDeallocating else { return }
        guard index >= 0 && index < DirectStreamingPlayer.availableStreams.count else {
            #if DEBUG
            print("📱 updateSelectionIndicator: Invalid index \(index), streams count=\(DirectStreamingPlayer.availableStreams.count)")
            #endif
            return
        }
        
        // Ensure selectionIndicator is a subview of languageCollectionView
        if selectionIndicator.superview != languageCollectionView {
            #if DEBUG
            print("📱 updateSelectionIndicator: Reparenting selectionIndicator")
            #endif
            languageCollectionView.addSubview(selectionIndicator)
            selectionIndicator.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                selectionIndicator.widthAnchor.constraint(equalToConstant: 4),
                selectionIndicator.heightAnchor.constraint(equalTo: languageCollectionView.heightAnchor, multiplier: 0.8),
                selectionIndicator.centerYAnchor.constraint(equalTo: languageCollectionView.centerYAnchor)
            ])
        }
        
        let indexPath = IndexPath(item: index, section: 0)
        languageCollectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: !isInitial)
        languageCollectionView.layoutIfNeeded()
        
        if let layoutAttributes = languageCollectionView.layoutAttributesForItem(at: indexPath) {
            let cellFrame = layoutAttributes.frame
            var cellCenterX = cellFrame.midX
            
            // Clamp cellCenterX to collection view bounds
            let minX = languageCollectionView.bounds.minX + selectionIndicator.frame.width / 2
            let maxX = languageCollectionView.bounds.maxX - selectionIndicator.frame.width / 2
            cellCenterX = max(minX, min(maxX, cellCenterX))
            
            #if DEBUG
            print("📱 updateSelectionIndicator: Moving to index=\(index), cellCenterX=\(cellCenterX), cellFrame=\(cellFrame), collectionViewBounds=\(languageCollectionView.bounds), isInitial=\(isInitial), caller=\(Thread.callStackSymbols[1])")
            #endif
            
            // Skip animation if collection view isn't fully laid out
            guard languageCollectionView.bounds.width > 0 else {
                #if DEBUG
                print("📱 updateSelectionIndicator: Skipping animation, collection view not laid out")
                #endif
                selectionIndicator.center.x = cellCenterX
                return
            }
            
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
            // Fallback: Center in collection view
            let fallbackCenterX = languageCollectionView.bounds.midX
            #if DEBUG
            print("📱 updateSelectionIndicator: No layout attributes for indexPath=\(indexPath), using fallback centerX=\(fallbackCenterX), bounds=\(languageCollectionView.bounds)")
            #endif
            UIView.animate(withDuration: isInitial ? 0.0 : 0.3) {
                self.selectionIndicator.center.x = fallbackCenterX
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
        #if DEBUG
        print("📱 collectionView:didSelectItemAt called for index \(indexPath.item)")
        #endif

        // Debounce stream switch
        let now = Date()
        if let lastTime = lastStreamSwitchTime, now.timeIntervalSince(lastTime) < streamSwitchDebounceInterval {
            #if DEBUG
            print("📱 collectionView:didSelectItemAt: Debouncing stream switch, time since last: \(now.timeIntervalSince(lastTime))s")
            #endif
            return
        }
        lastStreamSwitchTime = now

        streamSwitchWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let stream = DirectStreamingPlayer.availableStreams[indexPath.item]
            updateBackground(for: stream)
            playTuningSound() // Play tuning sound immediately
            streamingPlayer.resetTransientErrors()
            streamingPlayer.setStream(to: stream)
            hasPermanentPlaybackError = false
            selectedStreamIndex = indexPath.item
            if isPlaying || !isManualPause { startPlayback() }
            updateSelectionIndicator(to: indexPath.item)
            collectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: true)
        }
        streamSwitchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
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
            selectedStreamIndex = indexPath.item
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
            selectedStreamIndex = closestIndex
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
