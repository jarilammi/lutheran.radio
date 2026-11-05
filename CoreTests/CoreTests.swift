//
//  CoreTests.swift
//  CoreTests
//
//  Created by Jari Lammi on 21.3.2026.
//

import Testing
import Foundation   // Required under MemberImportVisibility for URLSessionConfiguration properties
@unsafe @preconcurrency import Security
@testable import Core

struct CoreTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    @Test func securityConfigurationSecureFactoryEnablesDNSSEC() async throws {
        let config = SecurityConfiguration.makeSecureEphemeralConfiguration()

        #expect(config.requiresDNSSECValidation == true)
        #expect(config.urlCache == nil)
        #expect(SecurityConfiguration.hostRequiresDNSSECValidation("livestream.siikkari.net"))
        #expect(SecurityConfiguration.hostRequiresDNSSECValidation("foo.bar.siikkari.net"))
        #expect(SecurityConfiguration.hostRequiresDNSSECValidation("siikkari.net") == true)
        // Media apex cutover: lutheran.radio is no longer a protected streaming host.
        #expect(SecurityConfiguration.hostRequiresDNSSECValidation("livestream.lutheran.radio") == false)
        #expect(SecurityConfiguration.hostRequiresDNSSECValidation("example.com") == false)
    }

    /// The normal factory stays DNSSEC-on. The retry factory is the only one that clears the flag.
    @Test func verifiedAddressRetryFactoryClearsDNSSECOnlyThere() {
        let normal = SecurityConfiguration.makeSecureEphemeralConfiguration()
        let retry = SecurityConfiguration.makeVerifiedAddressRetryConfiguration()
        #expect(SecurityConfiguration.current.requiresDNSSECValidationForStreaming)
        #expect(normal.requiresDNSSECValidation == true)
        #expect(retry.requiresDNSSECValidation == false)
        #expect(retry.urlCache == nil)
        #expect(retry.urlCredentialStorage == nil)
    }

    /// The verified-address pin wait rejects when it expires, and it ends before the
    /// shortest flag-off request timeout so `stopLoading` can run on the same queue.
    ///
    /// Ten seconds is not the 5 s DNS TXT watchdog and not the 10-minute pin cache.
    @Test func verifiedAddressPinEvaluationLimitFitsInsideTheFlagOffRequestTimeout() {
        let limit = SecurityConfiguration.current.verifiedAddressPinEvaluationLimit
        #expect(limit == 10)
        #expect(limit > 5)
        #expect(limit < ProtectedHostHTTPS.defaultRetryTimeout)
        #expect(limit != SecurityConfiguration.current.certificateValidationCacheDuration)
    }

    /// A finished accept is the only `true`. A finished rejection returns without waiting out the deadline.
    @Test func pinGateReturnsTheFinishedBoolean() {
        let accepted = VerifiedAddressPinGate()
        accepted.finish(true)
        #expect(accepted.waitForResult(until: .now() + .seconds(2)) == true)

        let rejected = VerifiedAddressPinGate()
        let started = ContinuousClock.now
        rejected.finish(false)
        #expect(rejected.waitForResult(until: .now() + .seconds(2)) == false)
        #expect(started.duration(to: .now) < .milliseconds(500))
    }

    /// Expiry is `false`. A later `finish(true)` must not become a second wait's accept.
    ///
    /// The production callback calls `complete` with the first result and returns.
    /// The semaphore has to stay alive for that late finish, and the stored decision stays expired.
    @Test func pinGateExpiryIgnoresALateAccept() {
        let gate = VerifiedAddressPinGate()
        #expect(gate.waitForResult(until: .now() + .milliseconds(40)) == false)
        gate.finish(true)
        #expect(gate.waitForResult(until: .now() + .milliseconds(40)) == false)
    }

    /// An accept that arrives while the waiter is blocked is the handshake's result.
    ///
    /// The finisher is a GCD queue. The waiter must not be a Swift task blocked on this
    /// semaphore: production waits on `radio.lutheran.verified-address`.
    @Test func pinGateReadsAnAcceptThatArrivesWhileWaiting() {
        let gate = VerifiedAddressPinGate()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(30)) {
            gate.finish(true)
        }
        #expect(gate.waitForResult(until: .now() + .seconds(2)) == true)
    }

    /// An empty chain fails closed. The verify callback then calls `complete(false)` without waiting.
    @Test func isolatedServerTrustRejectsAnEmptyChain() {
        let empty: [SecCertificate] = []
        #expect(IsolatedServerTrust.make(certificates: empty as CFArray) == nil)
    }

    /// The copy is a different `SecTrust` with the same leaf. The pin check reads that leaf's SPKI.
    ///
    /// The fixture is the unpinned example leaf used by the certificate tests. This test does not
    /// evaluate trust and does not open the network.
    @Test func isolatedServerTrustCopiesTheLeafOntoANewObject() throws {
        let handshake = try trustFromHex(unpinnedLeafDERHex)
        let isolated = try #require(IsolatedServerTrust.make(from: handshake))
        #expect(isolated !== handshake)
        let handshakeLeaf = try #require(leafDER(handshake))
        let isolatedLeaf = try #require(leafDER(isolated))
        #expect(isolatedLeaf == handshakeLeaf)
        let handshakeSPKI = try #require(SubjectPublicKeyInfo.leafFingerprint(trust: handshake))
        let isolatedSPKI = try #require(SubjectPublicKeyInfo.leafFingerprint(trust: isolated))
        #expect(isolatedSPKI == handshakeSPKI)
    }

    /// The TLS verify completion is a Swift function, wider than a pointer.
    ///
    /// `unsafeBitCast` to `UnsafeRawPointer` traps at runtime
    /// ("Can't unsafeBitCast between types of different sizes"). The verify
    /// callback calls it before returning.
    @Test func verifyCompletionIsWiderThanAPointer() {
        // A pointer is one word. The imported completion is a Swift function, two words.
        #expect(MemoryLayout<sec_protocol_verify_complete_t>.size == 2 * MemoryLayout<Int>.size)
    }

    /// Flag-off retry requires the DNSSEC-not-completed shape and a verified address.
    @Test func flagOffRetryRequiresDNSSECNotCompletedAndAddresses() {
        let silence = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [
                "_kCFStreamErrorDomainKey": NSNumber(value: 4),
                "_kCFStreamErrorCodeKey": NSNumber(value: -2102),
            ]
        )
        let plain = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(ProtectedHostHTTPS.allowsFlagOffRetry(error: silence, verifiedAddressCount: 1, alreadyRetried: false))
        #expect(ProtectedHostHTTPS.allowsFlagOffRetry(error: silence, verifiedAddressCount: 0, alreadyRetried: false) == false)
        #expect(ProtectedHostHTTPS.allowsFlagOffRetry(error: silence, verifiedAddressCount: 1, alreadyRetried: true) == false)
        #expect(ProtectedHostHTTPS.allowsFlagOffRetry(error: plain, verifiedAddressCount: 2, alreadyRetried: false) == false)
        let wrapped = NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown, userInfo: [NSUnderlyingErrorKey: silence])
        #expect(ProtectedHostHTTPS.isSystemDNSSECNotCompleted(wrapped))
    }

    /// Protects the invariant that DNS TXT success caching and runtime certificate
    /// pin-result caching use distinct durations (1 hour vs 10 minutes).
    ///
    /// Coupling them previously caused `CertificateValidator` to reuse successes for
    /// 3600 s while permanent docs and the streaming periodic HEAD timer specified 600 s.
    @Test func securityConfigurationCertificateAndModelCacheDurationsAreDistinct() {
        let policy = SecurityConfiguration.current
        #expect(policy.certificateValidationCacheDuration == 600)
        #expect(policy.modelCacheDuration == 3_600)
        #expect(policy.certificateValidationCacheDuration != policy.modelCacheDuration)
    }

    /// Media apex SSOT is `siikkari.net` only; DNS TXT hosts remain independent.
    ///
    /// Protects Invariant 5 (configuration centralization) for streaming apex policy
    /// and confirms TXT allow-list hosts are not coupled to the media apex list.
    @Test func securityConfigurationPreferredStreamingDomainIsSiikkariOnly() {
        let policy = SecurityConfiguration.current
        #expect(policy.preferredStreamingDomainSuffixes == [
            "siikkari.net"
        ])
        #expect(policy.preferredStreamingDomainSuffix == "siikkari.net")

        // TXT security-model hosts: siikkari primary, then established allow-list
        // fallbacks (independent of media apex list construction).
        #expect(policy.securityModelDomains == [
            "securitymodels.siikkari.net",
            "securitymodels.lutheranradio.eu",
            "securitymodels.lutheranradio.sk"
        ])
        #expect(policy.primarySecurityModelDomain == "securitymodels.siikkari.net")
        #expect(policy.secondarySecurityModelDomain == "securitymodels.lutheranradio.eu")
        #expect(policy.backupSecurityModelDomain == "securitymodels.lutheranradio.sk")
    }

    /// DNSSEC host policy must cover the sole media apex (bare + subdomain) and
    /// must **not** treat retired `lutheran.radio` media hosts as protected streaming.
    @Test func securityConfigurationHostRequiresDNSSECValidationCoversSiikkariOnly() {
        let policy = SecurityConfiguration.current

        #expect(policy.isProtectedStreamingHost("siikkari.net"))
        #expect(policy.isProtectedStreamingHost("english-eu.siikkari.net"))
        #expect(policy.isProtectedStreamingHost("european.siikkari.net"))
        #expect(SecurityConfiguration.hostRequiresDNSSECValidation("livestream.siikkari.net"))
        #expect(SecurityConfiguration.hostRequiresDNSSECValidation("SIIKKARI.NET"))

        #expect(policy.isProtectedStreamingHost("lutheran.radio") == false)
        #expect(policy.isProtectedStreamingHost("english-eu.lutheran.radio") == false)
        #expect(SecurityConfiguration.hostRequiresDNSSECValidation("livestream.lutheran.radio") == false)

        #expect(policy.isProtectedStreamingHost("evil-siikkari.net") == false)
        #expect(policy.isProtectedStreamingHost("siikkari.net.evil.example") == false)
        #expect(policy.isProtectedStreamingHost("notsiikkari.net") == false)
        #expect(SecurityConfiguration.hostRequiresDNSSECValidation(nil) == false)
        #expect(SecurityConfiguration.hostRequiresDNSSECValidation("example.com") == false)
    }

    /// Candidate host builder emits the sole media apex without hard-coded strings.
    @Test func securityConfigurationStreamingHostCandidatesUseSiikkariOnly() {
        let candidates = SecurityConfiguration.current.streamingHostCandidates(leadingLabel: "english-eu")
        #expect(candidates == [
            "english-eu.siikkari.net"
        ])
    }

    /// Runtime pin list accepts **only** the live `*.siikkari.net` leaf. The retired
    /// pre-cutover leaf must not remain on the production acceptance list.
    ///
    /// Protects Invariant 3 / 5: digests live only in SecurityConfiguration; validator
    /// walks ``pinnedFingerprintDigests``; production does not enlarge the MITM target
    /// set with obsolete leaf digests after media apex cutover.
    @Test func securityConfigurationPinnedFingerprintDigestsContainOnlyLiveSiikkariLeaf() {
        let policy = SecurityConfiguration.current
        let digests = policy.pinnedFingerprintDigests
        let live =
            "32:82:5E:97:8C:F7:1F:F1:0C:F6:80:9D:2D:15:C8:1D:AA:85:65:28:F4:67:D6:E5:1B:6F:7A:5F:B2:18:70:CD"
        let retiredHistorical =
            "CC:F7:8E:09:EF:F3:3D:9A:5D:8B:B0:5C:74:28:0D:F6:BE:14:1C:C4:47:F9:69:C2:90:2C:43:97:66:8B:3D:CC"

        #expect(digests.count == 1)
        #expect(digests[0].constantTimeMatches(policy.pinnedLeafFingerprintDigest))
        #expect(policy.pinnedLeafFingerprintDigest.constantTimeMatches(policy.pinnedSiikkariLeafFingerprintDigest))

        #expect(policy.pinnedLeafFingerprint == live)
        #expect(policy.pinnedSiikkariLeafFingerprint == live)

        #expect(policy.pinnedFingerprints == [live])
        #expect(!policy.pinnedFingerprints.contains(retiredHistorical))
    }

    /// The app `Info.plist` SPKI and ``pinnedMediaLeafSPKISHA256Base64`` are one key.
    ///
    /// ATS reads the plist. The Swift check reads the constant. CoreTests is hosted
    /// in the app, so `Bundle.main` here is that plist. A DoH resolver pin must not
    /// be reused as the media pin.
    @Test func appInfoPlistMediaSPKIEqualsSecurityConfiguration() throws {
        let policy = SecurityConfiguration.current
        let info = try #require(Bundle.main.infoDictionary)
        let ats = try #require(info["NSAppTransportSecurity"] as? [String: Any])
        let domains = try #require(ats["NSPinnedDomains"] as? [String: Any])
        let siikkari = try #require(domains["siikkari.net"] as? [String: Any])
        #expect(siikkari["NSIncludesSubdomains"] as? Bool == true)
        let identities = try #require(siikkari["NSPinnedLeafIdentities"] as? [[String: Any]])
        let pin = try #require(identities.first?["SPKI-SHA256-BASE64"] as? String)
        #expect(pin == policy.pinnedMediaLeafSPKISHA256Base64)
        let raw = try #require(Data(base64Encoded: policy.pinnedMediaLeafSPKISHA256Base64))
        #expect(raw.count == CertificateFingerprint.byteCount)
        let dohPins = policy.pinnedDoHResolvers.map(\.spkiSHA256Base64)
        #expect(!dohPins.contains(policy.pinnedMediaLeafSPKISHA256Base64))
    }

    /// A leaf with the media SPKI matches only for a `*.siikkari.net` host.
    ///
    /// The fixture is the public `*.siikkari.net` leaf. This test does not open
    /// the network. CoreTests is hosted in the app, whose `Info.plist` contains
    /// this pin. An empty pin string must still fail. That failure is what shows
    /// ``AppTransportSecurityPins`` does not read `Bundle.main`.
    @Test func appTransportSecurityPinsMatchMediaLeafForSiikkariHostOnly() throws {
        let trust = try trustFromHex(mediaLeafDERHex)
        let leaf = try #require(SubjectPublicKeyInfo.leafFingerprint(trust: trust))
        let pinBytes = try #require(Data(base64Encoded: SecurityConfiguration.current.pinnedMediaLeafSPKISHA256Base64))
        #expect(leaf.constantTimeMatches(CertificateFingerprint(bytes: [UInt8](pinBytes))))

        #expect(AppTransportSecurityPins.matches(trust: trust, host: "livestream.siikkari.net"))
        #expect(AppTransportSecurityPins.matches(trust: trust, host: "european.siikkari.net"))
        #expect(AppTransportSecurityPins.matches(trust: trust, host: "siikkari.net"))
        #expect(AppTransportSecurityPins.matches(trust: trust, host: "english-eu.siikkari.net"))
        #expect(AppTransportSecurityPins.matches(trust: trust, host: "Livestream.Siikkari.Net"))
        #expect(AppTransportSecurityPins.matches(trust: trust, host: "livestream.siikkari.net."))

        #expect(AppTransportSecurityPins.matches(trust: trust, host: "example.com") == false)
        #expect(AppTransportSecurityPins.matches(trust: trust, host: "livestream.lutheran.radio") == false)
        #expect(AppTransportSecurityPins.matches(trust: trust, host: "notsiikkari.net") == false)
        #expect(AppTransportSecurityPins.matches(trust: trust, host: "siikkari.net.evil.example") == false)
        #expect(AppTransportSecurityPins.matches(trust: trust, host: "") == false)

        #expect(AppTransportSecurityPins.matches(
            trust: trust,
            host: "livestream.siikkari.net",
            mediaSPKISHA256Base64: ""
        ) == false)
        let dohPin = try #require(SecurityConfiguration.current.pinnedDoHResolvers.first?.spkiSHA256Base64)
        #expect(AppTransportSecurityPins.matches(
            trust: trust,
            host: "livestream.siikkari.net",
            mediaSPKISHA256Base64: dohPin
        ) == false)

        let otherLeaf = try trustFromHex(unpinnedLeafDERHex)
        #expect(AppTransportSecurityPins.matches(trust: otherLeaf, host: "livestream.siikkari.net") == false)
    }

    /// Transition window for the next preferred-apex rotation is keyed to the live
    /// `*.siikkari.net` leaf (`notAfter` 2027-02-10) with a deliberate start on 2027-01-01.
    ///
    /// Protects Invariant 4: the bounds are absolute Gregorian GMT instants, not
    /// ``Calendar.current`` (a Buddhist, Japanese, Hebrew, or Islamic calendar
    /// reinterprets year 2027). Agents must not leave the prior 2026-07-27…2026-08-26
    /// cutover window after media cutover.
    @Test func securityConfigurationTransitionWindowMatchesSiikkariLeafExpiryLeadIn() {
        let policy = SecurityConfiguration.current
        // 2027-01-01 00:00:00 GMT and 2027-02-10 23:59:59 GMT.
        let expectedStart = Date(timeIntervalSince1970: 1_798_761_600)
        let expectedEnd = Date(timeIntervalSince1970: 1_802_303_999)

        #expect(policy.transitionWindowStart == expectedStart)
        #expect(policy.transitionWindowEnd == expectedEnd)
        #expect(policy.transitionWindowStart < policy.transitionWindowEnd)
        #expect(policy.isInTransitionWindow(at: expectedStart))
        #expect(policy.isInTransitionWindow(at: expectedEnd))
        #expect(policy.isInTransitionWindow(at: expectedStart.addingTimeInterval(86_400)))
        #expect(!policy.isInTransitionWindow(at: expectedStart.addingTimeInterval(-1)))
        #expect(!policy.isInTransitionWindow(at: expectedEnd.addingTimeInterval(1)))
    }

    /// Public `*.siikkari.net` leaf whose SPKI is ``pinnedMediaLeafSPKISHA256Base64``.
    ///
    /// Embedded so the matcher test does not contact the network. A later leaf
    /// that keeps this public key still satisfies the pin. Replace this DER when
    /// the public key itself changes.
    private var mediaLeafDERHex: String {
        "308204a53082044ba0030201020211008fc10b7c2cf6ff668dc517f7707f1377300a06082a8648ce3d0403023060310b300906035504061302474231183016060355040a130f5365637469676f204c696d69746564313730350603550403132e5365637469676f205075626c6963205365727665722041757468656e7469636174696f6e20434120445620453336301e170d3236303732373030303030305a170d3237303231303233353935395a30193117301506035504030c0e2a2e7369696b6b6172692e6e65743076301006072a8648ce3d020106052b81040022036200043dfbaf3fccfe358877bb2fbd0c147e3aa9c12cc77f46236a41ed92e733f92c27758d75eb89492a2f06f0f2c874f96513bc2a247fb6988c1663fb0491f3faa1bac666c7c596aeba0c84ee05d85ede3f421b456be010d0f58107150f0ebddd26aaa382030e3082030a301f0603551d230418301680141799a804c16fe42d70a80a103d03d3e91ab82663301d0603551d0e04160414a6326571d01f69e56350760f379fa03314c12e61300e0603551d0f0101ff040403020780300c0603551d130101ff04023000301d0603551d250416301406082b0601050507030106082b0601050507030230490603551d20044230403034060b2b06010401b231010202073025302306082b06010505070201161768747470733a2f2f7365637469676f2e636f6d2f4350533008060667810c01020130818406082b0601050507010104783076304f06082b060105050730028643687474703a2f2f6372742e7365637469676f2e636f6d2f5365637469676f5075626c696353657276657241757468656e7469636174696f6e434144564533362e637274302306082b060105050730018617687474703a2f2f6f6373702e7365637469676f2e636f6d30270603551d110420301e820e2a2e7369696b6b6172692e6e6574820c7369696b6b6172692e6e65743082018e060a2b06010401d6790204020482017e0482017a01780077001c9f682ce9faf0456950f81b968a87dddb3210d84ce6c8b2e382524ac4cf599f0000019fa2cf48fa00000403004830460221008d15f523cdc587043a67fb0d137ed178da805ddc84768f498b845f948a7e44d9022100f3ab6b30dff609721c56cd9836cc1400f478b33cc2c86ef17e98277aa24ac8d0007e008eca470bacde6af3a206b0a47a84b746fe1fc6bf953e25e69b4ee40248f3c6e80000019fa2cf4c0f0008000005000713d7ed04030047304502206f3694dd1b74b7a1b65b9772053599c84aa2f10430b3155d3181a3b3ad2300f2022100839fea0eba81832e284c040acee5a9d39cb3c509332755d05e6aef7a8daeb29c007d00596e6c338694b25972a256c8a0e8dd904a76e8083dda873b01083828143cee590000019fa2cf499f0008000005000053e9e5040300463044022038ba8c5dea378a59b3c2019bf8954b8133af4cab3b8e5725b62231b09dac9dab02204ed0e3bf11a85a4200bdb389b14f2b55f7f44db0ddfc4c3d2fe3fd0b3c910673300a06082a8648ce3d040302034800304502206a5dee09460872b2336b781938590f7394ee922e688e9720936af7f599b54d66022100e0805d0a90230092e7b35b189ab170665eb34131e0399896048ccf92c6fd0fd8"
    }

    /// Leaf that is not on ``pinnedFingerprintDigests``. Copied here so the trust-isolation
    /// test does not evaluate it and does not depend on the app-target helper.
    private var unpinnedLeafDERHex: String {
        "308201573081ffa003020102021412b1fc2cbbb59f804f114f22940b299505a0ce3b300a06082a8648ce3d040302301b3119301706035504030c10756e70696e6e65642e6578616d706c65301e170d3230303130313030303030305a170d3336303130313030303030305a301b3119301706035504030c10756e70696e6e65642e6578616d706c653059301306072a8648ce3d020106082a8648ce3d03010703420004f412bb1f6ced16551cc21240b88b96694a7ab0f15c81307a95535f0b2e912121a6a049cc120df6ab1872a7006968f8683819cc66fdef483c72ced1290f91931ca321301f301d0603551d0e041604141b7d4bc13886be706bbd1a6a4d22a0056acc13f6300a06082a8648ce3d040302034700304402207bdac94c3923bdd5c44ab314455022b4b6ecf080e9607b1833ea9a4823f39b50022056280733f1df43c126f2d3baa9409f42dede3910cb846a13b4e95912ea6acab8"
    }

    private func derFromHex(_ hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private func trustFromHex(_ hex: String) throws -> SecTrust {
        let der = try #require(derFromHex(hex))
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        let policy = SecPolicyCreateBasicX509()
        var trust: SecTrust?
        // SAFETY: SecTrustCreateWithCertificates writes a +1 trust through `trust` for this fixture.
        let status = unsafe SecTrustCreateWithCertificates(certificate, policy, &trust)
        #expect(status == errSecSuccess)
        return try #require(trust)
    }

    private func leafDER(_ trust: SecTrust) -> Data? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return nil
        }
        return SecCertificateCopyData(leaf) as Data
    }

}
