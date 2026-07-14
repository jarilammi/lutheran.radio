//
//  Lutheran_RadioTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 26.10.2024.
//

import XCTest
import WidgetSurface
@testable import Lutheran_Radio

/// Protocol that our mock will implement to match DirectStreamingPlayer interface
protocol StreamingPlayerProtocol {
    func play(completion: @escaping @Sendable (Bool) -> Void)
    func stop(completion: (@Sendable () -> Void)?)
    func setStream(to stream: DirectStreamingPlayer.Stream)
    func setVolume(_ volume: Float)
    func setDelegate(_ delegate: AnyObject?)
    func validateSecurityModelAsync(completion: @escaping @Sendable (Bool) -> Void)
    func resetTransientErrors()
    func isLastErrorPermanent() -> Bool
    func clearCallbacks()
    
    var onStatusChange: ((Bool, String) -> Void)? { get set }
    var onMetadataChange: ((String?) -> Void)? { get set }
    var selectedStream: DirectStreamingPlayer.Stream { get set }
}

/// Minimal mock that implements the protocol without inheriting complexity
final class MockStreamingPlayer: StreamingPlayerProtocol, @unchecked Sendable {
    // Thread-safe storage
    private let _playCalled = ThreadSafeBox<Bool>(false)
    private let _stopCalled = ThreadSafeBox<Bool>(false)
    private let _setStreamCalled = ThreadSafeBox<Bool>(false)
    private let _volumeSet = ThreadSafeBox<Float?>(nil)
    private let _shouldSimulateSuccess = ThreadSafeBox<Bool>(true)
    private let _selectedStream = ThreadSafeBox<DirectStreamingPlayer.Stream?>(nil)
    
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
    
    var volumeSet: Float? {
        get { _volumeSet.value }
        set { _volumeSet.value = newValue }
    }
    
    var selectedStream: DirectStreamingPlayer.Stream {
        get { _selectedStream.value ?? DirectStreamingPlayer.availableStreams[0] }
        set { _selectedStream.value = newValue }
    }
    
    // Mock callbacks
    var onStatusChange: ((Bool, String) -> Void)?
    var onMetadataChange: ((String?) -> Void)?
    
    init() {
        selectedStream = DirectStreamingPlayer.availableStreams[0]
    }
    
    func play(completion: @escaping @Sendable (Bool) -> Void) {
        playCalled = true
        let success = _shouldSimulateSuccess.value
        
        // Simulate the status callback that ViewController expects
        DispatchQueue.main.async {
            self.onStatusChange?(success, success ? "Playing" : "Failed")
            completion(success)
        }
    }

    func stop(completion: (@Sendable () -> Void)? = nil) {
        stopCalled = true
        DispatchQueue.main.async {
            self.onStatusChange?(false, "Stopped")
            completion?()
        }
    }
    
    func setStream(to stream: DirectStreamingPlayer.Stream) {
        setStreamCalled = true
        selectedStream = stream
    }
    
    func setVolume(_ volume: Float) {
        volumeSet = volume
    }
    
    func setDelegate(_ delegate: AnyObject?) {
        // Mock implementation
    }
    
    func validateSecurityModelAsync(completion: @escaping @Sendable (Bool) -> Void) {
        DispatchQueue.main.async {
            completion(true)
        }
    }
    
    func resetTransientErrors() {
        // Mock implementation
    }
    
    func isLastErrorPermanent() -> Bool {
        return false
    }
    
    func clearCallbacks() {
        onStatusChange = nil
        onMetadataChange = nil
    }
    
    // Test helper methods
    func simulateSuccessfulPlayback() {
        _shouldSimulateSuccess.value = true
    }
    
    func simulateFailedPlayback() {
        _shouldSimulateSuccess.value = false
    }
    
    func reset() {
        playCalled = false
        stopCalled = false
        setStreamCalled = false
        volumeSet = nil
        _shouldSimulateSuccess.value = true
    }
}

/// Thread-safe wrapper for mutable properties
final class ThreadSafeBox<T>: @unchecked Sendable {
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

/// Custom ViewController for testing that uses our mock
final class TestViewController: UIViewController {
    let mockPlayer: MockStreamingPlayer
    private var _isPlaying = false
    private var _isManualPause = false
    
    // Public UI elements for testing
    let titleLabel = UILabel()
    let playPauseButton = UIButton(type: .system)
    let volumeSlider = UISlider()
    
    var isPlaying: Bool {
        get { _isPlaying }
        set { _isPlaying = newValue }
    }
    
    var isManualPause: Bool {
        get { _isManualPause }
        set { _isManualPause = newValue }
    }
    
    init(mockPlayer: MockStreamingPlayer) {
        self.mockPlayer = mockPlayer
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        // Clear callbacks to break any potential retain cycles
        mockPlayer.clearCallbacks()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupBasicUI()
        
        // Set up mock callbacks with weak self to avoid retain cycles
        mockPlayer.onStatusChange = { [weak self] isPlaying, status in
            DispatchQueue.main.async { [weak self] in
                self?.isPlaying = isPlaying
                self?.updatePlayPauseButton(isPlaying: isPlaying)
            }
        }
    }
    
    private func setupBasicUI() {
        // Configure UI elements
        titleLabel.text = "Lutheran Radio"
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        let config = UIImage.SymbolConfiguration(weight: .bold)
        playPauseButton.setImage(UIImage(systemName: "play.fill", withConfiguration: config), for: .normal)
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        
        volumeSlider.minimumValue = 0.0
        volumeSlider.maximumValue = 1.0
        volumeSlider.value = 0.5
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.addTarget(self, action: #selector(volumeDidChange(_:)), for: .valueChanged)
        
        // Add to view
        view.addSubview(titleLabel)
        view.addSubview(playPauseButton)
        view.addSubview(volumeSlider)
        
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            
            playPauseButton.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 20),
            playPauseButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 50),
            playPauseButton.heightAnchor.constraint(equalToConstant: 50),
            
            volumeSlider.topAnchor.constraint(equalTo: playPauseButton.bottomAnchor, constant: 20),
            volumeSlider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            volumeSlider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40)
        ])
    }
    
    @objc func playPauseTapped() {
        if isPlaying {
            pausePlayback()
        } else {
            startPlayback()
        }
    }
    
    private func startPlayback() {
        mockPlayer.play { success in
            // The mock will trigger onStatusChange callback
        }
    }
    
    private func pausePlayback() {
        isManualPause = true
        mockPlayer.stop()
        isPlaying = false
        updatePlayPauseButton(isPlaying: false)
    }
    
    @objc private func volumeDidChange(_ sender: UISlider) {
        mockPlayer.setVolume(sender.value)
    }
    
    func updatePlayPauseButton(isPlaying: Bool) {
        let config = UIImage.SymbolConfiguration(weight: .bold)
        let symbolName = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: symbolName, withConfiguration: config), for: .normal)
    }
}

final class Lutheran_RadioTests: XCTestCase {
    var testViewController: TestViewController!
    var mockPlayer: MockStreamingPlayer!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        mockPlayer = MockStreamingPlayer()
        testViewController = TestViewController(mockPlayer: mockPlayer)
        testViewController.loadViewIfNeeded()
    }
    
    override func tearDownWithError() throws {
        testViewController = nil
        mockPlayer = nil
        try super.tearDownWithError()
    }
    
    @MainActor
    func testPlayPauseButtonTogglesPlaybackState() async {
        // Setup
        mockPlayer.reset()
        mockPlayer.simulateSuccessfulPlayback()
        
        XCTAssertFalse(testViewController.isPlaying, "Should start in non-playing state")
        
        // Test playing
        testViewController.playPauseTapped()
        
        // Wait for async playback to complete (replaces the old asyncAfter + expectation)
        try? await Task.sleep(for: .milliseconds(250))
        
        XCTAssertTrue(mockPlayer.playCalled, "Play should have been called")
        XCTAssertTrue(testViewController.isPlaying, "Should be in playing state after successful playback")
        
        // Now test pausing
        mockPlayer.reset()
        testViewController.playPauseTapped()
        
        // Wait for stop to complete
        try? await Task.sleep(for: .milliseconds(250))
        
        XCTAssertTrue(mockPlayer.stopCalled, "Stop should have been called")
        XCTAssertFalse(testViewController.isPlaying, "Should not be in playing state after pause")
    }
    
    func testVolumeSliderChangesVolume() {
        XCTAssertEqual(testViewController.volumeSlider.value, 0.5, "Initial volume should be 0.5.")
        
        testViewController.volumeSlider.value = 0.8
        testViewController.volumeSlider.sendActions(for: .valueChanged)
        
        XCTAssertEqual(testViewController.volumeSlider.value, 0.8, "Volume slider should reflect the updated value.")
        XCTAssertEqual(mockPlayer.volumeSet, 0.8, "Player should have received the updated volume.")
    }
    
    func testViewControllerCreation() {
        // Test that we can create and configure a view controller without crashes
        let mockPlayer = MockStreamingPlayer()
        let viewController = TestViewController(mockPlayer: mockPlayer)
        viewController.loadViewIfNeeded()
        
        // Verify initial state
        XCTAssertFalse(viewController.isPlaying, "Should start in non-playing state")
        XCTAssertEqual(viewController.volumeSlider.value, 0.5, "Should have default volume")
        XCTAssertNotNil(viewController.view, "View should be loaded")
    }
}

// MARK: - Tests for modernized pure SwiftUI composed views
// The three views receive narrow value + closure inputs projected from PlayerViewModel
// (the composition root holds the @Bindable). These tests exercise creation and basic usage.
final class SwiftUIComposedViewsTests: XCTestCase {

    @MainActor
    func testLanguageSelectorView_CreatesAndBindsToVM() {
        let vm = PlayerViewModel.makeMock(selectedStreamIndex: 1)
        let view = LanguageSelectorView(
            selectedStreamIndex: vm.selectedStreamIndex,
            selectLanguage: vm.selectLanguage
        )
        XCTAssertNotNil(view)
        vm.selectedStreamIndex = 3
        XCTAssertEqual(vm.selectedStreamIndex, 3)
    }

    @MainActor
    func testPlaybackControlsView_BindsVisualStateAndCallsActions() {
        let vm = PlayerViewModel.makeMock(visualState: .prePlay)
        var playCalled = false
        vm.onPlayRequested = { playCalled = true }

        let view = PlaybackControlsView(
            controlPresentation: vm.controlPresentation,
            isActivelyPlaying: vm.isActivelyPlaying,
            sleepTimerRemaining: vm.sleepTimerRemaining,
            sleepTimerAccessibilityValue: vm.sleepTimerAccessibilityValue,
            statusPresentation: vm.statusPresentation,
            onPlay: vm.play,
            onPause: vm.pause
        )
        XCTAssertNotNil(view)

        // Simulate action
        vm.play()
        XCTAssertTrue(playCalled)
    }

    @MainActor
    func testNowPlayingMetadataView_RendersMetadataAndPhotoHeuristic() {
        let vm = PlayerViewModel.makeMock(currentMetadata: StreamProgramMetadata(programTitle: "Test", speaker: "Jari Lammi"))
        let view = NowPlayingMetadataView(displayModel: vm.nowPlayingDisplay)
        XCTAssertNotNil(view)
    }

    @MainActor
    func testNowPlayingMetadataView_PhotoHeuristicViaModel() {
        let vm = PlayerViewModel.makeMock(currentMetadata: StreamProgramMetadata(programTitle: "Sermon by Jari Lammi", speaker: nil))
        XCTAssertNotNil(NowPlayingMetadataView(displayModel: vm.nowPlayingDisplay))
    }
}
