//
//  WidgetRefreshManagerEventTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 7.7.2026.
//

import XCTest
@testable import Lutheran_Radio

/// White-box tests for the Tier 2 ``WidgetRefreshManager`` consumer path:
/// ``handlePlayerEvent(_:)`` visual derivation and SSOT fallback behavior.
///
/// These tests exercise the consumer-side contract that emitter tests in
/// ``SharedPlayerManagerEventTests`` do not cover: how ``PlayerEvent`` cases map
/// to ``refreshIfNeeded`` inputs before debouncing and WidgetCenter IPC run.
///
/// ## Why the bypass seam is required
///
/// Production ``handlePlayerEvent(_:)`` returns immediately under
/// ``SharedPlayerManager/isRunningInUITestMode``, and ``refreshIfNeeded`` performs
/// the same short-circuit plus WidgetCenter work. The DEBUG seams
/// ``_test_deriveRefreshParameters(for:)``, ``_test_handlePlayerEventBypassingUITestMode(_:)``,
/// ``_test_invokeHandlePlayerEvent(_:)``, and ``_test_setBypassUITestModeForRefreshGateObservation(_:)``
/// share production code paths so derivation and event-path refresh gate outcomes are
/// verified without timeline reloads or system-service stalls.
///
/// - SeeAlso: ``WidgetRefreshManager/handlePlayerEvent(_:)``,
///   ``WidgetRefreshManager/_test_deriveRefreshParameters(for:)``,
///   ``WidgetRefreshManager/_test_invokeHandlePlayerEvent(_:)``,
///   ``WidgetRefreshManager/_test_refreshIfNeededGateOutcomeLog()``,
///   ``SharedPlayerManager/persistWidgetSnapshot(visualState:language:streamMetadata:clearStreamMetadata:hasError:)``,
///   ``SharedPlayerManagerEventTests``, docs/Event-Driven-Refactor-Roadmap.md (Tier 5),
///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
@MainActor
final class WidgetRefreshManagerEventTests: XCTestCase {

    private let refreshManager = WidgetRefreshManager.shared
    private let manager = SharedPlayerManager.shared

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()

        await MainActor.run {
            let la = RadioLiveActivityManager.shared
            la.stopLocalUpdateTimer()
            la.activityObservationTask?.cancel()
            la.currentActivity = nil
        }

        await SharedPlayerManager.clearAllLocalState()

        WidgetRefreshManager.setHasActiveLutheranWidgets(true)
        WidgetRefreshManager._test_setRecordHandlePlayerEventDerivation(true)
    }

    override func tearDown() async throws {
        await MainActor.run {
            WidgetRefreshManager.setSessionTeardownInProgress(false)
            WidgetRefreshManager._test_setBypassUITestModeForRefreshGateObservation(false)
            WidgetRefreshManager._test_setRecordRefreshIfNeededGateOutcomes(false)
            WidgetRefreshManager._test_setRecordHandlePlayerEventDerivation(false)

            let la = RadioLiveActivityManager.shared
            la.stopLocalUpdateTimer()
            la.activityObservationTask?.cancel()
            la.currentActivity = nil
        }

        try await super.tearDown()
    }

    // MARK: - Gate observation helpers

    /// Polls until the refresh gate-outcome log reaches `minimum` entries.
    private func waitForGateLogCount(
        atLeast minimum: Int,
        timeout: TimeInterval = 5.0
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = WidgetRefreshManager._test_refreshIfNeededGateOutcomeLog().count
            if count >= minimum { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
        }
        return WidgetRefreshManager._test_refreshIfNeededGateOutcomeLog().count >= minimum
    }

    private func enableRefreshGateObservation() {
        WidgetRefreshManager._test_setBypassUITestModeForRefreshGateObservation(true)
        WidgetRefreshManager._test_setRecordRefreshIfNeededGateOutcomes(true)
        WidgetRefreshManager._test_clearRefreshIfNeededGateOutcomeLog()
        XCTAssertFalse(WidgetRefreshManager.isSessionTeardownInProgress)
    }

    // MARK: - Carried visual preference

    /// Verifies that ``PlayerEvent/visualStateDidChange(_:)`` supplies the carried
    /// visual even when the persisted snapshot still holds a different value.
    ///
    /// Widget timeline reloads must reflect the freshest in-event visual on visual
    /// transitions; stale persisted `.userPaused` must not override `.playing` carried
    /// on the event path.
    func testDeriveRefreshParametersPrefersCarriedVisualOverPersistedSnapshot() {
        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .userPaused,
            language: "fi",
            hasError: false
        )

        let derived = refreshManager._test_deriveRefreshParameters(
            for: .visualStateDidChange(.playing)
        )

        XCTAssertEqual(derived.visualState, .playing)
        XCTAssertEqual(derived.currentLanguage, "fi")
        XCTAssertFalse(derived.hasError)
    }

    // MARK: - Persisted fallback

    /// Verifies that non-carrying events (for example ``PlayerEvent/streamDidStart``)
    /// fall back to the authoritative persisted visual.
    func testDeriveRefreshParametersFallsBackToPersistedVisualForStreamDidStart() {
        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .userPaused,
            language: "de",
            hasError: false
        )

        let derived = refreshManager._test_deriveRefreshParameters(for: .streamDidStart)

        XCTAssertEqual(derived.visualState, .userPaused)
        XCTAssertEqual(derived.currentLanguage, "de")
        XCTAssertFalse(derived.hasError)
    }

    /// Verifies that ``PlayerEvent/persistedWidgetStateDidUpdate`` uses the persisted
    /// snapshot visual (the event carries no visual payload).
    func testDeriveRefreshParametersFallsBackToPersistedVisualForPersistedWidgetStateDidUpdate() {
        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .playing,
            language: "sv",
            hasError: false
        )

        let derived = refreshManager._test_deriveRefreshParameters(
            for: .persistedWidgetStateDidUpdate
        )

        XCTAssertEqual(derived.visualState, .playing)
        XCTAssertEqual(derived.currentLanguage, "sv")
        XCTAssertFalse(derived.hasError)
    }

    /// Verifies the safe default when no persisted snapshot exists.
    func testDeriveRefreshParametersDefaultsVisualToPrePlayWhenSnapshotAbsent() {
        XCTAssertNil(SharedPlayerManager.loadPersistedWidgetState())

        let derived = refreshManager._test_deriveRefreshParameters(
            for: .metadataDidUpdate(nil)
        )

        XCTAssertEqual(derived.visualState, .prePlay)
    }

    /// Verifies that ``SharedPlayerManager/loadSharedState()`` error state propagates
    /// through derivation for non-carrying events.
    func testDeriveRefreshParametersPropagatesHasErrorFromPersistedSnapshot() {
        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .userPaused,
            language: "en",
            hasError: true
        )

        let derived = refreshManager._test_deriveRefreshParameters(
            for: .streamDidFail(.securityFailure)
        )

        XCTAssertEqual(derived.visualState, .userPaused)
        XCTAssertEqual(derived.currentLanguage, "en")
        XCTAssertTrue(derived.hasError)
    }

    // MARK: - Bypass seam integration

    /// Verifies that ``_test_handlePlayerEventBypassingUITestMode(_:)`` records the
    /// same derivation as ``_test_deriveRefreshParameters(for:)`` without calling
    /// ``refreshIfNeeded``.
    func testHandlePlayerEventBypassSeamRecordsMatchingDerivation() async {
        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .thermalPaused,
            language: "nb",
            hasError: false
        )

        let expected = refreshManager._test_deriveRefreshParameters(
            for: .visualStateDidChange(.playing)
        )

        await refreshManager._test_handlePlayerEventBypassingUITestMode(
            .visualStateDidChange(.playing)
        )

        let recorded = WidgetRefreshManager._test_lastHandlePlayerEventDerivation()
        XCTAssertEqual(recorded, expected)
        XCTAssertEqual(recorded?.visualState, .playing)
        XCTAssertEqual(recorded?.currentLanguage, "nb")
    }

    // MARK: - Event-path refresh gate integration

    /// Verifies that production ``handlePlayerEvent(_:)`` routes through
    /// ``refreshIfNeeded`` and records ``passedGuards`` when gate observation is enabled.
    func testHandlePlayerEventEventPathRecordsPassedGuardsWhenGateObservationEnabled() async {
        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .userPaused,
            language: "fi",
            hasError: false
        )

        enableRefreshGateObservation()

        await refreshManager._test_invokeHandlePlayerEvent(.visualStateDidChange(.playing))

        XCTAssertEqual(
            WidgetRefreshManager._test_refreshIfNeededGateOutcomeLog(),
            [.passedGuards],
            "Event path must reach refreshIfNeeded and pass guards"
        )
    }

    /// Verifies that ``handlePlayerEvent(_:)`` returns before ``refreshIfNeeded`` while the
    /// session-teardown gate is held, so no gate outcomes are recorded on the event path.
    func testHandlePlayerEventEventPathSkipsRefreshWhileTeardownGateHeld() async {
        enableRefreshGateObservation()
        WidgetRefreshManager.setSessionTeardownInProgress(true)

        await refreshManager._test_invokeHandlePlayerEvent(.streamDidStart)

        XCTAssertTrue(
            WidgetRefreshManager._test_refreshIfNeededGateOutcomeLog().isEmpty,
            "Teardown gate must short-circuit handlePlayerEvent before refreshIfNeeded"
        )
    }

    /// Verifies that derivation recording and refresh gate-outcome recording compose on the
    /// bypass seam: both the derived snapshot and ``passedGuards`` are captured in one drive.
    func testHandlePlayerEventBypassSeamRecordsDerivationAndRefreshGateOutcome() async {
        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .prePlay,
            language: "de",
            hasError: false
        )

        enableRefreshGateObservation()
        WidgetRefreshManager._test_setRecordHandlePlayerEventDerivation(true)

        let expected = refreshManager._test_deriveRefreshParameters(
            for: .visualStateDidChange(.playing)
        )

        await refreshManager._test_handlePlayerEventBypassingUITestMode(
            .visualStateDidChange(.playing)
        )

        XCTAssertEqual(WidgetRefreshManager._test_lastHandlePlayerEventDerivation(), expected)
        XCTAssertEqual(
            WidgetRefreshManager._test_refreshIfNeededGateOutcomeLog(),
            [.passedGuards],
            "Gate observation must still run when derivation recording is enabled"
        )
    }

    /// Verifies the live Tier 2 observer path: ``SharedPlayerManager`` emissions delivered
    /// through ``beginObservingPlayerEvents()`` invoke ``handlePlayerEvent(_:)`` and record
    /// refresh gate outcomes without WidgetCenter IPC.
    func testLivePlayerEventObserverRecordsPassedGuardsOnEmittedTransition() async {
        await manager.setUserIntentToPlay()

        enableRefreshGateObservation()

        await manager.setUserPaused()

        await Task.yield()
        try? await Task.sleep(for: .milliseconds(150))

        let satisfied = await waitForGateLogCount(atLeast: 1)
        let gateLog = WidgetRefreshManager._test_refreshIfNeededGateOutcomeLog()

        XCTAssertTrue(
            satisfied,
            "Live observer must route emitted events to refreshIfNeeded; log: \(gateLog)"
        )
        XCTAssertTrue(
            gateLog.allSatisfy { $0 == .passedGuards },
            "All event-path refresh attempts must pass guards when teardown is not held; log: \(gateLog)"
        )
        XCTAssertFalse(
            gateLog.contains(.suppressedBySessionTeardown),
            "Post-emission refresh must not be suppressed without teardown; log: \(gateLog)"
        )
    }
}