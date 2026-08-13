//
//  WidgetRefreshManager.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 14.6.2025.
//
//  Prevents excessive widget refreshes through debouncing and change detection.
//  Fully aligned with PlayerVisualState as the Single Source of Truth (SSOT).
//
//  Dual-path architecture (non-forcing; intentional):
//  - Mutation path (main app): the Tier 2 `PlayerEvent` observer is the sole
//    driver of timeline reloads after in-process state mutations (saves, stream
//    transitions, language updates emit events; imperative refresh was removed).
//  - Imperative path: lifecycle (foreground), teardown / post-stop hygiene,
//    termination, widget-extension optimistic intents, and optional
//    `refreshAllMediaSurfaces(widgetRefresh:)` — surfaces that have no
//    corresponding PlayerEvent or run outside the main-app event stream.
//  Both paths converge on the public `refreshIfNeeded` surface with the same
//  debouncing, coalescing, regress guards, privacy gate, and session-teardown
//  suppression. Duplicate triggers are expected at some edges (e.g. post-stop
//  hygiene + stop emissions) and are deduplicated inside that surface.
//
//  Each call site passes ``WidgetRefreshTrigger`` so dual-path inventory and
//  DEBUG dual-fire observation stay honest. See docs/Event-Driven-Refactor-Roadmap.md
//  (imperative refresh inventory) and docs/Widget-Functionality-Roadmap.md.
//

// SHARED: Cross-target source (main app + LutheranRadioWidgetExtension)
//
// Single physical file on disk, compiled into both targets via Xcode
// File System Synchronized Group + membershipExceptions (see project.pbxproj).
//
// Purpose:
// @MainActor coordinator for debounced, coalesced `WidgetCenter.reloadTimelines`
// calls. Prevents spam while ensuring widgets and Live Activities reflect the
// latest `PlayerVisualState` promptly.
//
// Key invariants:
// - 100% driven by `PlayerVisualState` (the SSOT).
// - Respects the privacy gate `hasActiveLutheranWidgets` (via
//   `WidgetRefreshManager` + `SharedPlayerManager`) to suppress writes when no
//   Lutheran widgets are installed.
// - Coalesces `.prePlay` → `.playing` and dedupes **identical** non-playing chrome
//   (connecting `.prePlay`/`.cleared` + sticky pause/lock) so attach-path and dual-path
//   storms do not re-issue `reloadTimelines` for unchanged language/visual. Attach-path
//   Connecting deferral holds a single coalesce deadline (does not reset on each status
//   callback). Execute-time home **wake** discard (``refreshWouldDiscardHomeWake`` —
//   memory lag then session lag) blocks residual sticky after intentional Connecting and
//   mid-switch premature `.playing` without inventing playing during hold. Reload is
//   wake-only; Provider paint is session + privacy-gated ``homeWidgetLiveChrome``.
// - Main-app mutation-path reloads are driven by the `PlayerEvent` observer;
//   imperative callers remain for lifecycle, teardown, extension optimistic,
//   and optional media-surface coordination only (non-forcing dual path).
// - This file contains *no* security logic. Security decisions live only in
//   `Core/` (see CODING_AGENT.md "Core Framework Surface Area").
//
// - SeeAlso: `SharedPlayerManager` (authoritative emitter of `PlayerEvent` via
//   ``events``; imperative lifecycle/teardown refresh callers), `PlayerVisualState`,
//   `PlayerEvent`, `PersistedWidgetState`, `WidgetEventObserver`, ``WidgetRefreshTrigger``,
//   CODING_AGENT.md (Single Source of Truth Principles + "Cross-target shared
//   source files (non-Core)" + event-driven non-forcing direction + Documentation
//   & Comment Standards),
//   docs/Event-Driven-Refactor-Roadmap.md (Tier 2 consumers + dual-path inventory),
//   docs/Widget-Functionality-Roadmap.md (refresh inventory),
//   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§8 wake-discard / PR5),
//   docs/Live-Activity-Stacking-and-Media-Surfaces.md (widget refresh quiet path),
//   <doc:Architecture>, README.md.

import Foundation
import WidgetKit
import WidgetSurface

/// Classifies why ``WidgetRefreshManager/refreshIfNeeded(visualState:currentLanguage:hasError:immediate:trigger:)``
/// was invoked.
///
/// Dual-path inventory (non-forcing architecture):
/// - **Event family** (``.playerEvent``): main-app mutation-path sole driver after
///   in-process state mutations emit ``PlayerEvent``.
/// - **Imperative family** (all other cases): lifecycle, teardown, extension optimistic,
///   optional media-surface coordination — no PlayerEvent stream or extension cannot emit.
///
/// Call sites must pass the matching case so DEBUG dual-fire observation and permanent
/// docs stay aligned. Duplicate event+imperative triggers within a short window are
/// expected at some edges and are deduplicated by debounce/coalesce inside ``refreshIfNeeded``.
///
/// - SeeAlso: ``WidgetRefreshManager/refreshIfNeeded(visualState:currentLanguage:hasError:immediate:trigger:)``,
///   ``WidgetRefreshManager/handlePlayerEvent(_:)``,
///   docs/Event-Driven-Refactor-Roadmap.md (dual-path inventory),
///   docs/Widget-Functionality-Roadmap.md (refresh inventory).
enum WidgetRefreshTrigger: String, Equatable, Sendable {
    /// Tier 2 ``PlayerEvent`` observer (``handlePlayerEvent(_:)``). Mutation path.
    case playerEvent
    /// Process/scene lifecycle with no corresponding ``PlayerEvent`` (e.g. foreground).
    case lifecycle
    /// Session teardown, post-stop hygiene, termination, factory-reset widget reload.
    case teardown
    /// Widget-extension optimistic intent or extension-process ``handleWidgetPlay`` / ``handleWidgetStop``.
    case extensionOptimistic
    /// ``SharedPlayerManager/refreshAllMediaSurfaces(liveActivity:widgetRefresh:widgetRefreshImmediate:)``
    /// when `widgetRefresh` is `true` (optional; default `false` prefers the event path).
    case mediaSurface
    /// Unit tests and DEBUG white-box seams that do not model a production caller.
    case test

    /// Whether this trigger belongs to the event observer family or an imperative caller.
    var pathFamily: WidgetRefreshPathFamily {
        switch self {
        case .playerEvent:
            return .event
        case .lifecycle, .teardown, .extensionOptimistic, .mediaSurface, .test:
            return .imperative
        }
    }
}

/// Coarse dual-path family for DEBUG dual-fire observation.
///
/// - SeeAlso: ``WidgetRefreshTrigger``, ``WidgetRefreshManager``.
enum WidgetRefreshPathFamily: String, Equatable, Sendable {
    /// ``WidgetRefreshTrigger/playerEvent`` — Tier 2 observer.
    case event
    /// Lifecycle, teardown, extension optimistic, media-surface, or test.
    case imperative
}

/// WidgetRefreshManager prevents excessive WidgetKit reloads through debouncing,
/// change detection, and adaptive intervals.
///
/// It is 100% driven by `PlayerVisualState` (the SSOT). Main-app **mutation-path**
/// timeline reloads are driven by the internal observer over `SharedPlayerManager.events`
/// (``handlePlayerEvent(_:)`` → ``refreshIfNeeded``). **Imperative** callers remain for
/// lifecycle, teardown/post-stop, termination, widget-extension optimistic intents, and
/// optional ``refreshAllMediaSurfaces`` widget refresh — surfaces without a usable
/// PlayerEvent stream. Both families share derivation surfaces (`loadPersistedWidgetState`,
/// `loadSharedState`) and the same public ``refreshIfNeeded`` guards.
///
/// `SharedPlayerManager.currentState` and `makeEventsStreamWithReplay()` are
/// available for any observer (including future widget paths) that requires
/// replay of state present before subscription.
///
/// - SeeAlso: `refreshIfNeeded(visualState:currentLanguage:hasError:immediate:trigger:)`,
///   ``WidgetRefreshTrigger``, `SharedPlayerManager.events`, `SharedPlayerManager.currentState`,
///   `SharedPlayerManager.makeEventsStreamWithReplay()`, `PlayerEvent`,
///   `PlayerCurrentState`, ``beginObservingPlayerEvents()``,
///   `WidgetEventObserver`,
///   docs/Event-Driven-Refactor-Roadmap.md (Tier 2 consumer + dual-path inventory),
///   CODING_AGENT.md, <doc:Architecture>.
@MainActor
final class WidgetRefreshManager: @unchecked Sendable {
    static let shared = WidgetRefreshManager()
    
    var lastRefreshTime: Date?
    private var pendingRefresh: DispatchWorkItem?
    /// Latest debounced target; read when the debounce timer runs so superseded visuals never reload timelines.
    private var pendingRefreshState: WidgetState?
    var lastKnownState: WidgetState?
    /// Interactive paint epoch observed at the last successful kind reload (0 when none).
    ///
    /// When ``homeWidgetInteractivePaintEpoch`` advances after a live-chrome / optimistic stamp
    /// while visual + language are unchanged, identical non-playing coalesce would skip the
    /// follow-up ``reloadTimelines`` that residual LIVE needs to re-resolve. Comparing suite
    /// epoch to this bookkeeping token allows one more kind-only wake without dual
    /// ``reloadAllTimelines`` thrash.
    ///
    /// DEBUG debounce observation must snapshot the same token on simulated execute; otherwise
    /// any leftover suite epoch looks permanently “advanced” and identity-coalesce never fires.
    /// - SeeAlso: ``_test_resetRefreshTimingState()``, ``performRefresh(for:)``.
    var lastPaintEpochAtSuccessfulReload: Int = 0
    /// Deferred `.prePlay` refresh; superseded by `.playing` on the same language within the coalesce window.
    private var coalescedPrePlayWorkItem: DispatchWorkItem?
    private var coalescedPrePlayState: WidgetState?
    
    /// The long-lived observation task for the non-forcing `PlayerEvent` stream.
    ///
    /// Created exactly once in `init` (main-app only) and retained for the
    /// lifetime of the shared `WidgetRefreshManager`. It delivers events to
    /// `handlePlayerEvent(_:)` which routes through the canonical
    /// `refreshIfNeeded(visualState:currentLanguage:hasError:immediate:)` entry
    /// point.
    ///
    /// - Important: This task is the **sole driver** for main-app mutation-path timeline
    ///   reloads (Tier 3 dedup, 2026-07-13). Imperative callers remain for lifecycle,
    ///   foreground, teardown, and widget-extension optimistic paths only.
    ///   The observer never forces a reload or mutates any debounce/coalesce state
    ///   outside the public surface.
    /// - Note: Guarded against widget extension process (no emissions occur there).
    /// - SeeAlso: ``beginObservingPlayerEvents()``, ``handlePlayerEvent(_:)``,
    ///   `SharedPlayerManager.events`, `PlayerEvent`, docs/Event-Driven-Refactor-Roadmap.md,
    ///   `WidgetEventObserver`.
    var eventObservationTask: Task<Void, Never>?

    var refreshCount = 0
    var adaptiveInterval: TimeInterval = 0.5
    private static let prePlayToPlayingCoalesceWindow: TimeInterval = 0.3

    /// Consolidated observer for the `PlayerEvent` stream.
    ///
    /// The observer is the extracted common implementation (see `WidgetEventObserver`).
    /// Its task is published into the legacy `eventObservationTask` seam for
    /// compatibility with any external inspection (none currently for this path).
    let playerEventObserver = WidgetEventObserver<PlayerEvent>()

    // MARK: - Privacy support (widget presence gating for write suppression)
    // Single source of truth for active Lutheran Radio widgets (home widget + Control Center kind).
    // Used by SharedPlayerManager write paths to suppress re-population of persistedWidgetState,
    // instantFeedback*, pendingAction*, lastUpdateTime, etc. when no Lutheran widgets are configured.
    // After an explicit clearAllLocalState the flag is forced false even
    // if configs still list the widget (prevents immediate re-write of a fresh snapshot on next play
    // until explicit re-detect on foreground or subsequent detection).
    // Widget providers (LutheranRadioWidget.swift, Control, LiveActivity) already early-return
    // to safe .prePlay + preferred language defaults when loadPersistedWidgetState() == nil.
    // The canonical list of our widget kinds lives in `ourWidgetKinds`.
    //
    // Concurrency: nonisolated(unsafe) justified because:
    // - Updates are serialized exclusively through @MainActor entry points (refreshHasActiveWidgets, setHasActiveLutheranWidgets, performRefresh).
    // - The containing class is already @unchecked Sendable (existing pattern in this file for WidgetKit/refresh state).
    // - Reads are best-effort cache for a privacy optimization gate (occasional stale true -> one extra write is harmless; false when should be true just delays a write until next foreground detect).
    // - Matches the risk profile of other timestamp/liveness mutable state already managed here.
    //
    // AGENT NOTE (widget initial play fix): The gate is intentionally bypassed inside
    // SharedPlayerManager for isWidgetProcess() during AppIntent execution. Widget code also
    // calls setHasActiveLutheranWidgets(true) in Provider entry points. This ensures the
    // first tap on a newly added widget can persist .playing + lang and bump lastUpdateTime
    // (see initial-play-widget.log failures: configs:0, lang:en, suppressing writes).
    nonisolated(unsafe) static private var _hasActiveLutheranWidgets: Bool = false
    // Nonisolated getter so it can be read from nonisolated static write-guard paths in SharedPlayerManager
    // (and widget extension code) while updates remain serialized on @MainActor.
    nonisolated static var hasActiveLutheranWidgets: Bool { unsafe _hasActiveLutheranWidgets }

    /// Sets the home/Control widget privacy write-suppression flag.
    ///
    /// Residual App Group clear (liveness `lastUpdateTime`, instant-feedback triple, privacy-gated
    /// program-metadata mirror, and live-chrome mirror) runs **only on the true→false edge** —
    /// same spirit as the false→true re-stamp. Re-asserting `false` while the gate is already
    /// closed is a no-op for residual keys so WidgetCenter lag (`configs: 0` while widgets still
    /// exist and extension intent paths may have stamped under widget-process bypass) cannot
    /// repeatedly wipe extension-readable chrome. Full privacy clear / factory / terminate paths
    /// still clear via their own helpers and are unaffected.
    ///
    /// Does not clear pending-action mailbox keys, Live Activity durable mirrors, or security caches.
    ///
    /// When the gate **opens** (`value == true` after a closed state), schedules a one-shot
    /// re-stamp of in-memory ICY program metadata **and** session live chrome into privacy-gated
    /// App Group mirrors so home widgets receive titles + visual/language that arrived while
    /// writes were suppressed (identical subsequent ICY is a no-op and would otherwise never
    /// re-persist; live chrome projects actor visual without inventing mid-hold ``.playing``).
    ///
    /// - Parameter value: `true` when at least one of our home/Control widget kinds is configured
    ///   (or a test/provider seam opens the gate); `false` forces write suppression.
    /// - SeeAlso: ``hasActiveLutheranWidgets``,
    ///   ``SharedPlayerManager/clearHomeWidgetLivenessAndInstantFeedbackResiduals()``,
    ///   ``SharedPlayerManager/clearHomeWidgetStreamMetadataMirror()``,
    ///   ``SharedPlayerManager/clearHomeWidgetLiveChromeMirror()``,
    ///   ``SharedPlayerManager/restampHomeWidgetProgramMetadataAfterPrivacyGateOpenIfNeeded()``,
    ///   ``SharedPlayerManager/restampHomeWidgetLiveChromeAfterPrivacyGateOpenIfNeeded()``,
    ///   ``SharedPlayerManager/bumpWidgetLivenessTimestamp(policy:minInterval:)``,
    ///   ``SharedPlayerManager/clearAllLocalState()``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§5.5, §7 privacy clear matrix).
    @MainActor
    static func setHasActiveLutheranWidgets(_ value: Bool) {
        let previous = hasActiveLutheranWidgets
        unsafe _hasActiveLutheranWidgets = value
        if previous && !value {
            // true→false edge only: drop residual heartbeat / optimistic language keys /
            // program-metadata + live-chrome mirrors. Re-asserting false must not wipe
            // extension-stamped chrome while WidgetCenter still reports configs:0 lag.
            SharedPlayerManager.clearHomeWidgetLivenessAndInstantFeedbackResiduals()
            SharedPlayerManager.clearHomeWidgetStreamMetadataMirror()
            SharedPlayerManager.clearHomeWidgetLiveChromeMirror()
        } else if value && !previous {
            // false→true edge only: ICY + session visual/language may already sit in main-app
            // memory (LA path / actor chrome) while home persist was suppressed. Re-stamp once
            // so Providers can read program + live chrome after install-while-playing.
            #if LUTHERAN_MAIN_APP
            Task {
                await SharedPlayerManager.shared.restampHomeWidgetProgramMetadataAfterPrivacyGateOpenIfNeeded()
                await SharedPlayerManager.shared.restampHomeWidgetLiveChromeAfterPrivacyGateOpenIfNeeded()
            }
            #endif
        }
    }

    /// Cross-process teardown gate: suppresses WidgetCenter IPC while system Now Playing
    /// session teardown is in flight (cold-launch factory reset, privacy clear, terminate).
    ///
    /// Set by ``SharedPlayerManager/teardownNowPlayingSession()`` and
    /// ``SharedPlayerManager/clearSystemNowPlayingMetadataSynchronously()``.
    /// Prevents debounced `reloadTimelines` from racing MediaRemoteUI during launch watchdog windows.
    ///
    /// - SeeAlso: ``setSessionTeardownInProgress(_:)``, ``refreshIfNeeded(visualState:currentLanguage:hasError:immediate:)``,
    ///   docs/Event-Driven-Refactor-Roadmap.md.
    // SAFETY: Written from @MainActor teardown entry points and SharedPlayerManager actor
    // `finishSessionTeardown`; read from refresh guards on @MainActor and nonisolated paths.
    // Stale `true` only delays one refresh cycle; stale `false` may allow one extra reload.
    nonisolated(unsafe) static private var _isSessionTeardownInProgress: Bool = false
    nonisolated static var isSessionTeardownInProgress: Bool { unsafe _isSessionTeardownInProgress }

    nonisolated static func setSessionTeardownInProgress(_ value: Bool) {
        unsafe _isSessionTeardownInProgress = value
    }

    /// Re-queries WidgetCenter.currentConfigurations() and updates the hasActiveLutheranWidgets flag.
    /// Primary call sites: sceneDidBecomeActive / foreground (SceneDelegate), after clear (forced false
    /// first, then re-detect allowed on next foreground), and opportunistic on write attempts when suppressed.
    ///
    /// Under test isolation (`SharedPlayerManager.isRunningInUITestMode`) this early-returns
    /// without performing the WidgetCenter IPC. WidgetCenter queries and reloadTimelines can
    /// wake widget renderers / Chrono (Live Activity surfaces) and cause multi-minute stalls
    /// in `xcodebuild test` environments. Tests that need the gate open use the direct
    /// `setHasActiveLutheranWidgets(true)` seam instead.
    @MainActor
    func refreshHasActiveWidgets() async {
        // Defense-in-depth test isolation (parallel to refreshIfNeeded and LA manager guards).
        // Prevents slow WidgetCenter system service round-trips during unit tests.
        if SharedPlayerManager.isRunningInUITestMode {
            return
        }
        if Self.isSessionTeardownInProgress {
            return
        }

        do {
            let configs = try await WidgetCenter.shared.currentConfigurations()
            let hasActive = configs.contains { Self.ourWidgetKinds.contains($0.kind) }
            Self.setHasActiveLutheranWidgets(hasActive)
            #if DEBUG
            print("[WidgetRefreshManager] Active Lutheran widgets re-detected for privacy gate: \(hasActive) (configs: \(configs.count))")
            #endif
        } catch {
            #if DEBUG
            print("[WidgetRefreshManager] refreshHasActiveWidgets failed: \(error.localizedDescription)")
            #endif
        }
    }
    
    private init() {
        #if DEBUG
        // XCTest hosts share this singleton with emitter unit tests. Suppress Tier 2
        // live observation by default so ``SharedPlayerManager/events`` remains available
        // for direct AsyncStream contract tests (single-iterator ``AsyncStream`` semantics).
        // Consumer tests that need the production observer call
        // ``_test_beginObservingPlayerEventsForTests()``.
        if SharedPlayerManager.isRunningInUITestMode {
            unsafe Self._test_suppressPlayerEventObservation = true
        }
        #endif

        // Start the additive internal observer of `SharedPlayerManager.events`.
        // Only the main app process emits; the guard inside prevents starting
        // a no-op consumer in the widget extension.
        beginObservingPlayerEvents()
    }

    // Single source for the widget kind identifiers we own (home widget + Control Center widget).
    // Used by the privacy hasActiveLutheranWidgets gate in refresh paths. Centralizing here means
    // adding a new widget kind in the future only requires one edit.
    private static let ourWidgetKinds = ["LutheranRadioWidget", "radio.lutheran.LutheranRadio.LutheranRadioWidget"]
    
    // MARK: - Modern API (only public entry point)
    
    /// Drops any scheduled debounced refresh (e.g. before a visual SSOT transition).
    ///
    /// Called from termination cleanup paths (AppDelegate, SceneDelegate) to ensure no
    /// in-flight work from the dying main process can still execute a `reloadTimelines`
    /// after the process has exited. Safe to call during willTerminate.
    ///
    /// The long-lived event observation task (``eventObservationTask``) is deliberately
    /// left running; termination of the main app process ends the task naturally.
    /// Observation is additive and does not participate in the "pending work" that
    /// must be cancelled to prevent post-exit reloads.
    func cancelPendingRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        pendingRefreshState = nil
        cancelCoalescedPrePlayRefresh()
    }
    
    /// Single public surface for all widget timeline reload decisions.
    ///
    /// Invoked by:
    /// - **Mutation path (main app):** ``handlePlayerEvent(_:)`` with ``WidgetRefreshTrigger/playerEvent``
    /// - **Imperative path:** lifecycle, teardown, extension optimistic, optional media-surface
    ///   coordination — each call site passes an explicit ``WidgetRefreshTrigger``
    ///
    /// - Parameters:
    ///   - visualState: Target ``PlayerVisualState`` for the timeline entry.
    ///   - currentLanguage: Caller-supplied stream language hint. Re-resolved via
    ///     ``SharedPlayerManager/languageForWidgetRefreshDerivation(fallbackLanguage:)`` so
    ///     coalesce / DEBUG labels track stream attach / LA content-push language under
    ///     privacy write suppression (never privacy hard-default `"en"` alone while the
    ///     engine stream is non-English).
    ///   - hasError: Permanent-error chrome flag from shared state.
    ///   - immediate: When `true`, bypasses prePlay coalesce deferral and adaptive debounce.
    ///   - trigger: Why this call was made (dual-path inventory + DEBUG dual-fire observation).
    ///     Defaults to ``WidgetRefreshTrigger/test`` for white-box tests; production callers
    ///     must pass the matching case.
    ///
    /// - SeeAlso: ``handlePlayerEvent(_:)``, ``WidgetRefreshTrigger``, `SharedPlayerManager.events`,
    ///   ``SharedPlayerManager/languageForWidgetRefreshDerivation(fallbackLanguage:)``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (dual-path inventory),
    ///   docs/Widget-Functionality-Roadmap.md (refresh inventory).
    func refreshIfNeeded(
        visualState: PlayerVisualState,
        currentLanguage: String,
        hasError: Bool,
        immediate: Bool = false,
        trigger: WidgetRefreshTrigger = .test
    ) {
        #if DEBUG
        // Soft dual-fire observation (not a product failure): event family + imperative
        // family within the dual-trigger window is expected at some edges and is only
        // logged / recorded for inventory. Hard assert is opt-in via test seam.
        Self.recordRefreshTriggerObservation(trigger)
        #else
        // Trigger is retained on the public surface for dual-path inventory honesty;
        // dual-fire observation is DEBUG-only.
        _ = trigger
        #endif

        #if DEBUG
        // White-box gate observation for session-teardown orchestration tests.
        // Bypasses UITestMode and WidgetCenter IPC while preserving the teardown
        // gate decision order used in production.
        if unsafe Self._test_bypassUITestModeForRefreshGateObservation {
            let outcome: RefreshIfNeededGateOutcome
            if Self.isSessionTeardownInProgress {
                outcome = .suppressedBySessionTeardown
            } else if !Self.hasActiveLutheranWidgets {
                outcome = .suppressedByPrivacyGate
            } else {
                outcome = .passedGuards
            }
            if unsafe Self._test_recordRefreshIfNeededGateOutcomes {
                unsafe Self._test_refreshGateOutcomeLog.append(outcome)
            }
            return
        }

        let debounceObservationActive = unsafe Self._test_bypassUITestModeForDebounceObservation
        #else
        let debounceObservationActive = false
        #endif

        // Defense-in-depth UI test isolation (SSOT).
        // Prevents WidgetKit timeline reloads that can wake widget renderers
        // (including Chrono for Live Activities) during -UITestMode launches.
        if SharedPlayerManager.isRunningInUITestMode, !debounceObservationActive {
            return
        }
        if Self.isSessionTeardownInProgress {
            #if DEBUG
            print("[WidgetRefreshManager] Skipped refresh — session teardown in progress")
            #endif
            return
        }

        // AGENT NOTE: Imperative callers (lifecycle, teardown, extension optimistic,
        // media-surface) and the event observer (`handlePlayerEvent` / `.playerEvent`)
        // converge here. All logic below (coalescing, debouncing, regress detection,
        // privacy gate) applies uniformly regardless of trigger source. The observer
        // path is intentionally non-special and never bypasses any check.
        //
        // Language re-resolution: ``loadSharedState()`` / ``preferredWidgetLanguage()``
        // hard-default to `"en"` under no-widgets privacy. Coalesce bookkeeping and DEBUG
        // `lang:` labels must track stream attach / LA content-push SSOT instead.

        let resolvedLanguage = SharedPlayerManager.languageForWidgetRefreshDerivation(
            fallbackLanguage: currentLanguage
        )
        // Soft-resume / recovery settle: event-path ``.playing`` is normally non-immediate so
        // Connecting can coalesce into one playing wake. Sticky pause → audible playing has no
        // Connecting intermediate — force immediate so home does not wait on adaptive debounce
        // after the last ``.userPaused`` wake (device eyes-on lag class).
        let softResumePlayingImmediate: Bool = {
            guard visualState == .playing, !immediate else { return false }
            guard let prior = lastKnownState?.visualState else { return false }
            switch prior {
            case .userPaused, .thermalPaused, .securityLocked:
                return true
            case .prePlay, .cleared, .playing:
                return false
            @unknown default:
                return false
            }
        }()
        let effectiveImmediate = immediate || softResumePlayingImmediate
        let newState = WidgetState(
            from: visualState,
            currentLanguage: resolvedLanguage,
            hasError: hasError,
            isImmediateDelivery: effectiveImmediate
        )
        
        if shouldCancelPendingDebounce(for: newState.visualState) {
            cancelPendingRefresh()
        }
        
        // ALWAYS refresh on language changes, regardless of throttling.
        // Mark language urgency as immediate for regress / memory-authority gates so destination
        // Connecting can advance past a lagging session snapshot still on prior-language playing
        // (stream-switch first paint) without inventing mid-hold playing.
        if let lastState = lastKnownState,
           lastState.currentLanguage != newState.currentLanguage {
            cancelCoalescedPrePlayRefresh()
            let languageUrgentState = WidgetState(
                from: newState.visualState,
                currentLanguage: newState.currentLanguage,
                hasError: newState.hasError,
                isImmediateDelivery: true
            )
            Task { @MainActor in
                await performRefreshIfNotStale(for: languageUrgentState)
            }
            return
        }
        
        // Identical connecting / sticky chrome: skip further reloads (attach storms + dual-path).
        // Connecting `.prePlay` is deferred (not event-path immediate) so soft-resume playing can
        // supersede it; without this gate repeated attach-status prePlay still storms reloads.
        // Language already matched above; first transition into this visual still executes once.
        // Exception: interactive paint epoch advanced since the last successful kind reload
        // (optimistic toggle / identity-skip wake / live-chrome settle) — residual LIVE still
        // needs a timeline re-delivery even when visual + language match lastKnown.
        let paintEpochNow = SharedPlayerManager.loadHomeWidgetInteractivePaintEpoch()
        let paintEpochAdvancedSinceReload = paintEpochNow > lastPaintEpochAtSuccessfulReload
        if let lastState = lastKnownState,
           !paintEpochAdvancedSinceReload,
           Self.shouldCoalesceIdenticalNonPlayingRefresh(
               requestedVisual: newState.visualState,
               lastKnownVisual: lastState.visualState,
               languageUnchanged: lastState.currentLanguage == newState.currentLanguage,
               errorFlagsMatch: lastState.hasError == newState.hasError,
               hasError: hasError
           ) {
            #if DEBUG
            print("[WidgetRefreshManager] Widget refresh coalesced: identical \(newState.debugVisualStateLabel) unchanged — lang: \(newState.currentLanguage)")
            recordDebounceOutcome(.coalescedIdenticalNonPlaying)
            #endif
            return
        }
        #if DEBUG
        if paintEpochAdvancedSinceReload,
           let lastState = lastKnownState,
           Self.shouldCoalesceIdenticalNonPlayingRefresh(
               requestedVisual: newState.visualState,
               lastKnownVisual: lastState.visualState,
               languageUnchanged: lastState.currentLanguage == newState.currentLanguage,
               errorFlagsMatch: lastState.hasError == newState.hasError,
               hasError: hasError
           ) {
            print(
                "[WidgetRefreshManager] Identical \(newState.debugVisualStateLabel) allowed — paint epoch \(paintEpochNow) > lastReload \(lastPaintEpochAtSuccessfulReload)"
            )
        }
        #endif
        
        // Errors and non-playing visual transitions supersede a deferred .prePlay refresh.
        if hasError {
            cancelCoalescedPrePlayRefresh()
        } else if coalescedPrePlayState != nil,
                  newState.visualState != .prePlay,
                  newState.visualState != .cleared,
                  newState.visualState != .playing {
            cancelCoalescedPrePlayRefresh()
        }
        
        // Coalesce back-to-back .prePlay/.cleared → .playing refreshes on the same language.
        if !hasError,
           newState.visualState == .playing,
           let prePlaySource = coalescedPrePlayState ?? lastKnownState,
           prePlaySource.currentLanguage == newState.currentLanguage,
           prePlaySource.visualState == .prePlay || prePlaySource.visualState == .cleared,
           prePlaySource.hasError == newState.hasError {
            let withinCoalesceWindow = coalescedPrePlayState != nil
                || (lastRefreshTime.map { Date().timeIntervalSince($0) < Self.prePlayToPlayingCoalesceWindow } ?? false)
            if withinCoalesceWindow {
                cancelCoalescedPrePlayRefresh()
                #if DEBUG
                print("[WidgetRefreshManager] Widget refresh coalesced: .prePlay → .playing, lang: \(newState.currentLanguage)")
                recordDebounceOutcome(.coalescedPrePlayToPlaying)
                #endif
                Task { @MainActor in
                    await performRefreshIfNotStale(for: newState)
                }
                return
            }
        }
        
        // Defer lone .prePlay / .cleared refreshes briefly so a fast .playing follow-up can supersede them.
        // (.cleared is rare for widgets because clear wipes snapshot + forces hasActive false, but
        // keep symmetric so in-process main-app driven paths behave consistently.)
        // `immediate: true` (or soft-resume playing immediacy above) bypasses deferral for session
        // teardown follow-up, termination hygiene, and sticky→playing settle.
        // Identical non-playing coalesce above already skipped when lastKnown matches.
        // Attach-path storms re-enter here many times — ``scheduleCoalescedPrePlayRefresh`` keeps a
        // single coalesce deadline (does not reset the window on each status callback).
        if !effectiveImmediate, !hasError, newState.visualState == .prePlay || newState.visualState == .cleared {
            #if DEBUG
            let alreadyDeferred = coalescedPrePlayWorkItem != nil
            if alreadyDeferred {
                print("[WidgetRefreshManager] Widget refresh deferred: coalesce window held (attach storm) — lang: \(newState.currentLanguage)")
                recordDebounceOutcome(.heldPrePlayDeferralWindow)
            } else {
                print("[WidgetRefreshManager] Widget refresh deferred: awaiting possible .playing follow-up — lang: \(newState.currentLanguage)")
                recordDebounceOutcome(.scheduledPrePlayDeferral)
            }
            #endif
            scheduleCoalescedPrePlayRefresh(for: newState)
            return
        }
        
        // Adaptive debouncing - increase interval with frequency
        if !effectiveImmediate {
            let now = Date()
            if let lastRefresh = lastRefreshTime {
                let timeSinceLastRefresh = now.timeIntervalSince(lastRefresh)
                
                if timeSinceLastRefresh < adaptiveInterval {
                    refreshCount += 1
                    adaptiveInterval = min(adaptiveInterval * 1.5, 3.0)
                    #if DEBUG
                    recordDebounceOutcome(.scheduledAdaptiveDebounce)
                    #endif
                    scheduleDelayedRefresh(for: newState, delay: adaptiveInterval)
                    return
                } else if timeSinceLastRefresh > 5.0 {
                    refreshCount = 0
                    adaptiveInterval = 0.5
                }
            }
        }
        
        Task { @MainActor in
            await performRefreshIfNotStale(for: newState)
        }
    }
    
    // MARK: - Private helpers
    
    /// True when a new visual SSOT should invalidate an in-flight debounced refresh.
    private func shouldCancelPendingDebounce(for newVisual: PlayerVisualState) -> Bool {
        guard pendingRefresh != nil else { return false }
        if let pendingVisual = pendingRefreshState?.visualState {
            return visualTransitionSupersedesPending(from: pendingVisual, to: newVisual)
        }
        if let lastVisual = lastKnownState?.visualState {
            return visualTransitionSupersedesPending(from: lastVisual, to: newVisual)
        }
        return true
    }
    
    private func visualTransitionSupersedesPending(
        from prior: PlayerVisualState,
        to new: PlayerVisualState
    ) -> Bool {
        if prior == new { return false }
        switch new {
        case .playing:
            return prior == .prePlay || prior == .cleared || prior == .userPaused
        case .userPaused, .thermalPaused, .securityLocked:
            return true
        case .prePlay, .cleared:
            return false
        }
    }
    
    /// Pure policy: whether a second timeline reload for the same non-playing chrome is redundant.
    ///
    /// Event-path ``refreshUsesImmediateDelivery(for:hasError:)`` forces `immediate: true` for
    /// sticky pause/lock and ``.cleared`` (factory-reset / pause urgency). Connecting
    /// ``.prePlay`` is deferred so soft-resume ``.playing`` can coalesce. Without this gate,
    /// attach-path status callbacks and dual-path post-stop hygiene re-issue identical
    /// `reloadTimelines` storms while language and visual are unchanged.
    ///
    /// Language changes must be handled by the caller first — this helper assumes language
    /// equality has already been evaluated (``languageUnchanged``).
    ///
    /// - Parameters:
    ///   - requestedVisual: Candidate visual for the refresh.
    ///   - lastKnownVisual: Visual from the last executed (or bookkept) refresh, if any.
    ///   - languageUnchanged: `true` when caller language matches last-known language.
    ///   - errorFlagsMatch: `true` when permanent-error flags match last-known.
    ///   - hasError: Permanent-error chrome for the candidate (never coalesce error repairs away).
    /// - Returns: `true` when the refresh should no-op.
    /// - SeeAlso: ``refreshIfNeeded(visualState:currentLanguage:hasError:immediate:trigger:)``,
    ///   ``refreshUsesImmediateDelivery(for:hasError:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   docs/Widget-Functionality-Roadmap.md.
    static func shouldCoalesceIdenticalNonPlayingRefresh(
        requestedVisual: PlayerVisualState,
        lastKnownVisual: PlayerVisualState?,
        languageUnchanged: Bool,
        errorFlagsMatch: Bool,
        hasError: Bool
    ) -> Bool {
        guard !hasError, languageUnchanged, errorFlagsMatch else { return false }
        guard let lastKnownVisual, lastKnownVisual == requestedVisual else { return false }
        switch requestedVisual {
        case .prePlay, .cleared, .userPaused, .thermalPaused, .securityLocked:
            return true
        case .playing:
            // Active playing is rate-limited by adaptive debounce, not identity skip —
            // a second playing push may still be required after a long gap.
            return false
        @unknown default:
            return false
        }
    }

    /// Pure policy: session-lag leg of execute-time home **wake** discard.
    ///
    /// Used by ``refreshWouldDiscardHomeWake(executing:memory:session:isImmediate:)`` after the
    /// memory leg. Intentional when a delayed intermediate (connecting chrome) loses a race to a
    /// newer session snapshot, or a delayed sticky pause loses to a soft-resume that already
    /// persisted ``.playing``. `reloadTimelines` is wake-only — discarding avoids a useless wake
    /// and hostile ``lastKnownState`` bookkeeping. Provider paint remains session +
    /// ``homeWidgetLiveChrome``. Dual-path architecture is unchanged.
    ///
    /// **Directionality (sticky pause vs lagging ``.playing``):**
    /// - **Non-immediate** (adaptive debounce / delayed work): ``.userPaused`` / ``.thermalPaused``
    ///   against session ``.playing`` is a discard — late pause lost the soft-resume race.
    /// - **Immediate** (sticky pause / teardown urgency): same pair is **not** a discard —
    ///   forward stop may still see a lagging session snapshot until the early sticky write
    ///   (or authoritative save) lands. Discarding would drop the honest pause wake.
    ///
    /// **Directionality (connecting advance / stream-switch hold):**
    /// - **Non-immediate** ``.prePlay`` / ``.cleared`` against session ``.playing`` is a discard
    ///   (late connecting after soft-resume / audible play already accepted).
    /// - **Immediate** language-change / switch-optimistic Connecting against lagging
    ///   ``.playing`` is **not** a discard — destination first wake must not wait for the
    ///   prior-language playing snapshot to clear.
    /// - Connecting against a lagging sticky ``.userPaused`` session is **not** a discard
    ///   (forward attach after pause). Reverse races (in-flight Connecting after sticky lock)
    ///   are blocked by the memory leg when memory is already sticky. Playing against sticky
    ///   session remains a discard.
    ///
    /// - Parameters:
    ///   - requested: Visual the delayed/debounced work would schedule.
    ///   - persisted: In-process session ``PersistedWidgetState/visualState`` at execute time.
    ///   - isImmediate: `true` when the refresh bypassed adaptive debounce (sticky pause,
    ///     teardown, permanent-error, language-change urgency, or explicit `immediate: true`).
    /// - Returns: `true` when the session leg requires discard.
    /// - SeeAlso: ``refreshWouldDiscardHomeWake(executing:memory:session:isImmediate:)``,
    ///   ``refreshWouldRegressMemoryAuthority(executing:memory:isImmediate:)``,
    ///   ``refreshUsesImmediateDelivery(for:hasError:)``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§8),
    ///   docs/Widget-Presentation-Dataflow.md (home wake discard).
    static func refreshWouldRegressPersistedSnapshot(
        executing requested: PlayerVisualState,
        persisted: PlayerVisualState,
        isImmediate: Bool = false
    ) -> Bool {
        if requested == persisted { return false }
        switch persisted {
        case .playing:
            // Delayed connecting after play accepted is stale (soft-resume residual).
            // Immediate language-change / switch optimistic Connecting is forward hold wake.
            if requested == .prePlay || requested == .cleared {
                return !isImmediate
            }
            // Delayed sticky pause after soft-resume to playing is stale.
            // Immediate sticky-pause / teardown urgency is a forward stop — do not discard
            // solely because the session snapshot still lags on .playing.
            if requested == .userPaused || requested == .thermalPaused {
                return !isImmediate
            }
            return false
        case .userPaused, .thermalPaused:
            // Playing must never reverse sticky via a lagging session path.
            // Connecting may advance sticky session (forward attach after pause / early sticky lag).
            // Reverse connecting-after-pause is blocked by the memory leg when sticky is locked.
            if requested == .playing {
                return true
            }
            return false
        case .securityLocked:
            return requested != .securityLocked
        case .prePlay, .cleared:
            return false
        @unknown default:
            return false
        }
    }

    /// Pure policy: memory-lag leg of execute-time home **wake** discard.
    ///
    /// Used by ``refreshWouldDiscardHomeWake(executing:memory:session:isImmediate:)`` first.
    /// Complements the session leg when the session snapshot lags
    /// ``SharedPlayerManager/currentVisualState`` (apply before save, early sticky, stream-switch
    /// hold). Discarding avoids mid-switch premature ``.playing`` wakes and residual sticky
    /// storms. Provider paint remains session + ``homeWidgetLiveChrome``.
    ///
    /// **Memory lag table:**
    /// 1. Sticky pause / thermal / security lock — never lose to connecting or playing.
    /// 2. Connecting / stream-switch hold (``.prePlay`` / ``.cleared``) — never lose to lagging
    ///    sticky, and never accept premature ``.playing`` until memory advances via ``setPlaying()``.
    /// 3. Authoritative ``.playing`` — discard non-immediate late connecting (post-audible prePlay);
    ///    immediate language-change Connecting may still advance (switch hold first wake);
    ///    discard sticky ``.userPaused`` / thermal after audible memory (soft-resume residual wake).
    ///
    /// - Parameters:
    ///   - requested: Visual the refresh would schedule into WidgetCenter.
    ///   - memory: ``SharedPlayerManager/currentVisualState`` (or extension optimistic force-set).
    ///   - isImmediate: Language-change / sticky / teardown urgency — same meaning as session leg.
    /// - Returns: `true` when the memory leg requires discard.
    /// - SeeAlso: ``refreshWouldDiscardHomeWake(executing:memory:session:isImmediate:)``,
    ///   ``refreshWouldRegressPersistedSnapshot(executing:persisted:isImmediate:)``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§8),
    ///   docs/Widget-Presentation-Dataflow.md (home wake discard).
    static func refreshWouldRegressMemoryAuthority(
        executing requested: PlayerVisualState,
        memory: PlayerVisualState,
        isImmediate: Bool = false
    ) -> Bool {
        if requested == memory { return false }
        switch memory {
        case .userPaused, .thermalPaused:
            // Sticky memory lock: never schedule connecting or playing that reverses it.
            // ``setPlaying()`` / ``applyVisualState(.prePlay)`` advance memory before events.
            return requested == .prePlay || requested == .cleared || requested == .playing
        case .securityLocked:
            return requested != .securityLocked
        case .prePlay, .cleared:
            // Connecting / switch hold: do not re-schedule lagging sticky, and do not invent
            // mid-hold playing until memory advances to authoritative playing.
            return requested == .userPaused
                || requested == .thermalPaused
                || requested == .playing
        case .playing:
            // Audible memory: non-immediate late connecting is post-audible prePlay residual.
            // Immediate language-change Connecting is forward switch hold (destination first wake).
            if requested == .prePlay || requested == .cleared {
                return !isImmediate
            }
            // Soft-resume residual: sticky ``.userPaused`` wake after memory already advanced to
            // ``.playing`` must not re-issue a timeline reload (otherwise residual pause chrome
            // over audible playing after soft-resume settle).
            // Forward home pause advances memory to ``.userPaused`` *before* the pause wake runs
            // (stop path), so real pauses are not discarded here.
            if requested == .userPaused || requested == .thermalPaused {
                return true
            }
            return false
        @unknown default:
            return false
        }
    }

    /// Pure policy: whether a scheduled home WidgetKit wake should be discarded.
    ///
    /// Compose **memory lag first**, then optional **session lag** — identical to the historical
    /// sequential checks in ``performRefreshIfNotStale(for:)``. `WidgetCenter.reloadTimelines` is
    /// wake-only; Providers re-read session + privacy-gated ``homeWidgetLiveChrome``. This gate
    /// only discards useless or bookkeeping-hostile wake candidates (residual sticky, premature
    /// mid-hold ``.playing``, soft-resume reverse-race pause, post-audible Connecting).
    ///
    /// **Soft-resume settle exception:** When memory already holds authoritative ``.playing`` and
    /// the candidate is also ``.playing``, session may still lag on sticky ``.userPaused`` until
    /// ``saveCurrentState()`` finishes after ``applyVisualState(.playing)``. The pure session
    /// helper still treats ``playing`` vs ``userPaused`` as a reverse-race discard (delayed
    /// playing must not clear sticky disk alone), but with matching memory the wake is honest
    /// home control paint (pause glyph after audible start) and must not be dropped — otherwise
    /// interactive LIVE can keep residual Tauko/play after soft-resume while App Group chrome
    /// already advanced on the live-chrome write that races the same settle.
    ///
    /// - Parameters:
    ///   - requested: Visual the refresh candidate would schedule.
    ///   - memory: ``SharedPlayerManager/currentVisualState`` (or extension optimistic force-set).
    ///   - session: In-process session snapshot visual when present; `nil` skips the session leg.
    ///   - isImmediate: Sticky / teardown / language-change / explicit urgency (same as helper legs).
    /// - Returns: `true` when the wake must be discarded.
    /// - Important: Soft-resume non-immediate Connecting deferral and
    ///   ``shouldCoalesceIdenticalNonPlayingRefresh`` are separate schedule-time policies; this
    ///   function is execute-time only.
    /// - SeeAlso: ``refreshWouldRegressMemoryAuthority(executing:memory:isImmediate:)``,
    ///   ``refreshWouldRegressPersistedSnapshot(executing:persisted:isImmediate:)``,
    ///   ``performRefreshIfNotStale(for:)``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§8 PR5),
    ///   docs/Widget-Presentation-Dataflow.md (home wake discard).
    static func refreshWouldDiscardHomeWake(
        executing requested: PlayerVisualState,
        memory: PlayerVisualState,
        session: PlayerVisualState?,
        isImmediate: Bool = false
    ) -> Bool {
        // Soft-resume / audible settle: actor already advanced to playing matching the candidate.
        // Session snapshot may lag sticky pause until the in-flight save lands — do not drop the
        // home playing wake that flips residual play glyph → pause glyph after soft-resume.
        if requested == .playing, memory == .playing {
            return false
        }
        if refreshWouldRegressMemoryAuthority(
            executing: requested,
            memory: memory,
            isImmediate: isImmediate
        ) {
            return true
        }
        if let session,
           refreshWouldRegressPersistedSnapshot(
               executing: requested,
               persisted: session,
               isImmediate: isImmediate
           ) {
            return true
        }
        return false
    }

    private func cancelCoalescedPrePlayRefresh() {
        coalescedPrePlayWorkItem?.cancel()
        coalescedPrePlayWorkItem = nil
        coalescedPrePlayState = nil
    }
    
    /// Schedules a single coalesce-window timer for Connecting chrome.
    ///
    /// Attach-path status storms call ``refreshIfNeeded`` with ``.prePlay`` repeatedly. Resetting
    /// the deadline on every callback starves the first honest Connecting paint for multi-second
    /// "awaiting possible .playing follow-up" storms. Keep the **first** deadline; only refresh
    /// the pending state payload so the latest language/error flags still execute.
    ///
    /// - Parameter state: Latest non-playing Connecting candidate for the deferred reload.
    /// - SeeAlso: ``refreshIfNeeded(visualState:currentLanguage:hasError:immediate:trigger:)``,
    ///   docs/Widget-Presentation-Dataflow.md (home refresh authority).
    private func scheduleCoalescedPrePlayRefresh(for state: WidgetState) {
        coalescedPrePlayState = state
        // Bound attach storms: do not reset the coalesce deadline while one is already pending.
        if coalescedPrePlayWorkItem != nil {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, let pendingState = self.coalescedPrePlayState else { return }
                self.coalescedPrePlayWorkItem = nil
                self.coalescedPrePlayState = nil
                await self.performRefreshIfNotStale(for: pendingState)
            }
        }

        coalescedPrePlayWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.prePlayToPlayingCoalesceWindow,
            execute: workItem
        )
    }
    
    private func scheduleDelayedRefresh(for state: WidgetState, delay: TimeInterval) {
        pendingRefresh?.cancel()
        pendingRefreshState = state
        
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, let pendingState = self.pendingRefreshState else { return }
                self.pendingRefresh = nil
                self.pendingRefreshState = nil
                await self.performRefreshIfNotStale(for: pendingState)
                self.adaptiveInterval = max(self.adaptiveInterval * 0.8, 0.5)
            }
        }
        
        pendingRefresh = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
    
    private func performRefreshIfNotStale(for state: WidgetState) async {
        // Execute-time home wake discard (main app + extension optimistic force-set): memory lag
        // then session lag. Blocks residual sticky after intentional Connecting and mid-switch
        // premature ``.playing`` while hold keeps memory at ``.prePlay``. Reload is wake-only;
        // Providers paint session + ``homeWidgetLiveChrome``.
        let memoryVisual = await SharedPlayerManager.shared.currentVisualState
        let sessionVisual = SharedPlayerManager.loadPersistedWidgetState()?.visualState
        let isImmediate = state.isImmediateDelivery
        if Self.refreshWouldDiscardHomeWake(
            executing: state.visualState,
            memory: memoryVisual,
            session: sessionVisual,
            isImmediate: isImmediate
        ) {
            #if DEBUG
            // Preserve leg-specific outcomes for triage / existing white-box tests (composition
            // is memory-first, same as the pure unified policy).
            if Self.refreshWouldRegressMemoryAuthority(
                executing: state.visualState,
                memory: memoryVisual,
                isImmediate: isImmediate
            ) {
                print("[WidgetRefreshManager] Widget refresh discarded: memory lag \(state.debugVisualStateLabel) vs memory \(debugLabel(for: memoryVisual))")
                recordDebounceOutcome(.discardedMemoryAuthorityRegress)
            } else if let sessionVisual {
                print("[WidgetRefreshManager] Widget refresh discarded: session lag \(state.debugVisualStateLabel) vs session \(debugLabel(for: sessionVisual))")
                recordDebounceOutcome(.discardedStaleDebouncedRegress)
            }
            #endif
            return
        }
        await performRefresh(for: state)
    }
    
    #if DEBUG
    private func debugLabel(for visualState: PlayerVisualState) -> String {
        WidgetState(
            from: visualState,
            currentLanguage: "",
            hasError: false
        ).debugVisualStateLabel
    }

    /// Appends a debounce/coalesce observation outcome when recording is enabled.
    private func recordDebounceOutcome(_ outcome: DebounceObservationOutcome) {
        guard unsafe Self._test_recordDebounceOutcomes else { return }
        unsafe Self._test_recordedDebounceOutcomes.append(outcome)
    }
    #endif
    
    private func performRefresh(for state: WidgetState) async {
        #if DEBUG
        recordDebounceOutcome(.refreshExecuted)
        if unsafe Self._test_bypassUITestModeForDebounceObservation {
            cancelPendingRefresh()
            lastRefreshTime = Date()
            lastKnownState = state
            // Mirror production kind-reload bookkeeping so paint-epoch advance is the only
            // reason identical non-playing coalesce is skipped under observation.
            lastPaintEpochAtSuccessfulReload =
                SharedPlayerManager.loadHomeWidgetInteractivePaintEpoch()
            return
        }
        #endif

        // Belt-and-suspenders: even if a caller reached here, never do WidgetCenter work under test.
        if SharedPlayerManager.isRunningInUITestMode {
            return
        }
        if Self.isSessionTeardownInProgress {
            return
        }

        cancelPendingRefresh()
        // Bookkeeping (`lastKnownState` / `lastRefreshTime`) only after a real WidgetCenter wake is
        // scheduled. Setting them before `await currentConfigurations()` made concurrent dual-path
        // `refreshIfNeeded` calls coalesce as "identical" while the first wake was still in flight —
        // harmless when the first completes, hostile if the first path is discarded mid-await.
        
        do {
            let configs = try await WidgetCenter.shared.currentConfigurations()

            let hasActive = configs.contains { Self.ourWidgetKinds.contains($0.kind) }
            Self.setHasActiveLutheranWidgets(hasActive)

            if hasActive {
                WidgetCenter.shared.reloadTimelines(ofKind: "LutheranRadioWidget")
                WidgetCenter.shared.reloadTimelines(ofKind: "radio.lutheran.LutheranRadio.LutheranRadioWidget")
                lastRefreshTime = Date()
                lastKnownState = state
                lastPaintEpochAtSuccessfulReload =
                    SharedPlayerManager.loadHomeWidgetInteractivePaintEpoch()
                
                #if DEBUG
                print("[WidgetRefreshManager] Widget refresh executed (our widgets active) — visualState: \(state.debugVisualStateLabel), lang: \(state.currentLanguage)")
                #endif
            } else {
                #if DEBUG
                print("[WidgetRefreshManager] Skipped widget refresh: No active Lutheran widgets configured (write suppression active)")
                #endif
            }
        } catch {
            #if DEBUG
            print("[WidgetRefreshManager] Widget refresh failed: \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - Event-driven consumer (Tier 2, strictly additive / non-forcing)

    /// Starts the internal `AsyncStream` observer over `SharedPlayerManager.events`.
    ///
    /// The observer is started from `init` and runs for the lifetime of the
    /// singleton in the main app process. On each yielded `PlayerEvent` it calls
    /// `handlePlayerEvent(_:)` which in turn invokes the public `refreshIfNeeded`
    /// surface using data derived from the same SSOT facades used by imperative callers.
    ///
    /// - Important: Sole driver of main-app **mutation-path** timeline reloads.
    ///   Imperative lifecycle, teardown, extension optimistic, and optional
    ///   media-surface callers remain; they do not replace this observer.
    /// - Precondition: Must be called on the main actor. Called exactly once.
    /// - Note: The `isWidgetProcess()` guard ensures the task is not created in
    ///   the widget extension (where `emit` is a no-op).
    /// - SeeAlso: ``handlePlayerEvent(_:)``, `SharedPlayerManager.events`,
    ///   ``emit(_:)`` (in SharedPlayerManager), `PlayerEvent`,
    ///   `refreshIfNeeded(visualState:currentLanguage:hasError:immediate:trigger:)`,
    ///   ``WidgetRefreshTrigger``,
    ///   CODING_AGENT.md (event-driven direction, "additive only", Documentation
    ///   & Comment Standards), docs/Event-Driven-Refactor-Roadmap.md,
    ///   <doc:Architecture>.
    @MainActor
    func beginObservingPlayerEvents() {
        guard !SharedPlayerManager.isWidgetProcess(),
              eventObservationTask == nil else { return }

        #if DEBUG
        // Unit tests that exercise exclusive live ``events`` iteration or multi-cast
        // replay isolation require the Tier 2 observer idle. AsyncStream's primary
        // iterator admits one consumer at a time; suppress observation for those
        // tests only (shared DEBUG seam — not product-path gating).
        guard unsafe !Self._test_suppressPlayerEventObservation else { return }
        #endif

        // Materialize the (lazily created) events stream, then delegate to the
        // consolidated `WidgetEventObserver`. The resulting task is assigned to
        // the stored property to preserve the exact test seam contract and
        // documentation.
        Task { @MainActor [weak self] in
            guard let self else { return }
            #if DEBUG
            guard unsafe !Self._test_suppressPlayerEventObservation else { return }
            #endif
            let stream = await SharedPlayerManager.shared.events
            self.playerEventObserver.beginObserving(stream) { [weak self] event in
                await self?.handlePlayerEvent(event)
            }
            self.eventObservationTask = self.playerEventObserver.task
        }
    }

    /// Reacts to a `PlayerEvent` by deriving current state via SSOT readers and
    /// calling ``refreshIfNeeded`` with ``WidgetRefreshTrigger/playerEvent``.
    ///
    /// Derivation prefers `loadPersistedWidgetState()` (for visual + language)
    /// and `loadSharedState()` (for `hasError`) — exactly the surfaces used by
    /// imperative callers. For events that carry a `PlayerVisualState` the carried
    /// value is preferred when fresher.
    ///
    /// The call always goes through the full implementation of `refreshIfNeeded`
    /// (language-change urgency, prePlay coalescing, adaptive debounce, regress
    /// checks, UITestMode short, privacy gate, etc.). Derived `.prePlay` and
    /// `.cleared` visuals request `immediate: true` so factory-reset and privacy-clear
    /// presentations are not deferred behind the coalesce window (parity with
    /// imperative teardown callers).
    ///
    /// - Parameter event: The domain event emitted by `SharedPlayerManager`
    ///   after a corresponding state mutation.
    /// - Postcondition: If the derived state warrants a timeline reload,
    ///   `WidgetCenter.reloadTimelines` may be scheduled (subject to all
    ///   existing guards and coalescing). No other side effects.
    /// - Important: Sole main-app **mutation-path** refresh driver. Imperative
    ///   lifecycle/teardown/extension callers may dual-fire near the same edge;
    ///   debounce/coalesce inside ``refreshIfNeeded`` absorbs duplicates. DEBUG
    ///   dual-fire observation records event+imperative pairs within the dual-trigger
    ///   window (soft log; not a product failure).
    /// - SeeAlso: ``beginObservingPlayerEvents()``,
    ///   ``refreshIfNeeded(visualState:currentLanguage:hasError:immediate:trigger:)``,
    ///   ``WidgetRefreshTrigger``,
    ///   `SharedPlayerManager.loadPersistedWidgetState`,
    ///   `SharedPlayerManager.loadSharedState`, `PlayerEvent`,
    ///   `WidgetEventObserver`,
    ///   docs/Event-Driven-Refactor-Roadmap.md,
    ///   CODING_AGENT.md (non-forcing architecture, SSOT principles).
    /// Parameters derived from a ``PlayerEvent`` and SSOT readers for ``refreshIfNeeded``.
    ///
    /// Extraction keeps the derivation contract testable without exercising WidgetCenter
    /// or debounce timers. Both ``handlePlayerEvent(_:)`` and the DEBUG white-box seams
    /// route through this helper so production and test observation share one code path.
    struct RefreshDerivation: Equatable, Sendable {
        let visualState: PlayerVisualState
        let currentLanguage: String
        let hasError: Bool
    }

    /// Derives ``refreshIfNeeded`` inputs from a ``PlayerEvent`` using the same SSOT
    /// facades as every imperative caller.
    ///
    /// - Parameter event: The domain event emitted after a state mutation.
    /// - Returns: Visual, language, and error flag for the canonical refresh surface.
    /// - Important: For ``PlayerEvent/visualStateDidChange(_:)`` the carried visual is
    ///   preferred even when the persisted snapshot is stale. All other cases — including
    ///   stream verbs, intent changes, metadata updates, and persist signals — fall back
    ///   to ``SharedPlayerManager/loadPersistedWidgetState()`` (or `.prePlay` when absent).
    /// - Important: Language uses ``SharedPlayerManager/languageForWidgetRefreshDerivation(fallbackLanguage:)``
    ///   so privacy hard-default `"en"` from ``loadSharedState()`` does not label non-English
    ///   streams in coalesce diagnostics when the session snapshot is write-suppressed.
    /// - SeeAlso: ``handlePlayerEvent(_:)``,
    ///   ``refreshIfNeeded(visualState:currentLanguage:hasError:immediate:trigger:)``,
    ///   ``SharedPlayerManager/languageForWidgetRefreshDerivation(fallbackLanguage:)``,
    ///   `SharedPlayerManager.loadSharedState`, docs/Event-Driven-Refactor-Roadmap.md.
    func deriveRefreshParameters(for event: PlayerEvent) -> RefreshDerivation {
        let persisted = SharedPlayerManager.loadPersistedWidgetState()
        let sharedState = SharedPlayerManager.shared.loadSharedState()

        let language = SharedPlayerManager.languageForWidgetRefreshDerivation(
            fallbackLanguage: sharedState.currentLanguage
        )
        let hasError = sharedState.hasError

        let visualState: PlayerVisualState
        switch event {
        case .visualStateDidChange(let carriedVisual):
            visualState = carriedVisual
        case .playbackIntentChanged, .streamDidStart, .streamDidPause, .streamDidStop,
             .streamDidFail, .metadataDidUpdate, .persistedWidgetStateDidUpdate:
            visualState = persisted?.visualState ?? .prePlay
        @unknown default:
            // `PlayerEvent` is `@frozen public` in `WidgetSurface`; future additive cases
            // fall back to the persisted snapshot like other non-visual events.
            visualState = persisted?.visualState ?? .prePlay
        }

        return RefreshDerivation(
            visualState: visualState,
            currentLanguage: language,
            hasError: hasError
        )
    }

    /// Returns whether the event path must bypass coalesce deferral and adaptive debouncing.
    ///
    /// Factory-reset / privacy-clear (``.cleared``), sticky pause/lock, and permanent-error
    /// chrome must not wait behind the adaptive debounce window. Connecting ``.prePlay`` is
    /// intentionally **not** immediate: it participates in the ``.prePlay`` → ``.playing``
    /// coalesce so same-stream soft-resume (audible within the window) schedules a single
    /// authoritative ``.playing`` home reload instead of painting Connecting after audio is live.
    /// True attach paths still show Connecting when the window elapses without a playing follow-up.
    /// Active ``PlayerVisualState/playing`` remains eligible for adaptive coalesce/debounce.
    ///
    /// - Parameters:
    ///   - visualState: The visual derived from the ``PlayerEvent`` payload or SSOT readers.
    ///   - hasError: Permanent-error flag from ``SharedPlayerManager/loadSharedState()``.
    /// - Returns: `true` when the derived refresh must execute immediately.
    /// - SeeAlso: ``refreshIfNeeded(visualState:currentLanguage:hasError:immediate:trigger:)``,
    ///   ``handlePlayerEvent(_:)``, ``SharedPlayerManager/performActualSave(_:)``,
    ///   docs/Widget-Functionality-Roadmap.md (Tier 3), docs/Event-Driven-Refactor-Roadmap.md,
    ///   docs/Widget-Presentation-Dataflow.md (home soft-resume refresh authority).
    func refreshUsesImmediateDelivery(
        for visualState: PlayerVisualState,
        hasError: Bool
    ) -> Bool {
        if hasError { return true }
        switch visualState {
        case .cleared, .userPaused, .thermalPaused, .securityLocked:
            return true
        case .prePlay, .playing:
            // Connecting participates in prePlay→playing coalesce; playing uses adaptive debounce.
            return false
        @unknown default:
            return true
        }
    }

    func handlePlayerEvent(_ event: PlayerEvent) async {
        // UITestMode defense (mirrors the guard at the top of refreshIfNeeded).
        #if DEBUG
        if SharedPlayerManager.isRunningInUITestMode,
           !(unsafe Self._test_bypassUITestModeForRefreshGateObservation) {
            return
        }
        #else
        if SharedPlayerManager.isRunningInUITestMode {
            return
        }
        #endif
        if Self.isSessionTeardownInProgress {
            return
        }

        let derived = deriveRefreshParameters(for: event)
        let immediate = refreshUsesImmediateDelivery(
            for: derived.visualState,
            hasError: derived.hasError
        )

        #if DEBUG
        if unsafe Self._test_recordHandlePlayerEventImmediate {
            unsafe Self._test_cachedHandlePlayerEventImmediate = immediate
        }
        #endif

        // Mutation-path sole driver: route through the public surface with
        // ``WidgetRefreshTrigger/playerEvent``. Debounce/coalesce/privacy apply identically
        // to imperative callers; dual-fire with lifecycle/teardown is expected and soft-logged.
        refreshIfNeeded(
            visualState: derived.visualState,
            currentLanguage: derived.currentLanguage,
            hasError: derived.hasError,
            immediate: immediate,
            trigger: .playerEvent
        )
    }

    #if DEBUG
    /// Soft dual-fire inventory hook (DEBUG only). Implementation lives in
    /// ``WidgetRefreshManager+TestSupport`` as ``DualRefreshTriggerInventory`` so this
    /// production file stays free of DEBUG mutable storage and strict-memory-safety noise.
    ///
    /// - SeeAlso: ``DualRefreshTriggerInventory/record(_:)``, ``WidgetRefreshTrigger``.
    private static func recordRefreshTriggerObservation(_ trigger: WidgetRefreshTrigger) {
        DualRefreshTriggerInventory.record(trigger)
    }
    #endif
}


// MARK: - WidgetState (in-memory WRM refresh projection)

/// Lightweight in-memory candidate for ``WidgetRefreshManager`` coalesce / debounce / wake policy.
///
/// Not an App Group snapshot and not a persist input. ``SharedPlayerManager/saveCurrentState()``
/// writes via ``performActualSave(_:)`` using actor visual + a play/language/error tuple only.
/// Playing vs paused and thermal-pause identity are derived from ``visualState`` at decision sites
/// (`isActivelyPlaying`, case matches) rather than stored as parallel booleans.
///
/// - Important: Keep only fields that WRM control flow actually reads. Do not reintroduce
///   write-only derived fields (`isPlaying`, `isThermalPaused`, wall-clock `timestamp`) or
///   unused transition flags without a live branch that consumes them.
/// - SeeAlso: ``WidgetRefreshManager/refreshIfNeeded(visualState:currentLanguage:hasError:immediate:trigger:)``,
///   ``WidgetRefreshManager/performRefreshIfNotStale(for:)``,
///   ``SharedPlayerManager/performActualSave(_:)``,
///   ``PlayerVisualState``, docs/Widget-Functionality-Roadmap.md
struct WidgetState {
    /// Authoritative visual chrome for this refresh candidate.
    let visualState: PlayerVisualState
    /// Language code used for coalesce identity and DEBUG labels.
    let currentLanguage: String
    /// Permanent-error flag for urgency and coalesce identity.
    let hasError: Bool
    /// Whether this candidate bypassed adaptive debounce (sticky pause, teardown, error, language urgency).
    /// Carried into ``WidgetRefreshManager/performRefreshIfNotStale(for:)`` so regress policy can
    /// distinguish forward sticky pause from a late debounced pause that lost the soft-resume race.
    let isImmediateDelivery: Bool

    /// Builds a WRM-only projection from refresh derivation inputs.
    ///
    /// - Parameters:
    ///   - visualState: Candidate ``PlayerVisualState``.
    ///   - currentLanguage: Resolved language for identity / labels.
    ///   - hasError: Permanent-error flag.
    ///   - isImmediateDelivery: When `true`, sticky/error/language-urgent delivery (default `false`).
    init(from visualState: PlayerVisualState,
         currentLanguage: String,
         hasError: Bool,
         isImmediateDelivery: Bool = false) {
        self.visualState = visualState
        self.currentLanguage = currentLanguage
        self.hasError = hasError
        self.isImmediateDelivery = isImmediateDelivery
    }

    #if DEBUG
    var debugVisualStateLabel: String {
        switch visualState {
        case .prePlay: return ".prePlay"
        case .cleared: return ".cleared"
        case .playing: return ".playing"
        case .userPaused: return ".userPaused"
        case .thermalPaused: return ".thermalPaused"
        case .securityLocked: return ".securityLocked"
        @unknown default: return ".unknown"
        }
    }
    #endif
}
