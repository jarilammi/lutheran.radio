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
    
    private var lastSavedState: (isPlaying: Bool, currentLanguage: String, hasError: Bool)?
    private var lastSaveTime: Date?
    private let minSaveInterval: TimeInterval = 1.0
    
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
        guard !isRunningInWidget() else { return }
        guard let player = self.player else { return }
        
        let now = Date()
        
        // FIXED: Use the correct public properties from DirectStreamingPlayer
        let playerRate = player.currentPlayerRate
        let itemStatus = player.currentItemStatus
        let hasCurrentItem = player.hasPlayerItem
        
        // More comprehensive playing detection using the actualPlaybackState property
        let actuallyPlaying = player.actualPlaybackState
        
        let currentState = (
            isPlaying: actuallyPlaying,
            currentLanguage: player.selectedStream.languageCode,
            hasError: player.hasPermanentError || player.isLastErrorPermanent()
        )
        
        #if DEBUG
        print("🔗 Detailed state: rate=\(playerRate), itemStatus=\(itemStatus.rawValue), hasItem=\(hasCurrentItem), result=\(actuallyPlaying)")
        #endif
        
        // FIXED: Only throttle rapid identical saves, not state changes
        if let lastState = lastSavedState,
           lastState.isPlaying == currentState.isPlaying,
           lastState.currentLanguage == currentState.currentLanguage,
           lastState.hasError == currentState.hasError {
            
            // Only throttle if trying to save identical state rapidly
            if let lastSave = lastSaveTime,
               now.timeIntervalSince(lastSave) < 1.0 {
                #if DEBUG
                print("🔗 Throttling identical state save")
                #endif
                return
            }
        }
        
        // Always save state changes immediately
        performActualSave(currentState, at: now)
    }

    private func performActualSave(_ state: (isPlaying: Bool, currentLanguage: String, hasError: Bool), at time: Date) {
        sharedDefaults?.set(state.isPlaying, forKey: "isPlaying")
        sharedDefaults?.set(state.currentLanguage, forKey: "currentLanguage")
        sharedDefaults?.set(state.hasError, forKey: "hasError")
        sharedDefaults?.set(time.timeIntervalSince1970, forKey: "lastUpdateTime")
        
        // Clear instant feedback flags when saving real state
        sharedDefaults?.removeObject(forKey: "isInstantFeedback")
        sharedDefaults?.removeObject(forKey: "instantFeedbackTime")
        sharedDefaults?.removeObject(forKey: "instantFeedbackLanguage")
        
        // Update widget immediately
        let newWidgetState = WidgetState(
            isPlaying: state.isPlaying,
            currentLanguage: state.currentLanguage,
            hasError: state.hasError
        )
        WidgetRefreshManager.shared.refreshIfNeeded(for: newWidgetState)
        
        lastSavedState = state
        lastSaveTime = time
        
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
