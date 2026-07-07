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
/// ``_test_deriveRefreshParameters(for:)`` and ``_test_handlePlayerEventBypassingUITestMode(_:)``
/// share the production ``deriveRefreshParameters(for:)`` helper so derivation is
/// verified without timeline reloads or system-service stalls.
///
/// - SeeAlso: ``WidgetRefreshManager/handlePlayerEvent(_:)``,
///   ``WidgetRefreshManager/_test_deriveRefreshParameters(for:)``,
///   ``SharedPlayerManager/persistWidgetSnapshot(visualState:language:streamMetadata:clearStreamMetadata:hasError:)``,
///   ``SharedPlayerManagerEventTests``, docs/Event-Driven-Refactor-Roadmap.md (Tier 5),
///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
@MainActor
final class WidgetRefreshManagerEventTests: XCTestCase {

    private let refreshManager = WidgetRefreshManager.shared

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
        WidgetRefreshManager._test_setRecordHandlePlayerEventDerivation(false)

        await MainActor.run {
            let la = RadioLiveActivityManager.shared
            la.stopLocalUpdateTimer()
            la.activityObservationTask?.cancel()
            la.currentActivity = nil
        }

        try await super.tearDown()
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
}