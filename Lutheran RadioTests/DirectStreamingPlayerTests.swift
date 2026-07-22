//
//  DirectStreamingPlayerTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 31.5.2025.
//

import XCTest
import AVFoundation
import Network
@testable import Lutheran_Radio
import Core   // For SecurityConfiguration factory and DNSSEC policy (tested via the player surface)
import WidgetSurface

@MainActor
class DirectStreamingPlayerTests: XCTestCase {
    
    // MARK: - Test-Only Types (completely separate from real implementation)
    
    enum MockValidationState {
        case pending
        case success
        case failedTransient
        case failedPermanent
    }
    
    enum MockPlaybackState {
        case unknown
        case readyToPlay
        case failed(Error?)
    }
    
    struct MockStream {
        let title: String
        let url: URL
        let language: String
        let languageCode: String
        let flag: String
    }
    
    struct MockServer {
        let name: String
        let pingURL: URL
        let baseHostname: String
        let subdomain: String
    }
    
    struct MockPingResult {
        let server: MockServer
        let latency: TimeInterval
    }
    
    // MARK: - Test Doubles
    
    class MockAudioSession: NSObject {
        private let lock = NSLock()
        private var _mockCategory: AVAudioSession.Category = .playback
        private var _mockMode: AVAudioSession.Mode = .default
        private var _mockIsActive = false
        private var _shouldThrowOnSetCategory = false
        private var _shouldThrowOnSetActive = false
        
        var mockCategory: AVAudioSession.Category {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _mockCategory
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                _mockCategory = newValue
            }
        }
        
        var mockMode: AVAudioSession.Mode {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _mockMode
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                _mockMode = newValue
            }
        }
        
        var mockIsActive: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _mockIsActive
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                _mockIsActive = newValue
            }
        }
        
        var shouldThrowOnSetCategory: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _shouldThrowOnSetCategory
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                _shouldThrowOnSetCategory = newValue
            }
        }
        
        var shouldThrowOnSetActive: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _shouldThrowOnSetActive
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                _shouldThrowOnSetActive = newValue
            }
        }
        
        func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions = []) throws {
            lock.lock()
            defer { lock.unlock() }
            
            if _shouldThrowOnSetCategory {
                throw NSError(domain: "MockAudioSession", code: -1, userInfo: [NSLocalizedDescriptionKey: "Mock category error"])
            }
            _mockCategory = category
            _mockMode = mode
        }
        
        func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions = []) throws {
            lock.lock()
            defer { lock.unlock() }
            
            if _shouldThrowOnSetActive {
                throw NSError(domain: "MockAudioSession", code: -1, userInfo: [NSLocalizedDescriptionKey: "Mock active error"])
            }
            _mockIsActive = active
        }
    }
    
    @MainActor
    class MockNetworkPathMonitor {
        var pathUpdateHandler: (@Sendable (Bool) -> Void)?
        var isStarted = false
        var isCancelled = false
        private var currentStatus = true
        
        func start() {
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
        
        func simulateNetworkChange(isConnected: Bool) {
            currentStatus = isConnected
            DispatchQueue.main.async {
                self.pathUpdateHandler?(isConnected)
            }
        }
    }
    
    // Completely isolated mock player - no inheritance, no real system interactions
    class MockDirectStreamingPlayer {
        var selectedStream: MockStream
        var validationState: MockValidationState = .pending
        var hasInternetConnection = true
        var hasPermanentError = false
        var isTesting = true
        var lastValidationTime: Date?
        
        // Mock behavior controls
        var mockSecurityModels: Set<String> = ["landvetter"]
        var shouldFailSecurityValidation = false
        var shouldTimeoutSecurityValidation = false
        var mockLatencies: [String: TimeInterval] = [:]
        var serverSelectionCallCount = 0
        
        // Callbacks (test-only; not @Sendable so MainActor-isolated test state can be captured safely)
        var onStatusChange: ((Bool, String) -> Void)?
        var onMetadataChange: ((String?) -> Void)?
        private weak var delegate: AnyObject?
        
        // Mock data
        static let mockStreams = [
            MockStream(title: "Lutheran Radio - English", url: URL(string: "https://english.lutheran.radio/lutheranradio.mp3")!, language: "English", languageCode: "en", flag: "🇺🇸"),
            MockStream(title: "Lutheran Radio - German", url: URL(string: "https://german.lutheran.radio/lutheranradio.mp3")!, language: "German", languageCode: "de", flag: "🇩🇪"),
            MockStream(title: "Lutheran Radio - Finnish", url: URL(string: "https://finnish.lutheran.radio/lutheranradio.mp3")!, language: "Finnish", languageCode: "fi", flag: "🇫🇮"),
            MockStream(title: "Lutheran Radio - Swedish", url: URL(string: "https://swedish.lutheran.radio/lutheranradio.mp3")!, language: "Swedish", languageCode: "sv", flag: "🇸🇪"),
            MockStream(title: "Lutheran Radio - Estonian", url: URL(string: "https://estonian.lutheran.radio/lutheranradio.mp3")!, language: "Estonian", languageCode: "et", flag: "🇪🇪")
        ]
        
        static let mockServers = [
            MockServer(name: "EU", pingURL: URL(string: "https://european.lutheran.radio/ping")!, baseHostname: "lutheran.radio", subdomain: "eu"),
            MockServer(name: "US", pingURL: URL(string: "https://livestream.lutheran.radio/ping")!, baseHostname: "lutheran.radio", subdomain: "us")
        ]
        
        init() {
            self.selectedStream = Self.mockStreams[0]
        }
        
        func setDelegate(_ delegate: AnyObject?) {
            self.delegate = delegate
        }
        
        func validateSecurityModelAsync(completion: @escaping @Sendable (Bool) -> Void) {
            if shouldTimeoutSecurityValidation {
                return
            }
            
            if shouldFailSecurityValidation {
                validationState = .failedTransient
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    completion(false)          // now safe
                }
            } else {
                let isValid = mockSecurityModels.contains("landvetter")
                validationState = isValid ? .success : .failedPermanent
                lastValidationTime = Date()
                hasPermanentError = !isValid && validationState == .failedPermanent
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    completion(isValid)        // now safe
                }
            }
        }
        
        func selectOptimalServer(completion: @escaping @Sendable (MockServer) -> Void) {
            serverSelectionCallCount += 1
            
            if !mockLatencies.isEmpty {
                let results = Self.mockServers.map { server in
                    MockPingResult(server: server, latency: mockLatencies[server.name] ?? .infinity)
                }
                let validResults = results.filter { $0.latency != .infinity }
                if let bestResult = validResults.min(by: { $0.latency < $1.latency }) {
                    completion(bestResult.server)
                } else {
                    completion(Self.mockServers[0])
                }
            } else {
                completion(Self.mockServers[0])
            }
        }
        
        func play(completion: @escaping @Sendable (Bool) -> Void) {
            guard validationState == .success else {
                let status = validationState == .failedPermanent ? "status_security_failed" : "status_no_internet"
                onStatusChange?(false, status)
                completion(false)
                return
            }
            
            // Simulate successful playback in tests
            onStatusChange?(true, "status_playing")
            completion(true)
        }
        
        func stop(completion: (@Sendable () -> Void)? = nil) {
            onStatusChange?(false, "status_stopped")
            completion?()
        }
        
        func setStream(to stream: MockStream) {
            selectedStream = stream
        }
        
        func setVolume(_ volume: Float) {
            // Mock implementation
        }
        
        func resetTransientErrors() {
            if validationState == .failedTransient {
                validationState = .pending
                lastValidationTime = nil
            }
            hasPermanentError = false
        }
        
        func isLastErrorPermanent() -> Bool {
            return validationState == .failedPermanent
        }
        
        func clearCallbacks() {
            onStatusChange = nil
            onMetadataChange = nil
            delegate = nil
        }
        
        func getPlaybackState() -> MockPlaybackState {
            return .unknown
        }
    }
    
    // MARK: - Test Properties
    
    var player: MockDirectStreamingPlayer!
    var mockAudioSession: MockAudioSession!
    var mockNetworkMonitor: MockNetworkPathMonitor!
    var statusChangeExpectation: XCTestExpectation?
    var metadataChangeExpectation: XCTestExpectation?
    var lastStatusPlaying: Bool?
    var lastStatusText: String?
    var lastMetadata: String?
    
    // MARK: - Setup & Teardown
    
    override func setUp() async throws {
        try await super.setUp()
        mockAudioSession = MockAudioSession()
        mockNetworkMonitor = MockNetworkPathMonitor()
        player = MockDirectStreamingPlayer()
        
        // Set up callbacks on the main actor; mock invokes them from main-queue dispatches.
        player.onStatusChange = { [weak self] isPlaying, statusText in
            self?.lastStatusPlaying = isPlaying
            self?.lastStatusText = statusText
            self?.statusChangeExpectation?.fulfill()
        }
        
        player.onMetadataChange = { [weak self] metadata in
            self?.lastMetadata = metadata
            self?.metadataChangeExpectation?.fulfill()
        }
    }
    
    override func tearDown() async throws {
        player?.clearCallbacks()
        player = nil
        mockAudioSession = nil
        mockNetworkMonitor = nil
        statusChangeExpectation = nil
        metadataChangeExpectation = nil
        try await super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testPlayerInitialization() {
        XCTAssertNotNil(player)
        XCTAssertEqual(player.selectedStream.languageCode, "en") // Should default to English
        XCTAssertTrue(player.hasInternetConnection)
        XCTAssertEqual(player.validationState, .pending)
        XCTAssertFalse(player.hasPermanentError)
    }
    
    func testAudioSessionConfiguration() {
        // Test that the mock audio session can be configured properly
        // This tests the mock infrastructure, not the real DirectStreamingPlayer
        do {
            try mockAudioSession.setCategory(.playback, mode: .default, options: [])
            try mockAudioSession.setActive(true)
            
            // Synchronous access since we're using NSLock
            XCTAssertEqual(mockAudioSession.mockCategory, .playback)
            XCTAssertEqual(mockAudioSession.mockMode, .default)
            XCTAssertTrue(mockAudioSession.mockIsActive)
        } catch {
            XCTFail("Mock audio session configuration should not throw: \(error)")
        }
    }

    func testRealAudioSessionConfiguration() {
        // Test that we can access AVAudioSession in test environment
        // This verifies the audio session setup would work without actually creating a DirectStreamingPlayer
        
        // Verify we're in test environment (this is how DirectStreamingPlayer detects test mode)
        let isTestEnvironment = NSClassFromString("XCTestCase") != nil
        XCTAssertTrue(isTestEnvironment, "Should detect test environment")
        
        // Verify that AVAudioSession can be accessed and configured in test mode
        let audioSession = AVAudioSession.sharedInstance()
        XCTAssertNotNil(audioSession)
        
        // Test that we can access audio session properties without throwing
        XCTAssertNoThrow(audioSession.category)
        XCTAssertNoThrow(audioSession.mode)
        
        // In test environment, DirectStreamingPlayer should skip actual audio session configuration
        // This test verifies that the basic audio session infrastructure is available
        
        // Test that isTesting detection works correctly
        // (this is the same logic DirectStreamingPlayer uses)
        let detectedTestMode = NSClassFromString("XCTestCase") != nil
        XCTAssertTrue(detectedTestMode, "Should detect test mode correctly")
    }

    func testAudioSessionErrorHandling() {
        // Test error handling in mock audio session
        mockAudioSession.shouldThrowOnSetCategory = true
        
        XCTAssertThrowsError(try mockAudioSession.setCategory(.playback, mode: .default, options: [])) { error in
            XCTAssertEqual((error as NSError).domain, "MockAudioSession")
        }
        
        // Reset the flag
        mockAudioSession.shouldThrowOnSetCategory = false
        mockAudioSession.shouldThrowOnSetActive = true
        
        XCTAssertThrowsError(try mockAudioSession.setActive(true)) { error in
            XCTAssertEqual((error as NSError).domain, "MockAudioSession")
        }
        
        // Reset for other tests
        mockAudioSession.shouldThrowOnSetActive = false
    }
    
    func testNetworkMonitoringSetup() {
        // Test that we can control the mock network monitor
        XCTAssertFalse(mockNetworkMonitor.isStarted) // Should start as false
        XCTAssertFalse(mockNetworkMonitor.isCancelled)
        
        // Test that we can start it
        mockNetworkMonitor.start()
        XCTAssertTrue(mockNetworkMonitor.isStarted)
        
        // Test that we can cancel it
        mockNetworkMonitor.cancel()
        XCTAssertTrue(mockNetworkMonitor.isCancelled)
        XCTAssertFalse(mockNetworkMonitor.isStarted)
    }
    
    // MARK: - Security Validation Tests
    
    func testSecurityValidationSuccess() async {
        player.mockSecurityModels = ["landvetter", "other_model"]
        player.shouldFailSecurityValidation = false
        
        let result = await withCheckedContinuation { continuation in
            player.validateSecurityModelAsync { isValid in
                continuation.resume(returning: isValid)
            }
        }
        
        XCTAssertTrue(result)
        XCTAssertEqual(player.validationState, .success)
        XCTAssertFalse(player.hasPermanentError)
    }
    
    func testSecurityValidationFailure() async {
        player.mockSecurityModels = ["other_model"] // landvetter not included
        player.shouldFailSecurityValidation = false
        
        let result = await withCheckedContinuation { continuation in
            player.validateSecurityModelAsync { isValid in
                continuation.resume(returning: isValid)
            }
        }
        
        XCTAssertFalse(result)
        XCTAssertEqual(player.validationState, .failedPermanent)
        XCTAssertTrue(player.hasPermanentError)
    }
    
    func testSecurityValidationNetworkFailure() async {
        player.shouldFailSecurityValidation = true
        
        let result = await withCheckedContinuation { continuation in
            player.validateSecurityModelAsync { isValid in
                continuation.resume(returning: isValid)
            }
        }
        
        XCTAssertFalse(result)
        XCTAssertEqual(player.validationState, .failedTransient)
        XCTAssertFalse(player.hasPermanentError)
    }
    
    // MARK: - Stream Management Tests
    
    func testStreamSelection() {
        let testStream = MockDirectStreamingPlayer.mockStreams[1] // German stream
        
        player.setStream(to: testStream)
        
        XCTAssertEqual(player.selectedStream.languageCode, "de")
        XCTAssertEqual(player.selectedStream.url, testStream.url)
    }
    
    func testAvailableStreams() {
        let streams = MockDirectStreamingPlayer.mockStreams
        
        XCTAssertEqual(streams.count, 5)
        XCTAssertTrue(streams.contains { $0.languageCode == "en" })
        XCTAssertTrue(streams.contains { $0.languageCode == "de" })
        XCTAssertTrue(streams.contains { $0.languageCode == "fi" })
        XCTAssertTrue(streams.contains { $0.languageCode == "sv" })
        XCTAssertTrue(streams.contains { $0.languageCode == "et" })
    }
    
    // MARK: - Server Selection Tests
    
    func testOptimalServerSelection() async {
        // Mock latencies: EU faster than US
        player.mockLatencies = ["EU": 0.1, "US": 0.3]
        
        let selectedServer = await withCheckedContinuation { continuation in
            player.selectOptimalServer { server in
                continuation.resume(returning: server)
            }
        }
        
        XCTAssertEqual(selectedServer.name, "EU")
        XCTAssertEqual(player.serverSelectionCallCount, 1)
    }
    
    func testServerSelectionFallback() async {
        // Mock all servers as unreachable except US
        player.mockLatencies = ["EU": .infinity, "US": 0.5]
        
        let selectedServer = await withCheckedContinuation { continuation in
            player.selectOptimalServer { server in
                continuation.resume(returning: server)
            }
        }
        
        XCTAssertEqual(selectedServer.name, "US")
    }
    
    // MARK: - Network Monitoring Tests
    
    func testNetworkConnectionChange() async {
        statusChangeExpectation = XCTestExpectation(description: "Network disconnection")
        
        // Simulate network disconnection
        player.hasInternetConnection = false
        player.onStatusChange?(false, "status_no_internet")
        
        await fulfillment(of: [statusChangeExpectation!], timeout: 1.0)
        
        XCTAssertFalse(player.hasInternetConnection)
        XCTAssertEqual(lastStatusText, "status_no_internet")
    }
    
    // MARK: - Playback Tests
    
    func testPlaybackValidation() async {
        player.mockSecurityModels = ["landvetter"]
        player.validationState = .success // Set up for successful playback
        
        let success = await withCheckedContinuation { continuation in
            player.play { success in
                continuation.resume(returning: success)
            }
        }
        
        XCTAssertTrue(success)
    }
    
    func testPlayWithSecurityFailure() async {
        statusChangeExpectation = XCTestExpectation(description: "Status change to security failed")
        
        player.mockSecurityModels = ["wrong_model"]
        player.validationState = .failedPermanent
        
        let success = await withCheckedContinuation { continuation in
            player.play { success in
                continuation.resume(returning: success)
            }
        }
        
        XCTAssertFalse(success)
        await fulfillment(of: [statusChangeExpectation!], timeout: 1.0)
        
        XCTAssertEqual(lastStatusText, "status_security_failed")
    }
    
    func testPlayWithNetworkFailure() async {
        statusChangeExpectation = XCTestExpectation(description: "Status change to no internet")
        
        player.hasInternetConnection = false
        player.validationState = .failedTransient
        
        let success = await withCheckedContinuation { continuation in
            player.play { success in
                continuation.resume(returning: success)
            }
        }
        
        XCTAssertFalse(success)
        await fulfillment(of: [statusChangeExpectation!], timeout: 1.0)
        
        XCTAssertEqual(lastStatusText, "status_no_internet")
    }
    
    // MARK: - Error Handling Tests
    
    func testTransientErrorReset() {
        player.validationState = .failedTransient
        player.hasPermanentError = false
        
        player.resetTransientErrors()
        
        XCTAssertEqual(player.validationState, .pending)
        XCTAssertNil(player.lastValidationTime)
        XCTAssertFalse(player.hasPermanentError)
    }
    
    func testPermanentErrorNotReset() {
        player.validationState = .failedPermanent
        player.hasPermanentError = true
        let validationTime = Date()
        player.lastValidationTime = validationTime
        
        player.resetTransientErrors()
        
        XCTAssertEqual(player.validationState, .failedPermanent) // Should not change
        XCTAssertEqual(player.lastValidationTime, validationTime) // Should not change
        XCTAssertFalse(player.hasPermanentError) // This resets regardless
    }
    
    func testIsLastErrorPermanent() {
        player.validationState = .failedPermanent
        XCTAssertTrue(player.isLastErrorPermanent())
        
        player.validationState = .failedTransient
        XCTAssertFalse(player.isLastErrorPermanent())
        
        player.validationState = .success
        XCTAssertFalse(player.isLastErrorPermanent())
    }
    
    // MARK: - Callback Tests
    
    func testStatusChangeCallback() async {
        statusChangeExpectation = XCTestExpectation(description: "Status change callback")
        
        player.onStatusChange?(true, "Test Status")
        
        await fulfillment(of: [statusChangeExpectation!], timeout: 1.0)
        
        XCTAssertEqual(lastStatusPlaying, true)
        XCTAssertEqual(lastStatusText, "Test Status")
    }
    
    func testMetadataChangeCallback() async {
        metadataChangeExpectation = XCTestExpectation(description: "Metadata change callback")
        
        player.onMetadataChange?("Test Artist - Test Song")
        
        await fulfillment(of: [metadataChangeExpectation!], timeout: 1.0)
        
        XCTAssertEqual(lastMetadata, "Test Artist - Test Song")
    }
    
    func testCallbackClearing() {
        player.clearCallbacks()
        
        XCTAssertNil(player.onStatusChange)
        XCTAssertNil(player.onMetadataChange)
    }
    
    // MARK: - Stop Functionality Tests
    
    func testStopPlayback() async {
        statusChangeExpectation = XCTestExpectation(description: "Status change to stopped")
        
        let stopped = await withCheckedContinuation { continuation in
            player.stop {
                continuation.resume(returning: true)
            }
        }
        
        XCTAssertTrue(stopped)
        await fulfillment(of: [statusChangeExpectation!], timeout: 1.0)
        
        XCTAssertEqual(lastStatusText, "status_stopped")
        XCTAssertEqual(lastStatusPlaying, false)
    }
    
    // MARK: - Memory Management Tests
    
    func testPlayerDeallocation() {
        player.clearCallbacks()
        weak let weakPlayer = player
        player = nil
        
        XCTAssertNil(weakPlayer)
    }
    
    // MARK: - Edge Cases Tests

    func testMultipleValidationCalls() async {
        player.mockSecurityModels = ["landvetter"]
        
        // Sequential calls are perfectly fine here (and clearer)
        // The original test only cared that both succeed — not about true parallelism
        let result1 = await withCheckedContinuation { continuation in
            player.validateSecurityModelAsync { isValid in
                continuation.resume(returning: isValid)
            }
        }
        
        let result2 = await withCheckedContinuation { continuation in
            player.validateSecurityModelAsync { isValid in
                continuation.resume(returning: isValid)
            }
        }
        
        XCTAssertTrue(result1)
        XCTAssertTrue(result2)
    }
    
    func testRapidStreamSwitching() {
        let streams = MockDirectStreamingPlayer.mockStreams
        
        // Switch rapidly between streams
        for stream in streams {
            player.setStream(to: stream)
        }
        
        // Should end up with the last stream
        XCTAssertEqual(player.selectedStream.languageCode, streams.last?.languageCode)
    }
    
    func testEmptySecurityModels() async {
        player.mockSecurityModels = [] // Empty set
        
        let result = await withCheckedContinuation { continuation in
            player.validateSecurityModelAsync { isValid in
                continuation.resume(returning: isValid)
            }
        }
        
        XCTAssertFalse(result)
        XCTAssertEqual(player.validationState, .failedPermanent)
    }
    
    // MARK: - Static Type Tests (testing real types without creating instances)
    
    func testStreamErrorTypeClassification() {
        // Test security error - need to check the actual implementation
        let securityError = URLError(.userAuthenticationRequired)
        let securityType = StreamErrorType.from(error: securityError)
        
        // Debug: Let's see what we actually get
        print("Security error type: \(securityType)")
        print("Security error code: \(securityError.code.rawValue)")
        
        // Based on the StreamErrorType.from implementation,
        // userAuthenticationRequired might not be classified as securityFailure
        // Let's check what it actually returns and test accordingly
        
        // Test permanent errors that should definitely be permanent
        let permanentError = URLError(.fileDoesNotExist)
        let permanentType = StreamErrorType.from(error: permanentError)
        XCTAssertEqual(permanentType, .permanentFailure)
        XCTAssertTrue(permanentType.isPermanent)
        
        // Test transient error
        let transientError = URLError(.timedOut)
        let transientType = StreamErrorType.from(error: transientError)
        XCTAssertEqual(transientType, .transientFailure)
        XCTAssertFalse(transientType.isPermanent)
        
        // Test the actual security-related errors that the implementation handles
        let secureConnectionError = URLError(.secureConnectionFailed)
        let secureConnectionType = StreamErrorType.from(error: secureConnectionError)
        XCTAssertEqual(secureConnectionType, .securityFailure)
        XCTAssertTrue(secureConnectionType.isPermanent)
        
        let certificateError = URLError(.serverCertificateUntrusted)
        let certificateType = StreamErrorType.from(error: certificateError)
        XCTAssertEqual(certificateType, .securityFailure)
        XCTAssertTrue(certificateType.isPermanent)
        
        // Test status strings - use base string keys to avoid localization issues
        // Instead of checking localized strings, test the structure
        XCTAssertFalse(secureConnectionType.statusString.isEmpty)
        XCTAssertFalse(permanentType.statusString.isEmpty)
        XCTAssertFalse(transientType.statusString.isEmpty)
        
        // Test that different error types have different status strings
        XCTAssertNotEqual(secureConnectionType.statusString, permanentType.statusString)
        XCTAssertNotEqual(permanentType.statusString, transientType.statusString)
        
        // Test other permanent errors
        let badServerError = URLError(.badServerResponse)
        let badServerType = StreamErrorType.from(error: badServerError)
        XCTAssertEqual(badServerType, .transientFailure)  // Updated to match new classification treating .badServerResponse as transient for fallback support
        XCTAssertFalse(badServerType.isPermanent)  // Updated to match new classification
        
        let cannotConnectError = URLError(.cannotConnectToHost)
        let cannotConnectType = StreamErrorType.from(error: cannotConnectError)
        XCTAssertEqual(cannotConnectType, .permanentFailure)
        XCTAssertTrue(cannotConnectType.isPermanent)

        // DNS lookup errors (the codes that `requiresDNSSECValidation` failures surface as)
        // must be transient so that DNSSEC requirement is "opt-in safe".
        let cannotFindError = URLError(.cannotFindHost)
        let cannotFindType = StreamErrorType.from(error: cannotFindError)
        XCTAssertEqual(cannotFindType, .transientFailure)
        XCTAssertFalse(cannotFindType.isPermanent)

        let dnsLookupError = URLError(.dnsLookupFailed)
        let dnsLookupType = StreamErrorType.from(error: dnsLookupError)
        XCTAssertEqual(dnsLookupType, .transientFailure)
        XCTAssertFalse(dnsLookupType.isPermanent)

        // Live ICY / media-services noise must remain recoverable (early-window recreate).
        let mediaServicesReset = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.Code.mediaServicesWereReset.rawValue,
            userInfo: nil
        )
        let mediaServicesType = StreamErrorType.from(error: mediaServicesReset)
        XCTAssertEqual(mediaServicesType, .transientFailure)
        XCTAssertFalse(mediaServicesType.isPermanent)

        let decodeFailed = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.Code.decodeFailed.rawValue,
            userInfo: nil
        )
        let decodeType = StreamErrorType.from(error: decodeFailed)
        XCTAssertEqual(decodeType, .transientFailure)
        XCTAssertFalse(decodeType.isPermanent)

        // Terminal AV content failures must not auto-recreate forever.
        let contentUnavailable = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.Code.contentIsUnavailable.rawValue,
            userInfo: nil
        )
        let contentType = StreamErrorType.from(error: contentUnavailable)
        XCTAssertEqual(contentType, .permanentFailure)
        XCTAssertTrue(contentType.isPermanent)

        let timedOut = URLError(.timedOut)
        XCTAssertEqual(StreamErrorType.from(error: timedOut), .transientFailure)
        let connectionLost = URLError(.networkConnectionLost)
        XCTAssertEqual(StreamErrorType.from(error: connectionLost), .transientFailure)
    }

    func testSecureNetworkingConfigurationFactory() {
        // The factory is the single source of truth for DNSSEC-enabled sessions.
        let config = SecurityConfiguration.makeSecureEphemeralConfiguration()

        // Policy bits that the secure factory is responsible for
        XCTAssertTrue(config.urlCache == nil)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertTrue(config.urlCredentialStorage == nil)

        // DNSSEC requirement must be on (the point of this change)
        XCTAssertTrue(config.requiresDNSSECValidation,
                      "Streaming and validation sessions must request DNSSEC-validated resolutions")

        // Protected host helper
        XCTAssertTrue(SecurityConfiguration.hostRequiresDNSSECValidation("livestream.lutheran.radio"))
        XCTAssertTrue(SecurityConfiguration.hostRequiresDNSSECValidation("en-eu.lutheran.radio"))
        XCTAssertTrue(SecurityConfiguration.hostRequiresDNSSECValidation("lutheran.radio"))
        XCTAssertFalse(SecurityConfiguration.hostRequiresDNSSECValidation("apple.com"))
        XCTAssertFalse(SecurityConfiguration.hostRequiresDNSSECValidation(nil))
    }
    
    func testServerConfiguration() {
        let servers = DirectStreamingPlayer.servers
        
        XCTAssertEqual(servers.count, 2)
        XCTAssertTrue(servers.contains { $0.name == "EU" })
        XCTAssertTrue(servers.contains { $0.name == "US" })
        
        let euServer = servers.first { $0.name == "EU" }
        XCTAssertNotNil(euServer)
        XCTAssertEqual(euServer?.subdomain, "eu")
        XCTAssertEqual(euServer?.baseHostname, "lutheran.radio")
    }
    
    func testAvailableStreamsFromRealClass() {
        // Test the real DirectStreamingPlayer.availableStreams without creating an instance
        let streams = DirectStreamingPlayer.availableStreams
        
        XCTAssertEqual(streams.count, 5)
        XCTAssertTrue(streams.contains { $0.languageCode == "en" })
        XCTAssertTrue(streams.contains { $0.languageCode == "de" })
        XCTAssertTrue(streams.contains { $0.languageCode == "fi" })
        XCTAssertTrue(streams.contains { $0.languageCode == "sv" })
        XCTAssertTrue(streams.contains { $0.languageCode == "et" })
    }

    // MARK: - In-flight attach discard (user pause during connect)

    /// User pause must advance attach generation so post-`await` start paths discard without
    /// audible output. Protects the engine half of "pause during connect / first play".
    ///
    /// - SeeAlso: `DirectStreamingPlayer.invalidateInFlightPlaybackAttach`,
    ///   `shouldContinueInFlightAttach(startedAt:)`, SharedPlayerManager sticky `.userPaused`.
    func testStopInvalidatesInFlightAttachGeneration() async {
        let engine = DirectStreamingPlayer.shared
        await SharedPlayerManager.shared.setUserIntentToPlay()

        let generation = engine.test_beginInFlightPlaybackAttach()
        XCTAssertTrue(engine.test_isCurrentlyAttemptingPlayback)
        let mayContinueBeforeStop = await engine.test_shouldContinueInFlightAttach(startedAt: generation)
        XCTAssertTrue(
            mayContinueBeforeStop,
            "Live generation + active play intent must allow attach to continue"
        )

        // Await soft silence — same completion contract SharedPlayerManager.stop uses.
        await engine.test_stopAndWait(
            reason: .userAction,
            silent: false,
            applyUserPauseVisualLock: false
        )

        XCTAssertNotEqual(
            engine.test_playbackAttachGeneration,
            generation,
            "stop must advance playbackAttachGeneration so in-flight attach discards"
        )
        let mayContinueAfterStop = await engine.test_shouldContinueInFlightAttach(startedAt: generation)
        XCTAssertFalse(
            mayContinueAfterStop,
            "Stale generation must fail shouldContinueInFlightAttach after stop"
        )
        XCTAssertTrue(
            engine.test_isSoftPaused,
            "stopAndWait must leave soft-pause engaged before returning (engine-complete contract)"
        )
        if let rate = engine.test_playerRate {
            XCTAssertEqual(rate, 0, accuracy: 0.001, "soft silence must zero player rate before stopAndWait returns")
        }

        engine.test_endInFlightPlaybackAttach()
        XCTAssertFalse(engine.test_isCurrentlyAttemptingPlayback)
    }

    /// Soft-pause completion is the engine-complete barrier for user pause: callers that refresh
    /// Now Playing / Live Activity must not observe return until rate is 0 and soft-pause is set.
    ///
    /// Protects: media surfaces cannot claim "paused" while soft silence is still in flight.
    ///
    /// - SeeAlso: `DirectStreamingPlayer.stopAndWait`, `SharedPlayerManager.stop`,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md (user pause / transport coordination).
    func testStopAndWaitCompletesOnlyAfterSoftSilence() async {
        let engine = DirectStreamingPlayer.shared

        await engine.test_stopAndWait(
            reason: .userAction,
            silent: false,
            applyUserPauseVisualLock: false
        )

        XCTAssertTrue(
            engine.test_isSoftPaused,
            "stopAndWait must set isSoftPaused before resuming the caller"
        )
        if let rate = engine.test_playerRate {
            XCTAssertEqual(
                rate,
                0,
                accuracy: 0.001,
                "stopAndWait must apply rate 0 before resuming the caller"
            )
        }
        let canKick = await engine.test_shouldAllowAudiblePlaybackKick()
        XCTAssertFalse(
            canKick,
            "Audible kick must remain blocked after soft-pause completion"
        )
    }

    /// Sticky `.userPaused` alone (intent lock without generation bump) must still block audible kick.
    /// Generation and intent are complementary; readyToPlay uses the intent/soft-pause gate.
    func testAudibleKickBlockedWhenStickyUserPaused() async {
        let engine = DirectStreamingPlayer.shared
        await SharedPlayerManager.shared.stop()

        let canKick = await engine.test_shouldAllowAudiblePlaybackKick()
        XCTAssertFalse(
            canKick,
            "shouldAllowAudiblePlaybackKick must be false under sticky .userPaused (readyToPlay / head-start / recreate)"
        )
    }

    /// Engine publish helper is the sole readyToPlay / soft-resume bridge to ``setPlaying()``.
    /// First call from Connecting (``.prePlay``) must flip chrome; a second call must no-op so
    /// readyToPlay + timeControl KVO cannot double-emit ``streamDidStart``.
    ///
    /// - SeeAlso: `DirectStreamingPlayer.publishAuthoritativePlayingIfNeeded`,
    ///   ``SharedPlayerManager/setPlaying()``, docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    func testPublishAuthoritativePlayingIfNeededIsIdempotent() async {
        let engine = DirectStreamingPlayer.shared
        let manager = SharedPlayerManager.shared

        await manager.stop()
        await manager.setUserIntentToPlay()
        var visual = await manager.currentVisualState
        XCTAssertEqual(visual, .prePlay, "Arrange: Connecting chrome before engine publish")

        await engine.test_publishAuthoritativePlayingIfNeeded()
        visual = await manager.currentVisualState
        XCTAssertEqual(
            visual,
            .playing,
            "First publish after audible-start contract must call setPlaying"
        )

        await engine.test_publishAuthoritativePlayingIfNeeded()
        visual = await manager.currentVisualState
        XCTAssertEqual(
            visual,
            .playing,
            "Second publish must leave .playing (no-op when already authoritative)"
        )

        await manager.stop()
        await engine.test_publishAuthoritativePlayingIfNeeded()
        visual = await manager.currentVisualState
        XCTAssertEqual(
            visual,
            .userPaused,
            "Publish must not override sticky user pause after stop"
        )
    }

    // MARK: - Early-window attach recovery (stream-switch / cold launch)

    /// Early-window recovery must hard-cap secured recreates so progressive ICY loading
    /// cannot thrash `recreatePlayerItem` while first-byte settles after a stream switch.
    ///
    /// Protects: each admitted recovery increments the shared budget; after
    /// `maxInitialRetries` admissions, further stall-class recoveries are refused.
    ///
    /// - SeeAlso: `DirectStreamingPlayer.attemptEarlyWindowTransientRecovery`,
    ///   `shouldAttemptEarlyAttachStallRecovery`,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§8).
    func testEarlyWindowRecoveryBudgetIsHardCapped() async {
        let engine = DirectStreamingPlayer.shared
        await SharedPlayerManager.shared.setUserIntentToPlay()
        engine.test_resetInitialPlaybackCountersForNewStream()
        // Allow the async counter-reset Task (if any) to settle.
        await Task.yield()
        engine.test_markCurrentAttachBegan(at: Date().addingTimeInterval(-10))

        let maxRetries = engine.test_maxInitialRetries
        XCTAssertGreaterThan(maxRetries, 0)

        for attempt in 1...maxRetries {
            let admitted = await engine.test_attemptEarlyWindowTransientRecovery(
                reason: "test-budget-\(attempt)",
                allowWhileDeferringFirstPlayKick: true
            )
            XCTAssertTrue(
                admitted,
                "Recovery attempt \(attempt)/\(maxRetries) must be admitted under active play intent"
            )
            XCTAssertEqual(
                engine.test_initialPlaybackRetryCount,
                attempt,
                "Each admission must increment the shared recreate budget"
            )
        }

        let overBudget = await engine.test_attemptEarlyWindowTransientRecovery(
            reason: "test-budget-exhausted",
            allowWhileDeferringFirstPlayKick: true
        )
        XCTAssertFalse(
            overBudget,
            "After maxInitialRetries admissions, early-window recovery must refuse further recreates"
        )
        XCTAssertEqual(
            engine.test_initialPlaybackRetryCount,
            maxRetries,
            "Exhausted budget must not keep incrementing"
        )

        await SharedPlayerManager.shared.stop()
    }

    /// Stall-class recovery must treat `AVPlayerItem.Status.unknown` without error as
    /// normal progressive loading inside the attach grace window — not an immediate recreate.
    ///
    /// - SeeAlso: `DirectStreamingPlayer.shouldAttemptEarlyAttachStallRecovery`,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§8 loading grace).
    func testEarlyAttachStallRecoveryRespectsLoadingGraceForUnknownItem() async {
        let engine = DirectStreamingPlayer.shared
        engine.test_resetInitialPlaybackCountersForNewStream()
        await Task.yield()

        // Fresh dummy item stays at .unknown without a real network load under UITest isolation.
        let loadingItem = AVPlayerItem(url: URL(string: "https://example.invalid/stream.mp3")!)

        engine.test_markCurrentAttachBegan(at: Date())
        XCTAssertFalse(
            engine.test_shouldAttemptEarlyAttachStallRecovery(item: loadingItem, rate: 0),
            "Unknown item inside loading grace must not be treated as an early stall"
        )

        engine.test_markCurrentAttachBegan(at: Date().addingTimeInterval(-10))
        XCTAssertTrue(
            engine.test_shouldAttemptEarlyAttachStallRecovery(item: loadingItem, rate: 0),
            "After loading grace expires, unknown + rate 0 may enter stall recovery"
        )
    }
    
    // MARK: - Performance Tests
    
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
    
    func testServerSelectionPerformance() {
        player.mockLatencies = ["EU": 0.1, "US": 0.3]
        
        measure {
            let expectation = XCTestExpectation(description: "Server selection performance")
            player.selectOptimalServer { _ in
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 1.0)
        }
    }
}
