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
import WidgetSurface
@testable import Lutheran_Radio

/// Protects the canonical title / speaker / emphasis mapping for every
/// `PlayerVisualState` × metadata presence combination (main-app test host),
/// plus Provider snapshot hygiene and stream-catalog assembly wrappers.
///
/// Pure presentation assembly without the stream catalog is covered in
/// `WidgetSurfaceTests`. This suite exercises membership-exception paths that
/// read ``SharedPlayerManager``. No WidgetCenter IPC or ActivityKit.
///
/// - SeeAlso: ``WidgetProviderSnapshotResolver``, ``WidgetProviderPresentationAssembly``,
///   docs/Widget-Presentation-Dataflow.md,
///   docs/Widget-Functionality-Roadmap.md (Tier 2 + Tier 5 provider synthesis).
final class WidgetDisplayModelsTests: XCTestCase {

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

    // MARK: - Provider snapshot resolver (Tier 3)

    /// Verifies ``WidgetProviderSnapshotResolver/resolveFromSnapshot()`` returns persisted fields.
    func testProviderSnapshotResolverReturnsPersistedFields() async {
        await MainActor.run {
            WidgetRefreshManager.setHasActiveLutheranWidgets(true)
        }
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

    /// Verifies factory defaults when no in-session snapshot exists.
    func testProviderSnapshotResolverDefaultsToPrePlayWhenSnapshotAbsent() async {
        await SharedPlayerManager.clearAllLocalState()
        XCTAssertNil(SharedPlayerManager.loadPersistedWidgetState())

        let fields = WidgetProviderSnapshotResolver.resolveFromSnapshot()
        XCTAssertEqual(fields.visualState, .prePlay)
        XCTAssertFalse(fields.hasError)
        XCTAssertFalse(fields.currentLanguage.isEmpty)
    }

    /// Verifies ``WidgetProviderSnapshotResolver/stationLabel(for:)`` uses the stream facade.
    func testProviderSnapshotResolverStationLabelUsesStreamFacade() {
        let label = WidgetProviderSnapshotResolver.stationLabel(for: "fi")
        XCTAssertTrue(label.contains("🇫🇮"))
        XCTAssertFalse(label.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    // MARK: - resolveWithActorHygiene (Tier 3 provider hygiene)

    /// Verifies ``resolveWithActorHygiene(manager:)`` returns the same snapshot fields as
    /// ``resolveFromSnapshot()`` after the actor hygiene hop.
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
        XCTAssertEqual(hygieneFields.streamMetadata?.programTitle, programTitle)
    }

    /// Verifies the hygiene hop reloads ``SharedPlayerManager/currentVisualState`` from the
    /// in-session snapshot when the actor holds stale in-memory policy.
    func testResolveWithActorHygieneReloadsActorVisualStateFromSnapshot() async {
        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .userPaused,
            language: "sv",
            streamMetadata: metadata(title: programTitle)
        )
        await manager.setVisualState(.prePlay)

        let fields = await WidgetProviderSnapshotResolver.resolveWithActorHygiene(manager: manager)

        XCTAssertEqual(fields.visualState, .userPaused)
        XCTAssertEqual(fields.currentLanguage, "sv")
        let actorVisual = await manager.currentVisualState
        XCTAssertEqual(actorVisual, .userPaused)
    }

    /// Verifies factory defaults survive hygiene when no in-session snapshot exists.
    func testResolveWithActorHygieneDefaultsToPrePlayWhenSnapshotAbsent() async {
        await SharedPlayerManager.clearAllLocalState()
        XCTAssertNil(SharedPlayerManager.loadPersistedWidgetState())

        let fields = await WidgetProviderSnapshotResolver.resolveWithActorHygiene(manager: manager)

        XCTAssertEqual(fields.visualState, .prePlay)
        XCTAssertFalse(fields.hasError)
        XCTAssertFalse(fields.currentLanguage.isEmpty)
        let actorVisual = await manager.currentVisualState
        XCTAssertEqual(actorVisual, .prePlay)
    }

    // MARK: - Provider presentation assembly (SimpleEntry / Control Value synthesis)

    /// Verifies ``assemblePresentationSlices(from:)`` maps every visual state through the
    /// three canonical presentation SSOTs (status, control, metadata).
    func testAssemblePresentationSlicesMatrixMapsEveryVisualState() {
        let states: [PlayerVisualState] = [
            .prePlay, .cleared, .playing, .userPaused, .thermalPaused, .securityLocked
        ]

        for state in states {
            let fields = snapshotFields(visualState: state, language: "en")
            let slices = WidgetProviderSnapshotResolver.assemblePresentationSlices(from: fields)
            let stream = SharedPlayerManager.streamForLanguageCode("en")

            XCTAssertEqual(slices.currentLanguageCode, "en")
            XCTAssertEqual(slices.currentStation, WidgetProviderSnapshotResolver.stationLabel(for: "en"))
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

    /// Verifies connection-error chrome is folded into ``statusPresentation.text``
    /// (no parallel statusMessage field) while preserving colors and control presentation.
    func testAssemblePresentationSlicesUsesConnectionErrorWhenHasError() {
        let fields = snapshotFields(visualState: .playing, language: "fi", hasError: true)
        let slices = WidgetProviderSnapshotResolver.assemblePresentationSlices(from: fields)
        let expectedError = String(
            localized: "Connection error",
            defaultValue: "Connection error",
            table: "Localizable"
        )
        let base = PlayerVisualState.playing.makeStatusPresentation()

        XCTAssertEqual(slices.statusPresentation.text, expectedError)
        XCTAssertEqual(slices.statusPresentation.background, base.background)
        XCTAssertEqual(slices.statusPresentation.foreground, base.foreground)
        XCTAssertEqual(slices.statusPresentation.systemImage, base.systemImage)
        XCTAssertEqual(slices.controlPresentation, PlayerVisualState.playing.makeControlPresentation())
    }

    /// Verifies metadata-bearing snapshots flow into ``widgetNowPlayingDisplayModel`` using
    /// the stream display name (SimpleEntry / Value synthesis contract).
    func testAssemblePresentationSlicesCarriesStreamMetadataIntoNowPlayingModel() {
        let meta = metadata(title: programTitle, speaker: speaker)
        let fields = snapshotFields(visualState: .playing, language: "fi", metadata: meta)
        let slices = WidgetProviderSnapshotResolver.assemblePresentationSlices(from: fields)
        let stream = SharedPlayerManager.streamForLanguageCode("fi")
        let expectedModel = widgetNowPlayingDisplayModel(
            visualState: .playing,
            streamMetadata: meta,
            languageName: stream.language
        )

        XCTAssertEqual(slices.widgetNowPlayingDisplayModel, expectedModel)
        XCTAssertEqual(slices.widgetNowPlayingDisplayModel.programTitle, programTitle)
        XCTAssertTrue(slices.widgetNowPlayingDisplayModel.speakerVisible)
    }

    /// Verifies Control-widget ``Value`` synthesis contract: slices match independent mapper calls.
    func testAssemblePresentationSlicesMatchesControlWidgetValueDerivation() {
        let fields = snapshotFields(
            visualState: .userPaused,
            language: "de",
            metadata: metadata(title: programTitle)
        )
        let slices = WidgetProviderSnapshotResolver.assemblePresentationSlices(from: fields)

        XCTAssertEqual(slices.statusPresentation, fields.visualState.makeStatusPresentation())
        XCTAssertEqual(slices.controlPresentation, fields.visualState.makeControlPresentation())
        XCTAssertEqual(slices.currentStation, WidgetProviderSnapshotResolver.stationLabel(for: "de"))
        XCTAssertEqual(slices.currentLanguageCode, fields.currentLanguage)
    }

    /// Verifies persisted snapshot → assembly path mirrors home-widget Provider entry synthesis.
    func testAssemblePresentationSlicesFromPersistedSnapshotMatchesProviderContract() async {
        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .playing,
            language: "et",
            streamMetadata: metadata(title: programTitle, speaker: speaker)
        )

        let fields = await WidgetProviderSnapshotResolver.resolveWithActorHygiene(manager: manager)
        let slices = WidgetProviderSnapshotResolver.assemblePresentationSlices(from: fields)
        let stream = SharedPlayerManager.streamForLanguageCode("et")

        XCTAssertEqual(fields.visualState, .playing)
        XCTAssertEqual(slices.currentLanguageCode, "et")
        XCTAssertEqual(slices.statusPresentation, PlayerVisualState.playing.makeStatusPresentation())
        XCTAssertEqual(
            slices.widgetNowPlayingDisplayModel,
            widgetNowPlayingDisplayModel(
                visualState: .playing,
                streamMetadata: fields.streamMetadata,
                languageName: stream.language
            )
        )
    }
}
