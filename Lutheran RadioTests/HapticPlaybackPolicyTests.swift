//
//  HapticPlaybackPolicyTests.swift
//  Lutheran RadioTests
//
//  Protects the became-playing confirmation haptic contract taken from
//  device log `haptics_doesnt_work_anymore_on_the_device.txt`:
//  every audible start arrives as `reasonKey: status_playing`. A
//  `reasonKey == nil` gate never calls ``HapticsController``.
//
//  Also documents why there is no CHHapticEngine: a warm engine holds the
//  Taptic Engine and mutes UIKit / SwiftUI impacts.
//
//  Pure policy only — no Core Haptics, ActivityKit, or WidgetCenter.
//
//  - SeeAlso: `HapticPlaybackPolicy`, `HapticsController`,
//    CODING_AGENT.md (fast test patterns).
//
//  Created by Jari Lammi on 15.8.2026.
//

import XCTest
import WidgetSurface
@testable import Lutheran_Radio

/// Device-log contract for ``HapticPlaybackPolicy``.
///
/// Why this is a policy suite:
/// - The silent-device failure was a *when to play* + *do not hold CHHapticEngine*
///   bug, not a pattern-player bug.
/// - Unit tests run under ``SharedPlayerManager/isRunningInUITestMode``, which
///   correctly skips generator playback. The policy is what we can assert.
///
/// - SeeAlso: ``HapticPlaybackPolicy/shouldPlayPlayingConfirmation(status:reasonKey:alreadyPlayedForCurrentAudibleStart:)``,
///   ``HapticsController``
@MainActor
final class HapticPlaybackPolicyTests: XCTestCase {

    /// The production key from the device log must play the confirmation haptic.
    func testStatusPlayingFiresConfirmationOnFirstAudibleStart() {
        XCTAssertTrue(
            HapticPlaybackPolicy.shouldPlayPlayingConfirmation(
                status: .playing,
                reasonKey: "status_playing",
                alreadyPlayedForCurrentAudibleStart: false
            )
        )
    }

    /// Interruption resume still uses `reasonKey == nil`.
    func testNilReasonKeyOnPlayingFiresConfirmation() {
        XCTAssertTrue(
            HapticPlaybackPolicy.shouldPlayPlayingConfirmation(
                status: .playing,
                reasonKey: nil,
                alreadyPlayedForCurrentAudibleStart: false
            )
        )
    }

    /// Latch prevents a later `status_playing` or `nil` on the same start from double-buzzing.
    func testLatchSuppressesSecondConfirmationOnSameAudibleStart() {
        XCTAssertFalse(
            HapticPlaybackPolicy.shouldPlayPlayingConfirmation(
                status: .playing,
                reasonKey: "status_playing",
                alreadyPlayedForCurrentAudibleStart: true
            )
        )
        XCTAssertFalse(
            HapticPlaybackPolicy.shouldPlayPlayingConfirmation(
                status: .playing,
                reasonKey: nil,
                alreadyPlayedForCurrentAudibleStart: true
            )
        )
    }

    /// Connecting / stopped / other keys must not play the became-playing haptic.
    func testNonPlayingStatusAndOtherKeysDoNotFireConfirmation() {
        XCTAssertFalse(
            HapticPlaybackPolicy.shouldPlayPlayingConfirmation(
                status: .stopped,
                reasonKey: "status_playing",
                alreadyPlayedForCurrentAudibleStart: false
            )
        )
        XCTAssertFalse(
            HapticPlaybackPolicy.shouldPlayPlayingConfirmation(
                status: .playing,
                reasonKey: "status_connecting",
                alreadyPlayedForCurrentAudibleStart: false
            )
        )
        XCTAssertFalse(
            HapticPlaybackPolicy.shouldPlayPlayingConfirmation(
                status: .playing,
                reasonKey: "status_buffering",
                alreadyPlayedForCurrentAudibleStart: false
            )
        )
    }

    func testLatchClearsOnEveryNonPlayingStatus() {
        XCTAssertTrue(HapticPlaybackPolicy.shouldClearAudibleStartHapticLatch(status: .stopped))
        XCTAssertTrue(HapticPlaybackPolicy.shouldClearAudibleStartHapticLatch(status: .paused))
        XCTAssertTrue(HapticPlaybackPolicy.shouldClearAudibleStartHapticLatch(status: .connecting))
        XCTAssertFalse(HapticPlaybackPolicy.shouldClearAudibleStartHapticLatch(status: .playing))
    }
}
