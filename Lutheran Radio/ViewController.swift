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
@preconcurrency import AVFoundation
import MediaPlayer
import AVKit
import Network
import CoreImage
import CoreHaptics
import WidgetKit
import Core

/// The main view controller for the Lutheran Radio app.
///
/// This class is responsible for:
/// - Primary UI (title, language flag `UICollectionView`, playback controls, volume, metadata, AirPlay)
/// - Audio streaming coordination via `DirectStreamingPlayer` (the single source of truth for the actual player)
/// - Widget and Live Activity synchronization through `SharedPlayerManager` + `WidgetRefreshManager`
/// - iOS 26+ energy-efficiency handling (Low Power Mode optimizations, parallax removal)
/// - Haptic feedback, background image processing with caching, network monitoring, and interruption handling
///
/// All playback user intents (in-app buttons, remote commands, Control Center, widgets, URL schemes)
/// are routed through `handleUserTogglePlayback()` (the internal Single Source of Truth) which then
/// updates `PlayerVisualState` and calls `updateUI(for:)`.
///
/// See the detailed architecture article in the file header above for the complete interaction model,
/// widget action debouncing strategy, and low-power mode behavior.
///
/// - Note: This is a large UIKit view controller (iOS 26.2+ only). Logical sections are grouped as:
///   Initialization → Lifecycle Methods → Public Interface (SceneDelegate/widget entry points) →
///   Protocol conformances → Private implementation grouped by concern.
@MainActor
class ViewController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSource, UIScrollViewDelegate, AVAudioPlayerDelegate {
    // MARK: - Private Properties and Constants
    /// Key for tracking if the user has dismissed the mobile data usage warning.
    /// - Note: Stored in standard UserDefaults for persistence across launches.
    private enum UserDefaultsKeys {
        static let hasDismissedDataUsageNotification = "hasDismissedDataUsageNotification"
    }
    
    // All widget state save / refresh rate limiting lives in saveCurrentState +
    // WidgetRefreshManager (the authoritative path). The earlier local throttling
    // and many redundant call sites have been removed.
    private var lastWidgetSwitchTime: Date?
    private var pendingWidgetSwitchWorkItem: DispatchWorkItem?
    private var processedActionIds: Set<String> = []
    
    // Widget play/pause action debouncing (prevents rapid taps from widget causing AVFoundation thrashing)
    private var lastWidgetActionTime: Date = .distantPast
    private let widgetActionDebounceInterval: TimeInterval = 0.65
    
    private var lastCollectionViewSize: CGSize = .zero
    
    /// Flag indicating if the device is in Low Power Mode (iOS 26+).
    /// - Returns: `true` if low power mode is enabled, triggering UI/processing optimizations.
    private var isLowEfficiencyMode: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
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
        layout.minimumInteritemSpacing = 10   // horizontal gap between flags (the value the centering math must match)
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.showsHorizontalScrollIndicator = false
        cv.backgroundColor = .systemBackground
        cv.isAccessibilityElement = false // Prevent the collection view itself from being focused; cells are accessible
        cv.accessibilityTraits = .none
        cv.contentInsetAdjustmentBehavior = .never   // CRITICAL: sectionInset alone must control centering; default .automatic injects safe-area insets that break the math
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
    private var needleCenterXConstraint: NSLayoutConstraint!   // drives the tuning needle X position via Auto Layout so layout passes don't fight it
    
    // MARK: - Audio and Streaming
    // New streaming player
    nonisolated private let streamingPlayer: DirectStreamingPlayer
    private let audioQueue = DispatchQueue(label: "radio.lutheran.audio", qos: .userInitiated)

    private let appLaunchTime = Date()
    private var hasEverPlayed = false
    private var isPlaying = false
    // Phase 4 Chunk 4: Deleted isManualPause and hasPermanentPlaybackError.
    // All decision logic, guards, and resurrection control now live exclusively in SharedPlayerManager.currentPlaybackIntent.
    // The only remaining use of hasPermanentPlaybackError was in safeUpdateStatusLabel (removed in next step).
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
    // Phase 4 Chunk 4: Removed pendingPlaybackWorkItem, lastPlaybackAttempt, minPlaybackInterval.
    // These belonged exclusively to the deleted attemptPlaybackWithRetry + startPlayback retry machine.
    private var isDeallocating = false // Flag to prevent operations during deallocation
    private var hasPlayedSpecialTuningSound = false // Flag to ensure special sound plays only once
    private var hasShownSecurityAlert = false // Flag to ensure security alert is shown only once
    
    // Testable accessors
    @objc var isPlayingState: Bool {
        get { isPlaying }
        set { isPlaying = newValue } // Add setter for testing
    }
    
    @objc var hasInternet: Bool {
        get { hasInternetConnection }
        set { hasInternetConnection = newValue } // Allow setting for test setup
    }
    
    // MARK: - Initialization
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
            self.updateMetadataLabel(
                text: self.metadataLabel.text ?? String(localized: "no_track_info")
            )
        }
        
        configureAudioSession()
        
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
        // Do not force the needle on the very first viewDidLoad call with isInitial:true.
        // The collection view has usually not performed its final layout pass yet (bounds may be
        // stale, sectionInset not yet applied to cells). Let the width-change guard in
        // viewDidLayoutSubviews (and later non-initial calls) do the first real positioning.
        updateSelectionIndicator(to: initialIndex, isInitial: false)
        
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
        updateForEnergyEfficiency()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(energyEfficiencyChanged),
            name: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"),
            object: nil
        )
        
        // === Asynchronous initialization (required for Swift 6 concurrency) ===
        Task { @MainActor [weak self] in
            guard let self else { return }
            
            await self.streamingPlayer.setStream(to: DirectStreamingPlayer.availableStreams[initialIndex])
            
            self.updateUserDefaultsLanguage(DirectStreamingPlayer.availableStreams[initialIndex].languageCode)
            self.updateBackground(for: DirectStreamingPlayer.availableStreams[initialIndex])
            
            // Tuning sound (now plays fully)
            self.playSpecialTuningSound()
            
            let visualState = await SharedPlayerManager.shared.currentVisualState
            #if DEBUG
            print("🔄 After tuning — visualState = \(visualState)")
            #endif
            
            guard visualState == .prePlay || visualState.shouldAutoPlayOrResume else {
                #if DEBUG
                print("🛡️ Blocked initial playback — state = \(visualState)")
                #endif
                return
            }
            
            guard self.hasInternetConnection else { return }
            
            #if DEBUG
            print("🚀 Starting initial stream playback after tuning (single source)")
            #endif
            
            self.streamingPlayer.cancelPendingSSLProtection()
            self.streamingPlayer.resetTransientErrors()
            
            // ONE central call — tuning sound has already finished.
            // viewDidAppear will NOT trigger another play() for .prePlay.
            await SharedPlayerManager.shared.play()
            self.restoreVolume()
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Only react to *width* changes. Height-only shifts (e.g. long metadata pushing
        // the contentStackView taller) must not retrigger needle positioning.
        // Never pass isInitial:true from a layout callback — that path is only for true
        // one-time setup in viewDidLoad.
        if languageCollectionView.frame.width != lastCollectionViewSize.width {
            updateSelectionIndicator(to: selectedStreamIndex, isInitial: false)
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
            Task { @MainActor [weak self] in
                self?.checkForPendingWidgetActions()
            }
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // Layout / UI setup (keep your existing code)
        // NOTE: Do NOT use isInitial:true here on cold launch — the collection view
        // has often not performed its final layout pass with the real bounds + sectionInset yet.
        // The width-change path in viewDidLayoutSubviews + the non-initial calls below are sufficient.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.updateSelectionIndicator(to: self.selectedStreamIndex, isInitial: false)
        }
        
        if !didInitialLayout {
            didInitialLayout = true
            // Removed the direct assignment using view.bounds (wrong view, wrong time).
            // Real positioning now comes from the layoutSubviews guard + the calls below.
            
            let currentLocale = Locale.current
            let languageCode = currentLocale.language.languageCode?.identifier
            let initialIndex = DirectStreamingPlayer.availableStreams.firstIndex(where: { $0.languageCode == languageCode }) ?? 0
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                let indexPath = IndexPath(item: initialIndex, section: 0)
                self.languageCollectionView.selectItem(at: indexPath, animated: false, scrollPosition: .centeredHorizontally)
                self.updateSelectionIndicator(to: initialIndex, isInitial: false)
            }
        }
        
        // ───────────────────────────────────────────────────────────────────
        // SAFE playback trigger in viewDidAppear — ONLY for resurrection cases
        // NO auto-play on cold launch (prePlay). That is handled in viewDidLoad after tuning.
        // ───────────────────────────────────────────────────────────────────
        Task { @MainActor in
            let visualState = await SharedPlayerManager.shared.currentVisualState
            
            #if DEBUG
            print("🔥 ViewController.viewDidAppear → currentVisualState = \(visualState)")
            #endif
            
            switch visualState {
            case .prePlay:
                #if DEBUG
                print("🔥 ViewController.viewDidAppear → prePlay on cold launch → SKIPPING (handled in viewDidLoad after tuning)")
                #endif
                // Do nothing — playback already started from viewDidLoad Task
                
            case .playing:
                #if DEBUG
                print("🔥 ViewController.viewDidAppear → already playing, no action needed")
                #endif
                self.updateSelectionIndicator(to: self.selectedStreamIndex, isInitial: false)
                
            case .userPaused, .thermalPaused, .securityLocked:
                #if DEBUG
                print("🔥 ViewController.viewDidAppear → \(visualState) → SKIPPING auto-play (resurrection prevented)")
                #endif
                await MainActor.run {
                    self.updateSelectionIndicator(to: self.selectedStreamIndex, isInitial: false)
                }
            }
        }
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
    
    /// Persists the current playback / language state to the shared app group UserDefaults
    /// so that the home-screen widget and Live Activities can reflect the correct visual state
    /// without launching the app.
    ///
    /// - Important: This method is throttled (4 s during first 5 s after launch, 2 s thereafter)
    /// Thin delegate to the single authoritative persistence + refresh path.
    ///
    /// Post-Phase 9: the 2–4 s throttle + "meaningful change" check + lastWidgetUpdate
    /// marker have been removed entirely. They were a historical VC-local rate limit
    /// that could suppress `saveCurrentState()` (and therefore the unconditional
    /// `PersistedWidgetState` snapshot write + `WidgetRefreshManager` trigger) from
    /// numerous call sites. WidgetRefreshManager now owns all debouncing and the
    /// lang-change immediate bypass; `saveCurrentState` (called from player actions
    /// and here) is the only place that authors the SSOT snapshot.
    ///
    /// Phase 10: ~12 redundant call sites pruned (remote commands, handleUserTogglePlayback,
    /// pause/stopPlayback wrappers, widget play/pause/switch handlers, completeStreamSwitch
    /// post-play, handleSwitchToLanguage). These were immediately after stop()/play()/
    /// userRequestedPlay() which already perform the authoritative saveCurrentState +
    /// snapshot + refresh. Remaining sites are in callback/insurance/dispatch paths that
    /// do not themselves mutate via the player methods. The snapshot + saveCurrentState
    /// path is now even more dominant with less scaffolding.
    ///
    /// - SeeAlso: `SharedPlayerManager.saveCurrentState()`, `WidgetRefreshManager.refreshIfNeeded(visualState:currentLanguage:hasError:immediate:)`
    func saveStateForWidget() {
        Task {
            await SharedPlayerManager.shared.saveCurrentState()
        }
    }

    private func setupFastWidgetActionChecking() {
        // Check for widget actions every second for the first 5 seconds after app starts
        // This ensures fast processing of widget actions when app becomes active.
        // Uses repeated asyncAfter (no Timer, no mutable counter, no Sendable data-race issues).
        for i in 1...5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i)) { [weak self] in
                self?.checkForPendingWidgetActions()
                if i == 5 {
                    #if DEBUG
                    print("🔗 Fast widget action checking completed")
                    #endif
                }
            }
        }
    }
    
    // MARK: - Streaming Callbacks (metadata only)
    //
    // IMPORTANT: The old onStatusChange closure has been completely removed.
    // It was the last piece overriding updateUI(for:) with .systemYellow after pause.
    // Status changes are now handled exclusively by StreamingPlayerDelegate.onStatusChange(_:reason:)
    // which calls updateUI(for:) — making PlayerVisualState the single source of truth.
    //
    // We only keep onMetadataChange because it still does useful non-conflicting work
    // (speaker photo + metadata label + Now Playing info).
    
    private func setupStreamingCallbacks() {
        streamingPlayer.onMetadataChange = { [weak self] metadata in
            guard let self else {
                #if DEBUG
                print("📱 onMetadataChange: ViewController is nil, skipping callback")
                #endif
                return
            }
            
            // Process metadata on background (regex is cheap and thread-safe)
            var potentialNames: [String] = []
            if let metadata = metadata {
                do {
                    let regex = try NSRegularExpression(pattern: "\\b[A-Z][a-z]+(?:\\s[A-Z][a-z]+)*\\b")
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
            
            // Hop to main for UI updates only
            DispatchQueue.main.async {
                if let metadata = metadata {
                    self.metadataLabel.text = metadata
                    self.updateNowPlayingInfo(title: metadata)
                    
                    let specificSpeakers = Set(["Jari Lammi"])
                    let matchedSpeaker = potentialNames.first(where: { specificSpeakers.contains($0) })
                    
                    if let speaker = matchedSpeaker,
                       let speakerImage = UIImage(named: "\(speaker.lowercased().replacingOccurrences(of: " ", with: "_"))_photo") {
                        
                        // Photo of the speaker
                        UIView.transition(with: self.speakerImageView, duration: 0.3, options: .transitionCrossDissolve, animations: {
                            self.speakerImageView.image = speakerImage
                            self.speakerImageView.isHidden = false
                            self.speakerImageHeightConstraint.constant = 100
                            self.speakerImageView.accessibilityLabel = "Photo of \(speaker)"
                        }, completion: nil)
                        
                    } else if let placeholderImage = UIImage(named: "radio-placeholder") {
                        // DEFAULT: always show station logo for everything else
                        UIView.transition(with: self.speakerImageView, duration: 0.3, options: .transitionCrossDissolve, animations: {
                            self.speakerImageView.image = placeholderImage
                            self.speakerImageView.isHidden = false
                            self.speakerImageHeightConstraint.constant = 100
                            self.speakerImageView.accessibilityLabel = "Lutheran Radio Logo"
                        }, completion: nil)
                    } else {
                        #if DEBUG
                        print("🔴 Still failed to load radio-placeholder from Assets.xcassets")
                        #endif
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
                self.streamingPlayer.resetTransientErrors()
                
                // Validate using the shared actor — automatic actor hop via await
                let isValid = await SecurityModelValidator.shared.validateSecurityModel()
                
                if isValid {
                    // Phase 4 Chunk 3 (micro-step): Security retry now routes through unified intent surface.
                    // Validation already passed in this closure; userRequestedPlay() sets intent + drives play().
                    // Legacy startPlayback() (with its duplicate security/debounce logic) no longer needed here.
                    await SharedPlayerManager.shared.userRequestedPlay()
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
            // Phase 4 Chunk 3 (micro-step): SSL transition "Continue" now routes through unified intent.
            // This is an explicit user recovery action during cert transition window.
            // userRequestedPlay() sets authoritative intent + drives the (now-reliable) playback path.
            guard let _ = self else { return }   // weak self retained for Task safety (no direct use after Chunk 4 cleanup)
            Task { @MainActor in
                await SharedPlayerManager.shared.userRequestedPlay()
            }
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
        // Read the actual configured values so the centering math always matches what the layout will draw.
        let totalItems = DirectStreamingPlayer.availableStreams.count
        let cellWidth = layout.itemSize.width
        let spacing = layout.minimumInteritemSpacing
        let totalCellWidth = (cellWidth * CGFloat(totalItems)) + (spacing * CGFloat(totalItems - 1))
        let collectionViewWidth = languageCollectionView.bounds.width
        let inset = max((collectionViewWidth - totalCellWidth) / 2, 0)
        layout.sectionInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        layout.invalidateLayout()
        
        #if DEBUG
        print("📱 centerCollectionViewContent: totalCellWidth=\(totalCellWidth), collectionViewWidth=\(collectionViewWidth), inset=\(inset), bounds=\(languageCollectionView.bounds)")
        #endif
    }

    /// Pure mathematical derivation of the tuning needle (selectionIndicator) center X.
    /// Mirrors the exact 50pt/10pt/inset formula from centerCollectionViewContent so we are
    /// independent of UICollectionView layoutAttributes timing during cold-start metadata storms
    /// and orientation changes.
    private func centerXForIndex(_ index: Int) -> CGFloat {
        let totalItems = DirectStreamingPlayer.availableStreams.count
        guard languageCollectionView.bounds.width > 0, totalItems > 0 else {
            return languageCollectionView.bounds.midX
        }
        guard let layout = languageCollectionView.collectionViewLayout as? UICollectionViewFlowLayout else {
            return languageCollectionView.bounds.midX
        }
        let safeIndex = min(max(index, 0), totalItems - 1)
        // Derive from the live layout configuration (set in one place + delegate) so the
        // needle math always matches the actual cell positions the collection view will draw.
        let cellWidth = layout.itemSize.width
        let spacing = layout.minimumInteritemSpacing
        let totalCellWidth = (cellWidth * CGFloat(totalItems)) + (spacing * CGFloat(totalItems - 1))
        let collectionViewWidth = languageCollectionView.bounds.width
        let inset = max((collectionViewWidth - totalCellWidth) / 2, 0)
        let rawCenter = inset + (cellWidth / 2) + (CGFloat(safeIndex) * (cellWidth + spacing))
        // Safe half-width even if the indicator frame hasn't been sized yet
        let halfWidth = max(selectionIndicator.frame.width / 2, 2)
        let minX = halfWidth
        let maxX = collectionViewWidth - halfWidth
        return max(minX, min(maxX, rawCenter))
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
                    self.stopPlayback()
                    self.updateUIForNoInternet()
                    // Phase 4 Chunk 4: Removed stale isManualPause state preservation across disconnect.
                    // Playback intent (userPaused / securityLocked) is now authoritative in SharedPlayerManager.
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
            if isPlaying {
                stopPlayback()
            }
            stopTuningSound()
            
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            
            // Always try to reactivate the session
            try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            
            // === CRITICAL GUARD: Respect PlayerVisualState user intent ===
            // This prevents the most common "play-on-pause resurrection" after phone calls, Siri, etc.
            if options.contains(.shouldResume) {
                Task { @MainActor in
                    guard await streamingPlayer.shouldAutoPlayOrResume else {
                        #if DEBUG
                        print("🚫 [Interruption Guard] Blocked auto-resume after interruption — currentVisualState is .userPaused")
                        #endif
                        
                        updateUI(for: .userPaused)
                        return
                    }
                    
                    #if DEBUG
                    print("▶️ [Interruption Guard] Allowed resume after interruption")
                    #endif
                    
                    // Phase 4 Chunk 3 (micro-step): Interruption .shouldResume path now uses unified intent-driven play().
                    // The guard above already consults shouldAutoPlayOrResume (which delegates to currentPlaybackIntent
                    // via canProceedWithPlayback post-Phase 2). startPlayback() + its retry machinery no longer needed.
                    await SharedPlayerManager.shared.play()
                }
            }
            
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
            // Phase 4 Chunk 3 (micro-step): Route change .newDeviceAvailable resume now uses unified intent.
            // Removed legacy isManualPause guard (intent-driven play() + canProceedWithPlayback is authoritative).
            // play() will correctly block on .userPaused / .securityLocked and respect cold-launch rules.
            Task { @MainActor in
                await SharedPlayerManager.shared.play()
            }
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
            Task { @MainActor [weak self] in
                guard let self = self else {
                    #if DEBUG
                    print("📱 connectivityCheckTimer: ViewController is nil, skipping callback")
                    #endif
                    return
                }
                self.performActiveConnectivityCheck()
            }
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
            self.streamingPlayer.resetTransientErrors()
            
            // 2. Re-validate using the shared actor
            let isValid = await SecurityModelValidator.shared.validateSecurityModel()
            
            if isValid {
                #if DEBUG
                print("📱 Validation succeeded after reconnection - attempting playback")
                #endif
                
                // Updated call – no longer takes a completion closure.
                // Phase 6 Chunk 5 + follow-up: Playback success/failure now flows exclusively
                // through the player's internal safeOnStatusChange → delegate path (no more
                // legacy closure bypass here). The play() implementation always emits proper
                // status_* reasonKeys.
                _ = await self.streamingPlayer.play()
                
            } else {
                #if DEBUG
                print("📱 Security model validation failed after reconnection")
                #endif
                
                // Show alert only if not already presenting one (security error path unchanged)
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
        [commandCenter.playCommand, commandCenter.pauseCommand, commandCenter.togglePlayPauseCommand, commandCenter.stopCommand].forEach { $0?.removeTarget(nil) }
        
        // Play from lockscreen / Control Center
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
            guard let self else { return .commandFailed }
            #if DEBUG
            print("playCommand: lockscreen/Control Center Play tapped → userRequestedPlay")
            #endif
            Task { @MainActor in
                await SharedPlayerManager.shared.userRequestedPlay()
                
                // Refresh UI + Now Playing exactly like togglePlayback does.
                // userRequestedPlay() already performs the authoritative save + snapshot.
                let newState = await SharedPlayerManager.shared.currentVisualState
                self.updateUI(for: newState)
                self.updateNowPlayingInfo()
            }
            return .success
        }
        
        // Pause from lockscreen / Control Center
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
            guard let self else { return .commandFailed }
            #if DEBUG
            print("pauseCommand: lockscreen/Control Center Pause tapped")
            #endif
            Task { @MainActor in
                await SharedPlayerManager.shared.stop()
                let newState = await SharedPlayerManager.shared.currentVisualState
                self.updateUI(for: newState)
                self.updateNowPlayingInfo()
                // stop() already performs the authoritative saveCurrentState + snapshot.
            }
            return .success
        }
        
        // Toggle (most common on Control Center, CarPlay, etc.)
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
            guard let self else { return .commandFailed }
            #if DEBUG
            print("togglePlayPauseCommand: received → using same logic as in-app toggle")
            #endif
            Task { @MainActor in
                let manager = SharedPlayerManager.shared
                let currentVisualState = await manager.currentVisualState
                let sharedState = manager.loadSharedState()
                
                if currentVisualState.isActivelyPlaying || sharedState.isPlaying {
                    await manager.stop()
                } else {
                    await manager.userRequestedPlay()
                }
                
                let newState = await manager.currentVisualState
                self.updateUI(for: newState)
                self.updateNowPlayingInfo()
                // stop()/userRequestedPlay() already cover the authoritative save + snapshot.
            }
            return .success
        }
        
        // Stop (kept for completeness)
        commandCenter.stopCommand.isEnabled = true
        commandCenter.stopCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                await SharedPlayerManager.shared.stop()
                let newState = await SharedPlayerManager.shared.currentVisualState
                self.updateUI(for: newState)
                self.updateNowPlayingInfo()
                // stop() already performs the authoritative saveCurrentState + snapshot.
            }
            return .success
        }
    }
    
    // MARK: - User-Initiated Playback (single source of truth)
    // All in-app buttons, lockscreen, Control Center, handleTogglePlayback(), widgets, etc. now go through here.
    /// Internal Single Source of Truth for all playback user intents.
    ///
    /// Every play/pause action — whether it originates from the in-app button, remote commands,
    /// Control Center, lock screen, widgets, or URL schemes — must ultimately go through this method
    /// (via `togglePlayback()`, the public `handle*Action` methods, or `handleWidgetAction`).
    ///
    /// It reads the current `PlayerVisualState` from `SharedPlayerManager`, decides whether to call
    /// `stop()` or `userRequestedPlay()`, then forces a full UI + now-playing + widget refresh.
    ///
    /// This is the only place that is allowed to mutate `isPlaying` in response to a user intent.
    ///
    /// - SeeAlso: `togglePlayback()`, `handlePlayAction()`, `handlePauseAction()`, `handleTogglePlayback()`, `updateUI(for:)`
    @MainActor
    private func handleUserTogglePlayback() async {
        let manager = SharedPlayerManager.shared
        let visualState = await manager.currentVisualState
        
        if visualState.isActivelyPlaying {
            // User wants to pause
            await manager.stop()
            self.isPlaying = false
        } else {
            // User explicitly wants to play → bypass resurrection protection
            await manager.userRequestedPlay()
            self.isPlaying = true
        }
        
        // Refresh everything. Phase 10 prune: stop()/userRequestedPlay() already call
        // saveCurrentState() (PersistedWidgetState snapshot + WidgetRefreshManager trigger).
        let newState = await manager.currentVisualState
        self.updateUI(for: newState)
        self.updateNowPlayingInfo()
    }
    
    private func updateNowPlayingInfo(title: String? = nil) {
        #if DEBUG
        print("🔄 updateNowPlayingInfo called with title: \(title ?? "nil") | thread: \(Thread.isMainThread ? "main" : "background")")
        #endif

        // === LIVE ICY METADATA ALWAYS WINS ===
        let liveMetadata = DirectStreamingPlayer.shared.currentMetadata
        let finalTitle = liveMetadata ?? (title ?? "Lutheran Radio")

        #if DEBUG
        if let liveMetadata {
            print("📻 ✅ Using LIVE ICY metadata: \(liveMetadata)")
        }
        print("🔄 updateNowPlayingInfo called with finalTitle: \(finalTitle) | thread: \(Thread.isMainThread ? "main" : "background")")
        #endif

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: finalTitle,
            MPMediaItemPropertyArtist: "Lutheran Radio",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPMediaItemPropertyMediaType: MPMediaType.anyAudio.rawValue
        ]

        // ✅ FIXED: Use asset catalog (thread-safe + supports light/dark variants)
        if let artwork = Self.placeholderArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
            #if DEBUG
            print("✅ Speaker logo loaded successfully")
            #endif
        } else {
            #if DEBUG
            print("🔴 Failed to load placeholder image")
            #endif
        }

        // Always update on main thread
        DispatchQueue.main.async {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            #if DEBUG
            print("🔄 Updated nowPlayingInfo on main thread [final title: \(finalTitle)]")
            #endif
        }
    }

    // MARK: - Static placeholder (one-time creation, huge performance win)

    private static let placeholderArtwork: MPMediaItemArtwork? = {
        guard let image = UIImage(named: "radio-placeholder") else {
            // This will only print once at app launch if something is still wrong
            #if DEBUG
            print("🔴 CRITICAL: Could not load radio-placeholder from Assets.xcassets")
            #endif
            return nil
        }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }()
    
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
    // Phase 4 Chunk 4: startPlayback() shim completely deleted (zero callers, all logic migrated to SharedPlayerManager intent surface).
    // The former securityLocked special case inside it was belt-and-suspenders; permanent lock alerts continue to surface
    // via SecurityModelValidator failure paths + explicit showSecurityModelAlert() calls in error handlers (preserved).
    
    // Phase 4 Chunk 4: attemptPlaybackWithRetry completely deleted.
    // It was the core of the "three try" symptom (exponential backoff + own debounce + direct player calls).
    // All call sites removed; permanent error surfacing now happens via onStatusChange + Shared intent paths.
    
    /// Pauses playback and updates UI/status.
    /// - Note: Sets manual pause flag and routes through SharedPlayerManager to ensure .userPaused state is set.
    private func pausePlayback() {
        #if DEBUG
        // Called from lockscreen / Control Center / MPRemoteCommandCenter paths.
        // Widget-initiated pauses now route directly through SharedPlayerManager.stop()
        // (clean authoritative path that immediately locks .userPaused).
        print("📱 pausePlayback called (lockscreen / remote command)")
        #endif
        
        Task { @MainActor in
            await SharedPlayerManager.shared.stop()
            self.isPlaying = false                    // ← critical for nowPlayingInfo + toggle
            let newState = await SharedPlayerManager.shared.currentVisualState
            self.updateUI(for: newState)
            self.updateNowPlayingInfo()
            // Phase 10 prune: stop() already covers authoritative snapshot + refresh.
        }
    }
    
    // MARK: - Manual Pause (user tap)
    private func stopPlayback() {
        #if DEBUG
        print("🛑 stopPlayback called")
        #endif
        
        Task { @MainActor in
            await SharedPlayerManager.shared.stop()
            self.isPlaying = false                    // ← critical for nowPlayingInfo
            let newState = await SharedPlayerManager.shared.currentVisualState
            self.updateUI(for: newState)
            self.updateNowPlayingInfo()
            // Phase 10 prune: stop() already covers authoritative snapshot + refresh.
        }
    }
    
    @MainActor
    private func updateUI(for visualState: PlayerVisualState) {
        
        // Text
        switch visualState {
        case .playing:
            statusLabel.text = String(localized: "status_playing")
        case .userPaused:
            statusLabel.text = String(localized: "status_paused")
        case .thermalPaused:
            statusLabel.text = String(localized: "status_thermal_paused")
        case .prePlay:
            statusLabel.text = String(localized: "status_connecting")
        case .securityLocked:
            statusLabel.text = String(localized: "status_security_failed")
            
            // 🔥 Alert lives here — most convenient place
            if !hasShownSecurityAlert {
                hasShownSecurityAlert = true
                showSecurityModelAlert()
            }
        }
        
        // Colors from the enum (this is now the only source of truth)
        statusLabel.backgroundColor = visualState.backgroundColor
        statusLabel.textColor = visualState.textColor
        
        // Button image
        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .bold)
        let imageName = visualState.isActivelyPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: imageName, withConfiguration: config), for: .normal)
        
        // Optional but VERY nice — button tint now follows the state too
        // playPauseButton.tintColor = visualState.buttonTintColor
        
        // Accessibility
        statusLabel.accessibilityLabel = statusLabel.text
        
        // This is the single place that translates a `PlayerVisualState` into concrete UI.
        // All call sites (SSOT, widget actions, network recovery, stream switches, etc.)
        // must go through here so that the UI cannot drift from the authoritative state.
        
        #if DEBUG
        print("🔥 ViewController.updateUI → applied \(visualState) (bg=\(visualState.backgroundColor), tint=\(visualState.buttonTintColor))")
        #endif
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
            
            DispatchQueue.main.async {
                if let cachedImage = self.processedImageCache.object(forKey: cacheKey as NSString) {
                    self.applyProcessedImage(cachedImage, for: stream)
                    return
                }
                
                // Process image on background queue (kick-off from main to satisfy isolation)
                self.processImageAsync(imageName: imageName, cacheKey: cacheKey, stream: stream, isDarkMode: isDarkMode)
            }
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
                
                // Apply filters based on interface style.
                // Methods are pure CPU transforms (no actor state) → nonisolated for Swift 6.
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
            
            // Cache the result on main (NSCache property access must be isolated).
            DispatchQueue.main.async {
                self.processedImageCache.setObject(finalImage, forKey: cacheKey as NSString)
            }
            
            // Apply to UI on main thread
            DispatchQueue.main.async {
                self.applyProcessedImage(finalImage, for: stream)
            }
        }
    }
    
    nonisolated private func applyDarkModeFilters(to image: CIImage) -> CIImage {
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

    nonisolated private func applyLightModeFilters(to image: CIImage) -> CIImage {
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
        // ✅ Modern + cleaner: activate directly, no unnecessary stored array
        NSLayoutConstraint.activate([
            backgroundImageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: -20),
            backgroundImageView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: 20),
            backgroundImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: -20),
            backgroundImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 20)
        ])
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
        languageCollectionView.bringSubviewToFront(selectionIndicator)   // correct parent; needle must sit above the flag cells
        
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

        // Create the horizontal position constraint for the tuning needle once.
        // We update its .constant in updateSelectionIndicator instead of mutating .center.x.
        needleCenterXConstraint = selectionIndicator.centerXAnchor.constraint(equalTo: languageCollectionView.leadingAnchor, constant: 0)
        needleCenterXConstraint.isActive = true
    }
    
    @objc private func handleMemoryWarning() {
        #if DEBUG
        print("🧹 Received memory warning")
        #endif
        
        // Clear image cache to free memory
        DispatchQueue.main.async { [weak self] in
            self?.processedImageCache.removeAllObjects()
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
            let audioSession = AVAudioSession.sharedInstance()
            // More robust session setup (prevents conflicts with main AVPlayer)
            try audioSession.setCategory(.playback,
                                        mode: .default,
                                        options: [.allowAirPlay, .allowBluetoothA2DP])
            try audioSession.setActive(true)
            
            #if DEBUG
            print("🔊 Audio session activated for special tuning sound")
            #endif
            
            // Strong reference - critical to prevent sound cut-off
            tuningPlayer = try AVAudioPlayer(contentsOf: tuningURL)
            tuningPlayer?.delegate = self
            tuningPlayer?.volume = preferredVolume()
            
            #if DEBUG
            print("🎵 Set special tuning sound volume to \(tuningPlayer?.volume ?? -1.0)")
            #endif
            
            tuningPlayer?.numberOfLoops = 0
            tuningPlayer?.prepareToPlay()
            
            // CRITICAL: Never trigger playback after tuning sound.
            // Initial playback is handled only via viewDidAppear + SharedPlayerManager.
            // Resurrection is fully blocked by PlayerVisualState.mustSuppressResurrection.
            
            let didPlay = tuningPlayer?.play() ?? false
            isTuningSoundPlaying = didPlay
            hasPlayedSpecialTuningSound = true
            
            #if DEBUG
            print(didPlay ? "🎵 Special tuning sound started playing" : "❌ Failed to start special tuning sound")
            #endif
            
            // CRITICAL: Tuning sound no longer controls playback or state.
            // All decisions go through SharedPlayerManager + PlayerVisualState in viewDidLoad.
            if didPlay {
                // Keep strong reference during playback via the ivar; no local needed.
                
                DispatchQueue.main.asyncAfter(deadline: .now() + (tuningPlayer?.duration ?? 2.0)) {
                    #if DEBUG
                    print("🎵 Special tuning sound should have finished")
                    #endif
                    
                    // Just clean up — NO visualState checks, NO play() calls
                    Task { @MainActor in
                        self.tuningPlayer = nil
                        self.isTuningSoundPlaying = false
                    }
                }
            } else {
                self.tuningPlayer = nil
            }
        } catch {
            #if DEBUG
            print("❌ Error loading special tuning sound: \(error.localizedDescription)")
            #endif
            completion?()
            self.tuningPlayer = nil
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
        Task { @MainActor in
            #if DEBUG
            print("🎵 Tuning sound finished playing, success: \(flag)")
            #endif
            isTuningSoundPlaying = false
            // Do NOT set tuningPlayer = nil immediately
            // tuningPlayer = nil
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
        // Snapshot the MainActor-isolated property on the actor, BEFORE entering the Sendable closure.
        // This is the required pattern for Swift 6 / approachable concurrency.
        let player = self.tuningPlayer

        audioQueue.async {
            if player?.isPlaying == true {
                player?.stop()
                #if DEBUG
                print("🎵 Tuning sound stopped via AVAudioPlayer")
                #endif
            }

            // State mutation must hop to MainActor (safe, no Sendable violation).
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isTuningSoundPlaying = false
                #if DEBUG
                print("🎵 isTuningSoundPlaying set to false (from stopTuningSound)")
                #endif
            }
        }
    }
    
    // MARK: - Lifecycle (deinit)
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
    
    // MARK: - Selection Indicator
    private func updateSelectionIndicator(to index: Int, isInitial: Bool = false, caller: String = #function) {
        // SINGLE SOURCE OF TRUTH
        // • During normal operation (pause, play, network hiccups, etc.) → always use selectedStreamIndex
        // • Only on true initial load → accept the passed index
        let targetIndex = isInitial ? index : selectedStreamIndex
        
        // Safety guard
        let safeIndex = min(max(targetIndex, 0), DirectStreamingPlayer.availableStreams.count - 1)
        
        #if DEBUG
        print("📱 updateSelectionIndicator: Moving to index=\(safeIndex) (selectedStreamIndex=\(selectedStreamIndex), isInitial=\(isInitial), caller=\(caller))")
        #endif
        
        guard !isDeallocating else { return }
        
        guard safeIndex >= 0 && safeIndex < DirectStreamingPlayer.availableStreams.count else {
            #if DEBUG
            print("📱 updateSelectionIndicator: Invalid index \(safeIndex), streams count=\(DirectStreamingPlayer.availableStreams.count)")
            #endif
            return
        }
        
        // Needle constraints are set once in setupUI(). Never re-parent or re-activate them here.
        // Repeated addSubview + NSLayoutConstraint.activate creates duplicate/ambiguous constraints
        // that fight the manual .center.x mutation and cause the needle to drift or snap.
        if selectionIndicator.superview != languageCollectionView {
            languageCollectionView.addSubview(selectionIndicator)
            selectionIndicator.translatesAutoresizingMaskIntoConstraints = false
            // constraints intentionally NOT re-activated here
        }
        
        // CRITICAL for fault tolerance:
        // Always re-apply the centering insets before we compute or trust anything.
        // This guarantees the same math that positions the cells is active.
        centerCollectionViewContent()
        languageCollectionView.layoutIfNeeded()
        
        let indexPath = IndexPath(item: safeIndex, section: 0)
        
        // Prefer the *actual* cell center from the layout engine. This guarantees the needle
        // sits on the real flag cell no matter what effective insets or timing the collection
        // view is using. Fall back to the pure math only if attributes are not available yet.
        let cellCenterX: CGFloat
        if let layoutAttributes = languageCollectionView.layoutAttributesForItem(at: indexPath) {
            let cellFrame = layoutAttributes.frame
            cellCenterX = cellFrame.midX
            #if DEBUG
            let derived = centerXForIndex(safeIndex)
            print("📱 updateSelectionIndicator: Moving to index=\(safeIndex), using actual midX=\(cellCenterX) (derived was \(derived), delta=\(cellCenterX - derived)), cellFrame=\(cellFrame), bounds=\(languageCollectionView.bounds), isInitial=\(isInitial), caller=\(caller)")
            #endif
        } else {
            cellCenterX = centerXForIndex(safeIndex)
            #if DEBUG
            print("📱 updateSelectionIndicator: No layout attributes for indexPath=\(indexPath) — falling back to derived centerX=\(cellCenterX)")
            #endif
        }
        
        // Skip if the collection view has no width yet (still early in layout)
        guard languageCollectionView.bounds.width > 0 else {
            #if DEBUG
            print("📱 updateSelectionIndicator: Skipping — collection view has zero width")
            #endif
            needleCenterXConstraint.constant = cellCenterX
            return
        }
        
        UIView.animate(withDuration: isInitial ? 0.0 : 0.3) {
            self.needleCenterXConstraint.constant = cellCenterX
            self.languageCollectionView.layoutIfNeeded()
            self.selectionIndicator.transform = isInitial ? .identity : CGAffineTransform(scaleX: 1.5, y: 1.0)
        } completion: { _ in
            if !isInitial {
                UIView.animate(withDuration: 0.1) {
                    self.selectionIndicator.transform = .identity
                }
            }
            self.didPositionNeedle = true
            #if DEBUG
            print("📱 updateSelectionIndicator: Animation completed, final center.x=\(self.selectionIndicator.center.x) (didPositionNeedle=true)")
            #endif
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
        
        let newIndex = indexPath.item
        
        #if DEBUG
        print("📱 collectionView:didSelectItemAt called for index \(newIndex)")
        #endif
        
        // INSTANT TUNING INDICATOR MOVEMENT — works whether playing or paused
        selectedStreamIndex = newIndex
        updateSelectionIndicator(to: newIndex, isInitial: false, caller: "didSelectItemAt")
        
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
            let stream = DirectStreamingPlayer.availableStreams[newIndex]  // use newIndex instead of indexPath.item
            updateBackground(for: stream)
            
            // Wait for tuning sound to complete if playing
            if self.isTuningSoundPlaying {
                #if DEBUG
                print("📱 collectionView:didSelectItemAt: Waiting for tuning sound to complete")
                #endif
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self = self else { return }
                    self.completeStreamSwitch(stream: stream, index: newIndex)
                }
            } else {
                self.completeStreamSwitch(stream: stream, index: newIndex)
            }
        }
        streamSwitchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem) // Reduced delay for responsiveness
    }
    
    private func updateUserDefaultsLanguage(_ languageCode: String) {
        let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared")

        // The legacy separate "currentLanguage" key is no longer written directly.
        // saveCombinedWidgetState writes the single authoritative PersistedWidgetState snapshot.
        // We still bump lastUpdateTime for the widget "isAppRunning" check and freshness.
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "lastUpdateTime")
        sharedDefaults?.synchronize()

        // Architectural shift: Persist language together with current visual state
        // so the widget's robust fallback (loadPersistedWidgetState) gets the correct
        // language without extra forcing or freshness heuristics.
        Task {
            await SharedPlayerManager.shared.saveCombinedWidgetState(language: languageCode)
        }

        // The language setter is the single owner of prompt widget language propagation.
        // Every call guarantees an immediate timeline reload carrying the new language.
        WidgetRefreshManager.shared.refreshIfNeeded(
            visualState: .prePlay,
            currentLanguage: languageCode,
            hasError: false,
            immediate: true
        )

        #if DEBUG
        print("🔗 MAIN APP: Updated UserDefaults language to: \(languageCode)")
        #endif
    }
    
    private func completeStreamSwitch(stream: DirectStreamingPlayer.Stream, index: Int) {
        // Immediate non-async work. The language setter owns prompt widget refresh.
        updateUserDefaultsLanguage(stream.languageCode)
        
        self.selectedStreamIndex = index
        saveStateForWidget()
        
        // Mark switch start immediately so state-saving can suppress spam
        self.lastStreamSwitchTime = Date()
        
        Task { @MainActor [weak self] in
            guard let self else { return }
            
            let visualState = await SharedPlayerManager.shared.currentVisualState
            
            #if DEBUG
            print("🔄 completeStreamSwitch started – currentVisualState = \(visualState), stream = \(stream.languageCode)")
            #endif
            
            // 🔥 CRITICAL: Always update the underlying stream model, even when .userPaused.
            // Now switching while paused correctly prepares the new language for the next manual play().
            await self.streamingPlayer.setStream(to: stream)
            self.streamingPlayer.resetTransientErrors()
            // Phase 4 Chunk 4: Removed hasPermanentPlaybackError = false (duplicative of intent model).
            
            #if DEBUG
            print("🔄 [completeStreamSwitch] Updated stream model to \(stream.languageCode) (works for both playing and userPaused)")
            #endif
            
            // Capture the original intent BEFORE any stop() or state mutation
            let wasPlayingBeforeSwitch = visualState.shouldAutoPlayOrResume
            
            // === STRONG GUARD: Never auto-resume if user explicitly paused ===
            guard wasPlayingBeforeSwitch else {
                #if DEBUG
                print("🚫 [completeStreamSwitch] Blocked — userPaused, no auto-resume")
                #endif
                
                // ← SINGLE SOURCE OF TRUTH
                self.updateUI(for: .userPaused)
                self.updateSelectionIndicator(to: index)
                return
            }
            
            #if DEBUG
            print("▶️ [completeStreamSwitch] Allowed resume during stream switch (was playing)")
            #endif
            
            // 1. Clean stop current playback
            await withCheckedContinuation { continuation in
                streamingPlayer.stop(
                    reason: .streamSwitch,
                    completion: { continuation.resume() },
                    silent: true
                )
            }
            
            // Chunk 2: Explicitly reset the cold-launch attempt counters for the *new* stream.
            // This prevents previous stream's ICY noise / safety net exhaustion from causing
            // a false status_stream_unavailable red alert on a normal user language switch.
            streamingPlayer.resetInitialPlaybackCountersForNewStream()
            
            // 2. Play tuning sound + switch stream
            await playTuningSound()
            
            guard wasPlayingBeforeSwitch else {
                #if DEBUG
                print("🛡️ [completeStreamSwitch] Blocked play() after tuning sound")
                #endif
                await streamingPlayer.setStream(to: stream)
                updateSelectionIndicator(to: index)
                return
            }
            
            #if DEBUG
            print("🔄 completeStreamSwitch → calling SharedPlayerManager.play() after tuning")
            #endif
            
            await streamingPlayer.setStream(to: stream)
            streamingPlayer.resetTransientErrors()
            updateUserDefaultsLanguage(stream.languageCode)
            // Phase 4 Chunk 4: Removed hasPermanentPlaybackError = false (duplicative).
            
            // 🔥 CRITICAL FIX for stream switching after PlayerVisualState refactor
            // Reset visual state to .prePlay so SharedPlayerManager.play() executes
            // the full cold-launch path (bypasses the .playing skip guard).
            // Also gives immediate yellow "connecting" UI feedback during the atomic switch.
            await SharedPlayerManager.shared.resetToPrePlayForNewStream()
            updateUI(for: .prePlay)
            
            await SharedPlayerManager.shared.play()
            await Task.yield()
            
            updateSelectionIndicator(to: index)
            // play() already performs the authoritative saveCurrentState + snapshot.
            // Language propagation handled by updateUserDefaultsLanguage call above.
            
            #if DEBUG
            print("📱 completeStreamSwitch: Switched to stream \(stream.language), index=\(index)")
            #endif
        }
    }
    
    // MARK: - UICollectionViewDelegateFlowLayout
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let cellWidth: CGFloat = 50
        #if DEBUG
        print("Cell size for item \(indexPath.item): width = \(cellWidth), height = 50")
        #endif
        return CGSize(width: cellWidth, height: 50)
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat {
        let spacing = 10.0
        #if DEBUG
        print("Minimum line spacing for section \(section): \(spacing)")
        #endif
        return spacing
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumInteritemSpacingForSectionAt section: Int) -> CGFloat {
        // Horizontal spacing between items in the horizontal flag row.
        // Must match layout.minimumInteritemSpacing and the centering math.
        let spacing: CGFloat = 10.0
        #if DEBUG
        print("Minimum inter-item spacing for section \(section): \(spacing)")
        #endif
        return spacing
    }
    
    // MARK: - Widget Action Handlers (No Tuning Sounds)

    /// Handle widget play action without tuning sounds
    private func handleWidgetPlayAction() {
        #if DEBUG
        print("🔗 Widget Play action - forcing playback (main app style)")
        #endif
        
        // Phase 4 Chunk 4: Removed duplicate clears of hasPermanentPlaybackError / isManualPause.
        // The modern path (clearUserPausedLockIfNeeded + play) drives authoritative intent.
        
        Task { @MainActor in
            await SharedPlayerManager.shared.clearUserPausedLockIfNeeded()
            
            #if DEBUG
            print("▶️ Widget Play button → calling SharedPlayerManager.play()")
            #endif
            
            await SharedPlayerManager.shared.play()
            #if DEBUG
            print("✅ Widget Play button: SharedPlayerManager.play() succeeded")
            #endif
            
            // Phase 10 prune: play() already performs saveCurrentState (snapshot + WidgetRefreshManager).
            // No extra poke required; providers saw optimistic state via intent's persistWidgetSnapshot
            // (or forcePersist for play/pause) + early loadPersistedWidgetState return.
            #if DEBUG
            print("🔗 Widget play action completed")
            #endif
        }
    }

    /// Handle widget pause action
    private func handleWidgetPauseAction() {
        // Phase 4 Chunk 4: Removed legacy isManualPause = true.
        // Authoritative .userPaused is set inside SharedPlayerManager.stop() / markAsUserPaused() (already called by this path).
        
        // Write critical non-display state synchronously (pending nuke + lastUserPauseTime barrier).
        // The legacy "playing" bool and playerVisualState JSON writes have been removed here
        // (Phase 8 cleanup): they are now true migration artifacts. Widget intents write the
        // authoritative PersistedWidgetState snapshot via forcePersistVisualState before the
        // Darwin round-trip; SharedPlayerManager.stop() writes isPlaying + snapshot via
        // performActualSave on the authoritative path. Providers prefer the snapshot first.
        if let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared") {
            // Nuke any stale "play" pending action that could race with this pause
            if sharedDefaults.string(forKey: "pendingAction") == "play" {
                sharedDefaults.removeObject(forKey: "pendingAction")
                sharedDefaults.removeObject(forKey: "pendingActionId")
                sharedDefaults.removeObject(forKey: "pendingActionTime")
                sharedDefaults.removeObject(forKey: "pendingLanguage")
            }
            
            // Record a hard barrier timestamp that all recovery/nudge paths can consult
            sharedDefaults.set(Date().timeIntervalSince1970, forKey: "lastUserPauseTime")
            sharedDefaults.synchronize()
            
            // Chunk 3: Also update the authoritative in-actor timestamp so recovery paths
            // using wasRecentlyUserPaused() see the pause without relying on raw UD + defensive sync.
            Task {
                await SharedPlayerManager.shared.recordUserPauseTimestamp()
            }
        }
        
        // Route through the clean authoritative stop path (SharedPlayerManager.stop).
        // stop() immediately locks .userPaused on the actor at the very top, persists the JSON,
        // notifies Darwin, and triggers proper widget refresh. This is the same clean path
        // used for explicit user pauses (remote commands, etc.) and avoids the old
        // pausePlayback() indirection for widget-initiated pauses.
        // stop() performs authoritative saveCurrentState() (writes PersistedWidgetState snapshot
        // + isPlaying + triggers WidgetRefreshManager with urgency for !playing). Widget providers
        // see correct state via early snapshot return (written optimistically by the widget intent
        // itself via forcePersistVisualState). Phase 10: the explicit saveStateForWidget after
        // stop() in this path (and many others) was pruned as redundant.
        Task { @MainActor in
            await SharedPlayerManager.shared.stop()
            self.isPlaying = false
            let newState = await SharedPlayerManager.shared.currentVisualState
            self.updateUI(for: newState)
            self.updateNowPlayingInfo()
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
                self.streamingPlayer.stop(
                    reason: .streamSwitch,
                    silent: true
                )
                
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
                
                // === CRITICAL: Clear lock + full reset for cold-launch play ===
                await SharedPlayerManager.shared.clearUserPausedLockIfNeeded()
                await SharedPlayerManager.shared.resetToPrePlayForNewStream()
                
                // 🔥 NEW: Update shared UserDefaults so widget actually shows the new language.
                // Phase 10: language setter centralizes the immediate .prePlay refreshIfNeeded
                // for prompt propagation; the prior explicit duplicate force is removed.
                self.updateUserDefaultsLanguage(languageCode)
                
                #if DEBUG
                print("🔗 [Widget Switch] Cleared lock + resetToPrePlayForNewStream() + updated language to \(languageCode)")
                #endif
                
                // 5. Update collection view
                let indexPath = IndexPath(item: targetIndex, section: 0)
                self.languageCollectionView.selectItem(at: indexPath, animated: true, scrollPosition: .centeredHorizontally)
                self.updateSelectionIndicator(to: targetIndex)
                
                // 6. Main-app style play
                try? await Task.sleep(for: .seconds(0.6))
                
                // Phase 4 Chunk 4: Removed duplicate clears before modern SharedPlayerManager.play() path.
                
                #if DEBUG
                print("▶️ [Widget Switch] Starting new stream using SharedPlayerManager.play() — main app path")
                #endif
                
                await SharedPlayerManager.shared.play()
                #if DEBUG
                print("✅ Widget switch: SharedPlayerManager.play() succeeded")
                #endif
                
                // 7. Phase 10 prune: play() already did the authoritative saveCurrentState (snapshot
                //    + WidgetRefreshManager). Language prompt owned by updateUserDefaultsLanguage.
                //    No extra saveStateForWidget needed here.
                #if DEBUG
                print("🔗 Widget switch completed (authoritative save covered by play())")
                #endif
                
                // 8. Clear pending action
                await SharedPlayerManager.shared.clearPendingAction(actionId: actionId)
                
                self.streamingPlayer.isSwitchingStream = false
            }
        }
        
        pendingWidgetSwitchWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }
    
    // REMOVED (architectural cleanup): updateUserDefaultsForStream
    // It was the last direct writer of the legacy "currentLanguage" key outside the
    // blessed paths (updateUserDefaultsLanguage + saveCombinedWidgetState).
    // Its one call site was routed to the modern method above. The method is deleted
    // to prevent future accidental direct writes.
    //
    // (Historical note: this helper predated the PersistedWidgetState SSOT work.)

    // Phase 4 Chunk 4: startPlaybackDirect() shim completely deleted (zero callers, all logic migrated).
    
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
            if let languageCode = pendingLanguage {
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
            
            // === WIDGET PLAY/PAUSE DEBOUNCE GUARD ===
            guard Date().timeIntervalSince(lastWidgetActionTime) > widgetActionDebounceInterval else {
                #if DEBUG
                print("🔇 Widget action debounced (too soon after previous tap)")
                #endif
                return
            }
            lastWidgetActionTime = Date()
            // === END OF GUARD ===
            
            // Widget play: clear any user pause lock then play. Do NOT reset to prePlay here
            // (resetToPrePlayForNewStream is only for language stream switches).
            // Hoisted weak-self form (proven pattern elsewhere in this file) — avoids implicit self capture / compiler error.
            // Route widget play through the documented user-requested entry point.
            // userRequestedPlay() properly clears .userPaused, resets cold-launch guards,
            // and calls play() — the correct lightweight path for external triggers
            // (widgets, Control Center, lockscreen, CarPlay). Avoids the old heavy
            // handleWidgetPlayAction + raw play() which pulled in tuning-sound waits
            // and full stream re-setup even on simple resume.
            Task { @MainActor [weak self] in
                guard let _ = self else { return }   // weak self retained for Task safety (no direct use after Chunk 4 cleanup)
                // Phase 4 Chunk 4: Removed duplicate clears (intent path via userRequestedPlay is authoritative).
                await SharedPlayerManager.shared.userRequestedPlay()

                // Phase 10 prune: userRequestedPlay() (→ setUserIntentToPlay + play) already covers
                // the authoritative saveCurrentState + PersistedWidgetState snapshot + refresh.
            }
        case "pause":
            #if DEBUG
            print("🔗 Executing widget pause action")
            #endif
            
            // === WIDGET PLAY/PAUSE DEBOUNCE GUARD ===
            guard Date().timeIntervalSince(lastWidgetActionTime) > widgetActionDebounceInterval else {
                #if DEBUG
                print("🔇 Widget action debounced (too soon after previous tap)")
                #endif
                return
            }
            lastWidgetActionTime = Date()
            // === END OF GUARD ===
            
            // Brave rapid-pause guard (must hop because checkForPendingWidgetActions is synchronous).
            // If we are already .userPaused, ignore the tap to avoid queuing a second Darwin roundtrip
            // that could race with recovery timers or a stale "play" pendingAction.
            // Hoisted weak-self + guard form (await-safe, matches every other Task site in this file).
            Task { @MainActor [weak self] in
                guard let self else { return }
                let vs = await SharedPlayerManager.shared.currentVisualState
                if vs == .userPaused {
                    #if DEBUG
                    print("🔇 Widget pause ignored — already .userPaused (prevents double-pause resurrection races)")
                    #endif
                    return
                }
                self.handleWidgetPauseAction()
            }
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
    ///
    /// Phase 4 Chunk 2: Routes through SharedPlayerManager intent (userRequestedPlay path)
    /// instead of direct-to-DirectStreamingPlayer bypass. Consistent with SSOT.
    public func handlePlayAction() {
        Task { @MainActor in
            await SharedPlayerManager.shared.setUserIntentToPlay()
            await SharedPlayerManager.shared.play()
        }
    }

    /// Public method to pause playback (callable from SceneDelegate)
    ///
    /// Phase 4 Chunk 2: Routes through SharedPlayerManager.stop() (the authoritative
    /// path that immediately sets .userPaused + persists + refreshes widgets).
    public func handlePauseAction() {
        Task { @MainActor in
            await SharedPlayerManager.shared.stop()
            let newState = await SharedPlayerManager.shared.currentVisualState
            updateUI(for: newState)
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
            
            selectedStreamIndex = targetIndex
            updateBackground(for: targetStream)
            streamingPlayer.isSwitchingStream = true
            
            #if DEBUG
            print("🛑 Starting silent stop for switch to \(languageCode)")
            #endif
            
            // Updated: use semantic reason (no more isSwitchingStream flag)
            streamingPlayer.stop(
                reason: .streamSwitch,      // ← NEW
                silent: true                // ← kept exactly as before
            )
            
            #if DEBUG
            print("🎵 Playing tuning sound")
            #endif
            await playTuningSound()
            
            streamingPlayer.resetTransientErrors()
            
            #if DEBUG
            print("📡 Setting stream to: \(targetStream.language)")
            #endif
            await streamingPlayer.setStream(to: targetStream)
            // Retired legacy direct-write helper; route through the modern path that also
            // writes the combined PersistedWidgetState snapshot.
            updateUserDefaultsLanguage(targetStream.languageCode)
            // Phase 4 Chunk 4: Removed hasPermanentPlaybackError = false (duplicative of intent + SecurityModelValidator).
            
            // UI update
            let indexPath = IndexPath(item: targetIndex, section: 0)
            languageCollectionView.selectItem(at: indexPath, animated: true, scrollPosition: .centeredHorizontally)
            updateSelectionIndicator(to: targetIndex)
            
            // Phase 4 Chunk 4: Replaced legacy isManualPause decision guard with authoritative intent check.
            // Language switch is a user action; we now ask the SSOT (currentPlaybackIntent via canProceedWithPlayback).
            // This removes one of the last places the stale flag controlled playback flow.
            if await SharedPlayerManager.shared.canProceedWithPlayback() {
                #if DEBUG
                print("▶️ Starting playback after switch (intent allows)")
                #endif
                
                // Small delay to let AVPlayerItem settle
                try? await Task.sleep(for: .seconds(0.5))
                
                handlePlayAction()   // Uses new path with markAsPlaying()
                
            } else {
                #if DEBUG
                print("⏸️ Intent blocks playback after switch (userPaused or securityLocked)")
                #endif
                // Still update UI to paused state
                updateUI(for: .userPaused)
            }
            
            streamingPlayer.isSwitchingStream = false
            
            #if DEBUG
            print("✅ handleSwitchToLanguage completed for \(languageCode)")
            #endif
            
            // Phase 10 prune: handlePlayAction / player paths + saveCurrentState already handle
            // the snapshot write + WidgetRefreshManager. (Language prompt via setter.)
        }
    }

    /// Public method to toggle play/pause state
    /// (callable from SceneDelegate, remote commands, Control Center, etc.)
    ///
    /// Phase 4 Chunk 2: Now delegates to the internal SSOT (`handleUserTogglePlayback`)
    /// so that all toggle entry points (button, widget URL schemes, SceneDelegate, remote)
    /// flow through the single authoritative intent decision path.
    public func handleTogglePlayback() {
        Task { @MainActor in
            await handleUserTogglePlayback()
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
    /// Primary @objc entry point for user-initiated play/pause (button tap + remote commands).
    ///
    /// Performs instant visual press feedback, rate-limits rapid taps, then delegates to
    /// `handleUserTogglePlayback()` (the internal SSOT). This keeps all playback decisions
    /// in one place while still giving immediate tactile response to the user.
    ///
    /// - SeeAlso: `handleUserTogglePlayback()`, `handleTogglePlayback()` (public wrapper for SceneDelegate)
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
            // Phase 4 Chunk 2 (first step toward true SSOT):
            // The animation + rate-limit above remain here (good UX).
            // All decision logic now delegates to the documented internal SSOT
            // (`handleUserTogglePlayback`), which is the single place that calls
            // SharedPlayerManager.userRequestedPlay() / stop() based on intent.
            // This eliminates the previous duplicate visualState + play/pause branching.
            await self.handleUserTogglePlayback()
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
            
            // Phase 4 Chunk 4: Removed assignment to deleted hasPermanentPlaybackError.
            // Permanent error state is now driven by SecurityModelValidator.isPermanentlyInvalid + intent.
            
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
                String(localized: "status_stopped"),
                String(localized: "status_ssl_transition")
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
    ///   - reasonKey: The localization key for the reason (e.g. "status_no_internet", "status_stream_unavailable").
    /// Called from background threads in DirectStreamingPlayer (@unchecked Sendable).
    /// Marked nonisolated + explicit MainActor hop to satisfy strict concurrency.
    nonisolated func onStatusChange(_ status: PlayerStatus, reasonKey: String?) {
        Task { @MainActor in
            // SINGLE SOURCE OF TRUTH — always pull latest locked state
            let visualState = await SharedPlayerManager.shared.currentVisualState
            
            #if DEBUG
            print("🔥 StreamingPlayerDelegate.onStatusChange → \(status) (reasonKey: \(reasonKey ?? "nil")) → visualState \(visualState)")
            #endif
            
            // Brave defensive rule: if the authoritative state is .userPaused, never let a transient
            // "stopped", "connecting", or "buffering" callback flip the UI back to yellow/green.
            // This was allowing the "stopped → visualState playing" flips visible in the logs during glitches.
            let effectiveVisualState: PlayerVisualState = {
                if visualState == .userPaused {
                    return .userPaused
                }
                return visualState
            }()
            
            // First apply the normal UI from PlayerVisualState (icon + basic label)
            self.updateUI(for: effectiveVisualState)
            
            // These now run *after* updateUI so they can override the label color/alerts when needed
            if let reasonKey = reasonKey {
                if reasonKey == "status_ssl_transition" {
                    self.statusLabel.backgroundColor = .systemOrange
                    self.statusLabel.textColor = .white
                    self.showSSLTransitionAlert()
                    
                } else if reasonKey == "status_no_internet" {
                    self.statusLabel.backgroundColor = .systemGray
                    self.statusLabel.textColor = .white
                    self.updateUIForNoInternet()
                    
                } else if reasonKey == "status_stream_unavailable" {
                    // Phase 6 Chunk 5 + follow-up: Hard/permanent connection failures and other
                    // stream unavailability cases use the red banner treatment and the
                    // alert_connection_failed_title for the popup (restoring the pre-unification
                    // severe failure presentation). The status label text itself remains the
                    // proper status_stream_unavailable value.
                    //
                    // alert_connection_failed_title should be renamed to status_failed or similar
                    //
                    // FIX: Cold-launch safety net (and other early-failure paths) can emit this
                    // while the optimistic .playing state from setPlaying() is still active.
                    // Force-correct the SSOT here so updateUI + widget saves see the real terminal state.
                    let vsForCheck = await SharedPlayerManager.shared.currentVisualState
                    if vsForCheck.isActivelyPlaying || vsForCheck == .prePlay {
                        await SharedPlayerManager.shared.setUserPaused()
                    }
                    let correctedVisualState = await SharedPlayerManager.shared.currentVisualState
                    self.updateUI(for: correctedVisualState)
                    
                    self.statusLabel.text = String(localized: "status_stream_unavailable")
                    self.statusLabel.backgroundColor = .systemRed
                    self.statusLabel.textColor = .white
                    self.statusLabel.accessibilityLabel = self.statusLabel.text

                    if self.presentedViewController == nil {
                        let alert = UIAlertController(
                            title: String(localized: "stream_unavailable_title"),
                            message: String(localized: "stream_unavailable_message"),
                            preferredStyle: .alert
                        )
                        alert.addAction(UIAlertAction(title: String(localized: "alert_retry"), style: .default) { _ in
                            // Phase 4 Chunk 3 (micro-step): Route user-initiated stream retry through the unified
                            // intent surface instead of the legacy startPlayback() retry machine.
                            // userRequestedPlay() sets authoritative .shouldBePlaying intent + triggers play().
                            Task { @MainActor in
                                await SharedPlayerManager.shared.userRequestedPlay()
                            }
                        })
                        alert.addAction(UIAlertAction(title: String(localized: "ok"), style: .cancel, handler: nil))
                        self.present(alert, animated: true)
                    }
                }
            }
            
            // Update flag
            if status == .playing {
                hasEverPlayed = true
                
                // Only haptic when user-initiated resume (not auto-resume after interruption)
                if reasonKey == nil {
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
            
            // Safely read visual state (respects .userPaused)
            let visualState = await manager.currentVisualState
            let state = manager.loadSharedState()
            
            switch action {
            case "play":
                if visualState.shouldAutoPlayOrResume || !state.isPlaying {
                    // Explicit user intent from widget → clear paused state
                    await manager.setUserIntentToPlay()
                    
                    #if DEBUG
                    print("▶️ Widget 'play' action → calling handleUserTogglePlayback (SSOT)")
                    #endif
                    await handleUserTogglePlayback()
                } else {
                    #if DEBUG
                    print("🛡️ Widget 'play' blocked — currentVisualState is .userPaused")
                    #endif
                }
                
            case "pause":
                if state.isPlaying {
                    #if DEBUG
                    print("⏸️ Widget 'pause' action → calling handleUserTogglePlayback (SSOT)")
                    #endif
                    await handleUserTogglePlayback()
                }
                
            case "switch":
                if let languageCode = parameter,
                   let targetStream = DirectStreamingPlayer.availableStreams.first(where: { $0.languageCode == languageCode }),
                   let newIndex = DirectStreamingPlayer.availableStreams.firstIndex(where: { $0.languageCode == languageCode }) {
                    
                    // 🔥 FIXED: switchToStream is now async
                    await SharedPlayerManager.shared.switchToStream(targetStream)
                    
                    // Update UI (safe on @MainActor)
                    selectedStreamIndex = newIndex
                    languageCollectionView.selectItem(at: IndexPath(row: newIndex, section: 0),
                                                      animated: true,
                                                      scrollPosition: .centeredHorizontally)
                    
                    updateSelectionIndicator(to: newIndex)
                    updateBackground(for: targetStream)
                    
                    // Respect visual state — only resume if not user-paused
                    try? await Task.sleep(for: .seconds(0.5))
                    
                    let finalVisualState = await manager.currentVisualState
                    if finalVisualState.shouldAutoPlayOrResume && !state.isPlaying {
                        #if DEBUG
                        print("▶️ Widget switch → resuming playback (user intent)")
                        #endif
                        await manager.setUserIntentToPlay()
                        await SharedPlayerManager.shared.play()
                    } else if !finalVisualState.shouldAutoPlayOrResume {
                        #if DEBUG
                        print("🛡️ Widget switch blocked resume — .userPaused")
                        #endif
                        updatePlayPauseButton(isPlaying: false)
                        safeUpdateStatusLabel(text: String(localized: "status_paused"),
                                              backgroundColor: .systemYellow,
                                              textColor: .label,
                                              isPermanentError: false)
                    }
                    
                    // Feedback and save
                    playHapticFeedback(style: .medium)
                    UIAccessibility.post(notification: .announcement,
                                        argument: String(localized: "switched_to_language \(targetStream.language)"))
                    
                    // Save state for widget consistency (Phase 10: many peers pruned; this one
                    // remains inside the lang-switch subcase of widget action dispatch).
                    saveStateForWidget()
                }
                
            default:
                #if DEBUG
                print("Unknown widget action: \(action)")
                #endif
            }
            
            // Post-action save: specific cases (play/pause/switch lang) were pruned in Phase 10
            // because their player methods already cover saveCurrentState/snapshot/refresh.
            // This tail poke remains for the general dispatch + any non-play paths (e.g. pure
            // lang switch without play) to ensure the authoritative snapshot is written after
            // Darwin processing. WidgetRefreshManager + snapshot SSOT handle the rest.
            saveStateForWidget()
            
            #if DEBUG
            print("🔗 Widget action '\(action)' completed → saveStateForWidget")
            #endif
            
            // Clear the pending action (actor-isolated)
            await SharedPlayerManager.shared.clearPendingAction(actionId: actionId)
        }
    }
}

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
