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
//  DoH pins and ``SecurityConfiguration/pinnedMediaLeafSPKISHA256Base64`` both
//  use this hash. They are not the media leaf DER pin, and they are not each other.
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

/// Media leaf SPKI check for a host under ``SecurityConfiguration/preferredStreamingDomainSuffixes``.
///
/// The pin is ``SecurityConfiguration/pinnedMediaLeafSPKISHA256Base64``. This
/// type does not read `Bundle.main`. The app `Info.plist` keeps the same bytes
/// so ATS can enforce them on URLSession. The widget bundle has no
/// `NSPinnedDomains`. An empty or undecodable pin set fails closed.
///
/// `NWConnection` does not apply ATS, so
/// ``CertificateValidator/validateStreamingServerTrust(_:host:)`` calls this
/// before ``CertificateValidator/validateServerTrust(_:)``.
///
/// - SeeAlso: ``SecurityConfiguration/pinnedMediaLeafSPKISHA256Base64``,
///   ``<doc:Security-Invariants>`` Invariant 2
enum AppTransportSecurityPins {
    /// Leaf SPKI matches the media pin for a protected streaming host.
    ///
    /// - Parameters:
    ///   - trust: Trust whose leaf certificate supplies the SPKI.
    ///   - host: TLS peer name. A trailing dot is ignored. An empty name fails closed.
    /// - Returns: `true` only when the leaf SPKI equals ``SecurityConfiguration/pinnedMediaLeafSPKISHA256Base64``
    ///   and `host` is under ``SecurityConfiguration/preferredStreamingDomainSuffixes``.
    /// - SeeAlso: ``SecurityConfiguration/pinnedMediaLeafSPKISHA256Base64``,
    ///   ``CertificateValidator/validateStreamingServerTrust(_:host:)``
    static func matches(trust: SecTrust, host: String) -> Bool {
        matches(
            trust: trust,
            host: host,
            mediaSPKISHA256Base64: SecurityConfiguration.current.pinnedMediaLeafSPKISHA256Base64
        )
    }

    /// Same check with an explicit pin string.
    ///
    /// Production passes ``SecurityConfiguration/pinnedMediaLeafSPKISHA256Base64``.
    /// An empty string, or base64 that is not 32 bytes, is an empty set and
    /// returns `false`. This method does not read `Bundle.main`.
    ///
    /// - Parameters:
    ///   - trust: Trust whose leaf certificate supplies the SPKI.
    ///   - host: TLS peer name.
    ///   - mediaSPKISHA256Base64: Pin to compare. Not a DoH resolver pin.
    /// - Returns: `true` only when the leaf SPKI matches that pin for a protected streaming host.
    static func matches(trust: SecTrust, host: String, mediaSPKISHA256Base64: String) -> Bool {
        let fingerprints = pins(for: host, mediaSPKISHA256Base64: mediaSPKISHA256Base64)
        guard !fingerprints.isEmpty,
              let leaf = SubjectPublicKeyInfo.leafFingerprint(trust: trust) else {
            return false
        }
        return fingerprints.contains { $0.constantTimeMatches(leaf) }
    }

    /// Pin set for `host`. Empty unless `host` is a protected streaming host and
    /// the pin decodes to 32 bytes.
    private static func pins(for host: String, mediaSPKISHA256Base64: String) -> [CertificateFingerprint] {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard SecurityConfiguration.current.isProtectedStreamingHost(normalized) else {
            return []
        }
        guard let bytes = Data(base64Encoded: mediaSPKISHA256Base64),
              bytes.count == CertificateFingerprint.byteCount else {
            return []
        }
        return [CertificateFingerprint(bytes: [UInt8](bytes))]
    }
}
