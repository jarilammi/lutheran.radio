//
//  CoreTests.swift
//  CoreTests
//
//  Created by Jari Lammi on 21.3.2026.
//

import Testing
import Foundation   // Required under MemberImportVisibility for URLSessionConfiguration properties
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

    /// The verify completion is invoked once through the copied block and then released.
    ///
    /// This is the lifetime `withoutActuallyEscaping` aborted inside the boringssl callback.
    @Test func verifyCompletionInvokesTheCopiedBlockOnce() {
        final class Flag { var value: Bool? }
        let flag = Flag()
        let block: @convention(block) (Bool) -> Void = { flag.value = $0 }
        let raw = unsafe unsafeBitCast(block, to: UnsafeRawPointer.self)
        let box = unsafe TLSVerifyCompletion(copying: raw)
        unsafe box.call(true)
        #expect(flag.value == true)
        unsafe box.call(false)
        #expect(flag.value == true)
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

}
