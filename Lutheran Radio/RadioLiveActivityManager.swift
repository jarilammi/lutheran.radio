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
import UIKit   // For UIApplication.willTerminateNotification (termination observer) and related lifecycle.

/// - Article: Privacy-First Live Activities Integration
///
/// `RadioLiveActivityManager` manages iOS 26+ Live Activities (Dynamic Island + Lock Screen)
/// for playback status using **local-only** `ActivityKit` updates. No push notifications,
/// no server involvement — privacy is preserved exactly like the home widgets.
///
/// ## Single Source of Truth Contract
/// - All content comes from `SharedPlayerManager.currentVisualState` (the `PlayerVisualState` SSOT)
///   + `currentStreamMetadata` / persisted snapshot.
/// - `RadioLiveActivityManager` **owns** the `Activity` instance lifecycle and its 10 s local
///   heartbeat timer.
/// - The **main app** (via `SharedPlayerManager` save paths + `RadioPlayerCoordinator`) drives
///   updates and starts. Widget/App Intent processes only mutate SPM; the main process pushes
///   to the Activity.
///
/// ## Heartbeat & Why It Was Previously Unreliable
/// The internal `updateTimer` (10 s) + `updateCurrentActivity()` keep the LA in sync while
/// the app is alive. Before the changes in this edit, it was only started from now-dead
/// `handleAppWillEnterBackground` paths and only pushed on ICY metadata. Resume (`.playing`)
/// could therefore lag or never appear in LA buttons. Now explicitly driven from SPM
/// visual transitions (setPlaying/stop) + every `performActualSave` + lifecycle delegates.
///
/// See:
/// - `SharedPlayerManager.setPlaying()`, `stop()`, `performActualSave()`
/// - `SceneDelegate` + `AppDelegate` (the wired handlers)
/// - `PlayerVisualState`
/// - `WidgetRefreshManager` (the parallel mechanism for home/Control widgets)
///
/// - SeeAlso: `SharedPlayerManager`, `PlayerVisualState.swift`, `LutheranRadioLiveActivityAttributes.swift`,
///   `CODING_AGENT.md` (Single Source of Truth Principles + Cross-target shared files),
///   <doc:Architecture>, RadioPlayerCoordinator (orchestration after SPM).
@MainActor
class RadioLiveActivityManager: ObservableObject {
    static let shared = RadioLiveActivityManager()
    
    @Published var currentActivity: Activity<LutheranRadioLiveActivityAttributes>?

    /// The 10 s repeating local heartbeat timer for an active Live Activity.
    ///
    /// - Important: This is intentionally `internal private(set)` as the
    ///   designated testing seam (see `startLocalUpdateTimer` / `stopLocalUpdateTimer`).
    ///   Tests use `@testable` to observe timer creation, validity, and cleanup
    ///   directly. Production code must never read or write this directly.
    ///
    /// - Note: The timer is a backup to explicit updates driven by
    ///   `SharedPlayerManager`. It only runs while `currentActivity != nil`.
    /// - SeeAlso: ``RadioLiveActivityManager/startLocalUpdateTimer()``,
    ///   ``RadioLiveActivityManager/stopLocalUpdateTimer()``,
    ///   RadioLiveActivityManagerTests
    internal private(set) var updateTimer: Timer?
    
    private init() {
        // Observe first so any "resume from existing LA" path is exercised (or short-circuited in tests).
        // The early return in observeExistingActivities() is what keeps test init time near-zero.
        // - SeeAlso: ``observeExistingActivities()``
        observeExistingActivities()

        // Defense-in-depth: also listen for willTerminate so we end the LA even if
        // AppDelegate.applicationWillTerminate is not delivered (common on abrupt kills).
        // The observer just forwards to the existing handle/end path.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillTerminateNotification),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }

    @objc private func handleWillTerminateNotification() {
        handleAppWillTerminate()
    }
    
    // MARK: - Privacy-First Live Activity Management

    /// Requests a new privacy-first Live Activity (or replaces an existing one).
    ///
    /// - Postcondition: If successful, `currentActivity` is non-nil and the 10 s local
    ///   update timer is running. Initial content uses the current `PlayerVisualState` SSOT.
    /// - Important: Only call from main-app code (never widget extension). The caller is
    ///   responsible for ensuring we are allowed to show an activity (usually right after
    ///   a `.playing` transition).
    /// - SeeAlso: `updateCurrentActivity()`, `SharedPlayerManager.setPlaying`
    func startActivity() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            #if DEBUG
            print("🔴 Live Activities are not enabled by user")
            #endif
            return
        }
        
        endActivity()
        
        let manager = SharedPlayerManager.shared
        
        let attributes = LutheranRadioLiveActivityAttributes(
            appName: "Lutheran Radio",
            startTime: Date()
        )
        
        // Safe actor access (now allowed because function is async)
        let visualState = await manager.currentVisualState
        let streamMetadata = await manager.currentStreamMetadata
            ?? SharedPlayerManager.loadPersistedStreamMetadata()
        
        let initialContentState = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: visualState,
            streamMetadata: streamMetadata
        )
        
        do {
            let activity = try Activity<LutheranRadioLiveActivityAttributes>.request(
                attributes: attributes,
                content: .init(state: initialContentState, staleDate: nil)
            )
            
            currentActivity = activity
            startLocalUpdateTimer()

            // Push an immediate update (the timer will keep it fresh every 10 s thereafter).
            // This gives the caller (e.g. setPlaying) instantaneous visual + button state
            // instead of waiting for the first timer tick.
            await updateCurrentActivity()
            
            #if DEBUG
            print("🔴 Privacy-first Live Activity started: \(activity.id)")
            #endif
            
        } catch {
            #if DEBUG
            print("🔴 Failed to start Live Activity: \(error)")
            #endif
        }
    }

    /// Pushes the latest `PlayerVisualState` + metadata from the SSOT into the active
    /// Live Activity.
    ///
    /// - Precondition: Must be called on the main actor (the method is `@MainActor`).
    /// - Note: Silently no-ops if no activity is currently active. This is the method
    ///   called by `SharedPlayerManager` on every visual state transition and save.
    /// - Important: Uses `nonisolated(unsafe)` + `unsafe` because `Activity.update` is
    ///   not Sendable in the current SDK; the capture of the Activity is done only after
    ///   we hold a strong local reference on the main actor.
    ///
    /// - SeeAlso: `startActivity()`, `SharedPlayerManager.performActualSave`
    @MainActor
    func updateCurrentActivity() async {
        guard let activity = currentActivity else { return }
        
        let manager = SharedPlayerManager.shared
        
        // Use visualState (SSOT) + await
        let visualState = await manager.currentVisualState
        let streamMetadata = await manager.currentStreamMetadata
            ?? SharedPlayerManager.loadPersistedStreamMetadata()
        
        let updatedContentState = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: visualState,
            streamMetadata: streamMetadata
        )
        
        nonisolated(unsafe) let safeActivity = activity
        unsafe await safeActivity.update(.init(state: updatedContentState, staleDate: nil))
        
        #if DEBUG
        print("🔴 Live Activity updated locally: visualState=\(visualState)")
        #endif
    }

    /// Ends the current Live Activity (if any) and stops the local heartbeat timer.
    ///
    /// The final pushed state is `.userPaused` (with no metadata) so that any transient
    /// UI the system shows during dismissal does not claim the stream is still live.
    /// Then `end(..., dismissalPolicy: .default)` is used so the LA is removed from the
    /// Lock Screen / Dynamic Island after the normal system grace period.
    ///
    /// - Note: Called on privacy clear (`clearAllLocalState`), on `applicationWillTerminate`,
    ///   and on `willTerminateNotification`. Does **not** automatically end on user pause
    ///   (a paused LA with a working play button is intentional for quick resume).
    ///
    /// - SeeAlso: `SharedPlayerManager.clearAllLocalState`, AppDelegate.applicationWillTerminate
    func endActivity() {
        stopLocalUpdateTimer()
        
        guard let activity = currentActivity else { return }
        
        currentActivity = nil   // clear immediately while still on the calling context
        
        // Capture safely once (standard Live Activity pattern under Swift 6)
        nonisolated(unsafe) let safeActivityToEnd = activity
        
        Task {
            let finalContentState = LutheranRadioLiveActivityAttributes.ContentState(
                visualState: .userPaused,
                streamMetadata: nil
            )
            
            // All async Live Activity work in one async context – modern SSOT pattern
            let content = ActivityContent(state: finalContentState, staleDate: nil)
            unsafe await safeActivityToEnd.update(content)
            unsafe await safeActivityToEnd.end(content, dismissalPolicy: .default)   // modern end API
            
            #if DEBUG
            print("🔴 Live Activity ended")
            #endif
        }
    }
    
    // MARK: - Local-Only Update Timer (the "heartbeat")
    
    /// Starts (or restarts) the 10 s repeating timer that keeps the Live Activity
    /// content fresh while the main app process is alive.
    ///
    /// The timer is the backup "heartbeat"; authoritative immediate updates are driven
    /// by `SharedPlayerManager` on visual state changes. Timer uses `Task` to hop to
    /// the @MainActor update method.
    ///
    /// - Important: Exposed as `internal` (together with `updateTimer` and
    ///   `stopLocalUpdateTimer`) as the designated white-box testing seam.
    ///   See ``RadioLiveActivityManager/updateTimer`` and RadioLiveActivityManagerTests.
    internal func startLocalUpdateTimer() {
        stopLocalUpdateTimer()
        
        // Update every 10 seconds while app is running audio.
        // This interval keeps program metadata and visual state (play/pause) reasonably
        // fresh without excessive battery impact. The 10 s value is intentionally coarser
        // than widget debouncing because Activity updates are more expensive.
        updateTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            Task { @MainActor in
                await self.updateCurrentActivity()
            }
        }
        
        #if DEBUG
        print("🔴 Started local update timer for Live Activity")
        #endif
    }
    
    /// Stops and clears the local update timer (if any).
    ///
    /// Called from `endActivity()`, lifecycle handlers, and tests.
    /// Must be paired with every `startLocalUpdateTimer()` to avoid leaking
    /// repeating timers into the test host or the app.
    internal func stopLocalUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
        
        #if DEBUG
        print("🔴 Stopped local update timer")
        #endif
    }
    
    // MARK: - Privacy-Safe Helper Methods
    
    /// Queries for a pre-existing Live Activity at singleton creation time so that
    /// local heartbeat timer can be resumed (e.g. after a background/foreground cycle).
    ///
    /// - Important: In DEBUG builds this performs a **robust test-environment short-circuit**.
    ///   A real `Activity<...>.activities.first` lookup is a synchronous daemon IPC that
    ///   becomes extremely slow under LLDB when any Live Activity is present in the
    ///   simulator (e.g. the app was streaming). The guard prevents that cost during
    ///   unit tests and guarantees `currentActivity` starts as `nil`.
    ///
    /// - Note: The three-way detection is required because `XCTestConfigurationFilePath`
    ///   is reliable under `xcodebuild` but often absent from Xcode GUI test runs
    ///   (Product → Test / test navigator). `NSClassFromString("XCTestCase")` matches the
    ///   detection pattern used in `DirectStreamingPlayer`.
    ///
    /// - SeeAlso: ``RadioLiveActivityManager/init()``, RadioLiveActivityManagerTests.setUp,
    ///   ``startLocalUpdateTimer()``, <doc:Architecture>
    private func observeExistingActivities() {
        #if DEBUG
        // Robust test detection (works in Xcode GUI + xcodebuild + attached LLDB).
        // We short-circuit *before* the synchronous ActivityKit daemon query.
        // See the /// discussion above for why the single-env-var check was insufficient.
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                          || NSClassFromString("XCTestCase") != nil
                          || ProcessInfo.processInfo.processName == "xctest"
                          || ProcessInfo.processInfo.processName.contains("xctest")

        if isRunningTests {
            currentActivity = nil
            return
        }
        #endif

        currentActivity = Activity<LutheranRadioLiveActivityAttributes>.activities.first

        if let activity = currentActivity {
            startLocalUpdateTimer() // Resume local updates if activity exists
            #if DEBUG
            print("🔴 Found existing Live Activity: \(activity.id)")
            #endif
        }
    }
}

// MARK: - App Lifecycle Integration (Privacy-Safe)

extension RadioLiveActivityManager {
    /// Called by SceneDelegate / AppDelegate when the scene enters background.
    ///
    /// Starts a Live Activity (if we are actively playing and none exists) so that
    /// the user has lock-screen / Dynamic Island controls while audio continues in
    /// the background.
    ///
    /// - SeeAlso: SceneDelegate.sceneDidEnterBackground
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
    
    /// Called on foreground transitions.
    ///
    /// Immediately pushes the current SSOT visual state so that any stale LA content
    /// (e.g. after a long background period) is corrected before the user sees it.
    func handleAppDidEnterForeground() {
        Task { @MainActor in
            await updateCurrentActivity()
        }
    }
    
    /// Called on process termination paths (AppDelegate + willTerminateNotification).
    ///
    /// Ends the activity so a stale "playing with buttons" preview does not remain
    /// on the lock screen after the app has been killed. Uses .default dismissal.
    func handleAppWillTerminate() {
        // Clean shutdown - end Live Activity gracefully
        endActivity()
    }
}
