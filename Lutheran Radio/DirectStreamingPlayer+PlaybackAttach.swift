//
//  DirectStreamingPlayer+PlaybackAttach.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 24.7.2026.
//
//  Playback attach domain (generation, soft-pause, silence-after-discard, prepareStreamChoice / attachAndPlay, startPlayback).
//
//  Behavior-preserving domain split from DirectStreamingPlayer.swift.
//  DirectStreamingPlayer remains the public façade; this file owns one domain.
//
//  AGENT NOTE: Members used across files are `internal` (Swift `private` is
//  file-scoped). Prefer this domain file over re-implementing attach / recovery
//  / catalog logic in call sites.
//
//  - SeeAlso: DirectStreamingPlayer.swift, PlaybackAttachState, SharedPlayerManager.play(), DirectStreamingPlayer+PlayerItemRecovery.swift,
//    CODING_AGENT.md (Single Source of Truth Principles).
//

import Foundation
import Core
import WidgetSurface
@unsafe @preconcurrency import AVFoundation

extension DirectStreamingPlayer {
    // MARK: - PlaybackAttachController domain
    //
    // Preferred end-state name for this domain (generation, soft-pause, silence-after-discard,
    // prepareStreamChoice / attachAndPlay / startPlayback). Behavior stays on the façade type
    // so public API (`PlaybackAttachState`, `attachAndPlay`, test seams) is unchanged; this
    // file is the single owner for attach-control methods.

    // MARK: - Playback attach state (soft-pause / generation / language binding)

    /// Read-only snapshot of soft-pause, attach generation, and attached-vs-selected language.
    ///
    /// SharedPlayerManager and media-surface observers **read** this surface; they must not
    /// reimplement soft-pause / generation rules. Mutation stays inside DirectStreamingPlayer
    /// stop / attach / resume paths.
    ///
    /// | Field | Meaning |
    /// |-------|---------|
    /// | `generation` | Monotonic attach generation; advanced on every stop |
    /// | `isInFlight` | Attach/start path suspended across `await` |
    /// | `isSoftPaused` | Secured item retained at rate 0 (same-stream resume eligible) |
    /// | `attachedItemLanguageCode` | Language bound to the current/soft-paused item |
    /// | `selectedStreamLanguageCode` | Current model selection |
    /// | `requiresStreamReattach` | Attached language ≠ selected → full attach required |
    ///
    /// - SeeAlso: ``currentPlaybackAttachState()``, ``softPauseResumeRequiresStreamReattach()``,
    ///   ``resumeFromSoftPauseIfAvailable()``, ``PlaybackPlayDecision``, SharedPlayerManager.play().
    struct PlaybackAttachState: Sendable, Equatable {
        let generation: UInt64
        let isInFlight: Bool
        let isSoftPaused: Bool
        let attachedItemLanguageCode: String?
        let selectedStreamLanguageCode: String

        /// True when a soft-paused or attached item targets a different language than the model.
        var requiresStreamReattach: Bool {
            guard let attached = attachedItemLanguageCode else { return false }
            return attached != selectedStreamLanguageCode
        }

        /// Soft-pause holds an item whose language matches selection (gapless resume candidate).
        var canSoftResumeSameStream: Bool {
            isSoftPaused && !requiresStreamReattach && attachedItemLanguageCode != nil
        }
    }

    /// Captures the current attach / soft-pause surface for observers (MainActor).
    ///
    /// - Returns: Immutable ``PlaybackAttachState`` snapshot.
    /// - SeeAlso: ``softPauseResumeRequiresStreamReattach()``, SharedPlayerManager.play().
    @MainActor
    func currentPlaybackAttachState() -> PlaybackAttachState {
        PlaybackAttachState(
            generation: playbackAttachGeneration,
            isInFlight: isCurrentlyAttemptingPlayback,
            isSoftPaused: isSoftPaused,
            attachedItemLanguageCode: attachedItemLanguageCode,
            selectedStreamLanguageCode: selectedStream.languageCode
        )
    }

    // MARK: - Stream choice + attach (canonical)

    /// Prepares a stream choice without starting audible attach.
    ///
    /// Canonical engine entry for model-only seed and orchestrated language-switch prep.
    /// Prefer this over the legacy wrappers when writing new call sites.
    ///
    /// - Parameters:
    ///   - stream: Target stream model (language / URL template).
    ///   - preparation: ``StreamChoicePreparation/modelOnly`` or ``StreamChoicePreparation/switchPrep``.
    /// - SeeAlso: ``StreamChoicePreparation``, ``attachAndPlay(to:context:)``,
    ///   ``switchToStream(_:)``, ``setSelectedStreamModelOnly(to:)``,
    ///   SharedPlayerManager.play(), RadioPlayerCoordinator stream-switch paths.
    ///
    /// AGENT NOTE: This is the only place model-only update and switch-prep (silent stop +
    /// counter reset) are allowed. Callers must not reimplement setModel + stop + counterReset.
    @MainActor
    func prepareStreamChoice(_ stream: Stream, preparation: StreamChoicePreparation) async {
        switch preparation {
        case .modelOnly:
            // Under test we still allow the pure model update (no network, no AV work).
            lastEmittedStatus = nil
            lastObservedTimeControl = nil
            lastObservedItemStatus = nil
            selectedStream = stream
            #if DEBUG
            print("[DirectStreamingPlayer] prepareStreamChoice(.modelOnly) for \(stream.language)")
            #endif

        case .switchPrep:
            let previousLanguage = selectedStream.languageCode
            let newLanguage = stream.languageCode
            let isLanguageChange = previousLanguage != newLanguage

            await prepareStreamChoice(stream, preparation: .modelOnly)
            resetTransientErrors()

            if isLanguageChange {
                #if DEBUG
                print("[DirectStreamingPlayer] prepareStreamChoice(.switchPrep) — silent .streamSwitch stop (\(previousLanguage) → \(newLanguage))")
                #endif
                await withCheckedContinuation { continuation in
                    stop(
                        reason: .streamSwitch,
                        completion: { continuation.resume() },
                        silent: true
                    )
                }
            }

            resetInitialPlaybackCountersForNewStream()

            #if DEBUG
            print("[DirectStreamingPlayer] prepareStreamChoice(.switchPrep) complete for \(newLanguage)")
            #endif
        }
    }

    /// Full atomic "prepare secured item + start playing" — primary attach entry for ``SharedPlayerManager/play()``.
    ///
    /// Prepares `stream` and starts attach under the same in-flight generation as recovery ``play()``.
    /// User pause while this method is suspended advances ``playbackAttachGeneration``; post-await
    /// re-checks discard the attach so sticky `.userPaused` cannot race a late first-play kick.
    ///
    /// - Parameters:
    ///   - stream: Target stream model (language / URL template).
    ///   - context: Cold launch, stream switch, or same-stream resume attach semantics.
    /// - SeeAlso: ``prepareStreamChoice(_:preparation:)``, ``startPlayback(context:attachGeneration:)``,
    ///   ``shouldContinueInFlightAttach(startedAt:)``, ``PlaybackAttachState``,
    ///   ``SharedPlayerManager/play()``.
    ///
    /// - Note: MainActor-isolated with ``play()`` so attach generation begin/end and silence
    ///   enforcement are same-isolation (no redundant `await` on synchronous MainActor helpers).
    @MainActor
    func attachAndPlay(to stream: Stream, context: PlaybackAttachContext = .coldLaunch) async {
        // UI Test isolation: never attach real items or start playback from the engine.
        // SharedPlayerManager.play() already short-circuits before reaching here for
        // explicit test taps; this guard protects any direct callers or future paths.
        guard !isTesting else {
            #if DEBUG
            print("[DirectStreamingPlayer] attachAndPlay — isTesting, no-op (no network, no AVPlayer work)")
            #endif
            return
        }

        // Cover the primary attach path (not only recovery `play()`) so stop during
        // connect/first-play can invalidate generation and soft-silence consistently.
        let attachGeneration = beginInFlightPlaybackAttach()
        await prepareSecuredPlayerItem(for: stream)

        guard await shouldContinueInFlightAttach(startedAt: attachGeneration) else {
            enforceSilenceAfterDiscardedAttach()
            endInFlightPlaybackAttach()
            return
        }

        await startPlayback(context: context, attachGeneration: attachGeneration)
        endInFlightPlaybackAttach()
    }

    /// Legacy name for ``prepareStreamChoice(_:preparation:)`` with ``StreamChoicePreparation/switchPrep``.
    ///
    /// - SeeAlso: ``prepareStreamChoice(_:preparation:)``, RadioPlayerCoordinator stream-switch paths.
    @MainActor
    func switchToStream(_ stream: Stream) async {
        #if DEBUG
        print("[DirectStreamingPlayer] switchToStream → prepareStreamChoice(.switchPrep)")
        #endif
        await prepareStreamChoice(stream, preparation: .switchPrep)
    }

    /// Legacy name for ``prepareStreamChoice(_:preparation:)`` with ``StreamChoicePreparation/modelOnly``.
    /// Used on cold launch before tuning so the secured item is created once in ``attachAndPlay``.
    func setSelectedStreamModelOnly(to stream: Stream) async {
        #if DEBUG
        print("[DirectStreamingPlayer] setSelectedStreamModelOnly → prepareStreamChoice(.modelOnly)")
        #endif
        await prepareStreamChoice(stream, preparation: .modelOnly)
    }

    /// Legacy name for ``attachAndPlay(to:context:)``. Prefer ``attachAndPlay`` in new code.
    @MainActor
    func setStreamAndPlay(to stream: Stream, context: PlaybackAttachContext = .coldLaunch) async {
        #if DEBUG
        print("[DirectStreamingPlayer] setStreamAndPlay → attachAndPlay")
        #endif
        await attachAndPlay(to: stream, context: context)
    }

    /// Updates the selected stream model and prepares the secured player item (no audible start).
    ///
    /// Internal attach helper used by ``attachAndPlay(to:context:)``. Prefer the canonical
    /// ``prepareStreamChoice`` + ``attachAndPlay`` pair at call sites.
    @MainActor
    func setStream(to stream: Stream) async {
        await prepareSecuredPlayerItem(for: stream)
    }

    /// Model update + optional clean stop + secured `AVPlayerItem` prepare (no audible kick).
    @MainActor
    func prepareSecuredPlayerItem(for stream: Stream) async {
        // UI Test isolation: prevent even model-only prepares from triggering
        // urlWithOptimalServer (which may ping) or AVURLAsset/resourceLoader work.
        guard !isTesting else {
            selectedStream = stream
            #if DEBUG
            print("[DirectStreamingPlayer] prepareSecuredPlayerItem — isTesting, model updated but no network/asset work")
            #endif
            return
        }

        let modelLanguage = selectedStream.languageCode
        let attachedLanguage = attachedItemLanguageCode
        let newLanguage = stream.languageCode
        let attachedMismatch = attachedLanguage.map { $0 != newLanguage } ?? false
        let modelChanged = modelLanguage != newLanguage
        let needsCleanStop = attachedMismatch || modelChanged

        #if DEBUG
        let fromLanguage = attachedLanguage ?? modelLanguage
        print("ATOMIC STREAM SWITCH: \(fromLanguage) → \(newLanguage)")
        #endif

        if needsCleanStop {
            #if DEBUG
            if attachedMismatch {
                print("[DirectStreamingPlayer] Attached item language mismatch — performing clean stop")
            } else {
                print("[DirectStreamingPlayer] Real stream switch detected – performing clean stop")
            }
            #endif

            isSwitchingStream = true
            defer { isSwitchingStream = false }

            isSoftPaused = false

            if playerItem != nil || attachedLanguage != nil {
                stop(reason: .streamSwitch, silent: true)
            }
        } else {
            #if DEBUG
            print("[DirectStreamingPlayer] Same stream or initial playback (\(newLanguage)) – skipping stop()")
            #endif
        }

        lastEmittedStatus = nil
        lastObservedTimeControl = nil
        lastObservedItemStatus = nil

        selectedStream = stream

        let url = await urlWithOptimalServer(for: stream)
        await preparePlayerItem(for: url)

        #if DEBUG
        print("[DirectStreamingPlayer] Stream model updated and secured AVPlayerItem prepared for \(stream.language)")
        #endif
    }

    /// Cancels any pending startup safety-net recreate (e.g. before sleep-timer scheduling).
    func cancelPendingStartupRecovery() {
        Task { @MainActor [weak self] in
            self?.cancelStartupSafetyNet()
        }
    }

    /// True when a soft-paused or attached item targets a different language than `selectedStream`.
    ///
    /// Delegates to ``currentPlaybackAttachState()`` so SPM does not reimplement language binding.
    @MainActor
    func softPauseResumeRequiresStreamReattach() -> Bool {
        currentPlaybackAttachState().requiresStreamReattach
    }

    @MainActor
    func bindAttachedItemToSelectedStream() {
        attachedItemLanguageCode = selectedStream.languageCode
    }

    @MainActor
    func clearAttachedItemBinding() {
        attachedItemLanguageCode = nil
    }

    /// Resumes a same-stream pause without recreating the secured `AVPlayerItem`.
    @MainActor
    func resumeFromSoftPauseIfAvailable() async -> Bool {
        // UI Test isolation: never resume real audio from soft-pause under test.
        guard !isTesting else { return false }

        guard isSoftPaused, playerItem != nil, player?.currentItem != nil else { return false }
        guard !softPauseResumeRequiresStreamReattach() else {
            isSoftPaused = false
            #if DEBUG
            print("[DirectStreamingPlayer] Soft-pause resume declined — attached item language (\(attachedItemLanguageCode ?? "nil")) != selected stream (\(selectedStream.languageCode))")
            #endif
            return false
        }
        guard await SharedPlayerManager.shared.canProceedWithPlayback() else { return false }

        isSoftPaused = false
        cancelStartupSafetyNet()

        guard let player else { return false }
        player.play()
        player.rate = 1.0
        player.playImmediately(atRate: 1.0)
        safeOnStatusChange(isPlaying: true, reasonKey: "status_playing")
        hasStartedPlaying = true
        // Authoritative chrome only after the rate kick — never from SharedPlayerManager.play()
        // before soft-resume returns (Connecting must not claim rate 1 / pause glyph while silent).
        await publishAuthoritativePlayingIfNeeded()

        #if DEBUG
        print("[DirectStreamingPlayer] Resumed from soft pause — skipped item recreation")
        #endif
        return true
    }

    #if DEBUG
    func debugAttachContextLabel(_ context: PlaybackAttachContext) -> String {
        switch context {
        case .coldLaunch: return "cold launch"
        case .streamSwitch: return "stream switch"
        case .resume: return "resume"
        @unknown default: return "attach"
        }
    }
    #endif

    func ensurePlayerExists() {
        if self.player == nil {
            #if DEBUG
            print("[DirectStreamingPlayer] Creating new AVPlayer instance")
            #endif
            
            let newPlayer = AVPlayer()
            newPlayer.automaticallyWaitsToMinimizeStalling = true
            self.player = newPlayer
            
            // Optional: Set volume from your slider
            // newPlayer.volume = Float(currentVolume)
        }
    }

    /// Private: Actually starts the player + handles session under a live attach generation.
    ///
    /// - Parameters:
    ///   - context: Cold launch, stream switch, or resume attach semantics.
    ///   - attachGeneration: Snapshot from ``beginInFlightPlaybackAttach()``; discarded after
    ///     user pause via ``invalidateInFlightPlaybackAttach()``.
    /// - SeeAlso: ``shouldContinueInFlightAttach(startedAt:)``, ``shouldAllowAudiblePlaybackKick()``.
    func startPlayback(context: PlaybackAttachContext = .coldLaunch, attachGeneration: UInt64) async {
        // UI Test isolation (defense-in-depth).
        guard !isTesting else {
            #if DEBUG
            print("[DirectStreamingPlayer] startPlayback — isTesting, early return (no audio session activation, no player.play)")
            #endif
            return
        }

        // ──────────────────────────────────────────────────────────────
        // Generation + intent: user pause during setStream / prior await must discard attach.
        // Sticky .userPaused / .securityLocked / .cleared (privacy clear) behavior preserved exactly.
        guard await shouldContinueInFlightAttach(startedAt: attachGeneration) else {
            #if DEBUG
            print("[DirectStreamingPlayer] startPlayback: discarded — generation or playbackIntent")
            #endif
            await enforceSilenceAfterDiscardedAttach()
            return
        }
        // ──────────────────────────────────────────────────────────────

        // Fresh playback attempt — clear dedup state so the first status we emit
        // (e.g. "status_connecting" or "status_playing") is never incorrectly suppressed.
        lastEmittedStatus = nil
        lastObservedTimeControl = nil
        lastObservedItemStatus = nil

        // Pre-compute the optimal URL (ensures server, bakes the host into the URL value).
        // We do this here (outside MainActor.run) so the run closure stays synchronous,
        // matching every other MainActor.run site in the file and avoiding overload resolution
        // issues under the widget extension's compilation context.
        let coldLaunchURL = await urlWithOptimalServer(for: selectedStream)
        guard await shouldContinueInFlightAttach(startedAt: attachGeneration) else {
            await enforceSilenceAfterDiscardedAttach()
            return
        }

        // Configure session using the reusable async helper (SSOT) before AVPlayer work.
        // (Eliminates prior direct top-level synchronous setActive calls from hot paths.)
        _ = await configureAudioSessionAsync()
        guard await shouldContinueInFlightAttach(startedAt: attachGeneration) else {
            await enforceSilenceAfterDiscardedAttach()
            return
        }

        await MainActor.run {
            ensurePlayerExists()
            
            guard let player = self.player else {
                #if DEBUG
                print("[DirectStreamingPlayer] No AVPlayer instance available")
                #endif
                return
            }
            
            // Item should already exist from setStream (secured preparePlayerItem). Attach only as fallback.
            if player.currentItem == nil {
                #if DEBUG
                print("[DirectStreamingPlayer] \(debugAttachContextLabel(context)): no currentItem after AVPlayer init → attaching fresh item")
                #endif
                
                let newItem = self.makeSecuredPlayerItem(for: coldLaunchURL)
                player.replaceCurrentItem(with: newItem)
                self.playerItem = newItem
                self.bindAttachedItemToSelectedStream()
                self.clearPlaybackTeardownGuard()
                self.setupPlaybackObservers()
                self.addObservers()
                
                #if DEBUG
                print("[DirectStreamingPlayer] attached fresh AVPlayerItem (\(debugAttachContextLabel(context)))")
                #endif
            } else {
                #if DEBUG
                print("[DirectStreamingPlayer] reusing secured AVPlayerItem from setStream")
                #endif
                // preparePlayerItem already ran setupPlaybackObservers; only attach item-level observers.
                self.addObservers()
            }
            
            player.automaticallyWaitsToMinimizeStalling = false
            // Defer the first audible kick until AVPlayerItem.status == .readyToPlay.
            // Do not call play() here — AVPlayer begins loading the attached item automatically;
            // playImmediately in addObservers' readyToPlay handler is the single audible kick.
            // That kick re-checks shouldAllowAudiblePlaybackKick() so user pause during connect wins.
            self.isDeferringFirstPlayKick = true
            self.hasReceivedLiveStreamMetadata = false
            self.cancelEarlyICYDropRecreate()
            // Loading grace clock for early-window stall patience (stream-switch + cold launch).
            self.currentAttachBeganAt = Date()
            self.safeOnStatusChange(isPlaying: false, reasonKey: "status_connecting")
            
            #if DEBUG
            print("[DirectStreamingPlayer] startPlayback: awaiting readyToPlay before first play kick (item.status: \(player.currentItem?.status.rawValue ?? -1))")
            #endif
        }
        
        // Optional ICY head-start retry — only when the first kick has not achieved playback.
        if context != .resume {
            try? await Task.sleep(for: .milliseconds(400))
            
            let headStartGeneration = attachGeneration
            Task { @MainActor in
                guard let player = self.player else { return }
                
                // Generation must still match (stop during the 400 ms sleep invalidates attach).
                guard await self.shouldContinueInFlightAttach(startedAt: headStartGeneration) else {
                    #if DEBUG
                    print("[DirectStreamingPlayer] post-head-start: discarded — generation or playbackIntent")
                    #endif
                    self.enforceSilenceAfterDiscardedAttach()
                    return
                }
                guard await self.shouldAllowAudiblePlaybackKick() else { return }

                let itemReady = player.currentItem?.status == .readyToPlay
                let alreadyPlaying = self.hasStartedPlaying || player.rate > 0.1
                guard !alreadyPlaying else {
                    #if DEBUG
                    print("[DirectStreamingPlayer] post-head-start: skipped — playback already active (hasStartedPlaying=\(self.hasStartedPlaying), rate=\(player.rate))")
                    #endif
                    return
                }
                
                guard itemReady else {
                    #if DEBUG
                    print("[DirectStreamingPlayer] post-head-start: skipped — item not ready yet, deferring to readyToPlay observer")
                    #endif
                    return
                }
                
                player.playImmediately(atRate: 1.0)
                self.isDeferringFirstPlayKick = false
                self.hasStartedPlaying = true
                self.safeOnStatusChange(isPlaying: true, reasonKey: "status_playing")
                await self.publishAuthoritativePlayingIfNeeded()
                #if DEBUG
                print("[DirectStreamingPlayer] post-head-start playImmediately called (ready fallback, item.status: \(player.currentItem?.status.rawValue ?? -1))")
                #endif
            }
        }
        
        // Only the single lightweight safety net (below) remains as true last resort.
        
        // Startup safety net: first-play attach only (cold launch or stream switch).
        // Same-stream resume uses soft pause and must not schedule a stale recreate.
        if (context == .coldLaunch || context == .streamSwitch) && initialPlaybackRetryCount == 0 {
            Task { @MainActor in
                #if DEBUG
                print("[DirectStreamingPlayer] scheduling startup safety net (single last resort)")
                #endif
                self.scheduleStartupSafetyNet()
            }
        }
        
        // Do not publish `.playing` here. Item is still loading (`isDeferringFirstPlayKick`);
        // status is `status_connecting`. Authoritative chrome is published from the readyToPlay
        // first-play kick (or soft-resume) via ``publishAuthoritativePlayingIfNeeded()``.
        #if DEBUG
        print("[DirectStreamingPlayer] startPlayback: deferred setPlaying until readyToPlay audible kick")
        #endif
    }

    // MARK: - In-flight attach generation (user pause completeness)

    /// Marks the start of an attach attempt and returns the generation to re-check after each `await`.
    ///
    /// - Returns: The current ``playbackAttachGeneration`` snapshot for this attempt.
    /// - Postcondition: ``isCurrentlyAttemptingPlayback`` is `true` until ``endInFlightPlaybackAttach()``.
    /// - SeeAlso: ``shouldContinueInFlightAttach(startedAt:)``, ``invalidateInFlightPlaybackAttach()``.
    @MainActor
    func beginInFlightPlaybackAttach() -> UInt64 {
        isCurrentlyAttemptingPlayback = true
        return playbackAttachGeneration
    }

    /// Clears the in-flight attach flag. Call from `defer` at the end of ``play()`` / ``setStreamAndPlay``.
    @MainActor
    func endInFlightPlaybackAttach() {
        isCurrentlyAttemptingPlayback = false
    }

    /// Advances ``playbackAttachGeneration`` so any in-flight attach discards after its next re-check.
    ///
    /// Called from every ``stop(reason:completion:silent:)`` entry — including soft pause — so sticky
    /// `.userPaused` cannot race a late `play()` / `playImmediately` after security validation or
    /// item attach. Safe from any thread (hops to MainActor when needed).
    ///
    /// - SeeAlso: ``shouldContinueInFlightAttach(startedAt:)``, ``enforceSilenceAfterDiscardedAttach()``.
    func invalidateInFlightPlaybackAttach() {
        let bump: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.playbackAttachGeneration &+= 1
            #if DEBUG
            print("[DirectStreamingPlayer] playbackAttachGeneration advanced → \(self.playbackAttachGeneration) (in-flight attach invalidated)")
            #endif
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(bump)
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated(bump) }
        }
    }

    /// Returns whether an attach attempt started at `generation` may still proceed to audible output.
    ///
    /// - Parameters:
    ///   - generation: Snapshot from ``beginInFlightPlaybackAttach()`` (or an equivalent capture).
    /// - Returns: `true` only when the generation is still current **and**
    ///   ``SharedPlayerManager/canProceedWithPlayback()`` allows audio (not sticky pause/lock).
    /// - Important: Call after every significant `await` on the start path (security validation,
    ///   server selection, audio-session activation, stream model mutation). Fail closed: pause
    ///   chrome + silent engine is correct; "paused chrome + audible stream" is not.
    /// - SeeAlso: ``canProceedWithPlayback()``, ``invalidateInFlightPlaybackAttach()``.
    @MainActor
    func shouldContinueInFlightAttach(startedAt generation: UInt64) async -> Bool {
        guard generation == playbackAttachGeneration else {
            #if DEBUG
            print("[DirectStreamingPlayer] in-flight attach discarded — generation advanced (stop/user pause raced attach)")
            #endif
            return false
        }
        guard await SharedPlayerManager.shared.canProceedWithPlayback() else {
            #if DEBUG
            print("[DirectStreamingPlayer] in-flight attach discarded — playbackIntent blocks (sticky pause/lock)")
            #endif
            return false
        }
        return true
    }

    /// Soft-silences the engine after an attach attempt is discarded mid-flight.
    ///
    /// Keeps a secured item when present (``isSoftPaused``) so same-stream resume remains available,
    /// clears deferred first-play kick and startup recovery, and never starts audio.
    ///
    /// - Postcondition: `player.rate == 0`, deferred kick cleared, soft-pause flag set when an item exists.
    /// - SeeAlso: ``performActualStop(reason:completion:silent:)``, soft-pause resume path.
    @MainActor
    func enforceSilenceAfterDiscardedAttach() {
        cancelStartupSafetyNet()
        cancelEarlyICYDropRecreate()
        isDeferringFirstPlayKick = false
        hasStartedPlaying = false
        player?.pause()
        player?.rate = 0.0
        if playerItem != nil {
            isSoftPaused = true
        }
        lastEmittedStatus = nil
        lastObservedTimeControl = nil
        lastObservedItemStatus = nil
        safeOnStatusChange(isPlaying: false, reasonKey: "status_stopped")
        #if DEBUG
        print("[DirectStreamingPlayer] enforceSilenceAfterDiscardedAttach — rate 0, soft-paused=\(isSoftPaused)")
        #endif
    }

    /// Shared gate for any path that would make the stream audible (readyToPlay kick, head-start,
    /// recreate restart). Blocks when soft-paused, teardown is active, or sticky intent forbids play.
    ///
    /// - Returns: `true` when an audible kick is allowed.
    /// - SeeAlso: ``shouldContinueInFlightAttach(startedAt:)``, ``canProceedWithPlayback()``.
    @MainActor
    func shouldAllowAudiblePlaybackKick() async -> Bool {
        guard !isSoftPaused else {
            #if DEBUG
            print("[DirectStreamingPlayer] audible kick suppressed — soft-paused")
            #endif
            return false
        }
        guard !isPlaybackTeardownActive else {
            #if DEBUG
            print("[DirectStreamingPlayer] audible kick suppressed — playback teardown active")
            #endif
            return false
        }
        guard await SharedPlayerManager.shared.canProceedWithPlayback() else {
            #if DEBUG
            print("[DirectStreamingPlayer] audible kick suppressed — playbackIntent blocks")
            #endif
            return false
        }
        return true
    }

    /// Publishes authoritative `.playing` chrome after the engine has started or resumed audible output.
    ///
    /// Call only after a rate kick / soft-resume `playImmediately` (or equivalent KVO observation of
    /// live play). Skips when sticky pause/lock already won or visual is already `.playing` so
    /// readyToPlay + timeControl KVO cannot double-emit `streamDidStart` or thrash surfaces.
    ///
    /// - Important: Never call from the start of ``SharedPlayerManager/play()`` or from
    ///   ``startPlayback(context:attachGeneration:)`` while still awaiting `.readyToPlay`.
    /// - SeeAlso: ``SharedPlayerManager/setPlaying()``, ``shouldAllowAudiblePlaybackKick()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md (connecting chrome vs audible start),
    ///   ``MediaTransportLatencyTimeline`` (DEBUG first-audio milestone).
    @MainActor
    func publishAuthoritativePlayingIfNeeded() async {
        guard await SharedPlayerManager.shared.canProceedWithPlayback() else {
            #if DEBUG
            print("[DirectStreamingPlayer] publishAuthoritativePlayingIfNeeded skipped — sticky pause/lock")
            MediaTransportLatencyTimeline.mark(
                .authoritativePlayingSkipped,
                detail: "reason=stickyPauseOrLock"
            )
            #endif
            return
        }
        let visual = await SharedPlayerManager.shared.currentVisualState
        guard visual != .playing else {
            #if DEBUG
            print("[DirectStreamingPlayer] publishAuthoritativePlayingIfNeeded no-op — already .playing")
            MediaTransportLatencyTimeline.mark(
                .authoritativePlayingSkipped,
                detail: "reason=alreadyPlaying"
            )
            #endif
            return
        }
        await SharedPlayerManager.shared.setPlaying()
        #if DEBUG
        print("[DirectStreamingPlayer] publishAuthoritativePlayingIfNeeded → setPlaying after audible start")
        MediaTransportLatencyTimeline.mark(.authoritativePlayingPublished)
        #endif
    }

    #if DEBUG
    /// Test seam: begin an in-flight attach and return the generation snapshot.
    @MainActor
    func test_beginInFlightPlaybackAttach() -> UInt64 {
        beginInFlightPlaybackAttach()
    }

    /// Test seam: clear the in-flight attach flag.
    @MainActor
    func test_endInFlightPlaybackAttach() {
        endInFlightPlaybackAttach()
    }

    /// Test seam: invalidate in-flight attach (same as stop entry).
    func test_invalidateInFlightPlaybackAttach() {
        invalidateInFlightPlaybackAttach()
    }

    /// Test seam: generation + intent re-check used after awaits on the start path.
    @MainActor
    func test_shouldContinueInFlightAttach(startedAt generation: UInt64) async -> Bool {
        await shouldContinueInFlightAttach(startedAt: generation)
    }

    /// Test seam: audible kick gate (readyToPlay / head-start / recreate).
    @MainActor
    func test_shouldAllowAudiblePlaybackKick() async -> Bool {
        await shouldAllowAudiblePlaybackKick()
    }

    /// Test seam: publish `.playing` only when not already playing (readyToPlay / soft-resume contract).
    @MainActor
    func test_publishAuthoritativePlayingIfNeeded() async {
        await publishAuthoritativePlayingIfNeeded()
    }

    /// Test seam: await soft-pause / hard-stop completion (production ``stopAndWait``).
    @MainActor
    func test_stopAndWait(
        reason: StopReason = .userAction,
        silent: Bool = false,
        applyUserPauseVisualLock: Bool = true
    ) async {
        await stopAndWait(
            reason: reason,
            silent: silent,
            applyUserPauseVisualLock: applyUserPauseVisualLock
        )
    }

    @MainActor
    var test_playbackAttachGeneration: UInt64 { playbackAttachGeneration }

    @MainActor
    var test_isCurrentlyAttemptingPlayback: Bool { isCurrentlyAttemptingPlayback }

    /// Test seam: soft-pause flag set when user pause retains a secured item path.
    @MainActor
    var test_isSoftPaused: Bool { isSoftPaused }

    /// Test seam: AVPlayer rate after soft silence (nil when no player is attached).
    @MainActor
    var test_playerRate: Float? { player?.rate }

    /// Test seam: early-window retry budget consumed so far for the current attach.
    @MainActor
    var test_initialPlaybackRetryCount: Int { initialPlaybackRetryCount }

    /// Test seam: hard cap shared by early-window recovery and the startup safety net.
    @MainActor
    var test_maxInitialRetries: Int { maxInitialRetries }

    /// Test seam: reset counters + loading grace for a fresh attach (stream-switch / cold).
    @MainActor
    func test_resetInitialPlaybackCountersForNewStream() {
        resetInitialPlaybackCountersForNewStream()
        currentAttachBeganAt = nil
    }

    /// Test seam: mark attach clock as if a secured item just attached.
    @MainActor
    func test_markCurrentAttachBegan(at date: Date = Date()) {
        currentAttachBeganAt = date
    }

    /// Test seam: stall-class early recovery gate (loading grace + item status).
    @MainActor
    func test_shouldAttemptEarlyAttachStallRecovery(item: AVPlayerItem, rate: Float) -> Bool {
        shouldAttemptEarlyAttachStallRecovery(item: item, rate: rate)
    }

    /// Test seam: early-window recovery admission (increments budget when it returns true).
    @MainActor
    @discardableResult
    func test_attemptEarlyWindowTransientRecovery(
        reason: String,
        allowWhileDeferringFirstPlayKick: Bool
    ) async -> Bool {
        // Under UITestMode there is usually no real item to recreate; we still exercise the
        // budget / intent / teardown gates. recreatePlayerItem no-ops without a URL asset.
        await attemptEarlyWindowTransientRecovery(
            reason: reason,
            allowWhileDeferringFirstPlayKick: allowWhileDeferringFirstPlayKick
        )
    }
    #endif
}
