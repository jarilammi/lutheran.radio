//
//  DirectStreamingPlayer+PlayerItemRecovery.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 24.7.2026.
//
//  Player-item recovery domain: startup safety net, early ICY drop recreate, early-window transient recovery, secured recreatePlayerItem, loading/item failure classification hooks.
//
//  Behavior-preserving domain split from DirectStreamingPlayer.swift.
//  DirectStreamingPlayer remains the public façade; this file owns one domain.
//
//  AGENT NOTE: Members used across files are `internal` (Swift `private` is
//  file-scoped). Prefer this domain file over re-implementing attach / recovery
//  / catalog logic in call sites.
//
//  - SeeAlso: DirectStreamingPlayer.swift, makeSecuredPlayerItem(for:), StreamErrorType.from(error:), DirectStreamingPlayer+PlaybackAttach.swift,
//    CODING_AGENT.md (Single Source of Truth Principles).
//

import Foundation
import Core
import WidgetSurface
@unsafe @preconcurrency import AVFoundation

extension DirectStreamingPlayer {
    // MARK: - PlayerItemRecovery domain
    //
    // Preferred end-state name for startup safety net, early ICY drop recreate, early-window
    // transient recovery, and secured recreatePlayerItem. Always rebuilds via
    // makeSecuredPlayerItem (resource loader + Core certificate path).

    @MainActor
    func cancelStartupSafetyNet() {
        startupSafetyNetWorkItem?.cancel()
        startupSafetyNetWorkItem = nil
    }
    // MARK: - Startup Safety Net (cold launch / stream-switch first attach)
    @MainActor
    func scheduleStartupSafetyNet() {
        guard initialPlaybackRetryCount < maxInitialRetries else { return }

        cancelStartupSafetyNet()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            Task { @MainActor in
                // ──────────────────────────────────────────────────────────────
                // intent-driven startup safety net.
                // The .prePlay visual-state heuristic has been removed (last remaining
                // currentVisualState decision point for control flow in DirectStreamingPlayer).
                // Activation now relies solely on: intent check + actual playback facts.
                guard await SharedPlayerManager.shared.canProceedWithPlayback() else {
                    #if DEBUG
                    print("[DirectStreamingPlayer] startup safety net: resurrection suppressed by playbackIntent")
                    #endif
                    return
                }
                // ──────────────────────────────────────────────────────────────
                
                let isActuallyPlaying = (self.player?.rate ?? 0) > 0.1 &&
                                        self.currentItemStatus == .readyToPlay
                
                if !isActuallyPlaying {
                    // Share the same hard budget as early-window recovery so stall recreates
                    // and the 5 s safety net cannot stack into a multi-recreate storm.
                    if self.initialPlaybackRetryCount >= self.maxInitialRetries {
                        #if DEBUG
                        let tc = self.player?.timeControlStatus.rawValue ?? -1
                        print("[DirectStreamingPlayer] [Playback] Startup safety net: budget already exhausted (\(self.initialPlaybackRetryCount)/\(self.maxInitialRetries))")
                        print("[DirectStreamingPlayer] [Playback] Safety net terminal: hasPermanentError=\(self.hasPermanentError) | timeControlStatus=\(tc) | rate=\(self.player?.rate ?? -1) | currentItemStatus=\(self.currentItemStatus.rawValue)")
                        #endif

                        if self.hasPermanentError {
                            self.safeOnStatusChange(isPlaying: false, reasonKey: "status_failed")
                        } else {
                            // One last secured recreate only — still no permanent red UX for
                            // pure transient ICY/Fig noise. Intent stays active so a later
                            // language switch or explicit play can recover.
                            #if DEBUG
                            print("[DirectStreamingPlayer] [Playback] Transient give-up: performing FINAL recreatePlayerItem() then suppressing severe status. No red popup.")
                            #endif
                            self.recreatePlayerItem()
                        }
                        return
                    }

                    self.initialPlaybackRetryCount += 1
                    #if DEBUG
                    print("[DirectStreamingPlayer] [Playback] Startup safety net: no playback detected after 5s – retry \(self.initialPlaybackRetryCount)/\(self.maxInitialRetries) | hasStartedPlaying=\(self.hasStartedPlaying) | currentItemStatus=\(self.currentItemStatus.rawValue) | hasPlayerItem=\(self.playerItem != nil) | rate=\(self.player?.rate ?? -1)")
                    #endif
                    self.recreatePlayerItem()
                }
            }
        }
        startupSafetyNetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
    }
    @MainActor
    func activatePlaybackTeardownGuard() {
        isPlaybackTeardownActive = true
        cancelEarlyICYDropRecreate()
        cancelStartupSafetyNet()
    }

    @MainActor
    func clearPlaybackTeardownGuard() {
        isPlaybackTeardownActive = false
    }

    /// Activates the teardown guard on the main actor without requiring the caller to be MainActor-isolated.
    func activatePlaybackTeardownGuardFromStop() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { activatePlaybackTeardownGuard() }
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated { self.activatePlaybackTeardownGuard() } }
        }
    }

    @MainActor
    func scheduleEarlyICYDropRecreate(rate: Float) {
        guard !isPlaybackTeardownActive else { return }
        earlyICYDropRecreateTask?.cancel()
        earlyICYDropRecreateTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard let self else { return }
            #if DEBUG
            print("[DirectStreamingPlayer] [Playback] Early timeControl drop on fresh ICY item (rate=\(rate)) — early-window recovery")
            #endif
            _ = await self.attemptEarlyWindowTransientRecovery(
                reason: "timeControlPaused-early",
                allowWhileDeferringFirstPlayKick: false
            )
        }
    }
    
    @MainActor
    func cancelEarlyICYDropRecreate() {
        earlyICYDropRecreateTask?.cancel()
        earlyICYDropRecreateTask = nil
    }

    /// Seconds remaining in the post-attach loading grace (0 when expired or not started).
    @MainActor
    func remainingEarlyAttachLoadingGraceSeconds() -> TimeInterval {
        guard let began = currentAttachBeganAt else {
            // No clock yet (observers before attach mark) — treat as full grace so we do not
            // recreate from a zero-delay path.
            return earlyAttachLoadingGraceSeconds
        }
        let elapsed = Date().timeIntervalSince(began)
        return max(0, earlyAttachLoadingGraceSeconds - elapsed)
    }

    /// Whether "buffer not likely to keep up + rate 0" may enter early-window recovery.
    ///
    /// Returns `false` while the secured item is still legitimately loading
    /// (`status == .unknown`, no error) inside ``earlyAttachLoadingGraceSeconds``.
    /// Hard errors and post-ready stuck rate always return `true` when the early budget remains.
    ///
    /// - Parameters:
    ///   - item: Current `AVPlayerItem` under observation.
    ///   - rate: Current `AVPlayer.rate`.
    /// - Returns: `true` when a stall-class early recreate is allowed to proceed.
    /// - SeeAlso: ``attemptEarlyWindowTransientRecovery(reason:allowWhileDeferringFirstPlayKick:)``,
    ///   ``earlyAttachLoadingGraceSeconds``, docs/cold-launch-streamplay-regression-checklist.md (§8).
    @MainActor
    func shouldAttemptEarlyAttachStallRecovery(item: AVPlayerItem, rate: Float) -> Bool {
        guard !hasStartedPlaying else { return false }
        guard initialPlaybackRetryCount < maxInitialRetries else { return false }
        guard rate < 0.1 else { return false }
        if item.error != nil { return true }
        switch item.status {
        case .failed:
            return true
        case .readyToPlay:
            // Ready but silent — short patience already applied by the caller's debounce.
            return true
        case .unknown:
            // Progressive ICY: unknown + no error is normal loading, not a stall, until grace ends.
            return remainingEarlyAttachLoadingGraceSeconds() <= 0
        @unknown default:
            return remainingEarlyAttachLoadingGraceSeconds() <= 0
        }
    }

    /// Silent recovery for transient ICY / Fig / decoder noise on a fresh attach.
    ///
    /// This is the single decision gate for early-window recovery. Callers (KVO, buffer
    /// observers, item `.failed`, resource-loader errors, loading errors) pass a diagnostic
    /// `reason` only. The gate enforces:
    /// - teardown suppression
    /// - pre-stable-play window (`!hasStartedPlaying`)
    /// - per-stream retry budget (`initialPlaybackRetryCount` / `maxInitialRetries`) —
    ///   **each successful admission increments the count** so the budget is a hard cap
    /// - ``SharedPlayerManager/canProceedWithPlayback()`` (sticky pause / security / clear)
    ///
    /// Stall-class callers must also pass ``shouldAttemptEarlyAttachStallRecovery(item:rate:)``
    /// so normal first-byte loading is not treated as an immediate recreate.
    ///
    /// On success it schedules ``recreatePlayerItem()``, which always rebuilds a **secured**
    /// item (resource loader + DNSSEC/cert path) under the current ``playbackAttachGeneration``.
    /// Permanent failures never enter here.
    ///
    /// - Parameters:
    ///   - reason: DEBUG diagnostic label for the recovery trigger.
    ///   - allowWhileDeferringFirstPlayKick: When `false`, skips while the first audible kick
    ///     is still waiting on `.readyToPlay` (used for pure timeControl pauses that often
    ///     resolve without recreate). When `true`, recovers even if the first kick is deferred
    ///     (item failure / resource-loader errors cannot wait for ready).
    /// - Returns: `true` if ``recreatePlayerItem()`` was invoked.
    /// - SeeAlso: `recreatePlayerItem()`, `handleItemStatusFailure(_:)`,
    ///   `shouldAttemptEarlyAttachStallRecovery(item:rate:)`,
    ///   `isInInitialRecoveryWindow`, docs/cold-launch-streamplay-regression-checklist.md (§8).
    @MainActor
    @discardableResult
    func attemptEarlyWindowTransientRecovery(
        reason: String,
        allowWhileDeferringFirstPlayKick: Bool
    ) async -> Bool {
        guard !isPlaybackTeardownActive else { return false }
        guard !hasStartedPlaying else { return false }
        if !allowWhileDeferringFirstPlayKick && isDeferringFirstPlayKick {
            #if DEBUG
            print("[DirectStreamingPlayer] early-window recovery skipped (\(reason)) — awaiting readyToPlay first-play kick")
            #endif
            return false
        }
        guard initialPlaybackRetryCount < maxInitialRetries else {
            #if DEBUG
            print("[DirectStreamingPlayer] early-window recovery budget exhausted (\(reason)) — \(initialPlaybackRetryCount)/\(maxInitialRetries)")
            #endif
            return false
        }
        guard await SharedPlayerManager.shared.canProceedWithPlayback() else {
            #if DEBUG
            print("[DirectStreamingPlayer] early-window recovery suppressed by playbackIntent (\(reason))")
            #endif
            return false
        }
        // Hard cap: every admitted recovery consumes one budget unit (never sticky-at-1).
        initialPlaybackRetryCount += 1
        #if DEBUG
        print("[DirectStreamingPlayer] early-window recovery → recreatePlayerItem | reason=\(reason) | retryCount=\(initialPlaybackRetryCount)/\(maxInitialRetries)")
        #endif
        recreatePlayerItem()
        return true
    }
    
    /// Rebuilds the current live `AVPlayerItem` on the secured resource-loader path.
    ///
    /// Canonical recovery tool for transient ICY/Fig/decoder noise and mid-session stalls.
    /// Always creates the replacement item via ``makeSecuredPlayerItem(for:)`` so DNSSEC and
    /// runtime certificate validation remain in force. Single-flight (`recreateInFlight`);
    /// suppressed while `isPlaybackTeardownActive`. Captures ``playbackAttachGeneration`` at
    /// entry and aborts if a concurrent ``stop(reason:completion:silent:)`` advanced it
    /// (stream-switch teardown or user pause supersedes the in-flight recreate).
    /// Rebinds player-level and item-level observers, then restarts only when
    /// ``SharedPlayerManager/canProceedWithPlayback()`` still allows audio.
    ///
    /// - SeeAlso: `attemptEarlyWindowTransientRecovery(reason:allowWhileDeferringFirstPlayKick:)`,
    ///   `makeSecuredPlayerItem(for:)`, `setupPlaybackObservers()`,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§8).
    func recreatePlayerItem() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard !self.isPlaybackTeardownActive else {
                #if DEBUG
                print("[DirectStreamingPlayer] [Playback] recreatePlayerItem: suppressed — playback teardown active")
                #endif
                return
            }
            guard !self.recreateInFlight else {
                #if DEBUG
                print("[DirectStreamingPlayer] [Playback] recreatePlayerItem: coalesced — already in flight")
                #endif
                return
            }
            let generationAtStart = self.playbackAttachGeneration
            self.recreateInFlight = true
            defer { self.recreateInFlight = false }
            
            #if DEBUG
            print("[DirectStreamingPlayer] Recreating secured player item (transient recovery)")
            #endif
            
            guard let urlAsset = self.playerItem?.asset as? AVURLAsset else {
                #if DEBUG
                print("[DirectStreamingPlayer] [Playback] Cannot recreate: no valid URL asset | hasStartedPlaying=\(self.hasStartedPlaying) | initialPlaybackRetryCount=\(self.initialPlaybackRetryCount) | playerItem=\(self.playerItem != nil) | this often happens during stream switch races")
                #endif
                return
            }
            
            let currentURL = urlAsset.url
            self.cancelEarlyICYDropRecreate()
            
            // Clear item-level observations before replacing the item.
            self.playerItemObservations.forEach { $0.invalidate() }
            self.playerItemObservations.removeAll()

            // Stream-switch / user stop may have advanced generation after we entered.
            guard generationAtStart == self.playbackAttachGeneration else {
                #if DEBUG
                print("[DirectStreamingPlayer] [Playback] recreatePlayerItem: discarded — attach generation advanced")
                #endif
                return
            }
            guard !self.isPlaybackTeardownActive else {
                #if DEBUG
                print("[DirectStreamingPlayer] [Playback] recreatePlayerItem: discarded — teardown became active")
                #endif
                return
            }
            
            // Security invariant: replacement items must use the resource-loader path
            // (never a bare AVURLAsset without the streaming delegate).
            let newItem = self.makeSecuredPlayerItem(for: currentURL)
            
            self.player?.replaceCurrentItem(with: newItem)
            self.playerItem = newItem
            self.bindAttachedItemToSelectedStream()
            self.clearPlaybackTeardownGuard()
            // Fresh loading grace for the replacement item (prefer one recreate settling cleanly
            // over a second recreate while tracks are still attaching).
            self.currentAttachBeganAt = Date()
            
            // Rebind player-level KVO + ICY, then item-level buffer/status observers.
            self.setupPlaybackObservers()
            self.addObservers()
            
            guard await self.shouldAllowAudiblePlaybackKick() else {
                #if DEBUG
                print("[DirectStreamingPlayer] recreatePlayerItem: audible restart suppressed (intent / soft-pause / teardown)")
                #endif
                self.isDeferringFirstPlayKick = false
                self.player?.pause()
                self.player?.rate = 0.0
                return
            }

            guard generationAtStart == self.playbackAttachGeneration else {
                #if DEBUG
                print("[DirectStreamingPlayer] [Playback] recreatePlayerItem: discarded after kick check — generation advanced")
                #endif
                self.player?.pause()
                self.player?.rate = 0.0
                return
            }
            
            // Restart only when still allowed — defer audible kick until item is ready.
            if newItem.status == .readyToPlay {
                self.isDeferringFirstPlayKick = false
                self.player?.playImmediately(atRate: 1.0)
            } else {
                self.isDeferringFirstPlayKick = true
            }
            
            #if DEBUG
            print("[DirectStreamingPlayer] Secured player item recreated (item.status: \(newItem.status.rawValue))")
            #endif
        }
    }
    func handleLoadingError(_ error: Error) async {
        let errorType = StreamErrorType.from(error: error)
        hasPermanentError = errorType.isPermanent
        
        #if DEBUG
        print("[DirectStreamingPlayer] [Loading Error] Type: \(errorType), isPermanent: \(errorType.isPermanent)")
        print("[DirectStreamingPlayer] [Loading Error] Error: \(error.localizedDescription)")
        #endif
        
        if let urlError = error as? URLError {
            switch urlError.code {
            case .serverCertificateUntrusted, .secureConnectionFailed:
                #if DEBUG
                print("[DirectStreamingPlayer] [Loading Error] SSL/Certificate error detected")
                #endif
                safeOnStatusChange(isPlaying: false, reasonKey: "status_security_failed")
                
            case .fileDoesNotExist:
                #if DEBUG
                print("[DirectStreamingPlayer] [Loading Error] Hard server error (resource missing)")
                #endif
                safeOnStatusChange(isPlaying: false, reasonKey: "status_failed")
                
            case .cannotFindHost, .dnsLookupFailed:
                #if DEBUG
                print("[DirectStreamingPlayer] [Loading Error] DNS lookup error (may be DNSSEC-unvalidated when policy active) — treating as transient")
                #endif
                // DNS lookup (including DNSSEC validation failure when
                // requiresDNSSECValidation is active) is recoverable in the early window.
                fallthrough
                
            default:
                #if DEBUG
                print("[DirectStreamingPlayer] [Loading Error] Transient error detected")
                #endif
                safeOnStatusChange(isPlaying: false, reasonKey: "status_buffering")
                
                if await attemptEarlyWindowTransientRecovery(
                    reason: "loadingError-url-\(urlError.code.rawValue)",
                    allowWhileDeferringFirstPlayKick: true
                ) {
                    return
                }
            }
        } else if !errorType.isPermanent {
            #if DEBUG
            print("[DirectStreamingPlayer] [Loading Error] Non-URL transient — early-window recovery path")
            #endif
            safeOnStatusChange(isPlaying: false, reasonKey: "status_buffering")
            if await attemptEarlyWindowTransientRecovery(
                reason: "loadingError-nonURL",
                allowWhileDeferringFirstPlayKick: true
            ) {
                return
            }
        } else {
            #if DEBUG
            print("[DirectStreamingPlayer] [Loading Error] Permanent non-URL error")
            #endif
            safeOnStatusChange(isPlaying: false, reasonKey: errorType.statusString)
        }
        
        // Terminal path: classified failure reaches SharedPlayerManager (intent preserved for
        // auto-resume on stream switch). `streamDidFail` is emitted inside mark… after mutation.
        await SharedPlayerManager.shared.markPlaybackStoppedByStreamFailure(errorType)
        stop()
    }

    func handleNetworkInterruption() {
        stop()
        let interruptionDelay: TimeInterval = isLowEfficiencyMode ? 1.0 : 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + interruptionDelay) { [weak self] in
            guard let self = self, self.delegate != nil else { return }
            // Emit a proper status_* key (never button titles or popup titles as reasonKey).
            self.safeOnStatusChange(isPlaying: false, reasonKey: "status_paused")
        }
    }
    
    func handlePlaybackError(_ error: Error?) {
        #if DEBUG
        if let avError = error as? AVError {
            print("[DirectStreamingPlayer] Playback error: code=\(avError.code.rawValue), desc=\(avError.localizedDescription)")
        }
        #endif
        // Route every AV/item failure through the same classification + early-window gate.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let item = self.playerItem {
                await self.handleItemStatusFailure(item)
            } else if let error {
                await self.handleLoadingError(error)
            }
        }
    }

    /// Central decision point for `.failed` status on an `AVPlayerItem`.
    ///
    /// Answers: is this self-healing transient noise on a fresh ICY attach (recover with
    /// secured ``recreatePlayerItem()``), or a real permanent failure that should surface
    /// via ``SharedPlayerManager/markPlaybackStoppedByStreamFailure(_:)``?
    ///
    /// Combines:
    /// - ``StreamErrorType/from(error:)`` classification (decoder / Fig noise → transient)
    /// - The fresh-item budget (`!hasStartedPlaying` + `initialPlaybackRetryCount`)
    /// - Intent check via ``SharedPlayerManager/canProceedWithPlayback()``
    ///
    /// After a user stream switch, `switchToStream` + `resetInitialPlaybackCountersForNewStream`
    /// give the new item a clean budget so prior-stream noise cannot poison the first attempt.
    /// Terminal failure preserves playback intent (typically `.shouldBePlaying`) so a language
    /// switch can auto-resume without an extra play tap.
    ///
    /// - Precondition: Called on a `.failed` KVO delivery for the current `playerItem`.
    /// - Postcondition: Either ``recreatePlayerItem()`` was scheduled (transient) or a terminal
    ///   status was emitted and the player was stopped (permanent / budget exhausted).
    ///
    /// - SeeAlso: `StreamErrorType.from(error:)`, `attemptEarlyWindowTransientRecovery`,
    ///   `switchToStream(_:)`, `resetInitialPlaybackCountersForNewStream()`,
    ///   `recreatePlayerItem()`, `RadioPlayerCoordinator.handleStatusChange`,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§6.12, §8.7), CODING_AGENT.md
    @MainActor
    func handleItemStatusFailure(_ item: AVPlayerItem) async {
        let error = item.error
        let errorType = StreamErrorType.from(error: error)

        hasPermanentError = errorType.isPermanent

        if !errorType.isPermanent {
            if await attemptEarlyWindowTransientRecovery(
                reason: "itemStatusFailed",
                allowWhileDeferringFirstPlayKick: true
            ) {
                return
            }
        }

        // Permanent, or late/exhausted transient — surface failure without sticky user pause.
        safeOnStatusChange(isPlaying: false, reasonKey: errorType.statusString)
        await SharedPlayerManager.shared.markPlaybackStoppedByStreamFailure(errorType)
        stop()
    }
}
