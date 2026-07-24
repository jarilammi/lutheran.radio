//
//  SharedPlayerManager+AppGroup.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 23.7.2026.
//
//  SHARED: Cross-target membership-exception source (main app + extension +
//  LutheranRadioWidgetTests). Mechanical split of SharedPlayerManager — same actor,
//  no API renames, no behavior change.
//
//  Purpose: Widget pending-action scheduling, Darwin notify, liveness heartbeat, and App Group save/load facades.
//
//  - SeeAlso: SharedPlayerManager.swift, CODING_AGENT.md (cross-target membership exceptions).
//

import Foundation
import Core
import WidgetSurface
#if LUTHERAN_MAIN_APP
import os
import WidgetKit
#endif

extension SharedPlayerManager {
    // MARK: - Widget Action Scheduling & Darwin Notifications (nonisolated)
    //
    // These methods schedule work for the main app via App Group + Darwin notifications.
    // They are deliberately nonisolated so widget intent handlers can call them without
    // crossing the actor boundary on the hot path.

    /// Writes the short-lived instant-feedback keys used by widget providers for optimistic UI.
    ///
    /// Also refreshes ``lastUpdateTime`` so providers treat the extension process as recently active
    /// for the interactive chrome window.
    ///
    /// - Parameter language: Language code shown during the optimistic window (must match the
    ///   widget timeline language when possible).
    /// - Precondition: Home-widget privacy gate open (`hasActiveWidgets`) **or** call is from a
    ///   widget/extension process (intent execution is proof a surface exists).
    /// - Postcondition: On success, `isInstantFeedback` / `instantFeedbackTime` /
    ///   `instantFeedbackLanguage` and a fresh `lastUpdateTime` are present in the App Group.
    ///   When suppressed, **no** keys are written (residuals are cleared only via privacy clear
    ///   or ``clearHomeWidgetLivenessAndInstantFeedbackResiduals()`` when the gate closes).
    /// - SeeAlso: ``bumpWidgetLivenessTimestamp(policy:minInterval:)``,
    ///   ``clearHomeWidgetLivenessAndInstantFeedbackResiduals()``,
    ///   ``loadSharedState()``, ``signalWidgetSwitchAction(visualState:language:)``,
    ///   CODING_AGENT.md (Single Source of Truth Principles).
    nonisolated static func writeInstantFeedback(language: String) {
        // Privacy gate (write suppression: no widgets configured).
        //
        // Bypass in widget process for the same reason as persistWidgetSnapshot: the executing
        // intent is proof a widget exists; we must allow the instantFeedbackLanguage + liveness
        // so loadSharedState + providers see fresh optimistic state without main-app roundtrip.
        guard Self.hasActiveWidgets || Self.isWidgetProcess() else {
            if !Self.isWidgetProcess() {
                Self.refreshHasActiveWidgetsStatus()
            }
            #if DEBUG
            print("[SharedPlayerManager] Suppressing instant feedback write (no active widgets configured — write suppression)")
            #endif
            return
        }
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return }
        let now = Date().timeIntervalSince1970
        // Liveness via the same privacy-gated helper (gate already passed above; immediate
        // stamp so interactive chrome is current after an extension action).
        Self.bumpWidgetLivenessTimestamp(policy: .immediate)
        defaults.set(true, forKey: "isInstantFeedback")
        defaults.set(now, forKey: "instantFeedbackTime")
        defaults.set(language, forKey: "instantFeedbackLanguage")
        // Explicit synchronize() removed — unnecessary for App Group + Darwin on iOS 26+.
    }

    /// Removes residual home-widget liveness and short-lived instant-feedback keys from the App Group.
    ///
    /// **Privacy residual hygiene:** When no Lutheran home/Control widgets are configured, or after
    /// an explicit privacy clear forces write suppression, `lastUpdateTime` and the three instant-
    /// feedback keys must not linger as operational "recent activity / recent language" signals.
    ///
    /// Does **not** touch:
    /// - Pending-action mailbox (`pendingAction*`, `pendingLanguage`) — first post-clear widget
    ///   intent must still deliver Darwin + pending when the main app is suspended
    /// - Durable Live Activity mirrors (`liveActivityToggleVisualState`, `liveActivityCurrentLanguage`)
    /// - Security caches (standard suite `lastSecurityValidation` and Core policy)
    /// - Retired visual keys (handled by ``clearPersistedVisualStateKeysFromDisk()``)
    ///
    /// - Postcondition: `lastUpdateTime`, `isInstantFeedback`, `instantFeedbackTime`, and
    ///   `instantFeedbackLanguage` are absent from the App Group suite (if available).
    /// - SeeAlso: ``removeAllLocalPlaybackKeys()``, ``writeInstantFeedback(language:)``,
    ///   ``bumpWidgetLivenessTimestamp(policy:minInterval:)``,
    ///   ``WidgetRefreshManager/setHasActiveLutheranWidgets(_:)``,
    ///   CODING_AGENT.md (Single Source of Truth Principles).
    ///
    /// AGENT NOTE: Call when the home-widget privacy gate closes. Privacy clear also removes
    /// these keys via ``removeAllLocalPlaybackKeys()`` (same set). Widget-process one-shot
    /// writes after re-add remain allowed via ``isWidgetProcess()`` bypasses on bump/instant.
    nonisolated static func clearHomeWidgetLivenessAndInstantFeedbackResiduals() {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return }
        defaults.removeObject(forKey: "lastUpdateTime")
        defaults.removeObject(forKey: "isInstantFeedback")
        defaults.removeObject(forKey: "instantFeedbackTime")
        defaults.removeObject(forKey: "instantFeedbackLanguage")
        #if DEBUG
        print("[SharedPlayerManager] Cleared home-widget liveness + instant-feedback residuals (privacy / no-widgets)")
        #endif
    }

    /// Write cadence for the home-widget liveness heartbeat (`lastUpdateTime`).
    ///
    /// Chooses only whether a privacy-allowed write is coalesced or stamped now. Orthogonal to:
    /// - the home-widget privacy gate (``hasActiveWidgets`` / widget-process bypass)
    /// - `PlayerEvent` emission and non-forcing refresh rules
    /// - termination sentinel writes (``forceStaleLivenessTimestampForTermination()``)
    ///
    /// - SeeAlso: ``bumpWidgetLivenessTimestamp(policy:minInterval:)``,
    ///   ``isMainAppProcessRecentlyActive()``, CODING_AGENT.md (Single Source of Truth Principles).
    enum WidgetLivenessWritePolicy: Sendable {
        /// Coalesce under `minInterval` (KVO / unchanged-snapshot heartbeats).
        case throttled
        /// Stamp `lastUpdateTime` now (language change, widget intent, fg/bg lifecycle edge).
        case immediate
    }

    /// Refreshes the App Group `lastUpdateTime` heartbeat used by widget `isAppRunning()` (60 s window).
    ///
    /// Default ``WidgetLivenessWritePolicy/throttled`` coalesces under `minInterval` so unchanged-snapshot
    /// save skips do not spam UserDefaults on every KVO tick. ``WidgetLivenessWritePolicy/immediate``
    /// stamps now for language-edge, widget-action, and lifecycle edges so interactive chrome does not
    /// lag. This surface is orthogonal to the `PlayerEvent` stream; it only informs passive vs
    /// interactive widget presentation.
    ///
    /// **Privacy:** Suppressed when ``hasActiveWidgets`` is false **unless** the call runs in a
    /// widget/extension process (intent proof). Main-app call sites (including language changes)
    /// must use this helper rather than writing `lastUpdateTime` directly so residual signals
    /// cannot reappear after privacy clear or with no home widgets.
    ///
    /// - Parameters:
    ///   - policy: ``.throttled`` (default) respects `minInterval`; ``.immediate`` always stamps when allowed.
    ///   - minInterval: Minimum seconds between throttled writes (default 30). Ignored for `.immediate`.
    /// - SeeAlso: ``WidgetLivenessWritePolicy``, ``forceStaleLivenessTimestampForTermination()``,
    ///   ``isMainAppProcessRecentlyActive()``,
    ///   ``clearHomeWidgetLivenessAndInstantFeedbackResiduals()``,
    ///   ``events``, docs/Event-Driven-Refactor-Roadmap.md.
    nonisolated static func bumpWidgetLivenessTimestamp(
        policy: WidgetLivenessWritePolicy = .throttled,
        minInterval: TimeInterval = 30
    ) {
        // Privacy gate: suppress liveness timestamp (and thus "app was recently running" signal) when no widgets installed.
        //
        // Bypass when in widget process: widget intent (play/pause) must bump lastUpdateTime so that
        // isAppRunning() (used by all widget sizes to decide between controls vs "tap_to_open") returns
        // true immediately. Without this, tapping play on a widget could leave the widget stuck showing
        // the tap prompt even while audio plays.
        guard Self.hasActiveWidgets || Self.isWidgetProcess() else {
            #if DEBUG
            print("[SharedPlayerManager] Suppressing liveness timestamp bump (no active widgets — write suppression)")
            #endif
            return
        }
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return }
        let now = Date().timeIntervalSince1970
        if policy == .throttled,
           let last = defaults.object(forKey: "lastUpdateTime") as? Double,
           now - last < minInterval {
            return
        }
        defaults.set(now, forKey: "lastUpdateTime")
        // Explicit synchronize() removed — unnecessary for App Group + Darwin on iOS 26+.
    }

    /// Immediate liveness stamp for lifecycle edges (background, foreground) where the widget
    /// must not flip to the offline prompt while audio continues.
    ///
    /// Uses ``WidgetLivenessWritePolicy/immediate`` only — still privacy-gated and non-forcing
    /// with respect to `PlayerEvent` / WidgetCenter.
    func recordWidgetLiveness() {
        Self.bumpWidgetLivenessTimestamp(policy: .immediate)
    }

    // MARK: - Widget / Live Activity Liveness Heuristic & Termination Cleanup (SSOT)

    /// Returns true if the main app process has signaled it is recently active via the
    /// `lastUpdateTime` heartbeat (within the 60 s window).
    ///
    /// This is the **single source of truth** for the widget "active UI vs. passive launch prompt"
    /// decision. Widget family views (Small/Medium/Large) use it to choose between rendering
    /// full status + PlayerControlPresentation buttons + flag grid (when true) vs. the
    /// "tap_to_open" icon + `widgetURL(URL(string: "lutheranradio://open"))` (when false).
    ///
    /// **Lifecycle contract (Cleanup Invariant)**:
    /// - While the main app process is alive (foreground or background audio), saves, fg/bg
    ///   transitions, and explicit liveness calls keep the timestamp recent → widgets render
    ///   interactive controls.
    /// - On observed main-app termination (applicationWillTerminate, sceneDidDisconnect,
    ///   willTerminateNotification), the main process **must** call
    ///   `forceStaleLivenessTimestampForTermination()` which sets the sentinel value 0.
    ///   Subsequent widget renders (system timelines or explicit) immediately see false and
    ///   render the stable passive "tap to open" surface.
    /// - Force-quit (no notification delivered) relies on natural aging + absence of further
    ///   main-process bumps/reloads. Worst case 60 s of "active" presentation.
    /// - Widget/App Intent processes may bump via the `isWidgetProcess()` bypass inside
    ///   `bumpWidgetLivenessTimestamp` only for their own optimistic feedback; they do not
    ///   keep the main app alive.
    /// - The passive path only launches the app via Apple-approved mechanisms (widgetURL,
    ///   Live Activity tap "open", or AppIntent surfaces marked `.openAppWhenRun`). No
    ///   implicit play, no reload side-effects, no resurrection.
    ///
    /// - Important: This is a *presentation heuristic only*. Never use for playback intent,
    ///   resurrection guards, or security decisions. Those use `PersistedWidgetState`,
    ///   `currentPlaybackIntent`, and `PlayerVisualState` directly.
    /// - Returns: `false` for missing key, explicit termination sentinel (0), or stale (>60 s).
    /// - Note: 60 s matches the original widget `isAppRunning` window; keep in sync.
    /// - SeeAlso: ``bumpWidgetLivenessTimestamp(policy:minInterval:)``,
    ///   ``forceStaleLivenessTimestampForTermination()``, `LutheranRadioWidget.swift`
    ///   (the `if !isAppRunning()` branches and `widgetURL`), `WidgetRefreshManager`,
    ///   CODING_AGENT.md (Single Source of Truth Principles + cross-target shared files),
    ///   docs/Widget-Presentation-Dataflow.md (App Termination section).
    ///
    /// AGENT NOTE: Any change to the 60 s constant, sentinel value, or the decision here
    /// must also update the widget view branches, the termination call sites, and this doc.
    nonisolated static func isMainAppProcessRecentlyActive() -> Bool {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return false }
        guard let lastUpdate = defaults.object(forKey: "lastUpdateTime") as? Double else { return false }
        if lastUpdate == 0 { return false } // explicit termination sentinel written on quit paths
        return Date().timeIntervalSince1970 - lastUpdate < 60
    }

    /// Returns true when `lastUpdateTime` is the explicit termination sentinel value (0).
    ///
    /// - Returns: `true` only when the key exists *and* equals exactly 0.0 (written by
    ///   `forceStaleLivenessTimestampForTermination` on willTerminate / disconnect paths).
    /// - Note: Brand-new installs (missing key) and normal idle (positive timestamp, even if >60 s)
    ///   return `false`. Only the deliberate termination marker returns `true`.
    ///
    /// This is the **post-termination liveness heuristic** used in combination with
    /// `currentPlaybackIntent.isStickyPauseOrLock` to provide a hard blocker against
    /// unwanted auto-play / tuning sound on device power-up or wake while a Live Activity
    /// (or widget surface) remains visible on the Lock Screen.
    ///
    /// **Why this exists**: Termination of the main process (even if a paused or playing LA
    /// was present) must be treated as the end of any prior playback intent. Subsequent
    /// wakes must not cause `DirectStreamingPlayer` side effects. Widgets/LAs may still
    /// render last-known visuals or passive "tap to open", and may schedule pending actions
    /// or post Darwin notifications, but they (and launch paths) must never start audio.
    ///
    /// - Precondition: Callers combine this with intent checks or the explicit-play flag
    ///   (see `hasProcessedExplicitUserPlayRequest`).
    /// - SeeAlso: ``isMainAppProcessRecentlyActive()``, ``forceStaleLivenessTimestampForTermination()``,
    ///   ``play()``, ``restoreVisualStateRespectingUserIntent()``, ``attemptResurrectionIfAllowed()``,
    ///   ViewController (cold-launch guard before tuning), CODING_AGENT.md (SSOT + resurrection),
    ///   <doc:Architecture>.
    ///
    /// AGENT NOTE: This + sticky intent is the required combined blocker on *every*
    /// auto-resume / state-restore / wake path. Update all such sites + the resurrection
    /// table when changing. Never bypass for LA-visible cases.
    nonisolated static func hasExplicitTerminationSentinel() -> Bool {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return false }
        guard let lastUpdate = defaults.object(forKey: "lastUpdateTime") as? Double else { return false }
        return lastUpdate == 0
    }

    /// Forces the widget liveness timestamp to the explicit termination sentinel (0).
    ///
    /// **Legacy termination surface** (liveness heuristic only). Call this from main-app
    /// termination paths only. It makes ``isMainAppProcessRecentlyActive()`` return false
    /// on the next widget provider execution so all surfaces render the passive,
    /// launch-only UI ("tap to open") immediately rather than showing stale active controls.
    ///
    /// Also clears short-lived instant-feedback keys so no "just acted" optimistic state
    /// survives the quit visually.
    ///
    /// This heuristic is separate from the `PlayerEvent` emission model. Event subscribers
    /// learn about termination via process lifetime; widgets use the sentinel for their
    /// render decision.
    ///
    /// **Cleanup Invariant**: After this call (on any observed termination), widget timelines
    /// and Live Activity (which we also end) must not present interactive controls or cause
    /// the widget extension to believe the main process can service updates. Only Apple-approved
    /// launch surfaces remain functional.
    ///
    /// Safe to call from willTerminate (synchronous context) — only touches UserDefaults.
    ///
    /// - Note: Does **not** remove `persistedWidgetState` (last-known visual + language +
    ///   metadata remain for providers that fall back and for clean relaunch). Contrast with
    ///   `removeAllLocalPlaybackKeys` (privacy clear).
    /// - SeeAlso: ``isMainAppProcessRecentlyActive()``, AppDelegate.applicationWillTerminate,
    ///   SceneDelegate.sceneDidDisconnect, RadioLiveActivityManager.handleAppWillTerminate,
    ///   ``removeAllLocalPlaybackKeys()``,
    ///   docs/Event-Driven-Refactor-Roadmap.md.
    nonisolated static func forceStaleLivenessTimestampForTermination() {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return }
        defaults.set(0.0, forKey: "lastUpdateTime")
        // Clear optimistic transients so the widget does not flash a stale "just played" state
        // on its next render after the main process has died.
        defaults.removeObject(forKey: "isInstantFeedback")
        defaults.removeObject(forKey: "instantFeedbackTime")
        defaults.removeObject(forKey: "instantFeedbackLanguage")
        // Visual state is memory-only; no on-disk snapshot to preserve across termination.
        // LA ends on termination — drop durable toggle visual + language mirrors so a cold
        // extension cannot plan pause/play or stamp language chrome from a dead surface.
        clearLiveActivityToggleVisualStateMirror()
        clearLiveActivityLanguageMirror()
        #if DEBUG
        print("[SharedPlayerManager] Forced stale lastUpdateTime (0) + cleared instant feedback for post-termination passive widget state")
        #endif
    }

}

// MARK: - UserDefaults Communication
extension SharedPlayerManager {
    
    /// Persists the current visual + language + error + metadata state to the App Group snapshot.
    ///
    /// This is the **primary authoritative writer** from the main app. It is driven by
    /// player KVO/status changes, explicit play/pause/switch paths, and lifecycle events.
    /// Widget and Live Activity consumers should read via `loadPersistedWidgetState()` (or
    /// the `loadSharedState` facade) rather than calling this.
    ///
    /// - Important: Language derivation is pure via ``PersistedLanguageResolution/resolve``:
    ///   preferredWidgetLanguage → no-snapshot model repair → stale `"en"` repair →
    ///   stream-switch hold prefers Direct model (already updated by switch prep).
    ///   That closes the race that caused widget language taps to revert to the previous stream.
    ///
    /// - Postcondition: If a write occurs, the in-process session snapshot contains the latest
    ///   (visualState, currentLanguage, hasError, metadata). Widget timeline reload is scheduled
    ///   by the Tier 2 ``PlayerEvent`` observer (``.persistedWidgetStateDidUpdate`` and related cases).
    ///
    /// - SeeAlso: ``PersistedLanguageResolution``, ``performActualSave(_:widgetState:at:)``,
    ///   ``preferredWidgetLanguage()``,
    ///   ``persistWidgetSnapshot(visualState:language:streamMetadata:clearStreamMetadata:hasError:)``,
    ///   ``loadPersistedWidgetState()``, CODING_AGENT.md (Single Source of Truth Principles),
    ///   the resurrection and persistence tables in this file.
    ///
    /// Actor-isolated. Callers on the main path must `await`.
    // Now async – callers must await this when they want to save
    func saveCurrentState() async {
        guard !isRunningInWidget() else { return }
        
        let player = DirectStreamingPlayer.shared
        
        let now = Date()
        
        // Pure language reconciliation (table-tested in WidgetSurface). Actor only gathers inputs.
        // Privacy write suppression remains in performActualSave — resolution never decides write.
        let snapshot = Self.loadPersistedWidgetState()
        let currentLanguageCode = PersistedLanguageResolution.resolve(
            preferredLanguage: Self.preferredWidgetLanguage(),
            hasSnapshot: snapshot != nil,
            snapshotLanguage: snapshot?.currentLanguage,
            modelLanguage: DirectStreamingPlayer.shared.selectedStream.languageCode,
            streamSwitchHoldActive: holdPrePlayVisualUntilPlayback
        )

        let isPermanentError    = await player.isLastErrorPermanent()
        // Source the legacy "playing" bool from the authoritative visual state (SSOT),
        // not the racy snapshot in actualPlaybackState. The snapshot frequently returns
        // false during normal playback (KVO timing, brief buffering, rate reads) causing
        // the "playing" UserDefaults key (used by WidgetToggleRadioIntent decision logic
        // and loadSharedState fallbacks) to be wrong. This was the "elsewhere" causing
        // first-widget-interaction flakiness even after the pause throttle fix.
        let isPlaying           = currentVisualState.isActivelyPlaying
        let hasPermanentError   = player.hasPermanentError
        
        // === NEW: WidgetState is now a computed view of PlayerVisualState (SSOT) ===
        let widgetState = WidgetState(
            from: currentVisualState,                  // ← SharedPlayerManager's SSOT
            currentLanguage: currentLanguageCode,
            hasError: hasPermanentError || isPermanentError,
            isTransitioning: false
        )
        
        let currentState = (
            isPlaying: isPlaying,
            currentLanguage: currentLanguageCode,
            hasError: hasPermanentError || isPermanentError
        )
        
        performActualSave(currentState, widgetState: widgetState, at: now)
    }
    
    nonisolated func saveFireAndForget() {
        Task {
            await saveCurrentState()
        }
    }
    
    internal func performActualSave(_ state: (isPlaying: Bool, currentLanguage: String, hasError: Bool),
                                   widgetState: WidgetState,
                                   at _: Date) {
        // Privacy gate: when !hasActiveWidgets we suppress all the legacy + snapshot writes
        // (savePersisted is also guarded, but we avoid the work and the downstream refreshIfNeeded scheduling).
        guard Self.hasActiveWidgets else {
            #if DEBUG
            print("[SharedPlayerManager] Suppressing performActualSave writes + refresh scheduling (no active widgets — write suppression)")
            #endif
            return
        }

        let previousSnapshot = Self.loadPersistedWidgetState()
        let previousLanguage = previousSnapshot?.currentLanguage ?? ""
        let isLanguageChange = !previousLanguage.isEmpty && previousLanguage != state.currentLanguage

        let previousHasError = previousSnapshot?.hasError ?? false
        let previousIsPlaying = previousSnapshot?.visualState.isActivelyPlaying ?? false

        let metadataUnchanged = previousSnapshot?.streamMetadata == currentStreamMetadata
        let snapshotUnchanged =
            previousSnapshot?.visualState == currentVisualState &&
            previousSnapshot?.currentLanguage == state.currentLanguage &&
            previousHasError == state.hasError &&
            previousIsPlaying == state.isPlaying &&
            metadataUnchanged

        // Urgent refresh for errors, language changes, or the first transition into sticky
        // pause/security lock — not on every KVO save while already `.userPaused`.
        let visualStateChanged = previousSnapshot?.visualState != currentVisualState
        let isTransitionToStickyPause = visualStateChanged && currentVisualState.mustSuppressResurrection
        // Widget optimistic pause may pre-write .userPaused; still urgent when isPlaying flips false.
        let isPlayingStopped = previousIsPlaying && !state.isPlaying
        let isUrgentUpdate = state.hasError || isLanguageChange || isTransitionToStickyPause || isPlayingStopped

        if snapshotUnchanged && !isUrgentUpdate {
            Self.bumpWidgetLivenessTimestamp()
            #if DEBUG
            print("[SharedPlayerManager] performActualSave: snapshot unchanged — skipping persist")
            #endif
            return
        }

        // Persist the authoritative (visualState + language + hasError) snapshot.
        // Widget providers and Live Activities take the early loadPersistedWidgetState() path.
        // hasError is now carried in the snapshot so loadSharedState can derive exclusively
        // from it (plus direct player state where appropriate in the main app).
        savePersistedWidgetState(
            visualState: Self.visualStateForPersistenceWrite(currentVisualState),
            language: state.currentLanguage,
            streamMetadata: currentStreamMetadata,
            hasError: state.hasError
        )

        // Liveness via privacy-gated helper (60 s "isAppRunning" heuristic). Outer
        // `hasActiveWidgets` guard already returned when suppressed; stamp immediately on real saves.
        Self.bumpWidgetLivenessTimestamp(policy: .immediate)

        // Clear instant feedback flags (still required for widget responsiveness)
        sharedDefaults?.removeObject(forKey: "isInstantFeedback")
        sharedDefaults?.removeObject(forKey: "instantFeedbackTime")
        sharedDefaults?.removeObject(forKey: "instantFeedbackLanguage")

        // Always hop to MainActor for WidgetRefreshManager (required in Swift 6)
        Task { @MainActor in
            if visualStateChanged {
                WidgetRefreshManager.shared.cancelPendingRefresh()
            }
            // Widget timeline reload is driven by the Tier 2 ``PlayerEvent`` observer
            // (``.visualStateDidChange``, ``.persistedWidgetStateDidUpdate``, stream verbs, etc.)
            // which routes through ``WidgetRefreshManager/handlePlayerEvent(_:)`` with urgency
            // parity via ``refreshUsesImmediateDelivery(for:hasError:)``. Imperative
            // Imperative ``refreshIfNeeded`` removed: mutation-path reloads are driven solely by
            // the Tier 2 observer (``handlePlayerEvent`` / ``WidgetRefreshTrigger/playerEvent``).

            // Live Activity refresh (parallel to widget timeline reload).
            // The call goes through the manager's change detection (lastPushedContent).
            // This path exists for widget parity (a visual save always gives LA a chance
            // to catch up). The common fast path for LA is the direct event calls from
            // setPlaying / didUpdateStreamMetadata etc. which read in-memory state.
            // No disk I/O is performed inside the Live Activity update itself.
            #if LUTHERAN_MAIN_APP
            await RadioLiveActivityManager.shared.updateCurrentActivity()
            #endif
        }

        #if DEBUG
        print("[SharedPlayerManager] State saved: playing=\(state.isPlaying), language=\(state.currentLanguage)")
        #endif
    }
    
    nonisolated func loadSharedState() -> (isPlaying: Bool, currentLanguage: String, hasError: Bool) {
        // Check for instant feedback state first
        if let instantFeedbackTime = sharedDefaults?.object(forKey: "instantFeedbackTime") as? Double,
           let instantFeedbackLanguage = sharedDefaults?.string(forKey: "instantFeedbackLanguage"),
           sharedDefaults?.bool(forKey: "isInstantFeedback") == true {
            
            let age = Date().timeIntervalSince1970 - instantFeedbackTime
            
            // Use the documented instant-feedback timeout.
            if age < Constants.instantFeedbackTimeout {
                // Prefer the just-written PersistedWidgetState snapshot (SSOT) for both
                // isPlaying and hasError.
                let persisted = Self.loadPersistedWidgetState()
                let isPlaying = persisted?.visualState.isActivelyPlaying ?? false
                let hasError = persisted?.hasError ?? false
                
                #if DEBUG
                print("[SharedPlayerManager] Using instant feedback state: \(instantFeedbackLanguage), age: \(age)s")
                #endif
                
                return (isPlaying, instantFeedbackLanguage, hasError)
            } else {
                // Clear expired instant feedback
                sharedDefaults?.removeObject(forKey: "isInstantFeedback")
                sharedDefaults?.removeObject(forKey: "instantFeedbackTime")
                sharedDefaults?.removeObject(forKey: "instantFeedbackLanguage")
                
                #if DEBUG
                print("[SharedPlayerManager] Cleared expired instant feedback (age: \(age)s)")
                #endif
            }
        }
        
        // Normal path: playback chrome and hasError from the in-process session snapshot only.
        // Language via preferredWidgetLanguage() (snapshot → bestInitial when widgets active → "en").
        let persisted = Self.loadPersistedWidgetState()
        let isPlaying = persisted?.visualState.isActivelyPlaying ?? false
        let hasError = persisted?.hasError ?? false
        let currentLanguage = Self.preferredWidgetLanguage()
        return (isPlaying, currentLanguage, hasError)
    }

    #if LUTHERAN_MAIN_APP
    /// Pauses playback when the sleep timer elapses.
    ///
    /// - Sets `currentVisualState = .userPaused` (so widgets/Live Activities render paused)
    ///   while `playbackIntent` remains `.sleepTimer` (non-sticky; distinguishable from
    ///   explicit `.userPaused` for resurrection and clear-lock logic).
    /// - Stops the engine with `reason: .interruption` (deliberately silent: no status
    ///   emission, teardown guard suppresses KVO).
    /// - Writes the PersistedWidgetState snapshot immediately.
    /// - Posts Darwin "pause" (primarily to wake widget providers) and the
    ///   `SleepTimerNotification.stateDidChange` (isActive=false) for main-app glue.
    ///
    /// **Main-app UI sync contract**:
    /// The live in-app visuals (RadioPlayerCoordinator + PlayerViewModel) are **not**
    /// updated by a status callback or by processing the Darwin pause (both are
    /// suppressed for this internal path). The `SleepTimerNotification` observer in the
    /// coordinator is responsible for pulling `currentVisualState` and calling
    /// `updateUI(for:)` after this method posts the inactive notification.
    ///
    /// - Precondition: Must only be called from the sleep timer task (after countdown
    ///   reaches zero and not cancelled).
    /// - Postcondition: `currentVisualState == .userPaused`, `currentPlaybackIntent == .sleepTimer`,
    ///   player is stopped, snapshot persisted, notifications posted.
    /// - Note: Does not set `lastUserPauseTimestamp` (contrast with `stop()` / `markAsUserPaused`).
    ///
    /// - SeeAlso: ``RadioPlayerCoordinator/sleepTimerStateDidChange(_:)``,
    ///   ``PlaybackIntent/sleepTimer``, ``currentVisualState``, ``saveCurrentState()``,
    ///   `DirectStreamingPlayer.stop(reason:)`, CODING_AGENT.md (Single Source of Truth Principles),
    ///   SharedPlayerManager.swift (resurrection protection table + "sleepTimer" intent rules).
    ///
    /// AGENT NOTE: Any future change to stop reason, Darwin posting, or suppression guards
    /// here must also update the observer in RadioPlayerCoordinator so the main-app visual
    /// (green → grey) continues to match the SSOT. Widgets are protected by the snapshot write.
    func applySleepTimerElapsedPause() async {
        ensureVisualStateLoaded()

        applyVisualState(.userPaused)
        updatePlaybackIntent(to: .sleepTimer)

        DirectStreamingPlayer.shared.stop(reason: .interruption)

        // Use canonical clear (emits metadataDidUpdate(nil)). Distinct from language stash.
        _clearIcyMetadataStash()

        await saveCurrentState()
        notifyMainApp(action: "pause")
        await updateNowPlayingInfo()

        await SleepTimerNotification.postStateChange(isActive: false)

        #if DEBUG
        print("[SharedPlayerManager] SleepTimer elapsed — paused with .sleepTimer intent (not sticky .userPaused)")
        #endif
    }
    #endif
}
