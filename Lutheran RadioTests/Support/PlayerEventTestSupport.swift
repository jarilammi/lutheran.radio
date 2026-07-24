//
//  PlayerEventTestSupport.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 23.7.2026.
//
//  Canonical, shared collectors and assertions for `PlayerEvent` AsyncStream and
//  DEBUG notification-seam tests under the main-app XCTest host.
//
//  These helpers encode the subscribe-before-action, task-group + grace
//  cancellation, and seam-vs-replay hybrid contracts that keep event-driven
//  suites fast and terminating. Prefer this module over private re-copies in
//  individual test files.
//
//  - Important: Helpers are test-only. They do not change production emission,
//    privacy write suppression, or non-forcing observation.
//  - SeeAlso: ``SharedPlayerManager/events``,
//    ``SharedPlayerManager/makeEventsStreamWithReplay()``,
//    ``SharedPlayerManager/emit(_:)``, ``PlayerEvent``,
//    RadioLiveActivityManager (isRunningUnderTest + deferred observeExistingActivities),
//    docs/Event-Driven-Refactor-Roadmap.md (Tier 5),
//    CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
//

import XCTest
import WidgetSurface
@testable import Lutheran_Radio

// MARK: - Live Activity sanitization

/// Cancels Live Activity observation and nils the in-process activity reference.
///
/// Call on the main actor **before** ``SharedPlayerManager/clearAllLocalState()``
/// (or any path that may invoke ``RadioLiveActivityManager/endActivity()``).
/// Clearing `currentActivity` first keeps ActivityKit system-service work off
/// the XCTest host path when a stale activity remains on the simulator.
///
/// - SeeAlso: ``RadioLiveActivityManager/isRunningUnderTest``,
///   CODING_AGENT.md (Fast, Reliable Test Patterns).
@MainActor
func sanitizeLiveActivityLocalState() {
    let la = RadioLiveActivityManager.shared
    la.stopLocalUpdateTimer()
    la.activityObservationTask?.cancel()
    la.currentActivity = nil
}

// MARK: - AsyncStream collectors

/// Collects up to `count` events from the given stream while (optionally) performing an action.
///
/// **This is the recommended helper for observing live AsyncStream emissions in tests.**
///
/// Subscription to the stream begins immediately (so that emissions triggered by the
/// action are observed). The action is then executed inside the same bounded wait.
/// Collection completes when the requested count is reached or the timeout fires.
///
/// Why the specific shape (subscribe-first + inside-action + withTaskGroup + grace):
/// - The shared live `events` stream only delivers to *currently active* iterators.
/// - A separate collector task + bare timeout Task can leave the `await collectionTask.value`
///   hanging because cancellation of `for await` on a never-finishing stream is cooperative
///   and can be delayed by the XCTest host scheduler.
/// - `withTaskGroup` + explicit `cancelAll()` + a short grace sleep after cancel guarantees
///   the outer await always terminates.
///
/// - Parameters:
///   - stream: The `AsyncStream<PlayerEvent>` to observe (live `events` or replay stream).
///   - count: Maximum number of events to collect.
///   - timeout: Maximum wait time in seconds. Use a higher value (e.g. 10s) for simulator noise.
///   - action: Work that should cause new events. Called after subscription is attached.
/// - Returns: Collected events in yield order.
/// - SeeAlso: ``waitForEvent(from:timeout:matching:whilePerforming:)``,
///   ``collectSeamEvents(minimumCount:timeout:whilePerforming:)``,
///   CODING_AGENT.md ("Test Execution Patience and Fast, Reliable Test Patterns").
func collectEvents(
    from stream: AsyncStream<PlayerEvent>,
    count: Int,
    timeout: TimeInterval = 10.0,
    whilePerforming action: @escaping @Sendable () async -> Void = {}
) async -> [PlayerEvent] {
    // Start collection task first so we are subscribed before the triggering action.
    // Higher default (10s) for simulator / XCTest scheduling noise on the singleton stream.
    let collectionTask = Task<[PlayerEvent], Never> {
        var local: [PlayerEvent] = []
        var seen = 0
        for await event in stream {
            if Task.isCancelled { break }
            local.append(event)
            seen += 1
            if seen >= count { break }
        }
        return local
    }

    // Allow the consumer task to attach to the stream before we trigger emissions.
    await Task.yield()
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(100))

    await action()

    // Give the action a chance to propagate through the actor and yield on the continuation.
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(100))

    // Race the collector against a timeout. Using a task group + explicit cancelAll
    // guarantees the await on collectionTask.value never hangs the test indefinitely
    // even if cooperative cancellation of a for-await on the (never-finishing) live
    // AsyncStream is delayed by the test host scheduler. Past yields to the shared
    // live stream are only visible to iterators that are active at yield time.
    let result = await withTaskGroup(of: [PlayerEvent].self) { group -> [PlayerEvent] in
        group.addTask {
            await collectionTask.value
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(Int(timeout)))
            collectionTask.cancel()
            // Grace period for the cancelled for-await to observe cancellation and exit.
            try? await Task.sleep(for: .milliseconds(150))
            // Return partial progress so callers can XCTFail instead of trapping on subscripts.
            return await collectionTask.value
        }

        for await first in group {
            group.cancelAll()
            return first
        }
        return []
    }
    return result
}

/// Collects up to `countEach` events from multiple streams concurrently while
/// performing a single shared action after every iterator has attached.
///
/// Use this for multi-subscriber replay tests: each `makeEventsStreamWithReplay()`
/// call produces an independent stream, but live forwarding races are only meaningful
/// when all collectors subscribe before the one mutation that should fan out.
///
/// - Parameters:
///   - streams: Independent replay (or live) streams to observe in parallel.
///   - countEach: Maximum events to collect per stream.
///   - timeout: Per-stream bounded wait in seconds.
///   - action: Work expected to cause live emissions visible to every attached iterator.
/// - Returns: Collected events per stream in the same order as `streams`.
func collectEventsConcurrently(
    from streams: [AsyncStream<PlayerEvent>],
    countEach: Int,
    timeout: TimeInterval = 5.0,
    whilePerforming action: @escaping @Sendable () async -> Void = {}
) async -> [[PlayerEvent]] {
    let collectionTasks = streams.map { stream in
        Task<[PlayerEvent], Never> {
            var local: [PlayerEvent] = []
            var seen = 0
            for await event in stream {
                if Task.isCancelled { break }
                local.append(event)
                seen += 1
                if seen >= countEach { break }
            }
            return local
        }
    }

    await Task.yield()
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(150))

    await action()

    await Task.yield()
    try? await Task.sleep(for: .milliseconds(100))

    return await withTaskGroup(of: (Int, [PlayerEvent]).self) { group -> [[PlayerEvent]] in
        for (index, task) in collectionTasks.enumerated() {
            group.addTask {
                let events = await withTaskGroup(of: [PlayerEvent].self) { inner -> [PlayerEvent] in
                    inner.addTask { await task.value }
                    inner.addTask {
                        try? await Task.sleep(for: .seconds(Int(timeout)))
                        task.cancel()
                        try? await Task.sleep(for: .milliseconds(150))
                        return await task.value
                    }
                    for await first in inner {
                        inner.cancelAll()
                        return first
                    }
                    return []
                }
                return (index, events)
            }
        }

        var results = Array(repeating: [PlayerEvent](), count: streams.count)
        for await (index, events) in group {
            results[index] = events
        }
        return results
    }
}

/// Waits for the first event matching the predicate after (optionally) performing an action.
///
/// More resilient than fixed-count collection when the exact number of intervening events
/// is unknown (e.g. setup emissions, multiple side-effect emits from one public call).
///
/// - Parameters:
///   - stream: Live or replay stream.
///   - timeout: Max seconds to wait.
///   - match: Predicate for the desired event.
///   - action: Work expected to cause the matching emission.
/// - Returns: The first matching event, or nil on timeout.
func waitForEvent(
    from stream: AsyncStream<PlayerEvent>,
    timeout: TimeInterval = 10.0,
    matching match: @escaping @Sendable (PlayerEvent) -> Bool,
    whilePerforming action: @escaping @Sendable () async -> Void = {}
) async -> PlayerEvent? {
    let waiterTask = Task<PlayerEvent?, Never> {
        for await event in stream {
            if Task.isCancelled { break }
            if match(event) { return event }
        }
        return nil
    }

    await Task.yield()
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(100))

    await action()

    await Task.yield()
    try? await Task.sleep(for: .milliseconds(100))

    let result = await withTaskGroup(of: PlayerEvent?.self) { group -> PlayerEvent? in
        group.addTask {
            await waiterTask.value
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(Int(timeout)))
            waiterTask.cancel()
            try? await Task.sleep(for: .milliseconds(150))
            return nil
        }

        for await first in group {
            group.cancelAll()
            return first
        }
        return nil
    }
    return result
}

// MARK: - DEBUG notification seam collectors

/// Notification name posted synchronously from ``SharedPlayerManager/emit(_:)`` under DEBUG.
///
/// Prefer seam collectors for emission-order assertions; the seam is not subject to
/// AsyncStream iterator attach races in the XCTest host.
let playerEventEmittedForTestNotification = Notification.Name("PlayerEventEmittedForTest")

/// Helper box to avoid escaping capture issues with observer token.
///
/// - SAFETY: `@unchecked Sendable` because the token is only mutated on the main
///   notification queue and torn down once via ``OneShotResume``.
private final class EmissionObserverBox: @unchecked Sendable {
    var token: NSObjectProtocol?
}

/// One-shot box for safe single resume of a continuation.
///
/// Uses `NSLock` because grace-delay `Task`s spawned from the notification
/// observer can race when `minimumCount` is reached on one event and trailing
/// emissions arrive before the grace sleep completes.
///
/// - SAFETY: `@unchecked Sendable` with internal lock serialization for the
///   single-resume flag; required for use across notification and timeout tasks.
private final class OneShotResume: @unchecked Sendable {
    private let lock = NSLock()
    private var did = false
    func markAndCheck() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if did { return false }
        did = true
        return true
    }
}

/// Collects live emissions via the DEBUG notification seam until `terminal` matches
/// an event (plus a short grace for trailing async emissions) or `timeout` elapses.
///
/// Prefer this over ``collectSeamEvents(minimumCount:timeout:whilePerforming:)`` when
/// the action completes asynchronously after the triggering call returns (for example
/// engine `switchToStream` prep followed by an authoritative metadata clear).
func collectSeamEventsUntil(
    timeout: TimeInterval = 8.0,
    until terminal: @escaping @Sendable (PlayerEvent) -> Bool,
    whilePerforming action: @escaping @Sendable () async -> Void = {}
) async -> [PlayerEvent] {
    // SAFETY: `@unchecked Sendable` collector mutated only on the main notification
    // queue and torn down once via OneShotResume before continuation resume.
    final class SeamCollector: @unchecked Sendable {
        var events: [PlayerEvent] = []
        var token: NSObjectProtocol?
    }

    let collector = SeamCollector()
    let oneShot = OneShotResume()

    return await withCheckedContinuation { (cont: CheckedContinuation<[PlayerEvent], Never>) in
        collector.token = NotificationCenter.default.addObserver(
            forName: playerEventEmittedForTestNotification,
            object: nil,
            queue: .main
        ) { note in
            if let event = note.userInfo?["event"] as? PlayerEvent {
                collector.events.append(event)
                if terminal(event) {
                    Task { @Sendable in
                        try? await Task.sleep(for: .milliseconds(400))
                        if oneShot.markAndCheck() {
                            if let token = collector.token {
                                NotificationCenter.default.removeObserver(token)
                                collector.token = nil
                            }
                            cont.resume(returning: collector.events)
                        }
                    }
                }
            }
        }

        Task { @Sendable in
            await action()
        }

        Task { @Sendable in
            try? await Task.sleep(for: .seconds(Int(timeout)))
            if oneShot.markAndCheck() {
                if let token = collector.token {
                    NotificationCenter.default.removeObserver(token)
                    collector.token = nil
                }
                cont.resume(returning: collector.events)
            }
        }
    }
}

/// Collects live emissions via the DEBUG notification seam until `minimumCount`
/// events arrive or `timeout` elapses.
///
/// Prefer this over replay-stream collection when asserting canonical emission order
/// from `stop()` and similar bursts — the seam is posted synchronously from `emit(_:)`
/// and is not subject to AsyncStream iterator attach races in the test host.
func collectSeamEvents(
    minimumCount: Int,
    timeout: TimeInterval = 5.0,
    whilePerforming action: @escaping @Sendable () async -> Void = {}
) async -> [PlayerEvent] {
    // SAFETY: `@unchecked Sendable` collector mutated only on the main notification
    // queue and torn down once via OneShotResume before continuation resume.
    final class SeamCollector: @unchecked Sendable {
        var events: [PlayerEvent] = []
        var token: NSObjectProtocol?
    }

    let collector = SeamCollector()
    let oneShot = OneShotResume()

    return await withCheckedContinuation { (cont: CheckedContinuation<[PlayerEvent], Never>) in
        collector.token = NotificationCenter.default.addObserver(
            forName: playerEventEmittedForTestNotification,
            object: nil,
            queue: .main
        ) { note in
            if let event = note.userInfo?["event"] as? PlayerEvent {
                collector.events.append(event)
                // Schedule exactly one grace window when the threshold is first reached
                // so trailing async emissions (e.g. `.persistedWidgetStateDidUpdate`)
                // are captured without spawning duplicate grace tasks.
                if collector.events.count == minimumCount {
                    // Grace for trailing async emissions (e.g. `.persistedWidgetStateDidUpdate`
                    // from `saveCurrentState()` immediately after `streamDidStop`).
                    Task { @Sendable in
                        try? await Task.sleep(for: .milliseconds(400))
                        if oneShot.markAndCheck() {
                            if let token = collector.token {
                                NotificationCenter.default.removeObserver(token)
                                collector.token = nil
                            }
                            cont.resume(returning: collector.events)
                        }
                    }
                }
            }
        }

        Task { @Sendable in
            await action()
        }

        Task { @Sendable in
            try? await Task.sleep(for: .seconds(Int(timeout)))
            if oneShot.markAndCheck() {
                if let token = collector.token {
                    NotificationCenter.default.removeObserver(token)
                    collector.token = nil
                }
                cont.resume(returning: collector.events)
            }
        }
    }
}

/// Waits (via NotificationCenter) for an emission of a specific `PlayerEvent`.
///
/// Uses a checked continuation + main-queue observer for reliable delivery
/// in the simulator test host. Complements the AsyncStream (the DEBUG
/// notification is posted from `emit` at the same time as the yield).
func waitForEmission(
    matching match: @escaping @Sendable (PlayerEvent) -> Bool,
    timeout: TimeInterval = 5.0,
    whilePerforming action: @escaping @Sendable () async -> Void = {}
) async -> PlayerEvent? {
    let box = EmissionObserverBox()
    let oneShot = OneShotResume()
    return await withCheckedContinuation { (cont: CheckedContinuation<PlayerEvent?, Never>) in
        box.token = NotificationCenter.default.addObserver(
            forName: playerEventEmittedForTestNotification,
            object: nil,
            queue: .main
        ) { note in
            if let event = note.userInfo?["event"] as? PlayerEvent, match(event) {
                if oneShot.markAndCheck() {
                    if let t = box.token {
                        NotificationCenter.default.removeObserver(t)
                        box.token = nil
                    }
                    cont.resume(returning: event)
                }
            }
        }

        Task { @Sendable in
            await action()
        }

        Task { @Sendable in
            try? await Task.sleep(for: .seconds(Int(timeout)))
            if oneShot.markAndCheck() {
                if let t = box.token {
                    NotificationCenter.default.removeObserver(t)
                    box.token = nil
                }
                cont.resume(returning: nil)
            }
        }
    }
}

// MARK: - Ordered subsequence assertion

/// Verifies that `events` contains a subsequence matching the predicates in order.
///
/// Each matcher must match exactly one later event than the previous match. This
/// supports emission-order assertions when unrelated events may appear between
/// the canonical mutation → transition → persist steps (for example setup noise
/// or asynchronous side effects).
///
/// - Parameters:
///   - events: Collected emissions in yield order.
///   - pattern: Ordered predicates describing the required subsequence.
///   - file: Source file for `XCTFail` (defaults to call site).
///   - line: Source line for `XCTFail` (defaults to call site).
func assertEvents(
    _ events: [PlayerEvent],
    containInOrder pattern: [@Sendable (PlayerEvent) -> Bool],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    var searchStart = events.startIndex
    for (index, matcher) in pattern.enumerated() {
        guard let matchIndex = events[searchStart...].firstIndex(where: matcher) else {
            XCTFail(
                "Expected ordered emission at position \(index) was not found. Collected: \(events)",
                file: file,
                line: line
            )
            return
        }
        searchStart = events.index(after: matchIndex)
    }
}

// MARK: - Shared suite isolation (event / media-surface hosts)

/// Cheap, deterministic isolation for main-host suites that exercise
/// ``SharedPlayerManager`` emission, media-surface coordination, cold-launch hygiene,
/// or DEBUG transport latency.
///
/// Order is intentional: Live Activity local nil → clearAllLocalState → enable
/// widgets-active privacy gate for observability → cancel replay forwarding →
/// suspend Tier 2 observation → pre-warm ``events``.
///
/// - Parameters:
///   - manager: Actor under test (defaults to the process singleton).
/// - SeeAlso: ``sanitizeLiveActivityLocalState()``,
///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
func prepareSharedPlayerManagerEventTestIsolation(
    manager: SharedPlayerManager = .shared
) async {
    await MainActor.run {
        sanitizeLiveActivityLocalState()
    }

    await SharedPlayerManager.clearAllLocalState()
    await manager.setUserIntentToPlay()

    await MainActor.run {
        WidgetRefreshManager.setHasActiveLutheranWidgets(true)
    }

    await manager.cancelReplayForwarding()
    await MainActor.run {
        WidgetRefreshManager._test_setSuppressPlayerEventObservation(true)
        WidgetRefreshManager.shared._test_suspendPlayerEventObservation()
    }
    await Task.yield()
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(150))

    _ = await manager.events
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(100))
}

/// Symmetric tear-down for suites that call ``prepareSharedPlayerManagerEventTestIsolation``.
///
/// Resets DEBUG observation / gate / Now Playing coordination seams so later tests
/// do not inherit isolation flags.
///
/// - Parameters:
///   - manager: Actor under test (defaults to the process singleton).
func tearDownSharedPlayerManagerEventTestIsolation(
    manager: SharedPlayerManager = .shared
) async {
    await manager.cancelReplayForwarding()

    await MainActor.run {
        sanitizeLiveActivityLocalState()
        WidgetRefreshManager.setSessionTeardownInProgress(false)
        WidgetRefreshManager._test_setBypassUITestModeForRefreshGateObservation(false)
        WidgetRefreshManager._test_setRecordRefreshIfNeededGateOutcomes(false)
        WidgetRefreshManager._test_setSuppressPlayerEventObservation(false)
        SharedPlayerManager._test_setSimulateWidgetProcessContext(false)
        SharedPlayerManager._test_setBypassUITestModeForNowPlayingUpdates(false)
        SharedPlayerManager._test_setRecordMediaSurfaceCoordinationOrder(false)
        SharedPlayerManager._test_clearMediaSurfaceCoordinationOrderLog()
    }
}

/// Picks a stream guaranteed to differ from the engine's current selection so
/// `switchToStream` exercises the language-change silent-stop path under test.
///
/// - Parameters:
///   - streams: Catalog from ``SharedPlayerManager/availableStreams`` or the engine list.
/// - Returns: A stream whose language code differs from the current engine selection.
func targetStreamDifferentFromCurrent(
    in streams: [DirectStreamingPlayer.Stream]
) async -> DirectStreamingPlayer.Stream {
    await MainActor.run {
        let current = DirectStreamingPlayer.shared.selectedStream.languageCode
        return streams.first { $0.languageCode != current } ?? streams[1]
    }
}
