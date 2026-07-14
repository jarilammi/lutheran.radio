//
//  PlayerPresentationMapperTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 14.7.2026.
//
//  Matrix contract tests for ``PlayerVisualState/makeStatusPresentation()`` and
//  ``PlayerVisualState/makeControlPresentation()`` — the status and control presentation SSOTs.
//

import SwiftUI
import XCTest
@testable import Lutheran_Radio

/// Protects the canonical status-pill and play/pause control mappings for every
/// ``PlayerVisualState`` case (OI-W3 strategy: main-app host, pure functions, no IPC).
///
/// **Contracts protected:**
/// - Status axis: background, foreground, localized text, and optional `systemImage` per case.
/// - Control axis: `pause.fill` only when ``PlayerVisualState/isActivelyPlaying``; otherwise `play.fill`.
/// - Control tint derives from ``PlayerVisualState/buttonTintColor`` via a single `Color(uiColor:)` bridge.
///
/// - SeeAlso: ``PlayerStatusPresentation``, ``PlayerControlPresentation``,
///   `PlayerVisualState.swift`, docs/Widget-Presentation-Dataflow.md,
///   docs/widget-test-gaps-analysis.md (P0).
final class PlayerPresentationMapperTests: XCTestCase {

    private let allVisualStates: [PlayerVisualState] = [
        .prePlay, .cleared, .playing, .userPaused, .thermalPaused, .securityLocked
    ]

    // MARK: - Status presentation matrix

    /// Verifies ``makeStatusPresentation()`` for every visual state against the documented mapping.
    func testMakeStatusPresentationMatrixMapsEveryVisualState() {
        let expectations: [PlayerVisualState: PlayerStatusPresentation] = [
            .playing: PlayerStatusPresentation(
                background: .green,
                foreground: .white,
                text: String(localized: "status_playing", defaultValue: "Playing", table: "Localizable"),
                systemImage: "play.fill"
            ),
            .prePlay: PlayerStatusPresentation(
                background: .yellow,
                foreground: .black,
                text: String(localized: "status_connecting", defaultValue: "Connecting", table: "Localizable"),
                systemImage: "play.circle"
            ),
            .cleared: PlayerStatusPresentation(
                background: .blue,
                foreground: .white,
                text: String(localized: "clear_local_state_done", defaultValue: "Cleared", table: "Localizable"),
                systemImage: nil
            ),
            .userPaused: PlayerStatusPresentation(
                background: .gray,
                foreground: .white,
                text: String(localized: "status_paused", defaultValue: "Paused", table: "Localizable"),
                systemImage: "pause.fill"
            ),
            .thermalPaused: PlayerStatusPresentation(
                background: .orange,
                foreground: .white,
                text: String(localized: "status_thermal_paused", defaultValue: "Paused (device hot)", table: "Localizable"),
                systemImage: "pause.fill"
            ),
            .securityLocked: PlayerStatusPresentation(
                background: .red,
                foreground: .white,
                text: String(localized: "status_security_failed", defaultValue: "Security check failed", table: "Localizable"),
                systemImage: "lock.fill"
            ),
        ]

        for state in allVisualStates {
            guard let expected = expectations[state] else {
                XCTFail("Missing status expectation for \(state)")
                continue
            }
            XCTAssertEqual(
                state.makeStatusPresentation(),
                expected,
                "Status presentation must match SSOT for \(state)"
            )
        }
    }

    /// Every visual state must surface non-empty localized status copy for widget/LA chrome.
    func testMakeStatusPresentationProducesNonEmptyLocalizedTextForAllStates() {
        for state in allVisualStates {
            let presentation = state.makeStatusPresentation()
            XCTAssertFalse(
                presentation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Status text must be non-empty for \(state)"
            )
        }
    }

    /// Regression guard: no two visual states may collapse to identical status presentations.
    func testMakeStatusPresentationIsDistinctAcrossAllVisualStates() {
        let pairs = allVisualStates.map { ($0, $0.makeStatusPresentation()) }
        for i in pairs.indices {
            for j in pairs.indices where j > i {
                XCTAssertNotEqual(
                    pairs[i].1,
                    pairs[j].1,
                    "Status presentation must differ for \(pairs[i].0) vs \(pairs[j].0)"
                )
            }
        }
    }

    // MARK: - Control presentation matrix

    /// Verifies ``makeControlPresentation()`` for every visual state against glyph + tint policy.
    func testMakeControlPresentationMatrixMapsEveryVisualState() {
        for state in allVisualStates {
            let expected = PlayerControlPresentation(
                systemImage: state.isActivelyPlaying ? "pause.fill" : "play.fill",
                tint: Color(uiColor: state.buttonTintColor)
            )
            XCTAssertEqual(
                state.makeControlPresentation(),
                expected,
                "Control presentation must match SSOT for \(state)"
            )
        }
    }

    /// Only ``PlayerVisualState/playing`` exposes the pause affordance; all other cases show play.
    func testMakeControlPresentationUsesPauseGlyphOnlyWhenActivelyPlaying() {
        for state in allVisualStates {
            let glyph = state.makeControlPresentation().systemImage
            if state == .playing {
                XCTAssertEqual(glyph, "pause.fill", "Playing must surface pause control")
            } else {
                XCTAssertEqual(glyph, "play.fill", "Non-playing \(state) must surface play control")
            }
        }
    }

    /// Control tint must remain aligned with ``buttonTintColor`` (single bridge site in mapper).
    func testMakeControlPresentationTintMatchesButtonTintColorPolicy() {
        for state in allVisualStates {
            let presentation = state.makeControlPresentation()
            let expectedTint = Color(uiColor: state.buttonTintColor)
            XCTAssertEqual(
                presentation.tint,
                expectedTint,
                "Control tint must mirror buttonTintColor for \(state)"
            )
        }
    }

    /// Regression guard: control presentations differ across at least playing vs paused families.
    func testMakeControlPresentationPlayingDiffersFromStickyPauseFamily() {
        let playing = PlayerVisualState.playing.makeControlPresentation()
        let pausedFamily: [PlayerVisualState] = [.userPaused, .thermalPaused, .securityLocked, .prePlay, .cleared]

        for state in pausedFamily {
            XCTAssertNotEqual(
                playing,
                state.makeControlPresentation(),
                "Playing control must differ from \(state)"
            )
        }
    }

}
