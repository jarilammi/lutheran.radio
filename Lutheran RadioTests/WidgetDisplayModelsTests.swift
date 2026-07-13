//
//  WidgetDisplayModelsTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 13.7.2026.
//
//  Tier 2 contract tests for the metadata/emphasis resolver
//  `widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)`.
//

import XCTest
@testable import Lutheran_Radio

/// Protects the canonical title / speaker / emphasis mapping for every
/// `PlayerVisualState` × metadata presence combination (OI-W3 strategy: main-app host).
///
/// Pure-function coverage — no WidgetCenter IPC or ActivityKit.
///
/// - SeeAlso: `WidgetDisplayModels.swift`, docs/Widget-Presentation-Dataflow.md,
///   docs/Widget-Functionality-Roadmap.md (Tier 2).
final class WidgetDisplayModelsTests: XCTestCase {

    private let languageName = "TestLang"
    private let programTitle = "Sunday Sermon"
    private let speaker = "Pastor Smith"

    private var liveFallback: String {
        widgetLiveStreamFallback(languageName: languageName)
    }

    private var noTrackPlaceholder: String {
        String(localized: "no_track_info", defaultValue: "No track information", table: "Localizable")
    }

    private func metadata(title: String?, speaker: String? = nil) -> StreamProgramMetadata? {
        guard title != nil || speaker != nil else { return nil }
        return StreamProgramMetadata(programTitle: title, speaker: speaker)
    }

    private func resolve(
        visualState: PlayerVisualState,
        metadata: StreamProgramMetadata?
    ) -> WidgetNowPlayingDisplayModel {
        widgetNowPlayingDisplayModel(
            visualState: visualState,
            streamMetadata: metadata,
            languageName: languageName
        )
    }

    // MARK: - Playing

    func testPlayingWithoutMetadataUsesLiveFallbackActiveEmphasis() {
        let model = resolve(visualState: .playing, metadata: nil)
        XCTAssertEqual(model.programTitle, liveFallback)
        XCTAssertEqual(model.emphasis, .active)
        XCTAssertFalse(model.speakerVisible)
        XCTAssertEqual(model.speakerLine, "\u{00A0}")
    }

    func testPlayingWithTitleUsesTitleActiveEmphasis() {
        let model = resolve(visualState: .playing, metadata: metadata(title: programTitle))
        XCTAssertEqual(model.programTitle, programTitle)
        XCTAssertEqual(model.emphasis, .active)
        XCTAssertFalse(model.speakerVisible)
    }

    func testPlayingWithTitleAndSpeakerShowsSpeakerLine() {
        let model = resolve(visualState: .playing, metadata: metadata(title: programTitle, speaker: speaker))
        XCTAssertEqual(model.programTitle, programTitle)
        XCTAssertEqual(model.speakerLine, speaker)
        XCTAssertTrue(model.speakerVisible)
        XCTAssertEqual(model.emphasis, .active)
    }

    func testPlayingWithEmptyTitleFallsBackToLiveStream() {
        let model = resolve(visualState: .playing, metadata: metadata(title: ""))
        XCTAssertEqual(model.programTitle, liveFallback)
        XCTAssertEqual(model.emphasis, .active)
    }

    // MARK: - PrePlay / Cleared (subdued live-fallback family)

    func testPrePlayWithoutMetadataUsesLiveFallbackSubdued() {
        let model = resolve(visualState: .prePlay, metadata: nil)
        XCTAssertEqual(model.programTitle, liveFallback)
        XCTAssertEqual(model.emphasis, .subdued)
        XCTAssertFalse(model.speakerVisible)
    }

    func testPrePlayWithTitleAndSpeakerShowsSpeakerSubdued() {
        let model = resolve(visualState: .prePlay, metadata: metadata(title: programTitle, speaker: speaker))
        XCTAssertEqual(model.programTitle, programTitle)
        XCTAssertTrue(model.speakerVisible)
        XCTAssertEqual(model.emphasis, .subdued)
    }

    func testClearedWithoutMetadataMatchesPrePlaySubduedPattern() {
        let model = resolve(visualState: .cleared, metadata: nil)
        XCTAssertEqual(model.programTitle, liveFallback)
        XCTAssertEqual(model.emphasis, .subdued)
        XCTAssertFalse(model.speakerVisible)
    }

    // MARK: - UserPaused

    func testUserPausedWithoutMetadataUsesNoTrackPlaceholder() {
        let model = resolve(visualState: .userPaused, metadata: nil)
        XCTAssertEqual(model.programTitle, noTrackPlaceholder)
        XCTAssertEqual(model.emphasis, .placeholder)
        XCTAssertFalse(model.speakerVisible)
    }

    func testUserPausedWithTitleRetainsSubduedTitle() {
        let model = resolve(visualState: .userPaused, metadata: metadata(title: programTitle))
        XCTAssertEqual(model.programTitle, programTitle)
        XCTAssertEqual(model.emphasis, .subdued)
        XCTAssertFalse(model.speakerVisible)
    }

    func testUserPausedWithTitleAndSpeakerShowsSpeakerSubdued() {
        let model = resolve(visualState: .userPaused, metadata: metadata(title: programTitle, speaker: speaker))
        XCTAssertEqual(model.programTitle, programTitle)
        XCTAssertEqual(model.speakerLine, speaker)
        XCTAssertTrue(model.speakerVisible)
        XCTAssertEqual(model.emphasis, .subdued)
    }

    // MARK: - ThermalPaused / SecurityLocked (placeholder family without metadata)

    func testThermalPausedWithoutMetadataUsesNoTrackPlaceholder() {
        let model = resolve(visualState: .thermalPaused, metadata: nil)
        XCTAssertEqual(model.programTitle, noTrackPlaceholder)
        XCTAssertEqual(model.emphasis, .placeholder)
        XCTAssertFalse(model.speakerVisible)
    }

    func testThermalPausedWithTitleRetainsSubduedWithoutSpeakerVisibility() {
        let model = resolve(visualState: .thermalPaused, metadata: metadata(title: programTitle, speaker: speaker))
        XCTAssertEqual(model.programTitle, programTitle)
        XCTAssertEqual(model.emphasis, .subdued)
        XCTAssertFalse(model.speakerVisible, "Speaker line hidden for thermalPaused even when metadata carries speaker")
        XCTAssertEqual(model.speakerLine, speaker)
    }

    func testSecurityLockedWithTitleMatchesThermalPausedMetadataRules() {
        let model = resolve(visualState: .securityLocked, metadata: metadata(title: programTitle, speaker: speaker))
        XCTAssertEqual(model.programTitle, programTitle)
        XCTAssertEqual(model.emphasis, .subdued)
        XCTAssertFalse(model.speakerVisible)
    }

    func testSecurityLockedWithoutMetadataUsesNoTrackPlaceholder() {
        let model = resolve(visualState: .securityLocked, metadata: nil)
        XCTAssertEqual(model.programTitle, noTrackPlaceholder)
        XCTAssertEqual(model.emphasis, .placeholder)
    }

    // MARK: - Matrix sweep (all visual states × nil metadata)

    func testAllVisualStatesWithNilMetadataProduceStableSpeakerLinePlaceholder() {
        let states: [PlayerVisualState] = [
            .prePlay, .cleared, .playing, .userPaused, .thermalPaused, .securityLocked
        ]

        for state in states {
            let model = resolve(visualState: state, metadata: nil)
            XCTAssertFalse(model.programTitle.isEmpty, "programTitle must be non-empty for \(state)")
            XCTAssertFalse(model.speakerLine.isEmpty, "speakerLine must use NBSP placeholder for \(state)")
        }
    }
}
