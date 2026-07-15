//
//  WidgetIntentContractExtensionTests.swift
//  LutheranRadioWidgetTests
//
//  Created by Jari Lammi on 15.7.2026.
//
//  Extension-profile contract tests for optimistic snapshots, pending actions,
//  and AppIntent perform-path SSOT (``WidgetIntentExecution/perform*``).
//
//  **Compile profile:** No `LUTHERAN_MAIN_APP`. ``SharedPlayerManager/isWidgetProcess()``
//  returns `true` by construction — the natural widget extension process model.
//  Never calls real ActivityKit IPC. WidgetCenter reloads may run behind the
//  privacy gate; tests set ``WidgetRefreshManager/setHasActiveLutheranWidgets(_:)``.
//
//  - SeeAlso: ``WidgetIntentExecution``, ``WidgetIntentCoordinators``,
//    docs/Widget-Functionality-Roadmap.md, CODING_AGENT.md (fast test patterns).
//

import XCTest
import WidgetSurface

/// Extension-profile contracts for optimistic intent + perform-path SSOT.
final class WidgetIntentContractExtensionTests: XCTestCase {

    private let manager = SharedPlayerManager.shared

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            WidgetRefreshManager.setHasActiveLutheranWidgets(true)
        }
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        // Extension profile: isWidgetProcess() is always true — no simulate flag needed.
        XCTAssertTrue(
            SharedPlayerManager.isWidgetProcess(),
            "LutheranRadioWidgetTests must compile without LUTHERAN_MAIN_APP"
        )
        XCTAssertTrue(manager.isRunningInWidget())
    }

    override func tearDown() async throws {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        try await super.tearDown()
    }

    // MARK: - Process profile

    /// Confirms the extension compile profile: widget process, emit suppressed by default.
    func testExtensionCompileProfileIsWidgetProcess() async {
        XCTAssertTrue(SharedPlayerManager.isWidgetProcess())
        XCTAssertTrue(manager.isRunningInWidget())

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

        await manager.emit(.visualStateDidChange(.playing))

        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
        collectionTask.cancel()
        try? await Task.sleep(for: .milliseconds(150))
        let streamEvents = await collectionTask.value

        XCTAssertTrue(streamEvents.isEmpty, "Widget process must suppress AsyncStream yields")
    }

    // MARK: - Pending action / optimistic persist

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

    func testPersistOptimisticWidgetSnapshotWritesWithoutPlayerEventYield() async {
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
        try? await Task.sleep(for: .milliseconds(80))

        manager.persistOptimisticWidgetSnapshot(.playing, language: "de")
        await manager.emit(.visualStateDidChange(.playing))

        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
        collectionTask.cancel()
        try? await Task.sleep(for: .milliseconds(150))
        let streamEvents = await collectionTask.value

        XCTAssertTrue(streamEvents.isEmpty)
        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(snapshot?.visualState, .playing)
        XCTAssertEqual(snapshot?.currentLanguage, "de")
    }

    func testSignalWidgetPendingActionPlayWritesOptimisticSnapshotAndPending() {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: "fi")

        let actionId = manager.signalWidgetPendingAction(
            visualState: .playing,
            action: "play",
            language: "fi"
        )

        XCTAssertNotNil(actionId)
        guard let pending = manager.getPendingActionIfFresh() else {
            XCTFail("Expected fresh play pending")
            return
        }
        XCTAssertEqual(pending.action, "play")
        XCTAssertEqual(SharedPlayerManager.loadPersistedWidgetState()?.visualState, .playing)
    }

    func testSignalWidgetPendingActionPauseWritesOptimisticSnapshotAndPending() {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: "de")

        let actionId = manager.signalWidgetPendingAction(
            visualState: .userPaused,
            action: "pause",
            language: "de"
        )

        XCTAssertNotNil(actionId)
        guard let pending = manager.getPendingActionIfFresh() else {
            XCTFail("Expected fresh pause pending")
            return
        }
        XCTAssertEqual(pending.action, "pause")
        XCTAssertEqual(SharedPlayerManager.loadPersistedWidgetState()?.visualState, .userPaused)
    }

    // MARK: - AppIntent perform-path SSOT (extension profile)

    // Note on pending-action assertions under TEST_HOST:
    // `signalWidgetPendingAction` posts a Darwin notify. When this suite runs inside the
    // Lutheran Radio app host, the main-app observer may drain App Group pending keys
    // before the next assertion. The reliable extension-profile contract is the
    // in-process optimistic snapshot written by the same module that compiled without
    // `LUTHERAN_MAIN_APP` (this test target). Pending is covered by the synchronous
    // signal tests above (and main-app host drain tests in Lutheran RadioTests).

    /// ``performHomeWidgetToggle()`` mirrors ``WidgetToggleRadioIntent/perform()``.
    func testPerformHomeWidgetToggleFromPausedPlansPlay() async {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: "fi")

        await WidgetIntentExecution.performHomeWidgetToggle()

        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(snapshot?.visualState, .playing, "Optimistic play snapshot after home toggle")
        XCTAssertEqual(snapshot?.currentLanguage, "fi")
    }

    /// ``performHomeWidgetToggle()`` from playing plans pause.
    func testPerformHomeWidgetToggleFromPlayingPlansPause() async {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: "en")

        await WidgetIntentExecution.performHomeWidgetToggle()

        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(snapshot?.visualState, .userPaused, "Optimistic pause snapshot after home toggle")
        XCTAssertEqual(snapshot?.currentLanguage, "en")
    }

    /// ``performControlWidgetToggle(isPlayingRequested:)`` mirrors Control ``ToggleRadioIntent``.
    func testPerformControlWidgetTogglePlayAndPause() async {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: "sv")

        await WidgetIntentExecution.performControlWidgetToggle(isPlayingRequested: true)
        XCTAssertEqual(
            SharedPlayerManager.loadPersistedWidgetState()?.visualState,
            .playing,
            "Control toggle true → optimistic .playing"
        )

        await WidgetIntentExecution.performControlWidgetToggle(isPlayingRequested: false)
        XCTAssertEqual(
            SharedPlayerManager.loadPersistedWidgetState()?.visualState,
            .userPaused,
            "Control toggle false → optimistic .userPaused"
        )
    }

    /// ``performHomeWidgetStreamSwitch`` preserves paused visual on optimistic switch (checklist §6).
    func testPerformHomeWidgetStreamSwitchPreservesUserPaused() async {
        let streams = manager.availableStreams
        guard streams.count >= 2 else {
            XCTFail("Stub stream list must include ≥2 languages")
            return
        }
        let source = streams[0]
        let target = streams[1]

        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: source.languageCode)

        await WidgetIntentExecution.performHomeWidgetStreamSwitch(languageCode: target.languageCode)

        // Snapshot is process-local SSOT under the extension compile profile.
        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(snapshot?.visualState, .userPaused, "Paused visual must survive optimistic switch")
        XCTAssertEqual(snapshot?.currentLanguage, target.languageCode)
    }

    /// Live Activity stream switch returns false for unknown language codes.
    func testPerformLiveActivityStreamSwitchRejectsUnknownLanguage() async {
        let switched = await WidgetIntentExecution.performLiveActivityStreamSwitch(languageCode: "xx-unknown")
        XCTAssertFalse(switched)
    }

    /// Live Activity stream switch succeeds for a known stub stream.
    func testPerformLiveActivityStreamSwitchAcceptsKnownLanguage() async {
        let streams = manager.availableStreams
        guard let target = streams.last else {
            XCTFail("Expected stub streams")
            return
        }
        let switched = await WidgetIntentExecution.performLiveActivityStreamSwitch(
            languageCode: target.languageCode
        )
        XCTAssertTrue(switched)
    }

    // MARK: - Immediate refresh gate (extension optimistic path)

    /// Optimistic toggle requests `immediate: true` refresh (extension-local reload path).
    ///
    /// Asserts the optimistic snapshot write completed under the privacy gate;
    /// does not require observing WidgetCenter IPC. Darwin may drain App Group pending
    /// when hosted by the main app (see perform-path note above).
    func testExecuteOptimisticToggleCompletesImmediateRefreshPath() async {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: "et")
        let plan = WidgetIntentCoordinators.planHomeWidgetToggle(from: .userPaused)
        XCTAssertEqual(plan.action, "play")

        await WidgetIntentExecution.executeOptimisticToggle(plan: plan, language: "et")

        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(snapshot?.visualState, .playing)
        XCTAssertEqual(snapshot?.currentLanguage, "et")
    }

    // MARK: - Instant feedback

    func testLoadSharedStatePrefersInstantFeedbackWithinFifteenSecondWindow() {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: "en")
        SharedPlayerManager.writeInstantFeedback(language: "fi")

        let state = manager.loadSharedState()
        XCTAssertEqual(state.currentLanguage, "fi")
        XCTAssertTrue(state.isPlaying)
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
    }
}
