//
//  PlayerPresentationMapperExtensionTests.swift
//  LutheranRadioWidgetTests
//
//  Created by Jari Lammi on 15.7.2026.
//
//  Thin extension-profile smoke for status/control presentation mappers.
//  Full per-state matrices live in WidgetSurfaceTests (pure framework host) and
//  main-app `PlayerPresentationMapperTests`. This suite only proves the mappers
//  link and behave under the widget extension compile profile (no LUTHERAN_MAIN_APP).
//
//  - SeeAlso: ``PlayerStatusPresentation``, ``PlayerControlPresentation``,
//    ``PlayerVisualChromePalette``, docs/Widget-Presentation-Dataflow.md,
//    docs/Widget-Functionality-Roadmap.md.
//

import SwiftUI
import XCTest
import WidgetSurface

/// Extension-profile linkage smoke for presentation mappers (full matrices elsewhere).
final class PlayerPresentationMapperExtensionTests: XCTestCase {

    /// Playing status chrome must compile and resolve under the extension module graph.
    func testStatusPresentationPlayingSmokeLinksUnderExtensionProfile() {
        let presentation = PlayerVisualState.playing.makeStatusPresentation()
        XCTAssertEqual(presentation.systemImage, "play.fill")
        XCTAssertFalse(presentation.text.isEmpty)
        XCTAssertEqual(
            presentation.background,
            PlayerVisualChromePalette.backgroundColor(for: .playing)
        )
    }

    /// Control glyph policy: pause only when actively playing (single representative check).
    func testControlPresentationPlayingUsesPauseGlyphSmoke() {
        XCTAssertEqual(
            PlayerVisualState.playing.makeControlPresentation().systemImage,
            "pause.fill"
        )
        XCTAssertEqual(
            PlayerVisualState.userPaused.makeControlPresentation().systemImage,
            "play.fill"
        )
    }
}
