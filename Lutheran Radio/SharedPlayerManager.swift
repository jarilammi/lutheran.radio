//
//  SharedPlayerManager.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 7.6.2025.
//

import Foundation
import AVFoundation
import Core

/// - Article: Shared State Management for Widgets and Extensions
///
/// `SharedPlayerManager` is a **pure dispatcher** that enables safe state sharing
/// between the main app, widgets, and Live Activities via App Groups + `UserDefaults`.
///
/// **Division of responsibilities (Single Source of Truth)**:
/// - `DirectStreamingPlayer` owns actual playback state, stream selection, error state,
///   and all mutations to the AVPlayer.
/// - `SharedPlayerManager` owns the **visual/intent state** (`currentVisualState` of type
///   `PlayerVisualState`) and is the only place that should be consulted for "what should
///   the UI/widget/Live Activity show right now?".
///
/// Core responsibilities:
/// - **Visual State SSOT**: `PlayerVisualState` (`.prePlay`, `.playing`, `.userPaused`,
///   `.thermalPaused`, `.securityLocked`) with strict "sticky .userPaused" resurrection protection.
/// - **Widget / Intent actions**: Optimistic instant feedback via App Group + Darwin notifications;
///   the main app performs the real work and persists authoritative state.
/// - **State persistence**: `saveCurrentState()` + `saveVisualState()` for cross-process sync.
/// - **Privacy**: only anonymous data; no timestamps, no history, no PII.
///
/// Usage:
/// - Main app / recovery logic: `await SharedPlayerManager.shared.play()`, `.stop()`, etc.
/// - Widgets / Live Activities / intents: `SharedPlayerManager.shared.loadSharedState()`,
///   `loadPersistedVisualStateDirect()` (snapshot-first), `forcePersistVisualState(...)` (never instantiate a player).
///
/// See also: `DirectStreamingPlayer` (actual playback), `PlayerVisualState.swift` (the visual SSOT),
/// `WidgetRefreshManager.swift`, and `RadioLiveActivityManager.swift`.
///
/// ## Formal Documentation: State Machine & App Group Persistence Model
///
/// The tables below are the authoritative reference for this component.
/// They live in the source file so they are impossible to miss or drift from
/// the implementation.
///
/// ### Resurrection Protection & State Transition Rules
///
/// **Sticky States (never auto-resume)**:
/// - `.userPaused` — explicit user pause/stop. Set in `stop()`, `markAsUserPaused()`,
///   `setUserPaused()`. Cleared only by `setUserIntentToPlay()` or widget play paths
///   that call `clearUserPausedLockIfNeeded()`.
/// - `.securityLocked` — permanent security failure (DNS TXT fail, 403, cert error).
///   Set in `play()` guard and `setSecurityLocked()`. Persists until next explicit play
///   that passes validation.
///
/// **Cold-Launch Grace Period** (defined in this actor):
/// - `initializationSettlingPeriod = 5.0` seconds
/// - Total window = 25 seconds (`< initializationSettlingPeriod + 20.0`)
/// - `initialPlaybackHasRun` one-shot guard prevents duplicate first-play attempts.
/// - The window only relaxes resurrection protection for `.prePlay`; `.userPaused` is
///   *never* bypassed, even inside the window (hard rule at the top of `play()`).
///
/// Phase 3 note: After intent unification, cold-launch special casing has been
/// significantly reduced. The one-shot and window logic are now minimal and
/// consistently subordinate to `currentPlaybackIntent`.
///
/// **Key Transition Methods**:
/// - `resetToPrePlayForNewStream()` — **only** place that intentionally sets `.prePlay`
///   after first launch (language/stream switches). Also clears `initialPlaybackHasRun`.
/// - `restoreVisualStateRespectingUserIntent()` — applies `suppressResurrectionIfNeeded()`.
/// - `attemptResurrectionIfAllowed()` — recovery path used by DirectStreamingPlayer nudges;
///   still respects `shouldAutoPlayOrResume`.
///
/// See `PlayerVisualState.swift` for `shouldAutoPlayOrResume`, `mustSuppressResurrection`,
/// `suppressResurrectionIfNeeded(currentState:)`, and the `from(status:isManualPause:...)` mapper.
///
/// **Phase 3 note (Cold-Launch Nuance Cleanup)**: Cold-launch special casing in `play()`
/// (one-shot + 25s window) has been further reduced and documented as minimal. The
/// authoritative `currentPlaybackIntent` is now the dominant signal even in cold-launch paths.
/// See Phase 3 chunks in the living plan for details.
///
/// **Chunk 2 complete (Playback Intent Unification)**: `currentPlaybackIntent` (owned exclusively
/// by this actor via `updatePlaybackIntent(to:)`) is now the primary decision signal in the
/// main resurrection paths:
/// - `play()` (top HARD RULE, central non-cold protection, one-shot simplification)
/// - `attemptResurrectionIfAllowed()`
/// - `restoreVisualStateRespectingUserIntent()`
/// The old overlapping visualState guards have been collapsed in the decision logic while
/// preserving (and making explicit) sticky `.userPaused` / `.securityLocked` resurrection
/// protection. Visual state remains the source of truth for UI/widget display.
///
/// | From State      | Trigger / Event                                   | Guard / Condition                                              | To State        | Resurrection Behavior / Notes |
/// |-----------------|---------------------------------------------------|-----------------------------------------------------------------|-----------------|-------------------------------|
/// | .prePlay        | Cold launch first play                            | Security valid + inside 25s window (or first time)              | .playing        | Sets `initialPlaybackHasRun = true` |
/// | .prePlay        | Explicit user play (button, widget, Siri, etc.)   | `userRequestedPlay()` → `setUserIntentToPlay()` first           | .playing        | Clears any prior .userPaused lock |
/// | .playing        | User taps pause/stop (any surface)                | `stop()` or `markAsUserPaused()` at top of method               | .userPaused     | Immediate sticky lock + early `saveVisualState()` |
/// | .playing        | User-initiated stream/language switch             | `resetToPrePlayForNewStream()` then `play()`                    | .prePlay → .playing | Special bypass of the ".playing guard" in play() |
/// | .playing        | AV interruption, stall, or thermal event          | `attemptResurrectionIfAllowed()` or player recovery nudges      | .playing        | Only proceeds if `shouldAutoPlayOrResume` |
/// | any             | Security validation failure (DNS/403/cert)        | Inside `play()` guard or StreamingSessionDelegate 403 handler   | .securityLocked | Permanent until explicit successful play |
/// | .userPaused     | User explicitly taps play (any surface)           | `userRequestedPlay()` or widget play path                       | .prePlay        | Resets cold-launch one-shot guard for resume |
/// | .thermalPaused  | Device cools sufficiently                         | DirectStreamingPlayer thermal recovery logic                    | .playing        | Only via `shouldAutoResumeOnThermalRecovery` |
/// | any             | App foreground, interruption.ended(.shouldResume) | `restoreVisualStateRespectingUserIntent()`                      | (unchanged or forced .userPaused) | Applies `suppressResurrectionIfNeeded()` |
///
/// ### Persistence Keys & Ownership (App Group "group.radio.lutheran.shared")
///
/// `persistedWidgetState` is the **single authoritative snapshot** for widget and Live Activity
/// display. It carries both the visual state and the current language, and is written on every
/// authoritative state change from the main app as well as optimistically from widget intents.
///
/// Widget providers and Live Activities are expected to consult `loadPersistedWidgetState()` first.
/// This design allows the system to operate with minimal reliance on short-lived optimistic keys
/// or freshness heuristics for normal operation.
///
/// Legacy separate keys (`playerVisualState` JSON and the standalone `currentLanguage` key) are
/// no longer written by current code paths. They exist only for compatibility with very old
/// installs that have never written a combined snapshot.
///
/// This is the authoritative shared state model. All values are anonymous. No PII, no listening history.
///
/// ---
/// **Phase 4 Completion Note (Playback Intent Unification — ViewController Cleanup)**:
///
/// After Phase 4 (under blanket approval):
/// - `ViewController` no longer contains any independent playback retry state machine.
/// - `attemptPlaybackWithRetry`, `startPlayback`, `startPlaybackDirect`, `lastPlaybackAttempt`,
///   `minPlaybackInterval`, `pendingPlaybackWorkItem` (playback), `isManualPause`, and
///   `hasPermanentPlaybackError` have all been removed from decision logic and (where possible) the file.
/// - All user-facing and system entry points (in-app button, widget URL schemes, SceneDelegate
///   `lutheranradio://` actions, remote commands, Control Center, interruption recovery, route changes,
///   stream unavailable / security error retries) now flow exclusively through:
///     - `handleUserTogglePlayback()` (the documented internal SSOT), or
///     - Direct `SharedPlayerManager` intent methods (`userRequestedPlay()`, `play()`, `stop()`,
///       `setUserIntentToPlay()`, `canProceedWithPlayback()`).
/// - Resurrection protection and "does the user want audio playing?" decisions are 100% owned by
///   this actor via the authoritative `currentPlaybackIntent` (written only through
///   `updatePlaybackIntent(to:)` at the sticky transition points).
/// - Permanent security lock alerts (`showSecurityModelAlert`) and stream unavailable error
///   surfacing remain fully preserved and user-visible via the normal error paths.
///
/// ViewController is now a thin coordinator/observer. The "three try" symptom that originated
/// from duplicated decision + retry logic in the main app layer has been eliminated at the source.
///
/// See `PLAYBACK_INTENT_UNIFICATION_PLAN.md` (Phase 4 records) for the full before/after audit
/// and living execution log.
///
/// | Key                     | Type                  | Primary Writers                                              | Primary Readers (widgets, recovery, UI)                              | Purpose & Semantics                                          | Lifetime / Notes |
/// |-------------------------|-----------------------|--------------------------------------------------------------|----------------------------------------------------------------------|--------------------------------------------------------------|------------------|
/// | playerVisualState       | Data (JSON)           | (Legacy — no longer written)                                 | `loadPersistedVisualStateDirect()` (prefers snapshot; falls back for old installs) | Legacy visual state key. Readers prefer the combined snapshot. | Migration / compat only |
/// | persistedWidgetState    | Data (JSON)           | `savePersistedWidgetState` (from performActualSave + saveCombined); also written optimistically by widget intents | `loadPersistedWidgetState()` (strongly preferred early return in providers) | **Single Source of Truth** for widget / Live Activity display (visualState + language) | Primary SSOT |
/// | playing (legacy)        | Bool                  | Older paths + fallbacks in `performActualSave`               | `ensureVisualStateLoaded` fallback, some widget decision logic       | Legacy "is radio playing" signal                             | Being phased out; still read as fallback |
/// | isPlaying               | Bool                  | `SharedPlayerManager.performActualSave`                      | `loadSharedState`, widget timeline providers                         | Snapshot derived from `currentVisualState.isActivelyPlaying` | Written on every authoritative save |
/// | currentLanguage         | String (languageCode) | (Legacy — no longer written by current paths)                | Migration fallbacks only in `loadPersistedWidgetState` / `preferredWidgetLanguage` | Legacy separate language key. Snapshot + `preferredWidgetLanguage()` are the SSOT. | Migration / compat only |
/// | hasError                | Bool                  | SharedPlayerManager (sourced from player.hasPermanentError)  | `loadSharedState`, widgets                                           | Permanent error flag for UI chrome                           | Set on security or unrecoverable network failures |
/// | lastUpdateTime          | Double (epoch)        | `SharedPlayerManager.performActualSave` (on every save) + widget handlers | Widget providers (isAppRunning 60 s check), instant-feedback expiry | Timestamp of last authoritative state change                 | Useful for external freshness + isAppRunning |
/// | lastUserPauseTime       | Double (epoch)        | ViewController (explicit pause paths) + widget pause round-trips | Cross-process / extension readers (for compatibility); legacy barrier consumers | Hard 8-second barrier after any user pause (Phase 6 Chunk 3: recovery paths in DirectStreamingPlayer now use authoritative actor `wasRecentlyUserPaused()` instead of raw UD + defensive sync) | Prevents resurrection attempts immediately after pause |
/// | isInstantFeedback       | Bool                  | Widget handlers (`handleWidgetPlay/Stop/Switch`)             | `loadSharedState` (checked first)                                    | Signals that a widget action just occurred (optimistic UI)   | Short-lived; cleared after 15s or next authoritative save |
/// | instantFeedbackTime     | Double (epoch)        | Widget handlers                                              | `loadSharedState`                                                    | Timestamp for the instant feedback validity window           | 15-second validity window |
/// | instantFeedbackLanguage | String                | Widget handlers                                              | `loadSharedState`                                                    | Language to show during the optimistic widget update         | Matches the language of the widget action |
/// | pendingAction           | String ("play","pause","switch") | Widget intent handlers, Control Center, some ViewController paths | `getPendingAction()`, SceneDelegate, widget providers          | One-shot command from extension process to main app          | Cleared by `clearPendingAction(actionId:)` after processing |
/// | pendingActionId         | String (UUID)         | Same writers as pendingAction                                | `getPendingAction()`, `clearPendingAction()`                         | Deduplication token to handle rapid repeated taps            | Prevents double-processing on race conditions |
/// | pendingActionTime       | Double (epoch)        | Same writers as pendingAction                                | Widget providers (staleness checks)                                  | Freshness timestamp for pending actions                      | Used to ignore very old pending actions |
/// | pendingLanguage         | String                | `scheduleWidgetAction` (only for "switch")                   | `getPendingAction()`, widget providers                               | Parameter for stream switch actions                          | Only meaningful when `pendingAction == "switch"` |
///
/// **Critical Invariants**:
/// - The main app is always the source of truth. Widgets write optimistic visual state +
///   `pendingAction`, then the main app performs real work and writes authoritative values.
/// - `saveCurrentState()` is the primary persistence path driven by the real player.
/// - Widget / extension code should prefer `loadPersistedVisualStateDirect()` or call
///   `syncVisualStateFromPersistence()` / `refreshVisualStateFromPersistence()` before
///   trusting in-memory `currentVisualState`.
actor SharedPlayerManager {
    static let shared = SharedPlayerManager()
    
    // MARK: - Cold Launch & Resurrection Guards
    private let appLaunchTime = Date()
    private let initializationSettlingPeriod: TimeInterval = 5.0
    private var initialPlaybackHasRun = false
    
    // MARK: - Chunk 3 (Phase 6): Authoritative recent-pause timestamp
    //
    // This is the first step toward eliminating the "Brave guard" defensive pattern.
    //
    // Problem being solved:
    //   Recovery paths in DirectStreamingPlayer (nudges, final recovery timer, recreatePlayerItem)
    //   were forced to do `syncVisualStateFromPersistence()` + raw UserDefaults read of
    //   "lastUserPauseTime" because the actor's in-memory state could lag behind widget
    //   optimistic writes and ViewController pause paths on cold launch / rapid resume.
    //
    // Solution direction (this micro-increment is pure scaffolding):
    //   - Centralize the timestamp inside the actor (single source of truth for "when did
    //     the user last explicitly pause?").
    //   - Expose a clean `wasRecentlyUserPaused(within:)` query.
    //   - All pause writers (inside this actor + ViewController) will update it.
    //   - DirectStreamingPlayer recovery paths will later switch to the actor query instead
    //     of raw UD + defensive sync on every nudge/timer.
    //
    // Current status (this edit): scaffolding only.
    //   - The property exists and is updated at key pause points (subsequent micro-increments).
    //   - No consumers yet. No behavior change. The raw "lastUserPauseTime" UD key continues
    //     to be written for widget/extension readers that need it.
    //   - `lastUserPauseTime` in UserDefaults remains the cross-process contract for non-actor
    //     readers (widget providers, etc.). We are only giving the main-app recovery paths a
    //     trustworthy in-actor view.
    //
    // Ownership: SharedPlayerManager is the only writer for the authoritative value used by
    // recovery decisions. The UD key is kept for compatibility with extension processes.
    private var lastUserPauseTimestamp: TimeInterval = 0
    
    // MARK: - Visual State (Single Source of Truth)
    /// Single source of truth for playback intent (UI + widget + Live Activity)
    /// This prevents the "play on pause" resurrection bug when set synchronously to .userPaused
    var currentVisualState: PlayerVisualState = .prePlay
    
    /// Guards one-time loading of the persisted PlayerVisualState JSON (or legacy "playing" bool fallback).
    /// Critical for widget/extension processes which start with a fresh actor instance (default .prePlay).
    private var hasLoadedVisualStateFromPersistence = false

    // MARK: - Playback Intent (Micro-Patch 2 — Ownership Scaffolding)
    //
    // This is the **first** step toward making `PlaybackIntent` the authoritative
    // answer to "Does the user currently want audio to be playing?".
    //
    // Current status (this patch): pure scaffolding.
    // - The property exists and is updated at the key intent transition points.
    // - It is NOT yet consulted by any guard, resurrection logic, or execution path.
    // - `currentVisualState` remains the active driver (100% backward compatible).
    // - No behavior change. No resurrection changes. No call-site changes.
    //
    // Future micro-patches (after explicit approval) will:
    // - Make resurrection decisions consult playbackIntent + sticky flags.
    // - Collapse the overlapping windows/one-shots.
    // - Drive DirectStreamingPlayer from intent.
    // - Remove attemptPlaybackWithRetry from ViewController.
    //
    // Ownership rule (permanent): SharedPlayerManager is the ONLY writer.
    private var playbackIntent: PlaybackIntent = .shouldBePlaying

    /// Read-only view of the current authoritative playback intent.
    /// Consumers inside the actor (and trusted callers) should prefer this
    /// over deriving intent from visual state.
    /// This is the single source of truth for "does the user want audio playing right now?"
    var currentPlaybackIntent: PlaybackIntent {
        playbackIntent
    }

    // MARK: - Phase 2: Intent-Driven Playback Execution

    /// Returns whether the player execution engine (DirectStreamingPlayer) should
    /// be allowed to start, resume, or recover playback right now.
    ///
    /// This is the **preferred** intent-driven check for all playback command paths.
    /// It is driven exclusively by `currentPlaybackIntent` (the single source of truth
    /// updated only via `updatePlaybackIntent(to:)`).
    ///
    /// Phase 2 Chunk 1: First introduction of intent-driven guard for the execution engine.
    /// Callers (DirectStreamingPlayer) should use this instead of deriving decisions
    /// from `currentVisualState.shouldAutoPlayOrResume` where possible.
    ///
    /// Sticky rules are preserved exactly: `.userPaused` and `.securityLocked` are
    /// permanent blockers until an explicit user play action clears them.
    func canProceedWithPlayback() async -> Bool {
        ensureVisualStateLoaded()
        return currentPlaybackIntent != .userPaused && currentPlaybackIntent != .securityLocked
    }

    /// Chunk 3 (Phase 6): Authoritative query for the recent explicit user pause barrier.
    ///
    /// Recovery paths (DirectStreamingPlayer nudges, final recovery timer, recreatePlayerItem,
    /// cold-launch safety net) should use this instead of reading "lastUserPauseTime" directly
    /// from UserDefaults + doing defensive `syncVisualStateFromPersistence()` on every timer.
    ///
    /// This removes the root cause of the recurring "Brave guard" pattern.
    ///
    /// The 8-second window is preserved exactly (same constant and semantics as the prior
    /// raw-UD logic in DirectStreamingPlayer). The value is maintained by the pause writers
    /// inside this actor (subsequent micro-increments will wire all call sites).
    ///
    /// Cross-process readers (widget providers, extensions) continue to use the
    /// "lastUserPauseTime" UserDefaults key — we do not change that contract.
    func wasRecentlyUserPaused(within interval: TimeInterval = 8.0) async -> Bool {
        // For true cold-launch or first recovery before any pause has been recorded,
        // treat as "not recently paused".
        guard lastUserPauseTimestamp > 0 else { return false }
        return Date().timeIntervalSince1970 - lastUserPauseTimestamp < interval
    }

    /// Public helper for external callers (e.g. ViewController pause paths) to record
    /// an explicit user pause timestamp into the authoritative actor state.
    ///
    /// This keeps the in-actor `lastUserPauseTimestamp` (used by recovery paths via
    /// `wasRecentlyUserPaused()`) in sync when pauses are initiated from ViewController
    /// surfaces that also need to write the raw UserDefaults key for extension readers.
    ///
    /// Chunk 3: Part of eliminating the need for defensive raw-UD + sync "Brave guards"
    /// in DirectStreamingPlayer recovery logic.
    nonisolated func recordUserPauseTimestamp() async {
        await _recordUserPauseTimestampInternal()
    }
    
    private func _recordUserPauseTimestampInternal() async {
        lastUserPauseTimestamp = Date().timeIntervalSince1970
    }

    /// Single internal entry point for all playback intent transitions.
    /// This is the **only** place that mutates `playbackIntent`.
    ///
    /// Call this (never assign `playbackIntent` directly) from every user-driven
    /// play/pause/stop/lock path so that `currentPlaybackIntent` becomes the
    /// authoritative answer to "does the user want audio playing right now?"
    ///
    /// Future increments inside Phase 1 will centralize sticky enforcement
    /// (`.userPaused` and `.securityLocked` only cleared by explicit user play)
    /// inside this method.
    internal func updatePlaybackIntent(to intent: PlaybackIntent) {
        if playbackIntent != intent {
            #if DEBUG
            print("🎯 [SharedPlayerManager] playbackIntent: \(playbackIntent) → \(intent)")
            #endif
            playbackIntent = intent
        }
    }
    
    // MARK: - Computed Properties (nonisolated safe access)
    
    // NEW: Make sharedDefaults easily accessible (nonisolated since it's read-only & safe)
    nonisolated private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: "group.radio.lutheran.shared")
    }
    
    // Widget-safe methods that won't crash
    nonisolated var availableStreams: [DirectStreamingPlayer.Stream] {
        return DirectStreamingPlayer.availableStreams
    }
    
    // MARK: - Initialization
    private init() {
    }
    
    // MARK: - Nonisolated Public Surface (Widget / Extension Safe)
    //
    // These entry points are safe for widget intents, timeline providers, Control Center,
    // Live Activities, and other non-actor contexts. They either perform no actor work
    // or hop internally via Task.
    
    /// Returns the authoritative visual state for widget/extension decision paths and fallbacks.
    ///
    /// Strongly prefers the combined `PersistedWidgetState` snapshot. Falls back to the
    /// legacy "playerVisualState" JSON only for very old installs that have never written
    /// a snapshot.
    nonisolated static func loadPersistedVisualStateDirect() -> PlayerVisualState {
        // Preferred: the unified snapshot (written from both main app and widget intents)
        if let combined = loadPersistedWidgetState() {
            return combined.visualState
        }
        // Legacy migration fallback only
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared"),
              let data = defaults.data(forKey: "playerVisualState"),
              let decoded = try? JSONDecoder().decode(PlayerVisualState.self, from: data) else {
            return .prePlay
        }
        return decoded
    }
    
    nonisolated func isRunningInWidget() -> Bool {
        #if DEBUG
        if Bundle.main.bundleIdentifier?.hasSuffix(".widget") == true {
            print("Running in widget (bundle ID suffix)")
        }
        #endif
        return Bundle.main.bundleIdentifier?.hasSuffix(".widget") == true ||
        ProcessInfo.processInfo.environment["WidgetKit"] != nil
    }
    
    /// Nonisolated convenience for widget/extension code paths that run outside actor isolation
    /// (e.g. handleWidgetPlay / handleWidgetStop). Fires a quick hop to ensure the persisted state is loaded
    /// before the method does its optimistic mutation.
    nonisolated public func ensureVisualStateLoadedForWidget() {
        Task { await Self.shared.ensureVisualStateLoaded() }
    }
    
    /// Nonisolated helper that widget intents can call to persist a visual state directly.
    /// This gives the next Provider run (even before the Darwin roundtrip completes) something
    /// authoritative to load.
    ///
    /// Writes the combined `PersistedWidgetState` snapshot (visual + current preferred language).
    /// This makes the snapshot the single source of truth for both authoritative saves from the
    /// main app and optimistic updates from widget intents. Providers that check the snapshot
    /// first see correct play/pause + language immediately.
    ///
    /// Also updates the in-memory currentVisualState in this process.
    nonisolated public func forcePersistVisualState(_ state: PlayerVisualState) {
        Self.persistWidgetSnapshot(visualState: state, language: Self.preferredWidgetLanguage())
        // Update in-memory so the widget process sees the fresh state on the next snapshot
        // without waiting for a Darwin round-trip or a full re-load.
        Task { await Self.shared._forceSetCurrentVisualState(state) }
    }

    private func _forceSetCurrentVisualState(_ state: PlayerVisualState) {
        currentVisualState = state
        hasLoadedVisualStateFromPersistence = true
    }

    /// Public entry point for widget/extension providers to guarantee they read the real persisted state.
    /// Call this once at the top of any Provider method before reading currentVisualState or loadSharedState for UI decisions.
    public func syncVisualStateFromPersistence() async {
        ensureVisualStateLoaded()
    }
    
    /// Forces a fresh load of the persisted PlayerVisualState JSON from the App Group container.
    /// Widget Providers (home screen + Control) should call this before reading currentVisualState
    /// for UI decisions. It resets the one-shot guard so that updates written by forcePersistVisualState
    /// (or by the main app via saveVisualState) are seen even in long-lived extension processes.
    public func refreshVisualStateFromPersistence() async {
        hasLoadedVisualStateFromPersistence = false
        ensureVisualStateLoaded()
    }
    
    // MARK: - Public Async API
    //
    // These are the primary methods called by the main app, DirectStreamingPlayer recovery logic,
    // user intent paths, and widget action handlers (after they have performed their optimistic updates).

    /// Safe, single entry point to change the visual state from anywhere.
    /// (Notification handlers, MainActor, background tasks, etc.)
    func setVisualState(_ state: PlayerVisualState) async {
        self.currentVisualState = state
    }
    
    /// Public async entry point for playing.
    ///
    /// Performs security validation, clears any sticky `.userPaused` lock for explicit user actions,
    /// respects the cold-launch resurrection window, and drives the real player via `DirectStreamingPlayer`.
    /// Widget callers take the optimistic instant-feedback path.
    func play() async {
        ensureVisualStateLoaded()
        
        // 🔥 FINAL FIX: Always clear .userPaused lock at the absolute top of play()
        // This covers widget play, Control Center, lockscreen, CarPlay, Siri — everything.
        await clearUserPausedLockIfNeeded()
        
        #if DEBUG
        print("🎵 SharedPlayerManager.play() ENTERED – currentPlaybackIntent = \(currentPlaybackIntent), currentVisualState = \(currentVisualState)")
        #endif
        
        // ──────────────────────────────────────────────────────────────
        // Cold-launch grace period (Phase 3 final state)
        // After intent unification (Phases 1-3), this 25s window + one-shot flag
        // is the *only* remaining special-case resurrection relaxation.
        // It is narrowly scoped to `.prePlay` first-play only and is always
        // subordinate to explicit `.userPaused` / `.securityLocked` intent.
        let isInColdLaunchWindow = !initialPlaybackHasRun ||
            Date().timeIntervalSince(appLaunchTime) < initializationSettlingPeriod + 20.0
        // ──────────────────────────────────────────────────────────────
        
        // HARD RULE: Never bypass resurrection protection for explicit user pause,
        // even inside the cold-launch window. User intent wins.
        // Chunk 2 (sub-increment 2.3): Now driven by authoritative currentPlaybackIntent
        // (wired in Chunk 1; visualState check collapsed here for consistency with central path).
        if currentPlaybackIntent == .userPaused {
            #if DEBUG
            print("🔒 [SharedPlayerManager] play() HARD-BLOCKED — explicit .userPaused (cold-launch bypass ignored)")
            #endif
            return
        }
        
        // CENTRAL RESURRECTION PROTECTION — relaxed only for prePlay during true cold launch
        // Chunk 2 (sub-increment 2.2): playbackIntent is now the primary/sole signal here.
        // The parallel visualState guard has been removed as we collapse overlapping checks.
        // Intent is authoritative (all transitions wired in Chunk 1).
        if !isInColdLaunchWindow {
            if currentPlaybackIntent == .userPaused || currentPlaybackIntent == .securityLocked {
                #if DEBUG
                print("🔒 [SharedPlayerManager] play() BLOCKED by playbackIntent = \(currentPlaybackIntent)")
                #endif
                return
            }
        } else {
            #if DEBUG
            print("🚀 Cold-launch window active – bypassing normal resurrection protection (except .userPaused) [Phase 3: minimal special case]")
            #endif
        }
        
        // Re-entrancy guard (Phase 3 Chunk 2): Detect actual AVPlayer state to break recovery loops.
        // Intent is the primary signal; this visual check is deliberately narrow (only outside cold window)
        // to protect against tight recovery-task loops when the player is already playing.
        if currentVisualState == .playing && !isInColdLaunchWindow {
            #if DEBUG
            print("✅ SharedPlayerManager.play() — already .playing, skipping redundant call (recovery loop prevented)")
            #endif
            return
        }
        
        // === ONE-SHOT GUARD FOR COLD LAUNCH INITIAL PLAYBACK (Phase 3 Chunk 1) ===
        // Cold-launch special casing is now minimal. The authoritative `currentPlaybackIntent`
        // is the primary signal; the one-shot flag only prevents duplicate first-play attempts
        // when we do *not* have explicit user play intent.
        if currentVisualState == .prePlay {
            if initialPlaybackHasRun && currentPlaybackIntent != .shouldBePlaying {
                #if DEBUG
                print("SharedPlayerManager.play() – skipping duplicate initial playback on cold launch")
                #endif
                return
            } else {
                if currentPlaybackIntent == .shouldBePlaying {
                    initialPlaybackHasRun = false
                } else {
                    initialPlaybackHasRun = true
                }
                #if DEBUG
                print("SharedPlayerManager.play() – this is the first cold-launch play call, proceeding")
                #endif
            }
        }
        
        let isValid = await SecurityModelValidator.shared.validateSecurityModel()
        
        #if DEBUG
        print("🔐 SecurityModelValidator returned: \(isValid)")
        if !isValid {
            print("❌ Validation failed → bailing out of playback")
        } else {
            print("✅ Validation passed → proceeding with playback")
        }
        #endif
        
        guard isValid else {
            #if DEBUG
            print("🔒 Permanent security validation failure — locking UI to .securityLocked")
            #endif
            
            // Direct mutation inside the actor (this is allowed and correct)
            self.currentVisualState = .securityLocked
            
            // Chunk 1: Wire the authoritative intent writer (security lock is permanent until explicit play succeeds).
            updatePlaybackIntent(to: .securityLocked)
            
            await self.saveCurrentState()
            
            #if DEBUG
            print("✅ Security lock applied – currentVisualState is now .securityLocked")
            #endif
            return
        }
        
        if isRunningInWidget() {
            handleWidgetPlay()
            return
        }
        
        // Wait for tuning sound (critical!)
        await waitForTuningSoundIfActive()
        
        let stream = DirectStreamingPlayer.shared.selectedStream
        #if DEBUG
        print("🎵 Setting stream to: \(stream)")
        #endif
        
        await DirectStreamingPlayer.shared.setStreamAndPlay(to: stream)
        
        // No saveCurrentState() here — observer will handle it
    }
    
    /// Forces the visual state to `.securityLocked` (permanent failure) and persists it.
    /// Called from server 403 responses or unrecoverable validation failures.
    func setSecurityLocked() async {
        self.currentVisualState = .securityLocked
        await self.saveCurrentState()
        
        #if DEBUG
        print("✅ Security lock applied from server 403 response")
        #endif
    }
    
    /// Safe resurrection entry point used by DirectStreamingPlayer recovery logic.
    /// Allows technical recovery (hiccups) even when visualState = .playing.
    ///
    /// Chunk 2 (first sub-increment): playbackIntent is now the *primary* (and sole)
    /// decision signal for this path. The old visualState guard has been removed
    /// as part of collapsing parallel checks — intent is authoritative because
    /// all sticky transitions (Chunk 1) now flow through updatePlaybackIntent.
    func attemptResurrectionIfAllowed() async {
        ensureVisualStateLoaded()
        
        #if DEBUG
        print("🚀 SharedPlayerManager.attemptResurrectionIfAllowed() – currentPlaybackIntent = \(currentPlaybackIntent), currentVisualState = \(currentVisualState)")
        #endif

        // PRIMARY GUARD: Driven by authoritative playbackIntent (Chunk 2).
        // Blocks for explicit user pause or permanent security lock.
        // This replaces the previous dual-guard pattern in this narrow recovery path.
        if currentPlaybackIntent == .userPaused || currentPlaybackIntent == .securityLocked {
            #if DEBUG
            print("🔒 [SharedPlayerManager] resurrection BLOCKED by playbackIntent = \(currentPlaybackIntent)")
            #endif
            return
        }

        // Light check — if the player is already playing, do nothing
        if DirectStreamingPlayer.shared.isActuallyPlaying() {
            #if DEBUG
            print("✅ SharedPlayerManager: already actually playing — skipping redundant recovery")
            #endif
            return
        }

        #if DEBUG
        print("🔄 Resurrection proceeding — player is stalled, forcing light recovery")
        #endif

        // Light recovery: just force the existing player back to life (no full validation/tuning/stream switch)
        await MainActor.run {
            DirectStreamingPlayer.shared.player?.playImmediately(atRate: 1.0)
        }
    }
    
    /// Called whenever the *user* explicitly taps Play (in-app button, lockscreen, Control Center, widgets, CarPlay…).
    /// This **exactly** mirrors the PLAY branch in `togglePlayback()` so there is zero behavioral difference.
    func userRequestedPlay() async {
        #if DEBUG
        print("SharedPlayerManager.userRequestedPlay() — setUserIntentToPlay + play() for explicit user intent")
        #endif
        
        await setUserIntentToPlay()
        await play()   // ← Fixed: no try/catch needed (play() is now non-throwing)
    }
    
    /// Explicitly records that the user performed a manual pause or stop.
    /// This locks .userPaused so resurrection paths are blocked.
    func markAsUserPaused() async {
        ensureVisualStateLoaded()
        
        #if DEBUG
        print("🔒 markAsUserPaused() called – forcing .userPaused to block resurrection")
        #endif
        
        // We are inside the actor, so mutation is allowed
        currentVisualState = .userPaused
        
        // Chunk 1: Wire the authoritative intent writer.
        updatePlaybackIntent(to: .userPaused)
        
        // Chunk 3 (3.2.2): Record authoritative pause timestamp for recovery paths.
        // This lets wasRecentlyUserPaused() return correct answers without raw UD reads.
        lastUserPauseTimestamp = Date().timeIntervalSince1970
        
        // Persist the locked state
        await saveCurrentState()
        
        #if DEBUG
        print("✅ Visual state locked to .userPaused")
        #endif
    }
    
    /// Public async entry point for stopping playback.
    ///
    /// Immediately locks visual state to `.userPaused` (sticky resurrection protection) and persists it,
    /// then stops the real player (main app path) or schedules the widget stop action.
    public func stop() async {
        ensureVisualStateLoaded()
        
        #if DEBUG
        print("🚀 SharedPlayerManager.stop() ENTERED – currentVisualState = \(currentVisualState)")
        #endif

        // 🔥 CRITICAL FIX: Lock .userPaused IMMEDIATELY at the very top
        // This closes the race window that causes resurrection after pause
        currentVisualState = .userPaused
        saveVisualState()   // persist early so widgets, Live Activity, and Darwin notifications see the new state

        // Chunk 1: Wire the authoritative intent writer (single source for sticky pause).
        updatePlaybackIntent(to: .userPaused)

        // Chunk 3 (3.2.2): Record authoritative pause timestamp (used by recovery query).
        lastUserPauseTimestamp = Date().timeIntervalSince1970

        #if DEBUG
        print("🛡️ userPaused locked immediately in stop() (resurrection protection active)")
        #endif

        if isRunningInWidget() {
            handleWidgetStop()
            return
        }

        // Main app path
        DirectStreamingPlayer.shared.stop()
        DirectStreamingPlayer.shared.player?.replaceCurrentItem(with: nil)
        
        // Always save after stop
        await saveCurrentState()
        
        notifyMainApp(action: "pause")
        
        #if DEBUG
        print("🛑 stop() completed – visualState locked to .userPaused")
        #endif
    }
    
    /// Nonisolated entry point for stream switching.
    ///
    /// Widget path schedules the switch via App Group + Darwin notification and returns immediately.
    /// Main app path forwards to `DirectStreamingPlayer`.
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
    /// Called **only** from `completeStreamSwitch`.
    /// This is the single place we intentionally allow the cold-launch-like first-play
    /// path after a switch while preserving `.userPaused` / `.securityLocked` protection.
    ///
    /// Phase 3 Chunk 3: Documentation modernized to reflect that cold-launch special
    /// casing is now minimal and driven by the authoritative intent model.
    func resetToPrePlayForNewStream() async {
        // 🔥 CRITICAL FIX: Always clear .userPaused lock for widget pure-play actions
        // This makes widget play/pause 100% reliable (was missing in pure-play path)
        await clearUserPausedLockIfNeeded()

        currentVisualState = .prePlay
        initialPlaybackHasRun = false
        saveVisualState()
        await saveCurrentState()

        // NOTE: We no longer write persistedWidgetState snapshot here.
        // resetToPrePlayForNewStream is the intentional cold-launch-style reset for
        // stream switches so the next play() call gets the correct first-play path.
        // Language changes are driven by callers via updateUserDefaultsLanguage() →
        // saveCombinedWidgetState(), which is the single place that authors the atomic
        // (visual + language) snapshot. This eliminates a source of potentially-stale
        // language in the snapshot (the old read of "currentLanguage" here could race
        // with the update in some call orders, e.g. widget switch handler).
        // performActualSave will still write the snapshot if it detects a language
        // change via its internal check.
        
        #if DEBUG
        print("🔄 [SharedPlayerManager] resetToPrePlayForNewStream() — state reset to .prePlay for atomic stream switch")
        #endif
    }
    
    /// Called only when the user taps the play button (or widget play action).
    /// Clears the .userPaused lock so resume is allowed.
    /// Resets the cold-launch guard ONLY for manual resumes.
    func setUserIntentToPlay() async {
        ensureVisualStateLoaded()
        
        #if DEBUG
        print("🎯 setUserIntentToPlay() called – clearing .userPaused lock")
        #endif
        
        if currentVisualState == .userPaused {
            currentVisualState = .prePlay
            
            // This is the critical line: allow resume without breaking cold-launch protection
            initialPlaybackHasRun = false
            
            #if DEBUG
            print("🎯 setUserIntentToPlay() → reset initialPlaybackHasRun = false (resume now allowed)")
            #endif
        }
        
        // Chunk 1: Wire the authoritative intent writer.
        updatePlaybackIntent(to: .shouldBePlaying)
        
        saveVisualState()
        await saveCurrentState()
    }
    
    /// Sets the visual state to .userPaused and persists it.
    /// This is the canonical way to record user-initiated pause intent.
    func setUserPaused() async {
        ensureVisualStateLoaded()
        currentVisualState = .userPaused
        
        // Chunk 1: Wire the authoritative intent writer.
        updatePlaybackIntent(to: .userPaused)
        
        // Chunk 3 (3.2.2): Record authoritative pause timestamp.
        lastUserPauseTimestamp = Date().timeIntervalSince1970
        
        saveVisualState()
        await saveCurrentState()
    }
    
    /// Sets the visual state to .playing and persists it.
    /// Call after successful playback start/resume.
    func setPlaying() async {
        ensureVisualStateLoaded()
        currentVisualState = .playing
        
        // Chunk 1: Wire the authoritative intent writer.
        updatePlaybackIntent(to: .shouldBePlaying)
        
        saveVisualState()
        await saveCurrentState()
    }
    
    /// Safe restoration – ALWAYS respects .userPaused and blocks resurrection.
    /// Call this on:
    /// - App/scene foreground
    /// - AVAudioSession interruption .shouldResume
    /// - Widget timeline reload
    /// - Any other system resume signal
    ///
    /// Phase 3 Chunk 5: Primary signal is now `currentPlaybackIntent`. The method is
    /// intentionally simple because most resurrection complexity has been collapsed
    /// into the intent model in earlier phases.
    func restoreVisualStateRespectingUserIntent() async {
        ensureVisualStateLoaded()
        
        // Chunk 2 (sub-increment 2.4) + Phase 3: playbackIntent is the primary signal.
        // Visual-based suppression below is secondary (for loading persisted state only).
        if currentPlaybackIntent == .userPaused || currentPlaybackIntent == .securityLocked {
            #if DEBUG
            print("🔒 [SharedPlayerManager] restoreVisualStateRespectingUserIntent BLOCKED by playbackIntent = \(currentPlaybackIntent)")
            #endif
            return
        }
        
        // If we already loaded something sticky from JSON, keep it; otherwise do the normal restore logic.
        if !hasLoadedVisualStateFromPersistence {
            let loaded = loadVisualState()
            currentVisualState = PlayerVisualState.suppressResurrectionIfNeeded(currentState: loaded)
        }
        
        saveVisualState()
        await saveCurrentState()
        
        if currentVisualState.mustSuppressResurrection {
            #if DEBUG
            print("🔒 Resurrection suppressed — userPaused is sticky")
            #endif
        } else if currentVisualState.shouldAutoPlayOrResume {
            #if DEBUG
            print("▶️ Allowed to resume playback")
            #endif
        }
    }
    
    // MARK: - Private Visual State Loading Guard
    
    /// Ensures the authoritative visual state is loaded from UserDefaults persistence.
    /// Safe to call repeatedly; only does work the first time per process (or after explicit reset).
    /// Widget providers and widget-side play/stop paths must call this (directly or via sync)
    /// before trusting currentVisualState.
    ///
    /// Phase 3 Chunk 5: This method feeds the intent-driven paths. Any legacy fallback
    /// is only for very old installs that never wrote a PersistedWidgetState snapshot.
    private func ensureVisualStateLoaded() {
        guard !hasLoadedVisualStateFromPersistence else { return }
        
        // Preferred: the full PlayerVisualState we persisted via saveVisualState()
        let loaded = loadVisualState()
        
        // If we got something other than the default (i.e. JSON was present), trust it.
        if loaded != .prePlay {
            currentVisualState = loaded
        } else {
            // Fallback for older data: derive from the classic "playing" bool written by saveCurrentState()
            // Treat anything that is not an explicit user pause as non-sticky here; the main app will correct on next real action.
            let legacyIsPlaying = sharedDefaults?.bool(forKey: "playing") ?? false
            currentVisualState = legacyIsPlaying ? .playing : .userPaused
        }
        
        hasLoadedVisualStateFromPersistence = true
        
        #if DEBUG
        if isRunningInWidget() {
            print("🔗 [Widget] ensureVisualStateLoaded → currentVisualState = \(currentVisualState)")
        }
        #endif
    }
    
    // MARK: - Private Helpers for Playback Control
    
    /// Clears the userPaused resurrection lock when a widget explicitly requests Play.
    /// Called from handleWidgetPlayAction() so the widget can always start playback.
    public func clearUserPausedLockIfNeeded() async {
        ensureVisualStateLoaded()
        if currentVisualState == .userPaused {
            #if DEBUG
            print("🔗 [Widget] Cleared userPaused lock for widget play action")
            #endif
            currentVisualState = .prePlay
            
            // Chunk 1: Wire the authoritative intent writer (widget play clears the pause lock).
            updatePlaybackIntent(to: .shouldBePlaying)
        }
    }
    
    /// Waits for the special tuning sound to finish before starting main radio playback.
    /// This eliminates the session / timing conflict that was preventing the stream from starting.
    private func waitForTuningSoundIfActive() async {
        // A proper notification/flag from the tuning-sound player would be cleaner than a fixed delay.
        // The current 1200 ms value has proven reliable across devices on cold launch.
        #if DEBUG
        print("⏳ Waiting for tuning sound to finish before main playback...")
        #endif
        
        try? await Task.sleep(for: .milliseconds(1200))
        
        #if DEBUG
        print("✅ Tuning sound wait completed")
        #endif
    }
    
    private func handleWidgetPlay() {
        ensureVisualStateLoadedForWidget()
        
        // Instant visual feedback for widget
        let now = Date().timeIntervalSince1970
        sharedDefaults?.set(now, forKey: "lastUpdateTime")
        sharedDefaults?.set(true, forKey: "isInstantFeedback")
        sharedDefaults?.set(now, forKey: "instantFeedbackTime")
        // Architectural shift: source from preferred (combined snapshot) even when writing legacy instant key
        sharedDefaults?.set(Self.preferredWidgetLanguage(), forKey: "instantFeedbackLanguage")
        
        // CRITICAL: Optimistic SSOT update (same pattern we already use in stop)
        currentVisualState = .playing
        
        // Chunk 1: Wire the authoritative intent writer for the optimistic widget play path.
        updatePlaybackIntent(to: .shouldBePlaying)
        
        saveVisualState()
        
        scheduleWidgetAction(action: "play")
        notifyMainApp(action: "play")
        
        // Small delay + optimistic widget refresh using the modern API
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            // Architectural shift: Prefer combined snapshot for optimistic language (no direct old key)
            let language = Self.preferredWidgetLanguage()
            
            await WidgetRefreshManager.shared.refreshIfNeeded(
                visualState: .playing,           // ← modern path
                currentLanguage: language,
                hasError: false,
                immediate: true
            )
            
            saveFireAndForget()
        }
    }
    
    private func handleWidgetStop() {
        ensureVisualStateLoadedForWidget()
        
        // Instant visual feedback for widget using the new authoritative state
        let now = Date().timeIntervalSince1970
        sharedDefaults?.set(now, forKey: "lastUpdateTime")
        sharedDefaults?.set(true, forKey: "isInstantFeedback")
        sharedDefaults?.set(now, forKey: "instantFeedbackTime")
        // Architectural shift: source from preferred (combined snapshot) even when writing legacy instant key
        sharedDefaults?.set(Self.preferredWidgetLanguage(), forKey: "instantFeedbackLanguage")
        
        // CRITICAL: Set the paused state synchronously for widget path
        currentVisualState = .userPaused
        
        // Chunk 1: Wire the authoritative intent writer for the optimistic widget stop path.
        updatePlaybackIntent(to: .userPaused)
        
        // Chunk 3 (3.2.2): Record authoritative pause timestamp for recovery paths.
        lastUserPauseTimestamp = Date().timeIntervalSince1970
        
        saveVisualState()
        
        scheduleWidgetAction(action: "pause")
        notifyMainApp(action: "pause")
        
        // Small delay + optimistic widget refresh using the modern API
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            // Architectural shift: Prefer combined snapshot for optimistic language (no direct old key)
            let language = Self.preferredWidgetLanguage()
            
            await WidgetRefreshManager.shared.refreshIfNeeded(
                visualState: currentVisualState,   // already .userPaused
                currentLanguage: language,
                hasError: false,
                immediate: true
            )
        }
    }
    
    // This helper must be nonisolated because it's called from the nonisolated switchToStream
    nonisolated private func handleWidgetSwitch(to stream: DirectStreamingPlayer.Stream) {
        let now = Date().timeIntervalSince1970
        sharedDefaults?.set(now, forKey: "lastUpdateTime")
        sharedDefaults?.set(true, forKey: "isInstantFeedback")
        sharedDefaults?.set(now, forKey: "instantFeedbackTime")
        sharedDefaults?.set(stream.languageCode, forKey: "instantFeedbackLanguage")
        sharedDefaults?.synchronize()

        // Phase 11: Best-effort write of the combined snapshot from the widget side.
        // Prefer the unified snapshot (or in-memory after any prior force in this process).
        // The legacy "playerVisualState" read has been removed (writes retired).
        // Main app will follow with authoritative saveCurrentState shortly.
        let visualForSwitch: PlayerVisualState
        if let combined = Self.loadPersistedWidgetState() {
            visualForSwitch = combined.visualState
        } else {
            // Fresh widget extension process with no prior snapshot in this launch — safe default.
            // The calling intent (SwitchStreamIntent) will have already persisted a snapshot
            // with the correct visual derived from loadSharedState just before this path.
            visualForSwitch = .prePlay
        }
        let snapshot = PersistedWidgetState(
            visualState: visualForSwitch,
            currentLanguage: stream.languageCode,
            lastLanguageChangeTime: Date()
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            sharedDefaults?.set(data, forKey: "persistedWidgetState")
            sharedDefaults?.synchronize()
        }
        
        scheduleWidgetAction(action: "switch", parameter: stream.languageCode)
        notifyMainApp(action: "switch", parameter: stream.languageCode)
        
        #if DEBUG
        print("🔗 Widget stream switch scheduled: \(stream.languageCode)")
        #endif
    }
    
    // MARK: - Widget Action Scheduling & Darwin Notifications (nonisolated)
    //
    // These methods schedule work for the main app via App Group + Darwin notifications.
    // They are deliberately nonisolated so widget intent handlers can call them without
    // crossing the actor boundary on the hot path.

    // Schedule widget action for main app to handle
    nonisolated private func scheduleWidgetAction(action: String, parameter: String? = nil) {
        guard let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            #if DEBUG
            print("🔗 ERROR: Failed to access shared UserDefaults in scheduleWidgetAction")
            #endif
            return
        }
        
        let actionId = UUID().uuidString
        sharedDefaults.set(action, forKey: "pendingAction")
        sharedDefaults.set(actionId, forKey: "pendingActionId")
        sharedDefaults.set(Date().timeIntervalSince1970, forKey: "pendingActionTime")
        
        // CRITICAL FIX: Always set the language parameter for switch actions
        if let param = parameter {
            sharedDefaults.set(param, forKey: "pendingLanguage")
            #if DEBUG
            print("🔗 Set pendingLanguage: \(param)")
            #endif
        } else if action == "switch" {
            // Fallback: use preferred (combined snapshot first) for pendingLanguage
            // DEPRECATED direct key read — will be removed after migration complete.
            let currentLanguage = Self.preferredWidgetLanguage()
            sharedDefaults.set(currentLanguage, forKey: "pendingLanguage")
            #if DEBUG
            print("🔗 Set fallback pendingLanguage: \(currentLanguage)")
            #endif
        }
        
        // Force synchronization
        sharedDefaults.synchronize()
        
        #if DEBUG
        print("🔗 Scheduled widget action: \(action) \(parameter ?? "") [ID: \(actionId)]")
        print("🔗 UserDefaults synchronized for App Group")
        #endif
    }
    
    // Notify main app using Darwin notifications
    nonisolated private func notifyMainApp(action: String, parameter: String? = nil) {
        let notificationName = "radio.lutheran.widget.action"
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(notificationName as CFString), nil, nil, true)
        
        #if DEBUG
        print("🔗 Posted Darwin notification for action: \(action)")
        #endif
    }
    
    /// Returns the currently pending widget action (if any), along with its parameter and unique ID.
    /// Used by the main app (typically in SceneDelegate or a notification handler) to process
    /// play/stop/switch requests originating from widgets or Control Center.
    func getPendingAction() -> (action: String, parameter: String?, actionId: String)? {
        guard let action = sharedDefaults?.string(forKey: "pendingAction"),
              let actionId = sharedDefaults?.string(forKey: "pendingActionId") else {
            return nil
        }
        
        let parameter = sharedDefaults?.string(forKey: "pendingLanguage")
        return (action, parameter, actionId)
    }
    
    /// Clears a pending widget action only if the provided `actionId` still matches the current one.
    /// Prevents race conditions when multiple rapid widget taps occur.
    func clearPendingAction(actionId: String) {
        // Only clear if the action ID matches to prevent race conditions
        if let currentActionId = sharedDefaults?.string(forKey: "pendingActionId"),
           currentActionId == actionId {
            sharedDefaults?.removeObject(forKey: "pendingAction")
            sharedDefaults?.removeObject(forKey: "pendingActionId")
            sharedDefaults?.removeObject(forKey: "pendingActionTime")
            sharedDefaults?.removeObject(forKey: "pendingLanguage")
            
            #if DEBUG
            print("🔗 Cleared pending action with ID: \(actionId)")
            #endif
        }
    }
    
    // MARK: - PlayerVisualState Persistence & Restoration (Private)

    private func saveVisualState() {
        // Intentionally a no-op for persistence.
        // All visual + language state flows through the PersistedWidgetState snapshot
        // written by performActualSave and the widget intent paths. The call sites
        // remain for in-memory discipline and resurrection protection.
    }

    private func loadVisualState() -> PlayerVisualState {
        // Prefer the combined snapshot for actor in-memory initialization
        // (both main app and widget extension processes). Legacy key is migration-only.
        if let combined = Self.loadPersistedWidgetState() {
            return combined.visualState
        }
        guard let data = sharedDefaults?.data(forKey: "playerVisualState"),
              let decoded = try? JSONDecoder().decode(PlayerVisualState.self, from: data) else {
            return .prePlay   // safe fallback for first launch
        }
        return decoded
    }

    // MARK: - Persisted Widget State (visual + language snapshot)

    /// Combined snapshot that carries both visual intent and language.
    /// This is the preferred path for cross-process widget and Live Activity correctness.
    struct PersistedWidgetState: Codable {
        let visualState: PlayerVisualState
        let currentLanguage: String
        let lastLanguageChangeTime: Date?
    }

    /// Saves the combined visual + language state as a single atomic blob.
    /// This is the new preferred path for cross-process widget correctness.
    private func savePersistedWidgetState(visualState: PlayerVisualState, language: String) {
        let snapshot = PersistedWidgetState(
            visualState: visualState,
            currentLanguage: language,
            lastLanguageChangeTime: Date()
        )
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(snapshot) {
            sharedDefaults?.set(data, forKey: "persistedWidgetState")
            sharedDefaults?.synchronize()
        }
    }

    /// Loads the combined visual + language snapshot.
    ///
    /// Pre-unification installs without a snapshot receive nil and fall back to safe
    /// defaults (.prePlay / "en") at call sites.
    nonisolated static func loadPersistedWidgetState() -> (visualState: PlayerVisualState, currentLanguage: String)? {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return nil }

        // Preferred (and now only) path: the unified PersistedWidgetState snapshot.
        // Written bidirectionally from performActualSave, saveCombined, forcePersist,
        // and persistWidgetSnapshot. All widget providers and Live Activities should
        // check this first.
        if let data = defaults.data(forKey: "persistedWidgetState"),
           let decoded = try? JSONDecoder().decode(PersistedWidgetState.self, from: data) {
            return (decoded.visualState, decoded.currentLanguage)
        }

        // No migration fallback remains for the retired playerVisualState / currentLanguage keys.
        // Old installs without a snapshot get the safe .prePlay / "en" defaults at usage sites.
        return nil
    }

    /// Nonisolated static writer for the combined PersistedWidgetState snapshot.
    /// Used by widget intents (optimistic path) and by forcePersistVisualState so that
    /// providers see fresh visual + language immediately via their early snapshot check,
    /// even before the main app processes the Darwin notification.
    nonisolated static func persistWidgetSnapshot(visualState: PlayerVisualState, language: String) {
        let snapshot = PersistedWidgetState(
            visualState: visualState,
            currentLanguage: language,
            lastLanguageChangeTime: Date()
        )
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(snapshot) {
            if let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") {
                defaults.set(data, forKey: "persistedWidgetState")
                defaults.synchronize()
            }
        }
    }

    /// Preferred source for widget language (and callers that need display language for
    /// widgets and Live Activities). Strongly prefers the combined `PersistedWidgetState`
    /// snapshot. Falls back to the legacy separate "currentLanguage" key only for migration
    /// compatibility.
    ///
    /// Using this helper (instead of reading the raw key directly) routes language reads
    /// through the snapshot and reduces the need for forcing or staleness heuristics.
    nonisolated static func preferredWidgetLanguage() -> String {
        if let combined = loadPersistedWidgetState() {
            return combined.currentLanguage
        }
        // Ultimate fallback (migration only)
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return "en" }
        return defaults.string(forKey: "currentLanguage") ?? "en"
    }

    /// Public entry point for language changes. Persists visual state + language together
    /// in the combined snapshot so widgets receive correct language without extra forcing.
    func saveCombinedWidgetState(language: String) {
        savePersistedWidgetState(visualState: currentVisualState, language: language)

        // 2026-05-29: Legacy separate "currentLanguage" key retired. lastUpdateTime
        // is still bumped for the 60 s "isAppRunning" widget check and general freshness.
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "lastUpdateTime")
        sharedDefaults?.synchronize()
    }
}

// MARK: - UserDefaults Communication
extension SharedPlayerManager {
    
    // Now async – callers must await this when they want to save
    func saveCurrentState() async {
        guard !isRunningInWidget() else { return }
        
        let player = DirectStreamingPlayer.shared
        
        let now = Date()
        
        // Fetch current values from the real player
        // NOTE (architectural shift): Language read now goes through preferredWidgetLanguage()
        // which strongly prefers the combined PersistedWidgetState snapshot. The old direct
        // key read is only in the ultimate fallback inside the helper (migration path).
        let currentLanguageCode = Self.preferredWidgetLanguage()
        let isPermanentError    = await player.isLastErrorPermanent()
        // Source the legacy "playing" bool from the authoritative visual state (SSOT),
        // not the racy snapshot in actualPlaybackState. The snapshot frequently returns
        // false during normal playback (KVO timing, brief buffering, rate reads) causing
        // the "playing" UserDefaults key (used by WidgetToggleRadioIntent decision logic
        // and loadSharedState fallbacks) to be wrong. This was the "elsewhere" causing
        // first-widget-interaction flakiness even after the pause throttle fix.
        let isPlaying           = currentVisualState.isActivelyPlaying
        let hasPermanentError   = player.hasPermanentError
        
        // === NEW: WidgetState is now a computed view of PlayerVisualState (SSOT) ===
        let widgetState = WidgetState(
            from: currentVisualState,                  // ← SharedPlayerManager's SSOT
            currentLanguage: currentLanguageCode,
            hasError: hasPermanentError || isPermanentError,
            isTransitioning: false
        )
        
        let currentState = (
            isPlaying: isPlaying,
            currentLanguage: currentLanguageCode,
            hasError: hasPermanentError || isPermanentError
        )
        
        performActualSave(currentState, widgetState: widgetState, at: now)
    }
    
    nonisolated func saveFireAndForget() {
        Task {
            await saveCurrentState()
        }
    }
    
    private func performActualSave(_ state: (isPlaying: Bool, currentLanguage: String, hasError: Bool),
                                   widgetState: WidgetState,
                                   at time: Date) {
        // The 5 s rapid-save throttle has been removed. The snapshot is written on every
        // call. Providers trust the snapshot first. WidgetRefreshManager handles debouncing
        // and language-change urgency. We retain isLanguageChange detection only for
        // the urgent refresh flag.
        let previousLanguage = Self.loadPersistedWidgetState()?.currentLanguage ?? ""
        let isLanguageChange = !previousLanguage.isEmpty && previousLanguage != state.currentLanguage

        // Always persist the authoritative (visualState + language) snapshot first.
        // Widget providers take the early loadPersistedWidgetState() path for both
        // authoritative and optimistic cases. WidgetRefreshManager handles debouncing
        // and language-change urgency.
        savePersistedWidgetState(visualState: currentVisualState, language: state.currentLanguage)

        // Legacy keys are written only for migration surface. They are no longer
        // rate-limited here; WidgetRefreshManager handles spam protection.
        sharedDefaults?.set(state.isPlaying, forKey: "isPlaying")
        // Legacy language key is no longer written. The snapshot is the primary
        // persistence for widget providers and Live Activities.
        sharedDefaults?.set(state.hasError, forKey: "hasError")
        sharedDefaults?.set(time.timeIntervalSince1970, forKey: "lastUpdateTime")
        
        // Clear instant feedback flags (still required for widget responsiveness)
        sharedDefaults?.removeObject(forKey: "isInstantFeedback")
        sharedDefaults?.removeObject(forKey: "instantFeedbackTime")
        sharedDefaults?.removeObject(forKey: "instantFeedbackLanguage")
        
        let isUrgentUpdate = !state.isPlaying || state.hasError || isLanguageChange
        
        // Always hop to MainActor for WidgetRefreshManager (required in Swift 6)
        Task { @MainActor in
            // ✅ Modern SSOT path — no more legacy WidgetState overload
            WidgetRefreshManager.shared.refreshIfNeeded(
                visualState: widgetState.isPlaying ? .playing : .userPaused,
                currentLanguage: state.currentLanguage,
                hasError: state.hasError,
                immediate: isUrgentUpdate
            )
        }
        
        #if DEBUG
        print("🔗 State saved: playing=\(state.isPlaying), language=\(state.currentLanguage)")
        #endif
    }
    
    // FIXED: Enhanced loadSharedState with better instant feedback handling
    nonisolated func loadSharedState() -> (isPlaying: Bool, currentLanguage: String, hasError: Bool) {
        // Check for instant feedback state first
        if let instantFeedbackTime = sharedDefaults?.object(forKey: "instantFeedbackTime") as? Double,
           let instantFeedbackLanguage = sharedDefaults?.string(forKey: "instantFeedbackLanguage"),
           sharedDefaults?.bool(forKey: "isInstantFeedback") == true {
            
            let age = Date().timeIntervalSince1970 - instantFeedbackTime
            
            // FIXED: Use instant feedback for 15 seconds (increased from 10)
            if age < 15.0 {
                let isPlaying = sharedDefaults?.bool(forKey: "isPlaying") ?? false
                let hasError = sharedDefaults?.bool(forKey: "hasError") ?? false
                
                #if DEBUG
                print("🔗 Using instant feedback state: \(instantFeedbackLanguage), age: \(age)s")
                #endif
                
                return (isPlaying, instantFeedbackLanguage, hasError)
            } else {
                // Clear expired instant feedback
                sharedDefaults?.removeObject(forKey: "isInstantFeedback")
                sharedDefaults?.removeObject(forKey: "instantFeedbackTime")
                sharedDefaults?.removeObject(forKey: "instantFeedbackLanguage")
                
                #if DEBUG
                print("🔗 Cleared expired instant feedback (age: \(age)s)")
                #endif
            }
        }
        
        // Normal state loading
        let isPlaying = sharedDefaults?.bool(forKey: "isPlaying") ?? false
        // Language is returned via the preferred helper (combined snapshot first).
        // This gives the large majority of call sites (Live Activities, many ViewController
        // paths, etc.) the authoritative language with no further changes.
        // The old direct key remains only as the ultimate migration fallback inside
        // preferredWidgetLanguage().
        let currentLanguage = Self.preferredWidgetLanguage()
        let hasError = sharedDefaults?.bool(forKey: "hasError") ?? false
        return (isPlaying, currentLanguage, hasError)
    }
}
