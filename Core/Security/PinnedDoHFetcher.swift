//
//  PinnedDoHFetcher.swift
//  Core
//
//  Created by Jari Lammi on 30.10.2026.
//
//  RFC 8484 DNS wire transport over HTTPS. Two resolvers, each authenticated by
//  its own SPKI pin plus the system trust store. This session does not set
//  `requiresDNSSECValidation`: that flag is what stalls when the system
//  validator never calls back. The AD bit on the DNS message is not read.
//
//  One ``PinnedDoHFetcher`` keeps one ephemeral `URLSession` per resolver host
//  and reuses it for every query that fetcher posts. `cloudflare-dns.com` and
//  `dns.google` do not share a session. ``resolverWalkFetchers()`` gives the
//  next fetcher its own sessions. ``DNSSECResolverWalk`` finishes them when
//  that walk attempt returns, before the next fetcher runs. A later walk does
//  not inherit the connection or cookies.
//
//  Pin failure, a redirect, a truncated message, or any rcode other than
//  NOERROR / NXDOMAIN skips that resolver inside this one query. The first
//  well-formed message is what the current ``DNSSECWalk`` verifies. This
//  fetcher does not ask another resolver for a second opinion on that message.
//  A signature or chain failure is a new walk in ``DNSSECResolverWalk``, bound
//  to the next resolver alone. The AD bit is not read.
//
//  - SeeAlso: ``DNSSECWalk``, ``DNSSECResolverWalk``, ``SecurityConfiguration/pinnedDoHResolvers``,
//    ``<doc:Security-Invariants>`` Invariant 1
//

import Foundation
// ``PinnedDoHSessionOwner`` holds the host-to-session map in a `Mutex`.
// Copies of one ``PinnedDoHFetcher`` share that owner. ``session(for:)`` and
// ``invalidate()`` stay synchronous, and `deinit` calls
// `finishTasksAndInvalidate()` before the owner is released. That call runs
// after `withLock` returns: this mutex is not recursive.
import Synchronization
@unsafe @preconcurrency import Security

/// One pinned DNS-over-HTTPS resolver. The host and SPKI live only in ``SecurityConfiguration``.
public struct PinnedDoHResolver: Sendable, Equatable {
    public var host: String
    public var spkiSHA256Base64: String

    public init(host: String, spkiSHA256Base64: String) {
        self.host = host
        self.spkiSHA256Base64 = spkiSHA256Base64
    }
}

/// Posts DNS queries to pinned resolvers in order.
///
/// One value keeps one ephemeral `URLSession` per resolver host and reuses it
/// across the queries that value makes. The two hosts do not share a session.
/// ``resolverWalkFetchers()`` gives the next fetcher a new session owner, so a
/// later walk does not inherit the connection or cookies.
/// ``DNSSECResolverWalk`` calls ``invalidateSessions()`` when that walk attempt
/// returns, before the next fetcher runs.
///
/// `resolvers` nil reads ``SecurityConfiguration/pinnedDoHResolvers`` when the
/// query runs. A non-nil list is the only set this fetcher may post to.
/// ``resolverWalkFetchers()`` is the production order: the full list, then one
/// fetcher per later resolver.
///
/// - SeeAlso: ``DNSSECResolverWalk``, ``<doc:Security-Invariants>`` Invariant 1
struct PinnedDoHFetcher: DNSWireFetching {
    /// Resolvers this fetcher may post to. Nil reads ``SecurityConfiguration/pinnedDoHResolvers`` at query time.
    let resolvers: [PinnedDoHResolver]?
    /// Sessions for this fetcher only. Copies of this value share the owner. A new value does not.
    private let sessions = PinnedDoHSessionOwner()

    init(resolvers: [PinnedDoHResolver]? = nil) {
        self.resolvers = resolvers
    }

    /// Ephemeral configuration for one resolver's reused DoH session.
    ///
    /// Cache and credential storage are nil. The request cache policy ignores
    /// local and remote caches. Request and resource timeouts are 4 seconds.
    /// `requiresDNSSECValidation` is left unset (the property defaults to false).
    /// This fetch exists because that flag produced no callback.
    ///
    /// - Returns: A new configuration. Each `URLSession` copies it.
    /// - SeeAlso: ``DNSSECResolverWalk``, ``<doc:Security-Invariants>`` Invariant 1
    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 4
        // SECURITY: Do not set requiresDNSSECValidation. The default is false.
        // Setting it is the stall this fetch exists to avoid. Authenticate the resolver by SPKI.
        return configuration
    }

    /// Finishes every session this fetcher opened.
    ///
    /// ``DNSSECResolverWalk`` calls this when the walk attempt returns, before
    /// the next fetcher runs. A second call does nothing. ``DNSWireFetching``
    /// has no close method, so fixture fetchers are unchanged.
    func invalidateSessions() {
        sessions.invalidate()
    }

    /// First fetcher posts to every pinned resolver. Each later fetcher posts to one remaining resolver.
    static func resolverWalkFetchers() -> [PinnedDoHFetcher] {
        let resolvers = SecurityConfiguration.current.pinnedDoHResolvers
        guard !resolvers.isEmpty else { return [] }
        var fetchers = [PinnedDoHFetcher(resolvers: resolvers)]
        for resolver in resolvers.dropFirst() {
            fetchers.append(PinnedDoHFetcher(resolvers: [resolver]))
        }
        return fetchers
    }

    func response(toQuery wire: Data) async -> Data? {
        if ProcessInfo.processInfo.arguments.contains("-UITestMode") {
            return nil
        }
        let list = resolvers ?? SecurityConfiguration.current.pinnedDoHResolvers
        for resolver in list {
            if let message = await post(wire, resolver: resolver), isWellFormed(message, query: wire) {
                return message
            }
        }
        return nil
    }

    private func post(_ wire: Data, resolver: PinnedDoHResolver) async -> Data? {
        guard let url = URL(string: "https://\(resolver.host)/dns-query"),
              let session = sessions.session(for: resolver) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.httpBody = wire
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 65_536 else {
                return nil
            }
            if let type = http.value(forHTTPHeaderField: "Content-Type"),
               !type.lowercased().contains("dns-message") {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private func isWellFormed(_ response: Data, query: Data) -> Bool {
        guard let queryMessage = DNSMessage.parse(query),
              let message = DNSMessage.parse(response),
              message.isResponse,
              message.id == queryMessage.id,
              !message.truncated,
              message.rcode == 0 || message.rcode == 3 else {
            return false
        }
        return true
    }

    /// Builds the pinned session for `resolver`. Nil when the SPKI pin is not 32 bytes.
    /// The caller stores one session per host and does not build another for that host.
    fileprivate static func makeSession(for resolver: PinnedDoHResolver) -> URLSession? {
        guard let pin = pinFingerprint(resolver.spkiSHA256Base64) else { return nil }
        let delegate = DoHPinDelegate(pin: pin)
        return URLSession(configuration: sessionConfiguration(), delegate: delegate, delegateQueue: nil)
    }

    private static func pinFingerprint(_ base64: String) -> CertificateFingerprint? {
        guard let bytes = Data(base64Encoded: base64), bytes.count == CertificateFingerprint.byteCount else {
            return nil
        }
        return CertificateFingerprint(bytes: [UInt8](bytes))
    }

    #if DEBUG
    /// Opens the reused session for `resolver` without posting a query.
    /// The same host on this fetcher returns the same object. A bad pin returns nil.
    func _test_sessionIdentifier(for resolver: PinnedDoHResolver) -> ObjectIdentifier? {
        sessions.identifier(for: resolver)
    }

    /// Sessions this fetcher still holds. Zero after ``invalidateSessions()``.
    var _test_openSessionCount: Int { sessions.openCount }
    #endif
}

/// One ephemeral `URLSession` per resolver host for a single ``PinnedDoHFetcher``.
///
/// Copies of the fetcher share this owner. The host map is the only mutable
/// state. A `Mutex` (`import Synchronization`) makes this class `Sendable`
/// and keeps ``session(for:)`` and ``invalidate()`` synchronous, including the
/// `deinit` backstop. `finishTasksAndInvalidate()` runs after `withLock`
/// returns: the mutex is not recursive, and invalidation can call the delegate.
/// ``DNSSECWalk`` awaits each query before the next. An overlapping
/// ``session(for:)`` still returns the session already stored for that host.
/// `URLSession` is `Sendable`. The network await stays outside the lock.
///
/// ``DNSSECResolverWalk`` calls ``invalidate()`` when the walk attempt returns,
/// before the next fetcher runs. `deinit` calls it again when the fetcher is
/// released without that call. A later walk does not inherit the connection
/// or cookies. There is no process-lifetime session.
///
/// - SeeAlso: ``PinnedDoHFetcher``, ``DNSSECResolverWalk``, ``<doc:Security-Invariants>`` Invariant 1
private final class PinnedDoHSessionOwner: Sendable {
    private let sessions = Mutex<[String: URLSession]>([:])

    /// The session already stored for `resolver.host`, or a new one.
    /// A pin that is not 32 bytes stores nothing.
    func session(for resolver: PinnedDoHResolver) -> URLSession? {
        sessions.withLock { map in
            if let existing = map[resolver.host] {
                return existing
            }
            guard let created = PinnedDoHFetcher.makeSession(for: resolver) else {
                return nil
            }
            map[resolver.host] = created
            return created
        }
    }

    /// Finishes every stored session and drops the references.
    /// A second call finds an empty map.
    func invalidate() {
        let open = sessions.withLock { map -> [URLSession] in
            let values = Array(map.values)
            map.removeAll()
            return values
        }
        for session in open {
            session.finishTasksAndInvalidate()
        }
    }

    deinit {
        invalidate()
    }

    #if DEBUG
    var openCount: Int {
        sessions.withLock { $0.count }
    }

    func identifier(for resolver: PinnedDoHResolver) -> ObjectIdentifier? {
        guard let session = session(for: resolver) else { return nil }
        return ObjectIdentifier(session)
    }
    #endif
}

/// Accepts a DoH handshake only when system trust succeeds and the leaf SPKI matches.
///
/// Redirects are refused. A pin mismatch cancels the challenge so the caller tries
/// the other resolver. This delegate does not call ``CertificateValidator``: that
/// actor's leaf pin is the media certificate, not the resolver.
// SAFETY: `pin` is an immutable value. The delegate methods do not mutate instance
// state. `NSObject` is not `Sendable`, so the conformance is unchecked.
private final class DoHPinDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let pin: CertificateFingerprint

    init(pin: CertificateFingerprint) {
        self.pin = pin
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.cancelAuthenticationChallenge, nil)
        }
        var error: CFError?
        // SAFETY: SecTrustEvaluateWithError writes `error` only on failure. The trust
        // object is the one URLSession presented for this resolver handshake.
        guard unsafe SecTrustEvaluateWithError(trust, &error),
              let leaf = SubjectPublicKeyInfo.leafFingerprint(trust: trust),
              leaf.constantTimeMatches(pin) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
