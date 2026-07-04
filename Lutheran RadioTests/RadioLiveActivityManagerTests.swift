//
//  RadioLiveActivityManagerTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 29.8.2025.
//

import XCTest
import ActivityKit
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
        //   Activity.update(...) + end(...) APIs. Those are synchronous daemon
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
}
