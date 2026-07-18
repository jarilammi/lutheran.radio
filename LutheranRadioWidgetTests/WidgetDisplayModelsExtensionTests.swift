//
//  WidgetDisplayModelsExtensionTests.swift
//  LutheranRadioWidgetTests
//
//  Created by Jari Lammi on 15.7.2026.
//
//  Extension-profile port of metadata resolver + Provider synthesis contracts, plus
//  stream-catalog ``displayLanguageName(for:)`` and pure ``displayFlag(for:)`` (WidgetSurface).
//  Compiles membership-exception ``WidgetDisplayModels.swift`` without `LUTHERAN_MAIN_APP`
//  (same as the widget extension).
//
//  - SeeAlso: ``widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)``,
//    ``WidgetProviderSnapshotResolver``, ``WidgetProviderPresentationAssembly``,
//    ``displayFlag(for:)``, ``displayLanguageName(for:)``,
//    docs/Widget-Functionality-Roadmap.md.
//

import XCTest
import WidgetSurface

/// Metadata resolver matrix + Provider assembly under the extension compile profile.
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

    private func snapshotFields(
        visualState: PlayerVisualState,
        language: String = "fi",
        metadata: StreamProgramMetadata? = nil,
        hasError: Bool = false
    ) -> WidgetProviderSnapshotFields {
        WidgetProviderSnapshotFields(
            currentLanguage: language,
            hasError: hasError,
            visualState: visualState,
            streamMetadata: metadata
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

    // MARK: - Metadata resolver (extension-profile)

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

    func testUserPausedWithTitleRetainsSubduedTitle() {
        let model = resolve(visualState: .userPaused, metadata: metadata(title: programTitle))
        XCTAssertEqual(model.programTitle, programTitle)
        XCTAssertEqual(model.emphasis, .subdued)
    }

    func testPrePlayWithoutMetadataUsesLiveFallbackSubdued() {
        let model = resolve(visualState: .prePlay, metadata: nil)
        XCTAssertEqual(model.programTitle, liveFallback)
        XCTAssertEqual(model.emphasis, .subdued)
    }

    // MARK: - Provider snapshot resolver

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

    // MARK: - Presentation assembly + factory blueprint (Provider synthesis)

    func testAssemblePresentationSlicesMatrixMapsEveryVisualState() {
        let states: [PlayerVisualState] = [
            .prePlay, .cleared, .playing, .userPaused, .thermalPaused, .securityLocked
        ]

        for state in states {
            let fields = snapshotFields(visualState: state, language: "en")
            let slices = WidgetProviderSnapshotResolver.assemblePresentationSlices(from: fields)
            let stream = SharedPlayerManager.streamForLanguageCode("en")

            XCTAssertEqual(slices.statusPresentation, state.makeStatusPresentation())
            XCTAssertEqual(slices.controlPresentation, state.makeControlPresentation())
            XCTAssertEqual(
                slices.widgetNowPlayingDisplayModel,
                widgetNowPlayingDisplayModel(
                    visualState: state,
                    streamMetadata: nil,
                    languageName: stream.language
                )
            )
        }
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

    // MARK: - displayFlag / displayLanguageName (pure helpers)

    /// Flag mapping for curated LA alt-stream + preview codes (no stream dependency).
    func testDisplayFlagMatrixForCuratedLanguageCodes() {
        XCTAssertEqual(displayFlag(for: "en"), "🇺🇸")
        XCTAssertEqual(displayFlag(for: "de"), "🇩🇪")
        XCTAssertEqual(displayFlag(for: "fi"), "🇫🇮")
        XCTAssertEqual(displayFlag(for: "sv"), "🇸🇪")
        XCTAssertEqual(displayFlag(for: "et"), "🇪🇪")
    }

    /// Unknown codes use the globe fallback (never empty).
    func testDisplayFlagUnknownCodeUsesGlobeFallback() {
        XCTAssertEqual(displayFlag(for: "xx"), "🌍")
        XCTAssertEqual(displayFlag(for: ""), "🌍")
        XCTAssertEqual(displayFlag(for: "nb"), "🌍")
    }

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
        // Cross-check: stream list language is non-empty and not the raw code.
        XCTAssertFalse(en.language.isEmpty)
        XCTAssertNotEqual(displayLanguageName(for: "en"), "en")
    }

    /// Codes absent from the stream list use localized fallback or capitalized code.
    ///
    /// Stub ``availableStreams`` only covers en/de/fi/sv/et; fallback switch still covers
    /// those same codes when streams are empty, but for a truly unknown code we capitalize.
    func testDisplayLanguageNameUnknownCodeCapitalizes() {
        XCTAssertEqual(displayLanguageName(for: "xx"), "Xx")
        XCTAssertEqual(displayLanguageName(for: "zz"), "Zz")
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
