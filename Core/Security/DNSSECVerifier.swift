//
//  DNSSECVerifier.swift
//  Core
//
//  Created by Jari Lammi on 30.10.2026.
//
//  Local DNSSEC verification for a positive RRset (RFC 4034 / RFC 4035).
//
//  Used only after the system validator produced zero callbacks. A delivered
//  non-Secure status never reaches this file. The AD bit is not an input.
//  Signature times use the device clock as given. ``maxAllowedTimeSkew`` and the
//  certificate transition window do not stretch an RRSIG.
//
//  Algorithms this chain uses: RSA-SHA256 (8) and ECDSA P-256 (13). An RSA
//  modulus shorter than 2048 bits verifies only when the RRSIG signer is `eu`.
//  That zone's signing key is 1024 bits and signs the `lutheranradio.eu` DS.
//  Every other signer, including the root, requires at least 2048 bits. A
//  modulus shorter than 1024 bits fails for every signer.
//
//  - SeeAlso: ``DNSSECWalk``, ``SecurityConfiguration/ianaRootTrustAnchors``,
//    ``<doc:Security-Invariants>`` Invariant 1 and Invariant 2
//

import CryptoKit
import Foundation
import Network
@unsafe @preconcurrency import Security

/// One IANA KeyDigest. Values live only in ``SecurityConfiguration``.
public struct DNSSECTrustAnchor: Sendable, Equatable {
    public var keyTag: UInt16
    public var algorithm: UInt8
    public var digestType: UInt8
    public var digest: Data
    /// Unix seconds. An anchor is ignored before this instant.
    ///
    /// This is the date the digest may be trusted. It is not the date that key
    /// took over signing the root DNSKEY set.
    public var validFrom: TimeInterval

    public init(keyTag: UInt16, algorithm: UInt8, digestType: UInt8, digest: Data, validFrom: TimeInterval) {
        self.keyTag = keyTag
        self.algorithm = algorithm
        self.digestType = digestType
        self.digest = digest
        self.validFrom = validFrom
    }
}

/// One verified address. The retry path connects only to these bytes.
public struct VerifiedSocketAddress: Sendable, Equatable, Hashable {
    public enum Family: Sendable, Equatable, Hashable {
        case v4
        case v6
    }

    public var family: Family
    public var raw: Data
    public var presentation: String
}

/// Supplies DNS wire bytes for one query. Production posts them to pinned DoH.
/// Tests return fixtures. No port-53 socket belongs behind this protocol.
protocol DNSWireFetching: Sendable {
    func response(toQuery wire: Data) async -> Data?
}

/// Outcome of a TXT lookup.
///
/// `.verified` is a TXT RRset that was present and whose signature checked.
/// The name set is empty only when that present RRset parses to no tokens.
/// A missing RRset is `.failed`. This walker does not prove absence: there is
/// no NSEC or NSEC3 check, so a missing set stays a temporary failure.
enum DNSSECVerifiedTXT: Sendable, Equatable {
    case verified(Set<String>)
    case failed
}

enum DNSSECCrypto {
    static let rsaSHA256: UInt8 = 8
    static let ecdsaP256SHA256: UInt8 = 13
    /// Absolute RSA floor, 1024 bits. Only the RRSIG signer `eu` may use a modulus this short.
    static let minimumRSAModulusBytes = 128
    /// RSA floor for every signer other than `eu`, 2048 bits.
    static let standardRSAModulusBytes = 256

    static func keyTag(_ rdata: Data) -> UInt16 {
        var accumulator: UInt32 = 0
        for (index, byte) in rdata.enumerated() {
            if index & 1 == 1 {
                accumulator += UInt32(byte)
            } else {
                accumulator += UInt32(byte) << 8
            }
        }
        accumulator += (accumulator >> 16) & 0xFFFF
        return UInt16(truncatingIfNeeded: accumulator & 0xFFFF)
    }

    static func dsDigest(owner: DNSName, dnskeyRdata: Data) -> Data {
        var material = owner.canonicalWire
        material.append(dnskeyRdata)
        return Data(SHA256.hash(data: material))
    }

    /// Canonical bytes an RRSIG signs (RFC 4034 §6). The signature itself is not included.
    static func signedMaterial(
        owner: DNSName,
        type: UInt16,
        algorithm: UInt8,
        labels: UInt8,
        originalTTL: UInt32,
        expiration: UInt32,
        inception: UInt32,
        keyTag: UInt16,
        signer: DNSName,
        rdatas: [Data]
    ) -> Data? {
        guard inception <= expiration else { return nil }
        guard let signedOwner = signedOwnerName(owner: owner, labels: labels) else { return nil }
        var prefix = Data()
        prefix.appendU16(type)
        prefix.append(algorithm)
        prefix.append(labels)
        prefix.appendU32(originalTTL)
        prefix.appendU32(expiration)
        prefix.appendU32(inception)
        prefix.appendU16(keyTag)
        prefix.append(signer.canonicalWire)
        var records: [Data] = []
        records.reserveCapacity(rdatas.count)
        for rdata in rdatas {
            guard rdata.count <= Int(UInt16.max) else { return nil }
            var record = signedOwner.canonicalWire
            record.appendU16(type)
            record.appendU16(DNSType.internet)
            record.appendU32(originalTTL)
            record.appendU16(UInt16(rdata.count))
            record.append(rdata)
            records.append(record)
        }
        records.sort { $0.lexicographicallyPrecedes($1) }
        var out = prefix
        for record in records {
            out.append(record)
        }
        return out
    }

    static func signatureIsCurrent(inception: UInt32, expiration: UInt32, now: TimeInterval) -> Bool {
        guard inception <= expiration else { return false }
        guard now >= 0, now <= Double(UInt32.max) else { return false }
        let nowSeconds = UInt32(now)
        return nowSeconds >= inception && nowSeconds <= expiration
    }

    /// Checks one DNSSEC signature.
    ///
    /// Algorithm 13 ignores `signer`. Algorithm 8 applies the modulus floors in the file header:
    /// 1024 bits only for the signer `eu`, and 2048 bits for every other signer.
    ///
    /// - Parameters:
    ///   - algorithm: DNSSEC algorithm number. 8 and 13 are the accepted values.
    ///   - publicKey: RFC 3110 RSA public key, or the raw 64-byte P-256 point.
    ///   - signature: RRSIG signature bytes.
    ///   - message: Canonical signed material (RFC 4034 §6).
    ///   - signer: RRSIG signer name. The 1024-bit RSA exception is the name `eu` alone.
    /// - Returns: `true` when the signature checks and the RSA modulus policy allows the key.
    /// - SeeAlso: ``DNSSECWalk``, ``<doc:Security-Invariants>`` Invariant 2
    static func verify(
        algorithm: UInt8,
        publicKey: Data,
        signature: Data,
        message: Data,
        signer: DNSName
    ) -> Bool {
        switch algorithm {
        case ecdsaP256SHA256:
            return verifyP256(publicKey: publicKey, signature: signature, message: message)
        case rsaSHA256:
            return verifyRSA(publicKey: publicKey, signature: signature, message: message, signer: signer)
        default:
            return false
        }
    }

    private static func signedOwnerName(owner: DNSName, labels: UInt8) -> DNSName? {
        let count = owner.labelCount
        if Int(labels) > count { return nil }
        if Int(labels) == count { return owner }
        let tail = Array(owner.labels.suffix(Int(labels)))
        return DNSName(labels: [Data("*".utf8)] + tail)
    }

    private static func verifyP256(publicKey: Data, signature: Data, message: Data) -> Bool {
        guard publicKey.count == 64, signature.count == 64 else { return false }
        var x963 = Data([0x04])
        x963.append(publicKey)
        guard let key = try? P256.Signing.PublicKey(x963Representation: x963),
              let parsed = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else {
            return false
        }
        return key.isValidSignature(parsed, for: message)
    }

    private static func verifyRSA(publicKey: Data, signature: Data, message: Data, signer: DNSName) -> Bool {
        guard let (exponent, modulus) = rfc3110(publicKey),
              rsaModulusIsAllowed(modulus, signer: signer) else {
            return false
        }
        let der = pkcs1PublicKey(modulus: modulus, exponent: exponent)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        // SAFETY: SecKeyCreateWithData borrows `der` for the call and returns a +1 key.
        // The modulus floor is 2048 bits, except the signer `eu`, which may use 1024 bits.
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) else {
            return false
        }
        // SAFETY: SecKeyVerifySignature hashes `message` with SHA-256 (PKCS#1 v1.5). DNSSEC algorithm 8 is that hash.
        return SecKeyVerifySignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            message as CFData,
            signature as CFData,
            nil
        )
    }

    /// RFC 3110 octet length. A 1024-bit modulus is 128 bytes. A 2048-bit modulus is 256 bytes.
    private static func rsaModulusIsAllowed(_ modulus: Data, signer: DNSName) -> Bool {
        if modulus.count >= standardRSAModulusBytes { return true }
        return modulus.count >= minimumRSAModulusBytes && signerAllowsShortRSA(signer)
    }

    /// The short-key exception is the zone name `eu`, not a name under that zone.
    private static func signerAllowsShortRSA(_ signer: DNSName) -> Bool {
        guard signer.labels.count == 1, let label = signer.labels.first else { return false }
        return label == Data("eu".utf8)
    }

    private static func rfc3110(_ key: Data) -> (exponent: Data, modulus: Data)? {
        guard let first = key.first else { return nil }
        let exponentLength: Int
        let exponentStart: Int
        if first == 0 {
            guard key.count >= 3 else { return nil }
            exponentLength = (Int(key[1]) << 8) | Int(key[2])
            exponentStart = 3
        } else {
            exponentLength = Int(first)
            exponentStart = 1
        }
        let modulusStart = exponentStart + exponentLength
        guard exponentLength > 0, modulusStart < key.count else { return nil }
        let exponent = key.subdata(in: exponentStart..<modulusStart)
        let modulus = key.subdata(in: modulusStart..<key.count)
        guard !modulus.isEmpty else { return nil }
        return (exponent, modulus)
    }

    private static func pkcs1PublicKey(modulus: Data, exponent: Data) -> Data {
        let body = derInteger(modulus) + derInteger(exponent)
        return derTLV(tag: 0x30, content: body)
    }

    private static func derInteger(_ bytes: Data) -> Data {
        var magnitude = bytes
        while magnitude.count > 1, magnitude.first == 0 {
            magnitude.removeFirst()
        }
        if let first = magnitude.first, first & 0x80 != 0 {
            magnitude.insert(0, at: 0)
        }
        return derTLV(tag: 0x02, content: magnitude)
    }

    private static func derTLV(tag: UInt8, content: Data) -> Data {
        var out = Data([tag])
        let length = content.count
        if length < 128 {
            out.append(UInt8(length))
        } else if length <= 0xFF {
            out.append(0x81)
            out.append(UInt8(length))
        } else {
            out.append(0x82)
            out.append(UInt8((length >> 8) & 0xFF))
            out.append(UInt8(length & 0xFF))
        }
        out.append(content)
        return out
    }
}

private struct ParsedRRSIG {
    var typeCovered: UInt16
    var algorithm: UInt8
    var labels: UInt8
    var originalTTL: UInt32
    var expiration: UInt32
    var inception: UInt32
    var keyTag: UInt16
    var signer: DNSName
    var signature: Data

    init?(record: DNSRR, message: Data) {
        let rdata = record.rdata
        guard rdata.count > 18 else { return nil }
        typeCovered = UInt16(rdata[0]) << 8 | UInt16(rdata[1])
        algorithm = rdata[2]
        labels = rdata[3]
        originalTTL = readU32(rdata, 4)
        expiration = readU32(rdata, 8)
        inception = readU32(rdata, 12)
        keyTag = UInt16(rdata[16]) << 8 | UInt16(rdata[17])
        var nameOffset = record.rdataOffset + 18
        guard nameOffset <= message.count,
              let signerName = DNSName.parse(message: message, offset: &nameOffset) else {
            return nil
        }
        let signatureStart = nameOffset - record.rdataOffset
        guard signatureStart >= 18, signatureStart <= rdata.count else { return nil }
        signature = rdata.subdata(in: signatureStart..<rdata.count)
        guard !signature.isEmpty else { return nil }
        signer = signerName
    }
}

private struct DNSKEYRecord {
    var rdata: Data
    var flags: UInt16
    var protocolNumber: UInt8
    var algorithm: UInt8
    var publicKey: Data
    var keyTag: UInt16

    var isZoneKey: Bool { (flags & 0x0100) != 0 && protocolNumber == 3 }

    init?(rdata: Data) {
        guard rdata.count >= 5 else { return nil }
        flags = UInt16(rdata[0]) << 8 | UInt16(rdata[1])
        protocolNumber = rdata[2]
        algorithm = rdata[3]
        publicKey = rdata.subdata(in: 4..<rdata.count)
        guard !publicKey.isEmpty else { return nil }
        keyTag = DNSSECCrypto.keyTag(rdata)
        self.rdata = rdata
    }
}

private func readU32(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset]) << 24
        | UInt32(data[offset + 1]) << 16
        | UInt32(data[offset + 2]) << 8
        | UInt32(data[offset + 3])
}

private enum ZoneAuthentication {
    case keys([DNSKEYRecord])
    case failed
}

private enum AddressRRset {
    case absent
    case verified([Data])
    case failed
}

/// Walks parent DS links from a name up to the configured root anchors.
///
/// The actor owns the message cache and the fetch budget. It does not store an
/// in-flight `Task` that awaits itself. A re-entrant fetch may repeat a query.
/// That costs a budget slot and does not deadlock.
actor DNSSECWalk {
    private let fetcher: any DNSWireFetching
    private let anchors: [DNSSECTrustAnchor]
    private let now: TimeInterval
    private var messages: [String: DNSMessage] = [:]
    private var zones: [String: ZoneAuthentication] = [:]
    private var fetches = 0
    private let fetchCap = 32
    private let depthCap = 8

    init(fetcher: any DNSWireFetching, anchors: [DNSSECTrustAnchor], now: Date) {
        self.fetcher = fetcher
        self.anchors = anchors
        self.now = now.timeIntervalSince1970
    }

    /// Verifies the TXT RRset at `name`.
    ///
    /// A missing RRset, a non-zero rcode, or a signature that does not verify is
    /// `.failed`. The host walk treats that as a temporary failure and tries the
    /// next host. Absence is not an authoritative empty set. A present RRset
    /// whose text parses to no names is `.verified` with an empty set.
    ///
    /// - SeeAlso: ``DNSSECVerifiedTXT``, ``<doc:Security-Invariants>`` Invariant 1
    func txtModels(name: DNSName) async -> DNSSECVerifiedTXT {
        guard let message = await fetch(name: name, type: DNSType.txt), message.rcode == 0 else {
            return .failed
        }
        let records = answers(message, name: name, type: DNSType.txt)
        // A missing RRset is not a verified empty set. No NSEC or NSEC3 proof is attempted.
        guard !records.isEmpty else { return .failed }
        let signatures = answers(message, name: name, type: DNSType.rrsig)
        guard await verifyRRset(owner: name, type: DNSType.txt, records: records, signatures: signatures, message: message) else {
            return .failed
        }
        var models = Set<String>()
        for record in records {
            models.formUnion(SecurityModelValidator.parseInlineTXTRecord(record.rdata))
        }
        return .verified(models)
    }

    func addresses(for name: DNSName) async -> [VerifiedSocketAddress] {
        let ipv4 = await addressRRset(name: name, type: DNSType.a)
        let ipv6 = await addressRRset(name: name, type: DNSType.aaaa)
        if case .failed = ipv4 { return [] }
        if case .failed = ipv6 { return [] }
        var found: [VerifiedSocketAddress] = []
        if case .verified(let rdatas) = ipv4 {
            found.append(contentsOf: rdatas.compactMap(Self.address(ipv4:)))
        }
        if case .verified(let rdatas) = ipv6 {
            found.append(contentsOf: rdatas.compactMap(Self.address(ipv6:)))
        }
        var unique: [VerifiedSocketAddress] = []
        for address in found where !unique.contains(address) {
            unique.append(address)
        }
        return unique
    }

    private func addressRRset(name: DNSName, type: UInt16) async -> AddressRRset {
        guard let message = await fetch(name: name, type: type) else { return .failed }
        if message.rcode == 3 { return .absent }
        guard message.rcode == 0 else { return .failed }
        let records = answers(message, name: name, type: type)
        if records.isEmpty { return .absent }
        let signatures = answers(message, name: name, type: DNSType.rrsig)
        guard await verifyRRset(owner: name, type: type, records: records, signatures: signatures, message: message) else {
            return .failed
        }
        return .verified(records.map(\.rdata))
    }

    private func verifyRRset(
        owner: DNSName,
        type: UInt16,
        records: [DNSRR],
        signatures: [DNSRR],
        message: DNSMessage
    ) async -> Bool {
        for signature in signatures {
            guard let parsed = ParsedRRSIG(record: signature, message: message.raw),
                  parsed.typeCovered == type,
                  DNSSECCrypto.signatureIsCurrent(inception: parsed.inception, expiration: parsed.expiration, now: now),
                  owner.isInZone(parsed.signer),
                  let keys = await authenticate(zone: parsed.signer, depth: 0),
                  let key = keys.first(where: { $0.keyTag == parsed.keyTag && $0.algorithm == parsed.algorithm }),
                  let material = DNSSECCrypto.signedMaterial(
                    owner: owner,
                    type: type,
                    algorithm: parsed.algorithm,
                    labels: parsed.labels,
                    originalTTL: parsed.originalTTL,
                    expiration: parsed.expiration,
                    inception: parsed.inception,
                    keyTag: parsed.keyTag,
                    signer: parsed.signer,
                    rdatas: records.map(\.rdata)
                  ),
                  DNSSECCrypto.verify(
                    algorithm: key.algorithm,
                    publicKey: key.publicKey,
                    signature: parsed.signature,
                    message: material,
                    signer: parsed.signer
                  ) else {
                continue
            }
            return true
        }
        return false
    }

    private func authenticate(zone: DNSName, depth: Int) async -> [DNSKEYRecord]? {
        if depth > depthCap { return nil }
        let cacheKey = zone.presentation
        if let cached = zones[cacheKey] {
            if case .keys(let keys) = cached { return keys }
            return nil
        }
        guard let message = await fetch(name: zone, type: DNSType.dnskey), message.rcode == 0 else {
            zones[cacheKey] = .failed
            return nil
        }
        let records = answers(message, name: zone, type: DNSType.dnskey)
        let parsed = records.compactMap { DNSKEYRecord(rdata: $0.rdata) }
        let zoneKeys = parsed.filter(\.isZoneKey)
        guard !zoneKeys.isEmpty else {
            zones[cacheKey] = .failed
            return nil
        }
        let trusted: [DNSKEYRecord]
        if zone.isRoot {
            trusted = zoneKeys.filter { matchesAnchor($0, zone: zone) }
        } else {
            guard let parent = zone.parent(),
                  let parentKeys = await authenticate(zone: parent, depth: depth + 1),
                  let dsMessage = await fetch(name: zone, type: DNSType.ds),
                  dsMessage.rcode == 0 else {
                zones[cacheKey] = .failed
                return nil
            }
            let dsRecords = answers(dsMessage, name: zone, type: DNSType.ds)
            guard !dsRecords.isEmpty,
                  verifyWithKeys(
                    owner: zone,
                    type: DNSType.ds,
                    records: dsRecords,
                    signatures: answers(dsMessage, name: zone, type: DNSType.rrsig),
                    message: dsMessage,
                    keys: parentKeys,
                    requiredSigner: parent
                  ) else {
                zones[cacheKey] = .failed
                return nil
            }
            trusted = zoneKeys.filter { key in
                dsRecords.contains { dsMatches($0.rdata, key: key, owner: zone) }
            }
        }
        guard !trusted.isEmpty,
              verifyWithKeys(
                owner: zone,
                type: DNSType.dnskey,
                records: records,
                signatures: answers(message, name: zone, type: DNSType.rrsig),
                message: message,
                keys: trusted,
                requiredSigner: zone
              ) else {
            zones[cacheKey] = .failed
            return nil
        }
        zones[cacheKey] = .keys(zoneKeys)
        return zoneKeys
    }

    private func verifyWithKeys(
        owner: DNSName,
        type: UInt16,
        records: [DNSRR],
        signatures: [DNSRR],
        message: DNSMessage,
        keys: [DNSKEYRecord],
        requiredSigner: DNSName
    ) -> Bool {
        let rdatas = records.map(\.rdata)
        for signature in signatures {
            guard let parsed = ParsedRRSIG(record: signature, message: message.raw),
                  parsed.typeCovered == type,
                  parsed.signer == requiredSigner,
                  DNSSECCrypto.signatureIsCurrent(inception: parsed.inception, expiration: parsed.expiration, now: now),
                  let key = keys.first(where: { $0.keyTag == parsed.keyTag && $0.algorithm == parsed.algorithm && $0.isZoneKey }),
                  let material = DNSSECCrypto.signedMaterial(
                    owner: owner,
                    type: type,
                    algorithm: parsed.algorithm,
                    labels: parsed.labels,
                    originalTTL: parsed.originalTTL,
                    expiration: parsed.expiration,
                    inception: parsed.inception,
                    keyTag: parsed.keyTag,
                    signer: parsed.signer,
                    rdatas: rdatas
                  ) else {
                continue
            }
            if DNSSECCrypto.verify(
                algorithm: key.algorithm,
                publicKey: key.publicKey,
                signature: parsed.signature,
                message: material,
                signer: parsed.signer
            ) {
                return true
            }
        }
        return false
    }

    private func matchesAnchor(_ key: DNSKEYRecord, zone: DNSName) -> Bool {
        let digest = DNSSECCrypto.dsDigest(owner: zone, dnskeyRdata: key.rdata)
        guard digest.count == 32 else { return false }
        // ``CertificateFingerprint/init(bytes:)`` preconditions on 32 bytes. The count check is the guard.
        let actual = CertificateFingerprint(bytes: [UInt8](digest))
        for anchor in anchors {
            guard anchor.digestType == 2,
                  anchor.digest.count == 32,
                  anchor.algorithm == key.algorithm,
                  anchor.keyTag == key.keyTag,
                  now >= anchor.validFrom else {
                continue
            }
            let expected = CertificateFingerprint(bytes: [UInt8](anchor.digest))
            if actual.constantTimeMatches(expected) {
                return true
            }
        }
        return false
    }

    private func dsMatches(_ rdata: Data, key: DNSKEYRecord, owner: DNSName) -> Bool {
        guard rdata.count == 36 else { return false }
        let tag = UInt16(rdata[0]) << 8 | UInt16(rdata[1])
        let algorithm = rdata[2]
        let digestType = rdata[3]
        guard digestType == 2, tag == key.keyTag, algorithm == key.algorithm else { return false }
        let published = rdata.subdata(in: 4..<36)
        let computed = DNSSECCrypto.dsDigest(owner: owner, dnskeyRdata: key.rdata)
        guard computed.count == 32 else { return false }
        let left = CertificateFingerprint(bytes: [UInt8](computed))
        let right = CertificateFingerprint(bytes: [UInt8](published))
        return left.constantTimeMatches(right)
    }

    private func fetch(name: DNSName, type: UInt16) async -> DNSMessage? {
        let key = "\(name.presentation)|\(type)"
        if let cached = messages[key] { return cached }
        guard fetches < fetchCap else { return nil }
        fetches += 1
        let id = UInt16.random(in: UInt16.min...UInt16.max)
        let query = DNSMessage.query(id: id, name: name, type: type)
        guard let bytes = await fetcher.response(toQuery: query),
              let message = DNSMessage.parse(bytes),
              message.isResponse,
              message.id == id,
              !message.truncated,
              message.rcode == 0 || message.rcode == 3 else {
            return nil
        }
        messages[key] = message
        return message
    }

    private func answers(_ message: DNSMessage, name: DNSName, type: UInt16) -> [DNSRR] {
        message.answers.filter { $0.name == name && $0.type == type && $0.klass == DNSType.internet }
    }

    private static func address(ipv4 rdata: Data) -> VerifiedSocketAddress? {
        guard rdata.count == 4 else { return nil }
        let presentation = rdata.map(String.init).joined(separator: ".")
        guard IPv4Address(presentation) != nil else { return nil }
        return VerifiedSocketAddress(family: .v4, raw: rdata, presentation: presentation)
    }

    private static func address(ipv6 rdata: Data) -> VerifiedSocketAddress? {
        guard rdata.count == 16 else { return nil }
        var parts: [String] = []
        parts.reserveCapacity(8)
        var index = 0
        while index < 16 {
            let value = UInt16(rdata[index]) << 8 | UInt16(rdata[index + 1])
            parts.append(String(value, radix: 16))
            index += 2
        }
        let presentation = parts.joined(separator: ":")
        guard IPv6Address(presentation) != nil else { return nil }
        return VerifiedSocketAddress(family: .v6, raw: rdata, presentation: presentation)
    }
}

/// Address entry used by the streaming retry. TXT verification stays on ``SecurityModelValidator``.
public enum DNSSECLocalVerification {
    /// A and AAAA addresses whose RRsets verified under the root anchors.
    ///
    /// Empty when the name is malformed, either present RRset fails, or no
    /// address survived. A verified A with AAAA absent is success. `-UITestMode`
    /// returns empty and does not open DoH.
    ///
    /// - Parameter host: Hostname, without a port.
    /// - Returns: Verified addresses in encounter order.
    /// - SeeAlso: ``ProtectedHostHTTPS``, ``<doc:Security-Invariants>`` Invariant 2
    public static func verifiedAddresses(forHost host: String) async -> [VerifiedSocketAddress] {
        if ProcessInfo.processInfo.arguments.contains("-UITestMode") {
            return []
        }
        guard let name = DNSName(presentation: host) else { return [] }
        let walk = DNSSECWalk(
            fetcher: PinnedDoHFetcher(),
            anchors: SecurityConfiguration.current.ianaRootTrustAnchors,
            now: Date()
        )
        return await walk.addresses(for: name)
    }
}
