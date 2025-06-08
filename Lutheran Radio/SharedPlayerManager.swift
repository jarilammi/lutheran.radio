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
            completion(true)
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
            completion()
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
            return
        }
        
        // Main app context
        guard let player = self.player else { return }
        
        player.stop { [weak self] in
            guard let self = self else { return }
            player.resetTransientErrors()
            player.setStream(to: stream)
            
            // Only auto-play if not manually paused
            if !self.loadSharedState().isPlaying {
                return
            }
            
            player.play { success in
                #if DEBUG
                print("📱 Direct stream switch \(success ? "succeeded" : "failed") for \(stream.language)")
                #endif
            }
        }
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
}

// MARK: - UserDefaults Communication
extension SharedPlayerManager {
    private var sharedDefaults: UserDefaults? {
        return UserDefaults(suiteName: "group.radio.lutheran.shared")
    }
    
    func saveCurrentState() {
        // Only save if we're in the main app, not widget
        guard !isRunningInWidget() else { return }
        
        guard let player = self.player else {
            // Fallback to current known state
            return
        }
        
        let isPlaying = player.isPlaying
        let currentLanguage = player.selectedStream.languageCode
        let hasError = player.hasPermanentError || player.isLastErrorPermanent()
        
        sharedDefaults?.set(isPlaying, forKey: "isPlaying")
        sharedDefaults?.set(currentLanguage, forKey: "currentLanguage")
        sharedDefaults?.set(hasError, forKey: "hasError")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "lastUpdateTime")
        
        // Force widget refresh immediately
        WidgetCenter.shared.reloadTimelines(ofKind: "LutheranRadioWidget")
        
        #if DEBUG
        print("🔗 Saved state: playing=\(isPlaying), language=\(currentLanguage), error=\(hasError)")
        print("🔗 Triggered widget timeline reload")
        #endif
    }
    
    func loadSharedState() -> (isPlaying: Bool, currentLanguage: String, hasError: Bool) {
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
