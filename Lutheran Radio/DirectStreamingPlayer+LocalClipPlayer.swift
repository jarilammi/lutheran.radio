//
//  DirectStreamingPlayer+LocalClipPlayer.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 25.7.2026.
//
//  Engine-owned short local file-clip start (tuning / special cold-launch delight).
//  Configures the shared playback session via the audio-session domain, then constructs
//  and starts `AVAudioPlayer` off the main actor.
//
//  Behavior-preserving domain split from DirectStreamingPlayer.swift.
//  DirectStreamingPlayer remains the public engine façade; this file owns one domain.
//
//  Ownership (do not invert):
//  - This domain owns **local bundled-clip** construction and start after session config
//    (``startLocalClipPlayer(contentsOf:volume:numberOfLoops:)``).
//  - Session category / activate / deactivate remain in `+AudioSession.swift` — never call
//    `setCategory` / `setActive` from this file.
//  - Callers (`RadioPlayerCoordinator+Tuning`) retain the returned player and assign
//    `AVAudioPlayerDelegate` on the main actor after return.
//  - No stored state lives here (extensions cannot declare stored properties).
//
//  Process invariants:
//  - No-op under UITestMode / `isTesting` (returns `nil` without constructing a player).
//  - No-op in widget/extension (`.appex` path) — primary protection is membership exclusion;
//    path guard is defense-in-depth. Extension type surface: `+WidgetStub.swift`.
//
//  AGENT NOTE: Single source of truth for local file-clip start after session config.
//  Do not construct `AVAudioPlayer` + `prepareToPlay`/`play` on `@MainActor` for tuning
//  delight. Members used across files are `internal` (Swift `private` is file-scoped).
//
//  - SeeAlso: DirectStreamingPlayer.swift (isolation map), DirectStreamingPlayer+AudioSession.swift,
//    DirectStreamingPlayer+WidgetStub.swift, RadioPlayerCoordinator+Tuning.swift,
//    TuningSoundCoordinator, CODING_AGENT.md (Single Source of Truth Principles).
//

import Foundation
@unsafe @preconcurrency import AVFoundation

// MARK: - Local clip player (tuning / special sounds)

extension DirectStreamingPlayer {

    /// Configures the shared playback session, then constructs and starts a short local
    /// `AVAudioPlayer` clip **off the main actor**.
    ///
    /// Why this exists: ``configureAudioSessionAsync()`` already activates the session without
    /// blocking the main thread, but `AVAudioPlayer.prepareToPlay()` / `play()` can still
    /// perform an implicit session activation on the **calling** thread. Creating and starting
    /// the clip on a background queue keeps that implicit work off `@MainActor`, eliminating
    /// the SessionCore "UI unresponsiveness if called on the main thread" diagnostic on
    /// cold-launch special tuning and stream-switch tuning paths.
    ///
    /// AGENT NOTE: Single source of truth for local file-clip start after session config.
    /// Do not construct `AVAudioPlayer` + `prepareToPlay`/`play` on `@MainActor` for tuning
    /// delight. Never call `setActive` outside ``configureAudioSessionAsync()`` /
    /// ``deactivateAudioSessionAsync()``.
    ///
    /// - Parameters:
    ///   - url: File URL of a bundled clip (typically WAV).
    ///   - volume: Linear gain applied before start (`0...1`).
    ///   - numberOfLoops: `0` for one-shot (default).
    /// - Returns: The player plus whether `play()` returned true, or `nil` when skipped under
    ///   `isTesting` / widget extension. Callers must retain the player until finish/stop and
    ///   may assign `AVAudioPlayerDelegate` on the main actor after return.
    /// - Throws: Errors from `AVAudioPlayer(contentsOf:)`.
    /// - Precondition: Call from `@MainActor`. The returned player is delivered on the main
    ///   actor for retention and optional delegate assignment.
    /// - Postcondition: When non-`nil` and `didStart == true`, audio is already playing;
    ///   caller owns the strong reference.
    /// - SeeAlso: ``configureAudioSessionAsync()``,
    ///   ``RadioPlayerCoordinator/playSpecialTuningSound(completion:)``,
    ///   ``RadioPlayerCoordinator/playTuningSound(animateNeedleTo:)``,
    ///   `RadioPlayerCoordinator+Tuning.swift`, `TuningSoundCoordinator`.
    @MainActor
    func startLocalClipPlayer(
        contentsOf url: URL,
        volume: Float = 1.0,
        numberOfLoops: Int = 0
    ) async throws -> (player: AVAudioPlayer, didStart: Bool)? {
        if Bundle.main.bundleURL.pathExtension == "appex" {
            return nil
        }
        guard !isTesting else {
            #if DEBUG
            print("[DirectStreamingPlayer] startLocalClipPlayer — isTesting, skipping local clip")
            #endif
            return nil
        }

        // Explicit session SSOT first (async / off-main activate). Waits for any in-flight
        // factory-reset deactivate before setCategory. Local clip start below does not
        // re-enter setActive on the main actor.
        _ = await configureAudioSessionAsync()

        let clipURL = url
        let clipVolume = volume
        let clipLoops = numberOfLoops

        // SAFETY: `AVAudioPlayer` is not `Sendable`. Construction, prepare, and play run on a
        // background queue so any implicit session activation stays off the main thread; the
        // instance is then handed back only via the main queue continuation resume (same
        // ownership hand-off pattern as historical main-thread construction, without the
        // main-thread activation cost). A safer typed API is not available from AVFoundation.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(player: AVAudioPlayer, didStart: Bool)?, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let player = try AVAudioPlayer(contentsOf: clipURL)
                    player.volume = clipVolume
                    player.numberOfLoops = clipLoops
                    player.prepareToPlay()
                    let didStart = player.play()
                    DispatchQueue.main.async {
                        continuation.resume(returning: (player: player, didStart: didStart))
                    }
                } catch {
                    DispatchQueue.main.async {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}
