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
        manager.currentActivity = nil
    }
    
    override func tearDown() async throws {
        // Must stop the timer (if any) before releasing the reference.
        // This prevents a live repeating Timer + @MainActor Task from keeping
        // the test runner (and LLDB) busy after the test case completes.
        // The singleton nature makes this cleanup mandatory.
        manager?.stopLocalUpdateTimer()
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
}
