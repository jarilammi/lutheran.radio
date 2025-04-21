//
//  URLSessionDelegate.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 21.4.2025.
//

import Foundation

// MARK: - Custom URLSessionDelegate for DNS Override
class CustomDNSURLSessionDelegate: NSObject, URLSessionTaskDelegate {
    let hostnameToIP: [String: String]
    
    init(hostnameToIP: [String: String]) {
        self.hostnameToIP = hostnameToIP
        super.init()
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection redirectResponse: HTTPURLResponse, newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(newRequest)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            #if DEBUG
            print("📡 [CustomDNS] Task failed: \(error.localizedDescription)")
            #endif
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, willBeginDelayedRequest request: URLRequest, completionHandler: @escaping (URLSession.DelayedRequestDisposition, URLRequest?) -> Void) {
        guard let url = request.url, let host = url.host, let ipAddress = hostnameToIP[host] else {
            completionHandler(.continueLoading, nil)
            return
        }
        
        // Create a new URL with the IP address
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = ipAddress
        if let newURL = components?.url {
            var newRequest = request
            newRequest.url = newURL
            newRequest.setValue(host, forHTTPHeaderField: "Host") // Preserve original host in headers
            #if DEBUG
            print("📡 [CustomDNS] Overriding DNS for \(host) to \(ipAddress), new URL: \(newURL)")
            #endif
            completionHandler(.continueLoading, newRequest)
        } else {
            completionHandler(.continueLoading, nil)
        }
    }
}
