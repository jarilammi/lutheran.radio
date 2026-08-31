//
//  PlayerPresentationMapperTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 14.7.2026.
//
//  Matrix contract tests for ``PlayerVisualState/makeStatusPresentation()`` and
//  ``PlayerVisualState/makeControlPresentation()`` — the status and control presentation SSOTs.
//
//  Main-app test host (`LUTHERAN_MAIN_APP`). Swift Testing: pure mappers, no shared
//  mutable state, no ``@Suite(.serialized)``, no `confirmation()`. Event / Live Activity /
//  AsyncStream suites stay XCTest. Pure-framework safety net:
//  `WidgetSurfaceTests.statusPresentationMatrixMapsEveryVisualState`.
//

import Foundation
import SwiftUI
import Testing
import UIKit
import WidgetSurface
@testable import Lutheran_Radio

/// Exhaustive visual-state list for mapper matrices. Keep in lockstep with
/// ``PlayerVisualState`` cases — the enum is not `CaseIterable`.
private let playerPresentationMapperVisualStates: [PlayerVisualState] = [
    .prePlay, .cleared, .playing, .userPaused, .thermalPaused, .securityLocked
]

/// Protects the canonical status-pill and play/pause control mappings for every
/// ``PlayerVisualState`` case under the main-app test host.
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
@Suite("PlayerPresentationMapper Tests")
struct PlayerPresentationMapperTests {

    // MARK: - Status presentation matrix

    /// Verifies ``makeStatusPresentation()`` for every visual state against the documented mapping.
    @Test func `Status presentation matrix maps every visual state`() {
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

        #expect(
            expectations.count == playerPresentationMapperVisualStates.count,
            "Status matrix must include every PlayerVisualState case"
        )

        for state in playerPresentationMapperVisualStates {
            let expected = expectations[state]
            #expect(expected != nil, "Missing status expectation for \(state)")
            if let expected {
                #expect(
                    state.makeStatusPresentation() == expected,
                    "Status presentation must match SSOT for \(state)"
                )
            }
        }
    }

    /// Verifies the optional status glyph policy: only ``PlayerVisualState/cleared`` omits `systemImage`.
    @Test(arguments: playerPresentationMapperVisualStates)
    func `Status systemImage matches SSOT`(state: PlayerVisualState) {
        let expectedGlyphs: [PlayerVisualState: String?] = [
            .playing: "play.fill",
            .prePlay: "play.circle",
            .cleared: nil,
            .userPaused: "pause.fill",
            .thermalPaused: "pause.fill",
            .securityLocked: "lock.fill",
        ]
        #expect(
            state.makeStatusPresentation().systemImage == expectedGlyphs[state] ?? nil,
            "Status systemImage must match SSOT for \(state)"
        )
    }

    /// Every visual state must surface non-empty localized status copy for widget and Live Activity chrome.
    @Test(arguments: playerPresentationMapperVisualStates)
    func `Status text is non-empty localized copy`(state: PlayerVisualState) {
        let presentation = state.makeStatusPresentation()
        #expect(
            !presentation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Status text must be non-empty for \(state)"
        )
    }

    /// Regression guard: no two visual states may collapse to identical status presentations.
    @Test func `Status presentation is distinct across all visual states`() {
        let pairs = playerPresentationMapperVisualStates.map { ($0, $0.makeStatusPresentation()) }
        for i in pairs.indices {
            for j in pairs.indices where j > i {
                #expect(
                    pairs[i].1 != pairs[j].1,
                    "Status presentation must differ for \(pairs[i].0) vs \(pairs[j].0)"
                )
            }
        }
    }

    // MARK: - Control presentation matrix

    /// Verifies ``makeControlPresentation()`` for every visual state against glyph + tint policy.
    @Test(arguments: playerPresentationMapperVisualStates)
    func `Control presentation matches SSOT`(state: PlayerVisualState) {
        let expected = PlayerControlPresentation(
            systemImage: state.isActivelyPlaying ? "pause.fill" : "play.fill",
            tint: PlayerVisualChromePalette.buttonTintColor(for: state)
        )
        #expect(
            state.makeControlPresentation() == expected,
            "Control presentation must match SSOT for \(state)"
        )
    }

    /// Only ``PlayerVisualState/playing`` exposes the pause affordance; all other cases show play.
    @Test(arguments: playerPresentationMapperVisualStates)
    func `Control pause glyph is used only when playing`(state: PlayerVisualState) {
        let glyph = state.makeControlPresentation().systemImage
        if state == .playing {
            #expect(glyph == "pause.fill", "Playing must surface pause control")
        } else {
            #expect(glyph == "play.fill", "Non-playing \(state) must surface play control")
        }
    }

    /// Control tint and UIKit ``buttonTintColor`` both delegate to ``PlayerVisualChromePalette``.
    @Test(arguments: playerPresentationMapperVisualStates)
    func `Control tint matches button tint policy`(state: PlayerVisualState) {
        let expectedUIColors: [PlayerVisualState: UIColor] = [
            .prePlay: .systemYellow,
            .cleared: .systemBlue,
            .playing: .systemGreen,
            .userPaused: .secondaryLabel,
            .thermalPaused: .systemOrange,
            .securityLocked: .systemRed,
        ]

        let presentation = state.makeControlPresentation()
        let policyColor = expectedUIColors[state] ?? state.buttonTintColor
        #expect(
            PlayerVisualChromePalette.buttonTintUIColor(for: state) == policyColor,
            "Chrome palette button tint must remain stable for \(state)"
        )
        #expect(
            state.buttonTintColor == policyColor,
            "buttonTintColor must delegate to chrome palette for \(state)"
        )
        #expect(
            presentation.tint == PlayerVisualChromePalette.buttonTintColor(for: state),
            "Control tint must mirror chrome palette for \(state)"
        )
    }

    /// Status presentation colors match the same palette as UIKit chrome properties.
    @Test(arguments: playerPresentationMapperVisualStates)
    func `Status colors match chrome palette`(state: PlayerVisualState) {
        let presentation = state.makeStatusPresentation()
        #expect(
            presentation.background == PlayerVisualChromePalette.backgroundColor(for: state),
            "Status background must match chrome palette for \(state)"
        )
        #expect(
            presentation.foreground == PlayerVisualChromePalette.textColor(for: state),
            "Status foreground must match chrome palette for \(state)"
        )
        #expect(
            state.backgroundColor == PlayerVisualChromePalette.backgroundUIColor(for: state),
            "UIKit backgroundColor must match chrome palette for \(state)"
        )
        #expect(
            state.textColor == PlayerVisualChromePalette.textUIColor(for: state),
            "UIKit textColor must match chrome palette for \(state)"
        )
    }

    /// Regression guard: control presentations differ across playing vs every non-playing state.
    @Test func `Playing control differs from all non-playing states`() {
        let playing = PlayerVisualState.playing.makeControlPresentation()
        let nonPlaying = playerPresentationMapperVisualStates.filter { $0 != .playing }

        for state in nonPlaying {
            #expect(
                playing != state.makeControlPresentation(),
                "Playing control must differ from \(state)"
            )
        }
    }

    /// Non-playing states that share the play glyph must still differ by tint policy.
    @Test func `Non-playing control presentations remain distinct by tint`() {
        let nonPlaying = playerPresentationMapperVisualStates.filter { !$0.isActivelyPlaying }
        let presentations = nonPlaying.map { ($0, $0.makeControlPresentation()) }

        for i in presentations.indices {
            for j in presentations.indices where j > i {
                #expect(
                    presentations[i].1 != presentations[j].1,
                    "Control presentation must differ for \(presentations[i].0) vs \(presentations[j].0)"
                )
            }
        }
    }
}
