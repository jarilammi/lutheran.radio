//
//  MockDirectStreamingPlayerTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 27.4.2025.
//

import XCTest
import AVFoundation
import Network
@testable import Lutheran_Radio

// Mock implementation of NetworkPathMonitoring for tests
protocol TestNetworkPathMonitoring: AnyObject {
    var pathUpdateHandler: ((NetworkPathStatus) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func cancel()
}

// Mock NWPathMonitor for tests
class MockNWPathMonitor: TestNetworkPathMonitoring {
    var pathUpdateHandler: ((NetworkPathStatus) -> Void)?
    var isStarted = false
    var isCanceled = false
    
    func start(queue: DispatchQueue) {
        isStarted = true
    }
    
    func cancel() {
        isCanceled = true
        pathUpdateHandler = nil
    }
    
    func simulatePathUpdate(status: NetworkPathStatus) {
        pathUpdateHandler?(status)
    }
}

// Adapter to bridge TestNetworkPathMonitoring to Network orders
class NetworkPathMonitoringAdapter: NetworkPathMonitoring {
    private let testMonitor: TestNetworkPathMonitoring
    
    init(testMonitor: TestNetworkPathMonitoring) {
        self.testMonitor = testMonitor
    }
    
    var pathUpdateHandler: (@Sendable (NetworkPathStatus) -> Void)? {
        didSet {
            testMonitor.pathUpdateHandler = pathUpdateHandler
        }
    }
    
    func start(queue: DispatchQueue) {
        testMonitor.start(queue: queue)
    }
    
    func cancel() {
        testMonitor.cancel()
    }
}

// Mock implementation of DirectStreamingPlayer
final class MockDirectStreamingPlayer: @unchecked Sendable {
    var selectedStream: DirectStreamingPlayer.Stream
    var validationState: DirectStreamingPlayer.ValidationState = .pending
    var hasInternetConnection: Bool = false
    var hasPermanentError: Bool = false
    var lastValidationTime: Date?
    var lastError: Error?
    var isSwitchingStream: Bool = false
    var onStatusChange: ((Bool, String) -> Void)?
    var onMetadataChange: ((String?) -> Void)?
    var mockNetworkMonitor: MockNWPathMonitor?
    var networkMonitor: NetworkPathMonitoring?
    var simulatedValidationResult: Bool?
    var simulatedSecurityModels: Result<Set<String>, Error>?
    var didCallPlay: Bool = false
    var didCallStop: Bool = false
    var simulatedStatus: AVPlayerItem.Status?
    
    private let playbackQueue = DispatchQueue(label: "radio.lutheran.playback.mock", qos: .userInitiated)
    private let availableStreams: [DirectStreamingPlayer.Stream]
    
    init(availableStreams: [DirectStreamingPlayer.Stream] = DirectStreamingPlayer.availableStreams) {
        self.availableStreams = availableStreams
        let initialStream = availableStreams.first { $0.languageCode == Locale.current.language.languageCode?.identifier } ?? availableStreams.first!
        self.selectedStream = initialStream
        setupNetworkMonitoring()
    }
    
    func setupNetworkMonitoring() {
        mockNetworkMonitor = MockNWPathMonitor()
        guard let mockNetworkMonitor = mockNetworkMonitor else {
            #if DEBUG
            print("❌ Failed to initialize mockNetworkMonitor")
            #endif
            return
        }
        networkMonitor = NetworkPathMonitoringAdapter(testMonitor: mockNetworkMonitor)
        mockNetworkMonitor.pathUpdateHandler = { [weak self] status in
            guard let self = self else {
                #if DEBUG
                print("🧹 [Network] Skipped path update: self is nil")
                #endif
                return
            }
            let wasConnected = self.hasInternetConnection
            self.hasInternetConnection = status == .satisfied
            #if DEBUG
            print("🌐 [Network] Status: \(self.hasInternetConnection ? "Connected" : "Disconnected")")
            #endif
            if self.hasInternetConnection && !wasConnected {
                self.lastValidationTime = nil
                self.validationState = .pending
                self.validateSecurityModelAsync { isValid in
                    if !isValid {
                        DispatchQueue.main.async {
                            self.onStatusChange?(false, String(localized: self.validationState == .failedPermanent ? "status_security_failed" : "status_no_internet"))
                        }
                    } else if !self.hasPermanentError {
                        self.play { success in
                            DispatchQueue.main.async {
                                self.onStatusChange?(success, String(localized: success ? "status_playing" : "status_stream_unavailable"))
                            }
                        }
                    }
                }
            } else if !self.hasInternetConnection && wasConnected {
                self.validationState = .failedTransient
                DispatchQueue.main.async {
                    self.onStatusChange?(false, String(localized: "status_no_internet"))
                }
            }
        }
        networkMonitor?.start(queue: DispatchQueue(label: "radio.lutheran.networkmonitor"))
        #if DEBUG
        print("🌐 Mock network monitoring set up, mockNetworkMonitor: \(mockNetworkMonitor)")
        #endif
    }
    
    func validateSecurityModelAsync(completion: @escaping (Bool) -> Void) {
        if let isValid = simulatedValidationResult {
            validationState = isValid ? .success : .failedTransient
            DispatchQueue.main.async {
                if !isValid {
                    self.onStatusChange?(false, String(localized: "status_no_internet"))
                }
                completion(isValid)
            }
        } else {
            fetchValidSecurityModels { [weak self] result in
                guard let self = self else {
                    completion(false)
                    return
                }
                switch result {
                case .success(let models):
                    let isValid = models.contains("mariehamn")
                    self.validationState = isValid ? .success : .failedPermanent
                    self.lastValidationTime = Date()
                    DispatchQueue.main.async {
                        if !isValid {
                            self.onStatusChange?(false, String(localized: "status_security_failed"))
                        }
                        completion(isValid)
                    }
                case .failure:
                    self.validationState = .failedTransient
                    DispatchQueue.main.async {
                        self.onStatusChange?(false, String(localized: "status_no_internet"))
                        completion(false)
                    }
                }
            }
        }
    }
    
    func fetchValidSecurityModels(completion: @escaping (Result<Set<String>, Error>) -> Void) {
        if let result = simulatedSecurityModels {
            completion(result)
        } else {
            completion(.success(["mariehamn"]))
        }
    }
    
    func setStream(to stream: DirectStreamingPlayer.Stream) {
        guard !isSwitchingStream else {
            #if DEBUG
            print("📡 Stream switch skipped: already switching")
            #endif
            return
        }
        isSwitchingStream = true
        
        stop { [weak self] in
            guard let self = self else {
                self?.isSwitchingStream = false
                return
            }
            
            self.selectedStream = stream
            self.validationState = .success
            #if DEBUG
            print("📡 Stream set to: \(stream.language), URL: \(stream.url)")
            #endif
            
            DispatchQueue.main.async {
                self.onMetadataChange?(stream.language)
            }
            
            self.isSwitchingStream = false
            
            self.play { success in
                DispatchQueue.main.async {
                    self.onStatusChange?(success, String(localized: success ? "status_playing" : "status_stream_unavailable"))
                }
            }
        }
    }
    
    func play(completion: @escaping (Bool) -> Void) {
        didCallPlay = true
        if validationState == .pending {
            validateSecurityModelAsync { [weak self] isValid in
                guard let self = self else {
                    completion(false)
                    return
                }
                if isValid {
                    self.play(completion: completion)
                } else {
                    DispatchQueue.main.async {
                        self.onStatusChange?(false, String(localized: self.validationState == .failedPermanent ? "status_security_failed" : "status_no_internet"))
                        completion(false)
                    }
                }
            }
            return
        }
        
        guard validationState == .success else {
            DispatchQueue.main.async {
                self.onStatusChange?(false, String(localized: self.validationState == .failedPermanent ? "status_security_failed" : "status_no_internet"))
                completion(false)
            }
            return
        }
        
        if let status = simulatedStatus {
            simulateStatusChange(status)
            completion(status == .readyToPlay)
        } else {
            simulateStatusChange(.readyToPlay)
            completion(true)
        }
    }
    
    func stop(completion: (() -> Void)? = nil) {
        didCallStop = true
        playbackQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion?() }
                return
            }
            
            DispatchQueue.main.async {
                self.onStatusChange?(false, String(localized: "status_stopped"))
                completion?()
            }
        }
    }
    
    func resetTransientErrors() {
        if validationState == .failedTransient {
            validationState = .pending
            lastValidationTime = nil
            hasPermanentError = false
        }
    }
    
    func isLastErrorPermanent() -> Bool {
        hasPermanentError
    }
    
    func clearCallbacks() {
        onMetadataChange = nil
        onStatusChange = nil
    }
    
    private func simulateStatusChange(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            onStatusChange?(true, String(localized: "status_playing"))
        case .failed:
            onStatusChange?(false, String(localized: "status_stream_unavailable"))
        case .unknown:
            onStatusChange?(false, String(localized: "status_buffering"))
        @unknown default:
            break
        }
    }
    
    deinit {
        networkMonitor?.cancel()
        mockNetworkMonitor?.cancel()
        clearCallbacks()
        #if DEBUG
        print("🧹 MockDirectStreamingPlayer deinit")
        #endif
    }
}

@MainActor
class MockDirectStreamingPlayerTests: XCTestCase {
    var player: MockDirectStreamingPlayer!
    var initialTitle: String?
    var mockStreams: [DirectStreamingPlayer.Stream]!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        
        // Mock available streams to ensure at least one stream exists
        mockStreams = [
            DirectStreamingPlayer.Stream(
                title: String(localized: "lutheran_radio_title") + " - " + String(localized: "language_finnish"),
                url: URL(string: "http://example.com/fi")!,
                language: String(localized: "language_finnish"),
                languageCode: "fi",
                flag: "🇫🇮"
            ),
            DirectStreamingPlayer.Stream(
                title: String(localized: "lutheran_radio_title") + " - " + String(localized: "language_english"),
                url: URL(string: "http://example.com/en")!,
                language: String(localized: "language_english"),
                languageCode: "en",
                flag: "🇺🇸"
            )
        ]
        #if DEBUG
        print("📡 Mock streams set: \(mockStreams.map { $0.language })")
        #endif
        
        // Initialize player with mocked streams
        player = MockDirectStreamingPlayer(availableStreams: mockStreams)
        
        // Verify player initialization
        guard player != nil else {
            XCTFail("Failed to initialize MockDirectStreamingPlayer")
            throw NSError(domain: "TestSetup", code: -1, userInfo: [NSLocalizedDescriptionKey: "Player initialization failed"])
        }
        
        // Set up mock network monitoring
        guard player.mockNetworkMonitor != nil else {
            XCTFail("mockNetworkMonitor is nil after setupNetworkMonitoring")
            throw NSError(domain: "TestSetup", code: -2, userInfo: [NSLocalizedDescriptionKey: "Network monitor setup failed"])
        }
        
        // Simulate network connection
        player.mockNetworkMonitor?.simulatePathUpdate(status: .satisfied)
        
        // Configure mock validation
        player.simulatedValidationResult = true
        player.simulatedSecurityModels = .success(["mariehamn"])
        
        // Select stream based on locale
        let testLocale = Locale(identifier: "fi_FI")
        let languageCode = testLocale.language.languageCode?.identifier ?? "en"
        guard let selectedStream = mockStreams.first(where: { $0.languageCode == languageCode }) ??
                  mockStreams.first else {
            XCTFail("No valid stream available for languageCode: \(languageCode)")
            throw NSError(domain: "TestSetup", code: -3, userInfo: [NSLocalizedDescriptionKey: "No valid stream found"])
        }
        
        // Set up expectations for async operations
        let validationExpectation = XCTestExpectation(description: "Initial validation completes")
        let metadataExpectation = XCTestExpectation(description: "Metadata callback completes")
        
        player.onMetadataChange = { [weak self] title in
            #if DEBUG
            print("📡 Metadata changed to: \(title ?? "nil")")
            #endif
            self?.initialTitle = title
            metadataExpectation.fulfill()
        }
        
        // Perform validation and stream selection synchronously
        player.validateSecurityModelAsync { isValid in
            XCTAssertTrue(isValid, "Initial validation should succeed")
            validationExpectation.fulfill()
        }
        
        // Set stream
        player.setStream(to: selectedStream)
        
        // Wait for validation and metadata to complete
        wait(for: [validationExpectation, metadataExpectation], timeout: 5.0)
    }
    
    override func tearDown() async throws {
        if let player = player {
            let cleanupExpectation = XCTestExpectation(description: "Player cleanup completes")
            
            player.stop {
                player.clearCallbacks()
                player.networkMonitor?.cancel()
                player.mockNetworkMonitor?.cancel()
                player.mockNetworkMonitor = nil
                cleanupExpectation.fulfill()
            }
            
            await fulfillment(of: [cleanupExpectation], timeout: 5.0)
        }
        
        player = nil
        mockStreams = nil
        try await Task.sleep(nanoseconds: 500_000_000)
        try await super.tearDown()
    }
    
    func testInitializationSelectsLocaleStream() async {
        guard let player = player else {
            XCTFail("Player is nil after setup")
            return
        }
        
        let testLocale = Locale(identifier: "fi_FI")
        let languageCode = testLocale.language.languageCode?.identifier ?? "en"
        guard let expectedStream = mockStreams.first(where: { $0.languageCode == languageCode }) ??
                  mockStreams.first else {
            XCTFail("No valid stream available")
            return
        }
        
        XCTAssertEqual(initialTitle, expectedStream.language, "Initial stream language should match locale or default to first stream")
    }
    
    func testPlaySetsUpPlayerAndCallsCompletion() async {
        guard let player = player else {
            XCTFail("Player is nil after setup")
            return
        }
        
        let expectation = XCTestExpectation(description: "Play completes successfully")
        player.simulatedStatus = .readyToPlay
        
        var statusChangedToPlaying = false
        player.onStatusChange = { isPlaying, statusText in
            if isPlaying && statusText == String(localized: "status_playing") {
                statusChangedToPlaying = true
                expectation.fulfill()
            }
        }
        
        await player.play { success in
            XCTAssertTrue(success, "Completion should indicate success when ready to play")
            XCTAssertTrue(player.didCallPlay, "Play method should be called")
        }
        
        await fulfillment(of: [expectation], timeout: 5.0)
        XCTAssertTrue(statusChangedToPlaying, "Status should change to playing")
    }
    
    func testStopRemovesObserversAndPauses() async {
        guard let player = player else {
            XCTFail("Player is nil after setup")
            return
        }
        
        let expectation = XCTestExpectation(description: "Stop completes successfully")
        player.simulatedStatus = .readyToPlay
        
        await player.play { _ in }
        
        var statusStopped = false
        player.onStatusChange = { isPlaying, statusText in
            if !isPlaying && statusText == String(localized: "status_stopped") {
                statusStopped = true
                expectation.fulfill()
            }
        }
        
        await player.stop()
        
        await fulfillment(of: [expectation], timeout: 5.0)
        XCTAssertTrue(player.didCallStop, "Stop method should be called")
        XCTAssertTrue(statusStopped, "Status should change to stopped")
    }
    
    func testSetStreamUpdatesStreamAndPlays() async {
        guard let player = player else {
            XCTFail("Player is nil after setup")
            return
        }
        
        guard mockStreams.count > 1 else {
            XCTFail("Not enough streams available to test stream switching")
            return
        }
        
        let newStream = mockStreams[1]
        let expectation = XCTestExpectation(description: "Stream switch completes")
        player.simulatedStatus = .readyToPlay
        
        var metadataChangedToNewStream = false
        player.onMetadataChange = { title in
            if title == newStream.language {
                metadataChangedToNewStream = true
                expectation.fulfill()
            }
        }
        
        var statusChangedToPlaying = false
        player.onStatusChange = { isPlaying, statusText in
            if isPlaying && statusText == String(localized: "status_playing") {
                statusChangedToPlaying = true
            }
        }
        
        player.setStream(to: newStream)
        
        await fulfillment(of: [expectation], timeout: 5.0)
        XCTAssertTrue(metadataChangedToNewStream, "Metadata should reflect new stream")
        XCTAssertTrue(player.didCallPlay, "Play should be called after setting stream")
        XCTAssertTrue(statusChangedToPlaying, "Status should change to playing")
    }
    
    func testPlaybackFailureTriggersErrorStatus() async {
        guard let player = player else {
            XCTFail("Player is nil after setup")
            return
        }
        
        let expectation = XCTestExpectation(description: "Handles playback failure")
        player.simulatedStatus = .failed
        
        var errorStatusReceived = false
        player.onStatusChange = { isPlaying, statusText in
            if !isPlaying && statusText == String(localized: "status_stream_unavailable") {
                errorStatusReceived = true
                expectation.fulfill()
            }
        }
        
        await player.play { success in
            XCTAssertFalse(success, "Completion should indicate failure")
        }
        
        await fulfillment(of: [expectation], timeout: 5.0)
        XCTAssertTrue(errorStatusReceived, "Status should indicate stream unavailable")
    }
    
    func testSecurityModelValidation() async {
        let player = MockDirectStreamingPlayer(availableStreams: mockStreams)
        let expectation = XCTestExpectation(description: "Validation completes")
        
        player.simulatedValidationResult = false
        player.simulatedSecurityModels = .failure(NSError(domain: "test", code: -1, userInfo: nil))
        
        await player.validateSecurityModelAsync { isValid in
            XCTAssertFalse(isValid, "Validation should fail with mock failure")
            XCTAssertEqual(player.validationState, DirectStreamingPlayer.ValidationState.failedTransient, "Validation state should be failedTransient")
            expectation.fulfill()
        }
        
        await fulfillment(of: [expectation], timeout: 5.0)
        
        let cleanupExpectation = XCTestExpectation(description: "Cleanup completes")
        await player.stop {
            player.clearCallbacks()
            player.networkMonitor?.cancel()
            cleanupExpectation.fulfill()
        }
        await fulfillment(of: [cleanupExpectation], timeout: 5.0)
    }
    
    func testSecurityModelValidationSuccess() async {
        let player = MockDirectStreamingPlayer(availableStreams: mockStreams)
        let expectation = XCTestExpectation(description: "Validation completes")
        
        player.simulatedValidationResult = true
        player.simulatedSecurityModels = .success(["mariehamn"])
        
        await player.validateSecurityModelAsync { isValid in
            XCTAssertTrue(isValid, "Validation should succeed")
            XCTAssertEqual(player.validationState, DirectStreamingPlayer.ValidationState.success, "Validation state should be success")
            expectation.fulfill()
        }
        
        await fulfillment(of: [expectation], timeout: 5.0)
        
        let cleanupExpectation = XCTestExpectation(description: "Cleanup completes")
        await player.stop {
            player.clearCallbacks()
            player.networkMonitor?.cancel()
            cleanupExpectation.fulfill()
        }
        await fulfillment(of: [cleanupExpectation], timeout: 5.0)
    }
    
    func testErrorHandling() async {
        let player = MockDirectStreamingPlayer(availableStreams: mockStreams)
        
        // Test transient error reset
        player.validationState = .failedTransient
        player.hasPermanentError = false
        player.resetTransientErrors()
        XCTAssertEqual(player.validationState, DirectStreamingPlayer.ValidationState.pending, "Transient errors should be reset to pending")
        
        // Test permanent error reporting
        player.hasPermanentError = true
        player.lastError = NSError(domain: "test", code: -1, userInfo: nil)
        XCTAssertTrue(player.isLastErrorPermanent(), "Permanent error should be reported")
        
        // Test transient error handling during playback
        let expectation = XCTestExpectation(description: "Transient error handling")
        player.simulatedValidationResult = false
        player.simulatedSecurityModels = .failure(NSError(domain: "test", code: -1, userInfo: nil))
        
        var errorStatusReceived = false
        player.onStatusChange = { isPlaying, statusText in
            if !isPlaying && statusText == String(localized: "status_no_internet") {
                errorStatusReceived = true
                expectation.fulfill()
            }
        }
        
        await player.validateSecurityModelAsync { isValid in
            XCTAssertFalse(isValid, "Validation should fail")
        }
        
        await fulfillment(of: [expectation], timeout: 5.0)
        XCTAssertTrue(errorStatusReceived, "Status should indicate no internet")
        
        // Cleanup
        let cleanupExpectation = XCTestExpectation(description: "Cleanup completes")
        await player.stop {
            player.clearCallbacks()
            player.networkMonitor?.cancel()
            cleanupExpectation.fulfill()
        }
        await fulfillment(of: [cleanupExpectation], timeout: 5.0)
    }
}
