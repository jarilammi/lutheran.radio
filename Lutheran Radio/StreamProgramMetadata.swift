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
// widgets and Live Activities to show program/sermon title and speaker.
//
// Key invariants:
// - Pure value type: `Codable`, `Hashable`, `Sendable`, `Equatable`.
// - Owned by `SharedPlayerManager`; stored inside `PersistedWidgetState`.
// - No PII, no history. Anonymous only.
// - Parsing is best-effort for common radio formats ("Title", "Speaker - Title",
//   "Title by Speaker").
// - This file contains *no* security logic. Security decisions live only in
//   `Core/` (see CODING_AGENT.md "Core Framework Surface Area").
//
// - SeeAlso: `SharedPlayerManager`, `PlayerVisualState`, `PersistedWidgetState`
//   (contains this), CODING_AGENT.md (Single Source of Truth Principles +
//   "Cross-target shared source files (non-Core)"), README.md.

import Foundation

/// Lightweight, anonymous program metadata from the active audio stream.
///
/// Owned by `SharedPlayerManager` and persisted in `PersistedWidgetState` for
/// cross-process widget / Live Activity display. No history or PII.
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