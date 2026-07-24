//
//  WidgetDisplayModelsExtensionTests.swift
//  LutheranRadioWidgetTests
//
//  Created by Jari Lammi on 15.7.2026.
//
//  Extension-profile linkage for membership-exception display models and Provider
//  synthesis. Full pure presentation matrices (every visual state, flag map) live
//  in WidgetSurfaceTests. This suite keeps snapshot / catalog / blueprint smoke that
//  exercises SharedPlayerManager under the widget compile profile.
//
//  - SeeAlso: ``widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)``,
//    ``WidgetProviderSnapshotResolver``, ``WidgetProviderPresentationAssembly``,
//    ``displayFlag(for:)``, ``displayLanguageName(for:)``,
//    docs/Widget-Functionality-Roadmap.md.
//

import XCTest
import WidgetSurface

/// Extension-profile snapshot resolver + thin presentation linkage smoke.
final class WidgetDisplayModelsExtensionTests: XCTestCase {

    private let manager = SharedPlayerManager.shared
    private let languageName = "TestLang"
    private let programTitle = "Sunday Sermon"
    private let speaker = "Guest Speaker"

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

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            WidgetRefreshManager.setHasActiveLutheranWidgets(true)
        }
        SharedPlayerManager.removeAllLocalPlaybackKeys()
    }

    override func tearDown() async throws {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        try await super.tearDown()
    }

    // MARK: - Metadata resolver (representative extension-profile samples)

    func testPlayingWithoutMetadataUsesLiveFallbackActiveEmphasis() {
        let model = resolve(visualState: .playing, metadata: nil)
        XCTAssertEqual(model.programTitle, liveFallback)
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

    func testUserPausedWithoutMetadataUsesNoTrackPlaceholder() {
        let model = resolve(visualState: .userPaused, metadata: nil)
        XCTAssertEqual(model.programTitle, noTrackPlaceholder)
        XCTAssertEqual(model.emphasis, .placeholder)
    }

    // MARK: - Provider snapshot resolver (membership-exception SSOT)

    func testProviderSnapshotResolverReturnsPersistedFields() {
        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .userPaused,
            language: "sv",
            streamMetadata: metadata(title: programTitle, speaker: speaker),
            hasError: false
        )

        let fields = WidgetProviderSnapshotResolver.resolveFromSnapshot()
        XCTAssertEqual(fields.visualState, .userPaused)
        XCTAssertEqual(fields.currentLanguage, "sv")
        XCTAssertFalse(fields.hasError)
        XCTAssertEqual(fields.streamMetadata?.programTitle, programTitle)
    }

    func testProviderSnapshotResolverDefaultsToPrePlayWhenSnapshotAbsent() async {
        await SharedPlayerManager.clearAllLocalState()
        XCTAssertNil(SharedPlayerManager.loadPersistedWidgetState())

        let fields = WidgetProviderSnapshotResolver.resolveFromSnapshot()
        XCTAssertEqual(fields.visualState, .prePlay)
        XCTAssertFalse(fields.hasError)
        XCTAssertFalse(fields.currentLanguage.isEmpty)
    }

    func testResolveWithActorHygieneMatchesResolveFromSnapshot() async {
        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .playing,
            language: "de",
            streamMetadata: metadata(title: programTitle, speaker: speaker)
        )

        let hygieneFields = await WidgetProviderSnapshotResolver.resolveWithActorHygiene(manager: manager)
        let directFields = WidgetProviderSnapshotResolver.resolveFromSnapshot()

        XCTAssertEqual(hygieneFields, directFields)
        XCTAssertEqual(hygieneFields.visualState, .playing)
        XCTAssertEqual(hygieneFields.currentLanguage, "de")
    }

    // MARK: - Presentation assembly + factory blueprint (thin linkage smoke)

    /// Single-state assembly smoke under extension linkage (full matrix in WidgetSurfaceTests).
    func testAssemblePresentationSlicesPlayingSmokeLinksUnderExtensionProfile() {
        let fields = WidgetProviderSnapshotFields(
            currentLanguage: "en",
            hasError: false,
            visualState: .playing,
            streamMetadata: nil
        )
        let slices = WidgetProviderSnapshotResolver.assemblePresentationSlices(from: fields)
        XCTAssertEqual(slices.statusPresentation, PlayerVisualState.playing.makeStatusPresentation())
        XCTAssertEqual(slices.controlPresentation, PlayerVisualState.playing.makeControlPresentation())
    }

    func testHomeBlueprintFromResolverMatchesProviderContract() {
        let meta = metadata(title: programTitle, speaker: speaker)
        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .playing,
            language: "fi",
            streamMetadata: meta
        )

        let fields = WidgetProviderSnapshotResolver.resolveFromSnapshot()
        let slices = WidgetProviderSnapshotResolver.assemblePresentationSlices(from: fields)
        let blueprint = WidgetTimelineEntryFactory.makeHomeWidgetBlueprint(
            date: Date(),
            fields: fields,
            slices: slices
        )

        XCTAssertEqual(blueprint.visualState, .playing)
        XCTAssertEqual(blueprint.currentLanguageCode, "fi")
        XCTAssertEqual(blueprint.statusPresentation, slices.statusPresentation)
        XCTAssertEqual(blueprint.controlPresentation, slices.controlPresentation)
        XCTAssertEqual(blueprint.widgetNowPlayingDisplayModel, slices.widgetNowPlayingDisplayModel)
        XCTAssertEqual(blueprint.streamMetadata?.programTitle, programTitle)
    }

    func testControlBlueprintFromResolverMatchesProviderContract() {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: "de")

        let fields = WidgetProviderSnapshotResolver.resolveFromSnapshot()
        let slices = WidgetProviderSnapshotResolver.assemblePresentationSlices(from: fields)
        let blueprint = WidgetTimelineEntryFactory.makeControlWidgetBlueprint(
            fields: fields,
            slices: slices
        )

        XCTAssertEqual(blueprint.visualState, .userPaused)
        XCTAssertEqual(blueprint.statusPresentation, slices.statusPresentation)
        XCTAssertEqual(blueprint.controlPresentation, slices.controlPresentation)
        XCTAssertEqual(blueprint.currentStation, slices.currentStation)
    }

    // MARK: - Catalog-aware display helpers (extension stream stub linkage)

    /// Known codes prefer ``SharedPlayerManager/availableStreams`` language names.
    func testDisplayLanguageNamePrefersAvailableStreams() {
        let streams = manager.availableStreams
        guard let en = streams.first(where: { $0.languageCode == "en" }),
              let fi = streams.first(where: { $0.languageCode == "fi" }) else {
            XCTFail("Stub streams must include en and fi")
            return
        }
        XCTAssertEqual(displayLanguageName(for: "en"), en.language)
        XCTAssertEqual(displayLanguageName(for: "fi"), fi.language)
        XCTAssertFalse(en.language.isEmpty)
        XCTAssertNotEqual(displayLanguageName(for: "en"), "en")
    }

    /// Curated codes match stream-list flags when present (LA button consistency).
    func testDisplayFlagMatchesStreamListFlagsWhenAvailable() {
        for stream in manager.availableStreams {
            XCTAssertEqual(
                displayFlag(for: stream.languageCode),
                stream.flag,
                "displayFlag must match stream.flag for \(stream.languageCode)"
            )
        }
    }
}
