//
//  RadioLiveActivityManager.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 13.6.2025.
//
//  Privacy-first Live Activities - NO push notifications needed
//

import ActivityKit
import Foundation

/// - Article: Privacy-First Live Activities Integration
///
/// `RadioLiveActivityManager` manages iOS 26 Live Activities for playback status, using local-only updates (no push notifications or server calls) to maintain privacy.
///
/// Process:
/// 1. **Start/Update**: `startActivity()` creates activities with attributes like stream language/flag; `updateCurrentActivity()` refreshes every 10s via timer.
/// 2. **Lifecycle**: Auto-starts on background (`handleAppWillEnterBackground()`); ends on terminate; observes existing activities.
/// 3. **Integration**: Hooks into `DirectStreamingPlayer.swift` callbacks for status/metadata changes; shares state via `SharedPlayerManager.swift`.
/// 4. **Privacy Safeguards**: All data local; no external communication (see app-wide privacy in `DirectStreamingPlayer.swift`).
///
/// For app lifecycle ties, see extensions in `SceneDelegate.swift` and `AppDelegate.swift`. Widgets use separate sharing via `SharedPlayerManager.swift`.
@MainActor
class RadioLiveActivityManager: ObservableObject {
    static let shared = RadioLiveActivityManager()
    
    @Published var currentActivity: Activity<LutheranRadioLiveActivityAttributes>?
    private var updateTimer: Timer?
    
    private init() {
        observeExistingActivities()
    }
    
    // MARK: - Privacy-First Live Activity Management

    func startActivity() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            #if DEBUG
            print("🔴 Live Activities are not enabled by user")
            #endif
            return
        }
        
        endActivity()
        
        let manager = SharedPlayerManager.shared
        let state = manager.loadSharedState()
        let currentStream = manager.availableStreams.first(where: { $0.languageCode == state.currentLanguage }) ?? manager.availableStreams[0]
        
        let attributes = LutheranRadioLiveActivityAttributes(
            appName: "Lutheran Radio",
            startTime: Date()
        )
        
        // ✅ Safe actor access (now allowed because function is async)
        let visualState = await manager.currentVisualState
        
        let initialContentState = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: visualState,
            currentMetadata: nil,
            streamStatus: getStreamStatus(visualState: visualState, hasError: state.hasError),
            lastUpdated: Date(),
            currentStreamLanguage: currentStream.languageCode,
            currentStreamFlag: currentStream.flag
        )
        
        do {
            let activity = try Activity<LutheranRadioLiveActivityAttributes>.request(
                attributes: attributes,
                content: .init(state: initialContentState, staleDate: nil)
            )
            
            currentActivity = activity
            startLocalUpdateTimer()
            
            #if DEBUG
            print("🔴 Privacy-first Live Activity started: \(activity.id)")
            #endif
            
        } catch {
            #if DEBUG
            print("🔴 Failed to start Live Activity: \(error)")
            #endif
        }
    }

    // LOCAL UPDATES ONLY - No server communication
    @MainActor
    func updateCurrentActivity() async {
        guard let activity = currentActivity else { return }
        
        let manager = SharedPlayerManager.shared
        let state = manager.loadSharedState()
        let currentStream = manager.availableStreams.first(where: { $0.languageCode == state.currentLanguage }) ?? manager.availableStreams[0]
        
        // NEW: Use visualState (SSOT) + await
        let visualState = await manager.currentVisualState
        
        let updatedContentState = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: visualState,                                      // ← changed
            currentMetadata: nil,
            streamStatus: getStreamStatus(visualState: visualState, hasError: state.hasError),
            lastUpdated: Date(),
            currentStreamLanguage: currentStream.languageCode,
            currentStreamFlag: currentStream.flag
        )
        
        nonisolated(unsafe) let safeActivity = activity
        await safeActivity.update(.init(state: updatedContentState, staleDate: nil))
        
        #if DEBUG
        print("🔴 Live Activity updated locally: visualState=\(visualState)")
        #endif
    }

    func endActivity() {
        stopLocalUpdateTimer()
        
        guard let activity = currentActivity else { return }
        
        currentActivity = nil   // clear immediately while still on the calling context
        
        // Capture safely once (standard Live Activity pattern under Swift 6)
        nonisolated(unsafe) let safeActivityToEnd = activity
        
        Task {
            let manager = SharedPlayerManager.shared
            let state = manager.loadSharedState()
            let currentStream = manager.availableStreams.first(where: { $0.languageCode == state.currentLanguage }) ?? manager.availableStreams[0]
            
            let finalContentState = LutheranRadioLiveActivityAttributes.ContentState(
                visualState: .userPaused,                                  // ← changed (stopped = userPaused)
                currentMetadata: nil,
                streamStatus: "Stopped",
                lastUpdated: Date(),
                currentStreamLanguage: currentStream.languageCode,
                currentStreamFlag: currentStream.flag
            )
            
            // All async Live Activity work in one async context – modern SSOT pattern
            let content = ActivityContent(state: finalContentState, staleDate: nil)
            await safeActivityToEnd.update(content)
            await safeActivityToEnd.end(content, dismissalPolicy: .default)   // ← Fixed: now uses modern end(content:dismissalPolicy:)
            
            #if DEBUG
            print("🔴 Live Activity ended")
            #endif
        }
    }
    
    // MARK: - Local-Only Update Timer
    
    private func startLocalUpdateTimer() {
        stopLocalUpdateTimer()
        
        // Update every 10 seconds while app is running audio
        updateTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            Task {
                await self.updateCurrentActivity()
            }
        }
        
        #if DEBUG
        print("🔴 Started local update timer for Live Activity")
        #endif
    }
    
    private func stopLocalUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
        
        #if DEBUG
        print("🔴 Stopped local update timer")
        #endif
    }
    
    // MARK: - Privacy-Safe Helper Methods
    
    private func observeExistingActivities() {
        currentActivity = Activity< LutheranRadioLiveActivityAttributes>.activities.first
        
        if let activity = currentActivity {
            startLocalUpdateTimer() // Resume local updates if activity exists
            #if DEBUG
            print("🔴 Found existing Live Activity: \(activity.id)")
            #endif
        }
    }
    
    private func getStreamStatus(visualState: PlayerVisualState, hasError: Bool) -> String {
        if hasError {
            return String(localized: "Connection error", defaultValue: "Connection Error")
        } else if visualState == .thermalPaused {
            return String(localized: "status_thermal_paused", defaultValue: "Thermal pause")
        } else if visualState.isActivelyPlaying {
            return String(localized: "LIVE", defaultValue: "Live")
        } else {
            return String(localized: "Ready", defaultValue: "Ready")
        }
    }
}

// MARK: - App Lifecycle Integration (Privacy-Safe)

extension RadioLiveActivityManager {
    func handleAppWillEnterBackground() {
        // Auto-start Live Activity when backgrounding with audio
        let manager = SharedPlayerManager.shared
        let state = manager.loadSharedState()
        
        if state.isPlaying && currentActivity == nil {
            Task {   // ← wrap in Task because startActivity is now async
                await startActivity()
            }
        }
    }
    
    func handleAppDidEnterForeground() {
        // Update Live Activity with current state
        Task {
            await updateCurrentActivity()
        }
    }
    
    func handleAppWillTerminate() {
        // Clean shutdown - end Live Activity gracefully
        endActivity()
    }
}
