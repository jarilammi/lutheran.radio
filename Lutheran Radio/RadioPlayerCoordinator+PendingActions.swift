//
//  RadioPlayerCoordinator+PendingActions.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 25.7.2026.
//
//  Pending-action drain domain for RadioPlayerCoordinator (mechanical split).
//
//  Owns: App Group `pendingAction*` processing after Darwin notify / SceneDelegate
//  become-active / foreground / launch burst; same-direction play/pause debounce;
//  UITestMode drain-without-execute; media-transport mailbox enqueue for extension
//  play/pause; widget play/pause helpers invoked by the drain.
//
//  Does not own: mailbox key names or writers (SharedPlayerManager / WidgetIntentExecution),
//  engine attach (DirectStreamingPlayer), security validation (Core), or widget switch
//  orchestration (`handleWidgetSwitchToLanguage` / `switchToStreamFromWidget` live in
//  `RadioPlayerCoordinator+StreamSwitch.swift`).
//
//  Public entry stays ``RadioPlayerCoordinator/checkForPendingWidgetActions()``. Lifecycle
//  hosts (ViewController Darwin listener, SceneDelegate) call thin shims only.
//
//  - SeeAlso: ``SharedPlayerManager/signalWidgetPendingAction(visualState:action:language:)``,
//    ``SharedPlayerManager/submitMediaTransportCommandAndWait(_:)``,
//    ``MediaTransportLatencyTimeline`` (DEBUG drain milestones),
//    docs/Live-Activity-Stacking-and-Media-Surfaces.md,
//    docs/Widget-Functionality-Roadmap.md,
//    CODING_AGENT.md (Single Source of Truth Principles).
//

import UIKit
import WidgetKit
import Core
import WidgetSurface

extension RadioPlayerCoordinator {

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
    /// UITestMode drain-without-execute, mailbox enqueue, and switch work-item cancel live here
    /// (this extension file). Stored debounce stamps live on the coordinator instance.
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
                // (Work item is owned on the coordinator — cancelled here before mailbox play.)
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

    // MARK: - Widget play/pause helpers (invoked by drain)

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
        // Visual SSOT is SharedPlayerManager; push chrome after mailbox pause completes.
        let newState = await SharedPlayerManager.shared.currentVisualState
        updateUI(for: newState)
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
    // SAFETY: DEBUG-only XCTest seam; written only from test setUp/tearDown on the main host.
    // Not concurrent with production drains outside the unit-test process.
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
