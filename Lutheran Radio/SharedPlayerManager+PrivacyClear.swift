//
//  SharedPlayerManager+PrivacyClear.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 23.7.2026.
//
//  SHARED: Cross-target membership-exception source (main app + extension +
//  LutheranRadioWidgetTests). Mechanical split of SharedPlayerManager — same actor.
//
//  Purpose: Privacy clear of local playback keys and full local-state reset orchestration.
//  After clear, write suppression stays held closed until foreground WidgetCenter detect.
//  Home timeline wake must paint factory from absent keys — not session Connecting
//  (``.prePlay``) and not leftover last-stream language.
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

// MARK: - Privacy: Clear Local Playback State and Write Suppression
//
// These entry points implement the user-initiated "Clear local playback state".
// It removes recent playback/widget/Live Activity signals from the App Group and holds
// write suppression closed until the next foreground WidgetCenter detect.
//
// - removeAllLocalPlaybackKeys is nonisolated static (safe for widget/extension call sites in future).
// - clearAllLocalState is the @MainActor entry point used from UI (sleep timer menu / clear action etc.).
//   The timer preset/cancel UI itself is a SwiftUI confirmationDialog; the cancel + set paths still flow through here.
// - Intentionally reuses stop() + cancelSleepTimer() + the no-persist reset helper.
// - Never touches Core security keys (see explicit list in removeAllLocalPlaybackKeys).
extension SharedPlayerManager {
    /// Clears all local playback, widget snapshot, sleep, and optimistic intent state from the App Group.
    /// Does not affect security data or Core state.
    ///
    /// Does **not** touch:
    /// - "lastSecurityValidation" (Core DNS TXT 1-hour success cache — required for secure launch & streaming)
    /// - Any keys written by SecurityModelValidator / Core security
    /// - Certificate pinning data, app version, migration flags, or launch-critical state
    ///
    /// The clear always removes the primary snapshot even if widgets are configured (user explicitly requested it).
    /// After clear, `loadPersistedWidgetState()` returns nil and providers fall back to safe .prePlay / "en".
    /// Liveness + instant-feedback residuals are removed via
    /// ``clearHomeWidgetLivenessAndInstantFeedbackResiduals()`` (same helper as privacy-gate close).
    ///
    /// - SeeAlso: ``clearAllLocalState()``, ``clearHomeWidgetLivenessAndInstantFeedbackResiduals()``,
    ///   ``clearHomeWidgetStreamMetadataMirror()``, ``clearHomeWidgetLiveChromeMirror()``,
    ///   ``clearPersistedVisualStateKeysFromDisk()``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§7), CODING_AGENT.md.
    nonisolated static func removeAllLocalPlaybackKeys() {
        clearInMemorySessionSnapshot()
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return }

        // Retired visual/playback/language + orphan operational keys
        // (persistedWidgetState, isPlaying, bare currentLanguage, lastUserPauseTime, preferredVolume, …).
        clearPersistedVisualStateKeysFromDisk()

        // Liveness + optimistic instant feedback (shared residual helper used when the privacy
        // gate closes without a full clear as well).
        clearHomeWidgetLivenessAndInstantFeedbackResiduals()

        // Pending intent keys (these can leak "I just interacted").
        // Unconditional mailbox clear + re-arm so mid-session privacy clear does not leave the
        // main process stuck refusing legitimate later widget intents.
        clearPendingActionMailbox()
        // SAFETY: Process-local re-arm of nonisolated(unsafe) gate after mailbox clear; same
        // contract as ``discardResidualPendingActionsAndArmMailboxForThisProcess()``.
        unsafe pendingActionMailboxAcceptingExecution = true

        // Live Activity toggle visual + language mirrors (cross-process signals; privacy clear ends LA).
        defaults.removeObject(forKey: liveActivityToggleVisualStateAppGroupKey)
        defaults.removeObject(forKey: liveActivityCurrentLanguageAppGroupKey)
        // Privacy-gated home program-metadata + live-chrome mirrors (extension Provider chrome).
        defaults.removeObject(forKey: homeWidgetStreamMetadataAppGroupKey)
        clearHomeWidgetLiveChromeMirror()
        // Boot identity used only for post-reboot LA plan distrust; drop on privacy clear.
        defaults.removeObject(forKey: recordedSystemBootTimeAppGroupKey)

        // Explicit synchronize() removed — unnecessary (removals are visible cross-process
        // via subsequent loads and notifications; privacy clear is not performance-critical).

        #if DEBUG
        print("[SharedPlayerManager] Removed all local playback/widget keys (privacy clear)")
        #endif
    }

    /// Full clear entry point (call this). Stops playback (silent), resets actor SSOT state to
    /// .cleared visual + .cleared intent, removes persisted keys (including the snapshot), ends Live
    /// Activity, cancels sleep, notifies observers. Main UI gets blue "Cleared" pill immediately;
    /// widgets (no snapshot + write suppression) fall back to factory from **absent** keys.
    ///
    /// Write suppression stays **held closed** after this call: teardown
    /// ``WidgetRefreshManager/performRefresh(for:)`` and opportunistic
    /// ``refreshHasActiveWidgetsStatus()`` must not reopen ``hasActiveLutheranWidgets``
    /// while widgets remain on the Home Screen. SceneDelegate lifts the hold on
    /// become-active / enter-foreground, then ``refreshHasActiveWidgets()`` may detect
    /// again. Timeline reload after clear still wakes Home so Providers paint factory
    /// from **absent** keys — not session Connecting (``.prePlay``) and not leftover
    /// last-stream language. The engine model reseeds to
    /// ``preferredMainAppInitialLanguageCode()`` before that wake so coordinator
    /// ``setSelectedStreamModelOnly`` is not racing leftover attach language into
    /// ``WidgetRefreshManager`` bookkeeping.
    ///
    /// After this call visual is `.cleared`. Resign-active consults
    /// ``resignActiveSessionTeardownDecision()`` and does not run a second
    /// ``performSessionAndWidgetTeardown`` (that would immediately end the Live
    /// Activity this path already dismissed gracefully).
    ///
    /// - Important: After this call `loadPersistedWidgetState()` returns nil until the next
    ///   explicit play or widget-driven write.
    /// - Important: Gate-open restamp and ``saveCurrentState()`` treat in-session ``.cleared``
    ///   as factory for home chrome (no live-chrome / last-stream projection). The hold
    ///   additionally blocks WidgetCenter true-detect restamp until foreground.
    /// - Important: Does **not** skip session teardown for ordinary factory Connecting
    ///   ``.prePlay`` (cold launch / idle). Only the privacy-cleared visual/intent pair
    ///   suppresses Connecting + last-stream home payload.
    ///
    /// Must be called from @MainActor (UI surfaces, coordinator). Internally hops for actor work.
    ///
    /// - SeeAlso: ``removeAllLocalPlaybackKeys()``, ``resetStateToClearedForPrivacy()``,
    ///   ``WidgetRefreshManager/holdPrivacyClearWriteSuppressionClosedUntilForeground()``,
    ///   ``WidgetRefreshManager/applyDetectedWidgetPresence(_:)``,
    ///   ``WidgetRefreshManager/liftPrivacyClearWriteSuppressionHoldForForegroundDetect()``,
    ///   ``restampHomeWidgetLiveChromeAfterPrivacyGateOpenIfNeeded()``,
    ///   ``resignActiveSessionTeardownDecision()``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§7),
    ///   docs/Widget-Presentation-Dataflow.md (Cleanup Invariant),
    ///   CODING_AGENT.md.
    @MainActor
    static func clearAllLocalState() async {
        // 1. Stop the engine directly (silent) without going through SharedPlayerManager.stop().
        // Shared.stop() would force .userPaused visual + intent + early saves, which we must avoid
        // so that post-clear in-process UI and any status callbacks during clear do not mix sticky
        // paused semantics. The .cleared intent (set in the subsequent reset) is the blocker.
        // Await soft/hard silence so subsequent privacy clears do not race a still-audible engine.
        #if LUTHERAN_MAIN_APP
        await DirectStreamingPlayer.shared.stopAndWait(
            reason: .userAction,
            silent: true,
            applyUserPauseVisualLock: false
        )
        #endif

        // 2. Cancel sleep (also clears internal task + posts its own notification)
        #if LUTHERAN_MAIN_APP
        await Self.shared.cancelSleepTimer(restorePlaybackIntent: false, notifyStateChange: true)
        #endif

        // 3. Close the home-widget write gate and hold it before in-memory reset emits
        // ``PlayerEvent``s. Snapshot-absent metadata/stop events otherwise derive
        // Connecting ``.prePlay`` plus leftover attach language, and a deferred
        // ``.prePlay`` coalesce can execute after the teardown ``.cleared`` wake.
        // Hold also cancels in-flight Connecting reloads from the session just cleared.
        WidgetRefreshManager.setHasActiveLutheranWidgets(false)
        WidgetRefreshManager.holdPrivacyClearWriteSuppressionClosedUntilForeground()
        #if DEBUG
        print("[SharedPlayerManager] hasActiveWidgets forced false after privacy clear (hold-closed until foreground detect)")
        #endif

        // 4. Reset in-memory SSOT (visual + intent + metadata). Use the dedicated no-persist helper
        // (public resetToPrePlayForNewStream would re-persist a snapshot we are trying to erase).
        await Self.shared.resetStateToClearedForPrivacy()

        // 5. Wipe the UD keys (works cross-process for widgets + Live Activities)
        Self.removeAllLocalPlaybackKeys()

        // 6. Reseed the engine model to the locale initial stream *before* the teardown
        // timeline wake. Coordinator ``resetLanguageSelectorToInitialLocale`` still
        // updates the in-app selector after this returns (idempotent model-only).
        #if LUTHERAN_MAIN_APP
        let reseedCode = preferredMainAppInitialLanguageCode()
        await DirectStreamingPlayer.shared.setSelectedStreamModelOnly(
            to: DirectStreamingPlayer.streamForLanguageCode(reseedCode)
        )
        #endif

        // 7–7b. Session + widget teardown (Now Playing, LA graceful end, immediate widget reload to .cleared).
        #if LUTHERAN_MAIN_APP
        await Self.shared.performSessionAndWidgetTeardown(
            includeFactoryReset: false,
            liveActivityTeardown: .graceful,
            refreshWidgets: true,
            widgetVisualState: .cleared,
            staleLiveness: false
        )
        #endif

        // 8. Notify (widgets, Live Activities, UI coordinator, SceneDelegate etc. can react and fall back to defaults)
        NotificationCenter.default.post(name: .localStateCleared, object: nil)

        #if DEBUG
        print("[SharedPlayerManager] Local state fully cleared — playback stopped, snapshot removed, LA ended")
        #endif
    }
}
