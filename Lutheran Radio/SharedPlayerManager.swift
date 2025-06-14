//
//  SharedPlayerManager.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 7.6.2025.
//

import Foundation
import AVFoundation
import WidgetKit

class SharedPlayerManager {
    static let shared = SharedPlayerManager()
    
    // Use lazy initialization and check widget context
    private lazy var _player: DirectStreamingPlayer? = {
        // Never create player in widget context
        guard !isRunningInWidget() else {
            #if DEBUG
            print("🔗 Prevented DirectStreamingPlayer creation in widget context")
            #endif
            return nil
        }
        return DirectStreamingPlayer.shared
    }()
    
    private var player: DirectStreamingPlayer? {
        return _player
    }
    
    private init() {}
    
    // Widget-safe methods that won't crash
    var isPlaying: Bool {
        // Always read from UserDefaults for consistency
        let sharedState = loadSharedState()
        return sharedState.isPlaying
    }
    
    var currentStream: DirectStreamingPlayer.Stream {
        // Always reconstruct from UserDefaults
        let languageCode = sharedDefaults?.string(forKey: "currentLanguage") ?? "en"
        return availableStreams.first { $0.languageCode == languageCode } ?? availableStreams[0]
    }
    
    var availableStreams: [DirectStreamingPlayer.Stream] {
        return DirectStreamingPlayer.availableStreams
    }
    
    var hasError: Bool {
        // Always read from UserDefaults
        let sharedState = loadSharedState()
        return sharedState.hasError
    }
    
    // Widget-safe play method with improved error handling
    func play(completion: @escaping (Bool) -> Void) {
        if isRunningInWidget() {
            // For widgets, use App Group notification instead of direct scheduling
            scheduleWidgetAction(action: "play")
            notifyMainApp(action: "play")
            
            // Delay the completion and widget refresh to allow main app to process
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                completion(true)
                self.reloadAllWidgets()
            }
            return
        }
        
        // Main app context - use player directly
        guard let player = self.player else {
            completion(false)
            return
        }
        
        player.play(completion: completion)
    }
    
    // Widget-safe stop method with improved error handling
    func stop(completion: @escaping () -> Void = {}) {
        if isRunningInWidget() {
            scheduleWidgetAction(action: "pause")
            notifyMainApp(action: "pause")
            
            // Delay the completion and widget refresh to allow main app to process
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                completion()
                self.reloadAllWidgets()
            }
            return
        }
        
        // Main app context
        guard let player = self.player else {
            completion()
            return
        }
        
        player.stop(completion: completion)
    }
    
    // Simplified switch stream method for widgets
    func switchToStream(_ stream: DirectStreamingPlayer.Stream) {
        if isRunningInWidget() {
            scheduleWidgetAction(action: "switch", parameter: stream.languageCode)
            notifyMainApp(action: "switch", parameter: stream.languageCode)
            
            // Immediately update the cached state for instant UI feedback
            updateCachedStateForInstantFeedback(languageCode: stream.languageCode)
            
            // Then reload widgets and schedule a delayed reload for after main app processes
            reloadAllWidgets()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.reloadAllWidgets()
            }
            return
        }
        
        // Main app context
        guard let player = self.player else { return }
        
        player.stop { [weak self] in
            guard let self = self else { return }
            player.resetTransientErrors()
            player.setStream(to: stream)
            
            // Update state immediately
            self.saveCurrentState()
            
            // Only auto-play if not manually paused
            if !self.loadSharedState().isPlaying {
                return
            }
            
            player.play { success in
                #if DEBUG
                print("📱 Direct stream switch \(success ? "succeeded" : "failed") for \(stream.language)")
                #endif
                // Save state again after play attempt
                self.saveCurrentState()
            }
        }
    }
    
    // FIXED: Helper method to immediately update cached state for instant UI feedback
    private func updateCachedStateForInstantFeedback(languageCode: String) {
        sharedDefaults?.set(languageCode, forKey: "currentLanguage")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "lastUpdateTime")
        
        // FIXED: Set instant feedback flags
        sharedDefaults?.set(true, forKey: "isInstantFeedback")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "instantFeedbackTime")
        sharedDefaults?.set(languageCode, forKey: "instantFeedbackLanguage")
        
        sharedDefaults?.synchronize()
        
        // NEW: Immediate refresh for language switch
        let newState = WidgetState(
            isPlaying: loadSharedState().isPlaying,
            currentLanguage: languageCode,
            hasError: loadSharedState().hasError,
            isTransitioning: true
        )
        WidgetRefreshManager.shared.refreshIfNeeded(for: newState, immediate: true)
        
        #if DEBUG
        print("🔗 Updated cached state for instant UI feedback: \(languageCode)")
        #endif
    }
    
    // Check if running in widget context with additional checks
    private func isRunningInWidget() -> Bool {
        let bundlePath = Bundle.main.bundlePath
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        
        let isWidget = bundlePath.contains("PlugIns") ||
                      bundlePath.contains("SystemExtensions") ||
                      bundleId.contains("LutheranRadioWidget") ||
                      bundleId.hasSuffix(".LutheranRadioWidget")
        
        #if DEBUG
        if isWidget {
            print("🔗 Running in widget context: bundlePath=\(bundlePath), bundleId=\(bundleId)")
        }
        #endif
        
        return isWidget
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
        if let param = parameter {
            sharedDefaults.set(param, forKey: "pendingLanguage")
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
        CFNotificationCenterPostNotification(center, CFNotificationName(notificationName as CFString), nil, nil, false)
        
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
    private var sharedDefaults: UserDefaults? {
        return UserDefaults(suiteName: "group.radio.lutheran.shared")
    }
    
    // FIXED: Enhanced saveCurrentState to respect instant feedback
    func saveCurrentState() {
        // Only save if we're in the main app, not widget
        guard !isRunningInWidget() else { return }
        
        guard let player = self.player else {
            return
        }
        
        let isPlaying = player.isPlaying
        let currentLanguage = player.selectedStream.languageCode
        let hasError = player.hasPermanentError || player.isLastErrorPermanent()
        
        // FIXED: Check if instant feedback is active and for the same language
        if let instantFeedbackTime = sharedDefaults?.object(forKey: "instantFeedbackTime") as? Double,
           let instantFeedbackLanguage = sharedDefaults?.string(forKey: "instantFeedbackLanguage"),
           sharedDefaults?.bool(forKey: "isInstantFeedback") == true {
            
            let feedbackAge = Date().timeIntervalSince1970 - instantFeedbackTime
            
            // FIXED: Only override instant feedback if:
            // 1. It's older than 10 seconds, OR
            // 2. The main app has actually switched to the instant feedback language
            if feedbackAge < 10.0 && currentLanguage != instantFeedbackLanguage {
                #if DEBUG
                print("🔗 Preserving instant feedback: main app language=\(currentLanguage), instant feedback=\(instantFeedbackLanguage), age=\(feedbackAge)s")
                #endif
                // Don't save state yet - preserve instant feedback
                return
            }
            
            #if DEBUG
            print("🔗 Main app caught up to instant feedback: \(currentLanguage)")
            #endif
        }
        
        sharedDefaults?.set(isPlaying, forKey: "isPlaying")
        sharedDefaults?.set(currentLanguage, forKey: "currentLanguage")
        sharedDefaults?.set(hasError, forKey: "hasError")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "lastUpdateTime")
        
        // Clear instant feedback flags since we now have real state
        sharedDefaults?.removeObject(forKey: "isInstantFeedback")
        sharedDefaults?.removeObject(forKey: "instantFeedbackTime")
        sharedDefaults?.removeObject(forKey: "instantFeedbackLanguage")
        
        // NEW: Use optimized refresh manager
        let newState = WidgetState(
            isPlaying: isPlaying,
            currentLanguage: currentLanguage,
            hasError: hasError
        )
        WidgetRefreshManager.shared.refreshIfNeeded(for: newState)
        
        #if DEBUG
        print("🔗 Saved state: playing=\(isPlaying), language=\(currentLanguage), error=\(hasError) [cleared instant feedback]")
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
