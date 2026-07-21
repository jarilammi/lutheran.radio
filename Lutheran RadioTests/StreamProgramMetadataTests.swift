//
//  StreamProgramMetadataTests.swift
//  Lutheran RadioTests
//
//  ICY parsing and Now Playing display-string SSOT coverage.
//
//  Created by Jari Lammi on 6.6.2026.
//

import XCTest
import WidgetSurface
@testable import Lutheran_Radio

/// Protects ``StreamProgramMetadata/from(rawICYMetadata:)`` and
/// ``StreamProgramMetadata/nowPlayingDisplayStrings(fromParsed:rawFallback:stationName:languageName:)``.
///
/// Coverage includes ASCII and typographic dash separators, multi-segment program titles,
/// the `" by "` speaker form, empty/whitespace rejection, the Now Playing formatter matrix,
/// and alignment with ``widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)``
/// for shared program-title fixtures (Tier 4 media-surface parity).
///
/// - SeeAlso: `WidgetSurface/StreamProgramMetadata.swift`,
///   docs/Widget-Functionality-Roadmap.md (Tier 4 / Tier 5),
///   docs/Widget-Presentation-Dataflow.md (formatter parity),
///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
final class StreamProgramMetadataTests: XCTestCase {

    private let programTitle = "Sunday Sermon on Grace"
    private let speaker = "Guest Speaker"
    private let rawUnparsed = "Morning Service by Guest Speaker"
    private let languageName = "Finnish"
    private var stationName: String {
        String(localized: "lutheran_radio_title", table: "Localizable")
    }

    // MARK: - ICY parsing

    func testFromRawTitleOnly() {
        let metadata = StreamProgramMetadata.from(rawICYMetadata: programTitle)
        XCTAssertEqual(metadata?.programTitle, programTitle)
        XCTAssertNil(metadata?.speaker)
    }

    func testFromRawSpeakerDashTitle() {
        let metadata = StreamProgramMetadata.from(rawICYMetadata: "Guest Speaker - The Good Shepherd")
        XCTAssertEqual(metadata?.speaker, "Guest Speaker")
        XCTAssertEqual(metadata?.programTitle, "The Good Shepherd")
    }

    /// En dash (U+2013) is common in station automation; must yield speaker + title, not title-only.
    func testFromRawSpeakerEnDashTitle() {
        let raw = "Guest Speaker \u{2013} The Good Shepherd"
        let metadata = StreamProgramMetadata.from(rawICYMetadata: raw)
        XCTAssertEqual(metadata?.speaker, "Guest Speaker")
        XCTAssertEqual(metadata?.programTitle, "The Good Shepherd")
    }

    /// Em dash (U+2014) must share the same separator policy as hyphen-minus and en dash.
    func testFromRawSpeakerEmDashTitle() {
        let raw = "Guest Speaker \u{2014} The Good Shepherd"
        let metadata = StreamProgramMetadata.from(rawICYMetadata: raw)
        XCTAssertEqual(metadata?.speaker, "Guest Speaker")
        XCTAssertEqual(metadata?.programTitle, "The Good Shepherd")
    }

    /// Segments after the first dash separator remain part of the program title.
    func testFromRawMultiSegmentDashTitleJoinsTrailingParts() {
        let metadata = StreamProgramMetadata.from(
            rawICYMetadata: "Cantor - Vespers - Evening Prayer"
        )
        XCTAssertEqual(metadata?.speaker, "Cantor")
        XCTAssertEqual(metadata?.programTitle, "Vespers - Evening Prayer")
    }

    /// Multi-segment titles with en dash normalize and re-join with ASCII `" - "`.
    func testFromRawMultiSegmentEnDashTitleJoinsWithAsciiSeparator() {
        let raw = "Cantor \u{2013} Vespers \u{2013} Evening Prayer"
        let metadata = StreamProgramMetadata.from(rawICYMetadata: raw)
        XCTAssertEqual(metadata?.speaker, "Cantor")
        XCTAssertEqual(metadata?.programTitle, "Vespers - Evening Prayer")
    }

    func testFromRawTitleBySpeaker() {
        let metadata = StreamProgramMetadata.from(rawICYMetadata: "Morning Service by Guest Speaker")
        XCTAssertEqual(metadata?.programTitle, "Morning Service")
        XCTAssertEqual(metadata?.speaker, "Guest Speaker")
    }

    /// Unspaced hyphens inside words must not trigger speaker/title splitting.
    func testFromRawUnspacedHyphenRemainsTitleOnly() {
        let title = "Well-known Hymn Study"
        let metadata = StreamProgramMetadata.from(rawICYMetadata: title)
        XCTAssertEqual(metadata?.programTitle, title)
        XCTAssertNil(metadata?.speaker)
    }

    func testFromEmptyReturnsNil() {
        XCTAssertNil(StreamProgramMetadata.from(rawICYMetadata: nil))
        XCTAssertNil(StreamProgramMetadata.from(rawICYMetadata: "   "))
    }

    func testHasDisplayableContentRequiresNonEmptyField() {
        XCTAssertTrue(
            StreamProgramMetadata(programTitle: "Title", speaker: nil).hasDisplayableContent
        )
        XCTAssertTrue(
            StreamProgramMetadata(programTitle: nil, speaker: "Speaker").hasDisplayableContent
        )
        XCTAssertFalse(
            StreamProgramMetadata(programTitle: "", speaker: "").hasDisplayableContent
        )
        XCTAssertFalse(
            StreamProgramMetadata(programTitle: nil, speaker: nil).hasDisplayableContent
        )
    }

    // MARK: - nowPlayingDisplayStrings matrix

    func testNowPlayingDisplayStringsParsedTitleAndSpeakerUsesSpeakerArtistLine() {
        let parsed = StreamProgramMetadata(programTitle: programTitle, speaker: speaker)
        let display = StreamProgramMetadata.nowPlayingDisplayStrings(
            fromParsed: parsed,
            rawFallback: rawUnparsed,
            stationName: stationName,
            languageName: languageName
        )
        XCTAssertEqual(display.title, programTitle)
        XCTAssertEqual(display.artist, "\(speaker) • \(stationName)")
    }

    func testNowPlayingDisplayStringsParsedTitleOnlyUsesLanguageArtistLine() {
        let parsed = StreamProgramMetadata(programTitle: programTitle, speaker: nil)
        let display = StreamProgramMetadata.nowPlayingDisplayStrings(
            fromParsed: parsed,
            rawFallback: rawUnparsed,
            stationName: stationName,
            languageName: languageName
        )
        XCTAssertEqual(display.title, programTitle)
        XCTAssertEqual(display.artist, "\(languageName) • \(stationName)")
    }

    func testNowPlayingDisplayStringsEmptyParsedTitleFallsBackToRaw() {
        let parsed = StreamProgramMetadata(programTitle: "", speaker: speaker)
        let display = StreamProgramMetadata.nowPlayingDisplayStrings(
            fromParsed: parsed,
            rawFallback: rawUnparsed,
            stationName: stationName,
            languageName: languageName
        )
        XCTAssertEqual(display.title, rawUnparsed)
        XCTAssertEqual(display.artist, "\(languageName) • \(stationName)")
    }

    func testNowPlayingDisplayStringsRawFallbackWhenParsedAbsent() {
        let display = StreamProgramMetadata.nowPlayingDisplayStrings(
            fromParsed: nil,
            rawFallback: rawUnparsed,
            stationName: stationName,
            languageName: languageName
        )
        XCTAssertEqual(display.title, rawUnparsed)
        XCTAssertEqual(display.artist, "\(languageName) • \(stationName)")
    }

    func testNowPlayingDisplayStringsStationFallbackWhenNoMetadata() {
        let display = StreamProgramMetadata.nowPlayingDisplayStrings(
            fromParsed: nil,
            rawFallback: nil,
            stationName: stationName,
            languageName: languageName
        )
        XCTAssertEqual(display.title, stationName)
        XCTAssertEqual(display.artist, "\(languageName) • \(stationName)")
    }

    func testNowPlayingDisplayStringsWhitespaceOnlyRawIsUsedAsTitle() {
        let whitespaceRaw = "   "
        let display = StreamProgramMetadata.nowPlayingDisplayStrings(
            fromParsed: nil,
            rawFallback: whitespaceRaw,
            stationName: stationName,
            languageName: languageName
        )
        XCTAssertEqual(display.title, whitespaceRaw)
        XCTAssertEqual(display.artist, "\(languageName) • \(stationName)")
    }

    func testNowPlayingDisplayStringsEmptySpeakerUsesLanguageArtistLine() {
        let parsed = StreamProgramMetadata(programTitle: programTitle, speaker: "")
        let display = StreamProgramMetadata.nowPlayingDisplayStrings(
            fromParsed: parsed,
            rawFallback: nil,
            stationName: stationName,
            languageName: languageName
        )
        XCTAssertEqual(display.title, programTitle)
        XCTAssertEqual(display.artist, "\(languageName) • \(stationName)")
    }

    // MARK: - Widget alignment (program title parity)

    func testNowPlayingDisplayStringsProgramTitleAlignsWithWidgetModelWhenPlaying() {
        let parsed = StreamProgramMetadata(programTitle: programTitle, speaker: speaker)
        let display = StreamProgramMetadata.nowPlayingDisplayStrings(
            fromParsed: parsed,
            rawFallback: nil,
            stationName: stationName,
            languageName: languageName
        )
        let widgetModel = widgetNowPlayingDisplayModel(
            visualState: .playing,
            streamMetadata: parsed,
            languageName: languageName
        )
        XCTAssertEqual(display.title, widgetModel.programTitle)
        XCTAssertEqual(widgetModel.speakerLine, speaker)
    }

    func testNowPlayingDisplayStringsRawFallbackDiffersFromWidgetLiveFallbackByDesign() {
        let display = StreamProgramMetadata.nowPlayingDisplayStrings(
            fromParsed: nil,
            rawFallback: nil,
            stationName: stationName,
            languageName: languageName
        )
        let widgetModel = widgetNowPlayingDisplayModel(
            visualState: .playing,
            streamMetadata: nil,
            languageName: languageName
        )
        XCTAssertEqual(display.title, stationName)
        XCTAssertEqual(widgetModel.programTitle, widgetLiveStreamFallback(languageName: languageName))
        XCTAssertNotEqual(display.title, widgetModel.programTitle)
    }

    func testNowPlayingDisplayStringsMatrixDistinctArtistLinesAcrossPrimaryBranches() {
        let parsedWithSpeaker = StreamProgramMetadata(programTitle: programTitle, speaker: speaker)
        let parsedTitleOnly = StreamProgramMetadata(programTitle: programTitle, speaker: nil)

        let withSpeaker = StreamProgramMetadata.nowPlayingDisplayStrings(
            fromParsed: parsedWithSpeaker,
            rawFallback: nil,
            stationName: stationName,
            languageName: languageName
        )
        let titleOnly = StreamProgramMetadata.nowPlayingDisplayStrings(
            fromParsed: parsedTitleOnly,
            rawFallback: nil,
            stationName: stationName,
            languageName: languageName
        )
        let rawOnly = StreamProgramMetadata.nowPlayingDisplayStrings(
            fromParsed: nil,
            rawFallback: rawUnparsed,
            stationName: stationName,
            languageName: languageName
        )
        let stationOnly = StreamProgramMetadata.nowPlayingDisplayStrings(
            fromParsed: nil,
            rawFallback: nil,
            stationName: stationName,
            languageName: languageName
        )

        XCTAssertEqual(withSpeaker.title, titleOnly.title)
        XCTAssertNotEqual(withSpeaker.artist, titleOnly.artist)
        XCTAssertEqual(rawOnly.title, rawUnparsed)
        XCTAssertEqual(stationOnly.title, stationName)
        XCTAssertEqual(rawOnly.artist, stationOnly.artist)
    }
}
