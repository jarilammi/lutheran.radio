//
//  WidgetIntentContractTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 13.7.2026.
//
//  Tier 2 pending / instant / optimistic / switch / toggle-mapping contracts (main-app host).
//  Drain and joined round-trip coverage live in sibling suites split out later.
//

import XCTest
import WidgetSurface
@testable import Lutheran_Radio

/// Main-app host contracts for App Group pending actions, instant-feedback windows,
/// optimistic widget snapshots, widget stream-switch SSOT, and toggle-action mapping.
///
/// Pending-action drain execution and joined optimistic→drain round-trips live in
/// ``WidgetIntentPendingDrainTests`` and ``WidgetIntentJoinedRoundTripTests``.
/// Shared host factories live in `Support/WidgetIntentContractTestSupport.swift`.
///
/// Never calls real `WidgetCenter.reloadTimelines` or ActivityKit IPC.
///
/// - SeeAlso: ``WidgetIntentPendingDrainTests``, ``WidgetIntentJoinedRoundTripTests``,
///   `SharedPlayerManager.swift`, `RadioPlayerCoordinator.swift`,
///   docs/Widget-Functionality-Roadmap.md (Tier 2),
///   docs/cold-launch-streamplay-regression-checklist.md (§6–§7),
///   CODING_AGENT.md (fast test patterns).

final class WidgetIntentContractTests: XCTestCase {

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

    /// Instant feedback still wins inside the 15 s window when it **agrees** with the
    /// settled session / live-chrome language (optimistic switch after persist).
    ///
    /// **Invariant protected:** ``loadSharedState()`` uses ``instantFeedbackLanguage``
    /// when that code is already the session language.
    ///
    /// - SeeAlso: ``SharedPlayerManager/writeInstantFeedback(language:)``,
    ///   ``SharedPlayerManager/loadSharedState()``.
    func testLoadSharedStatePrefersInstantFeedbackWithinFifteenSecondWindow() {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: "fi")
        SharedPlayerManager.writeInstantFeedback(language: "fi")

        let state = manager.loadSharedState()
        XCTAssertEqual(state.currentLanguage, "fi")
        XCTAssertTrue(state.isPlaying)
        XCTAssertFalse(state.hasError)
    }

    /// Play/pause must not let a lagging instant-feedback language override a settled
    /// session / live-chrome stream.
    ///
    /// **Invariant protected:** After session + ``homeWidgetLiveChrome`` are `et`, a
    /// fresh ``instantFeedbackLanguage`` of `sv` (prior Live Activity language) is
    /// ignored by ``loadSharedState()``. Instant feedback remains for switch flash
    /// when the destination already matches session or chrome.
    ///
    /// - SeeAlso: ``SharedPlayerManager/loadSharedState()``,
    ///   ``SharedPlayerManager/settledSessionOrHomeLiveChromeLanguages()``,
    ///   ``SharedPlayerManager/languageForLiveActivityOrWidgetOptimistic()``.
    func testLoadSharedStateDoesNotOverrideSettledEtWithDisagreeingInstantFeedbackSv() {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: "et")
        SharedPlayerManager.persistLiveActivityLanguageMirror("sv")
        SharedPlayerManager.writeInstantFeedback(language: "sv")

        XCTAssertEqual(
            SharedPlayerManager.languageForLiveActivityOrWidgetOptimistic(),
            "et",
            "Play/pause optimistic language must prefer session/live chrome over a lagging LA mirror"
        )
        let state = manager.loadSharedState()
        XCTAssertEqual(state.currentLanguage, "et")
        XCTAssertTrue(state.isPlaying)
        XCTAssertFalse(state.hasError)
    }

    /// Instant feedback remains the language signal when no session or live chrome exists.
    func testLoadSharedStateUsesInstantFeedbackWhenNoSettledSessionOrLiveChrome() {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        SharedPlayerManager.writeInstantFeedback(language: "fi")

        let state = manager.loadSharedState()
        XCTAssertEqual(state.currentLanguage, "fi")
    }

    /// Widget-process pause of a settled `et` session must write `et` instant feedback
    /// even when the durable LA language mirror still holds `sv`.
    ///
    /// **Invariant protected:** ``handleWidgetStop()`` uses
    /// ``languageForLiveActivityOrWidgetOptimistic()`` (session / live chrome first).
    ///
    /// - SeeAlso: ``SharedPlayerManager/handleWidgetStop()``,
    ///   ``SharedPlayerManager/writeInstantFeedback(language:)``.
    func testHandleWidgetStopWritesInstantFeedbackMatchingSettledEtNotLaggingSv() async {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: "et")
        SharedPlayerManager.persistLiveActivityLanguageMirror("sv")

        await manager.handleWidgetStop()

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        XCTAssertEqual(defaults.string(forKey: "instantFeedbackLanguage"), "et")
        XCTAssertEqual(manager.loadSharedState().currentLanguage, "et")
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

    /// Active-play widget-path switch stamps Connecting (``.prePlay``) + destination language on
    /// the optimistic session snapshot — never mid-switch ``.playing``.
    ///
    /// - SeeAlso: ``WidgetIntentCoordinators/optimisticLiveActivityVisualForStreamSwitch(from:)``,
    ///   docs/Widget-Presentation-Dataflow.md.
    func testWidgetSwitchFromPlayingUsesConnectingOptimisticSnapshot() async {
        let streams = manager.availableStreams
        guard streams.count >= 2 else { return }

        let source = streams[0]
        let target = streams[1]

        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: source.languageCode)

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
        XCTAssertEqual(
            snapshot?.visualState,
            .prePlay,
            "Active-play switch must not claim destination playing during attach hold"
        )
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


    func testHomeWidgetToggleActionMappingMatrix() {
        let playEligible: [PlayerVisualState] = [
            .prePlay, .userPaused, .cleared, .securityLocked
        ]
        for state in playEligible {
            let mapped = WidgetIntentCoordinators.planHomeWidgetToggle(from: state)
            XCTAssertEqual(mapped.action, .play, "Play-eligible \(state) must schedule play")
            XCTAssertEqual(
                mapped.targetVisualState,
                state.optimisticHomeWidgetVisualAfterPlayPlan,
                "Home optimistic target for \(state) must hold pause or Connecting (never invent .playing)"
            )
        }

        let thermalMapped = WidgetIntentCoordinators.planHomeWidgetToggle(from: .thermalPaused)
        XCTAssertEqual(thermalMapped.action, .none)
        XCTAssertEqual(thermalMapped.targetVisualState, .thermalPaused)
        XCTAssertFalse(thermalMapped.shouldExecutePendingAction)

        let playingMapped = WidgetIntentCoordinators.planHomeWidgetToggle(from: .playing)
        XCTAssertEqual(playingMapped.action, .pause)
        XCTAssertEqual(playingMapped.targetVisualState, .userPaused)
    }

    /// Control widget `SetValueIntent` bool maps true → play, false → pause.
    func testControlWidgetToggleActionMappingMatrix() {
        let playMapped = WidgetIntentCoordinators.planControlWidgetToggle(isPlayingRequested: true)
        XCTAssertEqual(playMapped.action, .play)
        XCTAssertEqual(playMapped.targetVisualState, .playing)

        let pauseMapped = WidgetIntentCoordinators.planControlWidgetToggle(isPlayingRequested: false)
        XCTAssertEqual(pauseMapped.action, .pause)
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
                action: mapped.action.wireValue,
                language: "en"
            )
            XCTAssertNotNil(actionId)

            guard let pending = manager.getPendingActionIfFresh() else {
                XCTFail("Expected pending for visual \(state)")
                continue
            }
            XCTAssertEqual(pending.action, mapped.action.wireValue)

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
                action: mapped.action.wireValue,
                language: "sv"
            )
            XCTAssertNotNil(actionId)

            guard let pending = manager.getPendingActionIfFresh() else {
                XCTFail("Expected pending for control value \(value)")
                continue
            }
            XCTAssertEqual(pending.action, mapped.action.wireValue)
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
