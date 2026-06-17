//
//  LutheranRadioLiveActivityAttributes.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 13.6.2025.
//

// SHARED: Cross-target source (main app + LutheranRadioWidgetExtension)
//
// Single physical file on disk, compiled into both targets via Xcode
// File System Synchronized Group + membershipExceptions (see project.pbxproj).
//
// Purpose:
// `ActivityAttributes` + `ContentState` for `LutheranRadioLiveActivity`.
// Carries the authoritative `PlayerVisualState` and `StreamProgramMetadata`
// from the app into the Live Activity / Dynamic Island.
//
// Key invariants:
// - `ContentState` is the Live Activity projection of `PersistedWidgetState`.
// - Relies on the same `PlayerVisualState` and `StreamProgramMetadata` used by
//   widgets (no separate model).
// - Must remain `Codable + Sendable` for ActivityKit.
// - This file contains *no* security logic. Security decisions live only in
//   `Core/` (see CODING_AGENT.md "Core Framework Surface Area").
//
// - SeeAlso: `SharedPlayerManager` (source of the snapshot), `PlayerVisualState`,
//   `StreamProgramMetadata`, `LutheranRadioWidgetLiveActivity.swift`,
//   CODING_AGENT.md (Single Source of Truth Principles + "Cross-target shared
//   source files (non-Core)"), README.md.

import ActivityKit
import Foundation

struct LutheranRadioLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {   // ← added Sendable for Swift 6
        // MARK: - Single Source of Truth (authoritative)
        let visualState: PlayerVisualState
        /// Current program / sermon metadata from the active ICY stream.
        let streamMetadata: StreamProgramMetadata?
    }
    
    let appName: String
    let startTime: Date
}
