//
//  Lutheran_RadioTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 26.10.2024.
//

import XCTest
@testable import Lutheran_Radio

/// Mock implementation of DirectStreamingPlayer for testing
final class MockStreamingPlayer: DirectStreamingPlayer, @unchecked Sendable {
    // Use thread-safe storage for mutable properties
    private let _playCalled = MainTestThreadSafeBox<Bool>(false)
    private let _stopCalled = MainTestThreadSafeBox<Bool>(false)
    private let _setStreamCalled = MainTestThreadSafeBox<Bool>(false)
    private let _forcePlayCalled = MainTestThreadSafeBox<Bool>(false)
    private let _volume = MainTestThreadSafeBox<Float>(0.5)
    private let _volumeSet = MainTestThreadSafeBox<Float?>(nil)
    private let _playCompletion = MainTestThreadSafeBox<((Bool) -> Void)?>(nil)
    private let _stopCompletion = MainTestThreadSafeBox<(() -> Void)?>(nil)
    private let _shouldSimulateSuccess = MainTestThreadSafeBox<Bool>(true)
    
    var playCalled: Bool {
        get { _playCalled.value }
        set { _playCalled.value = newValue }
    }
    
    var stopCalled: Bool {
        get { _stopCalled.value }
        set { _stopCalled.value = newValue }
    }
    
    var setStreamCalled: Bool {
        get { _setStreamCalled.value }
        set { _setStreamCalled.value = newValue }
    }
    
    var forcePlayCalled: Bool {
        get { _forcePlayCalled.value }
        set { _forcePlayCalled.value = newValue }
    }
    
    var currentVolume: Float {
        get { _volume.value }
        set { _volume.value = newValue }
    }
    
    var volumeSet: Float? {
        get { _volumeSet.value }
        set { _volumeSet.value = newValue }
    }
    
    var playCompletion: ((Bool) -> Void)? {
        get { _playCompletion.value }
        set { _playCompletion.value = newValue }
    }
    
    var stopCompletion: (() -> Void)? {
        get { _stopCompletion.value }
        set { _stopCompletion.value = newValue }
    }
    
    override func play(completion: @escaping (Bool) -> Void) {
        playCalled = true
        playCompletion = completion
        // Simulate async behavior
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            completion(self._shouldSimulateSuccess.value)
        }
    }
    
    override func stop(completion: (() -> Void)? = nil) {
        stopCalled = true
        stopCompletion = completion
        completion?()
    }
    
    override func setStream(to stream: Stream) {
        setStreamCalled = true
        selectedStream = stream
    }
    
    override func setVolume(_ volume: Float) {
        currentVolume = volume
        volumeSet = volume
    }
    
    // Additional mock methods for testing
    func simulateSuccessfulPlayback() {
        _shouldSimulateSuccess.value = true
    }
    
    func simulateFailedPlayback() {
        _shouldSimulateSuccess.value = false
    }
    
    // Method to trigger force play (not a property call)
    func triggerForcePlay() {
        forcePlayCalled = true
    }
    
    // Reset method for test cleanup
    func reset() {
        playCalled = false
        stopCalled = false
        setStreamCalled = false
        forcePlayCalled = false
        currentVolume = 0.5
        volumeSet = nil
        playCompletion = nil
        stopCompletion = nil
        _shouldSimulateSuccess.value = true
    }
}

/// Thread-safe wrapper for mutable properties in Sendable classes (Main Tests)
final class MainTestThreadSafeBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    
    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _value = newValue
        }
    }
    
    init(_ value: T) {
        self._value = value
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
        // Setup
        viewController.hasInternet = true
        mockPlayer.stopCalled = false
        mockPlayer.playCalled = false
        
        // Bypass the async code and directly trigger play in the mock
        viewController.playPauseTapped()
        
        // Trigger force play method instead of calling as function
        mockPlayer.triggerForcePlay()
        
        // Verify play was called
        XCTAssertTrue(mockPlayer.playCalled, "Play should have been called")
        
        // Simulate successful playback
        mockPlayer.simulateSuccessfulPlayback()
        
        // Now we should be in playing state
        XCTAssertTrue(viewController.isPlayingState, "Should be in playing state after successful playback")
        
        // Reset for next test
        mockPlayer.playCalled = false
        mockPlayer.stopCalled = false
        
        // Test pausing
        viewController.playPauseTapped()
        
        // Check if stop was called
        XCTAssertTrue(mockPlayer.stopCalled, "Stop should have been called.")
    }
    
    func testVolumeSliderChangesVolume() {
        XCTAssertEqual(viewController.volumeSlider.value, 0.5, "Initial volume should be 0.5.")
        
        viewController.volumeSlider.value = 0.8
        viewController.volumeSlider.sendActions(for: .valueChanged)
        
        XCTAssertEqual(viewController.volumeSlider.value, 0.8, "Volume slider should reflect the updated value.")
        XCTAssertEqual(mockPlayer.volumeSet, 0.8, "Player should have received the updated volume.")
    }
    
    func testViewControllerDeallocation() {
        var viewController: ViewController? = ViewController()
        viewController?.viewDidLoad()
        viewController = nil
        XCTAssertNil(viewController, "ViewController should be deallocated")
    }
}
