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
        #expect(SecurityConfiguration.hostRequiresDNSSECValidation("livestream.lutheran.radio"))
        #expect(SecurityConfiguration.hostRequiresDNSSECValidation("foo.bar.lutheran.radio"))
        #expect(SecurityConfiguration.hostRequiresDNSSECValidation("lutheran.radio") == true)
        #expect(SecurityConfiguration.hostRequiresDNSSECValidation("example.com") == false)
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

}
