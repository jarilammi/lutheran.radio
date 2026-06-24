//
//  WidgetDisplayModels.swift
//  LutheranRadioWidget
//
//  Created by Jari Lammi on 12.6.2026.
//

import Foundation

// MARK: - Shared Widget / Live Activity Display Models (Metadata / Emphasis Axis)
//
// WidgetMetadataEmphasis + WidgetNowPlayingDisplayModel + `widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)`
// are the Single Source of Truth for the program-title / speaker-line / emphasis axis.
//
// This is the metadata/emphasis counterpart to the two narrow presentation surfaces on PlayerVisualState:
// - `PlayerStatusPresentation` + `makeStatusPresentation()` (status indicator axis)
// - `PlayerControlPresentation` + `makeControlPresentation()` (play/pause control axis)
//
// ## Snapshot-Driven Derivation Pattern
//
// As of this change, `WidgetNowPlayingDisplayModel` (or its equivalent fields) is **pre-derived** into the widget snapshot:
//
// - `SimpleEntry.widgetNowPlayingDisplayModel` is populated once inside the `Provider`
//   (`placeholder(in:)`, `snapshot(for:in:)`, `timeline(for:in:)` via `createEntry`).
// - `MediumWidgetView` and `LargeWidgetView` (and `WidgetMetadataRegion`) consume the
//   pre-derived value directly; they no longer call the resolver inside their `body`.
// - For Live Activities, `LockScreenLiveActivityView.body` and the outer `dynamicIsland`
//   closure compute `widgetNowPlayingDisplayModel(...)` once near the top, then close
//   over the narrow model for `.center`, `.compactLeading`, etc.
//
// Why pre-derive into the snapshot / top-of-view:
// - WidgetKit compares `TimelineEntry` (and its fields) to decide invalidation and
//   body re-evaluation. Carrying a narrow derived value means only mutations that
//   actually affect title/speaker/emphasis cause downstream view bodies to run.
// - ActivityKit region builders run independently; hoisting the call to the outer
//   closure bounds CPU / allocation work to once per push instead of N regions.
// - Leaf views and regions receive the smallest possible input set (title, speakerLine,
//   speakerVisible, emphasis) — exactly what `WidgetMetadataRegion` and the LA
//   metadata blocks need. This is the same principle already applied for
//   `statusPresentation` and `controlPresentation` on `SimpleEntry`.
//
// The resolver remains the single place that knows the `switch` on `PlayerVisualState` +
// metadata fallback rules (live stream title, "No track information", speaker visibility).
//
// ## Terminology (exact project names)
// - `widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)` — the core resolver.
// - `WidgetNowPlayingDisplayModel` — the narrow value type handed to views.
// - `SimpleEntry` — the `TimelineEntry` snapshot for home-screen widgets.
// - `WidgetMetadataRegion` — the fixed-height title + speaker slots used by medium/large.
// - `Provider` — the `AppIntentTimelineProvider`.
// - `DynamicIsland` regions (leading/trailing/center/bottom + compact*) in Live Activity.
//
// - SeeAlso: `PlayerVisualState` (source of `visualState`; hosts the status/control mappers),
//   ``PlayerVisualState/makeStatusPresentation()``, ``PlayerVisualState/makeControlPresentation()``,
//   `LutheranRadioWidget.swift` (SimpleEntry + Provider + Medium/Large views + WidgetMetadataRegion),
//   `LutheranRadioWidgetLiveActivity.swift` (LockScreenLiveActivityView + DynamicIsland usage),
//   `LutheranRadioLiveActivityAttributes.ContentState` (the LA snapshot carrying visualState + metadata),
//   CODING_AGENT.md (Documentation & Comment Standards, Single Source of Truth Principles,
//   narrow inputs for WidgetKit/ActivityKit, "Cross-target shared source files (non-Core)"),
//   <doc:Architecture>, README.md (Single Sources of Truth table),
//   docs/widget-liveactivity-presentation-dataflow-analysis.md.
//
// All user-visible strings use `String(localized: "key", table: "Localizable", ...)` with explicit table.

internal enum WidgetMetadataEmphasis {
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
internal struct WidgetNowPlayingDisplayModel {
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
