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

        // Initialize and launch the app **with explicit "-UITestMode" launch argument**.
        // This is the canonical (preferred) signal — see CODING_AGENT.md and
        // `SharedPlayerManager.isRunningInUITestMode` (the single source of truth).
        //
        // Effects:
        // - Cold-launch auto-play is suppressed in ViewController (clean .prePlay).
        // - `SharedPlayerManager.play()` short-circuits before SecurityModelValidator or setStreamAndPlay.
        // - DirectStreamingPlayer skips audio session, eager validation, and all playback engine work.
        // - No DNS, no real AVPlayer, no background audio.
        //
        // Explicit test taps (via userRequestedPlay) may still drive visual state to .playing
        // for UI assertions, but never trigger network or audio.
        app = XCUIApplication()
        app.launchArguments = ["-UITestMode"]
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
        // Access the volume control by identifier.
        // The control is now a native MPVolumeView (SystemVolumeSlider). It does not
        // register under the strict `sliders` matcher the way a SwiftUI Slider did;
        // we use a general descendant query so the test remains a simple existence
        // check for the element with accessibilityIdentifier "volumeSlider".
        let volumeSlider = app.descendants(matching: .any)["volumeSlider"]

        // Assert the volume control exists
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
            // Re-ensure the isolation arg on the re-launch performed by the metric.
            // launchArguments are read at each launch() time.
            app.launchArguments = ["-UITestMode"]
            // Measures the time taken to launch the app
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                app.launch()
            }
        }
    }
}
