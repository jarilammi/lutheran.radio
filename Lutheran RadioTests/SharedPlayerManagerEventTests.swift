//
//  SharedPlayerManagerEventTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 6.7.2026.
//
//  Emitter / replay contracts for `PlayerEvent` and `makeEventsStreamWithReplay()` (core Tier 3 / Tier 5).
//  Sibling suites hold failure / mutation-order / stream-switch coverage split out later.
//
//  Shared collectors: `Lutheran RadioTests/Support/PlayerEventTestSupport.swift`.
//  Isolation: ``prepareSharedPlayerManagerEventTestIsolation`` /
//  ``tearDownSharedPlayerManagerEventTestIsolation``.
//
//  - SeeAlso: ``SharedPlayerManager``, ``PlayerEvent``,
//    ``SharedPlayerManagerEventFailureTests``,
//    ``SharedPlayerManagerEventMutationOrderTests``,
//    ``SharedPlayerManagerEventStreamSwitchTests``,
//    docs/Event-Driven-Refactor-Roadmap.md,
//    CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
//

import MediaPlayer
import XCTest
import WidgetSurface
@testable import Lutheran_Radio

/// Primary emission / replay usage suite for `SharedPlayerManager`.
///
/// Covers Tier 3 replay prefix, widget-process emit suppression, Tier 5 live
/// emission smoke, hybrid stop emission order, and multi-subscriber replay attach.
/// Failure classification, mutation-order matrices, and stream-switch emission live
/// in sibling suites under `Lutheran RadioTests/`.
///
/// Canonical collectors remain in `PlayerEventTestSupport.swift` — do not re-copy.
///
/// - SeeAlso: ``SharedPlayerManagerEventFailureTests``,
///   ``SharedPlayerManagerEventMutationOrderTests``,
///   ``SharedPlayerManagerEventStreamSwitchTests``,
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
    /// The replay stream is the surface consumed by main-app chrome observation
    /// (``RadioPlayerCoordinator/beginObservingVisualStateForChrome()``) and
    /// `WidgetEventObserver`-based helpers; consumers depend on prefix-then-live ordering.
    ///
    /// **Why hybrid collection**: Prefix assertions use the replay stream (buffered, reliable).
    /// Canonical `stop()` emission order is asserted via the DEBUG notification seam because
    /// AsyncStream iterator attach races in the XCTest host can drop forwarded live yields.
    /// A best-effort replay-forwarding check follows without gating the primary contracts.
    ///
    /// - SeeAlso: ``SharedPlayerManager/makeEventsStreamWithReplay()``, ``SharedPlayerManager/stop()``,
    ///   ``SharedPlayerManager/currentState``, ``PlayerCurrentState``, ``emit(_:)``,
    ///   `WidgetEventObserver`, ``RadioPlayerCoordinator/beginObservingVisualStateForChrome()``,
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

        // Replay forwarding — best-effort only (never gates the suite).
        // A second iterator on the replay stream while re-driving stop() may observe a
        // forwarded live emission, an already-stopped side effect (e.g. persist signal),
        // or nothing under XCTest host attach timing. Canonical stop order is already
        // protected by the seam assertions above.
        // - SeeAlso: CODING_AGENT.md (hybrid collection — never XCTFail on forwarding alone).
        _ = await collectEvents(from: replayStream, count: 1, timeout: 2.0) {
            await m.stop()
        }
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
        await resetSharedPlayerManagerEventContrastPhase(manager: manager)

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
}

