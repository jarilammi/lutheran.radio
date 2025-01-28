//
//  Lutheran_RadioTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 26.10.2024.
//

import XCTest
@testable import Lutheran_Radio

final class Lutheran_RadioTests: XCTestCase {
    
    var viewController: ViewController!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        
        // Create an instance of ViewController
        viewController = ViewController()
        
        // Trigger view loading
        viewController.loadViewIfNeeded()
    }
    
    override func tearDownWithError() throws {
        viewController = nil
        try super.tearDownWithError()
    }
    
    func testPlayPauseButtonTogglesPlaybackState() {
        // Initial state: Connecting…
        XCTAssertTrue(viewController.isPlaying, "Player should initially be playing.")

        // Simulate a tap on the play/pause button
        viewController.playPauseButton.sendActions(for: .touchUpInside)

        // Verify that the player stops playing
        XCTAssertFalse(viewController.isPlaying, "Player should be paused after tapping playPauseButton.")

        // Simulate another tap on the play/pause button
        viewController.playPauseButton.sendActions(for: .touchUpInside)

        // Verify that the player resumes playing
        XCTAssertTrue(viewController.isPlaying, "Player should resume playing after tapping playPauseButton again.")
    }
    
    func testVolumeSliderChangesVolume() {
        // Initial volume slider value
        XCTAssertEqual(viewController.volumeSlider.value, 0.5, "Initial volume slider value should be 0.5.")
        
        // Simulate volume slider value change
        viewController.volumeSlider.value = 0.8
        viewController.volumeSlider.sendActions(for: .valueChanged)
        
        // Assert the slider's value is updated
        XCTAssertEqual(viewController.volumeSlider.value, 0.8, "Volume slider should reflect the updated value.")
    }
}
