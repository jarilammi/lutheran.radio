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
// - Coalesces `.prePlay` → `.playing` and dedupes sticky states.
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
    /// When the gate **closes** (`value == false`), also removes residual App Group liveness
    /// (`lastUpdateTime`) and short-lived instant-feedback keys so operational signals do not
    /// linger after privacy clear or when the user has no Lutheran widgets. Does not clear
    /// pending-action mailbox keys, Live Activity durable mirrors, or security caches.
    ///
    /// - Parameter value: `true` when at least one of our home/Control widget kinds is configured
    ///   (or a test/provider seam opens the gate); `false` forces write suppression.
    /// - SeeAlso: ``hasActiveLutheranWidgets``,
    ///   ``SharedPlayerManager/clearHomeWidgetLivenessAndInstantFeedbackResiduals()``,
    ///   ``SharedPlayerManager/bumpWidgetLivenessTimestamp(policy:minInterval:)``,
    ///   ``SharedPlayerManager/clearAllLocalState()``.
    @MainActor
    static func setHasActiveLutheranWidgets(_ value: Bool) {
        unsafe _hasActiveLutheranWidgets = value
        if !value {
            // Privacy residual: suppress future bumps via the flag, and drop any leftover
            // heartbeat / optimistic language keys that pre-dated the closed gate.
            SharedPlayerManager.clearHomeWidgetLivenessAndInstantFeedbackResiduals()
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
    ///   - currentLanguage: Stream language code for the entry.
    ///   - hasError: Permanent-error chrome flag from shared state.
    ///   - immediate: When `true`, bypasses prePlay coalesce deferral and adaptive debounce.
    ///   - trigger: Why this call was made (dual-path inventory + DEBUG dual-fire observation).
    ///     Defaults to ``WidgetRefreshTrigger/test`` for white-box tests; production callers
    ///     must pass the matching case.
    ///
    /// - SeeAlso: ``handlePlayerEvent(_:)``, ``WidgetRefreshTrigger``, `SharedPlayerManager.events`,
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

        let newState = WidgetState(
            from: visualState,
            currentLanguage: currentLanguage,
            hasError: hasError,
            isTransitioning: false
        )
        
        if shouldCancelPendingDebounce(for: newState.visualState) {
            cancelPendingRefresh()
        }
        
        // ALWAYS refresh on language changes, regardless of throttling
        if let lastState = lastKnownState,
           lastState.currentLanguage != newState.currentLanguage {
            cancelCoalescedPrePlayRefresh()
            Task { @MainActor in
                await performRefreshIfNotStale(for: newState)
            }
            return
        }
        
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
        // `immediate: true` bypasses deferral for session teardown follow-up and termination hygiene.
        if !immediate, !hasError, newState.visualState == .prePlay || newState.visualState == .cleared {
            #if DEBUG
            print("[WidgetRefreshManager] Widget refresh deferred: awaiting possible .playing follow-up — lang: \(newState.currentLanguage)")
            recordDebounceOutcome(.scheduledPrePlayDeferral)
            #endif
            scheduleCoalescedPrePlayRefresh(for: newState)
            return
        }
        
        // Coalesce duplicate immediate sticky-pause refreshes (KVO bursts, widget + app paths).
        if immediate,
           !hasError,
           newState.visualState.mustSuppressResurrection,
           let lastState = lastKnownState,
           lastState.visualState == newState.visualState,
           lastState.currentLanguage == newState.currentLanguage,
           lastState.hasError == newState.hasError {
            #if DEBUG
            print("[WidgetRefreshManager] Widget refresh coalesced: sticky \(newState.debugVisualStateLabel) unchanged")
            recordDebounceOutcome(.coalescedStickyImmediateDuplicate)
            #endif
            return
        }
        
        // Adaptive debouncing - increase interval with frequency
        if !immediate {
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
    
    /// Returns true if executing `requested` would regress the persisted widget snapshot.
    private func refreshWouldRegress(
        executing requested: PlayerVisualState,
        persisted: PlayerVisualState
    ) -> Bool {
        if requested == persisted { return false }
        switch persisted {
        case .playing:
            return requested == .prePlay || requested == .cleared || requested == .userPaused
        case .userPaused, .thermalPaused:
            return requested == .prePlay || requested == .cleared || requested == .playing
        case .securityLocked:
            return requested != .securityLocked
        case .prePlay, .cleared:
            return false
        }
    }
    
    private func cancelCoalescedPrePlayRefresh() {
        coalescedPrePlayWorkItem?.cancel()
        coalescedPrePlayWorkItem = nil
        coalescedPrePlayState = nil
    }
    
    private func scheduleCoalescedPrePlayRefresh(for state: WidgetState) {
        coalescedPrePlayState = state
        coalescedPrePlayWorkItem?.cancel()
        
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
        if let combined = SharedPlayerManager.loadPersistedWidgetState(),
           refreshWouldRegress(executing: state.visualState, persisted: combined.visualState) {
            #if DEBUG
            print("[WidgetRefreshManager] Widget refresh discarded: stale debounced \(state.debugVisualStateLabel) vs persisted \(debugLabel(for: combined.visualState))")
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
        lastRefreshTime = Date()
        lastKnownState = state
        
        do {
            let configs = try await WidgetCenter.shared.currentConfigurations()

            let hasActive = configs.contains { Self.ourWidgetKinds.contains($0.kind) }
            Self.setHasActiveLutheranWidgets(hasActive)

            if hasActive {
                WidgetCenter.shared.reloadTimelines(ofKind: "LutheranRadioWidget")
                WidgetCenter.shared.reloadTimelines(ofKind: "radio.lutheran.LutheranRadio.LutheranRadioWidget")
                
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
        // Unit tests that exercise replay live-forwarding (for example
        // ``PlayerEventSubscriber``) require an exclusive iterator on the shared
        // ``SharedPlayerManager/events`` stream. AsyncStream supports one consumer
        // at a time; suppress observation for those tests only.
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
    /// - SeeAlso: ``handlePlayerEvent(_:)``,
    ///   ``refreshIfNeeded(visualState:currentLanguage:hasError:immediate:trigger:)``,
    ///   `SharedPlayerManager.loadSharedState`, docs/Event-Driven-Refactor-Roadmap.md.
    func deriveRefreshParameters(for event: PlayerEvent) -> RefreshDerivation {
        let persisted = SharedPlayerManager.loadPersistedWidgetState()
        let sharedState = SharedPlayerManager.shared.loadSharedState()

        let language = persisted?.currentLanguage ?? sharedState.currentLanguage
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
    /// Parity with the urgency rules formerly carried only by imperative ``performActualSave``
    /// callers: factory-reset and privacy-clear visuals, sticky pause/lock states, and permanent
    /// error chrome must not wait behind the `.prePlay` → `.playing` coalesce window or adaptive
    /// debounce. Active ``PlayerVisualState/playing`` alone remains eligible for coalescing.
    ///
    /// - Parameters:
    ///   - visualState: The visual derived from the ``PlayerEvent`` payload or SSOT readers.
    ///   - hasError: Permanent-error flag from ``SharedPlayerManager/loadSharedState()``.
    /// - Returns: `true` when the derived refresh must execute immediately.
    /// - SeeAlso: ``refreshIfNeeded(visualState:currentLanguage:hasError:immediate:trigger:)``,
    ///   ``handlePlayerEvent(_:)``, ``SharedPlayerManager/performActualSave(_:widgetState:at:)``,
    ///   docs/Widget-Functionality-Roadmap.md (Tier 3), docs/Event-Driven-Refactor-Roadmap.md.
    func refreshUsesImmediateDelivery(
        for visualState: PlayerVisualState,
        hasError: Bool
    ) -> Bool {
        if hasError { return true }
        switch visualState {
        case .prePlay, .cleared, .userPaused, .thermalPaused, .securityLocked:
            return true
        case .playing:
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


// MARK: - WidgetState (lightweight projection of PlayerVisualState)

struct WidgetState {
    let visualState: PlayerVisualState
    let isPlaying: Bool
    let currentLanguage: String
    let hasError: Bool
    let isTransitioning: Bool
    let isThermalPaused: Bool
    let timestamp: Date
    
    /// Modern initializer — this is the only path now
    init(from visualState: PlayerVisualState,
         currentLanguage: String,
         hasError: Bool,
         isTransitioning: Bool = false) {
        self.visualState     = visualState
        self.isPlaying       = visualState.isActivelyPlaying
        self.currentLanguage = currentLanguage
        self.hasError        = hasError
        self.isTransitioning = isTransitioning
        self.isThermalPaused = (visualState == .thermalPaused)
        self.timestamp       = Date()
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
