//
//  WidgetDisplayModels.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 12.6.2026.
//

// SHARED: Cross-target source (main app + LutheranRadioWidgetExtension)
//
// Single physical file compiled into both targets.
//
// Purpose:
// Owns the metadata/emphasis presentation axis for widgets and Live Activities
// (`WidgetMetadataEmphasis`, `WidgetNowPlayingDisplayModel`, resolver) and
// language/flag helpers. Complements the status and control presentation mappers
// that live on `PlayerVisualState`.
//
// This file is presentation-only. No security logic, no streaming, no intent handling.
//
// - SeeAlso: docs/Widget-Presentation-Dataflow.md (primary reference for the
//   three-surface snapshot-driven contract), `LutheranRadioWidget.swift`,
//   `LutheranRadioWidgetLiveActivity.swift`, `PlayerVisualState.swift`,
//   CODING_AGENT.md.

import Foundation

// MARK: - Shared Widget / Live Activity Display Models
//
// Three narrow presentation surfaces are consistently derived once at the snapshot /
// provider level and consumed as value types by WidgetKit and ActivityKit surfaces:
//
// - `statusPresentation: PlayerStatusPresentation` (via `makeStatusPresentation()`)
// - `controlPresentation: PlayerControlPresentation` (via `makeControlPresentation()`)
// - `widgetNowPlayingDisplayModel: WidgetNowPlayingDisplayModel` (via `widgetNowPlayingDisplayModel(...)`)
//
// `WidgetMetadataEmphasis` + `WidgetNowPlayingDisplayModel` + the resolver function
// are the Single Source of Truth for the program-title / speaker-line / emphasis axis
// (the metadata/emphasis counterpart to the two presentation types on PlayerVisualState).
//
// ## Snapshot-Driven Derivation Pattern
//
// All three are **pre-derived** at the Provider / top-of-view level:
//
// - In home widgets: `SimpleEntry` is populated inside the `Provider`
//   (`placeholder(in:)`, `snapshot(for:in:)`, `timeline(for:in:)` via `createEntry`).
//   `LutheranRadioWidgetEntryView` projects the pre-derived values into
//   `SmallWidgetView`, `MediumWidgetView`, `LargeWidgetView`, and `WidgetMetadataRegion`;
//   family views receive narrow slices only; no derivation inside `body`.
// - In Live Activities: `LockScreenLiveActivityView.body` and the outer `dynamicIsland`
//   closure each compute the three narrow models once near the top, then close over them
//   for the various regions and sub-layouts.
//
// Why pre-derivation matters for WidgetKit / ActivityKit:
// - WidgetKit performs field-wise comparison on `TimelineEntry` values to decide
//   whether a view needs re-evaluation / invalidation. A narrow derived value means
//   only changes that affect the concrete status text, play glyph/tint, or title/speaker
//   cause body work for the consumers of that slice.
// - ActivityKit Dynamic Island region builders run independently. Hoisting derivation
//   to the outer closure bounds CPU and allocation work to once per push.
// - Leaf views and region closures receive the smallest possible input (e.g. four fields
//   for metadata), making them simpler, cheaper to diff, and easier to reason about.
//
// The resolvers (`makeStatusPresentation`, `makeControlPresentation`, and
// `widgetNowPlayingDisplayModel`) remain the single places that encode the mapping rules
// over `PlayerVisualState` + metadata fallbacks.
//
// ## Terminology (exact project names)
// - `PlayerStatusPresentation` + `makeStatusPresentation()` — status indicator axis.
// - `PlayerControlPresentation` + `makeControlPresentation()` — primary control axis.
// - `widgetNowPlayingDisplayModel(...)` — the core metadata/emphasis resolver.
// - `WidgetNowPlayingDisplayModel` — narrow value type for title/speaker/emphasis.
// - `SimpleEntry` — the `TimelineEntry` snapshot carrying all three for home widgets.
// - `WidgetMetadataRegion` — fixed-height title + speaker slots (medium/large).
// - `Provider` — the `AppIntentTimelineProvider`.
// - `LutheranRadioLiveActivityWidget` / Dynamic Island regions / `LockScreenLiveActivityView`.
//
// - SeeAlso: `PlayerVisualState` (the source; hosts the status/control mappers),
//   ``PlayerVisualState/makeStatusPresentation()``, ``PlayerVisualState/makeControlPresentation()``,
//   `LutheranRadioWidget.swift` (SimpleEntry + Provider + family views),
//   `LutheranRadioWidgetLiveActivity.swift` (top-level derivation + regions),
//   `LutheranRadioLiveActivityAttributes.ContentState`,
//   `WidgetDisplayModels.swift` (this file),
//   CODING_AGENT.md (Documentation & Comment Standards, Single Source of Truth Principles,
//   narrow inputs for WidgetKit/ActivityKit, Cross-target shared source files (non-Core)),
//   docs/Widget-Presentation-Dataflow.md (concise permanent guidance),
//   <doc:Architecture>, README.md (Single Sources of Truth).
//
// All user-visible strings use `String(localized: "key", table: "Localizable")` with explicit table.

internal enum WidgetMetadataEmphasis: Equatable {
    case active
    case subdued
    case placeholder

    var opacity: Double {
        switch self {
        case .active: 1.0
        case .subdued: 0.55
        case .placeholder: 0.45
        }
    }
}

/// Narrow value type carrying the pre-computed program title, speaker line,
/// speaker visibility, and emphasis level for the metadata region.
///
/// This is the single data shape passed from `SimpleEntry` (widgets) or
/// computed once at the top of Live Activity views into `WidgetMetadataRegion`
/// and the equivalent fixed metadata blocks in lock screen / Dynamic Island center.
///
/// Produced exclusively by `widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)`.
/// Consumers must treat the four fields as the complete contract for that axis
/// (no re-inspection of `PlayerVisualState` or raw `StreamProgramMetadata` for title/speaker decisions).
///
/// - SeeAlso: `widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)`,
///   `WidgetMetadataRegion`, `SimpleEntry.widgetNowPlayingDisplayModel`,
///   `LutheranRadioWidget.swift`, `LutheranRadioWidgetLiveActivity.swift`,
///   `WidgetMetadataEmphasis`, CODING_AGENT.md.
internal struct WidgetNowPlayingDisplayModel: Equatable {
    /// Localized program title (or live fallback / "No track information" placeholder).
    let programTitle: String

    /// Speaker line, or a non-breaking space (U+00A0) when absent (for stable layout).
    let speakerLine: String

    /// Whether the speaker line should be visible (subject to emphasis.opacity).
    let speakerVisible: Bool

    /// Emphasis level controlling opacity and semantic treatment (active / subdued / placeholder).
    let emphasis: WidgetMetadataEmphasis
}

/// Returns the localized "X · Live Stream" fallback used when no ICY programTitle.
internal func widgetLiveStreamFallback(languageName: String) -> String {
    unsafe String(
        format: String(localized: "live_activity_program_fallback", defaultValue: "%@ · Live Stream", table: "Localizable"),
        languageName
    )
}

/// Returns speaker line if present and non-empty in metadata.
internal func widgetProgramSpeakerLine(metadata: StreamProgramMetadata?) -> String? {
    guard let speaker = metadata?.speaker, !speaker.isEmpty else { return nil }
    return speaker
}

/// Returns a `WidgetNowPlayingDisplayModel` by applying the canonical title/speaker/emphasis
/// rules to the given `PlayerVisualState` and optional `StreamProgramMetadata`.
///
/// This is the Single Source of Truth for the metadata/emphasis axis. It is called:
/// - Once per snapshot in `Provider.placeholder`, `Provider.snapshot`, `Provider.timeline`
///   (via `createEntry`) to populate `SimpleEntry.widgetNowPlayingDisplayModel`.
/// - Once at the top level of `LockScreenLiveActivityView.body` and once inside the
///   outer `dynamicIsland` closure for Live Activities.
///
/// The caller supplies the `languageName` (display name for the current stream) because
/// `LutheranRadioLiveActivityAttributes.ContentState` does not carry the language;
/// widgets carry it on `SimpleEntry.currentLanguageCode` + `availableStreams`.
///
/// The returned model always provides stable values (title present, speakerLine either
/// real value or "\u{00A0}" placeholder) so that `WidgetMetadataRegion` and LA metadata
/// blocks can use fixed-height frames without conditional view insertion.
///
/// - Parameters:
///   - visualState: The authoritative `PlayerVisualState` from the persisted snapshot.
///   - streamMetadata: Optional ICY `StreamProgramMetadata` (programTitle + speaker).
///   - languageName: Localized display name of the active stream (e.g. "English") for
///     the "X · Live Stream" fallback.
/// - Returns: A narrow display model with title, speakerLine, speakerVisible, emphasis.
/// - SeeAlso: `WidgetNowPlayingDisplayModel`, `SimpleEntry.widgetNowPlayingDisplayModel`,
///   `widgetLiveStreamFallback(languageName:)`, `widgetProgramSpeakerLine(metadata:)`,
///   `LutheranRadioWidget.swift` (Provider derivation sites),
///   `LutheranRadioWidgetLiveActivity.swift` (top-level calls in LA views),
///   `PlayerVisualState`, `WidgetDisplayModels.swift` (module header for pattern rationale),
///   CODING_AGENT.md (snapshot-driven pattern, narrow inputs).
internal func widgetNowPlayingDisplayModel(
    visualState: PlayerVisualState,
    streamMetadata: StreamProgramMetadata?,
    languageName: String
) -> WidgetNowPlayingDisplayModel {
    let metadata = streamMetadata
    let state = visualState
    let liveFallback = widgetLiveStreamFallback(languageName: languageName)
    let noTrack = String(localized: "no_track_info", defaultValue: "No track information", table: "Localizable")
    let speaker = widgetProgramSpeakerLine(metadata: metadata)

    let programTitle: String
    let emphasis: WidgetMetadataEmphasis

    switch state {
    case .playing:
        programTitle = metadata?.programTitle.flatMap { $0.isEmpty ? nil : $0 } ?? liveFallback
        emphasis = .active
    case .prePlay, .cleared:
        programTitle = metadata?.programTitle.flatMap { $0.isEmpty ? nil : $0 } ?? liveFallback
        emphasis = .subdued
    case .userPaused:
        if let title = metadata?.programTitle, !title.isEmpty {
            programTitle = title
            emphasis = .subdued
        } else {
            programTitle = noTrack
            emphasis = .placeholder
        }
    case .thermalPaused, .securityLocked:
        if let title = metadata?.programTitle, !title.isEmpty {
            programTitle = title
            emphasis = .subdued
        } else {
            programTitle = noTrack
            emphasis = .placeholder
        }
    }

    let speakerVisible = speaker != nil && (state.isActivelyPlaying || state == .userPaused || state == .prePlay || state == .cleared)

    return WidgetNowPlayingDisplayModel(
        programTitle: programTitle,
        speakerLine: speaker ?? "\u{00A0}",
        speakerVisible: speakerVisible,
        emphasis: emphasis
    )
}

// MARK: - Display name / flag helpers (module-internal)
//
// Used by the SwiftUI preview matrix and (via the existing thin get* wrappers)
// by Live Activity for its curated alt-stream buttons.
// Prefer the real availableStreams (full 21 languages + correct localized names from
// the app's static list) and fall back to the established mapping for the common codes.
// This is the general form so we never hard-code "Lutheran Radio - English" or
// "🇺🇸 English" in preview data.

internal func displayLanguageName(for code: String) -> String {
    // Prefer the authoritative streams (best, locale-correct names from the main app)
    if let s = SharedPlayerManager.shared.availableStreams.first(where: { $0.languageCode == code }) {
        return s.language
    }
    // Fallback mapping (covers the languages used in LA alt buttons + common preview cases).
    // Uses the same keys as the previous private getLanguageName in the Live Activity file.
    switch code {
    case "en": return String(localized: "language_english", table: "Localizable")
    case "de": return String(localized: "language_german", table: "Localizable")
    case "fi": return String(localized: "language_finnish", table: "Localizable")
    case "sv": return String(localized: "language_swedish", table: "Localizable")
    case "et": return String(localized: "language_estonian", table: "Localizable")
    default: return code.capitalized
    }
}

internal func displayFlag(for code: String) -> String {
    switch code {
    case "en": return "🇺🇸"
    case "de": return "🇩🇪"
    case "fi": return "🇫🇮"
    case "sv": return "🇸🇪"
    case "et": return "🇪🇪"
    default: return "🌍"
    }
}

// MARK: - Provider snapshot resolution (Tier 3 hygiene)

/// Snapshot fields resolved for WidgetKit Provider timeline and Control Center reads.
///
/// Populated exclusively from ``SharedPlayerManager/loadPersistedWidgetState()`` (or safe
/// `.prePlay` defaults). Providers pre-derive presentation surfaces from these fields once
/// per entry — never from raw ``PlayerVisualState`` policy inside leaf `body` builders.
///
/// - SeeAlso: ``WidgetProviderSnapshotResolver``, `SimpleEntry`, `LutheranRadioWidgetControl/Value`,
///   docs/Widget-Functionality-Roadmap.md (Tier 3 provider audit).
struct WidgetProviderSnapshotFields: Sendable, Equatable {
    let currentLanguage: String
    let hasError: Bool
    let visualState: PlayerVisualState
    let streamMetadata: StreamProgramMetadata?
}

/// Pre-derived presentation slices assembled once from resolved snapshot fields.
///
/// Shared contract for home-widget ``SimpleEntry`` population and Control-widget ``Value``
/// derivation. Providers call ``WidgetProviderSnapshotResolver/assemblePresentationSlices(from:)``
/// after ``resolveWithActorHygiene(manager:)`` (or ``resolveFromSnapshot()`` for static previews)
/// so leaf views never re-derive mapping rules inside `body`.
///
/// - SeeAlso: ``WidgetProviderSnapshotResolver``, `SimpleEntry`, docs/Widget-Presentation-Dataflow.md,
///   docs/Widget-Functionality-Roadmap.md (Tier 3 provider audit).
struct WidgetProviderPresentationSlices: Sendable, Equatable {
    let currentLanguageCode: String
    let currentStation: String
    let statusPresentation: PlayerStatusPresentation
    let controlPresentation: PlayerControlPresentation
    let statusMessage: String
    let widgetNowPlayingDisplayModel: WidgetNowPlayingDisplayModel
}

/// Canonical resolver for home-widget and Control-widget Provider entry points.
///
/// Documents which paths require an actor hop versus safe direct snapshot reads.
/// Cross-process freshness still depends on main-app ``WidgetRefreshManager`` timeline reloads;
/// the resolver only governs in-process read hygiene inside the extension.
///
/// - SeeAlso: ``SharedPlayerManager/refreshVisualStateFromPersistence()``,
///   ``SharedPlayerManager/loadPersistedWidgetState()``, docs/Widget-Functionality-Roadmap.md.
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
    /// Single source of truth for Provider entry synthesis after snapshot resolution.
    /// Home-widget ``SimpleEntry`` and Control-widget ``Value`` must consume these slices
    /// rather than re-invoking ``PlayerVisualState/makeStatusPresentation()``,
    /// ``PlayerVisualState/makeControlPresentation()``, or ``widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)``
    /// in timeline or value-provider paths.
    ///
    /// - Parameter fields: Authoritative snapshot fields from ``resolveFromSnapshot()`` or
    ///   ``resolveWithActorHygiene(manager:)``.
    /// - Returns: Pre-derived slices ready to populate ``SimpleEntry`` / Control-widget ``Value``.
    /// - SeeAlso: ``WidgetProviderPresentationSlices``, ``WidgetProviderSnapshotFields``,
    ///   docs/Widget-Presentation-Dataflow.md, docs/Widget-Functionality-Roadmap.md.
    nonisolated static func assemblePresentationSlices(
        from fields: WidgetProviderSnapshotFields
    ) -> WidgetProviderPresentationSlices {
        let currentStream = SharedPlayerManager.streamForLanguageCode(fields.currentLanguage)
        let statusPresentation = fields.visualState.makeStatusPresentation()
        let controlPresentation = fields.visualState.makeControlPresentation()
        let statusMessage: String = fields.hasError
            ? String(localized: "Connection error", defaultValue: "Connection error", table: "Localizable")
            : statusPresentation.text
        let metadataModel = widgetNowPlayingDisplayModel(
            visualState: fields.visualState,
            streamMetadata: fields.streamMetadata,
            languageName: currentStream.language
        )
        return WidgetProviderPresentationSlices(
            currentLanguageCode: fields.currentLanguage,
            currentStation: stationLabel(for: fields.currentLanguage),
            statusPresentation: statusPresentation,
            controlPresentation: controlPresentation,
            statusMessage: statusMessage,
            widgetNowPlayingDisplayModel: metadataModel
        )
    }
}
