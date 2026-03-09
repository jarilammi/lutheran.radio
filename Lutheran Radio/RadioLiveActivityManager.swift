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

    func startActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            #if DEBUG
            print("🔴 Live Activities are not enabled by user")
            #endif
            return
        }
        
        // End existing activity if one exists
        endActivity()
        
        let manager = SharedPlayerManager.shared
        let state = manager.loadSharedState()
        let currentStream = manager.availableStreams.first(where: { $0.languageCode == state.currentLanguage }) ?? manager.availableStreams[0]
        
        let attributes = LutheranRadioLiveActivityAttributes(
            appName: "Lutheran Radio",
            startTime: Date()
        )
        
        let initialContentState = LutheranRadioLiveActivityAttributes.ContentState(
            isPlaying: state.isPlaying,
            currentMetadata: getCurrentMetadata(),
            streamStatus: getStreamStatus(isPlaying: state.isPlaying, hasError: state.hasError),
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
    func updateCurrentActivity() async {
        guard let activity = currentActivity else { return }
        
        let manager = SharedPlayerManager.shared
        let state = manager.loadSharedState()
        let currentStream = manager.availableStreams.first(where: { $0.languageCode == state.currentLanguage }) ?? manager.availableStreams[0]
        
        let updatedContentState = LutheranRadioLiveActivityAttributes.ContentState(
            isPlaying: state.isPlaying,
            currentMetadata: getCurrentMetadata(),
            streamStatus: getStreamStatus(isPlaying: state.isPlaying, hasError: state.hasError),
            lastUpdated: Date(),
            currentStreamLanguage: currentStream.languageCode,
            currentStreamFlag: currentStream.flag
        )
        
        await activity.update(.init(state: updatedContentState, staleDate: nil))
        
        #if DEBUG
        print("🔴 Live Activity updated locally: playing=\(state.isPlaying)")
        #endif
    }

    func endActivity() {
        stopLocalUpdateTimer()
        
        guard let activity = currentActivity else { return }
        
        // Fixed: Make the Task @Sendable compliant
        let activityToEnd = activity
        currentActivity = nil
        
        Task { @MainActor in
            let manager = SharedPlayerManager.shared
            let state = manager.loadSharedState()
            let currentStream = manager.availableStreams.first(where: { $0.languageCode == state.currentLanguage }) ?? manager.availableStreams[0]
            
            let finalContentState = LutheranRadioLiveActivityAttributes.ContentState(
                isPlaying: false,
                currentMetadata: nil,
                streamStatus: "Stopped",
                lastUpdated: Date(),
                currentStreamLanguage: currentStream.languageCode,
                currentStreamFlag: currentStream.flag
            )
            
            await activityToEnd.end(.init(state: finalContentState, staleDate: nil), dismissalPolicy: .default)
            
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
    
    private func getCurrentMetadata() -> String? {
        // Get metadata from local player only - no external calls
        if let metadata = getLocalMetadata(), !metadata.isEmpty {
            return metadata
        }
        return nil
    }
    
    private func getLocalMetadata() -> String? {
        // Temporarily return nil until we add metadata support
        return nil
    }
    
    private func getStreamStatus(isPlaying: Bool, hasError: Bool) -> String {
        if hasError {
            return "Connection Error"
        } else if isPlaying {
            return "Live"
        } else {
            return "Ready"
        }
    }
}

// MARK: - Enhanced Privacy Integration

extension DirectStreamingPlayer {
    func setupPrivacyFirstLiveActivity() {
        // Store original callbacks
        let originalOnStatusChange = onStatusChange
        let originalOnMetadataChange = onMetadataChange
        
        // Enhanced status change with Live Activity updates
        onStatusChange = { isPlaying, statusText in
            // Call original callback first
            originalOnStatusChange?(isPlaying, statusText)
            
            // Update Live Activity locally only
            Task {
                await RadioLiveActivityManager.shared.updateCurrentActivity()
            }
        }
        
        // Enhanced metadata change with Live Activity updates
        onMetadataChange = { metadata in  // ← No [weak self] capture since we don't use self
            // Call original callback
            originalOnMetadataChange?(metadata)
            
            // Update Live Activity with new metadata locally
            Task {
                await RadioLiveActivityManager.shared.updateCurrentActivity()
            }
        }
        
        #if DEBUG
        print("🔴 Privacy-first Live Activity integration setup complete")
        #endif
    }
}

// MARK: - App Lifecycle Integration (Privacy-Safe)

extension RadioLiveActivityManager {
    func handleAppWillEnterBackground() {
        // Auto-start Live Activity when backgrounding with audio
        let manager = SharedPlayerManager.shared
        let state = manager.loadSharedState()
        
        if state.isPlaying && currentActivity == nil {
            startActivity()
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
