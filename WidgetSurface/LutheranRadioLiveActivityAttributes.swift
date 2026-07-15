//
//  LutheranRadioLiveActivityAttributes.swift
//  WidgetSurface
//
//  Created by Jari Lammi on 13.6.2025.
//

// WidgetSurface framework — ActivityKit attribute types.
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
// Presentation contract:
// The broad `visualState` inside ContentState is the policy snapshot. Live Activity
// views derive narrow presentations at consumption time:
// - `visualState.makeStatusPresentation()` → status text/colors
// - `visualState.makeControlPresentation()` → play/pause glyph + tint
// (computed once per view or outer DynamicIsland closure, then passed inward).
// See LutheranRadioWidgetLiveActivity.swift and PlayerVisualState.swift.
//
// Toggle planning contract:
// `ContentState.visualState` is the preferred input for lock-screen play/pause
// planning (matches the glyph). When ActivityKit does not expose activities in the
// intent host, a durable App Group mirror of the same visual is used — see
// ``WidgetIntentCoordinators/resolveLiveActivityToggleVisualState`` and
// ``SharedPlayerManager/persistLiveActivityToggleVisualStateMirror``.
//
// - SeeAlso: `SharedPlayerManager` (source of the snapshot), `PlayerVisualState`
//   (makeStatusPresentation, makeControlPresentation, PlayerStatusPresentation,
//   PlayerControlPresentation), `StreamProgramMetadata`,
//   `LutheranRadioWidgetLiveActivity.swift`, WidgetDisplayModels.swift,
//   CODING_AGENT.md (Single Source of Truth Principles + "Cross-target shared
//   source files (non-Core)"), README.md.

import ActivityKit
import Foundation

public struct LutheranRadioLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {   // ← added Sendable for Swift 6
        // MARK: - Single Source of Truth (authoritative)
        public let visualState: PlayerVisualState
        /// Current program / sermon metadata from the active ICY stream.
        public let streamMetadata: StreamProgramMetadata?

        public init(visualState: PlayerVisualState, streamMetadata: StreamProgramMetadata?) {
            self.visualState = visualState
            self.streamMetadata = streamMetadata
        }
    }

    public let appName: String
    public let startTime: Date

    public init(appName: String, startTime: Date) {
        self.appName = appName
        self.startTime = startTime
    }
}
