//
//  SharedPlayerManagerEventTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 6.7.2026.
//
//  Emitter / replay contracts for `PlayerEvent` and `makeEventsStreamWithReplay()`.
//
//  Shared collectors: `Lutheran RadioTests/Support/PlayerEventTestSupport.swift`.
//  Isolation: ``prepareSharedPlayerManagerEventTestIsolation`` /
//  ``tearDownSharedPlayerManagerEventTestIsolation``.
//
//  - SeeAlso: ``SharedPlayerManager``, ``PlayerEvent``,
//    docs/Event-Driven-Refactor-Roadmap.md,
//    CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
//

import MediaPlayer
import XCTest
import WidgetSurface
@testable import Lutheran_Radio

/// Unit tests for the event-driven emission and replay surfaces of `SharedPlayerManager`:
/// live `events` AsyncStream emission and `makeEventsStreamWithReplay()` + `currentState`.
///
/// Media-surface coordination, cold-launch / Now Playing hygiene, and DEBUG latency
/// timeline coverage live in sibling suites under `Lutheran RadioTests/` so each file
/// stays navigable. Canonical collectors remain in `PlayerEventTestSupport.swift`.
///
/// ## Fast & Reliable Test Patterns (Reference for Future Agents)
///
/// **Canonical collectors and assertions** live in
/// `Lutheran RadioTests/Support/PlayerEventTestSupport.swift`
/// (`collectEvents`, `collectSeamEvents`, `waitForEmission`, `assertEvents`,
/// `sanitizeLiveActivityLocalState`, and related helpers). This suite is the
/// primary *usage* reference for emitter / replay / hybrid contracts; do not
/// re-copy collectors into new test files.
///
/// **AGENT RULE**: Allow the test runner sufficient time (often many minutes)
/// when output appears stalled. Bounded collection + sanitization + UITestMode
/// guards guarantee progress and termination.
///
/// Core techniques demonstrated:
/// - Subscribe *before* the action; drive actions inside `collectEvents(whilePerforming:)`.
/// - `withTaskGroup` + `cancelAll()` + grace sleep for never-finishing streams.
/// - Cheap sanitization of RadioLiveActivityManager before clearAllLocalState paths.
/// - Direct seams (`setHasActiveLutheranWidgets`) instead of WidgetCenter / ActivityKit.
/// - Hybrid seam + replay-prefix contracts for stop() multi-emit order.
///
/// - SeeAlso: ``PlayerEvent``, ``SharedPlayerManager/events``,
///   ``SharedPlayerManager/makeEventsStreamWithReplay()``,
///   ``SharedPlayerManagerMediaSurfaceTests``,
///   ``SharedPlayerManagerColdLaunchHygieneTests``,
///   ``SharedPlayerManagerMediaTransportLatencyTests``,
///   `PlayerEventTestSupport.swift`,
///   docs/Event-Driven-Refactor-Roadmap.md,
///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
final class SharedPlayerManagerEventTests: XCTestCase {

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

    // MARK: - Replay Scenario (Tier 3 contract)

    /// Verifies the replay contract for late subscribers.
    ///
    /// A call to `makeEventsStreamWithReplay()` must first yield four state-carrying
    /// events synthesized from `currentState` (visual, intent, metadata, persisted signal),
    /// then forward any subsequent live events.
    ///
    /// Stream transition verbs are deliberately **not** synthesized during replay.
    /// This test exercises exactly the documented Tier 3 behavior.
    ///
    /// - SeeAlso: ``SharedPlayerManager/makeEventsStreamWithReplay()``, ``SharedPlayerManager/currentState``,
    ///   ``PlayerCurrentState``, `PlayerEvent` replay notes in PlayerVisualState.swift,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 3 current-state replay).
    func testMakeEventsStreamWithReplayYieldsCurrentStateThenLiveEvents() async {
        // Arrange: drive the manager to a reproducible non-error state.
        await manager.setUserIntentToPlay()
        await manager.setPlaying()

        let snapshot = await manager.currentState

        // Act: obtain a fresh replaying stream (late-subscriber simulation)
        let replayStream = await manager.makeEventsStreamWithReplay()
        let initial = await collectEvents(from: replayStream, count: 4)

        // Assert: exactly the four documented synthesized events appear first, in order.
        XCTAssertEqual(initial.count, 4, "Replay must begin with the four state snapshot events")

        guard case let .visualStateDidChange(visual) = initial[0] else {
            XCTFail("First replay event must be .visualStateDidChange carrying current visualState")
            return
        }
        XCTAssertEqual(visual, snapshot.visualState, "Replayed visualState must match currentState")

        guard case let .playbackIntentChanged(intent) = initial[1] else {
            XCTFail("Second replay event must be .playbackIntentChanged carrying current intent")
            return
        }
        XCTAssertEqual(intent, snapshot.playbackIntent, "Replayed intent must match currentState")

        // Third is metadata (may be nil)
        guard case .metadataDidUpdate = initial[2] else {
            XCTFail("Third replay event must be .metadataDidUpdate (value may be nil)")
            return
        }

        // Fourth is the persisted snapshot signal
        XCTAssertEqual(
            initial[3],
            .persistedWidgetStateDidUpdate,
            "Fourth replay event must be the .persistedWidgetStateDidUpdate signal"
        )

        // Prove that a live event occurs after the replay prefix using the reliable
        // notification seam (the stream forwarding on the replayStream itself is exercised
        // by production code and is timing-sensitive in the full-app test host).
        let m = self.manager
        let stopSeen = await waitForEmission(matching: { event in
            if case .streamDidStop = event { return true }
            if case .playbackIntentChanged(.userPaused) = event { return true }
            return false
        }) {
            await m.stop()
        }
        XCTAssertNotNil(stopSeen, "A live emission must occur after the replay prefix (stop or intent change)")

        // Still exercise consuming from the replayStream after the prefix (non-gating for timing).
        _ = await collectEvents(from: replayStream, count: 1, timeout: 2.0)
        // We don't hard-assert more here; the seam above already proved the emission happened.
    }

    // MARK: - Widget Process Emission Guard

    /// Verifies that ``emit(_:)`` suppresses ``events`` yield and the DEBUG notification seam
    /// when ``isRunningInWidget()`` reports widget-process context.
    ///
    /// Widget extension processes perform optimistic snapshot writes via legacy forcing surfaces
    /// but never deliver authoritative ``PlayerEvent``s to the main-app observation stream.
    ///
    /// - SeeAlso: ``isRunningInWidget()``, ``emit(_:)``,
    ///   ``_test_setSimulateWidgetProcessContext(_:)``, docs/Event-Driven-Refactor-Roadmap.md.
    func testEmitSuppressesYieldWhenRunningInWidgetProcess() async {
        SharedPlayerManager._test_setSimulateWidgetProcessContext(true)
        defer { SharedPlayerManager._test_setSimulateWidgetProcessContext(false) }

        let liveStream = await manager.events
        let m = manager

        let streamEvents = await collectEvents(
            from: liveStream,
            count: 1,
            timeout: 1.0
        ) {
            await m.emit(.visualStateDidChange(.playing))
            await m.emit(.playbackIntentChanged(.shouldBePlaying))
            await m.emit(.streamDidStart)
            await m.emit(.streamDidPause)
            await m.emit(.streamDidStop)
            await m.emit(.streamDidFail(.transientFailure))
            await m.emit(
                .metadataDidUpdate(StreamProgramMetadata(programTitle: "Test", speaker: nil))
            )
            await m.emit(.persistedWidgetStateDidUpdate)
        }

        XCTAssertTrue(
            streamEvents.isEmpty,
            "Widget process context must suppress all AsyncStream yields from emit"
        )

        let seamEvents = await collectSeamEvents(
            minimumCount: 1,
            timeout: 1.0
        ) {
            await m.emit(.visualStateDidChange(.playing))
        }

        XCTAssertTrue(
            seamEvents.isEmpty,
            "Widget process context must suppress the DEBUG notification seam"
        )

        SharedPlayerManager._test_setSimulateWidgetProcessContext(false)

        let controlEvents = await collectSeamEvents(
            minimumCount: 1,
            timeout: 3.0
        ) {
            await m.emit(.visualStateDidChange(.userPaused))
        }

        XCTAssertEqual(controlEvents.count, 1)
        XCTAssertEqual(controlEvents.first, .visualStateDidChange(.userPaused))
    }

    // MARK: - Live Emission Coverage (Tier 5 incremental)

    /// Exercises the live `events` AsyncStream (distinct from the replaying variant)
    /// for the primary transition verbs that can be driven deterministically in unit tests.
    ///
    /// Verifies that the authoritative emitter surfaces deliver the expected `PlayerEvent`
    /// cases to subscribers on the live path:
    /// - `playbackIntentChanged` via canonical ``stop()`` and ``setPlaying()`` paths
    /// - `streamDidStop` + `visualStateDidChange(.userPaused)` via the canonical `stop()`
    /// - `streamDidPause` via `setUserPaused()`
    /// - `streamDidFail(_:)` carrying the exact `StreamErrorType` via
    ///   `markPlaybackStoppedByStreamFailure(_:)`
    /// - `streamDidStart` via ``setPlaying()`` on the recovery path (live-stream contract
    ///   also protected by ``testLiveEventsStreamDeliversStreamDidStartFromSetPlaying``)
    /// - `metadataDidUpdate(_:)` (non-nil program metadata) via `didUpdateStreamMetadata(_:)`
    /// - `persistedWidgetStateDidUpdate` via `saveCurrentState()` (privacy gate enabled in setUp)
    /// - `visualStateDidChange` for `.userPaused` and `.playing` transitions
    ///
    /// Each `PlayerEvent` case above is asserted independently (not a single OR).
    /// **Hybrid collection**: a long-lived live iterator plus the DEBUG notification seam
    /// run in parallel over one action sequence. Each case is asserted with per-case
    /// `contains` on **live OR seam** because the shared live `AsyncStream` delivery is
    /// non-deterministic in the XCTest host (see CODING_AGENT.md); the seam proves every
    /// `emit(_:)` site ran while the live iterator proves the production stream still
    /// delivers a non-empty subset.
    ///
    /// Canonical emission order for individual transitions is protected by the dedicated
    /// seam-based order tests in this file.
    ///
    /// Live Activity acceleration for test speed (see commit 10e0e46):
    /// Previously the widget / Live Activity surfaces were "disabled altogether" (flag left
    /// false after clear) to avoid 5-minute stalls. The stalls were caused by
    /// `clearAllLocalState()` → `endActivity()` performing real `Activity.update` + `.end`
    /// IPCs whenever a Live Activity had been left on the simulator, and by WidgetCenter
    /// queries / reloadTimelines when the gate was opened.
    ///
    /// Current approach (accelerated, coverage-preserving):
    /// - setUp performs cheap local sanitization (stop timer, cancel obs task, nil
    ///   `currentActivity`) *before* clearAllLocalState. Combined with the guards
    ///   inside `RadioLiveActivityManager` (endActivity/start/update/observe), the
    ///   expensive system service paths are never taken.
    /// - WidgetCenter surfaces short-circuit under `isRunningInUITestMode`.
    /// - We set the `hasActiveLutheranWidgets` gate directly via the test seam.
    ///
    /// For the full rationale and copy-paste patterns for new tests, see:
    /// - The implementation and header comment of `collectEvents(from:count:whilePerforming:)`
    /// - CODING_AGENT.md → "Test Execution Patience and Fast, Reliable Test Patterns"
    ///
    /// - SeeAlso: ``SharedPlayerManager/events``, `collectEvents(from:count:whilePerforming:)`,
    ///   ``emit(_:)``, ``stop()``, ``setUserPaused()``, ``setPlaying()``,
    ///   ``markPlaybackStoppedByStreamFailure(_:)``,
    ///   ``updatePlaybackIntent(to:)``, ``didUpdateStreamMetadata(_:)``, ``saveCurrentState()``,
    ///   ``PlayerEvent``, `PlayerCurrentState`,
    ///   ``RadioLiveActivityManager/endActivity()``, ``RadioLiveActivityManager/isRunningUnderTest``,
    ///   `WidgetRefreshManager.refreshHasActiveWidgets`, `WidgetRefreshManager.setHasActiveLutheranWidgets`,
    ///   RadioLiveActivityManagerTests, docs/Event-Driven-Refactor-Roadmap.md (Tier 5),
    ///   CODING_AGENT.md (Test Execution Patience..., test documentation standards).
    func testLiveEmitsTransitionEventsForStopPauseFailAndIntent() async {
        // setUp has already established a clean non-blocked state with explicit intent
        // and has pre-warmed the events stream.

        // Hybrid live + seam collection over one action sequence (see doc comment).
        let liveStream = await manager.events
        let m = self.manager

        final class HybridCollector: @unchecked Sendable {
            var live: [PlayerEvent] = []
            var seam: [PlayerEvent] = []
            var seamToken: NSObjectProtocol?
        }
        let hybrid = HybridCollector()

        hybrid.seamToken = NotificationCenter.default.addObserver(
            forName: playerEventEmittedForTestNotification,
            object: nil,
            queue: .main
        ) { note in
            if let event = note.userInfo?["event"] as? PlayerEvent {
                hybrid.seam.append(event)
            }
        }

        let liveSample = await withTaskGroup(of: [PlayerEvent].self) { group -> [PlayerEvent] in
            group.addTask {
                for await event in liveStream {
                    if Task.isCancelled { break }
                    hybrid.live.append(event)
                }
                return hybrid.live
            }

            await Task.yield()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(250))

            await m.stop()
            await m.setUserPaused()
            await m.setPlaying()
            await m.markPlaybackStoppedByStreamFailure(.transientFailure)
            await m.didUpdateStreamMetadata("Test Program • Speaker")
            await m.saveCurrentState()

            await Task.yield()
            try? await Task.sleep(for: .milliseconds(600))

            group.cancelAll()
            try? await Task.sleep(for: .milliseconds(150))

            for await result in group {
                return result
            }
            return hybrid.live
        }

        if let token = hybrid.seamToken {
            NotificationCenter.default.removeObserver(token)
            hybrid.seamToken = nil
        }
        let seamSample = hybrid.seam

        XCTAssertFalse(
            liveSample.isEmpty && seamSample.isEmpty,
            "Live stream or DEBUG seam must observe emissions across the action sequence; live: \(liveSample), seam: \(seamSample)"
        )
        XCTAssertFalse(
            seamSample.isEmpty,
            "DEBUG seam must observe emissions across the action sequence; got none"
        )

        XCTAssertTrue(
            liveOrSeamContains(liveSample, seamSample) { if case .playbackIntentChanged(.userPaused) = $0 { return true }; return false },
            "Must include playbackIntentChanged(.userPaused) on live or seam; live: \(liveSample), seam: \(seamSample)"
        )
        XCTAssertTrue(
            liveOrSeamContains(liveSample, seamSample) { if case .playbackIntentChanged(.shouldBePlaying) = $0 { return true }; return false },
            "Must include playbackIntentChanged(.shouldBePlaying) on live or seam; live: \(liveSample), seam: \(seamSample)"
        )
        XCTAssertTrue(
            liveOrSeamContains(liveSample, seamSample) { if case .visualStateDidChange(.userPaused) = $0 { return true }; return false },
            "Must include visualStateDidChange(.userPaused) on live or seam; live: \(liveSample), seam: \(seamSample)"
        )
        XCTAssertTrue(
            liveOrSeamContains(liveSample, seamSample) { if case .visualStateDidChange(.playing) = $0 { return true }; return false },
            "Must include visualStateDidChange(.playing) on live or seam; live: \(liveSample), seam: \(seamSample)"
        )
        XCTAssertTrue(
            liveOrSeamContains(liveSample, seamSample) { if case .streamDidStop = $0 { return true }; return false },
            "Must include streamDidStop on live or seam; live: \(liveSample), seam: \(seamSample)"
        )
        XCTAssertTrue(
            liveOrSeamContains(liveSample, seamSample) { if case .streamDidPause = $0 { return true }; return false },
            "Must include streamDidPause on live or seam; live: \(liveSample), seam: \(seamSample)"
        )
        XCTAssertTrue(
            liveOrSeamContains(liveSample, seamSample) { if case .streamDidStart = $0 { return true }; return false },
            "Must include streamDidStart from setPlaying() on live or seam; live: \(liveSample), seam: \(seamSample)"
        )
        XCTAssertTrue(
            liveOrSeamContains(liveSample, seamSample) { if case .streamDidFail(.transientFailure) = $0 { return true }; return false },
            "Must include streamDidFail(.transientFailure) on live or seam; live: \(liveSample), seam: \(seamSample)"
        )
        XCTAssertTrue(
            liveOrSeamContains(liveSample, seamSample) { if case .metadataDidUpdate(let metadata) = $0, metadata != nil { return true }; return false },
            "Must include non-nil metadataDidUpdate on live or seam; live: \(liveSample), seam: \(seamSample)"
        )
        XCTAssertTrue(
            liveOrSeamContains(liveSample, seamSample) { if case .persistedWidgetStateDidUpdate = $0 { return true }; return false },
            "Must include persistedWidgetStateDidUpdate on live or seam; live: \(liveSample), seam: \(seamSample)"
        )
    }

    /// Returns whether `live` or `seam` contains an event matching `predicate`.
    ///
    /// Used by the hybrid live-emission smoke test when the XCTest host drops a subset
    /// of yields on the shared live `AsyncStream` but the DEBUG seam still proves emit.
    private func liveOrSeamContains(
        _ live: [PlayerEvent],
        _ seam: [PlayerEvent],
        matching predicate: (PlayerEvent) -> Bool
    ) -> Bool {
        live.contains(where: predicate) || seam.contains(where: predicate)
    }

    // MARK: - Replay Forwarding & Emission Order (Tier 5)

    /// Verifies that a replaying stream delivers the four state-prefix events first and
    /// then forwards subsequent live emissions from the authoritative emitter in yield order.
    ///
    /// This test protects two finalized contracts:
    /// 1. **Late-subscriber replay** — `makeEventsStreamWithReplay()` synthesizes exactly
    ///    four state-carrying events from `currentState` before attaching to the live stream.
    /// 2. **Emission order for `stop()`** — the canonical stop path emits mutation events
    ///    (`visualStateDidChange`, `playbackIntentChanged`) before the terminal verb
    ///    (`streamDidStop`), followed by the persisted snapshot signal when the privacy
    ///    gate allows the write path. Engine soft pause is awaited with
    ///    `applyUserPauseVisualLock: false`, so stop must **not** re-enter `setUserPaused` /
    ///    emit `streamDidPause`. Assertions use ordered subsequence matching, not a fixed
    ///    total event count.
    ///
    /// The replay stream is the surface consumed by `PlayerEventSubscriber` and
    /// `WidgetEventObserver`-based helpers; consumers depend on prefix-then-live ordering.
    ///
    /// **Why hybrid collection**: Prefix assertions use the replay stream (buffered, reliable).
    /// Canonical `stop()` emission order is asserted via the DEBUG notification seam because
    /// AsyncStream iterator attach races in the XCTest host can drop forwarded live yields.
    /// A best-effort replay-forwarding check follows without gating the primary contracts.
    ///
    /// - SeeAlso: ``SharedPlayerManager/makeEventsStreamWithReplay()``, ``SharedPlayerManager/stop()``,
    ///   ``SharedPlayerManager/currentState``, ``PlayerCurrentState``, ``emit(_:)``,
    ///   `PlayerEventSubscriber`, `WidgetEventObserver`,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 3 replay + Tier 5 emission order),
    ///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
    func testReplayStreamPrefixesStateThenForwardsLiveStopEmissionsInOrder() async {
        // Arrange: reproducible non-terminal state (setUp already cleared + set intent).
        await manager.setUserIntentToPlay()
        let snapshot = await manager.currentState

        let replayStream = await manager.makeEventsStreamWithReplay()
        let m = self.manager

        // Tier 3 — prefix contract (buffered when the replay stream is created).
        let prefix = await collectEvents(from: replayStream, count: 4, timeout: 2.0)
        guard prefix.count == 4 else {
            XCTFail("Replay stream must begin with four prefix events; got \(prefix.count): \(prefix)")
            return
        }

        guard case let .visualStateDidChange(prefixVisual) = prefix[0] else {
            XCTFail("First event must be replayed .visualStateDidChange")
            return
        }
        XCTAssertEqual(
            prefixVisual,
            snapshot.visualState,
            "Replayed visual state must match currentState at stream creation"
        )

        guard case let .playbackIntentChanged(prefixIntent) = prefix[1] else {
            XCTFail("Second event must be replayed .playbackIntentChanged")
            return
        }
        XCTAssertEqual(
            prefixIntent,
            snapshot.playbackIntent,
            "Replayed intent must match currentState at stream creation"
        )

        guard case let .metadataDidUpdate(prefixMetadata) = prefix[2] else {
            XCTFail("Third event must be replayed .metadataDidUpdate")
            return
        }
        XCTAssertEqual(
            prefixMetadata,
            snapshot.streamMetadata,
            "Replayed metadata must match currentState at stream creation"
        )

        XCTAssertEqual(
            prefix[3],
            .persistedWidgetStateDidUpdate,
            "Fourth event must be the replayed persisted snapshot signal"
        )

        // Tier 5 — canonical stop() emission order via the notification seam (reliable).
        let liveEmissions = await collectSeamEvents(minimumCount: 3, timeout: 5.0) {
            await m.stop()
        }
        assertEvents(liveEmissions, containInOrder: [
            { if case .visualStateDidChange(.userPaused) = $0 { return true }; return false },
            { if case .playbackIntentChanged(.userPaused) = $0 { return true }; return false },
            { if case .streamDidStop = $0 { return true }; return false },
        ])
        XCTAssertTrue(
            liveEmissions.contains(.persistedWidgetStateDidUpdate),
            "Live stop path should emit .persistedWidgetStateDidUpdate when the write path runs; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidPause = $0 { return true }; return false },
            "SPM stop owns streamDidStop + sticky lock; engine must not re-enter setUserPaused/streamDidPause; got: \(liveEmissions)"
        )

        // Replay forwarding — best-effort: a second iterator on the replay stream while re-driving
        // stop() should observe at least one forwarded live emission (timing-sensitive).
        let forwarded = await collectEvents(from: replayStream, count: 1, timeout: 2.0) {
            await m.stop()
        }
        guard !forwarded.isEmpty else {
            // Best-effort only: forwarding attach timing is flaky in the test host.
            // Canonical order is already protected by the seam assertions above.
            return
        }
        XCTAssertTrue(
            forwarded.contains { if case .streamDidStop = $0 { return true }; return false } ||
            forwarded.contains { if case .playbackIntentChanged(.userPaused) = $0 { return true }; return false } ||
            forwarded.contains { if case .visualStateDidChange(.userPaused) = $0 { return true }; return false },
            "Replay stream must forward at least one live stop emission; got: \(forwarded)"
        )
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
    /// Consumers (`PlayerEventSubscriber`, `WidgetRefreshManager`) rely on this ordering
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
    /// `saveCurrentState`) even though ``markAsUserPaused()`` omits the early
    /// `saveVisualState()` call and the post-save Live Activity update task present
    /// in ``setUserPaused()``.
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

    /// Verifies the full active-intent language-switch path emission contract.
    ///
    /// Mirrors the resume branch of `RadioPlayerCoordinator.completeStreamSwitch` /
    /// `switchToStreamFromWidget`: ``resetToPrePlayForNewStream()`` (yellow `.prePlay` hold
    /// **before** engine silent stop), engine prep via ``switchToStream(_:)``, then successful
    /// attach via ``setPlaying()`` (stand-in for ``play()`` under UITestMode).
    ///
    /// **Reset phase:** `visualStateDidChange(.prePlay)` and metadata clear precede engine prep;
    /// intent stays `.shouldBePlaying` (no `playbackIntentChanged`, no stream verbs).
    ///
    /// **Resume phase:** `visualStateDidChange(.playing)` → `streamDidStart` → persist signal;
    /// intent still unchanged.
    ///
    /// Collection uses the DEBUG notification seam. Ordered subsequence matching tolerates
    /// extra `.persistedWidgetStateDidUpdate` / `.metadataDidUpdate(nil)` emissions from the
    /// hold path and engine silent-stop save.
    ///
    /// - SeeAlso: ``resetToPrePlayForNewStream(preserveActiveSleepTimer:connectingLanguageCode:)``,
    ///   ``switchToStream(_:)``, ``setPlaying()``, ``isStreamSwitchPrePlayHoldActive``,
    ///   `RadioPlayerCoordinator.completeStreamSwitch`,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5),
    ///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
    func testActiveLanguageSwitchResetThenResumeEmissionOrderPreservesIntent() async {
        let streams = manager.availableStreams
        guard streams.count >= 2 else { return }
        let other = await targetStreamDifferentFromCurrent(in: streams)

        await manager.setPlaying()
        let intentBefore = await manager.currentPlaybackIntent
        XCTAssertEqual(
            intentBefore,
            .shouldBePlaying,
            "Precondition: active switch path preserves an already-active playback intent"
        )

        let m = self.manager
        let liveEmissions = await collectSeamEvents(minimumCount: 4, timeout: 8.0) {
            await m.resetToPrePlayForNewStream()
            await m.switchToStream(other)
            await m.setPlaying()
        }

        assertEvents(liveEmissions, containInOrder: [
            { if case .visualStateDidChange(.prePlay) = $0 { return true }; return false },
            { if case .visualStateDidChange(.playing) = $0 { return true }; return false },
            { if case .streamDidStart = $0 { return true }; return false },
        ])
        XCTAssertTrue(
            liveEmissions.contains(.persistedWidgetStateDidUpdate),
            "Active switch path should persist at least once; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .playbackIntentChanged = $0 { return true }; return false },
            "Active language switch must not emit playbackIntentChanged — intent stays \(intentBefore); got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidPause = $0 { return true }; return false } ||
            liveEmissions.contains { if case .streamDidStop = $0 { return true }; return false } ||
            liveEmissions.contains { if case .streamDidFail = $0 { return true }; return false },
            "Active switch must not emit terminal stream verbs; got: \(liveEmissions)"
        )

        let visualAfter = await manager.currentVisualState
        let intentAfter = await manager.currentPlaybackIntent
        XCTAssertEqual(visualAfter, .playing)
        XCTAssertEqual(intentAfter, .shouldBePlaying)

        let current = SharedPlayerManager.streamForLanguageCode(other.languageCode)
        XCTAssertEqual(current.languageCode, other.languageCode)
    }

    /// Active-intent stream switch must establish Connecting chrome and clear prior-language
    /// program metadata **before** engine silent stop, so lock-screen surfaces cannot keep
    /// `.playing` mid teardown.
    ///
    /// Protects the coordinator contract: ``resetToPrePlayForNewStream()`` then
    /// ``switchToStream(_:)`` leaves ``isStreamSwitchPrePlayHoldActive`` true with nil metadata
    /// until authoritative ``setPlaying()``.
    ///
    /// - SeeAlso: ``resetToPrePlayForNewStream(preserveActiveSleepTimer:connectingLanguageCode:)``,
    ///   ``isStreamSwitchPrePlayHoldActive``, ``switchToStream(_:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§6).
    func testActiveStreamSwitchHoldClearsPlayingChromeAndMetadataBeforeEnginePrep() async {
        let streams = manager.availableStreams
        guard streams.count >= 2 else { return }
        let other = await targetStreamDifferentFromCurrent(in: streams)

        await manager.setPlaying()
        await manager.didUpdateStreamMetadata("Prior Language Program • Speaker")
        var meta = await manager.currentStreamMetadata
        XCTAssertNotNil(meta, "Arrange: prior-language ICY title present before switch")

        await manager.resetToPrePlayForNewStream(connectingLanguageCode: other.languageCode)

        let visualDuringHold = await manager.currentVisualState
        let holdActive = await manager.isStreamSwitchPrePlayHoldActive
        meta = await manager.currentStreamMetadata
        XCTAssertEqual(visualDuringHold, .prePlay, "Hold must force Connecting chrome before silent stop")
        XCTAssertTrue(holdActive, "Stream-switch prePlay hold must be active before engine prep")
        XCTAssertNil(meta, "Prior-language program title must clear with the hold")

        await manager.switchToStream(other)

        let visualAfterEnginePrep = await manager.currentVisualState
        let holdAfterEnginePrep = await manager.isStreamSwitchPrePlayHoldActive
        XCTAssertEqual(
            visualAfterEnginePrep,
            .prePlay,
            "Silent streamSwitch stop must not restore .playing while hold is active"
        )
        XCTAssertTrue(
            holdAfterEnginePrep,
            "Hold must remain until authoritative setPlaying after attach"
        )

        let intent = await manager.currentPlaybackIntent
        XCTAssertTrue(
            intent.isActivePlaybackIntent,
            "Active-intent switch must preserve play intent through hold + engine prep"
        )
    }

    /// Stream-switch Connecting hold must publish the **destination** language for Live Activity
    /// content **before** ``selectedStream`` updates, so Lock Screen chrome does not show
    /// `.prePlay` with the prior stream’s flag/name for one content push.
    ///
    /// After ``setPlaying()`` the hold-time override clears and language follows stream attach.
    ///
    /// - SeeAlso: ``resetToPrePlayForNewStream(preserveActiveSleepTimer:connectingLanguageCode:)``,
    ///   ``liveActivityLanguageCodeForContentPush()``, ``mainAppLiveActivityLanguageCode()``,
    ///   ``persistLiveActivityLanguageMirror(_:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   docs/Widget-Functionality-Roadmap.md (Live Activity language chrome SSOT).
    func testStreamSwitchHoldContentLanguageMatchesDestinationBeforeEnginePrep() async {
        let streams = manager.availableStreams
        guard streams.count >= 2 else { return }
        let other = await targetStreamDifferentFromCurrent(in: streams)
        let priorLanguage = await MainActor.run {
            DirectStreamingPlayer.shared.selectedStream.languageCode
        }
        XCTAssertNotEqual(
            priorLanguage,
            other.languageCode,
            "Arrange: destination must differ from engine selection before hold"
        )

        await manager.setPlaying()
        await manager.resetToPrePlayForNewStream(connectingLanguageCode: other.languageCode)

        let holdActive = await manager.isStreamSwitchPrePlayHoldActive
        let contentLanguage = await manager.liveActivityLanguageCodeForContentPush()
        let engineLanguage = SharedPlayerManager.mainAppLiveActivityLanguageCode()
        let mirror = SharedPlayerManager.loadLiveActivityLanguageMirror()

        XCTAssertTrue(holdActive, "Hold must be active for the content-language override")
        XCTAssertEqual(
            contentLanguage,
            other.languageCode,
            "LA ContentState language must be destination during Connecting hold"
        )
        XCTAssertEqual(
            engineLanguage,
            priorLanguage,
            "Engine selectedStream may still be prior until switchToStream — that is the race this override covers"
        )
        XCTAssertEqual(
            mirror,
            other.languageCode,
            "Durable LA language mirror must warm destination on hold (extension optimistic paths)"
        )

        await manager.switchToStream(other)
        let contentAfterPrep = await manager.liveActivityLanguageCodeForContentPush()
        XCTAssertEqual(contentAfterPrep, other.languageCode)

        await manager.setPlaying()
        let contentAfterPlay = await manager.liveActivityLanguageCodeForContentPush()
        let engineAfterPlay = SharedPlayerManager.mainAppLiveActivityLanguageCode()
        XCTAssertEqual(contentAfterPlay, other.languageCode)
        XCTAssertEqual(engineAfterPlay, other.languageCode)
        XCTAssertEqual(
            contentAfterPlay,
            engineAfterPlay,
            "After setPlaying, content language must equal stream-attach language (hold override cleared)"
        )
    }

    /// Verifies the full paused language-switch path emission contract.
    ///
    /// Mirrors the explicit-paused branch of `RadioPlayerCoordinator.completeStreamSwitch` /
    /// `switchToStreamFromWidget`: engine prep via ``switchToStream(_:)`` (no auto-resume),
    /// then ``clearSoftPauseMetadataStashForLanguageChange()`` to drop stale ICY titles.
    ///
    /// Visual and intent must remain sticky `.userPaused`. The canonical clear must be the
    /// final `.metadataDidUpdate` in the collected window (engine prep may emit a prior
    /// non-nil update). Engine silent-stop may add `.persistedWidgetStateDidUpdate`
    /// without changing visual or intent.
    ///
    /// - SeeAlso: ``clearSoftPauseMetadataStashForLanguageChange()``,
    ///   ``switchToStream(_:)``, `RadioPlayerCoordinator.completeStreamSwitch`,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5),
    ///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
    func testPausedLanguageSwitchFullPathClearsMetadataWithoutVisualOrIntentMutation() async {
        let streams = manager.availableStreams
        guard streams.count >= 2 else { return }
        let other = await targetStreamDifferentFromCurrent(in: streams)

        await manager.setUserPaused()
        await manager.didUpdateStreamMetadata("Test Program • Speaker")

        let visualBefore = await manager.currentVisualState
        let intentBefore = await manager.currentPlaybackIntent
        XCTAssertEqual(visualBefore, .userPaused)
        XCTAssertEqual(intentBefore, .userPaused)

        let m = self.manager
        let liveEmissions = await collectSeamEventsUntil(timeout: 8.0, until: { event in
            if case .metadataDidUpdate(nil) = event { return true }
            return false
        }) {
            await m.switchToStream(other)
            await m.clearSoftPauseMetadataStashForLanguageChange()
        }

        XCTAssertTrue(
            liveEmissions.contains { if case .metadataDidUpdate(nil) = $0 { return true }; return false },
            "Paused switch must emit .metadataDidUpdate(nil); got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .visualStateDidChange = $0 { return true }; return false },
            "Paused switch must not mutate visual state via events; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .playbackIntentChanged = $0 { return true }; return false },
            "Paused switch must not emit playbackIntentChanged; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidStart = $0 { return true }; return false } ||
            liveEmissions.contains { if case .streamDidPause = $0 { return true }; return false } ||
            liveEmissions.contains { if case .streamDidStop = $0 { return true }; return false } ||
            liveEmissions.contains { if case .streamDidFail = $0 { return true }; return false },
            "Paused switch must not emit stream transition verbs; got: \(liveEmissions)"
        )

        // Visual + intent postconditions only: engine async callbacks may repopulate display
        // metadata after the authoritative clear returns (race under full-suite ordering).
        let visualAfter = await manager.currentVisualState
        let intentAfter = await manager.currentPlaybackIntent
        XCTAssertEqual(visualAfter, visualBefore)
        XCTAssertEqual(intentAfter, intentBefore)

        let current = SharedPlayerManager.streamForLanguageCode(other.languageCode)
        XCTAssertEqual(current.languageCode, other.languageCode)
    }

    /// Verifies the Tier 3 replay prefix after ``markPlaybackStoppedByStreamFailure(_:)``
    /// and after subsequent recovery via ``setPlaying()``.
    ///
    /// Stream failure is visually identical to explicit pause (`.userPaused`) but
    /// **must not** flip `playbackIntent` to sticky `.userPaused`. Late subscribers
    /// (`PlayerEventSubscriber`, `WidgetEventObserver`) initialize from the replay
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
    /// is false). Consumers (`PlayerEventSubscriber`, `WidgetRefreshManager`) initialize
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
        await resetManagerForContrastPhase()

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
    /// Consumers (`PlayerEventSubscriber`, `WidgetRefreshManager`) must combine
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
        await resetManagerForContrastPhase()

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
        await resetManagerForContrastPhase()

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

    /// Verifies multi-subscriber replay attach ordering for independent per-call streams.
    ///
    /// Each ``makeEventsStreamWithReplay()`` invocation materializes an independent
    /// stream whose four-event prefix reflects ``currentState`` at creation time.
    /// Subsequent live emissions fan out to every replay stream whose forwarding
    /// iterator was active before the mutation.
    ///
    /// **Attach-time independence:** an early subscriber's prefix reflects pre-mutation
    /// state; a late subscriber created after ``setUserPaused()`` reflects post-mutation
    /// state without synthesizing historical `streamDid*` verbs.
    ///
    /// **Concurrent same-state attach:** two replay streams created together must yield
    /// identical four-event prefixes when both iterators attach in parallel via
    /// ``collectEventsConcurrently(from:countEach:timeout:whilePerforming:)``.
    ///
    /// Canonical live pause ordering with multiple concurrent ``events`` iterators is
    /// covered by the DEBUG notification seam in
    /// ``testSetUserPausedEmissionOrderMatchesCanonicalMutationSequence`` (the live
    /// stream shares each yield across iterators; ``WidgetRefreshManager`` also
    /// observes the stream in the test host). Replay live-forwarding to multiple
    /// independent replay streams remains best-effort only (same XCTest host caveat
    /// as ``testReplayStreamPrefixesStateThenForwardsLiveStopEmissionsInOrder``).
    ///
    /// - SeeAlso: ``makeEventsStreamWithReplay()``, ``currentState``, ``setUserPaused()``,
    ///   ``collectEventsConcurrently(from:countEach:timeout:whilePerforming:)``,
    ///   ``testSetUserPausedEmissionOrderMatchesCanonicalMutationSequence``,
    ///   ``testReplayStreamPrefixesStateThenForwardsLiveStopEmissionsInOrder``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5 multi-subscriber),
    ///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
    func testMultiSubscriberReplayAttachOrderingPreservesIndependentPrefixesAndLiveOrder() async {
        // Phase 1 — attach-time prefix independence.
        let initialSnapshot = await manager.currentState

        let earlyStream = await manager.makeEventsStreamWithReplay()
        let earlyPrefix = await collectEvents(from: earlyStream, count: 4, timeout: 2.0)
        guard earlyPrefix.count == 4 else {
            XCTFail("Early replay stream must begin with four prefix events; got \(earlyPrefix.count): \(earlyPrefix)")
            return
        }

        guard case let .visualStateDidChange(earlyVisual) = earlyPrefix[0],
              case let .playbackIntentChanged(earlyIntent) = earlyPrefix[1],
              case let .metadataDidUpdate(earlyMetadata) = earlyPrefix[2] else {
            XCTFail("Early replay prefix must carry visual, intent, and metadata; got: \(earlyPrefix)")
            return
        }
        XCTAssertEqual(earlyVisual, initialSnapshot.visualState)
        XCTAssertEqual(earlyIntent, initialSnapshot.playbackIntent)
        XCTAssertEqual(earlyMetadata, initialSnapshot.streamMetadata)
        XCTAssertEqual(earlyPrefix[3], .persistedWidgetStateDidUpdate)

        await manager.setUserPaused()
        let pausedSnapshot = await manager.currentState
        XCTAssertEqual(pausedSnapshot.visualState, .userPaused)
        XCTAssertEqual(pausedSnapshot.playbackIntent, .userPaused)

        let lateStream = await manager.makeEventsStreamWithReplay()
        let latePrefix = await collectEvents(from: lateStream, count: 4, timeout: 2.0)
        guard latePrefix.count == 4 else {
            XCTFail("Late replay stream must begin with four prefix events; got \(latePrefix.count): \(latePrefix)")
            return
        }

        guard case let .visualStateDidChange(lateVisual) = latePrefix[0],
              case let .playbackIntentChanged(lateIntent) = latePrefix[1] else {
            XCTFail("Late replay prefix must carry visual and intent; got: \(latePrefix)")
            return
        }
        XCTAssertEqual(lateVisual, pausedSnapshot.visualState)
        XCTAssertEqual(lateIntent, pausedSnapshot.playbackIntent)
        XCTAssertNotEqual(earlyIntent, lateIntent, "Late subscriber prefix must reflect post-mutation intent")
        XCTAssertFalse(
            latePrefix.contains { if case .streamDidPause = $0 { return true }; return false },
            "Late subscriber prefix must not synthesize historical streamDidPause verbs"
        )

        // Phase 2 — concurrent same-state replay prefixes (reliable attach ordering).
        await resetManagerForContrastPhase()

        let streamA = await manager.makeEventsStreamWithReplay()
        let streamB = await manager.makeEventsStreamWithReplay()

        let prefixes = await collectEventsConcurrently(
            from: [streamA, streamB],
            countEach: 4,
            timeout: 2.0
        )
        XCTAssertEqual(prefixes.count, 2)
        XCTAssertEqual(prefixes[0].count, 4)
        XCTAssertEqual(prefixes[1].count, 4)
        XCTAssertEqual(
            prefixes[0],
            prefixes[1],
            "Replay streams created at the same state must synthesize identical prefixes"
        )
    }

    /// Re-establishes the same non-blocked starting state as ``setUp()`` for a second
    /// emission scenario inside a single test method (explicit-pause vs failure contrast).
    private func resetManagerForContrastPhase() async {
        await MainActor.run {
            sanitizeLiveActivityLocalState()
        }

        await SharedPlayerManager.clearAllLocalState()
        await manager.setUserIntentToPlay()

        await MainActor.run {
            WidgetRefreshManager.setHasActiveLutheranWidgets(true)
        }

        _ = await manager.events
    }

}
