//
//  PlaybackPausePressFeedbackTests.swift
//  Lutheran RadioTests
//
//  Protects the pause-only in-app press-chrome contract on
//  `PlaybackControlsView`: the SwiftUI `.sensoryFeedback` token bumps only
//  on an explicit pause while audio is flowing. Play tap does not bump.
//  UITestMode and Low Power Mode skip the same way `HapticsController`
//  skips `playHapticFeedback(style:)`.
//
//  Why this shape:
//  - Confirmation haptic stays on `HapticPlaybackPolicy` + `HapticsController`
//    via `RadioPlayerCoordinator.handleStatusChange` (untouched).
//  - Binding `.sensoryFeedback` to `isActivelyPlaying` would also fire on
//    language switch, stream failure, thermal, and security lock.
//  - `PlayerVisualState.isActivelyPlaying` is `self == .playing` only.
//  - Unit tests run under `SharedPlayerManager.isRunningInUITestMode`, so
//    we cannot assert the Taptic Engine. The helper is the testable policy.
//  - No ActivityKit, WidgetCenter, or live AsyncStream.
//
//  - SeeAlso: `PlaybackPausePressFeedback`, `PlaybackControlsView`,
//    `HapticPlaybackPolicy`, `HapticsController`,
//    CODING_AGENT.md (test documentation + fast patterns).
//
//  Created by Jari Lammi on 15.8.2026.
//

import XCTest
import WidgetSurface
@testable import Lutheran_Radio

/// Pause-only press-chrome policy for ``PlaybackPausePressFeedback``.
///
/// Invariant: the token bump is an explicit in-app pause request, not a
/// visual-state edge. Play confirmation remains on ``HapticPlaybackPolicy``.
///
/// - SeeAlso: ``PlaybackPausePressFeedback/shouldBumpPausePressToken(isActivelyPlaying:isUITestMode:isLowPowerModeEnabled:)``,
///   ``HapticPlaybackPolicy``, ``HapticsController``,
///   ``PlayerVisualState/isActivelyPlaying``
@MainActor
final class PlaybackPausePressFeedbackTests: XCTestCase {

    /// Pause while audio is flowing is the only production bump.
    func testPauseWhileActivelyPlayingBumpsToken() {
        XCTAssertTrue(
            PlaybackPausePressFeedback.shouldBumpPausePressToken(
                isActivelyPlaying: true,
                isUITestMode: false,
                isLowPowerModeEnabled: false
            ),
            "Explicit pause while playing must bump the sensory-feedback token"
        )
    }

    /// Play / Connecting keep a play affordance — `isActivelyPlaying` is false.
    /// The Button play branch never calls the bump helper.
    func testPlayAffordanceDoesNotBumpToken() {
        XCTAssertFalse(
            PlaybackPausePressFeedback.shouldBumpPausePressToken(
                isActivelyPlaying: false,
                isUITestMode: false,
                isLowPowerModeEnabled: false
            ),
            "Play tap and Connecting must not bump the pause-only token"
        )
        XCTAssertFalse(
            PlayerVisualState.prePlay.isActivelyPlaying,
            "Connecting (.prePlay) is not actively playing — not a pause press"
        )
        XCTAssertTrue(
            PlayerVisualState.playing.isActivelyPlaying,
            "isActivelyPlaying remains self == .playing only"
        )
    }

    /// Same UITestMode skip as ``HapticsController/playHapticFeedback(style:)``.
    func testUITestModeSkipsTokenBump() {
        XCTAssertFalse(
            PlaybackPausePressFeedback.shouldBumpPausePressToken(
                isActivelyPlaying: true,
                isUITestMode: true,
                isLowPowerModeEnabled: false
            ),
            "UITestMode must not bump the pause-press token"
        )
    }

    /// Same Low Power skip as ``HapticsController`` so pause cannot out-buzz
    /// play confirmation when the coordinator is also silent.
    func testLowPowerModeSkipsTokenBump() {
        XCTAssertFalse(
            PlaybackPausePressFeedback.shouldBumpPausePressToken(
                isActivelyPlaying: true,
                isUITestMode: false,
                isLowPowerModeEnabled: true
            ),
            "Low Power Mode must not bump the pause-press token"
        )
    }

    /// Both skip gates together still refuse.
    func testUITestModeAndLowPowerTogetherStillSkip() {
        XCTAssertFalse(
            PlaybackPausePressFeedback.shouldBumpPausePressToken(
                isActivelyPlaying: true,
                isUITestMode: true,
                isLowPowerModeEnabled: true
            )
        )
    }
}
