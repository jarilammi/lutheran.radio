//
//  CustomDNSURLSessionDelegateTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 21.4.2025.
//

import XCTest
import Foundation
@testable import Lutheran_Radio

class CustomDNSURLSessionDelegateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
    }
    
    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }
    
    func testDNSOverrideRedirectAndError() {
        let expectation = self.expectation(description: "Handles DNS override, redirect, and error")
        let originalURL = URL(string: "https://test.com/stream.mp3")!
        let redirectURL = URL(string: "https://redirect.test.com/stream.mp3")!
        
        // Mock hostnameToIP for DNS override
        let hostnameToIP: [String: String] = ["test.com": "192.168.1.1"]
        let delegate = CustomDNSURLSessionDelegate(hostnameToIP: hostnameToIP)
        
        // Set up URLSession
        let config = URLSessionConfiguration.default
        config.protocolClasses = [MockURLProtocol.self]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: .main)
        let task = session.dataTask(with: originalURL)
        
        // Step 1: Test DNS override by manually invoking willBeginDelayedRequest
        var modifiedRequest: URLRequest?
        delegate.urlSession(session, task: task, willBeginDelayedRequest: URLRequest(url: originalURL)) { disposition, newRequest in
            XCTAssertEqual(disposition, .continueLoading, "Expected continueLoading disposition")
            modifiedRequest = newRequest
        }
        
        XCTAssertNotNil(modifiedRequest, "Expected a modified request")
        XCTAssertEqual(modifiedRequest?.url?.host, "192.168.1.1", "Expected DNS override to IP address")
        XCTAssertEqual(modifiedRequest?.value(forHTTPHeaderField: "Host"), "test.com", "Expected original host in Host header")
        
        // Step 2: MockURLProtocol setup for redirect and error
        var isRedirected = false
        MockURLProtocol.requestHandler = { request in
            print("MockURLProtocol received request: \(request.url?.absoluteString ?? "nil")")
            print("Request headers: \(request.allHTTPHeaderFields ?? [:])")
            
            if request.url?.host == "192.168.1.1" && !isRedirected {
                isRedirected = true
                let response = HTTPURLResponse(
                    url: originalURL,
                    statusCode: 301,
                    httpVersion: "1.1",
                    headerFields: ["Location": redirectURL.absoluteString]
                )!
                return (response, Data(), nil)
            } else if request.url?.host == "redirect.test.com" {
                let response = HTTPURLResponse(
                    url: redirectURL,
                    statusCode: 500,
                    httpVersion: "1.1",
                    headerFields: nil
                )!
                let error = URLError(.badServerResponse)
                return (response, Data(), error)
            } else {
                XCTFail("Unexpected request host: \(request.url?.host ?? "nil")")
                let response = HTTPURLResponse(
                    url: request.url ?? originalURL,
                    statusCode: 400,
                    httpVersion: "1.1",
                    headerFields: nil
                )!
                return (response, Data(), URLError(.badURL))
            }
        }
        
        // Step 3: Manually test redirect handling
        let redirectResponse = HTTPURLResponse(
            url: originalURL,
            statusCode: 301,
            httpVersion: "1.1",
            headerFields: ["Location": redirectURL.absoluteString]
        )!
        var redirectRequest: URLRequest?
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: redirectResponse, newRequest: URLRequest(url: redirectURL)) { newRequest in
            redirectRequest = newRequest
        }
        
        XCTAssertEqual(redirectRequest?.url?.host, "redirect.test.com", "Expected redirect to new host")
        
        // Step 4: Simulate the redirected request
        var finalResponse: URLResponse?
        var finalError: Error?
        if let handler = MockURLProtocol.requestHandler {
            do {
                let (response, _, error) = try handler(URLRequest(url: redirectURL))
                finalResponse = response
                finalError = error
            } catch {
                XCTFail("MockURLProtocol requestHandler threw unexpected error: \(error)")
            }
        } else {
            XCTFail("MockURLProtocol requestHandler is nil")
        }
        
        // Step 5: Test error handling
        delegate.urlSession(session, task: task, didCompleteWithError: finalError)
        
        // Verify final response and error
        if let httpResponse = finalResponse as? HTTPURLResponse {
            XCTAssertEqual(httpResponse.statusCode, 500, "Expected final response to be 500 after redirect")
        }
        XCTAssertNotNil(finalError, "Expected an error to be received")
        if let urlError = finalError as? URLError {
            XCTAssertEqual(urlError.code, .badServerResponse, "Expected bad server response error")
        }
        
        expectation.fulfill()
        
        waitForExpectations(timeout: 5.0) { error in
            if let error = error {
                XCTFail("Test timed out: \(error)")
            }
        }
    }
    
    func testNoDNSOverrideWhenHostNotInMapping() {
        let expectation = self.expectation(description: "Handles request without DNS override")
        let url = URL(string: "https://unknown.com/stream.mp3")!
        
        // Empty hostnameToIP
        let hostnameToIP: [String: String] = [:]
        let delegate = CustomDNSURLSessionDelegate(hostnameToIP: hostnameToIP)
        
        // Mock URL protocol handler
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.host, "unknown.com", "Expected original host with no DNS override")
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "1.1",
                headerFields: nil
            )!
            return (response, Data(), nil)
        }
        
        // Set up URLSession
        let config = URLSessionConfiguration.default
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: .main)
        
        // Start data task
        let task = session.dataTask(with: url) { _, response, error in
            if let httpResponse = response as? HTTPURLResponse {
                XCTAssertEqual(httpResponse.statusCode, 200, "Expected successful response")
            }
            XCTAssertNil(error, "Expected no error")
            expectation.fulfill()
        }
        
        task.resume()
        
        waitForExpectations(timeout: 2.0) { error in
            if let error = error {
                XCTFail("Test timed out: \(error)")
            }
        }
    }
    
    func testDNSOverrideWithInvalidURLComponents() {
        let originalURL = URL(string: "https://test.com/stream.mp3")!
        let hostnameToIP: [String: String] = ["test.com": "invalid_ip_😊"]
        let delegate = CustomDNSURLSessionDelegate(hostnameToIP: hostnameToIP)
        
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: .main)
        let task = session.dataTask(with: originalURL)
        
        let expectation = self.expectation(description: "DNS override with invalid IP produces modified request")
        delegate.urlSession(session, task: task, willBeginDelayedRequest: URLRequest(url: originalURL)) { disposition, newRequest in
            XCTAssertEqual(disposition, .continueLoading, "Expected continueLoading disposition")
            XCTAssertNotNil(newRequest, "Expected a modified request")
            XCTAssertEqual(newRequest?.url?.host, "xn--invalid_ip_-e017j", "Expected Punycode-encoded host")
            XCTAssertEqual(newRequest?.value(forHTTPHeaderField: "Host"), "test.com", "Expected original host in Host header")
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 2.0) { error in
            if let error = error {
                XCTFail("Test timed out: \(error)")
            }
        }
    }
    
    func testDNSOverrideWithNilURLComponents() {
        let originalURL = URL(string: "https://test.com/stream.mp3")!
        let hostnameToIP: [String: String] = ["test.com": "\0"] // Invalid control character to fail URLComponents
        let delegate = CustomDNSURLSessionDelegate(hostnameToIP: hostnameToIP)
        
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: .main)
        let task = session.dataTask(with: originalURL)
        
        let expectation = self.expectation(description: "No DNS override for invalid IP")
        delegate.urlSession(session, task: task, willBeginDelayedRequest: URLRequest(url: originalURL)) { disposition, newRequest in
            XCTAssertEqual(disposition, .continueLoading, "Expected continueLoading disposition")
            XCTAssertNil(newRequest, "Expected no modified request")
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 2.0) { error in
            if let error = error {
                XCTFail("Test timed out: \(error)")
            }
        }
    }
}
