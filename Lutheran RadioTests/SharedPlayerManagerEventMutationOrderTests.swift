//
//  SharedPlayerManagerEventMutationOrderTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 26.7.2026.
//
//  Mutation emission-order contracts (pause / play / metadata / privacy / sleep timer).
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

/// Canonical mutation emission-order contracts for pause, play, metadata, privacy, and sleep timer.
///
/// Sibling of ``SharedPlayerManagerEventTests`` (core replay/live) and
/// ``SharedPlayerManagerEventFailureTests`` (failure payloads / replay prefixes).
///
/// - SeeAlso: ``SharedPlayerManagerEventTests``,
///   ``setUserPaused()``, ``setPlaying()``, ``applySleepTimerElapsedPause()``,
///   `PlayerEventTestSupport.swift`,
///   docs/Event-Driven-Refactor-Roadmap.md,
///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).

final class SharedPlayerManagerEventMutationOrderTests: XCTestCase {

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

    // MARK: - Sleep Timer Test Fixtures

    /// Establishes active sleep-timer countdown semantics: `.playing` visual and
    /// `.sleepTimer` intent with no running actor countdown task.
    ///
    /// Cancels the scheduled task without restoring intent so
    /// ``applySleepTimerElapsedPause()`` can be driven deterministically.
    private func establishActiveSleepTimerCountdownState() async {
        await manager.setPlaying()
        _ = await manager.setSleepTimer(duration: 3600)
        await manager.cancelSleepTimer(restorePlaybackIntent: false, notifyStateChange: false)

        let visual = await manager.currentVisualState
        let intent = await manager.currentPlaybackIntent
        XCTAssertEqual(visual, .playing)
        XCTAssertEqual(intent, .sleepTimer)
    }

    /// Establishes post-elapsed sleep-timer semantics: grey `.userPaused` visual with
    /// preserved `.sleepTimer` intent (non-sticky pause contract).
    private func establishSleepTimerElapsedPauseState() async {
        await establishActiveSleepTimerCountdownState()
        await manager.applySleepTimerElapsedPause()

        let snapshot = await manager.currentState
        XCTAssertEqual(snapshot.visualState, .userPaused)
        XCTAssertEqual(snapshot.playbackIntent, .sleepTimer)
        XCTAssertFalse(
            snapshot.isBlockedByStickyIntent,
            "Elapsed sleep timer must not present as sticky user pause"
        )
    }

    /// Verifies the canonical emission order for ``setUserPaused()``.
    ///
    /// Explicit user pause is distinct from terminal ``stop()`` and from
    /// ``markPlaybackStoppedByStreamFailure(_:)``:
    /// - Visual and intent both move to sticky `.userPaused` (resurrection protection).
    /// - The `streamDidPause` verb follows the mutation events and precedes the
    ///   persisted snapshot signal when the privacy gate allows the write path.
    ///
    /// Consumers use this ordering to distinguish pause from stop/fail and to update
    /// controls before snapshot-driven widget reloads.
    ///
    /// Collection uses the DEBUG notification seam (same rationale as the `stop()` and
    /// failure order tests).
    ///
    /// - SeeAlso: ``setUserPaused()``, ``markAsUserPaused()``, ``stop()``,
    ///   ``markPlaybackStoppedByStreamFailure(_:)``, ``emit(_:)``,
    ///   `PlayerEvent.streamDidPause`,
    ///   ``testMarkAsUserPausedEmissionOrderMatchesCanonicalMutationSequence``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5),
    ///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
    func testSetUserPausedEmissionOrderMatchesCanonicalMutationSequence() async {
        // setUp established .shouldBePlaying intent and .prePlay visual.
        let intentBefore = await manager.currentPlaybackIntent
        XCTAssertEqual(
            intentBefore,
            .shouldBePlaying,
            "Precondition: pause path tests transition from an active-play intent"
        )

        let m = self.manager
        let liveEmissions = await collectSeamEvents(minimumCount: 3, timeout: 5.0) {
            await m.setUserPaused()
        }

        assertEvents(liveEmissions, containInOrder: [
            { if case .visualStateDidChange(.userPaused) = $0 { return true }; return false },
            { if case .playbackIntentChanged(.userPaused) = $0 { return true }; return false },
            { if case .streamDidPause = $0 { return true }; return false },
        ])
        XCTAssertTrue(
            liveEmissions.contains(.persistedWidgetStateDidUpdate),
            "Pause path should emit .persistedWidgetStateDidUpdate when the write path runs; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidStop = $0 { return true }; return false },
            "User pause must emit streamDidPause, not streamDidStop; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidFail = $0 { return true }; return false },
            "User pause must emit streamDidPause, not streamDidFail; got: \(liveEmissions)"
        )

        let visualAfter = await manager.currentVisualState
        let intentAfter = await manager.currentPlaybackIntent
        XCTAssertEqual(visualAfter, .userPaused)
        XCTAssertEqual(intentAfter, .userPaused)
    }

    /// Verifies the canonical emission order for ``markAsUserPaused()``.
    ///
    /// ``markAsUserPaused()`` is the authoritative pause surface invoked from
    /// `DirectStreamingPlayer` user-action stop paths (remote commands, in-app pause)
    /// when resurrection protection must lock visual and intent to sticky `.userPaused`
    /// before the engine tears down playback. The event subsequence matches
    /// ``setUserPaused()`` because both routes perform the same mutation sequence
    /// (`applyVisualState` → `updatePlaybackIntent` → `streamDidPause` →
    /// `saveCurrentState`). Authoritative snapshot writes are only via
    /// ``saveCurrentState()`` / `performActualSave` (privacy-gated).
    ///
    /// Consumers (`WidgetRefreshManager`, ``PlayerEventSubscriber``) observe the
    /// identical pause vocabulary regardless of which canonical surface the player
    /// invoked. This test guards that contract independently so a future refactor
    /// cannot diverge the two paths silently.
    ///
    /// Collection uses the DEBUG notification seam (same rationale as
    /// ``testSetUserPausedEmissionOrderMatchesCanonicalMutationSequence``).
    ///
    /// - SeeAlso: ``markAsUserPaused()``, ``setUserPaused()``, ``stop()``,
    ///   ``markPlaybackStoppedByStreamFailure(_:)``, ``emit(_:)``,
    ///   `PlayerEvent.streamDidPause`, `DirectStreamingPlayer.markAsUserPaused()`,
    ///   ``testSetUserPausedEmissionOrderMatchesCanonicalMutationSequence``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5),
    ///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
    func testMarkAsUserPausedEmissionOrderMatchesCanonicalMutationSequence() async {
        // setUp established .shouldBePlaying intent and .prePlay visual — the
        // typical precondition when DirectStreamingPlayer calls markAsUserPaused()
        // after a user-initiated pause from an active-play intent.
        let intentBefore = await manager.currentPlaybackIntent
        XCTAssertEqual(
            intentBefore,
            .shouldBePlaying,
            "Precondition: markAsUserPaused path tests transition from an active-play intent"
        )

        let m = self.manager
        let liveEmissions = await collectSeamEvents(minimumCount: 3, timeout: 5.0) {
            await m.markAsUserPaused()
        }

        assertEvents(liveEmissions, containInOrder: [
            { if case .visualStateDidChange(.userPaused) = $0 { return true }; return false },
            { if case .playbackIntentChanged(.userPaused) = $0 { return true }; return false },
            { if case .streamDidPause = $0 { return true }; return false },
        ])
        XCTAssertTrue(
            liveEmissions.contains(.persistedWidgetStateDidUpdate),
            "markAsUserPaused path should emit .persistedWidgetStateDidUpdate when the write path runs; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidStop = $0 { return true }; return false },
            "markAsUserPaused must emit streamDidPause, not streamDidStop; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidFail = $0 { return true }; return false },
            "markAsUserPaused must emit streamDidPause, not streamDidFail; got: \(liveEmissions)"
        )

        let visualAfter = await manager.currentVisualState
        let intentAfter = await manager.currentPlaybackIntent
        XCTAssertEqual(visualAfter, .userPaused)
        XCTAssertEqual(intentAfter, .userPaused)
    }

    /// Verifies that ``clearSoftPauseMetadataStashForLanguageChange()`` emits
    /// `.metadataDidUpdate(nil)` without mutating playback visual or intent state.
    ///
    /// Paused language switches must drop stale ICY program titles so widgets and
    /// Now Playing show the new station name instead of the prior language's program.
    /// The canonical clear path routes through `_clearIcyMetadataStash()` which emits
    /// after the nil assignment. This is distinct from ``didUpdateStreamMetadata(_:)``
    /// (non-nil updates) and from stream transition verbs.
    ///
    /// Collection uses the DEBUG notification seam so the assertion is isolated to
    /// emissions triggered by the clear action.
    ///
    /// - SeeAlso: ``clearSoftPauseMetadataStashForLanguageChange()``,
    ///   ``didUpdateStreamMetadata(_:)``, `_clearIcyMetadataStash()`,
    ///   `PlayerEvent.metadataDidUpdate`, ``currentState``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5),
    ///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
    func testMetadataClearEmitsNilWithoutPlaybackMutation() async {
        // Arrange: establish non-nil metadata (paused language-switch precondition).
        await manager.setUserPaused()
        await manager.didUpdateStreamMetadata("Test Program • Speaker")

        let stateBefore = await manager.currentState
        XCTAssertNotNil(
            stateBefore.streamMetadata,
            "Precondition: metadata must be present before the language-change clear"
        )
        let visualBefore = await manager.currentVisualState
        let intentBefore = await manager.currentPlaybackIntent

        let m = self.manager
        let liveEmissions = await collectSeamEvents(minimumCount: 1, timeout: 5.0) {
            await m.clearSoftPauseMetadataStashForLanguageChange()
        }

        XCTAssertEqual(
            liveEmissions.count,
            1,
            "Clear path should emit exactly one metadata event; got: \(liveEmissions)"
        )
        XCTAssertEqual(
            liveEmissions[0],
            .metadataDidUpdate(nil),
            "Language-change metadata clear must emit .metadataDidUpdate(nil)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .visualStateDidChange = $0 { return true }; return false },
            "Metadata clear must not emit visualStateDidChange; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .playbackIntentChanged = $0 { return true }; return false },
            "Metadata clear must not emit playbackIntentChanged; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidStart = $0 { return true }; return false } ||
            liveEmissions.contains { if case .streamDidPause = $0 { return true }; return false } ||
            liveEmissions.contains { if case .streamDidStop = $0 { return true }; return false } ||
            liveEmissions.contains { if case .streamDidFail = $0 { return true }; return false },
            "Metadata clear must not emit stream transition verbs; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains(.persistedWidgetStateDidUpdate),
            "Metadata clear must not persist widget snapshot (no .persistedWidgetStateDidUpdate); got: \(liveEmissions)"
        )

        // Visual + intent postconditions only: engine async callbacks may repopulate display
        // metadata after the authoritative clear returns (race under full-suite ordering).
        let visualAfter = await manager.currentVisualState
        let intentAfter = await manager.currentPlaybackIntent
        XCTAssertEqual(visualAfter, visualBefore)
        XCTAssertEqual(intentAfter, intentBefore)
    }

    /// Verifies that ``saveCurrentState()`` does not emit ``PlayerEvent/persistedWidgetStateDidUpdate``
    /// when the privacy write gate is closed (`hasActiveLutheranWidgets == false`).
    ///
    /// The gate suppresses `performActualSave` and `savePersistedWidgetState` in the main app;
    /// emission occurs only after an authoritative snapshot write. Closed gate ⇒ no write ⇒ no event.
    ///
    /// setUp enables the gate for other tests; this test explicitly closes it before driving
    /// `saveCurrentState()`. Collection uses the DEBUG notification seam with a bounded timeout
    /// (no `minimumCount` contract — absence of emissions is the assertion).
    ///
    /// - SeeAlso: ``saveCurrentState()``, ``savePersistedWidgetState(visualState:language:streamMetadata:hasError:)``,
    ///   `WidgetRefreshManager.setHasActiveLutheranWidgets`, `SharedPlayerManager.hasActiveWidgets`,
    ///   `PlayerEvent.persistedWidgetStateDidUpdate`, docs/Event-Driven-Refactor-Roadmap.md (Tier 5),
    ///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
    func testSaveCurrentStateWithPrivacyGateClosedSuppressesPersistedWidgetStateEmission() async {
        await MainActor.run {
            WidgetRefreshManager.setHasActiveLutheranWidgets(false)
            XCTAssertFalse(
                WidgetRefreshManager.hasActiveLutheranWidgets,
                "Precondition: privacy gate must be closed for this negative-path test"
            )
        }

        let m = self.manager
        // `minimumCount` is unreachable; the timeout path returns whatever was collected
        // during the action + grace window (expected: none).
        let liveEmissions = await collectSeamEvents(minimumCount: 100, timeout: 1.0) {
            await m.saveCurrentState()
        }

        XCTAssertFalse(
            liveEmissions.contains(.persistedWidgetStateDidUpdate),
            "Closed privacy gate must suppress persisted snapshot write and emit; got: \(liveEmissions)"
        )
    }

    /// Verifies the canonical emission order for ``setPlaying()`` on the recovery path.
    ///
    /// Successful playback start (or resume after user pause) is distinct from
    /// ``setUserPaused()``, ``stop()``, and ``markPlaybackStoppedByStreamFailure(_:)``:
    /// - Visual moves to `.playing` and intent to `.shouldBePlaying` (unless sleep timer).
    /// - The `streamDidStart` verb follows the mutation events and precedes the
    ///   persisted snapshot signal when the privacy gate allows the write path.
    ///
    /// The test drives from sticky `.userPaused` so both `visualStateDidChange` and
    /// `playbackIntentChanged` appear in the ordered subsequence (intent is already
    /// `.shouldBePlaying` after setUp alone, which would skip the intent emission).
    ///
    /// Collection uses the DEBUG notification seam (same rationale as the other
    /// emission-order tests).
    ///
    /// - SeeAlso: ``setPlaying()``, ``setUserPaused()``, ``emit(_:)``,
    ///   `PlayerEvent.streamDidStart`, ``currentPlaybackIntent``,
    ///   ``SharedPlayerManager/isRunningInUITestMode``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5),
    ///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
    func testSetPlayingEmissionOrderMatchesCanonicalMutationSequence() async {
        // Arrange: paused state so intent and visual both transition on setPlaying().
        await manager.setUserPaused()

        let visualBefore = await manager.currentVisualState
        let intentBefore = await manager.currentPlaybackIntent
        XCTAssertEqual(visualBefore, .userPaused)
        XCTAssertEqual(intentBefore, .userPaused)

        let m = self.manager
        let liveEmissions = await collectSeamEvents(minimumCount: 3, timeout: 5.0) {
            await m.setPlaying()
        }

        assertEvents(liveEmissions, containInOrder: [
            { if case .visualStateDidChange(.playing) = $0 { return true }; return false },
            { if case .playbackIntentChanged(.shouldBePlaying) = $0 { return true }; return false },
            { if case .streamDidStart = $0 { return true }; return false },
        ])
        XCTAssertTrue(
            liveEmissions.contains(.persistedWidgetStateDidUpdate),
            "setPlaying path should emit .persistedWidgetStateDidUpdate when the write path runs; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidPause = $0 { return true }; return false },
            "setPlaying must emit streamDidStart, not streamDidPause; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidStop = $0 { return true }; return false },
            "setPlaying must emit streamDidStart, not streamDidStop; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidFail = $0 { return true }; return false },
            "setPlaying must emit streamDidStart, not streamDidFail; got: \(liveEmissions)"
        )

        let visualAfter = await manager.currentVisualState
        let intentAfter = await manager.currentPlaybackIntent
        XCTAssertEqual(visualAfter, .playing)
        XCTAssertEqual(intentAfter, .shouldBePlaying)
    }

    /// Verifies that ``setPlaying()`` delivers `PlayerEvent.streamDidStart` on the
    /// authoritative live ``events`` AsyncStream.
    ///
    /// ``play()`` skips stream attach and does not invoke ``setPlaying()`` under
    /// ``isRunningInUITestMode``; unit tests therefore drive the canonical emission
    /// surface directly. This contract protects consumers that subscribe to the live
    /// stream independently of the DEBUG notification seam used by emission-order tests.
    ///
    /// Collection uses ``waitForEvent(from:timeout:matching:whilePerforming:)`` with
    /// subscribe-before-action semantics on the shared live stream. A fresh stream is
    /// materialized after the arrange-phase pause so buffered pause emissions do not
    /// satisfy the collector before ``setPlaying()`` runs.
    ///
    /// - SeeAlso: ``setPlaying()``, ``play()``, ``events``, `PlayerEvent.streamDidStart`,
    ///   ``SharedPlayerManager/isRunningInUITestMode``,
    ///   ``WidgetRefreshManager/_test_setSuppressPlayerEventObservation(_:)``,
    ///   ``WidgetRefreshManager/_test_suspendPlayerEventObservation()``,
    ///   ``_test_resetEventsStreamForIsolation()``,
    ///   ``testSetPlayingEmissionOrderMatchesCanonicalMutationSequence``,
    ///   ``testLiveEmitsTransitionEventsForStopPauseFailAndIntent``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5),
    ///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
    func testLiveEventsStreamDeliversStreamDidStartFromSetPlaying() async {
        await manager.setUserPaused()
        await manager._test_resetEventsStreamForIsolation()
        let liveStream = await manager.events
        let m = manager

        let matched = await waitForEvent(
            from: liveStream,
            timeout: 10.0,
            matching: { event in
                if case .streamDidStart = event { return true }
                return false
            }
        ) {
            await m.setPlaying()
        }

        XCTAssertEqual(
            matched,
            .streamDidStart,
            "Live events stream must deliver streamDidStart from setPlaying()"
        )

        let visualAfter = await manager.currentVisualState
        let intentAfter = await manager.currentPlaybackIntent
        XCTAssertEqual(visualAfter, .playing)
        XCTAssertEqual(intentAfter, .shouldBePlaying)
    }

    /// Verifies the canonical emission order for ``applySleepTimerElapsedPause()``.
    ///
    /// When the sleep timer elapses, the authoritative pause surface writes grey
    /// `.userPaused` chrome while retaining `.sleepTimer` intent so resurrection,
    /// replay, and coordinator glue can distinguish timer-driven pause from sticky
    /// explicit pause or recoverable stream failure.
    ///
    /// **Ordered subsequence:** `visualStateDidChange(.userPaused)` →
    /// `metadataDidUpdate(nil)` (ICY stash clear) → `.persistedWidgetStateDidUpdate`
    /// when the privacy gate allows the write path.
    ///
    /// **Negative guards:** no `playbackIntentChanged` when intent is already
    /// `.sleepTimer`; no `streamDidPause`, `streamDidStop`, or `streamDidFail`
    /// (engine stop uses `.interruption`, which deliberately skips stream verbs).
    ///
    /// Collection uses the DEBUG notification seam.
    ///
    /// - SeeAlso: ``applySleepTimerElapsedPause()``, ``setSleepTimer(duration:)``,
    ///   ``cancelSleepTimer(restorePlaybackIntent:notifyStateChange:)``,
    ///   ``PlaybackIntent/sleepTimer``, ``testReplayPrefixDistinguishesExplicitPauseFromStreamFailure``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5),
    ///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
    func testApplySleepTimerElapsedPauseEmissionOrderPreservesSleepTimerIntent() async {
        await establishActiveSleepTimerCountdownState()

        let m = self.manager
        let liveEmissions = await collectSeamEvents(minimumCount: 2, timeout: 8.0) {
            await m.applySleepTimerElapsedPause()
        }

        assertEvents(liveEmissions, containInOrder: [
            { if case .visualStateDidChange(.userPaused) = $0 { return true }; return false },
            { if case .metadataDidUpdate(nil) = $0 { return true }; return false },
        ])
        XCTAssertTrue(
            liveEmissions.contains(.persistedWidgetStateDidUpdate),
            "Elapsed sleep timer must persist the widget snapshot; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .playbackIntentChanged = $0 { return true }; return false },
            "Intent is already .sleepTimer — applySleepTimerElapsedPause must not re-emit playbackIntentChanged; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidPause = $0 { return true }; return false },
            "Interruption stop must not emit streamDidPause; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidStop = $0 { return true }; return false },
            "Interruption stop must not emit streamDidStop; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidFail = $0 { return true }; return false },
            "Elapsed sleep timer must not emit streamDidFail; got: \(liveEmissions)"
        )

        let snapshot = await manager.currentState
        XCTAssertEqual(snapshot.visualState, .userPaused)
        XCTAssertEqual(snapshot.playbackIntent, .sleepTimer)
        XCTAssertFalse(snapshot.isBlockedByStickyIntent)
    }

    /// Verifies that ``setPlaying()`` preserves `.sleepTimer` intent without emitting
    /// `playbackIntentChanged(.shouldBePlaying)` when the user resumes after timer
    /// elapsed pause.
    ///
    /// The sleep-timer guard inside ``setPlaying()`` keeps intent at `.sleepTimer`
    /// so stream-switch holds, resurrection tables, and coordinator countdown UI remain
    /// aligned with the active-timer contract through successful engine attach.
    ///
    /// **Ordered subsequence:** `visualStateDidChange(.playing)` → `streamDidStart` →
    /// `.persistedWidgetStateDidUpdate` when the write path runs.
    ///
    /// **Negative guards:** no `playbackIntentChanged`; no pause/stop/fail verbs.
    ///
    /// Collection uses the DEBUG notification seam.
    ///
    /// - SeeAlso: ``setPlaying()``, ``applySleepTimerElapsedPause()``,
    ///   ``PlaybackIntent/sleepTimer``, ``canProceedWithPlayback()``,
    ///   ``testSetPlayingEmissionOrderMatchesCanonicalMutationSequence``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5),
    ///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
    func testSetPlayingWithSleepTimerIntentPreservesIntentWithoutPlaybackIntentChanged() async {
        await establishSleepTimerElapsedPauseState()

        let m = self.manager
        let liveEmissions = await collectSeamEvents(minimumCount: 2, timeout: 5.0) {
            await m.setPlaying()
        }

        assertEvents(liveEmissions, containInOrder: [
            { if case .visualStateDidChange(.playing) = $0 { return true }; return false },
            { if case .streamDidStart = $0 { return true }; return false },
        ])
        XCTAssertTrue(
            liveEmissions.contains(.persistedWidgetStateDidUpdate),
            "setPlaying resume after sleep timer must persist snapshot when gate allows; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .playbackIntentChanged = $0 { return true }; return false },
            "setPlaying must preserve .sleepTimer without playbackIntentChanged; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .playbackIntentChanged(.shouldBePlaying) = $0 { return true }; return false },
            "setPlaying must not rewrite .sleepTimer to .shouldBePlaying; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidPause = $0 { return true }; return false },
            "setPlaying must emit streamDidStart, not streamDidPause; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidStop = $0 { return true }; return false },
            "setPlaying must emit streamDidStart, not streamDidStop; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidFail = $0 { return true }; return false },
            "setPlaying must emit streamDidStart, not streamDidFail; got: \(liveEmissions)"
        )

        let snapshot = await manager.currentState
        XCTAssertEqual(snapshot.visualState, .playing)
        XCTAssertEqual(snapshot.playbackIntent, .sleepTimer)
        XCTAssertTrue(snapshot.playbackIntent.isActivePlaybackIntent)
    }

}
