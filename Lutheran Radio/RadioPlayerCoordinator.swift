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
//  Darwin listener setup, deinit CF cleanup).
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

/// Lightweight coordinator (wiring + orchestration only). Does not own playback execution, security,
/// streaming engine decisions, or widget snapshot authority — those remain exclusively in
/// SharedPlayerManager + DirectStreamingPlayer + Core security paths (per guardrails).
///
/// Sleep timer note: coordinator is the single owner of timer logic (set/cancel + countdown glue +
/// interaction windows + VM sync). SwiftUI (PlaybackControlsView) owns only the .confirmationDialog
/// presentation and calls back via PlayerViewModel closures. configureSleepTimerButtonMenu is retained.
@MainActor
final class RadioPlayerCoordinator {

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
    /// During the hybrid phase the closure passed from `RadioPlayerView` typically calls
    /// `configureSleepTimerButtonMenu()`. This property exists for future cleaner wiring
    /// (e.g. if the coordinator itself wants to drive presentation of a SwiftUI sheet or
    /// confirmation dialog without the caller knowing the implementation).
    ///
    /// Current primary path: PlaybackControlsView presents its own `.confirmationDialog`
    /// and the resulting choices are delivered via the `PlayerViewModel` action closures
    /// (onSleepTimerPresetSelected / onSleepTimerCancelSelected) which are wired directly
    /// to `handleSleepTimerPresetSelected` / `handleSleepTimerCancelSelected`.
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
    // internal for cross-sync with VC's onMetadataChange suppression check (same sleep interaction window)
    var isSleepTimerInteractionActive = false
    // internal so VC metadata callback (kept in host) can cross-stash during sleep interaction window
    var pendingMetadataVisualRefresh: String?
    private static let sleepTimerMenuSettleNs: UInt64 = 250_000_000
    private static let sleepTimerPostScheduleUISettleNs: UInt64 = 300_000_000
    private static let sleepTimerDeferredVisualSettleNs: UInt64 = 500_000_000

    // Widget action debounce (some state shared with VC for now; logic here for switch handling)
    private var lastWidgetSwitchTime: Date?
    private var pendingWidgetSwitchWorkItem: DispatchWorkItem?

    // MARK: - Init / Wiring
    init(
        backgroundImageController: BackgroundImageController,
        streamingPlayer: DirectStreamingPlayer
    ) {
        self.backgroundImageController = backgroundImageController
        self.streamingPlayer = streamingPlayer
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
                await SharedPlayerManager.shared.resetToPrePlayForNewStream()
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
    /// 2. Engine preparation exclusively via `DirectStreamingPlayer.switchToStream(_:)`
    ///    (the SSOT: model update, transient reset, awaited stop for lang change, counter reset).
    /// 3. Mirror selection + chrome (index, background, UserDefaults language, selector view).
    /// 4. If `!shouldResumeAfterSwitch`: clear soft-pause stash, force `.userPaused` visual,
    ///    announce, clear the `actionId`, and return (no playback started).
    /// 5. If resuming: `resetToPrePlayForNewStream()` (defensive clear + `.prePlay` + hold +
    ///    one-shot reset), update UI to `.prePlay`, then `SharedPlayerManager.play()`.
    /// 6. Announce + clear pending `actionId`.
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
    ///   ``SharedPlayerManager/currentPlaybackIntent``,
    ///   `announceSwitchedToLanguage(_:)`,
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

        // Engine prep via the SSOT. Replaces all prior manual setSelected + reset + stop sites
        // on the widget path.
        await streamingPlayer.switchToStream(stream)

        selectedStreamIndex = index
        backgroundImageController.update(for: stream)
        updateUserDefaultsLanguage(stream.languageCode)

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

        await SharedPlayerManager.shared.resetToPrePlayForNewStream()
        viewModel?.selectedStreamIndex = index // migrated from // languageSelectorView (SwiftUI uses VM) .setSelectedIndex(index, caller: "widgetSwitch-prePlay")
        updateUI(for: .prePlay)

        #if DEBUG
        print("[RadioPlayerCoordinator] ▶ [Widget Switch] Starting new stream using SharedPlayerManager.play() — main app path")
        #endif

        // Direct `play()` after `isActivePlaybackIntent` check + resetToPrePlayForNewStream.
        // This is the permitted internal continuation when playback intent was already active.
        // See the rule stated in the `///` above and the Precondition on `userRequestedPlay()`.
        // Do NOT change this site to `userRequestedPlay()`; that would be semantically incorrect
        // for a continuation-of-active-intent switch and would break symmetry with completeStreamSwitch.
        await SharedPlayerManager.shared.play()

        #if DEBUG
        print("[RadioPlayerCoordinator] Widget switch: SharedPlayerManager.play() succeeded")
        print("[RadioPlayerCoordinator] Widget switch completed (authoritative save covered by play())")
        #endif

        announceSwitchedToLanguage(stream)
        SharedPlayerManager.shared.clearPendingAction(actionId: actionId)
    }

    // Widget play/pause action helpers (no tuning sounds)
    /// Vestigial shim retained for any remaining direct callers.
    ///
    /// Now delegates to `userRequestedPlay()` (the designated explicit-play path).
    /// Previously performed only `clearUserPausedLockIfNeeded() + play()` (weaker;
    /// bypassed full `setUserIntentToPlay` double-save + NowPlaying configure).
    /// Primary widget "play" path is already checkForPendingWidgetActions → userRequestedPlay.
    ///
    /// - SeeAlso: ``SharedPlayerManager/userRequestedPlay()``,
    ///   ViewController.checkForPendingWidgetActions,
    ///   CODING_AGENT.md.
    ///
    /// AGENT NOTE: Prefer the pending + checkForPending + userRequestedPlay route for
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

    func handleWidgetPauseAction() {
        if let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared") {
            if sharedDefaults.string(forKey: "pendingAction") == "play" {
                sharedDefaults.removeObject(forKey: "pendingAction")
                sharedDefaults.removeObject(forKey: "pendingActionId")
                sharedDefaults.removeObject(forKey: "pendingActionTime")
                sharedDefaults.removeObject(forKey: "pendingLanguage")
            }

            sharedDefaults.set(Date().timeIntervalSince1970, forKey: "lastUserPauseTime")
            sharedDefaults.synchronize()

            Task {
                await SharedPlayerManager.shared.recordUserPauseTimestamp()
            }
        }

        Task { @MainActor in
            await SharedPlayerManager.shared.stop()
            // Note: isPlaying flag lives in VC for a few legacy paths; coordinator does not duplicate the flag.
            let newState = await SharedPlayerManager.shared.currentVisualState
            self.updateUI(for: newState)
            self.updateNowPlayingInfo()
        }
    }

    // The processedActionIds set is kept on VC for cross-cutting dedup; the coordinator receives the guard decision from caller.
    // We keep a local mirror of the set for the widget switch path we fully own (mechanical extraction).
    private var processedActionIds: Set<String> = []

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
        self.updateNowPlayingInfo()

        // Event-driven Live Activity push (the manager will suppress if content is
        // identical to last pushed). This is intentionally after the SPM work so that
        // currentVisualState is stable.
        #if LUTHERAN_MAIN_APP
        await RadioLiveActivityManager.shared.updateCurrentActivity()
        #endif
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
                await SharedPlayerManager.shared.resetToPrePlayForNewStream(
                    preserveActiveSleepTimer: intent == .sleepTimer
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
    func updateUserDefaultsLanguage(_ languageCode: String) {
        let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "lastUpdateTime")
        sharedDefaults?.synchronize()

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
            // The saveCombined + isLanguageChange path in performActualSave already marks urgent
            // and the snapshot itself is the SSOT read by providers. We still issue an immediate
            // refresh here (after the persist) for prompt cross-process visibility of the lang.
            //
            // See: SharedPlayerManager.swift (handleWidgetSwitch, signalWidgetSwitchAction,
            // loadPersistedVisualStateDirect, setUserIntentToPlay, ensureVisualStateLoaded
            // anti-regression for hadStickyUserPause), switchToStreamFromWidget,
            // completeStreamSwitch paused branch, WidgetToggleRadioIntent.perform,
            // CODING_AGENT.md (Single Source of Truth Principles + cross-target shared files),
            // WidgetRefreshManager (language change urgency + refreshWouldRegress).
            let visual = await SharedPlayerManager.shared.currentVisualState
            WidgetRefreshManager.shared.refreshIfNeeded(
                visualState: visual,
                currentLanguage: languageCode,
                hasError: false,
                immediate: true
            )
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
    /// 1. Snapshot language + save widget state.
    /// 2. (In caller `handleLanguageSelection`) optimistic `.prePlay` UI when the prior
    ///    visual permitted auto-resume.
    /// 3. Engine prep via `DirectStreamingPlayer.switchToStream` (SSOT).
    /// 4. Intent guard using a snapshot of `currentPlaybackIntent.isActivePlaybackIntent`.
    /// 5. If not resuming: clear soft-pause, force `.userPaused` UI, announce, return.
    /// 6. If resuming: optional tuning sound + needle animation, second guard,
    ///    conditional `resetToPrePlayForNewStream` (skips when hold already active),
    ///    set `.prePlay` UI, then `SharedPlayerManager.play()`.
    /// 7. Final announce.
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
        updateUserDefaultsLanguage(stream.languageCode)

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

            // Engine preparation is performed via the SSOT for *every* user-initiated
            // stream choice (both the resume/play path and the explicit-paused path).
            // This replaces all prior manual setSelectedStreamModelOnly + resetTransientErrors
            // sites inside this method. switchToStream guarantees ordering (model first,
            // awaited stop when language changes, fresh counters).
            await streamingPlayer.switchToStream(stream)
            guard !Task.isCancelled else { return }

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
            updateUserDefaultsLanguage(stream.languageCode)

            if await SharedPlayerManager.shared.isStreamSwitchPrePlayHoldActive {
                #if DEBUG
                print("[RadioPlayerCoordinator] [completeStreamSwitch] Skipping redundant resetToPrePlayForNewStream — tap already set .prePlay hold")
                #endif
            } else {
                let intent = await SharedPlayerManager.shared.currentPlaybackIntent
                await SharedPlayerManager.shared.resetToPrePlayForNewStream(
                    preserveActiveSleepTimer: intent == .sleepTimer
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
    @MainActor
    func updateUI(for visualState: PlayerVisualState) {
        if lastAppliedVisualState == visualState {
            #if DEBUG
            print("[RadioPlayerCoordinator] updateUI → skipped (already applied \(visualState))")
            #endif
            return
        }
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
                        let isValid = await SecurityModelValidator.shared.validateSecurityModel()
                        if isValid {
                            await SharedPlayerManager.shared.userRequestedPlay()
                        } else {
                            let isPermanent = await SecurityModelValidator.shared.isPermanentlyInvalid
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
            self.updateNowPlayingInfo()

            // Explicit LA push in the coordinator pause path (in addition to the push
            // inside SharedPlayerManager.stop) for the fastest possible button/state
            // reflection on Dynamic Island / Lock Screen after a pause action that
            // originated from remote / coordinator.
            #if LUTHERAN_MAIN_APP
            await RadioLiveActivityManager.shared.updateCurrentActivity()
            #endif
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
            self.updateNowPlayingInfo()

            #if LUTHERAN_MAIN_APP
            await RadioLiveActivityManager.shared.updateCurrentActivity()
            #endif
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

    // MARK: - Haptics (tiny controller extraction P5+; thin forward only — behavior preserved)
    func playHapticFeedback(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        hapticsController.playHapticFeedback(style: style)
    }

    // MARK: - Tuning sounds (moved with state; part of stream selection delight flow)
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
            completion?()
            return
        }

        do {
            tuningPlayer = try AVAudioPlayer(contentsOf: tuningURL)
            tuningPlayer?.delegate = nil // Coordinator does not conform to AVAudioPlayerDelegate; completion is fire-and-forget for special clip
            tuningPlayer?.prepareToPlay()
            hasPlayedSpecialTuningSound = true
            isTuningSoundPlaying = true
            lastTuningSoundTime = Date()

            #if DEBUG
            print("[RadioPlayerCoordinator] Playing special tuning sound (duration: \(tuningPlayer?.duration ?? 0)s)")
            #endif

            tuningPlayer?.play()

            // Fire completion after estimated duration (matches prior timing)
            let duration = tuningPlayer?.duration ?? 1.5
            try? await Task.sleep(for: .seconds(duration + 0.1))
            isTuningSoundPlaying = false
            completion?()
        } catch {
            #if DEBUG
            print("[RadioPlayerCoordinator] Failed to play special tuning sound: \(error)")
            #endif
            isTuningSoundPlaying = false
            completion?()
        }
    }

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
            tuningPlayer = try AVAudioPlayer(contentsOf: tuningURL)
            tuningPlayer?.delegate = nil
            tuningPlayer?.prepareToPlay()
            isTuningSoundPlaying = true
            lastTuningSoundTime = Date()

            #if DEBUG
            print("[RadioPlayerCoordinator] Playing tuning sound (duration: \(tuningPlayer?.duration ?? 0)s)")
            #endif

            if let idx = index {
                viewModel?.selectedStreamIndex = idx
            }

            tuningPlayer?.play()

            // Non-blocking wait matching prior behavior
            let duration = tuningPlayer?.duration ?? 0.8
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
        tuningPlayer?.stop()
        tuningPlayer = nil
        isTuningSoundPlaying = false
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
        viewController?.isSleepTimerInteractionActive = true
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
        viewController?.isSleepTimerInteractionActive = true
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
        viewController?.isSleepTimerInteractionActive = false
        guard applyDeferredVisuals, let metadata = pendingMetadataVisualRefresh else { return }
        pendingMetadataVisualRefresh = nil
        viewController?.pendingMetadataVisualRefresh = nil
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
    /// and user-visible surfaces.
    ///
    /// Special handling exists for transient states (connecting/buffering preserve optimistic
    /// prePlay/playing) and for explicit user pauses. The unavailable/failed reaction now
    /// includes an `isInInitialRecoveryWindow` guard so that normal self-healing ICY decoder
    /// noise immediately after a language switch (or cold launch) does not force `.userPaused`
    /// + alert.
    ///
    /// - Parameters:
    ///   - status: Coarse player status.
    ///   - reasonKey: Exact Localizable key (e.g. "status_playing", "status_stream_unavailable").
    ///     Used both for localization and for precise branching.
    ///
    /// - SeeAlso: `DirectStreamingPlayer.safeOnStatusChange`, `handleItemStatusFailure(_:)`,
    ///   `streamingPlayer.isInInitialRecoveryWindow`, `SharedPlayerManager.markPlaybackStoppedByStreamFailure`,
    ///   `updateUI(for:)`, CODING_AGENT.md (transient vs permanent modeling)
    func handleStatusChange(_ status: PlayerStatus, reasonKey: String?) async {
        let visualState = await SharedPlayerManager.shared.currentVisualState
        let playbackIntent = await SharedPlayerManager.shared.currentPlaybackIntent

        #if DEBUG
        print("[RadioPlayerCoordinator] onStatusChange → \(status) (reasonKey: \(reasonKey ?? "nil")) → visualState \(visualState)")
        #endif

        let effectiveVisualState: PlayerVisualState = {
            // .cleared (post-privacy-clear) must be preserved on any status callbacks after the reset
            // (including "connecting"/"buffering"/"stopped" from the silent stop). This is the fix
            // for the "status reset visual issue": without this the pill would flip back to .prePlay
            // "Connect" yellow. The .cleared *intent* is still the resurrection blocker.
            if playbackIntent == .cleared {
                return .cleared
            }

            if let reasonKey,
               (reasonKey == "status_connecting" || reasonKey == "status_buffering"),
               status != .playing {
                if visualState == .prePlay || visualState == .playing || visualState == .cleared {
                    return visualState
                }
                if playbackIntent.isActivePlaybackIntent {
                    return .prePlay
                }
            }

            // Strong protection for explicit *user pause* (.userPaused visual or intent) on terminal
            // statuses (status_stopped etc. from KVO on live streams while paused). We must not
            // regress a grey paused UI to yellow "yhditää"/.prePlay. 
            // Post "Clear local state" the reset uses .cleared visual + .cleared intent (the
            // intent alone blocks); this prevents .userPaused (grey) from leaking into post-clear
            // cold launches or causing "Blocked initial playback".
            // The language selector is independently reseeded to a clean initial locale.
            // Security has its own red. Only target real .userPaused here.
            if status == .stopped || status == .paused
                || reasonKey == "status_stopped" || reasonKey == "status_paused" {
                if visualState == .userPaused || playbackIntent == .userPaused {
                    return .userPaused
                }
            }

            if visualState == .userPaused || visualState == .prePlay || visualState == .cleared {
                return visualState
            }
            return visualState
        }()

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
                // Early-window guard (modest architectural consolidation).
                //
                // After `switchToStream` + `resetInitialPlaybackCountersForNewStream`, the player
                // gives the new item a fresh retry budget. Normal live ICY HE-AAC framing/decoder
                // noise on the very first packets is expected and is recovered silently by
                // `recreatePlayerItem()` (see `handleItemStatusFailure` and the two observer sites).
                //
                // If the player reports we are still in that window, suppress the mark-to-.userPaused
                // and the "Lähetys ei saatavilla" alert. The next successful readyToPlay / playing
                // status will drive the UI forward without the grey pause flash.
                //
                // This guard is defensive: the centralized player logic already avoids emitting
                // the bad keys for transients, but other safety-net or fallback paths could still
                // emit them. The window check ensures the documented contract holds at the UI layer.
                if streamingPlayer.isInInitialRecoveryWindow {
                    #if DEBUG
                    print("[RadioPlayerCoordinator] Suppressing unavailable/failed reaction — streamingPlayer.isInInitialRecoveryWindow (transient ICY noise on fresh post-switch/cold item)")
                    #endif
                    // Leave visual in whatever prePlay/playing/connecting state the effective logic chose.
                    // Recovery will produce a subsequent status_playing.
                } else {
                    let vsForCheck = await SharedPlayerManager.shared.currentVisualState
                    if vsForCheck.isActivelyPlaying || vsForCheck == .prePlay {
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
