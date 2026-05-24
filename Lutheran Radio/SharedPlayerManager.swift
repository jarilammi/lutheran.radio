//
//  SharedPlayerManager.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 7.6.2025.
//

import Foundation
import AVFoundation
import WidgetKit
import Core

/// - Article: Shared State Management for Widgets and Extensions
///
/// `SharedPlayerManager` is a **pure dispatcher** that enables safe state sharing
/// between the main app, widgets, and Live Activities via App Groups + `UserDefaults`.
///
/// **Single source of truth**: All state mutations (`isPlaying`, `selectedStream`,
/// `hasPermanentError`, `validationState`, etc.) now live **exclusively** in
/// `DirectStreamingPlayer`. `SharedPlayerManager` never mutates state itself — it
/// only forwards calls and persists the authoritative state via
/// `DirectStreamingPlayer.saveCurrentState()` + `UserDefaults` (suite
/// `group.radio.lutheran.shared`).
///
/// Core Functions:
/// - **State Persistence**: delegated entirely to `DirectStreamingPlayer`
/// - **Widget Actions**: play/stop/switch via URL schemes (handled in `SceneDelegate`)
///   with instant-feedback `UserDefaults` for responsive widget UI
/// - **Refresh**: `WidgetRefreshManager` (no direct `WidgetCenter` calls)
/// - **Privacy**: only anonymous data; no timestamps, no history, no PII
///
/// Usage:
/// - Main app: `SharedPlayerManager.shared.play { … }`
/// - Widgets / Live Activities: `SharedPlayerManager.shared.loadSharedState()`
///   (no player is ever instantiated)
///
/// See also: `DirectStreamingPlayer` (single source of truth) and
/// `RadioLiveActivityManager.swift`.
actor SharedPlayerManager {
    static let shared = SharedPlayerManager()
    
    // Add initialization tracking
    private let appLaunchTime = Date()
    private let initializationSettlingPeriod: TimeInterval = 5.0
    private var initialPlaybackHasRun = false
    
    nonisolated func isRunningInWidget() -> Bool {
        // Example common implementations – use yours
        #if DEBUG
        if Bundle.main.bundleIdentifier?.hasSuffix(".widget") == true {
            print("Running in widget (bundle ID suffix)")
        }
        #endif
        return Bundle.main.bundleIdentifier?.hasSuffix(".widget") == true ||
        ProcessInfo.processInfo.environment["WidgetKit"] != nil  // or your exact check
    }
    
    // NEW: Make sharedDefaults easily accessible (nonisolated since it's read-only & safe)
    nonisolated private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: "group.radio.lutheran.shared")
    }
    
    private init() {
    }
    
    // Widget-safe methods that won't crash
    nonisolated var availableStreams: [DirectStreamingPlayer.Stream] {
        return DirectStreamingPlayer.availableStreams
    }
    
    // Single source of truth for playback intent (UI + widget + Live Activity)
    // This prevents the "play on pause" resurrection bug when set synchronously to .userPaused
    var currentVisualState: PlayerVisualState = .prePlay
    
    /// Safe, single entry point to change the visual state from anywhere.
    /// (Notification handlers, MainActor, background tasks, etc.)
    func setVisualState(_ state: PlayerVisualState) async {
        self.currentVisualState = state
        // Any existing didSet / observers / widget / Live Activity updates
        // that you already have will still run here.
    }
    
    // MARK: - Public API

    /// Public async entry point for playing — safe to call from anywhere
    func play() async {
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
        
        // CENTRAL RESURRECTION PROTECTION — but relaxed during cold launch
        if !isInColdLaunchWindow {
            guard currentVisualState.shouldAutoPlayOrResume else {
                #if DEBUG
                print("🔒 [SharedPlayerManager] play() BLOCKED — currentVisualState = \(currentVisualState) (userPaused or error lock active)")
                #endif
                return
            }
        } else {
            #if DEBUG
            print("🚀 Cold-launch window active – bypassing normal resurrection protection")
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
    
    func setSecurityLocked() async {
        self.currentVisualState = .securityLocked
        await self.saveCurrentState()
        
        #if DEBUG
        print("✅ Security lock applied from server 403 response")
        #endif
    }
    
    // MARK: - Resurrection (still respects SSOT)

    /// Safe resurrection entry point used by DirectStreamingPlayer recovery logic.
    /// Allows technical recovery (hiccups) even when visualState = .playing.
    func attemptResurrectionIfAllowed() async {
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
    
    // MARK: - User Intent State Management
    
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
    
    // MARK: - Explicit User Play
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
        #if DEBUG
        print("🔒 markAsUserPaused() called – forcing .userPaused to block resurrection")
        #endif
        
        // We are inside the actor, so mutation is allowed
        currentVisualState = .userPaused
        
        // Persist the locked state (use whatever your real method is called)
        await saveCurrentState()          // ← change name if yours is different (e.g. saveState(), persistState())
        
        // Update UI / nowPlaying / widget
        // await updateNowPlayingInfo()
        
        #if DEBUG
        print("✅ Visual state locked to .userPaused")
        #endif
    }
    
    // MARK: - Widget-specific helpers

    /// Clears the userPaused resurrection lock when a widget explicitly requests Play.
    /// Called from handleWidgetPlayAction() so the widget can always start playback.
    public func clearUserPausedLockIfNeeded() async {
        if currentVisualState == .userPaused {
            #if DEBUG
            print("🔗 [Widget] Cleared userPaused lock for widget play action")
            #endif
            currentVisualState = .prePlay
        }
    }
    
    /// Public async entry point for stopping playback
    public func stop() async {
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
        
        // Note: saveVisualState() already called early above — no need to duplicate
        
        notifyMainApp(action: "pause")
        
        #if DEBUG
        print("🛑 stop() completed – visualState locked to .userPaused")
        #endif
    }

    // MARK: - Private Helpers for play()

    private func validatePlaybackRequest() async -> Bool {
        // TODO: Put your actual validation logic here (subscription check, network, etc.)
        // For now we allow everything — replace this when you have a validator
        return true
    }

    private func handleWidgetPlay() {
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
    
    // MARK: - Tuning Sound Handling

    /// Waits for the special tuning sound to finish before starting main radio playback.
    /// This eliminates the session / timing conflict that was preventing the stream from starting.
    private func waitForTuningSoundIfActive() async {
        // TODO: Replace this simple delay with a proper notification/flag when you have time.
        // For now, this fixed delay works very reliably on cold launch.
        #if DEBUG
        print("⏳ Waiting for tuning sound to finish before main playback...")
        #endif
        
        try? await Task.sleep(for: .milliseconds(1200))
        
        #if DEBUG
        print("✅ Tuning sound wait completed")
        #endif
    }
    
    // MARK: - PlayerVisualState Management
    
    /// Called only when the user taps the play button (or widget play action).
    /// Clears the .userPaused lock so resume is allowed.
    /// Resets the cold-launch guard ONLY for manual resumes.
    func setUserIntentToPlay() async {
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
        currentVisualState = .userPaused
        saveVisualState()
        await saveCurrentState()
    }
    
    /// Sets the visual state to .playing and persists it.
    /// Call after successful playback start/resume.
    func setPlaying() async {
        currentVisualState = .playing
        saveVisualState()
        await saveCurrentState()
    }
    
    // MARK: - PlayerVisualState Persistence & Restoration

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

    /// Safe restoration – ALWAYS respects .userPaused and blocks resurrection.
    /// Call this on:
    /// - App/scene foreground
    /// - AVAudioSession interruption .shouldResume
    /// - Widget timeline reload
    /// - Any other system resume signal
    func restoreVisualStateRespectingUserIntent() async {
        let loaded = loadVisualState()
        
        // This is the key line that finally stops the bug
        currentVisualState = PlayerVisualState.suppressResurrectionIfNeeded(currentState: loaded)
        
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
    
    // MARK: - Private Helpers for stop()

    private func handleWidgetStop() {
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
    
    // MARK: - Stream Switching

    nonisolated func switchToStream(_ stream: DirectStreamingPlayer.Stream) async {
        if isRunningInWidget() {
            // Widget path must stay nonisolated and synchronous/fast
            handleWidgetSwitch(to: stream)
            return
        }
        
        // Main app path
        await DirectStreamingPlayer.shared.switchToStream(stream)
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
        
        WidgetCenter.shared.reloadAllTimelines()
        
        #if DEBUG
        print("🔗 Widget stream switch scheduled: \(stream.languageCode)")
        #endif
    }
    
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
    
    private func reloadAllWidgets() {
        // DEPRECATED: Use WidgetRefreshManager.shared.refreshIfNeeded() instead
        #if DEBUG
        print("🔗 DEPRECATED: Direct widget reload called - use WidgetRefreshManager instead")
        #endif
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
        let isPlaying           = player.actualPlaybackState
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
        // Suppress rapid successive saves during language/stream switches
        if let lastUpdate = sharedDefaults?.double(forKey: "lastUpdateTime"),
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
        
        let isUrgentUpdate = state.isPlaying || state.hasError
        
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
    
    // Get pending actions safely
    func getPendingAction() -> (action: String, parameter: String?, actionId: String)? {
        guard let action = sharedDefaults?.string(forKey: "pendingAction"),
              let actionId = sharedDefaults?.string(forKey: "pendingActionId") else {
            return nil
        }
        
        let parameter = sharedDefaults?.string(forKey: "pendingLanguage")
        return (action, parameter, actionId)
    }
    
    // Clear processed actions
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
}
