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
        viewController = ViewController()
        viewController.loadViewIfNeeded()
    }
    
    override func tearDownWithError() throws {
        viewController = nil
        try super.tearDownWithError()
    }
    
    func testPlayPauseButtonTogglesPlaybackState() {
        // Initial state should be not playing
        XCTAssertFalse(viewController.isPlaying, "Player should initially be stopped.")
        
        // Set hasInternetConnection to true to simulate network availability
        viewController.hasInternetConnection = true
        
        // Simulate first tap on play/pause button - should start playing
        viewController.playPauseButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(viewController.isPlaying, "Player should start playing after first tap.")
        
        // Simulate second tap - should pause
        viewController.playPauseButton.sendActions(for: .touchUpInside)
        XCTAssertFalse(viewController.isPlaying, "Player should pause after second tap.")
        
        // Simulate third tap - should resume
        viewController.playPauseButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(viewController.isPlaying, "Player should resume playing after third tap.")
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
