//
//  SharedPlayerManagerEventFailureTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 26.7.2026.
//
//  Stream-failure emission order and post-failure replay-prefix contracts.
//  Split from ``SharedPlayerManagerEventTests``; method names preserved.
//
//  Shared collectors: `Lutheran RadioTests/Support/PlayerEventTestSupport.swift`.
//  Isolation: ``prepareSharedPlayerManagerEventTestIsolation`` /
//  ``tearDownSharedPlayerManagerEventTestIsolation``.
//
//  - SeeAlso: ``SharedPlayerManager``, ``PlayerEvent``,
//    ``SharedPlayerManagerEventTests``,
//    docs/Event-Driven-Refactor-Roadmap.md,
//    CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
//

import MediaPlayer
import XCTest
import WidgetSurface
@testable import Lutheran_Radio

/// Failure-classification and post-failure replay-prefix contracts for `SharedPlayerManager`.
///
/// Covers `streamDidFail` payload fidelity (transient / security / permanent / unknown),
/// failure emission order with intent preservation, and Tier 3 replay prefixes after
/// failure and recovery. Core replay/live smoke lives in ``SharedPlayerManagerEventTests``.
///
/// - SeeAlso: ``SharedPlayerManagerEventTests``,
///   ``markPlaybackStoppedByStreamFailure(_:)``, `StreamErrorType`,
///   `PlayerEventTestSupport.swift`,
///   docs/Event-Driven-Refactor-Roadmap.md,
///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).

final class SharedPlayerManagerEventFailureTests: XCTestCase {

    private let manager = SharedPlayerManager.shared

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()
        await prepareSharedPlayerManagerEventTestIsolation(manager: manager)
    }

    override func tearDown() async throws {
        await tearDownSharedPlayerManagerEventTestIsolation(manager: manager)
        try await super.tearDown()
    }

    /// Verifies the canonical emission order and intent preservation for
    /// ``markPlaybackStoppedByStreamFailure(_:)``.
    ///
    /// Stream failure is distinct from explicit user pause or terminal stop:
    /// - Visual moves to grey `.userPaused` for error UI.
    /// - `playbackIntent` stays unchanged (typically `.shouldBePlaying`) so language
    ///   switches can auto-resume without an extra play tap.
    /// - The classified `streamDidFail` verb follows the visual mutation and precedes
    ///   the persisted snapshot signal when the privacy gate allows the write path.
    ///
    /// Consumers (`WidgetRefreshManager`, main-app chrome observation) rely on this ordering
    /// and on the absence of `playbackIntentChanged` during failure recovery paths.
    ///
    /// Collection uses the DEBUG notification seam (same rationale as the `stop()` order
    /// test) so assertions are not subject to AsyncStream iterator attach races.
    ///
    /// - SeeAlso: ``markPlaybackStoppedByStreamFailure(_:)``, ``emit(_:)``,
    ///   `PlayerEvent.streamDidFail`, ``currentPlaybackIntent``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5 emission order),
    ///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
    func testStreamFailureEmissionOrderPreservesIntentAndMutationSequence() async {
        // setUp established .shouldBePlaying intent (via setUserIntentToPlay).
        let intentBefore = await manager.currentPlaybackIntent
        XCTAssertEqual(
            intentBefore,
            .shouldBePlaying,
            "Precondition: failure path tests intent preservation from an active-play intent"
        )

        let m = self.manager
        let liveEmissions = await collectSeamEvents(minimumCount: 2, timeout: 5.0) {
            await m.markPlaybackStoppedByStreamFailure(.transientFailure)
        }

        assertEvents(liveEmissions, containInOrder: [
            { if case .visualStateDidChange(.userPaused) = $0 { return true }; return false },
            { if case .streamDidFail(.transientFailure) = $0 { return true }; return false },
        ])
        XCTAssertTrue(
            liveEmissions.contains(.persistedWidgetStateDidUpdate),
            "Failure path should emit .persistedWidgetStateDidUpdate when the write path runs; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .playbackIntentChanged = $0 { return true }; return false },
            "Stream failure must not emit playbackIntentChanged — intent stays \(intentBefore); got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidPause = $0 { return true }; return false },
            "Stream failure must emit streamDidFail, not streamDidPause; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidStop = $0 { return true }; return false },
            "Stream failure must emit streamDidFail, not streamDidStop; got: \(liveEmissions)"
        )

        let intentAfter = await manager.currentPlaybackIntent
        XCTAssertEqual(
            intentAfter,
            intentBefore,
            "playbackIntent must remain unchanged after stream failure (auto-resume contract)"
        )
    }

    /// Verifies that ``markPlaybackStoppedByStreamFailure(_:)`` emits
    /// `streamDidFail(.securityFailure)` with the exact classified payload.
    ///
    /// Hard security failures (certificate pinning rejection, untrusted leaf, DNS security
    /// model mismatch surfaced as `URLError.secureConnectionFailed` / `serverCertificateUntrusted`)
    /// are classified in `StreamErrorType.from(error:)` as
    /// `.securityFailure`. That value is never auto-retried (`isPermanent == true`) and
    /// drives a distinct localized status string. Consumers must receive the precise
    /// discriminator — not a generic fail verb — to gate recovery UI and widget error state.
    ///
    /// The transient-failure emission-order test proves the mutation subsequence for
    /// `.transientFailure`. This test closes the `StreamErrorType` classification gap for
    /// the security branch: the authoritative emitter forwards the player's classification
    /// verbatim in the `streamDidFail` associated value.
    ///
    /// Collection uses the DEBUG notification seam (same rationale as the other
    /// emission-order tests).
    ///
    /// - SeeAlso: ``markPlaybackStoppedByStreamFailure(_:)``, ``emit(_:)``,
    ///   `PlayerEvent.streamDidFail`, `StreamErrorType`,
    ///   `StreamErrorType.from(error:)`,
    ///   ``testStreamFailureEmissionOrderPreservesIntentAndMutationSequence``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5),
    ///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
    func testSecurityFailureStreamDidFailPayloadIsFaithfullyEmitted() async {
        let intentBefore = await manager.currentPlaybackIntent
        XCTAssertEqual(
            intentBefore,
            .shouldBePlaying,
            "Precondition: security failure path preserves intent from an active-play intent"
        )

        let m = self.manager
        let liveEmissions = await collectSeamEvents(minimumCount: 2, timeout: 5.0) {
            await m.markPlaybackStoppedByStreamFailure(.securityFailure)
        }

        assertEvents(liveEmissions, containInOrder: [
            { if case .visualStateDidChange(.userPaused) = $0 { return true }; return false },
            { if case .streamDidFail(.securityFailure) = $0 { return true }; return false },
        ])
        XCTAssertTrue(
            liveEmissions.contains(.persistedWidgetStateDidUpdate),
            "Security failure path should emit .persistedWidgetStateDidUpdate when the write path runs; got: \(liveEmissions)"
        )

        let failPayloads = liveEmissions.compactMap { event -> StreamErrorType? in
            if case .streamDidFail(let errorType) = event { return errorType }
            return nil
        }
        XCTAssertEqual(
            failPayloads,
            [.securityFailure],
            "Exactly one streamDidFail emission with .securityFailure payload; got: \(failPayloads)"
        )
        XCTAssertFalse(
            failPayloads.contains(.transientFailure),
            "Security failure must not emit transientFailure classification; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            failPayloads.contains(.permanentFailure),
            "Security failure must not emit permanentFailure classification; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .playbackIntentChanged = $0 { return true }; return false },
            "Security failure must not emit playbackIntentChanged — intent stays \(intentBefore); got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidPause = $0 { return true }; return false },
            "Security failure must emit streamDidFail, not streamDidPause; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidStop = $0 { return true }; return false },
            "Security failure must emit streamDidFail, not streamDidStop; got: \(liveEmissions)"
        )

        let intentAfter = await manager.currentPlaybackIntent
        XCTAssertEqual(
            intentAfter,
            intentBefore,
            "playbackIntent must remain unchanged after security failure (distinct from sticky user pause)"
        )
    }

    /// Verifies that ``markPlaybackStoppedByStreamFailure(_:)`` emits
    /// `streamDidFail(.permanentFailure)` with the exact classified payload.
    ///
    /// Hard post-DNS stream failures (resource gone, TCP connect after successful name
    /// resolution, resource unavailable) are classified in
    /// `StreamErrorType.from(error:)` as `.permanentFailure`.
    /// That value is never auto-retried (`isPermanent == true`) and drives the
    /// `status_failed` localized status string. Consumers must receive the precise
    /// discriminator — not a generic fail verb or a security/transient
    /// misclassification — to gate recovery UI and widget error state.
    ///
    /// The transient-failure and security-failure emission-order tests prove the mutation
    /// subsequence for their respective branches. This test closes the `StreamErrorType`
    /// classification gap for the permanent branch: the authoritative emitter forwards
    /// the player's classification verbatim in the `streamDidFail` associated value.
    ///
    /// Collection uses the DEBUG notification seam (same rationale as the other
    /// emission-order tests).
    ///
    /// - SeeAlso: ``markPlaybackStoppedByStreamFailure(_:)``, ``emit(_:)``,
    ///   `PlayerEvent.streamDidFail`, `StreamErrorType`,
    ///   `StreamErrorType.from(error:)`,
    ///   ``testSecurityFailureStreamDidFailPayloadIsFaithfullyEmitted``,
    ///   ``testStreamFailureEmissionOrderPreservesIntentAndMutationSequence``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5),
    ///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
    func testPermanentFailureStreamDidFailPayloadIsFaithfullyEmitted() async {
        let intentBefore = await manager.currentPlaybackIntent
        XCTAssertEqual(
            intentBefore,
            .shouldBePlaying,
            "Precondition: permanent failure path preserves intent from an active-play intent"
        )

        let m = self.manager
        let liveEmissions = await collectSeamEvents(minimumCount: 2, timeout: 5.0) {
            await m.markPlaybackStoppedByStreamFailure(.permanentFailure)
        }

        assertEvents(liveEmissions, containInOrder: [
            { if case .visualStateDidChange(.userPaused) = $0 { return true }; return false },
            { if case .streamDidFail(.permanentFailure) = $0 { return true }; return false },
        ])
        XCTAssertTrue(
            liveEmissions.contains(.persistedWidgetStateDidUpdate),
            "Permanent failure path should emit .persistedWidgetStateDidUpdate when the write path runs; got: \(liveEmissions)"
        )

        let failPayloads = liveEmissions.compactMap { event -> StreamErrorType? in
            if case .streamDidFail(let errorType) = event { return errorType }
            return nil
        }
        XCTAssertEqual(
            failPayloads,
            [.permanentFailure],
            "Exactly one streamDidFail emission with .permanentFailure payload; got: \(failPayloads)"
        )
        XCTAssertFalse(
            failPayloads.contains(.securityFailure),
            "Permanent failure must not emit securityFailure classification; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            failPayloads.contains(.transientFailure),
            "Permanent failure must not emit transientFailure classification; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .playbackIntentChanged = $0 { return true }; return false },
            "Permanent failure must not emit playbackIntentChanged — intent stays \(intentBefore); got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidPause = $0 { return true }; return false },
            "Permanent failure must emit streamDidFail, not streamDidPause; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidStop = $0 { return true }; return false },
            "Permanent failure must emit streamDidFail, not streamDidStop; got: \(liveEmissions)"
        )

        let intentAfter = await manager.currentPlaybackIntent
        XCTAssertEqual(
            intentAfter,
            intentBefore,
            "playbackIntent must remain unchanged after permanent failure (distinct from sticky user pause)"
        )
    }

    /// Verifies that ``markPlaybackStoppedByStreamFailure(_:)`` emits
    /// `streamDidFail(.unknown)` with the exact classified payload.
    ///
    /// Unclassified errors (`StreamErrorType.from(error:)` when `error` is `nil`, or when
    /// the NSError domain/code does not match a known security, permanent, or transient
    /// branch) surface as `.unknown`. Recovery paths treat this conservatively as transient
    /// in early-window recreate logic, but the emitter must still forward the precise
    /// discriminator so consumers can distinguish unclassified failures from the other
    /// `StreamErrorType` cases.
    ///
    /// The transient-, security-, and permanent-failure emission tests prove the mutation
    /// subsequence for their respective branches. This test closes the final
    /// `StreamErrorType` classification gap: the authoritative emitter forwards the
    /// player's classification verbatim in the `streamDidFail` associated value.
    ///
    /// Collection uses the DEBUG notification seam (same rationale as the other
    /// emission-order tests).
    ///
    /// - SeeAlso: ``markPlaybackStoppedByStreamFailure(_:)``, ``emit(_:)``,
    ///   `PlayerEvent.streamDidFail`, `StreamErrorType`,
    ///   `StreamErrorType.from(error:)`,
    ///   ``testSecurityFailureStreamDidFailPayloadIsFaithfullyEmitted``,
    ///   ``testPermanentFailureStreamDidFailPayloadIsFaithfullyEmitted``,
    ///   ``testStreamFailureEmissionOrderPreservesIntentAndMutationSequence``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5),
    ///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
    func testUnknownStreamDidFailPayloadIsFaithfullyEmitted() async {
        let intentBefore = await manager.currentPlaybackIntent
        XCTAssertEqual(
            intentBefore,
            .shouldBePlaying,
            "Precondition: unknown failure path preserves intent from an active-play intent"
        )

        let m = self.manager
        let liveEmissions = await collectSeamEvents(minimumCount: 2, timeout: 5.0) {
            await m.markPlaybackStoppedByStreamFailure(.unknown)
        }

        assertEvents(liveEmissions, containInOrder: [
            { if case .visualStateDidChange(.userPaused) = $0 { return true }; return false },
            { if case .streamDidFail(.unknown) = $0 { return true }; return false },
        ])
        XCTAssertTrue(
            liveEmissions.contains(.persistedWidgetStateDidUpdate),
            "Unknown failure path should emit .persistedWidgetStateDidUpdate when the write path runs; got: \(liveEmissions)"
        )

        let failPayloads = liveEmissions.compactMap { event -> StreamErrorType? in
            if case .streamDidFail(let errorType) = event { return errorType }
            return nil
        }
        XCTAssertEqual(
            failPayloads,
            [.unknown],
            "Exactly one streamDidFail emission with .unknown payload; got: \(failPayloads)"
        )
        XCTAssertFalse(
            failPayloads.contains(.securityFailure),
            "Unknown failure must not emit securityFailure classification; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            failPayloads.contains(.transientFailure),
            "Unknown failure must not emit transientFailure classification; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            failPayloads.contains(.permanentFailure),
            "Unknown failure must not emit permanentFailure classification; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .playbackIntentChanged = $0 { return true }; return false },
            "Unknown failure must not emit playbackIntentChanged — intent stays \(intentBefore); got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidPause = $0 { return true }; return false },
            "Unknown failure must emit streamDidFail, not streamDidPause; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidStop = $0 { return true }; return false },
            "Unknown failure must emit streamDidFail, not streamDidStop; got: \(liveEmissions)"
        )

        let intentAfter = await manager.currentPlaybackIntent
        XCTAssertEqual(
            intentAfter,
            intentBefore,
            "playbackIntent must remain unchanged after unknown failure (auto-resume contract)"
        )
    }

    /// Verifies the Tier 3 replay prefix after ``markPlaybackStoppedByStreamFailure(_:)``
    /// and after subsequent recovery via ``setPlaying()``.
    ///
    /// Stream failure is visually identical to explicit pause (`.userPaused`) but
    /// **must not** flip `playbackIntent` to sticky `.userPaused`. Late subscribers
    /// (`WidgetEventObserver`, main-app chrome observation) initialize from the replay
    /// prefix — not from historical `streamDidFail` verbs — so the synthesized
    /// `.playbackIntentChanged` value is the contract that distinguishes auto-resume
    /// failure UI from sticky user pause.
    ///
    /// **Failure phase:** prefix carries `.userPaused` visual and `.shouldBePlaying`
    /// intent; `currentState.isBlockedByStickyIntent` is false.
    ///
    /// **Recovery phase:** after `setPlaying()`, a fresh replay stream prefix reflects
    /// `.playing` / `.shouldBePlaying` and `isActivelyPlaying == true`.
    ///
    /// Replay live-forwarding of recovery emissions on the first stream is best-effort
    /// only (same XCTest host attach-race caveat as the `stop()` replay test).
    ///
    /// - SeeAlso: ``markPlaybackStoppedByStreamFailure(_:)``, ``setPlaying()``,
    ///   ``makeEventsStreamWithReplay()``, ``currentState``, ``PlayerCurrentState``,
    ///   `PlayerCurrentState.isBlockedByStickyIntent`,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 3 error/recovery + Tier 5 late-subscriber),
    ///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
    func testReplayPrefixAfterStreamFailurePreservesIntentThenReflectsRecovery() async {
        let intentBefore = await manager.currentPlaybackIntent
        XCTAssertEqual(
            intentBefore,
            .shouldBePlaying,
            "Precondition: failure replay tests intent preservation from an active-play intent"
        )

        await manager.markPlaybackStoppedByStreamFailure(.transientFailure)

        let failureSnapshot = await manager.currentState
        XCTAssertEqual(failureSnapshot.visualState, .userPaused)
        XCTAssertEqual(
            failureSnapshot.playbackIntent,
            .shouldBePlaying,
            "Failure grey UI must not convert intent to sticky .userPaused"
        )
        XCTAssertFalse(
            failureSnapshot.isBlockedByStickyIntent,
            "Late subscribers must see recoverable failure (not sticky pause) via replay"
        )

        let replayStream = await manager.makeEventsStreamWithReplay()
        let m = self.manager

        let failurePrefix = await collectEvents(from: replayStream, count: 4, timeout: 2.0)
        guard failurePrefix.count == 4 else {
            XCTFail("Replay after failure must begin with four prefix events; got \(failurePrefix.count): \(failurePrefix)")
            return
        }

        guard case let .visualStateDidChange(prefixVisual) = failurePrefix[0] else {
            XCTFail("First replay event after failure must be .visualStateDidChange")
            return
        }
        XCTAssertEqual(prefixVisual, .userPaused)

        guard case let .playbackIntentChanged(prefixIntent) = failurePrefix[1] else {
            XCTFail("Second replay event after failure must be .playbackIntentChanged")
            return
        }
        XCTAssertEqual(
            prefixIntent,
            .shouldBePlaying,
            "Replay prefix must expose preserved intent, not sticky pause"
        )
        XCTAssertEqual(prefixIntent, failureSnapshot.playbackIntent)

        guard case let .metadataDidUpdate(prefixMetadata) = failurePrefix[2] else {
            XCTFail("Third replay event after failure must be .metadataDidUpdate")
            return
        }
        XCTAssertEqual(prefixMetadata, failureSnapshot.streamMetadata)

        XCTAssertEqual(
            failurePrefix[3],
            .persistedWidgetStateDidUpdate,
            "Fourth replay event after failure must be the persisted snapshot signal"
        )

        // Best-effort: drive recovery on the first replay stream so forwarding is exercised.
        // Attach races in the XCTest host may deliver only a trailing `.persistedWidgetStateDidUpdate`
        // (or nothing); recovery prefix assertions below are the primary contract (same pattern as
        // `testReplayStreamPrefixesStateThenForwardsLiveStopEmissionsInOrder`).
        _ = await collectEvents(from: replayStream, count: 1, timeout: 2.0) {
            await m.setPlaying()
        }

        let recoverySnapshot = await manager.currentState
        XCTAssertEqual(recoverySnapshot.visualState, .playing)
        XCTAssertEqual(recoverySnapshot.playbackIntent, .shouldBePlaying)
        XCTAssertTrue(recoverySnapshot.isActivelyPlaying)

        let recoveryReplay = await manager.makeEventsStreamWithReplay()
        let recoveryPrefix = await collectEvents(from: recoveryReplay, count: 4, timeout: 2.0)
        guard recoveryPrefix.count == 4 else {
            XCTFail("Replay after recovery must begin with four prefix events; got \(recoveryPrefix.count): \(recoveryPrefix)")
            return
        }

        guard case let .visualStateDidChange(recoveryVisual) = recoveryPrefix[0] else {
            XCTFail("First replay event after recovery must be .visualStateDidChange")
            return
        }
        XCTAssertEqual(recoveryVisual, .playing)
        XCTAssertEqual(recoveryVisual, recoverySnapshot.visualState)

        guard case let .playbackIntentChanged(recoveryIntent) = recoveryPrefix[1] else {
            XCTFail("Second replay event after recovery must be .playbackIntentChanged")
            return
        }
        XCTAssertEqual(recoveryIntent, .shouldBePlaying)
        XCTAssertEqual(recoveryIntent, recoverySnapshot.playbackIntent)

        guard case let .metadataDidUpdate(recoveryMetadata) = recoveryPrefix[2] else {
            XCTFail("Third replay event after recovery must be .metadataDidUpdate")
            return
        }
        XCTAssertEqual(recoveryMetadata, recoverySnapshot.streamMetadata)

        XCTAssertEqual(
            recoveryPrefix[3],
            .persistedWidgetStateDidUpdate,
            "Fourth replay event after recovery must be the persisted snapshot signal"
        )
    }

    /// Verifies that late-subscriber replay distinguishes explicit user pause from
    /// stream failure when both surfaces present identical grey `.userPaused` visuals.
    ///
    /// ``setUserPaused()`` moves intent to sticky `.userPaused` (`isBlockedByStickyIntent`
    /// is true). ``markPlaybackStoppedByStreamFailure(_:)`` preserves `.shouldBePlaying`
    /// so auto-resume paths can recover without an extra play tap (`isBlockedByStickyIntent`
    /// is false). Consumers (`WidgetRefreshManager`, main-app chrome observation) initialize
    /// from the replay prefix — not from historical `streamDidPause` / `streamDidFail`
    /// verbs — so the synthesized `.playbackIntentChanged` value is the contract that
    /// separates sticky pause from recoverable failure UI.
    ///
    /// **Explicit pause phase:** `currentState` and replay prefix carry `.userPaused`
    /// visual and intent; `isBlockedByStickyIntent == true`.
    ///
    /// **Failure phase** (after isolated reset): same grey visual with preserved
    /// `.shouldBePlaying` intent; `isBlockedByStickyIntent == false`.
    ///
    /// - SeeAlso: ``setUserPaused()``, ``markPlaybackStoppedByStreamFailure(_:)``,
    ///   ``makeEventsStreamWithReplay()``, ``currentState``, ``PlayerCurrentState``,
    ///   `PlayerCurrentState.isBlockedByStickyIntent`,
    ///   ``testReplayPrefixAfterStreamFailurePreservesIntentThenReflectsRecovery``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5 late-subscriber),
    ///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
    func testReplayPrefixDistinguishesExplicitPauseFromStreamFailure() async {
        // Phase 1 — explicit sticky pause.
        await manager.setUserPaused()

        let pauseSnapshot = await manager.currentState
        XCTAssertEqual(pauseSnapshot.visualState, .userPaused)
        XCTAssertEqual(pauseSnapshot.playbackIntent, .userPaused)
        XCTAssertTrue(
            pauseSnapshot.isBlockedByStickyIntent,
            "Explicit pause must block auto-resume via sticky intent"
        )

        let pauseReplay = await manager.makeEventsStreamWithReplay()
        let pausePrefix = await collectEvents(from: pauseReplay, count: 4, timeout: 2.0)
        guard pausePrefix.count == 4 else {
            XCTFail("Replay after explicit pause must begin with four prefix events; got \(pausePrefix.count): \(pausePrefix)")
            return
        }

        guard case let .visualStateDidChange(pauseVisual) = pausePrefix[0] else {
            XCTFail("First replay event after explicit pause must be .visualStateDidChange")
            return
        }
        XCTAssertEqual(pauseVisual, .userPaused)

        guard case let .playbackIntentChanged(pauseIntent) = pausePrefix[1] else {
            XCTFail("Second replay event after explicit pause must be .playbackIntentChanged")
            return
        }
        XCTAssertEqual(
            pauseIntent,
            .userPaused,
            "Explicit pause replay prefix must expose sticky intent"
        )
        XCTAssertEqual(pauseIntent, pauseSnapshot.playbackIntent)

        // Phase 2 — recoverable stream failure (isolated reset to the same starting intent).
        await resetSharedPlayerManagerEventContrastPhase(manager: manager)

        let intentBeforeFailure = await manager.currentPlaybackIntent
        XCTAssertEqual(
            intentBeforeFailure,
            .shouldBePlaying,
            "Precondition: failure contrast tests intent preservation from active-play intent"
        )

        await manager.markPlaybackStoppedByStreamFailure(.transientFailure)

        let failureSnapshot = await manager.currentState
        XCTAssertEqual(failureSnapshot.visualState, .userPaused)
        XCTAssertEqual(
            failureSnapshot.playbackIntent,
            .shouldBePlaying,
            "Stream failure grey UI must not convert intent to sticky .userPaused"
        )
        XCTAssertFalse(
            failureSnapshot.isBlockedByStickyIntent,
            "Failure replay must not present as sticky pause"
        )

        let failureReplay = await manager.makeEventsStreamWithReplay()
        let failurePrefix = await collectEvents(from: failureReplay, count: 4, timeout: 2.0)
        guard failurePrefix.count == 4 else {
            XCTFail("Replay after stream failure must begin with four prefix events; got \(failurePrefix.count): \(failurePrefix)")
            return
        }

        guard case let .visualStateDidChange(failureVisual) = failurePrefix[0] else {
            XCTFail("First replay event after stream failure must be .visualStateDidChange")
            return
        }
        XCTAssertEqual(failureVisual, .userPaused)

        guard case let .playbackIntentChanged(failureIntent) = failurePrefix[1] else {
            XCTFail("Second replay event after stream failure must be .playbackIntentChanged")
            return
        }
        XCTAssertEqual(
            failureIntent,
            .shouldBePlaying,
            "Failure replay prefix must expose preserved intent, not sticky pause"
        )
        XCTAssertEqual(failureIntent, failureSnapshot.playbackIntent)

        // Cross-phase contrast: identical grey visual, divergent intent contract.
        XCTAssertEqual(pauseVisual, failureVisual, "Both paths share grey .userPaused visual")
        XCTAssertNotEqual(
            pauseIntent,
            failureIntent,
            "Replay prefix intent is the sole late-subscriber discriminator between pause and failure"
        )
    }

    /// Verifies that late-subscriber replay surfaces permanent-error state via
    /// ``currentState`` / ``PlayerCurrentState/hasError``, not via synthesized
    /// `streamDidFail` verbs.
    ///
    /// Tier 3 replay deliberately omits stream transition verbs; terminal error
    /// conditions are expressed through snapshot fields (especially `hasError`).
    /// Consumers (`WidgetRefreshManager`, main-app chrome observation) must combine
    /// the four-event replay prefix with `currentState` (or
    /// `PlayerCurrentState.isInPermanentError`) to distinguish permanent failure
    /// chrome from recoverable grey pause UI.
    ///
    /// **Security-lock phase:** ``setSecurityLocked()`` yields `.securityLocked`
    /// visual in the replay prefix; `hasError` and `isInPermanentError` are true.
    ///
    /// **Permanent stream-failure phase:** grey `.userPaused` visual (identical to
    /// transient failure) with `hasError == true` when the engine's
    /// `hasPermanentError` flag is set before ``markPlaybackStoppedByStreamFailure(_:)``.
    ///
    /// **Transient-failure contrast:** same grey visual with `hasError == false`.
    ///
    /// - SeeAlso: ``setSecurityLocked()``, ``markPlaybackStoppedByStreamFailure(_:)``,
    ///   ``makeEventsStreamWithReplay()``, ``currentState``, ``PlayerCurrentState``,
    ///   `PlayerCurrentState.isInPermanentError`, `PlayerCurrentState.hasError`,
    ///   ``testReplayPrefixDistinguishesExplicitPauseFromStreamFailure``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5 late-subscriber),
    ///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
    func testReplayPrefixReflectsPermanentErrorInCurrentStateSnapshot() async {
        // Phase 1 — security lock: hasError derived from .securityLocked visual.
        await manager.setSecurityLocked()

        let lockSnapshot = await manager.currentState
        XCTAssertEqual(lockSnapshot.visualState, .securityLocked)
        XCTAssertTrue(
            lockSnapshot.hasError,
            "Security lock must surface permanent error in replay snapshot"
        )
        XCTAssertTrue(lockSnapshot.isInPermanentError)

        let lockReplay = await manager.makeEventsStreamWithReplay()
        let lockPrefix = await collectEvents(from: lockReplay, count: 4, timeout: 2.0)
        guard lockPrefix.count == 4 else {
            XCTFail("Replay after security lock must begin with four prefix events; got \(lockPrefix.count): \(lockPrefix)")
            return
        }

        guard case let .visualStateDidChange(lockVisual) = lockPrefix[0] else {
            XCTFail("First replay event after security lock must be .visualStateDidChange")
            return
        }
        XCTAssertEqual(lockVisual, .securityLocked)
        XCTAssertEqual(lockVisual, lockSnapshot.visualState)

        // Phase 2 — permanent stream failure: grey visual + hasError via persisted snapshot.
        await resetSharedPlayerManagerEventContrastPhase(manager: manager)

        await MainActor.run {
            DirectStreamingPlayer.shared.hasPermanentError = true
        }
        await manager.markPlaybackStoppedByStreamFailure(.permanentFailure)

        let permSnapshot = await manager.currentState
        XCTAssertEqual(permSnapshot.visualState, .userPaused)
        XCTAssertTrue(
            permSnapshot.hasError,
            "Permanent stream failure must set hasError in replay snapshot"
        )
        XCTAssertTrue(permSnapshot.isInPermanentError)
        XCTAssertFalse(
            permSnapshot.isBlockedByStickyIntent,
            "Permanent failure grey UI must not imply sticky pause intent"
        )

        let permSharedState = manager.loadSharedState()
        XCTAssertTrue(
            permSharedState.hasError,
            "Persisted widget snapshot must carry hasError for permanent stream failure"
        )

        let permReplay = await manager.makeEventsStreamWithReplay()
        let permPrefix = await collectEvents(from: permReplay, count: 4, timeout: 2.0)
        guard permPrefix.count == 4 else {
            XCTFail("Replay after permanent failure must begin with four prefix events; got \(permPrefix.count): \(permPrefix)")
            return
        }

        guard case let .visualStateDidChange(permVisual) = permPrefix[0] else {
            XCTFail("First replay event after permanent failure must be .visualStateDidChange")
            return
        }
        XCTAssertEqual(permVisual, .userPaused)
        XCTAssertEqual(permVisual, permSnapshot.visualState)

        // Phase 3 — transient failure contrast: identical grey visual, hasError false.
        await resetSharedPlayerManagerEventContrastPhase(manager: manager)

        await MainActor.run {
            DirectStreamingPlayer.shared.hasPermanentError = false
        }
        await manager.markPlaybackStoppedByStreamFailure(.transientFailure)

        let transientSnapshot = await manager.currentState
        XCTAssertEqual(transientSnapshot.visualState, .userPaused)
        XCTAssertFalse(
            transientSnapshot.hasError,
            "Transient failure must not set hasError in replay snapshot"
        )
        XCTAssertFalse(transientSnapshot.isInPermanentError)

        let transientReplay = await manager.makeEventsStreamWithReplay()
        let transientPrefix = await collectEvents(from: transientReplay, count: 4, timeout: 2.0)
        guard transientPrefix.count == 4 else {
            XCTFail("Replay after transient failure must begin with four prefix events; got \(transientPrefix.count): \(transientPrefix)")
            return
        }

        guard case let .visualStateDidChange(transientVisual) = transientPrefix[0] else {
            XCTFail("First replay event after transient failure must be .visualStateDidChange")
            return
        }
        XCTAssertEqual(transientVisual, .userPaused)

        // Cross-phase contrast: grey visual alone does not signal permanence.
        XCTAssertEqual(permVisual, transientVisual, "Permanent and transient failures share grey .userPaused visual")
        XCTAssertNotEqual(
            permSnapshot.hasError,
            transientSnapshot.hasError,
            "hasError in currentState is the late-subscriber discriminator for permanent stream failure"
        )
        XCTAssertNotEqual(
            lockVisual,
            permVisual,
            "Security lock uses distinct .securityLocked visual vs grey stream failure"
        )
    }

}
