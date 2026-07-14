//
//  WidgetIntentCoordinators.swift
//  WidgetSurface
//
//  Created by Jari Lammi on 14.7.2026.
//
//  Pure intent planning SSOT for home widgets, Control Center, and Live Activity toggles.
//  Extension `perform()` bodies delegate here for action/target mapping; cross-target
//  execution lives in ``WidgetIntentExecution`` (WidgetDisplayModels.swift).
//
//  - SeeAlso: docs/WidgetSurface-OI-W3-Plan-and-Status.md (PR 2),
//    docs/Widget-Functionality-Roadmap.md (OI-W3), CODING_AGENT.md.
//

import Foundation

/// Optimistic play/pause plan for home-widget and Control-widget toggle intents.
public struct WidgetToggleActionPlan: Sendable, Equatable {
    /// Pending-action verb written to App Group (`"play"` or `"pause"`).
    public let action: String
    /// Optimistic visual state persisted before the main app drains the pending action.
    public let targetVisualState: PlayerVisualState

    public init(action: String, targetVisualState: PlayerVisualState) {
        self.action = action
        self.targetVisualState = targetVisualState
    }
}

/// Playback direction for Live Activity toggle intents (main-app execution via actor).
public enum WidgetLiveActivityTogglePlan: Sendable, Equatable {
    case pause
    case play
}

/// Canonical mapping from snapshot/control input to optimistic toggle plans.
///
/// AGENT NOTE: Tests and extension `perform()` must call these planners — never duplicate
/// the home/control bool matrices in test helpers or extension bodies.
public enum WidgetIntentCoordinators {

    /// Plans home-widget toggle from the persisted visual state SSOT read.
    ///
    /// - Parameter visualState: ``SharedPlayerManager/loadPersistedVisualStateDirect()`` in production.
    /// - Returns: Pending action + optimistic target visual state.
    public static func planHomeWidgetToggle(from visualState: PlayerVisualState) -> WidgetToggleActionPlan {
        let shouldPlay = !visualState.isActivelyPlaying
        return WidgetToggleActionPlan(
            action: shouldPlay ? "play" : "pause",
            targetVisualState: shouldPlay ? .playing : .userPaused
        )
    }

    /// Plans Control-widget `SetValueIntent` toggle (`true` = play, `false` = pause).
    ///
    /// - Parameter isPlayingRequested: Bool from `ControlWidgetToggle` / `ToggleRadioIntent.value`.
    /// - Returns: Pending action + optimistic target visual state.
    public static func planControlWidgetToggle(isPlayingRequested value: Bool) -> WidgetToggleActionPlan {
        WidgetToggleActionPlan(
            action: value ? "play" : "pause",
            targetVisualState: value ? .playing : .userPaused
        )
    }

    /// Plans Live Activity play/pause toggle from actor-isolated visual state.
    ///
    /// - Parameter visualState: ``SharedPlayerManager/currentVisualState`` in production.
    /// - Returns: Whether the extension should call `stop()` or `userRequestedPlay()`.
    public static func planLiveActivityToggle(from visualState: PlayerVisualState) -> WidgetLiveActivityTogglePlan {
        visualState.isActivelyPlaying ? .pause : .play
    }

    /// Resolves the language code for optimistic snapshot writes.
    ///
    /// Prefers the persisted snapshot language (the value the Provider just rendered) over
    /// `preferredWidgetLanguage()` so first interaction does not fall back to `"en"` when the
    /// hasActiveWidgets cache is still cold.
    ///
    /// - Parameters:
    ///   - persistedLanguage: `PersistedWidgetState.currentLanguage` when a snapshot exists.
    ///   - preferredLanguage: ``SharedPlayerManager/preferredWidgetLanguage()`` fallback.
    /// - Returns: Language code for optimistic persist + pending-action tuple.
    public static func languageForOptimisticUpdate(
        persistedLanguage: String?,
        preferredLanguage: String
    ) -> String {
        persistedLanguage ?? preferredLanguage
    }
}
