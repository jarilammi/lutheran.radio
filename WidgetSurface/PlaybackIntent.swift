//
//  PlaybackIntent.swift
//  WidgetSurface
//
//  Created by Jari Lammi on 23.7.2026.
//
//  User playback intent and related stop/attach policy enums.
//
//  WidgetSurface framework — presentation-only (no security logic).
//
//  Ownership:
//  - `PlaybackIntent` is written exclusively by `SharedPlayerManager`.
//  - Consumers (engine, UI, widget paths, remote commands) read intent via the actor
//    and never invent independent "should I play?" decisions.
//  - Complements ``PlayerVisualState`` (what the UI shows) with explicit play/pause intent.
//
//  Sticky resurrection blockers:
//  - Visual: `.userPaused`, `.securityLocked`
//  - Intent: `.userPaused`, `.securityLocked`, `.cleared`
//  Only explicit user play clears sticky blockers.
//
//  - SeeAlso: ``PlayerVisualState``, ``PlayerEvent``, `SharedPlayerManager`,
//    CODING_AGENT.md (Single Source of Truth Principles).
//  - AGENT NOTE: Any change to sticky semantics must also update the resurrection
//    tables and guards inside SharedPlayerManager.swift.
//

import Foundation

// MARK: - Playback Intent

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
public enum PlaybackIntent: Codable, Equatable, Hashable, Sendable {
    case shouldBePlaying
    case shouldBePaused
    case userPaused
    case sleepTimer
    case securityLocked
    case cleared
}

public extension PlaybackIntent {
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

// MARK: - Stop Reason

/// Why we are stopping playback.
/// This lets us preserve user intent during stream switches
/// instead of blindly setting `.userPaused`.
public enum StopReason: Sendable {
    case userAction          // explicit pause button → become sticky .userPaused
    case streamSwitch        // language change → keep playing intent
    case interruption        // background / call / AirPlay / sleep timer / etc.
    case error               // security failure, network loss, etc.
}

/// How `DirectStreamingPlayer` should attach or resume the secured `AVPlayerItem`.
@frozen public enum PlaybackAttachContext: Sendable, Equatable {
    case coldLaunch
    case streamSwitch
    case resume
}

/// How `DirectStreamingPlayer` prepares a stream choice **without** starting audible attach.
///
/// Canonical entry: ``DirectStreamingPlayer/prepareStreamChoice(_:preparation:)``.
/// Legacy wrappers (`setSelectedStreamModelOnly`, `switchToStream`) map to these cases.
///
/// | Case | Effect | Typical callers |
/// |------|--------|-----------------|
/// | ``modelOnly`` | Update `selectedStream` only (no item, no stop) | Cold-launch seed, snapshot alignment before attach |
/// | ``switchPrep`` | Model + silent stop on language change + recovery budget reset | Orchestrated language switch before play |
///
/// Audible attach is always ``DirectStreamingPlayer/attachAndPlay(to:context:)``
/// (legacy name: `setStreamAndPlay`).
///
/// - SeeAlso: ``PlaybackAttachContext``, ``PlaybackPlayDecision``,
///   SharedPlayerManager.play(), RadioPlayerCoordinator stream-switch paths.
@frozen public enum StreamChoicePreparation: Sendable, Equatable {
    /// Update selected stream model only (no secured item, no silent stop).
    case modelOnly
    /// Full switch prep: model, silent `.streamSwitch` stop when language changes, counter reset.
    case switchPrep
}
