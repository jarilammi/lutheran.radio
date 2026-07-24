//
//  WidgetProviderPresentationAssembly.swift
//  WidgetSurface
//
//  Created by Jari Lammi on 18.7.2026.
//
//  Pure assembly of narrow presentation slices from ``WidgetProviderSnapshotFields``.
//  Presentation-only — no security logic (see Core/). Does not read
//  ``SharedPlayerManager``; language labels are supplied by the caller.
//
//  Snapshot *reads* and actor hygiene remain on ``WidgetProviderSnapshotResolver``
//  (membership-exception source under `Lutheran Radio/`), which resolves language
//  labels from the stream catalog and forwards into this assembly.
//
//  - SeeAlso: ``WidgetProviderSnapshotFields``, ``WidgetProviderPresentationSlices``,
//    ``WidgetTimelineEntryFactory``, ``widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)``,
//    docs/Widget-Presentation-Dataflow.md, docs/Widget-Functionality-Roadmap.md.
//

import Foundation

/// Pure Provider presentation assembly for home-widget and Control-widget entry synthesis.
///
/// Derives the three narrow presentation surfaces once from snapshot fields and
/// explicit language labels. Providers and ``WidgetProviderSnapshotResolver`` must
/// not re-invoke status/control/metadata mappers after assembly.
///
/// - SeeAlso: ``WidgetTimelineEntryFactory``, docs/Widget-Presentation-Dataflow.md.
public enum WidgetProviderPresentationAssembly {

    /// Assembles the three narrow presentation surfaces plus station label from snapshot fields.
    ///
    /// Single source of truth for pure presentation synthesis after snapshot resolution.
    /// Home-widget ``SimpleEntry`` and Control-widget ``Value`` consume these slices
    /// rather than re-invoking ``PlayerVisualState/makeStatusPresentation()``,
    /// ``PlayerVisualState/makeControlPresentation()``, or
    /// ``widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)``
    /// in timeline or value-provider paths.
    ///
    /// - Parameters:
    ///   - fields: Authoritative snapshot fields (visual state, language code, metadata, error).
    ///   - languageName: Localized stream language name used by the metadata/emphasis mapper
    ///     (from the stream catalog or ``displayLanguageName(for:preferredStreamLanguage:)``).
    ///   - stationLabel: Localized station chrome (`flag + " " + language name`) for
    ///     home-widget `currentStation` and Control-widget ``Value``.
    /// - Returns: Pre-derived slices ready to populate ``SimpleEntry`` / Control-widget ``Value``.
    /// - SeeAlso: ``WidgetProviderPresentationSlices``, ``WidgetProviderSnapshotFields``,
    ///   docs/Widget-Presentation-Dataflow.md, docs/Widget-Functionality-Roadmap.md.
    public static func assemblePresentationSlices(
        from fields: WidgetProviderSnapshotFields,
        languageName: String,
        stationLabel: String
    ) -> WidgetProviderPresentationSlices {
        let baseStatus = fields.visualState.makeStatusPresentation()
        // Fold `hasError` into the narrow status surface so family views never need a
        // parallel `statusMessage` string. `Connection error` is Localizable (21 langs);
        // marked extractionState: manual in the app catalog because this call site is in
        // WidgetSurface (catalog-owning targets would otherwise mark it stale).
        let statusPresentation: PlayerStatusPresentation
        if fields.hasError {
            statusPresentation = PlayerStatusPresentation(
                background: baseStatus.background,
                foreground: baseStatus.foreground,
                text: String(
                    localized: "Connection error",
                    defaultValue: "Connection error",
                    table: "Localizable"
                ),
                systemImage: baseStatus.systemImage
            )
        } else {
            statusPresentation = baseStatus
        }
        let controlPresentation = fields.visualState.makeControlPresentation()
        let metadataModel = widgetNowPlayingDisplayModel(
            visualState: fields.visualState,
            streamMetadata: fields.streamMetadata,
            languageName: languageName
        )
        return WidgetProviderPresentationSlices(
            currentLanguageCode: fields.currentLanguage,
            currentStation: stationLabel,
            statusPresentation: statusPresentation,
            controlPresentation: controlPresentation,
            widgetNowPlayingDisplayModel: metadataModel
        )
    }
}
