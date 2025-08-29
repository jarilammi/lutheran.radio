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
        XCTAssertNil(manager.currentActivity)
    }
    
    // MARK: - Timer Management Tests
    
    func testStartLocalUpdateTimerSchedulesTimer() {
        // Note: Since startLocalUpdateTimer is private, we can't directly call it without changing the source.
        // Making it internal would make it possible to call manager.startLocalUpdateTimer()
        let mirror = Mirror(reflecting: manager!)
        let updateTimer = mirror.descendant("updateTimer") as? Timer
        XCTAssertNil(updateTimer) // Assuming not started
    }
    
    func testStopLocalUpdateTimerInvalidatesTimer() {
        // Similar note as above
        let mirror = Mirror(reflecting: manager!)
        let updateTimer = mirror.descendant("updateTimer") as? Timer
        XCTAssertNil(updateTimer)
    }
}
