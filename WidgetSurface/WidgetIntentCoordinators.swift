//
//  WidgetIntentCoordinators.swift
//  WidgetSurface
//
//  Created by Jari Lammi on 14.7.2026.
//
//  Pure intent planning SSOT for home widgets, Control Center, and Live Activity toggles.
//  Extension `perform()` bodies delegate here for action/target mapping; cross-target
//  execution lives in ``WidgetIntentExecution`` (membership-exception source under
//  `Lutheran Radio/`).
//
//  Pending play/pause verbs are typed as ``WidgetToggleAction`` inside planning; App Group
//  mailbox boundaries convert via ``WidgetToggleAction/wireValue``.
//
//  - SeeAlso: docs/Widget-Functionality-Roadmap.md, docs/Widget-Presentation-Dataflow.md,
//    CODING_AGENT.md (cross-target widget sources).
//

import Foundation

// MARK: - WidgetToggleAction

/// Typed pending play/pause verb for home-widget and Control-widget toggle plans.
///
/// Planning and tests use the enum. App Group / Darwin mailbox writers convert with
/// ``wireValue`` (`"play"`, `"pause"`). Refuse plans use ``none`` and do not schedule
/// a pending action (thermal gate keeps chrome authoritative).
///
/// - Note: Stream-switch pending actions use the separate `"switch"` wire verb and are
///   not represented on this enum (see ``SharedPlayerManager/scheduleWidgetAction``).
/// - SeeAlso: ``WidgetToggleActionPlan``, ``WidgetIntentExecution/executeOptimisticToggle(plan:language:)``
public enum WidgetToggleAction: String, Sendable, Equatable, Hashable {
    case play
    case pause
    /// Policy refuse — no pending App Group action and no engine mutation.
    case none

    /// Wire form written to App Group `pendingAction` for executable plans.
    ///
    /// - Returns: `"play"`, `"pause"`, or `"none"` (refuse plans should not call schedule).
    public var wireValue: String { rawValue }

    /// Parses an App Group / Darwin wire string into a typed toggle action.
    ///
    /// - Parameter wireValue: Stored `pendingAction` string (`"play"`, `"pause"`, `"none"`).
    /// - Returns: Matching case, or `nil` when the string is not a toggle verb
    ///   (e.g. `"switch"` uses a different mailbox path).
    public init?(wireValue: String) {
        self.init(rawValue: wireValue)
    }
}

/// Optimistic play/pause plan for home-widget and Control-widget toggle intents.
public struct WidgetToggleActionPlan: Sendable, Equatable {
    /// Typed pending-action verb. Executable plans use ``WidgetToggleAction/play`` or
    /// ``WidgetToggleAction/pause``; thermal refuse uses ``WidgetToggleAction/none``.
    public let action: WidgetToggleAction
    /// Optimistic visual state persisted before the main app drains the pending action.
    /// For refuse plans, equals the current visual (thermal chrome stays authoritative).
    public let targetVisualState: PlayerVisualState

    public init(action: WidgetToggleAction, targetVisualState: PlayerVisualState) {
        self.action = action
        self.targetVisualState = targetVisualState
    }

    /// Whether a pending App Group action should be scheduled and drained.
    ///
    /// - Returns: `true` for play/pause; `false` for none (thermal refuse).
    public var shouldExecutePendingAction: Bool {
        action == .play || action == .pause
    }
}

/// Playback direction for Live Activity toggle intents (main-app execution via actor).
///
/// - `pause` / `play`: engine mutation via ``WidgetIntentExecution/executeLiveActivityToggle(plan:)``.
/// - `refuse`: keep policy chrome (e.g. thermal while still hot); no optimistic flip, no engine work.
///
/// - SeeAlso: ``PlayerVisualState/blocksPlannedPlay``, ``PlayerVisualState/plansMediaToggleAsPause``,
///   ``WidgetIntentCoordinators/planLiveActivityToggle(from:)``
public enum WidgetLiveActivityTogglePlan: Sendable, Equatable {
    case pause
    case play
    /// No engine mutation and no optimistic chrome change (policy gate still authoritative).
    case refuse
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
    /// Matrix (pure visual; connecting cancel uses actor pipeline on lock-screen / remotes):
    /// - ``PlayerVisualState/plansMediaToggleAsPause`` (``.playing``) → pause / `.userPaused`
    /// - ``PlayerVisualState/blocksPlannedPlay`` (``.thermalPaused``) → `"none"` / keep thermal
    /// - otherwise → play / ``PlayerVisualState/optimisticVisualAfterPlayPlan``
    ///
    /// - Parameter visualState: ``SharedPlayerManager/loadPersistedVisualStateDirect()`` in production.
    /// - Returns: Pending action + optimistic target visual state.
    /// - SeeAlso: ``planLiveActivityToggle(from:)``, ``PlayerVisualState/blocksPlannedPlay``
    public static func planHomeWidgetToggle(from visualState: PlayerVisualState) -> WidgetToggleActionPlan {
        if visualState.plansMediaToggleAsPause {
            return WidgetToggleActionPlan(action: .pause, targetVisualState: .userPaused)
        }
        if visualState.blocksPlannedPlay {
            return WidgetToggleActionPlan(action: .none, targetVisualState: visualState)
        }
        return WidgetToggleActionPlan(
            action: .play,
            targetVisualState: visualState.optimisticVisualAfterPlayPlan
        )
    }

    /// Plans Control-widget `SetValueIntent` toggle (`true` = play, `false` = pause).
    ///
    /// - Parameter isPlayingRequested: Bool from `ControlWidgetToggle` / `ToggleRadioIntent.value`.
    /// - Returns: Pending action + optimistic target visual state.
    public static func planControlWidgetToggle(isPlayingRequested value: Bool) -> WidgetToggleActionPlan {
        WidgetToggleActionPlan(
            action: value ? .play : .pause,
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
    ///   - isConnectingPlayback: When `true` (main-app start pipeline active, not yet
    ///     ``PlayerVisualState/isActivelyPlaying``), plan **pause** to cancel connect instead of
    ///     re-entering ``userRequestedPlay()`` (duplicate validation / attach). Wire from
    ///     ``SharedPlayerManager/isConnectingPlayback``.
    /// - Returns: Whether the intent path should pause, play, or refuse.
    /// - Important: Wire `distrustDurableMirrorPlay` from
    ///   ``SharedPlayerManager/shouldDistrustDurableMirrorPlayPlanning()`` at
    ///   ``WidgetIntentExecution/performLiveActivityToggle()``. Default `false` preserves
    ///   in-session empty-extension pause planning (mirror `.playing` → pause).
    /// - SeeAlso: docs/Widget-Functionality-Roadmap.md (lock-screen LA toggle planning),
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    public static func planLiveActivityToggle(
        resolution: LiveActivityToggleVisualResolution,
        distrustDurableMirrorPlay: Bool = false,
        isConnectingPlayback: Bool = false
    ) -> WidgetLiveActivityTogglePlan {
        // In-flight connect wins over pure visual: second lock-screen / remote toggle cancels
        // attach rather than stacking another play pipeline on Connecting chrome.
        if isConnectingPlayback {
            return .pause
        }
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
    /// Prefer ``planLiveActivityToggle(resolution:distrustDurableMirrorPlay:isConnectingPlayback:)``
    /// or multi-source resolution at ``WidgetIntentExecution/performLiveActivityToggle()`` so
    /// lock-screen intents do not invert when extension-local memory is empty, do not resurrect
    /// play from a durable mirror alone after termination or reboot, cancel in-flight connect,
    /// and refuse thermal play while the hardware gate is authoritative.
    ///
    /// - Parameter visualState: Effective visual state (from LA content, durable mirror, or actor).
    /// - Returns: Pause when audio is flowing; refuse when ``blocksPlannedPlay``; otherwise play.
    /// - SeeAlso: ``PlayerVisualState/plansMediaToggleAsPause``, ``PlayerVisualState/blocksPlannedPlay``
    public static func planLiveActivityToggle(from visualState: PlayerVisualState) -> WidgetLiveActivityTogglePlan {
        if visualState.plansMediaToggleAsPause {
            return .pause
        }
        if visualState.blocksPlannedPlay {
            return .refuse
        }
        return .play
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
