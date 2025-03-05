//
//  Lutheran_RadioTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 26.10.2024.
//

import XCTest
@testable import Lutheran_Radio

class MockStreamingPlayer: DirectStreamingPlayer, @unchecked Sendable {
    var playCalled = false
    var stopCalled = false
    var volumeSet: Float?
    
    override func play(completion: @escaping (Bool) -> Void) {
        playCalled = true
        completion(true)
    }
    
    override func stop() {
        stopCalled = true
    }
    
    override func setVolume(_ volume: Float) {
        volumeSet = volume
    }
}

final class Lutheran_RadioTests: XCTestCase {
    var viewController: ViewController!
    var mockPlayer: MockStreamingPlayer!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        mockPlayer = MockStreamingPlayer()
        viewController = ViewController(streamingPlayer: mockPlayer)
        viewController.loadViewIfNeeded()
    }
    
    override func tearDownWithError() throws {
        viewController = nil
        mockPlayer = nil
        try super.tearDownWithError()
    }
    
    func testPlayPauseButtonTogglesPlaybackState() {
        XCTAssertFalse(viewController.isPlayingState, "Player should initially be stopped.")
        viewController.hasInternet = true
        
        viewController.playPauseButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(viewController.isPlayingState, "Player should start playing after first tap.")
        XCTAssertTrue(mockPlayer.playCalled, "Play should have been called.")
        
        viewController.playPauseButton.sendActions(for: .touchUpInside)
        XCTAssertFalse(viewController.isPlayingState, "Player should pause after second tap.")
        XCTAssertTrue(mockPlayer.stopCalled, "Stop should have been called.")
        
        mockPlayer.playCalled = false
        mockPlayer.stopCalled = false
        
        viewController.playPauseButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(viewController.isPlayingState, "Player should resume after third tap.")
        XCTAssertTrue(mockPlayer.playCalled, "Play should have been called again.")
    }
    
    func testVolumeSliderChangesVolume() {
        XCTAssertEqual(viewController.volumeSlider.value, 0.5, "Initial volume should be 0.5.")
        
        viewController.volumeSlider.value = 0.8
        viewController.volumeSlider.sendActions(for: .valueChanged)
        
        XCTAssertEqual(viewController.volumeSlider.value, 0.8, "Volume slider should reflect the updated value.")
        XCTAssertEqual(mockPlayer.volumeSet, 0.8, "Player should have received the updated volume.")
    }
}
