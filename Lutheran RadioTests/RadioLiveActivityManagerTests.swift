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
    
    override func setUp() {
        super.setUp()
        manager = RadioLiveActivityManager.shared
    }
    
    override func tearDown() {
        manager = nil
        super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testInitializationObservesExistingActivities() {
        // In the test environment (no real ActivityKit entitlement / running activities),
        // currentActivity should be nil after shared init / observe.
        XCTAssertNil(manager.currentActivity)
    }
    
    // MARK: - Timer Management Tests
    // These now exercise the (intentionally internal) timer methods so the heartbeat
    // logic can be verified. The 10 s LA refresh timer is the backup to the explicit
    // SPM-driven updates added for the pause/resume and "app close" symptoms.

    func testStartLocalUpdateTimerSchedulesTimer() {
        manager.stopLocalUpdateTimer() // ensure clean
        manager.startLocalUpdateTimer()
        
        let mirror = Mirror(reflecting: manager)
        let updateTimer = mirror.descendant("updateTimer") as? Timer
        XCTAssertNotNil(updateTimer, "startLocalUpdateTimer must schedule a non-nil repeating Timer")
        XCTAssertTrue(updateTimer?.isValid ?? false)
        
        // cleanup
        manager.stopLocalUpdateTimer()
    }
    
    func testStopLocalUpdateTimerInvalidatesTimer() {
        manager.startLocalUpdateTimer()
        manager.stopLocalUpdateTimer()
        
        let mirror = Mirror(reflecting: manager)
        let updateTimer = mirror.descendant("updateTimer") as? Timer
        XCTAssertNil(updateTimer, "stopLocalUpdateTimer must clear the timer reference")
    }
}
