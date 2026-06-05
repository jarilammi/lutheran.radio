//
//  CertificateFingerprintTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 5.6.2026.
//

import Testing
import Foundation
@testable import Core

@Suite("CertificateFingerprint Tests")
struct CertificateFingerprintTests {

    private static let pinnedLeafHex =
        "CC:F7:8E:09:EF:F3:3D:9A:5D:8B:B0:5C:74:28:0D:F6:BE:14:1C:C4:47:F9:69:C2:90:2C:43:97:66:8B:3D:CC"

    @Test("constantTimeMatches returns true for identical digests")
    func constantTimeMatches_equalPins() {
        let digest = SecurityConfiguration.current.pinnedLeafFingerprintDigest
        #expect(digest.constantTimeMatches(digest))
    }

    @Test("constantTimeMatches returns false when first byte differs")
    func constantTimeMatches_differFirstByte() throws {
        let base = SecurityConfiguration.current.pinnedLeafFingerprintDigest
        let altered = try #require(flipByte(in: base, at: 0))
        #expect(!base.constantTimeMatches(altered))
    }

    @Test("constantTimeMatches returns false when last byte differs")
    func constantTimeMatches_differLastByte() throws {
        let base = SecurityConfiguration.current.pinnedLeafFingerprintDigest
        let altered = try #require(flipByte(in: base, at: CertificateFingerprint.byteCount - 1))
        #expect(!base.constantTimeMatches(altered))
    }

    @Test("Equatable delegates to constantTimeMatches")
    func equatableUsesConstantTime() throws {
        let digest = SecurityConfiguration.current.pinnedLeafFingerprintDigest
        #expect(digest == digest)

        let altered = try #require(flipByte(in: digest, at: 15))
        #expect(digest != altered)
    }

    @Test("colonHexUppercase round-trips through parser")
    func colonHexRoundTrip() throws {
        let fromConfig = SecurityConfiguration.current.pinnedLeafFingerprintDigest
        let parsed = try #require(CertificateFingerprint(colonHexUppercase: Self.pinnedLeafHex))
        #expect(fromConfig.constantTimeMatches(parsed))
        #expect(parsed.colonHexUppercase == Self.pinnedLeafHex)
    }

    private func flipByte(in fingerprint: CertificateFingerprint, at index: Int) -> CertificateFingerprint? {
        guard var bytes = digestBytes(from: fingerprint) else { return nil }
        bytes[index] ^= 0xFF
        return CertificateFingerprint(bytes: bytes)
    }

    private func digestBytes(from fingerprint: CertificateFingerprint) -> [UInt8]? {
        let hex = fingerprint.colonHexUppercase
        var bytes = [UInt8]()
        bytes.reserveCapacity(CertificateFingerprint.byteCount)
        var index = hex.startIndex
        while index < hex.endIndex {
            if hex[index] == ":" {
                index = hex.index(after: index)
                continue
            }
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                Issue.record("Invalid hex in colonHexUppercase")
                return nil
            }
            bytes.append(byte)
            index = next
        }
        guard bytes.count == CertificateFingerprint.byteCount else {
            Issue.record("Unexpected digest length")
            return nil
        }
        return bytes
    }
}
