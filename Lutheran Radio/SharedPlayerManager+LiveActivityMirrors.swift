//
//  SharedPlayerManager+LiveActivityMirrors.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 23.7.2026.
//
//  SHARED: Cross-target membership-exception source (main app + extension +
//  LutheranRadioWidgetTests). Mechanical split of SharedPlayerManager — same actor,
//  no API renames, no behavior change.
//
//  Purpose: Live Activity durable visual/language App Group mirrors, boot identity, and extension-hosted toggle planning helpers.
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
    // MARK: - Live Activity toggle durable mirror (cross-process)

    /// App Group key for the last Live Activity `ContentState.visualState` used by toggle planning.
    ///
    /// Distinct from the memory-only widget session snapshot and **not** subject to home-widget
    /// `hasActiveWidgets` write suppression. Lock Screen / Dynamic Island already surface this
    /// visual; the mirror exists so extension-hosted App Intents can match the glyph when
    /// `Activity.activities` is briefly empty and extension memory has no session snapshot.
    nonisolated static let liveActivityToggleVisualStateAppGroupKey = "liveActivityToggleVisualState"

    /// Writes the durable Live Activity visual-state mirror for cross-process toggle planning.
    ///
    /// - Parameter visualState: Last pushed (or optimistically planned) LA visual state.
    /// - Important: Always writes when the App Group is available — not gated by
    ///   ``hasActiveWidgets``. Home-widget privacy suppression must not invert LA pause.
    /// - Postcondition: Also records current system boot identity so post-reboot planning can
    ///   detect a dirty power cycle when `willTerminate` never ran.
    /// - SeeAlso: ``loadLiveActivityToggleVisualStateMirror()``, ``clearLiveActivityToggleVisualStateMirror()``,
    ///   ``recordCurrentSystemBootTime()``, ``shouldDistrustDurableMirrorPlayPlanning()``,
    ///   ``WidgetIntentCoordinators/resolveLiveActivityToggleVisualState(liveActivityContent:durableMirror:actorVisualState:sessionSnapshot:)``,
    ///   `RadioLiveActivityManager.updateCurrentActivity`.
    nonisolated static func persistLiveActivityToggleVisualStateMirror(_ visualState: PlayerVisualState) {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return }
        defaults.set(liveActivityToggleMirrorToken(for: visualState), forKey: liveActivityToggleVisualStateAppGroupKey)
        #if LUTHERAN_MAIN_APP
        // Warm boot identity only from the main app. Extension optimistic mirror writes must
        // not clear post-reboot distrust (otherwise a forced-pause first tap would re-enable
        // durable-mirror-alone play on the second tap before the main process is live).
        recordCurrentSystemBootTime()
        #endif
    }

    /// Reads the durable Live Activity visual-state mirror, if present and well-formed.
    ///
    /// - Returns: Mirrored ``PlayerVisualState``, or `nil` when missing/unknown (treat as no signal).
    /// - SeeAlso: ``persistLiveActivityToggleVisualStateMirror(_:)``.
    nonisolated static func loadLiveActivityToggleVisualStateMirror() -> PlayerVisualState? {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared"),
              let token = defaults.string(forKey: liveActivityToggleVisualStateAppGroupKey)
        else {
            return nil
        }
        return playerVisualState(fromLiveActivityToggleMirrorToken: token)
    }

    /// Clears the durable Live Activity toggle mirror (LA end, termination, factory reset, privacy clear).
    nonisolated static func clearLiveActivityToggleVisualStateMirror() {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return }
        defaults.removeObject(forKey: liveActivityToggleVisualStateAppGroupKey)
    }

    // MARK: - Live Activity language durable mirror (cross-process)

    /// App Group key for the last Live Activity `ContentState.currentLanguage`.
    ///
    /// Parallel to ``liveActivityToggleVisualStateAppGroupKey``: not gated by home-widget
    /// ``hasActiveWidgets``. Language chrome on Lock Screen / Dynamic Island rides ActivityKit
    /// ``ContentState.currentLanguage``; this mirror feeds extension-hosted optimistic play/pause
    /// language (instant feedback / pending language) when `Activity.activities` is empty and
    /// the memory-only session snapshot is absent.
    ///
    /// - SeeAlso: ``persistLiveActivityLanguageMirror(_:)``, ``loadLiveActivityLanguageMirror()``,
    ///   ``clearLiveActivityLanguageMirror()``, ``languageForLiveActivityOrWidgetOptimistic()``,
    ///   ``mainAppLiveActivityLanguageCode()``.
    nonisolated static let liveActivityCurrentLanguageAppGroupKey = "liveActivityCurrentLanguage"

    /// Writes the durable Live Activity language mirror for cross-process optimistic language.
    ///
    /// - Parameter languageCode: Last pushed (or ContentState-aligned) stream language code.
    /// - Important: Always writes when the App Group is available — not gated by
    ///   ``hasActiveWidgets``. Home-widget privacy suppression must not force English on LA-only
    ///   sessions when the engine stream is non-English.
    /// - SeeAlso: ``loadLiveActivityLanguageMirror()``, ``clearLiveActivityLanguageMirror()``,
    ///   `RadioLiveActivityManager.updateCurrentActivity`.
    nonisolated static func persistLiveActivityLanguageMirror(_ languageCode: String) {
        guard !languageCode.isEmpty else { return }
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return }
        defaults.set(languageCode, forKey: liveActivityCurrentLanguageAppGroupKey)
    }

    /// Reads the durable Live Activity language mirror, if present and non-empty.
    ///
    /// - Returns: Mirrored language code, or `nil` when missing/empty (treat as no signal).
    /// - SeeAlso: ``persistLiveActivityLanguageMirror(_:)``.
    nonisolated static func loadLiveActivityLanguageMirror() -> String? {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared"),
              let code = defaults.string(forKey: liveActivityCurrentLanguageAppGroupKey),
              !code.isEmpty
        else {
            return nil
        }
        return code
    }

    /// Clears the durable Live Activity language mirror (LA end, termination, factory reset, privacy clear).
    nonisolated static func clearLiveActivityLanguageMirror() {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return }
        defaults.removeObject(forKey: liveActivityCurrentLanguageAppGroupKey)
    }

    /// Main-app stream language from engine attach / session (no stream-switch hold override).
    ///
    /// Prefer ``DirectStreamingPlayer/selectedStream`` (stream attach SSOT) so language chrome
    /// tracks the engine even when home-widget write suppression leaves the session snapshot
    /// empty and ``preferredWidgetLanguage()`` would hard-default to `"en"`. Falls back to the
    /// in-process session snapshot language, then ``preferredMainAppInitialLanguageCode()``.
    ///
    /// **Live Activity content pushes** should use ``liveActivityLanguageCodeForContentPush()``
    /// so an in-flight Connecting hold can report the destination language before
    /// ``selectedStream`` updates.
    ///
    /// - Returns: Non-empty language code suitable for ActivityKit content and the durable language mirror.
    /// - Important: Main-app only semantics. Extension hosts must not use this for chrome; they
    ///   render ``ContentState.currentLanguage`` and may read the durable language mirror for
    ///   optimistic intent language only.
    /// - SeeAlso: ``liveActivityLanguageCodeForContentPush()``, ``persistLiveActivityLanguageMirror(_:)``,
    ///   ``languageForLiveActivityOrWidgetOptimistic()``,
    ///   docs/Widget-Functionality-Roadmap.md (Live Activity language chrome SSOT).
    nonisolated static func mainAppLiveActivityLanguageCode() -> String {
        let selected = DirectStreamingPlayer.shared.selectedStream.languageCode
        if !selected.isEmpty {
            return selected
        }
        if let snapshotLanguage = loadPersistedWidgetState()?.currentLanguage, !snapshotLanguage.isEmpty {
            return snapshotLanguage
        }
        return preferredMainAppInitialLanguageCode()
    }

    /// Language code for extension/main optimistic play/pause paths that still write instant
    /// feedback or pending language (not for Live Activity view chrome).
    ///
    /// Resolve order (first non-empty wins):
    /// 1. In-process session snapshot (`PersistedWidgetState.currentLanguage`)
    /// 2. Durable Live Activity language mirror (``loadLiveActivityLanguageMirror()``)
    /// 3. ``preferredWidgetLanguage()`` (may hard-default `"en"` under no-widgets)
    ///
    /// Live Activity **views** must not call this — they use `context.state.currentLanguage` only.
    /// This helper exists so LA-hosted play/pause does not stamp English into instant-feedback
    /// keys when ContentState / the language mirror already hold the active stream code.
    ///
    /// - SeeAlso: ``writeInstantFeedback(language:)``, ``persistLiveActivityLanguageMirror(_:)``,
    ///   ``WidgetIntentExecution/performLiveActivityToggle()``.
    nonisolated static func languageForLiveActivityOrWidgetOptimistic() -> String {
        if let snapshotLanguage = loadPersistedWidgetState()?.currentLanguage, !snapshotLanguage.isEmpty {
            return snapshotLanguage
        }
        if let mirrorLanguage = loadLiveActivityLanguageMirror(), !mirrorLanguage.isEmpty {
            return mirrorLanguage
        }
        return preferredWidgetLanguage()
    }

    // MARK: - Boot identity + durable-mirror play distrust (LA toggle hygiene)

    /// App Group key for the wall-clock epoch of the system boot last observed while the app
    /// was healthy enough to write LA toggle state (or complete factory reset).
    ///
    /// - SeeAlso: ``recordCurrentSystemBootTime()``, ``hasDeviceRebootedSinceLastRecordedBoot()``.
    nonisolated static let recordedSystemBootTimeAppGroupKey = "recordedSystemBootTime"

    /// Wall-clock epoch of the current device boot (`now - systemUptime`).
    ///
    /// - Returns: Seconds since 1970 for this boot. Stable for the lifetime of the boot;
    ///   changes after reboot / power cycle.
    nonisolated static func currentSystemBootTimeIntervalSince1970() -> TimeInterval {
        Date(timeIntervalSinceNow: -ProcessInfo.processInfo.systemUptime).timeIntervalSince1970
    }

    /// Persists the current boot identity into the App Group.
    ///
    /// Called when the process is known to be live on this boot (LA mirror write, factory reset).
    /// Enables ``hasDeviceRebootedSinceLastRecordedBoot()`` after a hard power-off that skipped
    /// `willTerminate`.
    ///
    /// - SeeAlso: ``shouldDistrustDurableMirrorPlayPlanning()``.
    nonisolated static func recordCurrentSystemBootTime() {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return }
        defaults.set(currentSystemBootTimeIntervalSince1970(), forKey: recordedSystemBootTimeAppGroupKey)
    }

    /// Whether the device has rebooted since the last recorded healthy boot identity.
    ///
    /// - Returns: `true` when a prior boot epoch exists and differs from the current boot by more
    ///   than a small epsilon. Missing key → `false` (first install / never recorded).
    /// - Note: Does not start or stop audio; only feeds LA toggle planning distrust.
    /// - SeeAlso: ``shouldDistrustDurableMirrorPlayPlanning()``, ``recordCurrentSystemBootTime()``.
    nonisolated static func hasDeviceRebootedSinceLastRecordedBoot() -> Bool {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared"),
              let recorded = defaults.object(forKey: recordedSystemBootTimeAppGroupKey) as? Double
        else {
            return false
        }
        let current = currentSystemBootTimeIntervalSince1970()
        // Boot epochs are stable per boot; allow a few seconds of float / clock skew noise.
        return abs(current - recorded) > 2.0
    }

    /// Whether Live Activity toggle planning must refuse **play** from the durable App Group
    /// mirror alone (post-termination sentinel or device reboot since last recorded boot).
    ///
    /// ActivityKit `ContentState` remains trusted: a real lock-screen glyph is an explicit
    /// user-facing signal. Stale mirror after dirty power-off must not call
    /// ``userRequestedPlay()`` without that content signal.
    ///
    /// - Returns: `true` when ``hasExplicitTerminationSentinel()`` or
    ///   ``hasDeviceRebootedSinceLastRecordedBoot()``.
    /// - SeeAlso: ``WidgetIntentCoordinators/planLiveActivityToggle(resolution:distrustDurableMirrorPlay:)``,
    ///   ``WidgetIntentExecution/performLiveActivityToggle()``.
    nonisolated static func shouldDistrustDurableMirrorPlayPlanning() -> Bool {
        hasExplicitTerminationSentinel() || hasDeviceRebootedSinceLastRecordedBoot()
    }

    /// Stable App Group token for ``PlayerVisualState`` (plain cases, no associated values).
    nonisolated private static func liveActivityToggleMirrorToken(for state: PlayerVisualState) -> String {
        switch state {
        case .prePlay: return "prePlay"
        case .cleared: return "cleared"
        case .playing: return "playing"
        case .userPaused: return "userPaused"
        case .thermalPaused: return "thermalPaused"
        case .securityLocked: return "securityLocked"
        }
    }

    nonisolated private static func playerVisualState(
        fromLiveActivityToggleMirrorToken token: String
    ) -> PlayerVisualState? {
        switch token {
        case "prePlay": return .prePlay
        case "cleared": return .cleared
        case "playing": return .playing
        case "userPaused": return .userPaused
        case "thermalPaused": return .thermalPaused
        case "securityLocked": return .securityLocked
        default: return nil
        }
    }

    /// Optimistic play/pause widget path: persist visual state, schedule pending action, notify main app.
    ///
    /// - Parameters:
    ///   - visualState: Target (.playing or .userPaused) for instant widget icon/state flip.
    ///   - action: "play" or "pause".
    ///   - language: Language code to pair with the snapshot (strongly recommended from widget).
    ///     If omitted, falls back inside ``persistOptimisticWidgetSnapshot``. Always pass the language the widget
    ///     timeline was using to avoid transient "en" in mixed-language initial-play scenarios.
    ///
    /// Always bypasses privacy gate (via force + isWidgetProcess) because intent execution
    /// proves the widget is present.
    @discardableResult
    nonisolated func signalWidgetPendingAction(
        visualState: PlayerVisualState,
        action: String,
        language: String? = nil
    ) -> String? {
        persistOptimisticWidgetSnapshot(visualState, language: language)
        // Also bump liveness from the widget action itself so isAppRunning() flips true
        // without requiring main-app processing (prevents "tap_to_open" after widget play).
        Self.bumpWidgetLivenessTimestamp(policy: .immediate)
        let actionId = scheduleWidgetAction(action: action)
        notifyMainApp(action: action)
        return actionId
    }

    /// Optimistic stream-switch widget path: instant feedback, snapshot, schedule, notify.
    @discardableResult
    nonisolated func signalWidgetSwitchAction(
        visualState: PlayerVisualState,
        language: String
    ) -> String? {
        Self.writeInstantFeedback(language: language)
        Self.persistWidgetSnapshot(visualState: visualState, language: language, clearStreamMetadata: true)
        Self.bumpWidgetLivenessTimestamp(policy: .immediate)
        let actionId = scheduleWidgetAction(action: "switch", parameter: language)
        notifyMainApp(action: "switch", parameter: language)
        return actionId
    }

    /// Schedules a one-shot widget action for the main app via App Group UserDefaults.
    /// Returns the generated action ID, or `nil` if the App Group is unavailable.
    @discardableResult
    nonisolated func scheduleWidgetAction(action: String, parameter: String? = nil) -> String? {
        // Privacy gate for *persistent* state (snapshot, liveness, instantFeedbackLanguage, metadata).
        // Transient one-shot command keys (pendingAction*, pendingLanguage) are *still written*
        // even when !hasActiveWidgets (post-clear or no widgets configured). This guarantees the
        // first widget play/pause/switch after a privacy clear always delivers its Darwin +
        // pending so the main app can act.
        //
        // Note (post-fix): snapshot + liveness are now also written from widget process via
        // the isWidgetProcess() bypass inside persist/bump (see persistOptimisticWidgetSnapshot + signal*).
        // Main processing still does explicit refreshHasActive + save for authoritative values.
        let isPrivacySuppressed = !Self.hasActiveWidgets
        if isPrivacySuppressed {
            Self.refreshHasActiveWidgetsStatus()
            #if DEBUG
            print("[SharedPlayerManager] Privacy gate active for scheduleWidgetAction (no active widgets) — allowing transient pending command, suppressing persistent writes")
            #endif
        }

        guard let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            #if DEBUG
            print("[SharedPlayerManager] ERROR: Failed to access shared UserDefaults in scheduleWidgetAction")
            #endif
            return nil
        }
        
        let actionId = UUID().uuidString
        sharedDefaults.set(action, forKey: "pendingAction")
        sharedDefaults.set(actionId, forKey: "pendingActionId")
        sharedDefaults.set(Date().timeIntervalSince1970, forKey: "pendingActionTime")
        
        // Note: Always set the language parameter for switch actions.
        if let param = parameter {
            sharedDefaults.set(param, forKey: "pendingLanguage")
            #if DEBUG
            print("[SharedPlayerManager] Set pendingLanguage: \(param)")
            #endif
        } else if action == "switch" {
            // Fallback: use preferred (combined snapshot first) for pendingLanguage
            // Fallback via preferredWidgetLanguage() when no parameter is supplied.
            let currentLanguage = Self.preferredWidgetLanguage()
            sharedDefaults.set(currentLanguage, forKey: "pendingLanguage")
            #if DEBUG
            print("[SharedPlayerManager] Set fallback pendingLanguage: \(currentLanguage)")
            #endif
        }
        
        // Explicit synchronize() removed — App Group writes are visible to the receiving
        // process via Darwin notification without an explicit flush on modern iOS.
        
        #if DEBUG
        print("[SharedPlayerManager] Scheduled widget action: \(action) \(parameter ?? "") [ID: \(actionId)]")
        #endif
        
        return actionId
    }
    
    /// Posts a Darwin notification so the main app processes a pending widget action.
    nonisolated func notifyMainApp(action: String, parameter: String? = nil) {
        #if LUTHERAN_MAIN_APP
        if !isRunningInWidget(), action == "pause" {
            DarwinSelfEchoGuard.markExpectingSelfPostedPauseEcho()
        }
        #endif

        let notificationName = "radio.lutheran.widget.action"
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(notificationName as CFString), nil, nil, true)
        
        #if DEBUG
        print("[SharedPlayerManager] Posted Darwin notification for action: \(action)")
        #endif
    }
    
    /// Returns whether any widget action is queued in the App Group (staleness not checked).
    nonisolated func hasPendingWidgetAction() -> Bool {
        getPendingAction() != nil
    }

    /// Returns the currently pending widget action (if any), along with its parameter and unique ID.
    /// Used by the main app (typically in SceneDelegate or a notification handler) to process
    /// play/stop/switch requests originating from widgets or Control Center.
    nonisolated func getPendingAction() -> (action: String, parameter: String?, actionId: String)? {
        guard let action = sharedDefaults?.string(forKey: "pendingAction"),
              let actionId = sharedDefaults?.string(forKey: "pendingActionId") else {
            return nil
        }

        let parameter = sharedDefaults?.string(forKey: "pendingLanguage")
        return (action, parameter, actionId)
    }

    /// Returns a pending widget action only if younger than `maxAge` seconds.
    /// Expired actions are cleared automatically.
    nonisolated func getPendingActionIfFresh(maxAge: TimeInterval = 30) -> (action: String, parameter: String?, actionId: String)? {
        guard let pending = getPendingAction() else { return nil }

        let pendingTime = sharedDefaults?.double(forKey: "pendingActionTime") ?? 0
        let actionAge = Date().timeIntervalSince1970 - pendingTime

        guard actionAge < maxAge else {
            #if DEBUG
            print("[SharedPlayerManager] Pending action expired (age: \(actionAge)s), clearing")
            #endif
            clearPendingAction(actionId: pending.actionId)
            return nil
        }

        return pending
    }
    
    /// Clears a pending widget action only if the provided `actionId` still matches the current one.
    /// Prevents race conditions when multiple rapid widget taps occur.
    nonisolated func clearPendingAction(actionId: String) {
        guard let currentActionId = sharedDefaults?.string(forKey: "pendingActionId"),
              currentActionId == actionId else { return }
        sharedDefaults?.removeObject(forKey: "pendingAction")
        sharedDefaults?.removeObject(forKey: "pendingActionId")
        sharedDefaults?.removeObject(forKey: "pendingActionTime")
        sharedDefaults?.removeObject(forKey: "pendingLanguage")
        #if DEBUG
        print("[SharedPlayerManager] Cleared pending action with ID: \(actionId)")
        #endif
    }
    
}

