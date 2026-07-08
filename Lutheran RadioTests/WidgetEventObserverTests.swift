//
//  WidgetEventObserverTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 9.7.2026.
//

import XCTest
@testable import Lutheran_Radio

/// White-box unit tests for the shared ``WidgetEventObserver`` observation helper.
///
/// Coverage targets the consolidated AsyncSequence wiring used by
/// ``WidgetRefreshManager`` (``PlayerEvent`` stream) and
/// ``RadioLiveActivityManager`` (Live Activity attribute events):
///
/// - **Element delivery:** handlers receive yielded elements on the main actor in order.
/// - **Termination:** optional ``onTermination`` runs after normal stream completion.
/// - **Cancel / restart:** ``cancel()`` clears ``task``; a subsequent ``beginObserving``
///   cancels the prior observation task so only the new sequence delivers.
///
/// Tests use lightweight in-memory ``AsyncStream`` fixtures — no ``SharedPlayerManager``,
/// WidgetCenter, or ActivityKit IPC.
///
/// - SeeAlso: ``WidgetEventObserver/beginObserving(_:onElement:onTermination:)``,
///   ``WidgetEventObserver/beginObserving(unsafeSequence:onElement:onTermination:)``,
///   ``WidgetEventObserver/cancel()``, ``WidgetEventObserver/task``,
///   ``WidgetRefreshManagerEventTests``, ``PlayerEventSubscriberEventTests``,
///   docs/Event-Driven-Refactor-Roadmap.md (Tier 2 polish / Tier 5),
///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
@MainActor
final class WidgetEventObserverTests: XCTestCase {

    // MARK: - Helpers

    /// Polls until `condition()` is true or the timeout elapses.
    private func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 2.0
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    // MARK: - Element delivery

    /// Verifies that ``beginObserving(_:onElement:onTermination:)`` delivers every
    /// yielded element to the handler on the main actor in submission order.
    func testBeginObservingDeliversElementsInOrder() async {
        let observer = WidgetEventObserver<Int>()
        let stream = AsyncStream<Int> { continuation in
            continuation.yield(1)
            continuation.yield(2)
            continuation.yield(3)
            continuation.finish()
        }

        var received: [Int] = []
        observer.beginObserving(stream) { element in
            received.append(element)
        }

        XCTAssertNotNil(observer.task, "Observation must schedule a live task")

        let satisfied = await waitUntil({ received.count >= 3 })
        XCTAssertTrue(satisfied, "Must receive all three elements; got: \(received)")
        XCTAssertEqual(received, [1, 2, 3])
    }

    /// Verifies that the ``beginObserving(unsafeSequence:onElement:onTermination:)``
    /// overload delivers elements identically to the Sendable overload.
    ///
    /// Production uses this path for ActivityKit ``contentUpdates`` sequences
    /// materialized under `nonisolated(unsafe)` at the call site.
    func testUnsafeOverloadDeliversElementsInOrder() async {
        let observer = WidgetEventObserver<String>()
        let stream = AsyncStream<String> { continuation in
            continuation.yield("alpha")
            continuation.yield("beta")
            continuation.finish()
        }

        var received: [String] = []
        observer.beginObserving(unsafeSequence: stream) { element in
            received.append(element)
        }

        let satisfied = await waitUntil({ received.count >= 2 })
        XCTAssertTrue(satisfied, "Unsafe overload must deliver elements; got: \(received)")
        XCTAssertEqual(received, ["alpha", "beta"])
    }

    // MARK: - Termination handler

    /// Verifies that ``onTermination`` runs exactly once after the sequence finishes normally.
    func testTerminationHandlerInvokedWhenStreamFinishes() async {
        let observer = WidgetEventObserver<Int>()
        let stream = AsyncStream<Int> { continuation in
            continuation.yield(7)
            continuation.finish()
        }

        var received: [Int] = []
        var terminationCount = 0

        observer.beginObserving(
            stream,
            onElement: { received.append($0) },
            onTermination: { terminationCount += 1 }
        )

        let elementsReady = await waitUntil({ received.count >= 1 })
        let terminated = await waitUntil({ terminationCount >= 1 })

        XCTAssertTrue(elementsReady, "Element must be delivered before termination; got: \(received)")
        XCTAssertTrue(terminated, "Termination handler must run after stream finish")
        XCTAssertEqual(terminationCount, 1)
    }

    /// Verifies that ``onTermination`` runs when observation is cancelled via ``cancel()``.
    ///
    /// Cancellation ends the `for try await` loop; the helper invokes the terminal handler
    /// after the catch block so managers can self-heal (for example nil-ing ``currentActivity``).
    func testTerminationHandlerInvokedWhenObservationCancelled() async {
        let observer = WidgetEventObserver<Int>()
        let stream = AsyncStream<Int> { _ in }

        var terminationCount = 0
        observer.beginObserving(
            stream,
            onElement: { _ in },
            onTermination: { terminationCount += 1 }
        )

        XCTAssertNotNil(observer.task)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))

        observer.cancel()
        XCTAssertNil(observer.task)

        let terminated = await waitUntil({ terminationCount >= 1 })
        XCTAssertTrue(terminated, "Termination handler must run after explicit cancel")
        XCTAssertEqual(terminationCount, 1)
    }

    // MARK: - Cancel / restart

    /// Verifies that ``cancel()`` clears ``task`` and prevents further element delivery
    /// from the same sequence continuation.
    func testCancelClearsTaskAndStopsFurtherDelivery() async {
        let observer = WidgetEventObserver<Int>()

        var continuation: AsyncStream<Int>.Continuation?
        let stream = AsyncStream<Int> { continuation = $0 }

        var received: [Int] = []
        observer.beginObserving(stream) { received.append($0) }

        continuation?.yield(1)
        let firstDelivered = await waitUntil({ received.count >= 1 })
        XCTAssertTrue(firstDelivered, "Precondition: first element must arrive")

        observer.cancel()
        XCTAssertNil(observer.task)

        continuation?.yield(2)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(received, [1], "Cancel must stop further delivery from the same stream")
    }

    /// Verifies cancel-before-start semantics: restarting observation on a new sequence
    /// cancels the prior task so only the replacement stream delivers elements.
    func testRestartCancelsPriorObservationAndDeliversFromNewStream() async {
        let observer = WidgetEventObserver<Int>()

        var firstContinuation: AsyncStream<Int>.Continuation?
        let firstStream = AsyncStream<Int> { firstContinuation = $0 }

        var firstReceived: [Int] = []
        observer.beginObserving(firstStream) { firstReceived.append($0) }

        firstContinuation?.yield(1)
        let firstReady = await waitUntil({ firstReceived.count >= 1 })
        XCTAssertTrue(firstReady, "Precondition: first stream must deliver before restart")

        let secondStream = AsyncStream<Int> { continuation in
            continuation.yield(10)
            continuation.yield(11)
            continuation.finish()
        }

        var secondReceived: [Int] = []
        observer.beginObserving(secondStream) { secondReceived.append($0) }

        await Task.yield()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))

        firstContinuation?.yield(99)

        let secondReady = await waitUntil({ secondReceived.count >= 2 })
        XCTAssertTrue(secondReady, "Restarted observer must deliver from the new stream; got: \(secondReceived)")

        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(firstReceived, [1], "Prior stream must not deliver after restart")
        XCTAssertEqual(secondReceived, [10, 11])
    }
}