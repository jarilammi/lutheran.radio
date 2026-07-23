//
//  WidgetDisplayModels.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 12.6.2026.
//

// SHARED: Cross-target source (main app + LutheranRadioWidgetExtension)
//
// Membership-exception file compiled into both targets via project.pbxproj.
// Intent *execution* lives in WidgetIntentExecution.swift (same exception set).
//
// Purpose (this file — snapshot hygiene + catalog labels that require
// ``SharedPlayerManager``):
// - Stream-catalog-aware ``displayLanguageName(for:)`` (wraps pure WidgetSurface helpers).
// - ``WidgetProviderSnapshotResolver`` — Provider snapshot reads, actor hygiene, and
//   stream-catalog station labels; pure presentation assembly is delegated to
//   ``WidgetProviderPresentationAssembly`` in WidgetSurface.
//
// AGENT NOTE: Pure presentation types and mapping live in **WidgetSurface**, not here:
// - Status/control: ``PlayerVisualState/makeStatusPresentation()``,
//   ``PlayerVisualState/makeControlPresentation()`` (`WidgetSurface/PlayerVisualState.swift`)
// - Metadata/emphasis SSOT: ``WidgetMetadataEmphasis``, ``WidgetNowPlayingDisplayModel``,
//   ``widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)``
//   (`WidgetSurface/WidgetNowPlayingDisplay.swift`)
// - Language chrome: ``displayFlag(for:)``, pure
//   ``displayLanguageName(for:preferredStreamLanguage:)`` (`WidgetSurface/WidgetLanguageDisplay.swift`)
// - Pure Provider slice assembly: ``WidgetProviderPresentationAssembly``
// - Intent *plans*: ``WidgetIntentCoordinators``; *blueprints*: ``WidgetTimelineEntryFactory``
//
// This file stays cross-target because snapshot hygiene must call ``SharedPlayerManager``.
// Intent execution lives in WidgetIntentExecution.swift (same membershipExceptions set).
// Moving those call sites into WidgetSurface would create a circular module dependency
// (`SharedPlayerManager` already imports WidgetSurface).
//
// No security logic and no AVPlayer/streaming ownership.
//
// - SeeAlso: docs/Widget-Presentation-Dataflow.md, docs/Widget-Functionality-Roadmap.md,
//   ``WidgetProviderPresentationAssembly``, ``WidgetIntentCoordinators``,
//   ``WidgetTimelineEntryFactory``, CODING_AGENT.md (cross-target widget sources).

import Foundation
import WidgetSurface

// MARK: - Stream-catalog language name (membership-exception wrapper)
//
// ``displayFlag(for:)`` and pure ``displayLanguageName(for:preferredStreamLanguage:)``
// live in WidgetSurface. This wrapper prefers ``SharedPlayerManager/availableStreams``
// so Live Activity alt buttons and previews match the app stream catalog.
//
// Contracts: `WidgetDisplayModelsExtensionTests` (stream-list preference, unknown capitalize).
// - SeeAlso: docs/Widget-Functionality-Roadmap.md (Tier 5 display helper index).

/// Localized display name for a stream language code (LA alt buttons + previews).
///
/// Prefers ``SharedPlayerManager/availableStreams``; otherwise uses pure WidgetSurface
/// curated `Localizable` keys for en/de/fi/sv/et, then `code.capitalized`.
///
/// - Parameter code: BCP-47-style language code (e.g. `"fi"`).
/// - Returns: Non-empty display name suitable for UI.
/// - SeeAlso: ``displayFlag(for:)``, ``displayLanguageName(for:preferredStreamLanguage:)``,
///   docs/Widget-Functionality-Roadmap.md.
internal func displayLanguageName(for code: String) -> String {
    let preferred = SharedPlayerManager.shared.availableStreams
        .first(where: { $0.languageCode == code })?
        .language
    return displayLanguageName(for: code, preferredStreamLanguage: preferred)
}

// MARK: - Provider snapshot resolution (hygiene + catalog labels)

/// Canonical resolver for home-widget and Control-widget Provider entry points.
///
/// Documents which paths require an actor hop versus safe direct snapshot reads.
/// Cross-process freshness still depends on main-app ``WidgetRefreshManager`` timeline reloads;
/// the resolver only governs in-process read hygiene inside the extension.
///
/// Pure presentation assembly is ``WidgetProviderPresentationAssembly``; this type owns
/// ``SharedPlayerManager`` snapshot reads, actor hygiene, and stream-catalog labels.
///
/// - SeeAlso: ``SharedPlayerManager/refreshVisualStateFromPersistence()``,
///   ``SharedPlayerManager/loadPersistedWidgetState()``,
///   ``WidgetProviderPresentationAssembly``, docs/Widget-Functionality-Roadmap.md.
enum WidgetProviderSnapshotResolver {

    /// Resolves snapshot fields without an actor hop.
    ///
    /// Safe when the Provider consumes only static snapshot readers (`loadPersistedWidgetState`,
    /// `preferredWidgetLanguage`, `streamForLanguageCode`) and never consults
    /// ``SharedPlayerManager/currentVisualState``. Home-widget timeline rendering uses this
    /// after optional hygiene because `getPendingOrCurrentState` never falls back to actor state.
    ///
    /// - Returns: Authoritative session snapshot fields, or factory `.prePlay` defaults when absent.
    nonisolated static func resolveFromSnapshot() -> WidgetProviderSnapshotFields {
        if let combined = SharedPlayerManager.loadPersistedWidgetState() {
            return WidgetProviderSnapshotFields(
                currentLanguage: combined.currentLanguage,
                hasError: combined.hasError,
                visualState: combined.visualState,
                streamMetadata: combined.streamMetadata
            )
        }
        return WidgetProviderSnapshotFields(
            currentLanguage: SharedPlayerManager.preferredWidgetLanguage(),
            hasError: false,
            visualState: .prePlay,
            streamMetadata: nil
        )
    }

    /// Full provider hygiene: resets the actor loaded-guard, then resolves snapshot fields.
    ///
    /// Required when a Provider may consult ``SharedPlayerManager/currentVisualState`` (Control Center
    /// App Group-unavailable fallback) and recommended for every timeline `snapshot` / `timeline`
    /// request in long-lived extension processes after optimistic ``persistOptimisticWidgetSnapshot``
    /// writes. The hop synchronizes the actor guard; snapshot reads remain static.
    ///
    /// - Parameter manager: The shared actor instance for the executing process.
    /// - Returns: Fields from ``resolveFromSnapshot()`` after hygiene.
    static func resolveWithActorHygiene(
        manager: SharedPlayerManager = .shared
    ) async -> WidgetProviderSnapshotFields {
        await manager.refreshVisualStateFromPersistence()
        return resolveFromSnapshot()
    }

    /// Localized station label (`flag + language name`) for a language code.
    ///
    /// - Parameter languageCode: BCP-47-style stream code from the snapshot.
    /// - Returns: Display string used by home-widget `currentStation` and Control-widget `Value`.
    nonisolated static func stationLabel(for languageCode: String) -> String {
        let stream = SharedPlayerManager.streamForLanguageCode(languageCode)
        return stream.flag + " " + stream.language
    }

    /// Assembles the three narrow presentation surfaces plus station label from snapshot fields.
    ///
    /// Resolves stream-catalog language labels, then delegates pure presentation synthesis to
    /// ``WidgetProviderPresentationAssembly``. Home-widget ``SimpleEntry`` and Control-widget
    /// ``Value`` must consume these slices rather than re-invoking presentation mappers in
    /// timeline or value-provider paths.
    ///
    /// - Parameter fields: Authoritative snapshot fields from ``resolveFromSnapshot()`` or
    ///   ``resolveWithActorHygiene(manager:)``.
    /// - Returns: Pre-derived slices ready to populate ``SimpleEntry`` / Control-widget ``Value``.
    /// - SeeAlso: ``WidgetProviderPresentationAssembly/assemblePresentationSlices(from:languageName:stationLabel:)``,
    ///   ``WidgetProviderPresentationSlices``, ``WidgetProviderSnapshotFields``,
    ///   docs/Widget-Presentation-Dataflow.md, docs/Widget-Functionality-Roadmap.md.
    nonisolated static func assemblePresentationSlices(
        from fields: WidgetProviderSnapshotFields
    ) -> WidgetProviderPresentationSlices {
        let stream = SharedPlayerManager.streamForLanguageCode(fields.currentLanguage)
        return WidgetProviderPresentationAssembly.assemblePresentationSlices(
            from: fields,
            languageName: stream.language,
            stationLabel: stationLabel(for: fields.currentLanguage)
        )
    }
}
