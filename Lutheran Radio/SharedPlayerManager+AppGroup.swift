//
//  SharedPlayerManager+AppGroup.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 23.7.2026.
//
//  SHARED: Cross-target membership-exception source (main app + extension +
//  LutheranRadioWidgetTests). Mechanical split of SharedPlayerManager — same actor.
//
//  Purpose: Widget pending-action scheduling, Darwin notify, liveness heartbeat, and
//  App Group save/load facades. ``writeInstantFeedback(language:)`` persists
//  ``settledLanguageForInstantFeedback()`` when the caller disagrees (session vs
//  ``homeWidgetLiveChrome`` by freshness — a leftover session code is not a valid
//  match when chrome is strictly fresher). ``loadSharedState()`` still ignores a
//  disagreeing instant-feedback language.
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
    /// Attempts to refresh ``lastUpdateTime`` via ``bumpWidgetLivenessTimestamp(policy:minInterval:)``
    /// so interactive chrome stays current **when main is already recently active**. Extension
    /// bumps are honesty-gated (no new 60 s interactive session after main process exit / reboot /
    /// termination sentinel); instant-feedback language keys still write when the privacy gate
    /// allows so short optimistic language paint can proceed without resurrecting liveness.
    ///
    /// Play/pause callers must pass the settled session / ``homeWidgetLiveChrome`` language
    /// (``languageForLiveActivityOrWidgetOptimistic()``). This writer still **coerces** a
    /// disagreeing caller language via ``languageForInstantFeedbackWrite(_:)`` so neither
    /// an empty extension session (device locale) nor a leftover session code can plant
    /// that language while fresher ``homeWidgetLiveChrome`` already names the stream.
    /// Stream-switch callers persist the **destination** into session + live chrome first,
    /// so the destination is already the fresher settled source and is stored as given.
    /// The 15 s ``loadSharedState()`` window does not let a disagreeing instant-feedback
    /// language override ``settledLanguageForInstantFeedback()``.
    ///
    /// - Parameter language: Language code shown during the optimistic window (must match the
    ///   widget timeline language when possible). Persisted value is
    ///   ``languageForInstantFeedbackWrite(_:)`` of this argument.
    /// - Precondition: Home-widget privacy gate open (`hasActiveWidgets`) **or** call is from a
    ///   widget/extension process (intent execution is proof a surface exists).
    /// - Postcondition: On success, `isInstantFeedback` / `instantFeedbackTime` /
    ///   `instantFeedbackLanguage` are present. The stored language is `language` when it
    ///   matches ``settledLanguageForInstantFeedback()`` (or that resolver is `nil`);
    ///   otherwise the freshness-settled session / live-chrome language.
    ///   `lastUpdateTime` is refreshed only when
    ///   ``bumpWidgetLivenessTimestamp(policy:minInterval:)`` allows (main process rules or
    ///   extension refresh-of-open-window rules). When privacy-suppressed, **no** keys are written
    ///   (residuals cleared only via privacy clear or
    ///   ``clearHomeWidgetLivenessAndInstantFeedbackResiduals()`` when the gate closes).
    /// - SeeAlso: ``bumpWidgetLivenessTimestamp(policy:minInterval:)``,
    ///   ``clearHomeWidgetLivenessAndInstantFeedbackResiduals()``,
    ///   ``loadSharedState()``, ``languageForInstantFeedbackWrite(_:)``,
    ///   ``settledLanguageForInstantFeedback()``,
    ///   ``languageForLiveActivityOrWidgetOptimistic()``,
    ///   ``signalWidgetSwitchAction(visualState:language:)``,
    ///   CODING_AGENT.md (Single Source of Truth Principles).
    nonisolated static func writeInstantFeedback(language: String) {
        // Privacy gate (write suppression: no widgets configured).
        //
        // Bypass in widget process for the same reason as persistWidgetSnapshot: the executing
        // intent is proof a widget exists; we must allow the instantFeedbackLanguage (and a
        // liveness *refresh* when main was already in-window) so loadSharedState + providers
        // see optimistic language without a main-app roundtrip.
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
        let languageToWrite = Self.languageForInstantFeedbackWrite(language)
        #if DEBUG
        if languageToWrite != language {
            print("[SharedPlayerManager] Coercing instant feedback language \(language) to settled session/live-chrome \(languageToWrite)")
        }
        #endif
        let now = Date().timeIntervalSince1970
        // May no-op under extension honesty gate; instant-feedback keys still write below.
        Self.bumpWidgetLivenessTimestamp(policy: .immediate)
        defaults.set(true, forKey: "isInstantFeedback")
        defaults.set(now, forKey: "instantFeedbackTime")
        defaults.set(languageToWrite, forKey: "instantFeedbackLanguage")
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
    /// AGENT NOTE: Call on the home-widget privacy gate **true→false** edge (via
    /// ``WidgetRefreshManager/setHasActiveLutheranWidgets(_:)``). Re-asserting a closed gate
    /// must not re-run this clear. Privacy clear also removes these keys via
    /// ``removeAllLocalPlaybackKeys()`` (same set). Widget-process one-shot writes after re-add
    /// remain allowed via ``isWidgetProcess()`` bypasses on bump/instant.
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
    /// **Extension honesty (main not recently active / reboot):** When ``isWidgetProcess()`` is
    /// true, a bump is allowed only when the interactive window is **already** open
    /// (``isMainAppProcessRecentlyActive()`` before the write) **and**
    /// ``shouldDistrustDurableMirrorPlayPlanning()`` is false. Extension intents must not:
    /// - open a new 60 s interactive chrome session after main is no longer resident / stale heartbeat
    /// - clear a termination sentinel (`lastUpdateTime == 0`) by writing a positive timestamp
    /// - re-open interactive chrome after device reboot (boot-identity mismatch)
    ///
    /// Main-app bumps are unchanged (still privacy-gated only). Liveness remains a *presentation*
    /// heuristic — never a `play()` / cold-launch gate.
    ///
    /// - Parameters:
    ///   - policy: ``.throttled`` (default) respects `minInterval`; ``.immediate`` always stamps when allowed.
    ///   - minInterval: Minimum seconds between throttled writes (default 30). Ignored for `.immediate`.
    /// - SeeAlso: ``WidgetLivenessWritePolicy``, ``forceStaleLivenessTimestampForTermination()``,
    ///   ``isMainAppProcessRecentlyActive()``, ``shouldDistrustDurableMirrorPlayPlanning()``,
    ///   ``clearHomeWidgetLivenessAndInstantFeedbackResiduals()``,
    ///   ``events``, docs/Event-Driven-Refactor-Roadmap.md,
    ///   docs/Widget-Presentation-Dataflow.md.
    nonisolated static func bumpWidgetLivenessTimestamp(
        policy: WidgetLivenessWritePolicy = .throttled,
        minInterval: TimeInterval = 30
    ) {
        // Privacy gate: suppress liveness timestamp (and thus "app was recently running" signal) when no widgets installed.
        //
        // Widget-process bypass remains for privacy only (intent proves a surface exists). It does
        // **not** authorize resurrecting interactive chrome when main is not resident or post-reboot.
        guard Self.hasActiveWidgets || Self.isWidgetProcess() else {
            #if DEBUG
            print("[SharedPlayerManager] Suppressing liveness timestamp bump (no active widgets — write suppression)")
            #endif
            return
        }

        // Extension: refresh an already-open interactive window only. Never invent a fresh 60 s
        // "main is live" session from App Intent alone after process exit, termination sentinel, or reboot.
        if Self.isWidgetProcess() {
            if Self.shouldDistrustDurableMirrorPlayPlanning() {
                #if DEBUG
                print("[SharedPlayerManager] Suppressing extension liveness bump (termination sentinel or reboot distrust)")
                #endif
                return
            }
            if !Self.isMainAppProcessRecentlyActive() {
                #if DEBUG
                print("[SharedPlayerManager] Suppressing extension liveness bump (main not recently active — no interactive resurrection)")
                #endif
                return
            }
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
    ///   main-process bumps/reloads. Worst case 60 s of residual "active" presentation unless
    ///   extension honesty gates apply (below).
    /// - Widget/App Intent processes may **refresh** `lastUpdateTime` only while the 60 s
    ///   interactive window is already open **and** termination/reboot distrust is false
    ///   (see ``bumpWidgetLivenessTimestamp(policy:minInterval:)``). They must not open a new
    ///   interactive session after main process exit, clear a termination sentinel, or re-open chrome
    ///   after device reboot. They do not keep the main app alive.
    /// - The passive path only launches the app via Apple-approved mechanisms (widgetURL,
    ///   Live Activity tap "open", or AppIntent surfaces marked `.openAppWhenRun`). No
    ///   implicit play from the passive branch, no reload side-effects, no on-disk play
    ///   resurrection (cold-launch auto-play in the main UI is a separate product path).
    ///
    /// - Important: This is a *presentation heuristic only*. Never use for playback intent,
    ///   resurrection guards, or security decisions. Those use `PersistedWidgetState`,
    ///   `currentPlaybackIntent`, and `PlayerVisualState` directly.
    /// - Returns: `false` for missing key, explicit termination sentinel (0), stale (>60 s),
    ///   or device reboot since the last recorded healthy boot identity (residual pre-reboot
    ///   timestamps must not keep interactive chrome after hard power-off).
    /// - Note: 60 s matches the original widget `isAppRunning` window; keep in sync.
    /// - SeeAlso: ``bumpWidgetLivenessTimestamp(policy:minInterval:)``,
    ///   ``forceStaleLivenessTimestampForTermination()``,
    ///   ``hasDeviceRebootedSinceLastRecordedBoot()``,
    ///   `LutheranRadioWidget.swift` (the `if !isAppRunning()` branches and `widgetURL`),
    ///   `WidgetRefreshManager`, CODING_AGENT.md (Single Source of Truth Principles +
    ///   cross-target shared files), docs/Widget-Presentation-Dataflow.md (App Termination).
    ///
    /// AGENT NOTE: Any change to the 60 s constant, sentinel value, reboot distrust, or the
    /// decision here must also update the widget view branches, the termination call sites,
    /// extension liveness honesty tests, and this doc.
    nonisolated static func isMainAppProcessRecentlyActive() -> Bool {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return false }
        guard let lastUpdate = defaults.object(forKey: "lastUpdateTime") as? Double else { return false }
        if lastUpdate == 0 { return false } // explicit termination sentinel written on quit paths
        // Residual App Group heartbeat can survive hard power-off; boot identity is the
        // presentation signal that this process generation did not write it on this boot.
        if hasDeviceRebootedSinceLastRecordedBoot() { return false }
        return Date().timeIntervalSince1970 - lastUpdate < 60
    }

    /// Returns true when `lastUpdateTime` is the explicit termination sentinel value (0).
    ///
    /// - Returns: `true` only when the key exists *and* equals exactly 0.0 (written by
    ///   `forceStaleLivenessTimestampForTermination` on willTerminate / disconnect paths).
    /// - Note: Brand-new installs (missing key) and normal idle (positive timestamp, even if >60 s)
    ///   return `false`. Only the deliberate termination marker returns `true`.
    ///
    /// **Presentation / extension scope only.** This is the post-termination liveness marker
    /// for:
    /// - home-widget passive chrome via ``isMainAppProcessRecentlyActive()``
    /// - durable Live Activity mirror distrust via ``shouldDistrustDurableMirrorPlayPlanning()``
    ///
    /// It must **never** gate main-app `play()`, cold-launch auto-play, resurrection, or
    /// restore paths. Play status is process-local (factory reset + sticky intent SSOT).
    ///
    /// - SeeAlso: ``isMainAppProcessRecentlyActive()``, ``forceStaleLivenessTimestampForTermination()``,
    ///   ``shouldDistrustDurableMirrorPlayPlanning()``,
    ///   CODING_AGENT.md (SSOT + memory-only visual policy),
    ///   docs/Widget-Presentation-Dataflow.md.
    ///
    /// AGENT NOTE: Do not reintroduce this as a play / cold-launch / resurrection gate.
    /// Update widget presentation + mirror-distrust call sites only when changing semantics.
    nonisolated static func hasExplicitTerminationSentinel() -> Bool {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return false }
        guard let lastUpdate = defaults.object(forKey: "lastUpdateTime") as? Double else { return false }
        return lastUpdate == 0
    }

    /// Forces the widget liveness timestamp to the explicit termination sentinel (0).
    ///
    /// **Presentation termination surface** (liveness heuristic only). Call this from main-app
    /// termination paths only. It makes ``isMainAppProcessRecentlyActive()`` return false
    /// on the next widget provider execution so all surfaces render the passive,
    /// launch-only UI ("tap to open") immediately rather than showing stale active controls.
    ///
    /// Also clears short-lived instant-feedback keys so no "just acted" optimistic state
    /// survives the quit visually, and clears durable LA mirrors so extension planning cannot
    /// invent play from residual chrome after process exit.
    ///
    /// This heuristic is separate from the `PlayerEvent` emission model and from main-app
    /// playback decisions. Event subscribers learn about termination via process lifetime;
    /// widgets use the sentinel for their render decision. The next cold launch factory-resets
    /// play status independently of this key.
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
    /// - SeeAlso: ``isMainAppProcessRecentlyActive()``, ``hasExplicitTerminationSentinel()``,
    ///   AppDelegate.applicationWillTerminate, SceneDelegate.sceneDidDisconnect,
    ///   RadioLiveActivityManager.handleAppWillTerminate,
    ///   ``removeAllLocalPlaybackKeys()``, ``clearHomeWidgetLiveChromeMirror()``,
    ///   docs/Event-Driven-Refactor-Roadmap.md, docs/Widget-Presentation-Dataflow.md,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§6.3, §7).
    nonisolated static func forceStaleLivenessTimestampForTermination() {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return }
        defaults.set(0.0, forKey: "lastUpdateTime")
        // Clear optimistic transients so the widget does not flash a stale "just played" state
        // on its next render after the main process has exited.
        defaults.removeObject(forKey: "isInstantFeedback")
        defaults.removeObject(forKey: "instantFeedbackTime")
        defaults.removeObject(forKey: "instantFeedbackLanguage")
        // Visual state is memory-only; no on-disk snapshot to preserve across termination.
        // LA ends on termination — drop durable toggle visual + language mirrors so a cold
        // extension cannot plan pause/play or stamp language chrome from residual LA mirrors.
        clearLiveActivityToggleVisualStateMirror()
        clearLiveActivityLanguageMirror()
        // Home live chrome is session-scoped only (OI-1): clear so passive post-terminate
        // Providers do not briefly flash last playing/pause glyphs from the exited process.
        clearHomeWidgetLiveChromeMirror()
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
    ///   non-empty destination stamp (`streamSwitchConnectingLanguageCode`) — Connecting hold
    ///   **or** paused-path stamp — outranks preferred/snapshot/model → preferredWidgetLanguage →
    ///   no-snapshot model repair → preferred `"en"` disambiguation (keep intentional English
    ///   when model is `"en"`; repair hard-default pollution only when model is non-en) → hold
    ///   without destination prefers Direct model (already updated by switch prep). Destination
    ///   stamp keeps the session snapshot language aligned with Live Activity
    ///   ``liveActivityLanguageCodeForContentPush()`` before preferred/model fully settle.
    ///
    /// - Important: Language is resolved **after** any suspension points in this method so a
    ///   concurrent ``saveCombinedWidgetState(language:)`` (switch-path destination write) is
    ///   visible before `performActualSave`. Resolving before `await` and writing after allowed
    ///   a stale prior language to clobber the destination as the last writer.
    ///
    /// - Postcondition: If a write occurs, the in-process session snapshot contains the latest
    ///   (visualState, currentLanguage, hasError, metadata). Widget timeline reload is scheduled
    ///   by the Tier 2 ``PlayerEvent`` observer (``.persistedWidgetStateDidUpdate`` and related cases).
    ///
    /// - SeeAlso: ``PersistedLanguageResolution``, ``performActualSave(_:)``,
    ///   ``preferredWidgetLanguage()``, ``streamSwitchConnectingLanguageCode``,
    ///   ``liveActivityLanguageCodeForContentPush()``,
    ///   ``saveCombinedWidgetState(language:)``,
    ///   ``persistWidgetSnapshot(visualState:language:streamMetadata:clearStreamMetadata:hasError:)``,
    ///   ``loadPersistedWidgetState()``, CODING_AGENT.md (Single Source of Truth Principles),
    ///   the resurrection and persistence tables in this file,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md (Connecting + destination language).
    ///
    /// Actor-isolated. Callers on the main path must `await`.
    // Now async – callers must await this when they want to save
    func saveCurrentState() async {
        guard !isRunningInWidget() else { return }
        
        let player = DirectStreamingPlayer.shared

        // Suspend before language resolve so concurrent destination snapshot writes are visible.
        // Source the legacy "playing" bool from the authoritative visual state (SSOT),
        // not the racy snapshot in actualPlaybackState. The snapshot frequently returns
        // false during normal playback (KVO timing, brief buffering, rate reads) causing
        // the "playing" UserDefaults key (used by WidgetToggleRadioIntent decision logic
        // and loadSharedState fallbacks) to be wrong. This was the "elsewhere" causing
        // first-widget-interaction flakiness even after the pause throttle fix.
        let isPermanentError = await player.isLastErrorPermanent()
        let isPlaying = currentVisualState.isActivelyPlaying
        let hasPermanentError = player.hasPermanentError

        // Pure language reconciliation (table-tested in WidgetSurface). Actor only gathers inputs.
        // Privacy write suppression remains in performActualSave — resolution never decides write.
        // Pass hold-time destination so snapshot language matches LA ContentState during Connecting
        // (preferred/snapshot/model still lag on the prior stream until engine switch completes).
        // AGENT NOTE: Resolve immediately before performActualSave — never cache language across
        // an `await` or a concurrent saveCombinedWidgetState destination write can be clobbered.
        let snapshot = Self.loadPersistedWidgetState()
        let currentLanguageCode = PersistedLanguageResolution.resolve(
            preferredLanguage: Self.preferredWidgetLanguage(),
            hasSnapshot: snapshot != nil,
            snapshotLanguage: snapshot?.currentLanguage,
            modelLanguage: DirectStreamingPlayer.shared.selectedStream.languageCode,
            streamSwitchHoldActive: holdPrePlayVisualUntilPlayback,
            connectingLanguageCode: streamSwitchConnectingLanguageCode
        )

        // Persist path compares the tuple + actor `currentVisualState` / metadata only.
        // In-memory ``WidgetState`` is a WidgetRefreshManager projection and is not built here.
        let currentState = (
            isPlaying: isPlaying,
            currentLanguage: currentLanguageCode,
            hasError: hasPermanentError || isPermanentError
        )
        
        performActualSave(currentState)
    }
    
    nonisolated func saveFireAndForget() {
        Task {
            await saveCurrentState()
        }
    }
    
    /// Pure policy: skip re-persist of identical sticky Connecting chrome (``.prePlay`` / ``.cleared``).
    ///
    /// Attach-path status storms and coordinator label saves call ``saveCurrentState()`` many times
    /// while language and connecting visual are already correct. The first transition into Connecting
    /// (prior visual ≠ connecting) still writes because ``previousVisual`` differs. Language changes,
    /// error repairs, and metadata mutations still write. Parity with sticky-pause force-save skip
    /// on the status pipeline and with ``WidgetRefreshManager/shouldCoalesceIdenticalNonPlayingRefresh``.
    ///
    /// - Parameters:
    ///   - currentVisual: Actor visual about to be persisted.
    ///   - previousVisual: Snapshot visual from the last write, if any.
    ///   - languageUnchanged: `true` when candidate language matches the snapshot language.
    ///   - errorUnchanged: `true` when permanent-error flags match.
    ///   - metadataUnchanged: `true` when stream program metadata matches.
    ///   - hasError: Candidate permanent-error flag (never skip error repairs).
    /// - Returns: `true` when the persist must no-op (liveness-only).
    /// - SeeAlso: ``performActualSave(_:)``,
    ///   ``DirectStreamingPlayer/shouldSkipForceWidgetSaveOnStableStatus(isPlaying:reasonKey:visual:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    nonisolated static func shouldSkipIdenticalStickyConnectingSnapshotWrite(
        currentVisual: PlayerVisualState,
        previousVisual: PlayerVisualState?,
        languageUnchanged: Bool,
        errorUnchanged: Bool,
        metadataUnchanged: Bool,
        hasError: Bool
    ) -> Bool {
        guard !hasError else { return false }
        guard languageUnchanged, errorUnchanged, metadataUnchanged else { return false }
        guard let previousVisual, previousVisual == currentVisual else { return false }
        switch currentVisual {
        case .prePlay, .cleared:
            return true
        case .playing, .userPaused, .thermalPaused, .securityLocked:
            return false
        }
    }

    /// Authoritative privacy-gated App Group snapshot write for the main-app persist path.
    ///
    /// Uses the caller-provided `(isPlaying, currentLanguage, hasError)` tuple together with
    /// actor-isolated ``currentVisualState`` and ``currentStreamMetadata``. Does not accept an
    /// in-memory ``WidgetState`` projection — that type is owned by ``WidgetRefreshManager`` for
    /// coalesce / debounce bookkeeping only.
    ///
    /// - Parameters:
    ///   - state: Candidate play/language/error flags resolved by ``saveCurrentState()``.
    /// - Precondition: Caller must already be on the main-app process path (`saveCurrentState`
    ///   returns early in the extension).
    /// - Postcondition: When the privacy gate is open and the candidate is not an identical
    ///   sticky Connecting no-op / non-urgent unchanged snapshot, ``savePersistedWidgetState``
    ///   runs and liveness is stamped immediately; otherwise only a liveness bump may occur.
    /// - SeeAlso: ``saveCurrentState()``, ``shouldSkipIdenticalStickyConnectingSnapshotWrite``,
    ///   ``WidgetRefreshManager``, ``bumpWidgetLivenessTimestamp(policy:minInterval:)``,
    ///   the App Group table in `SharedPlayerManager.swift`,
    ///   docs/Widget-Functionality-Roadmap.md
    internal func performActualSave(_ state: (isPlaying: Bool, currentLanguage: String, hasError: Bool)) {
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
        let languageUnchanged = previousSnapshot.map { $0.currentLanguage == state.currentLanguage } ?? false

        let previousHasError = previousSnapshot?.hasError ?? false
        let previousIsPlaying = previousSnapshot?.visualState.isActivelyPlaying ?? false
        let errorUnchanged = previousHasError == state.hasError

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
        // Do not treat playing→Connecting (stream-switch hold) as "playing stopped" urgency once
        // Connecting chrome for the destination language is already on the snapshot — that is
        // attach-path noise covered by ``shouldSkipIdenticalStickyConnectingSnapshotWrite``.
        let isPlayingStopped = previousIsPlaying && !state.isPlaying
            && !(currentVisualState == .prePlay || currentVisualState == .cleared)
        let isUrgentUpdate = state.hasError || isLanguageChange || isTransitionToStickyPause || isPlayingStopped

        // Attach-path quiet: identical sticky Connecting chrome + unchanged language → skip
        // (parity with sticky-pause force-save skip). First prePlay write still lands when
        // previous visual differs or language/error/metadata changed.
        if Self.shouldSkipIdenticalStickyConnectingSnapshotWrite(
            currentVisual: currentVisualState,
            previousVisual: previousSnapshot?.visualState,
            languageUnchanged: languageUnchanged,
            errorUnchanged: errorUnchanged,
            metadataUnchanged: metadataUnchanged,
            hasError: state.hasError
        ) {
            Self.bumpWidgetLivenessTimestamp()
            #if DEBUG
            print("[SharedPlayerManager] performActualSave: identical sticky connecting — skipping persist")
            #endif
            return
        }

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
    
    /// Combined playback chrome for widget / Live Activity / intent readers.
    ///
    /// `isPlaying` and `hasError` always come from the in-process ``PersistedWidgetState``
    /// snapshot. Language uses the 15 s instant-feedback window only when that code agrees
    /// with ``settledLanguageForInstantFeedback()``, or when neither session nor
    /// ``homeWidgetLiveChrome`` has a language yet (first-tap / destination flash). Play/pause
    /// of a settled stream must not let a leftover session code or lagging
    /// ``instantFeedbackLanguage`` override the fresher of those sources.
    ///
    /// - Returns: `isPlaying` from snapshot visual, `currentLanguage` per the instant-feedback
    ///   vs freshness-settled session / live-chrome rule, `hasError` from the snapshot.
    /// - SeeAlso: ``writeInstantFeedback(language:)``,
    ///   ``languageForInstantFeedbackWrite(_:)``,
    ///   ``settledLanguageForInstantFeedback()``,
    ///   ``languageForLiveActivityOrWidgetOptimistic()``,
    ///   ``settledSessionOrHomeLiveChromeLanguages()``,
    ///   ``preferredWidgetLanguage()``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§5.3),
    ///   docs/Widget-Presentation-Dataflow.md,
    ///   CODING_AGENT.md (Single Source of Truth Principles).
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
                let settledLanguage = Self.settledLanguageForInstantFeedback()
                // Instant feedback is the short optimistic **switch** flash (destination already
                // the fresher of session / live chrome) or the only language when no snapshot
                // exists. A leftover session code is not a valid match when chrome is strictly
                // fresher — ``settledLanguageForInstantFeedback()`` applies that rule.
                let currentLanguage: String
                if let settledLanguage, settledLanguage != instantFeedbackLanguage {
                    currentLanguage = settledLanguage
                    #if DEBUG
                    print("[SharedPlayerManager] Ignoring instant feedback language \(instantFeedbackLanguage) (age: \(age)s) — settled session/live-chrome is \(currentLanguage)")
                    #endif
                } else {
                    currentLanguage = instantFeedbackLanguage
                    #if DEBUG
                    print("[SharedPlayerManager] Using instant feedback state: \(instantFeedbackLanguage), age: \(age)s")
                    #endif
                }

                return (isPlaying, currentLanguage, hasError)
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
    /// - Note: Uses ``PlaybackIntent/sleepTimer`` (not sticky ``.userPaused``) so resume rules
    ///   differ from explicit ``stop()`` / ``markAsUserPaused()`` pause paths.
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
