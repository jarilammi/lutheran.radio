//
//  StreamProgramMetadata.swift
//  WidgetSurface
//
//  Created by Jari Lammi on 6.6.2026.
//
//  Parsed ICY/Shoutcast program metadata for widgets and Live Activities.
//

// WidgetSurface framework — presentation-only (no security logic).
//
// Purpose:
// Lightweight value type + parser for ICY `StreamTitle` metadata. Used by
// widgets, Live Activities, *and* the system Now Playing surface (MPNowPlayingInfoCenter).
//
// Key invariants:
// - Pure value type: `Codable`, `Hashable`, `Sendable`, `Equatable`.
// - Owned by `SharedPlayerManager`; stored inside `PersistedWidgetState`.
// - No PII, no history. Anonymous only.
// - Parsing is best-effort for common radio formats:
//     • title only
//     • "Speaker - Title" (hyphen-minus, en dash U+2013, or em dash U+2014)
//     • "Title by Speaker"
//   Multi-segment dash titles keep segments after the first as the program title
//   (joined with ASCII " - ").
// - `nowPlayingDisplayStrings(...)` is the SSOT for title/artist used by Lock Screen / CC.
// - This file contains *no* security logic. Security decisions live only in
//   `Core/` (see CODING_AGENT.md "Core Framework Surface Area").
//
// Why typographic dashes matter:
// Shoutcast/ICY encoders and station automation often emit en or em dashes between
// speaker and program name. Treating only ASCII hyphen-minus as a separator silently
// demotes those titles to “title only,” dropping speaker attribution on every surface
// that reads this type (widgets, Live Activities, system Now Playing).
//
// - SeeAlso: `SharedPlayerManager`, `PlayerVisualState`, `PersistedWidgetState`
//   (contains this), ``widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)``,
//   SharedPlayerManager+NowPlaying.swift,
//   docs/Widget-Presentation-Dataflow.md (formatter parity),
//   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
//   CODING_AGENT.md (Single Source of Truth Principles + cross-target widget sources),
//   README.md.
//
// AGENT NOTE: `from(rawICYMetadata:)` and `nowPlayingDisplayStrings(...)` are the
// authoritative parsers/formatters for program metadata presentation. Do not re-implement
// dash / "by" splitting or Now Playing title/artist ladders elsewhere.

import Foundation

/// Lightweight, anonymous program metadata from the active audio stream.
///
/// Owned by `SharedPlayerManager` and persisted in `PersistedWidgetState` for
/// cross-process widget / Live Activity display. Also supplies ``nowPlayingDisplayStrings(fromParsed:rawFallback:stationName:languageName:)``
/// for the system Now Playing surface. No history or PII is retained.
///
/// - Important: Presentation-only. Never place security decisions, DNS lookups, or
///   certificate handling in this type or its extensions.
/// - SeeAlso: ``from(rawICYMetadata:)``, ``nowPlayingDisplayStrings(fromParsed:rawFallback:stationName:languageName:)``,
///   ``widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)``,
///   `PersistedWidgetState`, docs/Widget-Presentation-Dataflow.md.
public struct StreamProgramMetadata: Codable, Hashable, Sendable, Equatable {
    /// Primary program, sermon, or talk title when the stream supplies one.
    public let programTitle: String?
    /// Speaker or presenter when parsed from a recognized ICY `StreamTitle` pattern.
    public let speaker: String?

    /// Creates structured metadata from already-separated title and speaker fields.
    ///
    /// Prefer ``from(rawICYMetadata:)`` when the input is a raw ICY `StreamTitle` string.
    /// Use this initializer for tests, persistence round-trips, and call sites that already
    /// hold discrete fields.
    ///
    /// - Parameters:
    ///   - programTitle: Optional primary title; empty strings are stored as-is and treated
    ///     as non-displayable by ``hasDisplayableContent`` and the Now Playing formatter.
    ///   - speaker: Optional speaker or presenter name.
    /// - SeeAlso: ``from(rawICYMetadata:)``, ``hasDisplayableContent``.
    public init(programTitle: String?, speaker: String?) {
        self.programTitle = programTitle
        self.speaker = speaker
    }

    /// Whether either field carries a non-empty string suitable for UI presentation.
    ///
    /// Used by persistence and surface-update paths to decide whether metadata is worth
    /// storing or pushing. Empty strings count as absent; `nil` and `""` are both non-displayable.
    ///
    /// - Returns: `true` when `programTitle` or `speaker` is non-`nil` and non-empty.
    /// - SeeAlso: ``from(rawICYMetadata:)``, `PersistedWidgetState`.
    public var hasDisplayableContent: Bool {
        let titlePresent = programTitle.map { !$0.isEmpty } ?? false
        let speakerPresent = speaker.map { !$0.isEmpty } ?? false
        return titlePresent || speakerPresent
    }

    /// Parses a raw ICY `StreamTitle` string into structured program and speaker fields.
    ///
    /// Best-effort recognition of common radio automation formats. Unrecognized shapes
    /// become title-only metadata so callers still receive a non-`nil` value for a non-empty
    /// stream title.
    ///
    /// Recognized patterns (after leading/trailing whitespace trim):
    /// - `"Sermon Title"` → title only
    /// - `"Speaker Name - Sermon Title"` → speaker + title (ASCII hyphen-minus U+002D)
    /// - `"Speaker Name – Sermon Title"` → speaker + title (en dash U+2013)
    /// - `"Speaker Name — Sermon Title"` → speaker + title (em dash U+2014)
    /// - `"Speaker - Part A - Part B"` → speaker + title `"Part A - Part B"` (segments after
    ///   the first are re-joined with ASCII `" - "`)
    /// - `"Sermon Title by Speaker Name"` → title + speaker (case-insensitive `" by "`)
    ///
    /// Dash recognition normalizes spaced en/em dashes to spaced hyphen-minus before split
    /// so a single code path owns separator policy. Only the spaced forms (`" - "`, `" – "`,
    /// `" — "`) are treated as separators; unspaced hyphens inside words are left intact.
    ///
    /// - Parameter rawICYMetadata: Raw `StreamTitle` payload, or `nil` when the stream has
    ///   not delivered metadata.
    /// - Returns: Parsed metadata, or `nil` when the input is `nil`, empty, or whitespace-only.
    /// - Note: The `" by "` branch runs only when no multi-segment dash split succeeds, so
    ///   titles that contain both a dash separator and the word “by” prefer the dash form.
    /// - SeeAlso: ``hasDisplayableContent``,
    ///   ``nowPlayingDisplayStrings(fromParsed:rawFallback:stationName:languageName:)``,
    ///   ``widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    ///
    /// AGENT NOTE: Single source of truth for ICY title → structured fields. Widget, Live
    /// Activity, and Now Playing surfaces must not re-parse `StreamTitle` with divergent rules.
    public static func from(rawICYMetadata: String?) -> StreamProgramMetadata? {
        guard let raw = rawICYMetadata?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        // Normalize spaced typographic dashes to ASCII so separator policy lives in one place.
        // En dash (U+2013) and em dash (U+2014) are common in station automation StreamTitle values.
        let normalizedDashes = raw
            .replacingOccurrences(of: " \u{2013} ", with: " - ")
            .replacingOccurrences(of: " \u{2014} ", with: " - ")

        let dashParts = normalizedDashes
            .components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if dashParts.count >= 2 {
            let speaker = dashParts[0]
            // Preserve multi-segment program names ("Series - Episode - Theme") after the speaker.
            let title = dashParts.dropFirst().joined(separator: " - ")
            return StreamProgramMetadata(programTitle: title, speaker: speaker)
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

/// Canonical title and artist strings for `MPNowPlayingInfoCenter`.
///
/// Intentionally narrower than ``WidgetNowPlayingDisplayModel``, which also carries
/// emphasis and speaker-visibility policy for WidgetKit and ActivityKit. This type holds
/// only the two strings written to the system media surface.
///
/// - SeeAlso: ``StreamProgramMetadata/nowPlayingDisplayStrings(fromParsed:rawFallback:stationName:languageName:)``,
///   SharedPlayerManager+NowPlaying.swift, docs/Live-Activity-Stacking-and-Media-Surfaces.md.
public struct NowPlayingDisplayStrings: Sendable, Equatable {
    /// Value for `MPMediaItemPropertyTitle` (program title, raw ICY, or station fallback).
    public let title: String
    /// Value for `MPMediaItemPropertyArtist` (speaker or language, always with station name).
    public let artist: String

    /// Creates a resolved Now Playing title/artist pair.
    ///
    /// - Parameters:
    ///   - title: Media item title string.
    ///   - artist: Media item artist string.
    /// - SeeAlso: ``StreamProgramMetadata/nowPlayingDisplayStrings(fromParsed:rawFallback:stationName:languageName:)``.
    public init(title: String, artist: String) {
        self.title = title
        self.artist = artist
    }
}

public extension StreamProgramMetadata {
    /// Returns the canonical title/artist pair for `MPNowPlayingInfoCenter`.
    ///
    /// Single source of truth for the program / speaker / fallback formatting used on the
    /// system Now Playing surface (Lock Screen media card, Control Center, hardware remotes,
    /// Siri). Ensures program-title parity with Live Activities and widgets when ICY
    /// `StreamTitle` arrives, while applying Now Playing–specific artist-line composition.
    ///
    /// Resolution order (identical to the prior inline logic in `updateNowPlayingInfo`):
    /// 1. Prefer parsed `programTitle` when non-empty; artist uses speaker when present,
    ///    otherwise language + station.
    /// 2. Fall back to the raw unparsed ICY string when no usable parsed title exists.
    /// 3. Final fallback: station name as title and language + station as artist.
    ///
    /// - Parameters:
    ///   - parsed: Parsed metadata from ``from(rawICYMetadata:)`` (preferred source).
    ///   - raw: Raw `nowPlayingStreamMetadata` string (used only when parsed has no title).
    ///   - stationName: Localized station title (from `"lutheran_radio_title"`).
    ///   - languageName: Display name of the current stream/language.
    /// - Returns: Resolved strings for `MPMediaItemPropertyTitle` and `MPMediaItemPropertyArtist`.
    /// - Precondition: `stationName` and `languageName` must already be localized via
    ///   `String(localized:)` / the stream catalog display helpers.
    /// - SeeAlso: ``updateNowPlayingInfo()`` (SharedPlayerManager+NowPlaying.swift),
    ///   ``didUpdateStreamMetadata(_:)``,
    ///   ``widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)`` (different
    ///   rules and emphasis; do not substitute one for the other),
    ///   `clearSoftPauseMetadataStashForLanguageChange()`,
    ///   docs/Widget-Presentation-Dataflow.md,
    ///   CODING_AGENT.md (Single Source of Truth Principles + cross-target widget sources).
    ///
    /// AGENT NOTE: Authoritative location for Now Playing title/artist construction. Changes
    /// to how program titles or speaker attribution appear on the system media surface must
    /// be implemented here (and call sites updated only if the signature changes). Do not
    /// duplicate this resolution ladder elsewhere.
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
