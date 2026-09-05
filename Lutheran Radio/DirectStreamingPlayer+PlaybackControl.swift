//
//  DirectStreamingPlayer+PlaybackControl.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.7.2026.
//
//  Engine-owned public play / stop entry surface for the secured AVPlayer streaming engine.
//  Owns cold-start `play()`, attach-aware `createAndStartPlayer`, and hard-teardown
//  stop paths (`stop` / `stopAndWait` / `performActualStop` / synchronous cleanup helpers).
//  User pause cancels the Icecast URLSession and nils the item — not a retained
//  live connection. Stream-switch hard stop also `replaceCurrentItem(with: nil)` after
//  loader cancel so the next language does not attach onto a dirty `AVPlayer` graph.
//  Soft-pause (item at rate 0) is only ``enforceSilenceAfterDiscardedAttach``.
//
//  Behavior-preserving domain split from DirectStreamingPlayer.swift.
//  DirectStreamingPlayer remains the public engine façade; this file owns one domain.
//
//  Ownership (do not invert):
//  - This domain owns **public playback control entrypoints**: ``play()``,
//    ``createAndStartPlayer(for:attachGeneration:)``, ``stop(reason:completion:silent:applyUserPauseVisualLock:)``,
//    ``stopAndWait(reason:silent:applyUserPauseVisualLock:)``, ``performActualStop(reason:silent:)``,
//    ``stopSynchronously()``, ``performStopCleanup()``.
//  - Attach generation / soft-pause state machines live in `+PlaybackAttach.swift`; this domain
//    *calls* ``beginInFlightPlaybackAttach()`` / ``invalidateInFlightPlaybackAttach()`` /
//    ``shouldContinueInFlightAttach(startedAt:)`` and must not re-own generation storage.
//  - Secured item construction lives in `+SecuredPlayerItem.swift` (`makeSecuredPlayerItem` /
//    `preparePlayerItem`) so recovery, attach, and this domain share one Core-backed path —
//    never bypass resource loader / Core pins.
//  - Audio session activate/deactivate remains in `+AudioSession.swift` — call
//    ``configureAudioSessionAsync()`` only; never `setCategory` / `setActive` here.
//    Configure waits for any in-flight factory-reset deactivate via ``audioSessionMutationTail``.
//    SessionCore deactivate of a never-configured session is skipped. First presentable
//    configure settles SessionCore before `setCategory`.
//  - Visual/intent SSOT remains ``SharedPlayerManager`` (sticky pause, canProceedWithPlayback,
//    saveCurrentState). Engine silence completes before optional visual lock / surface refresh.
//  - System media session hard detach for privacy/factory reset lives in
//    `+SystemMediaSession.swift` (``teardownSystemMediaSession*``) — not this domain.
//
//  Process invariants:
//  - No-op under UITestMode (`isTesting`) for ``play()`` / ``createAndStartPlayer``.
//  - ``stop`` under `isTesting` still applies the Icecast teardown postcondition (teardown guard,
//    `isSoftPaused == false`, item niled, loaders cancelled) on MainActor — it must not hop
//    `audioQueue` or AVAudioSession (that re-introduces the XCTest-host launch hang).
//  - User pause during validation / session activation advances attach generation; post-await
//    paths re-check generation + intent and discard without audible start.
//  - User-action stop always hard-tears down the custom resource-loader session so a paused
//    Icecast keep-alive cannot keep receiving the live body. ``SharedPlayerManager/stop()`` then
//    deactivates ``AVAudioSession``. Play after pause is full ``attachAndPlay``.
//  - ``SharedPlayerManager/stop()`` may pass `applyUserPauseVisualLock: false` when it already
//    owns sticky `.userPaused` + single media-surface refresh.
//
//  AGENT NOTE: Members used across files are `internal` (Swift `private` is file-scoped).
//  Prefer this domain file over re-implementing stop ordering in call sites. Do not mix
//  audio-session category surgery or attach-generation redesign into this domain peel.
//
//  - SeeAlso: DirectStreamingPlayer.swift, DirectStreamingPlayer+PlaybackAttach.swift,
//    DirectStreamingPlayer+SecuredPlayerItem.swift, DirectStreamingPlayer+AudioSession.swift,
//    DirectStreamingPlayer+SystemMediaSession.swift, DirectStreamingPlayer+PlayerItemRecovery.swift,
//    SharedPlayerManager.stop(), SharedPlayerManager.play() pipeline,
//    docs/Live-Activity-Stacking-and-Media-Surfaces.md,
//    CODING_AGENT.md (Single Source of Truth Principles).
//

import Foundation
@unsafe @preconcurrency import AVFoundation
import Core
import WidgetSurface

// MARK: - Playback control (public play / stop)

extension DirectStreamingPlayer {

    // MARK: - Playback Control Methods

    /// Starts or resumes playback after validation and server selection.
    ///
    /// User pause during this method (security validation, server selection, or attach) advances
    /// ``playbackAttachGeneration`` via ``stop(reason:completion:silent:)``. This method re-checks
    /// generation + intent after every significant `await` and discards without audible start.
    ///
    /// - Returns: `true` if playback was successfully *initiated* (item replaced + play() called).
    ///            Note: Actual audio may start slightly later when the item becomes readyToPlay.
    /// - Throws: Only critical unrecoverable errors (rare).
    /// - SeeAlso: ``shouldContinueInFlightAttach(startedAt:)``, ``attachAndPlay(to:context:)``,
    ///   ``SharedPlayerManager/canProceedWithPlayback()``.
    @MainActor
    func play() async -> Bool {
        // UI Test isolation (defense-in-depth).
        // Even if a recovery or network-restore path reaches here, never start real playback.
        // Visual state for assertions is driven exclusively through SharedPlayerManager.
        guard !isTesting else {
            #if DEBUG
            print("[DirectStreamingPlayer] play() — isTesting, early return (no AVPlayer, no audio session, no network)")
            #endif
            return false
        }

        // === Important guard : Driven by authoritative playback intent ===
        // This is the first execution-engine site wired to `currentPlaybackIntent` via
        // the new `canProceedWithPlayback()` helper. It replaces the prior ad-hoc visualState
        // derivation for this narrow top-level path.
        //
        // Sticky `.userPaused` / `.securityLocked` behavior is preserved exactly (the helper
        // returns false for those states, matching the old `shouldAutoPlayOrResume` rules).
        // This prevents "play-on-pause resurrection" after explicit user pause.
        guard await SharedPlayerManager.shared.canProceedWithPlayback() else {
            #if DEBUG
            print("🚫 [Play Guard] Blocked by playbackIntent = \(await SharedPlayerManager.shared.currentPlaybackIntent)")
            #endif
            safeOnStatusChange(isPlaying: false, reasonKey: "status_paused")   // ← changed
            return false
        }
        
        guard !isCurrentlyAttemptingPlayback else {
            #if DEBUG
            print("[DirectStreamingPlayer] [Playback Guard] Already attempting playback — ignoring duplicate call")
            #endif
            return false
        }
        
        let attachGeneration = beginInFlightPlaybackAttach()
        defer { endInFlightPlaybackAttach() }
        
        safeOnStatusChange(isPlaying: true, reasonKey: "status_connecting")   // ← changed
        SharedPlayerManager.shared.saveFireAndForget()
        
        let isValid = await SecurityValidationFacade.validate(.recoveryValidityCheck)
        // User may have paused (lock screen / Live Activity / Now Playing) during validation.
        guard await shouldContinueInFlightAttach(startedAt: attachGeneration) else {
            enforceSilenceAfterDiscardedAttach()
            return false
        }
        guard isValid else {
            let isPermanent = await SecurityValidationFacade.isPermanentlyInvalid()
            guard await shouldContinueInFlightAttach(startedAt: attachGeneration) else {
                enforceSilenceAfterDiscardedAttach()
                return false
            }
            let statusKey = isPermanent ? "status_security_failed" : "status_no_internet"
            safeOnStatusChange(isPlaying: false, reasonKey: statusKey)       // ← changed
            SharedPlayerManager.shared.saveFireAndForget()
            return false
        }
        
        #if DEBUG
        print("[DirectStreamingPlayer] Security validation passed — creating player for \(selectedStream.languageCode)")
        #endif
        
        // Recovery / cold engine `play()` must ping after the 10 s throttle. Same-stream
        // warm reuse is only ``PlaybackAttachContext/resume`` via ``attachAndPlay``.
        let streamURL = await urlWithOptimalServer(for: selectedStream)
        guard await shouldContinueInFlightAttach(startedAt: attachGeneration) else {
            enforceSilenceAfterDiscardedAttach()
            return false
        }
        await createAndStartPlayer(for: streamURL, attachGeneration: attachGeneration)
        guard await shouldContinueInFlightAttach(startedAt: attachGeneration) else {
            enforceSilenceAfterDiscardedAttach()
            return false
        }

        await SharedPlayerManager.shared.saveCurrentState()
        return true
    }

    // MARK: - Main-Actor-Bound Player Creation (Swift 6 safe)

    /// Creates the secured player item and starts AVPlayer when the attach generation is still live.
    ///
    /// - Parameters:
    ///   - url: Stream URL from ``urlWithOptimalServer(for:)``.
    ///   - attachGeneration: Snapshot from ``beginInFlightPlaybackAttach()`` for post-await discard.
    /// - Important: Re-checks generation + intent after audio-session activation so user pause
    ///   during that `await` cannot leave a late `player.play()` audible.
    @MainActor
    func createAndStartPlayer(for url: URL, attachGeneration: UInt64) async {
        // UI Test isolation (defense-in-depth). play() already guards, but this protects
        // any future direct caller of the private helper.
        guard !isTesting else {
            #if DEBUG
            print("[DirectStreamingPlayer] createAndStartPlayer — isTesting, no-op")
            #endif
            return
        }

        // === Playback intent + generation guard ===
        // Catches internal/resume paths and races where stop advanced generation while this
        // attach was suspended (security validation, server selection).
        // Sticky .userPaused / .securityLocked / .cleared (privacy clear) behavior preserved exactly.
        guard await shouldContinueInFlightAttach(startedAt: attachGeneration) else {
            #if DEBUG
            print("🚫 [Deep Play Guard] Blocked — in-flight attach discarded before item create")
            #endif
            enforceSilenceAfterDiscardedAttach()
            return
        }
        
        let playerItem = makeSecuredPlayerItem(for: url)
        self.playerItem = playerItem
        bindAttachedItemToSelectedStream()
        clearPlaybackTeardownGuard()
        
        if self.player == nil {
            self.player = AVPlayer(playerItem: playerItem)
        } else {
            self.player?.replaceCurrentItem(with: playerItem)
        }
        // Activate the audio session before playback (async, main-thread safe).
        // ``audioSessionMutationTail`` waits for any in-flight factory-reset deactivate
        // mutation before setCategory. SessionCore deactivate of a never-configured
        // session is skipped (``shouldSkipSessionCoreDeactivate``). First presentable
        // configure settles SessionCore before `setCategory`.
        let audioSessionOK = await configureAudioSessionAsync()
        #if DEBUG
        if audioSessionOK {
            print("[DirectStreamingPlayer] [MainActor] AVAudioSession activated successfully (.playback)")
        } else {
            print("[DirectStreamingPlayer] [MainActor] Failed to activate AVAudioSession")
        }
        #endif
        // User pause during session activation must not reach player.play().
        guard await shouldContinueInFlightAttach(startedAt: attachGeneration) else {
            enforceSilenceAfterDiscardedAttach()
            return
        }
        // ========================================================
        
        self.player?.automaticallyWaitsToMinimizeStalling = true
        self.player?.play()

        #if DEBUG
        print("[DirectStreamingPlayer] ▶ [MainActor] AVPlayer created + play() called for \(url.lastPathComponent)")
        #endif

        // Do NOT call notifyMainApp here — let SharedPlayerManager do it
    }

    // MARK: - Stop (soft pause / hard teardown)

    /// Stops playback and cleans up resources.
    ///
    /// User pause during connect / first-play / reattach **must** complete: sticky `.userPaused` is
    /// already locked by ``SharedPlayerManager/stop()`` (when that is the entry), generation is advanced
    /// here so in-flight attach discards after its next `await`, and soft pause (or hard teardown)
    /// silences any partially attached player. There is **no** early return that leaves attach free
    /// to call `playImmediately` after paused chrome is shown.
    ///
    /// **Engine-complete ordering:** Hard teardown cancels ``activeResourceLoaders`` (Icecast
    /// `URLSession` keep-alive), nils the item, and clears ``isSoftPaused`` **before** invoking
    /// `completion`. Callers that refresh Now Playing / Live Activity must await that completion
    /// (prefer ``stopAndWait(reason:silent:applyUserPauseVisualLock:)``) so glyphs cannot flip
    /// while the Icecast URLSession is still running.
    ///
    /// **Why not AVPlayer.pause() alone:** media bytes flow through a custom resource loader,
    /// not AVPlayer’s HLS stack. `canUseNetworkResourcesForLiveStreamingWhilePaused` does not
    /// apply. Leaving the item attached would keep `StreamingSessionDelegate` receiving MP3.
    ///
    /// **Visual-lock ownership:** When ``SharedPlayerManager/stop()`` already locked sticky
    /// `.userPaused`, pass `applyUserPauseVisualLock: false` so this path does not re-enter
    /// ``markAsUserPaused()`` / ``setUserPaused()`` (avoids a second `refreshAllMediaSurfaces`
    /// storm and a spurious `streamDidPause` after `streamDidStop`). Direct engine stops that do
    /// not go through SPM still use the default `true` and apply the visual lock **after** silence.
    ///
    /// - Parameters:
    ///   - reason: Why we are stopping. This is now the single source of truth for user intent.
    ///             `.userAction` → sticky `.userPaused` when `applyUserPauseVisualLock` is true
    ///             `.streamSwitch`, `.interruption`, `.error` → preserve play intent
    ///   - completion: Optional MainActor handler invoked after hard-teardown completion.
    ///                 Always called once.
    ///   - silent: If `true`, skips status updates / UI flicker (exactly as it behaved in recent commits).
    ///   - applyUserPauseVisualLock: When `true` (default) and `reason == .userAction && !silent`,
    ///     applies sticky pause via ``markAsUserPaused()`` **after** engine silence. Pass `false`
    ///     when the caller already owns the sticky lock and will refresh media surfaces once.
    /// - SeeAlso: ``stopAndWait(reason:silent:applyUserPauseVisualLock:)``,
    ///   ``invalidateInFlightPlaybackAttach()``, ``shouldContinueInFlightAttach(startedAt:)``,
    ///   ``shouldAllowAudiblePlaybackKick(startedAt:)``, ``SharedPlayerManager/stop()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md (user pause / transport coordination).
    func stop(
        reason: StopReason = .userAction,
        completion: (@MainActor @Sendable () -> Void)? = nil,
        silent: Bool = false,
        applyUserPauseVisualLock: Bool = true
    ) {
        
        #if DEBUG
        print("[DirectStreamingPlayer] FORCE STOPPING ALL PLAYBACK - reason: \(reason), silent: \(silent), applyUserPauseVisualLock: \(applyUserPauseVisualLock), attemptingPlayback: \(isCurrentlyAttemptingPlayback)")
        #endif

        // Always invalidate in-flight attach first. User pause (or any stop) that races security
        // validation / server selection / session activation must win: post-await start paths
        // re-check generation + canProceedWithPlayback and discard without audible output.
        invalidateInFlightPlaybackAttach()

        if isCurrentlyAttemptingPlayback {
            #if DEBUG
            print("[DirectStreamingPlayer] [Stop] User/engine stop during in-flight attach — generation invalidated; hard teardown will run (no early skip)")
            #endif
        }

        // Always activate before async work so stale KVO / debounced recreate cannot race
        // Icecast teardown. User pause used to skip this for "soft pause" (item retained);
        // that left the keep-alive data task running while chrome showed paused.
        activatePlaybackTeardownGuardFromStop()

        // XCTest host: apply the same Icecast teardown postcondition without audioQueue / session IPC.
        // AGENT NOTE: Skipping this re-introduces the black-screen / 5–15 min `test-without-building`
        // hang (see SharedPlayerManager.isRunningInUITestMode).
        if isTesting {
            Task { @MainActor [weak self, reason, silent, applyUserPauseVisualLock, completion] in
                guard let self else {
                    completion?()
                    return
                }
                self.cancelStartupSafetyNet()
                self.cancelEarlyICYDropRecreate()
                self.player?.pause()
                self.player?.rate = 0.0
                self.isSoftPaused = false
                self.activeResourceLoaders.forEach { (_, delegate) in
                    delegate.cancel()
                }
                self.activeResourceLoaders.removeAll()
                if Self.shouldReplaceCurrentItemWithNilOnStop(reason: reason) {
                    self.player?.replaceCurrentItem(with: nil)
                }
                self.playerItem = nil
                self.clearAttachedItemBinding()
                if applyUserPauseVisualLock && reason == .userAction && !silent {
                    await self.markAsUserPaused()
                }
                if !silent {
                    await SharedPlayerManager.shared.saveCurrentState()
                }
                completion?()
            }
            return
        }
        
        loadingTimeoutWorkItem?.cancel()
        currentLoadingDelegate?.loadingRequest.finishLoading(with: URLError(.cancelled))
        currentLoadingDelegate = nil
        
        removeAudioSessionObservers()
        
        // Hard teardown first, then optional sticky visual lock. Outer `completion` fires only after
        // loaders are cancelled so SPM can refresh media surfaces without "paused chrome + live HTTP".
        // Teardown uses a continuation bridged from audioQueue → main.
        Task { @MainActor [weak self, reason, silent, applyUserPauseVisualLock, completion] in
            guard let self else {
                completion?()
                return
            }

            await self.performActualStop(reason: reason, silent: silent)

            // .streamSwitch / .interruption / .error intentionally skip markAsUserPaused().
            // SharedPlayerManager.stop already owns sticky lock + single surface refresh — skip here.
            if applyUserPauseVisualLock && reason == .userAction && !silent {
                await self.markAsUserPaused()
                #if DEBUG
                print("[DirectStreamingPlayer] markAsUserPaused() after hard teardown – visualState set to .userPaused")
                #endif
            }

            // Silent stops (privacy clear, stream-switch teardown) must not re-persist a snapshot
            // after ``SharedPlayerManager/clearAllLocalState()`` has removed it.
            if !silent {
                await SharedPlayerManager.shared.saveCurrentState()
            }

            completion?()
        }
    }

    /// Awaits engine stop completion (hard-teardown: loaders cancelled, item niled).
    ///
    /// Prefer this over fire-and-forget ``stop(reason:completion:silent:applyUserPauseVisualLock:)``
    /// whenever the caller will update Now Playing / Live Activity or treat the stop as
    /// engine-complete. Return means the Icecast data task is cancelled and ``isSoftPaused`` is false.
    ///
    /// - Parameters:
    ///   - reason: Stop reason (see ``stop(reason:completion:silent:applyUserPauseVisualLock:)``).
    ///   - silent: Skips status flicker when `true`.
    ///   - applyUserPauseVisualLock: Pass `false` when ``SharedPlayerManager/stop()`` already
    ///     locked sticky `.userPaused` and will perform the single media-surface refresh.
    /// - SeeAlso: ``stop(reason:completion:silent:applyUserPauseVisualLock:)``,
    ///   ``SharedPlayerManager/stop()``, docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   ``MediaTransportLatencyTimeline`` (DEBUG soft-silence milestone).
    func stopAndWait(
        reason: StopReason = .userAction,
        silent: Bool = false,
        applyUserPauseVisualLock: Bool = true
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stop(
                reason: reason,
                completion: { continuation.resume() },
                silent: silent,
                applyUserPauseVisualLock: applyUserPauseVisualLock
            )
        }
        #if DEBUG
        // Engine-complete: hard teardown finished (loaders cancelled / item niled) before this resumes.
        MediaTransportLatencyTimeline.mark(
            .softSilenceComplete,
            detail: "reason=\(reason) silent=\(silent) applyVisualLock=\(applyUserPauseVisualLock)"
        )
        #endif
    }

    /// Whether a hard stop should `replaceCurrentItem(with: nil)` after pause and loader cancel.
    ///
    /// Icecast language switch reuses the same `AVPlayer`. Niling `playerItem` without detaching
    /// `AVPlayer.currentItem` leaves a dirty graph; the next secured item then attaches onto it.
    /// Soft-pause same-stream resume must not use this path — it retains the item
    /// (``enforceSilenceAfterDiscardedAttach``). User pause is already hard teardown of the
    /// Icecast session; it does not need this HAL detach because the next play is a full
    /// ``attachAndPlay`` of the same language.
    ///
    /// - Parameter reason: Engine stop reason.
    /// - Returns: `true` for ``StopReason/streamSwitch`` (next attach is a different language).
    /// - SeeAlso: ``performActualStop(reason:silent:)``, ``teardownSystemMediaSessionSynchronously()``,
    ///   ``clearAttachedItemBinding()``, ``makeSecuredPlayerItem(for:)``.
    static func shouldReplaceCurrentItemWithNilOnStop(reason: StopReason) -> Bool {
        reason == .streamSwitch
    }

    /// Performs the actual stop operation (MainActor entry from ``stop``’s isolation task).
    ///
    /// Always hard-tears down: cancel resource loaders (Icecast `URLSession`), nil `playerItem`,
    /// clear ``isSoftPaused``. On ``StopReason/streamSwitch``, also `replaceCurrentItem(with: nil)`
    /// after pause + loader cancel so the next language does not attach onto a dirty `AVPlayer`
    /// graph (same item-nil postcondition as ``teardownSystemMediaSessionSynchronously()``,
    /// without deactivating `AVAudioSession`). User pause must not retain a live HTTP body
    /// while chrome shows paused. In-flight attach discard still uses
    /// ``enforceSilenceAfterDiscardedAttach`` (short-lived, not unattended pause) and must
    /// **not** nil-replace — that path retains the item for same-stream resume.
    ///
    /// Schedules cleanup on `audioQueue` and resumes only after rate is zeroed / status
    /// emitted on the MainActor. ``stopAndWait`` callers (including
    /// ``prepareStreamChoice(_:preparation:)`` `.switchPrep`) resume only after this
    /// continuation, so the next secured item attaches on a niled current item.
    ///
    /// - Parameters:
    ///   - reason: Why we are stopping (drives silent + stream-switch item-nil).
    ///   - silent: If `true`, skips all status updates to avoid UI flicker.
    /// - Note: Combines `silent` and non-user reasons into `effectiveSilent`.
    /// - SeeAlso: ``shouldReplaceCurrentItemWithNilOnStop(reason:)``,
    ///   ``teardownSystemMediaSessionSynchronously()``, ``clearAttachedItemBinding()``,
    ///   ``makeSecuredPlayerItem(for:)``, ``StreamingSessionDelegate/cancel()``,
    ///   ``SharedPlayerManager/stop()``, docs/Widget-Presentation-Dataflow.md (Cleanup Invariant),
    ///   CODING_AGENT.md.
    @MainActor
    func performActualStop(
        reason: StopReason,
        silent: Bool = false
    ) async {
        // Derive effectiveSilent exactly as before, but now driven by reason
        // (preserves silent + stream-switch / interruption behaviour)
        let effectiveSilent = silent || (reason != .userAction)

        activatePlaybackTeardownGuardFromStop()
        hasStartedPlaying = false
        isDeferringFirstPlayKick = false
        
        if isDeallocating {
            stopSynchronously()
            return
        }

        // Hard teardown: bridge audioQueue work with a single continuation resume on MainActor.
        // Resume is always scheduled via main.async so it never runs on the same stack as
        // withCheckedContinuation’s body.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            audioQueue.async { [weak self] in
                guard let self, !self.isDeallocating else {
                    DispatchQueue.main.async {
                        continuation.resume()
                    }
                    return
                }

                #if DEBUG
                print("[DirectStreamingPlayer] Stopping playback (reason: \(reason), effectiveSilent: \(effectiveSilent))")
                #endif

                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.isSoftPaused = false
                    }
                }

                guard self.player != nil || self.playerItem != nil else {
                    // Item already gone; still drop any leftover Icecast data tasks.
                    self.activeResourceLoaders.forEach { (_, delegate) in
                        delegate.cancel()
                    }
                    self.activeResourceLoaders.removeAll()
                    if !effectiveSilent {
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                self.safeOnStatusChange(isPlaying: false, reasonKey: "status_stopped")
                            }
                            continuation.resume()
                        }
                    } else {
                        DispatchQueue.main.async {
                            continuation.resume()
                        }
                    }
                    #if DEBUG
                    print("[DirectStreamingPlayer] Playback already stopped, resource loaders cancelled (reason: \(reason))")
                    #endif
                    return
                }

                // Pause + cleanup
                self.executeAudioOperation({
                    self.player?.pause()
                    self.player?.rate = 0.0
                    return ""
                }, completion: { _ in })

                self.activeResourceLoaders.forEach { (_, delegate) in
                    delegate.cancel()
                }
                self.activeResourceLoaders.removeAll()

                if let metadataOutput = self.metadataOutput, let playerItem = self.playerItem {
                    if playerItem.outputs.contains(metadataOutput) {
                        playerItem.remove(metadataOutput)
                        #if DEBUG
                        print("[DirectStreamingPlayer] Removed metadata output from playerItem in stop")
                        #endif
                    }
                }
                self.metadataOutput = nil

                self.playerItemObservations.forEach { $0.invalidate() }
                self.playerItemObservations.removeAll()
                self.removeObserversImplementation()
                self.playerItem = nil
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if Self.shouldReplaceCurrentItemWithNilOnStop(reason: reason) {
                            self.player?.replaceCurrentItem(with: nil)
                        }
                        self.clearAttachedItemBinding()
                    }
                }

                if !effectiveSilent {
                    // A real terminal stop is a context change — clear dedup so the
                    // "status_stopped" we are about to emit (and any subsequent play) is not suppressed.
                    lastEmittedStatus = nil
                    lastObservedTimeControl = nil
                    lastObservedItemStatus = nil

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.safeOnStatusChange(isPlaying: false, reasonKey: "status_stopped")
                        }
                        continuation.resume()
                    }
                } else {
                    DispatchQueue.main.async {
                        continuation.resume()
                    }
                }

                self.stopBufferingTimer()

                #if DEBUG
                print("[DirectStreamingPlayer] Playback stopped, playerItem and resource loaders cleared (reason: \(reason))")
                #endif
            }
        }
    }
    
    func stopSynchronously() {
        // Perform all cleanup on main thread
        if Thread.isMainThread {
            player?.pause()
            player?.rate = 0.0
        } else {
            DispatchQueue.main.sync {
                player?.pause()
                player?.rate = 0.0
            }
        }
        
        // Cancel active resource loaders
        activeResourceLoaders.forEach { (_: AVAssetResourceLoadingRequest, delegate: StreamingSessionDelegate) in
            delegate.cancel()
        }
        activeResourceLoaders.removeAll()
        
        // Remove metadata output
        if let metadataOutput = self.metadataOutput, let playerItem = self.playerItem {
            if playerItem.outputs.contains(metadataOutput) {
                playerItem.remove(metadataOutput)
            }
        }
        self.metadataOutput = nil
        
        // Remove observers synchronously
        removeObserversSynchronously()
        
        // Clear playerItem
        playerItem = nil
        if Thread.isMainThread {
            MainActor.assumeIsolated { clearAttachedItemBinding() }
        }
        
        // Stop buffering timer
        bufferingTimer?.invalidate()
        bufferingTimer = nil
    }
    
    func performStopCleanup() {
        // Original stop logic without weak references
        guard player != nil || playerItem != nil else {
            return
        }
        
        player?.pause()
        player?.rate = 0.0
        
        activeResourceLoaders.forEach { (_: AVAssetResourceLoadingRequest, delegate: StreamingSessionDelegate) in
            delegate.cancel()
        }
        activeResourceLoaders.removeAll()
        
        if let metadataOutput = self.metadataOutput, let playerItem = self.playerItem {
            if playerItem.outputs.contains(metadataOutput) {
                playerItem.remove(metadataOutput)
            }
        }
        self.metadataOutput = nil
        
        removeObserversImplementation()
        playerItem = nil
        if Thread.isMainThread {
            MainActor.assumeIsolated { clearAttachedItemBinding() }
        }
        stopBufferingTimer()
    }

}
