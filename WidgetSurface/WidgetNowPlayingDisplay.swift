//
//  WidgetNowPlayingDisplay.swift
//  WidgetSurface
//
//  Created by Jari Lammi on 14.7.2026.
//
//  Metadata/emphasis presentation axis for WidgetKit and ActivityKit surfaces.
//  Presentation-only — no security logic (see Core/).
//
//  - SeeAlso: ``PlayerVisualState``, docs/Widget-Presentation-Dataflow.md,
//    docs/Widget-Functionality-Roadmap.md, CODING_AGENT.md.
//

import Foundation

/// Emphasis level for program title and speaker line opacity in widget/LA metadata regions.
public enum WidgetMetadataEmphasis: Equatable, Sendable {
    case active
    case subdued
    case placeholder

    public var opacity: Double {
        switch self {
        case .active: 1.0
        case .subdued: 0.55
        case .placeholder: 0.45
        }
    }
}

/// Narrow value type for program title, speaker line, visibility, and emphasis.
///
/// Produced exclusively by ``widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)``.
/// Consumers must not re-derive title/speaker rules from ``PlayerVisualState`` in view bodies.
///
/// - SeeAlso: ``widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)``,
///   docs/Widget-Presentation-Dataflow.md.
public struct WidgetNowPlayingDisplayModel: Equatable, Sendable {
    public let programTitle: String
    public let speakerLine: String
    public let speakerVisible: Bool
    public let emphasis: WidgetMetadataEmphasis

    public init(
        programTitle: String,
        speakerLine: String,
        speakerVisible: Bool,
        emphasis: WidgetMetadataEmphasis
    ) {
        self.programTitle = programTitle
        self.speakerLine = speakerLine
        self.speakerVisible = speakerVisible
        self.emphasis = emphasis
    }
}

/// Returns the localized "X · Live Stream" fallback when no ICY program title is present.
///
/// Uses catalog key `live_activity_program_fallback` from the app/widget `Localizable`
/// table (all 21 languages). The key is marked `extractionState: manual` in
/// `Localizable.xcstrings` because this call site lives in the `WidgetSurface` framework;
/// Xcode auto-extraction only scans the catalog-owning targets and would otherwise mark
/// the entry stale despite live usage.
///
/// - Parameter languageName: Localized stream language label inserted into the format.
/// - Returns: Formatted fallback such as "English · Live Stream".
/// - SeeAlso: ``widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)``,
///   `Localizable.xcstrings` (`live_activity_program_fallback`), CODING_AGENT.md.
public func widgetLiveStreamFallback(languageName: String) -> String {
    // SAFETY: `unsafe String(format:)` is required for localized format strings under strict memory safety.
    // Catalog format string with `%@` + trusted language name (same pattern as other
    // placeholder-bearing Localizable keys under SWIFT_STRICT_MEMORY_SAFETY = YES).
    unsafe String(
        format: String(localized: "live_activity_program_fallback", defaultValue: "%@ · Live Stream", table: "Localizable"),
        languageName
    )
}

/// Returns the speaker line when metadata carries a non-empty speaker value.
public func widgetProgramSpeakerLine(metadata: StreamProgramMetadata?) -> String? {
    guard let speaker = metadata?.speaker, !speaker.isEmpty else { return nil }
    return speaker
}

/// Single source of truth for the metadata/emphasis axis over ``PlayerVisualState`` and ICY metadata.
///
/// Call once per snapshot in WidgetKit Providers and once at the top of Live Activity view builders.
/// The returned model always supplies stable title and speaker slots (speaker uses U+00A0 when absent).
///
/// - Parameters:
///   - visualState: Authoritative visual state from the persisted snapshot.
///   - streamMetadata: Optional ICY metadata (program title + speaker).
///   - languageName: Localized stream display name for the live-stream fallback.
/// - Returns: Narrow display model for metadata regions.
/// - SeeAlso: ``WidgetNowPlayingDisplayModel``, docs/Widget-Presentation-Dataflow.md.
public func widgetNowPlayingDisplayModel(
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

    @unknown default:
        programTitle = noTrack
        emphasis = .placeholder
    }

    let speakerVisible = speaker != nil && (
        state.isActivelyPlaying || state == .userPaused || state == .prePlay || state == .cleared
    )

    return WidgetNowPlayingDisplayModel(
        programTitle: programTitle,
        speakerLine: speaker ?? "\u{00A0}",
        speakerVisible: speakerVisible,
        emphasis: emphasis
    )
}
