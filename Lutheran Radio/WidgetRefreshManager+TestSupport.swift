//
//  WidgetRefreshManager+TestSupport.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 23.7.2026.
//
//  SHARED: Cross-target membership-exception source. DEBUG-only white-box harness for
//  WidgetRefreshManager (compiled out of Release). Mechanical split — no production
//  behavior change.
//
//  Production refresh paths in WidgetRefreshManager.swift reference these seams under
//  `#if DEBUG` only; members are internal so both files share the same type surface.
//
//  - SeeAlso: WidgetRefreshManager.swift, WidgetRefreshManagerEventTests,
//    docs/Event-Driven-Refactor-Roadmap.md, CODING_AGENT.md (fast test patterns).
//

import Foundation
import WidgetSurface

#if DEBUG
extension WidgetRefreshManager {

    /// Outcome of the early guards in ``refreshIfNeeded(visualState:currentLanguage:hasError:immediate:)``.
    ///
    /// Recorded only when ``_test_setRecordRefreshIfNeededGateOutcomes(true)`` and
    /// ``_test_setBypassUITestModeForRefreshGateObservation(true)`` are active. Compiled out of Release.
    enum RefreshIfNeededGateOutcome: Equatable, Sendable {
        /// The call passed UITestMode, session-teardown, and privacy guards (WidgetCenter IPC skipped in test mode).
        case passedGuards
        /// The call returned early because ``isSessionTeardownInProgress`` was true.
        case suppressedBySessionTeardown
        /// The call returned early because ``hasActiveLutheranWidgets`` is false (write/read privacy gate).
        case suppressedByPrivacyGate
    }

    /// Outcome of debouncing and coalescing branches inside
    /// ``refreshIfNeeded(visualState:currentLanguage:hasError:immediate:)``.
    ///
    /// Recorded when ``_test_setBypassUITestModeForDebounceObservation(true)`` exercises the
    /// full timing heuristics while ``performRefresh`` skips WidgetCenter IPC. Compiled out of Release.
    enum DebounceObservationOutcome: Equatable, Sendable {
        /// A lone ``PlayerVisualState/prePlay`` or ``PlayerVisualState/cleared`` refresh was deferred.
        case scheduledPrePlayDeferral
        /// A fast ``PlayerVisualState/playing`` follow-up superseded a deferred prePlay refresh.
        case coalescedPrePlayToPlaying
        /// A rapid repeat refresh was scheduled behind the adaptive debounce interval.
        case scheduledAdaptiveDebounce
        /// An immediate sticky-pause refresh was dropped as a duplicate of ``lastKnownState``.
        case coalescedStickyImmediateDuplicate
        /// ``performRefresh`` reached the execution point (timeline reload skipped under observation).
        case refreshExecuted
    }

    // SAFETY: DEBUG-only gate-observation flags written from @MainActor test entry points;
    // reads occur on the same actor during XCTest. Matches the established nonisolated(unsafe)
    // pattern for privacy-gate and event-observation test seams in this file.
    nonisolated(unsafe) internal static var _test_bypassUITestModeForRefreshGateObservation = false
    nonisolated(unsafe) internal static var _test_recordRefreshIfNeededGateOutcomes = false
    nonisolated(unsafe) internal static var _test_refreshGateOutcomeLog: [RefreshIfNeededGateOutcome] = []
    nonisolated(unsafe) internal static var _test_bypassUITestModeForDebounceObservation = false
    nonisolated(unsafe) internal static var _test_recordDebounceOutcomes = false
    nonisolated(unsafe) internal static var _test_recordedDebounceOutcomes: [DebounceObservationOutcome] = []

    /// Bypasses the UITestMode early return in ``handlePlayerEvent(_:)`` and
    /// ``refreshIfNeeded(visualState:currentLanguage:hasError:immediate:)`` so unit tests can
    /// observe the Tier 2 event observer → refresh gate chain without WidgetCenter IPC.
    ///
    /// - Parameter bypass: When `true`, ``handlePlayerEvent(_:)`` and ``refreshIfNeeded`` evaluate
    ///   ``isSessionTeardownInProgress`` and ``hasActiveLutheranWidgets`` (refresh path records
    ///   gate outcomes and returns before debounce/coalesce logic).
    /// - SeeAlso: ``_test_setRecordRefreshIfNeededGateOutcomes(_:)``,
    ///   ``_test_refreshIfNeededGateOutcomeLog()``, ``_test_invokeHandlePlayerEvent(_:)``,
    ///   ``setSessionTeardownInProgress(_:)``,
    ///   ``SharedPlayerManager/performSessionAndWidgetTeardown(includeFactoryReset:liveActivityTeardown:refreshWidgets:widgetVisualState:staleLiveness:)``,
    ///   ``WidgetRefreshManagerEventTests``, docs/Event-Driven-Refactor-Roadmap.md (session teardown coverage).
    @MainActor
    static func _test_setBypassUITestModeForRefreshGateObservation(_ bypass: Bool) {
        unsafe _test_bypassUITestModeForRefreshGateObservation = bypass
        if !bypass {
            unsafe _test_refreshGateOutcomeLog = []
        }
    }

    /// Enables append-only recording of refresh guard outcomes for white-box tests.
    ///
    /// - Parameter enabled: Whether each ``refreshIfNeeded`` call appends to
    ///   ``_test_refreshIfNeededGateOutcomeLog()``.
    /// - SeeAlso: ``_test_setBypassUITestModeForRefreshGateObservation(_:)``,
    ///   ``SharedPlayerManagerEventTests``.
    @MainActor
    static func _test_setRecordRefreshIfNeededGateOutcomes(_ enabled: Bool) {
        unsafe _test_recordRefreshIfNeededGateOutcomes = enabled
        if !enabled {
            unsafe _test_refreshGateOutcomeLog = []
        }
    }

    /// Returns the guard-outcome log captured since the last clear or disable.
    @MainActor
    static func _test_refreshIfNeededGateOutcomeLog() -> [RefreshIfNeededGateOutcome] {
        unsafe _test_refreshGateOutcomeLog
    }

    /// Clears the guard-outcome log without changing observation flags.
    @MainActor
    static func _test_clearRefreshIfNeededGateOutcomeLog() {
        unsafe _test_refreshGateOutcomeLog = []
    }

    /// Bypasses the UITestMode early return so ``refreshIfNeeded`` runs debouncing and
    /// coalescing heuristics while ``performRefresh`` records ``refreshExecuted`` without
    /// WidgetCenter IPC.
    ///
    /// Pair with ``_test_setRecordDebounceOutcomes(true)`` and
    /// ``_test_debounceOutcomeLog()`` in timing-dependent consumer tests.
    ///
    /// - Parameter bypass: When `true`, the full deferral/coalesce/adaptive-debounce path executes.
    /// - SeeAlso: ``DebounceObservationOutcome``, ``_test_debounceOutcomeLog()``,
    ///   ``WidgetRefreshManagerEventTests``, docs/Event-Driven-Refactor-Roadmap.md (Tier 5).
    @MainActor
    static func _test_setBypassUITestModeForDebounceObservation(_ bypass: Bool) {
        unsafe _test_bypassUITestModeForDebounceObservation = bypass
        if !bypass {
            unsafe _test_recordedDebounceOutcomes = []
        }
    }

    /// Enables append-only recording of debounce and coalesce branch outcomes.
    ///
    /// - Parameter enabled: Whether each qualifying ``refreshIfNeeded`` branch appends to
    ///   ``_test_debounceOutcomeLog()``.
    /// - SeeAlso: ``_test_setBypassUITestModeForDebounceObservation(_:)``.
    @MainActor
    static func _test_setRecordDebounceOutcomes(_ enabled: Bool) {
        unsafe _test_recordDebounceOutcomes = enabled
        if !enabled {
            unsafe _test_recordedDebounceOutcomes = []
        }
    }

    /// Returns debounce/coalesce outcomes captured since the last clear or disable.
    @MainActor
    static func _test_debounceOutcomeLog() -> [DebounceObservationOutcome] {
        unsafe _test_recordedDebounceOutcomes
    }

    /// Clears the debounce observation log without changing bypass flags.
    @MainActor
    static func _test_clearDebounceOutcomeLog() {
        unsafe _test_recordedDebounceOutcomes = []
    }

    /// Resets debounce, coalesce, and last-known refresh state for timing-isolated unit tests.
    ///
    /// Cancels pending work items and clears ``lastRefreshTime`` / ``lastKnownState`` so
    /// successive tests do not inherit coalesce windows from prior drives.
    ///
    /// - SeeAlso: ``_test_setBypassUITestModeForDebounceObservation(_:)``,
    ///   ``WidgetRefreshManagerEventTests``.
    @MainActor
    func _test_resetRefreshTimingState() {
        cancelPendingRefresh()
        lastRefreshTime = nil
        lastKnownState = nil
        refreshCount = 0
        adaptiveInterval = 0.5
    }

    /// Snapshot of refresh parameters derived by ``handlePlayerEvent(_:)`` for white-box tests.
    ///
    /// Compiled out of Release builds; zero production effect.
    struct HandlePlayerEventDerivation: Equatable, Sendable {
        let visualState: PlayerVisualState
        let currentLanguage: String
        let hasError: Bool
    }

    // SAFETY: DEBUG-only test observation flags written exclusively from @MainActor test
    // entry points; reads occur on the same actor during XCTest. Matches the established
    // nonisolated(unsafe) pattern for privacy-gate cache state in this file.
    nonisolated(unsafe) internal static var _test_recordHandlePlayerEventDerivation = false
    nonisolated(unsafe) internal static var _test_cachedHandlePlayerEventDerivation: HandlePlayerEventDerivation?

    // SAFETY: DEBUG-only immediate-flag observation for event-path white-box tests.
    // Written from @MainActor ``handlePlayerEvent(_:)``; read on the same actor during XCTest.
    nonisolated(unsafe) internal static var _test_recordHandlePlayerEventImmediate = false
    nonisolated(unsafe) internal static var _test_cachedHandlePlayerEventImmediate: Bool?

    // SAFETY: DEBUG-only gate for suspending the Tier 2 live ``events`` observer so
    // other consumers can attach the sole AsyncStream iterator during XCTest (replay
    // forwarding in ``makeEventsStreamWithReplay()``). Written from @MainActor tests.
    nonisolated(unsafe) internal static var _test_suppressPlayerEventObservation = false

    /// Prevents ``beginObservingPlayerEvents()`` from starting while enabled.
    ///
    /// Replay live-forwarding in ``SharedPlayerManager/makeEventsStreamWithReplay()``
    /// requires the shared ``events`` iterator. ``AsyncStream`` admits one consumer;
    /// tests that drive ``PlayerEventSubscriber`` enable this gate and call
    /// ``_test_suspendPlayerEventObservation()`` to release any observer started
    /// before the flag was set.
    ///
    /// - Parameter suppress: Whether Tier 2 live observation must remain idle.
    /// - SeeAlso: ``_test_suspendPlayerEventObservation()``, ``PlayerEventSubscriberEventTests``,
    ///   CODING_AGENT.md (fast test patterns).
    @MainActor
    static func _test_setSuppressPlayerEventObservation(_ suppress: Bool) {
        unsafe _test_suppressPlayerEventObservation = suppress
    }

    /// Cancels the active Tier 2 ``PlayerEvent`` observation task, if any.
    ///
    /// Idempotent. Used with ``_test_setSuppressPlayerEventObservation(true)`` so
    /// replay-forwarding tests can consume live emissions without WidgetCenter work.
    ///
    /// - SeeAlso: ``beginObservingPlayerEvents()``, ``PlayerEventSubscriberEventTests``.
    @MainActor
    func _test_suspendPlayerEventObservation() {
        playerEventObserver.cancel()
        eventObservationTask = nil
    }

    /// Starts Tier 2 live ``PlayerEvent`` observation for tests that exercise the
    /// production observer path.
    ///
    /// XCTest hosts suppress observation at ``init()`` so emitter tests can attach the
    /// sole ``SharedPlayerManager/events`` iterator. Call this after
    /// ``SharedPlayerManager/cancelReplayForwarding()`` when a test needs the live
    /// observer to route emissions through ``handlePlayerEvent(_:)``.
    ///
    /// - SeeAlso: ``_test_setSuppressPlayerEventObservation(_:)``,
    ///   ``_test_suspendPlayerEventObservation()``, ``WidgetRefreshManagerEventTests``,
    ///   ``SharedPlayerManagerEventTests``, CODING_AGENT.md (fast test patterns).
    @MainActor
    func _test_beginObservingPlayerEventsForTests() {
        unsafe Self._test_suppressPlayerEventObservation = false
        beginObservingPlayerEvents()
    }

    /// Polls until the Tier 2 ``PlayerEvent`` observation task is attached or `timeout` elapses.
    ///
    /// XCTest hosts must await attachment before driving live mutations; ``AsyncStream`` does not
    /// replay yields to iterators that suspend after emission.
    ///
    /// - Parameter timeout: Maximum wait in seconds.
    /// - Returns: `true` when ``eventObservationTask`` is non-nil before timeout.
    @MainActor
    func _test_waitForPlayerEventObservationAttached(timeout: TimeInterval = 5.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if eventObservationTask != nil {
                return true
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
        }
        return eventObservationTask != nil
    }

    /// Enables recording of derived refresh parameters without calling ``refreshIfNeeded``
    /// or WidgetCenter IPC.
    ///
    /// When enabled, ``_test_handlePlayerEventBypassingUITestMode(_:)`` stores the derived
    /// snapshot and returns immediately. Tests assert against
    /// ``_test_lastHandlePlayerEventDerivation()`` instead of observing timeline reloads.
    ///
    /// - Parameter enabled: Whether the bypass seam records derivations.
    /// - SeeAlso: ``_test_handlePlayerEventBypassingUITestMode(_:)``,
    ///   ``_test_deriveRefreshParameters(for:)``, CODING_AGENT.md (fast test patterns).
    @MainActor
    static func _test_setRecordHandlePlayerEventDerivation(_ enabled: Bool) {
        unsafe _test_recordHandlePlayerEventDerivation = enabled
        if !enabled {
            unsafe _test_cachedHandlePlayerEventDerivation = nil
        }
    }

    /// Returns the most recent derivation captured by the bypass seam, if any.
    @MainActor
    static func _test_lastHandlePlayerEventDerivation() -> HandlePlayerEventDerivation? {
        unsafe _test_cachedHandlePlayerEventDerivation
    }

    /// Enables recording of the `immediate` flag passed from ``handlePlayerEvent(_:)`` to
    /// ``refreshIfNeeded(visualState:currentLanguage:hasError:immediate:)``.
    ///
    /// - Parameter enabled: Whether each ``handlePlayerEvent(_:)`` call stores the urgency flag.
    /// - SeeAlso: ``_test_lastHandlePlayerEventImmediate()``, ``WidgetRefreshManagerEventTests``.
    @MainActor
    static func _test_setRecordHandlePlayerEventImmediate(_ enabled: Bool) {
        unsafe _test_recordHandlePlayerEventImmediate = enabled
        if !enabled {
            unsafe _test_cachedHandlePlayerEventImmediate = nil
        }
    }

    /// Returns the most recent `immediate` value recorded by ``handlePlayerEvent(_:)``, if any.
    @MainActor
    static func _test_lastHandlePlayerEventImmediate() -> Bool? {
        unsafe _test_cachedHandlePlayerEventImmediate
    }

    /// Exposes ``deriveRefreshParameters(for:)`` for white-box consumer tests.
    ///
    /// - Parameter event: The ``PlayerEvent`` under test.
    /// - Returns: The visual, language, and error inputs that ``handlePlayerEvent(_:)``
    ///   would pass to ``refreshIfNeeded``.
    /// - SeeAlso: ``handlePlayerEvent(_:)``, ``HandlePlayerEventDerivation``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5 consumer coverage).
    @MainActor
    func _test_deriveRefreshParameters(for event: PlayerEvent) -> HandlePlayerEventDerivation {
        let derived = deriveRefreshParameters(for: event)
        return HandlePlayerEventDerivation(
            visualState: derived.visualState,
            currentLanguage: derived.currentLanguage,
            hasError: derived.hasError
        )
    }

    /// Invokes ``handlePlayerEvent(_:)`` derivation with UITestMode guards bypassed.
    ///
    /// Production ``handlePlayerEvent(_:)`` returns immediately under
    /// ``SharedPlayerManager/isRunningInUITestMode``; this seam exercises the same
    /// derivation path for unit tests without requiring a `-UITestMode` launch or
    /// WidgetCenter round-trips.
    ///
    /// When ``_test_setRecordHandlePlayerEventDerivation(true)`` is active, the method
    /// records the derived parameters. It still calls ``refreshIfNeeded`` when
    /// ``_test_setRecordRefreshIfNeededGateOutcomes(true)`` is also active so derivation
    /// and gate-outcome integration can be asserted in one drive. Otherwise it routes
    /// through the full refresh surface (subject to gate-observation bypass flags).
    ///
    /// - Parameter event: The ``PlayerEvent`` to derive from.
    /// - SeeAlso: ``deriveRefreshParameters(for:)``, ``_test_deriveRefreshParameters(for:)``,
    ///   ``_test_invokeHandlePlayerEvent(_:)``, `SharedPlayerManager.loadPersistedWidgetState`,
    ///   CODING_AGENT.md.
    @MainActor
    func _test_handlePlayerEventBypassingUITestMode(_ event: PlayerEvent) async {
        let derived = deriveRefreshParameters(for: event)
        let snapshot = HandlePlayerEventDerivation(
            visualState: derived.visualState,
            currentLanguage: derived.currentLanguage,
            hasError: derived.hasError
        )

        if unsafe Self._test_recordHandlePlayerEventDerivation {
            unsafe Self._test_cachedHandlePlayerEventDerivation = snapshot
            if !(unsafe Self._test_recordRefreshIfNeededGateOutcomes) {
                return
            }
        }

        let immediate = refreshUsesImmediateDelivery(
            for: derived.visualState,
            hasError: derived.hasError
        )

        refreshIfNeeded(
            visualState: derived.visualState,
            currentLanguage: derived.currentLanguage,
            hasError: derived.hasError,
            immediate: immediate
        )
    }

    /// Invokes production ``handlePlayerEvent(_:)`` for event-path integration tests.
    ///
    /// Requires ``_test_setBypassUITestModeForRefreshGateObservation(true)`` under the XCTest
    /// host so the observer callback and this seam share the same UITestMode bypass. Pair with
    /// ``_test_setRecordRefreshIfNeededGateOutcomes(true)`` to assert gate outcomes without
    /// WidgetCenter IPC.
    ///
    /// - Parameter event: The ``PlayerEvent`` delivered by the Tier 2 observer.
    /// - SeeAlso: ``beginObservingPlayerEvents()``, ``handlePlayerEvent(_:)``,
    ///   ``_test_refreshIfNeededGateOutcomeLog()``, ``WidgetRefreshManagerEventTests``.
    @MainActor
    func _test_invokeHandlePlayerEvent(_ event: PlayerEvent) async {
        await handlePlayerEvent(event)
    }
}
#endif

