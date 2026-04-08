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
    
    // MARK: - Public API

    /// Public async entry point for playing — safe to call from anywhere
    public func play() async {
        #if DEBUG
        print("🚀 SharedPlayerManager.play() ENTERED – currentVisualState = \(currentVisualState)")
        #endif

        // SINGLE SOURCE OF TRUTH — this kills resurrection in ALL paths
        if !currentVisualState.shouldAutoPlayOrResume {
            #if DEBUG
            print("🛡️ Blocked play() – currentVisualState = \(currentVisualState) (resurrection prevented)")
            #endif
            return
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

        guard isValid else { return }

        if isRunningInWidget() {
            handleWidgetPlay()
            return
        }

        let stream = DirectStreamingPlayer.shared.selectedStream
        #if DEBUG
        print("🎵 Setting stream to: \(stream)")
        #endif

        await DirectStreamingPlayer.shared.setStream(to: stream)
        
        #if DEBUG
        print("💾 Saving current state after stream setup")
        #endif
        await saveCurrentState()
    }
    
    /// Public async entry point for stopping playback
    public func stop() async {
        if isRunningInWidget() {
            handleWidgetStop()
            return
        }
        
        // CRITICAL: Update visual state SYNCHRONOUSLY before any async work
        // This prevents the "play on pause" resurrection
        currentVisualState = .userPaused
        
        // Main app path
        DirectStreamingPlayer.shared.stop()
        DirectStreamingPlayer.shared.player?.replaceCurrentItem(with: nil)
        
        // Always save after stop
        await saveCurrentState()
        
        // Also persist the new visual state for widgets / Live Activities
        saveVisualState()
        
        notifyMainApp(action: "pause")
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
        
        scheduleWidgetAction(action: "play")
        notifyMainApp(action: "play")
        
        // Small delay + optimistic widget refresh
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            let optimisticState = WidgetState(
                isPlaying: true,
                currentLanguage: sharedDefaults?.string(forKey: "currentLanguage") ?? "en",
                hasError: false
            )
            await WidgetRefreshManager.shared.refreshIfNeeded(for: optimisticState, immediate: true)
            
            await saveFireAndForget()
        }
    }
    
    /// Called only after the player confirmed successful start of playback
    private func saveCurrentStateAfterSuccess() async {
        guard !isRunningInWidget() else { return }
        
        let player = DirectStreamingPlayer.shared
        let now = Date()
        
        let currentLanguageCode = sharedDefaults?.string(forKey: "currentLanguage") ?? "en"
        let hasPermanentError = await player.isLastErrorPermanent()
        
        let currentState = (
            isPlaying: true,                    // We KNOW it's playing now
            currentLanguage: currentLanguageCode,
            hasError: hasPermanentError
        )
        
        performActualSave(currentState, at: now)
        
        // Optional: extra notification for widgets/Live Activities
        notifyMainApp(action: "play")
    }
    
    // MARK: - PlayerVisualState Management

    /// Call this when the user explicitly taps Play.
    /// Clears the .userPaused intent so the guard in play() will allow playback.
    func setUserIntentToPlay() async {
        currentVisualState = .prePlay   // or .playing if you prefer
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
        await saveCurrentState()
    }
    
    // MARK: - PlayerVisualState Persistence

    private func saveVisualState() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(currentVisualState) {
            sharedDefaults?.set(data, forKey: "playerVisualState")
            sharedDefaults?.synchronize()   // Safe and cheap for widget/extension sync
        }
    }

    private func loadVisualState() -> PlayerVisualState {
        guard let data = sharedDefaults?.data(forKey: "playerVisualState"),
              let decoded = try? JSONDecoder().decode(PlayerVisualState.self, from: data) else {
            return .prePlay   // safe fallback
        }
        return decoded
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
        
        // Persist the full visual state so widget / Live Activity read the correct paused intent
        saveVisualState()
        
        scheduleWidgetAction(action: "pause")
        notifyMainApp(action: "pause")
        
        // Small delay + optimistic widget refresh using correct paused state
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            let optimisticState = WidgetState(
                isPlaying: false,                    // keep for backward compatibility for now
                currentLanguage: sharedDefaults?.string(forKey: "currentLanguage") ?? "en",
                hasError: false
            )
            await WidgetRefreshManager.shared.refreshIfNeeded(for: optimisticState, immediate: true)
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
        
        let player = DirectStreamingPlayer.shared  // ← use the singleton directly
        
        let now = Date()
        
        // Fetch current values from the real player (add these getters if missing!)
        let currentLanguageCode = sharedDefaults?.string(forKey: "currentLanguage") ?? "en"
        let isPermanentError     = await player.isLastErrorPermanent()
        let isPlaying            = player.actualPlaybackState     // assume this exists/returns Bool
        let hasPermanentError    = player.hasPermanentError
        
        let currentState = (
            isPlaying: isPlaying,
            currentLanguage: currentLanguageCode,
            hasError: hasPermanentError || isPermanentError
        )
        
        performActualSave(currentState, at: now)
    }
    
    nonisolated func saveFireAndForget() {
        Task {
            await saveCurrentState()
        }
    }
    
    private func performActualSave(_ state: (isPlaying: Bool, currentLanguage: String, hasError: Bool), at time: Date) {
        sharedDefaults?.set(state.isPlaying, forKey: "isPlaying")
        sharedDefaults?.set(state.currentLanguage, forKey: "currentLanguage")
        sharedDefaults?.set(state.hasError, forKey: "hasError")
        sharedDefaults?.set(time.timeIntervalSince1970, forKey: "lastUpdateTime")
        
        // Clear instant feedback flags (still required for widget responsiveness)
        sharedDefaults?.removeObject(forKey: "isInstantFeedback")
        sharedDefaults?.removeObject(forKey: "instantFeedbackTime")
        sharedDefaults?.removeObject(forKey: "instantFeedbackLanguage")
        
        let newWidgetState = WidgetState(
            isPlaying: state.isPlaying,
            currentLanguage: state.currentLanguage,
            hasError: state.hasError
        )
        
        let isUrgentUpdate = state.isPlaying || state.hasError
        
        // Always hop to MainActor for WidgetRefreshManager (required in Swift 6)
        Task { @MainActor in
            WidgetRefreshManager.shared.refreshIfNeeded(for: newWidgetState, immediate: isUrgentUpdate)
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
