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
/// - **Playback**: Toggles via `togglePlayback()`; monitors network (`NWPathMonitor`) and shows the 3-choice cellular data permission prompt on expensive networks (decision + persistence extracted to CellularPermissionManager).
/// - **Background Handling**: Integrates with `RadioLiveActivityManager.swift` for Live Activities on backgrounding; saves state via `SharedPlayerManager.swift`.
/// - **Widget/URL Handling**: Public methods like `handlePlayAction()` process schemes from `SceneDelegate.swift`.
///
/// Accessibility: VoiceOver announcements for status/metadata; hyphenation for long text. For lifecycle events, see `SceneDelegate.swift` and `AppDelegate.swift`.
import UIKit
@unsafe @preconcurrency import AVFoundation
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
/// ultimately route through `userRequestedPlay()` (designated explicit-play entry) or
/// `handleUserTogglePlayback()` (the toggle SSOT inside the coordinator). See the
/// `userRequestedPlay` Precondition and AGENT NOTE for the explicit vs. internal distinction.
///
/// See the detailed architecture article in the file header above for the complete interaction model,
/// widget action debouncing strategy, and low-power mode behavior.
///
/// - Note: This is a large UIKit view controller (iOS 26.2+ only). Logical sections are grouped as:
///   Initialization → Lifecycle Methods → Public Interface (SceneDelegate/widget entry points) →
///   Protocol conformances → Private implementation grouped by concern.
@MainActor
class ViewController: UIViewController, AVAudioPlayerDelegate {
    // MARK: - Private Properties and Constants
    
    // NOTE: lastAppliedVisualState, selectedStreamIndex (mirror only for legacy sync spots),
    // tuning*, streamSwitch*, sleep UI*, hasShownSecurityAlert, hasPlayedSpecialTuningSound, hasEverPlayed
    // and related orchestration state now live exclusively in RadioPlayerCoordinator. VC keeps only
    // what is required for the thin host surface (network flags, isDeallocating, test accessors,
    // widget polling debounce/processed set, pending widget switch work item).
    
    // Cellular permission state + migration + per-launch prompting is fully extracted to CellularPermissionManager
    // (owned here because the network path handler + alert presentation remain in the retained thin host surface
    // per decomposition guardrails; the manager contains no security or streaming logic).
    private let cellularPermissionManager = CellularPermissionManager()
    
    private var lastWidgetSwitchTime: Date?
    private var pendingWidgetSwitchWorkItem: DispatchWorkItem?
    private var processedActionIds: Set<String> = []
    
    // Widget play/pause action debouncing (prevents rapid taps from widget causing AVFoundation thrashing)
    private var lastWidgetActionTime: Date = .distantPast
    private let widgetActionDebounceInterval: TimeInterval = 0.65
    
    // MARK: - UI Elements
    /// The main title label displaying "Lutheran Radio".
    /// - Accessibility: Labeled for VoiceOver with dynamic font support.
    let titleLabel: UILabel = {
        let label = UILabel()
        label.text = String(localized: "lutheran_radio_title", table: "Localizable")
        label.textAlignment = .center
        label.font = UIFont.preferredFont(forTextStyle: .title1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isAccessibilityElement = true
        label.accessibilityLabel = String(localized: "lutheran_radio_title", table: "Localizable")
        return label
    }()
    
    /// Composed language/flag selector (custom horizontal scroller + red tuning needle).
    /// Owns collection, indicator, all needle math, and collection protocols.
    /// ViewController retains selectedStreamIndex + all playback intent / stream switch logic.
    let languageSelectorView = LanguageSelectorView()

    /// Background image + Core Image processing.
    /// Owns the full-bleed backgroundImageView, all CI filtering (dark/light morphology + controls),
    /// caching, in-flight coalescing, cold-launch + stream-switch deferral (attach + ICY stable),
    /// low-power fast path, energy efficiency (LPM parallax + raw image), and parallax.
    /// ViewController performs hierarchy addition + constraints and drives via the narrow hooks
    /// at the correct moments. All heavy logic moved verbatim (behavior preserved).
    let backgroundImageController = BackgroundImageController()

    // Playback controls (play/pause + sleep timer button + playback status) and now-playing metadata/speaker
    // are composed views. Owner (VC) wires a few buttons for menus/animation and calls narrow setters at the
    // right moments. All visual rendering for these elements is now encapsulated; intent + sleep countdown logic stay here.
    let playbackControlsView = PlaybackControlsView()
    let nowPlayingMetadataView = NowPlayingMetadataView()

    /// Lightweight RadioPlayerCoordinator (wiring + full stream selection flow + visual distribution + sleep glue + haptics + initial sequencing).
    var radioPlayerCoordinator: RadioPlayerCoordinator!

    let volumeSlider: UISlider = {
        let slider = UISlider()
        slider.minimumValue = 0.0
        slider.maximumValue = 1.0
        slider.value = 0.5 // Default volume
        slider.minimumTrackTintColor = .tintColor
        slider.maximumTrackTintColor = .tertiaryLabel
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.isAccessibilityElement = true
        slider.accessibilityLabel = String(localized: "accessibility_label_volume", table: "Localizable")
        slider.accessibilityHint = String(localized: "accessibility_hint_volume", table: "Localizable")
        return slider
    }()
    
    let airplayButton: AVRoutePickerView = {
        let view = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        view.tintColor = .tintColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isAccessibilityElement = true
        view.accessibilityLabel = String(localized: "accessibility_label_airplay", table: "Localizable")
        view.accessibilityHint = String(localized: "accessibility_hint_airplay", table: "Localizable")
        return view
    }()
    
    // Local hapticEngine lazy + handlers removed (single owner in RadioPlayerCoordinator).
    // The early init call site in viewDidLoad was removed; wireAndInitialSetup performs equivalent.
    
    // selectedStreamIndex kept as thin mirror only for a few legacy sync sites in checkForPending/play paths
    // that read it before delegating. All orchestration mutates the one in RadioPlayerCoordinator.
    private var selectedStreamIndex: Int = 0
    
    private var isInitialSetupComplete = false
    
    // MARK: - Audio and Streaming
    // New streaming player
    nonisolated private let streamingPlayer: DirectStreamingPlayer
    private let audioQueue = DispatchQueue(label: "radio.lutheran.audio", qos: .userInitiated)

    private let appLaunchTime = Date()
    private var isPlaying = false
    // All decision logic, guards, and resurrection control now live exclusively in SharedPlayerManager.currentPlaybackIntent.
    private var networkMonitor: NWPathMonitor?
    private var networkMonitorHandler: (@Sendable (NWPath) -> Void)? // Store handler to clear it
    private var hasInternetConnection = true
    private var connectivityCheckTimer: Timer?
    private var lastConnectionAttemptTime: Date?
    private var isDeallocating = false // Flag to prevent operations during deallocation

    // NOTE (P5): Most orchestration state removed (see above). Retained for the *special* cold-launch tuning sound path only
    // (the one path that stays in VC host because it is the unique user of AVAudioPlayerDelegate + TuningSoundCoordinator gate):
    private var hasPlayedSpecialTuningSound = false
    private var isTuningSoundPlaying = false
    private var tuningPlayer: AVAudioPlayer?
    // (lastTuningSoundTime + regular playTuningSound/stopTuningSound fully removed; regular tuning delight now only in coordinator.)

    // Retained (P5): sleep interaction suppression state for the onMetadataChange callback (which lives in VC because it is registered on the streamingPlayer here).
    // The coordinator's sleep handlers set the authoritative flag; we sync it here so the callback sees the window and stashes to both copies so coordinator finish can consume.
    // internal (not private) so RadioPlayerCoordinator (same module, via weak viewController) can sync the flag/pending for the metadata suppression window that is observed from VC's onMetadataChange callback.
    var isSleepTimerInteractionActive = false
    var pendingMetadataVisualRefresh: String?
    
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
    /// Initializes the view hierarchy and initial stream selection.
    /// - Note: Performs heavy setup; defers non-critical tasks with asyncAfter for better launch performance.
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        // Processed image cache limit is now configured inside BackgroundImageController.
        
        // Add custom accessibility actions for playPauseButton (now owned by playbackControlsView)
        playbackControlsView.playPauseButton.accessibilityCustomActions = [
            UIAccessibilityCustomAction(
                name: String(localized: "toggle_playback", defaultValue: "Toggle Playback", table: "Localizable", comment: "Accessibility action to toggle playback"),
                target: self,
                selector: #selector(togglePlayback)
            )
        ]
        
        // Add custom accessibility actions for volumeSlider
        volumeSlider.accessibilityCustomActions = [
            UIAccessibilityCustomAction(
                name: String(localized: "increase_volume", defaultValue: "Increase Volume", table: "Localizable", comment: "Accessibility action to increase volume"),
                target: self,
                selector: #selector(increaseVolume)
            ),
            UIAccessibilityCustomAction(
                name: String(localized: "decrease_volume", defaultValue: "Decrease Volume", table: "Localizable", comment: "Accessibility action to decrease volume"),
                target: self,
                selector: #selector(decreaseVolume)
            )
        ]
        
        // Register for preferred content size category changes
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (controller: Self, previousTraitCollection: UITraitCollection) in
            guard let self else { return }
            nowPlayingMetadataView.setMetadata(
                nowPlayingMetadataView.metadataLabel.text ?? String(localized: "no_track_info", table: "Localizable")
            )
        }
        
        // Playback audio session is configured in DirectStreamingPlayer.init (single owner).
        
        // Haptic engine init + start is owned by RadioPlayerCoordinator.wireAndInitialSetup() (single owner of haptics).
        // Local hapticEngine lazy + startHapticEngine/playHapticFeedback bodies deleted (calls forwarded).
        
        setupDarwinNotificationListener()
        setupUI()
        
        // Create + wire coordinator after hierarchy is built.
        radioPlayerCoordinator = RadioPlayerCoordinator(
            languageSelectorView: languageSelectorView,
            backgroundImageController: backgroundImageController,
            playbackControlsView: playbackControlsView,
            nowPlayingMetadataView: nowPlayingMetadataView,
            streamingPlayer: streamingPlayer
        )
        radioPlayerCoordinator.viewController = self
        radioPlayerCoordinator.presentAlert = { [weak self] alert in self?.present(alert, animated: true) }
        radioPlayerCoordinator.wireAndInitialSetup()
        
        // No instance selectedStreamIndex mutation or onSelectionChanged wiring here (coordinator owns).
        // Compute initial language preferring the PersistedWidgetState last language (via SSOT helper)
        // so the early seed, persist snapshot, player model, updateUserDefaultsLanguage, *and* the
        // coordinator's needle (set in wireAndInitialSetup) are consistent for "last stream remembered".
        // Falls back via bestInitialLanguageCode (robust preferredLanguages) when no snapshot
        // (first-run / clear / privacy). Uses the shared indexForLanguageCode helper.
        let languageCode = SharedPlayerManager.preferredMainAppInitialLanguageCode()
        let initialIndex = DirectStreamingPlayer.indexForLanguageCode(languageCode)
        selectedStreamIndex = initialIndex  // Seed thin mirror for viewDidLayoutSubviews notifyLayoutChange (width-claim) so initial needle is not stomped by stale 0 (regression guard)
        
        // Set initial volume slider position (UI only)
        let volumeToUse = preferredVolume()
        volumeSlider.value = volumeToUse
        volumeSlider.accessibilityValue = unsafe String(format: String(localized: "accessibility_value_volume", table: "Localizable"), Int(volumeToUse * 100))
        #if DEBUG
        print("[ViewController] Set initial volumeSlider to \(volumeToUse)")
        #endif
        
        setupControls()
        // Reset per-launch cellular permission flags early (before network monitoring can fire the expensive path).
        // The manager itself seeds the persisted permission + does legacy migration on init.
        cellularPermissionManager.resetPerLaunchFlags()
        setupNetworkMonitoring()
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

        // Sleep timer notification observer + initial sync is owned exclusively by RadioPlayerCoordinator (added in wireAndInitialSetup + viewDidAppearResurrectionCheck).
        // VC no longer observes or syncs the sleep UI glue.
        
        // Energy Efficiency Optimizations (iOS 26) — now owned by BackgroundImageController.
        // The controller self-registers for power state notifications and reacts using its last stream.
        backgroundImageController.updateForEnergyEfficiency()
        
        // === Asynchronous initialization (required for Swift 6 concurrency) ===
        Task { @MainActor [weak self] in
            guard let self else { return }
            
            let initialStream = SharedPlayerManager.streamForLanguageCode(languageCode)
            
            // In-memory UI + model setup only (selector needle, player selectedStream).
            // These are required for the app to be usable on launch and do not re-create
            // "recently deleted" persisted data (snapshot, lastUpdateTime, language liveness signals).
            self.updateUI(for: .prePlay)
            
            // Stream model and UI only; secured AVPlayerItem is created once in setStreamAndPlay after tuning.
            await self.streamingPlayer.setSelectedStreamModelOnly(to: initialStream)
            
            // Background deferral state is now owned by BackgroundImageController (cold launch path preserved).
            // Actual image processing is deferred until playback is stable; choosing the initial lang
            // for prep is acceptable (not an "I listened" signal).
            backgroundImageController.scheduleDeferredForStreamSwitch(initialStream)
            
            await self.playSpecialTuningSound()
            
            let visualState = await SharedPlayerManager.shared.currentVisualState
            let intent = await SharedPlayerManager.shared.currentPlaybackIntent
            #if DEBUG
            print("[ViewController] After tuning — visualState = \(visualState), intent = \(intent)")
            #endif
            
            // Post-clear cold launch first play (visual .prePlay + .cleared intent, or normal prePlay):
            // the guard now allows the success path. We deliberately perform identifying writes
            // (persist seed, updateUserDefaultsLanguage which bumps lastUpdateTime + saveCombined +
            // refresh) ONLY after the guard passes. This ensures recently deleted data is not
            // re-created by launch setup until either (a) explicit manual play or (b) the successful
            // post-clear cold-start play. If the guard blocks, no such writes occur.
            // The initialStream language here now comes from the centralized bestInitialLanguageCode
            // (preferredLanguages match) rather than the old fragile Locale.current path.
            guard visualState == .prePlay || visualState.shouldAutoPlayOrResume || intent == .cleared else {
                #if DEBUG
                print("[ViewController] Blocked initial playback — state = \(visualState)")
                #endif
                return
            }
            
            if intent == .cleared {
                #if DEBUG
                print("[ViewController] post-clear cold launch — allowing initial playback and state creation")
                #endif
            }
            
            guard self.hasInternetConnection else { return }
            
            // Identifying / persistence writes (snapshot seed, lastUpdateTime bump, combined state,
            // widget refresh) happen here — only on the path that will actually start the post-clear
            // first play. This satisfies the "deleted data not re-created until play or post-clear cold launch".
            // Seed snapshot here (after guard) rather than before player init; status handling and
            // prePlay visual now tolerate the timing.
            //
            // Post-clear + widget-installed: the clear path forces hasActiveWidgets=false (to avoid
            // immediate re-population of identifying state). On the *successful post-clear cold-start play*
            // we are now at the permitted moment to (re)create the snapshot with the reseeded language
            // (bestInitialLanguageCode via the captured initialStream). Re-query here so the gate in
            // persistWidgetSnapshot / saveCombined opens for this explicit first write.
            if !SharedPlayerManager.hasActiveWidgets {
                await WidgetRefreshManager.shared.refreshHasActiveWidgets()
            }
            SharedPlayerManager.persistWidgetSnapshot(
                visualState: .prePlay,
                language: initialStream.languageCode
            )
            await SharedPlayerManager.shared.refreshVisualStateFromPersistence()
            
            radioPlayerCoordinator?.updateUserDefaultsLanguage(initialStream.languageCode)
            
            #if DEBUG
            print("[ViewController] Starting initial stream playback after tuning (single source)")
            #endif
            
            self.streamingPlayer.cancelPendingSSLProtection()
            self.streamingPlayer.resetTransientErrors()
            
            // ONE central call — play() waits on TuningSoundCoordinator until the special clip finishes.
            // viewDidAppear will NOT trigger another play() for .prePlay.
            // Cold-launch initial playback: permitted direct call to play() after coordinator
            // guard (see RadioPlayerCoordinator.performColdLaunchPlaybackIfAllowed and
            // userRequestedPlay Precondition in SPM). Not an "explicit tap" path.
            await SharedPlayerManager.shared.play()
            self.restoreVolume()
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Only react to *width* changes. Height-only shifts (e.g. long metadata pushing
        // the contentStackView taller) must not retrigger needle positioning.
        // Forward to the extracted LanguageSelectorView (it owns lastCollectionViewSize + epsilon guard + needle math).
        languageSelectorView.notifyLayoutChange(currentSelectedIndex: selectedStreamIndex)
        radioPlayerCoordinator?.notifyLayoutChange()
    }
    
    private func preferredVolume() -> Float {
        guard let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            return 0.5
        }
        let savedVolume = sharedDefaults.float(forKey: "preferredVolume")
        let volumeToUse = savedVolume > 0 ? savedVolume : 0.5
        // Persist default if none exists (for consistency with restoreVolume)
        persistPreferredVolume(volumeToUse)
        return volumeToUse
    }

    private func persistPreferredVolume(_ volume: Float) {
        guard let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return }
        sharedDefaults.set(volume, forKey: "preferredVolume")
        sharedDefaults.synchronize()
    }
    
    private func restoreVolume() {
        let volumeToUse = preferredVolume()
        volumeSlider.value = volumeToUse
        streamingPlayer.setVolume(volumeToUse)
    }
    
    func setupDarwinNotificationListener() {
        let notificationName = "radio.lutheran.widget.action"
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        
        // Use a simpler approach without context pointer
        unsafe CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (_, observer, _, _, _) in
                guard let observer = unsafe observer else { return }
                let vc = unsafe Unmanaged<ViewController>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    #if LUTHERAN_MAIN_APP
                    let hasPendingAction = SharedPlayerManager.shared.hasPendingWidgetAction()
                    if DarwinSelfEchoGuard.shouldSuppressPauseEcho(hasPendingAction: hasPendingAction) {
                        #if DEBUG
                        print("[ViewController] Ignoring self-posted Darwin pause notification echo")
                        #endif
                        return
                    }
                    #endif

                    #if DEBUG
                    print("[ViewController] Received Darwin notification for widget action")
                    #endif
                    vc.checkForPendingWidgetActions()
                }
            },
            notificationName as CFString,
            nil,
            .deliverImmediately
        )
        
        #if DEBUG
        print("[ViewController] Darwin notification listener setup complete")
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
        
        // Cold-launch needle: viewDidLayoutSubviews width-change guard only (no delayed appear updates).
        
        // ───────────────────────────────────────────────────────────────────
        // SAFE playback trigger in viewDidAppear — ONLY for resurrection cases
        // NO auto-play on cold launch (prePlay). That is handled in viewDidLoad after tuning.
        // ───────────────────────────────────────────────────────────────────
        Task { @MainActor in
            let visualState = await SharedPlayerManager.shared.currentVisualState
            
            #if DEBUG
            print("[ViewController] viewDidAppear → currentVisualState = \(visualState)")
            #endif
            
            switch visualState {
            case .prePlay:
                #if DEBUG
                print("[ViewController] viewDidAppear → prePlay on cold launch → SKIPPING (handled in viewDidLoad after tuning)")
                #endif
                // Do nothing — playback already started from viewDidLoad Task
                
            case .playing:
                #if DEBUG
                print("[ViewController] viewDidAppear → already playing, no action needed")
                #endif
                
            case .userPaused, .thermalPaused, .securityLocked:
                #if DEBUG
                print("[ViewController] viewDidAppear → \(visualState) → SKIPPING auto-play (resurrection prevented)")
                #endif
            }

            // Sleep timer display sync is performed inside viewDidAppearResurrectionCheck (coordinator).
            await self.radioPlayerCoordinator?.viewDidAppearResurrectionCheck()
        }
    }
    
    /// Thin delegate to `SharedPlayerManager.saveCurrentState()` so widgets and Live Activities
    /// receive the authoritative `PersistedWidgetState` snapshot. Debouncing lives in
    /// `WidgetRefreshManager`; this path does not apply its own throttle.
    ///
    ///
    ///
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
                    print("[ViewController] Fast widget action checking completed")
                    #endif
                }
            }
        }
    }
    
    // MARK: - Streaming Callbacks (metadata only)
    // Status changes: StreamingPlayerDelegate.onStatusChange → updateUI(for:).
    // onMetadataChange only (speaker photo, metadata label, Now Playing).
    
    private func setupStreamingCallbacks() {
        streamingPlayer.onMetadataChange = { [weak self] metadata in
            guard let self else {
                #if DEBUG
                print("[ViewController] onMetadataChange: ViewController is nil, skipping callback")
                #endif
                return
            }
            
            // Process metadata on background (regex is cheap and thread-safe).
            // The regex helper now lives in nowPlayingMetadataView (small pure helper); use it to avoid duplication.
            let potentialNames: [String] = metadata.map { nowPlayingMetadataView.potentialNames(from: $0) } ?? []
            
            // Hop to main for UI updates only
            DispatchQueue.main.async { [self] in
                if let metadata = metadata {
                    self.nowPlayingMetadataView.setMetadata(metadata)
                    if self.isSleepTimerInteractionActive {
                        self.pendingMetadataVisualRefresh = metadata
                        // Also stash to coordinator copy so its finishSleepTimerInteraction (which owns consumption) sees it.
                        radioPlayerCoordinator?.pendingMetadataVisualRefresh = metadata
                    } else {
                        self.updateNowPlayingInfo(title: metadata)
                        self.nowPlayingMetadataView.applySpeakerVisuals(for: metadata, potentialNames: potentialNames)
                    }
                } else {
                    self.nowPlayingMetadataView.setMetadata(String(localized: "no_track_info", table: "Localizable"))
                    if !self.isSleepTimerInteractionActive {
                        self.updateNowPlayingInfo()
                        self.nowPlayingMetadataView.speakerImageView.isHidden = true
                    }
                }
                self.saveStateForWidget()
            }
        }
    }
    
    // showSecurityModelAlert + showSSLTransitionAlert removed (their creation + presentation logic lives inside RadioPlayerCoordinator.updateUI/handleStatusChange using the injected presentAlert hook).
    // No call sites remain in VC.
    
    private func setupControls() {
        // Targets and identifiers are on the composed controls view's buttons
        playbackControlsView.playPauseButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        // Menu construction (and all sleep countdown/menu state machine) is in coordinator.
        radioPlayerCoordinator?.configureSleepTimerButtonMenu()
        playbackControlsView.sleepTimerButton.accessibilityIdentifier = "sleepTimerButton"
        playbackControlsView.playPauseButton.accessibilityIdentifier = "playPauseButton"
        playbackControlsView.playPauseButton.accessibilityHint = String(localized: "accessibility_hint_play_pause", table: "Localizable")
        playbackControlsView.playPauseButton.accessibilityLabel = String(localized: "accessibility_label_play", table: "Localizable")  // e.g., "Play" in Localizable.strings
        playbackControlsView.playPauseButton.accessibilityTraits = [.button, .playsSound]  // Hints that it triggers sound
        
        volumeSlider.addTarget(self, action: #selector(volumeChanged(_:)), for: .valueChanged)
        volumeSlider.accessibilityIdentifier = "volumeSlider"
        volumeSlider.accessibilityHint = String(localized: "accessibility_hint_volume", table: "Localizable")
        volumeSlider.accessibilityLabel = String(localized: "accessibility_label_volume", table: "Localizable")  // e.g., "Volume"
        volumeSlider.accessibilityTraits = .adjustable  // Default, but explicit for clarity
        volumeSlider.accessibilityValue = unsafe String(format: String(localized: "accessibility_value_volume", table: "Localizable"), Int(volumeSlider.value * 100))  // e.g., "50 percent"
        
        // Add AirPlay button tap feedback
        airplayButton.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(airplayTapped)))
        airplayButton.accessibilityLabel = String(localized: "accessibility_label_airplay", table: "Localizable")  // e.g., "AirPlay picker"
        airplayButton.accessibilityHint = String(localized: "accessibility_hint_airplay", table: "Localizable")  // e.g., "Double tap to select audio output"
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
    
    // MARK: - Network and Interruption Handling
    private func setupNetworkMonitoring() {
        networkMonitor?.cancel()
        networkMonitor = nil
        networkMonitor = NWPathMonitor()
        #if DEBUG
        print("[ViewController] Setting up network monitoring")
        #endif
        networkMonitorHandler = { [weak self] path in
            guard let self = self else {
                #if DEBUG
                print("[ViewController] pathUpdateHandler: ViewController is nil, skipping callback")
                #endif
                return
            }
            let isConnected = path.status == .satisfied
            let isExpensive = path.isExpensive
            DispatchQueue.main.async {
                // Smarter cellular / metered data permission prompt (replaces the prior binary "don't show again" once-per-launch alert).
                // Decision, persistence, migration, and per-launch guards live in the extracted CellularPermissionManager.
                // The prompt is shown only on the isExpensive branch; security reconnection / validation logic below is untouched.
                if self.cellularPermissionManager.shouldShowPrompt(isConnected: isConnected, isExpensive: isExpensive) {
                    self.showCellularDataAlert()
                    self.cellularPermissionManager.markPromptedThisLaunch()
                }

                // Existing network status handling
                let wasConnected = self.hasInternetConnection
                self.hasInternetConnection = isConnected
                #if DEBUG
                print("[ViewController] Network path update: status=\(path.status), isExpensive=\(path.isExpensive), isConstrained=\(path.isConstrained)")
                #endif
                if isConnected != wasConnected {
                    #if DEBUG
                    print("[ViewController] Network status changed: \(isConnected ? "Connected" : "Disconnected")")
                    #endif
                }
                if isConnected && !wasConnected {
                    #if DEBUG
                    print("[ViewController] Network monitor detected reconnection")
                    #endif
                    self.radioPlayerCoordinator?.stopTuningSound()
                    self.handleNetworkReconnection()
                } else if !isConnected && wasConnected {
                    #if DEBUG
                    print("[ViewController] Network disconnected - stopping playback and tuning sound")
                    #endif
                    self.radioPlayerCoordinator?.stopTuningSound()
                    self.stopPlayback()
                    self.updateUIForNoInternet()
                    // Playback intent (userPaused / securityLocked) is now authoritative in SharedPlayerManager.
                }
            }
        }
        networkMonitor?.pathUpdateHandler = networkMonitorHandler
        let monitorQueue = DispatchQueue(label: "NetworkMonitor", qos: .utility)
        networkMonitor?.start(queue: monitorQueue)
        setupConnectivityCheckTimer()
    }
    
    private func showCellularDataAlert() {
        let alert = UIAlertController(
            title: String(localized: "mobile_data_usage_title", table: "Localizable"),
            message: String(localized: "mobile_data_usage_message", table: "Localizable"),
            preferredStyle: .alert
        )

        // "Always Allow" — persist .alwaysAllow (also writes legacy compat flag) and allow playback on cellular.
        alert.addAction(UIAlertAction(title: String(localized: "cellular_always_allow", table: "Localizable"), style: .default) { [weak self] _ in
            guard let self else { return }
            self.cellularPermissionManager.setAlwaysAllow()
            self.cellularPermissionManager.markPromptedThisLaunch()
        })

        // "Allow for This Session" — in-memory only until next launch; no permanent write beyond the session flag.
        alert.addAction(UIAlertAction(title: String(localized: "cellular_allow_this_session", table: "Localizable"), style: .default) { [weak self] _ in
            guard let self else { return }
            self.cellularPermissionManager.setSessionAllow()
            self.cellularPermissionManager.markPromptedThisLaunch()
        })

        // "Not Now" — treat as explicit user pause for this launch on cellular; stop via SSOT so intent becomes .userPaused,
        // widgets/Live Activities update, and no auto-resurrection until next explicit user play. Prompt will re-appear on next launch for .ask.
        alert.addAction(UIAlertAction(title: String(localized: "cellular_not_now", table: "Localizable"), style: .cancel) { [weak self] _ in
            guard let self else { return }
            self.cellularPermissionManager.setAsk()
            self.cellularPermissionManager.markPromptedThisLaunch()
            self.stopPlayback()
        })

        present(alert, animated: true, completion: nil)
    }
    
    private func setupInterruptionHandling() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil)
    }
    
    @objc private func handleInterruption(_ notification: Notification) {
        guard !isDeallocating else {
            #if DEBUG
            print("[ViewController] handleInterruption: ViewController is deallocating, skipping")
            #endif
            return
        }
        
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        switch type {
        case .began:
            #if DEBUG
            print("[ViewController] AVAudioSession interruption began (isPlaying=\(isPlaying))")
            #endif
            if isPlaying {
                stopPlayback()
            }
            radioPlayerCoordinator?.stopTuningSound()
            
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            
            // Always try to reactivate the session
            try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            
            // === Important guard: Respect PlayerVisualState user intent ===
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
                    print("[ViewController] ▶ [Interruption Guard] Allowed resume after interruption")
                    #endif
                    
                    // Recovery path after AV interruption .shouldResume (guard already verified
                    // canProceed / !sticky via shouldAutoPlayOrResume). Direct SPM.play() is
                    // permitted here (recovery + intent already known active per the
                    // userRequestedPlay Precondition).
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
            print("[ViewController] handleRouteChange: ViewController is deallocating, skipping")
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
            Task { @MainActor in
                // Route-change recovery: only proceed if intent permits (defensive; SPM.play
                // would also block). This is a technical recovery path, not explicit user play.
                // (See userRequestedPlay Precondition for permitted direct play() cases.)
                if await SharedPlayerManager.shared.canProceedWithPlayback() {
                    await SharedPlayerManager.shared.play()
                }
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
                    print("[ViewController] connectivityCheckTimer: ViewController is nil, skipping callback")
                    #endif
                    return
                }
                self.performActiveConnectivityCheck()
            }
        }
    }
    
    private func performActiveConnectivityCheck() {
        guard !hasInternetConnection else { return }
        
        if let lastAttempt = lastConnectionAttemptTime,
           Date().timeIntervalSince(lastAttempt) < 10.0 {
            return
        }
        
        lastConnectionAttemptTime = Date()
        
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 5.0
        let session = URLSession(configuration: config)
        
        // Use our makeURL helper for consistency and safety
        let url = DirectStreamingPlayer.makeURL("https://www.apple.com/library/test/success.html")
        
        let task = session.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else {
                #if DEBUG
                print("[ViewController] performActiveConnectivityCheck: ViewController is nil, skipping callback")
                #endif
                return
            }
            
            let success = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
            
            DispatchQueue.main.async {
                if success && !self.hasInternetConnection {
                    #if DEBUG
                    print("[ViewController] Active check detected internet connection")
                    #endif
                    self.hasInternetConnection = true
                    self.handleNetworkReconnection()
                }
            }
        }
        task.resume()
    }
    
    /// Handles network reconnection (and active connectivity poll success) by re-validating
    /// the security model and conditionally resuming playback.
    ///
    /// This is invoked from the `NWPathMonitor` `pathUpdateHandler` when `isConnected && !wasConnected`,
    /// and from `performActiveConnectivityCheck` when a live probe succeeds while
    /// `hasInternetConnection` was previously false.
    ///
    /// Flow:
    /// 1. Force `hasInternetConnection = true`.
    /// 2. Reset transient streaming errors on the engine.
    /// 3. Perform explicit security re-validation via `SecurityModelValidator`.
    /// 4. On success **and** only if `currentPlaybackIntent` permits (`canProceedWithPlayback`),
    ///    call `SharedPlayerManager.play()` (technical recovery path).
    /// 5. On validation failure, present a one-time security alert (if none is already shown).
    ///
    /// - Important: Reconnection is a **technical recovery**, not an explicit user play/resume.
    ///   It must never call `userRequestedPlay()`. Doing so would invoke `setUserIntentToPlay()`,
    ///   clearing any `.userPaused`, `.cleared`, or similar sticky lock and violating the
    ///   resurrection protection contract.
    /// - Precondition: Called only on the main actor (enforced by the Task { @MainActor } and
    ///   the NWPathMonitor dispatch).
    /// - Postcondition: If playback resumes, it does so through the authoritative SPM path
    ///   (visual state, persistence, Now Playing, and widget/LA snapshots are updated by `play()`).
    ///   If intent is `.userPaused` / `.securityLocked` / `.cleared`, no playback is started.
    /// - Note: The explicit `validateSecurityModel()` success check is the preserved
    ///   reconnection trigger condition. `SPM.play()` will validate again internally (safe).
    /// - SeeAlso: ``SharedPlayerManager/play()``, ``SharedPlayerManager/userRequestedPlay()``,
    ///   ``SharedPlayerManager/canProceedWithPlayback()``, ``SharedPlayerManager/currentPlaybackIntent``,
    ///   `DirectStreamingPlayer.resetTransientErrors()`, `SecurityModelValidator.validateSecurityModel()`,
    ///   `setupNetworkMonitoring()`, `performActiveConnectivityCheck()`,
    ///   RadioPlayerCoordinator (other recovery patterns: interruption, route change, cold launch),
    ///   <doc:Architecture>, CODING_AGENT.md (Single Source of Truth Principles + permitted `play()` cases).
    ///
    /// AGENT NOTE: Prior to the intent model, this method performed the direct low-level call
    /// `_ = await self.streamingPlayer.play()` inside the `if isValid` block. That bypassed
    /// `currentPlaybackIntent`, `canProceedWithPlayback`, `setPlaying` / visual updates,
    /// `saveCurrentState` (widgets, Live Activities, Now Playing), and the single source of truth
    /// for resurrection. Even after engine guards were added, the call site itself was not
    /// authoritative. The current pattern (`canProceed ? SPM.play() : nothing`) is the correct
    /// technical-recovery usage of the permitted direct `play()` case. It matches the style used
    /// for route-change recovery and guarded interruption `.shouldResume`. `userRequestedPlay()`
    /// is deliberately reserved for button taps, widget play actions, remote commands, Siri, etc.
    ///
    /// This path no longer bypasses the playback intent model.
    private func handleNetworkReconnection() {
        hasInternetConnection = true
        
        #if DEBUG
        print("[ViewController] Network reconnected - checking validation state")
        #endif
        
        Task { @MainActor in
            // 1. Reset transient failures
            self.streamingPlayer.resetTransientErrors()
            
            // 2. Re-validate using the shared actor (this success condition is the preserved
            //    trigger for the reconnection playback attempt per historical behavior).
            let isValid = await SecurityModelValidator.shared.validateSecurityModel()
            
            if isValid {
                #if DEBUG
                print("[ViewController] Validation succeeded after reconnection - attempting playback (via SPM.play for intent consistency)")
                #endif
                
                // Recovery after network: call through SPM.play() (permitted technical recovery path)
                // rather than raw engine play(). The canProceed guard ensures we only proceed for
                // active intents (.shouldBePlaying); sticky states (.userPaused, .securityLocked,
                // .cleared) cause an early return here and we never reach clearUserPausedLockIfNeeded
                // inside play().
                //
                // Contrast with userRequestedPlay(), which always does setUserIntentToPlay() first.
                // Using that here would incorrectly resurrect after an explicit user pause.
                if await SharedPlayerManager.shared.canProceedWithPlayback() {
                    await SharedPlayerManager.shared.play()
                }
                
            } else {
                #if DEBUG
                print("[ViewController] Security model validation failed after reconnection")
                #endif
                
                // Show alert only if not already presenting one (security error path unchanged)
                if presentedViewController == nil {
                    let alert = UIAlertController(
                        title: String(localized: "security_model_error_title", table: "Localizable"),
                        message: String(localized: "security_model_error_message", table: "Localizable"),
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: String(localized: "ok", table: "Localizable"), style: .default))
                    present(alert, animated: true)
                }
            }
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
        // Single implementation lives in RadioPlayerCoordinator (orchestration owner).
        // VC retains the method for the @objc togglePlayback + public handleTogglePlayback call sites.
        await radioPlayerCoordinator?.handleUserTogglePlayback()
    }
    
    private func updateNowPlayingInfo(title: String? = nil) {
        radioPlayerCoordinator?.updateNowPlayingInfo(title: title)
    }
    
    private func updateUIForNoInternet() {
        radioPlayerCoordinator?.updateUIForNoInternet()
    }
    
    // MARK: - Playback Control Methods
    
    /// Pauses playback and updates UI/status.
    /// - Note: Sets manual pause flag and routes through SharedPlayerManager to ensure .userPaused state is set.
    private func pausePlayback() {
        // Implementation in coordinator.
        radioPlayerCoordinator?.pausePlayback()
    }
    
    // MARK: - Manual Pause (user tap)
    private func stopPlayback() {
        // Implementation in coordinator.
        radioPlayerCoordinator?.stopPlayback()
    }
    
    @MainActor
    private func updateUI(for visualState: PlayerVisualState) {
        // The skip-last + distribution + security alert side-effect logic lives in coordinator (single owner).
        // VC keeps a 1-line forwarder for the remaining call sites in host-owned paths (network, interruptions, legacy widget action).
        radioPlayerCoordinator?.updateUI(for: visualState)
    }
    
    @objc private func volumeChanged(_ sender: UISlider) {
        streamingPlayer.setVolume(sender.value)
        sender.accessibilityValue = unsafe String(format: String(localized: "accessibility_value_volume", table: "Localizable"), Int(sender.value * 100))  // e.g., "75 percent"
        persistPreferredVolume(sender.value)
    }
    
    private func setupUI() {
        // backgroundImageView is owned and configured by BackgroundImageController.
        // We only add it to the hierarchy and apply the full-bleed (parallax bleed) constraints here.
        let bgView = backgroundImageController.backgroundImageView
        view.addSubview(bgView)
        // Modern + cleaner: activate directly, no unnecessary stored array
        NSLayoutConstraint.activate([
            bgView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: -20),
            bgView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: 20),
            bgView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: -20),
            bgView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 20)
        ])
        bgView.layer.zPosition = -1
        
        view.addSubview(titleLabel)
        view.addSubview(languageSelectorView)

        // Use the composed controls view (internal stack + sizes for play/sleep/playback status).
        // External constraints only touch the container (top/center/height + volume below it).
        view.addSubview(playbackControlsView)
        view.addSubview(volumeSlider)

        // Metadata label is driven by the composed metadata view (contentStack still used for
        // identical vertical spacing/leading/trailing to language selector). Speaker image is vended
        // and placed exactly where it was (below language selector).
        view.addSubview(nowPlayingMetadataView.speakerImageView)
        let contentStackView = UIStackView(arrangedSubviews: [nowPlayingMetadataView.metadataLabel])
        contentStackView.axis = .vertical
        contentStackView.alignment = .center
        contentStackView.spacing = 10
        contentStackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentStackView)
        
        view.addSubview(airplayButton)
        
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playbackControlsView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 20),
            playbackControlsView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playbackControlsView.heightAnchor.constraint(equalToConstant: 50),
            volumeSlider.topAnchor.constraint(equalTo: playbackControlsView.bottomAnchor, constant: 20),
            volumeSlider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            volumeSlider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            contentStackView.topAnchor.constraint(equalTo: volumeSlider.bottomAnchor, constant: 20),
            contentStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            contentStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            languageSelectorView.topAnchor.constraint(equalTo: contentStackView.bottomAnchor, constant: 20),
            languageSelectorView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            languageSelectorView.widthAnchor.constraint(equalTo: view.widthAnchor),
            languageSelectorView.heightAnchor.constraint(equalToConstant: 50),
            nowPlayingMetadataView.speakerImageView.topAnchor.constraint(equalTo: languageSelectorView.bottomAnchor, constant: 20),
            nowPlayingMetadataView.speakerImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            nowPlayingMetadataView.speakerImageView.widthAnchor.constraint(equalToConstant: 100),
            airplayButton.topAnchor.constraint(equalTo: nowPlayingMetadataView.speakerImageView.bottomAnchor, constant: 20),
            airplayButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            airplayButton.widthAnchor.constraint(equalToConstant: 44),
            airplayButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        nowPlayingMetadataView.speakerImageHeightConstraint = nowPlayingMetadataView.speakerImageView.heightAnchor.constraint(equalToConstant: 50)
        nowPlayingMetadataView.speakerImageHeightConstraint?.isActive = true

        // NOTE: LanguageSelectorView now internally creates its collectionView + selectionIndicator,
        // adds the indicator as subview of the collection, and activates its own needleCenterXConstraint.
        // All needle math and layout delegate work is encapsulated there.
        // PlaybackControlsView owns its internal horizontal stack + playback status/button sizing.
        // NowPlayingMetadataView owns the metadata label + speaker image + apply logic.
    }
    
    @objc private func handleMemoryWarning() {
        #if DEBUG
        print("[ViewController] Received memory warning")
        #endif
        
        // Clear image cache to free memory (delegated to BackgroundImageController)
        backgroundImageController.clearCache()
        #if DEBUG
        print("[ViewController] Requested background image cache clear (handled by BackgroundImageController)")
        #endif
    }
    
    // MARK: - Audio Setup
    func playSpecialTuningSound(completion: (() -> Void)? = nil) async {
        guard !hasPlayedSpecialTuningSound else {
            #if DEBUG
            print("[ViewController] Special tuning sound already played, skipping")
            #endif
            completion?()
            return
        }
        
        guard let tuningURL = Bundle.main.url(forResource: "special_tuning_sound", withExtension: "wav") else {
            #if DEBUG
            print("[ViewController] Error: special_tuning_sound.wav not found in bundle")
            #endif
            await TuningSoundCoordinator.shared.notifyNoActivePlayback()
            completion?()
            return
        }
        
        do {
            streamingPlayer.setupAudioSession()
            
            // Strong reference - critical to prevent sound cut-off
            tuningPlayer = try AVAudioPlayer(contentsOf: tuningURL)
            tuningPlayer?.delegate = self
            tuningPlayer?.volume = preferredVolume()
            
            #if DEBUG
            print("[ViewController] Set special tuning sound volume to \(tuningPlayer?.volume ?? -1.0)")
            #endif
            
            tuningPlayer?.numberOfLoops = 0
            tuningPlayer?.prepareToPlay()
            
            // Important: Never trigger playback after tuning sound.
            // Initial playback is handled only via viewDidAppear + SharedPlayerManager.
            // Resurrection is fully blocked by PlayerVisualState.mustSuppressResurrection.
            
            let didPlay = tuningPlayer?.play() ?? false
            isTuningSoundPlaying = didPlay
            hasPlayedSpecialTuningSound = true
            
            #if DEBUG
            print(didPlay ? "[ViewController] Special tuning sound started playing" : "[ViewController] Failed to start special tuning sound")
            #endif
            
            if didPlay, let duration = tuningPlayer?.duration {
                await TuningSoundCoordinator.shared.notifyPlaybackStarted(estimatedDuration: duration)
            } else {
                await TuningSoundCoordinator.shared.notifyNoActivePlayback()
                tuningPlayer = nil
            }
        } catch {
            #if DEBUG
            print("[ViewController] Error loading special tuning sound: \(error.localizedDescription)")
            #endif
            await TuningSoundCoordinator.shared.notifyNoActivePlayback()
            completion?()
            tuningPlayer = nil
        }
    }

    // Retained solely to support the special cold-launch tuning clip (AVAudioPlayerDelegate set on tuningPlayer in playSpecialTuningSound).
    // Regular tuning paths no longer use these (removed regular playTuningSound body + stopTuningSound).
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard player === tuningPlayer else { return }
            #if DEBUG
            print("[ViewController] Tuning sound finished playing, success: \(flag)")
            #endif
            isTuningSoundPlaying = false
            tuningPlayer = nil
            await TuningSoundCoordinator.shared.notifyPlaybackFinished()
        }
    }
    
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard player === tuningPlayer else { return }
            #if DEBUG
            print("[ViewController] Tuning sound decode error: \(error?.localizedDescription ?? "Unknown")")
            #endif
            isTuningSoundPlaying = false
            tuningPlayer = nil
            await TuningSoundCoordinator.shared.notifyPlaybackFinished()
        }
    }
    
    // Regular playTuningSound / stopTuningSound + their state removed (orchestration exclusively in RadioPlayerCoordinator.playTuningSound for switch delight flows).
    // Special tuning sound (cold-launch only, integrates TuningSoundCoordinator gate + AV delegate for finish) remains here because it is called from the host viewDidLoad Task and the AVAudioPlayerDelegate conformance is on ViewController.
    // The two audioPlayer* delegate impls below are retained solely for the special clip path.
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // sleepTimerDisplayTask cancel owned by coordinator deinit + its stopLocal.
    }

    // Entire sleep timer UI glue (configure menu + preset/cancel handlers + finish + stateDidChange + sync + begin/stopLocal display + the 3 *Settle consts + instance vars)
    // removed from VC. Single implementation + observer lives in RadioPlayerCoordinator (wired in wireAndInitialSetup).
    // configure call site in setupControls now forwards to coordinator. Observers and viewWillDisappear cancel for this concern removed.

    // MARK: - Lifecycle (deinit)
    /// Cleans up resources, observers, and audio players to prevent leaks.
    /// - Note: Sets `isDeallocating` to avoid operations during teardown.
    deinit {
        isDeallocating = true
        // Sleep notif observer remove: no longer added by VC; coordinator manages its own.
        
        #if DEBUG
        print("[ViewController] deinit starting")
        #endif
        
        // ONLY this is allowed in deinit (CF + Unmanaged is explicitly permitted)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        unsafe CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
        
        #if DEBUG
        print("[ViewController] deinit completed")
        #endif
    }
    
    // handleLanguageSelection + completeStreamSwitch + updateUserDefaultsLanguage (full orchestration + debounce + prePlay optimistic + tuning + intent reset + background deferral + play sequencing)
    // removed. Single source now in RadioPlayerCoordinator (wired via onSelectionChanged closure set in wireAndInitialSetup; no overwrite here).
    // The languageSelectorView.onSelectionChanged wiring that pointed here has been removed so the coordinator's handler is authoritative.
    
    // private handleWidgetPlayAction / handleWidgetPauseAction bodies removed (logic lives in coordinator equivalents or direct manager calls in checkForPendingWidgetActions).
    // The pause call site below now delegates. Play uses the direct authoritative path (per comments in checkForPending).

    /// Handles widget-initiated stream switching to a specific language without playing tuning sounds.
    public func handleWidgetSwitchToLanguage(_ languageCode: String, actionId: String) {
        // Full implementation (processed guard, debounce, workItem, stop/set/play flow, intent checks) lives in RadioPlayerCoordinator.
        radioPlayerCoordinator?.handleWidgetSwitchToLanguage(languageCode, actionId: actionId)
    }
    
    // MARK: - Widget and URL Scheme Handling
    /// Handles widget and URL scheme actions for playback control and stream switching.
    /// - Note: Relies on `DirectStreamingPlayer.isSwitchingStream` (set to `internal`) to coordinate stream switches and suppress unnecessary "stopped" status updates during transitions. Ensures smooth UI updates for widget and URL scheme interactions.
    public func checkForPendingWidgetActions() {
        guard let pending = SharedPlayerManager.shared.getPendingActionIfFresh(maxAge: 30.0) else {
            return
        }

        let pendingAction = pending.action
        let pendingLanguage = pending.parameter
        let actionId = pending.actionId

        #if DEBUG
        print("[ViewController] Found pending action: \(pendingAction), ID: \(actionId)")
        print("[ViewController] Pending language: \(pendingLanguage ?? "nil")")
        #endif

        // Clear action immediately to prevent re-processing
        SharedPlayerManager.shared.clearPendingAction(actionId: actionId)
        
        switch pendingAction {
        case "switch":
            if let languageCode = pendingLanguage {
                #if DEBUG
                print("[ViewController] Executing widget switch action to language: \(languageCode)")
                #endif
                handleWidgetSwitchToLanguage(languageCode, actionId: actionId)
            } else {
                #if DEBUG
                print("[ViewController] Switch action missing language code - pendingLanguage was nil")
                #endif
            }
        case "play":
            #if DEBUG
            print("[ViewController] Executing widget play action")
            #endif
            
            // === WIDGET PLAY/PAUSE DEBOUNCE GUARD ===
            guard Date().timeIntervalSince(lastWidgetActionTime) > widgetActionDebounceInterval else {
                #if DEBUG
                print("[ViewController] Widget action debounced (too soon after previous tap)")
                #endif
                return
            }
            lastWidgetActionTime = Date()
            // === END OF GUARD ===
            
            // Widget play: clear any user pause lock then play. Do NOT reset to prePlay here
            // (resetToPrePlayForNewStream is only for language stream switches).
            // Hoisted weak-self form (proven pattern elsewhere in this file) — avoids implicit self capture / compiler error.
            // Route widget play through the documented designated entry point.
            // `userRequestedPlay()` properly clears .userPaused, resets guards,
            // configures NowPlaying, and calls play(). This is the required path for
            // external explicit triggers (widgets via pending+Darwin, Control Center,
            // lockscreen, CarPlay, LA, Siri). See the userRequestedPlay AGENT NOTE + Precondition.
            Task { @MainActor [weak self] in
                // If a widget switch was recently scheduled (to select a lang while paused) and a play
                // tap followed immediately, cancel the deferred switch workItem. Its selection effect
                // is now covered by the alignment inside play() + the sync below; letting the workItem
                // run could issue a late stop() on the stream we just started.
                self?.pendingWidgetSwitchWorkItem?.cancel()
                self?.pendingWidgetSwitchWorkItem = nil

                await SharedPlayerManager.shared.userRequestedPlay()

                // After play (which now defensively aligns the model to the persisted language from
                // any preceding widget switch signal), sync the in-app language selector + needle
                // so the main UI reflects the language that is actually playing. This prevents the
                // "en selected in widget/needle, but fi audible" desync observed in the 2026-06-12
                // re-capture of initial-streamplay-start.txt.
                guard let self else { return }
                let playingLang = DirectStreamingPlayer.shared.selectedStream.languageCode
                if let targetIndex = DirectStreamingPlayer.availableStreams.firstIndex(where: { $0.languageCode == playingLang }) {
                    if self.selectedStreamIndex != targetIndex {
                        self.selectedStreamIndex = targetIndex
                        radioPlayerCoordinator?.selectedStreamIndex = targetIndex
                    }
                    self.languageSelectorView.setSelectedIndex(targetIndex, caller: "widgetPlay-synced")
                }
            }
        case "pause":
            #if DEBUG
            print("[ViewController] Executing widget pause action")
            #endif
            
            // === WIDGET PLAY/PAUSE DEBOUNCE GUARD ===
            guard Date().timeIntervalSince(lastWidgetActionTime) > widgetActionDebounceInterval else {
                #if DEBUG
                print("[ViewController] Widget action debounced (too soon after previous tap)")
                #endif
                return
            }
            lastWidgetActionTime = Date()
            // === END OF GUARD ===
            
            // Rapid-pause guard (must hop because checkForPendingWidgetActions is synchronous).
            // If we are already .userPaused, ignore the tap to avoid queuing a second Darwin roundtrip
            // that could race with recovery timers or a stale "play" pendingAction.
            // Hoisted weak-self + guard form (await-safe, matches every other Task site in this file).
            Task { @MainActor [weak self] in
                guard let self else { return }
                let vs = await SharedPlayerManager.shared.currentVisualState
                if vs == .userPaused {
                    #if DEBUG
                    print("[ViewController] Widget pause ignored — already .userPaused (prevents double-pause resurrection races)")
                    #endif
                    return
                }
                // Delegate to coordinator (single orchestration for widget pause glue).
                radioPlayerCoordinator?.handleWidgetPauseAction()
            }
        default:
            #if DEBUG
            print("[ViewController] Unknown pending action: \(pendingAction)")
            #endif
        }
        
        // Clean up old processed action IDs (keep only last 10)
        if processedActionIds.count > 10 {
            let sortedIds = Array(processedActionIds).suffix(10)
            processedActionIds = Set(sortedIds)
        }
    }
    
}

// MARK: - Public Methods for URL Scheme Handling
extension ViewController {

    /// Public method to start playback (callable from SceneDelegate for lutheranradio://play,
    /// and used by some legacy widget URL and switch-to-lang flows).
    ///
    /// Delegates to coordinator shim which now forwards to the designated
    /// `SharedPlayerManager.userRequestedPlay()` (authoritative explicit-play entry).
    ///
    /// - SeeAlso: RadioPlayerCoordinator.handlePlayAction,
    ///   ``SharedPlayerManager/userRequestedPlay()``,
    ///   CODING_AGENT.md.
    public func handlePlayAction() {
        // Thin delegate (coordinator shim owns the forward to userRequestedPlay).
        radioPlayerCoordinator?.handlePlayAction()
    }

    /// Public method to pause playback (callable from SceneDelegate)
    ///
    /// Routes through SharedPlayerManager.stop() (the authoritative
    /// path that immediately sets .userPaused + persists + refreshes widgets).
    public func handlePauseAction() {
        // Thin delegate.
        radioPlayerCoordinator?.handlePauseAction()
    }

    /// Public method to switch to a specific language stream (callable from SceneDelegate).
    /// - Parameter languageCode: The ISO language code to switch to (e.g., "en", "de", "fi", "sv", "et").
    public func handleSwitchToLanguage(_ languageCode: String) {
        // Full external switch orchestration (stop + tuning + setStream + userDefaults + reset + play sequencing + UI) lives in RadioPlayerCoordinator.
        radioPlayerCoordinator?.handleSwitchToLanguage(languageCode)
    }

    /// Public method to toggle play/pause state
    /// (callable from SceneDelegate, remote commands, Control Center, etc.)
    ///
    /// Now delegates to the internal SSOT (`handleUserTogglePlayback`)
    /// so that all toggle entry points (button, widget URL schemes, SceneDelegate, remote)
    /// flow through the single authoritative intent decision path.
    public func handleTogglePlayback() {
        // Thin delegate (both the coordinator shim and the internal handleUserTogglePlayback forward are covered by this).
        radioPlayerCoordinator?.handleTogglePlayback()
    }

    /// Public method called when the user taps the Live Activity (Lock Screen or Dynamic Island)
    /// or uses other "open" deep links from widgets.
    ///
    /// Simply foregrounds the app and runs the coordinator's resurrection / state sync check.
    /// Respects all sticky .userPaused / .securityLocked rules exactly like viewDidAppear.
    /// No new playback intent is created here — this is pure navigation / surface activation.
    public func handleOpenFromLiveActivity() {
        Task { @MainActor in
            await radioPlayerCoordinator?.viewDidAppearResurrectionCheck()
        }
    }
}

extension ViewController {
    func updateStatusLabel(text: String, backgroundColor: UIColor, textColor: UIColor) {
        // Forward to composed controls view (playback status)
        playbackControlsView.setStatus(text: text, backgroundColor: backgroundColor, textColor: textColor)
        
        // Announce status changes to VoiceOver only for play/pause states (kept in owner per original)
        if text == String(localized: "status_playing", table: "Localizable") || text == String(localized: "status_paused", table: "Localizable") {
            unsafe UIAccessibility.post(notification: .announcement, argument: text)
        }
    }
    
    // MARK: - Accessibility and Haptic Helpers
    // startHapticEngine removed (no local engine; coordinator owns haptics).
    
    // MARK: - Toggle Playback
    /// Primary @objc entry point for user-initiated play/pause (button tap + remote commands).
    ///
    /// Performs instant visual press feedback, rate-limits rapid taps, then delegates to
    /// `handleUserTogglePlayback()` (the internal SSOT). This keeps all playback decisions
    /// in one place while still giving immediate tactile response to the user.
    ///
    /// - SeeAlso: `handleUserTogglePlayback()`, `handleTogglePlayback()` (public wrapper for SceneDelegate)
    @objc private func togglePlayback() {
        // Instant visual press feedback (button lives in playbackControlsView)
        let targetButton = playbackControlsView.playPauseButton
        UIView.animate(withDuration: 0.1, animations: {
            targetButton.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        }) { _ in
            UIView.animate(withDuration: 0.1) {
                targetButton.transform = .identity
            }
        }
        
        // Prevent multiple rapid taps
        targetButton.isUserInteractionEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.playbackControlsView.playPauseButton.isUserInteractionEnabled = true
        }
        
        Task { @MainActor in
            await self.handleUserTogglePlayback()
        }
    }
    
    // playHapticFeedback (and the companion startHapticEngine) removed from VC.
    // All call sites updated to radioPlayerCoordinator?.playHapticFeedback(...) or removed with the deleted bodies.
    // Single implementation + engine live in RadioPlayerCoordinator.
    
    @objc private func increaseVolume() {
        let newValue = min(volumeSlider.value + 0.1, volumeSlider.maximumValue)
        volumeSlider.setValue(newValue, animated: true)
        volumeChanged(volumeSlider)
        unsafe UIAccessibility.post(notification: .announcement, argument: String(format: String(localized: "volume_set_to", defaultValue: "Volume set to %d percent", table: "Localizable", comment: ""), Int(newValue * 100)))
    }
    
    @objc private func decreaseVolume() {
        let newValue = max(volumeSlider.value - 0.1, volumeSlider.minimumValue)
        volumeSlider.setValue(newValue, animated: true)
        volumeChanged(volumeSlider)
        unsafe UIAccessibility.post(notification: .announcement, argument: String(format: String(localized: "volume_set_to", defaultValue: "Volume set to %d percent", table: "Localizable", comment: ""), Int(newValue * 100)))
    }
    
    private func safeUpdateStatusLabel(text: String, backgroundColor: UIColor, textColor: UIColor, isPermanentError: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Use the setter (it contains the redundant-text skip)
            self.playbackControlsView.setStatus(text: text, backgroundColor: backgroundColor, textColor: textColor)
            
            // Permanent error state is now driven by SecurityModelValidator.isPermanentlyInvalid + intent.
            
            if text != String(localized: "status_playing", table: "Localizable") {
                self.saveStateForWidget()
            }
            
            // Announce ALL important status changes
            let importantStatuses: Set<String> = [
                String(localized: "status_connecting", table: "Localizable"),
                String(localized: "status_playing", table: "Localizable"),
                String(localized: "status_paused", table: "Localizable"),
                String(localized: "status_paused_call", table: "Localizable"),
                String(localized: "status_no_internet", table: "Localizable"),
                String(localized: "status_stream_unavailable", table: "Localizable"),
                String(localized: "status_failed", table: "Localizable"),
                String(localized: "status_security_failed", table: "Localizable"),
                String(localized: "status_stopped", table: "Localizable"),
                String(localized: "status_ssl_transition", table: "Localizable")
            ]
            
            if importantStatuses.contains(text) {
                unsafe UIAccessibility.post(notification: .announcement, argument: text)
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
        Task { @MainActor [weak self] in
            // Forward heavy work to coordinator (distribution, haptics, background flush, corrections).
            await self?.radioPlayerCoordinator?.handleStatusChange(status, reasonKey: reasonKey)
            // Old body removed in the minimal diff (forward to coordinator is the active path; behavior preserved).
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
                    // Legacy widget-URL "play" path. Uses set + toggle (which does set+play in else).
                    // Primary widget play path is now the pending "play" case above which goes
                    // straight to `userRequestedPlay()` (the designation). This path still sets
                    // an active playback intent via `setUserIntentToPlay()`.
                    #if DEBUG
                    print("[ViewController] ▶ Widget 'play' (legacy URL) → handleUserTogglePlayback")
                    #endif
                    await manager.setUserIntentToPlay()
                    await handleUserTogglePlayback()
                } else {
                    #if DEBUG
                    print("[ViewController] Widget 'play' blocked — currentVisualState is .userPaused")
                    #endif
                }
                
            case "pause":
                if state.isPlaying {
                    #if DEBUG
                    print("[ViewController] ⏸ Widget 'pause' action → calling handleUserTogglePlayback (SSOT)")
                    #endif
                    await handleUserTogglePlayback()
                }
                
            case "switch":
                if let languageCode = parameter {
                    #if DEBUG
                    print("[ViewController] Widget switch action reached legacy handleWidgetAction path — delegating to canonical coordinator handler (primary routes use handleWidgetSwitchToLanguage + switchToStreamFromWidget)")
                    #endif
                    // Primary call sites (SceneDelegate widget-action + checkForPendingWidgetActions)
                    // already special-case "switch" and call handleWidgetSwitchToLanguage directly.
                    // This case is legacy/unreachable in current routing. Delegation ensures that
                    // even if hit, we do not duplicate manual engine sequences or UI logic.
                    // The processedActionIds guard inserted at top of this method will cause the
                    // inner handler to early-return; the trailing clearPending + save below still run.
                    // Any real switch work will have been driven by the canonical path.
                    handleWidgetSwitchToLanguage(languageCode, actionId: actionId)
                }
                
            default:
                #if DEBUG
                print("Unknown widget action: \(action)")
                #endif
            }
            
            saveStateForWidget()
            
            #if DEBUG
            print("[ViewController] Widget action '\(action)' completed → saveStateForWidget")
            #endif
            
            // Clear the pending action (actor-isolated)
            SharedPlayerManager.shared.clearPendingAction(actionId: actionId)
        }
    }
}
