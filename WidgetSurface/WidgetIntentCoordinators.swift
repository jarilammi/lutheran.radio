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
//  - SeeAlso: docs/Widget-Functionality-Roadmap.md (widget extension test coverage),
//    docs/Widget-Presentation-Dataflow.md, CODING_AGENT.md.
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

/// Which signal produced the visual state used to plan a Live Activity toggle.
///
/// Lock-screen LA intents often run in a short-lived extension process whose
/// in-memory ``PersistedWidgetState`` session snapshot is empty (especially when
/// home-widget write suppression is active). Planning must prefer signals that
/// match the button glyph the user actually saw.
///
/// Priority (highest first): live ActivityKit content → durable App Group mirror
/// → actor (when actively playing) → session snapshot → actor → default `.prePlay`.
///
/// **Post-term / reboot play distrust:** when ``planLiveActivityToggle(resolution:distrustDurableMirrorPlay:)``
/// is called with `distrustDurableMirrorPlay: true`, a resolution whose sole winning source is
/// ``LiveActivityToggleStateSource/durableCrossProcessMirror`` must not produce `.play`
/// (stale App Group after dirty power-off). ActivityKit content remains trusted.
///
/// - SeeAlso: ``WidgetIntentCoordinators/resolveLiveActivityToggleVisualState(liveActivityContent:durableMirror:actorVisualState:sessionSnapshot:)``,
///   docs/Widget-Functionality-Roadmap.md.
public enum LiveActivityToggleStateSource: String, Sendable, Equatable {
    /// `Activity<…>.content.state.visualState` — matches the rendered LA glyph.
    case liveActivityContent
    /// App Group key written on every LA content push (cross-process, privacy-gated separately from home widgets).
    case durableCrossProcessMirror
    /// Extension/main-process ``SharedPlayerManager/currentVisualState``.
    case actorVisualState
    /// In-process session snapshot (`loadPersistedWidgetState`), if present.
    case sessionSnapshot
    /// No usable signal; factory default for cold extension.
    case defaultPrePlay
}

/// Resolved visual state + provenance for Live Activity toggle planning.
public struct LiveActivityToggleVisualResolution: Sendable, Equatable {
    public let visualState: PlayerVisualState
    public let source: LiveActivityToggleStateSource

    public init(visualState: PlayerVisualState, source: LiveActivityToggleStateSource) {
        self.visualState = visualState
        self.source = source
    }
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

    /// Resolves which visual state should drive Live Activity play/pause planning.
    ///
    /// - Parameters:
    ///   - liveActivityContent: `ContentState.visualState` from an active ActivityKit activity, when readable.
    ///   - durableMirror: Cross-process App Group mirror of the last pushed LA visual state.
    ///   - actorVisualState: ``SharedPlayerManager/currentVisualState`` in the intent process (often `.prePlay` when the session snapshot is empty).
    ///   - sessionSnapshot: In-process `PersistedWidgetState.visualState` when present this process lifetime.
    /// - Returns: Effective visual state and which signal won.
    /// - Important: Prefer Live Activity content over extension-local actor state so the plan matches the lock-screen glyph (playing → pause).
    /// - SeeAlso: ``planLiveActivityToggle(from:)``, ``planLiveActivityToggle(resolution:)``.
    public static func resolveLiveActivityToggleVisualState(
        liveActivityContent: PlayerVisualState?,
        durableMirror: PlayerVisualState?,
        actorVisualState: PlayerVisualState?,
        sessionSnapshot: PlayerVisualState?
    ) -> LiveActivityToggleVisualResolution {
        // 1. ActivityKit content — same SSOT the LA UI used for the control glyph.
        if let liveActivityContent {
            return LiveActivityToggleVisualResolution(
                visualState: liveActivityContent,
                source: .liveActivityContent
            )
        }

        // 2. Durable cross-process mirror — survives empty extension memory / no home widgets.
        if let durableMirror {
            return LiveActivityToggleVisualResolution(
                visualState: durableMirror,
                source: .durableCrossProcessMirror
            )
        }

        // 3. Actor actively playing (main-app intent host or warm extension).
        if let actorVisualState, actorVisualState.isActivelyPlaying {
            return LiveActivityToggleVisualResolution(
                visualState: actorVisualState,
                source: .actorVisualState
            )
        }

        // 4. In-process session snapshot when the main app (or a prior intent) wrote one.
        if let sessionSnapshot {
            return LiveActivityToggleVisualResolution(
                visualState: sessionSnapshot,
                source: .sessionSnapshot
            )
        }

        // 5. Remaining actor value (including sticky pause) over factory default.
        if let actorVisualState {
            return LiveActivityToggleVisualResolution(
                visualState: actorVisualState,
                source: .actorVisualState
            )
        }

        return LiveActivityToggleVisualResolution(
            visualState: .prePlay,
            source: .defaultPrePlay
        )
    }

    /// Plans Live Activity play/pause from a fully resolved multi-source visual state.
    ///
    /// - Parameters:
    ///   - resolution: Output of ``resolveLiveActivityToggleVisualState(liveActivityContent:durableMirror:actorVisualState:sessionSnapshot:)``.
    ///   - distrustDurableMirrorPlay: When `true` (post-termination sentinel or device reboot),
    ///     refuse `.play` if the winning source is only the durable App Group mirror. Maps to
    ///     `.pause` so execution never calls `userRequestedPlay()` from a stale mirror alone.
    ///     ActivityKit content and actor/session sources are unchanged.
    /// - Returns: Whether the intent path should pause or play.
    /// - Important: Wire `distrustDurableMirrorPlay` from
    ///   ``SharedPlayerManager/shouldDistrustDurableMirrorPlayPlanning()`` at
    ///   ``WidgetIntentExecution/performLiveActivityToggle()``. Default `false` preserves
    ///   in-session empty-extension pause planning (mirror `.playing` → pause).
    /// - SeeAlso: docs/Widget-Functionality-Roadmap.md (lock-screen LA toggle planning).
    public static func planLiveActivityToggle(
        resolution: LiveActivityToggleVisualResolution,
        distrustDurableMirrorPlay: Bool = false
    ) -> WidgetLiveActivityTogglePlan {
        let plan = planLiveActivityToggle(from: resolution.visualState)
        if distrustDurableMirrorPlay,
           resolution.source == .durableCrossProcessMirror,
           plan == .play {
            // SECURITY/RESURRECTION: durable mirror after term/reboot is a stale App Group
            // signal, not a live glyph. Never synthesize play from it alone.
            return .pause
        }
        return plan
    }

    /// Plans Live Activity play/pause toggle from a single visual state.
    ///
    /// Prefer ``planLiveActivityToggle(resolution:distrustDurableMirrorPlay:)`` or multi-source
    /// resolution at ``WidgetIntentExecution/performLiveActivityToggle()`` so lock-screen intents
    /// do not invert when extension-local memory is empty, and do not resurrect play from a
    /// durable mirror alone after termination or reboot.
    ///
    /// - Parameter visualState: Effective visual state (from LA content, durable mirror, or actor).
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
