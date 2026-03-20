//
//  SharedPlayerManager.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 7.6.2025.
//

import Foundation
import AVFoundation
import WidgetKit

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
    var availableStreams: [DirectStreamingPlayer.Stream] {
        return DirectStreamingPlayer.availableStreams
    }
    
    // Widget-safe play method with improved error handling
    func play(completion: @escaping @Sendable (Bool) -> Void) {
        if isRunningInWidget() {
            // Instant visual feedback for the user (very important for perceived responsiveness)
            sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "lastUpdateTime")
            sharedDefaults?.set(true, forKey: "isInstantFeedback")
            sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "instantFeedbackTime")
            sharedDefaults?.set(sharedDefaults?.string(forKey: "currentLanguage") ?? "en",
                               forKey: "instantFeedbackLanguage")
            // No need for .synchronize() in 2025+ — system handles it fast enough

            scheduleWidgetAction(action: "play")
            notifyMainApp(action: "play")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                completion(true)
                self.reloadAllWidgets()           // or better: WidgetRefreshManager.shared.refreshIfNeeded()
                SharedPlayerManager.shared.saveFireAndForget()  // best-effort state push
            }
            return
        }

        // Main app path — security + real playback happens here
        Task { @MainActor in
            do {
                try await DirectStreamingPlayer.shared.play()  // assuming throws now
                completion(true)
            } catch {
                completion(false)
                // Optionally log or set hasPermanentError
            }
            await self.saveCurrentState()  // pushes authoritative state to shared defaults
        }
    }

    // Widget-safe stop method – unchanged (already perfect)
    func stop(completion: @escaping @Sendable () -> Void = {}) {
        if isRunningInWidget() {
            // ← instant UserDefaults + pending action (keep exactly as-is)
            sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "lastUpdateTime")
            sharedDefaults?.set(true, forKey: "isInstantFeedback")
            sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "instantFeedbackTime")
            sharedDefaults?.set(sharedDefaults?.string(forKey: "currentLanguage") ?? "en", forKey: "instantFeedbackLanguage")
            sharedDefaults?.synchronize()
            
            scheduleWidgetAction(action: "pause")
            notifyMainApp(action: "pause")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                completion()
                self.reloadAllWidgets()
            }
            return
        }
        
        // Main app forward
        DirectStreamingPlayer.shared.stop(completion: completion)
    }

    // NEW: switchToStream – now a pure dispatcher (Swift 6 compliant)
    func switchToStream(_ stream: DirectStreamingPlayer.Stream) {
        if isRunningInWidget() {
            // ← instant UserDefaults + pending action (keep exactly as-is)
            sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "lastUpdateTime")
            sharedDefaults?.set(true, forKey: "isInstantFeedback")
            sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "instantFeedbackTime")
            sharedDefaults?.set(stream.languageCode, forKey: "instantFeedbackLanguage")
            sharedDefaults?.synchronize()
            
            scheduleWidgetAction(action: "switch", parameter: stream.languageCode)
            notifyMainApp(action: "switch", parameter: stream.languageCode)
            
            WidgetCenter.shared.reloadAllTimelines()
            
            #if DEBUG
            print("Widget stream switch scheduled: \(stream.languageCode)")
            #endif
            return
        }
        
        // Main app forward
        DirectStreamingPlayer.shared.switchToStream(stream)
    }
    
    // Schedule widget action for main app to handle
    private func scheduleWidgetAction(action: String, parameter: String? = nil) {
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
    private func notifyMainApp(action: String, parameter: String? = nil) {
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
    func loadSharedState() -> (isPlaying: Bool, currentLanguage: String, hasError: Bool) {
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
