//
//  ProtectedHostHTTPS.swift
//  Core
//
//  Created by Jari Lammi on 30.10.2026.
//
//  One streaming retry for the case where URLSession reports that DNSSEC did not
//  finish. The first attempt always uses ``SecurityConfiguration/makeSecureEphemeralConfiguration()``.
//  ``requiresDNSSECValidationForStreaming`` stays true.
//
//  The retry exists only when the error is `NSURLErrorDomain` -1001 whose stream
//  error is domain 4 / code -2102, and local A/AAAA verification of that host
//  just succeeded. The replacement session clears `requiresDNSSECValidation` and
//  connects only to those addresses, with the TLS peer name still the hostname.
//  Cache and credentials stay nil. A redirect to another host does not reuse the
//  address set; the caller starts a DNSSEC-on request for the new host.
//
//  `NWConnection` does not apply `NSPinnedDomains`. The verify block checks the
//  Info.plist SPKI pin, then ``CertificateValidator/validateServerTrust(_:)``.
//  The verify completion imports as a non-escaping Swift function, wider than a
//  pointer. It is called before the verify callback returns. `unsafeBitCast` to
//  `UnsafeRawPointer` traps ("Can't unsafeBitCast between types of different sizes").
//
//  - SeeAlso: ``DNSSECLocalVerification``, ``<doc:Security-Invariants>`` Invariant 2
//

import Foundation
import Network
import Synchronization
@unsafe @preconcurrency import Security

public enum ProtectedHostHTTPS {
    /// Error domain when a flag-off connection is asked to follow a different host.
    public static let dnssecRedirectDomain = "radio.lutheran.dnssec-redirect"

    /// `true` for the URLSession timeout that means the system DNSSEC validator did not finish.
    ///
    /// A plain timeout is not enough. The stream domain must be 4 and the stream code -2102,
    /// on this error or on an underlying error (at most eight deep).
    public static func isSystemDNSSECNotCompleted(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth < 8 {
            // URLSession stores the CFNetwork stream domain and code under these exact userInfo strings.
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut,
               streamValue(nsError.userInfo["_kCFStreamErrorDomainKey"]) == 4,
               streamValue(nsError.userInfo["_kCFStreamErrorCodeKey"]) == -2102 {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    /// Whether this failure may use ``SecurityConfiguration/makeVerifiedAddressRetryConfiguration()``.
    ///
    /// - Parameters:
    ///   - error: The failing task error.
    ///   - verifiedAddressCount: Addresses local verification just accepted. Zero refuses the retry.
    ///   - alreadyRetried: The one allowed flag-off attempt for this request has been used.
    /// - Returns: `true` only for the DNSSEC-not-completed shape, a non-empty address set, and a first retry.
    public static func allowsFlagOffRetry(error: Error, verifiedAddressCount: Int, alreadyRetried: Bool) -> Bool {
        !alreadyRetried && verifiedAddressCount > 0 && isSystemDNSSECNotCompleted(error)
    }

    /// Loads `request` with DNSSEC required, then at most one verified-address retry.
    ///
    /// - Parameters:
    ///   - request: The caller-built request. Its `User-Agent` is left unchanged.
    ///   - host: Hostname that must satisfy ``SecurityConfiguration/hostRequiresDNSSECValidation(_:)`` before a retry.
    ///   - configureFirst: Applied only to the DNSSEC-on configuration (timeouts). Not applied to the retry.
    ///   - delegate: Forwarded to both sessions. The retry's TLS check runs inside the custom protocol.
    ///   - delegateQueue: Queue for `delegate`. Nil uses URLSession's default.
    ///   - retryTimeout: Request timeout for the flag-off attempt. The first attempt keeps `configureFirst`.
    /// - Returns: The response body and URL response.
    /// - Throws: The original error when the retry is not allowed or itself fails. A cross-host redirect
    ///   starts a new DNSSEC-on load for that host (one restart).
    /// - SeeAlso: ``allowsFlagOffRetry(error:verifiedAddressCount:alreadyRetried:)``
    public static func data(
        for request: URLRequest,
        host: String?,
        configureFirst: (URLSessionConfiguration) -> Void,
        delegate: (any URLSessionTaskDelegate)?,
        delegateQueue: OperationQueue?,
        retryTimeout: TimeInterval = 15
    ) async throws -> (Data, URLResponse) {
        try await load(
            request,
            host: host,
            configureFirst: configureFirst,
            delegate: delegate,
            delegateQueue: delegateQueue,
            retryTimeout: retryTimeout,
            redirectDepth: 0
        )
    }

    /// Copies `request` and binds it to `addresses` for ``VerifiedAddressHTTPSProtocol``.
    ///
    /// The token header is stripped before bytes are written to the origin.
    public static func requestByBindingVerifiedAddresses(
        _ request: URLRequest,
        host: String,
        addresses: [VerifiedSocketAddress]
    ) -> URLRequest {
        var copy = request
        let token = VerifiedAddressRegistry.insert(
            VerifiedAddressBinding(host: host, addresses: addresses)
        )
        copy.setValue(token.uuidString, forHTTPHeaderField: VerifiedAddressRegistry.header)
        return copy
    }

    private static func load(
        _ request: URLRequest,
        host: String?,
        configureFirst: (URLSessionConfiguration) -> Void,
        delegate: (any URLSessionTaskDelegate)?,
        delegateQueue: OperationQueue?,
        retryTimeout: TimeInterval,
        redirectDepth: Int
    ) async throws -> (Data, URLResponse) {
        let configuration = SecurityConfiguration.makeSecureEphemeralConfiguration()
        configureFirst(configuration)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
        do {
            let result = try await session.data(for: request)
            session.finishTasksAndInvalidate()
            return result
        } catch {
            session.finishTasksAndInvalidate()
            guard let host, SecurityConfiguration.hostRequiresDNSSECValidation(host),
                  isSystemDNSSECNotCompleted(error) else {
                throw error
            }
            let addresses = await DNSSECLocalVerification.verifiedAddresses(forHost: host)
            guard allowsFlagOffRetry(error: error, verifiedAddressCount: addresses.count, alreadyRetried: false) else {
                throw error
            }
            let retryConfiguration = SecurityConfiguration.makeVerifiedAddressRetryConfiguration()
            retryConfiguration.timeoutIntervalForRequest = retryTimeout
            retryConfiguration.timeoutIntervalForResource = max(retryTimeout, 20)
            let retrySession = URLSession(
                configuration: retryConfiguration,
                delegate: delegate,
                delegateQueue: delegateQueue
            )
            var retryRequest = request
            retryRequest.timeoutInterval = retryTimeout
            retryRequest = requestByBindingVerifiedAddresses(retryRequest, host: host, addresses: addresses)
            do {
                let result = try await retrySession.data(for: retryRequest)
                retrySession.finishTasksAndInvalidate()
                VerifiedAddressRegistry.removeToken(from: retryRequest)
                return result
            } catch {
                retrySession.finishTasksAndInvalidate()
                VerifiedAddressRegistry.removeToken(from: retryRequest)
                if redirectDepth < 1, let restarted = redirectedRequest(from: error, fallback: request) {
                    return try await load(
                        restarted,
                        host: restarted.url?.host,
                        configureFirst: configureFirst,
                        delegate: delegate,
                        delegateQueue: delegateQueue,
                        retryTimeout: retryTimeout,
                        redirectDepth: redirectDepth + 1
                    )
                }
                throw error
            }
        }
    }

    private static func streamValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let number = value as? Int { return number }
        return nil
    }

    private static func redirectedRequest(from error: Error, fallback: URLRequest) -> URLRequest? {
        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth < 8 {
            if nsError.domain == dnssecRedirectDomain,
               let urlString = nsError.userInfo["URL"] as? String,
               let url = URL(string: urlString) {
                var request = fallback
                request.url = url
                return request
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return nil
    }
}

struct VerifiedAddressBinding: Sendable {
    var host: String
    var addresses: [VerifiedSocketAddress]
}

enum VerifiedAddressRegistry {
    static let header = "X-Lutheran-Verified-Address"
    private static let storage = Mutex<[UUID: VerifiedAddressBinding]>([:])

    static func insert(_ binding: VerifiedAddressBinding) -> UUID {
        let id = UUID()
        storage.withLock { $0[id] = binding }
        return id
    }

    static func peek(_ id: UUID) -> VerifiedAddressBinding? {
        storage.withLock { $0[id] }
    }

    static func remove(_ id: UUID) {
        storage.withLock { _ = $0.removeValue(forKey: id) }
    }

    static func removeToken(from request: URLRequest) {
        guard let token = request.value(forHTTPHeaderField: header), let id = UUID(uuidString: token) else { return }
        remove(id)
    }
}

/// HTTPS/1.1 to a verified address list. Registered only on the flag-off configuration.
///
/// SAFETY: `URLProtocol` is not `Sendable`. Callbacks and `NWConnection` events hop to
/// `queue`. The TLS verify block does not capture this instance; it captures the hostname
/// and the trust object.
/// Internal: only ``SecurityConfiguration/makeVerifiedAddressRetryConfiguration()`` registers it.
final class VerifiedAddressHTTPSProtocol: URLProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: "radio.lutheran.verified-address")
    private var connection: NWConnection?
    private var generation = 0
    private var stopped = false
    private var clientFinished = false
    private var redirectCount = 0
    private var currentURL: URL?
    private var headerBuffer = Data()
    private var headersSent = false
    private var bodyRemaining: Int?
    private var chunkRemaining: Int?
    private var readingChunkSize = true
    private var chunkBuffer = Data()
    private var bodyMode: BodyMode = .untilClose

    private enum BodyMode {
        case untilClose
        case contentLength
        case chunked
        case none
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard request.url?.scheme?.lowercased() == "https",
              let token = request.value(forHTTPHeaderField: VerifiedAddressRegistry.header),
              let id = UUID(uuidString: token),
              VerifiedAddressRegistry.peek(id) != nil else {
            return false
        }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    override func stopLoading() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.connection?.cancel()
            self.removeBinding()
        }
    }

    private func startOnQueue() {
        guard let url = request.url, let host = url.host, let token = tokenIdentifier, let binding = VerifiedAddressRegistry.peek(token) else {
            fail(URLError(.badURL))
            return
        }
        let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let boundHost = binding.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard normalizedHost == boundHost else {
            fail(URLError(.cannotConnectToHost))
            return
        }
        currentURL = url
        connect(addresses: binding.addresses, index: 0, host: binding.host)
    }

    private var tokenIdentifier: UUID? {
        guard let token = request.value(forHTTPHeaderField: VerifiedAddressRegistry.header) else { return nil }
        return UUID(uuidString: token)
    }

    private func connect(addresses: [VerifiedSocketAddress], index: Int, host: String) {
        guard !stopped else { return }
        guard index < addresses.count, let url = currentURL else {
            fail(URLError(.cannotConnectToHost))
            return
        }
        let portNumber = UInt16(url.port ?? 443)
        guard let port = NWEndpoint.Port(rawValue: portNumber) else {
            fail(URLError(.badURL))
            return
        }
        let endpoint: NWEndpoint
        switch addresses[index].family {
        case .v4:
            guard let ip = IPv4Address(addresses[index].presentation) else {
                connect(addresses: addresses, index: index + 1, host: host)
                return
            }
            endpoint = .hostPort(host: .ipv4(ip), port: port)
        case .v6:
            guard let ip = IPv6Address(addresses[index].presentation) else {
                connect(addresses: addresses, index: index + 1, host: host)
                return
            }
            endpoint = .hostPort(host: .ipv6(ip), port: port)
        }
        let tls = NWProtocolTLS.Options()
        let securityOptions = tls.securityProtocolOptions
        host.withCString { name in
            // SAFETY: sec_protocol_options_set_tls_server_name copies the hostname. The peer name stays the URL host, not the address.
            unsafe sec_protocol_options_set_tls_server_name(securityOptions, name)
        }
        "http/1.1".withCString { proto in
            // SAFETY: The ALPN string is copied. Icecast on these origins is HTTP/1.1. h2 is not offered.
            unsafe sec_protocol_options_add_tls_application_protocol(securityOptions, proto)
        }
        installVerify(options: securityOptions, host: host)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(to: endpoint, using: parameters)
        self.generation += 1
        let attempt = self.generation
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, attempt == self.generation else { return }
            switch state {
            case .ready:
                self.sendRequest(on: connection, generation: attempt, host: host)
                self.receive(on: connection, generation: attempt)
            case .failed:
                if self.headersSent || self.clientFinished {
                    self.fail(URLError(.networkConnectionLost))
                } else {
                    self.connect(addresses: addresses, index: index + 1, host: host)
                }
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func installVerify(options: sec_protocol_options_t, host: String) {
        // SECURITY: Boringssl still performs the TLS record protection. This block
        // only accepts or rejects the certificate. ATS SPKI is required because
        // NWConnection does not apply NSPinnedDomains. The leaf DER pin remains
        // CertificateValidator.validateServerTrust. No private cipher is added.
        //
        // `complete` is `sec_protocol_verify_complete_t`, imported as `(Bool) -> Void`.
        // That value is wider than a pointer, so `unsafeBitCast` to `UnsafeRawPointer`
        // traps. It is non-escaping, so it is called before this callback returns.
        // Trust evaluation hops to the certificate actor, which does not use this queue.
        let peer = host
        sec_protocol_options_set_verify_block(options, { _, trustRef, complete in
            // SAFETY: sec_trust_copy_ref returns a +1 SecTrust. The header omits
            // SEC_RETURNS_RETAINED, so Swift imports Unmanaged. takeRetainedValue balances that retain.
            let trust = unsafe sec_trust_copy_ref(trustRef).takeRetainedValue()
            let outcome = Mutex(false)
            let done = DispatchSemaphore(value: 0)
            Task {
                let accepted = await CertificateValidator.shared.validateStreamingServerTrust(trust, host: peer)
                outcome.withLock { $0 = accepted }
                done.signal()
            }
            // This queue is blocked only for the pin check. `complete` is then called
            // on this turn, the same way Network.framework samples call it inline.
            done.wait()
            complete(outcome.withLock { $0 })
        }, queue)
    }

    private func sendRequest(on connection: NWConnection, generation: Int, host: String) {
        guard generation == self.generation, let url = currentURL, let payload = requestBytes(url: url, host: host) else {
            fail(URLError(.badURL))
            return
        }
        headerBuffer.removeAll()
        headersSent = false
        chunkBuffer.removeAll()
        readingChunkSize = true
        chunkRemaining = nil
        bodyRemaining = nil
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let self, generation == self.generation else { return }
            if let error {
                self.fail(error)
            }
        })
    }

    private func requestBytes(url: URL, host: String) -> Data? {
        let method = request.httpMethod ?? "GET"
        let path = url.path.isEmpty ? "/" : url.path
        let query = url.query.map { "?\($0)" } ?? ""
        var lines = ["\(method) \(path)\(query) HTTP/1.1"]
        var hasHost = false
        for (field, value) in request.allHTTPHeaderFields ?? [:] {
            if field.caseInsensitiveCompare(VerifiedAddressRegistry.header) == .orderedSame { continue }
            if field.caseInsensitiveCompare("Host") == .orderedSame { hasHost = true }
            lines.append("\(field): \(value)")
        }
        if !hasHost {
            if let port = url.port, port != 443 {
                lines.append("Host: \(host):\(port)")
            } else {
                lines.append("Host: \(host)")
            }
        }
        let body = request.httpBody ?? Data()
        if !body.isEmpty, request.value(forHTTPHeaderField: "Content-Length") == nil {
            lines.append("Content-Length: \(body.count)")
        }
        guard var bytes = lines.joined(separator: "\r\n").data(using: .utf8) else { return nil }
        bytes.append(Data("\r\n\r\n".utf8))
        bytes.append(body)
        return bytes
    }

    private func receive(on connection: NWConnection, generation: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, generation == self.generation, !self.stopped, !self.clientFinished else { return }
            if let data, !data.isEmpty {
                self.consume(data)
            }
            if self.clientFinished || self.stopped { return }
            if let error {
                self.fail(error)
                return
            }
            if isComplete {
                if self.headersSent, self.bodyMode == .untilClose {
                    self.succeed()
                } else {
                    self.fail(URLError(.networkConnectionLost))
                }
                return
            }
            self.receive(on: connection, generation: generation)
        }
    }

    private func consume(_ data: Data) {
        if !headersSent {
            headerBuffer.append(data)
            guard headerBuffer.count <= 65_536 else {
                fail(URLError(.cannotParseResponse))
                return
            }
            guard let separator = headerBuffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let headerBytes = headerBuffer.subdata(in: 0..<separator.lowerBound)
            let rest = headerBuffer.subdata(in: separator.upperBound..<headerBuffer.count)
            headerBuffer.removeAll()
            guard handleHeaders(headerBytes) else { return }
            if !rest.isEmpty, !clientFinished {
                consumeBody(rest)
            }
            return
        }
        consumeBody(data)
    }

    private func handleHeaders(_ bytes: Data) -> Bool {
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            fail(URLError(.cannotParseResponse))
            return false
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            fail(URLError(.cannotParseResponse))
            return false
        }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]), let url = currentURL else {
            fail(URLError(.cannotParseResponse))
            return false
        }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[name] = value
        }
        if [301, 302, 303, 307, 308].contains(status) {
            followRedirect(status: status, fields: fields)
            return false
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields) else {
            fail(URLError(.cannotParseResponse))
            return false
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        headersSent = true
        let method = (request.httpMethod ?? "GET").uppercased()
        if method == "HEAD" {
            bodyMode = .none
            succeed()
            return false
        }
        if fields["transfer-encoding"]?.lowercased().contains("chunked") == true {
            bodyMode = .chunked
            readingChunkSize = true
        } else if let lengthText = fields["content-length"], let length = Int(lengthText) {
            bodyMode = .contentLength
            bodyRemaining = length
            if length == 0 { succeed() }
        } else {
            bodyMode = .untilClose
        }
        return true
    }

    private func followRedirect(status: Int, fields: [String: String]) {
        guard let location = fields["location"], let base = currentURL,
              let target = URL(string: location, relativeTo: base)?.absoluteURL,
              let targetHost = target.host else {
            fail(URLError(.badURL))
            return
        }
        let currentHost = base.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let nextHost = targetHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard currentHost == nextHost else {
            fail(NSError(
                domain: ProtectedHostHTTPS.dnssecRedirectDomain,
                code: 1,
                userInfo: [
                    "host": targetHost,
                    "URL": target.absoluteString,
                    NSLocalizedDescriptionKey: "Verified-address retry does not follow a different host",
                ]
            ))
            return
        }
        redirectCount += 1
        guard redirectCount <= 3, let token = tokenIdentifier, let binding = VerifiedAddressRegistry.peek(token) else {
            fail(URLError(.badURL))
            return
        }
        if status == 303 {
            // 303 switches to GET. The stored URLRequest is immutable from here; Icecast retries are GET.
        }
        currentURL = target
        connection?.cancel()
        connect(addresses: binding.addresses, index: 0, host: binding.host)
    }

    private func consumeBody(_ data: Data) {
        switch bodyMode {
        case .none:
            return
        case .untilClose:
            client?.urlProtocol(self, didLoad: data)
        case .contentLength:
            guard var remaining = bodyRemaining else { return }
            if data.count < remaining {
                client?.urlProtocol(self, didLoad: data)
                remaining -= data.count
                bodyRemaining = remaining
                return
            }
            if remaining > 0 {
                client?.urlProtocol(self, didLoad: data.prefix(remaining))
            }
            succeed()
        case .chunked:
            consumeChunked(data)
        }
    }

    private func consumeChunked(_ data: Data) {
        chunkBuffer.append(data)
        while !clientFinished {
            if readingChunkSize {
                guard let crlf = chunkBuffer.range(of: Data("\r\n".utf8)) else { return }
                let line = chunkBuffer.subdata(in: 0..<crlf.lowerBound)
                chunkBuffer.removeSubrange(0..<crlf.upperBound)
                let sizeText = String(data: line, encoding: .utf8)?.split(separator: ";").first.map(String.init) ?? ""
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else {
                    fail(URLError(.cannotParseResponse))
                    return
                }
                chunkRemaining = size
                readingChunkSize = false
            } else if let remaining = chunkRemaining {
                guard chunkBuffer.count >= remaining + 2 else { return }
                if remaining > 0 {
                    client?.urlProtocol(self, didLoad: chunkBuffer.prefix(remaining))
                }
                chunkBuffer.removeSubrange(0..<(remaining + 2))
                chunkRemaining = nil
                readingChunkSize = true
                if remaining == 0 {
                    succeed()
                    return
                }
            }
        }
    }

    private func succeed() {
        guard !clientFinished else { return }
        clientFinished = true
        client?.urlProtocolDidFinishLoading(self)
        connection?.cancel()
        removeBinding()
    }

    private func fail(_ error: Error) {
        guard !clientFinished else { return }
        clientFinished = true
        client?.urlProtocol(self, didFailWithError: error)
        connection?.cancel()
        removeBinding()
    }

    private func removeBinding() {
        if let token = tokenIdentifier {
            VerifiedAddressRegistry.remove(token)
        }
    }
}
