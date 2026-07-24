//
//  SharedPlayerManager+PlaybackPipeline.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 23.7.2026.
//
//  SHARED: Cross-target membership-exception source (main app + extension +
//  LutheranRadioWidgetTests). Mechanical split of SharedPlayerManager — same actor,
//  no API renames, no behavior change.
//
//  Purpose: Playback intent checks, public play/stop/switch API, visual-state mutations, and private playback helpers.
//
//  - SeeAlso: SharedPlayerManager.swift, CODING_AGENT.md (cross-target membership exceptions).
//

import Foundation
import Core
import WidgetSurface
#if LUTHERAN_MAIN_APP
import os
import WidgetKit
#endif

extension SharedPlayerManager {
    // MARK: - Intent-Driven Playback Execution

    /// Returns whether the player execution engine (DirectStreamingPlayer) should
    /// be allowed to start, resume, or recover playback right now.
    ///
    /// This is the **preferred** intent-driven check for all playback command paths.
    /// It is driven exclusively by `currentPlaybackIntent` (the single source of truth
    /// updated only via `updatePlaybackIntent(to:)`).
    ///
    /// Callers (DirectStreamingPlayer) should use this instead of deriving decisions
    /// from `currentVisualState.shouldAutoPlayOrResume` where possible.
    ///
    /// Sticky rules are preserved exactly: `.userPaused`, `.securityLocked`, and `.cleared`
    /// (privacy clear) are permanent blockers (via isStickyPauseOrLock) until an explicit user play
    /// action clears them. For `.cleared` the visual is the dedicated .cleared (blue) so the
    /// current session shows explicit reset confirmation; the intent alone blocks; cold-launch
    /// (no snapshot) sees .prePlay.
    /// `.sleepTimer` permits execution only while visual state is still `.playing`
    /// (active countdown); after the timer fires, explicit play is required.
    func canProceedWithPlayback() async -> Bool {
        ensureVisualStateLoaded()
        if currentPlaybackIntent.isStickyPauseOrLock { return false }
        if currentPlaybackIntent == .sleepTimer {
            return currentVisualState == .playing || holdPrePlayVisualUntilPlayback
        }
        return currentPlaybackIntent == .shouldBePlaying
    }

    /// Returns whether the user paused within the given interval (default 8 s).
    ///
    /// Reads the in-actor ``lastUserPauseTimestamp`` only. Retired App Group
    /// `lastUserPauseTime` is never consulted (purged on launch; no writers).
    ///
    /// - Parameter interval: Maximum age in seconds for a pause to count as "recent".
    /// - Returns: `true` when an in-session pause was recorded within `interval`.
    /// - SeeAlso: ``recordUserPauseTimestamp()``, ``Constants/recentUserPauseBarrier``
    func wasRecentlyUserPaused(within interval: TimeInterval = Constants.recentUserPauseBarrier) async -> Bool {
        // For true cold-launch or first recovery before any pause has been recorded,
        // treat as "not recently paused".
        guard lastUserPauseTimestamp > 0 else { return false }
        return Date().timeIntervalSince1970 - lastUserPauseTimestamp < interval
    }

    /// Records an explicit user pause into the in-actor recovery barrier.
    ///
    /// Call from main-app pause surfaces (widget drain, coordinator, stop paths that
    /// already set intent elsewhere). Does **not** write App Group keys — the former
    /// `lastUserPauseTime` disk signal is retired with no remaining readers.
    ///
    /// - SeeAlso: ``wasRecentlyUserPaused(within:)``, `RadioPlayerCoordinator.handleWidgetPauseAction()`
    nonisolated func recordUserPauseTimestamp() async {
        await _recordUserPauseTimestampInternal()
    }
    
    internal func _recordUserPauseTimestampInternal() async {
        lastUserPauseTimestamp = Date().timeIntervalSince1970
    }

    /// Single internal entry point for all playback intent transitions.
    ///
    /// This is the **only** place that mutates the private `playbackIntent` backing
    /// store. All explicit user actions and sticky state changes must flow through here.
    ///
    /// After the intent is updated, `emit(.playbackIntentChanged(intent))` is called
    /// so that the authoritative `PlayerEvent` is delivered to all observers.
    ///
    /// - Parameter intent: The new authoritative intent.
    ///
    /// - Postcondition: `currentPlaybackIntent` reflects the value (sticky rules
    ///   for userPaused/securityLocked/cleared are enforced by callers before calling).
    ///   A `playbackIntentChanged` event has been emitted when the value actually changed.
    ///
    /// - SeeAlso: ``currentPlaybackIntent``, ``canProceedWithPlayback()``, ``emit(_:)``,
    ///   ``events``, CODING_AGENT.md.
    ///
    /// Internal to the actor.
    internal func updatePlaybackIntent(to intent: PlaybackIntent) {
        if playbackIntent != intent {
            #if DEBUG
            print("[SharedPlayerManager] playbackIntent: \(playbackIntent) → \(intent)")
            #endif
            playbackIntent = intent
            // Emit because a change to the current playback intent is a significant
            // domain transition observed by widgets, Live Activities, and UI.
            emit(.playbackIntentChanged(intent))
        }
    }
    
}

extension SharedPlayerManager {
    // MARK: - Public Async API
    //
    // These are the primary methods called by the main app, DirectStreamingPlayer recovery logic,
    // user intent paths, and widget action handlers (after they have performed their optimistic updates).

    /// Safe, single entry point to change the visual state from anywhere.
    /// (Notification handlers, MainActor, background tasks, etc.)
    ///
    /// - Postcondition: `currentVisualState` updated (with special thermal handling);
    ///   `.visualStateDidChange` emitted.
    ///
    /// - SeeAlso: ``applyVisualState(_:)``, ``currentVisualState``, `PlayerEvent.visualStateDidChange`,
    ///   CODING_AGENT.md, docs/Event-Driven-Refactor-Roadmap.md.
    ///
    /// AGENT NOTE: All significant visual transitions should prefer this entry or the
    /// internal apply helper so that emission is centralized and never duplicated.
    func setVisualState(_ state: PlayerVisualState) async {
        #if LUTHERAN_MAIN_APP
        if state == .thermalPaused {
            await cancelSleepTimer()
        }
        #endif
        applyVisualState(state)
    }

    /// Internal helper that performs the visual state assignment and emits the change event.
    ///
    /// Centralizes Tier 1 emission for `visualStateDidChange`. Used by `setVisualState`
    /// and by direct transition sites inside the actor after their semantic mutation.
    ///
    /// - Postcondition: `currentVisualState` set; event yielded if continuation active.
    internal func applyVisualState(_ state: PlayerVisualState) {
        currentVisualState = state
        emit(.visualStateDidChange(state))
    }
    
    /// Public async entry point for playing / resuming (the execution engine).
    ///
    /// This is the central implementation of playback start. It is **not** the public
    /// entry for new explicit user requests — those must go through `userRequestedPlay()`.
    ///
    /// Responsibilities (order matters for resurrection / one-shot / intent correctness):
    /// - ensureVisualStateLoaded + (main) configureNowPlaying + cancelSleep
    /// - `clearUserPausedLockIfNeeded()` (defensive top-level clear)
    /// - Pure early gates via ``PlaybackPlayDecision/evaluateEarlyGates(_:)`` (sentinel, sticky,
    ///   pipeline, already-audible, prePlay one-shot, UITest vs security path)
    /// - Classify context via ``PlaybackPlayDecision/classify`` + attach via ``attachContext``
    /// - Security validation (``SecurityValidationFacade`` `.beforeAttach`) → on fail: securityLocked
    /// - **Re-check sticky pause after validation** (user may pause during the `await`)
    /// - **Keep Connecting chrome** (``.prePlay`` / stream-switch hold) — do **not** call
    ///   ``setPlaying()`` here; rate 1 / pause glyph before audio is a transport lie
    /// - Widget branch (optimistic extension visual) or main: soft-pause resume, alignment, attachAndPlay
    /// - **Re-check sticky pause after tuning wait / soft-resume / immediately before attach**
    /// - Authoritative ``setPlaying()`` only from engine: soft-resume after rate kick, or readyToPlay
    ///   first-play kick (``DirectStreamingPlayer``)
    ///
    /// UITestMode special case: pure early outcome `.enterUITestIsolation` short-circuits *before*
    /// security validation and never reaches attach. Visual transition to .playing is still
    /// performed for explicit userRequestedPlay taps. Auto cold-launch play is prevented earlier
    /// in ViewController.viewDidLoad.
    ///
    /// Direct calls are permitted only for the cases documented on `userRequestedPlay()`.
    ///
    /// - SeeAlso: ``userRequestedPlay()``, ``setUserIntentToPlay()``,
    ///   ``PlaybackPlayDecision``, ``shouldNoOpPlayWhileAlreadyAudible()``,
    ///   ``clearUserPausedLockIfNeeded()``, ``canProceedWithPlayback()``,
    ///   ``attemptResurrectionIfAllowed()``, ``stop()``,
    ///   RadioPlayerCoordinator (canonical switch methods + shims),
    ///   ``isRunningInUITestMode``, ViewController.viewDidLoad,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md (user pause during connect),
    ///   CODING_AGENT.md (test isolation requirements), <doc:Architecture>, <doc:Security-Invariants>.
    ///
    /// AGENT NOTE (SSOT): Early-gate *ordering* lives in ``PlaybackPlayDecision``. After any edit
    /// to pure tables or actor side effects here, re-verify:
    ///   1. widget resume after .userPaused reaches the engine when signaled
    ///   2. cold launch still allowed exactly once via the one-shot + relaxed window
    ///   3. explicit .userPaused remains sticky even inside 25s window
    ///   4. pause during validation / attach never leaves play proceeding to audible start
    ///   5. second play while already audible is a no-op even when resurrection is relaxed
    /// Cross-update the resurrection table, userRequestedPlay doc, and
    /// coordinator architecture comment.
    func play() async {
        ensureVisualStateLoaded()
        let preserveSleepTimerForStreamSwitch =
            holdPrePlayVisualUntilPlayback && currentPlaybackIntent == .sleepTimer
        #if LUTHERAN_MAIN_APP
        await configureNowPlayingControlsIfNeeded()
        if !preserveSleepTimerForStreamSwitch {
            await cancelSleepTimer()
        } else {
            #if DEBUG
            print("[SharedPlayerManager] play() — preserving active sleep timer during stream switch")
            #endif
        }
        #endif
        
        // Note: Always clear .userPaused / .cleared / elapsed-sleep-timer locks at the absolute top of play()
        // This covers widget play, Control Center, lock screen, and Siri — everything.
        await clearUserPausedLockIfNeeded()

        // AGENT NOTE: Explicit user play requests must have already run setUserIntentToPlay()
        // (via `userRequestedPlay()` or by establishing an active playback intent before an
        // internal `play()` call). See the Precondition on `userRequestedPlay()`.

        #if DEBUG
        print("[SharedPlayerManager] SharedPlayerManager.play() ENTERED – currentPlaybackIntent = \(currentPlaybackIntent), currentVisualState = \(currentVisualState)")
        #endif

        let playClassification = PlaybackPlayDecision.classify(
            holdPrePlayVisualUntilPlayback: holdPrePlayVisualUntilPlayback,
            hasCompletedTrueColdLaunchPlay: hasCompletedTrueColdLaunchPlay
        )
        let isStreamSwitchPlay = playClassification == .streamSwitch
        let isTrueColdLaunchPlay = playClassification == .trueColdLaunch
        let isResumePlay = playClassification == .resume
        let resurrectionProtectionRelaxed = !initialPlaybackHasRun ||
            Date().timeIntervalSince(appLaunchTime) < Constants.coldLaunchWindow

        #if DEBUG
        if resurrectionProtectionRelaxed {
            switch playClassification {
            case .trueColdLaunch:
                print("[SharedPlayerManager] Cold-launch first play – resurrection protection relaxed")
            case .streamSwitch:
                print("[SharedPlayerManager] Stream-switch play – resurrection protection relaxed")
            case .resume:
                print("[SharedPlayerManager] Resume play – resurrection protection relaxed")
            }
        }
        #endif

        let alreadyAudible = await shouldNoOpPlayWhileAlreadyAudible()
        let earlyDecision = PlaybackPlayDecision.evaluateEarlyGates(
            PlaybackPlayDecisionInputs(
                hasTerminationSentinel: Self.hasExplicitTerminationSentinel(),
                hasProcessedExplicitUserPlayRequest: hasProcessedExplicitUserPlayRequest,
                isStickyPauseOrLock: currentPlaybackIntent.isStickyPauseOrLock,
                isPlaybackStartPipelineActive: isPlaybackStartPipelineActive,
                alreadyAudibleMatchingSelection: alreadyAudible,
                isPrePlayVisual: currentVisualState == .prePlay,
                initialPlaybackHasRun: initialPlaybackHasRun,
                isActivePlaybackIntent: currentPlaybackIntent.isActivePlaybackIntent,
                isTrueColdLaunchPlay: isTrueColdLaunchPlay,
                isUITestMode: Self.isRunningInUITestMode
            )
        )

        if let setInitial = earlyDecision.setInitialPlaybackHasRun {
            initialPlaybackHasRun = setInitial
        }
        if earlyDecision.markTrueColdLaunchCompleted {
            hasCompletedTrueColdLaunchPlay = true
        }

        switch earlyDecision.outcome {
        case .blockTerminationSentinel:
            #if DEBUG
            print("[SharedPlayerManager] play() BLOCKED — hasExplicitTerminationSentinel() && !hasProcessedExplicitUserPlayRequest (device wake / LA visible / power-up protection)")
            #endif
            return

        case .blockStickyPauseOrLock:
            #if DEBUG
            print("[SharedPlayerManager] play() blocked — explicit \(currentPlaybackIntent) (resurrection bypass ignored)")
            #endif
            clearPlaybackStartPipeline()
            return

        case .skipDuplicateStartPipeline:
            #if DEBUG
            print("[SharedPlayerManager] play() — start pipeline already active, skipping duplicate entry")
            #endif
            return

        case .skipAlreadyAudible:
            #if DEBUG
            print("[SharedPlayerManager] SharedPlayerManager.play() — already audibly playing matching selection, skipping attachAndPlay (idempotent)")
            #endif
            return

        case .skipDuplicateAutomaticPrePlay:
            #if DEBUG
            print("SharedPlayerManager.play() – skipping duplicate automatic prePlay playback")
            #endif
            return

        case .enterUITestIsolation:
            isPlaybackStartPipelineActive = true
            #if DEBUG
            print("[SharedPlayerManager] play() UITestMode — skipping SecurityValidationFacade, attachAndPlay, and all widget/Live Activity work")
            #endif
            clearStreamSwitchPrePlayHold()
            // Only set minimal visual state for test assertions. Do NOT call setPlaying()
            // because it triggers Live Activities and Now Playing.
            if currentPlaybackIntent.isActivePlaybackIntent {
                currentVisualState = .playing
            }
            clearPlaybackStartPipeline()
            return

        case .proceedToSecurityValidation:
            isPlaybackStartPipelineActive = true
            #if DEBUG
            switch playClassification {
            case .streamSwitch:
                print("SharedPlayerManager.play() – stream-switch play, proceeding")
            case .trueColdLaunch:
                print("SharedPlayerManager.play() – cold-launch first play, proceeding")
            case .resume:
                print("SharedPlayerManager.play() – resume play, proceeding")
            }
            #endif
            break
        }

        let isValid = await SecurityValidationFacade.validate(.beforeAttach)
        
        #if DEBUG
        print("🔐 SecurityValidationFacade.beforeAttach returned: \(isValid)")
        if !isValid {
            print("[SharedPlayerManager] Validation failed → bailing out of playback")
        } else {
            print("[SharedPlayerManager] Validation passed → proceeding with playback")
        }
        #endif

        // User may have paused (lock screen / Live Activity / Now Playing / headset) during
        // security validation. Sticky intent wins — do not optimistic-setPlaying or attach.
        if currentPlaybackIntent.isStickyPauseOrLock {
            #if DEBUG
            print("[SharedPlayerManager] play() aborted after security validation — sticky \(currentPlaybackIntent)")
            #endif
            clearPlaybackStartPipeline()
            return
        }
        
        guard isValid else {
            #if DEBUG
            print("[SharedPlayerManager] Permanent security validation failure — locking UI to .securityLocked")
            #endif

            #if LUTHERAN_MAIN_APP
            await cancelSleepTimer(restorePlaybackIntent: false)
            #endif
            
            // Use apply so visualStateDidChange is emitted (Tier 1).
            applyVisualState(.securityLocked)
            
            updatePlaybackIntent(to: .securityLocked)
            clearPlaybackStartPipeline()
            
            await self.saveCurrentState()
            
            #if DEBUG
            print("[SharedPlayerManager] Security lock applied – currentVisualState is now .securityLocked")
            #endif
            return
        }
        
        // Connecting chrome only until the engine has soft-resumed or kicked audible output.
        // Claiming `.playing` here (rate 1, pause glyph, streamDidStart) while security attach or
        // soft-resume is still in flight made lock-screen / Live Activity chrome lie about audio.
        // Stream-switch hold stays true so yellow `.prePlay` persists until ``setPlaying()``.
        // Authoritative sites: `resumeFromSoftPauseIfAvailable`, readyToPlay first-play kick
        // (`publishAuthoritativePlayingIfNeeded`), interruption resume markAsPlaying.
        if currentVisualState != .prePlay
            && currentVisualState != .playing
            && currentPlaybackIntent.isActivePlaybackIntent {
            applyVisualState(.prePlay)
            #if DEBUG
            print("[SharedPlayerManager] play() — connecting chrome (.prePlay) before soft-resume / attach")
            #endif
        }
        #if DEBUG
        if holdPrePlayVisualUntilPlayback {
            print("[SharedPlayerManager] play() — stream-switch prePlay hold retained until engine setPlaying")
        } else {
            print("[SharedPlayerManager] play() — deferring setPlaying until soft-resume or readyToPlay kick")
        }
        #endif
        
        if isRunningInWidget() {
            handleWidgetPlay()
            // Extension does not own engine attach; main-app pipeline state is authoritative there.
            clearPlaybackStartPipeline()
            return
        }
        
        #if LUTHERAN_MAIN_APP
        await waitForTuningSoundIfActive()
        // Pause during tuning sound must not reach attachAndPlay / first-play kick.
        if currentPlaybackIntent.isStickyPauseOrLock {
            #if DEBUG
            print("[SharedPlayerManager] play() aborted after tuning wait — sticky \(currentPlaybackIntent)")
            #endif
            clearPlaybackStartPipeline()
            return
        }
        #endif
        
        #if LUTHERAN_MAIN_APP
        var declinedSoftPauseForLanguageChange = false
        if isResumePlay {
            let resumed = await DirectStreamingPlayer.shared.resumeFromSoftPauseIfAvailable()
            if resumed {
                await rehydrateStreamMetadataFromStashIfNeeded()
                #if DEBUG
                print("[SharedPlayerManager] Resumed from soft pause — skipped attachAndPlay")
                #endif
                // Soft-resume publishes authoritative playing (clears pipeline in setPlaying).
                return
            }
            // Soft-resume may await; re-check sticky pause before full reattach.
            if currentPlaybackIntent.isStickyPauseOrLock {
                #if DEBUG
                print("[SharedPlayerManager] play() aborted after soft-pause resume attempt — sticky \(currentPlaybackIntent)")
                #endif
                clearPlaybackStartPipeline()
                return
            }
            declinedSoftPauseForLanguageChange = await DirectStreamingPlayer.shared.softPauseResumeRequiresStreamReattach()
            if declinedSoftPauseForLanguageChange {
                DirectStreamingPlayer.shared.resetInitialPlaybackCountersForNewStream()
            }
        }
        #endif

        #if LUTHERAN_MAIN_APP
        let attachContext = PlaybackPlayDecision.attachContext(
            classification: playClassification,
            declinedSoftPauseForLanguageChange: declinedSoftPauseForLanguageChange
        )
        #else
        let attachContext = PlaybackPlayDecision.attachContext(
            classification: playClassification,
            declinedSoftPauseForLanguageChange: false
        )
        #endif

        // Defensive alignment for *widget switch* timing only (see Widget SwitchStreamIntent optimistic
        // persist + Darwin). We condition on the *existence of a persisted snapshot* so that we only
        // override the DirectStreamingPlayer model when a widget actually wrote a fresh language choice.
        //
        // Critically, when no snapshot exists (post-clearAllLocalState, first-run, or privacy no-widgets
        // paths) we must NOT clobber here. Those paths deliberately seed selectedStream (and
        // the LanguageSelectorView needle) via preferredMainAppInitialLanguageCode() which falls back to
        // DirectStreamingPlayer.bestInitialLanguageCode() (walks Locale.preferredLanguages for a
        // supported stream: en/de/fi/sv/et). Using preferredWidgetLanguage() would force the widget
        // privacy hard-default "en" and defeat the best-fitting-language initial selection.
        // The initial persistWidgetSnapshot in the post-clear cold path is itself privacy-gated, so
        // absence of snapshot is the correct signal to trust the main-app seeding.
        //
        // Stream-switch reconciliation exception (AGENT NOTE):
        // For widget (and main-app) language switches the orchestrator *first* calls
        // prepareStreamChoice(.switchPrep) / switchToStream — which updates the Direct model —
        // then resetToPrePlayForNewStream + play(). Alignment must not blindly re-apply a snapshot
        // that still contains the old language. Guarding here + model preference in saveCurrentState
        // prevents the reversion.
        if !isStreamSwitchPlay {
            if let snapshot = Self.loadPersistedWidgetState() {
                let preferredLang = snapshot.currentLanguage
                if DirectStreamingPlayer.shared.selectedStream.languageCode != preferredLang {
                    let synced = Self.streamForLanguageCode(preferredLang)
                    if synced.languageCode == preferredLang {
                        #if DEBUG
                        print("[SharedPlayerManager] Aligning selectedStream to persisted widget language \(preferredLang) (was \(DirectStreamingPlayer.shared.selectedStream.languageCode)) before attachAndPlay")
                        #endif
                        await DirectStreamingPlayer.shared.prepareStreamChoice(synced, preparation: .modelOnly)
                    }
                }
            }
        }

        // Final sticky re-check immediately before engine attach (last await may have been
        // prepareStreamChoice(.modelOnly) or soft-pause helpers above).
        if currentPlaybackIntent.isStickyPauseOrLock {
            #if DEBUG
            print("[SharedPlayerManager] play() aborted before attachAndPlay — sticky \(currentPlaybackIntent)")
            #endif
            clearPlaybackStartPipeline()
            return
        }

        let stream = DirectStreamingPlayer.shared.selectedStream
        #if DEBUG
        print("[SharedPlayerManager] Setting stream to: \(stream)")
        #endif
        
        await DirectStreamingPlayer.shared.attachAndPlay(to: stream, context: attachContext)
        
        // Pipeline stays active until engine ``setPlaying()`` or user ``stop()`` so Connecting
        // toggles can still cancel attach. No saveCurrentState() here — observer will handle it.
    }
    
    /// Forces the visual state to `.securityLocked` (permanent failure) and persists it.
    /// Called from server 403 responses or unrecoverable validation failures.
    func setSecurityLocked() async {
        #if LUTHERAN_MAIN_APP
        await cancelSleepTimer(restorePlaybackIntent: false)
        #endif
        applyVisualState(.securityLocked)
        await self.saveCurrentState()
        
        #if DEBUG
        print("[SharedPlayerManager] Security lock applied from server 403 response")
        #endif
    }
    
    /// Safe resurrection entry point used by DirectStreamingPlayer recovery logic.
    /// Allows technical recovery (hiccups) even when visualState = .playing.
    ///
    /// `playbackIntent` is now the *primary* (and sole) decision signal for this path.
    /// The old visualState guard has been removed as part of collapsing parallel checks.
    /// All sticky transitions flow through `updatePlaybackIntent(to:)`.
    ///
    /// Also blocks on `hasExplicitTerminationSentinel()` so that post-termination
    /// wakes never auto-resume even via recovery nudges.
    func attemptResurrectionIfAllowed() async {
        // UI Test isolation (SSOT): never poke the real AVPlayer or start audio from recovery paths.
        if Self.isRunningInUITestMode {
            return
        }

        ensureVisualStateLoaded()
        
        #if DEBUG
        print("[SharedPlayerManager] SharedPlayerManager.attemptResurrectionIfAllowed() – currentPlaybackIntent = \(currentPlaybackIntent), currentVisualState = \(currentVisualState)")
        #endif

        // Block explicit user pause, elapsed sleep timer, permanent security lock,
        // or post-termination launch (sentinel). The sentinel + sticky combination is the
        // required hard blocker on all auto-resume paths (see CODING_AGENT.md).
        if currentPlaybackIntent.isStickyPauseOrLock
            || (currentPlaybackIntent == .sleepTimer && currentVisualState != .playing)
            || Self.hasExplicitTerminationSentinel() {
            #if DEBUG
            print("[SharedPlayerManager] resurrection BLOCKED by playbackIntent or termination sentinel")
            #endif
            return
        }

        // Light check — if the player is already playing, do nothing
        if DirectStreamingPlayer.shared.isActuallyPlaying() {
            #if DEBUG
            print("[SharedPlayerManager] SharedPlayerManager: already actually playing — skipping redundant recovery")
            #endif
            return
        }

        #if DEBUG
        print("[SharedPlayerManager] Resurrection proceeding — player is stalled, forcing light recovery")
        #endif

        // Light recovery: just force the existing player back to life (no full validation/tuning/stream switch)
        await MainActor.run {
            #if LUTHERAN_MAIN_APP
            DirectStreamingPlayer.shared.player?.playImmediately(atRate: 1.0)
            #endif
        }
    }
    
    /// Called whenever the *user* explicitly requests playback start or resume
    /// (in-app button, lock screen, Control Center, home widgets via pending, Live Activity,
    /// Siri/Shortcuts, CarPlay, URL schemes, security retry, etc.).
    ///
    /// This is the **single authoritative explicit-play entry point**.
    ///
    /// Contract (in order):
    /// 1. Thermal refuse while device is still stressed (policy chrome stays).
    /// 2. Idempotent no-op while Connecting (start pipeline already active).
    /// 3. Idempotent no-op while already audibly playing the selected language — **before**
    ///    ``setUserIntentToPlay()`` so chrome is never forced through Connecting and the
    ///    secured item is never rebuilt (holds even inside the cold-launch relaxed window).
    /// 4. (Main-app only) `configureNowPlayingControlsIfNeeded()`
    /// 5. `setUserIntentToPlay()` — forces `.prePlay` on sticky pause/clear, does
    ///    `updatePlaybackIntent(to: .shouldBePlaying)`, double-saves.
    /// 6. `play()` — the execution engine (defensive clear, classify cold/stream-switch/resume,
    ///    sticky/one-shot/security guards, connecting chrome, engine drive; ``setPlaying()`` only
    ///    after soft-resume or readyToPlay audible kick). Soft-paused same-language resume still
    ///    reaches ``DirectStreamingPlayer/resumeFromSoftPauseIfAvailable()`` (not step 3).
    ///
    /// - Precondition: Must be used for every *explicit user* "start playing" surface.
    ///   Raw `play()` is reserved for cold-launch initial, internal continuation when
    ///   playback intent is already active (end of the canonical switch resume paths),
    ///   technical recovery via `attemptResurrectionIfAllowed()`, and the private widget
    ///   branch inside `play()`.
    ///
    /// - Postcondition: `currentPlaybackIntent` is `.shouldBePlaying` (or derived) and
    ///   (if allowed) playback proceeds or is initiated. When already audibly playing
    ///   matching selection, state is unchanged (optional surface reaffirm only).
    ///
    /// - SeeAlso: ``play()``, ``setUserIntentToPlay()``, ``shouldNoOpPlayWhileAlreadyAudible()``,
    ///   ``clearUserPausedLockIfNeeded()``, ``currentPlaybackIntent``,
    ///   ``attemptResurrectionIfAllowed()``,
    ///   RadioPlayerCoordinator.completeStreamSwitch,
    ///   RadioPlayerCoordinator.switchToStreamFromWidget,
    ///   CODING_AGENT.md (Single Source of Truth Principles),
    ///   <doc:Architecture>, PlayerVisualState.swift (resurrection table cross-ref).
    ///
    /// AGENT NOTE: This method + `play()` are the SSOT for playback initiation semantics.
    /// Any new call site (new intent, CarPlay, etc.) must use `userRequestedPlay()` for
    /// explicit user play. Direct `play()` (without a preceding explicit play request)
    /// is only for the four permitted internal/recovery/cold cases listed in the
    /// Precondition. Update this doc, the resurrection table, and the architecture block
    /// in RadioPlayerCoordinator together.
    /// Never duplicate the set + play sequence.
    func userRequestedPlay() async {
        #if DEBUG
        print("SharedPlayerManager.userRequestedPlay() — setUserIntentToPlay + play() for explicit user intent")
        #endif

        // Thermal gate: while the device is still stressed, keep thermal chrome and do not
        // re-enter validation/attach. Cool-down auto-resume uses `shouldAutoResumeOnThermalRecovery`.
        // When cooled but visual still `.thermalPaused`, allow explicit play (sanitizes via intent path).
        if currentVisualState.blocksPlannedPlay && Self.isDeviceThermallyStressed() {
            #if DEBUG
            print("[SharedPlayerManager] userRequestedPlay() refused — thermal gate still active")
            #endif
            return
        }

        // Idempotent while Connecting: a second play plan must not re-run security validation
        // or stack another attach on an already-active start pipeline.
        if isConnectingPlayback {
            #if DEBUG
            print("[SharedPlayerManager] userRequestedPlay() no-op — playback start pipeline already active (Connecting)")
            #endif
            return
        }

        // Already audibly playing the selected language: do not force Connecting via
        // `setUserIntentToPlay` and do not rebuild the secured item. Soft-paused resume
        // does not hit this branch (engine rate is 0).
        if await shouldNoOpPlayWhileAlreadyAudible() {
            #if DEBUG
            print("[SharedPlayerManager] userRequestedPlay() no-op — already audibly playing matching selection")
            #endif
            #if LUTHERAN_MAIN_APP
            // Light surface reaffirm only — no visual/intent mutation, no attach.
            await refreshAllMediaSurfaces(liveActivity: .updateIfActive)
            #endif
            return
        }
        
        hasProcessedExplicitUserPlayRequest = true
        #if LUTHERAN_MAIN_APP
        await configureNowPlayingControlsIfNeeded()
        #endif
        await setUserIntentToPlay()
        await play()   // ← Fixed: no try/catch needed (play() is now non-throwing)
    }

    /// Whether a second play request must no-op because playback is already audible on the
    /// currently selected language (or UITest chrome already reports authoritative `.playing`).
    ///
    /// Production signal is engine-truth via ``DirectStreamingPlayer/isActuallyPlaying()`` plus
    /// same-language attach (``DirectStreamingPlayer/softPauseResumeRequiresStreamReattach()`` is
    /// false). Soft-paused same-stream resume is **not** a no-op: soft silence has rate 0, so
    /// `isActuallyPlaying` is false and the caller proceeds to soft-resume.
    ///
    /// **Invariant:** This check must **not** depend on cold-launch `resurrectionProtectionRelaxed`.
    /// The relaxed window exists so first play / recovery may proceed despite prior sticky
    /// snapshots; it must never authorize tearing down a live secured item for a redundant play.
    ///
    /// - Returns: `true` when the caller should return without `setStreamAndPlay` / intent thrash.
    /// - Precondition: Sticky pause/lock and stream-switch hold are handled separately
    ///   (`false` here so intentional switch attach and pause→play resume stay open).
    /// - SeeAlso: ``userRequestedPlay()``, ``play()``,
    ///   ``DirectStreamingPlayer/resumeFromSoftPauseIfAvailable()``,
    ///   ``DirectStreamingPlayer/isActuallyPlaying()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   CODING_AGENT.md (Single Source of Truth Principles), <doc:Architecture>.
    ///
    /// AGENT NOTE: Single source of truth for play-while-already-playing idempotency.
    /// Both ``userRequestedPlay()`` (before ``setUserIntentToPlay()``) and ``play()`` must
    /// consult this helper. Do not re-introduce a visual-only skip gated on the cold-launch window.
    internal func shouldNoOpPlayWhileAlreadyAudible() async -> Bool {
        if currentPlaybackIntent.isStickyPauseOrLock {
            return false
        }
        // Stream-switch hold means a new attach is intentional — never treat as already-playing.
        if holdPrePlayVisualUntilPlayback {
            return false
        }

        #if LUTHERAN_MAIN_APP
        // Engine-truth: already audible on the attached language matching `selectedStream`.
        if DirectStreamingPlayer.shared.isActuallyPlaying() {
            let needsLanguageReattach =
                await DirectStreamingPlayer.shared.softPauseResumeRequiresStreamReattach()
            if needsLanguageReattach {
                return false
            }
            return true
        }

        // UITestMode has no real AVPlayer rate. Authoritative chrome `.playing` with an active
        // playback intent is the stand-in so unit tests can prove idempotency without network audio.
        if Self.isRunningInUITestMode,
           currentVisualState == .playing,
           currentPlaybackIntent.isActivePlaybackIntent {
            return true
        }
        #endif

        return false
    }
    
    /// Explicitly records that the user performed a manual pause or stop.
    /// This locks `.userPaused` (sticky resurrection blocker) so that resurrection
    /// paths are blocked until the next explicit user play.
    ///
    /// Called from DirectStreamingPlayer user-action stop paths and certain
    /// coordinator surfaces. The visual + intent mutations here are the SSOT.
    ///
    /// - Postcondition: visual = .userPaused, intent = .userPaused, timestamp set,
    ///   persisted, and `streamDidPause` emitted.
    ///
    /// - SeeAlso: ``setUserPaused()``, ``stop()``, ``emit(_:)``, `PlayerEvent.streamDidPause`,
    ///   `DirectStreamingPlayer.stop(reason:)`, `DirectStreamingPlayer.markAsUserPaused()`,
    ///   ``testMarkAsUserPausedEmissionOrderMatchesCanonicalMutationSequence``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5 emission order),
    ///   CODING_AGENT.md (resurrection tables).
    ///
    /// - Note: Emission subsequence matches ``setUserPaused()`` (`visualStateDidChange` →
    ///   `playbackIntentChanged` → `streamDidPause` → `persistedWidgetStateDidUpdate`).
    ///   Both surfaces persist via ``saveCurrentState()`` after mutation; consumers observe
    ///   the same pause vocabulary regardless of which canonical entry was invoked.
    ///
    /// AGENT NOTE: Emission site for pause is after mutation. This method is called
    /// by the player; do not move pause decision logic here.
    func markAsUserPaused() async {
        ensureVisualStateLoaded()

        #if LUTHERAN_MAIN_APP
        await cancelSleepTimer(restorePlaybackIntent: false)
        #endif
        
        #if DEBUG
        print("[SharedPlayerManager] markAsUserPaused() called – forcing .userPaused to block resurrection")
        #endif
        
        // We are inside the actor, so mutation is allowed
        applyVisualState(.userPaused)
        
        updatePlaybackIntent(to: .userPaused)
        
        // Record authoritative pause timestamp for recovery paths.
        // This lets wasRecentlyUserPaused() return correct answers without raw UD reads.
        lastUserPauseTimestamp = Date().timeIntervalSince1970
        
        // Emission after the state mutation (visual + intent). Authoritative for
        // streamDidPause. All save / notify paths remain exactly as before.
        emit(.streamDidPause)
        
        // Persist the locked state
        await saveCurrentState()
        
        #if LUTHERAN_MAIN_APP
        await refreshAllMediaSurfaces(liveActivity: .updateIfActive)
        #endif
        
        #if DEBUG
        print("[SharedPlayerManager] Visual state locked to .userPaused")
        #endif
    }
    
    /// Public async entry point for stopping playback.
    ///
    /// Immediately locks visual state to `.userPaused` (sticky resurrection protection) and persists it,
    /// then awaits engine soft silence (main app path) or schedules the widget stop action.
    ///
    /// - Important: Sticky intent is locked **before** the engine stop so that any in-flight
    ///   attach still suspended on security validation / server selection / session activation
    ///   re-checks ``canProceedWithPlayback()`` and discards without audible start.
    ///   `DirectStreamingPlayer.stop` also advances its attach generation so post-await start
    ///   paths cannot complete against a paused chrome surface.
    ///
    /// - Important: Media surfaces (Now Playing rate, Live Activity glyph) are refreshed only
    ///   **after** soft-pause completion (`player.pause` + `rate == 0` + `isSoftPaused`). This is
    ///   the single ownership path for “user pause complete”: SPM owns sticky visual lock +
    ///   `streamDidStop` + one ``refreshAllMediaSurfaces``; the engine is told
    ///   `applyUserPauseVisualLock: false` so it does not re-enter ``setUserPaused()`` /
    ///   ``markAsUserPaused()`` (no second surface storm, no `streamDidPause` after `streamDidStop`).
    ///
    /// - Postcondition: visual + intent forced to `.userPaused`, timestamp recorded,
    ///   engine soft silence awaited (main), authoritative ``saveCurrentState()``
    ///   performed (privacy-gated), surfaces notified once after silence, and
    ///   `streamDidStop` emitted.
    ///
    /// - SeeAlso: ``setUserPaused()``, ``markAsUserPaused()``, ``emit(_:)``,
    ///   `PlayerEvent.streamDidStop`,
    ///   `DirectStreamingPlayer.stopAndWait(reason:silent:applyUserPauseVisualLock:)`,
    ///   ``canProceedWithPlayback()``, CODING_AGENT.md (resurrection protection, SSOT stop path),
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    ///
    /// AGENT NOTE: `.streamDidStop` is emitted here after the immediate mutation
    /// because `stop()` is the public authoritative stop entry. Widget vs main paths
    /// preserved; engine stop is awaited so chrome cannot lead audio.
    public func stop() async {
        ensureVisualStateLoaded()

        #if LUTHERAN_MAIN_APP
        await cancelSleepTimer(restorePlaybackIntent: false)
        #endif
        
        #if DEBUG
        print("[SharedPlayerManager] SharedPlayerManager.stop() ENTERED – currentVisualState = \(currentVisualState)")
        #endif

        // Cancel Connecting as well as audible play — pipeline must not outlive sticky pause.
        clearPlaybackStartPipeline()

        // Note: Lock .userPaused IMMEDIATELY at the very top
        // This closes the race window that causes resurrection after pause.
        // Authoritative cross-process snapshot is written later via saveCurrentState().
        applyVisualState(.userPaused)

        updatePlaybackIntent(to: .userPaused)

        // Record authoritative pause timestamp (used by recovery query).
        lastUserPauseTimestamp = Date().timeIntervalSince1970

        // Emission of streamDidStop after the core mutation (visual + intent).
        // Distinguishes terminal stop from transient pause for future observers.
        // Additive only.
        emit(.streamDidStop)

        #if DEBUG
        print("[SharedPlayerManager] userPaused locked immediately in stop() (resurrection protection active)")
        #endif

        if isRunningInWidget() {
            handleWidgetStop()
            return
        }

        // Main app path — await soft pause so rate is 0 before Now Playing / Live Activity flip.
        // applyUserPauseVisualLock: false — sticky lock + streamDidStop already applied above;
        // a nested setUserPaused would double-refresh surfaces and emit streamDidPause after stop.
        await DirectStreamingPlayer.shared.stopAndWait(
            reason: .userAction,
            silent: false,
            applyUserPauseVisualLock: false
        )

        // Keep parsed metadata in the snapshot so widgets can show a subdued last-known
        // program line while paused. Raw ICY in nowPlayingStreamMetadata is unchanged
        // for same-stream soft-pause resume re-hydrate.

        // Always save after engine silence
        await saveCurrentState()
        
        notifyMainApp(action: "pause")
        
        #if LUTHERAN_MAIN_APP
        // Single media-surface refresh after soft silence — engine-complete ownership path.
        await refreshAllMediaSurfaces(liveActivity: .updateIfActive)
        await performPostStopWidgetHygiene()
        #endif
        
        #if DEBUG
        print("[SharedPlayerManager] stop() completed – visualState locked to .userPaused, engine soft-silenced, surfaces refreshed")
        #endif
    }
    
    /// Nonisolated entry point for stream switching (signaling + dispatch).
    ///
    /// - Widget / extension paths (including Live Activity intents): immediately schedule
    ///   optimistic state + pending action via App Group + Darwin. The authoritative
    ///   main-app reconciliation then happens via `RadioPlayerCoordinator.handleWidgetSwitchToLanguage`
    ///   → `switchToStreamFromWidget(to:index:actionId:)`.
    /// - Main-app forwarding (Siri, shortcuts, some legacy): forwards directly to
    ///   `DirectStreamingPlayer.switchToStream` (the engine prep SSOT).
    ///
    /// **Full UI stream choice from flag taps in the main app** must go through
    /// `RadioPlayerCoordinator.completeStreamSwitch` (via `handleLanguageSelection`)
    /// so that main-app-only tuning sound, needle animation, prePlay hold coordination,
    /// and precise `resetToPrePlayForNewStream` + `play()` timing stay owned in one place.
    ///
    /// - SeeAlso: `DirectStreamingPlayer.switchToStream`,
    ///   `RadioPlayerCoordinator.completeStreamSwitch`,
    ///   `RadioPlayerCoordinator.switchToStreamFromWidget(to:index:actionId:)`,
    ///   `RadioPlayerCoordinator.handleWidgetSwitchToLanguage`,
    ///   `RadioPlayerCoordinator.handleLanguageSelection`,
    ///   CODING_AGENT.md (Single Source of Truth Principles + "Cross-target shared source files").
    nonisolated func switchToStream(_ stream: DirectStreamingPlayer.Stream) async {
        if isRunningInWidget() {
            // Widget path must stay nonisolated and synchronous/fast
            handleWidgetSwitch(to: stream)
            return
        }
        
        // Main app path
        await DirectStreamingPlayer.shared.switchToStream(stream)
    }
    
    // MARK: - Visual State Management (User Intent)
    //
    // These methods are the canonical ways to record explicit user intent and to
    // restore state while always respecting the sticky .userPaused / .securityLocked rules.

    /// Reset to `.prePlay` (and clear the cold-launch one-shot guard) so that
    /// a real language/stream switch behaves **exactly** like the initial
    /// cold-launch playback path.
    ///
    /// Establishes Connecting chrome for an active-intent stream/language switch.
    ///
    /// Called from stream-switch paths (`handleLanguageSelection`, `completeStreamSwitch`,
    /// `switchToStreamFromWidget`, Siri intents, widget/shortcut). Enables the cold-launch-like
    /// first-play path after a switch while preserving sticky pause / security protection on
    /// non-resume paths.
    ///
    /// **Switch timing contract (chrome before teardown):**
    /// For an *active* playback intent, call this **before** the engine silent `.streamSwitch`
    /// stop and **with** the destination language when known. That order guarantees Live Activity
    /// / Now Playing never advertise `.playing` mid teardown, and never show Connecting with the
    /// **prior** stream’s language chrome for a frame while the engine model still points at the
    /// old stream. Engine prep (`DirectStreamingPlayer.switchToStream`) may update the stream
    /// model after this hold is active; `saveCurrentState` / `play()` prefer the Direct model
    /// under the hold. Home-widget session language snapshot writes remain the caller’s job via
    /// `updateUserDefaultsLanguage` → `saveCombinedWidgetState` after model prep.
    ///
    /// - Parameters:
    ///   - preserveActiveSleepTimer: When true, the sleep timer (if any) is left running
    ///     across the switch (rare; normally false).
    ///   - connectingLanguageCode: Destination stream language for LA / durable language mirror
    ///     on the immediate Connecting surface refresh. Pass the target code whenever the
    ///     caller knows it (widget switch, flag tap, Siri). When `nil`, language chrome follows
    ///     ``mainAppLiveActivityLanguageCode()`` (may still be the prior stream until engine prep).
    ///
    /// - Postcondition: `currentVisualState == .prePlay`, `holdPrePlayVisualUntilPlayback == true`,
    ///   `initialPlaybackHasRun == false`, soft-pause ICY stash cleared (no stale program title
    ///   across languages). When `connectingLanguageCode` is non-empty, durable LA language mirror
    ///   and ``liveActivityLanguageCodeForContentPush()`` report that code for the hold duration.
    ///   Main-app media surfaces refreshed so lock-screen chrome shows Connecting + target language.
    ///
    /// - SeeAlso: ``liveActivityLanguageCodeForContentPush()``, ``play()``, ``saveCurrentState()``,
    ///   ``clearSoftPauseMetadataStashForLanguageChange()``,
    ///   ``refreshAllMediaSurfaces(liveActivity:widgetRefresh:widgetRefreshImmediate:)``,
    ///   `RadioPlayerCoordinator.completeStreamSwitch`, `RadioPlayerCoordinator.switchToStreamFromWidget`,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§6),
    ///   CODING_AGENT.md (Single Source of Truth Principles).
    func resetToPrePlayForNewStream(
        preserveActiveSleepTimer: Bool = false,
        connectingLanguageCode: String? = nil
    ) async {
        #if LUTHERAN_MAIN_APP
        if !preserveActiveSleepTimer {
            await cancelSleepTimer(restorePlaybackIntent: false)
        }
        #endif
        // Note: Always clear .userPaused / .cleared lock for widget pure-play actions
        // This makes widget play/pause 100% reliable (was missing in pure-play path)
        await clearUserPausedLockIfNeeded()

        applyVisualState(.prePlay)
        holdPrePlayVisualUntilPlayback = true
        initialPlaybackHasRun = false
        // Destination language for the hold-time surface push (before selectedStream updates).
        if let connectingLanguageCode, !connectingLanguageCode.isEmpty {
            streamSwitchConnectingLanguageCode = connectingLanguageCode
            Self.persistLiveActivityLanguageMirror(connectingLanguageCode)
        } else {
            streamSwitchConnectingLanguageCode = nil
        }
        // Drop prior-language program title before any language mirror / LA push so ContentState
        // cannot show "playing + old title + new language" during silent engine teardown.
        _clearIcyMetadataStash()
        await saveCurrentState()

        #if LUTHERAN_MAIN_APP
        // Push Connecting chrome immediately with target language when provided (do not wait
        // for setPlaying or a later post-switch language write).
        await refreshAllMediaSurfaces(liveActivity: .updateIfActive)
        #endif

        // NOTE: Home-widget session language snapshot is still authored by callers via
        // updateUserDefaultsLanguage() → saveCombinedWidgetState() after engine model prep.
        
        #if DEBUG
        let languageNote = connectingLanguageCode.map { " language=\($0)" } ?? ""
        print("[SharedPlayerManager] resetToPrePlayForNewStream() — state reset to .prePlay for atomic stream switch\(languageNote)")
        #endif
    }

    /// Internal helper **only** for the privacy "clear local state" path.
    /// Performs a clean reset of visual/intent/metadata/guards to .cleared visual ("Cleared" blue pill + clear_local_state_done)
    /// + .cleared intent. **without** any persistence side-effects (no saveCurrentState, no persistWidgetSnapshot, no liveness bump).
    /// The .cleared intent (in the current process) is the hard blocker (canProceedWithPlayback, play() top guard,
    /// recovery, startPlayback etc.). Visual .cleared gives explicit post-reset confirmation in the current session
    /// (distinct from yellow connecting). A subsequent cold launch sees .prePlay because removeAllLocalPlaybackKeys
    /// + hasActiveWidgets=false + no snapshot. This prevents grey .userPaused mixing or "connect" after clear.
    /// On next launch the no-snapshot path in ensureVisualStateLoaded allows the normal cold-launch flow.
    /// SECURITY: This touches only in-memory actor state for the current process.
    func resetStateToClearedForPrivacy() {
        Self.clearInMemorySessionSnapshot()
        applyVisualState(.cleared)
        clearStreamSwitchPrePlayHold()
        initialPlaybackHasRun = false
        updatePlaybackIntent(to: .cleared)
        // Use the canonical clear helper (which now also emits .metadataDidUpdate(nil)).
        // Distinct from language-change: no NowPlayingInfo or widget persist here.
        _clearIcyMetadataStash()
        lastUserPauseTimestamp = 0

        #if DEBUG
        print("[SharedPlayerManager] resetStateToClearedForPrivacy — in-memory SSOT reset to .cleared (blue) + .cleared intent (no persist; .cleared blocks recovery until explicit play)")
        #endif
    }
    
    /// Called only when the user taps the play button (or widget play action).
    /// Clears the .userPaused lock so resume is allowed.
    /// Clears `.userPaused` so `play()` can proceed via explicit `.shouldBePlaying` intent.
    /// Also moves thermal / security recovery chrome to Connecting (``.prePlay``) before
    /// validation so control surfaces do not keep policy-error glyphs while a recovery play runs.
    func setUserIntentToPlay() async {
        ensureVisualStateLoaded()

        hasProcessedExplicitUserPlayRequest = true

        #if LUTHERAN_MAIN_APP
        await cancelSleepTimer(restorePlaybackIntent: false)
        #endif
        
        #if DEBUG
        print("[SharedPlayerManager] setUserIntentToPlay() called – clearing sticky / policy chrome for explicit play")
        #endif
        
        if currentVisualState == .userPaused
            || currentPlaybackIntent == .cleared
            || currentVisualState == .cleared
            || currentVisualState == .thermalPaused
            || currentVisualState == .securityLocked {
            applyVisualState(.prePlay)
            
            #if DEBUG
            print("[SharedPlayerManager] setUserIntentToPlay() → .prePlay with .shouldBePlaying (resume/clear/recovery path)")
            #endif
        }
        
        updatePlaybackIntent(to: .shouldBePlaying)
        
        // Widget language selection while paused relies on optimistic PersistedWidgetState.
        // Explicitly align Direct's model here (before saveCurrentState) so that:
        // - the snapshot written by this resume path carries the user-chosen language, and
        // - setStreamAndPlay later in play() sees the correct stream even if the switch
        //   reconciliation was debounced or a prior model value lingered.
        // This upholds the "switch while paused + follow-on play uses preferred-lang alignment"
        // contract documented in handleWidgetSwitch + signalWidgetSwitchAction.
        if let snapshot = Self.loadPersistedWidgetState() {
            let preferredLang = snapshot.currentLanguage
            if !preferredLang.isEmpty,
               DirectStreamingPlayer.shared.selectedStream.languageCode != preferredLang {
                let synced = Self.streamForLanguageCode(preferredLang)
                if synced.languageCode == preferredLang {
                    #if DEBUG
                    print("[SharedPlayerManager] setUserIntentToPlay alignment: using persisted lang \(preferredLang) (was \(DirectStreamingPlayer.shared.selectedStream.languageCode))")
                    #endif
                    await DirectStreamingPlayer.shared.prepareStreamChoice(synced, preparation: .modelOnly)
                }
            }
        }
        
        await saveCurrentState()
    }
    
    /// Records that playback stopped due to stream failure (decode/network), not explicit user pause.
    ///
    /// Grey `.userPaused` visual supports error UI; `playbackIntent` stays unchanged (typically
    /// `.shouldBePlaying`) so language switches can auto-resume without an extra play tap.
    /// Does not bump `lastUserPauseTimestamp` — stream failure is not a sticky user pause.
    ///
    /// Emission of the classified `streamDidFail` occurs here after the mutation. This is the
    /// existing surface that DirectStreamingPlayer calls (passing the value it classified via
    /// `StreamErrorType.from(error:)`) for terminal failures.
    ///
    /// - Parameter errorType: The classified failure owned and computed by the player.
    ///   Default preserves behavior for coordinator/test call sites.
    ///
    /// - Postcondition: `currentVisualState == .userPaused`; `playbackIntent` unchanged;
    ///   snapshot saved; `.streamDidFail(errorType)` emitted via the authoritative emitter.
    ///   All classification, early-window retry, recreate, and stop decisions remain in
    ///   `DirectStreamingPlayer`.
    ///
    /// - SeeAlso: ``emit(_:)``, ``events``, `PlayerEvent.streamDidFail`,
    ///   ``setPlaying()``, ``stop()``, ``setUserPaused()``, ``markAsUserPaused()``,
    ///   `StreamErrorType`, `DirectStreamingPlayer` (early-window recovery + `recreatePlayerItem`),
    ///   `RadioPlayerCoordinator.completeStreamSwitch` / `switchToStreamFromWidget` (auto-resume
    ///   when intent remains active),
    ///   docs/cold-launch-streamplay-regression-checklist.md (§6.12),
    ///   docs/Event-Driven-Refactor-Roadmap.md, CODING_AGENT.md.
    ///
    /// AGENT NOTE: Single source of truth for stream-failure visual mutation. Emission after
    /// mutation. Classification stays in DirectStreamingPlayer. Intent is intentionally left
    /// unchanged so language switches can auto-resume after a recoverable failure.
    func markPlaybackStoppedByStreamFailure(_ errorType: StreamErrorType = .permanentFailure) async {
        ensureVisualStateLoaded()

        #if DEBUG
        print("[SharedPlayerManager] markPlaybackStoppedByStreamFailure() — visual .userPaused, intent unchanged (\(playbackIntent))")
        #endif

        applyVisualState(.userPaused)

        // Emission *after* the state mutation (visual). This is the required location.
        // The payload carries the exact classified value from the player.
        emit(.streamDidFail(errorType))

        await saveCurrentState()
        #if LUTHERAN_MAIN_APP
        await refreshAllMediaSurfaces(liveActivity: .updateIfActive)
        #endif
    }

    /// Sets the visual state to `.userPaused` (sticky) and the playback intent
    /// to `.userPaused`, records the pause timestamp, persists the snapshot, and
    /// notifies surfaces.
    ///
    /// This is the canonical surface for recording an explicit user-initiated pause
    /// (from DirectStreamingPlayer mark paths, remote commands, etc.).
    ///
    /// - Postcondition: visual = .userPaused, intent = .userPaused, timestamp recorded,
    ///   snapshot written, and `streamDidPause` emitted.
    ///
    /// - SeeAlso: ``markAsUserPaused()``, ``stop()``, ``emit(_:)``,
    ///   `PlayerEvent.streamDidPause`, `DirectStreamingPlayer.markAsUserPaused()`,
    ///   CODING_AGENT.md.
    ///
    /// AGENT NOTE: `.streamDidPause` is emitted after the mutation here. Callers
    /// (including Direct) continue to invoke `setUserPaused()` unchanged.
    func setUserPaused() async {
        ensureVisualStateLoaded()

        #if LUTHERAN_MAIN_APP
        await cancelSleepTimer(restorePlaybackIntent: false)
        #endif
        applyVisualState(.userPaused)
        
        updatePlaybackIntent(to: .userPaused)
        
        // Record authoritative pause timestamp.
        lastUserPauseTimestamp = Date().timeIntervalSince1970
        
        // Emission after state mutation. Authoritative emitter site for pause.
        // Additive: saveCurrentState + NowPlaying + LA paths are unaltered.
        emit(.streamDidPause)
        
        await saveCurrentState()
        #if LUTHERAN_MAIN_APP
        await refreshAllMediaSurfaces(liveActivity: .updateIfActive)
        #endif
    }
    
    /// Sets the visual state to `.playing` (and the intent to `.shouldBePlaying`
    /// unless a sleep timer is active) and persists the authoritative snapshot.
    ///
    /// Call only when the engine has started or resumed **audible** output (or UITestMode
    /// asserts that transition without real audio). Production call sites:
    /// soft-pause resume after rate kick, readyToPlay first-play kick / KVO playing via
    /// ``DirectStreamingPlayer`` `publishAuthoritativePlayingIfNeeded`, interruption resume.
    ///
    /// - Important: Do **not** call from the start of ``play()`` or from `startPlayback` while
    ///   still awaiting `.readyToPlay`. Connecting chrome must stay `.prePlay` (rate 0, play
    ///   affordance) until this method runs.
    ///
    /// - Postcondition: `currentVisualState == .playing`, intent updated if appropriate,
    ///   stream-switch hold cleared, snapshot saved (when the privacy gate allows), Now Playing /
    ///   Live Activity surfaces notified via ``refreshAllMediaSurfaces(liveActivity: .startOrUpdate)``
    ///   (main app, skipped in UITestMode), and `streamDidStart` emitted after the visual + intent mutations.
    ///
    /// - SeeAlso: ``emit(_:)``, ``refreshAllMediaSurfaces(liveActivity:widgetRefresh:widgetRefreshImmediate:)``,
    ///   `DirectStreamingPlayer.startPlayback(context:)`, ``play()``, ``markPlaybackStoppedByStreamFailure(_:)``,
    ///   `PlayerEvent.streamDidStart`, docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   CODING_AGENT.md (SSOT for visual/intent, additive event emission).
    ///
    /// AGENT NOTE: Emission of `.streamDidStart` occurs here (after visual + intent
    /// mutation) because `setPlaying` is the canonical surface for "underlying streaming
    /// became active." Engine helpers must call it only after audible start (or soft-resume
    /// rate kick). Do not re-introduce optimistic setPlaying in ``play()``.
    func setPlaying() async {
        // UI Test isolation (SSOT): perform the canonical visual + intent + event mutations
        // and persist the snapshot (when the privacy gate allows) so unit tests can assert
        // emission order on the DEBUG notification seam. Skip Live Activity and Now Playing
        // IPC — the expensive surfaces that previously caused multi-minute test stalls.
        if Self.isRunningInUITestMode {
            ensureVisualStateLoaded()
            clearStreamSwitchPrePlayHold()
            clearPlaybackStartPipeline()
            applyVisualState(.playing)

            if playbackIntent != .sleepTimer {
                updatePlaybackIntent(to: .shouldBePlaying)
            }

            emit(.streamDidStart)

            await saveCurrentState()
            return
        }

        ensureVisualStateLoaded()
        clearStreamSwitchPrePlayHold()
        clearPlaybackStartPipeline()
        applyVisualState(.playing)
        
        if playbackIntent != .sleepTimer {
            updatePlaybackIntent(to: .shouldBePlaying)
        }
        
        // Emission after the core state mutation (visual + intent). This is the
        // authoritative site for "underlying streaming state became active".
        // Additive only: all prior save/NowPlaying/LA logic continues exactly.
        emit(.streamDidStart)
        
        await saveCurrentState()
        #if LUTHERAN_MAIN_APP
        await refreshAllMediaSurfaces(liveActivity: .startOrUpdate)
        #endif
    }
    
    /// Safe restoration – ALWAYS respects .userPaused and blocks resurrection.
    /// Call this on:
    /// - App/scene foreground
    /// - AVAudioSession interruption .shouldResume
    /// - Widget timeline reload
    /// - Any other system resume signal
    ///
    /// Primary signal is now `currentPlaybackIntent`. The method is
    /// intentionally simple because most resurrection complexity has been collapsed
    /// Resurrection complexity lives in `currentPlaybackIntent`.
    func restoreVisualStateRespectingUserIntent() async {
        ensureVisualStateLoaded()
        
        // Combined blocker: sticky intent OR post-termination sentinel.
        // Prevents foreground / interruption.ended / wake paths from resurrecting playback
        // when the prior session ended via termination or the user had paused.
        // Widgets/Live Activities may still render from PersistedWidgetState; only the
        // player is blocked.
        if currentPlaybackIntent.isStickyPauseOrLock
            || (currentPlaybackIntent == .sleepTimer && currentVisualState != .playing)
            || Self.hasExplicitTerminationSentinel() {
            #if DEBUG
            print("[SharedPlayerManager] restoreVisualStateRespectingUserIntent BLOCKED by playbackIntent or termination sentinel")
            #endif
            return
        }
        
        // If we already loaded something sticky from JSON, keep it; otherwise do the normal restore logic.
        if !hasLoadedVisualStateFromPersistence {
            let loaded = loadVisualState()
            if loaded.mustSuppressResurrection {
                currentVisualState = .userPaused
            } else {
                currentVisualState = loaded
            }
        }
        
        await saveCurrentState()
        
        if currentVisualState.mustSuppressResurrection {
            #if DEBUG
            print("[SharedPlayerManager] Resurrection suppressed — userPaused is sticky")
            #endif
        } else if currentVisualState.shouldAutoPlayOrResume {
            #if DEBUG
            print("[SharedPlayerManager] ▶ Allowed to resume playback")
            #endif
        }
    }
    
    // MARK: - Private Visual State Loading Guard
    
    /// Applies the factory-default visual load path once per process (or after explicit reset).
    ///
    /// **Memory-only policy:** Never restores visual state from UserDefaults. Cold launches always
    /// start at `.prePlay` (set by ``resetToFactoryDefaultsOnLaunch()`` / `init()`). During the
    /// active session, an in-memory snapshot may exist for widget refresh derivation; actor-owned
    /// `currentVisualState` remains authoritative for playback decisions.
    ///
    /// Widget providers must call this (directly or via ``syncVisualStateFromPersistence()``)
    /// before trusting `currentVisualState`.
    internal func ensureVisualStateLoaded() {
        // Upgrade hygiene: remove retired App Group visual/language keys if present.
        Self.clearPersistedVisualStateKeysFromDisk()

        guard !hasLoadedVisualStateFromPersistence else { return }

        let hadStickyUserPause = currentVisualState == .userPaused

        if let combined = Self.loadPersistedWidgetState() {
            // In-session only: memory snapshot present after first authoritative write this process.
            var loadedVisual = Self.sanitizedVisualStateForCrossProcessRestore(combined.visualState)
            if hadStickyUserPause && loadedVisual == .prePlay {
                loadedVisual = .userPaused
            }
            currentVisualState = loadedVisual
            if currentVisualState == .userPaused {
                updatePlaybackIntent(to: .userPaused)
            } else if currentVisualState == .securityLocked {
                updatePlaybackIntent(to: .securityLocked)
            }
        } else if hadStickyUserPause {
            currentVisualState = .userPaused
        } else {
            currentVisualState = .prePlay
        }

        hasLoadedVisualStateFromPersistence = true
        
        #if DEBUG
        if isRunningInWidget() {
            print("[SharedPlayerManager] [Widget] ensureVisualStateLoaded → currentVisualState = \(currentVisualState)")
        }
        #endif
    }
    
    // MARK: - Private Helpers for Playback Control
    
    /// Clears sticky pause/clear resurrection locks (.userPaused or .cleared) when an
    /// explicit user play action (widget, button, Siri, etc.) requests playback.
    /// Also handles sleepTimer special case. Called from play() and widget play paths.
    public func clearUserPausedLockIfNeeded() async {
        ensureVisualStateLoaded()

        // Keep .sleepTimer through stream-switch prePlay (yellow) and active playback.
        if currentPlaybackIntent == .sleepTimer {
            if currentVisualState == .playing || holdPrePlayVisualUntilPlayback {
                return
            }
        }

        guard currentVisualState == .userPaused
            || currentPlaybackIntent == .cleared
            || currentPlaybackIntent == .sleepTimer else { return }

        #if DEBUG
        print("[SharedPlayerManager] Cleared sticky lock for explicit play (visual=\(currentVisualState), intent=\(currentPlaybackIntent))")
        #endif

        if currentVisualState == .userPaused || currentPlaybackIntent == .cleared || currentVisualState == .cleared {
            applyVisualState(.prePlay)
        }

        updatePlaybackIntent(to: .shouldBePlaying)
    }
    
    #if LUTHERAN_MAIN_APP
    /// Waits for an active tuning clip to finish (delegate-driven) before main stream attach.
    /// No-op when ViewController already awaited the same clip (e.g. stream switch after `playTuningSound`).
    internal func waitForTuningSoundIfActive() async {
        await TuningSoundCoordinator.shared.waitForActivePlaybackToFinishIfNeeded()
    }
    #endif
    
    internal func handleWidgetPlay() {
        ensureVisualStateLoadedForWidget()
        
        // Instant visual feedback: prefer session / LA language mirror over bare
        // preferredWidgetLanguage() so LA-only (no home widgets) play does not stamp "en"
        // when the engine stream is non-English.
        let optimisticLanguage = Self.languageForLiveActivityOrWidgetOptimistic()
        Self.writeInstantFeedback(language: optimisticLanguage)
        
        // Important: Optimistic SSOT update (same pattern we already use in stop)
        applyVisualState(.playing)
        
        updatePlaybackIntent(to: .shouldBePlaying)
        
        scheduleWidgetAction(action: "play")
        notifyMainApp(action: "play")
        
        // Imperative **extensionOptimistic** path: widget process has no PlayerEvent
        // stream; delayed refresh reloads timelines after optimistic snapshot write.
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            let language = Self.languageForLiveActivityOrWidgetOptimistic()
            
            await WidgetRefreshManager.shared.refreshIfNeeded(
                visualState: .playing,
                currentLanguage: language,
                hasError: false,
                immediate: true,
                trigger: .extensionOptimistic
            )
            
            saveFireAndForget()
        }
    }
    
    internal func handleWidgetStop() {
        ensureVisualStateLoadedForWidget()
        
        // Instant visual feedback: prefer session / LA language mirror over bare
        // preferredWidgetLanguage() so LA-only pause does not stamp "en".
        let optimisticLanguage = Self.languageForLiveActivityOrWidgetOptimistic()
        Self.writeInstantFeedback(language: optimisticLanguage)
        
        // Important: Set the paused state synchronously for widget path
        applyVisualState(.userPaused)
        
        updatePlaybackIntent(to: .userPaused)
        
        // Record authoritative pause timestamp for recovery paths.
        lastUserPauseTimestamp = Date().timeIntervalSince1970
        
        scheduleWidgetAction(action: "pause")
        notifyMainApp(action: "pause")
        
        // Imperative **extensionOptimistic** path (no PlayerEvent emission in extension).
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            let language = Self.languageForLiveActivityOrWidgetOptimistic()
            
            await WidgetRefreshManager.shared.refreshIfNeeded(
                visualState: currentVisualState,   // already .userPaused
                currentLanguage: language,
                hasError: false,
                immediate: true,
                trigger: .extensionOptimistic
            )
        }
    }
    
    // This helper must be nonisolated because it's called from the nonisolated switchToStream
    nonisolated private func handleWidgetSwitch(to stream: DirectStreamingPlayer.Stream) {
        // Preserve the current play/pause (or other) visual across language switch for the
        // optimistic PersistedWidgetState snapshot. Must use loadPersistedVisualStateDirect()
        // (in-process session snapshot via persistOptimisticWidgetSnapshot / persistWidgetSnapshot).
        // Retired App Group `isPlaying` is never consulted; playback chrome is snapshot-derived only.
        //
        // Using the snapshot visual ensures switch while paused carries .userPaused + new
        // language; the follow-on "play" pending + preferred-lang alignment inside play()
        // then starts the correct stream.
        let visualForSwitch = Self.loadPersistedVisualStateDirect()
        signalWidgetSwitchAction(visualState: visualForSwitch, language: stream.languageCode)

        #if DEBUG
        print("[SharedPlayerManager] Widget stream switch scheduled: \(stream.languageCode)")
        #endif
    }
    
}

