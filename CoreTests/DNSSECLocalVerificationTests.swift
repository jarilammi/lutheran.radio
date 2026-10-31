//
//  DNSSECLocalVerificationTests.swift
//  CoreTests
//
//  Created by Jari Lammi on 30.10.2026.
//
//  Fixture chains only. No sockets, no DoH, no live DNS.
//  The chain is signed with the same canonical bytes ``DNSSECCrypto/signedMaterial`` verifies.
//  Bad signature, expired RRSIG, and a wrong trust anchor must still fail.
//
//  - SeeAlso: ``DNSSECWalk``, ``<doc:Security-Invariants>`` Invariant 1
//

import CryptoKit
import Foundation
import Synchronization
import Testing
@unsafe @preconcurrency import Security
@testable import Core

final class MappedDNSFetcher: DNSWireFetching, @unchecked Sendable {
    let responses: [String: Data]
    let queries = Mutex<[String]>([])

    init(responses: [String: Data]) {
        self.responses = responses
    }

    func response(toQuery wire: Data) async -> Data? {
        guard let message = DNSMessage.parse(wire), let question = message.questions.first else { return nil }
        let key = "\(question.name.presentation)|\(question.type)"
        queries.withLock { $0.append(key) }
        guard var body = responses[key], body.count >= 2 else { return nil }
        body[0] = UInt8(message.id >> 8)
        body[1] = UInt8(message.id & 0xFF)
        return body
    }
}

enum DNSSECFixtureBuilder {
    static let inception: UInt32 = 1_700_000_000
    static let expiration: UInt32 = 1_800_000_000
    static let ttl: UInt32 = 300
    static let now = Date(timeIntervalSince1970: 1_750_000_000)

    struct Built: Sendable {
        var anchors: [DNSSECTrustAnchor]
        var fetcher: MappedDNSFetcher
    }

    struct ZoneKey {
        var name: DNSName
        var privateKey: P256.Signing.PrivateKey
        var dnskey: Data
        var tag: UInt16
    }

    static func allowList(txt: String, corruptTXT: Bool = false, omitTXTRecords: Bool = false) throws -> Built {
        let root = try zoneKey(name: .root)
        let net = try zoneKey(name: try name("net"))
        let apex = try zoneKey(name: try name("siikkari.net"))
        let txtName = try name("securitymodels.siikkari.net")
        var responses: [String: Data] = [:]
        responses[key(root.name, DNSType.dnskey)] = try signedMessage(
            owner: root.name,
            type: DNSType.dnskey,
            rdata: root.dnskey,
            signer: root,
            corrupt: false
        )
        responses[key(net.name, DNSType.ds)] = try signedMessage(
            owner: net.name,
            type: DNSType.ds,
            rdata: dsRecord(child: net),
            signer: root,
            corrupt: false
        )
        responses[key(net.name, DNSType.dnskey)] = try signedMessage(
            owner: net.name,
            type: DNSType.dnskey,
            rdata: net.dnskey,
            signer: net,
            corrupt: false
        )
        responses[key(apex.name, DNSType.ds)] = try signedMessage(
            owner: apex.name,
            type: DNSType.ds,
            rdata: dsRecord(child: apex),
            signer: net,
            corrupt: false
        )
        responses[key(apex.name, DNSType.dnskey)] = try signedMessage(
            owner: apex.name,
            type: DNSType.dnskey,
            rdata: apex.dnskey,
            signer: apex,
            corrupt: false
        )
        if omitTXTRecords {
            // NOERROR with no TXT records. Absence is not a verified empty set.
            responses[key(txtName, DNSType.txt)] = emptyAnswer(owner: txtName, type: DNSType.txt)
        } else {
            responses[key(txtName, DNSType.txt)] = try signedMessage(
                owner: txtName,
                type: DNSType.txt,
                rdata: txtRdata(txt),
                signer: apex,
                corrupt: corruptTXT
            )
        }
        return Built(anchors: [anchor(for: root)], fetcher: MappedDNSFetcher(responses: responses))
    }

    static func addressFixture(corruptAAAA: Bool = false) throws -> (Built, DNSName) {
        let root = try zoneKey(name: .root)
        let apex = try zoneKey(name: try name("example"))
        let host = try name("www.example")
        let address = Data([203, 0, 113, 10])
        var responses: [String: Data] = [:]
        responses[key(root.name, DNSType.dnskey)] = try signedMessage(
            owner: root.name, type: DNSType.dnskey, rdata: root.dnskey, signer: root, corrupt: false
        )
        responses[key(apex.name, DNSType.ds)] = try signedMessage(
            owner: apex.name, type: DNSType.ds, rdata: dsRecord(child: apex), signer: root, corrupt: false
        )
        responses[key(apex.name, DNSType.dnskey)] = try signedMessage(
            owner: apex.name, type: DNSType.dnskey, rdata: apex.dnskey, signer: apex, corrupt: false
        )
        responses[key(host, DNSType.a)] = try signedMessage(
            owner: host, type: DNSType.a, rdata: address, signer: apex, corrupt: false
        )
        responses[key(host, DNSType.aaaa)] = emptyAnswer(owner: host, type: DNSType.aaaa)
        if corruptAAAA {
            responses[key(host, DNSType.aaaa)] = try signedMessage(
                owner: host,
                type: DNSType.aaaa,
                rdata: Data(repeating: 0, count: 16),
                signer: apex,
                corrupt: true
            )
        }
        return (Built(anchors: [anchor(for: root)], fetcher: MappedDNSFetcher(responses: responses)), host)
    }

    private static func zoneKey(name: DNSName) throws -> ZoneKey {
        let privateKey = P256.Signing.PrivateKey()
        let x963 = privateKey.publicKey.x963Representation
        let xy = x963.dropFirst()
        var rdata = Data()
        rdata.appendU16(0x0101)
        rdata.append(3)
        rdata.append(13)
        rdata.append(xy)
        return ZoneKey(name: name, privateKey: privateKey, dnskey: rdata, tag: DNSSECCrypto.keyTag(rdata))
    }

    private static func anchor(for zone: ZoneKey) -> DNSSECTrustAnchor {
        DNSSECTrustAnchor(
            keyTag: zone.tag,
            algorithm: 13,
            digestType: 2,
            digest: DNSSECCrypto.dsDigest(owner: zone.name, dnskeyRdata: zone.dnskey),
            validFrom: 0
        )
    }

    private static func dsRecord(child: ZoneKey) -> Data {
        var data = Data()
        data.appendU16(child.tag)
        data.append(13)
        data.append(2)
        data.append(DNSSECCrypto.dsDigest(owner: child.name, dnskeyRdata: child.dnskey))
        return data
    }

    private static func signedMessage(
        owner: DNSName,
        type: UInt16,
        rdata: Data,
        signer: ZoneKey,
        corrupt: Bool
    ) throws -> Data {
        let labels = UInt8(owner.labelCount)
        guard let material = DNSSECCrypto.signedMaterial(
            owner: owner,
            type: type,
            algorithm: 13,
            labels: labels,
            originalTTL: ttl,
            expiration: expiration,
            inception: inception,
            keyTag: signer.tag,
            signer: signer.name,
            rdatas: [rdata]
        ) else {
            throw FixtureError.material
        }
        var signature = try signer.privateKey.signature(for: material).rawRepresentation
        if corrupt, !signature.isEmpty {
            signature[signature.index(before: signature.endIndex)] ^= 0xFF
        }
        var rrsig = Data()
        rrsig.appendU16(type)
        rrsig.append(13)
        rrsig.append(labels)
        rrsig.appendU32(ttl)
        rrsig.appendU32(expiration)
        rrsig.appendU32(inception)
        rrsig.appendU16(signer.tag)
        rrsig.append(signer.name.canonicalWire)
        rrsig.append(signature)
        let question = DNSQuestion(name: owner, type: type, klass: DNSType.internet)
        let record = DNSRR(name: owner, type: type, klass: DNSType.internet, ttl: ttl, rdata: rdata)
        let signatureRR = DNSRR(name: owner, type: DNSType.rrsig, klass: DNSType.internet, ttl: ttl, rdata: rrsig)
        return DNSMessage.response(id: 0, rcode: 0, question: question, answers: [record, signatureRR])
    }

    private static func emptyAnswer(owner: DNSName, type: UInt16) -> Data {
        let question = DNSQuestion(name: owner, type: type, klass: DNSType.internet)
        return DNSMessage.response(id: 0, rcode: 0, question: question, answers: [])
    }

    private static func txtRdata(_ text: String) -> Data {
        let bytes = Data(text.utf8)
        var data = Data([UInt8(bytes.count)])
        data.append(bytes)
        return data
    }

    private static func name(_ presentation: String) throws -> DNSName {
        guard let parsed = DNSName(presentation: presentation) else { throw FixtureError.material }
        return parsed
    }

    private static func key(_ name: DNSName, _ type: UInt16) -> String {
        "\(name.presentation)|\(type)"
    }

    private enum FixtureError: Error {
        case material
    }
}

@Suite("Local DNSSEC verification")
struct DNSSECLocalVerificationTests {
    @Test("A verified TXT set is authoritative")
    func verifiedTXT() async throws {
        let built = try DNSSECFixtureBuilder.allowList(txt: "dallas,montereypark,kailuakona")
        let walk = DNSSECWalk(
            fetcher: built.fetcher,
            anchors: built.anchors,
            now: DNSSECFixtureBuilder.now
        )
        let name = try #require(DNSName(presentation: "securitymodels.siikkari.net"))
        let outcome = await walk.txtModels(name: name)
        #expect(outcome == .verified(["dallas", "montereypark", "kailuakona"]))
    }

    /// A missing TXT RRset stays ``DNSSECVerifiedTXT/failed``. The host walk treats
    /// that as a temporary failure. This walker does not prove absence, so the
    /// outcome is not ``DNSSECVerifiedTXT/verified`` of an empty set.
    ///
    /// - SeeAlso: ``DNSSECWalk/txtModels(name:)``, ``<doc:Security-Invariants>`` Invariant 1
    @Test("A missing TXT RRset is not a verified empty set")
    func missingTXTIsNotVerifiedEmpty() async throws {
        let built = try DNSSECFixtureBuilder.allowList(txt: "kailuakona", omitTXTRecords: true)
        let walk = DNSSECWalk(fetcher: built.fetcher, anchors: built.anchors, now: DNSSECFixtureBuilder.now)
        let name = try #require(DNSName(presentation: "securitymodels.siikkari.net"))
        #expect(await walk.txtModels(name: name) == .failed)
    }

    @Test("A bad signature is not a verified set")
    func badSignatureFails() async throws {
        let built = try DNSSECFixtureBuilder.allowList(txt: "kailuakona", corruptTXT: true)
        let walk = DNSSECWalk(fetcher: built.fetcher, anchors: built.anchors, now: DNSSECFixtureBuilder.now)
        let name = try #require(DNSName(presentation: "securitymodels.siikkari.net"))
        let outcome = await walk.txtModels(name: name)
        #expect(outcome == .failed)
    }

    @Test("An expired RRSIG is not a verified set")
    func expiredSignatureFails() async throws {
        let built = try DNSSECFixtureBuilder.allowList(txt: "kailuakona")
        let walk = DNSSECWalk(
            fetcher: built.fetcher,
            anchors: built.anchors,
            now: Date(timeIntervalSince1970: 1_800_000_001)
        )
        let name = try #require(DNSName(presentation: "securitymodels.siikkari.net"))
        #expect(await walk.txtModels(name: name) == .failed)
    }

    @Test("The wrong trust anchor is not a verified set")
    func wrongAnchorFails() async throws {
        let built = try DNSSECFixtureBuilder.allowList(txt: "kailuakona")
        var digest = Data(built.anchors[0].digest)
        digest[0] ^= 0xFF
        let wrong = DNSSECTrustAnchor(
            keyTag: built.anchors[0].keyTag,
            algorithm: built.anchors[0].algorithm,
            digestType: 2,
            digest: digest,
            validFrom: 0
        )
        let walk = DNSSECWalk(fetcher: built.fetcher, anchors: [wrong], now: DNSSECFixtureBuilder.now)
        let name = try #require(DNSName(presentation: "securitymodels.siikkari.net"))
        #expect(await walk.txtModels(name: name) == .failed)
    }

    @Test("A verified A record with AAAA absent is an address")
    func verifiedAWithoutAAAA() async throws {
        let (built, host) = try DNSSECFixtureBuilder.addressFixture()
        let walk = DNSSECWalk(fetcher: built.fetcher, anchors: built.anchors, now: DNSSECFixtureBuilder.now)
        let addresses = await walk.addresses(for: host)
        #expect(addresses.count == 1)
        #expect(addresses.first?.presentation == "203.0.113.10")
    }

    @Test("A failed AAAA RRset drops the whole address set")
    func failedAAAADropsAddresses() async throws {
        let (built, host) = try DNSSECFixtureBuilder.addressFixture(corruptAAAA: true)
        let walk = DNSSECWalk(fetcher: built.fetcher, anchors: built.anchors, now: DNSSECFixtureBuilder.now)
        #expect(await walk.addresses(for: host) == [])
    }

    /// A 1024-bit RSA modulus verifies only when the RRSIG signer is `eu`.
    /// That zone-signing key signs the `lutheranradio.eu` DS. The root and any
    /// other name require 2048 bits. A modulus under 1024 bits fails for every signer.
    ///
    /// - SeeAlso: ``DNSSECCrypto/verify(algorithm:publicKey:signature:message:signer:)``,
    ///   ``<doc:Security-Invariants>`` Invariant 2
    @Test("RSA-SHA256 verifies a 1024-bit key only for the eu signer")
    func rsaRoundTrip() throws {
        let message = Data("lutheran-radio-dnssec".utf8)
        let eu = try #require(DNSName(presentation: "eu"))
        let root = DNSName.root
        let child = try #require(DNSName(presentation: "lutheranradio.eu"))
        let narrow = try Self.rsaKey(bits: 1024)
        let narrowSignature = try narrow.signature(for: message)
        #expect(DNSSECCrypto.verify(
            algorithm: 8, publicKey: narrow.publicKey, signature: narrowSignature, message: message, signer: eu
        ))
        #expect(DNSSECCrypto.verify(
            algorithm: 8, publicKey: narrow.publicKey, signature: narrowSignature, message: message, signer: root
        ) == false)
        #expect(DNSSECCrypto.verify(
            algorithm: 8, publicKey: narrow.publicKey, signature: narrowSignature, message: message, signer: child
        ) == false)
        var broken = narrowSignature
        broken[0] ^= 0xFF
        #expect(DNSSECCrypto.verify(
            algorithm: 8, publicKey: narrow.publicKey, signature: broken, message: message, signer: eu
        ) == false)
        var short = Data([1, 0x01])
        short.append(Data(repeating: 0x11, count: 64))
        #expect(DNSSECCrypto.verify(
            algorithm: 8, publicKey: short, signature: narrowSignature, message: message, signer: eu
        ) == false)
        #expect(DNSSECCrypto.verify(
            algorithm: 8, publicKey: short, signature: narrowSignature, message: message, signer: root
        ) == false)
        let wide = try Self.rsaKey(bits: 2048)
        let wideSignature = try wide.signature(for: message)
        #expect(DNSSECCrypto.verify(
            algorithm: 8, publicKey: wide.publicKey, signature: wideSignature, message: message, signer: root
        ))
        #expect(DNSSECCrypto.verify(
            algorithm: 8, publicKey: wide.publicKey, signature: wideSignature, message: message, signer: eu
        ))
    }

    /// Order is KSK-2017 (20326), then KSK-2024 (38696). The timestamps are
    /// `validFrom`, not the 11 October 2026 signing change.
    ///
    /// - SeeAlso: ``SecurityConfiguration/ianaRootTrustAnchors``
    @Test("The embedded root anchors are the two current KeyDigests")
    func embeddedAnchors() {
        let anchors = SecurityConfiguration.current.ianaRootTrustAnchors
        #expect(anchors.map(\.keyTag) == [20326, 38696])
        #expect(anchors.allSatisfy { $0.algorithm == 8 && $0.digestType == 2 && $0.digest.count == 32 })
        #expect(anchors[0].validFrom == 1_485_993_600)
        #expect(anchors[1].validFrom == 1_721_260_800)
        let resolvers = SecurityConfiguration.current.pinnedDoHResolvers
        #expect(resolvers.map(\.host) == ["cloudflare-dns.com", "dns.google"])
    }

    private struct RSAKey {
        var publicKey: Data
        var privateKey: SecKey

        func signature(for message: Data) throws -> Data {
            try #require(
                SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, nil) as Data?
            )
        }
    }

    private static func rsaKey(bits: Int) throws -> RSAKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: bits,
        ]
        var error: Unmanaged<CFError>?
        // SAFETY: `&error` is an unsafe pointer to Unmanaged. The key is +1 and stays in this function.
        let privateKey = try #require(unsafe SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let pkcs1 = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        return RSAKey(publicKey: try #require(rfc3110PublicKey(pkcs1: pkcs1)), privateKey: privateKey)
    }

    private static func rfc3110PublicKey(pkcs1: Data) -> Data? {
        guard pkcs1.first == 0x30, pkcs1.count > 2 else { return nil }
        var offset = 2
        if pkcs1[1] & 0x80 != 0 {
            offset = 2 + Int(pkcs1[1] & 0x7F)
        }
        guard let modulus = derInteger(pkcs1, offset: &offset),
              let exponent = derInteger(pkcs1, offset: &offset) else {
            return nil
        }
        var body = Data()
        if exponent.count < 256 {
            body.append(UInt8(exponent.count))
        } else {
            body.append(0)
            body.append(UInt8((exponent.count >> 8) & 0xFF))
            body.append(UInt8(exponent.count & 0xFF))
        }
        body.append(exponent)
        body.append(modulus)
        return body
    }

    private static func derInteger(_ data: Data, offset: inout Int) -> Data? {
        guard offset < data.count, data[offset] == 0x02 else { return nil }
        offset += 1
        guard offset < data.count else { return nil }
        var length = Int(data[offset])
        offset += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            length = 0
            guard offset + count <= data.count else { return nil }
            for _ in 0..<count {
                length = (length << 8) | Int(data[offset])
                offset += 1
            }
        }
        guard offset + length <= data.count else { return nil }
        var bytes = data.subdata(in: offset..<(offset + length))
        offset += length
        if bytes.first == 0 { bytes.removeFirst() }
        return bytes
    }
}
