//
//  SharedPlayerManagerEventTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 6.7.2026.
//

import XCTest
@testable import Lutheran_Radio

/// Unit tests for the event-driven surfaces of `SharedPlayerManager`:
/// `events` AsyncStream emission and `makeEventsStreamWithReplay()` + `currentState`.
///
/// These tests provide the first coverage for the `PlayerEvent` vocabulary and replay
/// contract (Tier 4 / Tier 5 backlog item in the roadmap). All tests are additive;
/// they exercise the public actor surfaces without altering any production paths.
///
/// - SeeAlso: ``PlayerEvent``, ``SharedPlayerManager/events``, ``SharedPlayerManager/makeEventsStreamWithReplay()``,
///   ``SharedPlayerManager/currentState``, ``PlayerCurrentState``,
///   docs/Event-Driven-Refactor-Roadmap.md (Tier 4 tests item),
///   CODING_AGENT.md (test documentation, Single Source of Truth Principles).
final class SharedPlayerManagerEventTests: XCTestCase {

    private let manager = SharedPlayerManager.shared

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()
        // Establish a clean, known starting state for each test.
        // clearAllLocalState resets intent/visual to the cleared blocker (privacy semantics).
        // Follow with explicit user intent to reach a non-blocked prePlay-like state.
        await SharedPlayerManager.clearAllLocalState()
        await manager.setUserIntentToPlay()
    }

    // MARK: - Event Collection Helper

    /// Collects up to `count` events from the given stream while (optionally) performing an action.
    ///
    /// Subscription to the stream begins immediately (so that emissions triggered by the
    /// action are observed). The action is then executed. Collection completes when the
    /// requested count is reached or the timeout fires. Designed to be safe under
    /// strict Swift 6 concurrency.
    ///
    /// - Parameters:
    ///   - stream: The `AsyncStream<PlayerEvent>` to observe (live `events` or replay stream).
    ///   - count: Maximum number of events to collect.
    ///   - timeout: Maximum wait time in seconds.
    ///   - action: Work that should cause new events. Called synchronously after subscription begins.
    /// - Returns: Collected events in yield order.
    private func collectEvents(
        from stream: AsyncStream<PlayerEvent>,
        count: Int,
        timeout: TimeInterval = 2.0,
        whilePerforming action: () async -> Void = {}
    ) async -> [PlayerEvent] {
        // Start collection task first so we are subscribed before the triggering action.
        let collectionTask = Task<[PlayerEvent], Never> {
            var local: [PlayerEvent] = []
            var seen = 0
            for await event in stream {
                local.append(event)
                seen += 1
                if seen >= count { break }
            }
            return local
        }

        // Allow the consumer task to attach to the stream before we trigger emissions.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(30))

        await action()

        // Cooperative timeout
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(Int(timeout)))
            collectionTask.cancel()
        }

        let result = await collectionTask.value
        timeoutTask.cancel()
        return result
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

        // Optional: prove that live events continue to flow after the replay prefix.
        // Trigger a pause and verify a live event arrives on the same stream instance.
        let more = await collectEvents(from: replayStream, count: 1) {
            await manager.stop()
        }
        XCTAssertFalse(more.isEmpty, "After replay prefix, the stream must forward subsequent live emissions")
        XCTAssertTrue(
            more.contains(.streamDidStop) || more.contains { if case .playbackIntentChanged(.userPaused) = $0 { return true }; return false },
            "Live follow-on events after replay must include stop/intent changes"
        )
    }
}
