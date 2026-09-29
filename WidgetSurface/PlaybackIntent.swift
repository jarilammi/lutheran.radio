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
///
/// ``resume`` is a same-stream attach that still holds a secured item path the caller
/// chose not to treat as a fresh mount (warm cluster reuse, no startup safety net).
/// ``freshAttachAfterHardTeardown`` is Play after user pause or a paused station
/// switch already cleared the item (`isSoftPaused == false`, attached language nil).
/// That mount schedules the same first-attach recovery as ``coldLaunch`` and
/// ``streamSwitch`` (startup safety net + head-start kick) and does **not** use the
/// same-stream warm window. It is not a stream-switch hold: it does not set
/// `holdPrePlayVisualUntilPlayback` and does not clear ICY again.
///
/// - SeeAlso: ``PlaybackPlayDecision/attachContext(classification:declinedSoftPauseForLanguageChange:freshAttachAfterHardTeardown:)``,
///   ``schedulesFirstAttachRecovery``,
///   docs/cold-launch-streamplay-regression-checklist.md (§4, §5),
///   docs/Live-Activity-Stacking-and-Media-Surfaces.md (explicit Play visual)
@frozen public enum PlaybackAttachContext: Sendable, Equatable {
    case coldLaunch
    case streamSwitch
    case resume
    /// Play classified as resume, but no retained soft-paused item survived the teardown.
    case freshAttachAfterHardTeardown

    /// Startup safety net and the post-head-start kick run for this attach.
    ///
    /// Soft-pause resume never reaches ``DirectStreamingPlayer/attachAndPlay(to:context:)``.
    /// ``resume`` must not schedule a stale recreate of an item that is already secured.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/scheduleStartupSafetyNet()``,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§4.5, §11.3).
    public var schedulesFirstAttachRecovery: Bool {
        switch self {
        case .coldLaunch, .streamSwitch, .freshAttachAfterHardTeardown:
            return true
        case .resume:
            return false
        }
    }

    /// Same-process warm cluster reuse (beyond the 10 s throttle) is only for ``resume``.
    ///
    /// Fresh attach, cold launch, and stream switch still attach immediately on
    /// default/last-good and may start a background ping. They do not block the first
    /// byte on a new ping pair.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/shouldReuseCachedServerSelection(lastSelectionAge:allowSameStreamWarmReuse:)``,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§5).
    public var allowsSameStreamWarmClusterReuse: Bool {
        self == .resume
    }
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
/// Audible attach is always ``DirectStreamingPlayer/attachAndPlay(to:context:)``.
///
/// - SeeAlso: ``PlaybackAttachContext``, ``PlaybackPlayDecision``,
///   SharedPlayerManager.play(), RadioPlayerCoordinator stream-switch paths.
@frozen public enum StreamChoicePreparation: Sendable, Equatable {
    /// Update selected stream model only (no secured item, no silent stop).
    case modelOnly
    /// Full switch prep: model, silent `.streamSwitch` stop when language changes, counter reset.
    case switchPrep
}
