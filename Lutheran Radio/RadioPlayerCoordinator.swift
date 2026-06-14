//
//  RadioPlayerCoordinator.swift
//  Lutheran Radio
//
//  Lightweight @MainActor orchestration layer (introduced during ViewController decomposition).
//  Owns wiring of the extracted presentational components (LanguageSelectorView, BackgroundImageController,
//  PlaybackControlsView, NowPlayingMetadataView), the full stream-selection flows, distribution of every
//  visual/metadata/background update, sleep-timer UI state machine glue (notification observer + sync +
//  countdown Task + menu reconfig), haptics triggering, and initial-setup sequencing.
//
//  ViewController remains the thin lifecycle host + view hierarchy builder + public intent shims
//  (for SceneDelegate, widgets, remote commands) + hard-to-move observers (network, interruptions, route,
//  Darwin listener setup, deinit CF cleanup).
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
@MainActor
final class RadioPlayerCoordinator {

    // MARK: - Owned sub-components (wired here; narrow drive APIs used for all updates)
    private let languageSelectorView: LanguageSelectorView
    private let backgroundImageController: BackgroundImageController
    private let playbackControlsView: PlaybackControlsView
    private let nowPlayingMetadataView: NowPlayingMetadataView
    private let hapticsController = HapticsController()
    nonisolated private let streamingPlayer: DirectStreamingPlayer

    // Weak back-ref for the few services that remain difficult to move in a single mechanical pass
    // (primarily presenting security/stream alerts that were previously implemented directly on VC,
    // and saveStateForWidget which is a one-line thin forwarder). All heavy decision paths stay here.
    weak var viewController: ViewController?

    // Presenting hook (injected by VC so alerts can be shown without giving coordinator a full VC ref for layout).
    var presentAlert: ((UIAlertController) -> Void)?

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
        languageSelectorView: LanguageSelectorView,
        backgroundImageController: BackgroundImageController,
        playbackControlsView: PlaybackControlsView,
        nowPlayingMetadataView: NowPlayingMetadataView,
        streamingPlayer: DirectStreamingPlayer
    ) {
        self.languageSelectorView = languageSelectorView
        self.backgroundImageController = backgroundImageController
        self.playbackControlsView = playbackControlsView
        self.nowPlayingMetadataView = nowPlayingMetadataView
        self.streamingPlayer = streamingPlayer
    }

    /// Called by VC after it has added the subviews to the hierarchy (setupUI complete).
    /// Wires closures, performs initial index calculation (locale-driven), reloads + positions needle,
    /// starts haptic if supported, and registers the sleep notification observer.
    func wireAndInitialSetup() {
        // Wire selection notification (owner = coordinator keeps full optimistic prePlay + switch + intent logic)
        languageSelectorView.onSelectionChanged = { [weak self] newIndex in
            self?.handleLanguageSelection(at: newIndex)
        }

        // Initial index: prefers last stream from PersistedWidgetState (SSOT) so the tuning needle
        // reflects "last stream remembered" on cold launch / resurrection. Falls back via
        // bestInitialLanguageCode (robust preferredLanguages match) only for first-run / post-clear /
        // privacy-no-widgets cases (distinct from widget "en" default).
        let languageCode = SharedPlayerManager.preferredMainAppInitialLanguageCode()
        let initialIndex = DirectStreamingPlayer.indexForLanguageCode(languageCode)
        selectedStreamIndex = initialIndex

        languageSelectorView.reloadData()
        languageSelectorView.setSelectedIndex(initialIndex, isInitial: true, caller: "coordinatorInitialSetup")

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
        // After clear the intent is .cleared (blocks proceed) while visual is .prePlay for clean UI.
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
        languageSelectorView.reloadData()
        languageSelectorView.setSelectedIndex(initialIndex, isInitial: true, caller: "clearLocalState")

        // Keep the DirectStreamingPlayer model in sync with the reseeded initial locale (post-clear).
        // This ensures any subsequent saveCurrentState / persist (after hasActiveWidgets re-detect when
        // a widget is installed) or alignment logic sees the main-app bestInitial choice rather than a
        // stale pre-clear selection. Launch paths already do an explicit setSelectedStreamModelOnly for
        // the same reason.
        let stream = DirectStreamingPlayer.streamForLanguageCode(languageCode)
        await DirectStreamingPlayer.shared.setSelectedStreamModelOnly(to: stream)
    }

    /// Called from the async portion of VC viewDidLoad Task after tuning sound + model-only set.
    /// Owns the resurrection guard + SharedPlayerManager.play() launch for cold start (prePlay path).
    func performColdLaunchPlaybackIfAllowed(initialStream: DirectStreamingPlayer.Stream) async {
        let visualState = await SharedPlayerManager.shared.currentVisualState
        let intent = await SharedPlayerManager.shared.currentPlaybackIntent
        #if DEBUG
        print("[RadioPlayerCoordinator] After tuning — visualState = \(visualState), intent = \(intent)")
        #endif

        // Allow .prePlay (normal cold or post-clear) even if visual guard would be strict.
        // .cleared intent alone does not block the post-clear cold-start success path (it only
        // prevents auto-recovery before explicit play or the successful initial play()).
        let canStartPostClearPlay = visualState == .prePlay || visualState.shouldAutoPlayOrResume || intent == .cleared
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
    func handlePlayAction() {
        Task { @MainActor in
            await SharedPlayerManager.shared.setUserIntentToPlay()
            await SharedPlayerManager.shared.play()
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
            backgroundImageController.update(for: targetStream)
            streamingPlayer.isSwitchingStream = true

            #if DEBUG
            print("[RadioPlayerCoordinator] Starting silent stop for switch to \(languageCode)")
            #endif

            streamingPlayer.stop(
                reason: .streamSwitch,
                silent: true
            )

            #if DEBUG
            print("[RadioPlayerCoordinator] Playing tuning sound")
            #endif
            await playTuningSound(animateNeedleTo: targetIndex)

            streamingPlayer.resetTransientErrors()

            #if DEBUG
            print("[RadioPlayerCoordinator] Setting stream to: \(targetStream.language)")
            #endif
            await streamingPlayer.setStream(to: targetStream)
            updateUserDefaultsLanguage(targetStream.languageCode)

            languageSelectorView.setSelectedIndex(targetIndex, animated: true, caller: "externalLanguageSwitch")

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

            streamingPlayer.isSwitchingStream = false

            #if DEBUG
            print("[RadioPlayerCoordinator] handleSwitchToLanguage completed for \(languageCode)")
            #endif
        }
    }

    // Widget switch (no tuning) — full flow owned here
    func handleWidgetSwitchToLanguage(_ languageCode: String, actionId: String) {
        guard !processedActionIds.contains(actionId) else { return }
        processedActionIds.insert(actionId)

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
                defer { self.streamingPlayer.isSwitchingStream = false }

                guard let targetStream = DirectStreamingPlayer.availableStreams.first(where: { $0.languageCode == languageCode }),
                      let targetIndex = DirectStreamingPlayer.availableStreams.firstIndex(where: { $0.languageCode == languageCode }) else {
                    #if DEBUG
                    print("[RadioPlayerCoordinator] Widget switch: target stream not found for \(languageCode)")
                    #endif
                    return
                }

                let playbackIntent = await SharedPlayerManager.shared.currentPlaybackIntent
                let shouldResumeAfterSwitch = playbackIntent.isActivePlaybackIntent

                await self.streamingPlayer.setSelectedStreamModelOnly(to: targetStream)
                self.streamingPlayer.resetTransientErrors()

                await withCheckedContinuation { continuation in
                    self.streamingPlayer.stop(
                        reason: .streamSwitch,
                        completion: { continuation.resume() },
                        silent: true
                    )
                }

                self.streamingPlayer.resetInitialPlaybackCountersForNewStream()

                self.selectedStreamIndex = targetIndex
                self.backgroundImageController.update(for: targetStream)
                self.updateUserDefaultsLanguage(languageCode)

                self.languageSelectorView.setSelectedIndex(targetIndex, animated: true, caller: "widgetSwitch")

                guard shouldResumeAfterSwitch else {
                    #if DEBUG
                    print("[RadioPlayerCoordinator] [Widget Switch] Blocked — userPaused, no auto-resume")
                    #endif
                    await SharedPlayerManager.shared.clearSoftPauseMetadataStashForLanguageChange()
                    self.languageSelectorView.setSelectedIndex(targetIndex, caller: "widgetSwitch-paused")
                    self.updateUI(for: .userPaused)
                    SharedPlayerManager.shared.clearPendingAction(actionId: actionId)
                    return
                }

                await SharedPlayerManager.shared.resetToPrePlayForNewStream()
                self.languageSelectorView.setSelectedIndex(targetIndex, caller: "widgetSwitch-prePlay")
                self.updateUI(for: .prePlay)

                #if DEBUG
                print("[RadioPlayerCoordinator] ▶ [Widget Switch] Starting new stream using SharedPlayerManager.play() — main app path")
                #endif

                await SharedPlayerManager.shared.play()

                #if DEBUG
                print("[RadioPlayerCoordinator] Widget switch: SharedPlayerManager.play() succeeded")
                print("[RadioPlayerCoordinator] Widget switch completed (authoritative save covered by play())")
                #endif

                SharedPlayerManager.shared.clearPendingAction(actionId: actionId)
            }
        }

        pendingWidgetSwitchWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    // Widget play/pause action helpers (no tuning sounds)
    func handleWidgetPlayAction() {
        #if DEBUG
        print("[RadioPlayerCoordinator] Widget Play action - forcing playback (main app style)")
        #endif

        Task { @MainActor in
            await SharedPlayerManager.shared.clearUserPausedLockIfNeeded()

            #if DEBUG
            print("[RadioPlayerCoordinator] ▶ Widget Play button → calling SharedPlayerManager.play()")
            #endif

            await SharedPlayerManager.shared.play()
            #if DEBUG
            print("[RadioPlayerCoordinator] Widget Play button: SharedPlayerManager.play() succeeded")
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

    @MainActor
    func handleUserTogglePlayback() async {
        let manager = SharedPlayerManager.shared
        let visualState = await manager.currentVisualState

        if visualState.isActivelyPlaying {
            await manager.stop()
            // isPlaying flag update is performed by the caller (VC) where it was previously mutated
        } else {
            await manager.setUserIntentToPlay()
            // isPlaying = true is performed by caller for legacy paths

            self.updateUI(for: .prePlay)

            await manager.play()
        }

        let newState = await manager.currentVisualState
        self.updateUI(for: newState)
        self.updateNowPlayingInfo()
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
                self.languageSelectorView.setSelectedIndex(newIndex, isInitial: false, caller: "handleLanguageSelection")
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

    func updateUserDefaultsLanguage(_ languageCode: String) {
        let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "lastUpdateTime")
        sharedDefaults?.synchronize()

        Task {
            await SharedPlayerManager.shared.saveCombinedWidgetState(language: languageCode)
        }

        WidgetRefreshManager.shared.refreshIfNeeded(
            visualState: .prePlay,
            currentLanguage: languageCode,
            hasError: false,
            immediate: true
        )

        #if DEBUG
        print("[RadioPlayerCoordinator] MAIN APP: Updated UserDefaults language to: \(languageCode)")
        #endif
    }

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

            await self.streamingPlayer.setSelectedStreamModelOnly(to: stream)
            self.streamingPlayer.resetTransientErrors()

            #if DEBUG
            print("[RadioPlayerCoordinator] [completeStreamSwitch] Updated stream model to \(stream.languageCode) (works for both playing and userPaused)")
            #endif

            let shouldResumeAfterSwitch = playbackIntent.isActivePlaybackIntent

            guard shouldResumeAfterSwitch else {
                #if DEBUG
                print("🚫 [RadioPlayerCoordinator] [completeStreamSwitch] Blocked — userPaused, no auto-resume")
                #endif

                await SharedPlayerManager.shared.clearSoftPauseMetadataStashForLanguageChange()

                self.backgroundImageController.cancelPendingDeferral()
                self.backgroundImageController.update(for: stream)
                self.updateUI(for: .userPaused)
                self.languageSelectorView.setSelectedIndex(index, caller: "completeStreamSwitch-userPaused")
                return
            }

            #if DEBUG
            print("[RadioPlayerCoordinator] ▶ [completeStreamSwitch] Allowed resume during stream switch (was playing)")
            #endif

            await withCheckedContinuation { continuation in
                streamingPlayer.stop(
                    reason: .streamSwitch,
                    completion: { continuation.resume() },
                    silent: true
                )
            }
            guard !Task.isCancelled else { return }

            streamingPlayer.resetInitialPlaybackCountersForNewStream()

            await playTuningSound(animateNeedleTo: index)
            guard !Task.isCancelled else { return }

            guard shouldResumeAfterSwitch else {
                #if DEBUG
                print("[RadioPlayerCoordinator] [completeStreamSwitch] Blocked play() after tuning sound")
                #endif
                languageSelectorView.setSelectedIndex(index, caller: "completeStreamSwitch-blockedPlay")
                return
            }

            #if DEBUG
            print("[RadioPlayerCoordinator] completeStreamSwitch → calling SharedPlayerManager.play() after tuning")
            #endif

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

        playbackControlsView.applyVisualState(visualState)

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

    func updateUIForNoInternet() {
        safeUpdateStatusLabel(
            text: String(localized: "status_no_internet", table: "Localizable"),
            backgroundColor: .systemGray,
            textColor: .white,
            isPermanentError: false
        )
        nowPlayingMetadataView.setMetadata(String(localized: "no_track_info", table: "Localizable"))
        playbackControlsView.setPlayPause(isPlaying: false)
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
            self.playbackControlsView.setStatus(text: text, backgroundColor: backgroundColor, textColor: textColor)

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
                languageSelectorView.setSelectedIndex(idx, animated: true, animationDuration: 0.3, caller: "playTuningSound-fallback")
            }
            return
        }

        // Debounce rapid calls (verbatim)
        if let lastTime = lastTuningSoundTime, Date().timeIntervalSince(lastTime) < 0.3 {
            #if DEBUG
            print("[RadioPlayerCoordinator] playTuningSound: Debouncing rapid tuning sound call")
            #endif
            if let idx = index {
                languageSelectorView.setSelectedIndex(idx, animated: true, animationDuration: 0.3, caller: "playTuningSound-debounced")
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
                languageSelectorView.setSelectedIndex(idx, animated: true, animationDuration: 0.3, caller: "playTuningSound")
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
                languageSelectorView.setSelectedIndex(idx, animated: true, animationDuration: 0.3, caller: "playTuningSound-error")
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

        playbackControlsView.sleepTimerButton.menu = UIMenu(
            title: String(localized: "sleep_timer_sheet_title", table: "Localizable"),
            options: .displayInline,
            children: children
        )
        playbackControlsView.sleepTimerButton.showsMenuAsPrimaryAction = true
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
            playbackControlsView.applySleepTimerButtonAppearance(remaining: confirmed, deferImageSwap: false)
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
        nowPlayingMetadataView.applySpeakerVisuals(
            for: metadata,
            potentialNames: nowPlayingMetadataView.potentialNames(from: metadata),
            animated: false
        )
    }

    @objc private func sleepTimerStateDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let isActive = notification.userInfo?[SleepTimerNotification.Key.isActive] as? Bool ?? false
            if !isActive {
                self.stopLocalSleepTimerDisplay()
                return
            }
            if let remaining = notification.userInfo?[SleepTimerNotification.Key.remainingSeconds] as? Int,
               remaining > 0,
               self.cachedSleepTimerRemaining == nil {
                self.beginLocalSleepTimerDisplay(remaining: remaining)
            }
        }
    }

    @MainActor
    func syncSleepTimerDisplayFromActorIfNeeded() async {
        let remaining = await SharedPlayerManager.shared.sleepTimerRemainingSeconds
        if let remaining, remaining > 0 {
            beginLocalSleepTimerDisplay(remaining: remaining)
        } else if cachedSleepTimerRemaining != nil {
            stopLocalSleepTimerDisplay()
        }
    }

    @MainActor
    private func beginLocalSleepTimerDisplay(remaining: Int, deferImageSwap: Bool = false) {
        cachedSleepTimerRemaining = remaining
        playbackControlsView.applySleepTimerButtonAppearance(remaining: remaining, deferImageSwap: deferImageSwap)
        configureSleepTimerButtonMenu()

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
                self.playbackControlsView.applySleepTimerButtonAppearance(remaining: self.cachedSleepTimerRemaining)
            }
        }
    }

    @MainActor
    private func stopLocalSleepTimerDisplay() {
        sleepTimerDisplayTask?.cancel()
        sleepTimerDisplayTask = nil
        cachedSleepTimerRemaining = nil
        playbackControlsView.applySleepTimerButtonAppearance(remaining: nil)
        configureSleepTimerButtonMenu()
    }

    // MARK: - Privacy clear (Clear local playback state)
    // Wired from the destructive item in the sleep timer menu.
    // Uses the SSOT clearAllLocalState (engine stop + reset to .prePlay visual + .cleared intent
    // without persist, removes all local UD keys, ends LA, forces no-widgets gate, posts notification).
    // We drive the UI to clean .prePlay (no sticky .userPaused mixing) + reseed language selector
    // (device locale fallback) + rebuild menu. A transient confirmation status is shown using the
    // prePlay chrome so the destructive action has clear feedback without yellow "connecting".
    // Recently deleted data is not re-created by this action or the immediate post-clear launch
    // setup; it is only (re)created on explicit play or the successful post-clear cold-start play path.

    @MainActor
    private func confirmAndClearLocalState() {
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
                self.updateUI(for: .prePlay)
                // Transient confirmation using prePlay chrome (no grey userPaused for clear).
                self.playbackControlsView.setStatus(
                    text: String(localized: "clear_local_state_done", table: "Localizable"),
                    backgroundColor: .systemGray,
                    textColor: .white
                )
                await self.resetLanguageSelectorToInitialLocale()
                self.playHapticFeedback(style: .heavy)
                self.configureSleepTimerButtonMenu()
            }
        })
        presentAlert?(alert)
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
        languageSelectorView.notifyLayoutChange(currentSelectedIndex: selectedStreamIndex)
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
            // Post-clear launch: visual is deliberately .prePlay; the .cleared intent
            // blocks recovery. The cold-launch Task (post-guard) will drive the success path.
            #if DEBUG
            print("[RadioPlayerCoordinator] viewDidAppear → prePlay with .cleared intent (post-clear) → SKIPPING (cold launch will proceed)")
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
    func handleStatusChange(_ status: PlayerStatus, reasonKey: String?) async {
        let visualState = await SharedPlayerManager.shared.currentVisualState
        let playbackIntent = await SharedPlayerManager.shared.currentPlaybackIntent

        #if DEBUG
        print("[RadioPlayerCoordinator] onStatusChange → \(status) (reasonKey: \(reasonKey ?? "nil")) → visualState \(visualState)")
        #endif

        let effectiveVisualState: PlayerVisualState = {
            // .cleared (post-privacy-clear blocker) must never produce sticky .userPaused visuals
            // or block the post-clear cold-launch path. Treat it like a clean prePlay candidate so
            // early status_connecting from player init and post-clear launches see ready state
            // (no grey "paused cold" and no yellow flash mixing).
            if playbackIntent == .cleared {
                if (reasonKey == "status_connecting" || reasonKey == "status_buffering") && status != .playing {
                    return .prePlay
                }
                return .prePlay
            }

            if let reasonKey,
               (reasonKey == "status_connecting" || reasonKey == "status_buffering"),
               status != .playing {
                if visualState == .prePlay || visualState == .playing {
                    return visualState
                }
                if playbackIntent.isActivePlaybackIntent {
                    return .prePlay
                }
            }

            // Strong protection for explicit *user pause* (.userPaused visual or intent) on terminal
            // statuses (status_stopped etc. from KVO on live streams while paused). We must not
            // regress a grey paused UI to yellow "yhditää"/.prePlay. 
            // Post "Clear local state" the reset now uses .prePlay visual + .cleared intent (the
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

            if visualState == .userPaused || visualState == .prePlay {
                return visualState
            }
            return visualState
        }()

        self.updateUI(for: effectiveVisualState)

        // If we had to correct the UI to .userPaused for a real sticky user pause (despite the
        // actor having loaded a stale .prePlay), repair the in-memory SSOT immediately so that
        // any follow-on save uses the correct visual.
        // Never do this repair for .cleared (which intentionally uses .prePlay visual).
        if effectiveVisualState == .userPaused && visualState == .prePlay && playbackIntent == .userPaused {
            Task {
                await SharedPlayerManager.shared.setVisualState(.userPaused)
            }
        }

        if let reasonKey = reasonKey {
            if reasonKey == "status_ssl_transition" {
                let lbl = playbackControlsView.statusLabel
                lbl.backgroundColor = .systemOrange
                lbl.textColor = .white
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
                let lbl = playbackControlsView.statusLabel
                lbl.backgroundColor = .systemGray
                lbl.textColor = .white
                self.updateUIForNoInternet()

            } else if reasonKey == "status_stream_unavailable" || reasonKey == "status_failed" {
                let vsForCheck = await SharedPlayerManager.shared.currentVisualState
                if vsForCheck.isActivelyPlaying || vsForCheck == .prePlay {
                    await SharedPlayerManager.shared.markPlaybackStoppedByStreamFailure()
                }
                let correctedVisualState = await SharedPlayerManager.shared.currentVisualState
                self.updateUI(for: correctedVisualState)

                let reasonText = String(localized: String.LocalizationValue(reasonKey))
                playbackControlsView.setStatus(text: reasonText, backgroundColor: .systemRed, textColor: .white)

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
