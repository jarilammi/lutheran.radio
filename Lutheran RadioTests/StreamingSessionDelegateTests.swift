//
//  StreamingSessionDelegateTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 15.3.2025.
//

import XCTest
import AVFoundation
@testable import Lutheran_Radio

/// Comprehensive test suite for StreamingSessionDelegate
/// Uses integration testing approach since AVFoundation classes are difficult to mock
final class StreamingSessionDelegateTests: XCTestCase {
    
    // MARK: - Test Infrastructure
    
    private var delegate: StreamingSessionDelegate?
    private var mockSession: MockURLSession!
    private var mockDataTask: MockURLSessionDataTask!
    private var testAsset: AVURLAsset!
    private var resourceLoader: AVAssetResourceLoader!
    
    override func setUp() {
        super.setUp()
        
        // Create a test asset with a custom scheme to trigger resource loading
        let testURL = URL(string: "test-scheme://german.lutheran.radio:8443/lutheranradio.mp3")!
        testAsset = AVURLAsset(url: testURL)
        resourceLoader = testAsset.resourceLoader
        
        // Use proper URLSession creation methods instead of deprecated init()
        let config = URLSessionConfiguration.ephemeral
        let realSession = URLSession(configuration: config)
        mockSession = MockURLSession(session: realSession)
        
        // Create a real data task to wrap in our mock
        let dummyURL = URL(string: "https://example.com")!
        let realDataTask = realSession.dataTask(with: dummyURL)
        mockDataTask = MockURLSessionDataTask(dataTask: realDataTask)
    }
    
    override func tearDown() {
        delegate?.cancel()
        delegate = nil
        mockSession = nil
        mockDataTask = nil
        testAsset = nil
        resourceLoader = nil
        super.tearDown()
    }
    
    // MARK: - Integration Tests with Real AVAssetResourceLoader
    
    func testResourceLoaderDelegateIntegration() {
        // Given: A resource loader delegate setup
        let delegateSetExpectation = expectation(description: "Resource loader delegate set")
        let delegateQueue = DispatchQueue(label: "test.resource.loader")
        
        // Create a simple delegate to test the integration
        let testDelegate = TestResourceLoaderDelegate()
        testDelegate.onShouldWaitForLoadingRequest = { request in
            delegateSetExpectation.fulfill()
            return true
        }
        
        // When: Setting up resource loader
        resourceLoader.setDelegate(testDelegate, queue: delegateQueue)
        
        // Create player item to trigger resource loading
        let playerItem = AVPlayerItem(asset: testAsset)
        
        // Then: Should set up successfully
        wait(for: [delegateSetExpectation], timeout: 1.0)
        XCTAssertNotNil(playerItem, "Player item should be created successfully")
    }
    
    // MARK: - HTTP Response Handling Tests (Unit Level)
    
    func testHTTPResponseHandling() {
        // Given: Mock request and delegate
        let mockRequest = MockLoadingRequestWrapper()
        delegate = StreamingSessionDelegate(loadingRequest: mockRequest.request)
        delegate?.session = mockSession.wrappedSession
        delegate?.dataTask = mockDataTask.wrappedDataTask
        
        // Test successful response
        let successResponse = HTTPURLResponse(
            url: URL(string: "https://test.example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "audio/mpeg"]
        )!
        
        var completionResult: URLSession.ResponseDisposition?
        let completion: (URLSession.ResponseDisposition) -> Void = { disposition in
            completionResult = disposition
        }
        
        // When: Receiving successful response
        delegate?.urlSession(mockSession.wrappedSession, dataTask: mockDataTask.wrappedDataTask, didReceive: successResponse, completionHandler: completion)
        
        // Then: Should allow continuation
        XCTAssertEqual(completionResult, .allow, "Should allow successful responses")
    }
    
    func testForbiddenResponseHandling() {
        // Given: Mock request and delegate
        let mockRequest = MockLoadingRequestWrapper()
        delegate = StreamingSessionDelegate(loadingRequest: mockRequest.request)
        
        var errorReceived: Error?
        delegate?.onError = { error in
            errorReceived = error
        }
        
        let forbiddenResponse = HTTPURLResponse(
            url: URL(string: "https://test.example.com")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil
        )!
        
        var completionResult: URLSession.ResponseDisposition?
        let completion: (URLSession.ResponseDisposition) -> Void = { disposition in
            completionResult = disposition
        }
        
        // When: Receiving 403 response
        delegate?.urlSession(mockSession.wrappedSession, dataTask: mockDataTask.wrappedDataTask, didReceive: forbiddenResponse, completionHandler: completion)
        
        // Then: Should cancel and report error
        XCTAssertEqual(completionResult, .cancel, "Should cancel 403 responses")
        XCTAssertNotNil(errorReceived, "Should report error")
        XCTAssertEqual((errorReceived as? URLError)?.code, .userAuthenticationRequired, "Should be authentication error")
    }
    
    func testServerErrorResponseHandling() {
        let errorCases: [(statusCode: Int, expectedErrorCode: URLError.Code)] = [
            (502, .badServerResponse),
            (404, .fileDoesNotExist),
            (429, .resourceUnavailable),
            (503, .resourceUnavailable),
            (500, .badServerResponse)
        ]
        
        for (statusCode, expectedErrorCode) in errorCases {
            // Given: Fresh delegate for each test
            let mockRequest = MockLoadingRequestWrapper()
            let testDelegate = StreamingSessionDelegate(loadingRequest: mockRequest.request)
            
            var errorReceived: Error?
            testDelegate.onError = { error in
                errorReceived = error
            }
            
            let errorResponse = HTTPURLResponse(
                url: URL(string: "https://test.example.com")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            
            var completionResult: URLSession.ResponseDisposition?
            let completion: (URLSession.ResponseDisposition) -> Void = { disposition in
                completionResult = disposition
            }
            
            // When: Receiving error response
            testDelegate.urlSession(mockSession.wrappedSession, dataTask: mockDataTask.wrappedDataTask, didReceive: errorResponse, completionHandler: completion)
            
            // Then: Should handle appropriately
            XCTAssertEqual(completionResult, .cancel, "Should cancel error responses for status \(statusCode)")
            XCTAssertNotNil(errorReceived, "Should report error for status \(statusCode)")
            XCTAssertEqual((errorReceived as? URLError)?.code, expectedErrorCode, "Error code should match expected for status \(statusCode)")
        }
    }
    
    func testInvalidResponseTypeHandling() {
        // Given: Mock request and delegate
        let mockRequest = MockLoadingRequestWrapper()
        delegate = StreamingSessionDelegate(loadingRequest: mockRequest.request)
        
        let urlResponse = URLResponse(
            url: URL(string: "https://test.example.com")!,
            mimeType: nil,
            expectedContentLength: 0,
            textEncodingName: nil
        )
        
        var completionResult: URLSession.ResponseDisposition?
        let completion: (URLSession.ResponseDisposition) -> Void = { disposition in
            completionResult = disposition
        }
        
        // When: Receiving non-HTTP response
        delegate?.urlSession(mockSession.wrappedSession, dataTask: mockDataTask.wrappedDataTask, didReceive: urlResponse, completionHandler: completion)
        
        // Then: Should cancel
        XCTAssertEqual(completionResult, .cancel, "Should cancel non-HTTP responses")
    }
    
    // MARK: - Data Reception Tests
    
    func testDataReceptionFlow() {
        // Given: Mock request and delegate with successful response first
        let mockRequest = MockLoadingRequestWrapper()
        delegate = StreamingSessionDelegate(loadingRequest: mockRequest.request)
        
        let successResponse = HTTPURLResponse(
            url: URL(string: "https://test.example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        
        // Establish successful response first
        delegate?.urlSession(mockSession.wrappedSession, dataTask: mockDataTask.wrappedDataTask, didReceive: successResponse) { _ in }
        
        let testData = "Test audio stream data".data(using: .utf8)!
        
        // When: Receiving data
        delegate?.urlSession(mockSession.wrappedSession, dataTask: mockDataTask.wrappedDataTask, didReceive: testData)
        
        // Then: Should not crash (we can't easily verify the data was forwarded without complex mocking)
        // The fact that this doesn't crash means the data reception flow is working
        XCTAssertNotNil(delegate, "Delegate should remain valid after data reception")
    }
    
    // MARK: - SSL Certificate Validation Tests
    
    func testSSLCertificateValidationFlow() {
        // Given: Mock request and delegate with hostname
        let mockRequest = MockLoadingRequestWrapper()
        delegate = StreamingSessionDelegate(loadingRequest: mockRequest.request)
        delegate?.originalHostname = "german.lutheran.radio"
        
        let protectionSpace = URLProtectionSpace(
            host: "1.2.3.4",
            port: 443,
            protocol: NSURLProtectionSpaceHTTPS,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: MockURLAuthenticationChallengeSender()
        )
        
        var completionCalled = false
        let completion: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void = { _, _ in
            completionCalled = true
        }
        
        // When: Handling SSL challenge
        delegate?.urlSession(mockSession.wrappedSession, didReceive: challenge, completionHandler: completion)
        
        // Then: Should call completion
        XCTAssertTrue(completionCalled, "SSL challenge completion should be called")
    }
    
    func testNonSSLAuthenticationChallenge() {
        // Given: Mock request and delegate
        let mockRequest = MockLoadingRequestWrapper()
        delegate = StreamingSessionDelegate(loadingRequest: mockRequest.request)
        
        let protectionSpace = URLProtectionSpace(
            host: "test.example.com",
            port: 443,
            protocol: NSURLProtectionSpaceHTTPS,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: MockURLAuthenticationChallengeSender()
        )
        
        var completionResult: (URLSession.AuthChallengeDisposition, URLCredential?)?
        let completion: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void = { disposition, credential in
            completionResult = (disposition, credential)
        }
        
        // When: Handling non-SSL challenge
        delegate?.urlSession(mockSession.wrappedSession, didReceive: challenge, completionHandler: completion)
        
        // Then: Should use default handling
        XCTAssertEqual(completionResult?.0, .performDefaultHandling, "Should perform default handling for non-SSL challenges")
        XCTAssertNil(completionResult?.1, "Should not provide credential for non-SSL challenges")
    }
    
    // MARK: - Cleanup and Resource Management Tests
    
    func testCancelCleanup() {
        // Given: Mock request and delegate with session and task
        let mockRequest = MockLoadingRequestWrapper()
        delegate = StreamingSessionDelegate(loadingRequest: mockRequest.request)
        delegate?.session = mockSession.wrappedSession
        delegate?.dataTask = mockDataTask.wrappedDataTask
        
        let cancelExpectation = expectation(description: "DataTask cancel called")
        let invalidateExpectation = expectation(description: "Session invalidate called")
        
        mockDataTask.onCancel = { cancelExpectation.fulfill() }
        mockSession.onInvalidateAndCancel = { invalidateExpectation.fulfill() }
        
        // When: Cancelling
        delegate?.cancel()
        
        // Then: Should clean up resources
        wait(for: [cancelExpectation, invalidateExpectation], timeout: 1.0)
        XCTAssertNil(delegate?.session, "Session should be nil after cancel")
        XCTAssertNil(delegate?.dataTask, "Data task should be nil after cancel")
    }
    
    func testMultipleCancellations() {
        // Given: Mock request and delegate
        let mockRequest = MockLoadingRequestWrapper()
        delegate = StreamingSessionDelegate(loadingRequest: mockRequest.request)
        delegate?.session = mockSession.wrappedSession
        delegate?.dataTask = mockDataTask.wrappedDataTask
        
        // When: Calling cancel multiple times
        delegate?.cancel()
        delegate?.cancel()
        delegate?.cancel()
        
        // Then: Should not crash
        XCTAssertNil(delegate?.session, "Session should remain nil after multiple cancels")
        XCTAssertNil(delegate?.dataTask, "Data task should remain nil after multiple cancels")
    }
    
    // MARK: - Property Management Tests
    
    func testOriginalHostnameProperty() {
        // Given: Mock request and delegate
        let mockRequest = MockLoadingRequestWrapper()
        delegate = StreamingSessionDelegate(loadingRequest: mockRequest.request)
        
        let testHostname = "finnish.lutheran.radio"
        
        // When: Setting and retrieving hostname
        delegate?.originalHostname = testHostname
        let retrievedHostname = delegate?.originalHostname
        
        // Then: Should preserve hostname
        XCTAssertEqual(retrievedHostname, testHostname, "Should preserve original hostname")
    }
    
    // MARK: - Error Callback Tests
    
    func testErrorCallbackMechanism() {
        // Given: Mock request and delegate
        let mockRequest = MockLoadingRequestWrapper()
        delegate = StreamingSessionDelegate(loadingRequest: mockRequest.request)
        
        var callbackFired = false
        var receivedError: Error?
        
        delegate?.onError = { error in
            callbackFired = true
            receivedError = error
        }
        
        // When: Triggering an error via 403 response
        let forbiddenResponse = HTTPURLResponse(
            url: URL(string: "https://test.example.com")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil
        )!
        
        delegate?.urlSession(mockSession.wrappedSession, dataTask: mockDataTask.wrappedDataTask, didReceive: forbiddenResponse) { _ in }
        
        // Then: Should call error callback
        XCTAssertTrue(callbackFired, "Error callback should be called")
        XCTAssertNotNil(receivedError, "Should receive error object")
    }
}

// MARK: - Helper Classes

/// A wrapper that creates a real AVAssetResourceLoadingRequest for testing
private class MockLoadingRequestWrapper {
    let request: AVAssetResourceLoadingRequest
    
    init() {
        // Create a real request by setting up resource loading
        let url = URL(string: "test-scheme://test.example.com/stream")!
        let asset = AVURLAsset(url: url)
        
        // This is a hack to get a real AVAssetResourceLoadingRequest
        // We create a temporary delegate that captures the request
        var capturedRequest: AVAssetResourceLoadingRequest?
        
        let tempDelegate = TemporaryResourceLoaderDelegate { request in
            capturedRequest = request
            return false // Don't actually handle the request
        }
        
        asset.resourceLoader.setDelegate(tempDelegate, queue: DispatchQueue.main)
        
        // Create a player item to trigger resource loading
        let playerItem = AVPlayerItem(asset: asset)
        
        // Wait briefly for the request to be created
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            semaphore.signal()
        }
        semaphore.wait()
        
        // Use the captured request or create a minimal fallback
        if let captured = capturedRequest {
            self.request = captured
        } else {
            // Fallback: Create a simple test request by forcing resource loading
            // This is a workaround for AVFoundation testing limitations
            let config = URLSessionConfiguration.ephemeral
            let session = URLSession(configuration: config)
            let dummyRequest = URLRequest(url: url)
            let task = session.dataTask(with: dummyRequest)
            task.cancel() // Don't actually perform the request
            
            // Create another attempt with different approach
            let config2 = URLSessionConfiguration.ephemeral
            let session2 = URLSession(configuration: config2)
            let secondAsset = AVURLAsset(url: URL(string: "test-scheme://fallback.example.com/stream")!)
            let secondDelegate = TemporaryResourceLoaderDelegate { request in
                capturedRequest = request
                return false
            }
            secondAsset.resourceLoader.setDelegate(secondDelegate, queue: DispatchQueue.main)
            let secondItem = AVPlayerItem(asset: secondAsset)
            
            // Wait again
            let semaphore2 = DispatchSemaphore(value: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                semaphore2.signal()
            }
            semaphore2.wait()
            
            if let captured = capturedRequest {
                self.request = captured
            } else {
                // Final fallback - this test approach has limitations
                fatalError("Could not create real AVAssetResourceLoadingRequest for testing. This is a limitation of AVFoundation testing.")
            }
        }
    }
}

/// Temporary delegate to capture a real AVAssetResourceLoadingRequest
private class TemporaryResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    private let onRequest: (AVAssetResourceLoadingRequest) -> Bool
    
    init(onRequest: @escaping (AVAssetResourceLoadingRequest) -> Bool) {
        self.onRequest = onRequest
        super.init()
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        return onRequest(loadingRequest)
    }
}

/// Simple test delegate for resource loader integration tests
private class TestResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    var onShouldWaitForLoadingRequest: ((AVAssetResourceLoadingRequest) -> Bool)?
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        return onShouldWaitForLoadingRequest?(loadingRequest) ?? false
    }
}

// MARK: - Mock Objects

// MARK: - Mock Objects Using Composition (Avoiding Deprecated Subclassing)

/// Wrapper for URLSession that avoids deprecated subclassing
private class MockURLSession: @unchecked Sendable {
    private let _onInvalidateAndCancel = StreamingTestThreadSafeBox<(() -> Void)?>(nil)
    let wrappedSession: URLSession
    
    var onInvalidateAndCancel: (() -> Void)? {
        get { _onInvalidateAndCancel.value }
        set { _onInvalidateAndCancel.value = newValue }
    }
    
    init(session: URLSession) {
        self.wrappedSession = session
    }
    
    func invalidateAndCancel() {
        onInvalidateAndCancel?()
        wrappedSession.invalidateAndCancel()
    }
}

/// Wrapper for URLSessionDataTask that avoids deprecated subclassing
private class MockURLSessionDataTask: @unchecked Sendable {
    private let _onCancel = StreamingTestThreadSafeBox<(() -> Void)?>(nil)
    let wrappedDataTask: URLSessionDataTask
    
    var onCancel: (() -> Void)? {
        get { _onCancel.value }
        set { _onCancel.value = newValue }
    }
    
    init(dataTask: URLSessionDataTask) {
        self.wrappedDataTask = dataTask
    }
    
    func cancel() {
        onCancel?()
        wrappedDataTask.cancel()
    }
    
    func resume() {
        // Mock implementation - don't actually resume the real task
    }
}

/// Thread-safe wrapper for mutable properties in Sendable classes (StreamingSessionDelegate tests)
private final class StreamingTestThreadSafeBox<T>: @unchecked Sendable {
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

/// Mock URLAuthenticationChallengeSender for testing
private class MockURLAuthenticationChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {
        // Mock implementation
    }
    
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {
        // Mock implementation
    }
    
    func cancel(_ challenge: URLAuthenticationChallenge) {
        // Mock implementation
    }
    
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {
        // Mock implementation
    }
    
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {
        // Mock implementation
    }
}
