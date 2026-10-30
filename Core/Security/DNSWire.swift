//
//  DNSWire.swift
//  Core
//
//  Created by Jari Lammi on 30.10.2026.
//
//  Minimal DNS wire codec for local DNSSEC verification (RFC 1035 / RFC 8484).
//
//  This file parses and builds DNS messages. It does not decide trust. Signature
//  checks, the root trust anchor, and the ordered TXT host walk live in
//  ``DNSSECWalk`` and ``SecurityModelValidator``. No port-53 socket is opened
//  here. Callers feed bytes that arrived over pinned HTTPS or from a test fixture.
//
//  Name compression is accepted on read and never emitted. A pointer loop is a
//  parse failure. The AD bit is not read.
//
//  - SeeAlso: ``DNSSECWalk``, ``<doc:Security-Invariants>`` Invariant 1
//

import Foundation

enum DNSType {
    static let a: UInt16 = 1
    static let aaaa: UInt16 = 28
    static let txt: UInt16 = 16
    static let opt: UInt16 = 41
    static let ds: UInt16 = 43
    static let rrsig: UInt16 = 46
    static let dnskey: UInt16 = 48
    static let internet: UInt16 = 1
}

/// Uncompressed DNS name. Labels are stored lowercase so comparison is canonical.
struct DNSName: Equatable, Hashable, Sendable {
    var labels: [Data]

    static let root = DNSName(labels: [])

    var isRoot: Bool { labels.isEmpty }

    var labelCount: Int { labels.count }

    /// Parent zone name. The root has no parent.
    func parent() -> DNSName? {
        guard !labels.isEmpty else { return nil }
        return DNSName(labels: Array(labels.dropFirst()))
    }

    /// `true` when this name is the zone apex or a name below it.
    func isInZone(_ zone: DNSName) -> Bool {
        if zone.isRoot { return true }
        guard labels.count >= zone.labels.count else { return false }
        return Array(labels.suffix(zone.labels.count)) == zone.labels
    }

    /// Presentation form without a trailing dot. The root is `"."`.
    var presentation: String {
        if labels.isEmpty { return "." }
        return labels.compactMap { String(bytes: $0, encoding: .utf8) }.joined(separator: ".")
    }

    /// Canonical uncompressed wire form (RFC 4034 §6.2).
    var canonicalWire: Data {
        var data = Data()
        for label in labels {
            data.append(UInt8(label.count))
            data.append(label)
        }
        data.append(0)
        return data
    }

    init(labels: [Data]) {
        self.labels = labels.map { Data($0.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }) }
    }

    /// Parses a presentation name such as `siikkari.net`. Rejects empty labels.
    init?(presentation: String) {
        let trimmed = presentation.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if trimmed.isEmpty {
            self = .root
            return
        }
        var labels: [Data] = []
        for part in trimmed.split(separator: ".") {
            let bytes = Data(part.lowercased().utf8)
            guard !bytes.isEmpty, bytes.count <= 63 else { return nil }
            labels.append(bytes)
        }
        guard !labels.isEmpty, labels.count <= 128 else { return nil }
        self.labels = labels
    }

    /// Reads a possibly compressed name. Advances `offset` over the on-wire name
    /// (two bytes when the name is a pointer), not over the compression target.
    static func parse(message: Data, offset: inout Int) -> DNSName? {
        let start = offset
        var labels: [Data] = []
        var cursor = offset
        var jumped = false
        var hops = 0
        while cursor < message.count {
            if hops > 128 { return nil }
            let length = Int(message[cursor])
            if length & 0xC0 == 0xC0 {
                guard cursor + 1 < message.count else { return nil }
                let pointer = ((length & 0x3F) << 8) | Int(message[cursor + 1])
                guard pointer < message.count, pointer != cursor else { return nil }
                if !jumped {
                    offset = cursor + 2
                    jumped = true
                }
                cursor = pointer
                hops += 1
                continue
            }
            if length & 0xC0 != 0 { return nil }
            if length == 0 {
                if !jumped { offset = cursor + 1 }
                guard offset > start || message[start] == 0 else { return nil }
                return DNSName(labels: labels)
            }
            let valueStart = cursor + 1
            let valueEnd = valueStart + length
            guard valueEnd <= message.count else { return nil }
            labels.append(message.subdata(in: valueStart..<valueEnd))
            cursor = valueEnd
            if !jumped { offset = cursor }
            if labels.count > 128 { return nil }
        }
        return nil
    }
}

struct DNSQuestion: Equatable, Sendable {
    var name: DNSName
    var type: UInt16
    var klass: UInt16
}

struct DNSRR: Equatable, Sendable {
    var name: DNSName
    var type: UInt16
    var klass: UInt16
    var ttl: UInt32
    var rdata: Data
    /// Offset of `rdata` inside ``DNSMessage/raw``. Zero when the record was not parsed from a message.
    var rdataOffset: Int = 0
}

struct DNSMessage: Equatable, Sendable {
    var id: UInt16
    var isResponse: Bool
    var truncated: Bool
    var rcode: Int
    var questions: [DNSQuestion]
    var answers: [DNSRR]
    /// Original bytes. RRSIG signer names may use compression pointers into this buffer.
    var raw: Data = Data()

    /// Builds a recursive, checking-disabled query with EDNS DO set.
    ///
    /// CD is set so a resolver returns the RRset and its RRSIG even when that
    /// resolver did not validate. The AD bit on the response is ignored.
    static func query(id: UInt16, name: DNSName, type: UInt16) -> Data {
        var data = Data()
        data.appendU16(id)
        // RD + CD. QR is clear. AD is not set.
        data.appendU16(0x0110)
        data.appendU16(1)
        data.appendU16(0)
        data.appendU16(0)
        data.appendU16(1)
        data.append(name.canonicalWire)
        data.appendU16(type)
        data.appendU16(DNSType.internet)
        // OPT: payload 1232, DO bit in the extended flags.
        data.append(0)
        data.appendU16(DNSType.opt)
        data.appendU16(1232)
        data.appendU32(0x0000_8000)
        data.appendU16(0)
        return data
    }

    /// Uncompressed response used by fixtures. Production bytes come from DoH.
    static func response(id: UInt16, rcode: Int, question: DNSQuestion, answers: [DNSRR]) -> Data {
        var data = Data()
        data.appendU16(id)
        var flags: UInt16 = 0x8180 // QR, RD, RA
        flags |= UInt16(rcode & 0xF)
        data.appendU16(flags)
        data.appendU16(1)
        data.appendU16(UInt16(answers.count))
        data.appendU16(0)
        data.appendU16(0)
        data.append(question.name.canonicalWire)
        data.appendU16(question.type)
        data.appendU16(question.klass)
        for rr in answers {
            data.append(rr.name.canonicalWire)
            data.appendU16(rr.type)
            data.appendU16(rr.klass)
            data.appendU32(rr.ttl)
            data.appendU16(UInt16(rr.rdata.count))
            data.append(rr.rdata)
        }
        return data
    }

    static func parse(_ data: Data) -> DNSMessage? {
        guard data.count >= 12, data.count <= 65_535 else { return nil }
        let id = data.readU16(0)
        let flags = data.readU16(2)
        let questionCount = Int(data.readU16(4))
        let answerCount = Int(data.readU16(6))
        let authorityCount = Int(data.readU16(8))
        let additionalCount = Int(data.readU16(10))
        guard questionCount <= 8,
              answerCount <= 64,
              authorityCount <= 64,
              additionalCount <= 16 else { return nil }
        var offset = 12
        var questions: [DNSQuestion] = []
        for _ in 0..<questionCount {
            guard let name = DNSName.parse(message: data, offset: &offset),
                  let type = data.readU16(&offset),
                  let klass = data.readU16(&offset) else { return nil }
            questions.append(DNSQuestion(name: name, type: type, klass: klass))
        }
        func readRRs(_ count: Int) -> [DNSRR]? {
            var records: [DNSRR] = []
            for _ in 0..<count {
                guard let name = DNSName.parse(message: data, offset: &offset),
                      let type = data.readU16(&offset),
                      let klass = data.readU16(&offset),
                      let ttl = data.readU32(&offset),
                      let rdlen = data.readU16(&offset) else { return nil }
                let length = Int(rdlen)
                guard length <= 4096, offset + length <= data.count else { return nil }
                let rdataOffset = offset
                let rdata = data.subdata(in: offset..<(offset + length))
                offset += length
                records.append(DNSRR(
                    name: name,
                    type: type,
                    klass: klass,
                    ttl: ttl,
                    rdata: rdata,
                    rdataOffset: rdataOffset
                ))
            }
            return records
        }
        guard let answers = readRRs(answerCount),
              readRRs(authorityCount) != nil,
              readRRs(additionalCount) != nil else { return nil }
        return DNSMessage(
            id: id,
            isResponse: (flags & 0x8000) != 0,
            truncated: (flags & 0x0200) != 0,
            rcode: Int(flags & 0x000F),
            questions: questions,
            answers: answers,
            raw: data
        )
    }
}

extension Data {
    mutating func appendU16(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func appendU32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    fileprivate func readU16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    fileprivate func readU16(_ offset: inout Int) -> UInt16? {
        guard offset + 2 <= count else { return nil }
        let value = readU16(offset)
        offset += 2
        return value
    }

    fileprivate func readU32(_ offset: inout Int) -> UInt32? {
        guard offset + 4 <= count else { return nil }
        let value = UInt32(self[offset]) << 24
            | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8
            | UInt32(self[offset + 3])
        offset += 4
        return value
    }
}
