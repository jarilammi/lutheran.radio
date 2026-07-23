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

    /// Durable LA toggle mirror + empty session: first lock-screen-style toggle plans pause.
    ///
    /// Reproduces the lockscreen regression: extension actor defaults to `.prePlay` and the
    /// memory-only session snapshot is nil under home-widget write suppression, while audio
    /// (and the LA glyph) are still playing. The durable App Group mirror must drive `.pause`.
    func testPerformLiveActivityToggleUsesDurableMirrorWhenSessionEmpty() async {
        // Ensure no leftover in-process snapshot from prior tests in this process.
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        await MainActor.run {
            WidgetRefreshManager.setHasActiveLutheranWidgets(false)
        }

        // Authoritative LA surface says playing (what the lock screen showed).
        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(.playing)

        XCTAssertNil(
            SharedPlayerManager.loadPersistedWidgetState(),
            "Session snapshot must be empty to model cold extension + write suppression"
        )
        XCTAssertEqual(SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(), .playing)

        // Plan-only check (same inputs performLiveActivityToggle resolves) — avoid relying on
        // DirectStreamingPlayer soft-pause side effects under the widget stub.
        let resolution = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: nil,
            durableMirror: SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(),
            actorVisualState: .prePlay,
            sessionSnapshot: SharedPlayerManager.loadPersistedWidgetState()?.visualState
        )
        XCTAssertEqual(resolution.source, .durableCrossProcessMirror)
        XCTAssertEqual(resolution.visualState, .playing)
        XCTAssertEqual(
            WidgetIntentCoordinators.planLiveActivityToggle(resolution: resolution),
            .pause,
            "Empty extension memory must not invert lock-screen pause to play"
        )

        await WidgetIntentExecution.performLiveActivityToggle()

        // Optimistic mirror advances to paused for the next rapid tap.
        XCTAssertEqual(
            SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(),
            .userPaused,
            "After planned pause, durable mirror should optimistically flip to userPaused"
        )

        // Rapid second-tap contract without ActivityKit: durable mirror alone (content nil)
        // must plan play after the optimistic pause write — same direction as ContentState
        // once the optimistic Activity.update lands on device.
        let secondTap = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: nil,
            durableMirror: SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(),
            actorVisualState: .prePlay,
            sessionSnapshot: nil
        )
        XCTAssertEqual(secondTap.source, .durableCrossProcessMirror)
        XCTAssertEqual(
            WidgetIntentCoordinators.planLiveActivityToggle(resolution: secondTap),
            .play,
            "Second rapid tap after optimistic pause mirror must plan play"
        )
    }

    /// Optimistic ContentState builder preserves stream metadata and language when flipping control visual.
    ///
    /// Lock-screen toggle must not clear program title/speaker/language while flipping play/pause.
    func testOptimisticLiveActivityContentPreservesStreamMetadata() {
        let metadata = StreamProgramMetadata(programTitle: "Vesper", speaker: "Cantor")
        let before = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .playing,
            streamMetadata: metadata,
            currentLanguage: "et"
        )
        let after = before.replacingVisualState(.userPaused)
        XCTAssertEqual(after.visualState, .userPaused)
        XCTAssertEqual(after.streamMetadata, metadata)
        XCTAssertEqual(after.currentLanguage, "et")
    }

    /// Durable mirror alone: persist/load/clear contract (no ActivityKit IPC).
    func testLiveActivityToggleVisualStateMirrorRoundTrip() {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        XCTAssertNil(SharedPlayerManager.loadLiveActivityToggleVisualStateMirror())

        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(.playing)
        XCTAssertEqual(SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(), .playing)

        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(.userPaused)
        XCTAssertEqual(SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(), .userPaused)

        SharedPlayerManager.clearLiveActivityToggleVisualStateMirror()
        XCTAssertNil(SharedPlayerManager.loadLiveActivityToggleVisualStateMirror())
    }

    /// Durable LA language mirror: persist/load/clear; optimistic language prefers mirror over
    /// session-less preferredWidgetLanguage fallback.
    ///
    /// Protects LA-only sessions (no home widgets / empty session snapshot) so play/pause
    /// instant-feedback language is not stamped from the privacy-gated default when
    /// ContentState already held a non-English stream code on the durable mirror.
    func testLiveActivityLanguageMirrorRoundTripAndOptimisticLanguageResolve() {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        XCTAssertNil(SharedPlayerManager.loadLiveActivityLanguageMirror())
        XCTAssertNil(SharedPlayerManager.loadPersistedWidgetState())

        let fallbackWithoutMirror = SharedPlayerManager.languageForLiveActivityOrWidgetOptimistic()
        // Without session or mirror, optimistic language falls through to preferredWidgetLanguage.
        XCTAssertEqual(fallbackWithoutMirror, SharedPlayerManager.preferredWidgetLanguage())

        SharedPlayerManager.persistLiveActivityLanguageMirror("fi")
        XCTAssertEqual(SharedPlayerManager.loadLiveActivityLanguageMirror(), "fi")
        XCTAssertEqual(
            SharedPlayerManager.languageForLiveActivityOrWidgetOptimistic(),
            "fi",
            "Optimistic LA language must prefer durable language mirror over privacy-gated preferredWidgetLanguage"
        )

        SharedPlayerManager.clearLiveActivityLanguageMirror()
        XCTAssertNil(SharedPlayerManager.loadLiveActivityLanguageMirror())
        XCTAssertEqual(
            SharedPlayerManager.languageForLiveActivityOrWidgetOptimistic(),
            SharedPlayerManager.preferredWidgetLanguage()
        )
    }

    /// Privacy clear removes both durable LA visual and language mirrors.
    func testRemoveAllLocalPlaybackKeysClearsLiveActivityLanguageMirror() {
        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(.playing)
        SharedPlayerManager.persistLiveActivityLanguageMirror("de")
        XCTAssertEqual(SharedPlayerManager.loadLiveActivityLanguageMirror(), "de")

        SharedPlayerManager.removeAllLocalPlaybackKeys()

        XCTAssertNil(SharedPlayerManager.loadLiveActivityToggleVisualStateMirror())
        XCTAssertNil(SharedPlayerManager.loadLiveActivityLanguageMirror())
    }

    /// Simulated reboot (stale recorded boot) distrusts durable-mirror-alone play planning.
    ///
    /// Boot identity is warmed by the main app (LA push / factory reset), not by extension
    /// optimistic mirror writes — so this test records boot explicitly then ages it.
    func testShouldDistrustDurableMirrorPlayPlanningWhenBootIdentityStale() {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(.userPaused)
        // Simulate main-app LA push having recorded a healthy boot for this session.
        SharedPlayerManager.recordCurrentSystemBootTime()
        XCTAssertFalse(
            SharedPlayerManager.hasDeviceRebootedSinceLastRecordedBoot(),
            "Current boot identity must not report reboot"
        )

        let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared")
        // Simulate a prior boot epoch left in the App Group across hard power-off.
        defaults?.set(1.0, forKey: SharedPlayerManager.recordedSystemBootTimeAppGroupKey)

        XCTAssertTrue(SharedPlayerManager.hasDeviceRebootedSinceLastRecordedBoot())
        XCTAssertTrue(SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning())

        let resolution = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: nil,
            durableMirror: .userPaused,
            actorVisualState: .prePlay,
            sessionSnapshot: nil
        )
        XCTAssertEqual(
            WidgetIntentCoordinators.planLiveActivityToggle(
                resolution: resolution,
                distrustDurableMirrorPlay: SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning()
            ),
            .pause
        )
    }

    /// Termination sentinel alone distrusts durable-mirror-alone play.
    func testShouldDistrustDurableMirrorPlayPlanningWhenTerminationSentinel() {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        SharedPlayerManager.recordCurrentSystemBootTime()
        SharedPlayerManager.forceStaleLivenessTimestampForTermination()

        XCTAssertTrue(SharedPlayerManager.hasExplicitTerminationSentinel())
        XCTAssertTrue(SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning())
    }

    // MARK: - LiveActivitySwitchStreamIntent contract (symmetric to home switch + LA toggle)

    /// Unknown language codes must not invoke ``switchToStream`` (Bool false).
    ///
    /// Mirrors the thin AppIntent guard in ``LiveActivitySwitchStreamIntent/perform()`` via
    /// ``WidgetIntentExecution/performLiveActivityStreamSwitch(languageCode:)``.
    func testPerformLiveActivityStreamSwitchRejectsUnknownLanguage() async {
        let streams = manager.availableStreams
        guard let source = streams.first else {
            XCTFail("Expected stub streams")
            return
        }
        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: source.languageCode)

        let switched = await WidgetIntentExecution.performLiveActivityStreamSwitch(languageCode: "xx-unknown")
        XCTAssertFalse(switched)

        // Reject path must leave optimistic snapshot untouched.
        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(snapshot?.visualState, .userPaused)
        XCTAssertEqual(snapshot?.currentLanguage, source.languageCode)
    }

    /// Known language codes return true (stream list match + ``switchToStream`` invoked).
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

    /// LA stream switch preserves explicit pause and updates language (checklist §6 parity
    /// with ``performHomeWidgetStreamSwitch`` / home-widget optimistic switch SSOT).
    ///
    /// Extension profile: ``switchToStream`` is the shared optimistic path; LA does not
    /// re-plan play/pause (unlike ``performLiveActivityToggle`` multi-source resolution).
    func testPerformLiveActivityStreamSwitchPreservesUserPausedAndUpdatesLanguage() async {
        let streams = manager.availableStreams
        guard streams.count >= 2 else {
            XCTFail("Stub stream list must include ≥2 languages")
            return
        }
        let source = streams[0]
        let target = streams[1]

        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: source.languageCode)

        let switched = await WidgetIntentExecution.performLiveActivityStreamSwitch(
            languageCode: target.languageCode
        )
        XCTAssertTrue(switched)

        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(snapshot?.visualState, .userPaused, "Paused visual must survive LA optimistic switch")
        XCTAssertEqual(snapshot?.currentLanguage, target.languageCode)
    }

    /// Playing snapshot: LA switch updates language without flipping to pause/prePlay.
    func testPerformLiveActivityStreamSwitchFromPlayingUpdatesLanguageOnly() async {
        let streams = manager.availableStreams
        guard streams.count >= 2 else {
            XCTFail("Stub stream list must include ≥2 languages")
            return
        }
        let source = streams[0]
        let target = streams[1]

        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: source.languageCode)

        let switched = await WidgetIntentExecution.performLiveActivityStreamSwitch(
            languageCode: target.languageCode
        )
        XCTAssertTrue(switched)

        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(snapshot?.visualState, .playing, "Playing visual must survive LA optimistic switch")
        XCTAssertEqual(snapshot?.currentLanguage, target.languageCode)
    }

    /// Cold extension (empty session): known-language LA switch still succeeds.
    ///
    /// Symmetric to LA toggle’s empty-session planning path — switch does not require a
    /// pre-existing session snapshot or durable toggle mirror.
    func testPerformLiveActivityStreamSwitchSucceedsWithEmptySessionSnapshot() async {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        XCTAssertNil(SharedPlayerManager.loadPersistedWidgetState())

        let streams = manager.availableStreams
        guard let target = streams.first else {
            XCTFail("Expected stub streams")
            return
        }

        let switched = await WidgetIntentExecution.performLiveActivityStreamSwitch(
            languageCode: target.languageCode
        )
        XCTAssertTrue(switched)

        // Widget switch path writes optimistic language even from an empty session.
        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(snapshot?.currentLanguage, target.languageCode)
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
        XCTAssertEqual(plan.action, .play)

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
