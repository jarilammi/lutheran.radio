//
//  SubjectPublicKeyInfo.swift
//  Core
//
//  Created by Jari Lammi on 30.10.2026.
//
//  SHA-256 of a certificate's SubjectPublicKeyInfo, including the SEQUENCE header.
//  This is the same bytes ATS stores as `SPKI-SHA256-BASE64` and the same bytes
//  OpenSSL prints from `openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl base64`.
//
//  The walker skips an optional `[0] EXPLICIT` version, then five TBS fields
//  (serial, signature, issuer, validity, subject). The next SEQUENCE is the SPKI.
//  DoH pins and the streaming ATS check both use this. They are not the media
//  leaf DER pin.
//
//  - SeeAlso: ``PinnedDoHResolver``, ``CertificateValidator/validateStreamingServerTrust(_:host:)``,
//    ``<doc:Security-Invariants>`` Invariant 2
//

import CryptoKit
import Foundation
@unsafe @preconcurrency import Security

enum SubjectPublicKeyInfo {
    /// SHA-256 of the SPKI SEQUENCE, or nil when the certificate is not DER.
    static func fingerprint(certificateDER: Data) -> CertificateFingerprint? {
        guard let spki = extract(certificateDER: certificateDER) else { return nil }
        let digest = Array(SHA256.hash(data: spki))
        guard digest.count == CertificateFingerprint.byteCount else { return nil }
        return CertificateFingerprint(bytes: digest)
    }

    /// Leaf SPKI of `trust`. Nil when the chain or the encoding cannot be read.
    static func leafFingerprint(trust: SecTrust) -> CertificateFingerprint? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return nil
        }
        let der = SecCertificateCopyData(leaf) as Data
        return fingerprint(certificateDER: der)
    }

    private static func extract(certificateDER: Data) -> Data? {
        guard let outer = readTLV(certificateDER, offset: 0), outer.tag == 0x30 else { return nil }
        guard let tbs = readTLV(certificateDER, offset: outer.content.lowerBound), tbs.tag == 0x30 else {
            return nil
        }
        var cursor = tbs.content.lowerBound
        if cursor < certificateDER.count, certificateDER[cursor] & 0xE0 == 0xA0 {
            guard let version = readTLV(certificateDER, offset: cursor) else { return nil }
            cursor = version.full.upperBound
        }
        for _ in 0..<5 {
            guard let field = readTLV(certificateDER, offset: cursor) else { return nil }
            cursor = field.full.upperBound
        }
        guard let spki = readTLV(certificateDER, offset: cursor), spki.tag == 0x30 else { return nil }
        return certificateDER.subdata(in: spki.full)
    }

    private struct TLV {
        var tag: UInt8
        var full: Range<Int>
        var content: Range<Int>
    }

    private static func readTLV(_ data: Data, offset: Int) -> TLV? {
        guard offset < data.count else { return nil }
        let tag = data[offset]
        var cursor = offset + 1
        guard cursor < data.count else { return nil }
        let lengthByte = Int(data[cursor])
        cursor += 1
        let length: Int
        if lengthByte < 0x80 {
            length = lengthByte
        } else {
            let count = lengthByte & 0x7F
            guard count > 0, count <= 3, cursor + count <= data.count else { return nil }
            var value = 0
            for _ in 0..<count {
                value = (value << 8) | Int(data[cursor])
                cursor += 1
            }
            length = value
        }
        guard length >= 0, cursor + length <= data.count else { return nil }
        return TLV(tag: tag, full: offset..<(cursor + length), content: cursor..<(cursor + length))
    }
}

/// Info.plist `NSPinnedDomains` SPKI pins. An empty match set fails closed.
/// `NWConnection` does not apply ATS, so the verified-address retry checks this
/// list itself before ``CertificateValidator/validateServerTrust(_:)``.
enum AppTransportSecurityPins {
    static func matches(trust: SecTrust, host: String) -> Bool {
        let fingerprints = pins(for: host)
        guard !fingerprints.isEmpty,
              let leaf = SubjectPublicKeyInfo.leafFingerprint(trust: trust) else {
            return false
        }
        return fingerprints.contains { $0.constantTimeMatches(leaf) }
    }

    private static func pins(for host: String) -> [CertificateFingerprint] {
        guard let info = Bundle.main.infoDictionary,
              let ats = info["NSAppTransportSecurity"] as? [String: Any],
              let domains = ats["NSPinnedDomains"] as? [String: Any] else {
            return []
        }
        var matched: [CertificateFingerprint] = []
        for (domain, value) in domains {
            guard let entry = value as? [String: Any] else { continue }
            let includesSubdomains = (entry["NSIncludesSubdomains"] as? Bool) ?? false
            guard hostMatches(host, domain: domain, includesSubdomains: includesSubdomains),
                  let identities = entry["NSPinnedLeafIdentities"] as? [[String: Any]] else {
                continue
            }
            for identity in identities {
                guard let base64 = identity["SPKI-SHA256-BASE64"] as? String,
                      let bytes = Data(base64Encoded: base64),
                      bytes.count == CertificateFingerprint.byteCount else {
                    continue
                }
                matched.append(CertificateFingerprint(bytes: [UInt8](bytes)))
            }
        }
        return matched
    }

    private static func hostMatches(_ host: String, domain: String, includesSubdomains: Bool) -> Bool {
        let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let normalizedDomain = domain.lowercased()
        if normalizedHost == normalizedDomain { return true }
        return includesSubdomains && normalizedHost.hasSuffix("." + normalizedDomain)
    }
}
