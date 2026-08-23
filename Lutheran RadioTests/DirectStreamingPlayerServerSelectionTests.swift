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
import WidgetSurface

final class DirectStreamingPlayerServerSelectionTests: XCTestCase {

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
}
