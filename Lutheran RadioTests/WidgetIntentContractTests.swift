//
//  WidgetIntentContractTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 13.7.2026.
//
//  Tier 2 cross-process intent and snapshot contract tests (main-app host + DEBUG seams).
//

import XCTest
import WidgetSurface
@testable import Lutheran_Radio

/// Fast unit tests for App Group pending actions, instant-feedback windows,
/// optimistic widget snapshots, widget stream-switch SSOT (checklist §6), and
/// play/pause pending-action drain (Darwin → ``checkForPendingWidgetActions``).
///
/// Never calls real `WidgetCenter.reloadTimelines` or ActivityKit IPC.
///
/// - SeeAlso: `SharedPlayerManager.swift`, `RadioPlayerCoordinator.swift`,
///   `ViewController.checkForPendingWidgetActions`, docs/Widget-Functionality-Roadmap.md (Tier 2),
///   docs/cold-launch-streamplay-regression-checklist.md (§6–§7),
///   CODING_AGENT.md (fast test patterns).
final class WidgetIntentContractTests: XCTestCase {

    private let manager = SharedPlayerManager.shared

    override func setUp() async throws {
        try await super.setUp()

        await MainActor.run {
            let la = RadioLiveActivityManager.shared
            la.stopLocalUpdateTimer()
            la.activityObservationTask?.cancel()
            la.currentActivity = nil
            WidgetRefreshManager.setHasActiveLutheranWidgets(true)
            SharedPlayerManager._test_setSimulateWidgetProcessContext(false)
            ViewController._test_setBypassUITestModeForPendingActionProcessing(false)
        }

        SharedPlayerManager.removeAllLocalPlaybackKeys()
        await manager.setUserIntentToPlay()
    }

    override func tearDown() async throws {
        SharedPlayerManager._test_setSimulateWidgetProcessContext(false)
        await MainActor.run {
            ViewController._test_setBypassUITestModeForPendingActionProcessing(false)
        }
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        try await super.tearDown()
    }

    @MainActor
    private static func makePendingActionDrainHost() -> ViewController {
        let host = ViewController()
        host.radioPlayerCoordinator = RadioPlayerCoordinator(
            backgroundImageController: BackgroundImageController(),
            streamingPlayer: DirectStreamingPlayer.shared
        )
        ViewController._test_setBypassUITestModeForPendingActionProcessing(true)
        host._test_resetWidgetActionDebounceForTests()
        return host
    }

    @MainActor
    private static func waitUntil(
        timeout: TimeInterval = 3.0,
        pollIntervalMs: UInt64 = 50,
        condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(pollIntervalMs))
        }
        return false
    }

    // MARK: - Pending action dedup

    /// Rapid scheduling replaces the pending tuple; only the latest `actionId` is authoritative.
    func testRapidScheduleWidgetActionReplacesPendingWithLatest() {
        let firstId = manager.scheduleWidgetAction(action: "play")
        let secondId = manager.scheduleWidgetAction(action: "pause")

        XCTAssertNotNil(firstId)
        XCTAssertNotNil(secondId)
        XCTAssertNotEqual(firstId, secondId)

        guard let pending = manager.getPendingAction() else {
            XCTFail("Expected pending action after rapid schedule")
            return
        }
        XCTAssertEqual(pending.action, "pause")
        XCTAssertEqual(pending.actionId, secondId)
    }

    /// `clearPendingAction(actionId:)` is a no-op when the ID does not match the current pending action.
    func testClearPendingActionIgnoresStaleActionId() {
        let staleId = manager.scheduleWidgetAction(action: "play")!
        let currentId = manager.scheduleWidgetAction(action: "switch", parameter: "de")!

        manager.clearPendingAction(actionId: staleId)

        guard let pending = manager.getPendingAction() else {
            XCTFail("Stale clear must not remove the newer pending action")
            return
        }
        XCTAssertEqual(pending.action, "switch")
        XCTAssertEqual(pending.parameter, "de")
        XCTAssertEqual(pending.actionId, currentId)

        manager.clearPendingAction(actionId: currentId)
        XCTAssertNil(manager.getPendingAction())
    }

    /// Providers using `getPendingActionIfFresh` must drop expired pending actions.
    func testGetPendingActionIfFreshClearsStalePendingActionTime() {
        let actionId = manager.scheduleWidgetAction(action: "play")
        XCTAssertNotNil(actionId)

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        defaults.set(Date().timeIntervalSince1970 - 31, forKey: "pendingActionTime")

        XCTAssertNil(manager.getPendingActionIfFresh(maxAge: 30))
        XCTAssertNil(manager.getPendingAction())
    }

    // MARK: - Instant feedback expiry

    func testLoadSharedStatePrefersInstantFeedbackWithinFifteenSecondWindow() {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: "en")
        SharedPlayerManager.writeInstantFeedback(language: "fi")

        let state = manager.loadSharedState()
        XCTAssertEqual(state.currentLanguage, "fi")
        XCTAssertTrue(state.isPlaying)
        XCTAssertFalse(state.hasError)
    }

    func testLoadSharedStateFallsBackAfterInstantFeedbackExpiry() {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: "en")

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        defaults.set(true, forKey: "isInstantFeedback")
        defaults.set("fi", forKey: "instantFeedbackLanguage")
        defaults.set(Date().timeIntervalSince1970 - 16, forKey: "instantFeedbackTime")

        let state = manager.loadSharedState()
        XCTAssertEqual(state.currentLanguage, "en")
        XCTAssertFalse(state.isPlaying)
        XCTAssertNil(defaults.object(forKey: "isInstantFeedback"))
    }

    // MARK: - Optimistic persist contract

    func testPersistOptimisticWidgetSnapshotWritesSnapshotWithoutPlayerEventYield() async {
        SharedPlayerManager._test_setSimulateWidgetProcessContext(true)
        defer { SharedPlayerManager._test_setSimulateWidgetProcessContext(false) }

        let liveStream = await manager.events
        let collectionTask = Task<[PlayerEvent], Never> {
            var collected: [PlayerEvent] = []
            for await event in liveStream {
                if Task.isCancelled { break }
                collected.append(event)
                if collected.count >= 1 { break }
            }
            return collected
        }

        await Task.yield()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))

        SharedPlayerManager.shared.persistOptimisticWidgetSnapshot(.playing, language: "de")
        await manager.emit(.visualStateDidChange(.playing))

        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
        collectionTask.cancel()
        try? await Task.sleep(for: .milliseconds(150))
        let streamEvents = await collectionTask.value

        XCTAssertTrue(streamEvents.isEmpty, "Widget process must suppress AsyncStream yields")

        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(snapshot?.visualState, .playing)
        XCTAssertEqual(snapshot?.currentLanguage, "de")

        SharedPlayerManager._test_setSimulateWidgetProcessContext(false)
        await manager.setUserPaused()

        let authoritative = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(authoritative?.visualState, .userPaused)
    }

    func testAuthoritativeSaveDoesNotClearUnprocessedPendingAction() async {
        SharedPlayerManager._test_setSimulateWidgetProcessContext(true)
        let actionId = manager.scheduleWidgetAction(action: "play")!
        SharedPlayerManager.shared.persistOptimisticWidgetSnapshot(.playing, language: "sv")
        SharedPlayerManager._test_setSimulateWidgetProcessContext(false)

        await manager.setUserPaused()

        guard let pending = manager.getPendingAction() else {
            XCTFail("Authoritative save must not clear an unprocessed pending action")
            return
        }
        XCTAssertEqual(pending.action, "play")
        XCTAssertEqual(pending.actionId, actionId)
    }

    // MARK: - Widget switch SSOT regression (checklist §6)

    /// Widget pause → language switch must preserve `.userPaused` in the optimistic snapshot
    /// (2026-06-12 desync fix) and schedule a single fresh pending switch.
    func testWidgetSwitchPreservesUserPausedVisualInOptimisticSnapshot() async {
        let streams = manager.availableStreams
        guard streams.count >= 2 else { return }

        let source = streams[0]
        let target = streams[1]

        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: source.languageCode)

        SharedPlayerManager._test_setSimulateWidgetProcessContext(true)
        defer { SharedPlayerManager._test_setSimulateWidgetProcessContext(false) }

        await manager.switchToStream(target)

        guard let pending = manager.getPendingActionIfFresh() else {
            XCTFail("Widget switch must schedule a pending switch action")
            return
        }
        XCTAssertEqual(pending.action, "switch")
        XCTAssertEqual(pending.parameter, target.languageCode)

        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(snapshot?.visualState, .userPaused)
        XCTAssertEqual(snapshot?.currentLanguage, target.languageCode)
    }

    /// Main-app reconciliation for an explicit-paused widget switch updates the engine model
    /// without auto-resume (`switchToStreamFromWidget` paused branch).
    func testPausedWidgetSwitchReconciliationPreservesIntentAndUpdatesStreamModel() async {
        let streams = manager.availableStreams
        guard streams.count >= 2 else { return }

        let target = streams[1]
        await manager.setUserPaused()

        SharedPlayerManager._test_setSimulateWidgetProcessContext(true)
        manager.persistOptimisticWidgetSnapshot(.userPaused, language: streams[0].languageCode)
        await manager.switchToStream(target)
        SharedPlayerManager._test_setSimulateWidgetProcessContext(false)

        guard let pending = manager.getPendingActionIfFresh() else {
            XCTFail("Expected pending switch after widget path")
            return
        }

        await MainActor.run {
            let coordinator = RadioPlayerCoordinator(
                backgroundImageController: BackgroundImageController(),
                streamingPlayer: DirectStreamingPlayer.shared
            )
            coordinator.handleWidgetSwitchToLanguage(target.languageCode, actionId: pending.actionId)
        }

        try? await Task.sleep(for: .milliseconds(800))

        let intent = await manager.currentPlaybackIntent
        let visual = await manager.currentVisualState
        XCTAssertEqual(intent, .userPaused)
        XCTAssertEqual(visual, .userPaused)
        XCTAssertNil(manager.getPendingAction())

        let selected = SharedPlayerManager.streamForLanguageCode(target.languageCode)
        XCTAssertEqual(selected.languageCode, target.languageCode)
    }

    /// Duplicate delivery of the same `actionId` to `handleWidgetSwitchToLanguage` is a no-op
    /// after the first insertion into `processedActionIds`.
    func testHandleWidgetSwitchToLanguageDedupsIdenticalActionId() async {
        let streams = manager.availableStreams
        guard streams.count >= 2 else { return }
        let source = streams[0]
        let target = streams[1]

        await manager.setUserPaused()
        await manager.switchToStream(source)

        SharedPlayerManager._test_setSimulateWidgetProcessContext(true)
        manager.persistOptimisticWidgetSnapshot(.userPaused, language: source.languageCode)
        await manager.switchToStream(target)
        SharedPlayerManager._test_setSimulateWidgetProcessContext(false)

        guard let pending = manager.getPendingActionIfFresh() else {
            XCTFail("Precondition: widget path must schedule a pending switch")
            return
        }
        XCTAssertEqual(pending.actionId.count, 36)

        await MainActor.run {
            let coordinator = RadioPlayerCoordinator(
                backgroundImageController: BackgroundImageController(),
                streamingPlayer: DirectStreamingPlayer.shared
            )
            coordinator.handleWidgetSwitchToLanguage(target.languageCode, actionId: pending.actionId)
            coordinator.handleWidgetSwitchToLanguage(target.languageCode, actionId: pending.actionId)
        }

        var pendingCleared = false
        for _ in 0..<50 {
            if manager.getPendingAction() == nil {
                pendingCleared = true
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertTrue(pendingCleared, "Coordinator must clear pending switch after reconciliation")
        let selected = SharedPlayerManager.streamForLanguageCode(target.languageCode)
        XCTAssertEqual(selected.languageCode, target.languageCode)
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

        let host = Self.makePendingActionDrainHost()
        host.checkForPendingWidgetActions()

        XCTAssertNil(manager.getPendingAction(), "Drain must clear pending before async play Task runs")

        let drained = await Self.waitUntil {
            let intent = await SharedPlayerManager.shared.currentPlaybackIntent
            return intent == .shouldBePlaying
        }
        XCTAssertTrue(drained, "Play pending must route to userRequestedPlay → .shouldBePlaying intent")
        _ = host

        let visual = await manager.currentVisualState
        XCTAssertEqual(visual, .playing, "UITestMode play() sets .playing when intent is active")
    }

    /// Main-app drain: pending "pause" → coordinator ``handleWidgetPauseAction()`` → ``stop()``.
    @MainActor
    func testCheckForPendingWidgetActionsDrainsPausePending() async {
        await manager.setPlaying()

        let actionId = manager.scheduleWidgetAction(action: "pause")
        XCTAssertNotNil(actionId)

        let host = Self.makePendingActionDrainHost()
        host.checkForPendingWidgetActions()

        XCTAssertNil(manager.getPendingAction())

        let drained = await Self.waitUntil {
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

        let host = Self.makePendingActionDrainHost()
        host.checkForPendingWidgetActions()
        _ = host

        XCTAssertNil(manager.getPendingAction(), "Pending must be cleared even when pause is ignored")

        let visual = await manager.currentVisualState
        let intent = await manager.currentPlaybackIntent
        XCTAssertEqual(visual, .userPaused)
        XCTAssertEqual(intent, .userPaused)
    }

    /// Rapid widget play taps within the debounce window must not thrash AVFoundation.
    @MainActor
    func testCheckForPendingWidgetActionsDebouncesRapidPlayTaps() async {
        await manager.setUserPaused()

        let host = Self.makePendingActionDrainHost()
        SharedPlayerManager.shared.scheduleWidgetAction(action: "play")
        host.checkForPendingWidgetActions()

        SharedPlayerManager.shared.scheduleWidgetAction(action: "play")
        host.checkForPendingWidgetActions()
        _ = host

        XCTAssertNil(manager.getPendingAction(), "Second drain clears pending even when debounced")

        let drained = await Self.waitUntil {
            let intent = await SharedPlayerManager.shared.currentPlaybackIntent
            return intent == .shouldBePlaying
        }
        XCTAssertTrue(drained, "Only the first play tap within debounce should execute")
    }

    /// Darwin notify + foreground drain (SceneDelegate defense-in-depth path).
    @MainActor
    func testNotifyMainAppThenForegroundDrainExecutesPlayPending() async {
        await manager.setUserPaused()
        manager.scheduleWidgetAction(action: "play")

        SharedPlayerManager.shared.notifyMainApp(action: "play")

        let host = Self.makePendingActionDrainHost()
        host.checkForPendingWidgetActions()
        _ = host

        let drained = await Self.waitUntil {
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

        ViewController._test_setBypassUITestModeForPendingActionProcessing(false)
        let host = ViewController()
        host.checkForPendingWidgetActions()
        _ = host

        XCTAssertNil(manager.getPendingAction())
        let intent = await manager.currentPlaybackIntent
        let visual = await manager.currentVisualState
        XCTAssertEqual(intent, .userPaused)
        XCTAssertEqual(visual, .userPaused)
        XCTAssertEqual(actionId.count, 36)
    }

    /// Home widget toggle maps every non-playing visual to "play" and `.playing` to "pause".
    func testHomeWidgetToggleActionMappingMatrix() {
        let nonPlayingStates: [PlayerVisualState] = [
            .prePlay, .userPaused, .cleared, .thermalPaused, .securityLocked
        ]
        for state in nonPlayingStates {
            let mapped = WidgetIntentCoordinators.planHomeWidgetToggle(from: state)
            XCTAssertEqual(mapped.action, "play", "Non-playing \(state) must schedule play")
            XCTAssertEqual(mapped.targetVisualState, .playing)
        }

        let playingMapped = WidgetIntentCoordinators.planHomeWidgetToggle(from: .playing)
        XCTAssertEqual(playingMapped.action, "pause")
        XCTAssertEqual(playingMapped.targetVisualState, .userPaused)
    }

    /// Control widget `SetValueIntent` bool maps true → play, false → pause.
    func testControlWidgetToggleActionMappingMatrix() {
        let playMapped = WidgetIntentCoordinators.planControlWidgetToggle(isPlayingRequested: true)
        XCTAssertEqual(playMapped.action, "play")
        XCTAssertEqual(playMapped.targetVisualState, .playing)

        let pauseMapped = WidgetIntentCoordinators.planControlWidgetToggle(isPlayingRequested: false)
        XCTAssertEqual(pauseMapped.action, "pause")
        XCTAssertEqual(pauseMapped.targetVisualState, .userPaused)
    }

    /// End-to-end widget-simulated home-widget toggle uses the home-widget action mapping.
    func testSignalWidgetPendingActionUsesHomeWidgetToggleMapping() {
        SharedPlayerManager._test_setSimulateWidgetProcessContext(true)
        defer { SharedPlayerManager._test_setSimulateWidgetProcessContext(false) }

        for state in [PlayerVisualState.prePlay, .userPaused, .playing] {
            SharedPlayerManager.persistWidgetSnapshot(visualState: state, language: "en")
            let mapped = WidgetIntentCoordinators.planHomeWidgetToggle(from: state)

            if let stale = manager.getPendingAction() {
                manager.clearPendingAction(actionId: stale.actionId)
            }

            let actionId = SharedPlayerManager.shared.signalWidgetPendingAction(
                visualState: mapped.targetVisualState,
                action: mapped.action,
                language: "en"
            )
            XCTAssertNotNil(actionId)

            guard let pending = manager.getPendingActionIfFresh() else {
                XCTFail("Expected pending for visual \(state)")
                continue
            }
            XCTAssertEqual(pending.action, mapped.action)

            let snapshot = SharedPlayerManager.loadPersistedWidgetState()
            XCTAssertEqual(snapshot?.visualState, mapped.targetVisualState)
        }
    }

    /// End-to-end widget-simulated Control widget toggle uses bool → play/pause mapping.
    func testSignalWidgetPendingActionUsesControlWidgetToggleMapping() {
        SharedPlayerManager._test_setSimulateWidgetProcessContext(true)
        defer { SharedPlayerManager._test_setSimulateWidgetProcessContext(false) }

        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: "sv")

        for value in [true, false] {
            let mapped = WidgetIntentCoordinators.planControlWidgetToggle(isPlayingRequested: value)
            if let stale = manager.getPendingAction() {
                manager.clearPendingAction(actionId: stale.actionId)
            }

            let actionId = SharedPlayerManager.shared.signalWidgetPendingAction(
                visualState: mapped.targetVisualState,
                action: mapped.action,
                language: "sv"
            )
            XCTAssertNotNil(actionId)

            guard let pending = manager.getPendingActionIfFresh() else {
                XCTFail("Expected pending for control value \(value)")
                continue
            }
            XCTAssertEqual(pending.action, mapped.action)
            XCTAssertEqual(SharedPlayerManager.loadPersistedWidgetState()?.visualState, mapped.targetVisualState)
        }
    }

    /// ``handleWidgetPauseAction()`` is the coordinator surface invoked by pause drain.
    @MainActor
    func testHandleWidgetPauseActionSetsUserPaused() async {
        await manager.setPlaying()

        let coordinator = RadioPlayerCoordinator(
            backgroundImageController: BackgroundImageController(),
            streamingPlayer: DirectStreamingPlayer.shared
        )
        coordinator.handleWidgetPauseAction()

        let drained = await Self.waitUntil {
            let visual = await SharedPlayerManager.shared.currentVisualState
            return visual == .userPaused
        }
        XCTAssertTrue(drained)
        let intent = await manager.currentPlaybackIntent
        XCTAssertEqual(intent, .userPaused)
    }
}
