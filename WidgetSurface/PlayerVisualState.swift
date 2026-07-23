//
//  PlayerVisualState.swift
//  WidgetSurface
//
//  Created by Jari Lammi on 18.3.2026.
//
//  Visual playback policy SSOT for UI, widgets, Live Activities, and App Intents.
//
//  WidgetSurface framework — presentation-only (no security logic).
//
//  Module layout (behavior-preserving split):
//  - This file: `PlayerVisualState` cases, policy helpers, engine status mapping
//  - `PlaybackIntent.swift`: user intent + stop/attach enums
//  - `PlayerEvent.swift`: event vocabulary + late-subscriber replay snapshot
//  - `PlayerPresentation.swift`: narrow presentation types, chrome palette, mappers
//
//  Purpose:
//  Answers "what should the UI/widget show?" and carries sticky resurrection policy
//  for visual cases (``.userPaused``, ``.securityLocked``). Companion intent sticky
//  blockers (including ``.cleared``) live on ``PlaybackIntent``.
//
//  Event architecture (current truth):
//  - `SharedPlayerManager` is the authoritative emitter of ``PlayerEvent`` after mutations.
//  - Observation is additive / non-forcing; imperative mutation paths remain primary.
//  - Vocabulary types live in `PlayerEvent.swift`; emission sites are in SharedPlayerManager.
//
//  Key invariants:
//  - `PlayerVisualState` + `PlaybackIntent` (via `SharedPlayerManager`) are the SSOTs for
//    "what should the UI show?" and "does the user want audio playing?"
//  - `.userPaused` and `.securityLocked` (via visual) plus `.cleared` (via PlaybackIntent)
//    are sticky resurrection blockers; only explicit user play clears them.
//  - .cleared visual (blue + "clear_local_state_done") confirms a successful privacy reset;
//    the blocker is intent; post-clear launches without a snapshot use .prePlay.
//  - `isActivelyPlaying` and button tint remain on this type for semantic/policy decisions
//    (LIVE indicator, animation, resurrection, intent calculations). Pure glyph+tint
//    presentation for play/pause controls uses ``makeControlPresentation()``.
//  - Chrome colors are owned by ``PlayerVisualChromePalette``; UIColor properties here
//    delegate to that palette so UIKit and SwiftUI cannot drift.
//  - These types are persisted (Codable) in `PersistedWidgetState` for cross-process
//    optimistic state. No PII.
//  - This file contains *no* security logic. Security decisions live only in `Core/`.
//
//  - SeeAlso: `SharedPlayerManager` (mutation + persistence + event emission),
//    `PersistedWidgetState`, ``PlayerStatusPresentation``, ``PlayerControlPresentation``,
//    ``PlayerEvent``, ``PlaybackIntent``, ``PlayerVisualChromePalette``,
//    CODING_AGENT.md (Single Source of Truth Principles, cross-target WidgetSurface),
//    docs/Event-Driven-Refactor-Roadmap.md, docs/Widget-Presentation-Dataflow.md,
//    README.md (Single Sources of Truth table).
//  - AGENT NOTE: Any change to these cases or their sticky semantics must also update
//    the resurrection tables and guards inside SharedPlayerManager.swift.
//

import Foundation
import UIKit

// MARK: - PlayerVisualState

/// Single source of truth for playback UI **and** sticky visual intent policy.
///
/// - prePlay:        yellow, auto-plays on first launch only (or post stream switch)
/// - cleared:        blue "Cleared", shown immediately after successful privacy "Clear local state".
///                   Distinct confirmation that reset completed. The actual blocker is the
///                   companion `.cleared` PlaybackIntent (see ``PlaybackIntent``). Behaves like
///                   .prePlay for readiness (shouldAutoPlayOrResume) but provides explicit
///                   post-reset visual.
/// - playing:        green
/// - userPaused:     grey, NEVER auto-resumes
/// - thermalPaused:  amber, device is overheating (blocks auto-resume)
/// - securityLocked: red
///
/// `.userPaused` is sticky after any manual interaction until explicit play.
@frozen public enum PlayerVisualState: Codable, Equatable, Hashable, Sendable {

    case prePlay            // Initial load / connecting / never played yet → yellow
    case cleared            // Post "Clear local state" (privacy reset) → blue "Cleared"; ready state + intent blocker
    case playing            // Actively playing → green
    case userPaused         // Explicit user pause/stop → grey (sticky)
    case thermalPaused      // Device overheating → amber/orange warning
    case securityLocked     // Security / certificate failure → red

    // MARK: - Visual properties (palette delegates)

    /// Status / host background. Delegates to ``PlayerVisualChromePalette``.
    public var backgroundColor: UIColor {
        PlayerVisualChromePalette.backgroundUIColor(for: self)
    }

    /// Primary text color on ``backgroundColor``. Delegates to ``PlayerVisualChromePalette``.
    public var textColor: UIColor {
        PlayerVisualChromePalette.textUIColor(for: self)
    }

    /// Control / decorative tint. Delegates to ``PlayerVisualChromePalette``.
    ///
    /// Widget + Live Activity control presentation derives once via
    /// ``makeControlPresentation()``. Non-control uses (e.g. radio glyph in leading
    /// Dynamic Island region) may continue to read this property.
    public var buttonTintColor: UIColor {
        PlayerVisualChromePalette.buttonTintUIColor(for: self)
    }

    // MARK: - Semantic properties

    /// True only when audio is actively playing (``.playing``).
    ///
    /// This is a *semantic* / policy property, not a presentation helper.
    /// It is intentionally retained on `PlayerVisualState` for:
    /// - Resurrection and auto-play guards
    /// - LIVE indicator visibility and animation presence in widgets / Live Activities
    /// - Now Playing rate / `playbackState` alignment (audio flowing vs not)
    ///
    /// **Not** a complete media-toggle planner: connecting (``.prePlay`` while a start
    /// pipeline is active), thermal, and security need the companion helpers below and
    /// actor/engine context (``SharedPlayerManager/isConnectingPlayback``). Pure glyph
    /// choice for the control button uses ``makeControlPresentation()`` (still driven by
    /// this flag so connecting keeps a play affordance until audible ``setPlaying()``).
    ///
    /// - SeeAlso: ``plansMediaToggleAsPause``, ``blocksPlannedPlay``,
    ///   ``optimisticVisualAfterPlayPlan``, ``makeControlPresentation()``,
    ///   ``shouldAutoPlayOrResume``, docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   CODING_AGENT.md (isActivelyPlaying may remain for semantic decisions).
    public var isActivelyPlaying: Bool {
        self == .playing
    }

    /// Whether a pure-visual media-transport / widget / Live Activity **toggle** should plan pause.
    ///
    /// True only while audio is flowing (``.playing``). Canceling an in-flight connect
    /// (``.prePlay`` + active start pipeline) requires actor context and is applied by
    /// ``WidgetIntentCoordinators/planLiveActivityToggle(resolution:distrustDurableMirrorPlay:isConnectingPlayback:)``
    /// and ``SharedPlayerManager`` media-transport toggle — not by this flag alone.
    ///
    /// - SeeAlso: ``isActivelyPlaying``, ``blocksPlannedPlay``,
    ///   ``WidgetIntentCoordinators/planLiveActivityToggle(from:)``
    public var plansMediaToggleAsPause: Bool {
        isActivelyPlaying
    }

    /// Whether planned **play** must be refused while this visual is authoritative.
    ///
    /// - ``thermalPaused``: hardware thermal gate with automatic resume on cool-down
    ///   (`shouldAutoResumeOnThermalRecovery`). Scheduling play while still hot fights
    ///   that policy and can thrash attach without clear thermal chrome.
    /// - ``securityLocked`` is **not** blocked here: explicit play is the recovery path
    ///   (re-validation); optimistic chrome uses ``optimisticVisualAfterPlayPlan`` so the
    ///   control does not claim `.playing` before validation succeeds.
    ///
    /// - SeeAlso: ``shouldAutoResumeOnThermalRecovery``, ``optimisticVisualAfterPlayPlan``,
    ///   ``SharedPlayerManager/isDeviceThermallyStressed()``
    public var blocksPlannedPlay: Bool {
        self == .thermalPaused
    }

    /// Optimistic control visual after a **play** plan, before engine-complete ``setPlaying()``.
    ///
    /// - ``securityLocked`` → ``prePlay`` (connecting chrome) so recovery re-validation does
    ///   not flash green / pause-glyph while DNS/cert work is still in flight.
    /// - All other play-eligible states → ``playing`` so a rapid second lock-screen tap can
    ///   re-plan pause from optimistic ContentState (existing dual-tap contract).
    ///
    /// - Returns: Target visual for durable LA mirror / optimistic ContentState / home-widget
    ///   optimistic snapshot after a play plan.
    /// - SeeAlso: ``blocksPlannedPlay``, ``WidgetIntentExecution/performLiveActivityToggle()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    public var optimisticVisualAfterPlayPlan: PlayerVisualState {
        switch self {
        case .securityLocked:
            return .prePlay
        default:
            return .playing
        }
    }

    /// Single source of truth.
    /// Returns false for .userPaused and .error — this blocks ALL resurrection paths
    /// (viewDidAppear, completeStreamSwitch, widget callbacks, etc.)
    /// .cleared returns true (ready) because the blocker is carried exclusively by PlaybackIntent.cleared.
    public var shouldAutoPlayOrResume: Bool {
        switch self {
        case .prePlay, .cleared, .playing:
            return true
        case .userPaused, .thermalPaused, .securityLocked:
            return false
        }
    }

    public var shouldAutoResumeOnThermalRecovery: Bool {
        self == .thermalPaused
    }

    public var mustSuppressResurrection: Bool {
        self == .userPaused || self == .securityLocked
    }
}

// MARK: - Engine status mapping

public extension PlayerVisualState {
    /// Maps PlayerStatus + flags → visual state with strict "userPaused is sticky" rule.
    ///
    /// Once the user has manually paused (or ever played), we lock into .userPaused
    /// until they explicitly tap Play again. This prevents the yellow resurrection.
    /// Note: .cleared is set explicitly by privacy reset (never returned from this mapper);
    /// status callbacks after clear are forced to preserve the .cleared visual by caller logic
    /// that also inspects PlaybackIntent.
    static func from(
        status: PlayerStatus,
        isManualPause: Bool,
        hasEverPlayed: Bool,
        currentVisualState: PlayerVisualState = .prePlay
    ) -> PlayerVisualState {

        // Note: Once userPaused, stay there for any non-playing status
        // This defeats the status-callback flip-back bug
        if currentVisualState == .userPaused && status != .playing {
            #if DEBUG
            print("[PlayerVisualState] preserving sticky .userPaused for status=\(status)")
            #endif
            return .userPaused
        }

        switch status {
        case .playing:
            return .playing

        case .connecting:
            // Only show prePlay on true first launch (never played before)
            return hasEverPlayed ? .userPaused : .prePlay

        case .security:
            return .securityLocked

        case .paused, .stopped:
            // Once user has ever interacted (paused or played), stay in userPaused
            if isManualPause || hasEverPlayed || currentVisualState == .userPaused {
                return .userPaused
            }
            return .prePlay   // only for brand-new launch
        }
    }
}
