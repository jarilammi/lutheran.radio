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
// Carries the authoritative `PlayerVisualState`, stream language code, and
// `StreamProgramMetadata` from the app into the Live Activity / Dynamic Island.
//
// Key invariants:
// - `ContentState` is the Live Activity projection of player presentation state.
// - Relies on the same `PlayerVisualState` and `StreamProgramMetadata` used by
//   widgets (no separate model).
// - `currentLanguage` is the stream language code for Lock Screen / Dynamic Island
//   language chrome (flag, name, alt-stream “current”). It rides every
//   ActivityKit push so extension hosts never re-derive language via privacy-gated
//   ``preferredWidgetLanguage()`` under memory-only session + no home widgets.
// - Must remain `Codable + Sendable` for ActivityKit.
// - This file contains *no* security logic. Security decisions live only in
//   `Core/` (see CODING_AGENT.md "Core Framework Surface Area").
//
// Presentation contract:
// The broad `visualState` inside ContentState is the policy snapshot. Live Activity
// views derive narrow presentations at consumption time:
// - `visualState.makeStatusPresentation()` → status text/colors
// - `visualState.makeControlPresentation()` → play/pause glyph + tint
// - `currentLanguage` → flag / language name / alt-stream exclusion (hoisted once)
// (computed once per view or outer DynamicIsland closure, then passed inward).
// See LutheranRadioWidgetLiveActivity.swift and PlayerVisualState.swift.
//
// Toggle planning contract:
// `ContentState.visualState` is the preferred input for lock-screen play/pause
// planning (matches the glyph). Intent paths publish optimistic content via
// ``ContentState/replacingVisualState(_:)`` so a rapid second tap does not re-plan
// from stale pre-tap content. Language is preserved on control flips.
// When ActivityKit does not expose activities in the intent host, a durable App
// Group mirror of the visual (and language) is used — see
// ``WidgetIntentCoordinators/resolveLiveActivityToggleVisualState`` and
// ``SharedPlayerManager/persistLiveActivityToggleVisualStateMirror``.
//
// - SeeAlso: `SharedPlayerManager` (source of the snapshot), `PlayerVisualState`
//   (makeStatusPresentation, makeControlPresentation, PlayerStatusPresentation,
//   PlayerControlPresentation), `StreamProgramMetadata`,
//   `LutheranRadioWidgetLiveActivity.swift`, WidgetDisplayModels.swift,
//   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
//   docs/Widget-Functionality-Roadmap.md (Live Activity language chrome SSOT),
//   CODING_AGENT.md (Single Source of Truth Principles + "Cross-target shared
//   source files (non-Core)"), README.md.

import ActivityKit
import Foundation

public struct LutheranRadioLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        // MARK: - Single Source of Truth (authoritative)
        public let visualState: PlayerVisualState
        /// Current program / sermon metadata from the active ICY stream.
        public let streamMetadata: StreamProgramMetadata?
        /// Active stream language code for Lock Screen / Dynamic Island language chrome.
        ///
        /// Written by the main app on every Live Activity start/update from the stream
        /// attach language (``DirectStreamingPlayer/selectedStream``), not from privacy-gated
        /// home-widget language resolution. Views must render flag/name/alt-current only from
        /// this field (hoisted once), never from ``preferredWidgetLanguage()`` at render time.
        ///
        /// - Important: Missing decode key (older ActivityKit payloads) defaults to `"en"` so
        ///   decoding does not fail; the next main-app push replaces it with the real code.
        public let currentLanguage: String

        /// - Parameters:
        ///   - visualState: Control and status policy snapshot.
        ///   - streamMetadata: Optional ICY program title/speaker.
        ///   - currentLanguage: Stream language code for language chrome (default `"en"` only
        ///     for call sites that cannot yet supply a code; production push paths always pass
        ///     the engine stream language).
        public init(
            visualState: PlayerVisualState,
            streamMetadata: StreamProgramMetadata?,
            currentLanguage: String = "en"
        ) {
            self.visualState = visualState
            self.streamMetadata = streamMetadata
            self.currentLanguage = currentLanguage
        }

        /// Builds content with a new control visual while keeping program metadata and
        /// stream language unchanged.
        ///
        /// Lock-screen play/pause intents publish this optimistically so ActivityKit
        /// `ContentState.visualState` (the preferred resolve input for the next tap) and
        /// the control glyph advance before the main process finishes soft silence or soft
        /// resume. Metadata and language policy stay authoritative: titles, speakers, and
        /// language chrome are never invented or cleared on toggle — only the play/pause
        /// presentation flips.
        ///
        /// - Parameter visualState: Target control visual (typically `.userPaused` or `.playing`).
        /// - Returns: A new ``ContentState`` sharing this instance's ``streamMetadata`` and
        ///   ``currentLanguage``.
        /// - SeeAlso: ``WidgetIntentCoordinators/resolveLiveActivityToggleVisualState(liveActivityContent:durableMirror:actorVisualState:sessionSnapshot:)``,
        ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
        ///   docs/Widget-Presentation-Dataflow.md.
        public func replacingVisualState(_ visualState: PlayerVisualState) -> ContentState {
            ContentState(
                visualState: visualState,
                streamMetadata: streamMetadata,
                currentLanguage: currentLanguage
            )
        }

        // MARK: - Codable (explicit language default for older payloads)

        private enum CodingKeys: String, CodingKey {
            case visualState
            case streamMetadata
            case currentLanguage
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            visualState = try container.decode(PlayerVisualState.self, forKey: .visualState)
            streamMetadata = try container.decodeIfPresent(StreamProgramMetadata.self, forKey: .streamMetadata)
            // Older activities encoded before language chrome SSOT omit the key.
            // Defaulting to "en" keeps decode stable; the next main-app push corrects it.
            currentLanguage = try container.decodeIfPresent(String.self, forKey: .currentLanguage) ?? "en"
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(visualState, forKey: .visualState)
            try container.encodeIfPresent(streamMetadata, forKey: .streamMetadata)
            try container.encode(currentLanguage, forKey: .currentLanguage)
        }
    }

    public let appName: String
    public let startTime: Date

    public init(appName: String, startTime: Date) {
        self.appName = appName
        self.startTime = startTime
    }
}
