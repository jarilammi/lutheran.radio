//
//  ViewController+AudioSessionObservers.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.7.2026.
//
//  Audio session observer domain for the thin UIKit host (mechanical split).
//
//  Owns: host-side AVAudioSession interruption and route-change observers
//  (``setupInterruptionHandling``, ``setupRouteChangeHandling``, handlers) and the
//  consolidated session reconfiguration entry (``reconfigureAudioSession``).
//
//  Host work only:
//  - Interruption began → stop local tuning chrome (coordinator)
//  - Interruption ended + shouldResume → reconfigure session + intent-gated
//    technical recovery via ``SharedPlayerManager/play()``
//  - Route newDeviceAvailable / categoryChange → reconfigure (+ recovery play when intent allows)
//
//  Does **not** own:
//  - Playback rate pause on interruption/route (engine
//    `DirectStreamingPlayer+AudioSessionInterruption` — non-sticky, no ``PlayerVisualState/userPaused``)
//  - Audio session category / setActive SSOT (``DirectStreamingPlayer/configureAudioSessionAsync()``)
//  - Visual/intent SSOT (``SharedPlayerManager`` / ``PlayerVisualState``)
//  - Sticky pause via ``stopPlayback()`` (never call that from interruption/route — resurrection hazard)
//
//  Stored teardown flag (``isDeallocating``) and engine ref (``streamingPlayer``) remain on the
//  primary type body; this file owns the behavior that uses them for session observers.
//
//  - SeeAlso: `DirectStreamingPlayer+AudioSessionInterruption`,
//    ``DirectStreamingPlayer/configureAudioSessionAsync()``,
//    ``PlayerVisualState/shouldAutoPlayOrResume``,
//    ``SharedPlayerManager/canProceedWithPlayback()``,
//    ViewController.swift (isolation map),
//    CODING_AGENT.md (Single Source of Truth Principles).
//

import UIKit
@unsafe @preconcurrency import AVFoundation
import WidgetSurface

extension ViewController {

    // MARK: - Audio session observers (interruption + route)

    /// Installs the host AVAudioSession interruption observer.
    ///
    /// Playback rate pause on `.began` is engine-owned; this observer only drives tuning chrome
    /// stop and intent-gated recovery on `.ended`.
    ///
    /// - SeeAlso: ``handleInterruption(_:)``, `DirectStreamingPlayer+AudioSessionInterruption`
    func setupInterruptionHandling() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    /// Host-side AVAudioSession interruption observer (UIKit lifecycle surface).
    ///
    /// **Ownership split (do not collapse casually):**
    /// - **Engine** (`DirectStreamingPlayer+AudioSessionInterruption`): graceful `AVPlayer`
    ///   pause/resume from rate truth (`DirectStreamingPlayer.isPlaying`) **without** sticky
    ///   ``PlayerVisualState/userPaused``. That is the playback-surface owner for interruptions.
    /// - **Host (this method):** stop local tuning chrome on `.began`; on `.ended` +
    ///   `.shouldResume`, reconfigure the session and run the SPM technical recovery path only
    ///   when visual intent allows (`shouldAutoPlayOrResume`).
    ///
    /// **Why there is no host `isPlaying` bool:** A parallel host flag desynced from engine
    /// rate and SPM visual SSOT. Calling ``stopPlayback()`` (→ ``SharedPlayerManager/stop()``)
    /// on interruption would sticky-pause and block legitimate post-call resume — never reintroduce
    /// that branch here.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/isPlaying``, ``PlayerVisualState/shouldAutoPlayOrResume``,
    ///   `DirectStreamingPlayer+AudioSessionInterruption`, ``reconfigureAudioSession()``
    @objc func handleInterruption(_ notification: Notification) {
        guard !isDeallocating else {
            #if DEBUG
            print("[ViewController] handleInterruption: ViewController is deallocating, skipping")
            #endif
            return
        }

        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            #if DEBUG
            // Engine rate truth for diagnostics only — not a host playback store.
            print("[ViewController] AVAudioSession interruption began (engineIsPlaying=\(streamingPlayer.isPlaying))")
            #endif
            // Playback pause: engine observer (rate → pause, non-sticky). Host: tuning chrome only.
            radioPlayerCoordinator.stopTuningSound()

        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)

            // Consolidated via `reconfigureAudioSession()` → player's async helper.
            Task { @MainActor in
                await self.reconfigureAudioSession()
            }

            // === Important guard: Respect PlayerVisualState user intent ===
            // This prevents the most common "play-on-pause resurrection" after phone calls, Siri, etc.
            if options.contains(.shouldResume) {
                Task { @MainActor in
                    guard await streamingPlayer.shouldAutoPlayOrResume else {
                        #if DEBUG
                        print("🚫 [Interruption Guard] Blocked auto-resume after interruption — currentVisualState is .userPaused")
                        #endif

                        updateUI(for: .userPaused)
                        return
                    }

                    #if DEBUG
                    print("[ViewController] ▶ [Interruption Guard] Allowed resume after interruption")
                    #endif

                    // Recovery path after AV interruption .shouldResume (guard already verified
                    // canProceed / !sticky via shouldAutoPlayOrResume). Direct SPM.play() is
                    // permitted here (recovery + intent already known active per the
                    // userRequestedPlay Precondition).
                    await SharedPlayerManager.shared.play()
                }
            }

        @unknown default:
            break
        }
    }

    /// Installs the host AVAudioSession route-change observer.
    ///
    /// Engine owns rate-based pause when the output route disappears; host does not sticky-stop.
    ///
    /// - SeeAlso: ``handleRouteChange(_:)``, `DirectStreamingPlayer+AudioSessionInterruption`
    func setupRouteChangeHandling() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    /// Consolidated entry point for audio session (re)activation from ViewController surfaces.
    ///
    /// All activation calls originating in ViewController (interruption recovery, route change,
    /// and category change) route through this method so that activation logic stays in one
    /// place and always uses the async helper (`configureAudioSessionAsync` is the player SSOT).
    ///
    /// The underlying implementation guarantees that `setActive` is never invoked directly
    /// on the main thread (iOS 27+ uses framework async; 26.x uses off-main dispatch).
    ///
    /// Bundled tuning clips must not use this alone and then construct `AVAudioPlayer` on
    /// `@MainActor` — use ``DirectStreamingPlayer/startLocalClipPlayer(contentsOf:volume:numberOfLoops:)``
    /// so prepare/play (and any implicit activation) stay off the main actor.
    ///
    /// Playback entry points inside the player call `configureAudioSessionAsync()` (or the
    /// thin `setupAudioSession()` wrapper) directly. Engine construction does **not**
    /// activate — first clip / play / attach await configure, which waits for
    /// factory-reset Now Playing phase 2 deactivate on ``audioSessionMutationTail``.
    /// SessionCore deactivate of a never-configured session is skipped. First
    /// presentable configure settles SessionCore before `setCategory`.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/configureAudioSessionAsync()``,
    ///   ``DirectStreamingPlayer/deactivateAudioSessionAsync()``,
    ///   ``DirectStreamingPlayer/setupAudioSession()``,
    ///   ``DirectStreamingPlayer/startLocalClipPlayer(contentsOf:volume:numberOfLoops:)``,
    ///   `handleInterruption(_:)`, `handleRouteChange(_:)`,
    ///   `RadioPlayerCoordinator.playSpecialTuningSound(completion:)`.
    @MainActor
    func reconfigureAudioSession() async {
        _ = await streamingPlayer.configureAudioSessionAsync()
    }

    /// Host-side AVAudioSession route-change observer.
    ///
    /// **Ownership:** Engine route observer pauses when `player.rate > 0` without sticky
    /// user-pause. Host does **not** mirror that with a local `isPlaying` flag or
    /// ``stopPlayback()`` (sticky). Host work here is session reconfiguration + intent-gated
    /// recovery play on ``newDeviceAvailable``.
    ///
    /// - SeeAlso: `DirectStreamingPlayer+AudioSessionInterruption` (route observer),
    ///   ``SharedPlayerManager/canProceedWithPlayback()``, ``reconfigureAudioSession()``
    @objc func handleRouteChange(_ notification: Notification) {
        guard !isDeallocating else {
            #if DEBUG
            print("[ViewController] handleRouteChange: ViewController is deallocating, skipping")
            #endif
            return
        }
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            // Engine owns rate-based pause when the output route disappears.
            // Do not call stopPlayback() here — that would sticky-mark .userPaused.
            #if DEBUG
            print("[ViewController] Route oldDeviceUnavailable (engineIsPlaying=\(streamingPlayer.isPlaying)); engine owns pause")
            #endif
            break
        case .newDeviceAvailable:
            // Consolidated via `reconfigureAudioSession()` → player's async helper.
            // Await config before recovery play (preferred over fire-and-forget).
            Task { @MainActor in
                await self.reconfigureAudioSession()
                // Route-change recovery: only proceed if intent permits (defensive; SPM.play
                // would also block). This is a technical recovery path, not explicit user play.
                // (See userRequestedPlay Precondition for permitted direct play() cases.)
                if await SharedPlayerManager.shared.canProceedWithPlayback() {
                    await SharedPlayerManager.shared.play()
                }
            }
        case .categoryChange:
            // Consolidated via `reconfigureAudioSession()`.
            Task { @MainActor in
                await self.reconfigureAudioSession()
            }
        default:
            break
        }
    }
}
