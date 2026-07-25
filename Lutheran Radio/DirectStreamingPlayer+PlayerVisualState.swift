//
//  DirectStreamingPlayer+PlayerVisualState.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 24.7.2026.
//
//  Thin bridge from the streaming engine into SharedPlayerManager for auto-resume checks
//  and pause/playing marks. This file does **not** store visual or intent SSOT — it only
//  forwards to the actor (`setUserPaused`, publish-playing helpers, `canProceedWithPlayback`).
//
//  Behavior-preserving domain split from DirectStreamingPlayer.swift.
//  DirectStreamingPlayer remains the public engine façade; this file owns one domain.
//
//  AGENT NOTE: Members used across files are `internal` (Swift `private` is
//  file-scoped). Prefer this domain file over re-implementing attach / recovery
//  / catalog logic in call sites. Never treat these helpers as a second visual store.
//
//  - SeeAlso: DirectStreamingPlayer.swift, SharedPlayerManager,
//    CODING_AGENT.md (Single Source of Truth Principles).
//

import Foundation
import WidgetSurface

// MARK: - PlayerVisualState Integration

extension DirectStreamingPlayer {

    /// Returns whether we are allowed to automatically start or resume playback
    /// according to the user's explicit intent stored in SharedPlayerManager.
    ///
    /// Now delegates to the authoritative playback intent helper
    /// instead of deriving from visualState. This makes Direct consistent with its
    /// internal guards.
    var shouldAutoPlayOrResume: Bool {
        get async {
            await SharedPlayerManager.shared.canProceedWithPlayback()
        }
    }

    /// Marks the current intent as user-initiated pause.
    /// This should be called from all user-facing pause paths (button, widget, remote commands, Darwin notifications, etc.).
    func markAsUserPaused() async {
        await SharedPlayerManager.shared.setUserPaused()
        
        #if DEBUG
        print("[DirectStreamingPlayer] markAsUserPaused() called – currentVisualState = .userPaused")
        #endif
    }

    /// Marks the current intent as actively playing.
    /// Call this after a successful manual play or auto-resume (e.g. after AVPlayer starts with rate == 1.0).
    ///
    /// Prefers the same deduped path as readyToPlay / soft-resume so interruption resume cannot
    /// double-emit `streamDidStart` when chrome is already `.playing`.
    func markAsPlaying() async {
        await publishAuthoritativePlayingIfNeeded()
        
        #if DEBUG
        print("[DirectStreamingPlayer] ▶ markAsPlaying() called – currentVisualState = .playing (or already was)")
        #endif
    }
}
