//
//  DirectStreamingPlayer+ThermalProtection.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 25.7.2026.
//
//  Engine-owned thermal state and Low Power Mode observation for streaming safety.
//  Pauses audible playback under serious/critical thermal pressure, auto-resumes when
//  cooled (via SharedPlayerManager visual SSOT), and logs Low Power Mode transitions
//  while retry/fallback paths query ``isLowEfficiencyMode`` dynamically.
//
//  Behavior-preserving domain split from DirectStreamingPlayer.swift.
//  DirectStreamingPlayer remains the public engine façade; this file owns one domain.
//
//  Ownership (do not invert):
//  - This domain owns **thermal pause/resume observation** (``setupThermalProtection()``)
//    and **Low Power Mode observation** (``setupEnergyEfficiencyObservation()``).
//  - Stored `thermalObserver` and computed ``isLowEfficiencyMode`` live on the façade
//    class body (extensions cannot declare stored properties).
//  - Visual SSOT for `.thermalPaused` / recovery chrome remains ``SharedPlayerManager``;
//    this domain only *sets* visual state and calls engine ``play()`` / ``stop()``.
//  - Persistence must not write durable `.thermalPaused` (see
//    `SharedPlayerManager+Persistence` thermal sanitization).
//
//  Process invariants:
//  - Thermal recovery auto-play is gated by
//    ``PlayerVisualState/shouldAutoResumeOnThermalRecovery`` on the actor.
//  - Low Power Mode changes do not interrupt playback; they only affect dynamically
//    queried delays (server selection, recovery, buffer timers).
//  - Teardown via ``teardownThermalAndEnergyObservers()`` from
//    ``performDeinitCleanup()`` (façade `deinit` path) only.
//
//  AGENT NOTE: Members used across files are `internal` (Swift `private` is
//  file-scoped). Prefer this domain file over re-implementing ProcessInfo observers
//  in call sites. Do not mix play/stop entry surgery into this domain peel.
//
//  - SeeAlso: DirectStreamingPlayer.swift, SharedPlayerManager+Persistence (thermal
//    sanitization), SharedPlayerManager+PlaybackPipeline (thermal play gates),
//    PlayerVisualState.thermalPaused, CODING_AGENT.md (Single Source of Truth Principles).
//

import Foundation

// MARK: - Thermal protection & energy efficiency observation

extension DirectStreamingPlayer {

    /// Registers `ProcessInfo.thermalStateDidChangeNotification` on the main queue.
    ///
    /// Under `.serious` / `.critical` thermal pressure while audible, stops playback and
    /// publishes ``PlayerVisualState/thermalPaused``. When the device returns to
    /// `.nominal` / `.fair` and visual policy allows auto-resume, sets `.playing` then
    /// calls ``play()`` (falling back to `.userPaused` if attach fails).
    ///
    /// Stored token: ``thermalObserver`` on the façade. Pair with
    /// ``teardownThermalAndEnergyObservers()`` via ``performDeinitCleanup()``.
    ///
    /// - SeeAlso: ``PlayerVisualState/shouldAutoResumeOnThermalRecovery``,
    ///   `SharedPlayerManager.isDeviceThermallyStressed()`
    func setupThermalProtection() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }

            let thermalState = ProcessInfo.processInfo.thermalState

            // ── Device overheating ─────────────────────────────────────
            if thermalState == .serious || thermalState == .critical {
                if self.isPlaying {
                    Task { @MainActor in
                        self.stop()                                 // sync
                        await SharedPlayerManager.shared.setVisualState(.thermalPaused)
                    }
                }
                return
            }

            // ── Device cooled down again ───────────────────────────────
            if thermalState == .nominal || thermalState == .fair {
                Task { @MainActor in
                    // Must await actor-isolated property (Swift 6 rule)
                    if await SharedPlayerManager.shared.currentVisualState.shouldAutoResumeOnThermalRecovery {
                        // Set visual state *before* play() so UI turns green immediately
                        await SharedPlayerManager.shared.setVisualState(.playing)

                        let success = await self.play()

                        if !success {
                            await SharedPlayerManager.shared.setVisualState(.userPaused)
                        }
                    }
                }
            }
        }
    }

    /// Observes Low Power Mode transitions so DEBUG logs surface changes.
    ///
    /// No immediate playback action: ``isLowEfficiencyMode`` is queried dynamically in
    /// retry / fallback / buffer-timer paths. Call from DI-style inits that inject
    /// dependencies; the production `shared` designated init historically registers
    /// thermal only (behavior preserved).
    ///
    /// - SeeAlso: ``isLowEfficiencyMode``, ``teardownThermalAndEnergyObservers()``
    func setupEnergyEfficiencyObservation() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(energyEfficiencyChanged),
            name: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"),
            object: nil
        )
    }

    /// Handles changes to Low Power Mode state.
    ///
    /// No immediate actions; optimizations (e.g. longer retry intervals) apply via
    /// ``isLowEfficiencyMode`` checks on demand. Reduces unnecessary work in low-battery
    /// scenarios without interrupting core streaming.
    @objc private func energyEfficiencyChanged() {
        // No immediate action needed; the isLowEfficiencyMode property will be queried dynamically in retry/fallback spots
        #if DEBUG
        print("[DirectStreamingPlayer] Low Power Mode changed to: \(isLowEfficiencyMode ? "Enabled" : "Disabled")")
        #endif
    }

    /// Removes thermal and Low Power Mode observers. Call only from ``performDeinitCleanup()``.
    ///
    /// - Postcondition: ``thermalObserver`` is nil; LPM selector observer detached.
    /// - SeeAlso: ``performDeinitCleanup()`` in `DirectStreamingPlayer+DeinitHygiene.swift`.
    func teardownThermalAndEnergyObservers() {
        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
            thermalObserver = nil
        }
        NotificationCenter.default.removeObserver(
            self,
            name: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"),
            object: nil
        )
    }
}
