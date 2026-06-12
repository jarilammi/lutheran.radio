//
//  WidgetDisplayModels.swift
//  LutheranRadioWidget
//
//  Created by Jari Lammi on 12.6.2026.
//

import Foundation

// MARK: - Shared Widget / Live Activity Display Models
//
// WidgetMetadataEmphasis + WidgetNowPlayingDisplayModel + the resolver function
// provide a single source of truth for program title, speaker line, visibility,
// and emphasis (.active / .subdued / .placeholder).
//
// Used by medium + large home-screen widgets and by Live Activity (lock screen
// and Dynamic Island expanded region). Widget- and LA-specific layout details
// (fonts, spacing, alignment) stay in the respective view files.
//
// All user-visible strings use String(localized:) with the Localizable table.

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

internal struct WidgetNowPlayingDisplayModel {
    let programTitle: String
    let speakerLine: String
    let speakerVisible: Bool
    let emphasis: WidgetMetadataEmphasis
}

/// Returns the localized "X · Live Stream" fallback used when no ICY programTitle.
internal func widgetLiveStreamFallback(languageName: String) -> String {
    unsafe String(
        format: String(localized: "live_activity_program_fallback", defaultValue: "%@ · Live Stream"),
        languageName
    )
}

/// Returns speaker line if present and non-empty in metadata.
internal func widgetProgramSpeakerLine(metadata: StreamProgramMetadata?) -> String? {
    guard let speaker = metadata?.speaker, !speaker.isEmpty else { return nil }
    return speaker
}

/// Core resolver used by both home widgets (via SimpleEntry adapter) and Live Activity.
/// Produces fixed title/speaker values + emphasis for calm layout (no conditional row insertion).
internal func widgetNowPlayingDisplayModel(
    visualState: PlayerVisualState,
    streamMetadata: StreamProgramMetadata?,
    languageName: String
) -> WidgetNowPlayingDisplayModel {
    let metadata = streamMetadata
    let state = visualState
    let liveFallback = widgetLiveStreamFallback(languageName: languageName)
    let noTrack = String(localized: "no_track_info", defaultValue: "No track information")
    let speaker = widgetProgramSpeakerLine(metadata: metadata)

    let programTitle: String
    let emphasis: WidgetMetadataEmphasis

    switch state {
    case .playing:
        programTitle = metadata?.programTitle.flatMap { $0.isEmpty ? nil : $0 } ?? liveFallback
        emphasis = .active
    case .prePlay:
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

    let speakerVisible = speaker != nil && (state.isActivelyPlaying || state == .userPaused || state == .prePlay)

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
    case "en": return String(localized: "language_english")
    case "de": return String(localized: "language_german")
    case "fi": return String(localized: "language_finnish")
    case "sv": return String(localized: "language_swedish")
    case "et": return String(localized: "language_estonian")
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
