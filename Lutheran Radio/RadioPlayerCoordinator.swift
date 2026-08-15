//
//  RadioPlayerCoordinator.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 13.6.2026.
//
//  Lightweight @MainActor orchestration layer (introduced during ViewController decomposition).
//  Owns wiring of the extracted presentational components (LanguageSelectorView, BackgroundImageController,
//  PlaybackControlsView, NowPlayingMetadataView), the full stream-selection flows, distribution of every
//  visual/metadata/background update, haptics triggering, privacy clear UI, and initial-setup sequencing.
//
//  Domain extensions (same type, mechanical splits — public entry points unchanged).
//  See the isolation map on the class for the authoritative domain table.
//  - RadioPlayerCoordinator+PendingActions.swift — App Group pending-action drain, play/pause
//    debounce, UITestMode drain-without-execute, widget play/pause helpers + DEBUG seams.
//  - RadioPlayerCoordinator+SleepTimer.swift — sleep-timer UI glue (dialog settle windows,
//    preset/cancel handlers, local countdown Task + VM sync, SleepTimerNotification observer,
//    interaction window that defers Now Playing title apply). SPM remains timer authority.
//  - RadioPlayerCoordinator+Tuning.swift — cold-launch special clip, stream-switch delight clip,
//    stop/interrupt, AVAudioPlayerDelegate finish paths → TuningSoundCoordinator.
//  - RadioPlayerCoordinator+StreamSwitch.swift — language / stream-switch orchestration
//    (flag-tap completeStreamSwitch, widget silent switch, external deep-link switch,
//    updateUserDefaultsLanguage, VoiceOver language announce).
//  - RadioPlayerCoordinator+StatusDistribution.swift — chrome / status distribution
//    (updateUI, handleStatusChange, RadioPlayerChromeVisualResolver, VM metadata sync,
//    no-internet chrome, Now Playing / widget save thin forwarders, thermal VoiceOver).
//
//  Sleep timer presentation: sole surface is SwiftUI `.confirmationDialog` in PlaybackControlsView
//  (presets + conditional Cancel + always-present "Clear local state" privacy action).
//  Privacy clear (`confirmAndClearLocalState`) stays on this file; timer glue is +SleepTimer.
//  No UIKit UIMenu builder.
//
//  ViewController remains the thin lifecycle host + view hierarchy builder + public intent shims
//  (for SceneDelegate, widgets, remote commands) + hard-to-move observers (interruptions, route,
//  Darwin listener setup, deinit CF cleanup). Orchestration owned here (not on VC):
//  - Pending-action drain (see +PendingActions; VC/SceneDelegate call thin shims only)
//  - selectedStreamIndex + language selection / stream-switch (see +StreamSwitch)
//  - Sleep-timer interaction window + deferred ICY metadata apply (see +SleepTimer; metadata
//    registration here consults the interaction flag)
//  - DirectStreamingPlayer.onMetadataChange registration (in-app VM only; SPM owns ICY SSOT)
//  - Status / chrome distribution (see +StatusDistribution; host only hops StreamingPlayerDelegate)
//  - Cold-launch special tuning + stream-switch tuning delight (see +Tuning; host only invokes)
//  VC / SceneDelegate only call thin public shims after lifecycle or Darwin notify.
//
//  SwiftUI observation: coordinator now optionally drives a PlayerViewModel (@Observable) from
//  the same updateUI + orchestration paths. This is additive; UIKit subviews continue to be driven
//  verbatim. The VM provides the surface for SwiftUI while coordinator retains all timing authority.
//
//  All calls to SharedPlayerManager (currentVisualState, currentPlaybackIntent, play/stop/userRequestedPlay/
//  resetToPrePlayForNewStream/setUserIntentToPlay/setSleepTimer/cancelSleepTimer/sleepTimerRemainingSeconds/
//  persistWidgetSnapshot/saveCurrentState/didUpdateStreamMetadata/updateNowPlayingInfo/clear* etc.) are
//  preserved verbatim with zero changes in semantics or ordering.
//

import UIKit
@unsafe @preconcurrency import AVFoundation
import WidgetKit
import Core
import WidgetSurface

/// Lightweight coordinator (wiring + orchestration only). Does not own playback execution, security,
/// streaming engine decisions, or widget snapshot authority — those remain exclusively in
/// SharedPlayerManager + DirectStreamingPlayer + Core security paths (per guardrails).
///
/// **Pending-action drain:** Single owner of App Group `pendingAction*` processing after Darwin notify
/// or SceneDelegate become-active / foreground / launch burst. Implementation lives in
/// `RadioPlayerCoordinator+PendingActions.swift` (same type). Play and pause share the media-transport
/// mailbox; same-direction debounce (0.65 s) drops thrash while opposite verbs always run; UITestMode
/// clears without executing unless the DEBUG bypass is set. Lifecycle hosts call
/// ``checkForPendingWidgetActions()`` only — they do not reimplement debounce or mailbox enqueue.
///
/// **Sleep-timer UI glue:** Dialog settle windows, preset/cancel handlers, local countdown Task,
/// VM remaining sync, and `SleepTimerNotification` observation live in
/// `RadioPlayerCoordinator+SleepTimer.swift` (same type). SharedPlayerManager remains the timer
/// authority (`setSleepTimer` / `cancelSleepTimer` / `applySleepTimerElapsedPause`). SwiftUI
/// (`PlaybackControlsView`) owns only the `.confirmationDialog` presentation and calls back via
/// `PlayerViewModel` closures. Wire via ``wireSleepTimerUIGlue()`` from ``wireAndInitialSetup()``.
///
/// **Stream index / language switch:** Single owner of `selectedStreamIndex` (wired to
/// `PlayerViewModel` and all language / widget / stream-switch paths). Behavior lives in
/// `RadioPlayerCoordinator+StreamSwitch.swift`. The host does not mirror this value.
///
/// **Status / chrome distribution:** `updateUI`, `handleStatusChange`, SSOT visual observation
/// (``beginObservingVisualStateForChrome()``), and `RadioPlayerChromeVisualResolver` live in
/// `RadioPlayerCoordinator+StatusDistribution.swift` (same type). Host only hops
/// `StreamingPlayerDelegate` into ``handleStatusChange(_:reasonKey:)``. SPM remains visual/intent
/// SSOT; **primary** paint for durable visual transitions follows ``PlayerEvent/visualStateDidChange``;
/// status path is a **demoted adapter** (optional one-frame race lead + error/unavailable/SSL side
/// effects only — pure policy may promote early; supersession gate blocks regressing settled SSOT chrome).
///
/// **Metadata:** Registers `DirectStreamingPlayer.onMetadataChange` in ``wireAndInitialSetup()`` for
/// **in-app ViewModel only**. Live ICY StreamTitle SSOT is ``SharedPlayerManager/didUpdateStreamMetadata(_:)``
/// via ``DirectStreamingPlayer/safeOnMetadataChange`` — the coordinator must not re-enter that path.
/// Sleep-timer interaction (owned by +SleepTimer) defers only VM chrome re-apply during modal settle.
///
/// **Special tuning:** Production cold-launch clip is ``playSpecialTuningSound(completion:)``
/// (implementation in `+Tuning.swift`) — session/clip start via
/// ``DirectStreamingPlayer/startLocalClipPlayer``, finish via `AVAudioPlayerDelegate` →
/// ``TuningSoundCoordinator``. Stream-switch delight uses ``playTuningSound(animateNeedleTo:)``
/// (duration-based; no main-stream gate). Host interruption/route paths call ``stopTuningSound()``.
///
/// - SeeAlso: ``SharedPlayerManager/signalWidgetPendingAction(visualState:action:language:)``,
///   ``SharedPlayerManager/submitMediaTransportCommandAndWait(_:)``,
///   ``SharedPlayerManager/setSleepTimer(duration:)``,
///   `RadioPlayerChromeVisualResolver`, `TuningSoundCoordinator`,
///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
///   docs/Widget-Functionality-Roadmap.md, CODING_AGENT.md (Single Source of Truth Principles).
@MainActor
final class RadioPlayerCoordinator: NSObject, AVAudioPlayerDelegate {

    // MARK: - Isolation map (domain split)
    //
    // RadioPlayerCoordinator is the @MainActor orchestration façade. Mutable orchestration
    // stamps live on this primary type body; domain behavior lives in extension files.
    // Engine attach / security / widget snapshot SSOT are *not* in this map — see
    // DirectStreamingPlayer, Core, and SharedPlayerManager.
    //
    // | Domain | File | Responsibility |
    // |--------|------|----------------|
    // | Pending-action drain | RadioPlayerCoordinator+PendingActions.swift | App Group `pendingAction*` drain, play/pause debounce, UITestMode drain-without-execute, widget play/pause helpers + DEBUG seams |
    // | Sleep-timer UI glue | RadioPlayerCoordinator+SleepTimer.swift | Dialog settle windows, preset/cancel, local countdown Task + VM sync, SleepTimerNotification, metadata deferral window |
    // | Tuning sounds | RadioPlayerCoordinator+Tuning.swift | Cold-launch special clip, stream-switch delight, stop/interrupt, AVAudioPlayerDelegate finish → TuningSoundCoordinator |
    // | Stream switch / language | RadioPlayerCoordinator+StreamSwitch.swift | Flag-tap completeStreamSwitch, widget silent switch, external deep-link switch, keyboard/menu adjacent wrap (`handleAdjacentLanguageSelection`), updateUserDefaultsLanguage, language VoiceOver announce |
    // | Status / chrome distribution | RadioPlayerCoordinator+StatusDistribution.swift | updateUI, handleStatusChange, SSOT visual chrome observation, RadioPlayerChromeVisualResolver, VM metadata/switch-flag sync, no-internet chrome, NP/widget save forwarders, thermal VoiceOver |
    // | Play / pause toggle | (this file) | handlePlayAction / handlePauseAction / handleTogglePlayback / handleUserTogglePlayback / pausePlayback / stopPlayback public shims |
    // | Privacy clear | (this file) | confirmAndClearLocalState + localStateCleared observer |
    // | Layout / energy hooks | (this file) | notifyLayoutChange, viewDidAppearResurrectionCheck, memory/energy forwarders |
    // | Wiring / cold launch | (this file) | wireAndInitialSetup, performColdLaunchPlaybackIfAllowed, metadata registration, haptics prepare |
    //
    // Cross-layer owners (do not re-home into this façade):
    // - AVPlayer / attach / recovery / rate pause → DirectStreamingPlayer
    // - PlayerVisualState / PlaybackIntent / PlayerEvent / session snapshots → SharedPlayerManager
    // - Timer duration authority / elapsed pause → SharedPlayerManager sleep-timer APIs
    // - DNS TXT / cert digests / ATS SPKI → Core only
    // - Thin host lifecycle + Darwin install → ViewController; interruption/route observers →
    //   ViewController+AudioSessionObservers (host chrome only; engine owns rate pause)
    //
    // Stored-state rule: extensions cannot declare stored properties. Domain files mutate
    // internal stamps declared below (PendingActions / SleepTimer / Tuning / StreamSwitch /
    // StatusDistribution pattern).
    //
    // AGENT NOTE: Remaining peels (if needed) are optional privacy/layout extracts. Keep public
    // shims for SceneDelegate/VC stable. Prefer extension files over deep class hierarchies.

    // MARK: - Owned sub-components
    // LanguageSelectorView, PlaybackControlsView, NowPlayingMetadataView are now pure SwiftUI
    // and driven exclusively via the PlayerViewModel (pushed here, actions forwarded).
    // Background and streaming remain.
    // Internal: +SleepTimer needs modal deferral (cancelDeferredForModalInteraction /
    // rescheduleDeferredAfterModalIfNeeded) during dialog settle windows.
    // Internal streamingPlayer: +Tuning (and later domain peels) need clip/engine entry.
    let backgroundImageController: BackgroundImageController
    private let hapticsController = HapticsController()
    /// Engine façade retained for orchestration (metadata registration, stream switch,
    /// status reads, local-clip start). `internal` so domain extension files can call in;
    /// Swift `private` is file-scoped and would break `+Tuning` / `+StreamSwitch` /
    /// `+StatusDistribution` and other domain peels.
    nonisolated let streamingPlayer: DirectStreamingPlayer

    // Weak back-ref for the few services that remain difficult to move in a single mechanical pass
    // (primarily presenting security/stream alerts that were previously implemented directly on VC,
    // and saveStateForWidget which is a one-line thin forwarder). All heavy decision paths stay here.
    weak var viewController: ViewController?

    // Presenting hook (injected by VC so alerts can be shown without giving coordinator a full VC ref for layout).
    //
    // IMPORTANT: The closure provided by ViewController defers the actual `present(_:animated:)`
    // via DispatchQueue.main.async. This is required to avoid Auto Layout unsatisfiable constraint
    // warnings (320pt autoresizing vs. internal alert ~366pt width) when presenting right after
    // a SwiftUI .confirmationDialog action while other main-thread layout (widgets, background
    // images, etc.) is occurring. All uses of presentAlert? benefit from this protection.
    var presentAlert: ((UIAlertController) -> Void)?

    // MARK: - SwiftUI observation bridge (optional, non-breaking)
    /// When non-nil, the coordinator drives this @Observable model in addition to the
    /// legacy UIKit presentational views. This enables gradual SwiftUI adoption while
    /// the coordinator remains the single owner of timing, debouncing, and orchestration.
    ///
    /// All pushes happen on @MainActor. Never write to the viewModel from SwiftUI directly
    /// for authoritative state (use the action closures on the VM instead).
    var viewModel: PlayerViewModel?

    // MARK: - Orchestration state (moved from ViewController)
    var selectedStreamIndex: Int = 0
    // Chrome stamps (owned by +StatusDistribution). Internal so the extension file and
    // privacy-clear path on this file can share the same last-applied / alert / ever-played
    // flags without redeclaring stored properties in the extension.
    var lastAppliedVisualState: PlayerVisualState?
    var hasShownSecurityAlert = false
    var hasEverPlayed = false
    /// Multi-cast ``PlayerEvent`` observer that paints in-app chrome from visual SSOT
    /// transitions (``visualStateDidChange``) without requiring a status emission.
    /// Owned by +StatusDistribution; stored here because extensions cannot declare storage.
    let visualChromeEventObserver = WidgetEventObserver<PlayerEvent>()
    /// Observation task seam for SSOT chrome paint (cancelled in deinit / restart).
    var visualChromeObservationTask: Task<Void, Never>?
    // Tuning clip stamps (owned by +Tuning; deep coupling to TuningSoundCoordinator +
    // startLocalClipPlayer remains). Internal access so the extension file and language-
    // selection wait path on this file can share the same flags.
    var hasPlayedSpecialTuningSound = false
    var isTuningSoundPlaying = false
    var tuningPlayer: AVAudioPlayer?
    var lastTuningSoundTime: Date?

    // Stream switch debounce + cancellation (owned by +StreamSwitch). Internal so the
    // extension file can share work-item / task / last-switch stamps with this body.
    var streamSwitchWorkItem: DispatchWorkItem?
    var streamSwitchTask: Task<Void, Never>?
    var lastStreamSwitchTime: Date?
    let streamSwitchDebounceInterval: TimeInterval = 1.0

    // Sleep timer UI glue state + Task (owned by +SleepTimer; deep coupling to SharedPlayerManager
    // + SleepTimerNotification remains). Internal access so the extension file and the metadata
    // registration / deinit / privacy-clear paths on this file can share the same stamps.
    var sleepTimerDisplayTask: Task<Void, Never>?
    var cachedSleepTimerRemaining: Int?
    /// True while sleep-timer dialog settle is in flight; defers Now Playing title apply.
    var isSleepTimerInteractionActive = false
    /// Metadata stashed during the interaction window; applied in ``finishSleepTimerInteraction``.
    var pendingMetadataVisualRefresh: String?
    /// Settle delay after the SwiftUI confirmationDialog dismisses before applying timer work.
    static let sleepTimerDialogSettleNs: UInt64 = 250_000_000
    static let sleepTimerPostScheduleUISettleNs: UInt64 = 300_000_000
    static let sleepTimerDeferredVisualSettleNs: UInt64 = 500_000_000

    // Widget switch work item (actionId dedup uses processedActionIds below).
    // `pendingWidgetSwitchWorkItem` / `processedActionIds` are internal so +PendingActions can
    // cancel a deferred switch before mailbox play and bound the dedup set after drain.
    // Stream-switch debounce stamp is `lastStreamSwitchTime` (owned by +StreamSwitch).
    var pendingWidgetSwitchWorkItem: DispatchWorkItem?

    // Widget / extension-hosted play/pause drain debouncing (owned by +PendingActions).
    // Same-direction repeats within the interval are dropped (AVFoundation thrash guard).
    // Opposite verbs always execute so a rapid play→pause (or pause→play) flip is not lost
    // after optimistic Live Activity / home-widget chrome already acknowledged the second tap.
    // Internal access: methods live in RadioPlayerCoordinator+PendingActions.swift.
    var lastWidgetActionTime: Date = .distantPast
    /// Last executed pending verb for play/pause drain (`"play"` or `"pause"`).
    var lastWidgetPlayPauseAction: String?
    let widgetActionDebounceInterval: TimeInterval = 0.65

    /// Dedup set for widget-originated action IDs (switch path + drain bookkeeping).
    /// Legacy URL-scheme `handleWidgetAction` on ViewController keeps a separate set for that surface only.
    var processedActionIds: Set<String> = []

    // MARK: - Init / Wiring
    init(
        backgroundImageController: BackgroundImageController,
        streamingPlayer: DirectStreamingPlayer
    ) {
        self.backgroundImageController = backgroundImageController
        self.streamingPlayer = streamingPlayer
        super.init()
    }

    /// Called by VC after it has added the subviews to the hierarchy (setupUI complete).
    /// Wires VM action closures (SwiftUI composed views), performs initial index calculation,
    /// starts haptic if supported, and registers the sleep notification observer.
    func wireAndInitialSetup() {
        // Wire SwiftUI ViewModel action closures.
        // Pure SwiftUI views (LanguageSelectorView etc) call viewModel.selectLanguage / play / pause
        // which forward here. Coordinator owns the full orchestration.
        if let vm = viewModel {
            vm.onPlayRequested = { [weak self] in
                self?.handlePlayAction()
            }
            vm.onPauseRequested = { [weak self] in
                self?.handlePauseAction()
            }
            vm.onLanguageSelected = { [weak self] index in
                self?.handleLanguageSelection(at: index)
            }
        }

        // Initial index from SSOT (PersistedWidgetState or bestInitialLanguageCode).
        let languageCode = SharedPlayerManager.preferredMainAppInitialLanguageCode()
        let initialIndex = DirectStreamingPlayer.indexForLanguageCode(languageCode)
        selectedStreamIndex = initialIndex

        // VM drives the SwiftUI selector; push the initial selection.
        viewModel?.selectedStreamIndex = initialIndex

        // Haptics early init (if hardware supports) — now delegated to tiny controller (P5+ extraction)
        hapticsController.prepareIfSupported()

        // Sleep-timer VM closures + SleepTimerNotification observer (+SleepTimer domain).
        wireSleepTimerUIGlue()

        // Main chrome paint from SPM visual SSOT transitions (setPlaying / pause / stop /
        // policy visuals). Non-forcing multi-cast observation — does not steal the primary
        // events iterator from WidgetRefreshManager. Status path remains race lead + errors.
        Task { @MainActor [weak self] in
            await self?.beginObservingVisualStateForChrome()
        }

        // ICY metadata → in-app ViewModel only.
        //
        // SharedPlayerManager already owns the program-metadata SSOT via
        // ``DirectStreamingPlayer/safeOnMetadataChange`` → ``didUpdateStreamMetadata(_:)``
        // (emit, Live Activity, Now Playing, widget snapshot). This closure must not
        // re-enter that path — dual delivery caused duplicate `.metadataDidUpdate` and
        // double surface pushes on every live StreamTitle.
        //
        // Sleep-timer interaction defers only in-app chrome re-apply (VM); SPM surfaces
        // still update immediately through the engine SSOT path.
        // Status chrome still arrives via StreamingPlayerDelegate → handleStatusChange.
        streamingPlayer.onMetadataChange = { [weak self] metadata in
            guard let self else {
                #if DEBUG
                print("[RadioPlayerCoordinator] onMetadataChange: coordinator is nil, skipping")
                #endif
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let metadata {
                    if self.isSleepTimerInteractionActive {
                        // Defer in-app metadata chrome while the sleep dialog settles.
                        self.pendingMetadataVisualRefresh = metadata
                    } else {
                        self.syncMetadataToViewModel(metadata)
                    }
                } else {
                    self.pendingMetadataVisualRefresh = nil
                    self.syncMetadataToViewModel(nil)
                }
            }
        }

        // Privacy clear observer.
        // Reacts to SharedPlayerManager.clearAllLocalState() from any path (sleep menu, future settings, etc.).
        // After clear the intent is .cleared (blocks) while visual is .cleared (blue "Cleared" pill).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(localStateCleared(_:)),
            name: .localStateCleared,
            object: nil
        )

        // Energy hook already self-registered inside BackgroundImageController; no-op here.
        backgroundImageController.updateForEnergyEfficiency()
    }

    /// Re-seeds the language selector after clearAllLocalState.
    /// When loadPersistedWidgetState() == nil (the post-clear / privacy case), falls back via
    /// bestInitialLanguageCode (preferredLanguages match) to a user-friendly initial stream instead
    /// of always English. This produces the fresh non-identifying initial state for the no-snapshot
    /// (post-clear or no-widgets) case while giving better everyday UX on the reseed.
    ///
    /// Awaitable so the DirectStreamingPlayer model sync completes before the clear flow returns
    /// (prevents races where an immediate post-clear play tap would see a stale pre-clear selectedStream).
    @MainActor
    private func resetLanguageSelectorToInitialLocale() async {
        let languageCode = SharedPlayerManager.preferredMainAppInitialLanguageCode()
        let initialIndex = DirectStreamingPlayer.indexForLanguageCode(languageCode)
        selectedStreamIndex = initialIndex
        viewModel?.selectedStreamIndex = initialIndex

        // Keep the DirectStreamingPlayer model in sync...
        let stream = DirectStreamingPlayer.streamForLanguageCode(languageCode)
        await DirectStreamingPlayer.shared.setSelectedStreamModelOnly(to: stream)
    }

    /// Called from the async portion of VC viewDidLoad Task after tuning sound + model-only set.
    /// Owns the sticky-intent guard + SharedPlayerManager.play() launch for cold start (prePlay path).
    ///
    /// Process isolation: only this-process sticky intent blocks. Prior-process termination
    /// liveness is presentation-only and is never consulted here.
    ///
    /// - SeeAlso: ``SharedPlayerManager/play()``, ViewController cold-launch Task,
    ///   ``SharedPlayerManager/hasExplicitTerminationSentinel()`` (widget chrome only).
    func performColdLaunchPlaybackIfAllowed(initialStream: DirectStreamingPlayer.Stream) async {
        // Ensure snapshot + intent are authoritative before deciding cold auto-play.
        await SharedPlayerManager.shared.refreshVisualStateFromPersistence()
        let visualState = await SharedPlayerManager.shared.currentVisualState
        let intent = await SharedPlayerManager.shared.currentPlaybackIntent
        #if DEBUG
        print("[RadioPlayerCoordinator] performColdLaunch... visual=\(visualState), intent=\(intent)")
        #endif

        // Hard blocker: this-process sticky intent only.
        if intent.isStickyPauseOrLock {
            #if DEBUG
            print("[RadioPlayerCoordinator] Blocked cold-launch playback — sticky intent")
            #endif
            return
        }

        // Allow .prePlay (normal cold or post-clear launch) or .cleared (in-process post-clear).
        // .cleared intent alone does not block the post-clear cold-start success path (it only
        // prevents auto-recovery before explicit play or the successful initial play()).
        let canStartPostClearPlay = visualState == .prePlay || visualState == .cleared || visualState.shouldAutoPlayOrResume || intent == .cleared
        guard canStartPostClearPlay else {
            #if DEBUG
            print("[RadioPlayerCoordinator] Blocked initial playback — state = \(visualState)")
            #endif
            return
        }
        if intent == .cleared {
            #if DEBUG
            print("[RadioPlayerCoordinator] post-clear cold launch — allowing initial playback (intent will be cleared by play())")
            #endif
        }

        // Reachability SSOT is DirectStreamingPlayer.hasInternetConnection (engine path monitor).
        // Caller (VC cold-launch path) gates on that flag before invoking this; we drive play only.

        streamingPlayer.resetTransientErrors()

        // ONE central call — play() waits on TuningSoundCoordinator until the special clip finishes.
        await SharedPlayerManager.shared.play()
    }

    // MARK: - Public shims (forwarded from VC's public API surface for SceneDelegate / widgets)
    /// Thin public shim for explicit "play" requests from SceneDelegate (lutheranradio://play),
    /// legacy widget URL schemes, and handleSwitchToLanguage.
    ///
    /// Delegates to the designated authoritative entry `SharedPlayerManager.userRequestedPlay()`.
    /// Previously duplicated the set+play sequence; now a one-line forward (semantics identical).
    ///
    /// - SeeAlso: ``SharedPlayerManager/userRequestedPlay()``,
    ///   ViewController.handlePlayAction,
    ///   RadioPlayerCoordinator.handleSwitchToLanguage,
    ///   CODING_AGENT.md (Single Source of Truth Principles).
    ///
    /// AGENT NOTE: Keep this shim thin. If ordering of configureNowPlaying vs. other
    /// MainActor work ever matters for a call site, evaluate here but prefer routing
    /// all explicit starts to userRequestedPlay.
    func handlePlayAction() {
        Task { @MainActor in
            await SharedPlayerManager.shared.userRequestedPlay()
        }
    }

    func handlePauseAction() {
        Task { @MainActor in
            await SharedPlayerManager.shared.stop()
            let newState = await SharedPlayerManager.shared.currentVisualState
            updateUI(for: newState)
        }
    }

    func handleTogglePlayback() {
        Task { @MainActor in
            await handleUserTogglePlayback()
        }
    }

    // Language / stream-switch orchestration (handleSwitchToLanguage, handleWidgetSwitchToLanguage,
    // switchToStreamFromWidget, handleLanguageSelection, completeStreamSwitch,
    // updateUserDefaultsLanguage, announceSwitchedToLanguage) lives in
    // RadioPlayerCoordinator+StreamSwitch.swift.

    // Pending-action drain (checkForPendingWidgetActions, play/pause debounce, widget
    // play/pause helpers, DEBUG seams) lives in RadioPlayerCoordinator+PendingActions.swift.

    // MARK: - Core orchestration (moved verbatim from ViewController with only ownership adjustments)

    /// Thin coordinator for explicit user toggle actions (in-app play/pause button,
    /// remote commands, Control Center, lock-screen toggle, `handleTogglePlayback` public
    /// shim, and legacy widget URL "play"/"pause" paths).
    ///
    /// Reads the current `PlayerVisualState` (SSOT) and dispatches to the appropriate
    /// manager action:
    /// - If actively playing: calls `stop()` (establishes sticky `.userPaused` immediately).
    /// - Else: pushes immediate `.prePlay` visual for responsive connecting feedback,
    ///   then routes through the designated explicit-play entry `userRequestedPlay()`.
    ///
    /// After the action, always refreshes UI + Now Playing info from the resulting
    /// authoritative state so that button chrome, status, metadata, and widget snapshots
    /// are consistent.
    ///
    /// - Precondition: Must be called on the @MainActor (enforced by declaration).
    /// - Postcondition: `currentVisualState` reflects the after-toggle value; UI and
    ///   NowPlaying have been driven from it.
    ///
    /// - Note: This is the *toggle decision surface* for explicit user actions. It is
    ///   deliberately distinct from internal continuation after an active playback intent
    ///   (see the resume branches of the canonical switch methods).
    ///
    /// - SeeAlso: ``SharedPlayerManager/userRequestedPlay()``,
    ///   ``SharedPlayerManager/stop()``,
    ///   `handlePlayAction()`,
    ///   `handleTogglePlayback()`,
    ///   `ViewController.togglePlayback()`,
    ///   `ViewController.handleTogglePlayback()`,
    ///   CODING_AGENT.md (Single Source of Truth Principles),
    ///   <doc:Architecture>.
    ///
    /// AGENT NOTE: handleUserTogglePlayback handles *explicit user toggles* (button/remote/LA-adjacent
    /// surfaces that flip play/pause based on current visual). It is not an "internal continuation"
    /// site. The two canonical switch orchestrators (`completeStreamSwitch`,
    /// `switchToStreamFromWidget`) read `isActivePlaybackIntent` themselves and, when resuming,
    /// call `SharedPlayerManager.play()` directly after `resetToPrePlayForNewStream`. Those
    /// paths must *not* be altered to use `userRequestedPlay()` or this toggle method.
    /// This method (and the surfaces that call it) must always terminate their play branch at
    /// `userRequestedPlay()`. Update the `///` docs on `userRequestedPlay`, the two canonicals,
    /// and the architecture block in `+StreamSwitch` together on any change to the explicit vs.
    /// continuation rule.
    @MainActor
    func handleUserTogglePlayback() async {
        let manager = SharedPlayerManager.shared
        let visualState = await manager.currentVisualState

        if visualState.isActivelyPlaying {
            await manager.stop()
            // isPlaying flag update is performed by the caller (VC) where it was previously mutated
        } else {
            // Route the play/resume case through the designated explicit-play entry point
            // (`userRequestedPlay`) for consistency with handlePlayAction, remote toggle,
            // Siri, LA toggle, widget pending reconciliation / media-transport mailbox, etc.
            // Immediate .prePlay is preserved (setUserIntentToPlay also establishes .prePlay
            // internally for resume-from-pause/clear cases) so connecting feedback timing is
            // unchanged. Trailing updateUI still runs after the await.
            self.updateUI(for: .prePlay)
            await manager.userRequestedPlay()
        }

        let newState = await manager.currentVisualState
        self.updateUI(for: newState)
    }

    // Stream-switch methods (handleLanguageSelection, completeStreamSwitch,
    // updateUserDefaultsLanguage) live in RadioPlayerCoordinator+StreamSwitch.swift.

    // Status / chrome distribution (updateUI, handleStatusChange, RadioPlayerChromeVisualResolver,
    // setIsSwitchingStream, syncMetadataToViewModel, updateUIForNoInternet, saveStateForWidget,
    // safeUpdateStatusLabel, thermal VoiceOver) lives in
    // RadioPlayerCoordinator+StatusDistribution.swift.

    func pausePlayback() {
        #if DEBUG
        print("[RadioPlayerCoordinator] pausePlayback called (lockscreen / remote command)")
        #endif

        Task { @MainActor in
            await SharedPlayerManager.shared.stop()
            let newState = await SharedPlayerManager.shared.currentVisualState
            self.updateUI(for: newState)
        }
    }

    func stopPlayback() {
        #if DEBUG
        print("[RadioPlayerCoordinator] stopPlayback called")
        #endif

        Task { @MainActor in
            await SharedPlayerManager.shared.stop()
            let newState = await SharedPlayerManager.shared.currentVisualState
            self.updateUI(for: newState)
        }
    }

    // MARK: - Haptics (tiny controller extraction P5+; thin forward only — behavior preserved)
    func playHapticFeedback(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        hapticsController.playHapticFeedback(style: style)
    }

    // Tuning sounds (playSpecialTuningSound, playTuningSound, stopTuningSound,
    // AVAudioPlayerDelegate finish paths) live in RadioPlayerCoordinator+Tuning.swift.

    // MARK: - Privacy clear (Clear local playback state)
    // Wired from the destructive action in PlaybackControlsView's sleep-timer `.confirmationDialog`
    // via `onClearLocalStateTapped`. Uses SSOT `clearAllLocalState` (engine stop + .cleared visual/
    // intent without persist, removes local UD keys, ends LA, forces no-widgets gate, posts
    // notification). Drives UI to .cleared (blue pill + clear_local_state_done) + reseeds language.
    // Post-clear cold launches behave like fresh installs (no snapshot => .prePlay path).

    @MainActor
    /// Triggers the privacy "Clear local state" flow.
    ///
    /// Shows a confirmation UIAlert (using `clear_local_state_*` strings), then on confirm:
    /// calls `SharedPlayerManager.clearAllLocalState()`, resets UI to `.cleared` (the visual that
    /// surfaces `clear_local_state_done` + blue), reseeds language, plays haptic, and posts a
    /// VoiceOver announcement so `clear_local_state_done` stays live in the localization catalog.
    ///
    /// Called from the SwiftUI sleep-timer dialog: `onClearLocalStateTapped`
    /// (`PlaybackControlsView` → `RadioPlayerView` → `ViewController`).
    ///
    /// - Note: Visibility is internal (not private) to support the SwiftUI wiring from ViewController.
    /// - SeeAlso: `PlaybackControlsView` (dialog destructive action),
    ///   `SharedPlayerManager.clearAllLocalState`, `localStateCleared(_:)`.
    func confirmAndClearLocalState() {
        let alert = UIAlertController(
            title: String(localized: "clear_local_state_title", table: "Localizable"),
            message: String(localized: "clear_local_state_message", table: "Localizable"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "ok", table: "Localizable"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "clear_local_state_confirm", table: "Localizable"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await SharedPlayerManager.clearAllLocalState()
                // Force-push the post-clear visual to the SwiftUI VM even if updateUI would
                // early-return due to lastAppliedVisualState. This guarantees the status pill
                // and PlayerVisualState surface reflect .cleared (blue + "Cleared") + the cleared intent after privacy clear.
                // Force both the last-applied guard and the VM so a post-clear status callback
                // or repeated .prePlay cannot skip the surface update.
                lastAppliedVisualState = nil
                if let vm = self.viewModel {
                    vm.visualState = .cleared
                }
                self.updateUI(for: .cleared)
                // Post-clear visual is .cleared (blue "Cleared" using clear_local_state_done) + .cleared intent (the actual blocker).
                // Sighted users now see explicit reset confirmation in the status pill (the reason .cleared visual exists).
                // The VO announcement is still posted for a11y catalog + non-sighted users.
                await self.resetLanguageSelectorToInitialLocale()
                self.playHapticFeedback(style: .heavy)

                // Post clear_local_state_done as a VoiceOver announcement so the entry stays
                // active in the catalog for all 29 languages and non-sighted users receive
                // confirmation. Sighted users see the .cleared status pill.
                // SAFETY: UIAccessibility.post is the established announcement mechanism (same
                // usage and @preconcurrency handling as announceSwitchedToLanguage).
                let doneMessage = String(localized: "clear_local_state_done", table: "Localizable")
                unsafe UIAccessibility.post(notification: .announcement, argument: doneMessage)
            }
        })
        // Schedule the secondary confirmation alert via DispatchQueue.main.async.
        // The presentAlert hook itself also wraps the real UIViewController.present in
        // another DispatchQueue.main.async. Together this ensures the UIKit alert is
        // not presented until after the current runloop turn (and the SwiftUI dialog
        // dismissal) has had a chance to clean up its layout containers.
        //
        // Without the deferral(s), we reliably see the 320pt vs ~366pt conflict:
        //   NSAutoresizingMaskLayoutConstraint (width == 320)
        //   _UIAlertControllerPhoneTVMacView width >=/== chains
        //   explicit UIView width == 366
        // when "Clear local state" is tapped during playback + widget refresh + bg updates.
        DispatchQueue.main.async { [weak self] in
            self?.presentAlert?(alert)
        }
    }

    @objc private func localStateCleared(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Keep local countdown display in sync (mirrors sleepTimerStateDidChange cancel path).
            // Primary UI reset + language reseed for the explicit dialog path lives in confirmAndClearLocalState.
            stopLocalSleepTimerDisplay()
        }
    }

    // MARK: - View layout forwarding helpers (called by VC)
    func notifyLayoutChange() {
        // languageSelectorView (SwiftUI uses VM) .notifyLayoutChange(currentSelectedIndex: selectedStreamIndex)
    }

    func viewDidAppearResurrectionCheck() async {
        let visualState = await SharedPlayerManager.shared.currentVisualState

        #if DEBUG
        print("[RadioPlayerCoordinator] viewDidAppear → currentVisualState = \(visualState)")
        #endif

        switch visualState {
        case .prePlay:
            #if DEBUG
            print("[RadioPlayerCoordinator] viewDidAppear → prePlay on cold launch → SKIPPING (handled in viewDidLoad after tuning)")
            #endif
        case .playing:
            #if DEBUG
            print("[RadioPlayerCoordinator] viewDidAppear → already playing, no action needed")
            #endif
        case .userPaused, .thermalPaused, .securityLocked:
            #if DEBUG
            print("[RadioPlayerCoordinator] viewDidAppear → \(visualState) → SKIPPING auto-play (resurrection prevented)")
            #endif
        case .prePlay where (await SharedPlayerManager.shared.currentPlaybackIntent == .cleared):
            // Post-clear launch: on fresh launch after clear there is no snapshot so we land on .prePlay;
            // the .cleared intent blocks recovery. The cold-launch Task (post-guard) will drive the success path.
            #if DEBUG
            print("[RadioPlayerCoordinator] viewDidAppear → prePlay with .cleared intent (post-clear) → SKIPPING (cold launch will proceed)")
            #endif
        case .cleared:
            // In-process post-clear: visual .cleared (blue) is shown; intent blocks. Same skip for auto-play.
            #if DEBUG
            print("[RadioPlayerCoordinator] viewDidAppear → .cleared (post privacy clear) → SKIPPING (explicit play required)")
            #endif

        @unknown default:
            #if DEBUG
            print("[RadioPlayerCoordinator] viewDidAppear → unknown visualState → SKIPPING auto-play")
            #endif
        }

        await syncSleepTimerDisplayFromActorIfNeeded()
    }

    // MARK: - Memory / energy / misc (forwarded hooks)
    func handleMemoryWarning() {
        backgroundImageController.clearCache()
        #if DEBUG
        print("[RadioPlayerCoordinator] Requested background image cache clear (handled by BackgroundImageController)")
        #endif
    }

    func updateForEnergyEfficiency() {
        backgroundImageController.updateForEnergyEfficiency()
    }

    // handleStatusChange + RadioPlayerChromeVisualResolver live in
    // RadioPlayerCoordinator+StatusDistribution.swift.

    // MARK: - Deinit cleanup for coordinator-owned observers
    deinit {
        sleepTimerDisplayTask?.cancel()
        // Cancel SSOT chrome observation without hopping to MainActor (Task.cancel is
        // nonisolated). Stream onTermination removes the multi-cast subscription.
        visualChromeObservationTask?.cancel()
        NotificationCenter.default.removeObserver(
            self,
            name: SleepTimerNotification.stateDidChange,
            object: nil
        )
        #if DEBUG
        print("[RadioPlayerCoordinator] deinit completed")
        #endif
    }
}

