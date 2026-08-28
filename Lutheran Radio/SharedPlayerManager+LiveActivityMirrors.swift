//
//  SharedPlayerManager+LiveActivityMirrors.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 23.7.2026.
//
//  SHARED: Cross-target membership-exception source (main app + extension +
//  LutheranRadioWidgetTests). Mechanical split of SharedPlayerManager — same actor.
//
//  Purpose: Live Activity durable visual/language App Group mirrors, boot identity,
//  extension-hosted toggle planning helpers, and widget-refresh / play-pause
//  optimistic language derivation. Play/pause **proposal**, instant-feedback write,
//  and ``loadSharedState()`` read all follow ``settledLanguageForInstantFeedback()``
//  (session vs ``homeWidgetLiveChrome`` by the same freshness rule as
//  ``resolveHomeWidgetChromeFields``). A leftover session code is not a valid
//  match when chrome is strictly fresher. A lagging Live Activity language
//  mirror must not win.

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
    /// feedback, pending language, or the durable Live Activity language mirror (not for
    /// Live Activity **view** chrome).
    ///
    /// Resolve order (first non-empty wins):
    /// 1. ``settledLanguageForInstantFeedback()`` — session vs privacy-gated
    ///    ``homeWidgetLiveChrome`` by the same freshness rule as
    ///    ``resolveHomeWidgetChromeFields`` (chrome wins only when `updatedAt` is strictly
    ///    newer; ties stay session)
    /// 2. Durable Live Activity language mirror (``loadLiveActivityLanguageMirror()``)
    /// 3. ``preferredWidgetLanguage()`` (may hard-default `"en"` under no-widgets)
    ///
    /// Play/pause must propose the stream the user just paused or resumed. A leftover
    /// in-process session code is **not** that stream when live chrome is already strictly
    /// fresher. The durable language mirror can still hold a prior Live Activity
    /// ``ContentState`` language after a destination switch (fire ≠ accept) and must not
    /// win while session or live chrome already name the stream.
    ///
    /// Instant-feedback **write** and ``loadSharedState()`` **read** use the same freshness
    /// helper; this function is the play/pause **proposal** so ``handleWidgetPlay()`` /
    /// ``handleWidgetStop()`` and Live Activity toggle mirror warming do not pass leftover
    /// session into ``writeInstantFeedback(language:)`` or ``persistLiveActivityLanguageMirror(_:)``.
    /// Writer coerce and the read ignore remain defense in depth.
    ///
    /// ``settledSessionOrHomeLiveChromeLanguages()`` stays session-first for callers that
    /// only need “a settled stream exists” — do not use that list’s ``.first`` here.
    ///
    /// Live Activity **views** must not call this — they use `context.state.currentLanguage` only.
    ///
    /// - Returns: Non-empty language code for optimistic play/pause writes.
    /// - SeeAlso: ``writeInstantFeedback(language:)``, ``loadSharedState()``,
    ///   ``persistLiveActivityLanguageMirror(_:)``,
    ///   ``settledSessionOrHomeLiveChromeLanguages()``,
    ///   ``settledLanguageForInstantFeedback()``,
    ///   ``languageForInstantFeedbackWrite(_:)``,
    ///   ``WidgetIntentExecution/performLiveActivityToggle()``,
    ///   ``WidgetIntentExecution/languageForPlayPauseOptimisticWrite(resolutionLanguage:)``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§5.3).
    nonisolated static func languageForLiveActivityOrWidgetOptimistic() -> String {
        if let settled = settledLanguageForInstantFeedback() {
            return settled
        }
        if let mirrorLanguage = loadLiveActivityLanguageMirror(), !mirrorLanguage.isEmpty {
            return mirrorLanguage
        }
        return preferredWidgetLanguage()
    }

    /// Non-empty language codes from the in-process session snapshot and privacy-gated
    /// ``homeWidgetLiveChrome`` (session first; chrome appended when it differs).
    ///
    /// Callers that only need “a settled stream exists” may use this pair. Play/pause
    /// **proposal**, instant-feedback **write**, and ``loadSharedState()`` **read** must
    /// not treat every element as a valid match — a leftover session code plus fresher
    /// chrome yields `[stale, current]`, and ``.first`` / `contains` would re-plant the
    /// stale code. Those paths use ``settledLanguageForInstantFeedback()`` instead.
    ///
    /// - Returns: Zero, one, or two distinct non-empty language codes.
    /// - SeeAlso: ``languageForLiveActivityOrWidgetOptimistic()``,
    ///   ``settledLanguageForInstantFeedback()``,
    ///   ``languageForInstantFeedbackWrite(_:)``, ``loadSharedState()``,
    ///   ``loadHomeWidgetLiveChromeMirror()``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§5.3).
    nonisolated static func settledSessionOrHomeLiveChromeLanguages() -> [String] {
        var codes: [String] = []
        if let sessionLanguage = loadPersistedWidgetState()?.currentLanguage, !sessionLanguage.isEmpty {
            codes.append(sessionLanguage)
        }
        if let chromeLanguage = loadHomeWidgetLiveChromeMirror()?.currentLanguage,
           !chromeLanguage.isEmpty,
           !codes.contains(chromeLanguage) {
            codes.append(chromeLanguage)
        }
        return codes
    }

    /// Single settled language for play/pause proposal, instant-feedback write, and
    /// ``loadSharedState()`` read.
    ///
    /// Session vs privacy-gated ``homeWidgetLiveChrome`` use the same freshness comparison
    /// as ``languageForWidgetRefreshDerivation(fallbackLanguage:)`` and
    /// ``resolveHomeWidgetChromeFields``: chrome wins only when `updatedAt` is **strictly**
    /// greater than session ``PersistedWidgetState/lastLanguageChangeTime`` (`updatedAt` on
    /// the snapshot tuple). Ties stay with session. Missing session stamp is older than any
    /// positive chrome stamp (`-.infinity`).
    ///
    /// - Returns: Session language when it is the only or fresher/tied source; chrome
    ///   language when session is empty or chrome is strictly fresher; `nil` when both
    ///   are empty (first-tap / no-settled — callers store `proposed`).
    /// - Important: A leftover session code is **not** a valid instant-feedback match
    ///   merely because it appears in ``settledSessionOrHomeLiveChromeLanguages()``.
    ///   Play/pause must not propose or re-plant that leftover after chrome already
    ///   names the current stream. Optimistic switch may still store the destination
    ///   when it already matches this fresher settled source.
    /// - Important: Durable Live Activity language is never consulted. Privacy write
    ///   suppression is unchanged (this helper only reads).
    /// - SeeAlso: ``languageForInstantFeedbackWrite(_:)``, ``loadSharedState()``,
    ///   ``languageForLiveActivityOrWidgetOptimistic()``,
    ///   ``settledSessionOrHomeLiveChromeLanguages()``,
    ///   ``languageForWidgetRefreshDerivation(fallbackLanguage:)``,
    ///   ``resolveHomeWidgetChromeFields``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§5.3),
    ///   docs/Widget-Presentation-Dataflow.md,
    ///   CODING_AGENT.md (Single Source of Truth Principles).
    nonisolated static func settledLanguageForInstantFeedback() -> String? {
        let session = loadPersistedWidgetState()
        let sessionLanguage: String? = {
            guard let code = session?.currentLanguage, !code.isEmpty else { return nil }
            return code
        }()
        let liveChrome = loadHomeWidgetLiveChromeMirror()
        let chromeLanguage: String? = {
            guard let code = liveChrome?.currentLanguage, !code.isEmpty else { return nil }
            return code
        }()

        guard let sessionLanguage else {
            return chromeLanguage
        }
        guard let chromeLanguage, let liveChrome else {
            return sessionLanguage
        }
        if sessionLanguage == chromeLanguage {
            return sessionLanguage
        }
        // Disagree: reuse WRM / Provider freshness — chrome only when strictly newer.
        let sessionTime = session?.updatedAt ?? -.infinity
        if liveChrome.updatedAt > sessionTime {
            return chromeLanguage
        }
        return sessionLanguage
    }

    /// Language ``writeInstantFeedback(language:)`` persists for the 15 s optimistic window.
    ///
    /// Settles via ``settledLanguageForInstantFeedback()``. Play/pause must not plant a
    /// device-locale, leftover session, or lagging Live Activity language while the fresher
    /// of session / ``homeWidgetLiveChrome`` already names the stream. Stream switch
    /// persists the destination into session + live chrome **before** instant feedback, so
    /// the destination is already the fresher settled source and is stored as given.
    ///
    /// ``loadHomeWidgetLiveChromeMirror()`` re-syncs the App Group suite, so an empty
    /// extension session (OI-1) still sees stamped chrome.
    ///
    /// - Parameter proposed: Caller language (optimistic plan, locale fallback, or destination).
    /// - Returns: `proposed` when it already matches ``settledLanguageForInstantFeedback()``
    ///   or no settled language exists; otherwise that single settled language.
    /// - SeeAlso: ``writeInstantFeedback(language:)``, ``loadSharedState()``,
    ///   ``settledLanguageForInstantFeedback()``,
    ///   ``settledSessionOrHomeLiveChromeLanguages()``,
    ///   ``WidgetIntentExecution/executeOptimisticToggle(plan:language:)``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§5.3).
    nonisolated static func languageForInstantFeedbackWrite(_ proposed: String) -> String {
        guard let settled = settledLanguageForInstantFeedback() else {
            return proposed
        }
        return proposed == settled ? proposed : settled
    }

    /// Language for ``WidgetRefreshManager`` derivation, coalesce bookkeeping, and DEBUG labels.
    ///
    /// **Stream-switch honesty:** Extension optimistic switch stamps destination language into
    /// privacy-gated ``homeWidgetLiveChrome`` (and often instant-feedback) **before** the main-app
    /// process-local session language advances. Preferring a lagging session first produced WRM
    /// first-paint / deferred Connecting labels on the **prior** language (`lang: fi` while
    /// switching to `sv`) even though App Group chrome already held the destination.
    ///
    /// **Does not** open write suppression, write App Group snapshot keys, or change
    /// home-widget Provider chrome resolution (Providers use ``resolveHomeWidgetChromeFields``).
    ///
    /// Resolution order (first applicable wins):
    /// 1. Privacy-gated live-chrome language when present and (session absent, languages agree,
    ///    or live chrome `updatedAt` is strictly fresher than session) — cross-process switch
    ///    / optimistic settle SSOT for refresh labels
    /// 2. Session snapshot `currentLanguage` when non-empty
    /// 3. While privacy-clear write suppression is held closed and those sources are empty:
    ///    ``preferredMainAppInitialLanguageCode()`` (do not label leftover attach language)
    /// 4. Main app: ``DirectStreamingPlayer/selectedStream`` language (stream attach SSOT)
    /// 5. Durable Live Activity language mirror (destination stamp / last content push)
    /// 6. Non-empty `fallbackLanguage` from the refresh caller (when not privacy-default-only)
    /// 7. Main app: ``preferredMainAppInitialLanguageCode()``; extension: ``preferredWidgetLanguage()``
    ///
    /// - Parameter fallbackLanguage: Optional language already known to the caller
    ///   (e.g. ``loadSharedState()``.currentLanguage, which may already carry instant-feedback).
    ///   Used only after live chrome / snapshot / attach / mirror when it is non-empty; under
    ///   no-widgets a bare `"en"` fallback is ignored in favor of the main-app locale reseed so
    ///   hard-default pollution does not win.
    /// - Returns: Non-empty language code for refresh state and diagnostic labels.
    /// - SeeAlso: ``mainAppLiveActivityLanguageCode()``, ``languageForLiveActivityOrWidgetOptimistic()``,
    ///   ``liveActivityLanguageCodeForContentPush()``, ``preferredWidgetLanguage()``,
    ///   ``loadHomeWidgetLiveChromeMirror()``,
    ///   ``WidgetRefreshManager/deriveRefreshParameters(for:)``,
    ///   ``WidgetRefreshManager/refreshIfNeeded(visualState:currentLanguage:hasError:immediate:trigger:)``,
    ///   docs/Widget-Functionality-Roadmap.md, docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§5.3, §6).
    nonisolated static func languageForWidgetRefreshDerivation(fallbackLanguage: String = "") -> String {
        let session = loadPersistedWidgetState()
        let sessionLanguage = session?.currentLanguage
        let sessionTime = session?.updatedAt ?? -.infinity

        // Cross-process optimistic destination often lands in live chrome before main-process
        // session language advances (stream-switch first WRM sample). Prefer fresher mirror.
        if let liveChrome = loadHomeWidgetLiveChromeMirror(),
           !liveChrome.currentLanguage.isEmpty {
            let liveLang = liveChrome.currentLanguage
            if let sessionLanguage, !sessionLanguage.isEmpty {
                if sessionLanguage == liveLang {
                    return sessionLanguage
                }
                if liveChrome.updatedAt > sessionTime {
                    return liveLang
                }
                return sessionLanguage
            }
            return liveLang
        }

        if let snapshotLanguage = sessionLanguage, !snapshotLanguage.isEmpty {
            return snapshotLanguage
        }

        #if LUTHERAN_MAIN_APP
        // After in-session privacy clear, session + live chrome are absent on purpose.
        // Do not label the teardown / metadata wake with leftover engine attach language
        // (last stream before clear). Locale reseed is the factory language until
        // explicit play; coordinator ``setSelectedStreamModelOnly`` is idempotent.
        if WidgetRefreshManager.isPrivacyClearWriteSuppressionHeldClosed {
            let mainAppInitial = preferredMainAppInitialLanguageCode()
            if !mainAppInitial.isEmpty {
                return mainAppInitial
            }
        }

        let selected = DirectStreamingPlayer.shared.selectedStream.languageCode
        if !selected.isEmpty {
            return selected
        }
        if let mirrorLanguage = loadLiveActivityLanguageMirror(), !mirrorLanguage.isEmpty {
            return mirrorLanguage
        }
        // Under no home widgets, ``preferredWidgetLanguage()`` / ``loadSharedState()`` hard-default
        // to `"en"`. Do not let that privacy default label active non-English streams; prefer
        // main-app locale reseed, then a non-`"en"` caller signal, then intentional English.
        let mainAppInitial = preferredMainAppInitialLanguageCode()
        if !fallbackLanguage.isEmpty {
            if fallbackLanguage != "en" {
                return fallbackLanguage
            }
            if WidgetRefreshManager.hasActiveLutheranWidgets {
                return fallbackLanguage
            }
            // Privacy hard-default `"en"` with no attach/mirror: locale reseed is more honest
            // for diagnostics than inventing English from the privacy gate alone.
            if !mainAppInitial.isEmpty {
                return mainAppInitial
            }
            return fallbackLanguage
        }
        return mainAppInitial
        #else
        if let mirrorLanguage = loadLiveActivityLanguageMirror(), !mirrorLanguage.isEmpty {
            return mirrorLanguage
        }
        if !fallbackLanguage.isEmpty, fallbackLanguage != "en" {
            return fallbackLanguage
        }
        return languageForLiveActivityOrWidgetOptimistic()
        #endif
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

    /// Whether presentation must refuse residual App Group chrome as a live session
    /// (post-termination sentinel or device reboot since last recorded boot).
    ///
    /// **Live Activity:** ActivityKit `ContentState` remains trusted; durable toggle mirror alone
    /// must not call ``userRequestedPlay()`` after dirty power-off.
    /// **Home widget planning:** residual ``homeWidgetLiveChrome`` / empty factory alone must not
    /// schedule pending **play** after process exit or reboot (``planHomeWidgetToggle(resolution:…)``).
    /// **Control widget planning:** ``performControlWidgetToggle(isPlayingRequested:)`` refuses
    /// `true` (play) under the same flags; pause still executes for glyph honesty.
    /// **Home widget paint:** Providers ignore residual live chrome via
    /// ``resolveHomeWidgetChromeFields(..., distrustLiveChrome:)`` so last play/pause glyphs
    /// do not survive dirty exit / reboot when the App Group blob was not cleared.
    /// **Extension liveness:** also blocks opening a new interactive `lastUpdateTime` window.
    /// **Extension write:** refuses stamping ``.playing`` onto ``homeWidgetLiveChrome`` while true.
    ///
    /// - Returns: `true` when ``hasExplicitTerminationSentinel()`` or
    ///   ``hasDeviceRebootedSinceLastRecordedBoot()``.
    /// - SeeAlso: ``WidgetIntentCoordinators/planLiveActivityToggle(resolution:distrustDurableMirrorPlay:)``,
    ///   ``WidgetIntentCoordinators/planHomeWidgetToggle(resolution:distrustDurableMirrorPlay:mainProcessRecentlyActive:)``,
    ///   ``WidgetIntentExecution/performLiveActivityToggle()``,
    ///   ``WidgetIntentExecution/performHomeWidgetToggle()``,
    ///   ``WidgetIntentExecution/performControlWidgetToggle(isPlayingRequested:)``,
    ///   ``WidgetProviderSnapshotResolver/resolveFromSnapshot()``,
    ///   ``persistHomeWidgetLiveChromeMirror(_:)``,
    ///   ``bumpWidgetLivenessTimestamp(policy:minInterval:)``.
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
    /// Stamps in-process session RAM **and** privacy-gated ``homeWidgetLiveChrome`` via
    /// ``persistOptimisticWidgetSnapshot`` (reason `"optimisticToggle"`). Main-app sticky pause /
    /// ``setPlaying()`` later overwrite the mirror when the home-widget gate is open.
    ///
    /// - Parameters:
    ///   - visualState: Target from the caller’s pure plan (``.userPaused`` on pause;
    ///     home play uses ``PlayerVisualState/optimisticHomeWidgetVisualAfterPlayPlan`` —
    ///     never invent home ``.playing``. LA / media dual-tap uses
    ///     ``optimisticVisualAfterPlayPlan``).
    ///   - action: "play" or "pause".
    ///   - language: Language code to pair with the snapshot (strongly recommended from widget).
    ///     If omitted, falls back inside ``persistOptimisticWidgetSnapshot``. Always pass the language the widget
    ///     timeline was using to avoid transient "en" in mixed-language initial-play scenarios.
    ///
    /// Always bypasses privacy gate (via force + isWidgetProcess) because intent execution
    /// proves the widget is present.
    ///
    /// - SeeAlso: ``persistOptimisticWidgetSnapshot(_:language:)``,
    ///   ``stampHomeWidgetLiveChromeFromSession(visualState:language:hasError:reason:)``,
    ///   ``PlayerVisualState/optimisticHomeWidgetVisualAfterPlayPlan``,
    ///   ``WidgetIntentExecution/executeOptimisticToggle(plan:language:)``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§5.3 extension optimistic stamp matrix).
    @discardableResult
    nonisolated func signalWidgetPendingAction(
        visualState: PlayerVisualState,
        action: String,
        language: String? = nil
    ) -> String? {
        persistOptimisticWidgetSnapshot(visualState, language: language)
        // Refresh liveness only when main is already recently active and not post-term/reboot
        // (``bumpWidgetLivenessTimestamp`` extension honesty gate). Never open a new 60 s
        // interactive session from extension alone after process exit.
        Self.bumpWidgetLivenessTimestamp(policy: .immediate)
        let actionId = scheduleWidgetAction(action: action)
        notifyMainApp(action: action)
        return actionId
    }

    /// Optimistic stream-switch widget path: instant feedback, snapshot, schedule, notify.
    ///
    /// Projects destination language + switch honesty visual into session RAM and
    /// ``homeWidgetLiveChrome`` (reason `"optimisticSwitch"`). Visual must come from
    /// ``WidgetIntentCoordinators/optimisticLiveActivityVisualForStreamSwitch(from:)`` —
    /// actively playing → Connecting (``.prePlay``); sticky pause preserved.
    ///
    /// - Parameters:
    ///   - visualState: Optimistic switch visual (``.prePlay`` leaving play; ``.userPaused`` when paused).
    ///   - language: Destination stream language code.
    /// - SeeAlso: ``persistWidgetSnapshot(visualState:language:streamMetadata:clearStreamMetadata:hasError:liveChromeStampReason:)``,
    ///   ``handleWidgetSwitch(to:)``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§5.3, §9).
    @discardableResult
    nonisolated func signalWidgetSwitchAction(
        visualState: PlayerVisualState,
        language: String
    ) -> String? {
        // Persist destination session + live chrome **before** instant feedback so
        // ``loadSharedState()`` sees a settled code that agrees with the destination
        // (instant feedback remains the short switch flash, not a prior-language override).
        Self.persistWidgetSnapshot(
            visualState: visualState,
            language: language,
            clearStreamMetadata: true,
            liveChromeStampReason: "optimisticSwitch"
        )
        Self.writeInstantFeedback(language: language)
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

    /// Whether the main process may execute App Group pending commands this runtime.
    ///
    /// Starts **false** in the main app so SceneDelegate / Darwin / launch-burst drains that
    /// race ahead of cold-launch factory reset cannot honor residual pre-process mailbox
    /// entries (post-reboot / post-quit leftovers). Armed only after
    /// ``discardResidualPendingActionsAndArmMailboxForThisProcess()`` (factory reset path)
    /// or privacy clear / test isolation that intentionally opens the mailbox again.
    ///
    /// Widget-extension processes start armed (they write and contract-test-read; they do not
    /// attach the engine).
    ///
    /// - SeeAlso: ``getPendingActionIfFresh(maxAge:)``, ``resetToFactoryDefaultsOnLaunch()``,
    ///   ``discardResidualPendingActionsAndArmMailboxForThisProcess()``.
    // SAFETY: Process-local gate flipped only from main cold-launch / privacy / test isolation
    // paths; concurrent drains that observe a mid-flip still either refuse (unarmed) or honor
    // post-arm writes — residual pre-arm entries are cleared first.
    #if LUTHERAN_MAIN_APP
    nonisolated(unsafe) static var pendingActionMailboxAcceptingExecution = false
    #else
    nonisolated(unsafe) static var pendingActionMailboxAcceptingExecution = true
    #endif

    /// Drops every pending-action mailbox key without requiring a matching `actionId`.
    ///
    /// Used for cold-launch residual hygiene and privacy clear. Distinct from
    /// ``clearPendingAction(actionId:)`` which is race-safe for single-command completion.
    ///
    /// - Postcondition: `pendingAction`, `pendingActionId`, `pendingActionTime`, and
    ///   `pendingLanguage` are absent from the App Group (when available).
    /// - SeeAlso: ``discardResidualPendingActionsAndArmMailboxForThisProcess()``,
    ///   ``getPendingActionIfFresh(maxAge:)``.
    nonisolated static func clearPendingActionMailbox() {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return }
        defaults.removeObject(forKey: "pendingAction")
        defaults.removeObject(forKey: "pendingActionId")
        defaults.removeObject(forKey: "pendingActionTime")
        defaults.removeObject(forKey: "pendingLanguage")
        #if DEBUG
        print("[SharedPlayerManager] Cleared pending-action mailbox (unconditional)")
        #endif
    }

    /// Cold-launch / process-start hygiene: drop residual pending commands and allow future
    /// this-process drains to honor new mailbox writes.
    ///
    /// Call from ``resetToFactoryDefaultsOnLaunch()`` **before** special tuning / cold auto-play
    /// so SceneDelegate become-active and the launch drain burst cannot execute pre-reboot or
    /// pre-quit leftovers. After this returns, only pending written while the mailbox is armed
    /// (this process lifetime, after arm) is executable via ``getPendingActionIfFresh(maxAge:)``.
    ///
    /// - Postcondition: mailbox empty; ``pendingActionMailboxAcceptingExecution`` is `true`.
    /// - SeeAlso: ``getPendingActionIfFresh(maxAge:)``, ViewController factory-hygiene Task,
    ///   ``RadioPlayerCoordinator/checkForPendingWidgetActions()``.
    nonisolated static func discardResidualPendingActionsAndArmMailboxForThisProcess() {
        clearPendingActionMailbox()
        // SAFETY: Process-local arm flip on nonisolated(unsafe) storage; concurrent drains that
        // observe mid-flip either refuse (unarmed) or honor post-arm writes after residual clear.
        unsafe pendingActionMailboxAcceptingExecution = true
        #if DEBUG
        print("[SharedPlayerManager] Pending mailbox armed for this process (residual discarded)")
        #endif
    }

    /// Returns a pending widget action only if it is safe to execute in this process.
    ///
    /// **Freshness / honesty gates (any failure clears the mailbox entry and returns `nil`):**
    /// 1. Main process not yet armed after cold start
    ///    (``pendingActionMailboxAcceptingExecution``) — drops residual without execute so
    ///    early SceneDelegate / Darwin drains cannot race special tuning.
    /// 2. Pending wall-clock time is **before** the current device boot epoch — cross-reboot
    ///    residual even when wall-clock age is still under `maxAge`.
    /// 3. Explicit termination liveness sentinel still present — clean-quit residual must not
    ///    fire until a later this-boot write after liveness is refreshed (mailbox should already
    ///    be empty after factory arm; this is defense-in-depth).
    /// 4. Age ≥ `maxAge` seconds (default 30).
    ///
    /// - Parameter maxAge: Maximum age in seconds for an executable pending command.
    /// - Returns: Fresh this-boot pending command, or `nil` when absent / discarded.
    /// - SeeAlso: ``discardResidualPendingActionsAndArmMailboxForThisProcess()``,
    ///   ``hasDeviceRebootedSinceLastRecordedBoot()``, ``hasExplicitTerminationSentinel()``,
    ///   ``RadioPlayerCoordinator/checkForPendingWidgetActions()``.
    nonisolated func getPendingActionIfFresh(maxAge: TimeInterval = 30) -> (action: String, parameter: String?, actionId: String)? {
        guard let pending = getPendingAction() else { return nil }

        // Cold-launch race: refuse (and drop) residual until factory arm. Extension processes
        // start armed and only contract-test-read the mailbox.
        // SAFETY: Read of process-local nonisolated(unsafe) arm flag; false negatives only delay
        // drain until next become-active / Darwin wake after arm.
        if unsafe !Self.pendingActionMailboxAcceptingExecution {
            #if DEBUG
            print("[SharedPlayerManager] Pending action discarded — mailbox not armed this process (cold-launch residual hygiene)")
            #endif
            Self.clearPendingActionMailbox()
            return nil
        }

        let pendingTime = sharedDefaults?.double(forKey: "pendingActionTime") ?? 0
        let currentBoot = Self.currentSystemBootTimeIntervalSince1970()
        // Pending written before this boot (App Group survives reboot; wall-clock age alone is insufficient).
        if pendingTime > 0, pendingTime < currentBoot - 2.0 {
            #if DEBUG
            print("[SharedPlayerManager] Pending action discarded — pre-boot residual (pendingTime=\(pendingTime), boot=\(currentBoot))")
            #endif
            clearPendingAction(actionId: pending.actionId)
            return nil
        }

        // Clean-quit residual: termination sentinel still marks presentation distrust.
        if Self.hasExplicitTerminationSentinel() {
            #if DEBUG
            print("[SharedPlayerManager] Pending action discarded — termination sentinel still present")
            #endif
            clearPendingAction(actionId: pending.actionId)
            return nil
        }

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

