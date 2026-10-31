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
//
//  - SeeAlso: ``DNSSECWalk``, ``RetiredRootAnchorStore``, ``<doc:Security-Invariants>`` Invariant 1
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
