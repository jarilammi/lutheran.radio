//
//  DNSSECLocalVerificationTests.swift
//  CoreTests
//
//  Created by Jari Lammi on 30.10.2026.
//
//  Fixture chains only. No sockets, no DoH, no live DNS.
//  The chain is signed with the same canonical bytes ``DNSSECCrypto/signedMaterial`` verifies.
//  Bad signature, expired RRSIG, and a wrong trust anchor must still fail.
//  A self-signed revoked root DNSKEY suppresses that anchor's digest.
//  P-256 fixtures are not the IANA 20326 or 38696 key bytes.
//  One chain uses RSA-SHA256 at the root and a 1024-bit key only for the signer `eu`.
//  Two zone keys that share a key tag are both tried. A signature from a key
//  that is not in that list still fails. A colliding tag does not let another
//  anchor retire a root digest.
//  Resolver-walk fixtures use two local fetchers. They do not open DoH.
//
//  - SeeAlso: ``DNSSECWalk``, ``DNSSECResolverWalk``, ``RetiredRootAnchorStore``, ``<doc:Security-Invariants>`` Invariant 1
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
        let responses = try allowListResponses(
            root: root, net: net, apex: apex, txtName: txtName,
            txt: txt, corruptTXT: corruptTXT, omitTXTRecords: omitTXTRecords
        )
        return Built(anchors: [anchor(for: root)], fetcher: MappedDNSFetcher(responses: responses))
    }

    /// Two fetchers over one key set. A resolver-walk test can fail the first chain
    /// without giving the second fetcher a different trust anchor.
    static func pairedAllowLists(
        firstTXT: String,
        secondTXT: String,
        corruptFirstTXT: Bool = false,
        omitFirstTXT: Bool = false
    ) throws -> (anchors: [DNSSECTrustAnchor], first: MappedDNSFetcher, second: MappedDNSFetcher) {
        let root = try zoneKey(name: .root)
        let net = try zoneKey(name: try name("net"))
        let apex = try zoneKey(name: try name("siikkari.net"))
        let txtName = try name("securitymodels.siikkari.net")
        let first = try allowListResponses(
            root: root, net: net, apex: apex, txtName: txtName,
            txt: firstTXT, corruptTXT: corruptFirstTXT, omitTXTRecords: omitFirstTXT
        )
        let second = try allowListResponses(
            root: root, net: net, apex: apex, txtName: txtName,
            txt: secondTXT, corruptTXT: false, omitTXTRecords: false
        )
        return ([anchor(for: root)], MappedDNSFetcher(responses: first), MappedDNSFetcher(responses: second))
    }

    static func addressFixture(corruptAAAA: Bool = false, address: Data = Data([203, 0, 113, 10])) throws -> (Built, DNSName) {
        let root = try zoneKey(name: .root)
        let apex = try zoneKey(name: try name("example"))
        let host = try name("www.example")
        let responses = try addressResponses(root: root, apex: apex, host: host, address: address, corruptAAAA: corruptAAAA)
        return (Built(anchors: [anchor(for: root)], fetcher: MappedDNSFetcher(responses: responses)), host)
    }

    /// Two address fetchers over one key set. `secondAddress` is the A rdata the later walk would return.
    static func pairedAddressFixtures(
        firstCorruptAAAA: Bool,
        secondAddress: Data
    ) throws -> (anchors: [DNSSECTrustAnchor], host: DNSName, first: MappedDNSFetcher, second: MappedDNSFetcher) {
        let root = try zoneKey(name: .root)
        let apex = try zoneKey(name: try name("example"))
        let host = try name("www.example")
        let first = try addressResponses(
            root: root, apex: apex, host: host, address: Data([203, 0, 113, 10]), corruptAAAA: firstCorruptAAAA
        )
        let second = try addressResponses(
            root: root, apex: apex, host: host, address: secondAddress, corruptAAAA: false
        )
        return ([anchor(for: root)], host, MappedDNSFetcher(responses: first), MappedDNSFetcher(responses: second))
    }

    /// RSA-SHA256 root, 1024-bit `eu` signer, P-256 `lutheranradio.eu` child.
    ///
    /// The 1024-bit key signs the child DS. `rootBits` of 1024 builds a root the
    /// modulus floor must reject. `corruptEUDS` flips the `eu` DS signature.
    /// The fixture does not open DoH.
    static func rsaAllowList(txt: String, corruptEUDS: Bool = false, rootBits: Int = 2048) throws -> (Built, DNSName) {
        let root = try rsaZoneKey(name: .root, bits: rootBits)
        let eu = try rsaZoneKey(name: try name("eu"), bits: 1024)
        let child = try zoneKey(name: try name("lutheranradio.eu"))
        let txtName = try name("securitymodels.lutheranradio.eu")
        var responses: [String: Data] = [:]
        responses[key(root.name, DNSType.dnskey)] = try rsaSignedMessage(
            owner: root.name, type: DNSType.dnskey, rdata: root.dnskey, signer: root, corrupt: false
        )
        responses[key(eu.name, DNSType.ds)] = try rsaSignedMessage(
            owner: eu.name, type: DNSType.ds, rdata: dsRecord(owner: eu.name, dnskey: eu.dnskey), signer: root, corrupt: false
        )
        responses[key(eu.name, DNSType.dnskey)] = try rsaSignedMessage(
            owner: eu.name, type: DNSType.dnskey, rdata: eu.dnskey, signer: eu, corrupt: false
        )
        responses[key(child.name, DNSType.ds)] = try rsaSignedMessage(
            owner: child.name, type: DNSType.ds, rdata: dsRecord(child: child), signer: eu, corrupt: corruptEUDS
        )
        responses[key(child.name, DNSType.dnskey)] = try signedMessage(
            owner: child.name, type: DNSType.dnskey, rdata: child.dnskey, signer: child, corrupt: false
        )
        responses[key(txtName, DNSType.txt)] = try signedMessage(
            owner: txtName, type: DNSType.txt, rdata: txtRdata(txt), signer: child, corrupt: false
        )
        let built = Built(anchors: [rsaAnchor(for: root)], fetcher: MappedDNSFetcher(responses: responses))
        return (built, txtName)
    }

    /// RSA material for ``rsaRoundTrip``. The chain fixture uses ``rsaZoneKey(name:bits:)``.
    struct RSASigningKey {
        var publicKey: Data
        var privateKey: SecKey

        func signature(for message: Data) throws -> Data {
            // SAFETY: SecKeyCreateSignature borrows `message` for the call. Algorithm 8 is PKCS#1 v1.5 SHA-256.
            // The error out-parameter stays nil; a nil signature is the failure.
            try #require(
                SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, nil) as Data?
            )
        }
    }

    static func rsaSigningKey(bits: Int) throws -> RSASigningKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: bits,
        ]
        var error: Unmanaged<CFError>?
        // SAFETY: `&error` is an unsafe pointer to Unmanaged. The key is +1 and stays in this value.
        let privateKey = try #require(unsafe SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let pkcs1 = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        return RSASigningKey(publicKey: try #require(rfc3110PublicKey(pkcs1: pkcs1)), privateKey: privateKey)
    }

    private static func allowListResponses(
        root: ZoneKey,
        net: ZoneKey,
        apex: ZoneKey,
        txtName: DNSName,
        txt: String,
        corruptTXT: Bool,
        omitTXTRecords: Bool
    ) throws -> [String: Data] {
        var responses: [String: Data] = [:]
        responses[key(root.name, DNSType.dnskey)] = try signedMessage(
            owner: root.name, type: DNSType.dnskey, rdata: root.dnskey, signer: root, corrupt: false
        )
        responses[key(net.name, DNSType.ds)] = try signedMessage(
            owner: net.name, type: DNSType.ds, rdata: dsRecord(child: net), signer: root, corrupt: false
        )
        responses[key(net.name, DNSType.dnskey)] = try signedMessage(
            owner: net.name, type: DNSType.dnskey, rdata: net.dnskey, signer: net, corrupt: false
        )
        responses[key(apex.name, DNSType.ds)] = try signedMessage(
            owner: apex.name, type: DNSType.ds, rdata: dsRecord(child: apex), signer: net, corrupt: false
        )
        responses[key(apex.name, DNSType.dnskey)] = try signedMessage(
            owner: apex.name, type: DNSType.dnskey, rdata: apex.dnskey, signer: apex, corrupt: false
        )
        if omitTXTRecords {
            // NOERROR with no TXT records. Absence is not a verified empty set.
            responses[key(txtName, DNSType.txt)] = emptyAnswer(owner: txtName, type: DNSType.txt)
        } else {
            responses[key(txtName, DNSType.txt)] = try signedMessage(
                owner: txtName, type: DNSType.txt, rdata: txtRdata(txt), signer: apex, corrupt: corruptTXT
            )
        }
        return responses
    }

    private static func addressResponses(
        root: ZoneKey,
        apex: ZoneKey,
        host: DNSName,
        address: Data,
        corruptAAAA: Bool
    ) throws -> [String: Data] {
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
        return responses
    }

    private struct RSAZoneKey {
        var name: DNSName
        var signingKey: RSASigningKey
        var dnskey: Data
        var tag: UInt16
    }

    private static func rsaZoneKey(name: DNSName, bits: Int) throws -> RSAZoneKey {
        let material = try rsaSigningKey(bits: bits)
        var rdata = Data()
        rdata.appendU16(0x0101)
        rdata.append(3)
        rdata.append(DNSSECCrypto.rsaSHA256)
        rdata.append(material.publicKey)
        return RSAZoneKey(name: name, signingKey: material, dnskey: rdata, tag: DNSSECCrypto.keyTag(rdata))
    }

    private static func rsaAnchor(for zone: RSAZoneKey) -> DNSSECTrustAnchor {
        DNSSECTrustAnchor(
            keyTag: zone.tag,
            algorithm: DNSSECCrypto.rsaSHA256,
            digestType: 2,
            digest: DNSSECCrypto.dsDigest(owner: zone.name, dnskeyRdata: zone.dnskey),
            validFrom: 0
        )
    }

    private static func rsaSignedMessage(
        owner: DNSName,
        type: UInt16,
        rdata: Data,
        signer: RSAZoneKey,
        corrupt: Bool
    ) throws -> Data {
        let labels = UInt8(owner.labelCount)
        guard let material = DNSSECCrypto.signedMaterial(
            owner: owner,
            type: type,
            algorithm: DNSSECCrypto.rsaSHA256,
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
        var signature = try signer.signingKey.signature(for: material)
        if corrupt, !signature.isEmpty {
            signature[signature.index(before: signature.endIndex)] ^= 0xFF
        }
        var rrsig = Data()
        rrsig.appendU16(type)
        rrsig.append(DNSSECCrypto.rsaSHA256)
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
        dsRecord(owner: child.name, dnskey: child.dnskey)
    }

    private static func dsRecord(owner: DNSName, dnskey: Data) -> Data {
        guard dnskey.count >= 4 else { return Data() }
        var data = Data()
        data.appendU16(DNSSECCrypto.keyTag(dnskey))
        data.append(dnskey[3])
        data.append(2)
        data.append(DNSSECCrypto.dsDigest(owner: owner, dnskeyRdata: dnskey))
        return data
    }

    private struct RRSIGSpec {
        var signer: ZoneKey
        var keyTag: UInt16
        var corrupt: Bool = false
        var inception: UInt32 = DNSSECFixtureBuilder.inception
        var expiration: UInt32 = DNSSECFixtureBuilder.expiration
    }

    /// Two keys for `name` whose DNSKEY rdata shares one key tag.
    ///
    /// The first element was generated earlier. Tests list it first so a verifier
    /// that stops on the first tag match rejects a signature from the second.
    /// The search is bounded. A miss is a fixture failure.
    private static func pairSharingTag(name: DNSName) throws -> (ZoneKey, ZoneKey) {
        var byTag: [UInt16: ZoneKey] = [:]
        for _ in 0..<4096 {
            let key = try zoneKey(name: name)
            if let earlier = byTag[key.tag] {
                return (earlier, key)
            }
            byTag[key.tag] = key
        }
        throw FixtureError.material
    }

    /// Root keys where one key's revoked form shares the other key's tag.
    ///
    /// That key's tag without the REVOKE bit stays different, so the two anchors
    /// are not one key. The search is bounded. A miss is a fixture failure.
    /// The first tuple element is the key that gains the REVOKE bit.
    private static func revokedTagMatchesOtherAnchor() throws -> (revokedKey: ZoneKey, other: ZoneKey) {
        struct Entry {
            var key: ZoneKey
            var revokedTag: UInt16
        }
        var byUnrevokedTag: [UInt16: Entry] = [:]
        var byRevokedTag: [UInt16: Entry] = [:]
        for _ in 0..<4096 {
            let key = try zoneKey(name: .root)
            let revokedTag = DNSSECCrypto.keyTag(revokedRdata(key.dnskey))
            if key.tag == revokedTag { continue }
            if let other = byUnrevokedTag[revokedTag], other.key.tag != key.tag {
                return (key, other.key)
            }
            if let earlier = byRevokedTag[key.tag], earlier.key.tag != key.tag {
                return (earlier.key, key)
            }
            let entry = Entry(key: key, revokedTag: revokedTag)
            byUnrevokedTag[key.tag] = entry
            byRevokedTag[revokedTag] = entry
        }
        throw FixtureError.material
    }

    /// Two root keys whose tags stay distinct after A's rdata gains the REVOKE bit.
    private static func twoRootKeys() throws -> (ZoneKey, ZoneKey) {
        for _ in 0..<8 {
            let first = try zoneKey(name: .root)
            let second = try zoneKey(name: .root)
            let revokedFirst = DNSSECCrypto.keyTag(revokedRdata(first.dnskey))
            let revokedSecond = DNSSECCrypto.keyTag(revokedRdata(second.dnskey))
            let tags = [first.tag, second.tag, revokedFirst, revokedSecond]
            if Set(tags).count == tags.count {
                return (first, second)
            }
        }
        throw FixtureError.material
    }

    /// Published rdata with the REVOKE bit set (`0x0101 | 0x0080`). The input is not modified.
    private static func revokedRdata(_ rdata: Data) -> Data {
        var copy = Data(rdata)
        guard copy.count >= 2 else { return copy }
        let flags = UInt16(copy[0]) << 8 | UInt16(copy[1])
        let revoked = flags | 0x0080
        copy[0] = UInt8(revoked >> 8)
        copy[1] = UInt8(revoked & 0xFF)
        return copy
    }

    private static func revokedSpec(
        signer: ZoneKey,
        revoked: Data,
        corrupt: Bool = false,
        inception: UInt32 = DNSSECFixtureBuilder.inception,
        expiration: UInt32 = DNSSECFixtureBuilder.expiration
    ) -> RRSIGSpec {
        RRSIGSpec(
            signer: signer,
            keyTag: DNSSECCrypto.keyTag(revoked),
            corrupt: corrupt,
            inception: inception,
            expiration: expiration
        )
    }

    struct SelfRevocationWalk: Sendable {
        var retiring: Built
        var unrevokedCandidate: Built
        var survivor: Built
        var retiredDigest: Data
        var survivorDigest: Data
        var childName: DNSName
        var probeName: DNSName
    }

    /// Root answer: B unchanged, A with the REVOKE bit. Both sign the full DNSKEY set.
    /// The child TXT chains through B. `unrevokedCandidate` is only unrevoked A, signed by A.
    static func selfRevocation() throws -> SelfRevocationWalk {
        let (anchorA, anchorB) = try twoRootKeys()
        let anchors = [anchor(for: anchorA), anchor(for: anchorB)]
        let revokedA = revokedRdata(anchorA.dnskey)
        let retiringRoot = try dnskeyMessage(
            owner: .root,
            rdatas: [anchorB.dnskey, revokedA],
            signatures: [
                RRSIGSpec(signer: anchorB, keyTag: anchorB.tag),
                revokedSpec(signer: anchorA, revoked: revokedA),
            ]
        )
        let child = try zoneKey(name: try name("example"))
        let childName = try name("models.example")
        let retiring = try delegation(
            rootMessage: retiringRoot,
            dsSigner: anchorB,
            child: child,
            anchors: anchors,
            txtName: childName
        )
        let unrevokedRoot = try dnskeyMessage(
            owner: .root,
            rdatas: [anchorA.dnskey],
            signatures: [RRSIGSpec(signer: anchorA, keyTag: anchorA.tag)]
        )
        let probeName = try name("probe.example")
        let unrevokedCandidate = try txtSignedByRoot(
            rootMessage: unrevokedRoot,
            signer: anchorA,
            keyTag: anchorA.tag,
            anchors: anchors,
            name: probeName
        )
        let survivorRoot = try dnskeyMessage(
            owner: .root,
            rdatas: [anchorB.dnskey],
            signatures: [RRSIGSpec(signer: anchorB, keyTag: anchorB.tag)]
        )
        let survivor = try delegation(
            rootMessage: survivorRoot,
            dsSigner: anchorB,
            child: child,
            anchors: anchors,
            txtName: childName
        )
        return SelfRevocationWalk(
            retiring: retiring,
            unrevokedCandidate: unrevokedCandidate,
            survivor: survivor,
            retiredDigest: anchors[0].digest,
            survivorDigest: anchors[1].digest,
            childName: childName,
            probeName: probeName
        )
    }

    struct CopiedKeyWalk: Sendable {
        var copied: Built
        var onlyCopiedAnchor: Built
        var copiedDigest: Data
        var childName: DNSName
    }

    /// Unrevoked A, plus B's public key with the REVOKE bit, signed only by A.
    static func copiedRevokedKey() throws -> CopiedKeyWalk {
        let (anchorA, anchorB) = try twoRootKeys()
        let anchors = [anchor(for: anchorA), anchor(for: anchorB)]
        let revokedB = revokedRdata(anchorB.dnskey)
        let attackedRoot = try dnskeyMessage(
            owner: .root,
            rdatas: [anchorA.dnskey, revokedB],
            signatures: [RRSIGSpec(signer: anchorA, keyTag: anchorA.tag)]
        )
        let child = try zoneKey(name: try name("example"))
        let childName = try name("models.example")
        let copied = try delegation(
            rootMessage: attackedRoot,
            dsSigner: anchorA,
            child: child,
            anchors: anchors,
            txtName: childName
        )
        let onlyBRoot = try dnskeyMessage(
            owner: .root,
            rdatas: [anchorB.dnskey],
            signatures: [RRSIGSpec(signer: anchorB, keyTag: anchorB.tag)]
        )
        let onlyCopiedAnchor = try delegation(
            rootMessage: onlyBRoot,
            dsSigner: anchorB,
            child: child,
            anchors: anchors,
            txtName: childName
        )
        return CopiedKeyWalk(
            copied: copied,
            onlyCopiedAnchor: onlyCopiedAnchor,
            copiedDigest: anchors[1].digest,
            childName: childName
        )
    }

    struct RejectedRevocationWalk: Sendable {
        var presented: Built
        var onlyCandidate: Built
        var candidateDigest: Data
        var childName: DNSName
    }

    /// Same published keys as an honest revocation. B's signature is intact.
    /// The revoked key's signature is corrupted, or its lifetime is outside `now`.
    static func rejectedSelfSignature(corrupt: Bool, expired: Bool) throws -> RejectedRevocationWalk {
        let (anchorA, anchorB) = try twoRootKeys()
        let anchors = [anchor(for: anchorA), anchor(for: anchorB)]
        let revokedA = revokedRdata(anchorA.dnskey)
        let selfSignature = revokedSpec(
            signer: anchorA,
            revoked: revokedA,
            corrupt: corrupt,
            inception: expired ? 1_600_000_000 : inception,
            expiration: expired ? 1_600_000_100 : expiration
        )
        let presentedRoot = try dnskeyMessage(
            owner: .root,
            rdatas: [anchorB.dnskey, revokedA],
            signatures: [
                RRSIGSpec(signer: anchorB, keyTag: anchorB.tag),
                selfSignature,
            ]
        )
        let child = try zoneKey(name: try name("example"))
        let childName = try name("models.example")
        let presented = try delegation(
            rootMessage: presentedRoot,
            dsSigner: anchorB,
            child: child,
            anchors: anchors,
            txtName: childName
        )
        let onlyARoot = try dnskeyMessage(
            owner: .root,
            rdatas: [anchorA.dnskey],
            signatures: [RRSIGSpec(signer: anchorA, keyTag: anchorA.tag)]
        )
        let onlyCandidate = try delegation(
            rootMessage: onlyARoot,
            dsSigner: anchorA,
            child: child,
            anchors: anchors,
            txtName: childName
        )
        return RejectedRevocationWalk(
            presented: presented,
            onlyCandidate: onlyCandidate,
            candidateDigest: anchors[0].digest,
            childName: childName
        )
    }

    struct SoleRevocationWalk: Sendable {
        var revoked: Built
        var unrevoked: Built
        var digest: Data
        var name: DNSName
    }

    /// The only anchor's revoked form signs the root DNSKEY set.
    static func soleAnchorRevokes() throws -> SoleRevocationWalk {
        let anchorA = try zoneKey(name: .root)
        let anchors = [anchor(for: anchorA)]
        let revoked = revokedRdata(anchorA.dnskey)
        let revokedRoot = try dnskeyMessage(
            owner: .root,
            rdatas: [revoked],
            signatures: [revokedSpec(signer: anchorA, revoked: revoked)]
        )
        let name = try name("probe.example")
        let revokedWalk = try txtSignedByRoot(
            rootMessage: revokedRoot,
            signer: anchorA,
            keyTag: DNSSECCrypto.keyTag(revoked),
            anchors: anchors,
            name: name
        )
        let unrevokedRoot = try dnskeyMessage(
            owner: .root,
            rdatas: [anchorA.dnskey],
            signatures: [RRSIGSpec(signer: anchorA, keyTag: anchorA.tag)]
        )
        let unrevokedWalk = try txtSignedByRoot(
            rootMessage: unrevokedRoot,
            signer: anchorA,
            keyTag: anchorA.tag,
            anchors: anchors,
            name: name
        )
        return SoleRevocationWalk(
            revoked: revokedWalk,
            unrevoked: unrevokedWalk,
            digest: anchors[0].digest,
            name: name
        )
    }

    struct RevokedChildWalk: Sendable {
        var revoked: Built
        var live: Built
        var txtName: DNSName
        var rootDigest: Data
    }

    /// The child's only DS-matching DNSKEY has the REVOKE bit set. The live twin does not.
    static func revokedChild() throws -> RevokedChildWalk {
        let root = try zoneKey(name: .root)
        let child = try zoneKey(name: try name("example"))
        let txtName = try name("models.example")
        let revoked = revokedRdata(child.dnskey)
        return RevokedChildWalk(
            revoked: try childPublishing(
                root: root,
                child: child,
                published: revoked,
                keyTag: DNSSECCrypto.keyTag(revoked),
                txtName: txtName
            ),
            live: try childPublishing(
                root: root,
                child: child,
                published: child.dnskey,
                keyTag: child.tag,
                txtName: txtName
            ),
            txtName: txtName,
            rootDigest: anchor(for: root).digest
        )
    }

    private static func delegation(
        rootMessage: Data,
        dsSigner: ZoneKey,
        child: ZoneKey,
        anchors: [DNSSECTrustAnchor],
        txtName: DNSName
    ) throws -> Built {
        var responses: [String: Data] = [:]
        responses[key(.root, DNSType.dnskey)] = rootMessage
        responses[key(child.name, DNSType.ds)] = try signedMessage(
            owner: child.name,
            type: DNSType.ds,
            rdata: dsRecord(child: child),
            signer: dsSigner,
            corrupt: false
        )
        responses[key(child.name, DNSType.dnskey)] = try signedMessage(
            owner: child.name,
            type: DNSType.dnskey,
            rdata: child.dnskey,
            signer: child,
            corrupt: false
        )
        responses[key(txtName, DNSType.txt)] = try signedMessage(
            owner: txtName,
            type: DNSType.txt,
            rdata: txtRdata("kailuakona"),
            signer: child,
            corrupt: false
        )
        return Built(anchors: anchors, fetcher: MappedDNSFetcher(responses: responses))
    }

    private static func childPublishing(
        root: ZoneKey,
        child: ZoneKey,
        published: Data,
        keyTag: UInt16,
        txtName: DNSName
    ) throws -> Built {
        let rootMessage = try dnskeyMessage(
            owner: .root,
            rdatas: [root.dnskey],
            signatures: [RRSIGSpec(signer: root, keyTag: root.tag)]
        )
        var responses: [String: Data] = [:]
        responses[key(.root, DNSType.dnskey)] = rootMessage
        responses[key(child.name, DNSType.ds)] = try signedMessage(
            owner: child.name,
            type: DNSType.ds,
            rdata: dsRecord(owner: child.name, dnskey: published),
            signer: root,
            corrupt: false
        )
        responses[key(child.name, DNSType.dnskey)] = try dnskeyMessage(
            owner: child.name,
            rdatas: [published],
            signatures: [RRSIGSpec(signer: child, keyTag: keyTag)]
        )
        responses[key(txtName, DNSType.txt)] = try signedMessage(
            owner: txtName,
            type: DNSType.txt,
            rdata: txtRdata("kailuakona"),
            signer: child,
            corrupt: false,
            keyTag: keyTag
        )
        return Built(anchors: [anchor(for: root)], fetcher: MappedDNSFetcher(responses: responses))
    }

    private static func txtSignedByRoot(
        rootMessage: Data,
        signer: ZoneKey,
        keyTag: UInt16,
        anchors: [DNSSECTrustAnchor],
        name: DNSName
    ) throws -> Built {
        let txt = try signedMessage(
            owner: name,
            type: DNSType.txt,
            rdata: txtRdata("kailuakona"),
            signer: signer,
            corrupt: false,
            keyTag: keyTag
        )
        return Built(
            anchors: anchors,
            fetcher: MappedDNSFetcher(responses: [
                key(.root, DNSType.dnskey): rootMessage,
                key(name, DNSType.txt): txt,
            ])
        )
    }

    private static func signedMessage(
        owner: DNSName,
        type: UInt16,
        rdata: Data,
        signer: ZoneKey,
        corrupt: Bool,
        keyTag: UInt16? = nil,
        inception: UInt32 = DNSSECFixtureBuilder.inception,
        expiration: UInt32 = DNSSECFixtureBuilder.expiration
    ) throws -> Data {
        let spec = RRSIGSpec(
            signer: signer,
            keyTag: keyTag ?? signer.tag,
            corrupt: corrupt,
            inception: inception,
            expiration: expiration
        )
        let rrsig = try rrsigRdata(owner: owner, type: type, rdatas: [rdata], spec: spec)
        let question = DNSQuestion(name: owner, type: type, klass: DNSType.internet)
        let record = DNSRR(name: owner, type: type, klass: DNSType.internet, ttl: ttl, rdata: rdata)
        let signatureRR = DNSRR(name: owner, type: DNSType.rrsig, klass: DNSType.internet, ttl: ttl, rdata: rrsig)
        return DNSMessage.response(id: 0, rcode: 0, question: question, answers: [record, signatureRR])
    }

    private static func dnskeyMessage(owner: DNSName, rdatas: [Data], signatures: [RRSIGSpec]) throws -> Data {
        var answers: [DNSRR] = []
        answers.reserveCapacity(rdatas.count + signatures.count)
        for rdata in rdatas {
            answers.append(DNSRR(name: owner, type: DNSType.dnskey, klass: DNSType.internet, ttl: ttl, rdata: rdata))
        }
        for spec in signatures {
            let rrsig = try rrsigRdata(owner: owner, type: DNSType.dnskey, rdatas: rdatas, spec: spec)
            answers.append(DNSRR(name: owner, type: DNSType.rrsig, klass: DNSType.internet, ttl: ttl, rdata: rrsig))
        }
        let question = DNSQuestion(name: owner, type: DNSType.dnskey, klass: DNSType.internet)
        return DNSMessage.response(id: 0, rcode: 0, question: question, answers: answers)
    }

    /// Signs `rdatas` with one key. The RRSIG key tag is `spec.keyTag`, which for a
    /// revoked DNSKEY is ``DNSSECCrypto/keyTag(_:)`` of the revoked rdata.
    private static func rrsigRdata(owner: DNSName, type: UInt16, rdatas: [Data], spec: RRSIGSpec) throws -> Data {
        let labels = UInt8(owner.labelCount)
        guard let material = DNSSECCrypto.signedMaterial(
            owner: owner,
            type: type,
            algorithm: 13,
            labels: labels,
            originalTTL: ttl,
            expiration: spec.expiration,
            inception: spec.inception,
            keyTag: spec.keyTag,
            signer: spec.signer.name,
            rdatas: rdatas
        ) else {
            throw FixtureError.material
        }
        var signature = try spec.signer.privateKey.signature(for: material).rawRepresentation
        if spec.corrupt, !signature.isEmpty {
            signature[signature.index(before: signature.endIndex)] ^= 0xFF
        }
        var rrsig = Data()
        rrsig.appendU16(type)
        rrsig.append(13)
        rrsig.append(labels)
        rrsig.appendU32(ttl)
        rrsig.appendU32(spec.expiration)
        rrsig.appendU32(spec.inception)
        rrsig.appendU16(spec.keyTag)
        rrsig.append(spec.signer.name.canonicalWire)
        rrsig.append(signature)
        return rrsig
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

    struct SharedTagWalk: Sendable {
        var laterKey: Built
        var earlierKey: Built
        var brokenSignature: Built
        var unlistedSigner: Built
        var txtName: DNSName
        var sharedTag: UInt16
    }

    /// Child zone `example` publishes two keys with one tag. The decoy is listed
    /// first. `laterKey` is signed by the second key. `earlierKey` is signed by
    /// the first. `brokenSignature` damages the TXT signature. `unlistedSigner`
    /// publishes only the decoy and signs the TXT with the key that was left out.
    /// Both listed keys have a DS, so the DNSKEY check and the TXT check each see
    /// the pair. The fixture does not open DoH.
    static func sharedKeyTag() throws -> SharedTagWalk {
        let root = try zoneKey(name: .root)
        let zoneName = try name("example")
        let (decoy, signer) = try pairSharingTag(name: zoneName)
        guard decoy.tag == signer.tag else { throw FixtureError.material }
        let txtName = try name("models.example")
        let anchors = [anchor(for: root)]
        let rootMessage = try dnskeyMessage(
            owner: .root,
            rdatas: [root.dnskey],
            signatures: [RRSIGSpec(signer: root, keyTag: root.tag)]
        )
        let bothDS = try signedRRset(
            owner: zoneName,
            type: DNSType.ds,
            rdatas: [dsRecord(child: decoy), dsRecord(child: signer)],
            signer: root,
            corrupt: false
        )
        let laterKeys = try dnskeyMessage(
            owner: zoneName,
            rdatas: [decoy.dnskey, signer.dnskey],
            signatures: [RRSIGSpec(signer: signer, keyTag: signer.tag)]
        )
        let earlierKeys = try dnskeyMessage(
            owner: zoneName,
            rdatas: [decoy.dnskey, signer.dnskey],
            signatures: [RRSIGSpec(signer: decoy, keyTag: decoy.tag)]
        )
        let laterText = try signedMessage(
            owner: txtName,
            type: DNSType.txt,
            rdata: txtRdata("kailuakona"),
            signer: signer,
            corrupt: false
        )
        let earlierText = try signedMessage(
            owner: txtName,
            type: DNSType.txt,
            rdata: txtRdata("kailuakona"),
            signer: decoy,
            corrupt: false
        )
        let brokenText = try signedMessage(
            owner: txtName,
            type: DNSType.txt,
            rdata: txtRdata("kailuakona"),
            signer: signer,
            corrupt: true
        )
        let onlyDecoyDS = try signedMessage(
            owner: zoneName,
            type: DNSType.ds,
            rdata: dsRecord(child: decoy),
            signer: root,
            corrupt: false
        )
        let onlyDecoyKeys = try dnskeyMessage(
            owner: zoneName,
            rdatas: [decoy.dnskey],
            signatures: [RRSIGSpec(signer: decoy, keyTag: decoy.tag)]
        )
        func built(ds: Data, keys: Data, text: Data) -> Built {
            Built(
                anchors: anchors,
                fetcher: MappedDNSFetcher(responses: [
                    key(.root, DNSType.dnskey): rootMessage,
                    key(zoneName, DNSType.ds): ds,
                    key(zoneName, DNSType.dnskey): keys,
                    key(txtName, DNSType.txt): text,
                ])
            )
        }
        return SharedTagWalk(
            laterKey: built(ds: bothDS, keys: laterKeys, text: laterText),
            earlierKey: built(ds: bothDS, keys: earlierKeys, text: earlierText),
            brokenSignature: built(ds: bothDS, keys: laterKeys, text: brokenText),
            unlistedSigner: built(ds: onlyDecoyDS, keys: onlyDecoyKeys, text: laterText),
            txtName: txtName,
            sharedTag: decoy.tag
        )
    }

    struct CollidingTagRevocationWalk: Sendable {
        var presented: Built
        /// Later walk: that key alone, without the REVOKE bit.
        var unrevokedKeyAlone: Built
        /// Digest of the key that gains the REVOKE bit. Retirement must leave it trusted.
        var revokedKeyDigest: Data
        var childName: DNSName
        var revokedTag: UInt16
        var otherTag: UInt16
        /// Tag of that key before the REVOKE bit. It stays different from `otherTag`.
        var unrevokedTag: UInt16
    }

    /// One key's revoked tag equals the other anchor's tag. Only the other
    /// anchor signs the root DNSKEY set. A later walk is that key alone,
    /// without the REVOKE bit.
    static func revokedTagCollidesWithOtherAnchor() throws -> CollidingTagRevocationWalk {
        let (revokedKey, other) = try revokedTagMatchesOtherAnchor()
        let revoked = revokedRdata(revokedKey.dnskey)
        let revokedTag = DNSSECCrypto.keyTag(revoked)
        guard revokedTag == other.tag, revokedKey.tag != other.tag else { throw FixtureError.material }
        let anchors = [anchor(for: revokedKey), anchor(for: other)]
        let presentedRoot = try dnskeyMessage(
            owner: .root,
            rdatas: [other.dnskey, revoked],
            signatures: [RRSIGSpec(signer: other, keyTag: other.tag)]
        )
        let child = try zoneKey(name: try name("example"))
        let childName = try name("models.example")
        let presented = try delegation(
            rootMessage: presentedRoot,
            dsSigner: other,
            child: child,
            anchors: anchors,
            txtName: childName
        )
        let unrevokedRoot = try dnskeyMessage(
            owner: .root,
            rdatas: [revokedKey.dnskey],
            signatures: [RRSIGSpec(signer: revokedKey, keyTag: revokedKey.tag)]
        )
        let unrevokedKeyAlone = try delegation(
            rootMessage: unrevokedRoot,
            dsSigner: revokedKey,
            child: child,
            anchors: anchors,
            txtName: childName
        )
        return CollidingTagRevocationWalk(
            presented: presented,
            unrevokedKeyAlone: unrevokedKeyAlone,
            revokedKeyDigest: anchors[0].digest,
            childName: childName,
            revokedTag: revokedTag,
            otherTag: other.tag,
            unrevokedTag: revokedKey.tag
        )
    }

    /// Signs every rdata in one RRset. The RRSIG key tag is the signer's tag.
    private static func signedRRset(
        owner: DNSName,
        type: UInt16,
        rdatas: [Data],
        signer: ZoneKey,
        corrupt: Bool
    ) throws -> Data {
        let spec = RRSIGSpec(signer: signer, keyTag: signer.tag, corrupt: corrupt)
        let rrsig = try rrsigRdata(owner: owner, type: type, rdatas: rdatas, spec: spec)
        var answers: [DNSRR] = []
        answers.reserveCapacity(rdatas.count + 1)
        for rdata in rdatas {
            answers.append(DNSRR(name: owner, type: type, klass: DNSType.internet, ttl: ttl, rdata: rdata))
        }
        answers.append(DNSRR(name: owner, type: DNSType.rrsig, klass: DNSType.internet, ttl: ttl, rdata: rrsig))
        let question = DNSQuestion(name: owner, type: type, klass: DNSType.internet)
        return DNSMessage.response(id: 0, rcode: 0, question: question, answers: answers)
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
            now: DNSSECFixtureBuilder.now, retiredAnchors: RetiredRootAnchorStore.memory()
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
        let walk = DNSSECWalk(fetcher: built.fetcher, anchors: built.anchors, now: DNSSECFixtureBuilder.now, retiredAnchors: RetiredRootAnchorStore.memory())
        let name = try #require(DNSName(presentation: "securitymodels.siikkari.net"))
        #expect(await walk.txtModels(name: name) == .failed)
    }

    @Test("A bad signature is not a verified set")
    func badSignatureFails() async throws {
        let built = try DNSSECFixtureBuilder.allowList(txt: "kailuakona", corruptTXT: true)
        let walk = DNSSECWalk(fetcher: built.fetcher, anchors: built.anchors, now: DNSSECFixtureBuilder.now, retiredAnchors: RetiredRootAnchorStore.memory())
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
            now: Date(timeIntervalSince1970: 1_800_000_001),
            retiredAnchors: RetiredRootAnchorStore.memory()
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
        let walk = DNSSECWalk(fetcher: built.fetcher, anchors: [wrong], now: DNSSECFixtureBuilder.now, retiredAnchors: RetiredRootAnchorStore.memory())
        let name = try #require(DNSName(presentation: "securitymodels.siikkari.net"))
        #expect(await walk.txtModels(name: name) == .failed)
    }

    @Test("A verified A record with AAAA absent is an address")
    func verifiedAWithoutAAAA() async throws {
        let (built, host) = try DNSSECFixtureBuilder.addressFixture()
        let walk = DNSSECWalk(fetcher: built.fetcher, anchors: built.anchors, now: DNSSECFixtureBuilder.now, retiredAnchors: RetiredRootAnchorStore.memory())
        let addresses = await walk.addresses(for: host)
        #expect(addresses.count == 1)
        #expect(addresses.first?.presentation == "203.0.113.10")
    }

    @Test("A failed AAAA RRset drops the whole address set")
    func failedAAAADropsAddresses() async throws {
        let (built, host) = try DNSSECFixtureBuilder.addressFixture(corruptAAAA: true)
        let walk = DNSSECWalk(fetcher: built.fetcher, anchors: built.anchors, now: DNSSECFixtureBuilder.now, retiredAnchors: RetiredRootAnchorStore.memory())
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
        let narrow = try DNSSECFixtureBuilder.rsaSigningKey(bits: 1024)
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
        let wide = try DNSSECFixtureBuilder.rsaSigningKey(bits: 2048)
        let wideSignature = try wide.signature(for: message)
        #expect(DNSSECCrypto.verify(
            algorithm: 8, publicKey: wide.publicKey, signature: wideSignature, message: message, signer: root
        ))
        #expect(DNSSECCrypto.verify(
            algorithm: 8, publicKey: wide.publicKey, signature: wideSignature, message: message, signer: eu
        ))
    }

    /// Order is KSK-2017 (20326), then KSK-2024 (38696). The timestamps are
    /// `validFrom`, not the 11 October 2026 signing change and not the retirement signal.
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

    /// Honest self-revocation. Anchors A and B. The root answer contains B unchanged
    /// and A with the REVOKE bit set. B and the revoked key each sign the full DNSKEY
    /// set. A child TXT verifies under B, and the store contains A's digest.
    ///
    /// The second walk fails because that digest was suppressed. Its root answer is
    /// only the old unrevoked A rdata with a valid signature from A. The same answer
    /// verifies on a fresh store. A walk signed by B on the original store still succeeds.
    ///
    /// - SeeAlso: ``RetiredRootAnchorStore``, ``SecurityConfiguration/ianaRootTrustAnchors``,
    ///   ``<doc:Security-Invariants>`` Invariant 5
    @Test("A self-signed revoked root key suppresses that anchor")
    func selfSignedRevokeSuppressesThatAnchor() async throws {
        let fixture = try DNSSECFixtureBuilder.selfRevocation()
        let store = RetiredRootAnchorStore.memory()
        let retiring = DNSSECWalk(
            fetcher: fixture.retiring.fetcher,
            anchors: fixture.retiring.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: store
        )
        let child = await retiring.txtModels(name: fixture.childName)
        #expect(child == .verified(["kailuakona"]))
        #expect(await store.suppresses(fixture.retiredDigest))
        #expect(await store.suppresses(fixture.survivorDigest) == false)

        let fresh = DNSSECWalk(
            fetcher: fixture.unrevokedCandidate.fetcher,
            anchors: fixture.unrevokedCandidate.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: RetiredRootAnchorStore.memory()
        )
        #expect(await fresh.txtModels(name: fixture.probeName) == .verified(["kailuakona"]))

        let suppressed = DNSSECWalk(
            fetcher: fixture.unrevokedCandidate.fetcher,
            anchors: fixture.unrevokedCandidate.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: store
        )
        #expect(await suppressed.txtModels(name: fixture.probeName) == .failed)

        let survivor = DNSSECWalk(
            fetcher: fixture.survivor.fetcher,
            anchors: fixture.survivor.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: store
        )
        #expect(await survivor.txtModels(name: fixture.childName) == .verified(["kailuakona"]))
    }

    /// B's public key is published with the REVOKE bit, but only A signs the set.
    /// B's digest is not stored, so a later walk signed only by B still succeeds.
    @Test("A copied key without its own signature does not retire the anchor")
    func copiedKeyWithoutSelfSignatureDoesNotRetire() async throws {
        let fixture = try DNSSECFixtureBuilder.copiedRevokedKey()
        let store = RetiredRootAnchorStore.memory()
        let attacked = DNSSECWalk(
            fetcher: fixture.copied.fetcher,
            anchors: fixture.copied.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: store
        )
        #expect(await attacked.txtModels(name: fixture.childName) == .verified(["kailuakona"]))
        #expect(await store.suppresses(fixture.copiedDigest) == false)

        let onlyB = DNSSECWalk(
            fetcher: fixture.onlyCopiedAnchor.fetcher,
            anchors: fixture.onlyCopiedAnchor.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: store
        )
        #expect(await onlyB.txtModels(name: fixture.childName) == .verified(["kailuakona"]))
    }

    /// The revoked key's signature is corrupted. B's signature still verifies the set.
    /// A's digest is not stored, so a later walk signed only by A succeeds.
    @Test("A bad self-signature does not retire the anchor")
    func badSelfSignatureDoesNotRetire() async throws {
        let fixture = try DNSSECFixtureBuilder.rejectedSelfSignature(corrupt: true, expired: false)
        try await expectRejectedRevocation(fixture)
    }

    /// The revoked key's inception and expiration are outside now. B's signature is current.
    /// A's digest is not stored.
    @Test("An expired self-signature does not retire the anchor")
    func expiredSelfSignatureDoesNotRetire() async throws {
        let fixture = try DNSSECFixtureBuilder.rejectedSelfSignature(corrupt: false, expired: true)
        try await expectRejectedRevocation(fixture)
    }

    /// The only anchor's revoked form signs the set. The digest is stored and the walk fails.
    @Test("The last anchor's self-revocation is kept and the zone fails")
    func lastAnchorSelfRevokeFailsClosed() async throws {
        let fixture = try DNSSECFixtureBuilder.soleAnchorRevokes()
        let store = RetiredRootAnchorStore.memory()
        let walk = DNSSECWalk(
            fetcher: fixture.revoked.fetcher,
            anchors: fixture.revoked.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: store
        )
        #expect(await walk.txtModels(name: fixture.name) == .failed)
        #expect(await store.suppresses(fixture.digest))
    }

    /// A private suite remembers the digest for a new store. `UserDefaults.standard`
    /// and `lastSecurityValidation` are left as they were.
    ///
    /// The suite object is not used again after it is handed to the store. A later
    /// `UserDefaults(suiteName:)` is a new value so the test and the actor do not
    /// share one reference.
    @Test("A retired digest survives a new store on the same private suite")
    func retiredDigestPersistsInPrivateSuite() async throws {
        let suiteName = "radio.lutheran.coretests.retired-root-anchors.\(UUID().uuidString)"
        Self.removeSuite(named: suiteName)
        defer { Self.removeSuite(named: suiteName) }
        let standardRetiredBefore = UserDefaults.standard.data(forKey: RetiredRootAnchorStore.storageKey)
        let standardValidationBefore = UserDefaults.standard.object(forKey: "lastSecurityValidation") as? Date

        let fixture = try DNSSECFixtureBuilder.soleAnchorRevokes()
        let store = try Self.store(suiteName: suiteName, corruptLength: true)
        #expect(await store.persistedOctetCount() == 31)
        #expect(await store.suppresses(fixture.digest) == false)

        let walk = DNSSECWalk(
            fetcher: fixture.revoked.fetcher,
            anchors: fixture.revoked.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: store
        )
        #expect(await walk.txtModels(name: fixture.name) == .failed)
        #expect(await store.persistedOctetCount() == 32)
        #expect(await store.suppresses(fixture.digest))

        let reloaded = try Self.store(suiteName: suiteName, corruptLength: false)
        #expect(await reloaded.suppresses(fixture.digest))
        let again = DNSSECWalk(
            fetcher: fixture.unrevoked.fetcher,
            anchors: fixture.unrevoked.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: reloaded
        )
        #expect(await again.txtModels(name: fixture.name) == .failed)

        let fresh = DNSSECWalk(
            fetcher: fixture.unrevoked.fetcher,
            anchors: fixture.unrevoked.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: RetiredRootAnchorStore.memory()
        )
        #expect(await fresh.txtModels(name: fixture.name) == .verified(["kailuakona"]))

        #expect(UserDefaults.standard.data(forKey: RetiredRootAnchorStore.storageKey) == standardRetiredBefore)
        #expect(UserDefaults.standard.object(forKey: "lastSecurityValidation") as? Date == standardValidationBefore)
    }

    /// Hands a private suite to a new store. The caller does not keep the suite object.
    private static func store(suiteName: String, corruptLength: Bool) throws -> RetiredRootAnchorStore {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        if corruptLength {
            defaults.set(Data(count: 31), forKey: RetiredRootAnchorStore.storageKey)
        }
        return RetiredRootAnchorStore(defaults: defaults)
    }

    private static func removeSuite(named suiteName: String) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.removeObject(forKey: RetiredRootAnchorStore.storageKey)
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// The return filter is global. A child whose only DS-matching key has the REVOKE bit
    /// does not verify. The same key without the bit does. The child does not retire the root anchor.
    @Test("A revoked child DNSKEY does not verify its RRset")
    func revokedChildKeyDoesNotVerify() async throws {
        let fixture = try DNSSECFixtureBuilder.revokedChild()
        let store = RetiredRootAnchorStore.memory()
        let revoked = DNSSECWalk(
            fetcher: fixture.revoked.fetcher,
            anchors: fixture.revoked.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: store
        )
        #expect(await revoked.txtModels(name: fixture.txtName) == .failed)
        #expect(await store.suppresses(fixture.rootDigest) == false)

        let live = DNSSECWalk(
            fetcher: fixture.live.fetcher,
            anchors: fixture.live.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: RetiredRootAnchorStore.memory()
        )
        #expect(await live.txtModels(name: fixture.txtName) == .verified(["kailuakona"]))
    }

    /// The root is RSA-SHA256. The 1024-bit key signs only as `eu`. ``DNSSECWalk``
    /// checks the DNSKEY RRset and the DS. The fixture does not open DoH.
    ///
    /// - SeeAlso: ``DNSSECWalk``, ``DNSSECCrypto/verify(algorithm:publicKey:signature:message:signer:)``,
    ///   ``<doc:Security-Invariants>`` Invariant 2
    @Test("An RSA root chain verifies through DNSSECWalk")
    func rsaChainVerifies() async throws {
        let (built, name) = try DNSSECFixtureBuilder.rsaAllowList(txt: "dallas,montereypark,kailuakona")
        let walk = DNSSECWalk(
            fetcher: built.fetcher,
            anchors: built.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: RetiredRootAnchorStore.memory()
        )
        #expect(built.anchors[0].algorithm == 8)
        #expect(await walk.txtModels(name: name) == .verified(["dallas", "montereypark", "kailuakona"]))
    }

    /// The `eu` DS signature is damaged after the 2048-bit root has signed its own DNSKEY set.
    @Test("A bad RSA signature is not a verified set")
    func rsaBadSignatureFails() async throws {
        let (built, name) = try DNSSECFixtureBuilder.rsaAllowList(txt: "kailuakona", corruptEUDS: true)
        let walk = DNSSECWalk(
            fetcher: built.fetcher,
            anchors: built.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: RetiredRootAnchorStore.memory()
        )
        #expect(await walk.txtModels(name: name) == .failed)
    }

    @Test("The wrong RSA anchor is not a verified set")
    func rsaWrongAnchorFails() async throws {
        let (built, name) = try DNSSECFixtureBuilder.rsaAllowList(txt: "kailuakona")
        var digest = Data(built.anchors[0].digest)
        digest[0] ^= 0xFF
        let wrong = DNSSECTrustAnchor(
            keyTag: built.anchors[0].keyTag,
            algorithm: built.anchors[0].algorithm,
            digestType: 2,
            digest: digest,
            validFrom: 0
        )
        let walk = DNSSECWalk(
            fetcher: built.fetcher,
            anchors: [wrong],
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: RetiredRootAnchorStore.memory()
        )
        #expect(await walk.txtModels(name: name) == .failed)
    }

    /// A 1024-bit root signature can be mathematically valid and still fail the walk.
    /// The short-key exception is the signer `eu` alone.
    @Test("A 1024-bit RSA root does not verify")
    func rsaShortRootFails() async throws {
        let (built, name) = try DNSSECFixtureBuilder.rsaAllowList(txt: "kailuakona", rootBits: 1024)
        let walk = DNSSECWalk(
            fetcher: built.fetcher,
            anchors: built.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: RetiredRootAnchorStore.memory()
        )
        #expect(await walk.txtModels(name: name) == .failed)
    }

    /// Two P-256 zone keys share one key tag. The decoy is listed first. The DNSKEY
    /// set and the TXT RRset are signed by the later key, and both keys match a DS.
    /// The tag match on the decoy is not enough: the later key has to be tried.
    /// The fixture does not open DoH.
    ///
    /// - SeeAlso: ``DNSSECWalk``, ``<doc:Security-Invariants>`` Invariant 2
    @Test("A later key with the same tag verifies the RRset")
    func sharedKeyTagLaterKeyVerifies() async throws {
        let fixture = try DNSSECFixtureBuilder.sharedKeyTag()
        let walk = DNSSECWalk(
            fetcher: fixture.laterKey.fetcher,
            anchors: fixture.laterKey.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: RetiredRootAnchorStore.memory()
        )
        #expect(await walk.txtModels(name: fixture.txtName) == .verified(["kailuakona"]))
    }

    /// The earlier key signs. The later key shares the tag and does not have to
    /// verify. Acceptance is any one listed key, not every listed key.
    @Test("The earlier key still verifies when a later key shares its tag")
    func sharedKeyTagEarlierKeyVerifies() async throws {
        let fixture = try DNSSECFixtureBuilder.sharedKeyTag()
        let walk = DNSSECWalk(
            fetcher: fixture.earlierKey.fetcher,
            anchors: fixture.earlierKey.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: RetiredRootAnchorStore.memory()
        )
        #expect(await walk.txtModels(name: fixture.txtName) == .verified(["kailuakona"]))
    }

    /// The TXT signature is damaged. Both keys share the tag. Neither verifies,
    /// so the RRset fails. A tag match alone is not acceptance.
    @Test("A shared key tag fails closed when no listed key verifies")
    func sharedKeyTagFailsClosed() async throws {
        let fixture = try DNSSECFixtureBuilder.sharedKeyTag()
        let walk = DNSSECWalk(
            fetcher: fixture.brokenSignature.fetcher,
            anchors: fixture.brokenSignature.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: RetiredRootAnchorStore.memory()
        )
        #expect(await walk.txtModels(name: fixture.txtName) == .failed)
    }

    /// The TXT signature was made by a key that is not in the DNSKEY set. That
    /// key's tag collides with the published key. The published key does not
    /// verify the signature, and the missing key is not added.
    @Test("A colliding key that is not in the set does not verify")
    func sharedKeyTagIgnoresAnUnlistedKey() async throws {
        let fixture = try DNSSECFixtureBuilder.sharedKeyTag()
        let walk = DNSSECWalk(
            fetcher: fixture.unlistedSigner.fetcher,
            anchors: fixture.unlistedSigner.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: RetiredRootAnchorStore.memory()
        )
        #expect(await walk.txtModels(name: fixture.txtName) == .failed)
    }

    /// The revoked key's tag equals the other anchor's tag. Only the other anchor
    /// signs the DNSKEY set. The retirement check passes the revoked key alone, so
    /// the other signature is checked against that public key and does not retire
    /// the digest. A later walk signed by the unrevoked key still succeeds.
    ///
    /// - SeeAlso: ``RetiredRootAnchorStore``, ``<doc:Security-Invariants>`` Invariant 5
    @Test("A colliding key tag does not let another anchor retire a digest")
    func collidingKeyTagDoesNotRetireAnotherAnchor() async throws {
        let fixture = try DNSSECFixtureBuilder.revokedTagCollidesWithOtherAnchor()
        #expect(fixture.revokedTag == fixture.otherTag)
        #expect(fixture.unrevokedTag != fixture.otherTag)
        let store = RetiredRootAnchorStore.memory()
        let presented = DNSSECWalk(
            fetcher: fixture.presented.fetcher,
            anchors: fixture.presented.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: store
        )
        #expect(await presented.txtModels(name: fixture.childName) == .verified(["kailuakona"]))
        #expect(await store.suppresses(fixture.revokedKeyDigest) == false)
        let unrevokedKeyAlone = DNSSECWalk(
            fetcher: fixture.unrevokedKeyAlone.fetcher,
            anchors: fixture.unrevokedKeyAlone.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: store
        )
        #expect(await unrevokedKeyAlone.txtModels(name: fixture.childName) == .verified(["kailuakona"]))
    }

    /// A signature failure drops the first walk. The second fetcher is asked for the
    /// root DNSKEY, so the first walk's cached RRsets are not reused.
    ///
    /// - SeeAlso: ``DNSSECResolverWalk``, ``<doc:Security-Invariants>`` Invariant 1
    @Test("A signature failure starts a new walk on the next resolver")
    func signatureFailureStartsNewWalk() async throws {
        let paired = try DNSSECFixtureBuilder.pairedAllowLists(
            firstTXT: "other-model",
            secondTXT: "sunshinecoast",
            corruptFirstTXT: true
        )
        let name = try #require(DNSName(presentation: "securitymodels.siikkari.net"))
        let outcome = await DNSSECResolverWalk.txtModels(
            name: name,
            fetchers: [paired.first, paired.second],
            anchors: paired.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: RetiredRootAnchorStore.memory()
        )
        #expect(outcome == .verified(["sunshinecoast"]))
        #expect(Self.sawRootDNSKEY(paired.first))
        #expect(Self.sawRootDNSKEY(paired.second))
    }

    /// A verified omission is a successful verification. The resolver that would
    /// have answered `sunshinecoast` is not asked.
    @Test("A verified TXT omission does not ask the next resolver")
    func verifiedOmissionDoesNotAskNextResolver() async throws {
        let paired = try DNSSECFixtureBuilder.pairedAllowLists(
            firstTXT: "other-model",
            secondTXT: "sunshinecoast"
        )
        let name = try #require(DNSName(presentation: "securitymodels.siikkari.net"))
        let outcome = await DNSSECResolverWalk.txtModels(
            name: name,
            fetchers: [paired.first, paired.second],
            anchors: paired.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: RetiredRootAnchorStore.memory()
        )
        #expect(outcome == .verified(["other-model"]))
        #expect(paired.second.queries.withLock { $0 }.isEmpty)
    }

    /// A missing TXT RRset is unverified, so the next resolver's signed set can still be accepted.
    @Test("A missing TXT on the first resolver does not stop the next walk")
    func missingTXTAsksNextResolver() async throws {
        let paired = try DNSSECFixtureBuilder.pairedAllowLists(
            firstTXT: "other-model",
            secondTXT: "sunshinecoast",
            omitFirstTXT: true
        )
        let name = try #require(DNSName(presentation: "securitymodels.siikkari.net"))
        let outcome = await DNSSECResolverWalk.txtModels(
            name: name,
            fetchers: [paired.first, paired.second],
            anchors: paired.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: RetiredRootAnchorStore.memory()
        )
        #expect(outcome == .verified(["sunshinecoast"]))
        #expect(Self.sawRootDNSKEY(paired.second))
    }

    /// No message is a transport miss. The first fetcher already represents that miss,
    /// so the later fetcher is not started.
    @Test("A transport failure does not start another walk")
    func transportFailureDoesNotStartAnotherWalk() async throws {
        let good = try DNSSECFixtureBuilder.allowList(txt: "sunshinecoast")
        let silent = MappedDNSFetcher(responses: [:])
        let name = try #require(DNSName(presentation: "securitymodels.siikkari.net"))
        let outcome = await DNSSECResolverWalk.txtModels(
            name: name,
            fetchers: [silent, good.fetcher],
            anchors: good.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: RetiredRootAnchorStore.memory()
        )
        #expect(outcome == .failed)
        let txtKey = "securitymodels.siikkari.net|\(DNSType.txt)"
        #expect(silent.queries.withLock { $0.contains(txtKey) })
        #expect(good.fetcher.queries.withLock { $0 }.isEmpty)
    }

    /// A failed AAAA signature drops the first walk's A record. The next walk's address is the result.
    @Test("A failed address signature drops the first walk")
    func failedAddressSignatureDropsFirstWalk() async throws {
        let paired = try DNSSECFixtureBuilder.pairedAddressFixtures(
            firstCorruptAAAA: true,
            secondAddress: Data([203, 0, 113, 99])
        )
        let addresses = await DNSSECResolverWalk.addresses(
            for: paired.host,
            fetchers: [paired.first, paired.second],
            anchors: paired.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: RetiredRootAnchorStore.memory()
        )
        #expect(addresses.map(\.presentation) == ["203.0.113.99"])
        #expect(Self.sawRootDNSKEY(paired.second))
    }

    /// A verified A with AAAA absent stops. The other resolver's address is not merged in.
    @Test("A verified address set does not ask the next resolver")
    func verifiedAddressDoesNotAskNextResolver() async throws {
        let paired = try DNSSECFixtureBuilder.pairedAddressFixtures(
            firstCorruptAAAA: false,
            secondAddress: Data([203, 0, 113, 99])
        )
        let addresses = await DNSSECResolverWalk.addresses(
            for: paired.host,
            fetchers: [paired.first, paired.second],
            anchors: paired.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: RetiredRootAnchorStore.memory()
        )
        #expect(addresses.map(\.presentation) == ["203.0.113.10"])
        #expect(paired.second.queries.withLock { $0 }.isEmpty)
    }

    /// Production order is the full pinned list, then `dns.google` alone.
    @Test("The resolver walk binds the later fetcher to one resolver")
    func resolverWalkBindsLaterFetcher() {
        let fetchers = PinnedDoHFetcher.resolverWalkFetchers()
        #expect(fetchers.map { $0.resolvers?.map(\.host) } == [
            ["cloudflare-dns.com", "dns.google"],
            ["dns.google"],
        ])
    }

    private static func sawRootDNSKEY(_ fetcher: MappedDNSFetcher) -> Bool {
        let key = "\(DNSName.root.presentation)|\(DNSType.dnskey)"
        return fetcher.queries.withLock { $0.contains(key) }
    }

    private func expectRejectedRevocation(_ fixture: DNSSECFixtureBuilder.RejectedRevocationWalk) async throws {
        let store = RetiredRootAnchorStore.memory()
        let presented = DNSSECWalk(
            fetcher: fixture.presented.fetcher,
            anchors: fixture.presented.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: store
        )
        #expect(await presented.txtModels(name: fixture.childName) == .verified(["kailuakona"]))
        #expect(await store.suppresses(fixture.candidateDigest) == false)

        let onlyCandidate = DNSSECWalk(
            fetcher: fixture.onlyCandidate.fetcher,
            anchors: fixture.onlyCandidate.anchors,
            now: DNSSECFixtureBuilder.now,
            retiredAnchors: store
        )
        #expect(await onlyCandidate.txtModels(name: fixture.childName) == .verified(["kailuakona"]))
    }

}
