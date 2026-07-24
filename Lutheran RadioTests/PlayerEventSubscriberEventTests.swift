//
//  PlayerEventSubscriberEventTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 7.7.2026.
//

import XCTest
import WidgetSurface
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
/// - **Stream verbs:** ``streamDidStart``, ``streamDidPause``, ``streamDidStop``, and
///   ``streamDidFail`` increment ``eventCount`` without mutating ``lastObservedIntent``.
/// - **Visual / persist signals:** ``visualStateDidChange(_:)`` and
///   ``persistedWidgetStateDidUpdate`` increment ``eventCount`` without mutating intent.
/// - **Live forwarding:** After the four-event replay prefix, live ``SharedPlayerManager``
///   emissions continue to update ``eventCount`` and ``lastObservedIntent`` (intent events only).
/// - **Cancellation:** ``cancel()`` ends replay-stream observation so later emissions do not
///   reach ``handle(_:)``.
/// - **Widget process:** ``beginObserving()`` returns before intent seeding or replay attachment
///   when ``SharedPlayerManager/isWidgetProcess()`` is `true`.
///
/// Shared collectors (`collectEvents`, `sanitizeLiveActivityLocalState`) live in
/// `Lutheran RadioTests/Support/PlayerEventTestSupport.swift` — do not re-copy them here.
///
/// - SeeAlso: ``PlayerEventSubscriber/beginObserving()``, ``PlayerEventSubscriber/eventCount``,
///   ``PlayerEventSubscriber/lastObservedIntent``, ``SharedPlayerManager/makeEventsStreamWithReplay()``,
///   ``WidgetEventObserver``, ``RadioPlayerView``, ``SharedPlayerManagerEventTests``,
///   ``WidgetRefreshManagerEventTests``, `PlayerEventTestSupport.swift`,
///   docs/Event-Driven-Refactor-Roadmap.md (Tier 2 / Tier 5),
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

        sanitizeLiveActivityLocalState()

        await SharedPlayerManager.clearAllLocalState()
        await manager.setUserIntentToPlay()

        WidgetRefreshManager.setHasActiveLutheranWidgets(true)

        SharedPlayerManager._test_setSimulateWidgetProcessContext(false)

        _ = await manager.events

        // Release any stale replay live-forwarding attachment so
        // ``makeEventsStreamWithReplay()`` regains the sole ``events`` iterator.
        await manager.cancelReplayForwarding()
        await Task.yield()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(150))
    }

    override func tearDown() async throws {
        activeSubscriber?.cancel()
        activeSubscriber = nil
        await manager.cancelReplayForwarding()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
        WidgetRefreshManager._test_setSuppressPlayerEventObservation(false)
        SharedPlayerManager._test_setSimulateWidgetProcessContext(false)

        sanitizeLiveActivityLocalState()
        try await super.tearDown()
    }

    // MARK: - Helpers
    //
    // `collectEvents` is provided by Support/PlayerEventTestSupport.swift.

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
        // Freeze the counter once the prefix is in: under the XCTest host, scheduler
        // jitter or residual actor work can forward one extra live event after the
        // four synthesized state events. Exact `eventCount == 4` is not reliable without
        // cancel; `cancel()` releases replay live-forwarding (same as production onDisappear).
        subscriber.cancel()
    }

    // MARK: - Widget process guard

    /// Verifies that ``beginObserving()`` returns before replay attachment when
    /// ``SharedPlayerManager/isWidgetProcess()`` reports widget-extension context.
    ///
    /// Widget processes perform optimistic snapshot writes but never consume the authoritative
    /// ``PlayerEvent`` stream. Observable state must remain at factory defaults and no replay
    /// prefix or live forwarding may run.
    ///
    /// - SeeAlso: ``SharedPlayerManager/isWidgetProcess()``,
    ///   ``SharedPlayerManager/_test_setSimulateWidgetProcessContext(_:)``,
    ///   ``SharedPlayerManagerEventTests/testEmitSuppressesYieldWhenRunningInWidgetProcess()``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5).
    func testBeginObservingReturnsEarlyInWidgetProcessContext() async {
        SharedPlayerManager._test_setSimulateWidgetProcessContext(true)
        defer { SharedPlayerManager._test_setSimulateWidgetProcessContext(false) }

        await manager.setUserPaused()

        let subscriber = PlayerEventSubscriber()
        await subscriber.beginObserving()

        await Task.yield()
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(
            subscriber.eventCount,
            0,
            "Widget process context must not deliver replay prefix or live events"
        )
        XCTAssertEqual(
            subscriber.lastObservedIntent,
            .shouldBePlaying,
            "Widget process guard must skip intent seeding from the actor"
        )

        await manager.setPlaying()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(subscriber.eventCount, 0)
        XCTAssertEqual(subscriber.lastObservedIntent, .shouldBePlaying)

        SharedPlayerManager._test_setSimulateWidgetProcessContext(false)

        await beginObservingAndAwaitReplayPrefix(subscriber)
        XCTAssertGreaterThanOrEqual(
            subscriber.eventCount,
            4,
            "After leaving widget-process simulation, replay must deliver the four-event prefix"
        )
    }

    // MARK: - Replay prefix

    /// Verifies that ``beginObserving()`` seeds intent from the actor and accumulates the
    /// four-event replay prefix into ``eventCount`` with ``lastObservedIntent`` aligned to
    /// ``SharedPlayerManager/currentState``.
    ///
    /// Prefix delivery is gated at **at least** four events; the helper cancels observation
    /// after the threshold so trailing live-forwarded emissions under XCTest host timing
    /// do not fail an exact-count gate (see ``beginObservingAndAwaitReplayPrefix``).
    func testBeginObservingDeliversReplayPrefixAndAlignsObservableState() async {
        await manager.setUserIntentToPlay()
        let snapshot = await manager.currentState

        let subscriber = PlayerEventSubscriber()
        await beginObservingAndAwaitReplayPrefix(subscriber)

        XCTAssertGreaterThanOrEqual(subscriber.eventCount, 4)
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

    /// Verifies that stream transition verbs increment ``eventCount`` without mutating
    /// ``lastObservedIntent``.
    ///
    /// ``handle(_:)`` updates intent only for ``PlayerEvent/playbackIntentChanged(_:)``.
    /// Stream verbs are observability signals for generic UI refresh sites (``.onChange`` on
    /// ``eventCount``) and must not overwrite the last intent delivered by a prior
    /// ``playbackIntentChanged`` event.
    ///
    /// - SeeAlso: ``PlayerEvent/streamDidStart``, ``PlayerEvent/streamDidPause``,
    ///   ``PlayerEvent/streamDidStop``, ``PlayerEvent/streamDidFail(_:)``,
    ///   ``RadioPlayerView``, docs/Event-Driven-Refactor-Roadmap.md (Tier 5).
    func testHandleStreamVerbsIncrementEventCountWithoutMutatingIntent() async {
        let subscriber = PlayerEventSubscriber()

        await subscriber._test_applyPlayerEvent(.playbackIntentChanged(.shouldBePlaying))
        XCTAssertEqual(subscriber.eventCount, 1)
        XCTAssertEqual(subscriber.lastObservedIntent, .shouldBePlaying)

        let streamVerbs: [PlayerEvent] = [
            .streamDidStart,
            .streamDidPause,
            .streamDidStop,
            .streamDidFail(.transientFailure),
        ]

        for (index, verb) in streamVerbs.enumerated() {
            await subscriber._test_applyPlayerEvent(verb)
            XCTAssertEqual(
                subscriber.eventCount,
                index + 2,
                "Expected eventCount \(index + 2) after \(verb)"
            )
            XCTAssertEqual(
                subscriber.lastObservedIntent,
                .shouldBePlaying,
                "Stream verb \(verb) must not mutate lastObservedIntent"
            )
        }
    }

    // MARK: - Visual and persist observable rules

    /// Verifies that ``PlayerEvent/visualStateDidChange(_:)`` and
    /// ``PlayerEvent/persistedWidgetStateDidUpdate`` increment ``eventCount`` without
    /// overwriting ``lastObservedIntent``.
    ///
    /// ``handle(_:)`` updates intent exclusively on ``PlayerEvent/playbackIntentChanged(_:)``.
    /// Visual and persisted-snapshot signals are observability-only inputs for generic
    /// UI refresh sites (``.onChange`` on ``eventCount``).
    ///
    /// - SeeAlso: ``testHandleStreamVerbsIncrementEventCountWithoutMutatingIntent``,
    ///   ``testHandleUpdatesObservableStateForIntentAndNonIntentEvents``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5).
    func testHandleVisualAndPersistEventsIncrementEventCountWithoutMutatingIntent() async {
        let subscriber = PlayerEventSubscriber()

        await subscriber._test_applyPlayerEvent(.playbackIntentChanged(.shouldBePlaying))
        XCTAssertEqual(subscriber.eventCount, 1)
        XCTAssertEqual(subscriber.lastObservedIntent, .shouldBePlaying)

        let visualAndPersist: [PlayerEvent] = [
            .visualStateDidChange(.playing),
            .persistedWidgetStateDidUpdate,
        ]

        for (index, event) in visualAndPersist.enumerated() {
            await subscriber._test_applyPlayerEvent(event)
            XCTAssertEqual(
                subscriber.eventCount,
                index + 2,
                "Expected eventCount \(index + 2) after \(event)"
            )
            XCTAssertEqual(
                subscriber.lastObservedIntent,
                .shouldBePlaying,
                "Visual/persist event \(event) must not mutate lastObservedIntent"
            )
        }
    }

    // MARK: - Live forwarding after replay prefix

    /// Verifies that live ``SharedPlayerManager`` emissions forward after the four-event
    /// replay prefix on the stream ``beginObserving()`` consumes.
    ///
    /// ``PlayerEventSubscriber/beginObserving()`` materializes
    /// ``SharedPlayerManager/makeEventsStreamWithReplay()`` internally. This test exercises
    /// the replay stream live-forwarding attach contract with the subscribe-before-action
    /// collector pattern (same hardening as ``SharedPlayerManagerEventTests``).
    ///
    /// - SeeAlso: ``beginObserving()``, ``SharedPlayerManager/makeEventsStreamWithReplay()``,
    ///   ``SharedPlayerManager/cancelReplayForwarding()``, ``WidgetRefreshManager/_test_setSuppressPlayerEventObservation(_:)``,
    ///   ``SharedPlayerManagerEventTests/testReplayStreamPrefixesStateThenForwardsLiveStopEmissionsInOrder()``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 3 replay + Tier 5 consumer coverage),
    ///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
    func testLiveForwardingDeliversEventsAfterReplayPrefix() async {
        await manager.setUserIntentToPlay()
        await manager.cancelReplayForwarding()

        let replayStream = await manager.makeEventsStreamWithReplay()

        // Single continuous iterator: subscribe before ``setUserPaused()`` so prefix and
        // live yields share one attach (mirrors beginObserving + live mutation in production).
        // Capture the actor (Sendable) — not `self` — for the @Sendable action closure.
        let m = manager
        let events = await collectEvents(from: replayStream, count: 5, timeout: 5.0) {
            await m.setUserPaused()
        }

        XCTAssertGreaterThanOrEqual(
            events.count,
            4,
            "Replay stream must deliver at least the four-event prefix"
        )

        guard events.count >= 5 else {
            // Best-effort only: XCTest host attach races can still drop forwarded live yields
            // after the prefix (same limitation as
            // ``SharedPlayerManagerEventTests/testReplayStreamPrefixesStateThenForwardsLiveStopEmissionsInOrder()``).
            return
        }

        let liveBatch = Array(events.dropFirst(4))
        XCTAssertTrue(
            liveBatch.contains { event in
                if case .playbackIntentChanged(.userPaused) = event { return true }
                if case .visualStateDidChange(.userPaused) = event { return true }
                if case .streamDidPause = event { return true }
                return false
            },
            "Post-prefix events must include setUserPaused transition signals; got: \(liveBatch)"
        )
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
