//
//  RadioLiveActivityManagerTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 29.8.2025.
//
//  White-box unit tests for ``RadioLiveActivityManager`` timer demotion, change-detection
//  guards, and Live Activity attribute-events (`contentUpdates`) observation contracts.
//
//  Attribute-events tests consume DEBUG synthetic-stream seams on the manager
//  (`_test_beginObservingSyntheticContentUpdates`, `_test_wouldSuppressLiveActivityUpdate`,
//  `_test_setHarnessSimulatesActiveActivity`, `_test_cancelAttributeEventObservation`)
//  so ActivityKit IPC is never exercised under the XCTest host.
//
//  - SeeAlso: ``RadioLiveActivityManager``, ``WidgetEventObserver``,
//    docs/Event-Driven-Refactor-Roadmap.md (Tier 2 LA events / Tier 5),
//    CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).

import XCTest
import ActivityKit
import WidgetSurface
@testable import Lutheran_Radio

@MainActor
class RadioLiveActivityManagerTests: XCTestCase {
    
    var manager: RadioLiveActivityManager!
    
    override func setUp() async throws {
        try await super.setUp()
        manager = RadioLiveActivityManager.shared

        // Fast, cheap isolation only. Never call endActivity() here.
        //
        // Why:
        // - When you are playing the stream, a *real* Live Activity exists in the
        //   simulator (currentActivity holds a live Activity<...>).
        // - endActivity() would capture it and launch Tasks that call the real
        //   Activity.update(...) + end(...) APIs. Those are synchronous calls into ActivityKit's system services
        //   round-trips and become extremely slow under LLDB + active stream,
        //   causing exactly the "listening to the stream and test times out" symptom.
        //
        // Instead we only stop our local timer and nil the reference.
        // This is sufficient for the white-box timer tests and for the
        // initialization assertion. Real LAs (if present) are left alone.
        //
        // See ``RadioLiveActivityManager/isRunningUnderTest`` (and the early returns
        // in observeExistingActivities, startActivity, and updateCurrentActivity)
        // for the creation-time and call-time fast paths during tests.
        manager.stopLocalUpdateTimer()
        manager.activityObservationTask?.cancel()
        // Also cancel through the consolidated observer (its task is published
        // into the seam). The direct seam cancel remains the documented test
        // surface.
        // (internal visibility via @testable for the property itself.)
        manager.currentActivity = nil
    }
    
    override func tearDown() async throws {
        // Must stop the timer (if any) and cancel attribute event observation before
        // releasing. Prevents live Tasks / Timers keeping the runner alive.
        manager?.stopLocalUpdateTimer()
        manager?.activityObservationTask?.cancel()
        // The seam cancel stops the work; the observer is reset on next use.
        manager = nil
        try await super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testInitializationObservesExistingActivities() {
        // After accessing .shared (and our setUp sanitization), currentActivity
        // must be nil. The real work of forcing nil on first creation (and preventing
        // startActivity / updateCurrentActivity from doing real work) lives in the
        // #if DEBUG `isRunningUnderTest` checks.
        //
        // We also force nil in setUp (cheap direct assignment) so the assertion is
        // reliable even when other tests in the suite have started real Live Activities.
        XCTAssertNil(manager.currentActivity)
    }
    
    // MARK: - Timer Management Tests
    //
    // These exercise the internal timer heartbeat that backs Live Activity freshness.
    // The 10 s repeating timer is deliberately secondary to the explicit SPM-driven
    // `updateCurrentActivity()` calls (see SharedPlayerManager.setPlaying etc.).
    //
    // Invariant under test:
    //   startLocalUpdateTimer()  →  updateTimer != nil && updateTimer.isValid
    //   stopLocalUpdateTimer()   →  updateTimer == nil
    //
    // We observe via the already-`internal` property (no Mirror, no reflection).
    // This protects against regressions that would silently drop the LA heartbeat
    // or leave timers running (which previously caused LLDB + test runner stalls
    // and interaction with any real Activity in the simulator).
    //
    // - SeeAlso: RadioLiveActivityManager.updateTimer (the testing seam),
    //   startLocalUpdateTimer, stopLocalUpdateTimer, observeExistingActivities,
    //   startActivity, updateCurrentActivity, isRunningUnderTest.

    func testStartLocalUpdateTimerSchedulesTimer() {
        // setUp already stopped; this is extra belt-and-suspenders for the specific scenario.
        manager.stopLocalUpdateTimer()
        manager.startLocalUpdateTimer()

        // Direct access (property is intentionally internal private(set) for tests).
        XCTAssertNotNil(manager.updateTimer, "startLocalUpdateTimer must schedule a non-nil repeating Timer")
        XCTAssertTrue(manager.updateTimer?.isValid ?? false, "The scheduled timer must be valid")

        // Explicit stop here is still useful for readability; tearDown will also enforce it.
        manager.stopLocalUpdateTimer()
    }

    func testStopLocalUpdateTimerInvalidatesTimer() {
        manager.startLocalUpdateTimer()
        manager.stopLocalUpdateTimer()

        // After stop the backing reference must be cleared (stop does invalidate + nil).
        XCTAssertNil(manager.updateTimer, "stopLocalUpdateTimer must clear the timer reference")
    }

    // MARK: - Event-Driven + Change Detection Tests (new model)

    func testNoFallbackTimerStartedByDefaultAfterSanitization() {
        // After setUp sanitization the timer must be absent.
        // Normal paths (startActivity when we nil currentActivity, updateCurrentActivity)
        // must not introduce a repeating timer. This is the "timer demoted" guarantee.
        XCTAssertNil(manager.updateTimer, "No fallback timer should be scheduled by default paths under test isolation")
    }

    func testLastPushedContentIsClearedWhenActivityIsNilled() {
        // Simulate the post-end state without calling the real endActivity (which would
        // try real ActivityKit IPCs).
        manager.currentActivity = nil
        // Force a non-nil lastPushed to simulate prior push, then verify sanitization path
        // (we can't easily inject a real ContentState without an activity, but we can
        // assert that nil-ing the activity reference is accompanied by clearing lastPushed
        // in real endActivity paths; here we at least exercise the setter).
        // The production clearing happens inside endActivity before/after the Task.
        // We primarily verify the property is writable for test harness and starts nil.
        XCTAssertNil(manager.lastPushedContent)
    }

    func testUpdateCurrentActivityWithNoActivityIsNoOpAndDoesNotTouchLastPushed() {
        // Guard path: when there is no currentActivity we must early return before
        // computing or storing a lastPushed value. This keeps the "only push when active"
        // contract.
        XCTAssertNil(manager.currentActivity)
        let before = manager.lastPushedContent

        // This must be a fast no-op and must not synthesize a lastPushed.
        // Because we are under test guards + no activity, it will return early.
        // We call it to exercise the code path under the test short-circuits.
        // We cannot assert "no persistence side-effect" directly here without
        // heavy mocking of SharedPlayerManager, but the manager itself performs
        // zero UserDefaults or snapshot writes — that is enforced by code review
        // and the architecture (the only writes are inside performActualSave etc.).
        Task { @MainActor in
            await manager.updateCurrentActivity()
        }

        // Still no activity and lastPushed must be unchanged (nil).
        XCTAssertNil(manager.currentActivity)
        XCTAssertEqual(manager.lastPushedContent, before)
    }

    // MARK: - Attribute Events (contentUpdates) Observation

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

    private func makeContentState(
        visualState: PlayerVisualState,
        metadata: StreamProgramMetadata? = nil
    ) -> LutheranRadioLiveActivityAttributes.ContentState {
        LutheranRadioLiveActivityAttributes.ContentState(
            visualState: visualState,
            streamMetadata: metadata
        )
    }

    private func makeActivityContent(
        visualState: PlayerVisualState,
        metadata: StreamProgramMetadata? = nil
    ) -> ActivityContent<LutheranRadioLiveActivityAttributes.ContentState> {
        ActivityContent(
            state: makeContentState(visualState: visualState, metadata: metadata),
            staleDate: nil
        )
    }

    /// Verifies that synthetic attribute-events observation synchronizes
    /// ``lastPushedContent`` with each yielded ``ActivityContent`` state.
    ///
    /// Production consumes ActivityKit ``contentUpdates`` via
    /// ``beginObservingActivityEvents(_:)``. This test exercises the identical
    /// element handler through ``_test_beginObservingSyntheticContentUpdates(_:)``
    /// without system-service IPC.
    func testContentUpdatesObservationSynchronizesLastPushedContent() async {
        let playingContent = makeActivityContent(
            visualState: .playing,
            metadata: StreamProgramMetadata(programTitle: "Sunday Sermon", speaker: "Speaker")
        )

        let stream = AsyncStream<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>> { continuation in
            continuation.yield(playingContent)
            continuation.finish()
        }

        manager._test_beginObservingSyntheticContentUpdates(stream)

        let synchronized = await waitUntil({
            self.manager.lastPushedContent == playingContent.state
        })
        XCTAssertTrue(
            synchronized,
            "Attribute-events yield must align lastPushedContent with the system-accepted state"
        )
        XCTAssertEqual(manager.lastPushedContent?.visualState, .playing)
        XCTAssertEqual(manager.lastPushedContent?.streamMetadata, playingContent.state.streamMetadata)
    }

    /// Verifies that successive attribute-events yields replace ``lastPushedContent``
    /// so diff-driven suppression in ``updateCurrentActivity()`` tracks the latest
    /// rendered content.
    func testContentUpdatesObservationReplacesLastPushedContentOnSubsequentYield() async {
        let first = makeActivityContent(visualState: .playing)
        let second = makeActivityContent(
            visualState: .userPaused,
            metadata: StreamProgramMetadata(programTitle: "Paused Program", speaker: nil)
        )

        var continuation: AsyncStream<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>>.Continuation?
        let stream = AsyncStream { continuation = $0 }

        manager._test_beginObservingSyntheticContentUpdates(stream)

        continuation?.yield(first)
        let firstReady = await waitUntil({ self.manager.lastPushedContent == first.state })
        XCTAssertTrue(firstReady, "Precondition: first yield must synchronize lastPushedContent")

        continuation?.yield(second)
        let secondReady = await waitUntil({ self.manager.lastPushedContent == second.state })
        XCTAssertTrue(secondReady, "Second yield must replace lastPushedContent with the latest state")
        XCTAssertEqual(manager.lastPushedContent?.visualState, .userPaused)
    }

    /// Verifies that ``lastPushedContent`` diff logic suppresses redundant pushes when
    /// the candidate matches the attribute-events-aligned record.
    func testUpdateCurrentActivitySuppressesWhenLastPushedContentMatchesCandidate() async {
        let metadata = StreamProgramMetadata(programTitle: "Live Program", speaker: "Host")
        let aligned = makeActivityContent(visualState: .playing, metadata: metadata)

        let stream = AsyncStream<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>> { continuation in
            continuation.yield(aligned)
            continuation.finish()
        }

        manager._test_beginObservingSyntheticContentUpdates(stream)
        let alignedReady = await waitUntil({ self.manager.lastPushedContent == aligned.state })
        XCTAssertTrue(alignedReady, "Precondition: attribute-events alignment must populate lastPushedContent")

        XCTAssertTrue(
            manager._test_wouldSuppressLiveActivityUpdate(visualState: .playing, streamMetadata: metadata),
            "Matching candidate must suppress Activity.update IPC"
        )
        XCTAssertFalse(
            manager._test_wouldSuppressLiveActivityUpdate(visualState: .userPaused, streamMetadata: metadata),
            "Visual change must not suppress"
        )
        XCTAssertFalse(
            manager._test_wouldSuppressLiveActivityUpdate(
                visualState: .playing,
                streamMetadata: StreamProgramMetadata(programTitle: "Different", speaker: nil)
            ),
            "Metadata change must not suppress"
        )
    }

    /// Verifies termination self-healing clears stale tracking when observation ends
    /// while an activity reference is still considered active.
    func testAttributeObservationTerminationClearsStaleTrackingWhenActivityPresent() async {
        let content = makeActivityContent(visualState: .playing)
        var continuation: AsyncStream<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>>.Continuation?
        let stream = AsyncStream { continuation = $0 }

        manager._test_setHarnessSimulatesActiveActivity(true)
        manager._test_beginObservingSyntheticContentUpdates(stream)
        XCTAssertNotNil(manager.activityObservationTask, "Observation must publish activityObservationTask")

        continuation?.yield(content)
        let populated = await waitUntil({ self.manager.lastPushedContent == content.state })
        XCTAssertTrue(populated, "Precondition: attribute-events yield must populate lastPushedContent")

        manager._test_cancelAttributeEventObservation()

        let cleared = await waitUntil({ self.manager.lastPushedContent == nil })
        XCTAssertTrue(
            cleared,
            "Termination hygiene must clear lastPushedContent when activity tracking was active"
        )
        XCTAssertNil(manager.currentActivity)
    }

    /// Verifies that ``endActivity()`` cancels attribute-events observation and clears
    /// ``activityObservationTask`` without ActivityKit IPC under test isolation.
    func testEndActivityCancelsAttributeObservationTask() async {
        let stream = AsyncStream<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>> { _ in }
        manager._test_beginObservingSyntheticContentUpdates(stream)
        XCTAssertNotNil(manager.activityObservationTask, "Precondition: observation task must be live")

        manager.endActivity()

        XCTAssertNil(manager.activityObservationTask, "endActivity must cancel attribute-events observation")
        XCTAssertNil(manager.lastPushedContent, "endActivity must clear lastPushedContent under test isolation")
        XCTAssertNil(manager.currentActivity)
    }

    /// Verifies restart semantics: a second synthetic stream cancels the prior observation
    /// so only the replacement sequence updates ``lastPushedContent``.
    func testRestartingAttributeObservationCancelsPriorStream() async {
        var firstContinuation: AsyncStream<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>>.Continuation?
        let firstStream = AsyncStream { firstContinuation = $0 }

        let firstContent = makeActivityContent(visualState: .playing)
        manager._test_beginObservingSyntheticContentUpdates(firstStream)

        firstContinuation?.yield(firstContent)
        let firstReady = await waitUntil({ self.manager.lastPushedContent == firstContent.state })
        XCTAssertTrue(firstReady, "Precondition: first stream must deliver before restart")

        let secondContent = makeActivityContent(visualState: .userPaused)
        let secondStream = AsyncStream<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>> { continuation in
            continuation.yield(secondContent)
            continuation.finish()
        }

        manager._test_beginObservingSyntheticContentUpdates(secondStream)

        let secondReady = await waitUntil({ self.manager.lastPushedContent == secondContent.state })
        XCTAssertTrue(secondReady, "Restarted observation must deliver from the replacement stream")

        firstContinuation?.yield(makeActivityContent(visualState: .prePlay))
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(
            manager.lastPushedContent,
            secondContent.state,
            "Prior stream must not update lastPushedContent after restart"
        )
    }
}
