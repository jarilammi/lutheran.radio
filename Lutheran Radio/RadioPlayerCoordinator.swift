//
//  RadioPlayerCoordinator.swift
//  Lutheran Radio
//
//  Lightweight @MainActor orchestration layer (introduced during ViewController decomposition).
//  Owns wiring of the extracted presentational components (LanguageSelectorView, BackgroundImageController,
//  PlaybackControlsView, NowPlayingMetadataView), the full stream-selection flows, distribution of every
//  visual/metadata/background update, sleep-timer UI state machine glue (notification observer + sync +
//  countdown Task + preset/cancel handling + sync to VM), haptics triggering, and initial-setup sequencing.
//
//  Sleep timer: presentation migrated to SwiftUI .confirmationDialog in PlaybackControlsView.
//  Dialog now includes presets + conditional Cancel + always-present "Clear local state" (privacy).
//  All logic (handleSleepTimer*, confirmAndClearLocalState, begin/stop display, etc.) stays here.
//  The legacy configureSleepTimerButtonMenu UIMenu builder is intentionally preserved (still called
//  from glue paths) per requirements; it no longer drives visible UI.
//
//  ViewController remains the thin lifecycle host + view hierarchy builder + public intent shims
//  (for SceneDelegate, widgets, remote commands) + hard-to-move observers (network, interruptions, route,
//  Darwin listener setup, deinit CF cleanup). Orchestration owned here (not on VC):
//  - Pending-action drain (App Group mailbox → play/pause/switch)
//  - selectedStreamIndex + language selection / stream-switch
//  - Sleep-timer interaction window + deferred ICY metadata apply
//  - DirectStreamingPlayer.onMetadataChange registration
//  - Cold-launch special tuning (TuningSoundCoordinator gate) + stream-switch tuning delight
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
//  Created by Jari Lammi on 13.6.2026.
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
/// or SceneDelegate become-active / foreground / launch burst. Play and pause share the media-transport
/// mailbox; same-direction debounce (0.65 s) drops thrash while opposite verbs always run; UITestMode
/// clears without executing unless the DEBUG bypass is set. Lifecycle hosts call
/// ``checkForPendingWidgetActions()`` only — they do not reimplement debounce or mailbox enqueue.
///
/// **Stream index:** Single owner of `selectedStreamIndex` (wired to `PlayerViewModel` and all
/// language / widget / stream-switch paths). The host does not mirror this value.
///
/// **Metadata:** Registers `DirectStreamingPlayer.onMetadataChange` in ``wireAndInitialSetup()`` and
/// owns the sleep-timer interaction window that defers Now Playing title apply during modal settle.
///
/// **Special tuning:** Production cold-launch clip is ``playSpecialTuningSound(completion:)`` here —
/// session/clip start via ``DirectStreamingPlayer/startLocalClipPlayer``, finish via
/// `AVAudioPlayerDelegate` → ``TuningSoundCoordinator``. Stream-switch delight uses
/// ``playTuningSound(animateNeedleTo:)`` (duration-based; no main-stream gate).
///
/// Sleep timer note: coordinator is the single owner of timer logic (set/cancel + countdown glue +
/// interaction windows + VM sync). SwiftUI (PlaybackControlsView) owns only the .confirmationDialog
/// presentation and calls back via PlayerViewModel closures. configureSleepTimerButtonMenu is retained.
///
/// - SeeAlso: ``SharedPlayerManager/signalWidgetPendingAction(visualState:action:language:)``,
///   ``SharedPlayerManager/submitMediaTransportCommandAndWait(_:)``,
///   `TuningSoundCoordinator`, docs/Live-Activity-Stacking-and-Media-Surfaces.md,
///   docs/Widget-Functionality-Roadmap.md, CODING_AGENT.md (Single Source of Truth Principles).
@MainActor
final class RadioPlayerCoordinator: NSObject, AVAudioPlayerDelegate {

    // MARK: - Owned sub-components
    // LanguageSelectorView, PlaybackControlsView, NowPlayingMetadataView are now pure SwiftUI
    // and driven exclusively via the PlayerViewModel (pushed here, actions forwarded).
    // Background and streaming remain.
    private let backgroundImageController: BackgroundImageController
    private let hapticsController = HapticsController()
    nonisolated private let streamingPlayer: DirectStreamingPlayer

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

    /// Optional hook for the SwiftUI sleep timer button tap.
    ///
    /// Primary path: `PlaybackControlsView` presents its own `.confirmationDialog`; choices
    /// arrive via `PlayerViewModel` action closures (`onSleepTimerPresetSelected` /
    /// `onSleepTimerCancelSelected`) wired to `handleSleepTimerPresetSelected` /
    /// `handleSleepTimerCancelSelected`. When set, `RadioPlayerView` may also call
    /// `configureSleepTimerButtonMenu()` through this hook for menu configuration.
    var onSleepTimerButtonTapped: (() -> Void)?

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
    private var lastAppliedVisualState: PlayerVisualState?

    private var hasShownSecurityAlert = false
    private var hasPlayedSpecialTuningSound = false
    private var isTuningSoundPlaying = false
    private var tuningPlayer: AVAudioPlayer?
    private var lastTuningSoundTime: Date?
    private var hasEverPlayed = false

    // Stream switch debounce + cancellation (verbatim)
    private var streamSwitchWorkItem: DispatchWorkItem?
    private var streamSwitchTask: Task<Void, Never>?
    private var lastStreamSwitchTime: Date?
    private let streamSwitchDebounceInterval: TimeInterval = 1.0

    // Sleep timer UI glue state + Task (verbatim; deep coupling to SharedPlayerManager + SleepTimer remains)
    private var sleepTimerDisplayTask: Task<Void, Never>?
    private var cachedSleepTimerRemaining: Int?
    /// True while sleep-timer dialog settle is in flight; defers Now Playing title apply.
    private var isSleepTimerInteractionActive = false
    /// Metadata stashed during the interaction window; applied in ``finishSleepTimerInteraction``.
    private var pendingMetadataVisualRefresh: String?
    private static let sleepTimerMenuSettleNs: UInt64 = 250_000_000
    private static let sleepTimerPostScheduleUISettleNs: UInt64 = 300_000_000
    private static let sleepTimerDeferredVisualSettleNs: UInt64 = 500_000_000

    // Widget switch work item + last-switch stamp (actionId dedup uses processedActionIds below).
    private var lastWidgetSwitchTime: Date?
    private var pendingWidgetSwitchWorkItem: DispatchWorkItem?

    // Widget / extension-hosted play/pause drain debouncing (owned with checkForPendingWidgetActions).
    // Same-direction repeats within the interval are dropped (AVFoundation thrash guard).
    // Opposite verbs always execute so a rapid play→pause (or pause→play) flip is not lost
    // after optimistic Live Activity / home-widget chrome already acknowledged the second tap.
    private var lastWidgetActionTime: Date = .distantPast
    /// Last executed pending verb for play/pause drain (`"play"` or `"pause"`).
    private var lastWidgetPlayPauseAction: String?
    private let widgetActionDebounceInterval: TimeInterval = 0.65

    /// Dedup set for widget-originated action IDs (switch path + drain bookkeeping).
    /// Legacy URL-scheme `handleWidgetAction` on ViewController keeps a separate set for that surface only.
    private var processedActionIds: Set<String> = []

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
            // Wire sleep timer actions. The SwiftUI .confirmationDialog in PlaybackControlsView
            // calls these; the coordinator owns the full preset/cancel + settle + display + SPM logic.
            vm.onSleepTimerPresetSelected = { [weak self] minutes in
                self?.handleSleepTimerPresetSelected(minutes: minutes)
            }
            vm.onSleepTimerCancelSelected = { [weak self] in
                self?.handleSleepTimerCancelSelected()
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

        // Sleep timer observer (glue)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sleepTimerStateDidChange(_:)),
            name: SleepTimerNotification.stateDidChange,
            object: nil
        )

        // ICY metadata → VM + Now Playing (single owner; sleep interaction defers title apply).
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
                    self.syncMetadataToViewModel(metadata)
                    if self.isSleepTimerInteractionActive {
                        self.pendingMetadataVisualRefresh = metadata
                    } else {
                        self.updateNowPlayingInfo(title: metadata)
                    }
                } else {
                    self.syncMetadataToViewModel(nil)
                    if !self.isSleepTimerInteractionActive {
                        self.updateNowPlayingInfo()
                    }
                }
                self.saveStateForWidget()
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
    /// Owns the resurrection guard + SharedPlayerManager.play() launch for cold start (prePlay path).
    func performColdLaunchPlaybackIfAllowed(initialStream: DirectStreamingPlayer.Stream) async {
        // Ensure snapshot + intent are authoritative before deciding cold auto-play.
        await SharedPlayerManager.shared.refreshVisualStateFromPersistence()
        let visualState = await SharedPlayerManager.shared.currentVisualState
        let intent = await SharedPlayerManager.shared.currentPlaybackIntent
        let postTerm = SharedPlayerManager.hasExplicitTerminationSentinel()
        #if DEBUG
        print("[RadioPlayerCoordinator] performColdLaunch... visual=\(visualState), intent=\(intent), postTerm=\(postTerm)")
        #endif

        // Hard blocker: sticky intent OR explicit termination sentinel (lastUpdateTime==0).
        // This is the combined policy that must hold on every wake / LA-visible / power-up path.
        // Widgets/Live Activities may show last-known or passive UI; no DirectStreamingPlayer side effects.
        if intent.isStickyPauseOrLock || postTerm {
            #if DEBUG
            print("[RadioPlayerCoordinator] Blocked cold-launch playback — \(postTerm ? "termination sentinel" : "sticky intent")")
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

        // VC still owns hasInternetConnection flag for this guard (network observer stays in host for now)
        // The caller (VC) performs the hasInternetConnection check before invoking this.
        // We simply drive the play here.

        streamingPlayer.cancelPendingSSLProtection()
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

    /// External / Siri / deep-link / shortcut driven language switch entry point.
    ///
    /// Performs engine prep via `DirectStreamingPlayer.switchToStream`, plays the
    /// special tuning sound + needle animation (unlike pure widget reconciliation),
    /// respects current playback intent, and ends by announcing the switch to
    /// VoiceOver via `announceSwitchedToLanguage`.
    ///
    /// - Parameter languageCode: Target ISO code (must match one of the 5 streams).
    ///
    /// - SeeAlso: `completeStreamSwitch`, `switchToStreamFromWidget(to:index:actionId:)`,
    ///   `announceSwitchedToLanguage(_:)`, SceneDelegate (URL handling),
    ///   RadioPlaybackIntents (related Siri flow).
    func handleSwitchToLanguage(_ languageCode: String) {
        Task { @MainActor in
            #if DEBUG
            print("[RadioPlayerCoordinator] handleSwitchToLanguage started for: \(languageCode)")
            #endif

            guard let targetStream = DirectStreamingPlayer.availableStreams.first(where: { $0.languageCode == languageCode }),
                  let targetIndex = DirectStreamingPlayer.availableStreams.firstIndex(where: { $0.languageCode == languageCode }) else {
                #if DEBUG
                print("[RadioPlayerCoordinator] handleSwitchToLanguage: target stream not found for \(languageCode)")
                #endif
                return
            }

            selectedStreamIndex = targetIndex
            viewModel?.selectedStreamIndex = targetIndex
            backgroundImageController.update(for: targetStream)
            setIsSwitchingStream(true)
            defer { setIsSwitchingStream(false) }

            #if DEBUG
            print("[RadioPlayerCoordinator] handleSwitchToLanguage — engine prep via switchToStream")
            #endif
            await streamingPlayer.switchToStream(targetStream)

            #if DEBUG
            print("[RadioPlayerCoordinator] Playing tuning sound (external switch path)")
            #endif
            await playTuningSound(animateNeedleTo: targetIndex)

            updateUserDefaultsLanguage(targetStream.languageCode)

            // SwiftUI selector observes viewModel.selectedStreamIndex (matchedGeometryEffect animates)

            if await SharedPlayerManager.shared.canProceedWithPlayback() {
                let intent = await SharedPlayerManager.shared.currentPlaybackIntent
                await SharedPlayerManager.shared.resetToPrePlayForNewStream(
                    preserveActiveSleepTimer: intent == .sleepTimer,
                    connectingLanguageCode: targetStream.languageCode
                )
                updateUI(for: .prePlay)
            }

            if await SharedPlayerManager.shared.canProceedWithPlayback() {
                #if DEBUG
                print("[RadioPlayerCoordinator] ▶ Starting playback after switch (intent allows)")
                #endif

                try? await Task.sleep(for: .seconds(0.5))

                handlePlayAction()
            } else {
                #if DEBUG
                print("[RadioPlayerCoordinator] ⏸ Intent blocks playback after switch (userPaused, securityLocked, or cleared)")
                #endif
                updateUI(for: .userPaused)
            }

            announceSwitchedToLanguage(targetStream)

            #if DEBUG
            print("[RadioPlayerCoordinator] handleSwitchToLanguage completed for \(languageCode)")
            #endif
        }
    }

    /// Entry point for widget / Live Activity / pending-action reconciliation of a stream/language switch.
    ///
    /// Performs guard, deduplication, and debounce, then delegates to the canonical
    /// `switchToStreamFromWidget(to:index:actionId:)` for the actual engine + intent + play orchestration.
    /// Never plays tuning sound or animates the needle (those are main-app flag-tap only).
    ///
    /// - Parameters:
    ///   - languageCode: Target stream language code (e.g. "en", "fi").
    ///   - actionId: Unique ID for this pending widget action (used for dedup + clearing).
    ///
    /// - Important: Must respect `currentPlaybackIntent`. Does not auto-resume when user has
    ///   an explicit `.userPaused` (or `.securityLocked` / `.cleared`).
    ///
    /// - SeeAlso: `switchToStreamFromWidget(to:index:actionId:)`, `completeStreamSwitch`,
    ///   `DirectStreamingPlayer.switchToStream`, `SharedPlayerManager.currentPlaybackIntent`,
    ///   `SharedPlayerManager.resetToPrePlayForNewStream`, `SharedPlayerManager.play`,
    ///   CODING_AGENT.md (Single Source of Truth Principles + "Cross-target shared source files"),
    ///   <doc:Architecture>.
    ///
    /// AGENT NOTE: handleWidgetSwitchToLanguage is the *only* public entry for widget-driven
    /// language changes into the main app. The actionId/processed/debounce wrapper must stay here.
    /// Core orchestration (reset/switchToStream/play sequencing) lives in the private canonical below.
    /// Update both this doc and the canonical on any change to the widget path.
    func handleWidgetSwitchToLanguage(_ languageCode: String, actionId: String) {
        guard !processedActionIds.contains(actionId) else { return }
        processedActionIds.insert(actionId)

        // Always process the latest widget language selection (cancel any prior pending workItem).
        // The 2 s debounce is removed because:
        // - processedActionIds already dedups exact re-deliveries of the same actionId
        // - workItem cancel + last dispatch wins for rapid different-lang selections (the
        //   exact "paused sv -> en" flow).
        // - For paused state a language choice must be applied so the subsequent play uses it
        //   (see alignment in play() + setUserIntentToPlay).
        // Rapid hammering protection is still provided by the engine (switchToStream silent path)
        // and the blocked/no-auto-resume logic inside switchToStreamFromWidget.
        lastWidgetSwitchTime = Date()

        pendingWidgetSwitchWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            Task { @MainActor in
                self.setIsSwitchingStream(true)
                defer { self.setIsSwitchingStream(false) }

                guard let targetStream = DirectStreamingPlayer.availableStreams.first(where: { $0.languageCode == languageCode }),
                      let targetIndex = DirectStreamingPlayer.availableStreams.firstIndex(where: { $0.languageCode == languageCode }) else {
                    #if DEBUG
                    print("[RadioPlayerCoordinator] Widget switch: target stream not found for \(languageCode)")
                    #endif
                    // Still clear the action to avoid it sticking around.
                    SharedPlayerManager.shared.clearPendingAction(actionId: actionId)
                    return
                }

                await self.switchToStreamFromWidget(to: targetStream, index: targetIndex, actionId: actionId)
            }
        }

        pendingWidgetSwitchWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    /// Canonical (silent) stream-switch orchestration for widget and Live Activity reconciliation.
    ///
    /// This is the non-tuning, non-animating counterpart to `completeStreamSwitch`. It is the
    /// single place that reconciles an optimistic widget/LA language choice (signaled via
    /// `signalWidgetSwitchAction` + Darwin "switch" pending) with the authoritative engine
    /// and main-app visual/intent state.
    ///
    /// Responsibilities (executed in order):
    /// 1. Read `currentPlaybackIntent` once at entry and derive `shouldResumeAfterSwitch`
    ///    (`isActivePlaybackIntent`).
    /// 2. If resuming: `resetToPrePlayForNewStream` + Connecting UI **before** engine teardown
    ///    so Live Activity never stays `.playing` mid silent stop (symmetric with
    ///    `completeStreamSwitch`).
    /// 3. Engine preparation exclusively via `DirectStreamingPlayer.switchToStream(_:)`
    ///    (the SSOT: model update, transient reset, awaited stop for lang change, counter reset).
    /// 4. Mirror selection + language snapshot + LA language mirror + media-surface refresh.
    /// 5. If `!shouldResumeAfterSwitch`: clear soft-pause stash, force `.userPaused` visual,
    ///    announce, clear the `actionId`, and return (no playback started).
    /// 6. If resuming: `SharedPlayerManager.play()` (hold already active). Stream failure leaves
    ///    intent active (`.shouldBePlaying` / `.sleepTimer`), so this path auto-resumes without
    ///    an extra play tap.
    /// 7. Announce + clear pending `actionId`.
    ///
    /// **Direct `play()` rule (authoritative):** The call to `play()` in the resume branch is
    /// the *internal continuation in the active-intent resume branch* (after `isActivePlaybackIntent`
    /// was already true). It is one of the four explicitly permitted direct `play()` sites
    /// (see `userRequestedPlay` Precondition).
    /// All *explicit* user play/resume requests (widget play pending, toggle buttons, remote
    /// commands, Siri Play, LA start, security retry, etc.) must go through `userRequestedPlay()`.
    /// This site must **not** be changed to `userRequestedPlay()`; doing so would blur the
    /// distinction, risk overriding concurrent pause intents, and break symmetry with
    /// `completeStreamSwitch`. See the Precondition on `userRequestedPlay()` (permitted
    /// direct `play()` cases) and the matching rule on `completeStreamSwitch`.
    ///
    /// - Parameters:
    ///   - stream: Target stream chosen by the widget/LA action.
    ///   - index: Index of `stream` in `DirectStreamingPlayer.availableStreams` (used for
    ///            selector + background sync only).
    ///   - actionId: The pending action identifier from the widget signal (used for dedup
    ///               and to clear the transient command after reconciliation).
    ///
    /// - Precondition: Caller must have set `streamingPlayer.isSwitchingStream = true`
    ///   for the duration (this method does not own the flag). Must run on the @MainActor.
    /// - Postcondition: Engine model and UI selection reflect `stream`. If the pre-switch
    ///   intent was active, playback proceeds (or is initiated) for the new stream; otherwise
    ///   the selection is left in `.userPaused`. The `actionId` has been cleared.
    ///
    /// - Important: This method **never** plays the tuning sound and never animates the
    ///   needle. Those effects are owned exclusively by `completeStreamSwitch`.
    /// - Important: Widget switch semantics deliberately differ from Siri
    ///   `SwitchToLanguageIntent`: the latter always forces playback via `userRequestedPlay()`
    ///   after its switch (imperative "play in X"). Widget reconciliation preserves the
    ///   paused/playing choice that was current at the moment the widget action was issued.
    ///
    /// - SeeAlso: `completeStreamSwitch`,
    ///   `handleWidgetSwitchToLanguage`,
    ///   `DirectStreamingPlayer.switchToStream`,
    ///   ``SharedPlayerManager/play()``,
    ///   ``SharedPlayerManager/userRequestedPlay()``,
    ///   ``SharedPlayerManager/resetToPrePlayForNewStream(preserveActiveSleepTimer:)``,
    ///   ``SharedPlayerManager/markPlaybackStoppedByStreamFailure(_:)``,
    ///   ``SharedPlayerManager/currentPlaybackIntent``,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§6.12, §10),
    ///   CODING_AGENT.md (Single Source of Truth Principles),
    ///   <doc:Architecture>.
    ///
    /// AGENT NOTE: switchToStreamFromWidget + completeStreamSwitch are the two canonical
    /// stream-choice orchestrators. Both use the identical pattern for the resume case:
    /// read isActivePlaybackIntent → guard → resetToPrePlayForNewStream (if resuming) →
    /// direct `play()`. This is *not* an explicit request site. Update this `///`, the
    /// parallel doc on `completeStreamSwitch`, the architecture block comment, the
    /// userRequestedPlay Precondition, and the resurrection table together on any change.
    /// The justification for keeping the direct call (resurrection guards, race behavior,
    /// explicit-vs-continuation distinction, symmetry with completeStreamSwitch) lives in
    /// these `///` headers and the Precondition.
    private func switchToStreamFromWidget(to stream: DirectStreamingPlayer.Stream, index: Int, actionId: String) async {
        let playbackIntent = await SharedPlayerManager.shared.currentPlaybackIntent
        let shouldResumeAfterSwitch = playbackIntent.isActivePlaybackIntent

        // Connecting chrome **before** silent engine teardown, with destination language so Live
        // Activity never shows `.playing` mid-switch and never shows prior-language chrome for one
        // content push while visual is already Connecting (symmetric with completeStreamSwitch).
        if shouldResumeAfterSwitch {
            await SharedPlayerManager.shared.resetToPrePlayForNewStream(
                preserveActiveSleepTimer: playbackIntent == .sleepTimer,
                connectingLanguageCode: stream.languageCode
            )
            updateUI(for: .prePlay)
        }

        // Engine prep via the SSOT. Replaces all prior manual setSelected + reset + stop sites
        // on the widget path.
        await streamingPlayer.switchToStream(stream)

        selectedStreamIndex = index
        backgroundImageController.update(for: stream)
        // Session snapshot language after engine model prep (LA language already on hold when resuming).
        updateUserDefaultsLanguage(stream.languageCode)
        SharedPlayerManager.persistLiveActivityLanguageMirror(stream.languageCode)
        #if LUTHERAN_MAIN_APP
        await SharedPlayerManager.shared.refreshAllMediaSurfaces(liveActivity: .updateIfActive)
        #endif

        viewModel?.selectedStreamIndex = index // migrated from // languageSelectorView (SwiftUI uses VM) .setSelectedIndex(index, animated: true, caller: "widgetSwitch")

        guard shouldResumeAfterSwitch else {
            #if DEBUG
            print("[RadioPlayerCoordinator] [Widget Switch] Blocked — userPaused, no auto-resume")
            #endif
            await SharedPlayerManager.shared.clearSoftPauseMetadataStashForLanguageChange()
            viewModel?.selectedStreamIndex = index // migrated from // languageSelectorView (SwiftUI uses VM) .setSelectedIndex(index, caller: "widgetSwitch-paused")
            updateUI(for: .userPaused)
            announceSwitchedToLanguage(stream)
            SharedPlayerManager.shared.clearPendingAction(actionId: actionId)
            return
        }

        #if DEBUG
        print("[RadioPlayerCoordinator] ▶ [Widget Switch] Starting new stream using SharedPlayerManager.play() — main app path")
        #endif

        // Direct `play()` after prePlay hold + engine prep. Permitted internal continuation
        // when playback intent was already active — do not route to `userRequestedPlay()`.
        await SharedPlayerManager.shared.play()

        #if DEBUG
        print("[RadioPlayerCoordinator] Widget switch: SharedPlayerManager.play() succeeded")
        print("[RadioPlayerCoordinator] Widget switch completed (authoritative save covered by play())")
        #endif

        announceSwitchedToLanguage(stream)
        SharedPlayerManager.shared.clearPendingAction(actionId: actionId)
    }

    // MARK: - Pending-action drain (App Group mailbox → engine)

    /// Whether a widget/extension play or pause pending should execute under the same-direction debounce.
    ///
    /// - Parameter action: `"play"` or `"pause"`.
    /// - Returns: `false` only when the same verb ran within ``widgetActionDebounceInterval``;
    ///   opposite verbs and the first verb after the window always return `true`.
    /// - Note: Pending is already cleared before this check so a dropped same-direction
    ///   repeat cannot stick in the App Group. Opposite taps must not be dropped: extension
    ///   hosts publish optimistic chrome before Darwin drain, and a dropped opposite leaves
    ///   chrome and engine permanently skewed until the next user action.
    /// - SeeAlso: ``checkForPendingWidgetActions()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    private func shouldExecuteWidgetPlayPauseAction(_ action: String) -> Bool {
        let elapsed = Date().timeIntervalSince(lastWidgetActionTime)
        if elapsed > widgetActionDebounceInterval {
            return true
        }
        if let last = lastWidgetPlayPauseAction, last == action {
            return false
        }
        return true
    }

    /// Records the wall-clock and verb of a play/pause pending that will execute.
    private func recordWidgetPlayPauseAction(_ action: String) {
        lastWidgetActionTime = Date()
        lastWidgetPlayPauseAction = action
    }

    /// Drains one App Group pending action written by the widget extension / Control widget /
    /// extension-hosted Live Activity intent (play, pause, or switch).
    ///
    /// **Single owner:** Lifecycle hosts (Darwin listener on `ViewController`, SceneDelegate
    /// become-active / foreground, launch 1…5 s burst) call this method only. Debounce,
    /// UITestMode drain-without-execute, mailbox enqueue, and switch work-item cancel live here.
    ///
    /// **Cross-process latency path (extension host):**
    /// 1. Extension writes optimistic snapshot / LA ContentState + `pendingAction*` and posts
    ///    Darwin `radio.lutheran.widget.action` (`notifyMainApp`).
    /// 2. Main app receives Darwin (or SceneDelegate become-active / launch burst) and calls
    ///    this method (via the thin VC public shim when needed).
    /// 3. Play and pause execute on the serial ``MediaTransportCommand`` mailbox so a rapid
    ///    opposite drain can preempt an in-flight play the same way headset remotes do.
    ///
    /// **Debounce:** same-direction play/pause only (``shouldExecuteWidgetPlayPauseAction``);
    /// opposite verbs always run. UITestMode still drains without executing unless the DEBUG
    /// pending-action bypass is set.
    ///
    /// - Note: Relies on `DirectStreamingPlayer.isSwitchingStream` (set to `internal`) to
    ///   coordinate stream switches and suppress unnecessary "stopped" status updates during
    ///   transitions.
    /// - SeeAlso: ``SharedPlayerManager/submitMediaTransportCommandAndWait(_:)``,
    ///   ``SharedPlayerManager/signalWidgetPendingAction(visualState:action:language:)``,
    ///   ``handleWidgetPauseAction()``,
    ///   ``MediaTransportLatencyTimeline`` (DEBUG drain milestones),
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   docs/Widget-Functionality-Roadmap.md
    func checkForPendingWidgetActions() {
        // UITestMode defense-in-depth.
        // Even if a prior killed test session (or manual run) left a "play"/"pause" pendingAction
        // or Darwin notification in the shared App Group, do not interpret it as user input.
        // This prevents the "background test sessions would be interpreted as user input"
        // scenario that leaves the host in yellow .prePlay "connecting" state and stalls the
        // test runner. We still drain the pending key so the next real run starts clean.
        if SharedPlayerManager.isRunningInUITestMode {
            #if DEBUG
            if unsafe Self._test_bypassUITestModeForPendingActionProcessing {
                // Unit-test host: exercise the real play/pause drain contract (see WidgetIntentContractTests).
            } else {
                if let pending = SharedPlayerManager.shared.getPendingActionIfFresh(maxAge: 30.0) {
                    SharedPlayerManager.shared.clearPendingAction(actionId: pending.actionId)
                    print("[RadioPlayerCoordinator] UITestMode — cleared stale pending \(pending.action) without executing (avoids killed-session user input interpretation)")
                }
                return
            }
            #else
            if let pending = SharedPlayerManager.shared.getPendingActionIfFresh(maxAge: 30.0) {
                SharedPlayerManager.shared.clearPendingAction(actionId: pending.actionId)
            }
            return
            #endif
        }

        guard let pending = SharedPlayerManager.shared.getPendingActionIfFresh(maxAge: 30.0) else {
            return
        }

        let pendingAction = pending.action
        let pendingLanguage = pending.parameter
        let actionId = pending.actionId

        #if DEBUG
        print("[RadioPlayerCoordinator] Found pending action: \(pendingAction), ID: \(actionId)")
        print("[RadioPlayerCoordinator] Pending language: \(pendingLanguage ?? "nil")")
        MediaTransportLatencyTimeline.mark(
            .pendingActionDrainEntered,
            detail: "action=\(pendingAction) id=\(actionId)"
        )
        #endif

        // Clear action immediately to prevent re-processing
        SharedPlayerManager.shared.clearPendingAction(actionId: actionId)

        switch pendingAction {
        case "switch":
            if let languageCode = pendingLanguage {
                #if DEBUG
                print("[RadioPlayerCoordinator] Executing widget switch action to language: \(languageCode)")
                #endif
                handleWidgetSwitchToLanguage(languageCode, actionId: actionId)
            } else {
                #if DEBUG
                print("[RadioPlayerCoordinator] Switch action missing language code - pendingLanguage was nil")
                #endif
            }
        case "play":
            #if DEBUG
            print("[RadioPlayerCoordinator] Executing widget play action")
            #endif

            // Same-direction debounce only — opposite pause after a rapid flip must run.
            guard shouldExecuteWidgetPlayPauseAction("play") else {
                #if DEBUG
                print("[RadioPlayerCoordinator] Widget play debounced (same-direction within \(widgetActionDebounceInterval)s)")
                MediaTransportLatencyTimeline.mark(
                    .pendingActionDrainDebounced,
                    detail: "action=play"
                )
                #endif
                return
            }
            recordWidgetPlayPauseAction("play")

            // Widget play: clear any user pause lock then play. Do NOT reset to prePlay here
            // (resetToPrePlayForNewStream is only for language stream switches).
            // Engine work goes through the media-transport mailbox so a following pause
            // pending (or headset pause) can preempt an in-flight attach — same ordering as
            // system Now Playing and main-hosted Live Activity toggles.
            Task { @MainActor [weak self] in
                #if DEBUG
                MediaTransportLatencyTimeline.mark(.pendingActionDrainPlayStarted)
                #endif
                // If a widget switch was recently scheduled (to select a lang while paused) and a play
                // tap followed immediately, cancel the deferred switch workItem. Its selection effect
                // is now covered by the alignment inside play() + the sync below; letting the workItem
                // run could issue a late stop() on the stream we just started.
                // (Work item is owned here — not on the lifecycle host.)
                self?.pendingWidgetSwitchWorkItem?.cancel()
                self?.pendingWidgetSwitchWorkItem = nil

                await SharedPlayerManager.shared.submitMediaTransportCommandAndWait(.play)

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

                #if DEBUG
                MediaTransportLatencyTimeline.mark(.pendingActionDrainPlayFinished)
                #endif

                guard let self else { return }
                let playingLang = DirectStreamingPlayer.shared.selectedStream.languageCode
                if let targetIndex = DirectStreamingPlayer.availableStreams.firstIndex(where: { $0.languageCode == playingLang }) {
                    if self.selectedStreamIndex != targetIndex {
                        self.selectedStreamIndex = targetIndex
                    }
                    self.viewModel?.selectedStreamIndex = targetIndex
                }
            }
        case "pause":
            #if DEBUG
            print("[RadioPlayerCoordinator] Executing widget pause action")
            #endif

            // Same-direction debounce only — opposite play after a rapid flip must run.
            guard shouldExecuteWidgetPlayPauseAction("pause") else {
                #if DEBUG
                print("[RadioPlayerCoordinator] Widget pause debounced (same-direction within \(widgetActionDebounceInterval)s)")
                MediaTransportLatencyTimeline.mark(
                    .pendingActionDrainDebounced,
                    detail: "action=pause"
                )
                #endif
                return
            }
            recordWidgetPlayPauseAction("pause")

            // Single MainActor Task: already-.userPaused ignore + coordinator pause (mailbox).
            // Avoids a nested Task hop that previously delayed engine silence after Darwin.
            Task { @MainActor [weak self] in
                guard let self else { return }
                #if DEBUG
                MediaTransportLatencyTimeline.mark(.pendingActionDrainPauseStarted)
                #endif
                let vs = await SharedPlayerManager.shared.currentVisualState
                if vs == .userPaused {
                    #if DEBUG
                    print("[RadioPlayerCoordinator] Widget pause ignored — already .userPaused (prevents double-pause resurrection races)")
                    MediaTransportLatencyTimeline.mark(
                        .pendingActionDrainPauseFinished,
                        detail: "result=alreadyUserPaused"
                    )
                    #endif
                    return
                }
                await self.handleWidgetPauseAction()
                #if DEBUG
                MediaTransportLatencyTimeline.mark(.pendingActionDrainPauseFinished)
                #endif
            }
        default:
            #if DEBUG
            print("[RadioPlayerCoordinator] Unknown pending action: \(pendingAction)")
            #endif
        }

        // Bound switch-path dedup memory (keep only last 10 action IDs).
        if processedActionIds.count > 10 {
            let sortedIds = Array(processedActionIds).suffix(10)
            processedActionIds = Set(sortedIds)
        }
    }

    // Widget play/pause action helpers (no tuning sounds)
    /// Vestigial shim retained for any remaining direct callers.
    ///
    /// Now delegates to `userRequestedPlay()` (the designated explicit-play path).
    /// Previously performed only `clearUserPausedLockIfNeeded() + play()` (weaker;
    /// bypassed full `setUserIntentToPlay` double-save + NowPlaying configure).
    /// Primary widget "play" path is ``checkForPendingWidgetActions()`` → media-transport mailbox.
    ///
    /// - SeeAlso: ``SharedPlayerManager/userRequestedPlay()``,
    ///   ``checkForPendingWidgetActions()``,
    ///   CODING_AGENT.md.
    ///
    /// AGENT NOTE: Prefer the pending + checkForPending + mailbox route for
    /// all widget-originated play. If this shim is ever removed, audit call sites
    /// (currently none outside comments) and update the resurrection table comment.
    func handleWidgetPlayAction() {
        #if DEBUG
        print("[RadioPlayerCoordinator] Widget Play action → routing via designated userRequestedPlay()")
        #endif

        Task { @MainActor in
            await SharedPlayerManager.shared.userRequestedPlay()
            #if DEBUG
            print("[RadioPlayerCoordinator] Widget Play (via userRequestedPlay) completed")
            #endif
        }
    }

    /// Executes a widget/extension-originated pause after main-app pending drain.
    ///
    /// Clears a stale opposite `"play"` pending (if any still remain), records pause
    /// timestamps, then runs ``SharedPlayerManager/submitMediaTransportCommandAndWait(_:)``
    /// with `.pause` so engine silence shares the serial media-transport mailbox with
    /// system Now Playing, headset remotes, and main-hosted Live Activity toggles
    /// (pause preempts an in-flight play). Call sites that already hop to MainActor
    /// should `await` this method directly — no nested Task — so Darwin → silence
    /// does not pay an extra scheduling hop.
    ///
    /// - SeeAlso: ``checkForPendingWidgetActions()``,
    ///   ``SharedPlayerManager/submitMediaTransportCommandAndWait(_:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    func handleWidgetPauseAction() async {
        if let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared") {
            if sharedDefaults.string(forKey: "pendingAction") == "play" {
                sharedDefaults.removeObject(forKey: "pendingAction")
                sharedDefaults.removeObject(forKey: "pendingActionId")
                sharedDefaults.removeObject(forKey: "pendingActionTime")
                sharedDefaults.removeObject(forKey: "pendingLanguage")
            }
        }

        // Pause barrier is in-actor only (``recordUserPauseTimestamp`` → ``wasRecentlyUserPaused``).
        // App Group `lastUserPauseTime` is retired (no readers); residual keys are purged on launch.
        await SharedPlayerManager.shared.recordUserPauseTimestamp()
        await SharedPlayerManager.shared.submitMediaTransportCommandAndWait(.pause)
        // Note: isPlaying flag lives in VC for a few legacy paths; coordinator does not duplicate the flag.
        let newState = await SharedPlayerManager.shared.currentVisualState
        updateUI(for: newState)
    }

    // MARK: - Core orchestration (moved verbatim from ViewController with only ownership adjustments)

    // MARK: Stream choice / language switch paths (architectural note)
    //
    // All user-driven "change stream" flows converge on clearly separated responsibilities
    // (see CODING_AGENT.md Single Source of Truth Principles):
    //
    // - `DirectStreamingPlayer.switchToStream(_:)` — the **single source of truth** for
    //   *engine preparation* on any user-initiated choice (flag, widget, Siri, etc.).
    //   Performs: set model, reset transients, awaited silent streamSwitch stop (lang change),
    //   reset per-stream attempt counters. Always await when ordering with stop/play matters.
    //
    // - `RadioPlayerCoordinator` (this type):
    //   - `completeStreamSwitch` — canonical **main-app** full orchestration for flag taps.
    //     Owns tuning sound, prePlay hold coordination, intent guards, play sequencing,
    //     and UI side effects. The primary "user tapped a language" path.
    //   - `switchToStreamFromWidget(to:index:actionId:)` — canonical **widget/LA reconciliation**
    //     (silent, no tuning/needle). Thinly wrapped by `handleWidgetSwitchToLanguage`.
    //   - `handleWidgetSwitchToLanguage` — public entry (with actionId dedup + debounce)
    //     that delegates to the widget canonical.
    //   - `handleSwitchToLanguage` — external (Siri/shortcut/deep-link) path. Uses the
    //     engine SSOT + reset/play but is kept on a separate attach style for minimality;
    //     does not go through completeStreamSwitch (no main-app tuning expected for external).
    //   - `handleLanguageSelection` — entry from LanguageSelectorView taps (debounce +
    //     optimistic prePlay when appropriate, then delegates to completeStreamSwitch).
    //
    // - Playback initiation (separate SSOT from stream choice):
    //   - Explicit user "start/resume" requests use `SharedPlayerManager.userRequestedPlay()`
    //     (the designated single entry). See handlePlayAction,
    //     handleUserTogglePlayback (play branch), and all external surfaces.
    //   - Internal continuation when playback intent is already active (the resume branches
    //     of the two canonical switch methods `completeStreamSwitch` and `switchToStreamFromWidget`),
    //     cold launch, and recovery may call `play()` directly. The rule and justification
    //     are stated in the `///` docs on those methods and the Precondition on
    //     `userRequestedPlay()`.
    //
    // - `SharedPlayerManager` — owns `currentVisualState`, `currentPlaybackIntent`,
    //   `resetToPrePlayForNewStream`, resurrection rules, persisted widget snapshot,
    //   cross-process Darwin signaling, and the actual `play()` / `stop()` execution.
    //   Its `switchToStream` is the nonisolated signaling façade: widget context → schedule
    //   + Darwin; main-app context → forwards directly to engine.
    //
    // Widget paths originate from optimistic state + pending action + Darwin notification,
    // then land in `handleWidgetSwitchToLanguage` (or the Live Activity intent path via SPM).
    //
    // AGENT NOTE: Never re-introduce manual "setSelectedStreamModelOnly + resetTransient
    // + stop + resetCounters" sequences anywhere. Route engine work exclusively through
    // `DirectStreamingPlayer.switchToStream`. Main-app flag UX lives in `completeStreamSwitch`.
    // Widget reconciliation lives in `switchToStreamFromWidget`. Siri/external use SPM.switchToStream
    // + reset + userRequestedPlay (non-UI paths).
    // All explicit play initiation must use userRequestedPlay (or end at the permitted direct
    // `play()` sites after an active playback intent check). The two canonical switch resume
    // branches deliberately use direct `play()` (internal continuation of active intent).
    // See the `///` on `switchToStreamFromWidget`, `completeStreamSwitch`, `userRequestedPlay`,
    // and `play()` for the full analysis and "keep as-is" rule.
    // Update this block + the `///` docs on the four symbols together on any architecture change.

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
    /// and the architecture block in this file together on any change to the explicit vs.
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
            // (`userRequestedPlay`) for consistency with handlePlayAction, handleWidgetPlayAction,
            // remote toggle, Siri, LA toggle, widget pending reconciliation, etc.
            // Immediate .prePlay is preserved (setUserIntentToPlay also establishes .prePlay
            // internally for resume-from-pause/clear cases) so connecting feedback timing is
            // unchanged. The trailing updateUI + updateNowPlayingInfo still run after the await.
            self.updateUI(for: .prePlay)
            await manager.userRequestedPlay()
        }

        let newState = await manager.currentVisualState
        self.updateUI(for: newState)
    }

    private func handleLanguageSelection(at newIndex: Int) {
        // isDeallocating guard stays in host (VC) for now; coordinator is torn down with VC.
        #if DEBUG
        print("[RadioPlayerCoordinator] handleLanguageSelection called for index \(newIndex)")
        #endif

        selectedStreamIndex = newIndex
        Task { @MainActor [weak self] in
            guard let self else { return }
            let vs = await SharedPlayerManager.shared.currentVisualState
            if vs.shouldAutoPlayOrResume {
                let intent = await SharedPlayerManager.shared.currentPlaybackIntent
                let streams = DirectStreamingPlayer.availableStreams
                let connectingLanguage: String? =
                    streams.indices.contains(newIndex) ? streams[newIndex].languageCode : nil
                await SharedPlayerManager.shared.resetToPrePlayForNewStream(
                    preserveActiveSleepTimer: intent == .sleepTimer,
                    connectingLanguageCode: connectingLanguage
                )
                self.updateUI(for: .prePlay)
            } else {
                viewModel?.selectedStreamIndex = newIndex
            }
        }

        let now = Date()
        if let lastTime = lastStreamSwitchTime, now.timeIntervalSince(lastTime) < streamSwitchDebounceInterval {
            #if DEBUG
            print("[RadioPlayerCoordinator] handleLanguageSelection: Debouncing stream switch, time since last: \(now.timeIntervalSince(lastTime))s")
            #endif
            return
        }
        lastStreamSwitchTime = now

        streamSwitchWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let stream = DirectStreamingPlayer.availableStreams[newIndex]
            self.backgroundImageController.scheduleDeferredForStreamSwitch(stream)

            if self.isTuningSoundPlaying {
                #if DEBUG
                print("[RadioPlayerCoordinator] handleLanguageSelection: Waiting for tuning sound to complete")
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    /// Updates the shared language for widget/Live Activity consumption and persists
    /// a combined (currentVisualState + language) snapshot.
    ///
    /// - Parameter languageCode: The target stream language (e.g. "fi", "de").
    ///
    /// This is called on every user- or widget-driven language change (completeStreamSwitch,
    /// switchToStreamFromWidget, handleSwitchToLanguage, and early cold-launch seeding).
    ///
    /// **Why the visual must be preserved (not forced to .prePlay):**
    /// When the user changes language while paused (`.userPaused` visual + sticky intent),
    /// the widget must continue to display the grey paused state for the *new* language.
    /// The subsequent widget "play" tap then correctly routes through `userRequestedPlay()`
    /// (clearing the lock and using snapshot alignment in `setUserIntentToPlay`).
    /// Hard-coding `.prePlay` here used to inject the wrong visual into timelines and could
    /// race the snapshot write, producing the exact "widget pause → language change → resume"
    /// misbehavior on device/TestFlight (while simulator masked the timing).
    ///
    /// The authoritative write goes through `saveCombinedWidgetState` (which writes
    /// `PersistedWidgetState` with the actor's `currentVisualState` + the supplied language).
    /// We refresh *after* that persist (inside the Task) using the real visual captured
    /// at decision time. `isLanguageChange` is treated as urgent by `performActualSave`
    /// when full saves occur.
    ///
    /// - Important: Never hard-code visual state here. Always derive from
    ///   `SharedPlayerManager.shared.currentVisualState` (or the caller's knowledge of
    ///   whether we are in a resume vs. paused switch).
    ///
    /// - SeeAlso: ``completeStreamSwitch(stream:index:)``, ``switchToStreamFromWidget(to:index:actionId:)``,
    ///   ``SharedPlayerManager/saveCombinedWidgetState(language:)``,
    ///   ``SharedPlayerManager/setUserIntentToPlay()`` (the snapshot language alignment),
    ///   ``SharedPlayerManager/loadPersistedVisualStateDirect()``,
    ///   ``WidgetRefreshManager/refreshIfNeeded(visualState:currentLanguage:hasError:immediate:)``,
    ///   `PersistedWidgetState`, CODING_AGENT.md (Single Source of Truth Principles),
    ///   SharedPlayerManager.swift (handleWidgetSwitch + "pause on widget → language switch" contract).
    /// Updates session language snapshot paths after an in-app language selection.
    ///
    /// Liveness uses ``SharedPlayerManager/bumpWidgetLivenessTimestamp(policy:minInterval:)`` so the
    /// home-widget privacy gate suppresses `lastUpdateTime` when no Lutheran widgets are configured
    /// (and after privacy clear forces the gate closed). Snapshot persistence remains gated inside
    /// ``SharedPlayerManager/saveCombinedWidgetState(language:)``.
    ///
    /// - Parameter languageCode: Stream language code to persist when the privacy gate allows.
    /// - SeeAlso: ``SharedPlayerManager/bumpWidgetLivenessTimestamp(policy:minInterval:)``,
    ///   ``SharedPlayerManager/WidgetLivenessWritePolicy``,
    ///   ``SharedPlayerManager/saveCombinedWidgetState(language:)``,
    ///   ``SharedPlayerManager/clearHomeWidgetLivenessAndInstantFeedbackResiduals()``,
    ///   CODING_AGENT.md (Single Source of Truth Principles).
    func updateUserDefaultsLanguage(_ languageCode: String) {
        // Privacy-gated liveness only — never write lastUpdateTime raw (residual after clear / no widgets).
        SharedPlayerManager.bumpWidgetLivenessTimestamp(policy: .immediate)

        Task {
            await SharedPlayerManager.shared.saveCombinedWidgetState(language: languageCode)

            // Use the *actual* current visual state (e.g. .userPaused) rather than hard-coding
            // .prePlay. Language changes performed while the stream is paused must preserve the
            // sticky paused visual in the PersistedWidgetState snapshot so that:
            //  - widgets render the correct grey "Ready"/paused chrome for the *new* language
            //  - subsequent widget "play" / resume uses loadPersistedVisualStateDirect() + userRequestedPlay()
            //    to clear the lock and start the correct stream (see setUserIntentToPlay alignment).
            //
            // Previous hard-coded .prePlay could race with the snapshot write (saveCombined is
            // async) and deliver a timeline entry with the wrong visual. This was invisible on
            // simulator (fast scheduling) but produced the "pause → language change → resume"
            // failures on physical devices and TestFlight builds.
            //
            // Widget timeline reload is driven by ``.persistedWidgetStateDidUpdate`` on the Tier 2
            // observer path. ``WidgetRefreshManager/refreshIfNeeded`` always bypasses debounce on
            // language changes (Tier 3 dedup removed the redundant imperative call here).
            //
            // See: SharedPlayerManager.swift (handleWidgetSwitch, signalWidgetSwitchAction,
            // loadPersistedVisualStateDirect, setUserIntentToPlay, ensureVisualStateLoaded
            // anti-regression for hadStickyUserPause), switchToStreamFromWidget,
            // completeStreamSwitch paused branch, WidgetToggleRadioIntent.perform,
            // CODING_AGENT.md (Single Source of Truth Principles + cross-target shared files),
            // WidgetRefreshManager (language change urgency + refreshWouldRegress).
        }

        #if DEBUG
        print("[RadioPlayerCoordinator] MAIN APP: Updated UserDefaults language to: \(languageCode)")
        #endif
    }

    /// Canonical main-app orchestration for a user-initiated stream/language change
    /// Canonical main-app stream-switch orchestration for flag taps in the language selector.
    ///
    /// This is the full-experience counterpart to the silent `switchToStreamFromWidget`.
    /// It is the single owner of everything that happens when the user taps a language
    /// flag while the main UI is visible (optimistic prePlay, tuning sound, needle animation,
    /// intent-conditional continuation, Now Playing updates).
    ///
    /// Responsibilities (executed in order inside the debounced Task):
    /// 1. Snapshot intent; when resuming, establish `resetToPrePlayForNewStream` hold +
    ///    Connecting chrome **before** engine teardown (may already be set by
    ///    `handleLanguageSelection`).
    /// 2. Engine prep via `DirectStreamingPlayer.switchToStream` (SSOT silent stop + model).
    /// 3. Language snapshot + Live Activity language mirror + media-surface refresh
    ///    (visual is already Connecting or sticky pause — never `.playing` mid-teardown).
    /// 4. If not resuming: clear soft-pause metadata, force `.userPaused` UI, announce, return.
    /// 5. If resuming: optional tuning sound + needle animation, second guard,
    ///    conditional redundant-hold skip, then `SharedPlayerManager.play()`.
    /// 6. Final announce.
    ///
    /// **Direct `play()` rule (authoritative):** Inside the active-intent resume branch we
    /// call `play()` directly. This is internal continuation after a prior explicit action
    /// (or the initial launch) established an active playback intent (`isActivePlaybackIntent`).
    /// It is deliberately *not* routed through `userRequestedPlay()`. The same rule and
    /// justification apply to the resume branch of `switchToStreamFromWidget`. See the full
    /// rule in the Precondition on `userRequestedPlay()` and the matching note on
    /// `switchToStreamFromWidget`.
    ///
    /// - Parameters:
    ///   - stream: The target `Stream` chosen by the user tap.
    ///   - index: Index in `DirectStreamingPlayer.availableStreams` (drives selector
    ///            final position and background controller).
    ///
    /// - Important: Widget and Live Activity reconciliation paths *must not* call this
    ///   method. They go through `handleWidgetSwitchToLanguage` → `switchToStreamFromWidget`
    ///   (no tuning, no needle, different optimistic timing).
    /// - Important: External Siri / shortcut / deep-link switch uses `handleSwitchToLanguage`
    ///   (kept on a lighter attach style) which ends by calling through to `userRequestedPlay()`
    ///   (because a Siri "switch to X" is treated as an imperative play request).
    ///
    /// - SeeAlso: `handleLanguageSelection`,
    ///   `switchToStreamFromWidget(to:index:actionId:)`,
    ///   `handleWidgetSwitchToLanguage`,
    ///   `handleSwitchToLanguage`,
    ///   `DirectStreamingPlayer.switchToStream`,
    ///   ``SharedPlayerManager/play()``,
    ///   ``SharedPlayerManager/userRequestedPlay()``,
    ///   ``SharedPlayerManager/resetToPrePlayForNewStream(preserveActiveSleepTimer:)``,
    ///   ``SharedPlayerManager/currentPlaybackIntent``,
    ///   CODING_AGENT.md (Single Source of Truth Principles + "Cross-target shared source files"),
    ///   <doc:Architecture>.
    ///
    /// AGENT NOTE: completeStreamSwitch and switchToStreamFromWidget are a matched pair of
    /// canonicals. They must continue to use the same pattern for active-intent playback
    /// continuation (direct `play()` after the guard + reset). Changing one without the other,
    /// or routing either resume site to `userRequestedPlay()`, would violate the designation.
    /// Keep the "update together" set in sync: these two `///` docs + architecture block +
    /// userRequestedPlay Precondition + resurrection table.
    private func completeStreamSwitch(stream: DirectStreamingPlayer.Stream, index: Int) {
        self.selectedStreamIndex = index
        saveStateForWidget()

        self.lastStreamSwitchTime = Date()

        streamSwitchTask?.cancel()
        streamSwitchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }

            let visualState = await SharedPlayerManager.shared.currentVisualState
            let playbackIntent = await SharedPlayerManager.shared.currentPlaybackIntent

            #if DEBUG
            print("[RadioPlayerCoordinator] completeStreamSwitch started – currentVisualState = \(visualState), playbackIntent = \(playbackIntent), stream = \(stream.languageCode)")
            #endif

            let shouldResumeAfterSwitch = playbackIntent.isActivePlaybackIntent

            // Connecting chrome **before** silent engine teardown, with destination language so
            // Live Activity / Now Playing never advertise `.playing` mid stream-switch stop and
            // language chrome advances with Connecting (no prior-language one-frame lag).
            // `handleLanguageSelection` may already have set the hold; skip a second reset.
            if shouldResumeAfterSwitch {
                if await SharedPlayerManager.shared.isStreamSwitchPrePlayHoldActive {
                    #if DEBUG
                    print("[RadioPlayerCoordinator] [completeStreamSwitch] prePlay hold already active before engine prep")
                    #endif
                } else {
                    await SharedPlayerManager.shared.resetToPrePlayForNewStream(
                        preserveActiveSleepTimer: playbackIntent == .sleepTimer,
                        connectingLanguageCode: stream.languageCode
                    )
                }
                self.updateUI(for: .prePlay)
            }

            // Engine preparation is performed via the SSOT for *every* user-initiated
            // stream choice (both the resume/play path and the explicit-paused path).
            // switchToStream guarantees ordering (model first, awaited stop when language
            // changes, fresh counters). Visual is already Connecting when intent is active.
            await streamingPlayer.switchToStream(stream)
            guard !Task.isCancelled else { return }

            // Session snapshot language after model prep (LA language already on hold when resuming).
            // Paused path: still warm language mirror + surfaces without claiming `.playing`.
            updateUserDefaultsLanguage(stream.languageCode)
            SharedPlayerManager.persistLiveActivityLanguageMirror(stream.languageCode)
            #if LUTHERAN_MAIN_APP
            await SharedPlayerManager.shared.refreshAllMediaSurfaces(liveActivity: .updateIfActive)
            #endif

            guard shouldResumeAfterSwitch else {
                #if DEBUG
                print("🚫 [RadioPlayerCoordinator] [completeStreamSwitch] Blocked — userPaused, no auto-resume")
                #endif

                await SharedPlayerManager.shared.clearSoftPauseMetadataStashForLanguageChange()

                self.backgroundImageController.cancelPendingDeferral()
                self.backgroundImageController.update(for: stream)
                self.updateUI(for: .userPaused)
                self.viewModel?.selectedStreamIndex = index
                announceSwitchedToLanguage(stream)
                return
            }

            #if DEBUG
            print("[RadioPlayerCoordinator] ▶ [completeStreamSwitch] Allowed resume during stream switch (was playing)")
            #endif

            await playTuningSound(animateNeedleTo: index)
            guard !Task.isCancelled else { return }

            guard shouldResumeAfterSwitch else {
                #if DEBUG
                print("[RadioPlayerCoordinator] [completeStreamSwitch] Blocked play() after tuning sound")
                #endif
                viewModel?.selectedStreamIndex = index // migrated from // languageSelectorView (SwiftUI uses VM) .setSelectedIndex(index, caller: "completeStreamSwitch-blockedPlay")
                return
            }

            #if DEBUG
            print("[RadioPlayerCoordinator] completeStreamSwitch → calling SharedPlayerManager.play() after tuning")
            #endif

            // Direct `play()` here (and the symmetric site in switchToStreamFromWidget) is the
            // permitted internal continuation inside the active-intent resume branch. We reach
            // it only after `isActivePlaybackIntent` was already true. Explicit play requests
            // use `userRequestedPlay()`. See the `///` rule above and the Precondition on
            // `userRequestedPlay()`.
            if await SharedPlayerManager.shared.isStreamSwitchPrePlayHoldActive {
                #if DEBUG
                print("[RadioPlayerCoordinator] [completeStreamSwitch] Skipping redundant resetToPrePlayForNewStream — hold already active")
                #endif
            } else {
                let intent = await SharedPlayerManager.shared.currentPlaybackIntent
                await SharedPlayerManager.shared.resetToPrePlayForNewStream(
                    preserveActiveSleepTimer: intent == .sleepTimer,
                    connectingLanguageCode: stream.languageCode
                )
            }
            updateUI(for: .prePlay)

            await SharedPlayerManager.shared.play()
            guard !Task.isCancelled else { return }
            await Task.yield()

            announceSwitchedToLanguage(stream)

            #if DEBUG
            print("[RadioPlayerCoordinator] completeStreamSwitch: Switched to stream \(stream.language), index=\(index)")
            #endif
        }
    }

    // MARK: - Update distribution (single place for visual state application to all subviews)

    /// Applies a `PlayerVisualState` to in-app chrome (SwiftUI `PlayerViewModel` + security alert).
    ///
    /// Dedupes consecutive identical states via `lastAppliedVisualState` so connecting/buffering
    /// chatter does not thrash the pill. Authoritative promotion to `.playing` after deferred
    /// Connecting is decided in ``handleStatusChange(_:reasonKey:)`` /
    /// ``RadioPlayerChromeVisualResolver`` — this method only paints what it is given.
    ///
    /// VoiceOver: thermal enter/exit is announced here (modern chrome SSOT) via
    /// ``announceThermalVisualTransition(from:to:)`` so `status_thermal_paused` is spoken
    /// without requiring focus on the status pill. Other status strings continue to use the
    /// legacy `safeUpdateStatusLabel` allowlist where that path still runs.
    ///
    /// - Parameter visualState: Chrome visual to apply (not necessarily equal to SPM yet during
    ///   the deferred ``setPlaying()`` window).
    /// - SeeAlso: ``handleStatusChange(_:reasonKey:)``, ``RadioPlayerChromeVisualResolver``,
    ///   ``announceThermalVisualTransition(from:to:)``, `PlayerViewModel`,
    ///   CODING_AGENT.md (Single Source of Truth Principles).
    @MainActor
    func updateUI(for visualState: PlayerVisualState) {
        if lastAppliedVisualState == visualState {
            #if DEBUG
            print("[RadioPlayerCoordinator] updateUI → skipped (already applied \(visualState))")
            #endif
            return
        }
        let previousVisualState = lastAppliedVisualState
        lastAppliedVisualState = visualState

        // Pure SwiftUI views are driven via viewModel (pushed below).
        // // playbackControlsView.applyVisualState was UIKit path.

        // Drive the SwiftUI observable model (if wired).
        // This is the primary hand-off point so that SwiftUI reacts with the same
        // visual state the UIKit chrome just received. Coordinator owns timing.
        if let vm = viewModel {
            vm.visualState = visualState
            vm.selectedStreamIndex = selectedStreamIndex
            if visualState == .securityLocked {
                vm.isShowingSecurityError = true
                vm.lastErrorMessage = String(localized: "security_model_error_message", table: "Localizable")
            } else if vm.isShowingSecurityError {
                // Clear transient error surface on recovery to non-locked state
                vm.isShowingSecurityError = false
            }
        }

        if visualState == .securityLocked {
            if !hasShownSecurityAlert {
                hasShownSecurityAlert = true
                // Route alert presentation through injected hook (keeps security alert presentation site in host if desired;
                // the decision to show on this state transition lives here with the visual update).
                let alert = UIAlertController(
                    title: String(localized: "security_model_error_title", table: "Localizable"),
                    message: String(localized: "security_model_error_message", table: "Localizable"),
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "alert_retry", table: "Localizable"), style: .default, handler: { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in
                        self.streamingPlayer.resetTransientErrors()
                        let isValid = await SecurityValidationFacade.validate(.securityRetry)
                        if isValid {
                            await SharedPlayerManager.shared.userRequestedPlay()
                        } else {
                            let isPermanent = await SecurityValidationFacade.isPermanentlyInvalid()
                            #if DEBUG
                            print("[RadioPlayerCoordinator] Retry failed — permanent? \(isPermanent)")
                            #endif
                        }
                    }
                }))
                alert.addAction(UIAlertAction(title: String(localized: "ok", table: "Localizable"), style: .cancel, handler: nil))
                presentAlert?(alert)
            }
        }

        // Thermal pause is involuntary hardware chrome — announce enter/exit so VoiceOver
        // users hear `status_thermal_paused` / recovery without focusing the status pill.
        // Dedupe above ensures we only announce real transitions.
        announceThermalVisualTransition(from: previousVisualState, to: visualState)

        #if DEBUG
        print("[RadioPlayerCoordinator] updateUI → applied \(visualState) (bg=\(visualState.backgroundColor), tint=\(visualState.buttonTintColor))")
        #endif
    }

    // MARK: - VM sync helpers (coordinator remains driver)

    /// Pushes the stream-switching flag to both the legacy DirectStreamingPlayer and (if present) the SwiftUI VM.
    /// Call sites that set `streamingPlayer.isSwitchingStream` should prefer or also call this when a VM is active.
    @MainActor
    func setIsSwitchingStream(_ value: Bool) {
        streamingPlayer.isSwitchingStream = value
        viewModel?.isSwitchingStream = value
    }

    /// Pushes the remaining sleep timer seconds into the VM (if wired).
    /// The UIKit controls continue to be updated via the existing applySleepTimerButtonAppearance path.
    @MainActor
    func syncSleepTimerToViewModel(remaining: Int?) {
        viewModel?.sleepTimerRemaining = remaining.map { TimeInterval($0) }
    }

    /// Pushes parsed metadata into the observable model (coordinator or VC call sites can use this).
    @MainActor
    func syncMetadataToViewModel(_ raw: String?) {
        if let raw {
            viewModel?.currentMetadata = StreamProgramMetadata.from(rawICYMetadata: raw)
        } else {
            viewModel?.currentMetadata = nil
        }
    }

    func updateUIForNoInternet() {
        safeUpdateStatusLabel(
            text: String(localized: "status_no_internet", table: "Localizable"),
            backgroundColor: .systemGray,
            textColor: .white,
            isPermanentError: false
        )
        // Metadata + play/pause glyph now driven by VM for SwiftUI views.
        viewModel?.currentMetadata = nil
        // visualState update will cause the controls to show correct glyph.
    }

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

    // Thin now-playing + widget save (duplicated from original thin helpers; identical behavior)
    func updateNowPlayingInfo(title: String? = nil) {
        #if LUTHERAN_MAIN_APP
        Task {
            if let title {
                await SharedPlayerManager.shared.didUpdateStreamMetadata(title)
            } else {
                await SharedPlayerManager.shared.updateNowPlayingInfo()
            }
        }
        #endif
    }

    func saveStateForWidget() {
        Task {
            await SharedPlayerManager.shared.saveCurrentState()
        }
    }

    func safeUpdateStatusLabel(text: String, backgroundColor: UIColor, textColor: UIColor, isPermanentError: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // VM drives SwiftUI status pill
            viewModel?.visualState = .prePlay // placeholder; real state comes from caller

            if text != String(localized: "status_playing", table: "Localizable") {
                self.saveStateForWidget()
            }

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

    // MARK: - Accessibility announcements

    /// Posts a VoiceOver announcement that the stream language has changed.
    ///
    /// Revives the previously stale `"switched_to_language %@"` catalog entry
    /// (introduced for a11y but orphaned during the RadioPlayerCoordinator extraction).
    /// Called from the three canonical language-switch orchestration methods after the
    /// target stream has been applied and the selection UI updated.
    ///
    /// Uses the exact registered key with %@ placeholder + `String(format:)` so the
    /// extractor keeps the entry fresh and all 21 localizations remain active.
    ///
    /// - Parameter stream: The stream that was switched to. Its `.language` property
    ///   already holds the localized human-readable name (e.g. "English", "Suomi").
    /// - SeeAlso: `completeStreamSwitch`, `switchToStreamFromWidget(to:index:actionId:)`,
    ///   `handleSwitchToLanguage`, `DirectStreamingPlayer.Stream.language`
    private func announceSwitchedToLanguage(_ stream: DirectStreamingPlayer.Stream) {
        // SAFETY: UIAccessibility.post is the standard API for VoiceOver announcements.
        // The unsafe marker satisfies SWIFT_STRICT_MEMORY_SAFETY; this is the same
        // pattern used for all other .announcement posts in this file and ViewController.
        let announcement = unsafe String(
            format: String(
                localized: "switched_to_language %@",
                defaultValue: "Switched to %@",
                table: "Localizable",
                comment: "Voiceover announcement announcing the language switch. The placeholder value is replaced with the actual language name."
            ),
            stream.language
        )
        unsafe UIAccessibility.post(notification: .announcement, argument: announcement)
    }

    /// Announces thermal pause enter/exit on the modern ``updateUI(for:)`` chrome path.
    ///
    /// Keeps `status_thermal_paused` active for VoiceOver without requiring focus on the
    /// status pill. Sighted users already see the orange "Device hot" pill via
    /// ``PlayerVisualState/makeStatusPresentation()``; this only adds a proactive
    /// announcement for non-sighted users when the hardware gate flips.
    ///
    /// - Parameters:
    ///   - previous: Visual applied before this transition (`nil` on first paint).
    ///   - next: Visual being applied now (already deduped by ``updateUI(for:)``).
    /// - Note: Enter posts the catalog thermal string. Leave posts the destination
    ///   status-pill text (Play / Pause / …) so recovery is spoken once from this SSOT.
    /// - SeeAlso: ``updateUI(for:)``, ``PlayerVisualState/thermalPaused``,
    ///   `status_thermal_paused` in `Localizable.xcstrings`, CODING_AGENT.md.
    private func announceThermalVisualTransition(from previous: PlayerVisualState?, to next: PlayerVisualState) {
        let message: String?
        if next == .thermalPaused {
            // Enter thermal: speak the same short status string the pill shows.
            message = String(localized: "status_thermal_paused", table: "Localizable")
        } else if previous == .thermalPaused {
            // Leave thermal: speak the destination chrome status (e.g. Play after auto-resume).
            message = next.makeStatusPresentation().text
        } else {
            message = nil
        }
        guard let message, !message.isEmpty else { return }
        // SAFETY: UIAccessibility.post is the established VoiceOver announcement API
        // (same pattern as `announceSwitchedToLanguage` and post-clear `clear_local_state_done`).
        unsafe UIAccessibility.post(notification: .announcement, argument: message)
    }

    // MARK: - Haptics (tiny controller extraction P5+; thin forward only — behavior preserved)
    func playHapticFeedback(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        hapticsController.playHapticFeedback(style: style)
    }

    // MARK: - Tuning sounds (stream selection delight + cold-launch special clip)
    /// Plays the one-shot cold-launch special tuning clip, then signals ``TuningSoundCoordinator``.
    ///
    /// Session configuration and clip start go through
    /// ``DirectStreamingPlayer/startLocalClipPlayer(contentsOf:volume:numberOfLoops:)`` so
    /// `AVAudioPlayer` prepare/play never runs on the main actor. Initial stream attach remains
    /// `SharedPlayerManager.play()` after the coordinator wait — this method must not start the
    /// secured stream.
    ///
    /// AGENT NOTE: Single production owner for the special cold-launch clip. The thin host only
    /// invokes this method from its cold-launch Task; it does not retain clip state or conform to
    /// `AVAudioPlayerDelegate`.
    ///
    /// - Parameter completion: Optional early-exit hook; successful start finishes via
    ///   `AVAudioPlayerDelegate` → ``TuningSoundCoordinator/notifyPlaybackFinished(source:)``.
    /// - SeeAlso: ``DirectStreamingPlayer/startLocalClipPlayer(contentsOf:volume:numberOfLoops:)``,
    ///   ``DirectStreamingPlayer/configureAudioSessionAsync()``, `TuningSoundCoordinator`,
    ///   `SharedPlayerManager.play()`.
    func playSpecialTuningSound(completion: (() -> Void)? = nil) async {
        guard !hasPlayedSpecialTuningSound else {
            #if DEBUG
            print("[RadioPlayerCoordinator] Special tuning sound already played, skipping")
            #endif
            completion?()
            return
        }

        guard let tuningURL = Bundle.main.url(forResource: "special_tuning_sound", withExtension: "wav") else {
            #if DEBUG
            print("[RadioPlayerCoordinator] Error: special_tuning_sound.wav not found in bundle")
            #endif
            await TuningSoundCoordinator.shared.notifyNoActivePlayback()
            completion?()
            return
        }

        do {
            // SSOT: session activate + off-main AVAudioPlayer construct/prepare/play.
            // Retain the returned player on MainActor; delegate finish still owns waiters.
            // Volume default 1.0 (full relative gain). System output volume is SSOT.
            guard let clip = try await streamingPlayer.startLocalClipPlayer(
                contentsOf: tuningURL,
                volume: 1.0,
                numberOfLoops: 0
            ) else {
                await TuningSoundCoordinator.shared.notifyNoActivePlayback()
                completion?()
                return
            }

            let player = clip.player
            player.delegate = self
            tuningPlayer = player
            isTuningSoundPlaying = clip.didStart
            hasPlayedSpecialTuningSound = true
            lastTuningSoundTime = Date()

            #if DEBUG
            print("[RadioPlayerCoordinator] Set special tuning sound volume to \(player.volume)")
            print(clip.didStart
                  ? "[RadioPlayerCoordinator] Special tuning sound started playing"
                  : "[RadioPlayerCoordinator] Failed to start special tuning sound")
            #endif

            // Never trigger secured stream playback after tuning sound.
            // Initial playback is SharedPlayerManager.play() after the TuningSoundCoordinator wait.
            if clip.didStart {
                await TuningSoundCoordinator.shared.notifyPlaybackStarted(estimatedDuration: player.duration)
            } else {
                await TuningSoundCoordinator.shared.notifyNoActivePlayback()
                tuningPlayer = nil
            }
        } catch {
            #if DEBUG
            print("[RadioPlayerCoordinator] Error loading special tuning sound: \(error.localizedDescription)")
            #endif
            await TuningSoundCoordinator.shared.notifyNoActivePlayback()
            completion?()
            tuningPlayer = nil
        }
    }

    // MARK: - AVAudioPlayerDelegate (special cold-launch clip finish only)

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard player === self.tuningPlayer else { return }
            #if DEBUG
            print("[RadioPlayerCoordinator] Special tuning sound finished playing, success: \(flag)")
            #endif
            self.isTuningSoundPlaying = false
            self.tuningPlayer = nil
            await TuningSoundCoordinator.shared.notifyPlaybackFinished()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard player === self.tuningPlayer else { return }
            #if DEBUG
            print("[RadioPlayerCoordinator] Special tuning decode error: \(error?.localizedDescription ?? "Unknown")")
            #endif
            self.isTuningSoundPlaying = false
            self.tuningPlayer = nil
            await TuningSoundCoordinator.shared.notifyPlaybackFinished()
        }
    }

    /// Stream-switch / language-selector tuning delight clip.
    ///
    /// Uses ``DirectStreamingPlayer/startLocalClipPlayer(contentsOf:volume:numberOfLoops:)`` so
    /// session configuration and `AVAudioPlayer` prepare/play stay off the main-actor
    /// activation path. Needle index is applied on the main actor after start returns.
    ///
    /// - Parameter index: Optional stream index to commit to the view model while the clip plays.
    /// - SeeAlso: ``DirectStreamingPlayer/startLocalClipPlayer(contentsOf:volume:numberOfLoops:)``,
    ///   ``DirectStreamingPlayer/configureAudioSessionAsync()``.
    func playTuningSound(animateNeedleTo index: Int? = nil) async {
        guard let tuningURL = Bundle.main.url(forResource: "tuning_sound_1", withExtension: "wav") else {
            #if DEBUG
            print("[RadioPlayerCoordinator] Error: tuning_sound_1.wav not found in bundle")
            #endif
            if let idx = index {
                viewModel?.selectedStreamIndex = idx
            }
            return
        }

        // Debounce rapid calls (verbatim)
        if let lastTime = lastTuningSoundTime, Date().timeIntervalSince(lastTime) < 0.3 {
            #if DEBUG
            print("[RadioPlayerCoordinator] playTuningSound: Debouncing rapid tuning sound call")
            #endif
            if let idx = index {
                viewModel?.selectedStreamIndex = idx
            }
            return
        }

        do {
            guard let clip = try await streamingPlayer.startLocalClipPlayer(
                contentsOf: tuningURL,
                numberOfLoops: 0
            ) else {
                if let idx = index {
                    viewModel?.selectedStreamIndex = idx
                }
                return
            }

            clip.player.delegate = nil
            tuningPlayer = clip.player
            isTuningSoundPlaying = clip.didStart
            lastTuningSoundTime = Date()

            #if DEBUG
            print("[RadioPlayerCoordinator] Playing tuning sound (duration: \(clip.player.duration)s, didStart=\(clip.didStart))")
            #endif

            if let idx = index {
                viewModel?.selectedStreamIndex = idx
            }

            let duration = clip.player.duration > 0 ? clip.player.duration : 0.8
            try? await Task.sleep(for: .seconds(duration + 0.1))
            isTuningSoundPlaying = false
        } catch {
            #if DEBUG
            print("[RadioPlayerCoordinator] Failed to play tuning sound: \(error)")
            #endif
            isTuningSoundPlaying = false
            if let idx = index {
                viewModel?.selectedStreamIndex = idx
            }
        }
    }

    func stopTuningSound() {
        let wasActive = tuningPlayer != nil || isTuningSoundPlaying
        tuningPlayer?.stop()
        tuningPlayer = nil
        isTuningSoundPlaying = false
        if wasActive {
            // Resume any SharedPlayerManager.play() waiters if special clip was interrupted.
            Task { await TuningSoundCoordinator.shared.notifyPlaybackFinished(source: .cancelled) }
        }
        #if DEBUG
        print("[RadioPlayerCoordinator] Tuning sound stopped")
        #endif
    }

    // MARK: - Sleep timer UI glue (moved verbatim)
    //
    // IMPORTANT (SwiftUI migration):
    // The primary presentation of sleep timer options is now a native SwiftUI
    // `.confirmationDialog` inside PlaybackControlsView. It offers the same presets
    // (15/30/45/60) + conditional Cancel and routes choices through PlayerViewModel
    // action closures directly into the handle* methods below.
    //
    // `configureSleepTimerButtonMenu()` is retained (never removed per requirements)
    // and is still invoked from beginLocalSleepTimerDisplay, stopLocalSleepTimerDisplay,
    // handleCancelSelected, localStateCleared, confirmAndClearLocalState, and
    // view setup for any legacy/compatibility side-effects. Its UIMenu construction
    // currently has no attached presenter so produces no visible UI.
    //
    // All timer *business logic*, timing (settle constants), interaction flags,
    // countdown Task, sync to VM, and SharedPlayerManager calls remain here unchanged.
    func configureSleepTimerButtonMenu() {
        var children: [UIMenuElement] = []

        if cachedSleepTimerRemaining != nil {
            children.append(UIAction(
                title: String(localized: "sleep_timer_cancel_timer", table: "Localizable"),
                attributes: .destructive
            ) { [weak self] _ in
                self?.handleSleepTimerCancelSelected()
            })
        }

        let presets: [(minutes: Int, title: String)] = [
            (15, String(localized: "sleep_timer_preset_15_min", table: "Localizable")),
            (30, String(localized: "sleep_timer_preset_30_min", table: "Localizable")),
            (45, String(localized: "sleep_timer_preset_45_min", table: "Localizable")),
            (60, String(localized: "sleep_timer_preset_60_min", table: "Localizable"))
        ]

        for preset in presets {
            children.append(UIAction(title: preset.title) { [weak self] _ in
                self?.handleSleepTimerPresetSelected(minutes: preset.minutes)
            })
        }

        // "Clear local playback state" (destructive action in sleep timer menu).
        // Clears recent playback/widget/Live Activity state from the App Group.
        // Does not touch any security or Core data.
        children.append(UIAction(
            title: String(localized: "clear_local_state_title", table: "Localizable"),
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [weak self] _ in
            self?.confirmAndClearLocalState()
        })

        // (Modern SwiftUI path: presentation lives in PlaybackControlsView.confirmationDialog.
        // This builder is kept only for compatibility and internal re-sync calls.)
    }

    @MainActor
    private func handleSleepTimerPresetSelected(minutes: Int) {
        isSleepTimerInteractionActive = true
        backgroundImageController.cancelDeferredForModalInteraction()

        let totalSeconds = max(1, minutes * 60)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: Self.sleepTimerMenuSettleNs)
            let confirmed = await SharedPlayerManager.shared.setSleepTimer(
                duration: TimeInterval(totalSeconds)
            )
            guard let confirmed else {
                self.finishSleepTimerInteraction(applyDeferredVisuals: false)
                return
            }
            try? await Task.sleep(nanoseconds: Self.sleepTimerPostScheduleUISettleNs)
            guard !Task.isCancelled else { return }
            self.beginLocalSleepTimerDisplay(remaining: confirmed, deferImageSwap: true)
            try? await Task.sleep(nanoseconds: Self.sleepTimerDeferredVisualSettleNs)
            guard !Task.isCancelled else { return }
            // playbackControlsView.applySleepTimerButtonAppearance(remaining: confirmed, deferImageSwap: false)
            self.finishSleepTimerInteraction(applyDeferredVisuals: true)
            self.backgroundImageController.rescheduleDeferredAfterModalIfNeeded()
        }
    }

    @MainActor
    private func handleSleepTimerCancelSelected() {
        isSleepTimerInteractionActive = true
        backgroundImageController.cancelDeferredForModalInteraction()

        Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            self.stopLocalSleepTimerDisplay()
            await SharedPlayerManager.shared.cancelSleepTimer()
            self.configureSleepTimerButtonMenu()
            self.finishSleepTimerInteraction(applyDeferredVisuals: true)
            self.backgroundImageController.rescheduleDeferredAfterModalIfNeeded()
        }
    }

    @MainActor
    private func finishSleepTimerInteraction(applyDeferredVisuals: Bool) {
        isSleepTimerInteractionActive = false
        guard applyDeferredVisuals, let metadata = pendingMetadataVisualRefresh else { return }
        pendingMetadataVisualRefresh = nil
        updateNowPlayingInfo(title: metadata)
        // SwiftUI photo logic reacts to VM metadata change.
    }

    /// Receives broadcasts from SleepTimerNotification when a sleep timer is scheduled,
    /// ticks (first value only), or becomes inactive (elapsed or cancelled).
    ///
    /// - Important: This observer is the **main-app-only** channel that reconciles the
    ///   authoritative `currentVisualState` (from SharedPlayerManager SSOT) into the live
    ///   in-app UI after an internal sleep-timer pause. Widget/Live Activity consumers use
    ///   the persisted snapshot written by `applySleepTimerElapsedPause`; the main app
    ///   does not receive a status callback or actionable Darwin "pause" for this path.
    ///
    /// When the timer elapses:
    /// - `applySleepTimerElapsedPause` forces `currentVisualState = .userPaused` (so
    ///   widgets show paused) while leaving `playbackIntent = .sleepTimer` (non-sticky
    ///   so resurrection logic and clearUserPausedLockIfNeeded can distinguish it).
    /// - Direct stop uses `reason: .interruption` (effectiveSilent + teardown guard
    ///   suppresses KVO/status callbacks).
    /// - The self-posted Darwin pause is suppressed by `DarwinSelfEchoGuard`.
    /// - Therefore this observer must explicitly pull `currentVisualState` and call
    ///   `updateUI(for:)` so the main app chrome (VM → SwiftUI controls tint/glyph,
    ///   colors, pill) leaves the stale `.playing` (green) state.
    ///
    /// The `lastAppliedVisualState` guard inside `updateUI` makes the call a cheap no-op
    /// on cancel paths where visual state did not change.
    ///
    /// - SeeAlso: ``SharedPlayerManager/applySleepTimerElapsedPause()``,
    ///   `PlaybackIntent.sleepTimer`, `SleepTimerNotification`,
    ///   `handleStatusChange(_:reasonKey:)`, CODING_AGENT.md (Single Source of Truth Principles),
    ///   SharedPlayerManager.swift (resurrection table + applySleepTimerElapsedPause).
    ///
    /// - Note: Only the first remaining-seconds value seeds the local countdown to avoid
    ///   per-second actor hops; the coordinator owns decrementing locally.
    @objc private func sleepTimerStateDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let isActive = notification.userInfo?[SleepTimerNotification.Key.isActive] as? Bool ?? false
            if !isActive {
                self.stopLocalSleepTimerDisplay()

                // AGENT NOTE (sleep timer visual SSOT sync):
                // The main-app UI (green playing state) can diverge from the PersistedWidgetState
                // snapshot after sleep fire because the stop is silent and the Darwin pause is
                // intentionally suppressed as a self-echo. We must re-read the actor SSOT here
                // and drive updateUI so the in-app controls, VM, and chrome match .userPaused.
                // Widgets are already correct via the snapshot write + WidgetRefreshManager.
                // This is the designated place for the main-app side effect of timer completion.
                let visualState = await SharedPlayerManager.shared.currentVisualState
                self.updateUI(for: visualState)
                return
            }
            if let remaining = notification.userInfo?[SleepTimerNotification.Key.remainingSeconds] as? Int,
               remaining > 0,
               self.cachedSleepTimerRemaining == nil {
                self.beginLocalSleepTimerDisplay(remaining: remaining)
                self.syncSleepTimerToViewModel(remaining: remaining)
            }
        }
    }

    @MainActor
    func syncSleepTimerDisplayFromActorIfNeeded() async {
        let remaining = await SharedPlayerManager.shared.sleepTimerRemainingSeconds
        if let remaining, remaining > 0 {
            beginLocalSleepTimerDisplay(remaining: remaining)
            syncSleepTimerToViewModel(remaining: remaining)
        } else if cachedSleepTimerRemaining != nil {
            stopLocalSleepTimerDisplay()
        }
    }

    @MainActor
    private func beginLocalSleepTimerDisplay(remaining: Int, deferImageSwap: Bool = false) {
        cachedSleepTimerRemaining = remaining
        // playbackControlsView.applySleepTimerButtonAppearance(remaining: remaining, deferImageSwap: deferImageSwap)
        configureSleepTimerButtonMenu()

        // Drive SwiftUI VM countdown surface (non-breaking; UIKit path unchanged).
        syncSleepTimerToViewModel(remaining: remaining)

        sleepTimerDisplayTask?.cancel()
        sleepTimerDisplayTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            var remainingSeconds = self.cachedSleepTimerRemaining ?? 0

            while remainingSeconds > 0, !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }

                remainingSeconds -= 1
                self.cachedSleepTimerRemaining = remainingSeconds > 0 ? remainingSeconds : nil
                // self. (SwiftUI observes sleepTimerRemaining on VM)
            }
        }
    }

    @MainActor
    private func stopLocalSleepTimerDisplay() {
        sleepTimerDisplayTask?.cancel()
        sleepTimerDisplayTask = nil
        cachedSleepTimerRemaining = nil
        // playbackControlsView.applySleepTimerButtonAppearance(remaining: nil)
        configureSleepTimerButtonMenu()

        // Clear VM surface too.
        syncSleepTimerToViewModel(remaining: nil)
    }

    // MARK: - Privacy clear (Clear local playback state)
    // Wired from the destructive item in the (legacy UIMenu or SwiftUI .confirmationDialog).
    // The SwiftUI path arrives via onClearLocalStateTapped (PlaybackControlsView).
    // Uses the SSOT clearAllLocalState (engine stop + reset to .cleared visual + .cleared intent
    // without persist, removes all local UD keys, ends LA, forces no-widgets gate, posts notification).
    // We drive the UI to .cleared (blue pill showing clear_local_state_done) + reseed language selector
    // (device locale fallback) + rebuild menu.
    // The dedicated .cleared visual gives sighted confirmation the reset succeeded (fixing the prior
    // "status_connecting yellow after clear" visual issue). Post-clear cold launches behave like fresh
    // installs (no snapshot persisted => .prePlay path).
    // Recently deleted data is not re-created by this action or the immediate post-clear launch
    // setup; it is only (re)created on explicit play or the successful post-clear cold-start play path.

    @MainActor
    /// Triggers the privacy "Clear local state" flow.
    ///
    /// Shows a confirmation UIAlert (using "clear_local_state_*" strings), then on confirm:
    /// calls `SharedPlayerManager.clearAllLocalState()`, resets UI to .cleared (the visual that
    /// surfaces "clear_local_state_done" + blue), reseeds language, plays haptic, rebuilds menu,
    /// and posts VO announcement to keep "clear_local_state_done" live in the catalog.
    ///
    /// Called from:
    /// - The legacy UIMenu action inside `configureSleepTimerButtonMenu()`
    /// - The SwiftUI path: `onClearLocalStateTapped` closure (PlaybackControlsView via RadioPlayerView/VC)
    ///
    /// - Note: Visibility is internal (not private) to support the SwiftUI wiring from ViewController.
    /// - SeeAlso: `configureSleepTimerButtonMenu()`, PlaybackControlsView (the dialog button),
    ///   SharedPlayerManager.clearAllLocalState, localStateCleared(_:).
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
                self.configureSleepTimerButtonMenu()

                // Revive the stale "clear_local_state_done" string (was only used from the old
                // UIKit post-clear path that was deleted during SwiftUI foundation migration).
                // We post it as a VoiceOver announcement so the entry stays active in the catalog
                // for all 21 languages and users who trigger the action still receive confirmation
                // feedback. Sighted users continue to see the clean .prePlay state (no new banner).
                // Matches the revive pattern used for "switched_to_language %@" elsewhere in this file.
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
            // Keep menu and local timer display in sync (mirrors sleepTimerStateDidChange pattern).
            // Primary UI reset + language reseed for the explicit menu path lives in confirmAndClearLocalState.
            stopLocalSleepTimerDisplay()
            configureSleepTimerButtonMenu()
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

    // MARK: - Streaming status distribution entry (called from VC's StreamingPlayerDelegate hop)

    /// Receives every status update from the streaming engine and decides UI, visual state,
    /// alerts, and widget/Live Activity side effects.
    ///
    /// This is the central choke point for mapping low-level `PlayerStatus` + `reasonKey`
    /// (from `DirectStreamingPlayer.safeOnStatusChange`) into high-level `PlayerVisualState`
    /// and user-visible surfaces via ``RadioPlayerChromeVisualResolver``.
    ///
    /// **Connecting-until-audible chrome:** While the start pipeline is active, SPM holds
    /// `.prePlay` until engine ``setPlaying()`` / `publishAuthoritativePlayingIfNeeded`.
    /// Engine `status_playing` can arrive on MainActor **before** that actor mutation is
    /// visible. Chrome must still promote to `.playing` promptly — freezing `.prePlay` here
    /// leaves the in-app pill yellow while audio and Live Activity already show playing.
    /// Sticky `.userPaused` / `.cleared` / policy chrome remain protected.
    ///
    /// Special handling exists for transient states (connecting/buffering preserve optimistic
    /// prePlay/playing, with an engine-audible race guard) and for explicit user pauses. The
    /// unavailable/failed reaction includes an `isInInitialRecoveryWindow` guard so that normal
    /// self-healing ICY decoder noise immediately after a language switch (or cold launch)
    /// does not force `.userPaused` + alert.
    ///
    /// - Parameters:
    ///   - status: Coarse player status.
    ///   - reasonKey: Exact Localizable key (e.g. "status_playing", "status_stream_unavailable").
    ///     Used both for localization and for precise branching.
    ///
    /// - SeeAlso: ``RadioPlayerChromeVisualResolver/resolve(status:reasonKey:visualState:playbackIntent:engineIsActuallyPlaying:)``,
    ///   `DirectStreamingPlayer.safeOnStatusChange`, `handleItemStatusFailure(_:)`,
    ///   `streamingPlayer.isInInitialRecoveryWindow`, `SharedPlayerManager.markPlaybackStoppedByStreamFailure`,
    ///   `SharedPlayerManager.setPlaying()`, `updateUI(for:)`, CODING_AGENT.md (transient vs permanent modeling)
    func handleStatusChange(_ status: PlayerStatus, reasonKey: String?) async {
        let visualState = await SharedPlayerManager.shared.currentVisualState
        let playbackIntent = await SharedPlayerManager.shared.currentPlaybackIntent
        // Engine-truth for the deferred-setPlaying race: status_playing / brief buffer while
        // rate is already 1 must not re-stick Connecting chrome before SPM flips to `.playing`.
        let engineIsActuallyPlaying = streamingPlayer.isActuallyPlaying()

        #if DEBUG
        print("[RadioPlayerCoordinator] onStatusChange → \(status) (reasonKey: \(reasonKey ?? "nil")) → visualState \(visualState) enginePlaying=\(engineIsActuallyPlaying)")
        #endif

        let effectiveVisualState = RadioPlayerChromeVisualResolver.resolve(
            status: status,
            reasonKey: reasonKey,
            visualState: visualState,
            playbackIntent: playbackIntent,
            engineIsActuallyPlaying: engineIsActuallyPlaying
        )

        #if DEBUG
        if effectiveVisualState == .playing
            && visualState == .prePlay
            && (reasonKey == "status_playing" || engineIsActuallyPlaying) {
            print("[RadioPlayerCoordinator] in-app chrome → .playing while SPM still .prePlay (deferred setPlaying race; engine audible)")
            MediaTransportLatencyTimeline.mark(
                .inAppChromeAppliedPlaying,
                detail: "spmVisual=prePlay reasonKey=\(reasonKey ?? "nil")"
            )
        }
        #endif

        self.updateUI(for: effectiveVisualState)

        // If we had to correct the UI to .userPaused for a real sticky user pause (despite the
        // actor having loaded a stale .prePlay), repair the in-memory SSOT immediately so that
        // any follow-on save uses the correct visual.
        // Never do this repair for .cleared (the post-reset visual).
        if effectiveVisualState == .userPaused && visualState == .prePlay && playbackIntent == .userPaused {
            Task {
                await SharedPlayerManager.shared.setVisualState(.userPaused)
            }
        }

        if let reasonKey = reasonKey {
            if reasonKey == "status_ssl_transition" {
                // Status pill color updated via VM / SwiftUI in updateUI.

                // Present via hook (alert creation kept close to original site for mechanical fidelity)
                let alert = UIAlertController(
                    title: String(localized: "ssl_transition_title", table: "Localizable"),
                    message: String(localized: "ssl_transition_message", table: "Localizable"),
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "alert_continue", table: "Localizable"), style: .default, handler: { [weak self] _ in
                    guard self != nil else { return }
                    Task { @MainActor in
                        await SharedPlayerManager.shared.userRequestedPlay()
                    }
                }))
                alert.addAction(UIAlertAction(title: String(localized: "ok", table: "Localizable"), style: .cancel, handler: nil))
                presentAlert?(alert)

            } else if reasonKey == "status_no_internet" {
                // Status handled in updateUIForNoInternet via VM.
                self.updateUIForNoInternet()

            } else if reasonKey == "status_stream_unavailable" || reasonKey == "status_failed" {
                // After `switchToStream` + `resetInitialPlaybackCountersForNewStream`, the player
                // gives the new item a fresh retry budget. Live ICY framing/decoder noise on the
                // first packets is recovered silently by secured `recreatePlayerItem()`
                // (`handleItemStatusFailure`, buffer/timeControl observers, resource loader).
                //
                // While `isInInitialRecoveryWindow` is true, suppress grey-pause mutation and the
                // stream-unavailable alert. A later `status_playing` advances the UI without a flash.
                //
                // Defensive: engine paths already avoid severe keys for early transients; the
                // window check keeps the contract at the UI layer if a fallback still emits them.
                if streamingPlayer.isInInitialRecoveryWindow {
                    #if DEBUG
                    print("[RadioPlayerCoordinator] Suppressing unavailable/failed reaction — streamingPlayer.isInInitialRecoveryWindow (transient ICY noise on fresh post-switch/cold item)")
                    #endif
                } else {
                    let vsForCheck = await SharedPlayerManager.shared.currentVisualState
                    if vsForCheck.isActivelyPlaying || vsForCheck == .prePlay {
                        // Preserves playback intent (`.shouldBePlaying` / `.sleepTimer`) so a
                        // subsequent language switch auto-resumes without an extra play tap.
                        await SharedPlayerManager.shared.markPlaybackStoppedByStreamFailure()
                    }
                    let correctedVisualState = await SharedPlayerManager.shared.currentVisualState
                    self.updateUI(for: correctedVisualState)

                    if let vc = viewController, vc.presentedViewController == nil {
                        let alert = UIAlertController(
                            title: String(localized: "stream_unavailable_title", table: "Localizable"),
                            message: String(localized: "stream_unavailable_message", table: "Localizable"),
                            preferredStyle: .alert
                        )
                        alert.addAction(UIAlertAction(title: String(localized: "alert_retry", table: "Localizable"), style: .default) { _ in
                            Task { @MainActor in
                                await SharedPlayerManager.shared.userRequestedPlay()
                            }
                        })
                        alert.addAction(UIAlertAction(title: String(localized: "ok", table: "Localizable"), style: .cancel, handler: nil))
                        presentAlert?(alert)
                    }
                }
            }
        }

        if status == .playing {
            hasEverPlayed = true

            if reasonKey == nil {
                playHapticFeedback(style: .light)
            }

            if reasonKey == "status_playing" {
                self.backgroundImageController.scheduleDeferredFlushIfNeeded()
            }
        }

        saveStateForWidget()
    }

    // MARK: - Deinit cleanup for coordinator-owned observers
    deinit {
        sleepTimerDisplayTask?.cancel()
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

// MARK: - In-app chrome visual resolver (engine status → pill / glyph)

/// Pure mapping from streaming-engine status callbacks into the in-app chrome `PlayerVisualState`.
///
/// ``RadioPlayerCoordinator/handleStatusChange(_:reasonKey:)`` is the sole production call site.
/// Logic lives here so unit tests can assert Connecting-until-audible, sticky pause, and privacy
/// clear contracts without constructing a full UIKit host or driving `AVPlayer`.
///
/// ## Why this is not a dumb pass-through of SPM visual
///
/// SharedPlayerManager defers authoritative ``setPlaying()`` until soft-resume rate kick or
/// readyToPlay first-play kick (`publishAuthoritativePlayingIfNeeded`). Engine
/// `status_playing` is delivered via `DispatchQueue.main.async` and can interleave **before**
/// the SPM actor mutation is visible. Freezing chrome on SPM `.prePlay` in that window leaves
/// the main-app pill yellow (Connecting) while audio is live and Live Activity / Now Playing
/// already show playing.
///
/// Holding `.prePlay` during **true** Connecting (`status_connecting` / buffering while the
/// engine is not audibly playing) remains correct.
///
/// ## Sticky / policy protection (must not regress)
///
/// - `.userPaused` visual or intent on terminal stop/pause keys → grey pause chrome.
/// - `.cleared` intent (privacy clear) → blue cleared chrome for any residual engine chatter.
/// - `.securityLocked` / `.thermalPaused` while those visuals are authoritative → keep policy chrome
///   even if a late `status_playing` races in (engine kick should already be suppressed).
///
/// - SeeAlso: ``RadioPlayerCoordinator/handleStatusChange(_:reasonKey:)``,
///   ``SharedPlayerManager/setPlaying()``, `DirectStreamingPlayer.publishAuthoritativePlayingIfNeeded`,
///   `PlayerVisualState`, CODING_AGENT.md (Single Source of Truth Principles).
enum RadioPlayerChromeVisualResolver: Sendable {

    /// Resolves the chrome visual that ``RadioPlayerCoordinator/updateUI(for:)`` should apply.
    ///
    /// - Parameters:
    ///   - status: Coarse `PlayerStatus` from the streaming delegate (note: `status_connecting` is
    ///     often delivered with `isPlaying: true` → `.playing` status; always prefer `reasonKey`).
    ///   - reasonKey: Exact Localizable key from `safeOnStatusChange` (e.g. `"status_playing"`).
    ///   - visualState: Current SPM `currentVisualState` (may still be `.prePlay` after audible start).
    ///   - playbackIntent: Current SPM `currentPlaybackIntent`.
    ///   - engineIsActuallyPlaying: ``DirectStreamingPlayer/isActuallyPlaying()`` — rate + timeControl
    ///     truth used to avoid re-sticking Connecting chrome during the deferred-`setPlaying` race
    ///     when buffering/connecting keys arrive while audio is already flowing.
    /// - Returns: Chrome visual to apply. Does **not** mutate SPM; the actor remains SSOT for
    ///   persistence / widgets / LA. In-app chrome may lead SPM by one frame during deferred setPlaying.
    /// - SeeAlso: ``RadioPlayerCoordinator/handleStatusChange(_:reasonKey:)``,
    ///   ``SharedPlayerManager/setPlaying()``, CODING_AGENT.md.
    static func resolve(
        status: PlayerStatus,
        reasonKey: String?,
        visualState: PlayerVisualState,
        playbackIntent: PlaybackIntent,
        engineIsActuallyPlaying: Bool = false
    ) -> PlayerVisualState {
        // Privacy clear: intent alone blocks resurrection; chrome must stay blue `.cleared`
        // through residual connecting/stopped callbacks from the silent teardown.
        if playbackIntent == .cleared {
            return .cleared
        }

        // Authoritative audible-start report from the engine.
        // Prefer reasonKey: `status_connecting` is also delivered with PlayerStatus.playing
        // because safeOnStatusChange uses isPlaying:true for connecting feedback.
        let isAuthoritativePlayingReport =
            reasonKey == "status_playing"
            || (status == .playing && reasonKey == nil)

        if isAuthoritativePlayingReport {
            if visualState == .userPaused || playbackIntent == .userPaused {
                return .userPaused
            }
            if visualState == .cleared {
                return .cleared
            }
            if visualState == .securityLocked || playbackIntent == .securityLocked {
                return .securityLocked
            }
            if visualState == .thermalPaused {
                return .thermalPaused
            }
            // Deferred Connecting (.prePlay), already-playing SPM, or any other non-sticky
            // surface: promote chrome to green promptly when the engine reports audible play.
            return .playing
        }

        // Connecting / buffering: preserve optimistic chrome.
        // Key off reasonKey only — do not require `status != .playing`, because connecting is
        // emitted with isPlaying:true → PlayerStatus.playing.
        if let reasonKey,
           reasonKey == "status_connecting" || reasonKey == "status_buffering" {
            // Deferred setPlaying race: engine already audible, SPM still .prePlay, and a
            // buffer/connect key arrives after we (or status_playing) painted green — do not
            // re-stick yellow Connecting while rate is 1 and intent still wants play.
            if engineIsActuallyPlaying,
               playbackIntent.isActivePlaybackIntent,
               visualState == .prePlay || visualState == .playing {
                return .playing
            }
            if visualState == .prePlay || visualState == .playing || visualState == .cleared {
                return visualState
            }
            if playbackIntent.isActivePlaybackIntent {
                return .prePlay
            }
        }

        // Explicit user pause: terminal stop/pause keys must not regress grey → yellow Connecting.
        if status == .stopped || status == .paused
            || reasonKey == "status_stopped" || reasonKey == "status_paused" {
            if visualState == .userPaused || playbackIntent == .userPaused {
                return .userPaused
            }
        }

        // Protect sticky chrome from other engine chatter (SSL keys, unavailable noise, etc.).
        // Authoritative playing is handled above so this no longer freezes Connecting after audible start.
        if visualState == .userPaused || visualState == .prePlay || visualState == .cleared {
            return visualState
        }
        return visualState
    }
}

// MARK: - DEBUG test seams (WidgetIntentContractTests)

#if DEBUG
extension RadioPlayerCoordinator {

    /// When `true`, ``checkForPendingWidgetActions()`` processes play/pause/switch pendings
    /// under the XCTest host instead of the UITestMode drain-only path.
    ///
    /// Mirrors ``WidgetRefreshManager/_test_setBypassUITestModeForRefreshGateObservation(_:)``.
    /// Lifecycle hosts may forward via ``ViewController`` thin shims for existing test call sites.
    ///
    /// - SeeAlso: ``WidgetIntentContractTests``, ``checkForPendingWidgetActions()``,
    ///   ``SharedPlayerManager/isRunningInUITestMode``, docs/Widget-Functionality-Roadmap.md (Tier 2).
    nonisolated(unsafe) private static var _test_bypassUITestModeForPendingActionProcessing = false

    /// Enables or disables real pending-action processing while `isRunningInUITestMode` is true.
    nonisolated static func _test_setBypassUITestModeForPendingActionProcessing(_ bypass: Bool) {
        unsafe _test_bypassUITestModeForPendingActionProcessing = bypass
    }

    /// Resets widget play/pause debounce so back-to-back contract tests do not interfere.
    func _test_resetWidgetActionDebounceForTests() {
        lastWidgetActionTime = .distantPast
        lastWidgetPlayPauseAction = nil
    }
}
#endif
