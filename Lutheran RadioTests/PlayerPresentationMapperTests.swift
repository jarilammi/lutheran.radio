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
import WidgetSurface
@testable import Lutheran_Radio

/// Protects the canonical status-pill and play/pause control mappings for every
/// ``PlayerVisualState`` case.
///
/// **Invariant:** These mappers are pure functions with no WidgetCenter IPC, ActivityKit,
/// or actor hops. They run in the main-app test host and mirror the derivation performed
/// once per snapshot in widget Providers and Live Activity outer closures.
///
/// **Contracts protected:**
/// - Status axis: background, foreground, localized text, and optional `systemImage` per case.
/// - Control axis: `pause.fill` only when ``PlayerVisualState/isActivelyPlaying``; otherwise `play.fill`.
/// - Status and control colors both derive from ``PlayerVisualChromePalette``.
///
/// - SeeAlso: ``PlayerStatusPresentation``, ``PlayerControlPresentation``,
///   ``PlayerVisualChromePalette``, ``PlayerVisualState``,
///   docs/Widget-Presentation-Dataflow.md,
///   docs/Widget-Functionality-Roadmap.md (Tier 5 presentation mapper coverage).
final class PlayerPresentationMapperTests: XCTestCase {

    private let allVisualStates: [PlayerVisualState] = [
        .prePlay, .cleared, .playing, .userPaused, .thermalPaused, .securityLocked
    ]

    // MARK: - Status presentation matrix

    /// Verifies ``makeStatusPresentation()`` for every visual state against the documented mapping.
    func testMakeStatusPresentationMatrixMapsEveryVisualState() {
        let expectations: [PlayerVisualState: PlayerStatusPresentation] = [
            .playing: PlayerStatusPresentation(
                background: PlayerVisualChromePalette.backgroundColor(for: .playing),
                foreground: PlayerVisualChromePalette.textColor(for: .playing),
                text: String(localized: "status_playing", defaultValue: "Playing", table: "Localizable"),
                systemImage: "play.fill"
            ),
            .prePlay: PlayerStatusPresentation(
                background: PlayerVisualChromePalette.backgroundColor(for: .prePlay),
                foreground: PlayerVisualChromePalette.textColor(for: .prePlay),
                text: String(localized: "status_connecting", defaultValue: "Connecting", table: "Localizable"),
                systemImage: "play.circle"
            ),
            .cleared: PlayerStatusPresentation(
                background: PlayerVisualChromePalette.backgroundColor(for: .cleared),
                foreground: PlayerVisualChromePalette.textColor(for: .cleared),
                text: String(localized: "clear_local_state_done", defaultValue: "Cleared", table: "Localizable"),
                systemImage: nil
            ),
            .userPaused: PlayerStatusPresentation(
                background: PlayerVisualChromePalette.backgroundColor(for: .userPaused),
                foreground: PlayerVisualChromePalette.textColor(for: .userPaused),
                text: String(localized: "status_paused", defaultValue: "Paused", table: "Localizable"),
                systemImage: "pause.fill"
            ),
            .thermalPaused: PlayerStatusPresentation(
                background: PlayerVisualChromePalette.backgroundColor(for: .thermalPaused),
                foreground: PlayerVisualChromePalette.textColor(for: .thermalPaused),
                text: String(localized: "status_thermal_paused", defaultValue: "Paused (device hot)", table: "Localizable"),
                systemImage: "pause.fill"
            ),
            .securityLocked: PlayerStatusPresentation(
                background: PlayerVisualChromePalette.backgroundColor(for: .securityLocked),
                foreground: PlayerVisualChromePalette.textColor(for: .securityLocked),
                text: String(localized: "status_security_failed", defaultValue: "Security check failed", table: "Localizable"),
                systemImage: "lock.fill"
            ),
        ]

        XCTAssertEqual(
            expectations.count,
            allVisualStates.count,
            "Status matrix must include every PlayerVisualState case"
        )

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

    /// Verifies the optional status glyph policy: only ``PlayerVisualState/cleared`` omits `systemImage`.
    func testMakeStatusPresentationSystemImagePolicyPerVisualState() {
        let expectedGlyphs: [PlayerVisualState: String?] = [
            .playing: "play.fill",
            .prePlay: "play.circle",
            .cleared: nil,
            .userPaused: "pause.fill",
            .thermalPaused: "pause.fill",
            .securityLocked: "lock.fill",
        ]

        for state in allVisualStates {
            XCTAssertEqual(
                state.makeStatusPresentation().systemImage,
                expectedGlyphs[state] ?? nil,
                "Status systemImage must match SSOT for \(state)"
            )
        }
    }

    /// Every visual state must surface non-empty localized status copy for widget and Live Activity chrome.
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
                tint: PlayerVisualChromePalette.buttonTintColor(for: state)
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

    /// Control tint and UIKit ``buttonTintColor`` both delegate to ``PlayerVisualChromePalette``.
    func testMakeControlPresentationTintMatchesButtonTintColorPolicy() {
        let expectedUIColors: [PlayerVisualState: UIColor] = [
            .prePlay: .systemYellow,
            .cleared: .systemBlue,
            .playing: .systemGreen,
            .userPaused: .secondaryLabel,
            .thermalPaused: .systemOrange,
            .securityLocked: .systemRed,
        ]

        for state in allVisualStates {
            let presentation = state.makeControlPresentation()
            let policyColor = expectedUIColors[state] ?? state.buttonTintColor
            XCTAssertEqual(
                PlayerVisualChromePalette.buttonTintUIColor(for: state),
                policyColor,
                "Chrome palette button tint must remain stable for \(state)"
            )
            XCTAssertEqual(
                state.buttonTintColor,
                policyColor,
                "buttonTintColor must delegate to chrome palette for \(state)"
            )
            XCTAssertEqual(
                presentation.tint,
                PlayerVisualChromePalette.buttonTintColor(for: state),
                "Control tint must mirror chrome palette for \(state)"
            )
        }
    }

    /// Status presentation colors match the same palette as UIKit chrome properties.
    func testMakeStatusPresentationColorsMatchChromePalette() {
        for state in allVisualStates {
            let presentation = state.makeStatusPresentation()
            XCTAssertEqual(
                presentation.background,
                PlayerVisualChromePalette.backgroundColor(for: state),
                "Status background must match chrome palette for \(state)"
            )
            XCTAssertEqual(
                presentation.foreground,
                PlayerVisualChromePalette.textColor(for: state),
                "Status foreground must match chrome palette for \(state)"
            )
            XCTAssertEqual(
                state.backgroundColor,
                PlayerVisualChromePalette.backgroundUIColor(for: state),
                "UIKit backgroundColor must match chrome palette for \(state)"
            )
            XCTAssertEqual(
                state.textColor,
                PlayerVisualChromePalette.textUIColor(for: state),
                "UIKit textColor must match chrome palette for \(state)"
            )
        }
    }

    /// Regression guard: control presentations differ across playing vs every non-playing state.
    func testMakeControlPresentationPlayingDiffersFromAllNonPlayingStates() {
        let playing = PlayerVisualState.playing.makeControlPresentation()
        let nonPlaying = allVisualStates.filter { $0 != .playing }

        for state in nonPlaying {
            XCTAssertNotEqual(
                playing,
                state.makeControlPresentation(),
                "Playing control must differ from \(state)"
            )
        }
    }

    /// Non-playing states that share the play glyph must still differ by tint policy.
    func testMakeControlPresentationNonPlayingStatesRemainDistinctByTint() {
        let nonPlaying = allVisualStates.filter { !$0.isActivelyPlaying }
        let presentations = nonPlaying.map { ($0, $0.makeControlPresentation()) }

        for i in presentations.indices {
            for j in presentations.indices where j > i {
                XCTAssertNotEqual(
                    presentations[i].1,
                    presentations[j].1,
                    "Control presentation must differ for \(presentations[i].0) vs \(presentations[j].0)"
                )
            }
        }
    }
}
