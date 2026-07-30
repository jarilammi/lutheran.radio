//
//  WidgetRefreshManagerEventTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 7.7.2026.
//

import XCTest
import WidgetSurface
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
/// Live Activity sanitization uses shared ``sanitizeLiveActivityLocalState()`` from
/// `Lutheran RadioTests/Support/PlayerEventTestSupport.swift`.
///
/// - SeeAlso: ``WidgetRefreshManager/handlePlayerEvent(_:)``,
///   ``WidgetRefreshManager/_test_deriveRefreshParameters(for:)``,
///   ``WidgetRefreshManager/_test_invokeHandlePlayerEvent(_:)``,
///   ``WidgetRefreshManager/_test_refreshIfNeededGateOutcomeLog()``,
///   ``SharedPlayerManager/persistWidgetSnapshot(visualState:language:streamMetadata:clearStreamMetadata:hasError:)``,
///   ``SharedPlayerManagerEventTests``, `PlayerEventTestSupport.swift`,
///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5),
///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
@MainActor
final class WidgetRefreshManagerEventTests: XCTestCase {

    private let refreshManager = WidgetRefreshManager.shared
    private let manager = SharedPlayerManager.shared

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()

        // Suspend before clear so teardown emissions cannot re-persist a snapshot mid-setUp.
        sanitizeLiveActivityLocalState()
        refreshManager._test_suspendPlayerEventObservation()
        WidgetRefreshManager._test_setSuppressPlayerEventObservation(true)

        await SharedPlayerManager.clearAllLocalState()
        await manager.cancelReplayForwarding()

        WidgetRefreshManager.setHasActiveLutheranWidgets(true)
        WidgetRefreshManager._test_setRecordHandlePlayerEventDerivation(true)
    }

    override func tearDown() async throws {
        refreshManager._test_suspendPlayerEventObservation()
        WidgetRefreshManager._test_setSuppressPlayerEventObservation(true)
        WidgetRefreshManager.setSessionTeardownInProgress(false)
        WidgetRefreshManager._test_setBypassUITestModeForRefreshGateObservation(false)
        WidgetRefreshManager._test_setRecordRefreshIfNeededGateOutcomes(false)
        WidgetRefreshManager._test_setRecordHandlePlayerEventDerivation(false)
        WidgetRefreshManager._test_setRecordHandlePlayerEventImmediate(false)
        WidgetRefreshManager._test_setBypassUITestModeForDebounceObservation(false)
        WidgetRefreshManager._test_setRecordDebounceOutcomes(false)
        WidgetRefreshManager._test_setRecordDualRefreshTriggers(false)
        WidgetRefreshManager._test_setHardAssertOnDualRefreshTrigger(false)
        WidgetRefreshManager._test_resetRefreshTriggerObservationState()
        sanitizeLiveActivityLocalState()

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

    /// Under no home widgets, ``preferredWidgetLanguage()`` / ``loadSharedState()`` hard-default
    /// to `"en"`. Refresh derivation must still report stream-attach language so coalesce
    /// diagnostics (`lang:`) match the playing stream, not the privacy default.
    ///
    /// **Invariant protected:** privacy write suppression remains closed; only the language
    /// label for ``WidgetRefreshManager`` bookkeeping uses content-push / stream-attach SSOT.
    ///
    /// - SeeAlso: ``SharedPlayerManager/languageForWidgetRefreshDerivation(fallbackLanguage:)``,
    ///   ``SharedPlayerManager/preferredWidgetLanguage()``,
    ///   ``WidgetRefreshManager/deriveRefreshParameters(for:)``.
    func testDeriveRefreshParametersTracksStreamAttachWhenSnapshotAbsentUnderNoWidgets() async {
        await SharedPlayerManager.clearAllLocalState()
        SharedPlayerManager.clearLiveActivityLanguageMirror()
        await MainActor.run {
            WidgetRefreshManager.setHasActiveLutheranWidgets(false)
            WidgetRefreshManager._test_setSuppressPlayerEventObservation(true)
        }
        XCTAssertNil(SharedPlayerManager.loadPersistedWidgetState())
        XCTAssertEqual(
            SharedPlayerManager.preferredWidgetLanguage(),
            "en",
            "Precondition: no-widgets preferred path must still hard-default to en"
        )

        let streams = manager.availableStreams
        guard let estonian = streams.first(where: { $0.languageCode == "et" }) else {
            XCTFail("Expected Estonian stream in catalog")
            return
        }
        await manager.switchToStream(estonian)

        let derived = refreshManager._test_deriveRefreshParameters(
            for: .visualStateDidChange(.playing)
        )

        XCTAssertEqual(derived.visualState, .playing)
        XCTAssertEqual(
            derived.currentLanguage,
            "et",
            "No-snapshot privacy path must label refresh derivation with stream attach language, not hard-default en"
        )
    }

    /// Session snapshot language remains the top precedence for refresh derivation when present.
    func testDeriveRefreshParametersPrefersSnapshotLanguageOverStreamAttach() async {
        let streams = manager.availableStreams
        guard let german = streams.first(where: { $0.languageCode == "de" }) else {
            XCTFail("Expected German stream in catalog")
            return
        }
        await manager.switchToStream(german)

        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .playing,
            language: "fi",
            hasError: false
        )

        let derived = refreshManager._test_deriveRefreshParameters(
            for: .visualStateDidChange(.playing)
        )

        XCTAssertEqual(
            derived.currentLanguage,
            "fi",
            "In-process snapshot must outrank stream attach for refresh derivation"
        )
    }

    /// Imperative ``refreshIfNeeded`` re-resolves a privacy hard-default `"en"` caller language
    /// to stream attach before coalesce bookkeeping / DEBUG labels consume it.
    ///
    /// - SeeAlso: ``SharedPlayerManager/languageForWidgetRefreshDerivation(fallbackLanguage:)``,
    ///   ``WidgetRefreshManager/refreshIfNeeded(visualState:currentLanguage:hasError:immediate:trigger:)``.
    func testRefreshIfNeededResolvesPrivacyHardDefaultCallerLanguageViaStreamAttach() async {
        await SharedPlayerManager.clearAllLocalState()
        SharedPlayerManager.clearLiveActivityLanguageMirror()
        await MainActor.run {
            WidgetRefreshManager.setHasActiveLutheranWidgets(false)
            WidgetRefreshManager._test_setSuppressPlayerEventObservation(true)
        }

        let streams = manager.availableStreams
        guard let german = streams.first(where: { $0.languageCode == "de" }) else {
            XCTFail("Expected German stream in catalog")
            return
        }
        await manager.switchToStream(german)

        enableDebounceObservation()

        refreshManager.refreshIfNeeded(
            visualState: .playing,
            currentLanguage: "en",
            hasError: false,
            immediate: true,
            trigger: .test
        )

        let executed = await waitForDebounceOutcome(.refreshExecuted, timeout: 1.0)
        XCTAssertTrue(
            executed,
            "Immediate playing refresh must execute under debounce observation; log: \(WidgetRefreshManager._test_debounceOutcomeLog())"
        )
        XCTAssertEqual(
            refreshManager.lastKnownState?.currentLanguage,
            "de",
            "Caller privacy hard-default en must not stick in refresh bookkeeping while stream attach is de"
        )
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

    /// Verifies that ``handlePlayerEvent(_:)`` passes `immediate: true` for sticky pause/lock
    /// and factory-reset ``.cleared``, while Connecting ``.prePlay`` stays non-immediate so the
    /// ``.prePlay`` → ``.playing`` coalesce can supersede soft-resume connecting paints.
    ///
    /// - SeeAlso: ``handlePlayerEvent(_:)``,
    ///   ``WidgetRefreshManager/refreshUsesImmediateDelivery(for:hasError:)``,
    ///   ``WidgetRefreshManager/_test_lastHandlePlayerEventImmediate()``,
    ///   docs/Widget-Functionality-Roadmap.md (Tier 3), docs/Event-Driven-Refactor-Roadmap.md (Tier 5),
    ///   docs/Widget-Presentation-Dataflow.md (home soft-resume refresh authority).
    func testHandlePlayerEventEventPathUsesImmediateForPrePlayAndCleared() async {
        WidgetRefreshManager._test_setBypassUITestModeForRefreshGateObservation(true)
        WidgetRefreshManager._test_setRecordHandlePlayerEventImmediate(true)

        // Sticky / factory-reset / policy chrome: immediate (must not wait behind debounce).
        let immediateVisuals: [PlayerVisualState] = [
            .cleared, .userPaused, .thermalPaused, .securityLocked
        ]
        for visual in immediateVisuals {
            await refreshManager._test_invokeHandlePlayerEvent(.visualStateDidChange(visual))
            XCTAssertEqual(
                WidgetRefreshManager._test_lastHandlePlayerEventImmediate(),
                true,
                "Event path must pass immediate: true for \(visual)"
            )
        }

        // Connecting participates in prePlay→playing coalesce (soft-resume home honesty).
        await refreshManager._test_invokeHandlePlayerEvent(.visualStateDidChange(.prePlay))
        XCTAssertEqual(
            WidgetRefreshManager._test_lastHandlePlayerEventImmediate(),
            false,
            "Connecting .prePlay must defer so soft-resume .playing can supersede it"
        )

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

    // MARK: - Dual-path trigger inventory

    /// Verifies soft dual-fire observation records event+imperative pairs within the
    /// dual-trigger window without treating dual fire as a product failure.
    ///
    /// Protects the dual-path inventory contract: lifecycle (imperative) and
    /// ``playerEvent`` (mutation) both reach ``refreshIfNeeded``; close succession is
    /// expected and only soft-logged. Hard assert remains opt-in and disabled here.
    ///
    /// - SeeAlso: ``WidgetRefreshTrigger``, ``WidgetRefreshManager/DualRefreshTriggerObservation``,
    ///   ``WidgetRefreshManager/_test_dualRefreshTriggerLog()``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (dual-path inventory).
    func testDualRefreshTriggerObservationRecordsEventAndImperativePair() async {
        WidgetRefreshManager._test_resetRefreshTriggerObservationState()
        WidgetRefreshManager._test_setRecordDualRefreshTriggers(true)
        WidgetRefreshManager._test_setHardAssertOnDualRefreshTrigger(false)
        enableRefreshGateObservation()

        // Seed previous trigger as event family.
        refreshManager.refreshIfNeeded(
            visualState: .userPaused,
            currentLanguage: "fi",
            hasError: false,
            immediate: true,
            trigger: .playerEvent
        )
        // Immediate imperative lifecycle follow-up within the dual-fire window.
        refreshManager.refreshIfNeeded(
            visualState: .userPaused,
            currentLanguage: "fi",
            hasError: false,
            immediate: true,
            trigger: .lifecycle
        )

        let log = WidgetRefreshManager._test_dualRefreshTriggerLog()
        XCTAssertEqual(log.count, 1, "Expected one dual-fire observation; log: \(log)")
        XCTAssertEqual(log.first?.previous, .playerEvent)
        XCTAssertEqual(log.first?.current, .lifecycle)
        XCTAssertLessThanOrEqual(log.first?.intervalSeconds ?? 1, 0.15)
    }

    /// Verifies same-family back-to-back refreshes do not produce dual-fire observations.
    ///
    /// Debounce/coalesce may still run; dual-fire inventory only cares about event vs
    /// imperative family crossings.
    ///
    /// - SeeAlso: ``WidgetRefreshTrigger/pathFamily``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (dual-path inventory).
    func testSameFamilyRefreshTriggersDoNotRecordDualFire() async {
        WidgetRefreshManager._test_resetRefreshTriggerObservationState()
        WidgetRefreshManager._test_setRecordDualRefreshTriggers(true)
        enableRefreshGateObservation()

        refreshManager.refreshIfNeeded(
            visualState: .playing,
            currentLanguage: "en",
            hasError: false,
            immediate: true,
            trigger: .teardown
        )
        refreshManager.refreshIfNeeded(
            visualState: .prePlay,
            currentLanguage: "en",
            hasError: false,
            immediate: true,
            trigger: .lifecycle
        )

        XCTAssertTrue(
            WidgetRefreshManager._test_dualRefreshTriggerLog().isEmpty,
            "Imperative→imperative must not record dual-fire; log: \(WidgetRefreshManager._test_dualRefreshTriggerLog())"
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

    /// Soft-resume home honesty: event-path Connecting then authoritative playing must not
    /// execute a separate post-audible ``.prePlay`` timeline reload.
    ///
    /// Drives ``refreshIfNeeded`` with the same `immediate` flags
    /// ``refreshUsesImmediateDelivery(for:hasError:)`` would supply on the Tier 2 observer
    /// (Connecting non-immediate, playing non-immediate). Playing supersedes the deferred
    /// Connecting reload so soft-resume paints a single authoritative playing chrome.
    ///
    /// - SeeAlso: ``refreshUsesImmediateDelivery(for:hasError:)``,
    ///   ``refreshIfNeeded(visualState:currentLanguage:hasError:immediate:trigger:)``,
    ///   docs/Widget-Presentation-Dataflow.md (home soft-resume refresh authority).
    func testEventPathSoftResumePrePlayIsSupersededByAuthoritativePlaying() async {
        enableDebounceObservation()

        let prePlayImmediate = refreshManager.refreshUsesImmediateDelivery(
            for: .prePlay,
            hasError: false
        )
        let playingImmediate = refreshManager.refreshUsesImmediateDelivery(
            for: .playing,
            hasError: false
        )
        XCTAssertFalse(prePlayImmediate, "Event-path Connecting must not force immediate delivery")
        XCTAssertFalse(playingImmediate, "Playing remains eligible for coalesce/debounce")

        refreshManager.refreshIfNeeded(
            visualState: .prePlay,
            currentLanguage: "de",
            hasError: false,
            immediate: prePlayImmediate,
            trigger: .playerEvent
        )
        XCTAssertTrue(
            WidgetRefreshManager._test_debounceOutcomeLog().contains(.scheduledPrePlayDeferral),
            "Event-path prePlay must enter the coalesce deferral window"
        )
        XCTAssertEqual(refreshExecutedCount(), 0, "Deferred prePlay must not execute before playing")

        refreshManager.refreshIfNeeded(
            visualState: .playing,
            currentLanguage: "de",
            hasError: false,
            immediate: playingImmediate,
            trigger: .playerEvent
        )

        let executed = await waitForDebounceOutcome(.refreshExecuted, timeout: 1.0)
        let log = WidgetRefreshManager._test_debounceOutcomeLog()

        XCTAssertTrue(
            executed,
            "Authoritative playing must execute; log: \(log)"
        )
        XCTAssertTrue(
            log.contains(.coalescedPrePlayToPlaying),
            "Playing must supersede deferred Connecting; log: \(log)"
        )
        XCTAssertEqual(
            refreshExecutedCount(),
            1,
            "Soft-resume must produce a single home reload (playing), not prePlay then playing; log: \(log)"
        )
    }

    /// Pure policy: Connecting is never event-path immediate; sticky/clear/error are.
    ///
    /// - SeeAlso: ``WidgetRefreshManager/refreshUsesImmediateDelivery(for:hasError:)``.
    func testRefreshUsesImmediateDeliveryPolicyForConnectingVersusSticky() {
        XCTAssertFalse(
            refreshManager.refreshUsesImmediateDelivery(for: .prePlay, hasError: false),
            "Connecting must defer for soft-resume coalesce"
        )
        XCTAssertFalse(
            refreshManager.refreshUsesImmediateDelivery(for: .playing, hasError: false)
        )
        XCTAssertTrue(refreshManager.refreshUsesImmediateDelivery(for: .cleared, hasError: false))
        XCTAssertTrue(refreshManager.refreshUsesImmediateDelivery(for: .userPaused, hasError: false))
        XCTAssertTrue(refreshManager.refreshUsesImmediateDelivery(for: .thermalPaused, hasError: false))
        XCTAssertTrue(refreshManager.refreshUsesImmediateDelivery(for: .securityLocked, hasError: false))
        XCTAssertTrue(
            refreshManager.refreshUsesImmediateDelivery(for: .prePlay, hasError: true),
            "Permanent-error chrome always immediate"
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

    // MARK: - Identical non-playing coalesce (attach / dual-path storm)

    /// Pure policy: identical connecting and sticky visuals coalesce; playing and language/error
    /// mismatches never coalesce.
    ///
    /// Protects attach-path storm collapse without requiring WidgetCenter IPC.
    ///
    /// - SeeAlso: ``WidgetRefreshManager/shouldCoalesceIdenticalNonPlayingRefresh(requestedVisual:lastKnownVisual:languageUnchanged:errorFlagsMatch:hasError:)``.
    func testShouldCoalesceIdenticalNonPlayingRefreshPolicy() {
        let coalesceCases: [PlayerVisualState] = [
            .prePlay, .cleared, .userPaused, .thermalPaused, .securityLocked
        ]
        for visual in coalesceCases {
            XCTAssertTrue(
                WidgetRefreshManager.shouldCoalesceIdenticalNonPlayingRefresh(
                    requestedVisual: visual,
                    lastKnownVisual: visual,
                    languageUnchanged: true,
                    errorFlagsMatch: true,
                    hasError: false
                ),
                "Identical \(visual) must coalesce when language and error flags match"
            )
        }

        XCTAssertFalse(
            WidgetRefreshManager.shouldCoalesceIdenticalNonPlayingRefresh(
                requestedVisual: .playing,
                lastKnownVisual: .playing,
                languageUnchanged: true,
                errorFlagsMatch: true,
                hasError: false
            ),
            "Playing is rate-limited by adaptive debounce, not identity skip"
        )
        XCTAssertFalse(
            WidgetRefreshManager.shouldCoalesceIdenticalNonPlayingRefresh(
                requestedVisual: .prePlay,
                lastKnownVisual: nil,
                languageUnchanged: true,
                errorFlagsMatch: true,
                hasError: false
            ),
            "First connecting refresh must execute when lastKnown is absent"
        )
        XCTAssertFalse(
            WidgetRefreshManager.shouldCoalesceIdenticalNonPlayingRefresh(
                requestedVisual: .prePlay,
                lastKnownVisual: .prePlay,
                languageUnchanged: false,
                errorFlagsMatch: true,
                hasError: false
            ),
            "Language change must never identity-coalesce"
        )
        XCTAssertFalse(
            WidgetRefreshManager.shouldCoalesceIdenticalNonPlayingRefresh(
                requestedVisual: .userPaused,
                lastKnownVisual: .userPaused,
                languageUnchanged: true,
                errorFlagsMatch: true,
                hasError: true
            ),
            "Permanent-error chrome must not be identity-coalesced away"
        )
        XCTAssertFalse(
            WidgetRefreshManager.shouldCoalesceIdenticalNonPlayingRefresh(
                requestedVisual: .prePlay,
                lastKnownVisual: .userPaused,
                languageUnchanged: true,
                errorFlagsMatch: true,
                hasError: false
            ),
            "Visual transition must not identity-coalesce"
        )
    }

    /// Pure policy: delayed intermediate chrome regresses against a more advanced snapshot;
    /// matching visuals never regress. Sticky-pause regress is **directional**.
    ///
    /// - Non-immediate ``.userPaused`` vs persisted ``.playing`` is a regress (late pause lost
    ///   soft-resume race).
    /// - Immediate sticky-pause / teardown urgency against lagging ``.playing`` is **not** a
    ///   regress (forward stop; session snapshot may lag until early sticky write).
    ///
    /// Stale debounced discards are intentional — timeline reload cannot invent snapshot fields.
    ///
    /// - SeeAlso: ``WidgetRefreshManager/refreshWouldRegressPersistedSnapshot(executing:persisted:isImmediate:)``.
    func testRefreshWouldRegressPersistedSnapshotPolicy() {
        XCTAssertFalse(
            WidgetRefreshManager.refreshWouldRegressPersistedSnapshot(
                executing: .playing,
                persisted: .playing
            )
        )
        XCTAssertTrue(
            WidgetRefreshManager.refreshWouldRegressPersistedSnapshot(
                executing: .prePlay,
                persisted: .playing
            ),
            "Connecting chrome after play accepted is stale"
        )
        // Reverse soft-resume race: delayed/non-immediate pause after play already persisted.
        XCTAssertTrue(
            WidgetRefreshManager.refreshWouldRegressPersistedSnapshot(
                executing: .userPaused,
                persisted: .playing,
                isImmediate: false
            ),
            "Non-immediate pause after soft-resume to playing is stale"
        )
        XCTAssertTrue(
            WidgetRefreshManager.refreshWouldRegressPersistedSnapshot(
                executing: .userPaused,
                persisted: .playing
            ),
            "Default (non-immediate) pause vs playing remains a regress for soft-resume safety"
        )
        // Forward sticky pause: immediate urgency must not discard solely because snapshot lags.
        XCTAssertFalse(
            WidgetRefreshManager.refreshWouldRegressPersistedSnapshot(
                executing: .userPaused,
                persisted: .playing,
                isImmediate: true
            ),
            "Immediate sticky pause against lagging playing must execute (forward stop)"
        )
        XCTAssertFalse(
            WidgetRefreshManager.refreshWouldRegressPersistedSnapshot(
                executing: .thermalPaused,
                persisted: .playing,
                isImmediate: true
            ),
            "Immediate thermal pause against lagging playing must execute"
        )
        XCTAssertTrue(
            WidgetRefreshManager.refreshWouldRegressPersistedSnapshot(
                executing: .thermalPaused,
                persisted: .playing,
                isImmediate: false
            ),
            "Delayed thermal pause after playing is stale"
        )
        XCTAssertTrue(
            WidgetRefreshManager.refreshWouldRegressPersistedSnapshot(
                executing: .prePlay,
                persisted: .userPaused
            ),
            "Connecting chrome after sticky pause is stale"
        )
        XCTAssertTrue(
            WidgetRefreshManager.refreshWouldRegressPersistedSnapshot(
                executing: .playing,
                persisted: .userPaused
            ),
            "Playing must not reverse sticky pause via delayed refresh"
        )
        XCTAssertFalse(
            WidgetRefreshManager.refreshWouldRegressPersistedSnapshot(
                executing: .playing,
                persisted: .prePlay
            ),
            "Playing may advance connecting chrome"
        )
        XCTAssertFalse(
            WidgetRefreshManager.refreshWouldRegressPersistedSnapshot(
                executing: .userPaused,
                persisted: .prePlay
            ),
            "Sticky pause may advance connecting chrome"
        )
    }

    /// After sticky pause locks and the early sticky session snapshot is written, non-carried
    /// ``streamDidStop`` must derive ``.userPaused`` — never lagging ``.playing``.
    ///
    /// - SeeAlso: ``SharedPlayerManager/persistEarlyStickyUserPausedSnapshotIfPrivacyAllows()``,
    ///   ``WidgetRefreshManager/deriveRefreshParameters(for:)``.
    func testDeriveStreamDidStopUsesStickyUserPausedAfterEarlyStickySnapshot() async {
        WidgetRefreshManager.setHasActiveLutheranWidgets(true)
        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .playing,
            language: "de",
            hasError: false
        )
        XCTAssertEqual(
            SharedPlayerManager.loadPersistedWidgetState()?.visualState,
            .playing,
            "Precondition: session snapshot starts as playing"
        )

        await manager.setVisualState(.userPaused)
        await manager.persistEarlyStickyUserPausedSnapshotIfPrivacyAllows()

        XCTAssertEqual(
            SharedPlayerManager.loadPersistedWidgetState()?.visualState,
            .userPaused,
            "Early sticky write must advance session snapshot before non-carried events"
        )

        let derived = refreshManager._test_deriveRefreshParameters(for: .streamDidStop)
        XCTAssertEqual(
            derived.visualState,
            .userPaused,
            "streamDidStop must not re-derive .playing after sticky snapshot"
        )
        XCTAssertEqual(derived.currentLanguage, "de")
    }

    /// Event-path sticky pause honesty: with lagging session snapshot still ``.playing``,
    /// immediate ``.userPaused`` must execute (not discard); a later non-immediate pause
    /// against advanced ``.playing`` must still discard (soft-resume reverse race).
    ///
    /// Simulates the dual refresh-authority edges without WidgetCenter IPC.
    ///
    /// - SeeAlso: ``refreshWouldRegressPersistedSnapshot(executing:persisted:isImmediate:)``,
    ///   ``refreshIfNeeded(visualState:currentLanguage:hasError:immediate:trigger:)``.
    func testImmediateStickyPauseExecutesAgainstLaggingPlayingSnapshot() async {
        enableDebounceObservation()
        WidgetRefreshManager.setHasActiveLutheranWidgets(true)

        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .playing,
            language: "fi",
            hasError: false
        )

        // Forward stop: carried sticky visual is immediate (refreshUsesImmediateDelivery).
        let immediate = refreshManager.refreshUsesImmediateDelivery(
            for: .userPaused,
            hasError: false
        )
        XCTAssertTrue(immediate, "Sticky pause must request immediate delivery")

        refreshManager.refreshIfNeeded(
            visualState: .userPaused,
            currentLanguage: "fi",
            hasError: false,
            immediate: immediate,
            trigger: .playerEvent
        )

        let executed = await waitForDebounceOutcome(.refreshExecuted, timeout: 1.0)
        let log = WidgetRefreshManager._test_debounceOutcomeLog()
        XCTAssertTrue(executed, "Immediate sticky pause must execute; log: \(log)")
        XCTAssertFalse(
            log.contains(.discardedStaleDebouncedRegress),
            "Forward pause must not be discarded as stale vs lagging playing; log: \(log)"
        )
        XCTAssertEqual(
            refreshManager._test_lastKnownVisualState(),
            .userPaused,
            "Executed home target must be sticky pause, not playing"
        )
    }

    /// Soft-resume reverse race: non-immediate ``.userPaused`` after session snapshot advanced
    /// to ``.playing`` must discard at execute time (must not reverse authoritative playing).
    ///
    /// - SeeAlso: ``refreshWouldRegressPersistedSnapshot(executing:persisted:isImmediate:)``.
    func testDelayedUserPausedDiscardsWhenPersistedPlayingAfterSoftResume() async {
        enableDebounceObservation()
        WidgetRefreshManager.setHasActiveLutheranWidgets(true)

        // Establish a prior refresh so adaptive debounce will schedule the late pause.
        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .playing,
            language: "sv",
            hasError: false
        )
        refreshManager.refreshIfNeeded(
            visualState: .playing,
            currentLanguage: "sv",
            hasError: false,
            immediate: true,
            trigger: .playerEvent
        )
        let playingExecuted = await waitForDebounceOutcome(.refreshExecuted, timeout: 1.0)
        XCTAssertTrue(playingExecuted, "Precondition: playing refresh executes")
        XCTAssertEqual(refreshManager._test_lastKnownVisualState(), .playing)

        // Late non-immediate pause while disk still / again playing (soft-resume won).
        refreshManager.refreshIfNeeded(
            visualState: .userPaused,
            currentLanguage: "sv",
            hasError: false,
            immediate: false,
            trigger: .playerEvent
        )
        XCTAssertTrue(
            WidgetRefreshManager._test_debounceOutcomeLog().contains(.scheduledAdaptiveDebounce),
            "Non-immediate pause after recent refresh must schedule adaptive debounce"
        )

        let discarded = await waitForDebounceOutcome(
            .discardedStaleDebouncedRegress,
            timeout: 3.0
        )
        let log = WidgetRefreshManager._test_debounceOutcomeLog()
        XCTAssertTrue(
            discarded,
            "Delayed pause must discard when persisted snapshot is playing; log: \(log)"
        )
        XCTAssertEqual(
            refreshManager._test_lastKnownVisualState(),
            .playing,
            "Last executed visual must remain playing after discarded late pause"
        )
    }

    /// Full forward-pause refresh sequence after early sticky snapshot: non-carried
    /// ``streamDidStop`` and sticky carried visual never execute a ``.playing`` home target.
    ///
    /// - SeeAlso: ``persistEarlyStickyUserPausedSnapshotIfPrivacyAllows()``,
    ///   ``deriveRefreshParameters(for:)``,
    ///   ``refreshIfNeeded(visualState:currentLanguage:hasError:immediate:trigger:)``.
    func testStopEventPathDoesNotExecutePlayingAfterStickyUserPausedLock() async {
        enableDebounceObservation()
        WidgetRefreshManager.setHasActiveLutheranWidgets(true)

        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .playing,
            language: "de",
            hasError: false
        )

        // Memory + early sticky snapshot (production stop() order after sticky lock).
        await manager.setVisualState(.userPaused)
        await manager.persistEarlyStickyUserPausedSnapshotIfPrivacyAllows()
        XCTAssertEqual(
            SharedPlayerManager.loadPersistedWidgetState()?.visualState,
            .userPaused
        )

        // Carried visualStateDidChange(.userPaused) — immediate.
        refreshManager.refreshIfNeeded(
            visualState: .userPaused,
            currentLanguage: "de",
            hasError: false,
            immediate: true,
            trigger: .playerEvent
        )
        _ = await waitForDebounceOutcome(.refreshExecuted, timeout: 1.0)

        // Non-carried streamDidStop / playbackIntentChanged derive from session snapshot.
        let stopDerived = refreshManager._test_deriveRefreshParameters(for: .streamDidStop)
        let intentDerived = refreshManager._test_deriveRefreshParameters(
            for: .playbackIntentChanged(.userPaused)
        )
        XCTAssertEqual(stopDerived.visualState, .userPaused)
        XCTAssertEqual(intentDerived.visualState, .userPaused)

        refreshManager.refreshIfNeeded(
            visualState: stopDerived.visualState,
            currentLanguage: stopDerived.currentLanguage,
            hasError: stopDerived.hasError,
            immediate: refreshManager.refreshUsesImmediateDelivery(
                for: stopDerived.visualState,
                hasError: stopDerived.hasError
            ),
            trigger: .playerEvent
        )
        // Identical sticky may identity-coalesce; either way last known must stay userPaused.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(150))

        let log = WidgetRefreshManager._test_debounceOutcomeLog()
        XCTAssertEqual(
            refreshManager._test_lastKnownVisualState(),
            .userPaused,
            "Home execute target after sticky lock must settle on userPaused; log: \(log)"
        )
        XCTAssertNotEqual(
            refreshManager._test_lastKnownVisualState(),
            .playing,
            "Must not leave playing as last execute after sticky lock; log: \(log)"
        )
    }

    /// Privacy gate closed: early sticky snapshot must not create a session write.
    ///
    /// - SeeAlso: ``persistEarlyStickyUserPausedSnapshotIfPrivacyAllows()``.
    func testEarlyStickyUserPausedSnapshotSuppressedWhenPrivacyGateClosed() async {
        await SharedPlayerManager.clearAllLocalState()
        WidgetRefreshManager.setHasActiveLutheranWidgets(false)
        XCTAssertNil(SharedPlayerManager.loadPersistedWidgetState())

        await manager.setVisualState(.userPaused)
        await manager.persistEarlyStickyUserPausedSnapshotIfPrivacyAllows()

        XCTAssertNil(
            SharedPlayerManager.loadPersistedWidgetState(),
            "Early sticky write must not create a session snapshot while privacy gate is closed"
        )
    }

    /// Verifies that repeated immediate ``PlayerVisualState/prePlay`` refreshes (event-path
    /// urgency) collapse after the first execution so attach storms do not spam timelines.
    ///
    /// - SeeAlso: ``WidgetRefreshManager/shouldCoalesceIdenticalNonPlayingRefresh(requestedVisual:lastKnownVisual:languageUnchanged:errorFlagsMatch:hasError:)``,
    ///   ``refreshUsesImmediateDelivery(for:hasError:)``.
    func testRefreshIfNeededCoalescesIdenticalImmediatePrePlayAttachStorm() async {
        enableDebounceObservation()

        refreshManager.refreshIfNeeded(
            visualState: .prePlay,
            currentLanguage: "de",
            hasError: false,
            immediate: true,
            trigger: .playerEvent
        )

        let firstExecuted = await waitForDebounceOutcome(.refreshExecuted, timeout: 1.0)
        XCTAssertTrue(
            firstExecuted,
            "First immediate prePlay must execute (factory-reset / attach urgency)"
        )
        XCTAssertEqual(refreshExecutedCount(), 1)

        // Attach-path storm: many identical immediate prePlay callbacks.
        for _ in 0..<5 {
            refreshManager.refreshIfNeeded(
                visualState: .prePlay,
                currentLanguage: "de",
                hasError: false,
                immediate: true,
                trigger: .playerEvent
            )
        }

        let log = WidgetRefreshManager._test_debounceOutcomeLog()
        XCTAssertEqual(
            refreshExecutedCount(),
            1,
            "Identical immediate prePlay must not re-execute; log: \(log)"
        )
        XCTAssertEqual(
            log.filter { $0 == .coalescedIdenticalNonPlaying }.count,
            5,
            "Each storm callback must record identity coalesce; log: \(log)"
        )
    }

    /// Verifies sticky pause dual-path duplicates collapse after the first execution.
    ///
    /// Dual-path architecture (event + teardown hygiene) remains; only identical reloads drop.
    ///
    /// - SeeAlso: ``SharedPlayerManager/performPostStopWidgetHygiene()``,
    ///   ``WidgetRefreshTrigger``.
    func testRefreshIfNeededCoalescesIdenticalStickyUserPausedDualPath() async {
        enableDebounceObservation()

        refreshManager.refreshIfNeeded(
            visualState: .userPaused,
            currentLanguage: "fi",
            hasError: false,
            immediate: true,
            trigger: .playerEvent
        )
        let firstExecuted = await waitForDebounceOutcome(.refreshExecuted, timeout: 1.0)
        XCTAssertTrue(firstExecuted)

        refreshManager.refreshIfNeeded(
            visualState: .userPaused,
            currentLanguage: "fi",
            hasError: false,
            immediate: true,
            trigger: .teardown
        )

        let log = WidgetRefreshManager._test_debounceOutcomeLog()
        XCTAssertEqual(refreshExecutedCount(), 1, "Second sticky pause must not reload; log: \(log)")
        XCTAssertTrue(
            log.contains(.coalescedIdenticalNonPlaying),
            "Post-stop dual-path duplicate must identity-coalesce; log: \(log)"
        )
    }

    /// Verifies language change still forces a reload even when visual is identical connecting chrome.
    ///
    /// Snapshot language is the refresh-derivation SSOT under privacy re-resolution — seed it so
    /// caller hints are not collapsed to a hard-default when the engine stream is unset.
    func testRefreshIfNeededDoesNotCoalesceIdenticalPrePlayWhenLanguageChanges() async {
        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .prePlay,
            language: "sv",
            hasError: false
        )
        enableDebounceObservation()

        refreshManager.refreshIfNeeded(
            visualState: .prePlay,
            currentLanguage: "sv",
            hasError: false,
            immediate: true,
            trigger: .playerEvent
        )
        let firstExecuted = await waitForDebounceOutcome(.refreshExecuted, timeout: 1.0)
        XCTAssertTrue(firstExecuted)
        XCTAssertEqual(refreshExecutedCount(), 1)
        XCTAssertEqual(refreshManager.lastKnownState?.currentLanguage, "sv")

        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .prePlay,
            language: "de",
            hasError: false
        )
        refreshManager.refreshIfNeeded(
            visualState: .prePlay,
            currentLanguage: "de",
            hasError: false,
            immediate: true,
            trigger: .playerEvent
        )
        let secondExecuted = await waitForRefreshExecutedCount(atLeast: 2, timeout: 1.0)
        XCTAssertTrue(
            secondExecuted,
            "Language change must force a second reload; log: \(WidgetRefreshManager._test_debounceOutcomeLog())"
        )
        XCTAssertFalse(
            WidgetRefreshManager._test_debounceOutcomeLog().contains(.coalescedIdenticalNonPlaying),
            "Language urgency must not be identity-coalesced"
        )
        XCTAssertEqual(refreshManager.lastKnownState?.currentLanguage, "de")
    }

    /// Verifies non-immediate identical prePlay does not re-schedule deferral after lastKnown matches.
    func testRefreshIfNeededSkipsPrePlayDeferralWhenLastKnownAlreadyMatches() async {
        enableDebounceObservation()

        refreshManager.refreshIfNeeded(
            visualState: .prePlay,
            currentLanguage: "en",
            hasError: false,
            immediate: false
        )
        let executed = await waitForDebounceOutcome(.refreshExecuted, timeout: 1.0)
        XCTAssertTrue(executed)
        XCTAssertEqual(refreshExecutedCount(), 1)

        WidgetRefreshManager._test_clearDebounceOutcomeLog()

        refreshManager.refreshIfNeeded(
            visualState: .prePlay,
            currentLanguage: "en",
            hasError: false,
            immediate: false
        )

        let log = WidgetRefreshManager._test_debounceOutcomeLog()
        XCTAssertEqual(
            log,
            [.coalescedIdenticalNonPlaying],
            "Second non-immediate prePlay must identity-coalesce without re-deferral; log: \(log)"
        )
        XCTAssertEqual(refreshExecutedCount(), 0)
    }
}
