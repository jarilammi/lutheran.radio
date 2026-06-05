//
//  CertificateFingerprint.swift
//  Core
//
//  Created by Jari Lammi on 4.6.2026.
//

import Foundation
import CommonCrypto

/// Raw SHA-256 digest of a certificate's DER encoding (32 bytes).
///
/// Runtime pinning compares these values with constant-time equality.
/// OpenSSL-style colon-hex is materialized only for documentation and operator tooling.
public struct CertificateFingerprint: Sendable, Equatable {
    public static let byteCount = Int(CC_SHA256_DIGEST_LENGTH)

    private let storage: DigestStorage

    private typealias DigestStorage = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    /// Parses OpenSSL-style uppercase colon-separated hex (e.g. README / `openssl x509 -fingerprint -sha256`).
    public init?(colonHexUppercase hex: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(Self.byteCount)
        var index = hex.startIndex
        while index < hex.endIndex {
            if hex[index] == ":" {
                index = hex.index(after: index)
                continue
            }
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard next <= hex.endIndex, let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        guard bytes.count == Self.byteCount else { return nil }
        self.init(bytes: bytes)
    }

    init(bytes: [UInt8]) {
        precondition(bytes.count == Self.byteCount)
        storage = (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
            bytes[16], bytes[17], bytes[18], bytes[19], bytes[20], bytes[21], bytes[22], bytes[23],
            bytes[24], bytes[25], bytes[26], bytes[27], bytes[28], bytes[29], bytes[30], bytes[31]
        )
    }

    init(copyingTemporaryDigest buffer: UnsafeMutableBufferPointer<UInt8>) {
        precondition(buffer.count == Self.byteCount)
        // SAFETY: `buffer` holds exactly `byteCount` bytes written by CC_SHA256 in `sha256DERDigest`.
        storage = unsafe (
            buffer[0], buffer[1], buffer[2], buffer[3], buffer[4], buffer[5], buffer[6], buffer[7],
            buffer[8], buffer[9], buffer[10], buffer[11], buffer[12], buffer[13], buffer[14], buffer[15],
            buffer[16], buffer[17], buffer[18], buffer[19], buffer[20], buffer[21], buffer[22], buffer[23],
            buffer[24], buffer[25], buffer[26], buffer[27], buffer[28], buffer[29], buffer[30], buffer[31]
        )
    }

    /// OpenSSL-style uppercase colon-separated representation (operator / README parity).
    public var colonHexUppercase: String {
        unsafe Swift.withUnsafeBytes(of: storage) { raw in
            unsafe raw.map { unsafe String(format: "%02X", $0) }.joined(separator: ":")
        }
    }

    public static func == (lhs: CertificateFingerprint, rhs: CertificateFingerprint) -> Bool {
        lhs.constantTimeMatches(rhs)
    }

    /// Constant-time equality for runtime pinning.
    public func constantTimeMatches(_ other: CertificateFingerprint) -> Bool {
        var diff: UInt8 = 0
        unsafe Swift.withUnsafeBytes(of: storage) { lhs in
            unsafe other.withDigestBytes { rhs in
                for index in 0..<Self.byteCount {
                    unsafe diff |= lhs[index] ^ rhs[index]
                }
            }
        }
        return diff == 0
    }

    private func withDigestBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try unsafe Swift.withUnsafeBytes(of: storage, body)
    }
}

extension CertificateFingerprint {
    /// SHA-256 of DER bytes using stack-local digest storage and `Data.span` (no hex materialization).
    static func sha256DERDigest(of certData: Data) -> CertificateFingerprint? {
        guard !certData.isEmpty else { return nil }

        return unsafe withUnsafeTemporaryAllocation(of: UInt8.self, capacity: byteCount) { digestBuffer -> CertificateFingerprint? in
            // SAFETY: `digestBuffer` is stack-local; CC_SHA256 writes exactly `byteCount` bytes.
            var didHash = false
            unsafe certData.span.withUnsafeBytes { input in
                guard let inputBase = input.baseAddress else { return }
                _ = unsafe CC_SHA256(inputBase, CC_LONG(certData.count), digestBuffer.baseAddress)
                didHash = true
            }
            guard didHash else { return nil }
            return unsafe CertificateFingerprint(copyingTemporaryDigest: digestBuffer)
        }
    }
}
