//
//  PlayerEventSubscriberEventTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 7.7.2026.
//

import XCTest
@testable import Lutheran_Radio

/// Unit tests for the Tier 2 ``PlayerEventSubscriber`` consumer in the main-app player UI layer.
///
/// Coverage is split across the replay attachment path and the observable update rules:
///
/// - **Replay prefix:** ``beginObserving()`` seeds ``lastObservedIntent`` and accumulates the
///   four synthesized events from ``SharedPlayerManager/makeEventsStreamWithReplay()``.
/// - **Observable updates:** ``_test_applyPlayerEvent(_:)`` drives ``handle(_:)`` for intent and
///   non-intent payloads. Live ``events`` forwarding shares the single ``AsyncStream`` iterator
///   with ``WidgetRefreshManager``; emitter-side forwarding contracts remain in
///   ``SharedPlayerManagerEventTests``.
/// - **Cancellation:** ``cancel()`` ends replay-stream observation so later emissions do not
///   reach ``handle(_:)``.
///
/// - SeeAlso: ``PlayerEventSubscriber/beginObserving()``, ``PlayerEventSubscriber/eventCount``,
///   ``PlayerEventSubscriber/lastObservedIntent``, ``SharedPlayerManager/makeEventsStreamWithReplay()``,
///   ``WidgetEventObserver``, ``RadioPlayerView``, ``SharedPlayerManagerEventTests``,
///   ``WidgetRefreshManagerEventTests``, docs/Event-Driven-Refactor-Roadmap.md (Tier 2 / Tier 5),
///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
@MainActor
final class PlayerEventSubscriberEventTests: XCTestCase {

    private let manager = SharedPlayerManager.shared
    private var activeSubscriber: PlayerEventSubscriber?

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()

        WidgetRefreshManager._test_setSuppressPlayerEventObservation(true)
        await MainActor.run {
            WidgetRefreshManager.shared._test_suspendPlayerEventObservation()
        }
        await Task.yield()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(150))

        await MainActor.run {
            let la = RadioLiveActivityManager.shared
            la.stopLocalUpdateTimer()
            la.activityObservationTask?.cancel()
            la.currentActivity = nil
        }

        await SharedPlayerManager.clearAllLocalState()
        await manager.setUserIntentToPlay()

        await MainActor.run {
            WidgetRefreshManager.setHasActiveLutheranWidgets(true)
        }

        _ = await manager.events
    }

    override func tearDown() async throws {
        activeSubscriber?.cancel()
        activeSubscriber = nil
        await manager.cancelReplayForwarding()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
        WidgetRefreshManager._test_setSuppressPlayerEventObservation(false)

        await MainActor.run {
            let la = RadioLiveActivityManager.shared
            la.stopLocalUpdateTimer()
            la.activityObservationTask?.cancel()
            la.currentActivity = nil
        }
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func waitForEventCount(
        on subscriber: PlayerEventSubscriber,
        atLeast minimum: Int,
        timeout: TimeInterval = 10.0
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if subscriber.eventCount >= minimum { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
        }
        return subscriber.eventCount >= minimum
    }

    private func beginObservingAndAwaitReplayPrefix(
        _ subscriber: PlayerEventSubscriber
    ) async {
        activeSubscriber?.cancel()
        activeSubscriber = subscriber
        await subscriber.beginObserving()
        await Task.yield()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(150))

        let satisfied = await waitForEventCount(on: subscriber, atLeast: 4)
        XCTAssertTrue(
            satisfied,
            "Replay prefix must deliver four events; got eventCount=\(subscriber.eventCount)"
        )
    }

    // MARK: - Replay prefix

    /// Verifies that ``beginObserving()`` seeds intent from the actor and accumulates the
    /// four-event replay prefix into ``eventCount`` with ``lastObservedIntent`` aligned to
    /// ``SharedPlayerManager/currentState``.
    func testBeginObservingDeliversReplayPrefixAndAlignsObservableState() async {
        await manager.setUserIntentToPlay()
        let snapshot = await manager.currentState

        let subscriber = PlayerEventSubscriber()
        await beginObservingAndAwaitReplayPrefix(subscriber)

        XCTAssertEqual(subscriber.eventCount, 4)
        XCTAssertEqual(subscriber.lastObservedIntent, snapshot.playbackIntent)
    }

    // MARK: - Observable update rules

    /// Verifies that ``handle(_:)`` updates ``lastObservedIntent`` for
    /// ``PlayerEvent/playbackIntentChanged(_:)`` and increments ``eventCount`` for metadata
    /// without mutating the observed intent.
    func testHandleUpdatesObservableStateForIntentAndNonIntentEvents() async {
        let subscriber = PlayerEventSubscriber()

        await subscriber._test_applyPlayerEvent(.playbackIntentChanged(.userPaused))
        XCTAssertEqual(subscriber.eventCount, 1)
        XCTAssertEqual(subscriber.lastObservedIntent, .userPaused)

        let metadata = StreamProgramMetadata.from(rawICYMetadata: "Test Program • Speaker")
        await subscriber._test_applyPlayerEvent(.metadataDidUpdate(metadata))
        XCTAssertEqual(subscriber.eventCount, 2)
        XCTAssertEqual(subscriber.lastObservedIntent, .userPaused)
    }

    // MARK: - Cancellation

    /// Verifies that ``cancel()`` stops replay-stream delivery so ``eventCount`` and
    /// ``lastObservedIntent`` remain unchanged when the emitter produces new events.
    func testCancelStopsReplayStreamObservation() async {
        let subscriber = PlayerEventSubscriber()
        await beginObservingAndAwaitReplayPrefix(subscriber)

        let countAfterPrefix = subscriber.eventCount
        let intentAfterPrefix = subscriber.lastObservedIntent
        subscriber.cancel()

        await manager.setUserPaused()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(subscriber.eventCount, countAfterPrefix)
        XCTAssertEqual(subscriber.lastObservedIntent, intentAfterPrefix)
    }
}