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
//  Pin failure, a redirect, a truncated message, or any rcode other than
//  NOERROR / NXDOMAIN skips that resolver. The first well-formed message is the
//  one ``DNSSECWalk`` verifies. A later resolver is not asked for a second opinion.
//
//  - SeeAlso: ``DNSSECWalk``, ``SecurityConfiguration/pinnedDoHResolvers``,
//    ``<doc:Security-Invariants>`` Invariant 1
//

import Foundation
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

/// Posts one DNS query to ``SecurityConfiguration/pinnedDoHResolvers`` in order.
struct PinnedDoHFetcher: DNSWireFetching {
    func response(toQuery wire: Data) async -> Data? {
        if ProcessInfo.processInfo.arguments.contains("-UITestMode") {
            return nil
        }
        for resolver in SecurityConfiguration.current.pinnedDoHResolvers {
            if let message = await post(wire, resolver: resolver), isWellFormed(message, query: wire) {
                return message
            }
        }
        return nil
    }

    private func post(_ wire: Data, resolver: PinnedDoHResolver) async -> Data? {
        guard let pin = pinFingerprint(resolver.spkiSHA256Base64),
              let url = URL(string: "https://\(resolver.host)/dns-query") else {
            return nil
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 4
        // SECURITY: Do not set requiresDNSSECValidation here. This fetch exists
        // because that flag produced no callback. Authenticate the resolver by SPKI.
        let delegate = DoHPinDelegate(pin: pin)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        // The task has finished before this function returns. Without this, the session
        // keeps the pin delegate for the process lifetime (one session per chain fetch).
        defer { session.finishTasksAndInvalidate() }
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

    private func pinFingerprint(_ base64: String) -> CertificateFingerprint? {
        guard let bytes = Data(base64Encoded: base64), bytes.count == CertificateFingerprint.byteCount else {
            return nil
        }
        return CertificateFingerprint(bytes: [UInt8](bytes))
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
}

/// Accepts a DoH handshake only when system trust succeeds and the leaf SPKI matches.
///
/// Redirects are refused. A pin mismatch cancels the challenge so the caller tries
/// the other resolver. This delegate does not call ``CertificateValidator``: that
/// actor's leaf pin is the media certificate, not the resolver.
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
