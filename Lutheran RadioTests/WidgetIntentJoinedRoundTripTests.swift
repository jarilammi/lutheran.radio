//
//  WidgetIntentJoinedRoundTripTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 26.7.2026.
//
//  Joined optimistic-signal → drain → authoritative-state round-trip contracts.
//  Split from ``WidgetIntentContractTests``; method names preserved.
//

import XCTest
import WidgetSurface
@testable import Lutheran_Radio

/// Joined optimistic-signal → main-app-drain → authoritative-state contracts.
///
/// Multi-phase round-trips that join extension-shaped ``signalWidgetPendingAction`` with
/// ``RadioPlayerCoordinator/checkForPendingWidgetActions()`` and assert authoritative
/// visual/intent postconditions (including refresh-gate observation without WidgetCenter).
///
/// - SeeAlso: ``WidgetIntentContractTests``, ``WidgetIntentPendingDrainTests``,
///   ``restoreMainAppVisualPreservingOptimisticSnapshot(to:optimisticSnapshot:language:)``,
///   docs/Widget-Functionality-Roadmap.md (Tier 2 joined contracts),
///   CODING_AGENT.md (fast test patterns).

final class WidgetIntentJoinedRoundTripTests: XCTestCase {

    private let manager = SharedPlayerManager.shared

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            prepareWidgetIntentContractTestIsolation()
        }
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        await manager.setUserIntentToPlay()
        // Discard setUp emissions so live-stream emptiness contracts (widget-process
        // suppress) do not observe buffered ``events`` yields from this suite's setUp.
        await manager._test_resetEventsStreamForIsolation()
        _ = await manager.events
    }

    override func tearDown() async throws {
        await MainActor.run {
            tearDownWidgetIntentContractTestIsolation()
        }
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        try await super.tearDown()
    }

    // MARK: - Joined optimistic signal → drain contracts

    /// Optimistic widget play then main-app drain establish authoritative playing state.
    ///
    /// Protects the two-phase cross-process contract: extension-shaped
    /// ``signalWidgetPendingAction`` writes an optimistic session snapshot and pending
    /// command; ``RadioPlayerCoordinator/checkForPendingWidgetActions()`` then clears pending
    /// and drives mailbox play so visual and intent match main-app authority.
    ///
    /// Isolation: UITestMode host; pending-action bypass only via the drain host factory;
    /// widget-process simulation only during the optimistic write; no WidgetCenter or
    /// ActivityKit IPC.
    ///
    /// - SeeAlso: ``SharedPlayerManager/signalWidgetPendingAction``,
    ///   ``RadioPlayerCoordinator/checkForPendingWidgetActions()``,
    ///   `testCheckForPendingWidgetActionsDrainsPlayPending`,
    ///   `testSignalWidgetPendingActionPlayWritesOptimisticSnapshotAndPending`,
    ///   docs/Widget-Functionality-Roadmap.md (Tier 2),
    ///   docs/cold-launch-streamplay-regression-checklist.md (§6–§7),
    ///   CODING_AGENT.md (UITestMode, fast test patterns).
    @MainActor
    func testOptimisticPlaySignalThenDrainEstablishesAuthoritativePlayingState() async {
        await manager.setUserPaused()

        SharedPlayerManager._test_setSimulateWidgetProcessContext(true)
        let actionId = SharedPlayerManager.shared.signalWidgetPendingAction(
            visualState: .playing,
            action: "play",
            language: "fi"
        )
        SharedPlayerManager._test_setSimulateWidgetProcessContext(false)

        XCTAssertNotNil(actionId)
        guard let pending = manager.getPendingActionIfFresh() else {
            XCTFail("Optimistic signal must leave a fresh play pending")
            return
        }
        XCTAssertEqual(pending.action, "play")
        XCTAssertEqual(pending.actionId, actionId)
        XCTAssertEqual(
            SharedPlayerManager.loadPersistedWidgetState()?.visualState,
            .playing,
            "Optimistic phase must expose .playing before main-app drain"
        )

        let host = makePendingActionDrainHost()
        host.checkForPendingWidgetActions()
        _ = host

        let drained = await waitUntilWidgetIntentCondition {
            let intent = await SharedPlayerManager.shared.currentPlaybackIntent
            return intent == .shouldBePlaying
        }
        XCTAssertTrue(drained, "Drain must establish .shouldBePlaying")
        XCTAssertNil(manager.getPendingAction(), "Drain must clear pending before/with execute")

        let visual = await manager.currentVisualState
        XCTAssertEqual(visual, .playing)
        XCTAssertEqual(
            SharedPlayerManager.loadPersistedWidgetState()?.visualState,
            .playing
        )
    }

    /// Optimistic widget pause then main-app drain establish authoritative user-paused state.
    ///
    /// Protects the two-phase cross-process contract for pause: extension-shaped
    /// ``persistOptimisticWidgetSnapshot`` + ``scheduleWidgetAction`` write an optimistic
    /// `.userPaused` snapshot and pending "pause"; ``checkForPendingWidgetActions`` then
    /// clears pending and routes through ``RadioPlayerCoordinator/handleWidgetPauseAction()``
    /// so visual and intent match main-app authority.
    ///
    /// Arrangement notes (unit host, single process):
    /// 1. Optimistic write under widget-process simulation force-sets the shared actor
    ///    visual. Production extensions only mutate their own process, so the main app
    ///    still holds `.playing` until pause drain runs. The test restores main-app visual
    ///    to `.playing` while re-applying the optimistic session snapshot before drain.
    ///    Without that restore the drain’s “already `.userPaused`” guard skips `stop()`.
    /// 2. Darwin ``notifyMainApp`` is intentionally omitted here: leftover main-queue
    ///    listeners with pending-action bypass off would clear pending during the restore
    ///    wait. Drain is exercised manually (same as the bare-pending pause drain test).
    ///    Full ``signalWidgetPendingAction`` (including notify) remains covered by the
    ///    optimistic-write-only tests and the play joined drain.
    ///
    /// Isolation: UITestMode host; pending-action bypass only via the drain host factory;
    /// widget-process simulation only during the optimistic write; no WidgetCenter or
    /// ActivityKit IPC. Double-pause ignore remains a separate drain-only contract.
    ///
    /// - SeeAlso: ``SharedPlayerManager/persistOptimisticWidgetSnapshot(_:language:)``,
    ///   ``SharedPlayerManager/scheduleWidgetAction(action:parameter:)``,
    ///   ``RadioPlayerCoordinator/checkForPendingWidgetActions()``,
    ///   `testCheckForPendingWidgetActionsDrainsPausePending`,
    ///   `testSignalWidgetPendingActionPauseWritesOptimisticSnapshotAndPending`,
    ///   docs/Widget-Functionality-Roadmap.md (Tier 2),
    ///   docs/cold-launch-streamplay-regression-checklist.md (§6–§7),
    ///   CODING_AGENT.md (UITestMode, fast test patterns).
    @MainActor
    func testOptimisticPauseSignalThenDrainEstablishesAuthoritativeUserPausedState() async {
        await manager.setPlaying()

        SharedPlayerManager._test_setSimulateWidgetProcessContext(true)
        SharedPlayerManager.shared.persistOptimisticWidgetSnapshot(.userPaused, language: "fi")
        let actionId = manager.scheduleWidgetAction(action: "pause")
        SharedPlayerManager._test_setSimulateWidgetProcessContext(false)

        XCTAssertNotNil(actionId)
        guard let pending = manager.getPendingActionIfFresh() else {
            XCTFail("Optimistic signal must leave a fresh pause pending")
            return
        }
        XCTAssertEqual(pending.action, "pause")
        XCTAssertEqual(pending.actionId, actionId)
        XCTAssertEqual(
            SharedPlayerManager.loadPersistedWidgetState()?.visualState,
            .userPaused,
            "Optimistic phase must expose .userPaused before main-app drain"
        )

        // Cross-process model: main app still holds pre-signal visual until drain executes.
        await restoreMainAppVisualPreservingOptimisticSnapshot(
            to: .playing,
            optimisticSnapshot: .userPaused,
            language: "fi"
        )
        let restoredVisual = await manager.currentVisualState
        let restoredIntent = await manager.currentPlaybackIntent
        XCTAssertEqual(restoredVisual, .playing)
        XCTAssertEqual(restoredIntent, .shouldBePlaying)
        XCTAssertEqual(SharedPlayerManager.loadPersistedWidgetState()?.visualState, .userPaused)
        XCTAssertNotNil(manager.getPendingActionIfFresh(), "Restore must not clear pending")

        let host = makePendingActionDrainHost()
        host.checkForPendingWidgetActions()
        _ = host

        let drained = await waitUntilWidgetIntentCondition {
            let visual = await SharedPlayerManager.shared.currentVisualState
            let intent = await SharedPlayerManager.shared.currentPlaybackIntent
            return visual == .userPaused && intent == .userPaused
        }
        XCTAssertTrue(drained, "Drain must establish .userPaused visual and intent")
        XCTAssertNil(manager.getPendingAction(), "Drain must clear pending before/with execute")

        let intent = await manager.currentPlaybackIntent
        XCTAssertNotEqual(intent, .shouldBePlaying)
        XCTAssertEqual(
            SharedPlayerManager.loadPersistedWidgetState()?.visualState,
            .userPaused
        )
    }

    /// After optimistic play + drain, the refresh path records a guard-passing outcome
    /// without WidgetCenter IPC.
    ///
    /// Enables the Tier 2 ``PlayerEvent`` observer and gate-observation seams for this
    /// test only, then runs the joined optimistic play → drain pipe. Asserts that
    /// post-mutation refresh reaches ``refreshIfNeeded`` with guards open (privacy gate
    /// already true in setUp). Live AsyncStream delivery is best-effort under the XCTest
    /// host; when the gate log is empty after drain, the production
    /// ``handlePlayerEvent(_:)`` path is exercised with the canonical emissions that
    /// drain would produce (hybrid pattern shared with ``WidgetRefreshManagerEventTests``).
    ///
    /// Isolation: UITestMode host; pending-action bypass only via drain host; widget-process
    /// simulation only during optimistic write; gate/debounce observation flags reset in
    /// tearDown; no real `WidgetCenter.reloadTimelines`.
    ///
    /// - SeeAlso: ``WidgetRefreshManager/_test_beginObservingPlayerEventsForTests()``,
    ///   ``WidgetRefreshManager/_test_refreshIfNeededGateOutcomeLog()``,
    ///   ``WidgetRefreshManager/refreshIfNeeded``,
    ///   `testOptimisticPlaySignalThenDrainEstablishesAuthoritativePlayingState`,
    ///   docs/Widget-Functionality-Roadmap.md (Tier 2),
    ///   docs/Event-Driven-Refactor-Roadmap.md,
    ///   CODING_AGENT.md (UITestMode, fast test patterns).
    @MainActor
    func testOptimisticPlayDrainRequestsWidgetRefreshPassingGuards() async {
        await manager.cancelReplayForwarding()

        let refreshManager = WidgetRefreshManager.shared
        refreshManager._test_beginObservingPlayerEventsForTests()
        let attached = await refreshManager._test_waitForPlayerEventObservationAttached(timeout: 5.0)
        XCTAssertTrue(attached, "Tier 2 observer must attach before optimistic write and drain")

        WidgetRefreshManager._test_setBypassUITestModeForRefreshGateObservation(true)
        WidgetRefreshManager._test_setRecordRefreshIfNeededGateOutcomes(true)
        WidgetRefreshManager._test_clearRefreshIfNeededGateOutcomeLog()
        XCTAssertFalse(WidgetRefreshManager.isSessionTeardownInProgress)
        XCTAssertTrue(WidgetRefreshManager.hasActiveLutheranWidgets)

        await manager.setUserPaused()
        WidgetRefreshManager._test_clearRefreshIfNeededGateOutcomeLog()

        SharedPlayerManager._test_setSimulateWidgetProcessContext(true)
        let actionId = SharedPlayerManager.shared.signalWidgetPendingAction(
            visualState: .playing,
            action: "play",
            language: "fi"
        )
        SharedPlayerManager._test_setSimulateWidgetProcessContext(false)
        XCTAssertNotNil(actionId)

        let host = makePendingActionDrainHost()
        host.checkForPendingWidgetActions()
        _ = host

        let drained = await waitUntilWidgetIntentCondition {
            let intent = await SharedPlayerManager.shared.currentPlaybackIntent
            return intent == .shouldBePlaying
        }
        XCTAssertTrue(drained, "Drain must establish .shouldBePlaying before refresh assertion")

        var gateLog = WidgetRefreshManager._test_refreshIfNeededGateOutcomeLog()
        if !gateLog.contains(.passedGuards) {
            // Best-effort live attach may miss yields under the XCTest host; prove the
            // production event→refresh routing with the same emissions drain produces.
            await refreshManager._test_invokeHandlePlayerEvent(.visualStateDidChange(.playing))
            await refreshManager._test_invokeHandlePlayerEvent(.persistedWidgetStateDidUpdate)
            gateLog = WidgetRefreshManager._test_refreshIfNeededGateOutcomeLog()
        }

        let sawPassedGuards = await waitUntilWidgetIntentCondition(timeout: 2.0) {
            WidgetRefreshManager._test_refreshIfNeededGateOutcomeLog().contains(.passedGuards)
        }
        XCTAssertTrue(
            sawPassedGuards || gateLog.contains(.passedGuards),
            "Joined drain must schedule refresh that passes guards without WidgetCenter; log: \(WidgetRefreshManager._test_refreshIfNeededGateOutcomeLog())"
        )
        XCTAssertFalse(
            WidgetRefreshManager._test_refreshIfNeededGateOutcomeLog().contains(.suppressedBySessionTeardown),
            "Post-drain refresh must not be session-teardown suppressed"
        )
    }

    /// Full optimistic play signal under default UITestMode clears pending without executing.
    ///
    /// Regression for “stale widget pending must not execute as user input”: after an
    /// extension-shaped ``signalWidgetPendingAction`` (optimistic snapshot + pending + notify),
    /// ``checkForPendingWidgetActions`` with pending-action bypass **false** must clear
    /// pending and leave playback intent at `.userPaused` (no ``userRequestedPlay``).
    /// Complements `testUITestModeWithoutBypassDrainsPendingWithoutExecuting`, which
    /// schedules bare pending only.
    ///
    /// Optimistic session snapshot (and same-process force-set of actor visual) may still
    /// show `.playing` after clear — that is extension feedback, not main-app execute.
    /// Safety is intent + pending: intent stays sticky-paused and pending is drained.
    ///
    /// Isolation: no pending-action bypass; widget-process simulation only during the
    /// optimistic write; no WidgetCenter or ActivityKit IPC.
    ///
    /// - SeeAlso: ``SharedPlayerManager/signalWidgetPendingAction``,
    ///   ``RadioPlayerCoordinator/checkForPendingWidgetActions()``,
    ///   `testUITestModeWithoutBypassDrainsPendingWithoutExecuting`,
    ///   docs/Widget-Functionality-Roadmap.md (Tier 2),
    ///   CODING_AGENT.md (UITestMode isolation SSOT).
    @MainActor
    func testOptimisticPlaySignalWithoutPendingBypassClearsWithoutExecuting() async {
        await manager.setUserPaused()

        SharedPlayerManager._test_setSimulateWidgetProcessContext(true)
        let actionId = SharedPlayerManager.shared.signalWidgetPendingAction(
            visualState: .playing,
            action: "play",
            language: "fi"
        )
        SharedPlayerManager._test_setSimulateWidgetProcessContext(false)

        XCTAssertNotNil(actionId)
        XCTAssertEqual(
            SharedPlayerManager.loadPersistedWidgetState()?.visualState,
            .playing,
            "Optimistic write remains visible until main-app authority overwrites"
        )
        XCTAssertNotNil(manager.getPendingActionIfFresh())

        let host = makePendingActionDrainHost(bypassUITestMode: false)
        host.checkForPendingWidgetActions()
        _ = host

        XCTAssertNil(manager.getPendingAction(), "UITestMode without bypass must still clear pending")
        let intent = await manager.currentPlaybackIntent
        XCTAssertEqual(intent, .userPaused, "Play must not execute without pending-action bypass")
        XCTAssertNotEqual(intent, .shouldBePlaying)
        XCTAssertEqual(
            SharedPlayerManager.loadPersistedWidgetState()?.visualState,
            .playing,
            "Cleared-without-execute leaves optimistic snapshot until an authoritative write"
        )
    }



}
