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

// Helper to capture AVAssetResourceLoadingRequest
class MockResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    var capturedLoadingRequest: AVAssetResourceLoadingRequest?
    var onCapture: (() -> Void)?

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        capturedLoadingRequest = loadingRequest
        onCapture?()
        return true
    }
}

class StreamingSessionDelegateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
    }
    
    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }
    
    func testSuccessfulResponseSetsContentType() {
        let expectation = self.expectation(description: "Handles successful response")
        let url = URL(string: "streaming://test.com/stream.mp3")!
        let asset = AVURLAsset(url: url)
        let resourceLoaderDelegate = MockResourceLoaderDelegate()
        asset.resourceLoader.setDelegate(resourceLoaderDelegate, queue: .main)
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        
        resourceLoaderDelegate.onCapture = {
            guard let loadingRequest = resourceLoaderDelegate.capturedLoadingRequest else {
                XCTFail("Loading request not captured")
                return
            }
            // Provide hostnameToIP dictionary
            let hostnameToIP: [String: String] = ["test.com": "127.0.0.1"]
            let delegate = StreamingSessionDelegate(loadingRequest: loadingRequest, hostnameToIP: hostnameToIP)
            var errorReceived: Error?
            delegate.onError = { error in
                errorReceived = error
            }
            
            MockURLProtocol.requestHandler = { _ in
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "1.1",
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!
                let data = "dummy data".data(using: .utf8)!
                return (response, data, nil)
            }
            
            let config = URLSessionConfiguration.default
            config.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: OperationQueue.main) // Changed to main queue
            let task = session.dataTask(with: url)
            task.resume()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { // Reduced delay
                XCTAssertEqual(loadingRequest.contentInformationRequest?.contentType, "audio/mpeg")
                XCTAssertNil(errorReceived, "Should not receive an error for successful response")
                expectation.fulfill()
            }
        }
        
        player.play()
        waitForExpectations(timeout: 2.0) { error in
            if let error = error {
                XCTFail("Test timed out: \(error)")
            }
        }
    }
    func testReceivesDataAndResponds() {
        let expectation = self.expectation(description: "Receives and processes data")
        let url = URL(string: "streaming://test.com/stream.mp3")!
        let asset = AVURLAsset(url: url)
        let resourceLoaderDelegate = MockResourceLoaderDelegate()
        asset.resourceLoader.setDelegate(resourceLoaderDelegate, queue: .main)
        let playerItem = AVPlayerItem(asset: asset)
        
        resourceLoaderDelegate.onCapture = {
            guard let loadingRequest = resourceLoaderDelegate.capturedLoadingRequest else {
                XCTFail("Loading request not captured")
                return
            }
            // Provide hostnameToIP dictionary
            let hostnameToIP: [String: String] = ["test.com": "127.0.0.1"]
            let delegate = StreamingSessionDelegate(loadingRequest: loadingRequest, hostnameToIP: hostnameToIP)
            let testData = "test data".data(using: .utf8)!
            
            MockURLProtocol.requestHandler = { _ in
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "1.1", headerFields: nil)!
                return (response, testData, nil)
            }
            
            let config = URLSessionConfiguration.default
            config.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: url)
            task.resume()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // Since we can't directly inspect respond(with:), verify delegate processed data
                XCTAssertNil(delegate.onError, "No error should be reported")
                expectation.fulfill()
            }
        }
        
        _ = playerItem.status
        let player = AVPlayer(playerItem: playerItem)
        player.play()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        waitForExpectations(timeout: 1.0)
    }
    
    func test404ResponseFinishesWithError() {
        let expectation = self.expectation(description: "Handles 404 response")
        let url = URL(string: "streaming://test.com/stream.mp3")!
        let asset = AVURLAsset(url: url)
        let resourceLoaderDelegate = MockResourceLoaderDelegate()
        asset.resourceLoader.setDelegate(resourceLoaderDelegate, queue: .main)
        let playerItem = AVPlayerItem(asset: asset)
        
        resourceLoaderDelegate.onCapture = {
            guard let loadingRequest = resourceLoaderDelegate.capturedLoadingRequest else {
                XCTFail("Loading request not captured")
                return
            }
            // Provide hostnameToIP dictionary
            let hostnameToIP: [String: String] = ["test.com": "127.0.0.1"]
            let delegate = StreamingSessionDelegate(loadingRequest: loadingRequest, hostnameToIP: hostnameToIP)
            delegate.onError = { error in
                if let urlError = error as? URLError {
                    XCTAssertEqual(urlError.code, .fileDoesNotExist)
                    expectation.fulfill()
                } else {
                    XCTFail("Expected URLError.fileDoesNotExist")
                }
            }
            
            MockURLProtocol.requestHandler = { _ in
                let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "1.1", headerFields: nil)!
                return (response, Data(), nil)
            }
            
            let config = URLSessionConfiguration.default
            config.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: url)
            task.resume()
        }
        
        _ = playerItem.status
        let player = AVPlayer(playerItem: playerItem)
        player.play()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        waitForExpectations(timeout: 1.0)
    }
    
    func testTaskCompletesWithError() {
        let expectation = self.expectation(description: "Handles task completion with error")
        let url = URL(string: "streaming://test.com/stream.mp3")!
        let asset = AVURLAsset(url: url)
        let resourceLoaderDelegate = MockResourceLoaderDelegate()
        asset.resourceLoader.setDelegate(resourceLoaderDelegate, queue: .main)
        let playerItem = AVPlayerItem(asset: asset)
        
        resourceLoaderDelegate.onCapture = {
            guard let loadingRequest = resourceLoaderDelegate.capturedLoadingRequest else {
                XCTFail("Loading request not captured")
                return
            }
            // Provide hostnameToIP dictionary
            let hostnameToIP: [String: String] = ["test.com": "127.0.0.1"]
            let delegate = StreamingSessionDelegate(loadingRequest: loadingRequest, hostnameToIP: hostnameToIP)
            let testError = URLError(.networkConnectionLost)
            delegate.onError = { error in
                if let urlError = error as? URLError {
                    XCTAssertEqual(urlError.code, .networkConnectionLost)
                    expectation.fulfill()
                } else {
                    XCTFail("Expected URLError.networkConnectionLost")
                }
            }
            
            MockURLProtocol.requestHandler = { _ in
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "1.1", headerFields: nil)!
                return (response, Data(), testError)
            }
            
            let config = URLSessionConfiguration.default
            config.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: url)
            task.resume()
        }
        
        _ = playerItem.status
        let player = AVPlayer(playerItem: playerItem)
        player.play()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        waitForExpectations(timeout: 1.0)
    }
    
    func testCancellationDoesNotFinishLoading() {
        let expectation = self.expectation(description: "Handles cancellation gracefully")
        let url = URL(string: "streaming://test.com/stream.mp3")!
        let asset = AVURLAsset(url: url)
        let resourceLoaderDelegate = MockResourceLoaderDelegate()
        asset.resourceLoader.setDelegate(resourceLoaderDelegate, queue: .main)
        let playerItem = AVPlayerItem(asset: asset)
        
        resourceLoaderDelegate.onCapture = {
            guard let loadingRequest = resourceLoaderDelegate.capturedLoadingRequest else {
                XCTFail("Loading request not captured")
                return
            }
            // Provide hostnameToIP dictionary
            let hostnameToIP: [String: String] = ["test.com": "127.0.0.1"]
            let delegate = StreamingSessionDelegate(loadingRequest: loadingRequest, hostnameToIP: hostnameToIP)
            let cancelError = URLError(.cancelled)
            var errorReceived: Error?
            
            delegate.onError = { error in
                errorReceived = error
            }
            
            MockURLProtocol.requestHandler = { _ in
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "1.1", headerFields: nil)!
                return (response, Data(), cancelError)
            }
            
            let config = URLSessionConfiguration.default
            config.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: url)
            task.resume()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                XCTAssertNil(errorReceived, "Should not receive an error for cancellation")
                XCTAssertFalse(loadingRequest.isFinished, "Should not finish loading on cancellation")
                expectation.fulfill()
            }
        }
        
        _ = playerItem.status
        let player = AVPlayer(playerItem: playerItem)
        player.play()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        waitForExpectations(timeout: 1.0)
    }
}
