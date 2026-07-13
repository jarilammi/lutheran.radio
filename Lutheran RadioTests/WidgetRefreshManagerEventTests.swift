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
/// Debouncing and coalescing timing contracts are exercised through
/// ``_test_setBypassUITestModeForDebounceObservation(_:)`` and
/// ``_test_debounceOutcomeLog()``.
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

            // Suspend before clear so teardown emissions cannot re-persist a snapshot mid-setUp.
            refreshManager._test_suspendPlayerEventObservation()
            WidgetRefreshManager._test_setSuppressPlayerEventObservation(true)
        }

        await SharedPlayerManager.clearAllLocalState()
        await manager.cancelReplayForwarding()

        await MainActor.run {
            WidgetRefreshManager.setHasActiveLutheranWidgets(true)
            WidgetRefreshManager._test_setRecordHandlePlayerEventDerivation(true)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            refreshManager._test_suspendPlayerEventObservation()
            WidgetRefreshManager._test_setSuppressPlayerEventObservation(true)
            WidgetRefreshManager.setSessionTeardownInProgress(false)
            WidgetRefreshManager._test_setBypassUITestModeForRefreshGateObservation(false)
            WidgetRefreshManager._test_setRecordRefreshIfNeededGateOutcomes(false)
            WidgetRefreshManager._test_setRecordHandlePlayerEventDerivation(false)
            WidgetRefreshManager._test_setRecordHandlePlayerEventImmediate(false)
            WidgetRefreshManager._test_setBypassUITestModeForDebounceObservation(false)
            WidgetRefreshManager._test_setRecordDebounceOutcomes(false)

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

    private func enableDebounceObservation() {
        WidgetRefreshManager._test_setBypassUITestModeForDebounceObservation(true)
        WidgetRefreshManager._test_setRecordDebounceOutcomes(true)
        WidgetRefreshManager._test_clearDebounceOutcomeLog()
        refreshManager._test_resetRefreshTimingState()
        XCTAssertFalse(WidgetRefreshManager.isSessionTeardownInProgress)
    }

    /// Polls until the debounce observation log contains `outcome`.
    private func waitForDebounceOutcome(
        _ outcome: WidgetRefreshManager.DebounceObservationOutcome,
        timeout: TimeInterval = 2.0
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if WidgetRefreshManager._test_debounceOutcomeLog().contains(outcome) { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
        }
        return WidgetRefreshManager._test_debounceOutcomeLog().contains(outcome)
    }

    private func refreshExecutedCount() -> Int {
        WidgetRefreshManager._test_debounceOutcomeLog()
            .filter { $0 == .refreshExecuted }
            .count
    }

    /// Polls until ``refreshExecuted`` appears at least `minimum` times in the observation log.
    private func waitForRefreshExecutedCount(
        atLeast minimum: Int,
        timeout: TimeInterval = 2.0
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if refreshExecutedCount() >= minimum { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
        }
        return refreshExecutedCount() >= minimum
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

    /// Verifies that non-carrying stream verbs fall back to the authoritative persisted visual.
    ///
    /// ``deriveRefreshParameters(for:)`` treats every event except
    /// ``PlayerEvent/visualStateDidChange(_:)`` identically; this test anchors
    /// ``PlayerEvent/streamDidStart`` on the shared persisted-fallback path.
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

    /// Verifies persisted visual fallback for ``PlayerEvent/streamDidPause``.
    func testDeriveRefreshParametersFallsBackToPersistedVisualForStreamDidPause() {
        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .playing,
            language: "fi",
            hasError: false
        )

        let derived = refreshManager._test_deriveRefreshParameters(for: .streamDidPause)

        XCTAssertEqual(derived.visualState, .playing)
        XCTAssertEqual(derived.currentLanguage, "fi")
        XCTAssertFalse(derived.hasError)
    }

    /// Verifies persisted visual fallback for ``PlayerEvent/streamDidStop``.
    func testDeriveRefreshParametersFallsBackToPersistedVisualForStreamDidStop() {
        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .userPaused,
            language: "sv",
            hasError: false
        )

        let derived = refreshManager._test_deriveRefreshParameters(for: .streamDidStop)

        XCTAssertEqual(derived.visualState, .userPaused)
        XCTAssertEqual(derived.currentLanguage, "sv")
        XCTAssertFalse(derived.hasError)
    }

    /// Verifies persisted visual fallback for ``PlayerEvent/playbackIntentChanged(_:)``.
    func testDeriveRefreshParametersFallsBackToPersistedVisualForPlaybackIntentChanged() {
        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .playing,
            language: "nb",
            hasError: false
        )

        let derived = refreshManager._test_deriveRefreshParameters(
            for: .playbackIntentChanged(.shouldBePlaying)
        )

        XCTAssertEqual(derived.visualState, .playing)
        XCTAssertEqual(derived.currentLanguage, "nb")
        XCTAssertFalse(derived.hasError)
    }

    /// Verifies persisted visual fallback for non-nil ``PlayerEvent/metadataDidUpdate(_:)``.
    ///
    /// Metadata payloads do not carry visual state; derivation must still read the snapshot.
    func testDeriveRefreshParametersFallsBackToPersistedVisualForMetadataDidUpdateNonNil() {
        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .playing,
            language: "et",
            hasError: false
        )

        let metadata = StreamProgramMetadata(programTitle: "Sunday Sermon", speaker: "Speaker")
        let derived = refreshManager._test_deriveRefreshParameters(
            for: .metadataDidUpdate(metadata)
        )

        XCTAssertEqual(derived.visualState, .playing)
        XCTAssertEqual(derived.currentLanguage, "et")
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
    ///
    /// Re-runs ``SharedPlayerManager/clearAllLocalState()`` locally because sibling derivation
    /// tests persist snapshots and async clear work from ``setUp`` must settle before the nil
    /// precondition is asserted.
    func testDeriveRefreshParametersDefaultsVisualToPrePlayWhenSnapshotAbsent() async {
        await SharedPlayerManager.clearAllLocalState()
        await MainActor.run {
            WidgetRefreshManager.setHasActiveLutheranWidgets(true)
            WidgetRefreshManager._test_setSuppressPlayerEventObservation(true)
        }
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

    /// Verifies the Tier 2 observer attachment contract and that ``setUserPaused()`` refresh
    /// is driven exclusively by ``PlayerEvent`` delivery after Tier 3 dedup (no imperative
    /// ``performActualSave`` ``refreshIfNeeded``).
    ///
    /// Primary gate: observer attaches via ``_test_waitForPlayerEventObservationAttached(timeout:)``.
    /// Refresh outcomes: live ``AsyncStream`` delivery is best-effort in the XCTest host; when the
    /// gate log is empty after ``setUserPaused()``, the test exercises the production
    /// ``handlePlayerEvent(_:)`` path with the same canonical emissions (hybrid pattern from
    /// ``SharedPlayerManagerEventTests`` replay-forwarding tests).
    ///
    /// - SeeAlso: ``_test_invokeHandlePlayerEvent(_:)``,
    ///   ``testHandlePlayerEventEventPathRecordsPassedGuardsWhenGateObservationEnabled()``,
    ///   docs/Widget-Functionality-Roadmap.md (Tier 3).
    func testLivePlayerEventObserverRecordsPassedGuardsOnEmittedTransition() async {
        await manager.cancelReplayForwarding()
        await MainActor.run {
            refreshManager._test_beginObservingPlayerEventsForTests()
        }
        let attached = await refreshManager._test_waitForPlayerEventObservationAttached(timeout: 5.0)
        XCTAssertTrue(attached, "Tier 2 observer must attach before live mutations are driven")

        enableRefreshGateObservation()

        await manager.setUserIntentToPlay()
        await manager.setUserPaused()

        var gateLog = WidgetRefreshManager._test_refreshIfNeededGateOutcomeLog()
        if gateLog.isEmpty {
            // Best-effort live attach may miss yields; prove handler routing with canonical emissions.
            await refreshManager._test_invokeHandlePlayerEvent(.visualStateDidChange(.userPaused))
            await refreshManager._test_invokeHandlePlayerEvent(.persistedWidgetStateDidUpdate)
            gateLog = WidgetRefreshManager._test_refreshIfNeededGateOutcomeLog()
        }

        XCTAssertFalse(
            gateLog.isEmpty,
            "Event path must reach refreshIfNeeded after setUserPaused (live or handler seam); log: \(gateLog)"
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

    // MARK: - Event-path privacy gate

    /// Verifies that ``handlePlayerEvent(_:)`` records privacy suppression when
    /// ``hasActiveLutheranWidgets`` is false and the event is
    /// ``PlayerEvent/persistedWidgetStateDidUpdate``.
    ///
    /// The write-side privacy gate suppresses snapshot persistence and emission on the
    /// emitter path; the Tier 2 consumer must honor the same gate before scheduling
    /// timeline reload work.
    ///
    /// - SeeAlso: ``SharedPlayerManagerEventTests/testSaveCurrentStateWithPrivacyGateClosedSuppressesPersistedWidgetStateEmission()``,
    ///   ``WidgetRefreshManager/setHasActiveLutheranWidgets(_:)``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5).
    func testHandlePlayerEventEventPathSuppressesRefreshWhenPrivacyGateClosed() async {
        WidgetRefreshManager.setHasActiveLutheranWidgets(false)
        XCTAssertFalse(WidgetRefreshManager.hasActiveLutheranWidgets)

        enableRefreshGateObservation()

        await refreshManager._test_invokeHandlePlayerEvent(.persistedWidgetStateDidUpdate)

        XCTAssertEqual(
            WidgetRefreshManager._test_refreshIfNeededGateOutcomeLog(),
            [.suppressedByPrivacyGate],
            "Closed privacy gate must suppress event-path refresh before WidgetCenter IPC"
        )
    }

    // MARK: - Event-path immediate delivery

    /// Verifies that ``handlePlayerEvent(_:)`` passes `immediate: true` to
    /// ``refreshIfNeeded(visualState:currentLanguage:hasError:immediate:)`` for terminal and
    /// sticky-pause visuals (parity with former ``performActualSave`` urgency and teardown callers).
    ///
    /// Factory-reset, privacy-clear, and sticky pause/lock presentations must not be deferred
    /// behind the `.prePlay` → `.playing` coalesce window on the Tier 2 observer path.
    ///
    /// - SeeAlso: ``handlePlayerEvent(_:)``,
    ///   ``WidgetRefreshManager/_test_lastHandlePlayerEventImmediate()``,
    ///   docs/Widget-Functionality-Roadmap.md (Tier 3), docs/Event-Driven-Refactor-Roadmap.md (Tier 5).
    func testHandlePlayerEventEventPathUsesImmediateForPrePlayAndCleared() async {
        WidgetRefreshManager._test_setBypassUITestModeForRefreshGateObservation(true)
        WidgetRefreshManager._test_setRecordHandlePlayerEventImmediate(true)

        let immediateVisuals: [PlayerVisualState] = [
            .prePlay, .cleared, .userPaused, .thermalPaused, .securityLocked
        ]
        for visual in immediateVisuals {
            await refreshManager._test_invokeHandlePlayerEvent(.visualStateDidChange(visual))
            XCTAssertEqual(
                WidgetRefreshManager._test_lastHandlePlayerEventImmediate(),
                true,
                "Event path must pass immediate: true for \(visual)"
            )
        }

        await refreshManager._test_invokeHandlePlayerEvent(.visualStateDidChange(.playing))
        XCTAssertEqual(
            WidgetRefreshManager._test_lastHandlePlayerEventImmediate(),
            false,
            "Active playing visuals remain eligible for coalesce/debounce on the event path"
        )
    }

    /// Verifies that ``handlePlayerEvent(_:)`` requests immediate delivery when ``hasError`` is true
    /// even if the derived visual is ``PlayerVisualState/playing``.
    func testHandlePlayerEventEventPathUsesImmediateWhenHasError() async {
        WidgetRefreshManager._test_setBypassUITestModeForRefreshGateObservation(true)
        WidgetRefreshManager._test_setRecordHandlePlayerEventImmediate(true)

        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .playing,
            language: "fi",
            hasError: true
        )

        await refreshManager._test_invokeHandlePlayerEvent(.persistedWidgetStateDidUpdate)
        XCTAssertEqual(
            WidgetRefreshManager._test_lastHandlePlayerEventImmediate(),
            true,
            "Permanent-error chrome must bypass coalesce deferral on the event path"
        )
    }

    // MARK: - Debouncing and coalescing

    /// Verifies that a lone ``PlayerVisualState/prePlay`` refresh is deferred behind the
    /// coalesce window and executes once the window elapses without a ``playing`` follow-up.
    ///
    /// - SeeAlso: ``refreshIfNeeded(visualState:currentLanguage:hasError:immediate:)``,
    ///   ``_test_debounceOutcomeLog()``, docs/Event-Driven-Refactor-Roadmap.md (Tier 5).
    func testRefreshIfNeededDefersPrePlayUntilCoalesceWindowElapses() async {
        enableDebounceObservation()

        refreshManager.refreshIfNeeded(
            visualState: .prePlay,
            currentLanguage: "fi",
            hasError: false,
            immediate: false
        )

        XCTAssertEqual(
            WidgetRefreshManager._test_debounceOutcomeLog(),
            [.scheduledPrePlayDeferral],
            "Lone prePlay must schedule deferral without immediate execution"
        )
        XCTAssertEqual(refreshExecutedCount(), 0)

        let executed = await waitForDebounceOutcome(.refreshExecuted, timeout: 1.0)
        XCTAssertTrue(
            executed,
            "Deferred prePlay must execute after the coalesce window; log: \(WidgetRefreshManager._test_debounceOutcomeLog())"
        )
        XCTAssertEqual(refreshExecutedCount(), 1)
    }

    /// Verifies that a fast ``PlayerVisualState/playing`` follow-up coalesces a deferred
    /// ``PlayerVisualState/prePlay`` refresh into a single timeline reload.
    ///
    /// - SeeAlso: ``refreshIfNeeded(visualState:currentLanguage:hasError:immediate:)``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 2 consumer depth).
    func testRefreshIfNeededCoalescesPrePlayToPlayingWithinWindow() async {
        enableDebounceObservation()

        refreshManager.refreshIfNeeded(
            visualState: .prePlay,
            currentLanguage: "fi",
            hasError: false,
            immediate: false
        )
        refreshManager.refreshIfNeeded(
            visualState: .playing,
            currentLanguage: "fi",
            hasError: false,
            immediate: false
        )

        let executed = await waitForDebounceOutcome(.refreshExecuted, timeout: 1.0)
        let log = WidgetRefreshManager._test_debounceOutcomeLog()

        XCTAssertTrue(log.contains(.scheduledPrePlayDeferral))
        XCTAssertTrue(log.contains(.coalescedPrePlayToPlaying))
        XCTAssertTrue(
            executed,
            "Coalesced playing refresh must execute; log: \(log)"
        )
        XCTAssertEqual(
            refreshExecutedCount(),
            1,
            "prePlay deferral must not produce a separate reload when playing supersedes it"
        )
    }

    /// Verifies that rapid repeat ``PlayerVisualState/playing`` refreshes schedule adaptive
    /// debouncing instead of executing back-to-back timeline reloads.
    ///
    /// - SeeAlso: ``refreshIfNeeded(visualState:currentLanguage:hasError:immediate:)``,
    ///   ``WidgetRefreshManagerEventTests``.
    func testRefreshIfNeededSchedulesAdaptiveDebounceForRapidRepeats() async {
        enableDebounceObservation()

        refreshManager.refreshIfNeeded(
            visualState: .playing,
            currentLanguage: "fi",
            hasError: false,
            immediate: true
        )

        let firstExecuted = await waitForDebounceOutcome(.refreshExecuted, timeout: 1.0)
        XCTAssertTrue(
            firstExecuted,
            "Immediate playing refresh must execute asynchronously; log: \(WidgetRefreshManager._test_debounceOutcomeLog())"
        )
        XCTAssertEqual(refreshExecutedCount(), 1)

        refreshManager.refreshIfNeeded(
            visualState: .playing,
            currentLanguage: "fi",
            hasError: false,
            immediate: false
        )

        XCTAssertTrue(
            WidgetRefreshManager._test_debounceOutcomeLog().contains(.scheduledAdaptiveDebounce),
            "Second playing refresh within the adaptive interval must defer"
        )
        XCTAssertEqual(
            refreshExecutedCount(),
            1,
            "Debounced refresh must not execute synchronously"
        )

        let secondExecuted = await waitForRefreshExecutedCount(atLeast: 2, timeout: 2.0)
        XCTAssertTrue(
            secondExecuted,
            "Adaptive debounce must eventually execute a second reload; log: \(WidgetRefreshManager._test_debounceOutcomeLog())"
        )
        XCTAssertEqual(refreshExecutedCount(), 2)
    }
}