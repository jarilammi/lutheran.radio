//
//  CustomDNSURLSessionDelegate.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 21.4.2025.
//

/// - Article: Custom DNS URL Session Delegate Guide
///
/// This class provides custom DNS resolution for URL session tasks in Lutheran Radio.
import Foundation

// MARK: - Custom URLSessionDelegate for DNS Override
class CustomDNSURLSessionDelegate: NSObject, URLSessionTaskDelegate {
    /// A dictionary mapping hostnames to their corresponding IP addresses for DNS overriding.
    let hostnameToIP: [String: String]
    
    /// Initializes the delegate with a hostname-to-IP mapping.
    /// - Parameter hostnameToIP: A dictionary of hostnames and their IP addresses.
    init(hostnameToIP: [String: String]) {
        self.hostnameToIP = hostnameToIP
        super.init()
    }
    
    /// Handles HTTP redirection by allowing the default request.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Apply DNS override to redirects as well
        if let url = request.url, let host = url.host, let ipAddress = hostnameToIP[host] {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.host = ipAddress
            if let newURL = components?.url {
                var modifiedRequest = request
                modifiedRequest.url = newURL
                modifiedRequest.setValue(host, forHTTPHeaderField: "Host")
                #if DEBUG
                print("📡 [Redirect] Overriding DNS for \(host) to \(ipAddress)")
                #endif
                completionHandler(modifiedRequest)
                return
            }
        }
        completionHandler(request)
    }
    
    /// Logs completion with an error if present.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            #if DEBUG
            print("📡 [CustomDNS] Task failed: \(error.localizedDescription)")
            #endif
        }
    }
    
    /// Overrides DNS for delayed requests by replacing the host with an IP address.
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
