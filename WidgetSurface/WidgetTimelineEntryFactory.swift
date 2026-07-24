//
//  WidgetTimelineEntryFactory.swift
//  WidgetSurface
//
//  Created by Jari Lammi on 14.7.2026.
//
//  Testable assembly for WidgetKit ``SimpleEntry`` and Control-widget ``Value`` field sets.
//  Providers remain thin: resolve snapshot fields + slices, then map through this factory.
//
//  Pure presentation slice assembly lives in ``WidgetProviderPresentationAssembly``.
//  Snapshot reads and stream-catalog labels live on ``WidgetProviderSnapshotResolver``
//  (membership-exception source under `Lutheran Radio/`).
//
//  - SeeAlso: ``WidgetProviderPresentationAssembly``, ``WidgetProviderSnapshotResolver``,
//    docs/Widget-Presentation-Dataflow.md, docs/Widget-Functionality-Roadmap.md.
//

import Foundation

/// Snapshot fields resolved for WidgetKit Provider timeline and Control Center reads.
public struct WidgetProviderSnapshotFields: Sendable, Equatable {
    public let currentLanguage: String
    public let hasError: Bool
    public let visualState: PlayerVisualState
    public let streamMetadata: StreamProgramMetadata?

    public init(
        currentLanguage: String,
        hasError: Bool,
        visualState: PlayerVisualState,
        streamMetadata: StreamProgramMetadata?
    ) {
        self.currentLanguage = currentLanguage
        self.hasError = hasError
        self.visualState = visualState
        self.streamMetadata = streamMetadata
    }
}

/// Pre-derived presentation slices assembled once from resolved snapshot fields.
///
/// Home-widget ``SimpleEntry`` stores only these slices plus station / language / streams —
/// not the full ``PlayerVisualState`` or raw ``StreamProgramMetadata`` (already folded into
/// ``widgetNowPlayingDisplayModel`` and status/control presentations).
public struct WidgetProviderPresentationSlices: Sendable, Equatable {
    public let currentLanguageCode: String
    public let currentStation: String
    public let statusPresentation: PlayerStatusPresentation
    public let controlPresentation: PlayerControlPresentation
    public let widgetNowPlayingDisplayModel: WidgetNowPlayingDisplayModel

    public init(
        currentLanguageCode: String,
        currentStation: String,
        statusPresentation: PlayerStatusPresentation,
        controlPresentation: PlayerControlPresentation,
        widgetNowPlayingDisplayModel: WidgetNowPlayingDisplayModel
    ) {
        self.currentLanguageCode = currentLanguageCode
        self.currentStation = currentStation
        self.statusPresentation = statusPresentation
        self.controlPresentation = controlPresentation
        self.widgetNowPlayingDisplayModel = widgetNowPlayingDisplayModel
    }
}

/// Field bundle for home-widget ``SimpleEntry`` synthesis (extension adds streams + configuration).
///
/// Carries policy-side fields (`visualState`, `streamMetadata`) for Control-adjacent tests and
/// DEBUG logging; ``SimpleEntry`` itself stores only the narrow presentation slices that family
/// views consume (see ``WidgetTimelineEntryFactory/makeHomeWidgetBlueprint``).
public struct WidgetHomeTimelineEntryBlueprint: Sendable, Equatable {
    public let date: Date
    public let visualState: PlayerVisualState
    public let currentStation: String
    public let currentLanguageCode: String
    public let statusPresentation: PlayerStatusPresentation
    public let controlPresentation: PlayerControlPresentation
    public let widgetNowPlayingDisplayModel: WidgetNowPlayingDisplayModel
    public let streamMetadata: StreamProgramMetadata?

    public init(
        date: Date,
        visualState: PlayerVisualState,
        currentStation: String,
        currentLanguageCode: String,
        statusPresentation: PlayerStatusPresentation,
        controlPresentation: PlayerControlPresentation,
        widgetNowPlayingDisplayModel: WidgetNowPlayingDisplayModel,
        streamMetadata: StreamProgramMetadata?
    ) {
        self.date = date
        self.visualState = visualState
        self.currentStation = currentStation
        self.currentLanguageCode = currentLanguageCode
        self.statusPresentation = statusPresentation
        self.controlPresentation = controlPresentation
        self.widgetNowPlayingDisplayModel = widgetNowPlayingDisplayModel
        self.streamMetadata = streamMetadata
    }
}

/// Field bundle for Control-widget ``Value`` synthesis.
public struct WidgetControlValueBlueprint: Sendable, Equatable {
    public let visualState: PlayerVisualState
    public let currentStation: String
    public let statusPresentation: PlayerStatusPresentation
    public let controlPresentation: PlayerControlPresentation

    public init(
        visualState: PlayerVisualState,
        currentStation: String,
        statusPresentation: PlayerStatusPresentation,
        controlPresentation: PlayerControlPresentation
    ) {
        self.visualState = visualState
        self.currentStation = currentStation
        self.statusPresentation = statusPresentation
        self.controlPresentation = controlPresentation
    }
}

/// Maps resolved snapshot fields + presentation slices into Provider entry blueprints.
public enum WidgetTimelineEntryFactory {

    /// Assembles the home-widget timeline entry field set from resolver output.
    ///
    /// - Parameters:
    ///   - date: Timeline entry date (typically `Date()`).
    ///   - fields: Authoritative snapshot fields.
    ///   - slices: Pre-derived presentation slices from
    ///     ``WidgetProviderPresentationAssembly/assemblePresentationSlices(from:languageName:stationLabel:)``
    ///     (or the stream-catalog wrapper ``WidgetProviderSnapshotResolver/assemblePresentationSlices(from:)``).
    /// - Returns: Blueprint ready for ``SimpleEntry`` population (plus `availableStreams` and `configuration`).
    public static func makeHomeWidgetBlueprint(
        date: Date,
        fields: WidgetProviderSnapshotFields,
        slices: WidgetProviderPresentationSlices
    ) -> WidgetHomeTimelineEntryBlueprint {
        WidgetHomeTimelineEntryBlueprint(
            date: date,
            visualState: fields.visualState,
            currentStation: slices.currentStation,
            currentLanguageCode: slices.currentLanguageCode,
            statusPresentation: slices.statusPresentation,
            controlPresentation: slices.controlPresentation,
            widgetNowPlayingDisplayModel: slices.widgetNowPlayingDisplayModel,
            streamMetadata: fields.streamMetadata
        )
    }

    /// Assembles the Control-widget value field set from resolver output.
    ///
    /// - Parameters:
    ///   - fields: Authoritative snapshot fields.
    ///   - slices: Pre-derived presentation slices.
    /// - Returns: Blueprint ready for Control-widget ``Value`` population.
    public static func makeControlWidgetBlueprint(
        fields: WidgetProviderSnapshotFields,
        slices: WidgetProviderPresentationSlices
    ) -> WidgetControlValueBlueprint {
        WidgetControlValueBlueprint(
            visualState: fields.visualState,
            currentStation: slices.currentStation,
            statusPresentation: slices.statusPresentation,
            controlPresentation: slices.controlPresentation
        )
    }
}
