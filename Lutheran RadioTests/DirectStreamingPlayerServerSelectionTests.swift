//
//  DirectStreamingPlayerServerSelectionTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 23.8.2026.
//
//  Pure policy coverage for cluster ping reuse. Protects: same-stream hard-resume
//  may reuse the last measured server inside ``sameStreamWarmServerReuseInterval``
//  without a new EU/US ping pair; stream switch, cold launch, and recovery ``play()``
//  do not use that window; a missing stamp never reuses; the 10 s throttle still
//  applies to every context. Does not exercise real ping I/O (UITestMode isolation).
//
//  User pause remains Icecast hard-tear (``isSoftPaused`` stays false) — this suite
//  must not be “fixed” by retaining a live HTTP body.
//
//  - SeeAlso: ``DirectStreamingPlayer/shouldReuseCachedServerSelection(lastSelectionAge:allowSameStreamWarmReuse:)``,
//    ``DirectStreamingPlayer/urlWithOptimalServer(for:allowSameStreamWarmReuse:)``,
//    ``PlaybackAttachContext``, docs/Live-Activity-Stacking-and-Media-Surfaces.md,
//    docs/cold-launch-streamplay-regression-checklist.md (§5).
//

import XCTest
@testable import Lutheran_Radio
import Core
import WidgetSurface

final class DirectStreamingPlayerServerSelectionTests: XCTestCase {

    /// Protects: `/ping` sends `User-Agent: Lutheran Radio`.
    ///
    /// The origin returns HTTP 200 for that token and HTTP 403 for curl and
    /// browser agents. The token is not localized UI copy. The session factory
    /// is unchanged (`makeSecureEphemeralConfiguration`).
    func testLatencyProbeRequestSetsLutheranRadioUserAgent() {
        let url = URL(string: "https://european.siikkari.net/ping")!
        let request = DirectStreamingPlayer.latencyProbeRequest(url: url)

        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Lutheran Radio")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), DirectStreamingPlayer.latencyProbeUserAgent)
    }

    /// Protects: ``sameStreamWarmServerReuseInterval`` is strictly longer than the universal
    /// 10 s throttle so pause-then-play after the throttle expires can still skip the ping pair.
    func testSameStreamWarmReuseWindowIsLongerThanThrottle() {
        XCTAssertGreaterThan(
            DirectStreamingPlayer.sameStreamWarmServerReuseInterval,
            DirectStreamingPlayer.serverSelectionThrottleInterval,
            "Warm same-stream reuse must outlast the universal ping throttle"
        )
        XCTAssertEqual(DirectStreamingPlayer.serverSelectionThrottleInterval, 10.0)
        XCTAssertEqual(DirectStreamingPlayer.sameStreamWarmServerReuseInterval, 600.0)
    }

    /// Protects: a missing or niled ``lastServerSelectionTime`` (cold start, reconnect) always pings.
    func testMissingOrNegativeSelectionAgeNeverReuses() {
        XCTAssertFalse(
            DirectStreamingPlayer.shouldReuseCachedServerSelection(
                lastSelectionAge: nil,
                allowSameStreamWarmReuse: true
            ),
            "Nil stamp must ping even on same-stream resume"
        )
        XCTAssertFalse(
            DirectStreamingPlayer.shouldReuseCachedServerSelection(
                lastSelectionAge: -1,
                allowSameStreamWarmReuse: true
            ),
            "Negative age must not reuse"
        )
    }

    /// Protects: every attach context reuses inside the 10 s throttle, including stream switch.
    func testThrottleReusesForEveryAttachContext() {
        let age = DirectStreamingPlayer.serverSelectionThrottleInterval
        XCTAssertTrue(
            DirectStreamingPlayer.shouldReuseCachedServerSelection(
                lastSelectionAge: age,
                allowSameStreamWarmReuse: false
            ),
            "10 s throttle must skip ping for stream switch / cold launch / recovery"
        )
        XCTAssertTrue(
            DirectStreamingPlayer.shouldReuseCachedServerSelection(
                lastSelectionAge: 0,
                allowSameStreamWarmReuse: false
            )
        )
        XCTAssertTrue(
            DirectStreamingPlayer.shouldReuseCachedServerSelection(
                lastSelectionAge: 5,
                allowSameStreamWarmReuse: false
            )
        )
    }

    /// Protects: after the 10 s throttle, only same-stream hard-resume may reuse the warm cluster.
    func testWarmWindowReusesOnlyWhenSameStreamResumeIsAllowed() {
        let pastThrottle = DirectStreamingPlayer.serverSelectionThrottleInterval + 20
        XCTAssertLessThan(pastThrottle, DirectStreamingPlayer.sameStreamWarmServerReuseInterval)

        XCTAssertTrue(
            DirectStreamingPlayer.shouldReuseCachedServerSelection(
                lastSelectionAge: pastThrottle,
                allowSameStreamWarmReuse: true
            ),
            "Same-stream hard-resume must reuse a warm cluster after the 10 s throttle"
        )
        XCTAssertFalse(
            DirectStreamingPlayer.shouldReuseCachedServerSelection(
                lastSelectionAge: pastThrottle,
                allowSameStreamWarmReuse: false
            ),
            "Stream switch / cold launch / recovery must ping after the 10 s throttle"
        )
    }

    /// Protects: language switch maps to ``PlaybackAttachContext/streamSwitch``, which must not
    /// enable the warm window at the attach call site.
    func testStreamSwitchAndColdLaunchAttachContextsDoNotEnableWarmReuse() {
        XCTAssertEqual(
            PlaybackPlayDecision.attachContext(
                classification: .streamSwitch,
                declinedSoftPauseForLanguageChange: false
            ),
            .streamSwitch
        )
        XCTAssertEqual(
            PlaybackPlayDecision.attachContext(
                classification: .trueColdLaunch,
                declinedSoftPauseForLanguageChange: false
            ),
            .coldLaunch
        )
        XCTAssertEqual(
            PlaybackPlayDecision.attachContext(
                classification: .resume,
                declinedSoftPauseForLanguageChange: false
            ),
            .resume
        )
        XCTAssertEqual(
            PlaybackPlayDecision.attachContext(
                classification: .resume,
                declinedSoftPauseForLanguageChange: true
            ),
            .streamSwitch,
            "Soft-pause declined for language change is stream switch — must ping after throttle"
        )

        let pastThrottle = DirectStreamingPlayer.serverSelectionThrottleInterval + 20
        XCTAssertFalse(
            DirectStreamingPlayer.shouldReuseCachedServerSelection(
                lastSelectionAge: pastThrottle,
                allowSameStreamWarmReuse: PlaybackPlayDecision.attachContext(
                    classification: .streamSwitch,
                    declinedSoftPauseForLanguageChange: false
                ) == .resume
            )
        )
        XCTAssertTrue(
            DirectStreamingPlayer.shouldReuseCachedServerSelection(
                lastSelectionAge: pastThrottle,
                allowSameStreamWarmReuse: PlaybackPlayDecision.attachContext(
                    classification: .resume,
                    declinedSoftPauseForLanguageChange: false
                ) == .resume
            )
        )
        let fresh = PlaybackPlayDecision.attachContext(
            classification: .resume,
            declinedSoftPauseForLanguageChange: false,
            freshAttachAfterHardTeardown: true
        )
        XCTAssertEqual(fresh, .freshAttachAfterHardTeardown)
        XCTAssertFalse(
            DirectStreamingPlayer.shouldReuseCachedServerSelection(
                lastSelectionAge: pastThrottle,
                allowSameStreamWarmReuse: fresh.allowsSameStreamWarmClusterReuse
            ),
            "Fresh attach after hard teardown must not use the warm window"
        )
        XCTAssertTrue(
            DirectStreamingPlayer.attachInheritedClusterFromEarlierMount(
                context: fresh,
                hadPriorServerSelection: true
            ),
            "A prior ping stamp on fresh attach is an earlier mount’s cluster"
        )
        XCTAssertFalse(
            DirectStreamingPlayer.attachInheritedClusterFromEarlierMount(
                context: .resume,
                hadPriorServerSelection: true
            ),
            "Soft-pause resume must not mark the cluster as inherited"
        )
        XCTAssertFalse(
            DirectStreamingPlayer.attachInheritedClusterFromEarlierMount(
                context: .streamSwitch,
                hadPriorServerSelection: true
            ),
            "Stream switch must not leave a cluster because a ping margin was small"
        )
    }

    /// Protects: dual timeout must not stamp ``lastServerSelectionTime``, so the 10 s
    /// throttle cannot treat “we learned nothing” as a real cluster selection.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/shouldStampLastServerSelection(hasValidPingResult:)``
    func testDualTimeoutMustNotStampServerSelection() {
        XCTAssertTrue(
            DirectStreamingPlayer.shouldStampLastServerSelection(hasValidPingResult: true),
            "A valid ping RTT may stamp the measured cluster"
        )
        XCTAssertFalse(
            DirectStreamingPlayer.shouldStampLastServerSelection(hasValidPingResult: false),
            "Dual timeout must not stamp — next attach must be allowed to ping again"
        )
    }

    /// Protects: once the warm window expires, same-stream resume pings again.
    func testWarmWindowExpiryForcesPingEvenOnSameStreamResume() {
        let expired = DirectStreamingPlayer.sameStreamWarmServerReuseInterval + 0.001
        XCTAssertFalse(
            DirectStreamingPlayer.shouldReuseCachedServerSelection(
                lastSelectionAge: expired,
                allowSameStreamWarmReuse: true
            ),
            "Same-stream resume must ping after the warm window"
        )
        XCTAssertTrue(
            DirectStreamingPlayer.shouldReuseCachedServerSelection(
                lastSelectionAge: DirectStreamingPlayer.sameStreamWarmServerReuseInterval,
                allowSameStreamWarmReuse: true
            ),
            "Warm window is inclusive at the boundary"
        )
    }

    /// Protects: only HTTP 403 on a language stream host whose query is the embedded
    /// model excludes that cluster. Ping hosts, other statuses, and a missing query do not.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/isEmbeddedSecurityModelRejection(statusCode:url:expectedModel:apex:productionSubdomains:)``,
    ///   ``DirectStreamingPlayer/productionClusterSubdomain(host:apex:productionSubdomains:)``
    func testEmbeddedSecurityModelRejectionMatchesOnlyStream403() {
        let apex = SecurityConfiguration.current.preferredStreamingDomainSuffix
        let model = SecurityConfiguration.current.expectedSecurityModel
        let subdomains = ["eu", "us"]
        let finnishEU = URL(string: "https://finnish-eu.\(apex)/lutheranradio.mp3?security_model=\(model)")!
        let finnishUS = URL(string: "https://finnish-us.\(apex)/lutheranradio.mp3?security_model=\(model)")!
        let missingQuery = URL(string: "https://finnish-eu.\(apex)/lutheranradio.mp3")!
        let pingHost = URL(string: "https://european.\(apex)/ping")!

        XCTAssertTrue(
            DirectStreamingPlayer.isEmbeddedSecurityModelRejection(
                statusCode: 403,
                url: finnishEU,
                expectedModel: model,
                apex: apex,
                productionSubdomains: subdomains
            )
        )
        XCTAssertEqual(
            DirectStreamingPlayer.productionClusterSubdomain(host: finnishEU.host!, apex: apex, productionSubdomains: subdomains),
            "eu"
        )
        XCTAssertEqual(
            DirectStreamingPlayer.productionClusterSubdomain(host: finnishUS.host!, apex: apex, productionSubdomains: subdomains),
            "us"
        )
        XCTAssertNil(
            DirectStreamingPlayer.productionClusterSubdomain(host: pingHost.host!, apex: apex, productionSubdomains: subdomains),
            "Ping hosts are not stream clusters"
        )
        XCTAssertFalse(
            DirectStreamingPlayer.isEmbeddedSecurityModelRejection(
                statusCode: 200,
                url: finnishEU,
                expectedModel: model,
                apex: apex,
                productionSubdomains: subdomains
            )
        )
        XCTAssertFalse(
            DirectStreamingPlayer.isEmbeddedSecurityModelRejection(
                statusCode: 404,
                url: finnishEU,
                expectedModel: model,
                apex: apex,
                productionSubdomains: subdomains
            )
        )
        XCTAssertFalse(
            DirectStreamingPlayer.isEmbeddedSecurityModelRejection(
                statusCode: 403,
                url: missingQuery,
                expectedModel: model,
                apex: apex,
                productionSubdomains: subdomains
            )
        )
        XCTAssertFalse(
            DirectStreamingPlayer.isEmbeddedSecurityModelRejection(
                statusCode: 403,
                url: pingHost,
                expectedModel: model,
                apex: apex,
                productionSubdomains: subdomains
            )
        )
    }

    /// Protects: after `eu` refuses, the next cluster is `us`; after both, none remain.
    /// Throttle, warm reuse, and a lower EU latency cannot select a refused cluster.
    func testRejectedClusterIsSkippedByReuseAndLatency() {
        XCTAssertEqual(
            DirectStreamingPlayer.alternateEligibleCluster(
                currentSubdomain: "eu",
                rejectedSubdomains: ["eu"],
                servers: DirectStreamingPlayer.servers
            )?.subdomain,
            "us"
        )
        XCTAssertNil(
            DirectStreamingPlayer.alternateEligibleCluster(
                currentSubdomain: "eu",
                rejectedSubdomains: ["eu", "us"],
                servers: DirectStreamingPlayer.servers
            )
        )
        XCTAssertFalse(
            DirectStreamingPlayer.mayReuseCachedCluster(
                subdomain: "eu",
                rejectedSubdomains: ["eu"],
                lastSelectionAge: 0,
                allowSameStreamWarmReuse: true
            ),
            "Throttle and warm reuse must not keep a cluster that refused the embedded model"
        )
        XCTAssertTrue(
            DirectStreamingPlayer.mayReuseCachedCluster(
                subdomain: "us",
                rejectedSubdomains: ["eu"],
                lastSelectionAge: 0,
                allowSameStreamWarmReuse: false
            )
        )
        XCTAssertFalse(
            DirectStreamingPlayer.mayReuseCachedCluster(
                subdomain: "us",
                rejectedSubdomains: [],
                lastSelectionAge: nil,
                allowSameStreamWarmReuse: true
            ),
            "A missing stamp still pings"
        )
        let samples = [
            DirectStreamingPlayer.ClusterLatencySample(subdomain: "eu", latency: 0.05),
            DirectStreamingPlayer.ClusterLatencySample(subdomain: "us", latency: 0.40)
        ]
        XCTAssertEqual(
            DirectStreamingPlayer.winningClusterSubdomain(
                samples: samples,
                rejectedSubdomains: ["eu"],
                fallbackSubdomain: "eu"
            ),
            "us",
            "A lower latency on a refused cluster must not win"
        )
        XCTAssertNil(
            DirectStreamingPlayer.winningClusterSubdomain(
                samples: samples,
                rejectedSubdomains: ["eu", "us"],
                fallbackSubdomain: "eu"
            )
        )
    }
}
