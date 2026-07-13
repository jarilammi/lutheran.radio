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
/// - **Background Handling**: Delegates background/foreground/terminate to `SceneDelegate` + `AppDelegate`,
///   which now forward to `RadioLiveActivityManager` (LA) and `SharedPlayerManager` (widgets + liveness).
///   The actual LA drive lives in SPM save paths + the coordinator.
/// - **Widget/URL Handling**: Public methods like `handlePlayAction()` process schemes from `SceneDelegate.swift`.
///
/// Accessibility: VoiceOver announcements for status/metadata; hyphenation for long text. For lifecycle events, see `SceneDelegate.swift` and `AppDelegate.swift`.
import UIKit
import SwiftUI
@unsafe @preconcurrency import AVFoundation
import AVKit
import Network
import CoreImage
import CoreHaptics
import WidgetKit
import Core

/// The main view controller for the Lutheran Radio app.
///
/// Thin host + lifecycle owner during the SwiftUI migration.
///
/// Responsibilities that remain here:
/// - Hosting the background image layer (`BackgroundImageController`)
/// - Owning the single `UIHostingController` that presents `RadioPlayerView`
/// - Retaining a few hard-to-move observers (network, interruptions, route, Darwin widget actions)
/// - Public entry points for SceneDelegate, widgets, Siri, and URL schemes (thin shims to coordinator / SPM)
///
/// The primary player UI has been extracted into pure SwiftUI:
/// `RadioPlayerView` (composition root) + `NowPlayingMetadataView` + `LanguageSelectorView` +
/// `PlaybackControlsView` + `VolumeAndAirPlayRow`. All visual state is driven by `PlayerViewModel`,
/// with orchestration remaining in `RadioPlayerCoordinator`.
///
/// All playback user intents ultimately route through `userRequestedPlay()` or
/// `handleUserTogglePlayback()` (see SSOT comments).
///
/// - Note: iOS 26.2+ only. See `RadioPlayerView` and the coordinator for the modern layout.
/// - SeeAlso: `RadioPlayerView`, `PlayerViewModel`, `RadioPlayerCoordinator`,
///   `DirectStreamingPlayer`, `SharedPlayerManager`, CODING_AGENT.md, <doc:Architecture>.
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

    /// Background image + Core Image processing (owned here for layout + energy efficiency hooks).
    /// The actual visual presentation of the player now lives in the hosted `RadioPlayerView`.
    let backgroundImageController = BackgroundImageController()

    /// @Observable model for SwiftUI composed views (LanguageSelector, Controls, Metadata).
    /// Coordinator pushes visualState / selectedStreamIndex / currentMetadata into it.
    var playerViewModel: PlayerViewModel!

    /// Single UIHostingController for the entire player screen.
    ///
    /// Replaces the previous three separate hosting controllers + manual layout of
    /// UIKit title/volume/airplay pieces. The composed `RadioPlayerView` owns the
    /// vertical arrangement of the three modern SwiftUI subviews plus volume row.
    private lazy var playerHostingController = UIHostingController(
        rootView: RadioPlayerView(
            viewModel: PlayerViewModel.makeMock(),
            onSleepTimerTapped: { [weak self] in
                // Compatibility path only (see real wiring below).
                self?.radioPlayerCoordinator?.configureSleepTimerButtonMenu()
            },
            onClearLocalStateTapped: { [weak self] in
                // Privacy path: forwards to coordinator which performs double-confirmation
                // (UIAlert) + SharedPlayerManager.clearAllLocalState(). Restores the lost UIMenu action.
                self?.radioPlayerCoordinator?.confirmAndClearLocalState()
            }
        )
    )

    /// Lightweight RadioPlayerCoordinator (wiring + full stream selection flow + visual distribution + sleep glue + haptics + initial sequencing).
    var radioPlayerCoordinator: RadioPlayerCoordinator!

    // playerViewModel declared above as the driver for the modern SwiftUI composed views.

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

    // UIResponder menu building override (defense-in-depth for storyboard removal).
    //
    // See AppDelegate.buildMenu(with:) for the full rationale. The menu / key command
    // system walks the responder chain (window → rootViewController). By implementing
    // here we ensure no part of the chain causes UIKit to fall back to loading "Main".
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
    }

    // MARK: - Lifecycle Methods
    /// Initializes the view hierarchy and initial stream selection.
    ///
    /// Cold-launch playback decision lives in the trailing async Task. When the process
    /// was launched with "-UITestMode" (see XCUITest targets), the Task short-circuits
    /// immediately after a clean .prePlay UI update: no tuning sound, no identifying
    /// PersistedWidgetState writes, and no call to `SharedPlayerManager.play()`.
    /// This guarantees the streaming system (and security validation) stay idle until
    /// an explicit test interaction.
    ///
    /// - SeeAlso: ``SharedPlayerManager/isRunningInUITestMode``, ``SharedPlayerManager/play()``,
    ///   CODING_AGENT.md (UI test isolation requirements + launch arguments).
    /// - Note: Performs heavy setup; defers non-critical tasks with asyncAfter for better launch performance.
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        // Processed image cache limit is now configured inside BackgroundImageController.
        
        // Accessibility custom actions for play/pause now handled inside SwiftUI PlaybackControlsView.
        
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
        
        // Playback audio session is configured in DirectStreamingPlayer.init (single owner).
        
        // Haptic engine init + start is owned by RadioPlayerCoordinator.wireAndInitialSetup() (single owner of haptics).
        // Local hapticEngine lazy + startHapticEngine/playHapticFeedback bodies deleted (calls forwarded).
        
        setupDarwinNotificationListener()
        setupUI()
        
        // Create + wire coordinator after hierarchy is built.
        radioPlayerCoordinator = RadioPlayerCoordinator(
            backgroundImageController: backgroundImageController,
            streamingPlayer: streamingPlayer
        )
        // Create the observable VM and attach it so the coordinator can drive SwiftUI state.
        // Action closures are wired inside wireAndInitialSetup.
        playerViewModel = PlayerViewModel()
        radioPlayerCoordinator.viewModel = playerViewModel

        // Replace the hosted root view with the real (non-mock) composed RadioPlayerView.
        // This is the single source of the player UI surface going forward.
        playerHostingController.rootView = RadioPlayerView(
            viewModel: playerViewModel,
            onSleepTimerTapped: { [weak self] in
                // Compatibility path: still exercises configureSleepTimerButtonMenu (retained).
                // Primary sleep timer UI is now the .confirmationDialog inside PlaybackControlsView;
                // choices are delivered to coordinator via PlayerViewModel action closures.
                self?.radioPlayerCoordinator?.configureSleepTimerButtonMenu()
            },
            onClearLocalStateTapped: { [weak self] in
                // Compatibility + primary path for the restored privacy action.
                // Taps in the SwiftUI dialog land here and trigger the coordinator flow
                // (secondary UIAlert confirmation then clearAllLocalState + UI reset).
                self?.radioPlayerCoordinator?.confirmAndClearLocalState()
            }
        )

        radioPlayerCoordinator.viewController = self
        // Always defer the actual present(...) for coordinator-driven UIAlertControllers.
        // This protects against "Unable to simultaneously satisfy constraints" (320pt autoresizing
        // mask vs. internal ~366pt alert content width from _UIAlertControllerPhoneTVMacView)
        // when an alert is triggered synchronously from a SwiftUI .confirmationDialog action
        // (e.g. "Clear local state") while widget refreshes, background image updates, or other
        // layout work is in progress on the main thread. The extra runloop tick lets the
        // outgoing presentation container finish tearing down its constraints.
        radioPlayerCoordinator.presentAlert = { [weak self] alert in
            DispatchQueue.main.async { [weak self] in
                self?.present(alert, animated: true)
            }
        }
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

        // Seed the SwiftUI VM's index so that any early SwiftUI rendering sees the correct initial selection
        // (coordinator will keep it in sync on subsequent updateUI calls).
        playerViewModel?.selectedStreamIndex = initialIndex
        
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
        if !SharedPlayerManager.isRunningInUITestMode {
            setupNetworkMonitoring()
        }
        setupInterruptionHandling()
        setupRouteChangeHandling()
        setupStreamingCallbacks()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        
        setupFastWidgetActionChecking()
        isInitialSetupComplete = true

        // Sleep timer notification observer + initial sync + preset/cancel + clear-local-state handling owned exclusively by RadioPlayerCoordinator.
        // (added in wireAndInitialSetup). SwiftUI dialog (presets/Cancel/clear) calls back via PlayerViewModel or onClearLocalStateTapped; legacy onSleepTimerTapped still calls configure.
        // VC no longer observes or syncs the sleep UI glue.
        
        // Energy Efficiency Optimizations (iOS 26) — now owned by BackgroundImageController.
        // The controller self-registers for power state notifications and reacts using its last stream.
        backgroundImageController.updateForEnergyEfficiency()
        
        // === Asynchronous initialization (required for Swift 6 concurrency) ===
        Task { @MainActor [weak self] in
            guard let self else { return }

            // === UI Test Isolation (explicit -UITestMode launch argument) ===
            // When launched by XCUITest, never auto-trigger real audio streaming, tuning sound,
            // identifying persistence writes, or production security/network paths.
            // The player must remain in clean non-playing (.prePlay) state until a test
            // explicitly interacts (e.g. taps play). This prevents the 5-minute hang and
            // makes `test-without-building` fast + deterministic.
            //
            // Detection uses the single source of truth `SharedPlayerManager.isRunningInUITestMode`
            // (prefers explicit "-UITestMode" launch argument; XCTest indicators only as DEBUG fallback).
            //
            // - Security: DNS TXT / cert pinning paths are not exercised on launch (and are
            //   short-circuited before validate even on explicit taps in UITestMode).
            // - SeeAlso: ``SharedPlayerManager/isRunningInUITestMode``, ``SharedPlayerManager/play()``,
            //   DirectStreamingPlayer.isTesting, Lutheran_RadioUITests.swift (argument injection),
            //   CODING_AGENT.md (UI test isolation).
            if SharedPlayerManager.isRunningInUITestMode {
                #if DEBUG
                print("[ViewController] UITestMode (-UITestMode) — skipping cold-launch auto-play, tuning, snapshot seed, and all production streaming paths. Visual remains clean .prePlay.")
                #endif
                self.updateUI(for: .prePlay)
                return
            }

            // Memory-only policy: purge any stale on-disk visual keys and reset to factory .prePlay
            // before resurrection guards or tuning. Auto-play on first launch remains intact.
            await SharedPlayerManager.shared.resetToFactoryDefaultsOnLaunch()
            
            let initialStream = SharedPlayerManager.streamForLanguageCode(languageCode)
            
            // In-memory UI + model setup only (selector needle, player selectedStream).
            // These are required for the app to be usable on launch and do not re-create
            // "recently deleted" persisted data (snapshot, lastUpdateTime, language liveness signals).
            self.updateUI(for: .prePlay)  // not the post-clear path (that now uses .cleared)
            
            // Stream model and UI only; secured AVPlayerItem is created once in setStreamAndPlay after tuning.
            await self.streamingPlayer.setSelectedStreamModelOnly(to: initialStream)
            
            // Background deferral state is now owned by BackgroundImageController (cold launch path preserved).
            // Actual image processing is deferred until playback is stable; choosing the initial lang
            // for prep is acceptable (not an "I listened" signal).
            backgroundImageController.scheduleDeferredForStreamSwitch(initialStream)
            
            // ─────────────────────────────────────────────────────────────────────────
            // Resurrection / wake guard — MUST run before any tuning sound or play().
            //
            // Loads in-session visual + intent (memory-only; cold launch is always .prePlay).
            //
            // The combination `intent.isStickyPauseOrLock || hasExplicitTerminationSentinel()`
            // is the hard blocker required by policy:
            // - Prior .userPaused / .cleared / .securityLocked must never auto-start.
            // - Explicit termination (lastUpdateTime == 0) means the prior session is over;
            //   device power-up / wake (even with visible Lock Screen Live Activity) must
            //   produce zero side-effects into DirectStreamingPlayer.
            //
            // Only explicit user actions (button, widget pending "play", LA controls,
            // Siri, etc.) go through `userRequestedPlay` → flag + `setUserIntentToPlay`
            // and are allowed to proceed.
            //
            // Tuning sound is deliberately *after* this gate so that a sticky or
            // post-termination launch never emits the "radio tuning / connection sound".
            //
            // - Precondition: UITest short-circuit already returned above.
            // - Postcondition (blocked path): UI reflects loaded snapshot visual; no
            //   tuning, no persist seed, no player.play(), no network.
            // - SeeAlso: SharedPlayerManager.hasExplicitTerminationSentinel,
            //   SharedPlayerManager.play (the parallel early return), restore*,
            //   CODING_AGENT.md (SSOT resurrection, currentPlaybackIntent + liveness),
            //   RadioPlayerCoordinator.performColdLaunchPlaybackIfAllowed.
            // ─────────────────────────────────────────────────────────────────────────
            await SharedPlayerManager.shared.refreshVisualStateFromPersistence()
            let visualState = await SharedPlayerManager.shared.currentVisualState
            let intent = await SharedPlayerManager.shared.currentPlaybackIntent
            let postTerm = SharedPlayerManager.hasExplicitTerminationSentinel()
            
            if intent.isStickyPauseOrLock || postTerm {
                #if DEBUG
                print("[ViewController] Blocked cold-launch tuning + playback — \(postTerm ? "post-termination sentinel (0)" : "sticky playbackIntent") (respects user pause / term + visible LA on wake)")
                #endif
                // Show the correct persisted visual (e.g. grey paused, or last-known)
                // rather than forcing .prePlay. LA/widget already use the snapshot.
                self.updateUI(for: visualState)
                return
            }
            
            #if DEBUG
            print("[ViewController] Cold launch proceeding to tuning (no sticky, no termination sentinel)")
            #endif
            
            // Early UI to .prePlay for needle/selector positioning (matches prior behavior for allowed cold launches).
            self.updateUI(for: .prePlay)
            
            await self.playSpecialTuningSound()
            
            // Re-fetch after tuning: persistence refresh and thermal sanitization may have
            // updated in-memory state while the tuning clip played.
            let visualStateAfterTuning = await SharedPlayerManager.shared.currentVisualState
            let intentAfterTuning = await SharedPlayerManager.shared.currentPlaybackIntent
            
            #if DEBUG
            print("[ViewController] After tuning — visualState = \(visualStateAfterTuning), intent = \(intentAfterTuning)")
            #endif
            
            // Post-clear (or normal first) cold launch first play.
            // The early sentinel+sticky guard above already returned for .userPaused/.cleared-intent/
            // security/terminated cases (see resurrection policy). Reaching here means we are
            // in the permitted .prePlay / .cleared visual path for a clean launch.
            //
            // Identifying writes (snapshot seed + lastUpdateTime bump) happen only on this
            // success path so that clearAllLocalState + post-clear launches do not re-create
            // deleted data until the first explicit or allowed cold play.
            guard visualStateAfterTuning == .prePlay || visualStateAfterTuning == .cleared || visualStateAfterTuning.shouldAutoPlayOrResume || intentAfterTuning == .cleared else {
                #if DEBUG
                print("[ViewController] Blocked initial playback — state = \(visualStateAfterTuning)")
                #endif
                return
            }
            
            if intentAfterTuning == .cleared {
                #if DEBUG
                print("[ViewController] post-clear cold launch — allowing initial playback and state creation")
                #endif
            }
            
            guard self.hasInternetConnection else { return }
            
            // In-session widget refresh only (no on-disk visual persistence). Re-query widget
            // presence so saveCurrentState / performActualSave can update the in-memory session
            // snapshot after play() attaches.
            if !SharedPlayerManager.hasActiveWidgets {
                await WidgetRefreshManager.shared.refreshHasActiveWidgets()
            }

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
        // SwiftUI LanguageSelectorView uses matchedGeometryEffect; no manual notify needed.
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
                
            case .cleared:
                #if DEBUG
                print("[ViewController] viewDidAppear → .cleared (post privacy clear in this session) → SKIPPING (explicit play required)")
                #endif
                
            case .playing:
                #if DEBUG
                print("[ViewController] viewDidAppear → already playing, no action needed")
                #endif
                
            case .userPaused, .thermalPaused, .securityLocked:
                #if DEBUG
                print("[ViewController] viewDidAppear → \(visualState) → SKIPPING auto-play (resurrection prevented)")
                #endif
            }

            // Sleep timer display sync (and now dialog-driven set/cancel) performed via coordinator + VM.
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
        // Widget-action delivery does not use a repeating foreground poll timer (Tier 3).
        // Primary path: Darwin notify → checkForPendingWidgetActions. Defense-in-depth:
        // this 1…5 s burst after launch, SceneDelegate sceneDidBecomeActive /
        // sceneWillEnterForeground, and AppDelegate foreground hooks.
        //
        // UITestMode: skip entirely. The checker would only risk picking up stale pendings
        // from prior killed sessions and turning them into "user input". The guard inside
        // checkForPendingWidgetActions is defense-in-depth; skipping the schedule avoids
        // the "Fast widget action checking completed" timing marker during unit tests
        // and reduces scheduler noise in the test host.
        if SharedPlayerManager.isRunningInUITestMode {
            #if DEBUG
            print("[ViewController] UITestMode — skipping fast widget action checking schedule")
            #endif
            return
        }

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
            
            // Hop to main for UI updates only.
            // SwiftUI NowPlayingMetadataView handles its own text + photo using VM.currentMetadata.
            DispatchQueue.main.async { [self] in
                if let metadata = metadata {
                    radioPlayerCoordinator?.syncMetadataToViewModel(metadata)
                    if self.isSleepTimerInteractionActive {
                        self.pendingMetadataVisualRefresh = metadata
                        radioPlayerCoordinator?.pendingMetadataVisualRefresh = metadata
                    } else {
                        self.updateNowPlayingInfo(title: metadata)
                    }
                } else {
                    radioPlayerCoordinator?.syncMetadataToViewModel(nil)
                    if !self.isSleepTimerInteractionActive {
                        self.updateNowPlayingInfo()
                    }
                }
                self.saveStateForWidget()
            }
        }
    }
    
    // showSecurityModelAlert + showSSLTransitionAlert removed (their creation + presentation logic lives inside RadioPlayerCoordinator.updateUI/handleStatusChange using the injected presentAlert hook).
    // No call sites remain in VC.
    
    private func setupControls() {
        // SwiftUI PlaybackControlsView owns its own Buttons and taps (wired to viewModel).
        // Sleep timer *presentation* is now native .confirmationDialog in PlaybackControlsView (includes Clear local state privacy action).
        // The call to configureSleepTimerButtonMenu is retained for compatibility + internal glue
        // (the method is never removed during the incremental migration). All timer + clear logic lives in coordinator.
        // Accessibility and identifiers are now inside the SwiftUI views.
        radioPlayerCoordinator?.configureSleepTimerButtonMenu()  // compatibility / re-sync path; presentation is SwiftUI-native
        
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
        if SharedPlayerManager.isRunningInUITestMode {
            #if DEBUG
            print("[ViewController] UITestMode — skipping network monitoring setup (prevents any connecting/reconnect logic or timers in test host)")
            #endif
            return
        }
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
            
            // Consolidated via `reconfigureAudioSession()` → player's async helper.
            Task { @MainActor in
                await self.reconfigureAudioSession()
            }
            
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

    /// Consolidated entry point for audio session (re)activation from ViewController surfaces.
    ///
    /// All activation calls originating in ViewController (interruption recovery, route change,
    /// category change, and tuning sound setup) route through this method so that
    /// activation logic stays in one place and always uses the async helper
    /// (`configureAudioSessionAsync` is the player SSOT).
    ///
    /// The underlying implementation guarantees that `setActive` is never invoked directly
    /// on the main thread (iOS 27+ uses framework async; 26.x uses off-main dispatch).
    ///
    /// Playback entry points inside the player call `configureAudioSessionAsync()` (or the
    /// thin `setupAudioSession()` wrapper) directly.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/configureAudioSessionAsync()``,
    ///   ``DirectStreamingPlayer/deactivateAudioSessionAsync()``,
    ///   ``DirectStreamingPlayer/setupAudioSession()``, `handleInterruption(_:)`,
    ///   `handleRouteChange(_:)`, `playSpecialTuningSound(completion:)`.
    @MainActor
    private func reconfigureAudioSession() async {
        _ = await streamingPlayer.configureAudioSessionAsync()
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
            // Consolidated via `reconfigureAudioSession()` → player's async helper.
            // Await config before recovery play (preferred over fire-and-forget).
            Task { @MainActor in
                await self.reconfigureAudioSession()
                // Route-change recovery: only proceed if intent permits (defensive; SPM.play
                // would also block). This is a technical recovery path, not explicit user play.
                // (See userRequestedPlay Precondition for permitted direct play() cases.)
                if await SharedPlayerManager.shared.canProceedWithPlayback() {
                    await SharedPlayerManager.shared.play()
                }
            }
        case .categoryChange:
            // Consolidated via `reconfigureAudioSession()`.
            Task { @MainActor in
                await self.reconfigureAudioSession()
            }
        default:
            break
        }
    }
    
    private func setupConnectivityCheckTimer() {
        if SharedPlayerManager.isRunningInUITestMode {
            #if DEBUG
            print("[ViewController] UITestMode — skipping connectivity check timer")
            #endif
            return
        }
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
        if SharedPlayerManager.isRunningInUITestMode {
            return
        }
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
        if SharedPlayerManager.isRunningInUITestMode {
            return
        }
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
        view.backgroundColor = .systemBackground

        // Single SwiftUI player view (composes NowPlayingMetadataView + LanguageSelectorView
        // + PlaybackControlsView + VolumeAndAirPlayRow). This replaces the previous three
        // separate UIHostingControllers + manual interleaving of UIKit chrome.
        //
        // IMPORTANT LAYERING ORDER (background visibility fix):
        // 1. Add the playerHostingController (and its view) FIRST. At this moment it becomes
        //    the only (or top) subview and owns the safe-area content area.
        // 2. Explicitly clear its background so the decorative layer can show through.
        // 3. THEN insert the backgroundImageView at index 0. This places the full-bleed
        //    background BEHIND the hosting view in the subview list. zPosition = -1 is
        //    retained as a CALayer stacking belt-and-suspenders.
        // Why insert *after* adding the host but *at 0*? Adding host first gives it a stable
        // position in the hierarchy; insert(at:0) reliably pushes it above the background
        // without relying on later addSubview order or zPosition alone. RadioPlayerView
        // already uses Color.clear; the hosting view's opaque default was the obscurer.
        addChild(playerHostingController)
        view.addSubview(playerHostingController.view)
        playerHostingController.view.backgroundColor = .clear
        playerHostingController.view.translatesAutoresizingMaskIntoConstraints = false
        playerHostingController.didMove(toParent: self)

        NSLayoutConstraint.activate([
            playerHostingController.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            playerHostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerHostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerHostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Background image layer (full-bleed with parallax insets). Remains UIKit-owned
        // for the duration of the incremental SwiftUI migration (energy efficiency, CI pipeline,
        // deferral, etc. live in BackgroundImageController).
        //
        // Inserted at 0 (bottom) after the hosting controller so the SwiftUI content
        // renders in front. Constraints use view anchors (not safeArea) for true full-bleed.
        // updateForEnergyEfficiency(), scheduleDeferredForStreamSwitch(), and memory warning
        // handling are untouched; this is only the add/insert sequence.
        let bgView = backgroundImageController.backgroundImageView
        view.insertSubview(bgView, at: 0)
        bgView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bgView.topAnchor.constraint(equalTo: view.topAnchor),
            bgView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bgView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bgView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        bgView.layer.zPosition = -1
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
            // Consolidated through reconfigureAudioSession() (uses the SSOT
            // `configureAudioSessionAsync` under the hood). The player ensures
            // activation never triggers main-thread setActive warnings on 26.x.
            await self.reconfigureAudioSession()
            
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

    // Entire sleep timer UI glue (preset/cancel handlers + finish + stateDidChange + sync + begin/stopLocal display + the 3 *Settle consts + instance vars + interaction flags)
    // lives in RadioPlayerCoordinator (wired in wireAndInitialSetup + VM action closures).
    // Presentation is SwiftUI .confirmationDialog (PlaybackControlsView). configureSleepTimerButtonMenu()
    // is retained and still invoked from coordinator glue paths + setupControls for compatibility.
    // All timer business logic untouched.

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
        // UITestMode defense-in-depth.
        // Even if a prior killed test session (or manual run) left a "play"/"pause" pendingAction
        // or Darwin notification in the shared App Group, do not interpret it as user input.
        // This prevents the "background test sessions would be interpreted as user input"
        // scenario that leaves the host in yellow .prePlay "connecting" state and stalls the
        // test runner. We still drain the pending key so the next real run starts clean.
        if SharedPlayerManager.isRunningInUITestMode {
            if let pending = SharedPlayerManager.shared.getPendingActionIfFresh(maxAge: 30.0) {
                SharedPlayerManager.shared.clearPendingAction(actionId: pending.actionId)
                #if DEBUG
                print("[ViewController] UITestMode — cleared stale pending \(pending.action) without executing (avoids killed-session user input interpretation)")
                #endif
            }
            return
        }

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

                // For widget-originated play (initial play via widget is the key case in the log),
                // ensure the privacy gate is refreshed and we force an authoritative snapshot +
                // liveness bump. The widget intent may have written an optimistic snapshot (now
                // allowed via isWidgetProcess bypass), but the main app must also write so that
                // hasError, metadata, and the actually played language are authoritative.
                await WidgetRefreshManager.shared.refreshHasActiveWidgets()
                await SharedPlayerManager.shared.recordWidgetLiveness()
                await SharedPlayerManager.shared.saveCurrentState()

                guard let self else { return }
                let playingLang = DirectStreamingPlayer.shared.selectedStream.languageCode
                if let targetIndex = DirectStreamingPlayer.availableStreams.firstIndex(where: { $0.languageCode == playingLang }) {
                    if self.selectedStreamIndex != targetIndex {
                        self.selectedStreamIndex = targetIndex
                        radioPlayerCoordinator?.selectedStreamIndex = targetIndex
                    }
                    self.playerViewModel?.selectedStreamIndex = targetIndex // SwiftUI observes VM
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
        // Status now rendered inside SwiftUI PlaybackControlsView (driven by VM.visualState)
        // playbackControlsView.setStatus was UIKit path.
        
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
        // SwiftUI PlaybackControlsView provides its own press feedback via Button.
        // Rapid-tap guard is handled inside the VM/coordinator paths if needed.
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
            // Status updated via VM.visualState -> SwiftUI PlaybackControlsView
            // (no direct setStatus on hosted view).
            
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
