//
//  CertificateValidatorTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 24.7.2025.
//

import XCTest
import Security
import CommonCrypto
@testable import Lutheran_Radio

final class CertificateValidatorTests: XCTestCase {
    var validator: CertificateValidator!
    
    override func setUp() {
        super.setUp()
        validator = CertificateValidator()
    }
    
    func testComputeCertificateHash_WithValidCertificateData_ReturnsCorrectHash() throws {
        // Arrange: Use a known certificate DER data and expected hash
        // Note: Replace with actual DER bytes from a test certificate
        // For example, a sample self-signed cert DER (base64 encoded or hex)
        let sampleDERHex = "308204c83082046fa003020102021023a263781d99a86e1f86de25e5376c9d300a06082a8648ce3d04030230818f310b3009060355040613024742311b30190603550408131247726561746572204d616e636865737465723110300e0603550407130753616c666f726431183016060355040a130f5365637469676f204c696d69746564313730350603550403132e5365637469676f2045434320446f6d61696e2056616c69646174696f6e2053656375726520536572766572204341301e170d3234303732303030303030305a170d3235303832303233353935395a301b3119301706035504030c102a2e6c7574686572616e2e726164696f3076301006072a8648ce3d020106052b8104002203620004ae77100d57bac3c582f35cbf6743f71f516aac7d4672c31371f0436f35f4a83dcd95586998feb6024763f60563ab59bdc0ed34571e9d2b1aec3375d2881f903984a6c9c124abeade02f117cf895e297bcaebd789eeb153b685928c50c7cb2229a3820301308202fd301f0603551d23041830168014f6850a3b1186e1047d0eaa0b2cd2eecc647b7bae301d0603551d0e04160414b53c1d9881e0ea3d531728debb89b76608d082f7300e0603551d0f0101ff040403020780300c0603551d130101ff04023000301d0603551d250416301406082b0601050507030106082b0601050507030230490603551d20044230403034060b2b06010401b231010202073025302306082b06010505070201161768747470733a2f2f7365637469676f2e636f6d2f4350533008060667810c01020130818406082b0601050507010104783076304f06082b060105050730028643687474703a2f2f6372742e7365637469676f2e636f6d2f5365637469676f454343446f6d61696e56616c69646174696f6e53656375726553657276657243412e637274302306082b060105050730018617687474703a2f2f6f6373702e7365637469676f2e636f6d302b0603551d110424302282102a2e6c7574686572616e2e726164696f820e6c7574686572616e2e726164696f3082017d060a2b06010401d6790204020482016d048201690167007600dddcca3495d7e11605e79532fac79ff83d1c50dfdb003a1412760a2cacbbc82a00000190cfa9916a00000403004730450221009caa4857610a0f1ccb2cf703a756e304b1a988aae352bf6e5dd0a437f292c0c30220127ae597191a7f5a7e98da633eac80e3798c129ade1bce0166c7e668f1f10c6f0075000de1f2302bd30dc140621209ea552efc47747cb1d7e930ef0e421eb47e4eaa3400000190cfa99129000004030046304402204039dca16831fec0be83ec2bc5108e82bd4bc4221682722fa13d92679bc3585b0220668e9796891b39a3630703963e49dc671837a51b3ea81a28eae2f829da95438000760012f14e34bd53724c840619c38f3f7a13f8e7b56287889c6d300584ebe586263a00000190cfa991080000040300473045022100afc5c0fc5fa2f52763c8c2d5151100831bf5ac5b94c6d7b681d7239658599ce702206afd77d35edf69b734bbe787c20c430e6353801f2b5fc20538b8dc03b0bb8e86300a06082a8648ce3d0403020347003044022030658a00de3f7e37fdba527c2460dad8dec34f02e1a046c3bdab1a662024b44202204a99a59c6f9967209e0b481b6af94f14d72b661e8772bbdb63d39dd0f8f38749"  // Full DER hex from openssl s_client -connect livestream.lutheran.radio:8443 -servername livestream.lutheran.radio < /dev/null | openssl x509 -outform der | xxd -p -c 0 | tr -d '\n'
        guard let sampleDERData = Data(hexString: sampleDERHex) else {
            XCTFail("Invalid test DER data")
            return
        }
        
        guard let certificate = SecCertificateCreateWithData(nil, sampleDERData as CFData) else {
            XCTFail("Failed to create SecCertificate from test data")
            return
        }
        
        let expectedHash = "7C:A2:DB:51:07:8C:82:20:F7:B5:87:F3:05:79:65:E2:74:2C:6C:BE:72:47:69:51:B4:FE:7E:72:E2:D3:86:CC"  // Matches the pinned hash from CertificateValidator.swift
        
        // Act
        let computedHash = validator.computeCertificateHash(for: certificate)
        
        // Assert
        XCTAssertEqual(computedHash, expectedHash, "Computed hash should match expected value for known DER")
    }
    
    func testValidateCertificateChain_MatchingHash_ReturnsTrue() throws {
        // Arrange: Mock SecTrust with certificate that matches pinned hash
        let mockTrust = createMockSecTrust()
        
        // Act
        let isValid = validator.validateCertificateChain(serverTrust: mockTrust)
        
        // Assert
        XCTAssertTrue(isValid, "Should return true for matching hash")
    }
    
    func testValidateCertificateChain_NonMatchingHash_ReturnsFalse() throws {
        // Arrange: Use the top-level MismatchValidator subclass
        let mismatchValidator = MismatchValidator()
        let mockTrust = createMockSecTrust()
        
        // Act
        let isValid = mismatchValidator.validateCertificateChain(serverTrust: mockTrust)
        
        // Assert
        XCTAssertFalse(isValid, "Should return false for non-matching hash")
    }
    
    func testValidateServerTrust_DuringTransitionWithMismatch_ReturnsTrue() throws {
        // Arrange: Use the top-level MismatchValidator subclass (assume date is in transition period)
        let mismatchValidator = MismatchValidator()
        let mockTrust = createMockSecTrust()
        let exp = expectation(description: "Completion called")
        var result: Bool?
        
        // Act
        mismatchValidator.validateServerTrust(mockTrust) { isValid in
            result = isValid
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        
        // Assert
        XCTAssertTrue(result ?? false, "Should return true during transition despite mismatch")
    }
    
    // Helper to create mock SecTrust
    private func createMockSecTrust() -> SecTrust {
        let sampleDERHex = "308204c83082046fa003020102021023a263781d99a86e1f86de25e5376c9d300a06082a8648ce3d04030230818f310b3009060355040613024742311b30190603550408131247726561746572204d616e636865737465723110300e0603550407130753616c666f726431183016060355040a130f5365637469676f204c696d69746564313730350603550403132e5365637469676f2045434320446f6d61696e2056616c69646174696f6e2053656375726520536572766572204341301e170d3234303732303030303030305a170d3235303832303233353935395a301b3119301706035504030c102a2e6c7574686572616e2e726164696f3076301006072a8648ce3d020106052b8104002203620004ae77100d57bac3c582f35cbf6743f71f516aac7d4672c31371f0436f35f4a83dcd95586998feb6024763f60563ab59bdc0ed34571e9d2b1aec3375d2881f903984a6c9c124abeade02f117cf895e297bcaebd789eeb153b685928c50c7cb2229a3820301308202fd301f0603551d23041830168014f6850a3b1186e1047d0eaa0b2cd2eecc647b7bae301d0603551d0e04160414b53c1d9881e0ea3d531728debb89b76608d082f7300e0603551d0f0101ff040403020780300c0603551d130101ff04023000301d0603551d250416301406082b0601050507030106082b0601050507030230490603551d20044230403034060b2b06010401b231010202073025302306082b06010505070201161768747470733a2f2f7365637469676f2e636f6d2f4350533008060667810c01020130818406082b0601050507010104783076304f06082b060105050730028643687474703a2f2f6372742e7365637469676f2e636f6d2f5365637469676f454343446f6d61696e56616c69646174696f6e53656375726553657276657243412e637274302306082b060105050730018617687474703a2f2f6f6373702e7365637469676f2e636f6d302b0603551d110424302282102a2e6c7574686572616e2e726164696f820e6c7574686572616e2e726164696f3082017d060a2b06010401d6790204020482016d048201690167007600dddcca3495d7e11605e79532fac79ff83d1c50dfdb003a1412760a2cacbbc82a00000190cfa9916a00000403004730450221009caa4857610a0f1ccb2cf703a756e304b1a988aae352bf6e5dd0a437f292c0c30220127ae597191a7f5a7e98da633eac80e3798c129ade1bce0166c7e668f1f10c6f0075000de1f2302bd30dc140621209ea552efc47747cb1d7e930ef0e421eb47e4eaa3400000190cfa99129000004030046304402204039dca16831fec0be83ec2bc5108e82bd4bc4221682722fa13d92679bc3585b0220668e9796891b39a3630703963e49dc671837a51b3ea81a28eae2f829da95438000760012f14e34bd53724c840619c38f3f7a13f8e7b56287889c6d300584ebe586263a00000190cfa991080000040300473045022100afc5c0fc5fa2f52763c8c2d5151100831bf5ac5b94c6d7b681d7239658599ce702206afd77d35edf69b734bbe787c20c430e6353801f2b5fc20538b8dc03b0bb8e86300a06082a8648ce3d0403020347003044022030658a00de3f7e37fdba527c2460dad8dec34f02e1a046c3bdab1a662024b44202204a99a59c6f9967209e0b481b6af94f14d72b661e8772bbdb63d39dd0f8f38749"  // Valid DER matching pinned hash
        guard let der = Data(hexString: sampleDERHex) else {
            XCTFail("Invalid DER data")
            fatalError()  // For test safety
        }
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            XCTFail("Failed to create SecCertificate")
            fatalError()  // For test safety
        }
        let policy = SecPolicyCreateBasicX509()
        var trust: SecTrust?
        let createStatus = SecTrustCreateWithCertificates(cert, policy, &trust)
        guard createStatus == errSecSuccess, let mockTrust = trust else {
            XCTFail("Failed to create mock SecTrust: \(createStatus)")
            fatalError()  // For test safety
        }
        // Force trust evaluation to succeed by setting anchors
        SecTrustSetAnchorCertificates(mockTrust, [cert] as CFArray)
        return mockTrust
    }
    
    // Add more as needed
}

// Top-level subclass for testing mismatched hashes (shared across tests)
final class MismatchValidator: CertificateValidator, @unchecked Sendable {
    override var pinnedCertHash: String {
        "00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00"  // Invalid hash to force mismatch
    }
}

extension Data {
    init?(hexString: String) {
        // Implementation for hex to Data
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var i = hexString.startIndex
        for _ in 0..<len {
            let j = hexString.index(i, offsetBy: 2)
            let bytes = hexString[i..<j]
            if var num = UInt8(bytes, radix: 16) {
                data.append(&num, count: 1)
            } else {
                return nil
            }
            i = j
        }
        self = data
    }
}
