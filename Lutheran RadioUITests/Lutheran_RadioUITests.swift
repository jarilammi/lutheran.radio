//
//  Lutheran_RadioUITests.swift
//  Lutheran RadioUITests
//
//  Created by Jari Lammi on 26.10.2024.
//

import XCTest

final class Lutheran_RadioUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Stop immediately when a failure occurs
        continueAfterFailure = false

        // Initialize and launch the app
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        // Clean up resources after each test
        app = nil
        try super.tearDownWithError()
    }

    func testPlayPauseButtonExistsAndTogglesState() {
        // Access the play/pause button
        let playPauseButton = app.buttons["playPauseButton"]

        // Assert the button exists
        XCTAssertTrue(playPauseButton.exists, "Play/Pause button should exist.")

        // Simulate toggling play/pause state
        playPauseButton.tap()
        // Add additional assertions for state change if needed
        playPauseButton.tap()
    }

    func testVolumeSliderExists() {
        // Access the volume slider
        let volumeSlider = app.sliders["volumeSlider"]

        // Assert the slider exists
        XCTAssertTrue(volumeSlider.exists, "Volume slider should exist.")
    }

    @MainActor
    func testExample() throws {
        // Example test case for demonstrating UI test usage
        XCTAssertTrue(app.state == .runningForeground, "App should be running in the foreground.")
    }

    @MainActor
    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // Measures the time taken to launch the app
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                app.launch()
            }
        }
    }
}
