//
//  WidgetIntentPendingDrainTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 26.7.2026.
//
//  Play/pause pending-action drain contracts (main-app host + DEBUG seams).
//  Split from ``WidgetIntentContractTests``; method names preserved.
//

import XCTest
import WidgetSurface
@testable import Lutheran_Radio

/// Play/pause pending-action drain contracts (Darwin → coordinator drain → authority).
///
/// Covers ``signalWidgetPendingAction`` optimistic writes, ``checkForPendingWidgetActions``
/// drain (play/pause/debounce/opposite-verb), Darwin notify + foreground drain, and
/// UITestMode clear-without-execute. Joined multi-phase round-trips live in
/// ``WidgetIntentJoinedRoundTripTests``.
///
/// - SeeAlso: ``WidgetIntentContractTests``, ``WidgetIntentJoinedRoundTripTests``,
///   ``RadioPlayerCoordinator/checkForPendingWidgetActions()``,
///   ``makePendingActionDrainHost(bypassUITestMode:)``,
///   docs/Widget-Functionality-Roadmap.md (Tier 2 play/pause drain),
///   CODING_AGENT.md (fast test patterns).

final class WidgetIntentPendingDrainTests: XCTestCase {

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

    // MARK: - Play/pause pending-action drain (P1)

    /// Widget optimistic play path: ``signalWidgetPendingAction`` writes snapshot + schedules "play".
    func testSignalWidgetPendingActionPlayWritesOptimisticSnapshotAndPending() {
        SharedPlayerManager._test_setSimulateWidgetProcessContext(true)
        defer { SharedPlayerManager._test_setSimulateWidgetProcessContext(false) }

        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: "fi")

        let actionId = SharedPlayerManager.shared.signalWidgetPendingAction(
            visualState: .playing,
            action: "play",
            language: "fi"
        )

        XCTAssertNotNil(actionId)

        guard let pending = manager.getPendingActionIfFresh() else {
            XCTFail("Expected fresh play pending after signalWidgetPendingAction")
            return
        }
        XCTAssertEqual(pending.action, "play")
        XCTAssertEqual(pending.actionId, actionId)

        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(snapshot?.visualState, .playing)
        XCTAssertEqual(snapshot?.currentLanguage, "fi")
    }

    /// Widget optimistic pause path: ``signalWidgetPendingAction`` writes snapshot + schedules "pause".
    func testSignalWidgetPendingActionPauseWritesOptimisticSnapshotAndPending() {
        SharedPlayerManager._test_setSimulateWidgetProcessContext(true)
        defer { SharedPlayerManager._test_setSimulateWidgetProcessContext(false) }

        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: "de")

        let actionId = SharedPlayerManager.shared.signalWidgetPendingAction(
            visualState: .userPaused,
            action: "pause",
            language: "de"
        )

        XCTAssertNotNil(actionId)

        guard let pending = manager.getPendingActionIfFresh() else {
            XCTFail("Expected fresh pause pending after signalWidgetPendingAction")
            return
        }
        XCTAssertEqual(pending.action, "pause")
        XCTAssertEqual(pending.actionId, actionId)

        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(snapshot?.visualState, .userPaused)
        XCTAssertEqual(snapshot?.currentLanguage, "de")
    }

    /// Main-app drain: pending "play" → ``userRequestedPlay()`` (clears pause lock, active intent).
    @MainActor
    func testCheckForPendingWidgetActionsDrainsPlayPending() async {
        await manager.setUserPaused()

        let actionId = manager.scheduleWidgetAction(action: "play")
        XCTAssertNotNil(actionId)
        XCTAssertNotNil(manager.getPendingActionIfFresh())

        let host = makePendingActionDrainHost()
        host.checkForPendingWidgetActions()

        XCTAssertNil(manager.getPendingAction(), "Drain must clear pending before async play Task runs")

        let drained = await waitUntilWidgetIntentCondition {
            let intent = await SharedPlayerManager.shared.currentPlaybackIntent
            return intent == .shouldBePlaying
        }
        XCTAssertTrue(drained, "Play pending must route to userRequestedPlay → .shouldBePlaying intent")
        _ = host

        let visual = await manager.currentVisualState
        XCTAssertEqual(visual, .playing, "UITestMode play() sets .playing when intent is active")
    }

    /// Main-app drain: pending "pause" → coordinator ``handleWidgetPauseAction()`` → media-transport mailbox pause.
    @MainActor
    func testCheckForPendingWidgetActionsDrainsPausePending() async {
        await manager.setPlaying()

        let actionId = manager.scheduleWidgetAction(action: "pause")
        XCTAssertNotNil(actionId)

        let host = makePendingActionDrainHost()
        host.checkForPendingWidgetActions()

        XCTAssertNil(manager.getPendingAction())

        let drained = await waitUntilWidgetIntentCondition {
            let visual = await SharedPlayerManager.shared.currentVisualState
            let intent = await SharedPlayerManager.shared.currentPlaybackIntent
            return visual == .userPaused && intent == .userPaused
        }
        XCTAssertTrue(drained, "Pause pending must route to handleWidgetPauseAction → stop()")
        _ = host
    }

    /// Double-pause while already `.userPaused` is ignored (prevents resurrection races).
    @MainActor
    func testCheckForPendingWidgetActionsIgnoresPauseWhenAlreadyUserPaused() async {
        await manager.setUserPaused()

        manager.scheduleWidgetAction(action: "pause")

        let host = makePendingActionDrainHost()
        host.checkForPendingWidgetActions()
        _ = host

        XCTAssertNil(manager.getPendingAction(), "Pending must be cleared even when pause is ignored")

        let visual = await manager.currentVisualState
        let intent = await manager.currentPlaybackIntent
        XCTAssertEqual(visual, .userPaused)
        XCTAssertEqual(intent, .userPaused)
    }

    /// Rapid same-direction widget play taps within the debounce window must not thrash AVFoundation.
    ///
    /// Protects: same-verb debounce still drops a second `"play"` while allowing the first
    /// to establish `.shouldBePlaying`. Opposite verbs are covered by
    /// ``testCheckForPendingWidgetActionsAllowsOppositePlayPauseWithinDebounceWindow``.
    @MainActor
    func testCheckForPendingWidgetActionsDebouncesRapidPlayTaps() async {
        await manager.setUserPaused()

        let host = makePendingActionDrainHost()
        SharedPlayerManager.shared.scheduleWidgetAction(action: "play")
        host.checkForPendingWidgetActions()

        SharedPlayerManager.shared.scheduleWidgetAction(action: "play")
        host.checkForPendingWidgetActions()
        _ = host

        XCTAssertNil(manager.getPendingAction(), "Second drain clears pending even when debounced")

        let drained = await waitUntilWidgetIntentCondition {
            let intent = await SharedPlayerManager.shared.currentPlaybackIntent
            return intent == .shouldBePlaying
        }
        XCTAssertTrue(drained, "Only the first play tap within debounce should execute")
    }

    /// Opposite play→pause within the same-direction debounce window must still reach the engine.
    ///
    /// Extension-hosted Live Activity / home-widget toggles publish optimistic chrome before
    /// Darwin drain. Dropping an opposite pending left chrome paused while audio continued
    /// (or the reverse). Debounce applies only to same-direction repeats.
    ///
    /// - SeeAlso: ``RadioPlayerCoordinator/checkForPendingWidgetActions()``,
    ///   ``ViewController/checkForPendingWidgetActions()`` (shim),
    ///   ``SharedPlayerManager/submitMediaTransportCommandAndWait(_:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    @MainActor
    func testCheckForPendingWidgetActionsAllowsOppositePlayPauseWithinDebounceWindow() async {
        await manager.setUserPaused()

        let host = makePendingActionDrainHost()
        SharedPlayerManager.shared.scheduleWidgetAction(action: "play")
        host.checkForPendingWidgetActions()

        let playStarted = await waitUntilWidgetIntentCondition {
            let intent = await SharedPlayerManager.shared.currentPlaybackIntent
            return intent == .shouldBePlaying
        }
        XCTAssertTrue(playStarted, "First play pending must execute")

        SharedPlayerManager.shared.scheduleWidgetAction(action: "pause")
        host.checkForPendingWidgetActions()
        _ = host

        XCTAssertNil(manager.getPendingAction(), "Opposite pause pending must be cleared (not stuck)")

        let paused = await waitUntilWidgetIntentCondition {
            let visual = await SharedPlayerManager.shared.currentVisualState
            let intent = await SharedPlayerManager.shared.currentPlaybackIntent
            return visual == .userPaused && intent == .userPaused
        }
        XCTAssertTrue(
            paused,
            "Opposite pause within debounce window must execute (same-direction-only debounce)"
        )
    }

    /// Opposite pause→play within the debounce window must resume (not leave sticky pause).
    @MainActor
    func testCheckForPendingWidgetActionsAllowsOppositePausePlayWithinDebounceWindow() async {
        await manager.setPlaying()

        let host = makePendingActionDrainHost()
        SharedPlayerManager.shared.scheduleWidgetAction(action: "pause")
        host.checkForPendingWidgetActions()

        let paused = await waitUntilWidgetIntentCondition {
            let intent = await SharedPlayerManager.shared.currentPlaybackIntent
            return intent == .userPaused
        }
        XCTAssertTrue(paused, "First pause pending must execute")

        SharedPlayerManager.shared.scheduleWidgetAction(action: "play")
        host.checkForPendingWidgetActions()
        _ = host

        XCTAssertNil(manager.getPendingAction())

        let resumed = await waitUntilWidgetIntentCondition {
            let intent = await SharedPlayerManager.shared.currentPlaybackIntent
            return intent == .shouldBePlaying
        }
        XCTAssertTrue(
            resumed,
            "Opposite play within debounce window must execute after pause"
        )
    }

    /// Darwin notify + foreground drain (SceneDelegate defense-in-depth path).
    @MainActor
    func testNotifyMainAppThenForegroundDrainExecutesPlayPending() async {
        await manager.setUserPaused()
        manager.scheduleWidgetAction(action: "play")

        SharedPlayerManager.shared.notifyMainApp(action: "play")

        let host = makePendingActionDrainHost()
        host.checkForPendingWidgetActions()
        _ = host

        let drained = await waitUntilWidgetIntentCondition {
            let intent = await SharedPlayerManager.shared.currentPlaybackIntent
            return intent == .shouldBePlaying
        }
        XCTAssertTrue(drained, "Foreground drain after Darwin notify must execute play pending")
        XCTAssertNil(manager.getPendingAction())
    }

    /// UITestMode drain-only path (no bypass) clears pending without mutating playback state.
    @MainActor
    func testUITestModeWithoutBypassDrainsPendingWithoutExecuting() async {
        await manager.setUserPaused()
        let actionId = manager.scheduleWidgetAction(action: "play")!

        let host = makePendingActionDrainHost(bypassUITestMode: false)
        host.checkForPendingWidgetActions()
        _ = host

        XCTAssertNil(manager.getPendingAction())
        let intent = await manager.currentPlaybackIntent
        let visual = await manager.currentVisualState
        XCTAssertEqual(intent, .userPaused)
        XCTAssertEqual(visual, .userPaused)
        XCTAssertEqual(actionId.count, 36)
    }



}
