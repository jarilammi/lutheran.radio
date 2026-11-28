//
//  StreamingSessionDelegateTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 15.3.2025.
//

import XCTest
import AVFoundation
import Security
@testable import Core
@testable import Lutheran_Radio

/// Protocol to unify both delegate types for testing.
///
/// Production trust decisions flow through ``CertificateValidator`` (Core), not a
/// stored hostname on the session delegate. This protocol only shares cancel/session
/// surface used by the suite helpers.
protocol SessionDelegateProtocol {
    var session: URLSession? { get set }
    var dataTask: URLSessionDataTask? { get set }
    func cancel()
}

/// Practical test suite for StreamingSessionDelegate
/// Tests the delegate functionality using protocol-based approach
final class StreamingSessionDelegateTests: XCTestCase {
    
    // MARK: - Test Properties
    
    var mockLoadingRequest: MockLoadingRequest!
    var testableDelegate: TestableStreamingSessionDelegate!
    /// Keeps the custom-scheme asset alive until the production challenge returns.
    /// The scheme never resolves on the network.
    private var resourceLoaderAsset: AVURLAsset?
    private var resourceLoaderItem: AVPlayerItem?
    private var resourceLoaderDelegate: SimpleResourceLoaderDelegate?
    
    override func setUp() {
        super.setUp()
        mockLoadingRequest = MockLoadingRequest()
        testableDelegate = TestableStreamingSessionDelegate(mockLoadingRequest: mockLoadingRequest)
    }
    
    override func tearDown() {
        testableDelegate?.cancel()
        testableDelegate = nil
        mockLoadingRequest = nil
        resourceLoaderItem = nil
        resourceLoaderAsset = nil
        resourceLoaderDelegate = nil
        super.tearDown()
    }
    
    // Helper to create real StreamingSessionDelegate for basic tests
    private func createRealDelegate() -> StreamingSessionDelegate? {
        // Try to create a minimal loading request for real delegate tests
        let customURL = URL(string: "lutheranradio://test.lutheran.radio/stream.mp3")!
        let asset = AVURLAsset(url: customURL)
        
        var capturedRequest: AVAssetResourceLoadingRequest?
        let expectation = XCTestExpectation(description: "Capture loading request")
        
        asset.resourceLoader.setDelegate(SimpleResourceLoaderDelegate { request in
            capturedRequest = request
            expectation.fulfill()
            return true
        }, queue: DispatchQueue.main)
        
        // Trigger the resource loader
        Task {
            _ = try? await asset.load(.duration)
        }
        
        let result = XCTWaiter.wait(for: [expectation], timeout: 0.5)
        
        if result == .completed, let request = capturedRequest {
            return StreamingSessionDelegate(loadingRequest: request)
        } else {
            return nil
        }
    }
    
    // MARK: - Basic Functionality Tests
    
    func testCancelCleanup() {
        // Use testable delegate for reliable testing
        let delegate = testableDelegate!
        
        // Given: Create delegate with real session and task
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.0
        let session = URLSession(configuration: config)
        let url = URL(string: "https://httpbin.org/get")!
        let dataTask = session.dataTask(with: url)
        
        // Assign to delegate
        delegate.session = session
        delegate.dataTask = dataTask
        
        // Verify initial state
        XCTAssertNotNil(delegate.session, "Session should exist before cancel")
        XCTAssertNotNil(delegate.dataTask, "Data task should exist before cancel")
        
        // When: Cancelling
        delegate.cancel()
        
        // Then: Should clean up resources
        XCTAssertNil(delegate.session, "Session should be nil after cancel")
        XCTAssertNil(delegate.dataTask, "Data task should be nil after cancel")
    }
    
    func testMultipleCancellations() {
        // Use testable delegate
        let delegate = testableDelegate!
        
        // Given: Setup session and task
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)
        let url = URL(string: "https://httpbin.org/get")!
        let dataTask = session.dataTask(with: url)
        
        delegate.session = session
        delegate.dataTask = dataTask
        
        // When: Calling cancel multiple times
        delegate.cancel()
        delegate.cancel()
        delegate.cancel()
        
        // Then: Should not crash and maintain nil state
        XCTAssertNil(delegate.session, "Session should remain nil after multiple cancels")
        XCTAssertNil(delegate.dataTask, "Data task should remain nil after multiple cancels")
    }
    
    // MARK: - HTTP Response Handling Tests
    
    func testSuccessfulHTTPResponse() {
        // Given: A successful HTTP response
        let response = HTTPURLResponse(
            url: URL(string: "https://test.example.com")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "audio/mpeg"]
        )!
        
        let expectation = XCTestExpectation(description: "Response handling")
        let mockDataTask = URLSession.shared.dataTask(with: URL(string: "https://test.example.com")!)
        
        // When: Processing the response
        testableDelegate.urlSession(
            URLSession.shared,
            dataTask: mockDataTask,
            didReceive: response
        ) { disposition in
            // Then: Should allow the response
            XCTAssertEqual(disposition, .allow, "Should allow successful 200 response")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 1.0)
        
        // Verify content type was set
        XCTAssertEqual(mockLoadingRequest.contentType, "audio/mpeg", "Content type should be set")
        XCTAssertEqual(mockLoadingRequest.contentLength, -1, "Content length should be set to -1 for streaming")
        XCTAssertFalse(mockLoadingRequest.isByteRangeAccessSupported, "Byte range access should be disabled")
    }
    
    func testForbiddenHTTPResponse() {
        // Given: A 403 Forbidden response
        let response = HTTPURLResponse(
            url: URL(string: "https://test.example.com")!,
            statusCode: 403,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        
        var errorReceived: Error?
        testableDelegate.onError = { error in
            errorReceived = error
        }
        
        let expectation = XCTestExpectation(description: "403 response handling")
        let mockDataTask = URLSession.shared.dataTask(with: URL(string: "https://test.example.com")!)
        
        // When: Processing the 403 response
        testableDelegate.urlSession(
            URLSession.shared,
            dataTask: mockDataTask,
            didReceive: response
        ) { disposition in
            // Then: Should cancel the request
            XCTAssertEqual(disposition, .cancel, "Should cancel on 403 response")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 1.0)
        
        // Verify error callback was triggered
        XCTAssertNotNil(errorReceived, "Error callback should be triggered")
        if let urlError = errorReceived as? URLError {
            XCTAssertEqual(urlError.code, .userAuthenticationRequired, "Should return authentication required error for 403")
        }
        XCTAssertTrue(mockLoadingRequest.isFinishedLoading, "Loading request should be finished with error")
    }
    
    func testVariousHTTPErrorCodes() {
        let testCases: [(statusCode: Int, expectedError: URLError.Code)] = [
            (404, .fileDoesNotExist),
            (429, .resourceUnavailable),
            (502, .badServerResponse),
            (503, .resourceUnavailable),
            (500, .badServerResponse),
            (400, .badServerResponse)
        ]
        
        for testCase in testCases {
            // Reset for each test case
            let freshMockRequest = MockLoadingRequest()
            let freshDelegate = TestableStreamingSessionDelegate(mockLoadingRequest: freshMockRequest)
            
            var errorReceived: Error?
            freshDelegate.onError = { error in
                errorReceived = error
            }
            
            let response = HTTPURLResponse(
                url: URL(string: "https://test.example.com")!,
                statusCode: testCase.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            
            let expectation = XCTestExpectation(description: "Error response \(testCase.statusCode)")
            let mockDataTask = URLSession.shared.dataTask(with: URL(string: "https://test.example.com")!)
            
            freshDelegate.urlSession(
                URLSession.shared,
                dataTask: mockDataTask,
                didReceive: response
            ) { disposition in
                XCTAssertEqual(disposition, .cancel, "Should cancel on \(testCase.statusCode) response")
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 1.0)
            
            if let urlError = errorReceived as? URLError {
                XCTAssertEqual(urlError.code, testCase.expectedError,
                             "Status code \(testCase.statusCode) should map to \(testCase.expectedError)")
            } else {
                XCTFail("Expected URLError for status code \(testCase.statusCode)")
            }
            
            XCTAssertTrue(freshMockRequest.isFinishedLoading, "Loading request should be finished for error \(testCase.statusCode)")
        }
    }
    
    func testNonHTTPResponse() {
        // Given: A non-HTTP response
        let response = URLResponse(url: URL(string: "https://test.example.com")!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        
        let expectation = XCTestExpectation(description: "Non-HTTP response handling")
        let mockDataTask = URLSession.shared.dataTask(with: URL(string: "https://test.example.com")!)
        
        // When: Processing the non-HTTP response
        testableDelegate.urlSession(
            URLSession.shared,
            dataTask: mockDataTask,
            didReceive: response
        ) { disposition in
            // Then: Should cancel the request
            XCTAssertEqual(disposition, .cancel, "Should cancel on non-HTTP response")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    // MARK: - Data Handling Tests
    
    func testDataReceivingAfterSuccessfulResponse() {
        // Given: Create a data task that we'll reuse
        let testURL = URL(string: "https://test.example.com")!
        let mockDataTask = URLSession.shared.dataTask(with: testURL)
        
        // Reset the flag to ensure clean state
        testableDelegate.hasReceivedSuccessfulResponse = false
        
        // First establish a successful response
        let response = HTTPURLResponse(
            url: testURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "audio/mpeg"]
        )!
        
        let responseExpectation = XCTestExpectation(description: "Response received")
        
        testableDelegate.urlSession(
            URLSession.shared,
            dataTask: mockDataTask,
            didReceive: response
        ) { disposition in
            XCTAssertEqual(disposition, .allow, "Should allow response")
            responseExpectation.fulfill()
        }
        
        wait(for: [responseExpectation], timeout: 1.0)
        
        // Verify the flag was set
        XCTAssertTrue(testableDelegate.hasReceivedSuccessfulResponse, "Should have marked successful response")
        
        // When: Receiving data with the SAME data task
        let testData = "Test audio data".data(using: .utf8)!
        
        // Call the data delegate method directly
        testableDelegate.urlSession(
            URLSession.shared,
            dataTask: mockDataTask,  // Use same task
            didReceive: testData
        )
        
        // Then: Data should be forwarded to the loading request
        XCTAssertEqual(mockLoadingRequest.receivedData.count, 1, "Should have received one data chunk")
        XCTAssertEqual(mockLoadingRequest.receivedData.first, testData, "Should have received the correct data")
    }
    
    func testDataReceivingWithoutPriorResponse() {
        // Given: No prior response
        let testData = "Test audio data".data(using: .utf8)!
        let mockDataTask = URLSession.shared.dataTask(with: URL(string: "https://test.example.com")!)
        
        // When: Receiving data without a response
        XCTAssertNoThrow {
            self.testableDelegate.urlSession(
                URLSession.shared,
                dataTask: mockDataTask,
                didReceive: testData
            )
        }
        
        // Then: Data should be ignored (no prior response)
        XCTAssertEqual(mockLoadingRequest.receivedData.count, 0, "Should not receive data without prior response")
    }
    
    func testMultipleDataChunks() {
        // Given: Successful response first
        let response = HTTPURLResponse(
            url: URL(string: "https://test.example.com")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        
        let responseExpectation = XCTestExpectation(description: "Response received")
        let mockDataTask = URLSession.shared.dataTask(with: URL(string: "https://test.example.com")!)
        
        testableDelegate.urlSession(URLSession.shared, dataTask: mockDataTask, didReceive: response) { _ in
            responseExpectation.fulfill()
        }
        wait(for: [responseExpectation], timeout: 1.0)
        
        // When: Receiving multiple data chunks
        let chunk1 = "Chunk 1".data(using: .utf8)!
        let chunk2 = "Chunk 2".data(using: .utf8)!
        let chunk3 = "Chunk 3".data(using: .utf8)!
        
        testableDelegate.urlSession(URLSession.shared, dataTask: mockDataTask, didReceive: chunk1)
        testableDelegate.urlSession(URLSession.shared, dataTask: mockDataTask, didReceive: chunk2)
        testableDelegate.urlSession(URLSession.shared, dataTask: mockDataTask, didReceive: chunk3)
        
        // Then: All chunks should be received
        XCTAssertEqual(mockLoadingRequest.receivedData.count, 3, "Should have received three data chunks")
        XCTAssertEqual(mockLoadingRequest.receivedData[0], chunk1, "First chunk should match")
        XCTAssertEqual(mockLoadingRequest.receivedData[1], chunk2, "Second chunk should match")
        XCTAssertEqual(mockLoadingRequest.receivedData[2], chunk3, "Third chunk should match")
    }
    
    // MARK: - SSL Certificate Validation Tests
    
    /// Challenge disposition for the testable mock only.
    ///
    /// ``TestableStreamingSessionDelegate`` returns ``URLSession/AuthChallengeDisposition/performDefaultHandling``
    /// and never calls ``CertificateValidator``. Pin acceptance for the
    /// production Icecast delegate is ``testPinnedSiikkariLeafOnSiikkariHostIsAccepted``
    /// and the rejection tests below. Those tests do not open a stream.
    func testServerTrustAuthentication() {
        // Given: Server trust authentication challenge
        let protectionSpace = URLProtectionSpace(
            host: "192.168.1.1",
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
        
        let expectation = XCTestExpectation(description: "SSL validation")
        
        // When: Handling the challenge
        testableDelegate.urlSession(URLSession.shared, didReceive: challenge) { disposition, credential in
            // Then: Should either use credentials or perform default handling
            XCTAssertTrue(
                disposition == .useCredential || disposition == .performDefaultHandling || disposition == .cancelAuthenticationChallenge,
                "Should handle server trust appropriately, got: \(disposition)"
            )
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    func testNonServerTrustAuthentication() {
        // Given: Non-server trust authentication challenge
        let protectionSpace = URLProtectionSpace(
            host: "test.lutheran.radio",
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
        
        let expectation = XCTestExpectation(description: "Non-server trust auth")
        
        // When: Handling the challenge
        testableDelegate.urlSession(URLSession.shared, didReceive: challenge) { disposition, credential in
            // Then: Should perform default handling
            XCTAssertEqual(disposition, .performDefaultHandling, "Should perform default handling for non-server trust")
            XCTAssertNil(credential, "Should not provide credential for non-server trust")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    // MARK: - Error Callback Tests
    
    func testErrorCallbackTriggered() {
        // Given: Error callback set up
        var callbackError: Error?
        testableDelegate.onError = { error in
            callbackError = error
        }
        
        // When: Processing a 403 response (which triggers error)
        let response = HTTPURLResponse(
            url: URL(string: "https://test.example.com")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil
        )!
        
        let expectation = XCTestExpectation(description: "Error callback")
        let mockDataTask = URLSession.shared.dataTask(with: URL(string: "https://test.example.com")!)
        
        testableDelegate.urlSession(URLSession.shared, dataTask: mockDataTask, didReceive: response) { _ in
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 1.0)
        
        // Then: Error callback should be triggered
        XCTAssertNotNil(callbackError, "Error callback should be triggered")
    }
    
    func testErrorCallbackNotSetDoesNotCrash() {
        // Given: No error callback set
        testableDelegate.onError = nil
        
        // When: Processing an error response
        let response = HTTPURLResponse(
            url: URL(string: "https://test.example.com")!,
            statusCode: 500,
            httpVersion: nil,
            headerFields: nil
        )!
        
        let expectation = XCTestExpectation(description: "No crash without error callback")
        let mockDataTask = URLSession.shared.dataTask(with: URL(string: "https://test.example.com")!)
        
        // Then: Should not crash - call the method directly
        testableDelegate.urlSession(URLSession.shared, dataTask: mockDataTask, didReceive: response) { disposition in
            // Should still cancel even without error callback
            XCTAssertEqual(disposition, .cancel, "Should cancel on error even without callback")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    // MARK: - Memory Management Tests
    
    func testDelegateCleanupOnCancel() {
        // Given: Delegate with sessions
        autoreleasepool {
            let config = URLSessionConfiguration.ephemeral
            let session = URLSession(configuration: config)
            let dataTask = session.dataTask(with: URL(string: "https://example.com")!)
            
            testableDelegate.session = session
            testableDelegate.dataTask = dataTask
            
            // When: Cancelling
            testableDelegate.cancel()
        }
        
        // Then: Session and task should be properly released
        XCTAssertNil(testableDelegate.session, "Delegate should clear session reference")
        XCTAssertNil(testableDelegate.dataTask, "Delegate should clear data task reference")
    }

    // MARK: - Production Icecast trust challenge

    /// Invariant 3: the pinned `*.siikkari.net` leaf is still accepted for a
    /// `siikkari.net` host when the resource loader asks ``validateStreamingServerTrust(_:host:)``.
    ///
    /// The fixture is the public leaf already used by ``CertificateValidatorTests``.
    /// The task is not resumed, and the loading URL is a custom scheme, so this
    /// does not open a live stream.
    func testPinnedSiikkariLeafOnSiikkariHostIsAccepted() async throws {
        let (delegate, request) = try await makeProductionDelegate()
        var reported: Error?
        delegate.onError = { reported = $0 }
        let trust = CertificateValidatorTests().createMockSecTrust()
        let outcome = await decide(
            delegate,
            trust: trust,
            host: "livestream.siikkari.net"
        )

        XCTAssertEqual(outcome.disposition, .useCredential)
        XCTAssertNotNil(outcome.credential)
        XCTAssertNil(reported)
        XCTAssertFalse(request.isFinished)
    }

    /// Invariant 3 and 4: an unpinned leaf, and the pinned leaf on a host outside
    /// `siikkari.net`, are rejected while the transition window is open and the
    /// leniency latch is still on.
    ///
    /// ``validateServerTrust(_:)`` would accept the unpinned fixture in that window.
    /// The resource loader must not. A rejected challenge reports
    /// ``URLError.Code.serverCertificateUntrusted`` and finishes the loading request.
    /// The latch stays on because the SPKI check fails before leniency runs.
    func testUnpinnedOrNonSiikkariLeafIsRejectedInsideTransitionWindow() async throws {
        let insideWindow = Date(timeIntervalSince1970: 1_798_761_600 + 3_600)
        let probe = CertificateValidator(currentDate: { insideWindow })
        let leniencyWouldAccept = await probe.validateServerTrust(
            CertificateValidatorTests().createUnpinnedSecTrust()
        )
        XCTAssertTrue(
            leniencyWouldAccept,
            "The unpinned fixture must be one that leaf-only leniency would accept"
        )

        try await withSharedValidatorDate(insideWindow) {
            let latchOn = await CertificateValidator.shared.allowTransitionLeniency
            XCTAssertTrue(latchOn)

            let (unpinnedDelegate, unpinnedRequest) = try await self.makeProductionDelegate()
            let unpinnedError = self.expectation(description: "unpinned leaf reports untrusted")
            unpinnedDelegate.onError = { error in
                let urlError = error as? URLError
                XCTAssertEqual(urlError?.code, .serverCertificateUntrusted)
                unpinnedError.fulfill()
            }
            let unpinned = await self.decide(
                unpinnedDelegate,
                trust: CertificateValidatorTests().createUnpinnedSecTrust(),
                host: "livestream.siikkari.net"
            )
            await self.fulfillment(of: [unpinnedError], timeout: 1)
            XCTAssertEqual(unpinned.disposition, .cancelAuthenticationChallenge)
            XCTAssertNil(unpinned.credential)
            XCTAssertTrue(unpinnedRequest.isFinished)

            let (foreignDelegate, foreignRequest) = try await self.makeProductionDelegate()
            let foreignError = self.expectation(description: "non-siikkari host reports untrusted")
            foreignDelegate.onError = { error in
                let urlError = error as? URLError
                XCTAssertEqual(urlError?.code, .serverCertificateUntrusted)
                foreignError.fulfill()
            }
            let foreign = await self.decide(
                foreignDelegate,
                trust: CertificateValidatorTests().createMockSecTrust(),
                host: "example.com"
            )
            await self.fulfillment(of: [foreignError], timeout: 1)
            XCTAssertEqual(foreign.disposition, .cancelAuthenticationChallenge)
            XCTAssertNil(foreign.credential)
            XCTAssertTrue(foreignRequest.isFinished)

            let stillOn = await CertificateValidator.shared.allowTransitionLeniency
            XCTAssertTrue(stillOn, "An SPKI rejection must not turn the leniency latch off")
        }
    }

    /// An empty peer name cancels before the leaf check.
    ///
    /// The fixture is the pinned leaf, which a named `siikkari.net` host would
    /// accept. The challenge handler does not report ``onError`` for a missing
    /// host; the task failure finishes the loading request later.
    func testEmptyHostCancelsIcecastChallenge() async throws {
        let (delegate, request) = try await makeProductionDelegate()
        var reported: Error?
        delegate.onError = { reported = $0 }
        let outcome = await decide(
            delegate,
            trust: CertificateValidatorTests().createMockSecTrust(),
            host: ""
        )

        XCTAssertEqual(outcome.disposition, .cancelAuthenticationChallenge)
        XCTAssertNil(outcome.credential)
        XCTAssertNil(reported)
        XCTAssertFalse(request.isFinished)
    }

    /// Runs `body` while ``CertificateValidator/shared`` reads `date` as the device clock.
    ///
    /// Restores `Date()` afterwards, including when `body` throws. The production
    /// Icecast handler uses that shared validator, so the transition window has
    /// to be injected there.
    private func withSharedValidatorDate(
        _ date: Date,
        _ body: () async throws -> Void
    ) async throws {
        await CertificateValidator.shared._test_setCurrentDate { date }
        do {
            try await body()
        } catch {
            await CertificateValidator.shared._test_setCurrentDate { Date() }
            throw error
        }
        await CertificateValidator.shared._test_setCurrentDate { Date() }
    }

    /// Asks the production delegate to decide one server-trust challenge.
    ///
    /// The data task is never resumed.
    private func decide(
        _ delegate: StreamingSessionDelegate,
        trust: SecTrust,
        host: String
    ) async -> (disposition: URLSession.AuthChallengeDisposition, credential: URLCredential?) {
        let space = FixtureServerTrustProtectionSpace(host: host, serverTrust: trust)
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: MockURLAuthenticationChallengeSender()
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://unit.test.invalid/")!)
        return await delegate.urlSession(session, task: task, didReceive: challenge)
    }

    /// Captures one ``AVAssetResourceLoadingRequest`` from a custom-scheme asset.
    ///
    /// AVFoundation delivers the request to the resource loader instead of
    /// opening a network stream. The asset stays retained on this test case
    /// so the request remains valid for ``finishLoading(with:)``.
    private func makeProductionDelegate() async throws -> (StreamingSessionDelegate, AVAssetResourceLoadingRequest) {
        let box = LoadingRequestBox()
        let offered = expectation(description: "custom-scheme loading request")
        let asset = AVURLAsset(url: try XCTUnwrap(URL(string: "lutheranradio://unit.test/icecast")))
        let loader = SimpleResourceLoaderDelegate { request in
            box.request = request
            offered.fulfill()
            return true
        }
        resourceLoaderDelegate = loader
        resourceLoaderAsset = asset
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "radio.lutheran.test.resource-loader"))
        resourceLoaderItem = AVPlayerItem(asset: asset)
        Task {
            _ = try? await asset.load(.duration)
        }
        await fulfillment(of: [offered], timeout: 3)
        let request = try XCTUnwrap(box.request, "The custom scheme did not offer a loading request")
        return (StreamingSessionDelegate(loadingRequest: request), request)
    }

    /// Protects: production HTTP 500 still calls onError as a plain transient response.
    /// HTTP 503 cancels without onError, without a security lock, and records crowded.
    ///
    /// The custom-scheme URL is not a production region, so the 503 finishes the
    /// attempt instead of opening another host.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/noteStationCapacityHTTPResponse(url:statusCode:)``,
    ///   ``DirectStreamingPlayer/stationCapacityURLError(statusCode:)``
    func testProductionHTTP500CallsOnErrorAnd503DoesNot() async throws {
        let player = DirectStreamingPlayer.shared
        player.test_resetStationCapacityAttempt()
        player.test_resetEmbeddedSecurityModelClusterRejections()
        defer {
            player.test_resetStationCapacityAttempt()
            player.test_resetEmbeddedSecurityModelClusterRejections()
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: try XCTUnwrap(URL(string: "https://unit.test.invalid/")))

        let (delegate500, _) = try await makeProductionDelegate()
        var received500: URLError?
        delegate500.onError = { error in
            received500 = error as? URLError
        }
        let done500 = expectation(description: "HTTP 500 cancelled")
        delegate500.urlSession(
            session,
            dataTask: task,
            didReceive: httpStatus(500),
            completionHandler: { disposition in
                XCTAssertEqual(disposition, .cancel)
                done500.fulfill()
            }
        )
        await fulfillment(of: [done500], timeout: 1)
        XCTAssertEqual(received500?.code, .badServerResponse)
        XCTAssertNil(received500?.userInfo[DirectStreamingPlayer.stationCapacityResourceUserInfoKey])
        XCTAssertNil(player.test_lastStationCapacityReasonKey)
        XCTAssertTrue(player.embeddedSecurityModelRejectedSubdomains().isEmpty)

        let (delegate503, _) = try await makeProductionDelegate()
        var called503 = false
        delegate503.onError = { _ in
            called503 = true
        }
        let done503 = expectation(description: "HTTP 503 cancelled")
        delegate503.urlSession(
            session,
            dataTask: task,
            didReceive: httpStatus(503),
            completionHandler: { disposition in
                XCTAssertEqual(disposition, .cancel)
                done503.fulfill()
            }
        )
        await fulfillment(of: [done503], timeout: 1)
        XCTAssertFalse(called503)
        let deadline = Date().addingTimeInterval(2)
        while player.test_lastStationCapacityReasonKey == nil, Date() < deadline {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(player.test_lastStationCapacityReasonKey, "status_crowded")
        XCTAssertTrue(player.embeddedSecurityModelRejectedSubdomains().isEmpty)
    }

    private func httpStatus(_ statusCode: Int) -> HTTPURLResponse {
        let url = URL(string: "lutheranradio://unit.test/icecast")!
        return HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }
}

// MARK: - Mock Classes and Protocol Extensions

extension StreamingSessionDelegate: SessionDelegateProtocol {}

/// Protocol for loading request to allow mocking
protocol LoadingRequestProtocol: AnyObject {
    var contentType: String? { get set }
    var contentLength: Int64 { get set }
    var isByteRangeAccessSupported: Bool { get set }
    var receivedData: [Data] { get } // Added missing property
    func respondWithData(_ data: Data)
    func finishLoading()
    func finishLoading(with error: Error?)
}

/// Mock implementation of loading request
class MockLoadingRequest: LoadingRequestProtocol {
    var contentType: String?
    var contentLength: Int64 = 0
    var isByteRangeAccessSupported: Bool = false
    var receivedData: [Data] = []
    var isFinishedLoading: Bool = false
    var finishingError: Error?
    
    func respondWithData(_ data: Data) {
        receivedData.append(data)
    }
    
    func finishLoading() {
        isFinishedLoading = true
    }
    
    func finishLoading(with error: Error?) {
        isFinishedLoading = true
        finishingError = error
    }
}

/// Debug version with extensive logging.
///
/// Challenge handling deliberately does **not** reimplement Core leaf-digest
/// pinning. Production ``StreamingSessionDelegate`` routes server trust through
/// ``CertificateValidator/validateStreamingServerTrust(_:host:)``. The Icecast
/// cases are ``testPinnedSiikkariLeafOnSiikkariHostIsAccepted``,
/// ``testUnpinnedOrNonSiikkariLeafIsRejectedInsideTransitionWindow``, and
/// ``testEmptyHostCancelsIcecastChallenge``. This mock only exercises
/// disposition plumbing.
///
/// - Important: Test-only delegate; `session` and `dataTask` are mutated only on the
///   XCTest main thread during delegate callback simulation.
// SAFETY: Test-only type; mutable `session`/`dataTask` are confined to the XCTest main thread.
// `@unchecked Sendable` silences delegate-protocol isolation without crossing actor boundaries in production.
final class TestableStreamingSessionDelegate: NSObject, URLSessionDataDelegate, SessionDelegateProtocol, @unchecked Sendable {
    var session: URLSession?
    var dataTask: URLSessionDataTask?
    var onError: ((Error) -> Void)?
    
    private var mockLoadingRequest: LoadingRequestProtocol
    var hasReceivedSuccessfulResponse = false  // Make this public for testing
    
    init(mockLoadingRequest: LoadingRequestProtocol) {
        self.mockLoadingRequest = mockLoadingRequest
        super.init()
    }
    
    func cancel() {
        dataTask?.cancel()
        session?.invalidateAndCancel()
        session = nil
        dataTask = nil
        hasReceivedSuccessfulResponse = false  // Reset the flag on cancel
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        print("🔍 [TestDelegate] urlSession:didReceive:response called")
        print("🔍 [TestDelegate] Response type: \(type(of: response))")
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("🔍 [TestDelegate] Not an HTTP response, cancelling")
            completionHandler(.cancel)
            return
        }
        
        let statusCode = httpResponse.statusCode
        print("🔍 [TestDelegate] HTTP status code: \(statusCode)")
        
        if statusCode == 403 {
            print("🔍 [TestDelegate] 403 error, calling onError and finishing loading")
            onError?(URLError(.userAuthenticationRequired))
            mockLoadingRequest.finishLoading(with: URLError(.userAuthenticationRequired))
            completionHandler(.cancel)
            return
        }
        
        if (400...599).contains(statusCode) {
            print("🔍 [TestDelegate] Error status code \(statusCode)")
            // Same status map as production. This double still calls onError so the
            // existing code assertions stay on the callback. Production does not call
            // onError for these statuses.
            if let capacityError = DirectStreamingPlayer.stationCapacityURLError(statusCode: statusCode) {
                onError?(capacityError)
                mockLoadingRequest.finishLoading(with: capacityError)
                completionHandler(.cancel)
                return
            }
            let error: URLError.Code = statusCode == 404 ? .fileDoesNotExist : .badServerResponse
            onError?(URLError(error))
            mockLoadingRequest.finishLoading(with: URLError(error))
            completionHandler(.cancel)
            return
        }
        
        if let contentType = httpResponse.allHeaderFields["Content-Type"] as? String {
            print("🔍 [TestDelegate] Setting content type: \(contentType)")
            mockLoadingRequest.contentType = contentType
        }
        
        mockLoadingRequest.contentLength = -1
        mockLoadingRequest.isByteRangeAccessSupported = false
        
        // Mark that we've received a successful response
        hasReceivedSuccessfulResponse = true
        print("🔍 [TestDelegate] Set hasReceivedSuccessfulResponse = true")
        
        completionHandler(.allow)
        print("🔍 [TestDelegate] Called completion handler with .allow")
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        print("🔍 [TestDelegate] urlSession:didReceive:data called")
        print("🔍 [TestDelegate] Data size: \(data.count) bytes")
        print("🔍 [TestDelegate] hasReceivedSuccessfulResponse: \(hasReceivedSuccessfulResponse)")
        
        // Only process data if we've received a successful response
        guard hasReceivedSuccessfulResponse else {
            print("🔍 [TestDelegate] No successful response received, ignoring data")
            return
        }
        
        print("🔍 [TestDelegate] Calling mockLoadingRequest.respondWithData")
        mockLoadingRequest.respondWithData(data)
        print("🔍 [TestDelegate] Mock now has \(mockLoadingRequest.receivedData.count) data chunks")
    }
    
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Disposition plumbing only — not a substitute for Core pin evaluation.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            guard challenge.protectionSpace.serverTrust != nil else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// Holds the loading request captured on the resource-loader queue.
///
/// The test reads `request` only after the expectation is fulfilled.
private final class LoadingRequestBox: @unchecked Sendable {
    var request: AVAssetResourceLoadingRequest?
}

/// Protection space that keeps a fixture `SecTrust` after the challenge copies it.
///
/// The public ``URLProtectionSpace`` initializer cannot attach a trust. The
/// challenge's protection space is a copy, so ``copy(with:)`` returns this
/// subclass. Otherwise the copy drops the trust and the production handler
/// takes the missing-trust path.
///
/// Test-only. The trust is the fixture passed into one challenge decision.
// SAFETY: Test-only. `SecTrust` is confined to the challenge decision on the XCTest task.
final class FixtureServerTrustProtectionSpace: URLProtectionSpace, @unchecked Sendable {
    private let stubHost: String
    private let stubTrust: SecTrust

    init(host: String, serverTrust: SecTrust) {
        stubHost = host
        stubTrust = serverTrust
        super.init(
            host: host,
            port: 443,
            protocol: NSURLProtectionSpaceHTTPS,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
    }

    required init?(coder: NSCoder) {
        fatalError("Fixture protection spaces are not archived")
    }

    override var host: String { stubHost }

    override var serverTrust: SecTrust? { stubTrust }

    override var authenticationMethod: String { NSURLAuthenticationMethodServerTrust }

    override func copy(with zone: NSZone? = nil) -> Any {
        self
    }
}

/// Simple resource loader delegate for creating real loading requests in tests
private class SimpleResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    private let handler: (AVAssetResourceLoadingRequest) -> Bool
    
    init(handler: @escaping (AVAssetResourceLoadingRequest) -> Bool) {
        self.handler = handler
        super.init()
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        return handler(loadingRequest)
    }
}

/// Mock authentication challenge sender
final class MockURLAuthenticationChallengeSender: NSObject, URLAuthenticationChallengeSender {
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
