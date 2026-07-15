//
//  PlayerPresentationMapperExtensionTests.swift
//  LutheranRadioWidgetTests
//
//  Created by Jari Lammi on 15.7.2026.
//
//  Extension-profile port of status/control presentation mapper matrices.
//  Proves ``PlayerVisualState`` mappers compile and behave under the same module
//  linkage as the widget extension (WidgetSurface framework, no LUTHERAN_MAIN_APP).
//
//  - SeeAlso: ``PlayerStatusPresentation``, ``PlayerControlPresentation``,
//    docs/Widget-Presentation-Dataflow.md, docs/Widget-Functionality-Roadmap.md.
//

import SwiftUI
import XCTest
import WidgetSurface

/// Extension-profile mirror of `PlayerPresentationMapperTests` (main-app host).
final class PlayerPresentationMapperExtensionTests: XCTestCase {

    private let allVisualStates: [PlayerVisualState] = [
        .prePlay, .cleared, .playing, .userPaused, .thermalPaused, .securityLocked
    ]

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

        XCTAssertEqual(expectations.count, allVisualStates.count)

        for state in allVisualStates {
            guard let expected = expectations[state] else {
                XCTFail("Missing status expectation for \(state)")
                continue
            }
            XCTAssertEqual(state.makeStatusPresentation(), expected, "Status SSOT for \(state)")
        }
    }

    func testMakeControlPresentationUsesPauseGlyphOnlyWhenActivelyPlaying() {
        for state in allVisualStates {
            let glyph = state.makeControlPresentation().systemImage
            if state == .playing {
                XCTAssertEqual(glyph, "pause.fill")
            } else {
                XCTAssertEqual(glyph, "play.fill")
            }
        }
    }

    func testMakeControlPresentationMatrixMatchesGlyphAndTintPolicy() {
        for state in allVisualStates {
            let expected = PlayerControlPresentation(
                systemImage: state.isActivelyPlaying ? "pause.fill" : "play.fill",
                tint: Color(uiColor: state.buttonTintColor)
            )
            XCTAssertEqual(state.makeControlPresentation(), expected)
        }
    }
}
