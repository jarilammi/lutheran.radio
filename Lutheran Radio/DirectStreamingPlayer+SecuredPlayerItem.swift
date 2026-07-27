//
//  DirectStreamingPlayer+SecuredPlayerItem.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.7.2026.
//
//  Engine-owned secured AVPlayerItem construction for protected streaming HTTPS hosts
//  (preferredStreamingDomainSuffixes — today *.siikkari.net preferred).
//  Single owner for the Core-backed resource-loader path used by cold launch, stream
//  switch, soft recovery, and public createAndStartPlayer entrypoints.
//
//  Behavior-preserving domain split from DirectStreamingPlayer.swift.
//  DirectStreamingPlayer remains the public engine façade; this file owns one domain.
//
//  Ownership (do not invert):
//  - This domain owns **secured live item construction** (``makeSecuredPlayerItem(for:)``)
//    and **prepare-without-auto-play attach** (``preparePlayerItem(for:)``).
//  - Every attach / recovery / control path that needs a live stream item must call these
//    helpers — never construct a bare `AVURLAsset` without the resource-loader delegate.
//  - Resource-loader callbacks live in `+ResourceLoader.swift`; session URL security
//    (DNSSEC + runtime digest pins) is enforced via `StreamingSessionDelegate` + Core.
//  - Attach generation, soft-pause flags, and player/item storage remain on the façade
//    class body (extensions cannot declare stored properties).
//  - Public play/stop entry remains in `+PlaybackControl.swift`; generation-aware attach
//    remains in `+PlaybackAttach.swift`; silent recreate remains in `+PlayerItemRecovery.swift`.
//
//  Security invariant:
//  - Media bytes always load via `AVAssetResourceLoaderDelegate` → `StreamingSessionDelegate`
//    → ``SecurityConfiguration/makeSecureEphemeralConfiguration()``.
//  - Never bypass Core certificate / DNS policy from this domain or its callers.
//
//  Process invariants:
//  - ``preparePlayerItem(for:)`` clears the playback teardown guard and rebinds
//    item-language metadata for the selected stream before observers attach.
//  - Live buffer preference uses façade ``preferredLiveForwardBufferDuration``.
//
//  AGENT NOTE: Members used across files are `internal` (Swift `private` is file-scoped).
//  Prefer this domain file over re-implementing secured asset construction in call sites.
//  Do not mix play/stop entry surgery or audio-session category changes into this domain.
//
//  - SeeAlso: DirectStreamingPlayer.swift, DirectStreamingPlayer+ResourceLoader.swift,
//    DirectStreamingPlayer+PlaybackAttach.swift, DirectStreamingPlayer+PlayerItemRecovery.swift,
//    DirectStreamingPlayer+PlaybackControl.swift, StreamingSessionDelegate.swift,
//    Core/Configuration/SecurityConfiguration.swift, CODING_AGENT.md
//    (Core Framework Surface Area, Single Source of Truth Principles).
//

import Foundation
@unsafe @preconcurrency import AVFoundation
import Core

// MARK: - Secured player item construction

extension DirectStreamingPlayer {

    /// Builds a secured live `AVPlayerItem` for protected streaming HTTPS hosts.
    ///
    /// Every attach path (cold launch, stream switch, and silent transient recovery) must
    /// create items through this helper so media bytes always load via
    /// `AVAssetResourceLoaderDelegate` → `StreamingSessionDelegate` →
    /// ``SecurityConfiguration/makeSecureEphemeralConfiguration()`` (DNSSEC + runtime
    /// certificate digest validation). A bare `AVURLAsset(url:)` without the resource-loader
    /// delegate would bypass that pipeline.
    ///
    /// - Parameter url: Absolute HTTPS stream URL from ``urlWithOptimalServer(for:)`` (or the
    ///   current item’s URL during in-place recovery).
    /// - Returns: An `AVPlayerItem` with the resource loader wired and live buffer preference set.
    /// - SeeAlso: ``preparePlayerItem(for:)``, ``recreatePlayerItem()``,
    ///   `resourceLoader(_:shouldWaitForLoadingOfRequestedResource:)`,
    ///   `Core/Configuration/SecurityConfiguration.swift`, CODING_AGENT.md (Core surface area).
    @MainActor
    func makeSecuredPlayerItem(for url: URL) -> AVPlayerItem {
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: .main)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = preferredLiveForwardBufferDuration
        return item
    }

    /// Creates or replaces the current item via ``makeSecuredPlayerItem(for:)`` without auto-play.
    ///
    /// Used by stream-choice attach after server selection so observers bind before the
    /// generation-aware play kick. Does not call `play()` — callers own audible start.
    ///
    /// - Parameter url: Absolute HTTPS stream URL from ``urlWithOptimalServer(for:)``.
    /// - Postcondition: `player` / `playerItem` bound, teardown guard cleared, playback observers set.
    /// - SeeAlso: ``makeSecuredPlayerItem(for:)``, ``prepareStreamChoice(for:context:)``,
    ///   ``clearPlaybackTeardownGuard()``, ``setupPlaybackObservers()``.
    @MainActor
    func preparePlayerItem(for url: URL) async {
        let playerItem = makeSecuredPlayerItem(for: url)

        if self.player == nil {
            self.player = AVPlayer(playerItem: playerItem)
        } else {
            self.player?.replaceCurrentItem(with: playerItem)
        }
        self.playerItem = playerItem
        bindAttachedItemToSelectedStream()
        clearPlaybackTeardownGuard()

        setupPlaybackObservers()

        #if DEBUG
        print("[DirectStreamingPlayer] [MainActor] Player item prepared (no auto-play) for \(url.lastPathComponent)")
        #endif
    }
}
