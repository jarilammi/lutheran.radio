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
///   `loadPersistedVisualStateDirect()`, `forcePersistVisualState(...)` (never instantiate a player).
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
/// This is the authoritative shared state model. All values are anonymous. No PII, no listening history.
///
/// | Key                     | Type                  | Primary Writers                                              | Primary Readers (widgets, recovery, UI)                              | Purpose & Semantics                                          | Lifetime / Notes |
/// |-------------------------|-----------------------|--------------------------------------------------------------|----------------------------------------------------------------------|--------------------------------------------------------------|------------------|
/// | playerVisualState       | Data (JSON)           | SharedPlayerManager (`saveVisualState`, all setters), widget timeline providers in some paths | `loadPersistedVisualStateDirect()`, `ensure...`, widgets, Live Activities, `restore...` | **Modern Single Source of Truth** for visual intent. Preferred over legacy bools. | Persisted across launches |
/// | playing (legacy)        | Bool                  | Older paths + fallbacks in `performActualSave`               | `ensureVisualStateLoaded` fallback, some widget decision logic       | Legacy "is radio playing" signal                             | Being phased out; still read as fallback |
/// | isPlaying               | Bool                  | `SharedPlayerManager.performActualSave`                      | `loadSharedState`, widget timeline providers                         | Snapshot derived from `currentVisualState.isActivelyPlaying` | Written on every authoritative save |
/// | currentLanguage         | String (languageCode) | ViewController on switch, SharedPlayerManager save paths     | `loadSharedState`, widgets, Live Activities                          | Currently selected stream language                           | Updated on every stream change |
/// | hasError                | Bool                  | SharedPlayerManager (sourced from player.hasPermanentError)  | `loadSharedState`, widgets                                           | Permanent error flag for UI chrome                           | Set on security or unrecoverable network failures |
/// | lastUpdateTime          | Double (epoch)        | SharedPlayerManager (`performActualSave` + widget handlers)  | Throttling logic inside `performActualSave`, widget providers        | Timestamp of last authoritative state change                 | Used for 5s debounce + instant feedback expiry detection |
/// | lastUserPauseTime       | Double (epoch)        | ViewController (explicit pause paths)                        | DirectStreamingPlayer recovery nudges (two locations)                | Hard 8-second barrier after any user pause                   | Prevents resurrection attempts immediately after pause |
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
    
    // MARK: - Visual State (Single Source of Truth)
    /// Single source of truth for playback intent (UI + widget + Live Activity)
    /// This prevents the "play on pause" resurrection bug when set synchronously to .userPaused
    var currentVisualState: PlayerVisualState = .prePlay
    
    /// Guards one-time loading of the persisted PlayerVisualState JSON (or legacy "playing" bool fallback).
    /// Critical for widget/extension processes which start with a fresh actor instance (default .prePlay).
    private var hasLoadedVisualStateFromPersistence = false
    
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
    
    /// Decodes the "playerVisualState" JSON directly from the App Group UserDefaults.
    /// This is the robust fallback for widget button visuals when no pendingAction is active.
    /// It bypasses the actor's in-memory cache entirely.
    nonisolated static func loadPersistedVisualStateDirect() -> PlayerVisualState {
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
    
    /// Nonisolated helper that widget intents can call to persist a visual state directly to the JSON key.
    /// This gives the next Provider run (even before the Darwin roundtrip completes) something authoritative to load.
    ///
    /// Also updates the in-memory currentVisualState in this process so that any Provider
    /// running in the same widget extension process immediately sees the new value.
    nonisolated public func forcePersistVisualState(_ state: PlayerVisualState) {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(state) {
            sharedDefaults?.set(data, forKey: "playerVisualState")
            sharedDefaults?.synchronize()
        }
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
        print("🎵 SharedPlayerManager.play() ENTERED – currentVisualState = \(currentVisualState)")
        #endif
        
        // ──────────────────────────────────────────────────────────────
        // NEW: Cold-launch grace period (uses your existing vars)
        let isInColdLaunchWindow = !initialPlaybackHasRun ||
            Date().timeIntervalSince(appLaunchTime) < initializationSettlingPeriod + 20.0
        // ──────────────────────────────────────────────────────────────
        
        // HARD RULE: Never bypass resurrection protection for explicit user pause,
        // even inside the cold-launch window. User intent wins.
        if currentVisualState == .userPaused {
            #if DEBUG
            print("🔒 [SharedPlayerManager] play() HARD-BLOCKED — explicit .userPaused (cold-launch bypass ignored)")
            #endif
            return
        }
        
        // CENTRAL RESURRECTION PROTECTION — relaxed only for prePlay during true cold launch
        if !isInColdLaunchWindow {
            guard currentVisualState.shouldAutoPlayOrResume else {
                #if DEBUG
                print("🔒 [SharedPlayerManager] play() BLOCKED — currentVisualState = \(currentVisualState)")
                #endif
                return
            }
        } else {
            #if DEBUG
            print("🚀 Cold-launch window active – bypassing normal resurrection protection (except .userPaused)")
            #endif
        }
        
        // NEW: Prevent re-entrancy loop from recovery tasks (post-head-start + nudges)
        // but allow re-entrancy during cold launch (the transient stopped → playing flips)
        if currentVisualState == .playing && !isInColdLaunchWindow {
            #if DEBUG
            print("✅ SharedPlayerManager.play() — already .playing, skipping redundant call (recovery loop prevented)")
            #endif
            return
        }
        
        // === ONE-SHOT GUARD FOR COLD LAUNCH INITIAL PLAYBACK ===
        if currentVisualState == .prePlay {
            if initialPlaybackHasRun {
                #if DEBUG
                print("SharedPlayerManager.play() – skipping duplicate initial playback on cold launch")
                #endif
                return
            } else {
                initialPlaybackHasRun = true
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
    func attemptResurrectionIfAllowed() async {
        ensureVisualStateLoaded()
        
        #if DEBUG
        print("🚀 SharedPlayerManager.attemptResurrectionIfAllowed() – currentVisualState = \(currentVisualState)")
        #endif

        guard currentVisualState.shouldAutoPlayOrResume else {
            #if DEBUG
            print("🔒 [SharedPlayerManager] resurrection BLOCKED by visualState = \(currentVisualState)")
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
    /// Called **only** from `completeStreamSwitch` (and widget switch paths if needed later).
    /// This is the single place we intentionally bypass the `.playing` guard in `play()`
    /// while preserving `.userPaused` resurrection protection everywhere else.
    func resetToPrePlayForNewStream() async {
        // 🔥 CRITICAL FIX: Always clear .userPaused lock for widget pure-play actions
        // This makes widget play/pause 100% reliable (was missing in pure-play path)
        await clearUserPausedLockIfNeeded()

        currentVisualState = .prePlay
        initialPlaybackHasRun = false
        saveVisualState()
        await saveCurrentState()
        
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
        
        saveVisualState()
        await saveCurrentState()
    }
    
    /// Sets the visual state to .userPaused and persists it.
    /// This is the canonical way to record user-initiated pause intent.
    func setUserPaused() async {
        ensureVisualStateLoaded()
        currentVisualState = .userPaused
        saveVisualState()
        await saveCurrentState()
    }
    
    /// Sets the visual state to .playing and persists it.
    /// Call after successful playback start/resume.
    func setPlaying() async {
        ensureVisualStateLoaded()
        currentVisualState = .playing
        saveVisualState()
        await saveCurrentState()
    }
    
    /// Safe restoration – ALWAYS respects .userPaused and blocks resurrection.
    /// Call this on:
    /// - App/scene foreground
    /// - AVAudioSession interruption .shouldResume
    /// - Widget timeline reload
    /// - Any other system resume signal
    func restoreVisualStateRespectingUserIntent() async {
        ensureVisualStateLoaded()
        
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
        sharedDefaults?.set(sharedDefaults?.string(forKey: "currentLanguage") ?? "en",
                            forKey: "instantFeedbackLanguage")
        
        // CRITICAL: Optimistic SSOT update (same pattern we already use in stop)
        currentVisualState = .playing
        saveVisualState()
        
        scheduleWidgetAction(action: "play")
        notifyMainApp(action: "play")
        
        // Small delay + optimistic widget refresh using the modern API
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            let language = sharedDefaults?.string(forKey: "currentLanguage") ?? "en"
            
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
        sharedDefaults?.set(sharedDefaults?.string(forKey: "currentLanguage") ?? "en",
                            forKey: "instantFeedbackLanguage")
        
        // CRITICAL: Set the paused state synchronously for widget path
        currentVisualState = .userPaused
        saveVisualState()
        
        scheduleWidgetAction(action: "pause")
        notifyMainApp(action: "pause")
        
        // Small delay + optimistic widget refresh using the modern API
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            let language = sharedDefaults?.string(forKey: "currentLanguage") ?? "en"
            
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
            // Fallback: use current stream language if no parameter provided
            let currentLanguage = sharedDefaults.string(forKey: "currentLanguage") ?? "en"
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
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(currentVisualState) {
            sharedDefaults?.set(data, forKey: "playerVisualState")
            sharedDefaults?.synchronize()   // Safe for widget/extension sync
        }
    }

    private func loadVisualState() -> PlayerVisualState {
        guard let data = sharedDefaults?.data(forKey: "playerVisualState"),
              let decoded = try? JSONDecoder().decode(PlayerVisualState.self, from: data) else {
            return .prePlay   // safe fallback for first launch
        }
        return decoded
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
        let currentLanguageCode = sharedDefaults?.string(forKey: "currentLanguage") ?? "en"
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
        // Suppress rapid successive saves during language/stream switches.
        // CRITICAL FIX for first widget pause: explicit pauses (!isPlaying) must bypass
        // the 5s throttle. During cold launch + stream setup the throttle is constantly
        // active; the first widget pause save was dropped (second succeeded after window cleared).
        // Pauses are now treated as urgent so .userPaused always reaches widgets/Live Activities.
        if state.isPlaying,   // only throttle while actively playing / switching
           let lastUpdate = sharedDefaults?.double(forKey: "lastUpdateTime"),
           Date().timeIntervalSince1970 - lastUpdate < 5.0 {
            #if DEBUG
            print("🔇 Skipping rapid state save (stream switch in progress)")
            #endif
            return
        }
        
        sharedDefaults?.set(state.isPlaying, forKey: "isPlaying")
        sharedDefaults?.set(state.currentLanguage, forKey: "currentLanguage")
        sharedDefaults?.set(state.hasError, forKey: "hasError")
        sharedDefaults?.set(time.timeIntervalSince1970, forKey: "lastUpdateTime")
        
        // Clear instant feedback flags (still required for widget responsiveness)
        sharedDefaults?.removeObject(forKey: "isInstantFeedback")
        sharedDefaults?.removeObject(forKey: "instantFeedbackTime")
        sharedDefaults?.removeObject(forKey: "instantFeedbackLanguage")
        
        let isUrgentUpdate = !state.isPlaying || state.hasError
        
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
        let currentLanguage = sharedDefaults?.string(forKey: "currentLanguage") ?? "en"
        let hasError = sharedDefaults?.bool(forKey: "hasError") ?? false
        return (isPlaying, currentLanguage, hasError)
    }
}
