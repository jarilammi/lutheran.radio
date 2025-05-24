//
//  StreamingSessionDelegateTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 15.3.2025.
//

import XCTest
import AVFoundation
@testable import Lutheran_Radio

// Mock URL protocol to simulate network responses
class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data, Error?))?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            XCTFail("Request handler not set")
            return
        }

        do {
            let (response, data, error) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            if let error = error {
                client?.urlProtocol(self, didFailWithError: error)
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// Mock classes for testing since we can't easily mock AVFoundation classes
class MockContentInformationRequest {
    var contentType: String?
    var contentLength: Int64 = 0
    var isByteRangeAccessSupported = false
    
    init() {}
}

class MockDataRequest {
    private var receivedData = Data()
    
    init() {}
    
    func respond(with data: Data) {
        receivedData.append(data)
    }
    
    var totalReceivedData: Data {
        return receivedData
    }
}

class MockAVAssetResourceLoadingRequest {
    private var _contentInformationRequest: MockContentInformationRequest?
    private var _dataRequest: MockDataRequest?
    private var _request: URLRequest
    private var _isFinished = false
    private var _isCancelled = false
    private var _finishingError: Error?
    
    init(url: URL) {
        self._request = URLRequest(url: url)
        self._contentInformationRequest = MockContentInformationRequest()
        self._dataRequest = MockDataRequest()
    }
    
    var contentInformationRequest: MockContentInformationRequest? {
        return _contentInformationRequest
    }
    
    var dataRequest: MockDataRequest? {
        return _dataRequest
    }
    
    var request: URLRequest {
        return _request
    }
    
    var isFinished: Bool {
        return _isFinished
    }
    
    var isCancelled: Bool {
        return _isCancelled
    }
    
    func finishLoading() {
        _isFinished = true
    }
    
    func finishLoading(with error: Error?) {
        _isFinished = true
        _finishingError = error
    }
    
    var finishingError: Error? {
        return _finishingError
    }
}

// Wrapper to bridge our mock with AVAssetResourceLoadingRequest
class AVAssetResourceLoadingRequestWrapper {
    let mock: MockAVAssetResourceLoadingRequest
    
    init(mock: MockAVAssetResourceLoadingRequest) {
        self.mock = mock
    }
    
    var contentInformationRequest: MockContentInformationRequest? {
        return mock.contentInformationRequest
    }
    
    var dataRequest: MockDataRequest? {
        return mock.dataRequest
    }
    
    var request: URLRequest {
        return mock.request
    }
    
    var isFinished: Bool {
        return mock.isFinished
    }
    
    func finishLoading() {
        mock.finishLoading()
    }
    
    func finishLoading(with error: Error?) {
        mock.finishLoading(with: error)
    }
}

// Custom StreamingSessionDelegate for testing that uses our mock
class TestStreamingSessionDelegate: CustomDNSURLSessionDelegate, URLSessionDataDelegate {
    private var loadingRequest: AVAssetResourceLoadingRequestWrapper
    private var bytesReceived = 0
    private var receivedResponse = false
    var session: URLSession?
    var dataTask: URLSessionDataTask?
    var onError: ((Error) -> Void)?
    var originalHostname: String?
    
    init(loadingRequest: AVAssetResourceLoadingRequestWrapper, hostnameToIP: [String: String]) {
        self.loadingRequest = loadingRequest
        self.originalHostname = loadingRequest.request.url?.host
        super.init(hostnameToIP: hostnameToIP)
    }
    
    func cancel() {
        dataTask?.cancel()
        session?.invalidateAndCancel()
        session = nil
        dataTask = nil
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        
        let statusCode = httpResponse.statusCode
        if statusCode == 403 {
            onError?(URLError(.userAuthenticationRequired))
            loadingRequest.finishLoading(with: URLError(.userAuthenticationRequired))
            completionHandler(.cancel)
            return
        }
        
        if (400...599).contains(statusCode) {
            let error: URLError.Code
            switch statusCode {
            case 502:
                error = .badServerResponse
            case 404:
                error = .fileDoesNotExist
            case 429:
                error = .resourceUnavailable
            case 503:
                error = .resourceUnavailable
            default:
                error = .badServerResponse
            }
            onError?(URLError(error))
            loadingRequest.finishLoading(with: URLError(error))
            completionHandler(.cancel)
            return
        }
        
        if let contentType = httpResponse.allHeaderFields["Content-Type"] as? String {
            loadingRequest.contentInformationRequest?.contentType = contentType
        }
        
        loadingRequest.contentInformationRequest?.contentLength = -1
        loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = false
        
        receivedResponse = true
        completionHandler(.allow)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard receivedResponse else { return }
        bytesReceived += data.count
        loadingRequest.dataRequest?.respond(with: data)
    }
    
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            guard let serverTrust = challenge.protectionSpace.serverTrust else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            
            if let originalHost = self.originalHostname {
                let policy = SecPolicyCreateSSL(true, originalHost as CFString)
                SecTrustSetPolicies(serverTrust, [policy] as CFArray)
                
                var error: CFError?
                if SecTrustEvaluateWithError(serverTrust, &error) {
                    let credential = URLCredential(trust: serverTrust)
                    completionHandler(.useCredential, credential)
                } else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
    
    override func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            // Don't report cancellation as an error
            if let urlError = error as? URLError, urlError.code == .cancelled {
                return
            }
            onError?(error)
            loadingRequest.finishLoading(with: error)
        } else {
            loadingRequest.finishLoading()
        }
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let url = request.url, let host = url.host, let ipAddress = hostnameToIP[host] {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.host = ipAddress
            if let newURL = components?.url {
                var modifiedRequest = request
                modifiedRequest.url = newURL
                modifiedRequest.setValue(host, forHTTPHeaderField: "Host")
                completionHandler(modifiedRequest)
                return
            }
        }
        completionHandler(request)
    }
}

class StreamingSessionDelegateTests: XCTestCase {
    var mockRequest: MockAVAssetResourceLoadingRequest!
    var mockWrapper: AVAssetResourceLoadingRequestWrapper!
    var delegate: TestStreamingSessionDelegate!
    var session: URLSession!
    
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        
        let url = URL(string: "https://test.com/stream.mp3")!
        mockRequest = MockAVAssetResourceLoadingRequest(url: url)
        mockWrapper = AVAssetResourceLoadingRequestWrapper(mock: mockRequest)
        
        let hostnameToIP = ["test.com": "127.0.0.1"]
        delegate = TestStreamingSessionDelegate(loadingRequest: mockWrapper, hostnameToIP: hostnameToIP)
        
        let config = URLSessionConfiguration.default
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        delegate.session = session
    }
    
    override func tearDown() {
        delegate?.cancel()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }
    
    // MARK: - Success Cases
    
    func testSuccessfulResponseSetsContentType() {
        let expectation = self.expectation(description: "Handles successful response")
        
        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://test.com/stream.mp3")!,
                statusCode: 200,
                httpVersion: "1.1",
                headerFields: ["Content-Type": "audio/mpeg"]
            )!
            let data = "dummy data".data(using: .utf8)!
            return (response, data, nil)
        }
        
        let task = session.dataTask(with: URL(string: "https://test.com/stream.mp3")!)
        delegate.dataTask = task
        task.resume()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(self.mockWrapper.contentInformationRequest?.contentType, "audio/mpeg")
            XCTAssertEqual(self.mockWrapper.contentInformationRequest?.contentLength, -1)
            XCTAssertFalse(self.mockWrapper.contentInformationRequest?.isByteRangeAccessSupported ?? true)
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 2.0)
    }
    
    func testReceivesDataAndResponds() {
        let expectation = self.expectation(description: "Receives and processes data")
        let testData = "test streaming data".data(using: .utf8)!
        
        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://test.com/stream.mp3")!,
                statusCode: 200,
                httpVersion: "1.1",
                headerFields: ["Content-Type": "audio/mpeg"]
            )!
            return (response, testData, nil)
        }
        
        let task = session.dataTask(with: URL(string: "https://test.com/stream.mp3")!)
        delegate.dataTask = task
        task.resume()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let mockDataRequest = self.mockWrapper.dataRequest!
            XCTAssertEqual(mockDataRequest.totalReceivedData, testData)
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 2.0)
    }
    
    // MARK: - HTTP Error Cases
    
    func test404ResponseFinishesWithError() {
        let expectation = self.expectation(description: "Handles 404 response")
        var capturedError: Error?
        
        delegate.onError = { error in
            capturedError = error
            expectation.fulfill()
        }
        
        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://test.com/stream.mp3")!,
                statusCode: 404,
                httpVersion: "1.1",
                headerFields: nil
            )!
            return (response, Data(), nil)
        }
        
        let task = session.dataTask(with: URL(string: "https://test.com/stream.mp3")!)
        delegate.dataTask = task
        task.resume()
        
        waitForExpectations(timeout: 2.0)
        
        XCTAssertNotNil(capturedError)
        if let urlError = capturedError as? URLError {
            XCTAssertEqual(urlError.code, .fileDoesNotExist)
        } else {
            XCTFail("Expected URLError.fileDoesNotExist")
        }
        XCTAssertTrue(mockWrapper.isFinished)
        XCTAssertNotNil(mockRequest.finishingError)
    }
    
    func test403ResponseFinishesWithAuthError() {
        let expectation = self.expectation(description: "Handles 403 response")
        var capturedError: Error?
        
        delegate.onError = { error in
            capturedError = error
            expectation.fulfill()
        }
        
        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://test.com/stream.mp3")!,
                statusCode: 403,
                httpVersion: "1.1",
                headerFields: nil
            )!
            return (response, Data(), nil)
        }
        
        let task = session.dataTask(with: URL(string: "https://test.com/stream.mp3")!)
        delegate.dataTask = task
        task.resume()
        
        waitForExpectations(timeout: 2.0)
        
        XCTAssertNotNil(capturedError)
        if let urlError = capturedError as? URLError {
            XCTAssertEqual(urlError.code, .userAuthenticationRequired)
        } else {
            XCTFail("Expected URLError.userAuthenticationRequired")
        }
    }
    
    func test502ResponseFinishesWithBadServerError() {
        let expectation = self.expectation(description: "Handles 502 response")
        var capturedError: Error?
        
        delegate.onError = { error in
            capturedError = error
            expectation.fulfill()
        }
        
        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://test.com/stream.mp3")!,
                statusCode: 502,
                httpVersion: "1.1",
                headerFields: nil
            )!
            return (response, Data(), nil)
        }
        
        let task = session.dataTask(with: URL(string: "https://test.com/stream.mp3")!)
        delegate.dataTask = task
        task.resume()
        
        waitForExpectations(timeout: 2.0)
        
        XCTAssertNotNil(capturedError)
        if let urlError = capturedError as? URLError {
            XCTAssertEqual(urlError.code, .badServerResponse)
        } else {
            XCTFail("Expected URLError.badServerResponse")
        }
    }
    
    func test503ResponseFinishesWithResourceUnavailable() {
        let expectation = self.expectation(description: "Handles 503 response")
        var capturedError: Error?
        
        delegate.onError = { error in
            capturedError = error
            expectation.fulfill()
        }
        
        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://test.com/stream.mp3")!,
                statusCode: 503,
                httpVersion: "1.1",
                headerFields: nil
            )!
            return (response, Data(), nil)
        }
        
        let task = session.dataTask(with: URL(string: "https://test.com/stream.mp3")!)
        delegate.dataTask = task
        task.resume()
        
        waitForExpectations(timeout: 2.0)
        
        XCTAssertNotNil(capturedError)
        if let urlError = capturedError as? URLError {
            XCTAssertEqual(urlError.code, .resourceUnavailable)
        } else {
            XCTFail("Expected URLError.resourceUnavailable")
        }
    }
    
    func test429ResponseFinishesWithResourceUnavailable() {
        let expectation = self.expectation(description: "Handles 429 response")
        var capturedError: Error?
        
        delegate.onError = { error in
            capturedError = error
            expectation.fulfill()
        }
        
        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://test.com/stream.mp3")!,
                statusCode: 429,
                httpVersion: "1.1",
                headerFields: nil
            )!
            return (response, Data(), nil)
        }
        
        let task = session.dataTask(with: URL(string: "https://test.com/stream.mp3")!)
        delegate.dataTask = task
        task.resume()
        
        waitForExpectations(timeout: 2.0)
        
        XCTAssertNotNil(capturedError)
        if let urlError = capturedError as? URLError {
            XCTAssertEqual(urlError.code, .resourceUnavailable)
        } else {
            XCTFail("Expected URLError.resourceUnavailable")
        }
    }
    
    // MARK: - Network Error Cases
    
    func testTaskCompletesWithNetworkError() {
        let expectation = self.expectation(description: "Handles task completion with error")
        var capturedError: Error?
        
        delegate.onError = { error in
            capturedError = error
            expectation.fulfill()
        }
        
        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://test.com/stream.mp3")!,
                statusCode: 200,
                httpVersion: "1.1",
                headerFields: nil
            )!
            let testError = URLError(.networkConnectionLost)
            return (response, Data(), testError)
        }
        
        let task = session.dataTask(with: URL(string: "https://test.com/stream.mp3")!)
        delegate.dataTask = task
        task.resume()
        
        waitForExpectations(timeout: 2.0)
        
        XCTAssertNotNil(capturedError)
        if let urlError = capturedError as? URLError {
            XCTAssertEqual(urlError.code, .networkConnectionLost)
        } else {
            XCTFail("Expected URLError.networkConnectionLost, but got: \(type(of: capturedError))")
        }
    }
    
    // MARK: - Cancellation Tests
    
    func testCancelStopsTaskAndInvalidatesSession() {
        let url = URL(string: "https://test.com/stream.mp3")!
        let task = session.dataTask(with: url)
        delegate.dataTask = task
        
        XCTAssertNotNil(delegate.session)
        XCTAssertNotNil(delegate.dataTask)
        
        delegate.cancel()
        
        XCTAssertNil(delegate.session)
        XCTAssertNil(delegate.dataTask)
    }
    
    func testCancellationDoesNotTriggerErrorCallback() {
        let expectation = self.expectation(description: "Cancellation does not trigger error")
        var errorReceived: Error?
        
        delegate.onError = { error in
            errorReceived = error
        }
        
        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://test.com/stream.mp3")!,
                statusCode: 200,
                httpVersion: "1.1",
                headerFields: nil
            )!
            let cancelError = URLError(.cancelled)
            return (response, Data(), cancelError)
        }
        
        let task = session.dataTask(with: URL(string: "https://test.com/stream.mp3")!)
        delegate.dataTask = task
        task.resume()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertNil(errorReceived, "Should not receive an error for cancellation")
            XCTAssertFalse(self.mockWrapper.isFinished, "Should not finish loading on cancellation")
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 2.0)
    }
    
    // MARK: - DNS Override Tests
    
    func testDNSOverrideIsApplied() {
        // This test verifies that the delegate correctly inherits from CustomDNSURLSessionDelegate
        // and stores the hostnameToIP mapping
        XCTAssertEqual(delegate.hostnameToIP["test.com"], "127.0.0.1")
        XCTAssertEqual(delegate.originalHostname, "test.com")
    }
    
    // MARK: - Content Information Tests
    
    func testContentInformationRequestDefaults() {
        let expectation = self.expectation(description: "Sets content information defaults")
        
        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://test.com/stream.mp3")!,
                statusCode: 200,
                httpVersion: "1.1",
                headerFields: nil
            )!
            return (response, Data(), nil)
        }
        
        let task = session.dataTask(with: URL(string: "https://test.com/stream.mp3")!)
        delegate.dataTask = task
        task.resume()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // Verify default values are set according to implementation
            XCTAssertEqual(self.mockWrapper.contentInformationRequest?.contentLength, -1)
            XCTAssertFalse(self.mockWrapper.contentInformationRequest?.isByteRangeAccessSupported ?? true)
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 2.0)
    }
    
    // MARK: - Data Processing Tests
    
    func testDataNotProcessedBeforeResponse() {
        // This test ensures that data received before a response is ignored
        // This matches the `guard receivedResponse else { return }` in the implementation
        
        let expectation = self.expectation(description: "Data ignored before response")
        let testData = "early data".data(using: .utf8)!
        
        // Simulate receiving data before response by directly calling the delegate method
        delegate.urlSession(session, dataTask: session.dataTask(with: URL(string: "https://test.com/stream.mp3")!), didReceive: testData)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let mockDataRequest = self.mockWrapper.dataRequest!
            XCTAssertTrue(mockDataRequest.totalReceivedData.isEmpty)
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 1.0)
    }
}
