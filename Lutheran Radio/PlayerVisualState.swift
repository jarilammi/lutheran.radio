//
//  PlayerVisualState.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 18.3.2026.
//

// SHARED: Cross-target source (main app + LutheranRadioWidgetExtension)
//
// Single physical file on disk, compiled into both targets via Xcode
// File System Synchronized Group + membershipExceptions (see project.pbxproj).
//
// Purpose:
// Defines the core value types for visual playback state and user intent
// (`PlayerVisualState`, `PlaybackIntent`, `StopReason`, `PlaybackAttachContext`)
// that are used for UI, widgets, Live Activities, and App Intents.
//
// This file also hosts the canonical `PlayerEvent` vocabulary (introduced in the
// first introduction of the gradual migration to a purely event-driven architecture).
// All significant domain transitions are expressed as `PlayerEvent` emissions from
// `SharedPlayerManager` (Tier 1 coverage complete for the core cases). The addition
// is 100 % additive; no existing imperative paths were altered or wrapped. See the
// `PlayerEvent` declaration and SharedPlayerManager for current emission sites and
// non-forcing invariants.
//
// Presentation surfaces (narrow derived value types):
// - `PlayerStatusPresentation` + `makeStatusPresentation()`: status pill/indicator
//   (background, foreground, text, optional systemImage). Used by main player,
//   home widgets (SimpleEntry), Live Activities, and Control widget.
// - `PlayerControlPresentation` + `makeControlPresentation()`: primary play/pause
//   control affordance (systemImage + tint Color). Captures glyph choice and
//   tinting so widget/Live Activity leaf regions and buttons receive only the
//   data they render.
//
// Key invariants:
// - `PlayerVisualState` + `PlaybackIntent` (via `SharedPlayerManager`) are
//   the Single Source of Truth answering "what should the UI/widget show?"
//   and "does the user want audio playing?";
// - `.userPaused` and `.securityLocked` (via visual) plus `.cleared` (via PlaybackIntent)
//   are sticky resurrection blockers; only explicit user play clears them.
// - .cleared visual (blue + "clear_local_state_done") exists to give sighted confirmation
//   of a successful privacy reset (intent is the actual blocker; post-clear launches use
//   .prePlay because no snapshot is persisted).
// - `isActivelyPlaying` and `buttonTintColor` remain on `PlayerVisualState` for
//   semantic/policy decisions (LIVE indicator visibility, animation triggers,
//   resurrection, intent calculations). Only pure glyph+tint *presentation* reads
//   for play/pause controls are expected to migrate to the narrow control type.
// - These types are persisted (Codable) in `PersistedWidgetState` for
//   cross-process optimistic state. No PII.
// - This file contains *no* security logic. Security decisions live only in
//   `Core/` (see CODING_AGENT.md "Core Framework Surface Area").
//
// - SeeAlso: `SharedPlayerManager` (the actor owning mutation + persistence),
//   `PersistedWidgetState`, `PlayerStatusPresentation`, `PlayerControlPresentation`,
//   `PlayerEvent` (the canonical event vocabulary added alongside these types),
//   CODING_AGENT.md (Single Source of Truth Principles, "Cross-target shared
//   source files (non-Core)", Documentation & Comment Standards, gradual event-driven
//   refactor guidance),
//   WidgetDisplayModels.swift (the parallel metadata/emphasis axis),
//   README.md (Single Sources of Truth table).
// - AGENT NOTE: Any change to these enums or their semantics must also update
//   the resurrection tables and guards inside SharedPlayerManager.swift.
//   Changes that touch `PlayerEvent` must also consider impact on future emission
//   sites and widget snapshot consumers.

import Foundation
import UIKit
import SwiftUI

// MARK: - PlayerStatusPresentation

/// Narrow value type containing only the data required to render the player status indicator.
///
/// This type is intentionally minimal and value-semantic so that SwiftUI leaf views,
/// widget entries, and Live Activity content can depend on a tiny Equatable input instead of
/// the full policy-rich `PlayerVisualState`.
///
/// It carries SwiftUI-native `Color` (no repeated `Color(uiColor:)` bridging in bodies) plus
/// localized text and an optional system image name for glyphs.
///
/// Parallel narrow type: `PlayerControlPresentation` + `makeControlPresentation()` handles
/// the play/pause button glyph and tint decisions for widgets and Live Activities.
///
/// - Important: `PlayerVisualState` remains the Single Source of Truth for both presentation
///   *and* resurrection/policy semantics. This type is a derived snapshot for display only.
/// - Note: Changes to status colors or copy should be made in `makeStatusPresentation()`.
/// - SeeAlso: ``PlayerVisualState/makeStatusPresentation()``, ``PlayerControlPresentation``,
///   ``PlayerVisualState/makeControlPresentation()``, ``PlayerViewModel/statusPresentation``,
///   `SimpleEntry.statusPresentation`, CODING_AGENT.md (narrow inputs, value types,
///   cached derived on @Observable, docs/Widget-Presentation-Dataflow.md).
struct PlayerStatusPresentation: Equatable {
    /// Background fill color for the status pill / indicator.
    let background: Color

    /// Foreground color for text (and optional image) drawn on the background.
    let foreground: Color

    /// Localized status text (e.g. "Playing", "Paused", "Connecting", ...).
    let text: String

    /// Optional SF Symbol name to accompany the text (e.g. "play.fill", "pause.fill", "lock.fill").
    /// Consumers may ignore this if they render the glyph elsewhere (main player controls do).
    let systemImage: String?
}

// MARK: - PlayerControlPresentation

/// Narrow value type containing only the data required to render the primary playback control (play/pause button).
///
/// This is the direct parallel to `PlayerStatusPresentation` for the control affordance axis.
/// It exists so that WidgetKit TimelineEntry consumers (`SimpleEntry`) and ActivityKit
/// `ContentState` / `ActivityViewContext` consumers can depend on a tiny `Equatable` input
/// for glyph choice and tint instead of the full policy `PlayerVisualState`.
///
/// **Single Source of Truth**: `PlayerControlPresentation` + `makeControlPresentation()`
/// is the only place that decides "play.fill" vs "pause.fill" + tint for control affordances.
/// All widget family views, Dynamic Island regions, Lock Screen Live Activity, and the
/// Control widget consume this type (or its fields) for the primary button.
///
/// - `systemImage`: The SF Symbol name to use for the toggle ("play.fill" when not actively playing,
///   "pause.fill" when `isActivelyPlaying`). Consumers may append ".circle" or other variants
///   for specific chrome (Lock Screen uses circle variants) while still sourcing the base decision here.
/// - `tint`: SwiftUI `Color` (derived once via `makeControlPresentation`) so repeated
///   `Color(uiColor:)` or `.swiftUIColor` bridging does not occur inside view bodies or region closures.
///
/// Why this narrow type (even without @Observable):
/// WidgetKit and ActivityKit deliver frozen value-type snapshots. Re-evaluation of bodies
/// and Dynamic Island regions happens on field-wise comparison of the supplied input.
/// A `SimpleEntry` or `ContentState` carrying the full `visualState` means any change
/// (even an unrelated field) can cause re-execution of control button rendering. By pre-deriving
/// (widgets: in Provider) or computing once at the top of the view/outer closure (Live Activities)
/// and handing only `PlayerControlPresentation`, we shrink the invalidation surface for the
/// control button and keep derivation logic out of the view layer (see swiftui-specialist
/// dataflow.md principles applied to snapshot model).
///
/// - Important: `PlayerVisualState` remains the Single Source of Truth for policy and
///   resurrection semantics. This type is a pure derived snapshot for display only.
/// - Note: Glyph decision is intentionally driven by `isActivelyPlaying` (playing → pause
///   affordance). `buttonTintColor` supplies the tint. Changes to mapping belong here.
/// - SeeAlso: ``PlayerStatusPresentation``, ``PlayerVisualState/makeStatusPresentation()``,
///   ``PlayerVisualState/makeControlPresentation()``, `SimpleEntry.controlPresentation`,
///   `LutheranRadioLiveActivityAttributes.ContentState`,
///   CODING_AGENT.md (narrow inputs for value types + WidgetKit/ActivityKit snapshot constraints),
///   WidgetDisplayModels.swift (sibling presentation axis for metadata/emphasis).
struct PlayerControlPresentation: Sendable, Equatable {
    /// SF Symbol name for the playback toggle control.
    ///
    /// Typically "play.fill" or "pause.fill". Consumers are free to use variant forms
    /// (e.g. "play.circle.fill") when the design calls for it, but the choice of which
    /// base glyph (play vs pause) must be driven by this value.
    let systemImage: String

    /// Tint color to apply to the control glyph (and commonly to its enclosing circle or background).
    ///
    /// Already a SwiftUI `Color` so leaf buttons and regions do not perform UIColor bridging.
    let tint: Color
}

// MARK: - Playback Intent
//
// Explicit, first-class representation of the user's current desired playback state.
// This is the single source of truth that answers the question:
//     "Does the user currently want audio to be playing?"
//
// Ownership: EXCLUSIVELY SharedPlayerManager (the actor is the only writer).
// Consumers (DirectStreamingPlayer, ViewController, widget paths, remote commands,
// interruption recovery, etc.) READ the intent via SharedPlayerManager but NEVER
// make their own "should I play?" decisions.
//
// Complements `PlayerVisualState` (what the UI shows) with explicit play/pause intent.
// Sticky `.userPaused`, `.securityLocked` (via visual) and `.cleared` (via PlaybackIntent) block resurrection until cleared by explicit user play.
//
//

/// User's current desired playback state (the authoritative "intent" signal).
///
/// - shouldBePlaying: The user has expressed (or defaulted to) a desire for audio
///                    to be playing. This is the normal "play" intent.
/// - shouldBePaused:  The user has taken an action whose natural result is paused
///                    state (e.g. stream switch while playing, or an explicit but
///                    non-sticky pause in some flows). Not a resurrection blocker.
/// - userPaused:      Explicit, sticky user-initiated pause or stop (button, remote,
///                    Control Center, widget pause, lock screen, etc.). This is the
///                    primary resurrection blocker. Once set, only an explicit user
///                    play action may clear it.
/// - sleepTimer:      Sleep timer is active (countdown) or has just elapsed.
///                    While audio is still playing, intent mirrors `.shouldBePlaying`
///                    and visual state stays `.playing`. When the timer fires, visual
///                    becomes `.userPaused` but intent remains `.sleepTimer` so logic
///                    can distinguish timer-driven pause from sticky `.userPaused`.
/// - securityLocked:  Permanent security failure (DNS TXT validation failure,
///                    certificate pinning failure, 403 from streaming server, etc.).
///                    This is a hard, permanent blocker until the next successful
///                    explicit play that passes full security validation.
/// - cleared:         Explicit user-initiated privacy clear ("Clear local playback state").
///                    Visual is set to dedicated .cleared (blue "Cleared" using clear_local_state_done)
///                    for explicit confirmation of the completed reset. The blocker lives ONLY in the
///                    `.cleared` PlaybackIntent (checked in canProceedWithPlayback, play guards, etc.).
///                    Language selector is reseeded to a clean initial locale. This is a hard
///                    resurrection blocker (via intent). Only an explicit user play action clears it
///                    (and transitions visual to .prePlay on the way to playing). On next launch
///                    (no snapshot) the app starts fresh with .prePlay visual.
enum PlaybackIntent: Codable, Equatable, Hashable, Sendable {
    case shouldBePlaying
    case shouldBePaused
    case userPaused
    case sleepTimer
    case securityLocked
    case cleared
}

extension PlaybackIntent {
    /// True when the user still wants audio playing (normal play or active sleep-timer countdown).
    var isActivePlaybackIntent: Bool {
        self == .shouldBePlaying || self == .sleepTimer
    }

    /// Sticky blockers that only an explicit user play may clear.
    /// Includes .cleared for the privacy "Clear local playback state" path so that
    /// all DirectStreamingPlayer recovery / proceed guards treat it as a hard stop.
    var isStickyPauseOrLock: Bool {
        self == .userPaused || self == .securityLocked || self == .cleared
    }
}

// MARK: - PlayerEvent (canonical vocabulary for gradual event-driven migration)
//
// This is the **first step** of the long-term refactor toward a purely event-driven
// architecture in which nothing is forced and all significant state transitions and
// side effects are expressed by emitting `PlayerEvent` values.
//
// Strategy for non-forcing migration:
// - Implementation note: Introduce the shared vocabulary only. No emission sites,
//   no observers, no call-site changes. Existing imperative paths (direct calls to
//   play/pause/stop inside SharedPlayerManager, DirectStreamingPlayer, ViewController,
//   widget intents, etc.) continue to operate exactly as before.
// - Future changes: Instrument a single emission point at a time (e.g. inside
//   updatePlaybackIntent, inside persistWidgetSnapshot, inside metadata handlers),
//   then add narrow observers, then (much later) retire direct mutation sites behind
//   the event bus. Each step is independently reviewable, testable, and rollback-safe.
// - Benefit: decouples producers from consumers (widgets, Live Activities, Now Playing,
//   coordinators, analytics), improves testability (replay sequences of events), and
//   guarantees consistent snapshot derivation for all surfaces from a single event log.
//
// Why these cases: they mirror the high-signal transitions that today are performed
// through direct property sets, method calls, and multiple save paths. By naming them
// explicitly we create the extension point without changing any behavior.
//
// Invariants:
// - `PlayerEvent` is a pure vocabulary type. It carries no side effects.
// - All associated values use existing SSOT types only.
// - `PlayerEvent` lives in the cross-target shared file alongside `PlaybackIntent`
//   and `PlayerVisualState` so both main app and widget/LA surfaces see the same cases.
// - This file still contains *no* security logic.
//
// - SeeAlso: PlaybackIntent, PlayerVisualState, SharedPlayerManager, PersistedWidgetState,
//   StreamProgramMetadata, CODING_AGENT.md (event-driven direction, Single Source of Truth,
//   cross-target shared files), docs/ (Living-Media-Surfaces-and-Now-Playing-Prompt.md and
//   widget dataflow docs for context on why decoupling matters).
//
// AGENT NOTE: `PlayerEvent` is the Single Source of Truth for player-domain events.
// Future extensions must preserve Sendable + Hashable + Equatable. When adding cases,
// document the "why this event" rationale and ensure any payload type is itself
// Sendable/Hashable/Equatable and already visible to both app and widget targets.

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
enum PlayerEvent: Sendable, Hashable, Equatable {
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
    case streamDidFail(DirectStreamingPlayer.StreamErrorType)

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
struct PlayerCurrentState: Sendable, Equatable, Hashable {
    /// Current visual state (drives colors, glyphs, resurrection policy, and
    /// presentation derivations).
    let visualState: PlayerVisualState

    /// Authoritative playback intent (the SSOT answering "does the user want audio playing?").
    let playbackIntent: PlaybackIntent

    /// Latest program metadata parsed from the stream, if present.
    let streamMetadata: StreamProgramMetadata?

    /// Whether the current state reflects a permanent error (security lock or
    /// persisted hasError flag).
    let hasError: Bool

    // MARK: - Convenience accessors (derived, zero-cost)

    /// True when audio is actively flowing.
    ///
    /// Delegates to `PlayerVisualState.isActivelyPlaying` for semantic consistency
    /// with resurrection guards, LIVE indicators, and control glyph decisions.
    var isActivelyPlaying: Bool {
        visualState.isActivelyPlaying
    }

    /// True when the current intent is a sticky blocker that only an explicit
    /// user play action can clear.
    ///
    /// Delegates to `PlaybackIntent.isStickyPauseOrLock`. Useful for late
    /// subscribers that need to decide whether to show blocked UI without
    /// re-reading the raw intent.
    var isBlockedByStickyIntent: Bool {
        playbackIntent.isStickyPauseOrLock
    }

    /// True when a permanent error condition is present (security failure or
    /// unrecoverable stream failure persisted in the widget snapshot).
    ///
    /// Equivalent to `hasError`. Provided for naming symmetry with
    /// `DirectStreamingPlayer.StreamErrorType.isPermanent` and consumer code
    /// that talks about "permanent error" vs transient.
    var isInPermanentError: Bool {
        hasError
    }
}

// MARK: - PlayerVisualState (existing visual + legacy intent surface)

/// Single source of truth for playback UI **and** intent.
///
/// - prePlay:        yellow, auto-plays on first launch only (or post stream switch)
/// - cleared:        blue "Cleared", shown immediately after successful privacy "Clear local state".
///                   Distinct confirmation that reset completed. The actual blocker is the
///                   companion `.cleared` PlaybackIntent (see above). Behaves like .prePlay for
///                   readiness (shouldAutoPlayOrResume) but provides explicit post-reset visual.
/// - playing:        green
/// - userPaused:     grey, NEVER auto-resumes
/// - thermalPaused:  amber, device is overheating (blocks auto-resume)
/// - securityLocked: red
///
/// This version makes .userPaused "sticky" after any manual interaction.
enum PlayerVisualState: Codable, Equatable, Hashable, Sendable {
    
    case prePlay            // Initial load / connecting / never played yet → yellow
    case cleared            // Post "Clear local state" (privacy reset) → blue "Cleared"; ready state + intent blocker
    case playing            // Actively playing → green
    case userPaused         // Explicit user pause/stop → grey (sticky)
    case thermalPaused      // Device overheating → amber/orange warning
    case securityLocked     // Security / certificate failure → red
    
    // MARK: - Visual properties
    
    var backgroundColor: UIColor {
        switch self {
        case .prePlay:        return .systemYellow
        case .cleared:        return .systemBlue
        case .playing:        return .systemGreen
        case .userPaused:     return .systemGray
        case .thermalPaused:  return .systemOrange
        case .securityLocked: return .systemRed
        }
    }
    
    var textColor: UIColor {
        switch self {
        case .prePlay, .userPaused, .playing, .thermalPaused:
            return .label
        case .cleared, .securityLocked:
            return .white
        }
    }
    
    var buttonTintColor: UIColor {
        switch self {
        case .prePlay:        return .systemYellow
        case .cleared:        return .systemBlue
        case .playing:        return .systemGreen
        case .userPaused:     return .secondaryLabel
        case .thermalPaused:  return .systemOrange
        case .securityLocked: return .systemRed
        }
    }

    // NOTE (presentation vs policy):
    // `buttonTintColor` (and `backgroundColor`/`textColor`) are the legacy UIColor
    // surface. Widget + Live Activity control presentation now derives once via
    // `makeControlPresentation()` which returns SwiftUI Color + glyph. Direct reads
    // of buttonTintColor for play/pause tinting are being replaced by the narrow type.
    // Non-control uses (e.g. radio glyph in leading region) may continue to read it.
    
    // MARK: - Semantic properties
    
    /// True only when audio is actively playing.
    ///
    /// This is a *semantic* / policy property, not a presentation helper.
    /// It is intentionally retained on `PlayerVisualState` for:
    /// - Resurrection and auto-play guards
    /// - LIVE indicator visibility and animation presence in widgets / Live Activities
    /// - Intent decisions inside AppIntent handlers (WidgetToggleRadioIntent, etc.)
    ///
    /// Pure glyph choice ("play.fill" vs "pause.fill") and tint application for the
    /// control *button itself* should use `makeControlPresentation()` instead.
    /// See the widget and Live Activity migration for the narrow pattern.
    ///
    /// - SeeAlso: ``makeControlPresentation()``, ``shouldAutoPlayOrResume``,
    ///   CODING_AGENT.md (isActivelyPlaying may remain for semantic decisions).
    var isActivelyPlaying: Bool {
        self == .playing
    }
    
    /// Single source of truth.
    /// Returns false for .userPaused and .error — this blocks ALL resurrection paths
    /// (viewDidAppear, completeStreamSwitch, widget callbacks, etc.)
    /// .cleared returns true (ready) because the blocker is carried exclusively by PlaybackIntent.cleared.
    var shouldAutoPlayOrResume: Bool {
        switch self {
        case .prePlay, .cleared, .playing:
            return true
        case .userPaused, .thermalPaused, .securityLocked:
            return false
        }
    }
    
    var shouldAutoResumeOnThermalRecovery: Bool {
        self == .thermalPaused
    }
    
    var mustSuppressResurrection: Bool {
        self == .userPaused || self == .securityLocked
    }
}

// MARK: - Stop Reason

/// Why we are stopping playback.
/// This lets us preserve user intent during stream switches
/// instead of blindly setting `.userPaused`.
enum StopReason {
    case userAction          // explicit pause button → become sticky .userPaused
    case streamSwitch        // language change → keep playing intent
    case interruption        // background / call / AirPlay / sleep timer / etc.
    case error               // security failure, network loss, etc.
}

/// How `DirectStreamingPlayer` should attach or resume the secured `AVPlayerItem`.
enum PlaybackAttachContext: Sendable, Equatable {
    case coldLaunch
    case streamSwitch
    case resume
}

// MARK: - State mapping

extension PlayerVisualState {
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

    // MARK: - Presentation mapping (pure, for SwiftUI + widgets)

    /// Returns a narrow `PlayerStatusPresentation` derived from this visual state.
    ///
    /// This is the single canonical place that maps `PlayerVisualState` cases to
    /// SwiftUI colors, localized status text, and an optional system image.
    ///
    /// Status presentation is the "indicator" axis (pill / caption text + background).
    /// See the sibling `makeControlPresentation()` for the orthogonal "primary action
    /// affordance" axis (play/pause glyph + tint).
    ///
    /// - Important: Keep `PlayerVisualState` focused on policy and semantics
    ///   (resurrection, auto-play, sticky pauses). Presentation details live here.
    /// - Returns: A value-type struct suitable for direct use as a SwiftUI view input.
    /// - Note: Uses the same localized keys as `PlaybackControlsView` so all 21 languages stay in sync.
    /// - SeeAlso: ``PlayerStatusPresentation``, ``makeControlPresentation()``,
    ///   ``PlayerControlPresentation``, ``PlayerViewModel/statusPresentation``,
    ///   `SimpleEntry.statusPresentation`, CODING_AGENT.md (cache derived values on @Observable,
    ///   narrow inputs for leaves, WidgetKit/ActivityKit snapshot constraints).
    func makeStatusPresentation() -> PlayerStatusPresentation {
        switch self {
        case .playing:
            return PlayerStatusPresentation(
                background: .green,
                foreground: .white,
                text: String(localized: "status_playing", table: "Localizable"),
                systemImage: "play.fill"
            )

        case .prePlay:
            return PlayerStatusPresentation(
                background: .yellow,
                foreground: .black,
                text: String(localized: "status_connecting", table: "Localizable"),
                systemImage: "play.circle"
            )

        case .cleared:
            return PlayerStatusPresentation(
                background: .blue,
                foreground: .white,
                text: String(localized: "clear_local_state_done", table: "Localizable"),
                systemImage: nil
            )

        case .userPaused:
            return PlayerStatusPresentation(
                background: .gray,
                foreground: .white,
                text: String(localized: "status_paused", table: "Localizable"),
                systemImage: "pause.fill"
            )

        case .thermalPaused:
            return PlayerStatusPresentation(
                background: .orange,
                foreground: .white,
                text: String(localized: "status_thermal_paused", table: "Localizable"),
                systemImage: "pause.fill"
            )

        case .securityLocked:
            return PlayerStatusPresentation(
                background: .red,
                foreground: .white,
                text: String(localized: "status_security_failed", table: "Localizable"),
                systemImage: "lock.fill"
            )
        }
    }

    // MARK: - Control presentation mapping (pure, for widgets + Live Activities)

    /// Returns a narrow `PlayerControlPresentation` derived from this visual state.
    ///
    /// This is the single canonical mapper for the play/pause control glyph and its tint.
    /// It is the control-axis counterpart to `makeStatusPresentation()`.
    ///
    /// - Returns: A minimal Equatable value type carrying only `systemImage` ("play.fill"/"pause.fill")
    ///   and `tint` (as SwiftUI Color). Suitable for direct consumption by widget buttons,
    ///   Dynamic Island region closures, Lock Screen Live Activity controls, and the Control widget.
    /// - Precondition: Called on any `PlayerVisualState`; always produces a defined presentation.
    /// - Note: The glyph choice is deliberately based on `isActivelyPlaying` (the semantic
    ///   "audio is flowing" flag) so that the affordance matches user expectation:
    ///   actively playing → pause control visible; otherwise → play control.
    ///   Tint comes from the existing `buttonTintColor` policy (yellow/green/gray/blue/red...).
    /// - Complexity: O(1) switch + Color(uiColor:) conversion.
    /// - SeeAlso: ``PlayerControlPresentation``, ``PlayerStatusPresentation``,
    ///   ``makeStatusPresentation()``, `SimpleEntry` (receives the pre-derived value in providers),
    ///   `LutheranRadioWidgetLiveActivityWidget` (derives once per DynamicIsland / LockScreen),
    ///   CODING_AGENT.md (narrow inputs, value-type snapshot comparison cost,
    ///   "Pass views only the data they read"), WidgetDisplayModels.swift.
    ///
    /// AGENT NOTE: This is the Single Source of Truth for control glyph + tint decisions.
    /// Do not duplicate the mapping logic in view bodies, region builders, or WidgetDisplayModels.
    /// All play/pause `Image(systemName:)` + tint decisions for widgets, Live Activities,
    /// and the Control widget must flow through `makeControlPresentation()`.
    func makeControlPresentation() -> PlayerControlPresentation {
        let imageName = isActivelyPlaying ? "pause.fill" : "play.fill"
        // Use explicit UIColor initializer so the conversion is visible and consistent
        // with the UIColor-based policy properties on PlayerVisualState. The resulting
        // Color is stored in the narrow type so repeated bridging is avoided in bodies.
        let tint = Color(uiColor: buttonTintColor)
        return PlayerControlPresentation(systemImage: imageName, tint: tint)
    }
}
