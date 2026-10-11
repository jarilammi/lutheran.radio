//
//  CertificateValidatorTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 24.7.2025.
//

import Testing
import Foundation
import Security
@testable import Core

@Suite("CertificateValidator Tests")
struct CertificateValidatorTests {
    
    // MARK: - Cache policy SSOT
    
    /// Successful pin-result reuse must use ``certificateValidationCacheDuration``
    /// (10 minutes), not the DNS TXT ``modelCacheDuration`` (1 hour).
    @Test("certificate pin-result cache duration is 10 minutes and distinct from model cache")
    func certificateValidationCacheDurationPolicy() {
        let policy = SecurityConfiguration.current
        #expect(policy.certificateValidationCacheDuration == 600)
        #expect(policy.modelCacheDuration == 3_600)
        #expect(policy.certificateValidationCacheDuration < policy.modelCacheDuration)
    }
    
    // MARK: - Fingerprint Computation
    
    @Test("computeCertificateFingerprint returns correct SHA-256 fingerprint")
    func computeCertificateFingerprint() async throws {
        // Arrange: Use a known certificate DER data and expected fingerprint
        // Note: Replace with actual DER bytes from a test certificate
        // For example, a sample self-signed cert DER (base64 encoded or hex)
        let sampleDERHex = "308204a53082044ba0030201020211008fc10b7c2cf6ff668dc517f7707f1377300a06082a8648ce3d0403023060310b300906035504061302474231183016060355040a130f5365637469676f204c696d69746564313730350603550403132e5365637469676f205075626c6963205365727665722041757468656e7469636174696f6e20434120445620453336301e170d3236303732373030303030305a170d3237303231303233353935395a30193117301506035504030c0e2a2e7369696b6b6172692e6e65743076301006072a8648ce3d020106052b81040022036200043dfbaf3fccfe358877bb2fbd0c147e3aa9c12cc77f46236a41ed92e733f92c27758d75eb89492a2f06f0f2c874f96513bc2a247fb6988c1663fb0491f3faa1bac666c7c596aeba0c84ee05d85ede3f421b456be010d0f58107150f0ebddd26aaa382030e3082030a301f0603551d230418301680141799a804c16fe42d70a80a103d03d3e91ab82663301d0603551d0e04160414a6326571d01f69e56350760f379fa03314c12e61300e0603551d0f0101ff040403020780300c0603551d130101ff04023000301d0603551d250416301406082b0601050507030106082b0601050507030230490603551d20044230403034060b2b06010401b231010202073025302306082b06010505070201161768747470733a2f2f7365637469676f2e636f6d2f4350533008060667810c01020130818406082b0601050507010104783076304f06082b060105050730028643687474703a2f2f6372742e7365637469676f2e636f6d2f5365637469676f5075626c696353657276657241757468656e7469636174696f6e434144564533362e637274302306082b060105050730018617687474703a2f2f6f6373702e7365637469676f2e636f6d30270603551d110420301e820e2a2e7369696b6b6172692e6e6574820c7369696b6b6172692e6e65743082018e060a2b06010401d6790204020482017e0482017a01780077001c9f682ce9faf0456950f81b968a87dddb3210d84ce6c8b2e382524ac4cf599f0000019fa2cf48fa00000403004830460221008d15f523cdc587043a67fb0d137ed178da805ddc84768f498b845f948a7e44d9022100f3ab6b30dff609721c56cd9836cc1400f478b33cc2c86ef17e98277aa24ac8d0007e008eca470bacde6af3a206b0a47a84b746fe1fc6bf953e25e69b4ee40248f3c6e80000019fa2cf4c0f0008000005000713d7ed04030047304502206f3694dd1b74b7a1b65b9772053599c84aa2f10430b3155d3181a3b3ad2300f2022100839fea0eba81832e284c040acee5a9d39cb3c509332755d05e6aef7a8daeb29c007d00596e6c338694b25972a256c8a0e8dd904a76e8083dda873b01083828143cee590000019fa2cf499f0008000005000053e9e5040300463044022038ba8c5dea378a59b3c2019bf8954b8133af4cab3b8e5725b62231b09dac9dab02204ed0e3bf11a85a4200bdb389b14f2b55f7f44db0ddfc4c3d2fe3fd0b3c910673300a06082a8648ce3d040302034800304502206a5dee09460872b2336b781938590f7394ee922e688e9720936af7f599b54d66022100e0805d0a90230092e7b35b189ab170665eb34131e0399896048ccf92c6fd0fd8"  // Full DER hex from openssl s_client -connect livestream.siikkari.net:443 -servername livestream.siikkari.net < /dev/null | openssl x509 -outform der | xxd -p -c 0 | tr -d '\n' (matches sole production pin)
        
        guard let sampleDERData = Data(hexString: sampleDERHex) else {
            Issue.record("Invalid test DER data")
            return
        }
        
        guard let certificate = SecCertificateCreateWithData(nil, sampleDERData as CFData) else {
            Issue.record("Failed to create SecCertificate from test data")
            return
        }
        
        let expectedDigest = SecurityConfiguration.current.pinnedLeafFingerprintDigest
        
        let validator = CertificateValidator()
        let computedDigest = await validator.computeCertificateFingerprintDigest(for: certificate)
        
        #expect(computedDigest == expectedDigest)
        
        let computedHex = await validator.computeCertificateFingerprint(for: certificate)
        #expect(computedHex == expectedDigest.colonHexUppercase)
    }
    
    // MARK: - Chain & Server Trust Validation
    
    @Test("validateCertificateChain returns true for matching fingerprint")
    func validateCertificateChain_Matching() async throws {
        let validator = CertificateValidator()
        let mockTrust = createMockSecTrust()
        
        let isValid = await validator.validateCertificateChain(serverTrust: mockTrust)
        #expect(isValid == true)
    }
    
    @Test("validateServerTrust returns true for valid certificate")
    func validateServerTrust_Valid() async throws {
        let validator = CertificateValidator()
        let mockTrust = createMockSecTrust()
        
        let isValid = await validator.validateServerTrust(mockTrust)
        #expect(isValid == true)
    }
    
    @Test("validateServerTrust returns true during transition window (leniency active)")
    func validateServerTrust_DuringTransition() async throws {
        let transitionDate = SecurityConfiguration.current.transitionWindowStart.addingTimeInterval(3600)
        let validator = CertificateValidator(currentDate: { transitionDate })
        
        let mockTrust = createMockSecTrust()
        
        let isValid = await validator.validateServerTrust(mockTrust)
        #expect(isValid == true, "A pinned leaf stays accepted during the transition window")
    }

    /// Invariant 4: outside the Gregorian GMT window a leaf that is not on
    /// ``pinnedFingerprintDigests`` is a hard failure even though this fixture
    /// passes `SecTrustEvaluateWithError` (the test installs it as the sole anchor).
    @Test(
        "Pin mismatch outside the transition window is a hard failure",
        arguments: [
            Date(timeIntervalSince1970: 1_798_761_600 - 86_400),
            Date(timeIntervalSince1970: 1_802_303_999 + 86_400)
        ]
    )
    func validateServerTrust_unpinnedOutsideWindow(deviceDate: Date) async {
        let validator = CertificateValidator(currentDate: { deviceDate })
        let isValid = await validator.validateServerTrust(createUnpinnedSecTrust())
        #expect(isValid == false)
    }

    /// Invariant 3 and 4: a leniency accept is not a 10-minute pin-cache hit.
    /// After the latch drops, the next challenge must re-evaluate the leaf.
    @Test("Leniency accept is not reused after the latch turns off")
    func leniencyAcceptIsNotCachedAfterLatch() async {
        let insideWindow = Date(timeIntervalSince1970: 1_798_761_600 + 3_600)
        let validator = CertificateValidator(currentDate: { insideWindow })

        // A fresh `SecTrust` per call. Reusing one value across `await` is a
        // sending violation: `SecTrust` is not `Sendable`.
        let first = await validator.validateServerTrust(createUnpinnedSecTrust())
        #expect(first == true, "ATS fallback applies inside the window while the latch is on")

        let latched = await validator.noteServerDateForTransitionLeniency(
            serverDate: insideWindow.addingTimeInterval(301)
        )
        #expect(latched == false)

        let second = await validator.validateServerTrust(createUnpinnedSecTrust())
        #expect(second == false, "A leniency accept must not satisfy the pin-result cache")
        let stillOff = await validator.allowTransitionLeniency
        #expect(stillOff == false)
    }

    /// Invariant 4: skew or a device-in-window / server-outside mismatch disables
    /// leniency for the process. A later in-skew `Date` must not turn it back on.
    @Test("Server date observation never re-enables transition leniency")
    func serverDateObservationDoesNotRearmLeniency() async {
        let start = Date(timeIntervalSince1970: 1_798_761_600)
        let inside = start.addingTimeInterval(30)
        let mismatchValidator = CertificateValidator(currentDate: { inside })
        let mismatchLatched = await mismatchValidator.noteServerDateForTransitionLeniency(
            serverDate: start.addingTimeInterval(-30)
        )
        #expect(mismatchLatched == false, "Device inside the window and server outside latches leniency off")
        let mismatchStaysOff = await mismatchValidator.noteServerDateForTransitionLeniency(serverDate: inside)
        #expect(mismatchStaysOff == false)

        let skewValidator = CertificateValidator(currentDate: { inside })
        let skewLatched = await skewValidator.noteServerDateForTransitionLeniency(
            serverDate: inside.addingTimeInterval(301)
        )
        #expect(skewLatched == false)
        let skewStaysOff = await skewValidator.noteServerDateForTransitionLeniency(serverDate: inside)
        #expect(skewStaysOff == false)

        let beforeWindow = start.addingTimeInterval(-3_600)
        let stillLenient = CertificateValidator(currentDate: { beforeWindow })
        let allowed = await stillLenient.noteServerDateForTransitionLeniency(
            serverDate: beforeWindow.addingTimeInterval(20)
        )
        #expect(allowed == true, "Skew inside 5 minutes and both clocks outside the window leaves the latch on")
    }
    
    // MARK: - Helpers
    
    private func createMockSecTrust() -> SecTrust {
        let sampleDERHex = "308204a53082044ba0030201020211008fc10b7c2cf6ff668dc517f7707f1377300a06082a8648ce3d0403023060310b300906035504061302474231183016060355040a130f5365637469676f204c696d69746564313730350603550403132e5365637469676f205075626c6963205365727665722041757468656e7469636174696f6e20434120445620453336301e170d3236303732373030303030305a170d3237303231303233353935395a30193117301506035504030c0e2a2e7369696b6b6172692e6e65743076301006072a8648ce3d020106052b81040022036200043dfbaf3fccfe358877bb2fbd0c147e3aa9c12cc77f46236a41ed92e733f92c27758d75eb89492a2f06f0f2c874f96513bc2a247fb6988c1663fb0491f3faa1bac666c7c596aeba0c84ee05d85ede3f421b456be010d0f58107150f0ebddd26aaa382030e3082030a301f0603551d230418301680141799a804c16fe42d70a80a103d03d3e91ab82663301d0603551d0e04160414a6326571d01f69e56350760f379fa03314c12e61300e0603551d0f0101ff040403020780300c0603551d130101ff04023000301d0603551d250416301406082b0601050507030106082b0601050507030230490603551d20044230403034060b2b06010401b231010202073025302306082b06010505070201161768747470733a2f2f7365637469676f2e636f6d2f4350533008060667810c01020130818406082b0601050507010104783076304f06082b060105050730028643687474703a2f2f6372742e7365637469676f2e636f6d2f5365637469676f5075626c696353657276657241757468656e7469636174696f6e434144564533362e637274302306082b060105050730018617687474703a2f2f6f6373702e7365637469676f2e636f6d30270603551d110420301e820e2a2e7369696b6b6172692e6e6574820c7369696b6b6172692e6e65743082018e060a2b06010401d6790204020482017e0482017a01780077001c9f682ce9faf0456950f81b968a87dddb3210d84ce6c8b2e382524ac4cf599f0000019fa2cf48fa00000403004830460221008d15f523cdc587043a67fb0d137ed178da805ddc84768f498b845f948a7e44d9022100f3ab6b30dff609721c56cd9836cc1400f478b33cc2c86ef17e98277aa24ac8d0007e008eca470bacde6af3a206b0a47a84b746fe1fc6bf953e25e69b4ee40248f3c6e80000019fa2cf4c0f0008000005000713d7ed04030047304502206f3694dd1b74b7a1b65b9772053599c84aa2f10430b3155d3181a3b3ad2300f2022100839fea0eba81832e284c040acee5a9d39cb3c509332755d05e6aef7a8daeb29c007d00596e6c338694b25972a256c8a0e8dd904a76e8083dda873b01083828143cee590000019fa2cf499f0008000005000053e9e5040300463044022038ba8c5dea378a59b3c2019bf8954b8133af4cab3b8e5725b62231b09dac9dab02204ed0e3bf11a85a4200bdb389b14f2b55f7f44db0ddfc4c3d2fe3fd0b3c910673300a06082a8648ce3d040302034800304502206a5dee09460872b2336b781938590f7394ee922e688e9720936af7f599b54d66022100e0805d0a90230092e7b35b189ab170665eb34131e0399896048ccf92c6fd0fd8"  // Valid DER matching sole production pin (*.siikkari.net leaf)
        
        guard let der = Data(hexString: sampleDERHex) else {
            fatalError("Invalid DER data in test helper")
        }
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            fatalError("Failed to create SecCertificate in test helper")
        }
        
        let policy = SecPolicyCreateBasicX509()
        var trust: SecTrust?
        let status = unsafe SecTrustCreateWithCertificates(cert, policy, &trust)
        
        guard status == errSecSuccess, let mockTrust = trust else {
            fatalError("Failed to create mock SecTrust: \(status)")
        }
        
        SecTrustSetAnchorCertificates(mockTrust, [cert] as CFArray)
        return mockTrust
    }

    /// Leaf that is **not** on ``pinnedFingerprintDigests``.
    ///
    /// `SecTrustSetAnchorCertificates` makes `SecTrustEvaluateWithError` succeed so
    /// the test reaches the runtime pin check. Production does not install this
    /// certificate as a trust anchor. Validity is 2020-01-01 through 2036-01-01 GMT
    /// so the system clock, not the transition window, is what the trust evaluation sees.
    private func createUnpinnedSecTrust() -> SecTrust {
        let unpinnedDERHex = "308201573081ffa003020102021412b1fc2cbbb59f804f114f22940b299505a0ce3b300a06082a8648ce3d040302301b3119301706035504030c10756e70696e6e65642e6578616d706c65301e170d3230303130313030303030305a170d3336303130313030303030305a301b3119301706035504030c10756e70696e6e65642e6578616d706c653059301306072a8648ce3d020106082a8648ce3d03010703420004f412bb1f6ced16551cc21240b88b96694a7ab0f15c81307a95535f0b2e912121a6a049cc120df6ab1872a7006968f8683819cc66fdef483c72ced1290f91931ca321301f301d0603551d0e041604141b7d4bc13886be706bbd1a6a4d22a0056acc13f6300a06082a8648ce3d040302034700304402207bdac94c3923bdd5c44ab314455022b4b6ecf080e9607b1833ea9a4823f39b50022056280733f1df43c126f2d3baa9409f42dede3910cb846a13b4e95912ea6acab8"
        guard let der = Data(hexString: unpinnedDERHex) else {
            fatalError("Invalid unpinned DER data in test helper")
        }
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            fatalError("Failed to create unpinned SecCertificate in test helper")
        }
        let policy = SecPolicyCreateBasicX509()
        var trust: SecTrust?
        let status = unsafe SecTrustCreateWithCertificates(cert, policy, &trust)
        guard status == errSecSuccess, let mockTrust = trust else {
            fatalError("Failed to create unpinned SecTrust: \(status)")
        }
        SecTrustSetAnchorCertificates(mockTrust, [cert] as CFArray)
        return mockTrust
    }
}

// MARK: - Helper extension

extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var i = hexString.startIndex
        for _ in 0..<len {
            let j = hexString.index(i, offsetBy: 2)
            let bytes = hexString[i..<j]
            if var num = UInt8(bytes, radix: 16) {
                unsafe data.append(&num, count: 1)
            } else {
                return nil
            }
            i = j
        }
        self = data
    }
}
