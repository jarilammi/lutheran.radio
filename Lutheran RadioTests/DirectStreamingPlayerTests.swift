//
//  DirectStreamingPlayerTests.swift
//  Lutheran Radio Tests
//
//  Created by Jari Lammi on 31.5.2025.
//

import XCTest
import AVFoundation
import Network
@testable import Lutheran_Radio

@available(iOS 18.0, *)
final class DirectStreamingPlayerTests: XCTestCase {
    
    // MARK: - Test Doubles
    
    class MockAudioSession: AVAudioSession, @unchecked Sendable {
        var mockCategory: AVAudioSession.Category = .playback
        var mockMode: AVAudioSession.Mode = .default
        var mockIsActive = false
        var shouldThrowOnSetCategory = false
        var shouldThrowOnSetActive = false
        
        override func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions = []) throws {
            if shouldThrowOnSetCategory {
                throw NSError(domain: "MockAudioSession", code: -1, userInfo: [NSLocalizedDescriptionKey: "Mock category error"])
            }
            mockCategory = category
            mockMode = mode
        }
        
        override func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions = []) throws {
            if shouldThrowOnSetActive {
                throw NSError(domain: "MockAudioSession", code: -1, userInfo: [NSLocalizedDescriptionKey: "Mock active error"])
            }
            mockIsActive = active
        }
    }
    
    class MockNetworkPathMonitor: NetworkPathMonitoring {
        var pathUpdateHandler: (@Sendable (NetworkPathStatus) -> Void)?
        var isStarted = false
        var isCancelled = false
        private var currentStatus: NetworkPathStatus = .satisfied
        
        func start(queue: DispatchQueue) {
            isStarted = true
            // Simulate initial path update
            DispatchQueue.main.async {
                self.pathUpdateHandler?(self.currentStatus)
            }
        }
        
        func cancel() {
            isCancelled = true
            isStarted = false
        }
        
        func simulateNetworkChange(to status: NetworkPathStatus) {
            currentStatus = status
            DispatchQueue.main.async {
                self.pathUpdateHandler?(status)
            }
        }
    }
    
    @MainActor
    final class TestableDirectStreamingPlayer: DirectStreamingPlayer {
        var mockSecurityModels: Set<String> = ["landvetter"]
        var shouldFailSecurityValidation = false
        var shouldTimeoutSecurityValidation = false
        var mockLatencies: [String: TimeInterval] = [:]
        var serverSelectionCallCount = 0
        
        override func fetchValidSecurityModels(completion: @escaping (Result<Set<String>, Error>) -> Void) {
            Task { @MainActor in
                if shouldTimeoutSecurityValidation {
                    // Simulate timeout by not calling completion
                    return
                }
                
                if shouldFailSecurityValidation {
                    let error = NSError(domain: "TestError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Mock security validation failure"])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        completion(.failure(error))
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        completion(.success(self.mockSecurityModels))
                    }
                }
            }
        }
        
        override func selectOptimalServer(completion: @escaping (Server) -> Void) {
            Task { @MainActor in
                serverSelectionCallCount += 1
                
                // Use mock latencies if available
                if !mockLatencies.isEmpty {
                    let latencies = mockLatencies
                    let results = Self.servers.map { server in
                        PingResult(server: server, latency: latencies[server.name] ?? .infinity)
                    }
                    let validResults = results.filter { $0.latency != .infinity }
                    if let bestResult = validResults.min(by: { $0.latency < $1.latency }) {
                        completion(bestResult.server)
                    } else {
                        completion(Self.servers[0])
                    }
                } else {
                    // Default behavior
                    super.selectOptimalServer(completion: completion)
                }
            }
        }
        
        override func setupNetworkMonitoring() {
            // Override to prevent automatic network monitoring setup in tests
            // Tests will manually control network status
        }
    }
    
    // MARK: - Test Properties
    
    var player: TestableDirectStreamingPlayer!
    var mockAudioSession: MockAudioSession!
    var mockNetworkMonitor: MockNetworkPathMonitor!
    var statusChangeExpectation: XCTestExpectation?
    var metadataChangeExpectation: XCTestExpectation?
    var lastStatusPlaying: Bool?
    var lastStatusText: String?
    var lastMetadata: String?
    
    // MARK: - Setup & Teardown
    
    @MainActor
    override func setUp() {
        super.setUp()
        mockAudioSession = MockAudioSession()
        mockNetworkMonitor = MockNetworkPathMonitor()
        player = TestableDirectStreamingPlayer(audioSession: mockAudioSession, pathMonitor: mockNetworkMonitor)
        player.isTesting = true
        
        // Set up callbacks
        player.onStatusChange = { [weak self] isPlaying, statusText in
            self?.lastStatusPlaying = isPlaying
            self?.lastStatusText = statusText
            self?.statusChangeExpectation?.fulfill()
        }
        
        player.onMetadataChange = { [weak self] metadata in
            self?.lastMetadata = metadata
            self?.metadataChangeExpectation?.fulfill()
        }
        
        // Set delegate to enable callbacks
        player.setDelegate(self)
    }
    
    @MainActor
    override func tearDown() {
        player?.clearCallbacks()
        player?.stop()
        player = nil
        mockAudioSession = nil
        mockNetworkMonitor = nil
        statusChangeExpectation = nil
        metadataChangeExpectation = nil
        super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    @MainActor
    func testPlayerInitialization() {
        XCTAssertNotNil(player)
        XCTAssertEqual(player.selectedStream.languageCode, "en") // Should default to English or current locale
        XCTAssertTrue(player.hasInternetConnection)
        XCTAssertEqual(player.validationState, .pending)
        XCTAssertFalse(player.hasPermanentError)
    }
    
    @MainActor
    func testAudioSessionConfiguration() {
        // Audio session should be configured during init
        XCTAssertEqual(mockAudioSession.mockCategory, .playback)
        XCTAssertEqual(mockAudioSession.mockMode, .default)
        XCTAssertTrue(mockAudioSession.mockIsActive)
    }
    
    @MainActor
    func testNetworkMonitoringSetup() {
        XCTAssertTrue(mockNetworkMonitor.isStarted)
        XCTAssertFalse(mockNetworkMonitor.isCancelled)
    }
    
    // MARK: - Security Validation Tests
    
    @MainActor
    func testSecurityValidationSuccess() {
        let expectation = XCTestExpectation(description: "Security validation succeeds")
        
        player.mockSecurityModels = ["landvetter", "other_model"]
        player.shouldFailSecurityValidation = false
        
        player.validateSecurityModelAsync { isValid in
            XCTAssertTrue(isValid)
            XCTAssertEqual(self.player.validationState, .success)
            XCTAssertFalse(self.player.hasPermanentError)
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 2.0)
    }
    
    @MainActor
    func testSecurityValidationFailure() {
        let expectation = XCTestExpectation(description: "Security validation fails")
        
        player.mockSecurityModels = ["other_model"] // landvetter not included
        player.shouldFailSecurityValidation = false
        
        player.validateSecurityModelAsync { isValid in
            XCTAssertFalse(isValid)
            XCTAssertEqual(self.player.validationState, .failedPermanent)
            XCTAssertTrue(self.player.hasPermanentError)
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 2.0)
    }
    
    @MainActor
    func testSecurityValidationNetworkFailure() {
        let expectation = XCTestExpectation(description: "Security validation network failure")
        
        player.shouldFailSecurityValidation = true
        
        player.validateSecurityModelAsync { isValid in
            XCTAssertFalse(isValid)
            XCTAssertEqual(self.player.validationState, .failedTransient)
            XCTAssertFalse(self.player.hasPermanentError)
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 2.0)
    }
    
    @MainActor
    func testSecurityValidationCaching() {
        let firstExpectation = XCTestExpectation(description: "First validation")
        let secondExpectation = XCTestExpectation(description: "Second validation")
        
        player.mockSecurityModels = ["landvetter"]
        
        // First validation
        player.validateSecurityModelAsync { isValid in
            XCTAssertTrue(isValid)
            XCTAssertNotNil(self.player.lastValidationTime)
            firstExpectation.fulfill()
        }
        
        wait(for: [firstExpectation], timeout: 2.0)
        
        let firstValidationTime = player.lastValidationTime
        
        // Second validation should use cache
        player.validateSecurityModelAsync { isValid in
            XCTAssertTrue(isValid)
            XCTAssertEqual(self.player.lastValidationTime, firstValidationTime)
            secondExpectation.fulfill()
        }
        
        wait(for: [secondExpectation], timeout: 1.0)
    }
    
    @MainActor
    func testSecurityValidationTimeout() {
        let expectation = XCTestExpectation(description: "Security validation timeout")
        expectation.isInverted = true // Should NOT be fulfilled
        
        player.shouldTimeoutSecurityValidation = true
        
        player.validateSecurityModelAsync { isValid in
            expectation.fulfill() // This should not happen due to timeout
        }
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    // MARK: - Stream Management Tests
    
    @MainActor
    func testStreamSelection() {
        let testStream = DirectStreamingPlayer.availableStreams[1] // German stream
        
        player.setStream(to: testStream)
        
        XCTAssertEqual(player.selectedStream.languageCode, "de")
        XCTAssertEqual(player.selectedStream.url, testStream.url)
    }
    
    @MainActor
    func testStreamSwitchingFlag() {
        XCTAssertFalse(player.isSwitchingStream)
        
        let testStream = DirectStreamingPlayer.availableStreams[1]
        player.setStream(to: testStream)
        
        // Should be set to true during switch (though it may complete quickly in tests)
        // This is better tested with mock async operations
    }
    
    @MainActor
    func testAvailableStreams() {
        let streams = DirectStreamingPlayer.availableStreams
        
        XCTAssertEqual(streams.count, 5)
        XCTAssertTrue(streams.contains { $0.languageCode == "en" })
        XCTAssertTrue(streams.contains { $0.languageCode == "de" })
        XCTAssertTrue(streams.contains { $0.languageCode == "fi" })
        XCTAssertTrue(streams.contains { $0.languageCode == "sv" })
        XCTAssertTrue(streams.contains { $0.languageCode == "ee" })
    }
    
    // MARK: - Server Selection Tests
    
    @MainActor
    func testOptimalServerSelection() {
        let expectation = XCTestExpectation(description: "Server selection")
        
        // Mock latencies: EU faster than US
        player.mockLatencies = ["EU": 0.1, "US": 0.3]
        
        player.selectOptimalServer { server in
            XCTAssertEqual(server.name, "EU")
            XCTAssertEqual(self.player.serverSelectionCallCount, 1)
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 3.0)
    }
    
    @MainActor
    func testServerSelectionFallback() {
        let expectation = XCTestExpectation(description: "Server fallback")
        
        // Mock all servers as unreachable except US
        player.mockLatencies = ["EU": .infinity, "US": 0.5]
        
        player.selectOptimalServer { server in
            XCTAssertEqual(server.name, "US")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 3.0)
    }
    
    @MainActor
    func testServerSelectionCaching() {
        let firstExpectation = XCTestExpectation(description: "First selection")
        let secondExpectation = XCTestExpectation(description: "Second selection")
        
        player.mockLatencies = ["EU": 0.1, "US": 0.3]
        
        // First selection
        player.selectOptimalServer { server in
            XCTAssertEqual(server.name, "EU")
            firstExpectation.fulfill()
        }
        
        wait(for: [firstExpectation], timeout: 3.0)
        
        let firstCallCount = player.serverSelectionCallCount
        
        // Second selection should use cache (within throttle period)
        player.selectOptimalServer { server in
            XCTAssertEqual(server.name, "EU")
            XCTAssertEqual(self.player.serverSelectionCallCount, firstCallCount) // No additional call
            secondExpectation.fulfill()
        }
        
        wait(for: [secondExpectation], timeout: 1.0)
    }
    
    // MARK: - Network Monitoring Tests
    
    @MainActor
    func testNetworkConnectionChange() {
        statusChangeExpectation = XCTestExpectation(description: "Network disconnection")
        
        // Simulate network disconnection
        mockNetworkMonitor.simulateNetworkChange(to: .unsatisfied)
        
        wait(for: [statusChangeExpectation!], timeout: 1.0)
        
        XCTAssertFalse(player.hasInternetConnection)
        XCTAssertEqual(player.validationState, .failedTransient)
    }
    
    @MainActor
    func testNetworkReconnection() {
        // First disconnect
        mockNetworkMonitor.simulateNetworkChange(to: .unsatisfied)
        XCTAssertFalse(player.hasInternetConnection)
        
        statusChangeExpectation = XCTestExpectation(description: "Network reconnection")
        
        // Then reconnect
        mockNetworkMonitor.simulateNetworkChange(to: .satisfied)
        
        wait(for: [statusChangeExpectation!], timeout: 2.0)
        
        XCTAssertTrue(player.hasInternetConnection)
        XCTAssertEqual(player.validationState, .pending)
    }
    
    // MARK: - Playback State Tests
    
    @MainActor
    func testPlaybackStateUnknown() {
        let state = player.getPlaybackState()
        // Custom comparison since PlaybackState doesn't conform to Equatable
        switch state {
        case .unknown:
            XCTAssertTrue(true) // Test passes if state is unknown
        default:
            XCTFail("Expected unknown state, got \(state)")
        }
    }
    
    @MainActor
    func testPlaybackValidation() {
        let expectation = XCTestExpectation(description: "Play with validation")
        
        player.mockSecurityModels = ["landvetter"]
        player.mockLatencies = ["EU": 0.1, "US": 0.3]
        
        player.play { success in
            // Note: In tests, actual AVPlayer creation may fail, but validation should succeed
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 5.0)
        
        XCTAssertEqual(player.validationState, .success)
    }
    
    @MainActor
    func testPlayWithSecurityFailure() {
        let expectation = XCTestExpectation(description: "Play with security failure")
        statusChangeExpectation = XCTestExpectation(description: "Status change to security failed")
        
        player.mockSecurityModels = ["wrong_model"]
        
        player.play { success in
            XCTAssertFalse(success)
            expectation.fulfill()
        }
        
        wait(for: [expectation, statusChangeExpectation!], timeout: 3.0)
        
        XCTAssertEqual(player.validationState, .failedPermanent)
        XCTAssertTrue(player.hasPermanentError)
        XCTAssertEqual(lastStatusText, String(localized: "status_security_failed"))
    }
    
    @MainActor
    func testPlayWithNetworkFailure() {
        let expectation = XCTestExpectation(description: "Play with network failure")
        statusChangeExpectation = XCTestExpectation(description: "Status change to no internet")
        
        player.hasInternetConnection = false
        player.shouldFailSecurityValidation = true
        
        player.play { success in
            XCTAssertFalse(success)
            expectation.fulfill()
        }
        
        wait(for: [expectation, statusChangeExpectation!], timeout: 3.0)
        
        XCTAssertEqual(player.validationState, .failedTransient)
        XCTAssertFalse(player.hasPermanentError)
        XCTAssertEqual(lastStatusText, String(localized: "status_no_internet"))
    }
    
    // MARK: - Volume Control Tests
    
    @MainActor
    func testVolumeControl() {
        let testVolume: Float = 0.75
        
        // This mainly tests that the method doesn't crash
        // since we can't easily test AVPlayer volume in unit tests
        player.setVolume(testVolume)
        
        // No assertions needed - just ensuring no crash
    }
    
    // MARK: - Error Handling Tests
    
    @MainActor
    func testTransientErrorReset() {
        player.validationState = .failedTransient
        player.hasPermanentError = false
        
        player.resetTransientErrors()
        
        XCTAssertEqual(player.validationState, .pending)
        XCTAssertNil(player.lastValidationTime)
        XCTAssertFalse(player.hasPermanentError)
    }
    
    @MainActor
    func testPermanentErrorNotReset() {
        player.validationState = .failedPermanent
        player.hasPermanentError = true
        let validationTime = Date()
        player.lastValidationTime = validationTime
        
        player.resetTransientErrors()
        
        XCTAssertEqual(player.validationState, .failedPermanent)
        XCTAssertEqual(player.lastValidationTime, validationTime)
        XCTAssertTrue(player.hasPermanentError)
    }
    
    @MainActor
    func testErrorTypeClassification() {
        // Test security error
        let securityError = URLError(.userAuthenticationRequired)
        let securityType = DirectStreamingPlayer.StreamErrorType.from(error: securityError)
        XCTAssertEqual(securityType, .securityFailure)
        XCTAssertTrue(securityType.isPermanent)
        XCTAssertEqual(securityType.statusString, String(localized: "status_security_failed"))
        
        // Test permanent error
        let permanentError = URLError(.fileDoesNotExist)
        let permanentType = DirectStreamingPlayer.StreamErrorType.from(error: permanentError)
        XCTAssertEqual(permanentType, .permanentFailure)
        XCTAssertTrue(permanentType.isPermanent)
        
        // Test transient error
        let transientError = URLError(.timedOut)
        let transientType = DirectStreamingPlayer.StreamErrorType.from(error: transientError)
        XCTAssertEqual(transientType, .transientFailure)
        XCTAssertFalse(transientType.isPermanent)
    }
    
    @MainActor
    func testIsLastErrorPermanent() {
        player.validationState = .failedPermanent
        XCTAssertTrue(player.isLastErrorPermanent())
        
        player.validationState = .failedTransient
        XCTAssertFalse(player.isLastErrorPermanent())
        
        player.validationState = .success
        XCTAssertFalse(player.isLastErrorPermanent())
    }
    
    // MARK: - Callback Tests
    
    @MainActor
    func testStatusChangeCallback() {
        statusChangeExpectation = XCTestExpectation(description: "Status change callback")
        
        player.onStatusChange?(true, "Test Status")
        
        wait(for: [statusChangeExpectation!], timeout: 1.0)
        
        XCTAssertEqual(lastStatusPlaying, true)
        XCTAssertEqual(lastStatusText, "Test Status")
    }
    
    @MainActor
    func testMetadataChangeCallback() {
        metadataChangeExpectation = XCTestExpectation(description: "Metadata change callback")
        
        player.onMetadataChange?("Test Artist - Test Song")
        
        wait(for: [metadataChangeExpectation!], timeout: 1.0)
        
        XCTAssertEqual(lastMetadata, "Test Artist - Test Song")
    }
    
    @MainActor
    func testCallbackClearing() {
        player.clearCallbacks()
        
        XCTAssertNil(player.onStatusChange)
        XCTAssertNil(player.onMetadataChange)
    }
    
    // MARK: - Stop Functionality Tests
    
    @MainActor
    func testStopPlayback() {
        let expectation = XCTestExpectation(description: "Stop playback")
        statusChangeExpectation = XCTestExpectation(description: "Status change to stopped")
        
        player.stop {
            expectation.fulfill()
        }
        
        wait(for: [expectation, statusChangeExpectation!], timeout: 2.0)
        
        XCTAssertEqual(lastStatusText, String(localized: "status_stopped"))
        XCTAssertEqual(lastStatusPlaying, false)
    }
    
    // MARK: - Memory Management Tests
    
    @MainActor
    func testPlayerDeallocation() {
        weak var weakPlayer = player
        
        player.clearCallbacks()
        player = nil
        
        // Allow time for deallocation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertNil(weakPlayer)
        }
    }
    
    @MainActor
    func testNetworkMonitorCleanup() {
        player = nil
        
        // Network monitor should be cancelled during deallocation
        XCTAssertTrue(mockNetworkMonitor.isCancelled)
    }
    
    // MARK: - Edge Cases Tests
    
    @MainActor
    func testMultipleValidationCalls() {
        let expectation1 = XCTestExpectation(description: "First validation")
        let expectation2 = XCTestExpectation(description: "Second validation")
        
        player.mockSecurityModels = ["landvetter"]
        
        // Start two validations simultaneously
        player.validateSecurityModelAsync { isValid in
            XCTAssertTrue(isValid)
            expectation1.fulfill()
        }
        
        player.validateSecurityModelAsync { isValid in
            XCTAssertTrue(isValid)
            expectation2.fulfill()
        }
        
        wait(for: [expectation1, expectation2], timeout: 3.0)
    }
    
    @MainActor
    func testRapidStreamSwitching() {
        let streams = DirectStreamingPlayer.availableStreams
        
        // Switch rapidly between streams
        for stream in streams {
            player.setStream(to: stream)
        }
        
        // Should end up with the last stream
        XCTAssertEqual(player.selectedStream.languageCode, streams.last?.languageCode)
    }
    
    @MainActor
    func testEmptySecurityModels() {
        let expectation = XCTestExpectation(description: "Empty security models")
        
        player.mockSecurityModels = [] // Empty set
        
        player.validateSecurityModelAsync { isValid in
            XCTAssertFalse(isValid)
            XCTAssertEqual(self.player.validationState, .failedPermanent)
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 2.0)
    }
    
    // MARK: - Integration Tests
    
    @MainActor
    func testFullPlaybackFlow() {
        let expectation = XCTestExpectation(description: "Full playback flow")
        
        player.mockSecurityModels = ["landvetter"]
        player.mockLatencies = ["EU": 0.1, "US": 0.3]
        
        // Set stream
        let testStream = DirectStreamingPlayer.availableStreams[1]
        player.setStream(to: testStream)
        
        // Attempt playback
        player.play { success in
            // In real tests, this might fail due to network/AVPlayer constraints
            // but validation should succeed
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 5.0)
        
        XCTAssertEqual(player.selectedStream.languageCode, testStream.languageCode)
        XCTAssertEqual(player.validationState, .success)
        XCTAssertGreaterThan(player.serverSelectionCallCount, 0)
    }
    
    @MainActor
    func testNetworkRecoveryFlow() {
        // Start with network failure
        player.hasInternetConnection = false
        player.shouldFailSecurityValidation = true
        
        let firstExpectation = XCTestExpectation(description: "Network failure")
        player.play { success in
            XCTAssertFalse(success)
            firstExpectation.fulfill()
        }
        
        wait(for: [firstExpectation], timeout: 2.0)
        XCTAssertEqual(player.validationState, .failedTransient)
        
        // Simulate network recovery
        player.hasInternetConnection = true
        player.shouldFailSecurityValidation = false
        player.mockSecurityModels = ["landvetter"]
        
        let secondExpectation = XCTestExpectation(description: "Network recovery")
        player.play { success in
            secondExpectation.fulfill()
        }
        
        wait(for: [secondExpectation], timeout: 3.0)
        XCTAssertEqual(player.validationState, .success)
    }
    
    // MARK: - Performance Tests
    
    @MainActor
    func testSecurityValidationPerformance() {
        player.mockSecurityModels = ["landvetter"]
        
        measure {
            let expectation = XCTestExpectation(description: "Performance test")
            player.validateSecurityModelAsync { _ in
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 1.0)
        }
    }
    
    @MainActor
    func testServerSelectionPerformance() {
        player.mockLatencies = ["EU": 0.1, "US": 0.3]
        
        measure {
            let expectation = XCTestExpectation(description: "Server selection performance")
            player.selectOptimalServer { _ in
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2.0)
        }
    }
}

// MARK: - Test Extensions

extension DirectStreamingPlayerTests {
    
    func createMockURLError(_ code: URLError.Code) -> URLError {
        return URLError(code, userInfo: [NSLocalizedDescriptionKey: "Mock error for testing"])
    }
    
    func waitForAsyncOperation(timeout: TimeInterval = 1.0, operation: @escaping () -> Void) {
        let expectation = XCTestExpectation(description: "Async operation")
        DispatchQueue.main.async {
            operation()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: timeout)
    }
    
    // Helper to compare PlaybackState without Equatable
    func assertPlaybackState(_ actual: DirectStreamingPlayer.PlaybackState,
                             equals expected: DirectStreamingPlayer.PlaybackState,
                             file: StaticString = #file,
                             line: UInt = #line) {
        switch (actual, expected) {
        case (.unknown, .unknown), (.readyToPlay, .readyToPlay):
            XCTAssertTrue(true, file: file, line: line)
        case (.failed(let actualError), .failed(let expectedError)):
            XCTAssertEqual(actualError?.localizedDescription, expectedError?.localizedDescription, file: file, line: line)
        default:
            XCTFail("PlaybackState mismatch: expected \(expected), got \(actual)", file: file, line: line)
        }
    }
}
