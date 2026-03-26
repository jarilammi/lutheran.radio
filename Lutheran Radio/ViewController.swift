//
//  ViewController.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.10.2024.
//

/// The main view controller for the Lutheran Radio app, handling UI, audio streaming, language selection, and background playback.
///
/// This class manages the app's core functionality, including:
/// - Streaming radio content in multiple languages (English, German, Finnish, Swedish, Estonian).
/// - UI elements for playback control, volume, metadata display, and AirPlay.
/// - Network monitoring, audio session management, and widget integration.
/// - iOS 26-specific optimizations like low-power mode handling and haptics.
///
/// Flow: viewDidLoad initializes UI/audio; user interactions trigger playback/stream switches; callbacks handle status/metadata updates.
///
/// Key dependencies: AVFoundation for audio, UIKit for UI, CoreHaptics for feedback.
///
/// - Note: This app is iOS 26+ only, leveraging features like ProcessInfo.isLowPowerModeEnabled. All user-facing strings are localized.
/// - SeeAlso: `DirectStreamingPlayer` for streaming logic, `SharedPlayerManager` for widget sharing.

/// - Article: Main UI and User Interaction Flow
///
/// `ViewController` orchestrates the app's interface: title, language selector (`LanguageCell.swift`), play/pause controls, volume, and metadata display. It handles iOS 26 features like parallax effects, haptics, and low-power mode (`updateForEnergyEfficiency()`).
/// - Stream Switching: Uses `DirectStreamingPlayer.isSwitchingStream` to suppress "stopped" status updates during language switches, preventing UI flicker and ensuring a seamless user experience.
/// - Haptics: Provides tactile feedback for play/pause and stream switching using `CHHapticEngine` with a fallback to `UIImpactFeedbackGenerator`. Skips haptics in Low Power Mode to conserve battery.
/// - Low Power Mode: Optimizes UI and processing (e.g., removes parallax, reduces image quality) when `ProcessInfo.processInfo.isLowPowerModeEnabled` is true.
///
/// Key Interactions:
/// - **Language Switching**: Uses `UICollectionView` with flags; updates stream in `DirectStreamingPlayer.swift` and saves to UserDefaults for widgets.
/// - **Playback**: Toggles via `togglePlayback()`; monitors network (`NWPathMonitor`) and shows data usage alerts on cellular.
/// - **Background Handling**: Integrates with `RadioLiveActivityManager.swift` for Live Activities on backgrounding; saves state via `SharedPlayerManager.swift`.
/// - **Widget/URL Handling**: Public methods like `handlePlayAction()` process schemes from `SceneDelegate.swift`.
///
/// Accessibility: VoiceOver announcements for status/metadata; hyphenation for long text. For lifecycle events, see `SceneDelegate.swift` and `AppDelegate.swift`.
import UIKit
import AVFoundation
import MediaPlayer
import AVKit
import Network
import CoreImage
import CoreHaptics
import WidgetKit
import Core

// MARK: - Parallax Effect Extension
/// Extends UIView with device motion-based parallax effects.
extension UIView {
    /// Adds horizontal and vertical tilt effects for a 3D-like appearance.
    /// - Parameter intensity: Magnitude of the tilt (e.g., 10.0 for subtle effect).
    /// - Note: Removes existing effects first to prevent conflicts.
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

/// The main view controller for the Lutheran Radio app.
@MainActor
class ViewController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSource, UIScrollViewDelegate, AVAudioPlayerDelegate {
    // MARK: - Private Properties and Constants
    /// Key for tracking if the user has dismissed the mobile data usage warning.
    /// - Note: Stored in standard UserDefaults for persistence across launches.
    private enum UserDefaultsKeys {
        static let hasDismissedDataUsageNotification = "hasDismissedDataUsageNotification"
    }
    
    private var lastWidgetUpdate: Date?
    private var lastWidgetSwitchTime: Date?
    private var pendingWidgetSwitchWorkItem: DispatchWorkItem?
    private var processedActionIds: Set<String> = []
    
    private var lastCollectionViewSize: CGSize = .zero
    
    /// Flag indicating if the device is in Low Power Mode (iOS 26+).
    /// - Returns: `true` if low power mode is enabled, triggering UI/processing optimizations.
    private var isLowEfficiencyMode: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    
    private func updateForEnergyEfficiency() {
        if isLowEfficiencyMode {
            // Reduce CPU/GPU usage: Remove parallax and lower image quality
            backgroundImageView.motionEffects.forEach { backgroundImageView.removeMotionEffect($0) }
            // Optionally, reduce alpha or hide non-essential UI elements if needed
        } else {
            // Re-enable parallax if it was set up
            setupBackgroundParallax()
        }
        // Trigger background update with current stream to apply image processing changes
        updateBackground(for: DirectStreamingPlayer.availableStreams[selectedStreamIndex])
    }
    
    // MARK: - UI Elements
    /// The main title label displaying "Lutheran Radio".
    /// - Accessibility: Labeled for VoiceOver with dynamic font support.
    let titleLabel: UILabel = {
        let label = UILabel()
        label.text = String(localized: "lutheran_radio_title")
        label.textAlignment = .center
        label.font = UIFont.preferredFont(forTextStyle: .title1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isAccessibilityElement = true
        label.accessibilityLabel = String(localized: "lutheran_radio_title")
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
        cv.isAccessibilityElement = false // Prevent the collection view itself from being focused; cells are accessible
        cv.accessibilityTraits = .none
        return cv
    }()
    
    let selectionIndicator: UIView = {
        let view = UIView()
        view.backgroundColor = .systemRed.withAlphaComponent(0.7)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isAccessibilityElement = false
        return view
    }()
    
    let playPauseButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(weight: .bold)
        button.setImage(UIImage(systemName: "play.fill", withConfiguration: config), for: .normal)
        button.tintColor = .tintColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isAccessibilityElement = true
        button.accessibilityTraits = .button
        button.accessibilityHint = String(localized: "accessibility_hint_play_pause")
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
        label.isAccessibilityElement = true
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
        slider.isAccessibilityElement = true
        slider.accessibilityLabel = String(localized: "accessibility_label_volume")
        slider.accessibilityHint = String(localized: "accessibility_hint_volume")
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
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        label.isAccessibilityElement = true
        label.accessibilityHint = String(localized: "accessibility_hint_metadata")
        return label
    }()
    
    let airplayButton: AVRoutePickerView = {
        let view = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        view.tintColor = .tintColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isAccessibilityElement = true
        view.accessibilityLabel = String(localized: "accessibility_label_airplay")
        view.accessibilityHint = String(localized: "accessibility_hint_airplay")
        return view
    }()
    
    // MARK: - Background and Image Processing
    private let backgroundImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = UIColor.gray
        imageView.alpha = 0.1
        imageView.isAccessibilityElement = false
        return imageView
    }()
    
    /// Mapping of language codes to background image asset names.
    /// - Note: Used for dynamic backgrounds based on selected stream.
    private let backgroundImages: [String: String] = [
        "en": "north_america",
        "de": "germany",
        "fi": "finland",
        "sv": "sweden",
        "et": "estonia"
    ]
    
    // MARK: - Haptic Engine
    /// Manages the `CHHapticEngine` for providing tactile feedback during user interactions (e.g., play/pause, stream switching).
    /// - Features:
    ///   - **Low Power Mode Support**: Skips haptics when `ProcessInfo.processInfo.isLowPowerModeEnabled` is true to conserve battery (iOS 26+ optimization).
    ///   - **Reset Handling**: Automatically restarts the engine on interruptions (e.g., app backgrounding) via `resetHandler`.
    ///   - **Stopped Handling**: Restarts the engine unless stopped due to fatal errors (`.systemError`) or destruction (`.engineDestroyed`).
    ///   - **Fallback Mechanism**: Uses `UIImpactFeedbackGenerator` if `CHHapticEngine` fails to ensure reliable feedback.
    ///   - **Hardware Check**: Verifies haptic support via `CHHapticEngine.capabilitiesForHardware().supportsHaptics` before initialization.
    /// - Note: Optimized for low-latency feedback with `playsHapticsOnly = true`. Debug logs provide detailed feedback on engine state.
    private lazy var hapticEngine: CHHapticEngine? = {
        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            
            // Reset handler – now correctly captures weak self inside the @MainActor Task
            engine.resetHandler = { [weak self] in
                do {
                    try self?.hapticEngine?.start()
                    
                    // Capture weak self HERE (Apple-recommended pattern for nonisolated → MainActor hop)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        #if DEBUG
                        print("✅ Haptic engine restarted after reset")
                        #endif
                    }
                } catch {
                    #if DEBUG
                    print("❌ Failed to restart haptic engine after reset: \(error)")
                    #endif
                }
            }
            
            // Stopped handler (unchanged – no self capture)
            engine.stoppedHandler = { reason in
                #if DEBUG
                print("⚠️ Haptic engine stopped: reason \(reason.rawValue)")
                #endif
                if reason != .systemError && reason != .engineDestroyed {
                    do {
                        try engine.start()
                        #if DEBUG
                        print("✅ Haptic engine auto-restarted")
                        #endif
                    } catch {
                        #if DEBUG
                        print("❌ Failed to auto-restart haptic engine: \(error)")
                        #endif
                    }
                }
            }
            return engine
        } catch {
            #if DEBUG
            print("❌ Haptics unavailable during creation: \(error)")
            #endif
            return nil
        }
    }()
    
    // MARK: - Image Processing
    private let imageProcessingQueue = DispatchQueue(label: "radio.lutheran.imageProcessing", qos: .utility)
    private let imageProcessingContext = CIContext(options: [.useSoftwareRenderer: false])
    /// Cache for processed background images to avoid redundant CIImage filtering.
    /// - Note: Limited to 5 items (one per language) to manage memory.
    private var processedImageCache = NSCache<NSString, UIImage>()
    private let cacheQueue = DispatchQueue(label: "radio.lutheran.imageCache", qos: .utility)
    
    private var backgroundConstraints: [NSLayoutConstraint] = []
    private var selectedStreamIndex: Int = 0
    private var isRotating = false
    private var lastRotationTime: Date? // To debounce rapid rotations
    private let rotationDebounceInterval: TimeInterval = 0.5 // 500ms
    
    private var isInitialSetupComplete = false
    private var isInitialScrollLocked = true
    private var hasShownDataUsageNotification = false
    
    let speakerImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isHidden = true // Hidden by default
        imageView.layer.cornerRadius = 10
        imageView.clipsToBounds = true
        imageView.isAccessibilityElement = false
        return imageView
    }()
    
    private var speakerImageHeightConstraint: NSLayoutConstraint!
    
    // MARK: - Audio and Streaming
    // New streaming player
    nonisolated private let streamingPlayer: DirectStreamingPlayer
    private let audioQueue = DispatchQueue(label: "radio.lutheran.audio", qos: .userInitiated)

    // Add initializer for testing
    init(streamingPlayer: DirectStreamingPlayer = DirectStreamingPlayer.shared) {
        self.streamingPlayer = streamingPlayer
        super.init(nibName: nil, bundle: nil)
        self.streamingPlayer.setDelegate(self)
    }

    required init?(coder: NSCoder) {
        self.streamingPlayer = DirectStreamingPlayer.shared
        super.init(coder: coder)
        self.streamingPlayer.setDelegate(self)
    }
    
    private let appLaunchTime = Date()
    private var hasEverPlayed = false
    private var isPlaying = false
    private var isManualPause = false
    private var hasPermanentPlaybackError = false
    private var networkMonitor: NWPathMonitor?
    private var networkMonitorHandler: (@Sendable (NWPath) -> Void)? // Store handler to clear it
    private var hasInternetConnection = true
    private var connectivityCheckTimer: Timer?
    private var lastConnectionAttemptTime: Date?
    private var didInitialLayout = false
    private var didPositionNeedle = false
    private var isTuningSoundPlaying = false
    private var tuningPlayer: AVAudioPlayer?
    private var lastTuningSoundTime: Date?
    private var streamSwitchWorkItem: DispatchWorkItem?
    private var lastStreamSwitchTime: Date?
    private let streamSwitchDebounceInterval: TimeInterval = 1.0
    private var pendingStreamIndex: Int?
    private var pendingPlaybackWorkItem: DispatchWorkItem?
    private var lastPlaybackAttempt: Date?
    private let minPlaybackInterval: TimeInterval = 1.0 // 1 second
    private var isDeallocating = false // Flag to prevent operations during deallocation
    private var hasPlayedSpecialTuningSound = false // Flag to ensure special sound plays only once
    
    // Testable accessors
    @objc var isPlayingState: Bool {
        get { isPlaying }
        set { isPlaying = newValue } // Add setter for testing
    }
    
    @objc var hasInternet: Bool {
        get { hasInternetConnection }
        set { hasInternetConnection = newValue } // Allow setting for test setup
    }
    
    // MARK: - Lifecycle Methods
    /// Initializes the view hierarchy, audio session, and initial stream selection.
    /// - Note: Performs heavy setup; defers non-critical tasks with asyncAfter for better launch performance.
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        processedImageCache.countLimit = 5  // One per language, as there are 5 streams
        
        // Add custom accessibility actions for playPauseButton
        playPauseButton.accessibilityCustomActions = [
            UIAccessibilityCustomAction(
                name: NSLocalizedString("toggle_playback", comment: "Accessibility action to toggle playback"),
                target: self,
                selector: #selector(togglePlayback)
            )
        ]
        
        // Add custom accessibility actions for volumeSlider
        volumeSlider.accessibilityCustomActions = [
            UIAccessibilityCustomAction(
                name: NSLocalizedString("increase_volume", comment: "Accessibility action to increase volume"),
                target: self,
                selector: #selector(increaseVolume)
            ),
            UIAccessibilityCustomAction(
                name: NSLocalizedString("decrease_volume", comment: "Accessibility action to decrease volume"),
                target: self,
                selector: #selector(decreaseVolume)
            )
        ]
        
        // Register for preferred content size category changes
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (controller: Self, previousTraitCollection: UITraitCollection) in
            guard let self else { return }
            // Reapply attributes with new font size (prevents "sending 'self'" data race)
            self.updateMetadataLabel(
                text: self.metadataLabel.text ?? String(localized: "no_track_info")
            )
        }
        
        configureAudioSession() // Configure audio session
        
        // Initialize haptic engine early if hardware supports haptics
        if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            _ = hapticEngine // Trigger lazy initialization
            startHapticEngine()
        }
        
        setupDarwinNotificationListener()
        setupUI()
        
        languageCollectionView.delegate = self
        languageCollectionView.dataSource = self
        languageCollectionView.register(LanguageCell.self, forCellWithReuseIdentifier: "LanguageCell")
        languageCollectionView.bounces = false
        languageCollectionView.isScrollEnabled = false
        
        // Calculate initial stream index (synchronous part)
        let currentLocale = Locale.current
        let languageCode = currentLocale.language.languageCode?.identifier ?? "en"
        let initialIndex = DirectStreamingPlayer.availableStreams.firstIndex(where: { $0.languageCode == languageCode }) ?? 0
        selectedStreamIndex = initialIndex
        
        languageCollectionView.reloadData()
        languageCollectionView.layoutIfNeeded()
        
        let indexPath = IndexPath(item: initialIndex, section: 0)
        languageCollectionView.selectItem(at: indexPath, animated: false, scrollPosition: .centeredHorizontally)
        centerCollectionViewContent()
        updateSelectionIndicator(to: initialIndex, isInitial: true)
        
        // Set initial volume slider position (UI only)
        if let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared") {
            let savedVolume = sharedDefaults.float(forKey: "preferredVolume")
            let volumeToUse = savedVolume > 0 ? savedVolume : 0.5
            volumeSlider.value = volumeToUse
            volumeSlider.accessibilityValue = String(format: String(localized: "accessibility_value_volume"), Int(volumeToUse * 100))
            sharedDefaults.set(volumeToUse, forKey: "preferredVolume")
            sharedDefaults.synchronize()
            #if DEBUG
            print("📱 Set initial volumeSlider to \(volumeToUse)")
            #endif
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.isInitialScrollLocked = false
        }
        
        setupControls()
        setupNetworkMonitoring()
        setupBackgroundAudioControls()
        setupInterruptionHandling()
        setupRouteChangeHandling()
        setupStreamingCallbacks()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        
        setupWidgetActionPolling()
        setupFastWidgetActionChecking()
        isInitialSetupComplete = true
        setupBackgroundParallax()
        
        // Energy Efficiency Optimizations (iOS 26)
        updateForEnergyEfficiency()  // Initial check
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(energyEfficiencyChanged),
            name: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"),
            object: nil
        )
        
        // === Asynchronous initialization (required for Swift 6 concurrency) ===
        Task { @MainActor [weak self] in
            guard let self else { return }
            
            // Set the initial stream asynchronously (this was causing the error)
            await self.streamingPlayer.setStream(to: DirectStreamingPlayer.availableStreams[initialIndex])
            
            self.updateUserDefaultsLanguage(DirectStreamingPlayer.availableStreams[initialIndex].languageCode)
            self.updateBackground(for: DirectStreamingPlayer.availableStreams[initialIndex])
            
            // Play special tuning sound, then auto-play if appropriate
            await self.playSpecialTuningSound()
            
            guard self.hasInternetConnection && !self.isManualPause else {
                #if DEBUG
                print("📱 Skipped auto-play: no internet or manually paused")
                #endif
                return
            }
            
            #if DEBUG
            print("📱 Starting auto-playback after tuning sound - cancelling any pending stops")
            #endif
            
            self.streamingPlayer.cancelPendingSSLProtection()
            self.streamingPlayer.resetTransientErrors()
            await self.startPlayback()
            self.restoreVolume()
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if languageCollectionView.frame.size != lastCollectionViewSize {
            updateSelectionIndicator(to: selectedStreamIndex, isInitial: true)
            lastCollectionViewSize = languageCollectionView.frame.size
        }
    }
    
    private func preferredVolume() -> Float {
        guard let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            return 0.5
        }
        let savedVolume = sharedDefaults.float(forKey: "preferredVolume")
        let volumeToUse = savedVolume > 0 ? savedVolume : 0.5
        // Persist default if none exists (for consistency with restoreVolume)
        sharedDefaults.set(volumeToUse, forKey: "preferredVolume")
        sharedDefaults.synchronize()
        return volumeToUse
    }
    
    private func restoreVolume() {
        // Restore volume after player initialization
        if let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared") {
            let savedVolume = sharedDefaults.float(forKey: "preferredVolume")
            let volumeToUse = savedVolume > 0 ? savedVolume : 0.5 // Use saved volume or default to 0.5
            volumeSlider.value = volumeToUse
            streamingPlayer.setVolume(volumeToUse)
            sharedDefaults.set(volumeToUse, forKey: "preferredVolume") // Persist the default if none exists
            sharedDefaults.synchronize()
        }
    }
    
    func setupDarwinNotificationListener() {
        let notificationName = "radio.lutheran.widget.action"
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        
        // Use a simpler approach without context pointer
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (_, observer, _, _, _) in
                guard let observer = observer else { return }
                let vc = Unmanaged<ViewController>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    #if DEBUG
                    print("🔗 Received Darwin notification for widget action")
                    #endif
                    vc.checkForPendingWidgetActions()
                }
            },
            notificationName as CFString,
            nil,
            .deliverImmediately
        )
        
        #if DEBUG
        print("🔗 Darwin notification listener setup complete")
        #endif
    }
    
    private func setupWidgetActionPolling() {
        // Check for widget actions every 30 seconds as fallback
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.checkForPendingWidgetActions()
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {  // Increased delay for more stability
            self.updateSelectionIndicator(to: self.selectedStreamIndex, isInitial: true)
        }
        if !didInitialLayout {
            didInitialLayout = true
            selectionIndicator.center.x = view.bounds.width / 2
            
            let currentLocale = Locale.current
            let languageCode = currentLocale.language.languageCode?.identifier
            let initialIndex = DirectStreamingPlayer.availableStreams.firstIndex(where: { $0.languageCode == languageCode }) ?? 0
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                let indexPath = IndexPath(item: initialIndex, section: 0)
                self.languageCollectionView.selectItem(at: indexPath, animated: false, scrollPosition: .centeredHorizontally)
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
        
        // All non-Sendable cleanup – Apple-recommended (2026)
        isDeallocating = true
        
        streamingPlayer.clearCallbacks()
        
        connectivityCheckTimer?.invalidate()
        connectivityCheckTimer = nil
        streamSwitchWorkItem?.cancel()
        streamSwitchWorkItem = nil
        tuningPlayer?.stop()
        tuningPlayer = nil
        isTuningSoundPlaying = false
        
        networkMonitor?.pathUpdateHandler = nil
        networkMonitorHandler = nil
        networkMonitor?.cancel()
        networkMonitor = nil
        
        // Also remove the other NotificationCenter observers here (idempotent)
        NotificationCenter.default.removeObserver(self, name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"), object: nil)
        // ← REMOVED: .streamSwitchCompleted observer (no longer exists or needed)
        
        #if DEBUG
        print("🧹 ViewController cleanup completed in viewDidDisappear")
        #endif
    }
    
    /// Configures the audio session for background playback.
    /// - Throws: AVAudioSession errors if category/activation fails.
    /// - Note: Called in viewDidLoad; ensures ducking and mixing with other audio.
    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setActive(true)
            #if DEBUG
            print("🔊 Audio session configured for playback")
            #endif
        } catch {
            #if DEBUG
            print("❌ Failed to configure audio session: \(error.localizedDescription)")
            #endif
        }
    }
    
    func saveStateForWidget() {
        let now = Date()
        let timeSinceAppLaunch = now.timeIntervalSince(appLaunchTime)
        let isInInitializationPeriod = timeSinceAppLaunch < 5.0  // Match SharedPlayerManager
        
        // Enhanced throttling during initialization
        let throttleInterval: TimeInterval = isInInitializationPeriod ? 4.0 : 2.0
        
        if let lastUpdate = lastWidgetUpdate,
           now.timeIntervalSince(lastUpdate) < throttleInterval {
            #if DEBUG
            if isInInitializationPeriod {
                print("🔗 ViewController: Throttling widget update during initialization")
            }
            #endif
            return
        }
        
        let stateBeforeSave = SharedPlayerManager.shared.loadSharedState()
        
        Task {
            await SharedPlayerManager.shared.saveCurrentState()
            
            // Now load after the save has completed
            let stateAfterSave = SharedPlayerManager.shared.loadSharedState()
            
            if stateBeforeSave.isPlaying != stateAfterSave.isPlaying ||
               stateBeforeSave.currentLanguage != stateAfterSave.currentLanguage ||
               stateBeforeSave.hasError != stateAfterSave.hasError {
                
                // Update timestamp on the main actor (since lastWidgetUpdate is likely UI-related)
                await MainActor.run {
                    self.lastWidgetUpdate = now
                    
                    #if DEBUG
                    print("🔗 State saved for widgets (meaningful change detected)")
                    #endif
                }
            } else {
                #if DEBUG
                await MainActor.run {
                    print("🔗 No meaningful state change, skipping widget timestamp update")
                }
                #endif
            }
        }
    }
    
    private func setupFastWidgetActionChecking() {
        // Check for widget actions every second for the first 5 seconds after app starts
        // This ensures fast processing of widget actions when app becomes active
        var checksRemaining = 5 // 5 checks × 1.0s = 5 seconds
        
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            self.checkForPendingWidgetActions()
            
            checksRemaining -= 1
            
            if checksRemaining <= 0 {
                timer.invalidate()
                #if DEBUG
                print("🔗 Fast widget action checking completed")
                #endif
            }
        }
    }
    
    // MARK: - Enhanced Status Change Handling
    private func setupStreamingCallbacks() {
        streamingPlayer.onStatusChange = { [weak self] isPlaying, statusText in
            guard let self = self else {
                #if DEBUG
                print("📱 onStatusChange: ViewController is nil, skipping callback")
                #endif
                return
            }
            
            // Non-UI updates (safe on background if properties are nonisolated)
            self.isPlaying = isPlaying
            
            // Hop to main for UI and isolated state
            DispatchQueue.main.async {
                self.updatePlayPauseButton(isPlaying: isPlaying)
                self.saveStateForWidget()
                
                if isPlaying {
                    self.statusLabel.text = String(localized: "status_playing")
                    self.statusLabel.backgroundColor = .systemGreen
                    self.statusLabel.textColor = .black
                    self.playPauseButton.accessibilityLabel = String(localized: "accessibility_label_play_pause")
                } else {
                    self.statusLabel.text = statusText
                    self.playPauseButton.accessibilityLabel = String(localized: "accessibility_label_play")
                    
                    if statusText == String(localized: "status_security_failed") {
                        self.hasPermanentPlaybackError = true
                        self.isManualPause = true
                        self.statusLabel.backgroundColor = .systemRed
                        self.statusLabel.textColor = .white
                        self.showSecurityModelAlert()
                        
                    } else if statusText == String(localized: "status_ssl_transition") {
                        self.statusLabel.backgroundColor = .systemOrange
                        self.statusLabel.textColor = .white
                        self.showSSLTransitionAlert()
                        
                    } else if statusText == String(localized: "status_no_internet") {
                        self.statusLabel.backgroundColor = .systemGray
                        self.statusLabel.textColor = .white
                        self.updateUIForNoInternet()
                        
                    } else if statusText == String(localized: "status_stream_unavailable") {
                        self.statusLabel.backgroundColor = .systemOrange
                        self.statusLabel.textColor = .white
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
        }
        
        streamingPlayer.onMetadataChange = { [weak self] metadata in
            guard let self = self else {
                #if DEBUG
                print("📱 onMetadataChange: ViewController is nil, skipping callback")
                #endif
                return
            }
            
            // Process metadata on background (regex is cheap and thread-safe)
            var potentialNames: [String]? = nil
            if let metadata = metadata {
                do {
                    let regex = try NSRegularExpression(pattern: "\\b[A-Z][a-z]+(?:\\s[A-Z][a-z]+)*\\b")  // Tighten if needed, e.g., add length min
                    let matches = regex.matches(in: metadata, range: NSRange(metadata.startIndex..., in: metadata))
                    potentialNames = matches.compactMap { match in
                        Range(match.range, in: metadata).map { String(metadata[$0]) }
                    }
                } catch {
                    #if DEBUG
                    print("🔴 Regex failed in onMetadataChange: \(error)")
                    #endif
                }
            }
            
            // Hop to main for UI updates
            DispatchQueue.main.async {
                if let metadata = metadata {
                    self.metadataLabel.text = metadata
                    self.updateNowPlayingInfo(title: metadata)
                    
                    let specificSpeakers = Set(["Jari Lammi"])
                    let matchedSpeaker = potentialNames?.first(where: { specificSpeakers.contains($0) })
                    
                    if let speaker = matchedSpeaker,
                       let imagePath = Bundle.main.path(forResource: speaker.lowercased().replacingOccurrences(of: " ", with: "_") + "_photo", ofType: "png"),  // Assume png; adjust
                       let image = UIImage(contentsOfFile: imagePath) {
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
                    } else if potentialNames?.contains("Lutheran Radio") == true,
                              let imagePath = Bundle.main.path(forResource: "radio-placeholder", ofType: "png"),
                              let image = UIImage(contentsOfFile: imagePath) {
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
                self.saveStateForWidget()
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
            guard let self else { return }
            
            Task { @MainActor in   // ← Keeps UI work on main + gives us async context
                // Reset transient failures (now async)
                await self.streamingPlayer.resetTransientErrors()
                
                // Validate using the shared actor — automatic actor hop via await
                let isValid = await SecurityModelValidator.shared.validateSecurityModel()
                
                if isValid {
                    self.startPlayback()
                } else {
                    // Optional: distinguish failure type for better UX/logging
                    let isPermanent = await SecurityModelValidator.shared.isPermanentlyInvalid
                    
                    #if DEBUG
                    print("Retry failed — permanent? \(isPermanent)")
                    #endif
                    
                    // Could re-show alert or show different message
                    // For now: just log / do nothing extra
                }
            }
        }))
        
        alert.addAction(UIAlertAction(title: String(localized: "ok"), style: .cancel, handler: nil))
        
        present(alert, animated: true, completion: nil)
    }
    
    // MARK: - SSL Transition Alert
    
    private func showSSLTransitionAlert() {
        // Prevent multiple alerts
        guard presentedViewController == nil else { return }
        
        let alert = UIAlertController(
            title: String(localized: "ssl_transition_title"),
            message: String(localized: "ssl_transition_message"),
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: String(localized: "alert_continue"), style: .default, handler: { [weak self] _ in
            // Continue with current connection during transition
            self?.startPlayback()
        }))
        
        alert.addAction(UIAlertAction(title: String(localized: "ok"), style: .cancel, handler: nil))
        
        present(alert, animated: true, completion: nil)
    }
    
    private func setupControls() {
        playPauseButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        playPauseButton.accessibilityIdentifier = "playPauseButton"
        playPauseButton.accessibilityHint = String(localized: "accessibility_hint_play_pause")
        playPauseButton.accessibilityLabel = String(localized: "accessibility_label_play")  // e.g., "Play" in Localizable.strings
        playPauseButton.accessibilityTraits = [.button, .playsSound]  // Hints that it triggers sound
        
        volumeSlider.addTarget(self, action: #selector(volumeChanged(_:)), for: .valueChanged)
        volumeSlider.accessibilityIdentifier = "volumeSlider"
        volumeSlider.accessibilityHint = String(localized: "accessibility_hint_volume")
        volumeSlider.accessibilityLabel = String(localized: "accessibility_label_volume")  // e.g., "Volume"
        volumeSlider.accessibilityTraits = .adjustable  // Default, but explicit for clarity
        volumeSlider.accessibilityValue = String(format: String(localized: "accessibility_value_volume"), Int(volumeSlider.value * 100))  // e.g., "50 percent"
        
        // Add AirPlay button tap feedback
        airplayButton.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(airplayTapped)))
        airplayButton.accessibilityLabel = String(localized: "accessibility_label_airplay")  // e.g., "AirPlay picker"
        airplayButton.accessibilityHint = String(localized: "accessibility_hint_airplay")  // e.g., "Double tap to select audio output"
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
    
    // MARK: - Network and Interruption Handling
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
                if isConnected && isExpensive && !self.hasShownDataUsageNotification && !UserDefaults.standard.bool(forKey: UserDefaultsKeys.hasDismissedDataUsageNotification) {
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
            UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasDismissedDataUsageNotification)
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
            stopTuningSound() // Stop tuning sound during interruption
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
        
        Task { @MainActor in
            // 1. Reset transient failures
            await self.streamingPlayer.resetTransientErrors()
            
            // 2. Re-validate using the shared actor
            let isValid = await SecurityModelValidator.shared.validateSecurityModel()
            
            if isValid {
                #if DEBUG
                print("📱 Validation succeeded after reconnection - attempting playback")
                #endif
                
                // Updated call – no longer takes a completion closure
                let success = await self.streamingPlayer.play()
                
                if success {
                    self.streamingPlayer.onStatusChange?(true, String(localized: "status_playing"))
                } else {
                    self.streamingPlayer.onStatusChange?(false, String(localized: "status_stream_unavailable"))
                }
                
            } else {
                #if DEBUG
                print("📱 Security model validation failed after reconnection")
                #endif
                
                // Distinguish transient vs permanent using the new property
                let isPermanent = await SecurityModelValidator.shared.isPermanentlyInvalid
                
                let statusKey: String.LocalizationValue = isPermanent
                    ? "status_security_failed"
                    : "status_no_internet"
                
                self.streamingPlayer.onStatusChange?(false, String(localized: statusKey))
                
                // Show alert only if not already presenting one
                if presentedViewController == nil {
                    let alert = UIAlertController(
                        title: String(localized: "security_model_error_title"),
                        message: String(localized: "security_model_error_message"),
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: String(localized: "ok"), style: .default))
                    present(alert, animated: true)
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
        
        // Load image thread-safely (using bundle path to avoid UI assumptions)
        if let imagePath = Bundle.main.path(forResource: "radio-placeholder", ofType: nil),
           let image = UIImage(contentsOfFile: imagePath) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { size in
                // This closure may run on background; resize if needed (example)
                UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
                image.draw(in: CGRect(origin: .zero, size: size))
                let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
                UIGraphicsEndImageContext()
                return resizedImage ?? image
            }
            info[MPMediaItemPropertyArtwork] = artwork
        } else {
            print("🔴 Failed to load placeholder image")
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        print("🔄 Updated nowPlayingInfo on thread: \(Thread.isMainThread ? "main" : "background")")
    }
    
    private func updateUIForNoInternet() {
        safeUpdateStatusLabel(
            text: String(localized: "status_no_internet"),
            backgroundColor: .systemGray,
            textColor: .white,
            isPermanentError: false
        )
        metadataLabel.text = String(localized: "no_track_info")
        updatePlayPauseButton(isPlaying: false)
    }
    
    // MARK: - Playback Control Methods
    /// Starts audio playback with network checks and security validation.
    /// - Note: Debounces rapid calls and handles retries on transient errors.
    /// - Warning: Does not play if no internet or manual pause is active.
    private func startPlayback() {
        if !hasInternetConnection {
            updateUIForNoInternet()
            stopTuningSound()
            performActiveConnectivityCheck()
            return
        }
        
        let now = Date()
        if let lastAttempt = lastPlaybackAttempt,
           now.timeIntervalSince(lastAttempt) < 0.5,
           let lastFailedServer = streamingPlayer.lastFailedServer,
           lastFailedServer == streamingPlayer.selectedServerInfo.name {
            #if DEBUG
            print("📱 Debouncing failed server \(lastFailedServer), time since last: \(now.timeIntervalSince(lastAttempt))s")
            #endif
            return
        }
        lastPlaybackAttempt = now
        
        stopTuningSound()
        
        pendingPlaybackWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            
            isManualPause = false
            statusLabel.text = String(localized: "status_connecting")
            statusLabel.backgroundColor = .systemYellow
            statusLabel.textColor = .black
            
            Task { @MainActor in
                let isValid = await SecurityModelValidator.shared.validateSecurityModel()
                
                if isValid {
                    await self.streamingPlayer.resetTransientErrors()
                    
                    // FIXED: Modern async/await version (no trailing closure)
                    let success = await self.streamingPlayer.play()
                    
                    if success {
                        self.isPlaying = true
                        self.updatePlayPauseButton(isPlaying: true)
                        self.statusLabel.text = String(localized: "status_playing")
                        self.statusLabel.backgroundColor = .systemGreen
                    } else {
                        let isPermanent = await SecurityModelValidator.shared.isPermanentlyInvalid
                        
                        if isPermanent {
                            self.hasPermanentPlaybackError = true
                            self.statusLabel.text = String(localized: "status_stream_unavailable")
                            self.statusLabel.backgroundColor = .systemOrange
                            self.statusLabel.textColor = .white
                        } else {
                            self.attemptPlaybackWithRetry(attempt: 1, maxAttempts: 3)
                        }
                    }
                } else {
                    let isPermanent = await SecurityModelValidator.shared.isPermanentlyInvalid
                    
                    self.statusLabel.text = isPermanent
                        ? String(localized: "status_security_failed")
                        : String(localized: "status_no_internet")
                    
                    self.statusLabel.backgroundColor = isPermanent ? .systemRed : .systemGray
                    self.statusLabel.textColor = .white
                    
                    self.hasPermanentPlaybackError = isPermanent
                    
                    if isPermanent {
                        self.showSecurityModelAlert()
                    }
                }
            }
        }
        
        pendingPlaybackWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
        
        saveStateForWidget()
    }
    
    private func attemptPlaybackWithRetry(attempt: Int, maxAttempts: Int) {
        guard hasInternetConnection && !isManualPause && !hasPermanentPlaybackError else {
            #if DEBUG
            print("📱 Aborting playback attempt \(attempt) - no internet, manually paused, or previous permanent error")
            #endif
            if hasPermanentPlaybackError {
                streamingPlayer.onStatusChange?(false, String(localized: "status_stream_unavailable"))
            }
            return
        }
        
        let now = Date()
        if let lastAttempt = lastPlaybackAttempt,
           now.timeIntervalSince(lastAttempt) < minPlaybackInterval {
            
            DispatchQueue.main.asyncAfter(deadline: .now() + minPlaybackInterval) { [weak self] in
                guard let self else {
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
        
        let delay = pow(2.0, Double(attempt - 1))
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else {
                #if DEBUG
                print("📱 attemptPlaybackWithRetry (asyncAfter): ViewController is nil, skipping callback")
                #endif
                return
            }
            
            // UI / player setup on main thread
            self.streamingPlayer.setVolume(self.volumeSlider.value)
            
            // FIXED: Use modern async/await version instead of trailing closure
            Task { @MainActor in
                let success = await self.streamingPlayer.play()
                
                if success {
                    #if DEBUG
                    print("📱 Playback succeeded on attempt \(attempt)")
                    #endif
                    // Success UI updates can be handled here if needed.
                    // Usually already handled in startPlayback(), so optional.
                    
                } else {
                    let isPermanent = await SecurityModelValidator.shared.isPermanentlyInvalid
                    
                    if isPermanent {
                        #if DEBUG
                        print("📱 Permanent security model failure detected - stopping retries")
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
    
    /// Pauses playback and updates UI/status.
    /// - Note: Sets manual pause flag; saves state for widgets.
    /// - SeeAlso: `startPlayback()` for resumption logic.
    private func pausePlayback() {
        #if DEBUG
        print("📱 pausePlayback called from: \(Thread.callStackSymbols[1])")
        #endif
        
        isManualPause = true
        hasEverPlayed = false
        streamingPlayer.stop { [weak self] in
            guard let self = self else { return }
            
            // Hop to main queue for UI and isolated state updates
            DispatchQueue.main.async {
                self.isPlaying = false
                self.updatePlayPauseButton(isPlaying: false)
                self.updateStatusLabel(text: String(localized: "status_paused"), backgroundColor: .systemGray, textColor: .white)
                self.updateNowPlayingInfo()
                self.saveStateForWidget()
            }
        }
    }
    
    private func stopPlayback() {
        #if DEBUG
        print("📱 stopPlayback called from: \(Thread.callStackSymbols[1])")
        #endif
        streamingPlayer.stop()
        isPlaying = false
        updatePlayPauseButton(isPlaying: false)
        saveStateForWidget()
    }
    
    @objc private func volumeChanged(_ sender: UISlider) {
        streamingPlayer.setVolume(sender.value)
        sender.accessibilityValue = String(format: String(localized: "accessibility_value_volume"), Int(sender.value * 100))  // e.g., "75 percent"
        let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared")
        sharedDefaults?.set(sender.value, forKey: "preferredVolume")
        sharedDefaults?.synchronize()
    }
    
    private func updatePlayPauseButton(isPlaying: Bool, animated: Bool = false) {
        let imageName = isPlaying ? "pause.fill" : "play.fill"
        let config = UIImage.SymbolConfiguration(weight: .bold)
        let newImage = UIImage(systemName: imageName, withConfiguration: config)
        
        if animated {
            UIView.transition(with: playPauseButton, duration: 0.22, options: .transitionCrossDissolve, animations: {
                self.playPauseButton.setImage(newImage, for: .normal)
            })
        } else {
            playPauseButton.setImage(newImage, for: .normal)
        }
        
        playPauseButton.accessibilityLabel = isPlaying
        ? String(localized: "accessibility_label_play_pause")
        : String(localized: "accessibility_label_play")
    }
    
    private func setupBackgroundParallax() {
        backgroundImageView.addParallaxEffect(intensity: 10.0)
    }
    
    /// Updates the background image based on the selected stream's language.
    /// - Parameter stream: The current stream providing language code.
    /// - Note: Caches processed images; applies filters async for performance.
    /// - SeeAlso: `processImageAsync(imageName:cacheKey:stream:isDarkMode:)` for filtering details.
    private func updateBackground(for stream: DirectStreamingPlayer.Stream) {
        guard let imageName = backgroundImages[stream.languageCode] else {
            DispatchQueue.main.async {
                self.backgroundImageView.image = nil
            }
            return
        }
        
        let cacheKey = "\(imageName)_\(traitCollection.userInterfaceStyle.rawValue)"
        let isDarkMode = traitCollection.userInterfaceStyle == .dark  // ✅ Capture on main thread
        
        if isLowEfficiencyMode {
            // Low efficiency: Skip heavy processing/caching to save battery/CPU
            // Load raw image directly (lightweight) and apply without filters
            if let rawImage = UIImage(named: imageName) {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.backgroundImageView.image = rawImage
                    // ... Add any existing non-processing code here, e.g., constraints or animations if needed ...
                    // For example, if you have fade-in animation:
                    UIView.transition(with: self.backgroundImageView, duration: 0.5, options: .transitionCrossDissolve) {
                        self.backgroundImageView.image = rawImage
                    } completion: { _ in }
                }
            }
            return
        }
        
        // Normal mode: Proceed with caching and full processing
        cacheQueue.async { [weak self] in
            guard let self = self else { return }
            
            if let cachedImage = self.processedImageCache.object(forKey: cacheKey as NSString) {
                DispatchQueue.main.async {
                    self.applyProcessedImage(cachedImage, for: stream)
                }
                return
            }
            
            // Process image on background queue
            self.processImageAsync(imageName: imageName, cacheKey: cacheKey, stream: stream, isDarkMode: isDarkMode)  // ✅ Pass the captured value
        }
    }
    
    /// Processes and applies background image filters asynchronously.
    /// - Parameter imageName: Name of the base image asset.
    /// - Parameter cacheKey: Unique key for caching (includes interface style).
    /// - Parameter stream: Current stream for language-specific image.
    /// - Parameter isDarkMode: `true` if dark mode filters should be applied.
    /// - Note: Uses CIContext for efficiency; caches results to reduce CPU usage in low-power mode.
    private func processImageAsync(imageName: String, cacheKey: String, stream: DirectStreamingPlayer.Stream, isDarkMode: Bool) {
        guard let baseImage = UIImage(named: imageName) else {
            DispatchQueue.main.async {
                self.backgroundImageView.image = nil
            }
            return
        }
        
        imageProcessingQueue.async { [weak self] in
            guard let self = self else { return }
            
            let finalImage = autoreleasepool { () -> UIImage in
                guard let ciImage = CIImage(image: baseImage) else {
                    return baseImage
                }
                
                var processedImage = ciImage
                
                #if DEBUG
                print("Processing image for \(stream.languageCode), mode: \(isDarkMode ? "dark" : "light")")
                #endif
                
                // Apply filters based on interface style
                if isDarkMode {
                    processedImage = self.applyDarkModeFilters(to: processedImage)
                } else {
                    processedImage = self.applyLightModeFilters(to: processedImage)
                }
                
                // Convert back to UIImage
                guard let cgImage = self.imageProcessingContext.createCGImage(processedImage, from: processedImage.extent) else {
                    #if DEBUG
                    print("Failed to convert CIImage to CGImage - using base image as fallback")
                    #endif
                    return baseImage
                }
                
                let result = UIImage(cgImage: cgImage)
                #if DEBUG
                print("Successfully converted processed image to UIImage - size: \(result.size)")
                #endif
                return result
            }
            
            // Cache the result
            self.cacheQueue.async {
                self.processedImageCache.setObject(finalImage, forKey: cacheKey as NSString)
            }
            
            // Apply to UI on main thread
            DispatchQueue.main.async {
                self.applyProcessedImage(finalImage, for: stream)
            }
        }
    }
    
    private func applyDarkModeFilters(to image: CIImage) -> CIImage {
        var processedImage = image
        
        // Invert colors
        if let invertFilter = CIFilter(name: "CIColorInvert") {
            invertFilter.setValue(processedImage, forKey: kCIInputImageKey)
            if let outputImage = invertFilter.outputImage {
                processedImage = outputImage
                #if DEBUG
                print("Dark mode: Applied CIColorInvert - extent: \(processedImage.extent)")
                #endif
            }
        }
        
        // Adjust contrast and brightness
        if let controlsFilter = CIFilter(name: "CIColorControls") {
            controlsFilter.setValue(processedImage, forKey: kCIInputImageKey)
            controlsFilter.setValue(1.3, forKey: kCIInputContrastKey)
            controlsFilter.setValue(0.2, forKey: kCIInputBrightnessKey)
            if let outputImage = controlsFilter.outputImage {
                processedImage = outputImage
                #if DEBUG
                print("Dark mode: Applied CIColorControls - extent: \(processedImage.extent)")
                #endif
            }
        }
        
        // Morphology
        if let dilateFilter = CIFilter(name: "CIMorphologyMaximum") {
            dilateFilter.setValue(processedImage, forKey: kCIInputImageKey)
            dilateFilter.setValue(4.0, forKey: kCIInputRadiusKey)
            if let outputImage = dilateFilter.outputImage {
                processedImage = outputImage
                #if DEBUG
                print("Dark mode: Applied CIMorphologyMaximum - extent: \(processedImage.extent)")
                #endif
            }
        }
        
        return processedImage
    }

    private func applyLightModeFilters(to image: CIImage) -> CIImage {
        var processedImage = image
        
        // Color controls
        if let controlsFilter = CIFilter(name: "CIColorControls") {
            controlsFilter.setValue(processedImage, forKey: kCIInputImageKey)
            controlsFilter.setValue(1.3, forKey: kCIInputContrastKey)
            controlsFilter.setValue(-0.2, forKey: kCIInputBrightnessKey)
            if let outputImage = controlsFilter.outputImage {
                processedImage = outputImage
                #if DEBUG
                print("Light mode: Applied CIColorControls - extent: \(processedImage.extent)")
                #endif
            }
        }
        
        // Morphology operations
        if let dilateFilter = CIFilter(name: "CIMorphologyMaximum") {
            dilateFilter.setValue(processedImage, forKey: kCIInputImageKey)
            dilateFilter.setValue(5.0, forKey: kCIInputRadiusKey)
            if let outputImage = dilateFilter.outputImage {
                processedImage = outputImage
                #if DEBUG
                print("Light mode: Applied CIMorphologyMaximum - extent: \(processedImage.extent)")
                #endif
            }
        }
        
        if let erodeFilter = CIFilter(name: "CIMorphologyMinimum") {
            erodeFilter.setValue(processedImage, forKey: kCIInputImageKey)
            erodeFilter.setValue(1.0, forKey: kCIInputRadiusKey)
            if let outputImage = erodeFilter.outputImage {
                processedImage = outputImage
                #if DEBUG
                print("Light mode: Applied CIMorphologyMinimum - extent: \(processedImage.extent)")
                #endif
            }
        }
        
        return processedImage
    }
    
    private func applyProcessedImage(_ image: UIImage, for stream: DirectStreamingPlayer.Stream) {
        // This runs on main thread
        let screen = view.window?.windowScene?.screen
        let screenSize = screen?.bounds.size ?? CGSize(width: 375, height: 667) // Fallback to default iPhone size if nil
        let isSmallScreen = screenSize.height < 1600
        
        backgroundImageView.image = image
        
        if isSmallScreen {
            let imageSize = image.size
            let screenAspect = screenSize.width / screenSize.height
            let imageAspect = imageSize.width / imageSize.height
            let scaleFactor = min(0.85, screenAspect / imageAspect)
            backgroundImageView.transform = CGAffineTransform(scaleX: scaleFactor, y: scaleFactor)
        } else {
            backgroundImageView.transform = .identity
        }
        
        // Reapply parallax effect
        backgroundImageView.addParallaxEffect(intensity: 10.0)
        
        // Animate alpha change
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
        print("🧹 Received memory warning")
        #endif
        
        // Clear image cache to free memory
        cacheQueue.async {
            self.processedImageCache.removeAllObjects()
            #if DEBUG
            print("🧹 Cleared processed image cache")
            #endif
        }
    }
    
    // MARK: - Audio Setup
    func playSpecialTuningSound(completion: (() -> Void)? = nil) {
        guard !hasPlayedSpecialTuningSound else {
            #if DEBUG
            print("🎵 Special tuning sound already played, skipping")
            #endif
            completion?()
            return
        }
        
        guard let tuningURL = Bundle.main.url(forResource: "special_tuning_sound", withExtension: "wav") else {
            #if DEBUG
            print("❌ Error: special_tuning_sound.wav not found in bundle")
            #endif
            completion?()
            return
        }
        
        do {
            // Configure and activate audio session
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setActive(true)
            #if DEBUG
            print("🔊 Audio session activated for special tuning sound")
            #endif
            
            tuningPlayer = try AVAudioPlayer(contentsOf: tuningURL)
            tuningPlayer?.delegate = self
            tuningPlayer?.volume = preferredVolume()  // Set persistent volume
            #if DEBUG
            print("🎵 Set special tuning sound volume to \(tuningPlayer?.volume ?? -1.0)")
            #endif
            tuningPlayer?.numberOfLoops = 0
            tuningPlayer?.prepareToPlay()
            let didPlay = tuningPlayer?.play() ?? false
            
            // Optimistic UI during tuning sound – masks latency perfectly
            DispatchQueue.main.async { [weak self] in
                let manager = SharedPlayerManager.shared
                let state = manager.loadSharedState()
                let currentStream = manager.availableStreams.first(where: { $0.languageCode == state.currentLanguage }) ?? manager.availableStreams[0]
                
                self?.updatePlayPauseButton(isPlaying: true, animated: true)
                
                if !state.isPlaying {
                    self?.safeUpdateStatusLabel(
                        text: String(localized: "status_connecting"),
                        backgroundColor: .systemYellow,
                        textColor: .label,
                        isPermanentError: false
                    )
                }
            }
            
            isTuningSoundPlaying = didPlay
            hasPlayedSpecialTuningSound = true // Mark as played
            #if DEBUG
            if didPlay {
                print("🎵 Special tuning sound started playing")
            } else {
                print("❌ Failed to start special tuning sound")
            }
            #endif
            if didPlay {
                // Call completion after sound duration (2 seconds)
                DispatchQueue.main.asyncAfter(deadline: .now() + (tuningPlayer?.duration ?? 2.0)) {
                    #if DEBUG
                    print("🎵 Special tuning sound should have finished")
                    #endif
                    completion?()
                }
            } else {
                completion?()
            }
        } catch {
            #if DEBUG
            print("❌ Error loading special tuning sound: \(error.localizedDescription)")
            #endif
            completion?()
            return
        }
    }
    
    // Legacy compatibility
    func playTuningSound(completion: (() -> Void)? = nil) {
        Task { @MainActor in
            await playTuningSound()   // calls the new async version
            completion?()
        }
    }
    
    /// Modern async version - preferred in 2026 Swift code
    func playTuningSound() async {
        let now = Date()
        if let lastTime = lastTuningSoundTime, now.timeIntervalSince(lastTime) < 1.0 {
            #if DEBUG
            print("🎵 Skipping tuning sound: Debouncing, time since last: \(now.timeIntervalSince(lastTime))s")
            #endif
            return
        }
        
        lastTuningSoundTime = now
        
        let soundIndex = Int.random(in: 1...3)
        guard let tuningURL = Bundle.main.url(forResource: "tuning_sound_\(soundIndex)", withExtension: "wav") else {
            #if DEBUG
            print("❌ Error: tuning_sound_\(soundIndex).wav not found in bundle")
            #endif
            return
        }
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setActive(true)
            
            #if DEBUG
            print("🔊 Audio session activated for tuning sound")
            #endif
            
            tuningPlayer = try AVAudioPlayer(contentsOf: tuningURL)
            tuningPlayer?.delegate = self
            tuningPlayer?.volume = 1.0
            tuningPlayer?.numberOfLoops = 0
            tuningPlayer?.prepareToPlay()
            
            let didPlay = tuningPlayer?.play() ?? false
            isTuningSoundPlaying = didPlay
            
            #if DEBUG
            print(didPlay ? "🎵 Tuning sound \(soundIndex) started playing" : "❌ Failed to start tuning sound \(soundIndex)")
            #endif
            
            // Optimistic UI update (still on MainActor)
            let manager = SharedPlayerManager.shared
            let state = manager.loadSharedState()
            let currentStream = manager.availableStreams.first(where: { $0.languageCode == state.currentLanguage })
                ?? manager.availableStreams[0]
            
            updatePlayPauseButton(isPlaying: true, animated: true)
            
            if !state.isPlaying {
                safeUpdateStatusLabel(
                    text: String(localized: "status_connecting"),
                    backgroundColor: .systemYellow,
                    textColor: .label,
                    isPermanentError: false
                )
            }
            
            // Wait for the sound to finish naturally (this is the key improvement)
            if didPlay, let duration = tuningPlayer?.duration {
                try? await Task.sleep(for: .seconds(duration))
            } else {
                try? await Task.sleep(for: .seconds(1.0)) // fallback
            }
            
        } catch {
            #if DEBUG
            print("❌ Error loading tuning sound \(soundIndex): \(error.localizedDescription)")
            #endif
        }
    }
    
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // nonisolated because AVAudioPlayerDelegate can be called off-main
        // We hop to MainActor for UI/property access
        Task { @MainActor in
            #if DEBUG
            print("🎵 Tuning sound finished playing, success: \(flag)")
            #endif
            isTuningSoundPlaying = false
            tuningPlayer = nil
        }
    }
    
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            #if DEBUG
            print("❌ Tuning sound decode error: \(error?.localizedDescription ?? "Unknown")")
            #endif
            isTuningSoundPlaying = false
            tuningPlayer = nil
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
            
            // Stop the AVAudioPlayer
            if self.tuningPlayer?.isPlaying == true {
                self.tuningPlayer?.stop()
                #if DEBUG
                print("🎵 Tuning sound stopped via AVAudioPlayer")
                #endif
            }
            
            self.isTuningSoundPlaying = false
            #if DEBUG
            print("🎵 isTuningSoundPlaying set to false")
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
        
        isRotating = true  // Set flag
        
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
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {  // Slight delay for stability
                self.isRotating = false  // Clear flag post-animation
            }
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
        
        languageCollectionView.layoutIfNeeded() // Ensure latest layout
        
        if let layoutAttributes = languageCollectionView.layoutAttributesForItem(at: indexPath) {
            let cellFrame = layoutAttributes.frame
            var cellCenterX = cellFrame.midX
            
            // Clamp to view space to prevent offscreen
            let halfWidth = selectionIndicator.frame.width / 2
            let minX = halfWidth
            let maxX = languageCollectionView.bounds.width - halfWidth
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
        
        Task { @MainActor [weak self] in
            guard let self else { return }
            
            await streamingPlayer.stop()
            
            // Convert completion handler to async/await properly
            await withCheckedContinuation { continuation in
                playTuningSound { [weak self] in
                    guard let self else {
                        continuation.resume()
                        return
                    }
                    
                    // Now we can safely await inside this Task because we're still on @MainActor
                    Task { @MainActor in
                        await streamingPlayer.setStream(to: selectedStream)
                        hasPermanentPlaybackError = false
                        
                        if isPlaying || !isManualPause {
                            await startPlayback()           // assuming this is async too
                        }
                        
                        continuation.resume()
                    }
                }
            }
        }
    }
    
    // MARK: - UICollectionView DataSource and Delegate
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
        guard !isRotating else {  // Suppress during rotation
            #if DEBUG
            print("📱 Suppressed didSelect during rotation")
            #endif
            return
        }
        
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
            
            // Wait for tuning sound to complete if playing
            if self.isTuningSoundPlaying {
                #if DEBUG
                print("📱 collectionView:didSelectItemAt: Waiting for tuning sound to complete")
                #endif
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self = self else { return }
                    self.completeStreamSwitch(stream: stream, index: indexPath.item)
                }
            } else {
                self.completeStreamSwitch(stream: stream, index: indexPath.item)
            }
        }
        streamSwitchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem) // Reduced delay for responsiveness
    }
    
    private func updateUserDefaultsLanguage(_ languageCode: String) {
        let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared")
        sharedDefaults?.set(languageCode, forKey: "currentLanguage")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "lastUpdateTime")
        sharedDefaults?.synchronize()
        
        #if DEBUG
        print("🔗 MAIN APP: Updated UserDefaults language to: \(languageCode)")
        #endif
    }
    
    private func completeStreamSwitch(stream: DirectStreamingPlayer.Stream, index: Int) {
        // Immediate non-async work
        updateUserDefaultsLanguage(stream.languageCode)
        self.selectedStreamIndex = index
        saveStateForWidget()
        
        Task { @MainActor [weak self] in
            guard let self else { return }
            
            // 1. Stop the current stream (assuming it has a completion handler)
            await withCheckedContinuation { continuation in
                streamingPlayer.stop {
                    continuation.resume()
                }
            }
            
            // 2. Play tuning sound
            await withCheckedContinuation { continuation in
                self.playTuningSound { [weak self] in
                    guard let self else {
                        continuation.resume()
                        return
                    }
                    
                    // All the work that was inside the old nested closures
                    Task { @MainActor in   // Inner Task because setStream/startPlayback are async
                        await self.streamingPlayer.setStream(to: stream)
                        
                        self.streamingPlayer.resetTransientErrors()
                        self.updateUserDefaultsLanguage(stream.languageCode)
                        self.hasPermanentPlaybackError = false
                        
                        self.saveStateForWidget()
                        
                        if self.isPlaying || !self.isManualPause {
                            await self.startPlayback()
                        }
                        
                        self.updateSelectionIndicator(to: index)
                        
                        // Final safety save
                        try? await Task.sleep(for: .seconds(0.5))
                        self.saveStateForWidget()
                        
                        #if DEBUG
                        print("📱 completeStreamSwitch: Switched to stream \(stream.language), index=\(index)")
                        #endif
                        
                        continuation.resume()
                    }
                }
            }
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
    
    /// Cleans up resources, observers, and audio players to prevent leaks.
    /// - Note: Sets `isDeallocating` to avoid operations during teardown.
    deinit {
        isDeallocating = true
        
        #if DEBUG
        print("🧹 ViewController deinit starting")
        #endif
        
        // ONLY this is allowed in deinit (CF + Unmanaged is explicitly permitted)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
        
        #if DEBUG
        print("🧹 ViewController deinit completed")
        #endif
    }
    
    // MARK: - Widget Action Handlers (No Tuning Sounds)

    /// Handle widget play action without tuning sounds
    private func handleWidgetPlayAction() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            hasPermanentPlaybackError = false
            
            // Direct playback without tuning sounds
            startPlaybackDirect()
            
            // Immediately save state for widget feedback
            saveStateForWidget()
        }
    }

    /// Handle widget pause action
    private func handleWidgetPauseAction() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            pausePlayback()
            
            // Immediately save state for widget feedback
            saveStateForWidget()
        }
    }

    /// Handles widget-initiated stream switching to a specific language without playing tuning sounds.
    public func handleWidgetSwitchToLanguage(_ languageCode: String, actionId: String) {
        guard !processedActionIds.contains(actionId) else { return }
        processedActionIds.insert(actionId)
        
        // Debounce
        let now = Date()
        if let last = lastWidgetSwitchTime, now.timeIntervalSince(last) < 2.0 {
            return
        }
        lastWidgetSwitchTime = now
        
        pendingWidgetSwitchWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            Task { @MainActor in
                self.streamingPlayer.isSwitchingStream = true
                
                // 1. Stop current playback cleanly
                await self.streamingPlayer.stop(isSwitchingStream: true, silent: true)
                
                // 2. Find target
                guard let targetStream = DirectStreamingPlayer.availableStreams.first(where: { $0.languageCode == languageCode }),
                      let targetIndex = DirectStreamingPlayer.availableStreams.firstIndex(where: { $0.languageCode == languageCode }) else {
                    self.streamingPlayer.isSwitchingStream = false
                    #if DEBUG
                    print("❌ Widget switch: target stream not found for \(languageCode)")
                    #endif
                    return
                }
                
                // 3. Update local UI state immediately
                self.selectedStreamIndex = targetIndex
                self.updateBackground(for: targetStream)
                
                // 4. Switch in the shared actor
                await SharedPlayerManager.shared.switchToStream(targetStream)
                
                // 5. Update collection view
                let indexPath = IndexPath(item: targetIndex, section: 0)
                self.languageCollectionView.selectItem(at: indexPath, animated: true, scrollPosition: .centeredHorizontally)
                self.updateSelectionIndicator(to: targetIndex)
                
                // 6. Ensure playback starts (widget switches usually want immediate resume)
                try? await Task.sleep(for: .seconds(0.4))
                
                let state = SharedPlayerManager.shared.loadSharedState()
                if !state.isPlaying {
                    try? await SharedPlayerManager.shared.play()
                }
                
                self.streamingPlayer.isSwitchingStream = false
                
                // 7. Widget refresh (once, at the end)
                self.saveStateForWidget()
                WidgetCenter.shared.reloadAllTimelines()
                
                // 8. Clear pending action from actor
                await SharedPlayerManager.shared.clearPendingAction(actionId: actionId)
            }
        }
        
        pendingWidgetSwitchWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }
    
    private func updateUserDefaultsForStream(_ stream: DirectStreamingPlayer.Stream) {
        let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared")
        sharedDefaults?.set(stream.languageCode, forKey: "currentLanguage")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "lastUpdateTime")
        sharedDefaults?.synchronize()
    }

    /// Direct playback without tuning sounds (for widget actions, quick actions, etc.)
    private func startPlaybackDirect() {
        if !hasInternetConnection {
            updateUIForNoInternet()
            performActiveConnectivityCheck()
            return
        }
        
        isManualPause = false
        
        safeUpdateStatusLabel(
            text: String(localized: "status_connecting"),
            backgroundColor: .systemYellow,
            textColor: .black,
            isPermanentError: false
        )
        
        Task { @MainActor in
            let isValid = await SecurityModelValidator.shared.validateSecurityModel()
            
            if isValid {
                await self.streamingPlayer.resetTransientErrors()
                
                // 🔥 FIXED: play() is now async throws - no more completion handler
                do {
                    try await self.streamingPlayer.play()
                    
                    // Success path
                    self.isPlaying = true
                    self.updatePlayPauseButton(isPlaying: true)
                    
                    self.safeUpdateStatusLabel(
                        text: String(localized: "status_playing"),
                        backgroundColor: .systemGreen,
                        textColor: .black,
                        isPermanentError: false
                    )
                    
                    // Save state after successful playback
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.saveStateForWidget()
                    }
                    
                } catch {
                    // Failure path - use authoritative security state
                    let isPermanent = await SecurityModelValidator.shared.isPermanentlyInvalid
                    
                    if isPermanent {
                        self.safeUpdateStatusLabel(
                            text: String(localized: "status_stream_unavailable"),
                            backgroundColor: .systemOrange,
                            textColor: .white,
                            isPermanentError: true
                        )
                    } else {
                        // Simple retry without complex logic
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.startPlaybackDirect()
                        }
                    }
                }
            } else {
                let isPermanent = await SecurityModelValidator.shared.isPermanentlyInvalid
                
                self.safeUpdateStatusLabel(
                    text: isPermanent
                        ? String(localized: "status_security_failed")
                        : String(localized: "status_no_internet"),
                    backgroundColor: isPermanent ? .systemRed : .systemGray,
                    textColor: .white,
                    isPermanentError: isPermanent
                )
            }
        }
    }
    
    // MARK: - Widget and URL Scheme Handling
    /// Handles widget and URL scheme actions for playback control and stream switching.
    /// - Note: Relies on `DirectStreamingPlayer.isSwitchingStream` (set to `internal`) to coordinate stream switches and suppress unnecessary "stopped" status updates during transitions. Ensures smooth UI updates for widget and URL scheme interactions.
    public func checkForPendingWidgetActions() {
        guard let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            #if DEBUG
            print("🔗 ERROR: Failed to access shared UserDefaults")
            #endif
            return
        }
        
        guard let pendingAction = sharedDefaults.string(forKey: "pendingAction"),
              let actionId = sharedDefaults.string(forKey: "pendingActionId") else {
            return
        }
        
        let pendingTime = sharedDefaults.double(forKey: "pendingActionTime")
        let pendingLanguage = sharedDefaults.string(forKey: "pendingLanguage")
        let now = Date().timeIntervalSince1970
        let actionAge = now - pendingTime
        
        #if DEBUG
        print("🔗 Found pending action: \(pendingAction), age: \(actionAge)s, ID: \(actionId)")
        print("🔗 Pending language: \(pendingLanguage ?? "nil")")
        #endif
        
        // Expire actions after 30 seconds
        guard actionAge < 30.0 else {
            #if DEBUG
            print("🔗 Action expired (age: \(actionAge)s), clearing")
            #endif
            clearWidgetAction(actionId: actionId)
            return
        }
        
        // Clear action immediately to prevent re-processing
        clearWidgetAction(actionId: actionId)
        
        switch pendingAction {
        case "switch":
            if let languageCode = pendingLanguage {  // Use the already retrieved value
                #if DEBUG
                print("🔗 Executing widget switch action to language: \(languageCode)")
                #endif
                handleWidgetSwitchToLanguage(languageCode, actionId: actionId)
            } else {
                #if DEBUG
                print("🔗 Switch action missing language code - pendingLanguage was nil")
                #endif
            }
        case "play":
            #if DEBUG
            print("🔗 Executing widget play action")
            #endif
            handleWidgetPlayAction()
        case "pause":
            #if DEBUG
            print("🔗 Executing widget pause action")
            #endif
            handleWidgetPauseAction()
        default:
            #if DEBUG
            print("🔗 Unknown pending action: \(pendingAction)")
            #endif
        }
        
        // Clean up old processed action IDs (keep only last 10)
        if processedActionIds.count > 10 {
            let sortedIds = Array(processedActionIds).suffix(10)
            processedActionIds = Set(sortedIds)
        }
    }
    
    private func clearWidgetAction(actionId: String) {
        guard let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return }
        
        // Only clear if the action ID matches to prevent race conditions
        if let currentActionId = sharedDefaults.string(forKey: "pendingActionId"),
           currentActionId == actionId {
            sharedDefaults.removeObject(forKey: "pendingAction")
            sharedDefaults.removeObject(forKey: "pendingActionId")
            sharedDefaults.removeObject(forKey: "pendingActionTime")
            sharedDefaults.removeObject(forKey: "pendingLanguage")
            
            #if DEBUG
            print("🔗 Cleared processed action: \(actionId)")
            #endif
        }
    }
}

// MARK: - Public Methods for URL Scheme Handling
extension ViewController {
    
    /// Public method to start playback (callable from SceneDelegate)
    /// - Note: Async to main; resets permanent errors.
    public func handlePlayAction() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.hasPermanentPlaybackError = false
            self.startPlayback()
        }
    }
    
    /// Public method to pause playback (callable from SceneDelegate)
    public func handlePauseAction() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pausePlayback()
        }
    }
    
    /// Public method to switch to a specific language stream (callable from SceneDelegate).
    /// - Parameter languageCode: The ISO language code to switch to (e.g., "en", "de", "fi", "sv", "et").
    public func handleSwitchToLanguage(_ languageCode: String) {
        Task { @MainActor in
            #if DEBUG
            print("🔄 handleSwitchToLanguage started for: \(languageCode)")
            #endif
            
            guard let targetStream = DirectStreamingPlayer.availableStreams.first(where: { $0.languageCode == languageCode }),
                  let targetIndex = DirectStreamingPlayer.availableStreams.firstIndex(where: { $0.languageCode == languageCode }) else {
                #if DEBUG
                print("❌ handleSwitchToLanguage: target stream not found for \(languageCode)")
                #endif
                return
            }
            
            self.selectedStreamIndex = targetIndex
            self.updateBackground(for: targetStream)
            self.streamingPlayer.isSwitchingStream = true
            
            #if DEBUG
            print("🛑 Starting silent stop for switch to \(languageCode)")
            #endif
            await self.streamingPlayer.stop(isSwitchingStream: true, silent: true)
            
            #if DEBUG
            print("🎵 Playing tuning sound")
            #endif
            await withCheckedContinuation { continuation in
                self.playTuningSound {
                    continuation.resume()
                }
            }
            
            self.streamingPlayer.resetTransientErrors()
            
            #if DEBUG
            print("📡 Setting stream to: \(targetStream.language)")
            #endif
            await self.streamingPlayer.setStream(to: targetStream)
            updateUserDefaultsForStream(targetStream)
            self.hasPermanentPlaybackError = false
            
            // UI update
            let indexPath = IndexPath(item: targetIndex, section: 0)
            self.languageCollectionView.selectItem(at: indexPath, animated: true, scrollPosition: .centeredHorizontally)
            self.updateSelectionIndicator(to: targetIndex)
            
            if !self.isManualPause {
                #if DEBUG
                print("▶️ Starting playback after switch")
                #endif
                try? await SharedPlayerManager.shared.play()   // Prefer the shared manager here for consistency
            }
            
            self.streamingPlayer.isSwitchingStream = false
            
            #if DEBUG
            print("✅ handleSwitchToLanguage completed for \(languageCode)")
            #endif
            
            // Final widget refresh
            self.saveStateForWidget()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
    
    /// Public method to toggle play/pause state
    public func handleTogglePlayback() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.isPlaying {
                self.handlePauseAction()
            } else {
                self.handlePlayAction()
            }
        }
    }
}

extension ViewController {
    func updateStatusLabel(text: String, backgroundColor: UIColor, textColor: UIColor) {
        if statusLabel.text == text { return }
        
        statusLabel.text = text
        statusLabel.backgroundColor = backgroundColor
        statusLabel.textColor = textColor
        statusLabel.accessibilityLabel = text
        
        // Announce status changes to VoiceOver only for play/pause states
        if text == String(localized: "status_playing") || text == String(localized: "status_paused") {
            UIAccessibility.post(notification: .announcement, argument: text)
        }
    }
    
    func updateMetadataLabel(text: String) {
        if metadataLabel.text == text { return }
        
        // Enable hyphenation via attributed text
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.hyphenationFactor = 1.0  // Full hyphenation
        
        let attributes: [NSAttributedString.Key: Any] = [
            .font: metadataLabel.font ?? UIFont.preferredFont(forTextStyle: .callout),
            .foregroundColor: metadataLabel.textColor ?? .secondaryLabel,
            .paragraphStyle: paragraphStyle
        ]
        
        let attributedText = NSAttributedString(string: text, attributes: attributes)
        metadataLabel.attributedText = attributedText
        
        // Accessibility reads full text regardless of truncation
        metadataLabel.accessibilityLabel = text
        
        // Announce metadata changes if significant
        if text != String(localized: "no_track_info") {
            UIAccessibility.post(notification: .announcement, argument: text)
        }
    }
    
    @objc private func energyEfficiencyChanged() {
        updateForEnergyEfficiency()
    }
    
    // MARK: - Accessibility and Haptic Helpers
    private func startHapticEngine() {
        guard let engine = hapticEngine else { return }
        do {
            try engine.start()
            #if DEBUG
            print("✅ Haptic engine started successfully")
            #endif
        } catch {
            #if DEBUG
            print("❌ Failed to start haptic engine: \(error)")
            #endif
        }
    }
    
    // MARK: - Toggle Playback
    @objc private func togglePlayback() {
        // Instant visual press feedback
        UIView.animate(withDuration: 0.1, animations: {
            self.playPauseButton.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        }) { _ in
            UIView.animate(withDuration: 0.1) {
                self.playPauseButton.transform = .identity
            }
        }
        
        // Prevent multiple rapid taps
        playPauseButton.isUserInteractionEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.playPauseButton.isUserInteractionEnabled = true
        }
        
        Task { @MainActor in
            let manager = SharedPlayerManager.shared
            let state = manager.loadSharedState()
            
            if state.isPlaying {
                // === PAUSE ===
                self.updatePlayPauseButton(isPlaying: false)
                self.safeUpdateStatusLabel(text: String(localized: "status_paused"),
                                           backgroundColor: .systemYellow,
                                           textColor: .label,
                                           isPermanentError: false)
                
                await SharedPlayerManager.shared.stop()
                self.playHapticFeedback(style: .medium)
                
            } else {
                // === PLAY – optimistic UI ===
                self.updatePlayPauseButton(isPlaying: true)
                self.safeUpdateStatusLabel(text: String(localized: "status_connecting"),
                                           backgroundColor: .systemYellow,
                                           textColor: .label,
                                           isPermanentError: false)
                
                do {
                    try await SharedPlayerManager.shared.play()
                    self.playHapticFeedback(style: .heavy)
                    // Success → onStatusChange(.playing) or delegate will update final UI
                } catch {
                    // Failure → revert UI
                    self.updatePlayPauseButton(isPlaying: false)
                    self.safeUpdateStatusLabel(text: String(localized: "status_stopped"),
                                               backgroundColor: .systemRed,
                                               textColor: .white,
                                               isPermanentError: false)
                    self.playHapticFeedback(style: .heavy)
                }
            }
        }
    }
    
    // MARK: - Play Haptic Feedback
    /// Plays haptic feedback for user interactions (e.g., play/pause) using `CHHapticEngine` with a fallback to `UIImpactFeedbackGenerator`.
    /// - Parameter style: The feedback style (`.heavy` for play, `.medium` for pause).
    /// - Features:
    ///   - **Low Power Mode**: Skips haptics if `ProcessInfo.processInfo.isLowPowerModeEnabled` is true to conserve battery.
    ///   - **Hardware Check**: Ensures haptic support via `CHHapticEngine.capabilitiesForHardware().supportsHaptics`.
    ///   - **Custom Feedback**: Maps `.heavy` to intensity=1.0/sharpness=1.0 and `.medium` to intensity=0.7/sharpness=0.5 for distinct tactile feel.
    ///   - **Fallback**: Uses `UIImpactFeedbackGenerator` if `CHHapticEngine` fails (e.g., engine not started or hardware issue).
    /// - Note: Feedback is played synchronously after ensuring the engine is running. Debug logs track success/failure.
    /// - SeeAlso: `hapticEngine` for details on haptic engine initialization and management.
    private func playHapticFeedback(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        // Early exit in Low Power Mode to conserve battery
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            #if DEBUG
            print("❌ Haptics skipped in Low Power Mode")
            #endif
            return
        }
        
        // Check hardware support early
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics,
              let engine = hapticEngine else {
            #if DEBUG
            print("❌ Haptics not supported or engine unavailable")
            #endif
            return
        }
        
        do {
            // Explicitly start the engine if it's not running. This is synchronous and throws if it can't start.
            try engine.start()
            
            // Map style to custom intensity/sharpness (the custom vibration logic)
            let intensityValue: Float = (style == .heavy) ? 1.0 : 0.7
            let sharpnessValue: Float = (style == .heavy) ? 1.0 : 0.5
            
            // Create a simple transient event (short custom vibration)
            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: intensityValue)
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpnessValue)
            let event = CHHapticEvent(eventType: .hapticTransient, parameters: [intensity, sharpness], relativeTime: 0)
            
            // Create pattern and player
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            
            // Play immediately
            try player.start(atTime: CHHapticTimeImmediate)
            
            #if DEBUG
            print("✅ Haptic played: style=\(style), intensity=\(intensityValue), sharpness=\(sharpnessValue)")
            #endif
        } catch {
            #if DEBUG
            print("❌ Failed to play haptic: \(error.localizedDescription)")
            #endif
            // Fallback to UIImpactFeedbackGenerator if custom fails (but still respect LPM via the early guard)
            let fallback = UIImpactFeedbackGenerator(style: style)
            fallback.impactOccurred()
        }
    }
    
    @objc private func increaseVolume() {
        let newValue = min(volumeSlider.value + 0.1, volumeSlider.maximumValue)
        volumeSlider.setValue(newValue, animated: true)
        volumeChanged(volumeSlider)
        UIAccessibility.post(notification: .announcement, argument: String(format: NSLocalizedString("volume_set_to", comment: ""), Int(newValue * 100)))
    }
    
    @objc private func decreaseVolume() {
        let newValue = max(volumeSlider.value - 0.1, volumeSlider.minimumValue)
        volumeSlider.setValue(newValue, animated: true)
        volumeChanged(volumeSlider)
        UIAccessibility.post(notification: .announcement, argument: String(format: NSLocalizedString("volume_set_to", comment: ""), Int(newValue * 100)))
    }
    
    private func safeUpdateStatusLabel(text: String, backgroundColor: UIColor, textColor: UIColor, isPermanentError: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.statusLabel.text == text { return } // Skip redundant updates
            
            self.statusLabel.text = text
            self.statusLabel.backgroundColor = backgroundColor
            self.statusLabel.textColor = textColor
            self.statusLabel.accessibilityLabel = text   // always keep in sync
            
            self.hasPermanentPlaybackError = isPermanentError
            
            if text != String(localized: "status_playing") {
                self.saveStateForWidget()
            }
            
            // Announce ALL important status changes
            let importantStatuses: Set<String> = [
                String(localized: "status_connecting"),
                String(localized: "status_playing"),
                String(localized: "status_paused"),
                String(localized: "status_paused_call"),
                String(localized: "status_no_internet"),
                String(localized: "status_stream_unavailable"),
                String(localized: "status_security_failed"),
                String(localized: "status_stopped")
            ]
            
            if importantStatuses.contains(text) {
                UIAccessibility.post(notification: .announcement, argument: text)
            }
        }
    }
}

// MARK: - StreamingPlayerDelegate Conformance
extension ViewController: StreamingPlayerDelegate {
    /// Handles status changes from DirectStreamingPlayer (e.g., playing, paused).
    /// - Parameters:
    ///   - status: The new player status (e.g., .playing, .paused).
    ///   - reason: Optional reason for the change (e.g., "Interruption").
    /// Called from background threads in DirectStreamingPlayer (@unchecked Sendable).
    /// Marked nonisolated + explicit MainActor hop to satisfy strict concurrency.
    nonisolated func onStatusChange(_ status: PlayerStatus, _ reason: String?) {
        Task { @MainActor in
            let visualState = PlayerVisualState.from(
                status: status,
                isManualPause: isManualPause,
                hasEverPlayed: hasEverPlayed
            )
            
            let statusText: String = {
                switch status {
                case .playing:     return String(localized: "status_playing")
                case .paused:      return (reason == "Interruption")
                    ? String(localized: "status_paused_call")
                    : String(localized: "status_paused")
                case .stopped:     return String(localized: "status_stopped")
                case .connecting:  return String(localized: "status_connecting")
                case .security:    return String(localized: "status_security_failed")
                @unknown default:  return "Unknown state"
                }
            }()
            
            safeUpdateStatusLabel(
                text: statusText,
                backgroundColor: visualState.backgroundColor,
                textColor: visualState.textColor,
                isPermanentError: status == .security
            )
            
            let showPauseIcon = status == .playing ||
            (status == .paused && reason == "Interruption")
            updatePlayPauseButton(isPlaying: showPauseIcon)
            
            // Optional but VERY nice — button tint now follows the state too
            // playPauseButton.tintColor = visualState.buttonTintColor
            
            // Update flag
            if status == .playing {
                hasEverPlayed = true
                
                // Only haptic when user-initiated resume (not auto-resume after interruption)
                if reason == nil {
                    playHapticFeedback(style: .light)
                }
            }
            
            saveStateForWidget()   // keeps widget in sync
        }
    }
    
    // MARK: - Widget Action Handling
    
    /// Handles widget-initiated actions via URL schemes.
    public func handleWidgetAction(action: String, parameter: String?, actionId: String) {
        guard !processedActionIds.contains(actionId) else {
            #if DEBUG
            print("Skipping duplicate widget action ID: \(actionId)")
            #endif
            return
        }
        processedActionIds.insert(actionId)
        
        Task { @MainActor in
            let manager = SharedPlayerManager.shared
            let state = manager.loadSharedState()
            let currentStream = manager.availableStreams.first(where: { $0.languageCode == state.currentLanguage })
            ?? manager.availableStreams[0]
            
            
            switch action {
            case "play":
                if !state.isPlaying {
                    await togglePlayback()          // ← Added 'await'
                }
                
            case "pause":
                if state.isPlaying {
                    await togglePlayback()          // ← Added 'await'
                }
                
            case "switch":
                if let languageCode = parameter,
                   let targetStream = DirectStreamingPlayer.availableStreams.first(where: { $0.languageCode == languageCode }),
                   let newIndex = DirectStreamingPlayer.availableStreams.firstIndex(where: { $0.languageCode == languageCode }) {
                    
                    // 🔥 FIXED: switchToStream is now async (no trailing closure)
                    await SharedPlayerManager.shared.switchToStream(targetStream)
                    
                    // Update UI (safe on @MainActor)
                    selectedStreamIndex = newIndex
                    languageCollectionView.selectItem(at: IndexPath(row: newIndex, section: 0),
                                                      animated: true,
                                                      scrollPosition: .centeredHorizontally)
                    
                    updateSelectionIndicator(to: newIndex)
                    updateBackground(for: targetStream)
                    
                    // Always start/resume playback after widget switch (user intent)
                    try? await Task.sleep(for: .seconds(0.5))
                    
                    if !state.isPlaying {
                        // 🔥 FIXED: play() is now async (no trailing closure, may throw)
                        try? await SharedPlayerManager.shared.play()
                    }
                    
                    // Feedback and save
                    playHapticFeedback(style: .medium)
                    UIAccessibility.post(notification: .announcement,
                                         argument: String(localized: "switched_to_language \(targetStream.language)"))
                    
                    
                    // Save state for widget consistency
                    saveStateForWidget()
                }
                
            default:
                #if DEBUG
                print("Unknown widget action: \(action)")
                #endif
            }
            
            // Clear the pending action (actor-isolated)
            await SharedPlayerManager.shared.clearPendingAction(actionId: actionId)
        }
    }
}
