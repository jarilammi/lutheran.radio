//
//  ViewController.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.10.2024.
//
//  Thin UIKit host + lifecycle owner (SwiftUI migration). Not the streaming engine and not
//  the visual/intent SSOT. Domain behavior is file-split — see the isolation map on the class.
//
//  Owns: retained system observers and layout install in domain files (interruption / route in
//  `ViewController+AudioSessionObservers` — host work is tuning chrome + intent-gated resume
//  only; engine owns rate pause without sticky user-pause; Darwin widget notify + launch drain
//  burst in `ViewController+DarwinWidgetNotify`; engine path observation + cellular prompt
//  presentation in `ViewController+NetworkPathObservation` — path samples from
//  DirectStreamingPlayer; host does not own NWPathMonitor; ternary prefs in
//  CellularPermissionManager; layout hosting install + layout-pass forward in
//  `ViewController+LayoutHosting` — single UIHostingController + background insert), and
//  public SceneDelegate / URL / Siri shims that forward to RadioPlayerCoordinator or SPM.
//
//  Does not own:
//  - AVPlayer / attach / recovery / interruption rate pause → DirectStreamingPlayer
//  - PlayerVisualState / PlaybackIntent / PlayerEvent / widget snapshots → SharedPlayerManager
//  - Host-local playback bool (never reintroduce `isPlaying` shadow on this type)
//  - Stream switch, pending-action drain, sleep-timer glue, haptics, visual distribution →
//    RadioPlayerCoordinator
//  - Security model / certificates → Core only
//
//  - SeeAlso: RadioPlayerCoordinator, RadioPlayerView, PlayerViewModel, DirectStreamingPlayer,
//    SharedPlayerManager, CellularPermissionManager, CODING_AGENT.md, <doc:Architecture>.
//

/// - Article: Main UI host and interaction flow
///
/// `ViewController` is the **thin host**: it installs the SwiftUI player tree and keeps a small
/// set of lifecycle / system-observer responsibilities that are hard to move off UIKit. Primary
/// chrome lives in `RadioPlayerView` + `PlayerViewModel`; orchestration lives in
/// `RadioPlayerCoordinator`.
///
/// **Not owned here (common historical confusion):**
/// - Secure streaming engine → ``DirectStreamingPlayer``
/// - Visual/intent SSOT, events, App Group session writes → ``SharedPlayerManager``
/// - Playback catalog is the five radio streams (`en`, `de`, `fi`, `sv`, `et`) on
///   ``DirectStreamingPlayer/availableStreams``; UI localization is the 32-language
///   README Localizations table (not a stream count)
///
/// **Still on the host today (domain files where peeled):**
/// - Engine path observation (`ViewController+NetworkPathObservation`) for cellular expensive-path
///   prompt presentation and SPM reconnect/stop chrome — **not** a second `NWPathMonitor` or
///   HTTP probe timer. `CellularPermissionManager` owns ternary prefs.
/// - Audio interruption / route **observers** (`ViewController+AudioSessionObservers` — tuning
///   chrome stop + resume gate via SPM visual intent). Playback pause on interruption/route is
///   **not** host-owned — engine observers in `DirectStreamingPlayer+AudioSessionInterruption`
///   own rate pause without sticky user-pause. There is **no** host-local `isPlaying` shadow.
/// - Darwin widget-notify install + launch-burst scheduling (`ViewController+DarwinWidgetNotify`)
/// - Layout hosting install + layout-pass forward (`ViewController+LayoutHosting` — single
///   `UIHostingController` for `RadioPlayerView` + background layer insert; never eager AirPlay)
/// - Public shims: `handlePlayAction`, URL schemes, SceneDelegate entry points,
///   keyboard/menu adjacent-language (`handleAdjacentLanguageSelection`)
///
/// **Background / terminate:** `SceneDelegate` + `AppDelegate` forward to
/// `RadioLiveActivityManager` and `SharedPlayerManager` (widgets + liveness). Authoritative LA
/// ContentState updates ride SPM save paths and the coordinator — not a parallel host store.
///
/// Volume and AirPlay chrome are SwiftUI-owned (`VolumeAndAirPlayRow` / `AirPlayButton`); do not
/// reintroduce eager `AVRoutePickerView` construction on this type (launch-watchdog history).
///
/// Accessibility and low-power UI tweaks remain host/background-image concerns where still wired.
/// Lifecycle details: `SceneDelegate.swift`, `AppDelegate.swift`.
import UIKit
import SwiftUI
@unsafe @preconcurrency import AVFoundation
import CoreImage
import WidgetKit
import Core
import WidgetSurface

/// Thin UIKit host for the Lutheran Radio main scene (SwiftUI migration).
///
/// Responsibilities that remain here:
/// - Owning stored layout stamps (`BackgroundImageController`, hosting controller) and cold-launch lifecycle
/// - Retaining hard-to-move work in domain extensions:
///   - Interruptions/route → `ViewController+AudioSessionObservers`
///   - Darwin widget notify + launch drain burst → `ViewController+DarwinWidgetNotify`
///   - Engine path observation + cellular prompt presentation → `ViewController+NetworkPathObservation`
///     (no host monitor; ternary prefs in `CellularPermissionManager`)
///   - Layout hosting install + layout-pass forward → `ViewController+LayoutHosting`
/// - Public entry points for SceneDelegate, widgets, Siri, and URL schemes (thin shims to coordinator / SPM)
///
/// **Not owned by this type (SSOT / engine boundary):**
/// - AVPlayer attach, recovery, secured media, streaming path retries → ``DirectStreamingPlayer``
/// - In-session "is audio flowing" truth → ``DirectStreamingPlayer/isPlaying`` (rate + ready item);
///   host must not keep a parallel `isPlaying` bool
/// - Sticky visual/intent pause vs resume gates → ``SharedPlayerManager`` / ``PlayerVisualState``
/// - `PlayerVisualState`, `PlaybackIntent`, `PlayerEvent`, widget/LA session snapshots → ``SharedPlayerManager``
/// - Security model / certificate / DNS policy → Core only
///
/// **Orchestration owned by ``RadioPlayerCoordinator`` (not this type):**
/// - Pending-action drain (App Group `pendingAction*` → play/pause/switch)
/// - `selectedStreamIndex` + SwiftUI needle / language selection
/// - Sleep-timer interaction window + deferred metadata apply
/// - ICY `onMetadataChange` → VM / Now Playing
/// - Cold-launch special tuning clip + stream-switch tuning delight (`TuningSoundCoordinator` gate)
/// - Visual distribution, haptics, stream-switch debounce
///
/// Darwin observer install + launch burst live in `ViewController+DarwinWidgetNotify`.
/// This type still exposes a one-line public drain shim so SceneDelegate and tests can
/// call drain without holding a coordinator reference.
///
/// Primary player UI is SwiftUI: `RadioPlayerView` (composition root) +
/// `NowPlayingMetadataView` + `LanguageSelectorView` + `PlaybackControlsView` +
/// `VolumeAndAirPlayRow`. Leaf chrome is driven by `PlayerViewModel`.
///
/// Volume chrome is **not** owned by this host: system volume is SSOT via SwiftUI
/// `VolumeAndAirPlayRow` / `MPVolumeView` (identifier `volumeSlider` for UI tests).
/// AirPlay is **not** owned by this host: route-picker chrome lives exclusively in
/// SwiftUI `AirPlayButton` (deferred `AVRoutePickerView` construction after hierarchy attach).
/// Eager UIKit `AVRoutePickerView` on this type previously ran during scene-create and could
/// hit the launch watchdog under cold load — do not reintroduce it.
///
/// Playback user intents ultimately route through `userRequestedPlay()` or
/// `handleUserTogglePlayback()` into coordinator / SPM / engine — never a host-local
/// parallel playback store as SSOT.
///
/// - Note: iOS 26.2+ only. See `RadioPlayerView` and the coordinator for the modern layout.
/// - SeeAlso: `RadioPlayerView`, `AirPlayButton`, `VolumeAndAirPlayRow`, `PlayerViewModel`,
///   `RadioPlayerCoordinator`, `TuningSoundCoordinator`, `DirectStreamingPlayer`,
///   `SharedPlayerManager`, `CellularPermissionManager`, `PlaybackPlayDecision`,
///   `PlaybackKeyboardMenu`, CODING_AGENT.md, <doc:Architecture>.
@MainActor
class ViewController: UIViewController {

    // MARK: - Isolation map (domain split)
    //
    // ViewController is the @MainActor thin UIKit host. Mutable host flags live on this
    // primary type body; domain behavior lives in extension files where peeled.
    // Engine attach / security / widget snapshot SSOT / orchestration are *not* in this map —
    // see DirectStreamingPlayer, Core, SharedPlayerManager, and RadioPlayerCoordinator.
    //
    // | Domain | File | Responsibility |
    // |--------|------|----------------|
    // | Audio session observers | ViewController+AudioSessionObservers.swift | Interruption + route NotificationCenter install/handlers; ``reconfigureAudioSession`` → engine configure; intent-gated recovery play; tuning chrome stop on began |
    // | Darwin widget notify | ViewController+DarwinWidgetNotify.swift | CF Darwin observer install/teardown; launch 1…5 s drain burst; pause self-echo guard hop |
    // | Engine path observation | ViewController+NetworkPathObservation.swift | ``observeEngineNetworkPath`` / sample handler / cellular alert presentation / ``handleNetworkReconnection`` / path-callback clear; no host monitor |
    // | Layout hosting | ViewController+LayoutHosting.swift | ``setupUI`` hosting controller + background insert; ``viewDidLayoutSubviews`` → coordinator ``notifyLayoutChange``; ``presentCoordinatorAlertAfterOutgoingPresentationSettles`` (confirmationDialog presented chain empty **and** glass popover hosts gone, then layoutIfNeeded, then UIAlert) |
    // | Cold launch / lifecycle | (this file) | viewDidLoad Task (UITestMode, factory hygiene, mark presentable cold launch ready); viewDidAppear resurrection |
    // | Public shims | (this file) | SceneDelegate / URL / Siri / widget-action / keyboard-menu entry → coordinator or SPM |
    // | DEBUG test seams | (this file) | Drain bypass forwarders for WidgetIntentContractTests |
    //
    // Cross-layer owners (do not re-home into this host):
    // - AVPlayer / attach / recovery / rate pause on interruption → DirectStreamingPlayer
    // - Sole free-running NWPathMonitor + hasInternetConnection → DirectStreamingPlayer (+NetworkPath)
    // - PlayerVisualState / PlaybackIntent / PlayerEvent / session snapshots → SharedPlayerManager
    // - Stream switch / drain / sleep / chrome distribution / tuning clips → RadioPlayerCoordinator
    // - Ternary cellular prefs + migration → CellularPermissionManager
    // - DNS TXT / cert digests / ATS SPKI → Core only
    // - Audio session category / setActive → DirectStreamingPlayer+AudioSession
    // - Pending-action drain / mailbox keys → RadioPlayerCoordinator+PendingActions
    // - SwiftUI leaf chrome composition → RadioPlayerView / PlayerViewModel
    // - Background image CI / energy / deferral → BackgroundImageController
    //
    // Stored-state rule: extensions cannot declare stored properties. Domain files mutate
    // internal stamps declared below (`isDeallocating`, `streamingPlayer`,
    // `cellularPermissionManager`, `playerHostingController`, etc.).
    //
    // AGENT NOTE: Optional further peels are cold-launch Task bulk only if the primary host
    // is next touched for size — one cohesive domain per change. Public SceneDelegate/test
    // API must stay stable. Never reintroduce host `isPlaying` or a second NWPathMonitor.
    // Never reintroduce eager UIKit `AVRoutePickerView` on this type.

    // MARK: - Private Properties and Constants
    
    // Orchestration state (selectedStreamIndex, sleep interaction, tuning clips, visual
    // distribution, pending-action drain, metadata callbacks) lives exclusively in
    // RadioPlayerCoordinator. This host keeps only lifecycle, path observation, and thin public shims.
    
    // Cellular permission state + migration + per-launch prompting is fully extracted to CellularPermissionManager
    // (alert presentation lives in ViewController+NetworkPathObservation; path *samples* come from
    // DirectStreamingPlayer's sole NWPathMonitor via onNetworkPathChange — the host never starts a
    // second monitor). `internal` so the path-observation domain can present + mark prompts.
    let cellularPermissionManager = CellularPermissionManager()
    
    /// Dedup set for legacy `lutheranradio://widget-action` URL path only (`handleWidgetAction`).
    /// Pending-action drain and silent switch use the coordinator's set.
    private var processedActionIds: Set<String> = []
    
    // MARK: - UI Elements

    /// Background image + Core Image processing (owned here for layout + energy efficiency hooks).
    /// The actual visual presentation of the player now lives in the hosted `RadioPlayerView`.
    ///
    /// Assigned in both designated initializers (shared local with ``radioPlayerCoordinator``)
    /// so the coordinator can be constructed before `super.init` without reading `self`.
    let backgroundImageController: BackgroundImageController

    /// Observable model for SwiftUI composed views (LanguageSelector, Controls, Metadata).
    ///
    /// Definite value from construction — never an IUO. Coordinator pushes
    /// `visualState` / `selectedStreamIndex` / `currentMetadata` into it during
    /// ``RadioPlayerCoordinator/wireAndInitialSetup()``.
    ///
    /// - SeeAlso: ``PlayerViewModel``, ``RadioPlayerCoordinator``
    let playerViewModel = PlayerViewModel()

    /// Single UIHostingController for the entire player screen.
    ///
    /// Replaces the previous three separate hosting controllers + manual layout of
    /// UIKit title/volume/airplay pieces. The composed `RadioPlayerView` owns the
    /// vertical arrangement of the three modern SwiftUI subviews plus volume row.
    /// Uses the host's real ``playerViewModel`` from first materialization (no mock swap).
    ///
    /// Stored on the primary type body (`internal` for `ViewController+LayoutHosting`
    /// install). Hierarchy install lives in ``setupUI()`` — do not add sibling hosting
    /// controllers or construct AirPlay here.
    ///
    /// - SeeAlso: ``setupUI()``, ViewController+LayoutHosting, ``RadioPlayerView``
    lazy var playerHostingController = UIHostingController(
        rootView: RadioPlayerView(
            viewModel: playerViewModel,
            onClearLocalStateTapped: { [weak self] in
                // Privacy path: coordinator double-confirmation (UIAlert) + clearAllLocalState.
                self?.radioPlayerCoordinator.confirmAndClearLocalState()
            }
        )
    )

    /// Orchestration owner (stream selection, visual distribution, sleep glue, haptics, pending drain).
    ///
    /// Definite non-optional type constructed in every designated initializer. Tests may
    /// replace the instance after `ViewController()` for drain isolation; production
    /// ``viewDidLoad`` only wires cross-references and calls `wireAndInitialSetup()`.
    ///
    /// - Important: Never reintroduce `RadioPlayerCoordinator!` — lifecycle order must not
    ///   trap on an unset IUO. Prefer reassignment of a real instance over optional storage.
    /// - SeeAlso: ``RadioPlayerCoordinator``, CODING_AGENT.md (defensive Swift / force-unwraps)
    var radioPlayerCoordinator: RadioPlayerCoordinator

    // AGENT NOTE: AirPlay is **not** constructed here.
    //
    // Why: A stored `AVRoutePickerView` property initializer ran during
    // `ViewController.init` on the scene-create callout (`SceneDelegate.scene(_:willConnectTo:)`).
    // `AVRoutePickerView` immediately sets up `AVOutputContext`, which pulls CoreMedia /
    // CFPreferences over XPC. Under cold Simulator + post-reboot host load that IPC can
    // exceed the Background scene-create wall-clock budget (0x8BADF00D / FRONTBOARD).
    //
    // Ownership: the sole user-facing AirPlay control is SwiftUI `AirPlayButton` inside
    // `RadioPlayerView` / `VolumeAndAirPlayRow`. That path builds `AVRoutePickerView` only
    // inside `UIViewRepresentable.makeUIView` after the hosting hierarchy is attached —
    // off the scene-create critical path and after `ViewController` construction returns.
    //
    // Never reintroduce an eager (or setupControls-forced) UIKit `AVRoutePickerView` on this
    // type without an explicit deferred construction strategy and cold-launch verification.
    //
    // - SeeAlso: `AirPlayButton`, `VolumeAndAirPlayRow`, `SceneDelegate.scene(_:willConnectTo:)`,
    //   CODING_AGENT.md (launch / MediaRemoteUI watchdog history), <doc:Architecture>
    
    // MARK: - Audio and Streaming
    // Streaming engine is shared; orchestration (status chrome, metadata, tuning) is on the coordinator.
    // `internal` so domain extension files (`+AudioSessionObservers`, `+DarwinWidgetNotify`,
    // `+NetworkPathObservation`, `+LayoutHosting`) can call in; Swift `private` is file-scoped
    // and would break cross-file host domains.
    nonisolated let streamingPlayer: DirectStreamingPlayer

    // Playback authority (do not reintroduce a host-local `isPlaying` bool):
    // - Engine rate reality → ``DirectStreamingPlayer/isPlaying``
    // - Visual / sticky intent → ``SharedPlayerManager`` / ``PlayerVisualState``
    // - Resumption gates → `currentPlaybackIntent` / `shouldAutoPlayOrResume` / `canProceedWithPlayback`
    // Reachability SSOT: DirectStreamingPlayer.hasInternetConnection (engine-owned path monitor).
    // Host never owns NWPathMonitor / connectivity probe timer — see
    // ViewController+NetworkPathObservation (``observeEngineNetworkPath``).
    /// Teardown guard for observers that may fire after `deinit` begins.
    ///
    /// `internal` so domain extensions (`+AudioSessionObservers`, `+NetworkPathObservation`) can
    /// short-circuit safely without a second host flag.
    var isDeallocating = false

    /// Mirrors the engine reachability flag for tests and legacy call sites.
    ///
    /// Reads/writes ``DirectStreamingPlayer/hasInternetConnection`` — the host does not
    /// keep a parallel connectivity bool.
    @objc var hasInternet: Bool {
        get { streamingPlayer.hasInternetConnection }
        set { streamingPlayer.hasInternetConnection = newValue }
    }
    
    // MARK: - Initialization

    /// Designated initializer for production scene host and unit tests.
    ///
    /// Builds ``backgroundImageController`` and ``radioPlayerCoordinator`` before
    /// `super.init` from a shared local so neither property is an IUO and the
    /// coordinator never reads partially-initialized `self`.
    ///
    /// - Parameter streamingPlayer: Engine façade (default shared production instance).
    /// - SeeAlso: ``RadioPlayerCoordinator``, ``PlayerViewModel``
    init(streamingPlayer: DirectStreamingPlayer = DirectStreamingPlayer.shared) {
        self.streamingPlayer = streamingPlayer
        let background = BackgroundImageController()
        self.backgroundImageController = background
        self.radioPlayerCoordinator = RadioPlayerCoordinator(
            backgroundImageController: background,
            streamingPlayer: streamingPlayer
        )
        super.init(nibName: nil, bundle: nil)
        self.streamingPlayer.setDelegate(self)
    }

    required init?(coder: NSCoder) {
        self.streamingPlayer = DirectStreamingPlayer.shared
        let background = BackgroundImageController()
        self.backgroundImageController = background
        self.radioPlayerCoordinator = RadioPlayerCoordinator(
            backgroundImageController: background,
            streamingPlayer: streamingPlayer
        )
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
    /// Cold-launch **hygiene** lives in the trailing async Task (factory reset, model-only
    /// stream, `.prePlay` UI). Auto-play is **not** decided here: presentable cold launch
    /// runs special tuning + ``play()`` only on the first presentable scene after that
    /// reset. When the process was launched with "-UITestMode" (see XCUITest targets),
    /// the Task short-circuits immediately after a clean .prePlay UI update: no factory
    /// reset, no presentable cold launch, no tuning sound, no identifying
    /// PersistedWidgetState writes, and no call to `SharedPlayerManager.play()`.
    /// This guarantees the streaming system (and security validation) stay idle
    /// until an explicit test interaction.
    ///
    /// - SeeAlso: ``SharedPlayerManager/isRunningInUITestMode``, ``SharedPlayerManager/play()``,
    ///   ``RadioPlayerCoordinator/markPresentableColdLaunchPlaybackReady(initialStream:)``,
    ///   CODING_AGENT.md (UI test isolation requirements + launch arguments).
    /// - Note: Performs heavy setup; defers non-critical tasks with asyncAfter for better launch performance.
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        // Processed image cache limit is now configured inside BackgroundImageController.
        
        // Accessibility custom actions for play/pause live in SwiftUI PlaybackControlsView
        // (state-dependent play/pause labels + named `toggle_playback` action).
        // Volume VoiceOver cluster (value, increase/decrease actions, volume_set_to announce)
        // lives on SwiftUI VolumeAndAirPlayRow / SystemVolumeVoiceOver / MPVolumeView
        // (identifier volumeSlider).
        
        // Playback audio session: DirectStreamingPlayer is the single owner.
        // Construction does not activate; first clip / play / attach await
        // ``configureAudioSessionAsync()``.
        
        // Haptics owned by RadioPlayerCoordinator.wireAndInitialSetup() (single owner).
        // UIImpact only — do not add a CHHapticEngine (see HapticPlaybackPolicy).
        
        setupDarwinNotificationListener()
        setupUI()
        
        // Wire the init-time coordinator + VM after hierarchy is built.
        // Both are definite non-optionals from designated init (not created here).
        // Action closures are wired inside wireAndInitialSetup.
        // Hosted root already uses ``playerViewModel`` (lazy hosting controller); no mock swap.
        radioPlayerCoordinator.viewModel = playerViewModel
        radioPlayerCoordinator.viewController = self
        // Coordinator UIAlertControllers (privacy-clear confirm, security, SSL) present
        // after the sleep-timer `.confirmationDialog` presented chain is empty **and**
        // leftover `GlassPopoverContentViewRepresentable` hosts have left the window
        // scene, then `layoutIfNeeded` on this host + hosting view.
        // `presentedViewController == nil` is not enough (320 autoresizing vs ~357
        // alert width). PlaybackControlsView also withholds `onClearLocalStateTapped`
        // until the dialog `isPresented` is false (`SleepTimerPrivacyClearPresentation`).
        // Do not disable the confirmationDialog; do not fight UIKit's glass host constraints.
        radioPlayerCoordinator.presentAlert = { [weak self] alert in
            self?.presentCoordinatorAlertAfterOutgoingPresentationSettles(alert)
        }
        radioPlayerCoordinator.wireAndInitialSetup()
        
        // Initial language + selectedStreamIndex + VM needle seed are owned by
        // RadioPlayerCoordinator.wireAndInitialSetup (preferredMainAppInitialLanguageCode SSOT).
        // Host only needs the language code for the cold-launch stream model attach below.
        let languageCode = SharedPlayerManager.preferredMainAppInitialLanguageCode()

        // Play/pause + sleep timer + volume/AirPlay chrome live in SwiftUI
        // (PlaybackControlsView / VolumeAndAirPlayRow / AirPlayButton); no host UIKit control install.
        // Reset per-launch cellular permission flags early (before path observation can fire the expensive path).
        // The manager itself seeds the persisted permission + does legacy migration on init.
        // Path observation + cellular alert presentation: ViewController+NetworkPathObservation.
        cellularPermissionManager.resetPerLaunchFlags()
        // Single path monitor lives on DirectStreamingPlayer; host only observes.
        if !SharedPlayerManager.isRunningInUITestMode {
            observeEngineNetworkPath()
        }
        setupInterruptionHandling()
        setupRouteChangeHandling()
        // ICY onMetadataChange is registered in RadioPlayerCoordinator.wireAndInitialSetup
        // (single owner with sleep-interaction deferred apply).
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        
        setupFastWidgetActionChecking()

        // Sleep timer observer + preset/cancel + clear-local-state owned by RadioPlayerCoordinator
        // (wireAndInitialSetup + PlayerViewModel closures). Presentation is SwiftUI
        // `.confirmationDialog` in PlaybackControlsView; privacy clear via
        // SleepTimerPrivacyClearPresentation then onClearLocalStateTapped.
        
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
            // immediately — even if this process was created in the background (jetsam / last-media
            // relaunch). Residual hygiene must not wait for become-active.
            //
            // Auto-play is **not** this Task. After factory reset, product policy is open app =
            // radio only on the first **presentable** scene (special tuning then play when sticky
            // intent is absent) — not App Group play restore, and not a background scene-create.
            // Residual post-reboot surprise is orthogonal: discard residual pending + clear residual
            // NP so pre-reboot mailbox / media cards cannot surprise-attach *before* that user path.
            // (``discardResidualPendingActionsAndArmMailboxForThisProcess`` via factory reset.)
            //
            // - SeeAlso: ``RadioPlayerCoordinator/markPresentableColdLaunchPlaybackReady(initialStream:)``,
            //   ``RadioPlayerCoordinator/notePresentableSceneForColdLaunchPlayback()``,
            //   SharedPlayerManager.hasExplicitTerminationSentinel (presentation only),
            //   docs/Widget-Presentation-Dataflow.md (user-initiated main open vs residual surprise).
            await SharedPlayerManager.shared.resetToFactoryDefaultsOnLaunch()
            
            let initialStream = SharedPlayerManager.streamForLanguageCode(languageCode)
            
            // In-memory UI + model setup only (selector needle, player selectedStream).
            // These are required for the app to be usable on launch and do not re-create
            // "recently deleted" persisted data (snapshot, lastUpdateTime, language liveness signals).
            self.updateUI(for: .prePlay)  // not the post-clear path (that now uses .cleared)
            
            // Stream model and UI only; secured AVPlayerItem is created once in attachAndPlay after tuning.
            await self.streamingPlayer.prepareStreamChoice(initialStream, preparation: .modelOnly)
            
            // Background deferral state is now owned by BackgroundImageController (cold launch path preserved).
            // Actual image processing is deferred until playback is stable; choosing the initial lang
            // for prep is acceptable (not an "I listened" signal).
            backgroundImageController.scheduleDeferredForStreamSwitch(initialStream)

            // Mark presentable cold launch ready. If become-active already ran (slow factory reset /
            // ActivityKit end) **or** the scene is already `.active`, the coordinator proceeds
            // immediately. If this process is backgrounded (jetsam), it waits.
            await self.radioPlayerCoordinator.markPresentableColdLaunchPlaybackReady(initialStream: initialStream)
            if UIApplication.shared.applicationState == .active {
                await self.radioPlayerCoordinator.notePresentableSceneForColdLaunchPlayback()
            }
        }
    }
    
    // viewDidLayoutSubviews + setupUI: ViewController+LayoutHosting.swift

    // Darwin widget notify install + launch 1…5 s drain burst live in
    // ViewController+DarwinWidgetNotify.swift (isolation map: Darwin widget notify).
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // Cold-launch needle: viewDidLayoutSubviews width-change guard only (no delayed appear updates).
        
        // ───────────────────────────────────────────────────────────────────
        // SAFE playback trigger in viewDidAppear — ONLY for resurrection cases
        // NO auto-play on cold launch (prePlay). That is handled on the first presentable
        // scene after factory hygiene (presentable cold launch).
        // ───────────────────────────────────────────────────────────────────
        Task { @MainActor in
            let visualState = await SharedPlayerManager.shared.currentVisualState
            
            #if DEBUG
            print("[ViewController] viewDidAppear → currentVisualState = \(visualState)")
            #endif
            
            switch visualState {
            case .prePlay:
                #if DEBUG
                print("[ViewController] viewDidAppear → prePlay on cold launch → SKIPPING (handled on first presentable scene after factory hygiene)")
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

            @unknown default:
                #if DEBUG
                print("[ViewController] viewDidAppear → unknown visualState → SKIPPING auto-play")
                #endif
            }

            // Sleep timer display sync (and now dialog-driven set/cancel) performed via coordinator + VM.
            await self.radioPlayerCoordinator.viewDidAppearResurrectionCheck()
        }
    }
    
    // Persist after widget-action completion: ``RadioPlayerCoordinator/saveStateForWidget()``
    // (thin ``SharedPlayerManager/saveCurrentState()`` forwarder). Debouncing lives in
    // `WidgetRefreshManager`; that path does not apply its own throttle.

    // setupFastWidgetActionChecking: ViewController+DarwinWidgetNotify.swift
    // Engine path observation + cellular alert + reconnect: ViewController+NetworkPathObservation.swift
    // Audio session interruption / route + reconfigure: ViewController+AudioSessionObservers.swift
    // setupUI + viewDidLayoutSubviews + coordinator-alert present settle:
    // ViewController+LayoutHosting.swift (``presentCoordinatorAlertAfterOutgoingPresentationSettles``).

    // Status changes: StreamingPlayerDelegate.onStatusChange → coordinator handleStatusChange.
    // ICY metadata: coordinator registers DirectStreamingPlayer.onMetadataChange in wireAndInitialSetup.
    // showSecurityModelAlert + showSSLTransitionAlert: coordinator presentAlert hook.
    // Status chrome VoiceOver + no-internet side effects: coordinator
    // ``RadioPlayerCoordinator/safeUpdateStatusLabel`` / ``updateUIForNoInternet`` (not host duplicates).
    
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
    /// Host retains this method only as a thin forwarder for `@objc` / public shims — no
    /// host-local playback bool is updated here (visual/intent SSOT is SPM; rate truth is engine).
    ///
    /// - SeeAlso: `togglePlayback()`, `handlePlayAction()`, `handlePauseAction()`, `handleTogglePlayback()`, `updateUI(for:)`
    @MainActor
    private func handleUserTogglePlayback() async {
        // Single implementation lives in RadioPlayerCoordinator (orchestration owner).
        // VC retains the method for the @objc togglePlayback + public handleTogglePlayback call sites.
        await radioPlayerCoordinator.handleUserTogglePlayback()
    }
    
    // MARK: - Playback Control Methods
    // pausePlayback / stopPlayback orchestration live on RadioPlayerCoordinator public shims.
    // Path-observation disconnect and cellular "Not Now" call the coordinator directly
    // (ViewController+NetworkPathObservation). Public host handlePauseAction / toggle still go
    // through coordinator via handleUserTogglePlayback.

    /// Thin chrome forwarder for host-owned paths (interruption recovery, legacy widget).
    ///
    /// Distribution + security-alert side effects live in ``RadioPlayerCoordinator/updateUI(for:)``.
    /// `internal` so `ViewController+AudioSessionObservers` can refresh chrome after a blocked resume.
    /// Path-observation disconnect chrome calls the coordinator directly
    /// (``RadioPlayerCoordinator/updateUIForNoInternet()`` / ``stopPlayback()``).
    ///
    /// - Parameter visualState: Sticky or transient visual to push into the coordinator.
    /// - SeeAlso: ``RadioPlayerCoordinator/updateUI(for:)``, ViewController+AudioSessionObservers,
    ///   ViewController+NetworkPathObservation
    @MainActor
    func updateUI(for visualState: PlayerVisualState) {
        radioPlayerCoordinator.updateUI(for: visualState)
    }

    // setupUI: ViewController+LayoutHosting.swift (isolation map: Layout hosting).
    
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
    
    // Special cold-launch tuning + AVAudioPlayerDelegate finish path live on RadioPlayerCoordinator
    // (playSpecialTuningSound + TuningSoundCoordinator gate). Host only invokes the coordinator method.
    // Sleep timer UI glue lives in RadioPlayerCoordinator (wireAndInitialSetup + VM action closures).
    // Sole presentation: SwiftUI `.confirmationDialog` in PlaybackControlsView.
    // No host viewWillDisappear teardown (sleep cancel is coordinator-owned).

    // MARK: - Lifecycle (deinit)
    /// Cleans up resources, observers, and audio players to prevent leaks.
    /// - Note: Sets `isDeallocating` to avoid operations during teardown.
    deinit {
        isDeallocating = true
        // Sleep notif observer remove: no longer added by VC; coordinator manages its own.
        
        #if DEBUG
        print("[ViewController] deinit starting")
        #endif
        
        // Path callback clear: ViewController+NetworkPathObservation (monitor stays engine-owned).
        // Darwin CF observer remove: ViewController+DarwinWidgetNotify (same Unmanaged identity
        // as install). Swift `deinit` must stay on the primary type body.
        clearEngineNetworkPathObservation()
        removeDarwinNotificationObserver()
        
        #if DEBUG
        print("[ViewController] deinit completed")
        #endif
    }
    
    // handleLanguageSelection + completeStreamSwitch + updateUserDefaultsLanguage (full orchestration + debounce + prePlay optimistic + tuning + intent reset + background deferral + play sequencing)
    // removed. Single source now in RadioPlayerCoordinator (wired via onSelectionChanged closure set in wireAndInitialSetup; no overwrite here).
    // The languageSelectorView.onSelectionChanged wiring that pointed here has been removed so the coordinator's handler is authoritative.
    
    /// Handles widget-initiated stream switching to a specific language without playing tuning sounds.
    public func handleWidgetSwitchToLanguage(_ languageCode: String, actionId: String) {
        // Full implementation (processed guard, workItem, stop/set/play flow, intent checks) lives in RadioPlayerCoordinator.
        radioPlayerCoordinator.handleWidgetSwitchToLanguage(languageCode, actionId: actionId)
    }
    
    // MARK: - Widget and URL Scheme Handling

    /// Thin lifecycle / test entry for App Group pending-action drain.
    ///
    /// Ownership of debounce, UITestMode drain-without-execute, mailbox enqueue, and
    /// switch work-item cancel is ``RadioPlayerCoordinator/checkForPendingWidgetActions()``.
    /// Darwin notify + launch burst (`ViewController+DarwinWidgetNotify`) and SceneDelegate
    /// become-active / foreground call this shim only.
    ///
    /// - SeeAlso: ``RadioPlayerCoordinator/checkForPendingWidgetActions()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    public func checkForPendingWidgetActions() {
        radioPlayerCoordinator.checkForPendingWidgetActions()
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
        radioPlayerCoordinator.handlePlayAction()
    }

    /// Public method to pause playback (callable from SceneDelegate)
    ///
    /// Routes through SharedPlayerManager.stop() (the authoritative
    /// path that immediately sets .userPaused + persists + refreshes widgets).
    public func handlePauseAction() {
        // Thin delegate.
        radioPlayerCoordinator.handlePauseAction()
    }

    /// Public method to switch to a specific language stream (callable from SceneDelegate).
    /// - Parameter languageCode: The ISO language code to switch to (e.g., "en", "de", "fi", "sv", "et").
    public func handleSwitchToLanguage(_ languageCode: String) {
        // Full external switch orchestration (stop + tuning + prepareStreamChoice / attachAndPlay + userDefaults + reset + play sequencing + UI) lives in RadioPlayerCoordinator.
        radioPlayerCoordinator.handleSwitchToLanguage(languageCode)
    }

    /// Public method to toggle play/pause state
    /// (callable from SceneDelegate, remote commands, Control Center, etc.)
    ///
    /// Now delegates to the internal SSOT (`handleUserTogglePlayback`)
    /// so that all toggle entry points (button, widget URL schemes, SceneDelegate, remote)
    /// flow through the single authoritative intent decision path.
    public func handleTogglePlayback() {
        // Thin delegate (both the coordinator shim and the internal handleUserTogglePlayback forward are covered by this).
        radioPlayerCoordinator.handleTogglePlayback()
    }

    /// Menu / keyboard previous or next language (⌘[ / ⌘]).
    ///
    /// Wraps ``DirectStreamingPlayer/availableStreams`` via
    /// ``PlaybackKeyboardMenu/adjacentStreamIndex(current:offset:count:)`` and
    /// enters ``handleLanguageSelection(at:)`` (same orchestration as a flag tap).
    ///
    /// - Parameter offset: Signed catalog step (`-1` previous, `+1` next).
    /// - SeeAlso: ``RadioPlayerCoordinator/handleAdjacentLanguageSelection(offset:)``,
    ///   ``AppDelegate/menuPreviousLanguage(_:)``, ``AppDelegate/menuNextLanguage(_:)``
    public func handleAdjacentLanguageSelection(offset: Int) {
        radioPlayerCoordinator.handleAdjacentLanguageSelection(offset: offset)
    }

    /// Public method called when the user taps the Live Activity (Lock Screen or Dynamic Island)
    /// or uses other "open" deep links from widgets.
    ///
    /// Simply foregrounds the app and runs the coordinator's resurrection / state sync check.
    /// Respects all sticky .userPaused / .securityLocked rules exactly like viewDidAppear.
    /// No new playback intent is created here — this is pure navigation / surface activation.
    /// Presentable cold auto-play (if still ready) is owned by
    /// ``notePresentableSceneForColdLaunchPlayback()`` on become-active, not this open handler.
    public func handleOpenFromLiveActivity() {
        Task { @MainActor in
            await radioPlayerCoordinator.viewDidAppearResurrectionCheck()
        }
    }

    /// First presentable scene after factory hygiene: drain already ran; now the coordinator
    /// may run presentable cold launch (special tuning + ``play()`` when allowed).
    ///
    /// SceneDelegate calls this after pending-action drain and before Live Activity ensure.
    ///
    /// - SeeAlso: ``RadioPlayerCoordinator/notePresentableSceneForColdLaunchPlayback()``,
    ///   SceneDelegate.sceneDidBecomeActive
    func notePresentableSceneForColdLaunchPlayback() async {
        await radioPlayerCoordinator.notePresentableSceneForColdLaunchPlayback()
    }
}

extension ViewController {
    // MARK: - Toggle Playback
    /// Primary `@objc` entry for user-initiated play/pause (legacy remote / selector paths).
    ///
    /// Delegates to ``handleUserTogglePlayback()`` → coordinator. SwiftUI
    /// `PlaybackControlsView` owns pause press chrome; the coordinator owns
    /// audible-start and privacy-clear impacts.
    /// Status chrome VoiceOver is **not** host-owned — see
    /// ``RadioPlayerCoordinator/safeUpdateStatusLabel(text:backgroundColor:textColor:isPermanentError:)``.
    ///
    /// - SeeAlso: `handleUserTogglePlayback()`, `handleTogglePlayback()` (public SceneDelegate wrapper),
    ///   ``HapticPlaybackPolicy``, ``HapticsController``, CODING_AGENT.md
    @objc private func togglePlayback() {
        // SwiftUI PlaybackControlsView owns pause press chrome (local token +
        // `.sensoryFeedback`). Coordinator owns audible-start (`.light`) and
        // privacy-clear (`.heavy`) UIImpact via HapticPlaybackPolicy.
        // Rapid-tap guard is handled inside the VM/coordinator paths if needed.
        Task { @MainActor in
            await self.handleUserTogglePlayback()
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
            await self?.radioPlayerCoordinator.handleStatusChange(status, reasonKey: reasonKey)
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
                    // Primary call sites (SceneDelegate widget-action + coordinator drain)
                    // already special-case "switch" and call handleWidgetSwitchToLanguage directly.
                    // This case is legacy/unreachable in current routing. Delegation ensures that
                    // even if hit, we do not duplicate manual engine sequences or UI logic.
                    // The coordinator's processedActionIds may already contain actionId if the
                    // canonical path ran first; the trailing clearPending + save below still run.
                    handleWidgetSwitchToLanguage(languageCode, actionId: actionId)
                }
                
            default:
                #if DEBUG
                print("Unknown widget action: \(action)")
                #endif
            }
            
            radioPlayerCoordinator.saveStateForWidget()
            
            #if DEBUG
            print("[ViewController] Widget action '\(action)' completed → coordinator.saveStateForWidget")
            #endif
            
            // Clear the pending action (actor-isolated)
            SharedPlayerManager.shared.clearPendingAction(actionId: actionId)
        }
    }
}

// MARK: - DEBUG test seams (WidgetIntentContractTests)

#if DEBUG
extension ViewController {

    /// Forwards to ``RadioPlayerCoordinator`` (single owner of pending-action drain seams).
    ///
    /// Existing contract tests call this on the host ViewController without holding a
    /// coordinator reference; the bypass flag itself lives on the coordinator.
    ///
    /// - SeeAlso: ``RadioPlayerCoordinator/_test_setBypassUITestModeForPendingActionProcessing(_:)``,
    ///   ``checkForPendingWidgetActions()``, docs/Widget-Functionality-Roadmap.md (Tier 2).
    nonisolated static func _test_setBypassUITestModeForPendingActionProcessing(_ bypass: Bool) {
        RadioPlayerCoordinator._test_setBypassUITestModeForPendingActionProcessing(bypass)
    }

    /// Forwards debounce reset to the coordinator (always present after designated init).
    func _test_resetWidgetActionDebounceForTests() {
        radioPlayerCoordinator._test_resetWidgetActionDebounceForTests()
    }
}
#endif
