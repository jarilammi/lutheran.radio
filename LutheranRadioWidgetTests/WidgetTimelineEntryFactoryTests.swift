//
//  WidgetTimelineEntryFactoryTests.swift
//  LutheranRadioWidgetTests
//
//  Created by Jari Lammi on 15.7.2026.
//
//  Thin extension-profile smoke for ``WidgetTimelineEntryFactory`` blueprints.
//  Full per-visual-state presentation matrices live in WidgetSurfaceTests.
//
//  - SeeAlso: ``WidgetTimelineEntryFactory``, ``WidgetProviderPresentationSlices``,
//    docs/Widget-Functionality-Roadmap.md, docs/Widget-Presentation-Dataflow.md.
//

import XCTest
import WidgetSurface

/// Extension-profile linkage for home/Control blueprint assembly (full matrices elsewhere).
final class WidgetTimelineEntryFactoryTests: XCTestCase {

    private let entryDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func fields(
        visualState: PlayerVisualState = .playing,
        language: String = "fi",
        hasError: Bool = false,
        metadata: StreamProgramMetadata? = nil
    ) -> WidgetProviderSnapshotFields {
        WidgetProviderSnapshotFields(
            currentLanguage: language,
            hasError: hasError,
            visualState: visualState,
            streamMetadata: metadata
        )
    }

    private func slices(
        for state: PlayerVisualState,
        language: String = "fi",
        station: String = "🇫🇮 Finnish",
        metadataModel: WidgetNowPlayingDisplayModel? = nil
    ) -> WidgetProviderPresentationSlices {
        let status = state.makeStatusPresentation()
        let control = state.makeControlPresentation()
        let model = metadataModel ?? widgetNowPlayingDisplayModel(
            visualState: state,
            streamMetadata: nil,
            languageName: "Finnish"
        )
        return WidgetProviderPresentationSlices(
            currentLanguageCode: language,
            currentStation: station,
            statusPresentation: status,
            controlPresentation: control,
            widgetNowPlayingDisplayModel: model
        )
    }

    /// Home blueprint carries date, visual state, metadata, and all three presentation slices.
    func testMakeHomeWidgetBlueprintCopiesFieldsAndSlices() {
        let meta = StreamProgramMetadata(programTitle: "Sermon", speaker: "Pastor")
        let f = fields(visualState: .userPaused, language: "sv", metadata: meta)
        let s = slices(for: .userPaused, language: "sv", station: "🇸🇪 Swedish")

        let blueprint = WidgetTimelineEntryFactory.makeHomeWidgetBlueprint(
            date: entryDate,
            fields: f,
            slices: s
        )

        XCTAssertEqual(blueprint.date, entryDate)
        XCTAssertEqual(blueprint.visualState, .userPaused)
        XCTAssertEqual(blueprint.currentStation, s.currentStation)
        XCTAssertEqual(blueprint.currentLanguageCode, "sv")
        XCTAssertEqual(blueprint.statusPresentation, s.statusPresentation)
        XCTAssertEqual(blueprint.controlPresentation, s.controlPresentation)
        XCTAssertEqual(blueprint.widgetNowPlayingDisplayModel, s.widgetNowPlayingDisplayModel)
        XCTAssertEqual(blueprint.streamMetadata, meta)
    }

    /// Control blueprint carries visual state, station, and status/control presentations only.
    func testMakeControlWidgetBlueprintCopiesFieldsAndSlices() {
        let f = fields(visualState: .playing, language: "de")
        let s = slices(for: .playing, language: "de", station: "🇩🇪 German")

        let blueprint = WidgetTimelineEntryFactory.makeControlWidgetBlueprint(
            fields: f,
            slices: s
        )

        XCTAssertEqual(blueprint.visualState, .playing)
        XCTAssertEqual(blueprint.currentStation, s.currentStation)
        XCTAssertEqual(blueprint.statusPresentation, s.statusPresentation)
        XCTAssertEqual(blueprint.controlPresentation, s.controlPresentation)
    }
}
