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
/// - All **widget and relaunch** content is driven exclusively by `PersistedWidgetState`
///   (via `loadPersistedWidgetState` / `persistWidgetSnapshot` / `performActualSave`).
///   `PersistedWidgetState` is the undisputed SSOT for home widgets, Control widgets,
///   and app background/terminate restore. **Live Activity updates must never bypass or
///   weaken these writes.**
/// - Live Activity presentation is derived from the in-memory `SharedPlayerManager.currentVisualState`
///   + `currentStreamMetadata` (the transient path). When the main app is alive these are
///   authoritative and do not require a disk round-trip for the LA surface.
/// - `RadioLiveActivityManager` **owns** the `Activity` instance lifecycle.
/// - The **main app** (via direct event notifications from visual/metadata mutations +
///   `SharedPlayerManager` save paths) drives pushes. Widget/App Intent processes only
///   mutate SPM; only the main process owns and updates the Activity.
///
/// ## Event-Driven Model (Primary) vs. Timer (Demoted Fallback)
/// Updates are **purely reactive** to meaningful state changes:
/// - Visual transitions (`.prePlay` → `.playing`, play → `.userPaused`, etc.) via
///   `setPlaying`, `stop`, `setUserPaused`, `userRequestedPlay`, coordinator paths.
/// - ICY program metadata arrival via `didUpdateStreamMetadata`.
/// - Foreground correction and background auto-start.
///
/// The 10 s repeating timer (`updateTimer`) is intentionally demoted to a **rare fallback**
/// only (e.g. as an explicit safety net in unusual background metadata starvation cases).
/// It is **not** started automatically on `startActivity` or `observeExistingActivities`.
/// All normal freshness comes from the event sites above. `startLocalUpdateTimer` /
/// `stopLocalUpdateTimer` remain `internal` as the designated testing seam.
///
/// ## Update Invariant
/// An `Activity.update(...)` is performed **if and only if** the candidate
/// `ContentState(visualState:streamMetadata)` differs from the last successfully
/// pushed value (or `force` is true). This keeps Dynamic Island / Lock Screen
/// updates immediate without redundant IPC or battery cost on duplicate content.
///
/// ## Test Isolation
/// All creation, timer start, and update paths are short-circuited under DEBUG when
/// `isRunningUnderTest` is true. This is required for acceptable `xcodebuild test`
/// performance from the shell (and to avoid "hung before establishing connection").
/// See the guards in `startActivity`, `updateCurrentActivity`, and `observeExistingActivities`.
///
/// See:
/// - `SharedPlayerManager.setPlaying()`, `stop()`, `didUpdateStreamMetadata`, `performActualSave`
/// - `SceneDelegate` + `AppDelegate` (the wired handlers)
/// - `PlayerVisualState`, `StreamProgramMetadata`
/// - `WidgetRefreshManager` (the parallel mechanism for home/Control widgets)
///
/// - SeeAlso: `SharedPlayerManager`, `PlayerVisualState.swift`, `LutheranRadioLiveActivityAttributes.swift`,
///   `CODING_AGENT.md` (Single Source of Truth Principles + Cross-target shared files),
///   docs/Widget-Presentation-Dataflow.md (Live Activity Event-Driven section),
///   <doc:Architecture>, RadioPlayerCoordinator (orchestration after SPM),
///   ``isRunningUnderTest`` (test short-circuit).
@MainActor
class RadioLiveActivityManager: ObservableObject {
    static let shared = RadioLiveActivityManager()
    
    @Published var currentActivity: Activity<LutheranRadioLiveActivityAttributes>?

    /// The (now rarely used) repeating local timer.
    ///
    /// - Important: This is intentionally `internal private(set)` as the
    ///   designated testing seam (see `startLocalUpdateTimer` / `stopLocalUpdateTimer`).
    ///   Tests use `@testable` to observe timer creation, validity, and cleanup
    ///   directly. Production code must never read or write this directly.
    ///
    /// - Note: Primary Live Activity updates are event-driven. This timer exists only
    ///   as an explicit fallback and is not started by the normal start/observe paths.
    /// - SeeAlso: ``RadioLiveActivityManager/startLocalUpdateTimer()``,
    ///   ``RadioLiveActivityManager/stopLocalUpdateTimer()``,
    ///   RadioLiveActivityManagerTests
    internal private(set) var updateTimer: Timer?

    /// Last successfully pushed Live Activity content.
    ///
    /// Purely in-memory (main-app process only). Used to implement the
    /// "push only when rendered content would actually change" rule.
    ///
    /// - Lifecycle: Cleared in `endActivity` and on termination paths.
    /// - Update Invariant: Compared with the freshly derived candidate before
    ///   every `Activity.update`. Equality uses `ContentState`'s `Hashable`/`Equatable`
    ///   (visualState + streamMetadata).
    /// - Never persisted. Widgets continue to use `PersistedWidgetState`.
    ///
    /// Exposed as `internal private(set)` for white-box testing of the change-detection
    /// behavior (parallel to `updateTimer`).
    internal private(set) var lastPushedContent: LutheranRadioLiveActivityAttributes.ContentState?

    #if DEBUG
    /// Robust detection of unit / UI test execution under DEBUG.
    ///
    /// Matches the detection used inside `observeExistingActivities()`.
    /// Used to short-circuit Live Activity creation and update paths that would
    /// otherwise perform synchronous ActivityKit daemon IPCs or start the 10 s
    /// repeating timer — both of which keep the test runner / LLDB "alive" and
    /// cause extremely slow / hung tests when run via `xcodebuild` from shell.
    ///
    /// The four-way check is required for coverage across:
    /// - `xcodebuild test` (XCTestConfigurationFilePath present)
    /// - Xcode GUI "Product › Test" / test navigator (env var often absent)
    /// - Attached LLDB / process name variants ("xctest", "com.apple...xctest...")
    ///
    /// - SeeAlso: ``observeExistingActivities()``, RadioLiveActivityManagerTests
    private var isRunningUnderTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.processName == "xctest"
            || ProcessInfo.processInfo.processName.contains("xctest")
    }
    #endif
    
    private init() {
        // Observe first so any "resume from existing LA" path is exercised (or short-circuited in tests).
        // The early return via ``isRunningUnderTest`` inside observeExistingActivities() (and the
        // guards in startActivity / updateCurrentActivity) is what keeps test init + playback
        // transition time near-zero and prevents the repeating timer from keeping the runner alive.
        // - SeeAlso: ``observeExistingActivities()``, ``isRunningUnderTest``, ``startActivity()``
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
    /// In DEBUG builds this performs an early return (with timer cleanup) when
    /// `isRunningUnderTest` is true. This prevents creation of a real `Activity`
    /// plus the 10 s local `updateTimer` during tests. Without the guard, calls
    /// originating from `SharedPlayerManager.setPlaying()` (via `#if LUTHERAN_MAIN_APP`
    /// paths) during UI tests would start a repeating timer that keeps the test
    /// runner alive, manifesting as "very slow tests" or "hung before establishing
    /// connection" when running `xcodebuild ... test` from the shell.
    ///
    /// - Postcondition: If successful (non-test), `currentActivity` is non-nil and the 10 s local
    ///   update timer is running. Initial content uses the current `PlayerVisualState` SSOT.
    /// - Important: Only call from main-app code (never widget extension). The caller is
    ///   responsible for ensuring we are allowed to show an activity (usually right after
    ///   a `.playing` transition).
    /// - Note: The test short-circuit here is the companion to the identical guard
    ///   in `observeExistingActivities()`. It is what made the prior partial fix
    ///   (commit 2af37cf) insufficient.
    /// - SeeAlso: `updateCurrentActivity()`, `SharedPlayerManager.setPlaying`,
    ///   ``isRunningUnderTest``, ``observeExistingActivities()``, <doc:Architecture>
    func startActivity() async {
        // Defense-in-depth UI test isolation using the SSOT.
        // Prevents waking the Chrono widget renderer process (WidgetRenderer_Activities)
        // and avoids any ActivityKit daemon IPC or timer scheduling during UITestMode
        // (explicit "-UITestMode" or XCTest environment under DEBUG).
        if SharedPlayerManager.isRunningInUITestMode {
            stopLocalUpdateTimer()
            return
        }

        #if DEBUG
        if isRunningUnderTest {
            // Prevent creating real Live Activities + the repeating local timer
            // during unit/UI tests. This is what was keeping the test runner alive.
            stopLocalUpdateTimer()
            return
        }
        #endif

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

            // Event-driven model: do NOT start the 10 s fallback timer here.
            // Freshness comes from explicit calls at visual/metadata mutation sites
            // (setPlaying / stop / didUpdateStreamMetadata / coordinator) and lifecycle.
            // The timer is only started via the explicit internal testing / fallback API.

            // Initial push captures the starting state into lastPushedContent.
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

    /// Pushes the latest `PlayerVisualState` + metadata into the active Live Activity,
    /// **but only when the rendered content would actually change**.
    ///
    /// This is the central implementation of the event-driven Live Activity model.
    /// Callers (SPM visual transitions, `didUpdateStreamMetadata`, coordinator, lifecycle,
    /// and the old `performActualSave` bridge) invoke this on meaningful change.
    ///
    /// Derivation uses the **in-memory** actor state (`currentVisualState` +
    /// `currentStreamMetadata`) when the main app is running. The persisted snapshot
    /// is used only as a safe fallback (e.g. very early after start before the first
    /// mutation). This decouples transient LA presentation from the durable
    /// `PersistedWidgetState` writes that widgets and relaunch require.
    ///
    /// - Precondition: Must be called on the main actor (the method is `@MainActor`).
    /// - Postcondition: If an update is sent, `lastPushedContent` holds the exact
    ///   `ContentState` that was pushed.
    /// - Note: Silently no-ops if no activity is active. Duplicate content (visual +
    ///   metadata) is suppressed by the `lastPushedContent` comparison.
    /// - Update Invariant: `Activity.update` occurs **iff** the candidate differs from
    ///   `lastPushedContent` (or the call is treated as initial). This is what makes
    ///   Lock Screen / Dynamic Island feel immediate without timer polling.
    /// - Important: Uses `nonisolated(unsafe)` + `unsafe` because `Activity.update` is
    ///   not Sendable in the current SDK; the capture of the Activity is done only after
    ///   we hold a strong local reference on the main actor.
    ///
    /// - SeeAlso: `startActivity()`, `SharedPlayerManager.setPlaying`,
    ///   `SharedPlayerManager.didUpdateStreamMetadata`,
    ///   `performActualSave` (the bridge call remains for widget parity),
    ///   ``isRunningUnderTest``, docs/Widget-Presentation-Dataflow.md,
    ///   RadioLiveActivityManagerTests
    @MainActor
    func updateCurrentActivity() async {
        // Defense-in-depth UI test isolation (SSOT). Even if a stale currentActivity reference
        // existed, we must not call Activity.update during test runs.
        if SharedPlayerManager.isRunningInUITestMode {
            return
        }

        #if DEBUG
        if isRunningUnderTest {
            return
        }
        #endif

        guard let activity = currentActivity else { return }
        
        let manager = SharedPlayerManager.shared
        
        // Prefer the live in-memory values (decoupled path). Persisted is only fallback
        // so that an early push before the first mutation still has something reasonable.
        // This is the key separation: LA does not *require* a PersistedWidgetState write.
        let visualState = await manager.currentVisualState
        let streamMetadata = await manager.currentStreamMetadata
            ?? SharedPlayerManager.loadPersistedStreamMetadata()
        
        let candidate = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: visualState,
            streamMetadata: streamMetadata
        )
        
        // Event-driven deduplication (core of the responsiveness improvement).
        // We only cross the ActivityKit IPC boundary when the user-visible LA content
        // (status pill, control glyph/tint, program title/speaker) would actually differ.
        if let last = lastPushedContent, last == candidate {
            #if DEBUG
            print("🔴 Live Activity update suppressed (content unchanged)")
            #endif
            return
        }
        
        lastPushedContent = candidate
        
        nonisolated(unsafe) let safeActivity = activity
        unsafe await safeActivity.update(.init(state: candidate, staleDate: nil))
        
        #if DEBUG
        print("🔴 Live Activity updated locally: visualState=\(visualState)")
        #endif
    }

    /// Ends the current Live Activity (if any) and stops any fallback timer.
    ///
    /// The final pushed state is `.userPaused` (with no metadata) so that any transient
    /// UI the system shows during dismissal does not claim the stream is still live.
    ///
    /// `dismissalPolicy`:
    /// - `.default` (normal / clear paths): lets the system keep the ended activity visible
    ///   for a grace period so the user sees the final paused state before it is removed.
    /// - `.immediate` (termination path only): removes the activity surface right away.
    ///
    /// **Why `.immediate` on termination (Cleanup Invariant)**:
    /// Once the main app process has exited there is no longer an in-process actor that can
    /// service `AppIntent` taps from the Live Activity or push fresh `ContentState` updates.
    /// Leaving the LA visible would allow the ActivityKit / Chrono subsystem to continue
    /// treating the surface as "active", potentially causing pings to the widget renderer
    /// or presenting play controls that have no live backing process. Immediate dismissal
    /// after the final `.userPaused` update stops that.
    ///
    /// The user can still launch the app cleanly via home-screen widget "tap to open",
    /// Control widget, app icon, or (while the LA is still present before termination)
    /// the standard Live Activity tap-to-launch ("open") URL.
    ///
    /// - Lifecycle: Also clears `lastPushedContent` so a future restart starts fresh.
    /// - Note: Called on privacy clear (`clearAllLocalState`), on `applicationWillTerminate`,
    ///   and on `willTerminateNotification`. Does **not** automatically end on user pause
    ///   (a paused LA with a working play button is intentional for quick resume while the
    ///   main process is alive).
    /// - Precondition: Only the main app process calls this (widget processes never own
    ///   the Activity instance).
    /// - SeeAlso: `handleAppWillTerminate`, AppDelegate.applicationWillTerminate,
    ///   SharedPlayerManager.forceStaleLivenessTimestampForTermination,
    ///   docs/Widget-Presentation-Dataflow.md (termination section + LA event-driven section).
    func endActivity(dismissalPolicy: ActivityUIDismissalPolicy = .default) {
        stopLocalUpdateTimer()
        
        guard let activity = currentActivity else {
            lastPushedContent = nil
            return
        }
        
        currentActivity = nil   // clear immediately while still on the calling context
        lastPushedContent = nil // Lifecycle: next startActivity begins with a clean last-pushed record
        
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
            unsafe await safeActivityToEnd.end(content, dismissalPolicy: dismissalPolicy)
            
            #if DEBUG
            print("🔴 Live Activity ended (policy: \(dismissalPolicy))")
            #endif
        }
    }
    
    // MARK: - Local-Only Update Timer (demoted fallback only)
    
    /// Starts (or restarts) the repeating fallback timer.
    ///
    /// **This timer is no longer the primary mechanism.** The Live Activity system
    /// is event-driven: visual state changes and ICY metadata arrivals push
    /// immediately via `updateCurrentActivity()` (which applies its own change
    /// detection).
    ///
    /// The timer is retained **only** as:
    /// - An explicit testing seam (`internal`).
    /// - A rare manual fallback for pathological cases where events stop arriving
    ///   while audio continues (e.g. certain background metadata starvation).
    ///
    /// Normal code paths (setPlaying, stop, didUpdateStreamMetadata, foreground,
    /// background auto-start) must **not** start this timer.
    ///
    /// - Important: Exposed as `internal` (together with `updateTimer` and
    ///   `stopLocalUpdateTimer`) as the designated white-box testing seam.
    ///   See ``RadioLiveActivityManager/updateTimer`` and RadioLiveActivityManagerTests.
    internal func startLocalUpdateTimer() {
        stopLocalUpdateTimer()
        
        // Fallback interval only. Not used for normal freshness.
        updateTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            Task { @MainActor in
                await self.updateCurrentActivity()
            }
        }
        
        #if DEBUG
        print("🔴 Started local *fallback* update timer for Live Activity (rarely used)")
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
    /// - Important: In DEBUG builds this performs a **robust test-environment short-circuit**
    ///   using the shared ``isRunningUnderTest`` helper. A real `Activity<...>.activities.first`
    ///   lookup is a synchronous daemon IPC that becomes extremely slow under LLDB when any
    ///   Live Activity is present in the simulator (e.g. the app was streaming). The guard
    ///   prevents that cost during unit tests and guarantees `currentActivity` starts as `nil`.
    ///
    /// - Note: The four-condition detection (env var + class + two processName checks)
    ///   is required because `XCTestConfigurationFilePath` is reliable under `xcodebuild`
    ///   but often absent from Xcode GUI test runs (Product → Test / test navigator).
    ///   `NSClassFromString("XCTestCase")` matches the detection pattern used in
    ///   `DirectStreamingPlayer`. The same helper is used by `startActivity()` and
    ///   `updateCurrentActivity()` for defense-in-depth.
    ///
    /// - SeeAlso: ``RadioLiveActivityManager/init()``, ``isRunningUnderTest``,
    ///   RadioLiveActivityManagerTests.setUp, ``startLocalUpdateTimer()``,
    ///   ``startActivity()``, <doc:Architecture>
    private func observeExistingActivities() {
        // Defense-in-depth using the SSOT: short-circuit before any ActivityKit query
        // or timer scheduling when launched under -UITestMode. This is critical because
        // the manager is instantiated early (statics, coordinators) and its init calls this.
        if SharedPlayerManager.isRunningInUITestMode {
            currentActivity = nil
            return
        }

        #if DEBUG
        // Robust test detection (works in Xcode GUI + xcodebuild + attached LLDB).
        // We short-circuit *before* the synchronous ActivityKit daemon query
        // using the shared `isRunningUnderTest` computed property (DRY).
        if isRunningUnderTest {
            currentActivity = nil
            return
        }
        #endif

        currentActivity = Activity<LutheranRadioLiveActivityAttributes>.activities.first

        if let activity = currentActivity {
            // Event-driven model: do not auto-start the fallback timer on resume.
            // Any in-flight activity will receive pushes on the next visual or metadata
            // event (or explicit foreground correction). Starting the timer here would
            // re-introduce the old polling-driven behavior.
            #if DEBUG
            print("🔴 Found existing Live Activity: \(activity.id) — timer not auto-started (event-driven)")
            #endif
            // If a future caller needs the fallback, it can call startLocalUpdateTimer() explicitly.
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
    /// The started activity receives its initial content via the normal event-driven
    /// path inside `startActivity` → `updateCurrentActivity`. No fallback timer is
    /// started.
    ///
    /// Under DEBUG test runs we early-return before inspecting state or scheduling
    /// the async start, for defense-in-depth alongside the guards in startActivity.
    ///
    /// - SeeAlso: SceneDelegate.sceneDidEnterBackground, ``isRunningUnderTest``
    func handleAppWillEnterBackground() {
        // Defense-in-depth: never start Live Activities from background transitions under test.
        if SharedPlayerManager.isRunningInUITestMode { return }

        #if DEBUG
        if isRunningUnderTest { return }
        #endif

        // Auto-start Live Activity when backgrounding with audio.
        // Subsequent ICY metadata or visual changes will push via the decoupled path.
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
    ///
    /// Under DEBUG test runs we early-return to avoid even scheduling the no-op
    /// `updateCurrentActivity` Task.
    ///
    /// - SeeAlso: ``isRunningUnderTest``, handleAppWillEnterBackground
    func handleAppDidEnterForeground() {
        // Defense-in-depth: suppress foreground LA pushes under UITestMode.
        if SharedPlayerManager.isRunningInUITestMode { return }

        #if DEBUG
        if isRunningUnderTest { return }
        #endif

        Task { @MainActor in
            await updateCurrentActivity()
        }
    }
    
    /// Called on process termination paths (AppDelegate + willTerminateNotification).
    ///
    /// Ends the activity (with `.immediate` dismissal) so a stale "playing with buttons"
    /// preview does not remain on the lock screen / Dynamic Island after the main app
    /// process has been killed (normal termination or best-effort on some abrupt paths).
    ///
    /// Also called indirectly via the `UIApplication.willTerminateNotification` observer
    /// registered in init for defense-in-depth when AppDelegate is not delivered.
    ///
    /// - Cleanup Invariant: After this, no Live Activity owned by this process remains
    ///   that the ActivityKit subsystem could continue to ping or render with active
    ///   controls. The widget surfaces fall back to their passive "last-known + tap to open"
    ///   presentation via the staled liveness sentinel.
    func handleAppWillTerminate() {
        // Clean shutdown - end Live Activity immediately (see endActivity doc for rationale).
        // The final state pushed inside endActivity is always .userPaused.
        endActivity(dismissalPolicy: .immediate)
    }
}
