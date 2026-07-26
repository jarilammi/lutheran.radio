//
//  DirectStreamingPlayer+SystemMediaSession.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.7.2026.
//
//  Engine-owned hard detach of the secured AVPlayerItem for privacy clear, cold-launch
//  factory reset, and session teardown. Complements SharedPlayerManager Now Playing
//  metadata clear (`teardownNowPlayingSession` / `MPNowPlayingInfoCenter`).
//
//  Behavior-preserving domain split from DirectStreamingPlayer.swift.
//  DirectStreamingPlayer remains the public engine façade; this file owns one domain.
//
//  Ownership (do not invert):
//  - This domain owns **hard player-item detach** for system media session hygiene:
//    ``teardownSystemMediaSessionSynchronously()`` and ``teardownSystemMediaSession()``.
//  - Soft-pause / hard-stop *playback* paths remain in `+PlaybackControl.swift`
//    (``stop`` / ``performActualStop`` / ``stopSynchronously``). Those preserve recovery
//    affordances; this domain is the privacy / factory-reset detach that nils the item.
//  - Audio session deactivate remains in `+AudioSession.swift` — async teardown calls
//    ``deactivateAudioSessionAsync()`` only; never `setCategory` / `setActive` here.
//  - Now Playing *metadata* clear (`MPNowPlayingInfoCenter`) remains on
//    ``SharedPlayerManager`` (`teardownNowPlayingSession` / clear helpers). This domain
//    only detaches the engine item so MediaRemote has no live player binding.
//  - Player / item storage and soft-pause flags remain on the façade class body
//    (extensions cannot declare stored properties).
//
//  Process invariants:
//  - No-op under UITestMode / `isTesting` (privacy teardown must not touch AVFoundation
//    under the XCTest host isolation contract).
//  - Synchronous path: pause → rate 0 → replace item nil → clear binding → clear soft-pause.
//  - Async path: synchronous detach then session deactivate (watchdog-safe ordering owned
//    by SPM callers that may skip deactivate on terminate paths).
//
//  AGENT NOTE: Members used across files are `internal` (Swift `private` is file-scoped).
//  Prefer this domain file over re-implementing hard detach in privacy / factory-reset
//  call sites. Do not mix play/stop entry surgery or deinit hygiene into this domain peel.
//  Façade `deinit` stays on the primary type body (Swift requirement) and uses stop/
//  thermal/session teardown helpers — not these privacy detach entrypoints.
//
//  - SeeAlso: DirectStreamingPlayer.swift, DirectStreamingPlayer+AudioSession.swift,
//    DirectStreamingPlayer+PlaybackControl.swift, DirectStreamingPlayer+PlaybackAttach.swift
//    (``clearAttachedItemBinding()``), SharedPlayerManager.teardownNowPlayingSession(),
//    docs/Live-Activity-Stacking-and-Media-Surfaces.md,
//    docs/Event-Driven-Refactor-Roadmap.md (session teardown phases),
//    CODING_AGENT.md (Single Source of Truth Principles).
//

import Foundation
@unsafe @preconcurrency import AVFoundation

// MARK: - System media session teardown (Now Playing hygiene)

extension DirectStreamingPlayer {

    /// Hard-detaches the secured `AVPlayerItem` for privacy / cold-launch factory reset.
    ///
    /// Complements ``SharedPlayerManager/teardownNowPlayingSession()`` which clears
    /// `MPNowPlayingInfoCenter`. Safe when playback is already stopped or during privacy clear.
    ///
    /// - Postcondition: Player paused, current item nil, soft-pause stash cleared.
    /// - SeeAlso: ``teardownSystemMediaSession()``, ``deactivateAudioSessionAsync()``,
    ///   ``clearAttachedItemBinding()``.
    @MainActor
    func teardownSystemMediaSessionSynchronously() {
        guard !isTesting else { return }

        player?.pause()
        player?.rate = 0.0
        player?.replaceCurrentItem(with: nil)
        playerItem = nil
        clearAttachedItemBinding()
        isSoftPaused = false
    }

    /// Full async teardown: synchronous player detach plus audio session deactivation.
    ///
    /// - SeeAlso: ``SharedPlayerManager/teardownNowPlayingSession()``,
    ///   ``teardownSystemMediaSessionSynchronously()``, ``deactivateAudioSessionAsync()``.
    @MainActor
    func teardownSystemMediaSession() async {
        teardownSystemMediaSessionSynchronously()
        _ = await deactivateAudioSessionAsync()
    }
}
