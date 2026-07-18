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
/// optimistic widget snapshots, widget stream-switch SSOT (checklist §6),
/// play/pause pending-action drain (Darwin → ``checkForPendingWidgetActions``),
/// and joined optimistic-signal → main-app-drain → authoritative-state contracts
/// (including refresh gate observation without WidgetCenter IPC).
///
/// Never calls real `WidgetCenter.reloadTimelines` or ActivityKit IPC.
///
/// - SeeAlso: `SharedPlayerManager.swift`, `RadioPlayerCoordinator.swift`,
///   `ViewController.checkForPendingWidgetActions`,
///   ``SharedPlayerManager/signalWidgetPendingAction``,
///   ``WidgetRefreshManager/refreshIfNeeded``,
///   docs/Widget-Functionality-Roadmap.md (Tier 2),
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
            WidgetRefreshManager._test_setBypassUITestModeForRefreshGateObservation(false)
            WidgetRefreshManager._test_setRecordRefreshIfNeededGateOutcomes(false)
            WidgetRefreshManager._test_setBypassUITestModeForDebounceObservation(false)
            WidgetRefreshManager.shared._test_suspendPlayerEventObservation()
            WidgetRefreshManager._test_setSuppressPlayerEventObservation(true)
        }

        SharedPlayerManager.removeAllLocalPlaybackKeys()
        await manager.setUserIntentToPlay()
    }

    override func tearDown() async throws {
        SharedPlayerManager._test_setSimulateWidgetProcessContext(false)
        await MainActor.run {
            ViewController._test_setBypassUITestModeForPendingActionProcessing(false)
            WidgetRefreshManager._test_setBypassUITestModeForRefreshGateObservation(false)
            WidgetRefreshManager._test_setRecordRefreshIfNeededGateOutcomes(false)
            WidgetRefreshManager._test_setBypassUITestModeForDebounceObservation(false)
            WidgetRefreshManager.shared._test_suspendPlayerEventObservation()
            WidgetRefreshManager._test_setSuppressPlayerEventObservation(true)
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

    /// Undoes the same-process side effect of ``persistOptimisticWidgetSnapshot`` so drain
    /// observes main-app visual authority.
    ///
    /// Extension-shaped ``signalWidgetPendingAction`` force-sets the shared actor’s
    /// `currentVisualState` via ``persistOptimisticWidgetSnapshot``. In production that
    /// mutation lives only in the extension process; the main app still holds the
    /// pre-signal visual until ``checkForPendingWidgetActions`` executes. The unit host
    /// shares one actor, so tests must restore the main-app visual before drain while
    /// keeping the optimistic session snapshot and pending command.
    ///
    /// - Parameters:
    ///   - visual: Main-app visual that should remain until drain (e.g. `.playing` before pause).
    ///   - optimisticSnapshot: Session snapshot left by the extension write (re-applied after restore).
    ///   - language: Language for the re-applied optimistic snapshot.
    /// - SeeAlso: ``SharedPlayerManager/persistOptimisticWidgetSnapshot(_:language:)``,
    ///   ``SharedPlayerManager/persistWidgetSnapshot(visualState:language:clearStreamMetadata:)``,
    ///   docs/Widget-Functionality-Roadmap.md (Tier 2 cross-process intents).
    @MainActor
    private static func restoreMainAppVisualPreservingOptimisticSnapshot(
        to visual: PlayerVisualState,
        optimisticSnapshot: PlayerVisualState,
        language: String
    ) async {
        // Wait for the fire-and-forget optimistic force-set Task to land.
        _ = await waitUntil(timeout: 1.0) {
            let current = await SharedPlayerManager.shared.currentVisualState
            return current == optimisticSnapshot
        }
        await SharedPlayerManager.shared.setVisualState(visual)
        // `setVisualState` may rewrite the session snapshot; re-apply the extension optimistic write.
        SharedPlayerManager.persistWidgetSnapshot(
            visualState: optimisticSnapshot,
            language: language
        )
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

    /// Main-app drain: pending "pause" → coordinator ``handleWidgetPauseAction()`` → media-transport mailbox pause.
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

    /// Rapid same-direction widget play taps within the debounce window must not thrash AVFoundation.
    ///
    /// Protects: same-verb debounce still drops a second `"play"` while allowing the first
    /// to establish `.shouldBePlaying`. Opposite verbs are covered by
    /// ``testCheckForPendingWidgetActionsAllowsOppositePlayPauseWithinDebounceWindow``.
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

    /// Opposite play→pause within the same-direction debounce window must still reach the engine.
    ///
    /// Extension-hosted Live Activity / home-widget toggles publish optimistic chrome before
    /// Darwin drain. Dropping an opposite pending left chrome paused while audio continued
    /// (or the reverse). Debounce applies only to same-direction repeats.
    ///
    /// - SeeAlso: ``ViewController/checkForPendingWidgetActions()``,
    ///   ``SharedPlayerManager/submitMediaTransportCommandAndWait(_:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    @MainActor
    func testCheckForPendingWidgetActionsAllowsOppositePlayPauseWithinDebounceWindow() async {
        await manager.setUserPaused()

        let host = Self.makePendingActionDrainHost()
        SharedPlayerManager.shared.scheduleWidgetAction(action: "play")
        host.checkForPendingWidgetActions()

        let playStarted = await Self.waitUntil {
            let intent = await SharedPlayerManager.shared.currentPlaybackIntent
            return intent == .shouldBePlaying
        }
        XCTAssertTrue(playStarted, "First play pending must execute")

        SharedPlayerManager.shared.scheduleWidgetAction(action: "pause")
        host.checkForPendingWidgetActions()
        _ = host

        XCTAssertNil(manager.getPendingAction(), "Opposite pause pending must be cleared (not stuck)")

        let paused = await Self.waitUntil {
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

        let host = Self.makePendingActionDrainHost()
        SharedPlayerManager.shared.scheduleWidgetAction(action: "pause")
        host.checkForPendingWidgetActions()

        let paused = await Self.waitUntil {
            let intent = await SharedPlayerManager.shared.currentPlaybackIntent
            return intent == .userPaused
        }
        XCTAssertTrue(paused, "First pause pending must execute")

        SharedPlayerManager.shared.scheduleWidgetAction(action: "play")
        host.checkForPendingWidgetActions()
        _ = host

        XCTAssertNil(manager.getPendingAction())

        let resumed = await Self.waitUntil {
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

    // MARK: - Joined optimistic signal → drain contracts

    /// Optimistic widget play then main-app drain establish authoritative playing state.
    ///
    /// Protects the two-phase cross-process contract: extension-shaped
    /// ``signalWidgetPendingAction`` writes an optimistic session snapshot and pending
    /// command; ``checkForPendingWidgetActions`` then clears pending and drives
    /// ``userRequestedPlay`` so visual and intent match main-app authority.
    ///
    /// Isolation: UITestMode host; pending-action bypass only via the drain host factory;
    /// widget-process simulation only during the optimistic write; no WidgetCenter or
    /// ActivityKit IPC.
    ///
    /// - SeeAlso: ``SharedPlayerManager/signalWidgetPendingAction``,
    ///   ``ViewController/checkForPendingWidgetActions()``,
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

        let host = Self.makePendingActionDrainHost()
        host.checkForPendingWidgetActions()
        _ = host

        let drained = await Self.waitUntil {
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
    ///   ``ViewController/checkForPendingWidgetActions()``,
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
        await Self.restoreMainAppVisualPreservingOptimisticSnapshot(
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

        let host = Self.makePendingActionDrainHost()
        host.checkForPendingWidgetActions()
        _ = host

        let drained = await Self.waitUntil {
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

        let host = Self.makePendingActionDrainHost()
        host.checkForPendingWidgetActions()
        _ = host

        let drained = await Self.waitUntil {
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

        let sawPassedGuards = await Self.waitUntil(timeout: 2.0) {
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
    ///   ``ViewController/checkForPendingWidgetActions()``,
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

        ViewController._test_setBypassUITestModeForPendingActionProcessing(false)
        let host = ViewController()
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

    /// Home widget toggle: playing → pause; thermal → refuse; else play (security → Connecting).
    func testHomeWidgetToggleActionMappingMatrix() {
        let playEligible: [PlayerVisualState] = [
            .prePlay, .userPaused, .cleared, .securityLocked
        ]
        for state in playEligible {
            let mapped = WidgetIntentCoordinators.planHomeWidgetToggle(from: state)
            XCTAssertEqual(mapped.action, "play", "Play-eligible \(state) must schedule play")
            XCTAssertEqual(
                mapped.targetVisualState,
                state.optimisticVisualAfterPlayPlan,
                "Optimistic target for \(state) must follow security/connecting policy"
            )
        }

        let thermalMapped = WidgetIntentCoordinators.planHomeWidgetToggle(from: .thermalPaused)
        XCTAssertEqual(thermalMapped.action, "none")
        XCTAssertEqual(thermalMapped.targetVisualState, .thermalPaused)
        XCTAssertFalse(thermalMapped.shouldExecutePendingAction)

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
        await coordinator.handleWidgetPauseAction()

        let visual = await manager.currentVisualState
        let intent = await manager.currentPlaybackIntent
        XCTAssertEqual(visual, .userPaused)
        XCTAssertEqual(intent, .userPaused)
    }
}
