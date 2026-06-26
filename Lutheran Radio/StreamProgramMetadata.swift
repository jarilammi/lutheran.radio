//
//  StreamProgramMetadata.swift
//  Lutheran Radio
//
//  Parsed ICY/Shoutcast program metadata for widgets and Live Activities.
//

// SHARED: Cross-target source (main app + LutheranRadioWidgetExtension)
//
// Single physical file on disk, compiled into both targets via Xcode
// File System Synchronized Group + membershipExceptions (see project.pbxproj).
//
// Purpose:
// Lightweight value type + parser for ICY `StreamTitle` metadata. Used by
// widgets, Live Activities, *and* the system Now Playing surface (MPNowPlayingInfoCenter).
//
// Key invariants:
// - Pure value type: `Codable`, `Hashable`, `Sendable`, `Equatable`.
// - Owned by `SharedPlayerManager`; stored inside `PersistedWidgetState`.
// - No PII, no history. Anonymous only.
// - Parsing is best-effort for common radio formats ("Title", "Speaker - Title",
//   "Title by Speaker").
// - `nowPlayingDisplayStrings(...)` is the SSOT for title/artist used by Lock Screen / CC.
// - This file contains *no* security logic. Security decisions live only in
//   `Core/` (see CODING_AGENT.md "Core Framework Surface Area").
//
// - SeeAlso: `SharedPlayerManager`, `PlayerVisualState`, `PersistedWidgetState`
//   (contains this), `WidgetDisplayModels.swift` (widget/LA counterpart),
//   SharedPlayerManager+NowPlaying.swift,
//   CODING_AGENT.md (Single Source of Truth Principles + "Cross-target shared source files (non-Core)"), README.md.

import Foundation

/// Lightweight, anonymous program metadata from the active audio stream.
///
/// Owned by `SharedPlayerManager` and persisted in `PersistedWidgetState` for
/// cross-process widget / Live Activity display. Also supplies `nowPlayingDisplayStrings(...)`
/// for the system Now Playing surface. No history or PII.
struct StreamProgramMetadata: Codable, Hashable, Sendable, Equatable {
    /// Primary program / sermon / talk title.
    let programTitle: String?
    /// Speaker or presenter when parsed from the stream title.
    let speaker: String?

    var hasDisplayableContent: Bool {
        let titlePresent = programTitle.map { !$0.isEmpty } ?? false
        let speakerPresent = speaker.map { !$0.isEmpty } ?? false
        return titlePresent || speakerPresent
    }

    /// Parses a raw ICY `StreamTitle` string into structured metadata.
    ///
    /// Common radio formats:
    /// - `"Sermon Title"`
    /// - `"Speaker Name - Sermon Title"`
    /// - `"Sermon Title by Speaker Name"`
    static func from(rawICYMetadata: String?) -> StreamProgramMetadata? {
        guard let raw = rawICYMetadata?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        let dashParts = raw
            .components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if dashParts.count >= 2 {
            return StreamProgramMetadata(programTitle: dashParts[1], speaker: dashParts[0])
        }

        if let byRange = raw.range(of: " by ", options: .caseInsensitive) {
            let title = String(raw[..<byRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let speaker = String(raw[byRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return StreamProgramMetadata(
                programTitle: title,
                speaker: speaker.isEmpty ? nil : speaker
            )
        }

        return StreamProgramMetadata(programTitle: raw, speaker: nil)
    }
}

// MARK: - Now Playing surface formatting

// Supporting value type for system media surface strings.
// This is intentionally narrower than `WidgetNowPlayingDisplayModel`
// (which carries emphasis + speaker visibility rules for WidgetKit/ActivityKit).
internal struct NowPlayingDisplayStrings: Sendable, Equatable {
    let title: String
    let artist: String
}

extension StreamProgramMetadata {
    /// Returns the canonical title/artist pair for `MPNowPlayingInfoCenter`.
    ///
    /// Single source of truth for the program / speaker / fallback formatting
    /// used on the system Now Playing surface (Lock Screen media card, Control Center,
    /// hardware remotes, Siri). Ensures parity of program titles with Live Activities
    /// and widgets when ICY `StreamTitle` arrives.
    ///
    /// Rules (identical to prior inline logic in `updateNowPlayingInfo`):
    /// - Prefer parsed `programTitle` (with optional `speaker` for artist line).
    /// - Fall back to raw unparsed ICY if no parsed program title.
    /// - Final fallback: station name + language-augmented artist.
    ///
    /// - Parameters:
    ///   - parsed: Parsed metadata from `from(rawICYMetadata:)` (preferred source).
    ///   - raw: Raw `nowPlayingStreamMetadata` string (used only when parsed has no title).
    ///   - stationName: Localized station title (from "lutheran_radio_title").
    ///   - languageName: Display name of the current stream/language.
    /// - Returns: Resolved strings for `MPMediaItemPropertyTitle` and `MPMediaItemPropertyArtist`.
    /// - Precondition: `stationName` and `languageName` must be localized via `String(localized:)`.
    /// - SeeAlso: ``updateNowPlayingInfo()`` (SharedPlayerManager+NowPlaying.swift),
    ///   ``didUpdateStreamMetadata(_:)``,
    ///   `widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)` (different rules + emphasis),
    ///   `clearSoftPauseMetadataStashForLanguageChange()`,
    ///   CODING_AGENT.md (Single Source of Truth Principles + cross-target shared files).
    ///
    /// AGENT NOTE: This is now the authoritative location for Now Playing title/artist
    /// construction. Changes to how program titles or speaker attribution appear on
    /// the system media surface must be implemented here (and the call site updated
    /// if the signature changes). Do not duplicate the if/else ladder elsewhere.
    static func nowPlayingDisplayStrings(
        fromParsed parsed: StreamProgramMetadata?,
        rawFallback raw: String?,
        stationName: String,
        languageName: String
    ) -> NowPlayingDisplayStrings {
        if let program = parsed?.programTitle, !program.isEmpty {
            let artist: String
            if let speaker = parsed?.speaker, !speaker.isEmpty {
                artist = "\(speaker) • \(stationName)"
            } else {
                artist = "\(languageName) • \(stationName)"
            }
            return NowPlayingDisplayStrings(title: program, artist: artist)
        } else if let raw = raw, !raw.isEmpty {
            return NowPlayingDisplayStrings(
                title: raw,
                artist: "\(languageName) • \(stationName)"
            )
        } else {
            return NowPlayingDisplayStrings(
                title: stationName,
                artist: "\(languageName) • \(stationName)"
            )
        }
    }
}
