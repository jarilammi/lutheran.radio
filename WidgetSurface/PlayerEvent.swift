//
//  PlayerEvent.swift
//  WidgetSurface
//
//  Created by Jari Lammi on 23.7.2026.
//
//  Canonical player-domain event vocabulary and late-subscriber replay snapshot.
//
//  WidgetSurface framework — presentation-only (no security logic).
//
//  Ownership split (behavior-preserving):
//  - This file: `PlayerEvent` vocabulary + `PlayerCurrentState` replay snapshot
//  - `PlaybackIntent.swift`: user intent + stop/attach policy enums
//  - `PlayerVisualState.swift`: visual policy + engine status mapping
//  - `PlayerPresentation.swift`: narrow presentation types, chrome palette, mappers
//
//  Emission and mutation remain exclusively in `SharedPlayerManager` (main app).
//  Observation is additive / non-forcing — imperative paths stay primary.
//
//  Invariants:
//  - Pure vocabulary types only; no side effects, no security cases.
//  - Payloads use existing SSOT types (`PlaybackIntent`, `PlayerVisualState`,
//    `StreamProgramMetadata`, `StreamErrorType`).
//  - `Sendable` + `Hashable` + `Equatable` required for actor and test use.
//
//  - SeeAlso: `SharedPlayerManager` (emitter + `currentState` /
//    `makeEventsStreamWithReplay()`), ``PlaybackIntent``, ``PlayerVisualState``,
//    ``WidgetEventObserver``, docs/Event-Driven-Refactor-Roadmap.md,
//    CODING_AGENT.md (event-driven direction, Single Source of Truth).
//  - AGENT NOTE: When adding event cases that carry state, update
//    ``PlayerCurrentState`` construction in SharedPlayerManager in the same change.
//

import Foundation

// MARK: - PlayerEvent

/// Canonical vocabulary of significant domain events for the player and widget subsystem.
///
/// `SharedPlayerManager` is the authoritative emitter. Tier 1 emission coverage
/// (stream start/pause/stop/fail, metadata update, visual state change, persisted
/// widget state update, and intent change) is implemented inside the actor after
/// the corresponding mutations. Emissions are strictly additive; all direct
/// imperative paths and snapshot writes continue to operate unchanged.
///
/// - SeeAlso: <doc:Architecture>, SharedPlayerManager.swift, PlaybackIntent, PlayerVisualState,
///   CODING_AGENT.md, docs/Event-Driven-Refactor-Roadmap.md.
/// - Important: This type remains additive. Direct state access and existing call
///   sites are the primary mechanism; event observation is available for new
///   decoupled consumers (Tier 2+).
/// - Note: `PlayerEvent` conforms to Sendable so it can be safely sent across actor
///   boundaries and between the main app and widget/Live Activity extension processes.
///   Hashable + Equatable support snapshot comparison and testing.
/// - `SharedPlayerManager.currentState` and the replaying stream surface provide
///   initialization for late subscribers; see ``PlayerCurrentState``.
/// - Warning: Do not add security-sensitive or certificate-related cases here.
///   Security events stay inside Core/.
///
/// AGENT NOTE: Single source of truth for player-domain events. Any future extension
/// must preserve Sendable + Hashable and must be reviewed for impact on widget/Live
/// Activity snapshot derivation. All cases must carry a documentation comment
/// explaining the long-term decoupling or testability benefit.
@frozen public enum PlayerEvent: Sendable, Hashable, Equatable {
    /// The authoritative playback intent changed.
    ///
    /// Why this event exists: centralizes the signal ("does the user want audio playing?")
    /// so that UI, DirectStreamingPlayer recovery, widget intents, Live Activities, and
    /// resurrection logic can all react from one source instead of reading multiple flags.
    case playbackIntentChanged(PlaybackIntent)

    /// The stream successfully began delivering and rendering audio.
    ///
    /// Why this event exists: provides a single hook for side effects (liveness bump,
    /// Now Playing info, Live Activity start, optimistic widget clear) that today are
    /// scattered across KVO paths and play() call sites.
    case streamDidStart

    /// Playback entered a paused state (explicit or transient).
    ///
    /// Why this event exists: allows consistent pause bookkeeping and UI/widget
    /// synchronization without every pause path having to call the same three methods.
    case streamDidPause

    /// Playback was fully stopped (user action, switch, or termination).
    ///
    /// Why this event exists: distinguishes terminal stops from pauses for resurrection
    /// policy, widget state, and analytics in a uniform way.
    case streamDidStop

    /// The active stream reported a classified failure.
    ///
    /// The `StreamErrorType` payload distinguishes transient failures (subject to
    /// engine recovery via recreate and network paths) from permanentFailure and
    /// securityFailure. Successful recovery after a transient failure surfaces as
    /// a subsequent `streamDidStart`. `PlayerCurrentState.hasError` supplies the
    /// terminal error condition to late subscribers through the replaying stream
    /// and currentState snapshot.
    ///
    /// Why this event exists: routes permanent vs transient errors through the same
    /// vocabulary used for success paths, enabling a single error surface for widgets,
    /// user-visible status, and recovery decisions.
    case streamDidFail(StreamErrorType)

    /// Program metadata (title/speaker parsed from ICY StreamTitle) changed.
    ///
    /// Why this event exists: ensures all surfaces (Lock Screen Now Playing,
    /// widgets, Live Activities) receive identical metadata at the same moment
    /// instead of polling or duplicating the parse + dispatch logic.
    case metadataDidUpdate(StreamProgramMetadata?)

    /// The persisted widget snapshot (visual + language + metadata + hasError) was written.
    ///
    /// Why this event exists: `PersistedWidgetState` is the SSOT for home-screen widgets,
    /// Control widgets, and Live Activity content. Emitting on every authoritative or
    /// optimistic write will let consumers invalidate or update without tight coupling
    /// to `savePersistedWidgetState` / `persistWidgetSnapshot`.
    ///
    /// The case is emitted as a signal after authoritative snapshot writes.
    /// A payload-carrying variant may be introduced later if observers require
    /// the concrete state in the event itself; current consumers derive from
    /// the SSOT loaders.
    case persistedWidgetStateDidUpdate

    /// The in-memory visual state used for UI decisions and resurrection changed.
    ///
    /// Why this event exists: `PlayerVisualState` drives color, glyph, auto-play guards,
    /// and sticky pause logic. A dedicated change event will let observers (future
    /// event bus, test harnesses, debug overlays) stay in sync without observing the
    /// actor property directly.
    case visualStateDidChange(PlayerVisualState)
}

// MARK: - PlayerCurrentState

/// Snapshot of the current player-domain state for initializing late subscribers.
///
/// `PlayerCurrentState` captures the facts that `PlayerEvent` cases convey so that
/// observers starting after the manager has already emitted events can obtain the
/// present state without missing prior transitions.
///
/// `SharedPlayerManager` publishes this snapshot via ``SharedPlayerManager/currentState``.
/// A companion replaying stream (``SharedPlayerManager/makeEventsStreamWithReplay()``)
/// yields the equivalent `PlayerEvent` values first and then forwards live events.
///
/// The snapshot contains exactly the data carried by the Tier 1 events:
/// - `visualState` (from `visualStateDidChange`)
/// - `playbackIntent` (from `playbackIntentChanged`)
/// - `streamMetadata` (from `metadataDidUpdate`)
/// - `hasError` (derived from security locked state and persisted snapshot)
///
/// Stream transition verbs (`streamDidStart`, `streamDidPause`, `streamDidStop`,
/// `streamDidFail`) are **not** synthesized during replay. The resulting terminal
/// state is expressed through the four fields (especially `hasError` for terminal
/// error conditions). See the Tier 3 architectural evaluation in the roadmap.
///
/// **Single Source of Truth relationship**:
/// `PlayerCurrentState` is a derived, read-only convenience. The authoritative
/// values live in `SharedPlayerManager` (`currentVisualState`, `currentPlaybackIntent`,
/// `currentStreamMetadata`) and in `PersistedWidgetState` (via `loadPersistedWidgetState`).
/// Consumers may read the snapshot for initialization and then observe events for
/// subsequent deltas.
///
/// - Important: This type is additive. Existing direct state access, snapshot
///   loaders, and imperative paths remain the primary mechanism everywhere.
/// - Note: `PlayerCurrentState` is `Sendable`, `Equatable`, and `Hashable` so it
///   participates safely in Observation, actor boundaries, testing, and diffing.
/// - SeeAlso: ``PlayerEvent``, `SharedPlayerManager.currentState`,
///   `SharedPlayerManager.makeEventsStreamWithReplay()`,
///   `PlayerEventSubscriber`, `WidgetRefreshManager`,
///   `PlaybackIntent.isStickyPauseOrLock`,
///   `PlayerVisualState.isActivelyPlaying`,
///   docs/Event-Driven-Refactor-Roadmap.md (Tier 3 current-state replay + error and recovery surface),
///   CODING_AGENT.md (event-driven direction, Single Source of Truth Principles,
///   cross-target shared source files).
///
/// AGENT NOTE: `PlayerCurrentState` is the canonical replay surface for the
/// `PlayerEvent` vocabulary. When new event cases are added that carry state,
/// evaluate whether they must be reflected here and update the construction site
/// inside SharedPlayerManager together with this declaration. The computed
/// convenience properties below exist solely to reduce boilerplate for common
/// questions asked of a replay snapshot; they delegate to the authoritative types.
public struct PlayerCurrentState: Sendable, Equatable, Hashable {
    /// Current visual state (drives colors, glyphs, resurrection policy, and
    /// presentation derivations).
    public let visualState: PlayerVisualState

    /// Authoritative playback intent (the SSOT answering "does the user want audio playing?").
    public let playbackIntent: PlaybackIntent

    /// Latest program metadata parsed from the stream, if present.
    public let streamMetadata: StreamProgramMetadata?

    /// Whether the current state reflects a permanent error (security lock or
    /// persisted hasError flag).
    public let hasError: Bool

    public init(
        visualState: PlayerVisualState,
        playbackIntent: PlaybackIntent,
        streamMetadata: StreamProgramMetadata?,
        hasError: Bool
    ) {
        self.visualState = visualState
        self.playbackIntent = playbackIntent
        self.streamMetadata = streamMetadata
        self.hasError = hasError
    }

    // MARK: - Convenience accessors (derived, zero-cost)

    /// True when audio is actively flowing.
    ///
    /// Delegates to `PlayerVisualState.isActivelyPlaying` for semantic consistency
    /// with resurrection guards, LIVE indicators, and control glyph decisions.
    public var isActivelyPlaying: Bool {
        visualState.isActivelyPlaying
    }

    /// True when the current intent is a sticky blocker that only an explicit
    /// user play action can clear.
    ///
    /// Delegates to `PlaybackIntent.isStickyPauseOrLock`. Useful for late
    /// subscribers that need to decide whether to show blocked UI without
    /// re-reading the raw intent.
    public var isBlockedByStickyIntent: Bool {
        playbackIntent.isStickyPauseOrLock
    }

    /// True when a permanent error condition is present (security failure or
    /// unrecoverable stream failure persisted in the widget snapshot).
    ///
    /// Equivalent to `hasError`. Provided for naming symmetry with
    /// `DirectStreamingPlayer.StreamErrorType.isPermanent` and consumer code
    /// that talks about "permanent error" vs transient.
    public var isInPermanentError: Bool {
        hasError
    }
}
