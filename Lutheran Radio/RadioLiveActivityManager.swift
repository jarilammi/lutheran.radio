//
//  RadioLiveActivityManager.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 13.6.2025.
//
//  Privacy-first Live Activities - NO push notifications needed
//

@unsafe @preconcurrency import ActivityKit
import Foundation
import UIKit   // For UIApplication.willTerminateNotification (termination observer) and related lifecycle.
import WidgetSurface

/// `RadioLiveActivityManager` owns the lifecycle and push surface for privacy-first
/// local-only Live Activities (Dynamic Island + Lock Screen) using ActivityKit.
///
/// ## Purpose and Ownership
/// Manages creation, `ContentState` pushes (via `update(using:)`), and termination
/// of `Activity<LutheranRadioLiveActivityAttributes>`. All pushes are driven from
/// the main-app process only. Widget/App Intent processes mutate state via
/// `SharedPlayerManager` facades; only the main process owns the Activity reference.
///
/// ## Single Source of Truth Contract
/// - Widget and relaunch presentation use `PersistedWidgetState` exclusively
///   (see `loadPersistedWidgetState`, `savePersistedWidgetState`).
/// - Live Activity transient UI is derived from in-memory `SharedPlayerManager`
///   (`currentVisualState` + `currentStreamMetadata`) plus
///   ``SharedPlayerManager/liveActivityLanguageCodeForContentPush()`` (stream attach,
///   or destination language while a stream-switch Connecting hold is active).
/// - `ContentState.currentLanguage` is the language-chrome SSOT on Lock Screen / Dynamic
///   Island; views must not re-derive via privacy-gated ``preferredWidgetLanguage()``.
/// - Durable App Group mirrors (visual + language) warm extension-hosted intent paths
///   and are **not** gated by home-widget ``hasActiveWidgets``.
/// - `PersistedWidgetState` is never bypassed for widgets.
///
/// ## Event-Driven Model (Primary) + Live Activity Attribute Events
/// Updates are reactive to player-domain mutations (visual transitions, ICY
/// `metadataDidUpdate`, lifecycle). The 30 s fallback timer is demoted and not
/// started on normal paths.
///
/// In addition, the manager consumes the Live Activity attribute events
/// streams (`contentUpdates` yielding `ActivityContent<ContentState>` and
/// `activityStateUpdates`). On yield we align `lastPushedContent` (for
/// stronger diff-driven suppression) and react to terminal states for
/// self-healing lifecycle.
///
/// See the implementation of ``beginObservingActivityEvents(_:)`` and the
/// "Live Activity Attribute Events Observation" section in
/// docs/Widget-Presentation-Dataflow.md. The concrete loop is now the
/// reference implementation inside the shared `WidgetEventObserver`.
///
/// ## Update Invariant
/// `Activity.update(...)` occurs **iff** candidate differs from `lastPushedContent`
/// (or force/initial). Intent-path optimistic toggles publish ContentState and align
/// ``lastPushedContent`` first so a rapid second tap resolves from the post-toggle
/// glyph; the sequential sticky lock / soft-silence path then converges actor state
/// without requiring a special suppress rule that would block legitimate visual changes.
///
/// ## Test Isolation
/// All real Activity creation/update/timer paths are short-circuited under
/// `isRunningUnderTest` (and the UITestMode SSOT) so that `xcodebuild test`
/// remains fast. See guards in `startActivity`, `updateCurrentActivity`,
/// `observeExistingActivities`.
///
/// - SeeAlso: `SharedPlayerManager` (source of visual/metadata + emitter of
///   `PlayerEvent`), `LutheranRadioLiveActivityAttributes.ContentState`,
///   `PlayerVisualState`, `StreamProgramMetadata`,
///   `LutheranRadioWidgetLiveActivity.swift`,
///   `WidgetEventObserver`,
///   docs/Widget-Presentation-Dataflow.md (Live Activity Event-Driven + new
///   events observation section),
///   docs/Event-Driven-Refactor-Roadmap.md (Tier 2 LA events item),
///   CODING_AGENT.md (Single Source of Truth Principles, cross-target shared
///   files, Documentation & Comment Standards),
///   <doc:Architecture>, RadioLiveActivityManagerTests.
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
    ///   (visualState + streamMetadata + currentLanguage). Language-only stream
    ///   switches therefore force an ActivityKit push.
    /// - Never persisted as a snapshot. Widgets continue to use `PersistedWidgetState`.
    ///   Durable LA visual/language App Group mirrors are separate cross-process signals.
    ///
    /// Exposed as `internal private(set)` for white-box testing of the change-detection
    /// behavior (parallel to `updateTimer`).
    internal private(set) var lastPushedContent: LutheranRadioLiveActivityAttributes.ContentState?

    /// Long-lived task observing the Live Activity attribute events stream.
    ///
    /// Consumes `contentUpdates` (the events surface yielding
    /// `ActivityContent<ContentState>` on every attribute update). Started on
    /// acquisition (start or resume); cancelled on end paths. Used to keep
    /// `lastPushedContent` in sync with the system-accepted state for diff-driven
    /// suppression of `update(using:)` calls.
    ///
    /// Responsibilities on yield:
    /// - Synchronize `lastPushedContent` with the yielded activity's `contentState`.
    ///   This aligns the diff check in `updateCurrentActivity` with the exact
    ///   state the system last rendered, strengthening duplicate suppression.
    /// - On `.dismissed` or `.ended`, clear local tracking so that stale
    ///   references do not cause spurious update attempts.
    ///
    /// Why this matters: gives the manager a reactive, system-driven signal
    /// for both content convergence and lifecycle. Combined with the existing
    /// `lastPushedContent` diff and PlayerEvent-driven call sites, it reduces
    /// reliance on the timer fallback and makes forced pushes more robust
    /// without changing any public contract or adding polling.
    ///
    /// - Important: Observation is additive only. All existing push sites
    ///   (`SharedPlayerManager`, `RadioPlayerCoordinator`, lifecycle handlers)
    ///   and the privacy / test guards remain the primary mechanism.
    /// - Note: Runs on main actor via Task + MainActor.run to keep isolation
    ///   clean under strict Swift 6.
    /// - SeeAlso: ``beginObservingActivityEvents(_:)``, ``updateCurrentActivity()``,
    ///   ``endActivity(dismissalPolicy:)``, docs/Widget-Presentation-Dataflow.md,
    ///   docs/Event-Driven-Refactor-Roadmap.md, `WidgetEventObserver`.
    ///
    /// Exposed as `internal private(set)` (parallel to `updateTimer` / `lastPushedContent`)
    /// as the designated white-box testing seam. Production code must never read or
    /// assign this directly.
    internal private(set) var activityObservationTask: Task<Void, Never>?

    #if DEBUG
    /// When true, attribute-events observation termination performs the same local cleanup
    /// as production ``performAttributeObservationTerminationHygiene()`` when
    /// ``currentActivity`` is non-nil, without ActivityKit IPC.
    ///
    /// Used exclusively by ``_test_beginObservingSyntheticContentUpdates(_:)`` and
    /// RadioLiveActivityManagerTests.
    private var _test_harnessSimulatesActiveActivity = false
    #endif

    /// Consolidated observer for the Live Activity attribute events stream
    /// (`contentUpdates`). Delegates to `WidgetEventObserver` (the extracted
    /// common implementation) while continuing to publish the resulting task
    /// into the `activityObservationTask` seam for test isolation.
    private let activityEventObserver = WidgetEventObserver<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>>()

    #if DEBUG
    /// Robust detection of unit / UI test execution under DEBUG.
    ///
    /// Matches the detection used inside `observeExistingActivities()`.
    /// Used to short-circuit Live Activity creation and update paths that would
    /// otherwise perform synchronous calls to ActivityKit's system services or start the 10 s
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
        // Defer observation to a Task + yield so that the initial window + first layout
        // (which causes the system launch screen / splash to be dismissed) is never
        // blocked by a potentially slow synchronous ActivityKit query
        // (`Activity<...>.activities.first`) or stream setup.
        //
        // On simulator with stale Live Activities left from prior manual runs or tests,
        // the system service round-trips for `.activities` / contentUpdates can take many minutes
        // and previously kept the splash visible (or caused the 5-10 min "hangs" during
        // `xcodebuild test`).
        // The test setUp explicitly nils + cancels for the same reason.
        //
        // We still observe "early" (next suspension point after the window is visible)
        // so existing LA resumption works for normal cold launches.
        // The internal guards in observeExistingActivities() continue to short-circuit
        // under UITestMode / isRunningUnderTest.
        //
        // AGENT NOTE: If you are tempted to move this call back to synchronous init
        // "for simplicity", you will re-introduce launch stalls and slow test runs
        // on any simulator that has accumulated Live Activities. The pattern here
        // (defer + yield + early nil in observe + cheap sanitization in test setUp)
        // is required for acceptable cold launch and test performance.
        // See CODING_AGENT.md ("Test Execution Patience and Fast, Reliable Test Patterns").
        //
        // - SeeAlso: ``observeExistingActivities()``, scene(willConnectTo:), SceneDelegate,
        //   ``isRunningUnderTest``, CODING_AGENT.md (test isolation patterns + Test Execution Patience),
        //   the sanitization in SharedPlayerManagerEventTests.setUp and RadioLiveActivityManagerTests.setUp.
        Task { @MainActor [weak self] in
            // Cooperative yield lets the current runloop tick, layout, and first commit
            // complete so the launch screen is replaced by app content promptly.
            await Task.yield()
            self?.observeExistingActivities()
        }

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
    ///   ``SharedPlayerManager/refreshAllMediaSurfaces(liveActivity:widgetRefresh:widgetRefreshImmediate:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md (start policy),
    ///   ``isRunningUnderTest``, ``observeExistingActivities()``, <doc:Architecture>
    func startActivity() async {
        // Defense-in-depth UI test isolation using the SSOT.
        // Prevents waking the Chrono widget renderer process (WidgetRenderer_Activities)
        // and avoids any calls to ActivityKit's system services or timer scheduling during UITestMode
        // (explicit "-UITestMode" or XCTest environment under DEBUG).
        if SharedPlayerManager.isRunningInUITestMode {
            stopLocalUpdateTimer()
            activityEventObserver.cancel()
            activityObservationTask = nil
            return
        }

        #if DEBUG
        if isRunningUnderTest {
            // Prevent creating real Live Activities + the repeating local timer
            // during unit/UI tests. This is what was keeping the test runner alive.
            stopLocalUpdateTimer()
            activityEventObserver.cancel()
            activityObservationTask = nil
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
        // Prefer hold-time connecting language when a stream switch is in flight.
        let currentLanguage = await manager.liveActivityLanguageCodeForContentPush()
        
        let initialContentState = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: visualState,
            streamMetadata: streamMetadata,
            currentLanguage: currentLanguage
        )
        
        do {
            let activity = try Activity<LutheranRadioLiveActivityAttributes>.request(
                attributes: attributes,
                content: .init(state: initialContentState, staleDate: nil)
            )
            
            currentActivity = activity
            beginObservingActivityEvents(activity)

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

    /// Pushes the latest `PlayerVisualState` + metadata + stream language into the active
    /// Live Activity, **but only when the rendered content would actually change**.
    ///
    /// This is the central implementation of the event-driven Live Activity model.
    /// Callers (SPM visual transitions, `didUpdateStreamMetadata`, coordinator, lifecycle,
    /// and the old `performActualSave` bridge) invoke this on meaningful change.
    ///
    /// Derivation uses the **in-memory** actor state (`currentVisualState` +
    /// `currentStreamMetadata`) and ``SharedPlayerManager/liveActivityLanguageCodeForContentPush()``
    /// when the main app is running. The persisted snapshot is used only as a safe fallback for
    /// metadata (e.g. very early after start before the first mutation). This decouples transient
    /// LA presentation from the durable `PersistedWidgetState` writes that widgets and
    /// relaunch require — language chrome must not depend on privacy-gated home-widget writes.
    ///
    /// **Stream-switch hold:** While ``SharedPlayerManager/isStreamSwitchPrePlayHoldActive``
    /// or ``SharedPlayerManager/isConnectingPlayback`` is true, a candidate visual of
    /// `.playing` is clamped to `.prePlay` so lock-screen chrome cannot flash play affordance
    /// during silent engine teardown or first-byte attach. Coordinators establish Connecting
    /// **with the destination language** via ``resetToPrePlayForNewStream`` before `.streamSwitch`
    /// stop so language chrome does not lag one content push behind visual Connecting.
    ///
    /// - Precondition: Must be called on the main actor (the method is `@MainActor`).
    /// - Postcondition: If an update is sent, `lastPushedContent` holds the exact
    ///   `ContentState` that was pushed. Durable visual + language App Group mirrors are
    ///   warmed even when ActivityKit IPC is suppressed.
    /// - Note: Silently no-ops if no activity is active. Duplicate content (visual +
    ///   metadata + language) is suppressed by the `lastPushedContent` comparison.
    /// - Update Invariant: `Activity.update` occurs **iff** the candidate differs from
    ///   `lastPushedContent` (or the call is treated as initial). Language-only stream
    ///   switches must not be suppressed.
    /// - Important: Uses `nonisolated(unsafe)` + `unsafe` because `Activity.update` is
    ///   not Sendable in the current SDK; the capture of the Activity is done only after
    ///   we hold a strong local reference on the main actor.
    ///
    /// - SeeAlso: `startActivity()`, `SharedPlayerManager.setPlaying`,
    ///   `SharedPlayerManager.resetToPrePlayForNewStream`,
    ///   `SharedPlayerManager.didUpdateStreamMetadata`,
    ///   `performActualSave` (the bridge call remains for widget parity),
    ///   ``beginObservingActivityEvents(_:)`` (the Live Activity events surface that
    ///   keeps `lastPushedContent` aligned), ``isRunningUnderTest``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   docs/Widget-Presentation-Dataflow.md,
    ///   docs/Widget-Functionality-Roadmap.md (Live Activity language chrome SSOT),
    ///   docs/cold-launch-streamplay-regression-checklist.md (§6),
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
        var visualState = await manager.currentVisualState
        // Stream-switch hold / in-flight connect: never advertise `.playing` on LA while the
        // engine is tearing down or attaching a new secured item. Coordinators establish
        // `.prePlay` before silent stop; this clamp is defense-in-depth against a race where
        // language chrome updates before visual SSOT settles.
        let streamSwitchHold = await manager.isStreamSwitchPrePlayHoldActive
        let connecting = await manager.isConnectingPlayback
        if (streamSwitchHold || connecting) && visualState == .playing {
            visualState = .prePlay
        }
        let streamMetadata = await manager.currentStreamMetadata
            ?? SharedPlayerManager.loadPersistedStreamMetadata()
        // Hold-time target language advances with Connecting so the card never shows the
        // prior stream’s flag/name for one content push while the engine model is still old.
        let currentLanguage = await manager.liveActivityLanguageCodeForContentPush()
        
        let candidate = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: visualState,
            streamMetadata: streamMetadata,
            currentLanguage: currentLanguage
        )

        // Durable App Group mirrors for extension-hosted LA planning / optimistic language.
        // Always keep warm — even when ActivityKit IPC is suppressed — so lock-screen pause
        // and language chrome are not inverted when home-widget write suppression leaves the
        // extension session snapshot empty.
        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(visualState)
        SharedPlayerManager.persistLiveActivityLanguageMirror(currentLanguage)
        
        // Event-driven deduplication (core of the responsiveness improvement).
        // We only cross the ActivityKit IPC boundary when the user-visible LA content
        // (status pill, control glyph/tint, program title/speaker, language chrome)
        // would actually differ. Intent-path optimistic toggles pre-align ``lastPushedContent``
        // to the same visual the actor will reach after sticky lock / setPlaying, so the
        // engine-complete refresh commonly hits this suppress path (no thrash, no double IPC).
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
        print("🔴 Live Activity updated locally: visualState=\(visualState) language=\(currentLanguage)")
        #endif
    }

    /// Aligns in-memory ``lastPushedContent`` with an intent-path optimistic Live Activity visual.
    ///
    /// Called from ``WidgetIntentExecution`` after ActivityKit content is published (or when
    /// no activity is visible in this process). Matching the optimistic visual here means
    /// the subsequent engine-complete ``updateCurrentActivity()`` typically sees an equal
    /// candidate and suppresses redundant IPC once the actor sticky-locks or setPlaying.
    /// Program metadata and stream language are preserved from the last push, the owned
    /// activity content, or main-app language resolution — never cleared solely because the
    /// control flipped.
    ///
    /// - Parameter visualState: Optimistic control visual (`.userPaused` or `.playing`).
    /// - Postcondition: ``lastPushedContent`` reflects `visualState` with preserved metadata
    ///   and language when any source is available; durable toggle mirrors stay the caller's
    ///   job (already written before this alignment).
    /// - Note: Does not call `Activity.update` — the intent path owns that IPC via
    ///   `Activity.activities` so extension-hosted and main-hosted toggles share one push site.
    /// - SeeAlso: ``updateCurrentActivity()``, ``WidgetIntentExecution/performLiveActivityToggle()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    @MainActor
    func recordOptimisticToggleContent(visualState: PlayerVisualState) {
        let metadata =
            lastPushedContent?.streamMetadata
            ?? currentActivity?.content.state.streamMetadata
            ?? SharedPlayerManager.loadPersistedStreamMetadata()
        let language =
            lastPushedContent?.currentLanguage
            ?? currentActivity?.content.state.currentLanguage
            ?? SharedPlayerManager.mainAppLiveActivityLanguageCode()
        lastPushedContent = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: visualState,
            streamMetadata: metadata,
            currentLanguage: language
        )
        #if DEBUG
        print("🔴 Live Activity lastPushedContent aligned to optimistic visual=\(visualState) language=\(language)")
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
    /// - Important: Under `isRunningInUITestMode` (and DEBUG `isRunningUnderTest`) this
    ///   performs only cheap local cleanup and nils references; the real `Activity.end`
    ///   Task is skipped. This keeps unit tests fast even when a Live Activity was left
    ///   behind by a prior simulator streaming session. See also the guards in
    ///   `startActivity`, `updateCurrentActivity`, and `observeExistingActivities`.
    /// - SeeAlso: `handleAppWillTerminate`, AppDelegate.applicationWillTerminate,
    ///   SharedPlayerManager.forceStaleLivenessTimestampForTermination,
    ///   ``isRunningUnderTest``, SharedPlayerManager.isRunningInUITestMode,
    ///   RadioLiveActivityManagerTests, docs/Widget-Presentation-Dataflow.md (termination section + LA event-driven section).
    func endActivity(dismissalPolicy: ActivityUIDismissalPolicy = .default) {
        stopLocalUpdateTimer()

        // Cancel the attribute events observer (self-healing via the stream will
        // also do this on terminal states, but explicit end must be immediate).
        activityEventObserver.cancel()
        activityObservationTask = nil

        // Defense-in-depth UI test isolation.
        // Prevents real Activity.update + .end IPCs (slow system service round-trips under LLDB
        // when a Live Activity exists from a prior streaming session in the simulator).
        // Matches the pattern used in startActivity / updateCurrentActivity / observe.
        // When this fires, clear local references so any subsequent clearAllLocalState
        // or lifecycle caller sees a no-op end (currentActivity already nil).
        if SharedPlayerManager.isRunningInUITestMode {
            currentActivity = nil
            lastPushedContent = nil
            SharedPlayerManager.clearLiveActivityToggleVisualStateMirror()
            SharedPlayerManager.clearLiveActivityLanguageMirror()
            return
        }

        #if DEBUG
        if isRunningUnderTest {
            currentActivity = nil
            lastPushedContent = nil
            SharedPlayerManager.clearLiveActivityToggleVisualStateMirror()
            SharedPlayerManager.clearLiveActivityLanguageMirror()
            return
        }
        #endif
        
        guard let activity = currentActivity else {
            lastPushedContent = nil
            SharedPlayerManager.clearLiveActivityToggleVisualStateMirror()
            SharedPlayerManager.clearLiveActivityLanguageMirror()
            return
        }
        
        currentActivity = nil   // clear immediately while still on the calling context
        lastPushedContent = nil // Lifecycle: next startActivity begins with a clean last-pushed record
        SharedPlayerManager.clearLiveActivityToggleVisualStateMirror()
        SharedPlayerManager.clearLiveActivityLanguageMirror()
        
        // Capture safely once (standard Live Activity pattern under Swift 6)
        nonisolated(unsafe) let safeActivityToEnd = activity
        
        Task {
            let finalContentState = LutheranRadioLiveActivityAttributes.ContentState(
                visualState: .userPaused,
                streamMetadata: nil,
                currentLanguage: SharedPlayerManager.mainAppLiveActivityLanguageCode()
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
    ///   lookup is a synchronous call into ActivityKit's system services that becomes extremely slow under LLDB when any
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
            activityEventObserver.cancel()
            activityObservationTask = nil
            return
        }

        #if DEBUG
        // Robust test detection (works in Xcode GUI + xcodebuild + attached LLDB).
        // We short-circuit *before* the synchronous call to ActivityKit's system services
        // using the shared `isRunningUnderTest` computed property (DRY).
        if isRunningUnderTest {
            currentActivity = nil
            activityEventObserver.cancel()
            activityObservationTask = nil
            return
        }
        #endif

        currentActivity = Activity<LutheranRadioLiveActivityAttributes>.activities.first

        if let activity = currentActivity {
            // Event-driven model: do not auto-start the fallback timer on resume.
            // Any in-flight activity will receive pushes on the next visual or metadata
            // event (or explicit foreground correction). Starting the timer here would
            // re-introduce the old polling-driven behavior.
            beginObservingActivityEvents(activity)
            // Warm durable toggle visual + language mirrors from the system-held ContentState so
            // the first lock-screen pause / language-sensitive optimistic path after process
            // resume does not invert when extension memory is empty.
            let state = activity.content.state
            SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(state.visualState)
            SharedPlayerManager.persistLiveActivityLanguageMirror(state.currentLanguage)
            #if DEBUG
            print("🔴 Found existing Live Activity: \(activity.id) — timer not auto-started (event-driven)")
            #endif
            // If a future caller needs the fallback, it can call startLocalUpdateTimer() explicitly.
        }
    }

    // MARK: - Live Activity Attribute Events Observation

    /// Records a system-accepted ``ContentState`` from the attribute-events stream.
    ///
    /// Keeps ``lastPushedContent`` aligned with the Live Activity surface so
    /// ``updateCurrentActivity()`` can suppress redundant `Activity.update` IPC.
    private func handleActivityContentUpdate(
        _ content: ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>
    ) {
        lastPushedContent = content.state
        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(content.state.visualState)
        SharedPlayerManager.persistLiveActivityLanguageMirror(content.state.currentLanguage)
    }

    /// Clears local activity tracking when attribute-events observation ends.
    ///
    /// Self-healing hygiene runs when ``currentActivity`` is still non-nil (for example
    /// after system dismissal) so stale references do not drive spurious update attempts.
    private func performAttributeObservationTerminationHygiene() {
        #if DEBUG
        if _test_harnessSimulatesActiveActivity {
            _test_harnessSimulatesActiveActivity = false
            currentActivity = nil
            lastPushedContent = nil
            SharedPlayerManager.clearLiveActivityToggleVisualStateMirror()
            SharedPlayerManager.clearLiveActivityLanguageMirror()
            return
        }
        #endif
        guard currentActivity != nil else { return }
        currentActivity = nil
        lastPushedContent = nil
        SharedPlayerManager.clearLiveActivityToggleVisualStateMirror()
        SharedPlayerManager.clearLiveActivityLanguageMirror()
    }

    /// Publishes the consolidated observer task into ``activityObservationTask``.
    private func publishActivityObservationTask() {
        activityObservationTask = activityEventObserver.task
    }

    #if DEBUG
    /// White-box seam: wires production-identical attribute-events handlers against a
    /// synthetic ``AsyncStream`` fixture instead of ActivityKit ``contentUpdates`` IPC.
    ///
    /// - Parameter stream: In-memory ``ActivityContent`` sequence for unit tests.
    /// - Postcondition: ``activityObservationTask`` holds the observer task published by
    ///   ``WidgetEventObserver``.
    /// - SeeAlso: ``beginObservingActivityEvents(_:)``, RadioLiveActivityManagerTests,
    ///   ``_test_wouldSuppressLiveActivityUpdate(visualState:streamMetadata:)``,
    ///   ``_test_setHarnessSimulatesActiveActivity(_:)``.
    func _test_beginObservingSyntheticContentUpdates(
        _ stream: AsyncStream<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>>
    ) {
        activityEventObserver.beginObserving(
            stream,
            onElement: { [weak self] content in
                self?.handleActivityContentUpdate(content)
            },
            onTermination: { [weak self] in
                self?.performAttributeObservationTerminationHygiene()
            }
        )
        publishActivityObservationTask()
    }

    /// Returns whether ``updateCurrentActivity()`` would suppress an ActivityKit push because
    /// ``lastPushedContent`` already matches the candidate. Performs no IPC.
    ///
    /// - Parameters:
    ///   - visualState: Candidate visual state from the player SSOT.
    ///   - streamMetadata: Candidate ICY metadata (nil when absent).
    ///   - currentLanguage: Candidate stream language code (defaults to last-pushed language,
    ///     or ``SharedPlayerManager/mainAppLiveActivityLanguageCode()`` when unset).
    /// - Returns: `true` when the candidate equals ``lastPushedContent``.
    func _test_wouldSuppressLiveActivityUpdate(
        visualState: PlayerVisualState,
        streamMetadata: StreamProgramMetadata?,
        currentLanguage: String? = nil
    ) -> Bool {
        let language = currentLanguage
            ?? lastPushedContent?.currentLanguage
            ?? SharedPlayerManager.mainAppLiveActivityLanguageCode()
        let candidate = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: visualState,
            streamMetadata: streamMetadata,
            currentLanguage: language
        )
        if let last = lastPushedContent, last == candidate {
            return true
        }
        return false
    }

    /// Enables termination self-healing coverage in RadioLiveActivityManagerTests without
    /// creating a real ``Activity``.
    func _test_setHarnessSimulatesActiveActivity(_ simulates: Bool) {
        _test_harnessSimulatesActiveActivity = simulates
    }

    /// Cancels synthetic attribute-events observation through the consolidated observer.
    ///
    /// Mirrors the cancellation path in ``endActivity(dismissalPolicy:)`` without
    /// clearing ``currentActivity`` / ``lastPushedContent`` upfront so termination
    /// hygiene can be asserted in isolation.
    func _test_cancelAttributeEventObservation() {
        activityEventObserver.cancel()
        activityObservationTask = nil
    }
    #endif

    /// Begins observation of the supplied activity's attribute events stream
    /// (`contentUpdates`).
    ///
    /// This is ActivityKit's events surface for `LutheranRadioLiveActivityAttributes.ContentState`.
    /// On each yielded `ActivityContent` we record `.state` into `lastPushedContent`
    /// so the manager's diff check in `updateCurrentActivity` uses the exact
    /// value the Live Activity surface last rendered.
    ///
    /// - Parameters:
    ///   - activity: The live `Activity<LutheranRadioLiveActivityAttributes>`
    ///     instance whose attribute updates we will consume.
    /// - Precondition: Must be invoked on the main actor.
    /// - Postcondition: `activityObservationTask` holds a live task that will
    ///   run until cancelled. Any prior observation task is cancelled first.
    /// - Important: The yielded `contentState` is used to keep
    ///   `lastPushedContent` authoritative. Terminal states trigger local
    ///   cleanup so that `currentActivity` never points at a surface the system
    ///   has already dismissed.
    /// - Note: This is the concrete implementation of the "events stream
    ///   optimization" for Live Activities. It is additive; the existing
    ///   diff-driven `updateCurrentActivity` contract and all call sites from
    ///   `SharedPlayerManager` and coordinators are unchanged.
    /// - SeeAlso: ``activityObservationTask``, ``updateCurrentActivity()``,
    ///   ``lastPushedContent``, `endActivity(dismissalPolicy:)`,
    ///   docs/Widget-Presentation-Dataflow.md (Live Activity Attribute Events
    ///   Observation), docs/Event-Driven-Refactor-Roadmap.md,
    ///   ``observeExistingActivities()``, ``startActivity()``,
    ///   `WidgetEventObserver`.
    private func beginObservingActivityEvents(_ activity: Activity<LutheranRadioLiveActivityAttributes>) {
        // SAFETY: ActivityKit's contentUpdates is the attribute events surface
        // yielding ActivityContent<ContentState>. The sequence is not Sendable;
        // we extract under nonisolated(unsafe) on the main-actor call site
        // (see established patterns for framework interop in this project:
        // DNS C callbacks, AVFoundation delegates). The helper performs the
        // iteration; terminal handling is supplied via onTermination so that
        // opportunistic cleanup occurs exactly as before.
        nonisolated(unsafe) let contentUpdates = activity.contentUpdates

        // Delegate to the consolidated `WidgetEventObserver`. The per-element
        // work and terminal hygiene are identical to the prior direct Task.
        // The resulting task is published back into the seam property.
        // The concrete Activity contentUpdates sequence is not Sendable; the
        // unsafe overload + unsafe expression + nonisolated(unsafe) let at
        // materialization satisfy the bridge (consistent with prior direct code).
        activityEventObserver.beginObserving(
            unsafeSequence: unsafe contentUpdates,
            onElement: { [weak self] content in
                self?.handleActivityContentUpdate(content)
            },
            onTermination: { [weak self] in
                self?.performAttributeObservationTerminationHygiene()
            }
        )
        publishActivityObservationTask()
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
