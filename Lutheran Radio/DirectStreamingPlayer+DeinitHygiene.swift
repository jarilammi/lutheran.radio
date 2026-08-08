//
//  DirectStreamingPlayer+DeinitHygiene.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.7.2026.
//
//  Engine-owned teardown helpers invoked from façade `deinit` and privacy-adjacent
//  callback clearing. Keeps synchronous deallocation hygiene out of the primary type
//  body while leaving Swift `deinit` itself on the class (language requirement).
//
//  Behavior-preserving domain split from DirectStreamingPlayer.swift.
//  DirectStreamingPlayer remains the public engine façade; this file owns one domain.
//
//  Ownership (do not invert):
//  - This domain owns **callback clearing** (``clearCallbacks()``) and the **ordered
//    deallocation cleanup sequence** (``performDeinitCleanup()``).
//  - Swift `deinit` remains on the primary type body and must only: set
//    ``isDeallocating``, then call ``performDeinitCleanup()``. Do not re-expand cleanup
//    inline on the façade.
//  - Playback stop implementation remains in `+PlaybackControl.swift`
//    (``stopSynchronously()``). This domain only *calls* it.
//  - Thermal / energy observer teardown remains in `+ThermalProtection.swift`
//    (``teardownThermalAndEnergyObservers()``).
//  - Audio interruption observer removal remains in `+AudioSessionInterruption.swift`
//    (``removeAudioSessionObservers()``).
//  - Periodic certificate validation timer clear remains in
//    `+PeriodicCertificateValidation.swift` (``stopPeriodicCertificateValidation()``).
//  - Network monitor cancel uses façade-stored `networkMonitor` (setup lives in
//    `+NetworkPath.swift`).
//  - Stored flags (`isDeallocating`, work items, observations, failure maps) remain on
//    the façade class body (extensions cannot declare stored properties).
//
//  Process invariants:
//  - Cleanup is fully synchronous (safe under `deinit`; no Task / async / MainActor hop).
//  - ``isDeallocating`` must already be `true` before ``performDeinitCleanup()`` so stop
//    and observer paths short-circuit rather than re-entering async teardown.
//  - Order matters: cancel work items → synchronous stop → invalidate observations →
//    clear callbacks → cancel path monitor → clear metadata/server maps → thermal +
//    interruption + periodic certificate validation timer.
//    Do not reorder without re-auditing retain cycles and AVPlayer observer detach.
//  - No adaptive connect-time handshake budget remains on the engine (former
//    `+SSLProtection` setup had zero callers; do not reintroduce).
//
//  AGENT NOTE: Members used across files are `internal` (Swift `private` is file-scoped).
//  Prefer this domain over re-implementing deallocation sequences in privacy clear or
//  coordinator teardown. Do not mix play/stop entry surgery or audio-session configure
//  into this domain peel.
//
//  - SeeAlso: DirectStreamingPlayer.swift (isolation map, façade `deinit`),
//    DirectStreamingPlayer+PlaybackControl.swift (``stopSynchronously()``),
//    DirectStreamingPlayer+ThermalProtection.swift,
//    DirectStreamingPlayer+AudioSessionInterruption.swift,
//    DirectStreamingPlayer+PeriodicCertificateValidation.swift,
//    DirectStreamingPlayer+NetworkPath.swift,
//    CODING_AGENT.md (Single Source of Truth Principles).
//

import Foundation
@unsafe @preconcurrency import AVFoundation

// MARK: - Callback / deinit hygiene

extension DirectStreamingPlayer {

    /// Nils status, metadata, network-path, and delegate callbacks to break retain cycles.
    ///
    /// Called from ``performDeinitCleanup()`` and available for privacy / test isolation
    /// paths that must drop engine callbacks without full deallocation.
    ///
    /// - Postcondition: ``onStatusChange``, ``onMetadataChange``, ``onNetworkPathChange``,
    ///   and ``delegate`` are `nil`.
    /// - SeeAlso: ``performDeinitCleanup()``
    func clearCallbacks() {
        onStatusChange = nil
        onMetadataChange = nil
        onNetworkPathChange = nil
        delegate = nil
    }

    /// Ordered synchronous teardown for façade deallocation.
    ///
    /// - Precondition: ``isDeallocating`` is already `true` (set by façade `deinit`).
    /// - Postcondition: Pending work items cancelled; player stopped via
    ///   ``stopSynchronously()``; observations invalidated; callbacks cleared; network
    ///   monitor cancelled; thermal/interruption/periodic-cert timers torn down.
    /// - Important: Must remain fully synchronous — Swift `deinit` cannot await.
    /// - SeeAlso: Façade `deinit` on ``DirectStreamingPlayer``, ``clearCallbacks()``,
    ///   ``stopSynchronously()``, ``teardownThermalAndEnergyObservers()``,
    ///   ``removeAudioSessionObservers()``, ``stopPeriodicCertificateValidation()``.
    func performDeinitCleanup() {
        // Cancel pending server-selection work
        serverSelectionWorkItem?.cancel()

        #if DEBUG
        print("[DirectStreamingPlayer] [Deinit] Cancelled pending work items")
        #endif

        // Stop synchronously to avoid async cleanup during deallocation
        stopSynchronously()

        playerItemObservations.forEach { $0.invalidate() }
        playerItemObservations.removeAll()

        // Clear all callbacks to prevent retention cycles
        clearCallbacks()

        // Cancel network monitoring
        networkMonitor?.cancel()
        networkMonitor = nil

        // Clear metadata output
        metadataOutput = nil

        // Thermal + Low Power Mode observers: +ThermalProtection.swift
        teardownThermalAndEnergyObservers()

        // Interruption/route observers + periodic Core pin timer
        removeAudioSessionObservers()
        stopPeriodicCertificateValidation()

        #if DEBUG
        print("[DirectStreamingPlayer] deinit completed")
        #endif
    }
}
