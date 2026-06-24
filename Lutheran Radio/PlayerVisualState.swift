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
//   CODING_AGENT.md (Single Source of Truth Principles, "Cross-target shared
//   source files (non-Core)", Documentation & Comment Standards),
//   WidgetDisplayModels.swift (the parallel metadata/emphasis axis),
//   README.md (Single Sources of Truth table).
// - AGENT NOTE: Any change to these enums or their semantics must also update
//   the resurrection tables and guards inside SharedPlayerManager.swift.

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
struct PlayerControlPresentation: Equatable {
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
enum PlaybackIntent: Codable, Equatable {
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
enum PlayerVisualState: Codable, Equatable {
    
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
    func makeControlPresentation() -> PlayerControlPresentation {
        let imageName = isActivelyPlaying ? "pause.fill" : "play.fill"
        // Use explicit UIColor initializer so the conversion is visible and consistent
        // with the UIColor-based policy properties on PlayerVisualState. The resulting
        // Color is stored in the narrow type so repeated bridging is avoided in bodies.
        let tint = Color(uiColor: buttonTintColor)
        return PlayerControlPresentation(systemImage: imageName, tint: tint)
    }
}
