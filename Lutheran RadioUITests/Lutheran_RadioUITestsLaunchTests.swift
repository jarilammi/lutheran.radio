//
//  Lutheran_RadioUITestsLaunchTests.swift
//  Lutheran RadioUITests
//
//  Created by Jari Lammi on 26.10.2024.
//

import XCTest

final class Lutheran_RadioUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        // Explicit "-UITestMode" launch argument ensures no auto streaming or security DNS
        // on launch. See Lutheran_RadioUITests.swift and SharedPlayerManager.isRunningInUITestMode
        // (single source of truth; DirectStreamingPlayer delegates to it).
        app.launchArguments = ["-UITestMode"]
        let launchExpectation = expectation(description: "App launches successfully")
        
        app.launch()
        
        // Wait for app to be in foreground
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            XCTAssertTrue(app.state == .runningForeground, "App should be in foreground")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Launch Screen"
            attachment.lifetime = .keepAlways
            self.add(attachment)
            launchExpectation.fulfill()
        }
        
        wait(for: [launchExpectation], timeout: 5.0)
    }
}
