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
import os      // OSAllocatedUnfairLock for termination-path ActivityKit end wait
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
/// stream (`contentUpdates` yielding `ActivityContent<ContentState>`). On
/// yield we align `lastPushedContent` (for stronger diff-driven suppression).
/// Stream termination triggers local self-healing hygiene. Process exit and
/// cold-launch residual reaping are handled by ``handleAppWillTerminate()``
/// and ``observeExistingActivities()`` respectively.
///
/// See the implementation of ``beginObservingActivityEvents(_:)`` and the
/// "Live Activity Attribute Events Observation" section in
/// docs/Widget-Presentation-Dataflow.md. The concrete loop is now the
/// reference implementation inside the shared `WidgetEventObserver`.
///
/// ## Update Invariant
/// `Activity.update(...)` occurs **iff** the candidate is not suppressible under
/// ``shouldSuppressLiveActivityContentPush(lastPushed:candidate:ownedContentLanguage:)``
/// (or force/initial). Suppress is an **optimization**, not a source of truth:
/// owned `Activity.content.state.currentLanguage` beats optimistic / aspirational
/// ``lastPushedContent`` — never skip a push when the candidate language is non-empty
/// and differs from the surface the system still holds.
///
/// Intent-path optimistic toggles publish ContentState and align ``lastPushedContent``
/// so a rapid second tap resolves from the post-toggle glyph; the sequential sticky
/// lock / soft-silence path then converges actor state. Stream-switch optimistic
/// language alignment may advance ``lastPushedContent`` before system acceptance;
/// the owned-language gate + ``ensureAuthoritativeLanguageContentIfNeeded()`` keep
/// lock-screen flag/name on the destination until `content.state` matches.
///
/// ## Interactive recreation after stalled ActivityKit updates
/// Soft retries cannot repair an interactive activity whose system-held
/// `content.state` never advances (language stuck on a prior stream, or visual stuck
/// on `.userPaused` / `.prePlay` after soft resume or audible start while audio is
/// already playing). After a bounded streak of `Activity.update` completions that leave
/// system-held ContentState lagging, the manager may end the frozen surface and
/// ``startActivity()`` a replacement seeded from current language chrome + visual —
/// **only when an interactive `Activity.request` is eligible** (Live Activities enabled
/// and the application is active). When request is ineligible (lock screen / background
/// **visibility** constraints), the existing interactive activity is **kept** and a
/// pending ensure is recorded so the next foreground cycle can start or re-bind.
/// Recreation is capped so thrashing is impossible.
/// **Invariant:** never destroy the only interactive Live Activity unless a replacement
/// can be requested or a recoverable pending ensure is guaranteed.
/// Soft-resume / post-audible **visual** honesty prefers bounded
/// ``ensureAuthoritativePlayingContentIfNeeded()`` retries — not end+request — when the
/// only lag is owned `.prePlay` vs candidate `.playing`.
/// Language chrome prefers bounded ``ensureAuthoritativeLanguageContentIfNeeded()`` retries.
/// After the soft-retry budget is exhausted while interactive request is ineligible, language
/// ensure enters a **quiet pending** state for that destination so status-driven media-surface
/// refreshes do not thrash ActivityKit; re-arm on destination change, eligibility, become-active,
/// or system `contentUpdates`. Language-only status re-pushes defer while quiet; visual mutations
/// still push. Playing ensure has the same quiet-pending shape (``playingEnsureQuietPending``):
/// after ``authoritativePlayingContentEnsureMaxAttempts`` without owned `.playing` while request
/// is ineligible, visual-only status re-pushes that only repair `.playing` defer; pause
/// (``.userPaused``) and language mutations still push. Re-arm playing quiet on authoritative
/// play mutation (``setPlaying`` / soft-resume ensure), optimistic toggle / stream-switch,
/// eligibility, become-active, or `contentUpdates`. On foreground / become-active with an
/// **owned** activity, soft language + playing ensure run via
/// ``ensureAuthoritativeContentOnForegroundIfNeeded()`` (clears both quiet flags first);
/// dual SceneDelegate hooks are debounced for the owned-surface path while still
/// **consuming** language/playing quiet and ``pendingInteractiveLiveActivityEnsure`` on
/// unlock (and allowing a second pass when chrome still lags after a first ineligible pass).
/// Eligible-only recreation is a last resort after soft ensure still fails (never while request
/// is ineligible).
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

    /// In-process suppress memory for Live Activity content pushes.
    ///
    /// Purely in-memory (main-app process only). Used to implement the
    /// "push only when rendered content would actually change" rule — an
    /// **optimization**, not proof that the on-screen activity holds this state.
    ///
    /// - Lifecycle: Cleared in `endActivity` and on termination paths.
    /// - Update Invariant: Compared with the freshly derived candidate before
    ///   every `Activity.update`, **subject to** the owned-content language gate
    ///   (``shouldSuppressLiveActivityContentPush``). Equality uses `ContentState`'s
    ///   `Hashable`/`Equatable` (visualState + streamMetadata + currentLanguage).
    /// - After a real `Activity.update`, memory is re-seeded from the activity’s
    ///   `content.state` (system-observed), not from an unverified aspirational candidate.
    /// - Optimistic intent paths may advance this without system acceptance; suppress
    ///   still forces a push when `currentActivity?.content.state.currentLanguage`
    ///   differs from the candidate language.
    /// - Never persisted as a snapshot. Widgets continue to use `PersistedWidgetState`.
    ///   Durable LA visual/language App Group mirrors are separate cross-process signals.
    ///
    /// Exposed as `internal private(set)` for white-box testing of the change-detection
    /// behavior (parallel to `updateTimer`).
    /// - SeeAlso: ``updateCurrentActivity()``, ``ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``handleActivityContentUpdate(_:)``, docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    internal private(set) var lastPushedContent: LutheranRadioLiveActivityAttributes.ContentState?

    /// Consecutive real `Activity.update` completions where system-held content still
    /// mismatches the submitted candidate (language and/or stuck pause / Connecting visual).
    ///
    /// Reset when system-held chrome matches the candidate, on `contentUpdates`, end paths,
    /// and when a recreation begins. Used only to decide bounded interactive recreation.
    /// - SeeAlso: ``isStalledLiveActivityContentPush(candidate:accepted:)``,
    ///   ``shouldRecreateInteractiveLiveActivityAfterStalledPushes(consecutiveStalled:recreationsAttempted:threshold:maxRecreations:isRecreationInProgress:)``.
    private var consecutiveStalledContentPushes = 0

    /// How many times this process has recreated the interactive Live Activity because
    /// system-held ContentState lagged the candidate. Reset when a push advances chrome.
    private var interactiveContentRecreationsAttempted = 0

    /// Re-entrancy guard while ``recreateInteractiveLiveActivityAfterStalledContent()`` runs
    /// (end + start must not schedule nested recreation from the nested initial push).
    /// While true, non-essential content pushes are skipped so concurrent updates do not
    /// target a dying activity id.
    private var isRecreatingLiveActivityAfterStalledContent = false

    /// When true, the next eligible foreground cycle should request an interactive Live
    /// Activity if session policy still needs one and none is owned.
    ///
    /// Set when:
    /// - Stalled-content recreation is deferred because `Activity.request` is not eligible, or
    /// - An interactive start attempt fails while `currentActivity` remains nil
    ///
    /// Cleared when an interactive activity is successfully owned, or when session teardown
    /// ends Live Activities without an in-flight recreation.
    ///
    /// - SeeAlso: ``ensureInteractiveLiveActivityIfNeeded()``, ``startActivity()``,
    ///   ``recreateInteractiveLiveActivityAfterStalledContent()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    private var pendingInteractiveLiveActivityEnsure = false

    /// Debounce stamp for ``ensureInteractiveLiveActivityIfNeeded()`` **missing-card start**
    /// so SceneDelegate dual foreground hooks do not double-request.
    private var lastInteractiveLiveActivityEnsureAt: Date?

    /// Minimum interval between ensure-start attempts (SceneDelegate dual hooks both fire).
    private static let interactiveLiveActivityEnsureDebounceInterval: TimeInterval = 1.0

    /// Debounce stamp for **owned-surface** foreground soft language/playing ensure
    /// (``ensureAuthoritativeContentOnForegroundIfNeeded()`` via
    /// ``ensureInteractiveLiveActivityIfNeeded()``).
    ///
    /// Independent of the missing-card start stamp so a recent start attempt cannot block
    /// unlock soft-reconcile, and a recent soft ensure cannot block a missing-card start.
    private var lastOwnedSurfaceForegroundEnsureAt: Date?

    /// Minimum interval between owned-surface foreground soft-ensure cycles when there is
    /// nothing pending to consume (dual will-enter-foreground + become-active hooks, rapid
    /// resign/become thrash). Quiet pending, interactive pending ensure, or chrome still
    /// lagging while request-eligible force a re-invoke inside the window.
    ///
    /// - SeeAlso: ``shouldInvokeOwnedSurfaceForegroundEnsure(hasCurrentActivity:lastOwnedSurfaceForegroundEnsureAt:now:debounceInterval:languageEnsureQuietPending:playingEnsureQuietPending:pendingInteractiveLiveActivityEnsure:contentEnsureStillNeeded:isRequestEligible:)``.
    static let ownedSurfaceForegroundEnsureDebounceInterval: TimeInterval = 1.0

    /// Consecutive stalled updates required before end + ``startActivity()`` recreation.
    ///
    /// Allows brief lag (system still holding prior language for one or two frames) without
    /// thrashing; real freezes after pause/stream-switch exceed this quickly.
    static let stalledContentPushRecreationThreshold = 3

    /// Cap on interactive recreation per healthy match cycle (avoids end/start loops).
    static let maxInteractiveContentRecreations = 2

    /// Maximum soft pushes from ``ensureAuthoritativePlayingContentIfNeeded()`` while owned
    /// visual still lags authoritative `.playing` (ActivityKit acceptance lag after soft-resume
    /// or stream-switch audible start). Prefer this over end+request for visual-only freezes.
    ///
    /// After this budget is exhausted while interactive request is **ineligible**, playing
    /// soft-ensure enters quiet pending (``playingEnsureQuietPending``) so status-driven
    /// media-surface refreshes do not re-burn the soft-retry budget until re-arm
    /// (authoritative play mutation, optimistic toggle / stream-switch, eligibility,
    /// become-active, or system `contentUpdates` acceptance).
    ///
    /// - SeeAlso: ``ensureAuthoritativePlayingContentIfNeeded()``,
    ///   ``shouldRunPlayingContentEnsureSoftPushes(needsPlayingEnsure:quietPending:isRequestEligible:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static let authoritativePlayingContentEnsureMaxAttempts = 3

    /// Maximum soft pushes from ``ensureAuthoritativeLanguageContentIfNeeded()`` while owned
    /// `content.state.currentLanguage` still lags ``liveActivityLanguageCodeForContentPush()``
    /// (ActivityKit acceptance lag after stream-switch / deferred recreation while ineligible).
    /// Prefer this over end+request; eligible-only recreation is a last resort on foreground.
    ///
    /// After this budget is exhausted while interactive request is **ineligible**, language
    /// soft-ensure enters a quiet-pending state for that destination (see
    /// ``languageEnsureQuietPendingDestination``) so status-driven media-surface refreshes
    /// do not re-run the soft-retry budget until re-arm (destination change, eligibility,
    /// become-active, or system `contentUpdates` acceptance).
    ///
    /// - SeeAlso: ``ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``ensureAuthoritativeContentOnForegroundIfNeeded()``,
    ///   ``shouldRunLanguageContentEnsureSoftPushes(needsLanguageEnsure:destinationLanguage:quietPendingDestination:isRequestEligible:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static let authoritativeLanguageContentEnsureMaxAttempts = 3

    /// Destination language for which soft language ensure exhausted while interactive request
    /// was ineligible.
    ///
    /// When non-nil and equal to the current destination, further ensure-driven soft pushes and
    /// **language-only** status re-pushes stay quiet until re-arm:
    /// - Destination language changes (new stream-switch mutation)
    /// - Interactive request becomes eligible
    /// - Foreground / become-active owned-surface soft ensure
    /// - System `contentUpdates` yield (acceptance moment)
    /// - Owned language converges to destination
    ///
    /// Visual mutations (pause / play / Connecting) still push when owned visual differs —
    /// quiet is language-stall thrash protection only, not a full content freeze.
    ///
    /// - SeeAlso: ``ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``shouldRunLanguageContentEnsureSoftPushes(needsLanguageEnsure:destinationLanguage:quietPendingDestination:isRequestEligible:)``,
    ///   ``shouldDeferRedundantLanguagePushWhileQuiet(candidateLanguage:ownedContentLanguage:ownedContentVisual:candidateVisual:quietPendingDestination:isRequestEligible:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    private var languageEnsureQuietPendingDestination: String?

    /// Whether soft playing ensure exhausted while interactive request was ineligible and
    /// owned visual still lagged authoritative `.playing`.
    ///
    /// When true, further ensure-driven soft pushes and **visual-only** status re-pushes that
    /// only repair candidate `.playing` stay quiet until re-arm:
    /// - Authoritative play mutation (``setPlaying`` / soft-resume ensure re-arm)
    /// - Optimistic toggle or stream-switch ContentState (new control cycle)
    /// - Interactive request becomes eligible
    /// - Foreground / become-active owned-surface soft ensure
    /// - System `contentUpdates` yield (acceptance moment)
    /// - Owned visual converges to `.playing`
    ///
    /// Pause (``.userPaused``) and language mutations still push — quiet is playing-stall
    /// thrash protection only, not a full content freeze. Does **not** invent `.playing`
    /// during stream-switch hold / connecting.
    ///
    /// - SeeAlso: ``ensureAuthoritativePlayingContentIfNeeded()``,
    ///   ``shouldRunPlayingContentEnsureSoftPushes(needsPlayingEnsure:quietPending:isRequestEligible:)``,
    ///   ``shouldDeferRedundantPlayingPushWhileQuiet(candidateVisual:ownedContentVisual:ownedContentLanguage:candidateLanguage:quietPending:isRequestEligible:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    private var playingEnsureQuietPending = false

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
    /// - Postcondition: If successful (non-test), `currentActivity` is non-nil and initial
    ///   content uses the current `PlayerVisualState` SSOT. On request failure with no owned
    ///   activity, ``pendingInteractiveLiveActivityEnsure`` is set for foreground recovery.
    /// - Important: Only call from main-app code (never widget extension). The caller is
    ///   responsible for ensuring we are allowed to show an activity (usually right after
    ///   a `.playing` transition). Prefer ``ensureInteractiveLiveActivityIfNeeded()`` on
    ///   foreground when recovering after a visibility-class request failure.
    /// - Note: The test short-circuit here is the companion to the identical guard
    ///   in `observeExistingActivities()`. It is what made the prior partial fix
    ///   (commit 2af37cf) insufficient.
    /// - SeeAlso: `updateCurrentActivity()`, `SharedPlayerManager.setPlaying`,
    ///   ``ensureInteractiveLiveActivityIfNeeded()``,
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
            // User/system disabled: no recoverable request path.
            pendingInteractiveLiveActivityEnsure = false
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
            pendingInteractiveLiveActivityEnsure = false
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
            // Request failed after local end: re-bind if the system still holds a surface,
            // otherwise mark pending ensure so the next eligible foreground cycle can recover.
            await recoverAfterFailedInteractiveLiveActivityRequest()
        }
    }

    /// After a failed `Activity.request`, re-bind a system-held activity if present; else mark
    /// pending ensure for the next eligible foreground cycle.
    ///
    /// - Postcondition: Either `currentActivity` is non-nil (re-bound) or
    ///   ``pendingInteractiveLiveActivityEnsure`` is true when no surface is owned.
    /// - SeeAlso: ``startActivity()``, ``ensureInteractiveLiveActivityIfNeeded()``.
    private func recoverAfterFailedInteractiveLiveActivityRequest() async {
        // Prefer re-bind over a permanent blank surface (request may fail while system
        // still holds a residual interactive for this attribute type).
        if let existing = Activity<LutheranRadioLiveActivityAttributes>.activities.first {
            currentActivity = existing
            pendingInteractiveLiveActivityEnsure = false
            beginObservingActivityEvents(existing)
            await updateCurrentActivity()
            #if DEBUG
            print("🔴 Live Activity re-bound after failed request id=\(existing.id)")
            #endif
            return
        }
        if Self.shouldMarkPendingInteractiveLiveActivityEnsureAfterStartAttempt(
            currentActivityIsNil: currentActivity == nil
        ) {
            pendingInteractiveLiveActivityEnsure = true
            #if DEBUG
            print("🔴 Live Activity pending ensure after failed request (no owned surface)")
            #endif
        }
    }

    /// Pushes the latest `PlayerVisualState` + metadata + stream language into the active
    /// Live Activity, **but only when suppress policy allows**.
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
    /// **Suppress + owned language/visual:** Deduplication uses
    /// ``shouldSuppressLiveActivityContentPush(lastPushed:candidate:ownedContentLanguage:ownedContentVisual:)``.
    /// Owned `content.state.currentLanguage` and `content.state.visualState` beat optimistic
    /// ``lastPushedContent`` so a failed or aspirational push cannot stick the lock-screen
    /// flag or control glyph on prior chrome.
    ///
    /// **Post-update suppress memory:** After `Activity.update`, ``lastPushedContent`` is
    /// re-seeded from the activity’s observed `content.state` (not an unverified aspirational
    /// candidate). Language still mismatched → suppress memory keeps the system-held language
    /// so a further non-suppressed push remains eligible. Visual acceptance lag likewise leaves
    /// suppress memory on system-held visual.
    ///
    /// **Stalled system-held chrome recreation:** When system-held language or visual (pause or
    /// Connecting while the candidate needs Connecting/playing/pause) still mismatches after
    /// the await for a bounded streak, recreation is considered. End + request runs **only when**
    /// interactive `Activity.request` is eligible (activities enabled + application active). When
    /// ineligible, the existing activity is kept and a pending ensure is recorded.
    /// Soft retries (playing ensure) are preferred for pure visual freezes; destroying the only
    /// card under a visibility failure is worse than a stalled glyph.
    ///
    /// - Precondition: Must be called on the main actor (the method is `@MainActor`).
    /// - Postcondition: If an update is sent, `lastPushedContent` reflects the
    ///   system-observed `content.state` after the await. Durable visual + language App Group
    ///   mirrors are warmed even when ActivityKit IPC is suppressed. After stalled-push recreation threshold,
    ///   interactive activity may be recreated once per healthy match cycle (capped) when eligible.
    /// - Note: Silently no-ops if no activity is active or recreation is in progress.
    /// - Important: Uses `nonisolated(unsafe)` + `unsafe` because `Activity.update` is
    ///   not Sendable in the current SDK; the capture of the Activity is done only after
    ///   we hold a strong local reference on the main actor.
    ///
    /// - SeeAlso: `startActivity()`, ``ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``ensureAuthoritativePlayingContentIfNeeded()``,
    ///   ``recreateInteractiveLiveActivityAfterStalledContent()``,
    ///   `SharedPlayerManager.setPlaying`,
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

        // While end+start recreation owns the lifecycle, skip concurrent content pushes so
        // they do not target a dying activity id or race the replacement request.
        if isRecreatingLiveActivityAfterStalledContent {
            return
        }

        guard let activity = currentActivity else { return }
        
        let manager = SharedPlayerManager.shared
        
        // Prefer the live in-memory values (decoupled path). Persisted is only fallback
        // so that an early push before the first mutation still has something reasonable.
        // This is the key separation: LA does not *require* a PersistedWidgetState write.
        //
        // Metadata + language first (await hops). Visual/hold/connecting are sampled **last**
        // so a concurrent ``setPlaying()`` cannot be overwritten by a stale Connecting publish
        // (yellow lock-screen chrome stuck while audio is already playing — stream-switch
        // optimistic prePlay + fire-and-forget performActualSave LA refresh race).
        let streamMetadata = await manager.currentStreamMetadata
            ?? SharedPlayerManager.loadPersistedStreamMetadata()
        // Hold-time target language advances with Connecting so the card never shows the
        // prior stream’s flag/name for one content push while the engine model is still old.
        let currentLanguage = await manager.liveActivityLanguageCodeForContentPush()

        // Authoritative visual at push time — after all prior suspension points.
        let visualState = await Self.resolveContentPushVisual(from: manager)
        
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

        // Owned surface language + visual beat optimistic suppress memory (flag + glyph SSOT).
        let ownedLanguage = activity.content.state.currentLanguage
        let ownedVisual = activity.content.state.visualState
        if Self.shouldSuppressLiveActivityContentPush(
            lastPushed: lastPushedContent,
            candidate: candidate,
            ownedContentLanguage: ownedLanguage,
            ownedContentVisual: ownedVisual
        ) {
            #if DEBUG
            print(
                "🔴 Live Activity update suppressed (content unchanged; owned language=\(ownedLanguage) " +
                "owned visual=\(ownedVisual))"
            )
            #endif
            return
        }

        // After language soft-ensure exhausted while request is ineligible, defer language-only
        // status re-pushes for the same destination. Durable mirrors already warmed above.
        // Visual mutations still push. Re-arm: destination change, eligibility, become-active,
        // or contentUpdates (see languageEnsureQuietPendingDestination).
        let requestEligibleForQuiet = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: ActivityAuthorizationInfo().areActivitiesEnabled,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        if Self.shouldDeferRedundantLanguagePushWhileQuiet(
            candidateLanguage: candidate.currentLanguage,
            ownedContentLanguage: ownedLanguage,
            ownedContentVisual: ownedVisual,
            candidateVisual: candidate.visualState,
            quietPendingDestination: languageEnsureQuietPendingDestination,
            isRequestEligible: requestEligibleForQuiet
        ) {
            #if DEBUG
            print(
                "🔴 Live Activity language push deferred (quiet pending destination=" +
                "\(languageEnsureQuietPendingDestination ?? "nil"); owned language=\(ownedLanguage); " +
                "keeping surface; wait for eligibility, become-active, or language mutation)"
            )
            #endif
            return
        }

        // After playing soft-ensure exhausted while request is ineligible, defer visual-only
        // status re-pushes that only repair candidate `.playing`. Durable mirrors already warm.
        // Pause (userPaused) and language mutations still push. Re-arm: authoritative play,
        // optimistic toggle/switch, eligibility, become-active, or contentUpdates.
        if Self.shouldDeferRedundantPlayingPushWhileQuiet(
            candidateVisual: candidate.visualState,
            ownedContentVisual: ownedVisual,
            ownedContentLanguage: ownedLanguage,
            candidateLanguage: candidate.currentLanguage,
            quietPending: playingEnsureQuietPending,
            isRequestEligible: requestEligibleForQuiet
        ) {
            #if DEBUG
            print(
                "🔴 Live Activity playing visual push deferred (quiet pending; owned visual=" +
                "\(ownedVisual); keeping surface; wait for eligibility, become-active, or play mutation)"
            )
            #endif
            return
        }

        // SAFETY: Activity.update / Activity property access are not Sendable in the current
        // SDK; capture a local strong reference on the main actor, then read content/id only
        // under explicit `unsafe` (same capture pattern as end paths).
        nonisolated(unsafe) let safeActivity = activity
        unsafe await safeActivity.update(.init(state: candidate, staleDate: nil))

        // Suppress memory from system-observed content, never unverified aspirational candidate.
        // SAFETY: `content.state` / `id` on the nonisolated(unsafe) Activity capture require
        // an `unsafe` expression under SWIFT_STRICT_MEMORY_SAFETY.
        let accepted = unsafe safeActivity.content.state
        lastPushedContent = Self.suppressMemoryAfterActivityUpdate(
            candidate: candidate,
            acceptedSystemContent: accepted
        )

        // Owned language converged → clear language ensure quiet for this destination.
        if Self.shouldClearLanguageEnsureQuietPending(
            quietPendingDestination: languageEnsureQuietPendingDestination,
            destinationLanguage: candidate.currentLanguage,
            ownedOrSystemLanguage: accepted.currentLanguage
        ) {
            languageEnsureQuietPendingDestination = nil
        }
        // Owned visual converged to playing → clear playing ensure quiet.
        if Self.shouldClearPlayingEnsureQuietPending(
            quietPending: playingEnsureQuietPending,
            ownedOrSystemVisual: accepted.visualState
        ) {
            playingEnsureQuietPending = false
        }

        let contentStalled = Self.isStalledLiveActivityContentPush(
            candidate: candidate,
            accepted: accepted
        )
        if contentStalled {
            consecutiveStalledContentPushes += 1
        } else {
            // Healthy surface — clear recreation budget so a later freeze can recreate again.
            consecutiveStalledContentPushes = 0
            interactiveContentRecreationsAttempted = 0
        }

        #if DEBUG
        // SAFETY: Activity.id on the nonisolated(unsafe) capture (DEBUG diagnostics only).
        let activityId = unsafe safeActivity.id
        print(
            "🔴 Live Activity update: id=\(activityId) candidateLang=\(candidate.currentLanguage) " +
            "contentStateLang=\(accepted.currentLanguage) visual=\(accepted.visualState) " +
            "candidateVisual=\(candidate.visualState)"
        )
        if !candidate.currentLanguage.isEmpty,
           accepted.currentLanguage != candidate.currentLanguage {
            print(
                "🔴 Live Activity language not yet on surface (candidate=\(candidate.currentLanguage) " +
                "content.state=\(accepted.currentLanguage)); suppress memory kept system-held language"
            )
        } else if Self.isStalledLiveActivityContentPush(candidate: candidate, accepted: accepted),
                  accepted.visualState != candidate.visualState {
            print(
                "🔴 Live Activity visual not yet on surface (candidate=\(candidate.visualState) " +
                "content.state=\(accepted.visualState)); suppress memory kept system-held visual"
            )
        }
        #endif

        let requestEligible = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: ActivityAuthorizationInfo().areActivitiesEnabled,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        if Self.shouldPerformStalledContentRecreation(
            consecutiveStalled: consecutiveStalledContentPushes,
            recreationsAttempted: interactiveContentRecreationsAttempted,
            isRecreationInProgress: isRecreatingLiveActivityAfterStalledContent,
            isRequestEligible: requestEligible,
            threshold: Self.stalledContentPushRecreationThreshold,
            maxRecreations: Self.maxInteractiveContentRecreations
        ) {
            await recreateInteractiveLiveActivityAfterStalledContent()
        } else if Self.shouldRecreateInteractiveLiveActivityAfterStalledPushes(
            consecutiveStalled: consecutiveStalledContentPushes,
            recreationsAttempted: interactiveContentRecreationsAttempted,
            threshold: Self.stalledContentPushRecreationThreshold,
            maxRecreations: Self.maxInteractiveContentRecreations,
            isRecreationInProgress: isRecreatingLiveActivityAfterStalledContent
        ), !requestEligible {
            // Streak/cap would recreate, but request is not eligible — keep the existing
            // interactive surface and recover on the next eligible foreground cycle.
            pendingInteractiveLiveActivityEnsure = true
            #if DEBUG
            print(
                "🔴 Live Activity recreation deferred — interactive request not eligible " +
                "(keeping existing surface; pending ensure recorded)"
            )
            #endif
        }
    }

    /// Whether a completed `Activity.update` left the system surface on prior chrome.
    ///
    /// Counts as stalled (system-held chrome still lags) when:
    /// - Candidate language is non-empty and differs from system-held language (flag/name stall), or
    /// - System still shows `.userPaused` while the candidate needs `.prePlay` (Connecting) or
    ///   `.playing` (soft-resume / stream-switch attach honesty after pause), or
    /// - System still shows `.prePlay` (Connecting) while the candidate is authoritative
    ///   `.playing` (soft-resume / post-audible visual freeze — pure visual lag without language mismatch), or
    /// - System still shows `.prePlay` while the candidate is intentional `.userPaused`
    ///   (pause push never accepted; soft-resume then inherits a stuck Connecting glyph).
    ///
    /// Intentional Connecting match (candidate `.prePlay` while hold/connect forces Connecting)
    /// is **not** stalled — both sides agree on Connecting.
    ///
    /// - Parameters:
    ///   - candidate: Content submitted to ActivityKit.
    ///   - accepted: Re-read `activity.content.state` after the update await.
    /// - Returns: `true` when the push should increment the stalled-push streak.
    /// - SeeAlso: ``updateCurrentActivity()``, ``ensureAuthoritativePlayingContentIfNeeded()``,
    ///   ``shouldRecreateInteractiveLiveActivityAfterStalledPushes(consecutiveStalled:recreationsAttempted:threshold:maxRecreations:isRecreationInProgress:)``.
    static func isStalledLiveActivityContentPush(
        candidate: LutheranRadioLiveActivityAttributes.ContentState,
        accepted: LutheranRadioLiveActivityAttributes.ContentState
    ) -> Bool {
        if !candidate.currentLanguage.isEmpty,
           accepted.currentLanguage != candidate.currentLanguage {
            return true
        }
        // Soft-resume freeze: pause content never leaves the surface while audio plays / Connecting attaches.
        if accepted.visualState == .userPaused,
           candidate.visualState == .playing || candidate.visualState == .prePlay {
            return true
        }
        // Pure visual freeze: system still shows Connecting while candidate is authoritative playing.
        // Prefer soft playing-ensure retries; recreation remains gated by eligibility + streak/cap.
        if accepted.visualState == .prePlay, candidate.visualState == .playing {
            return true
        }
        // Pause honesty: system still Connecting while candidate is intentional user pause.
        if accepted.visualState == .prePlay, candidate.visualState == .userPaused {
            return true
        }
        return false
    }

    /// Whether soft retries should yield to interactive activity recreation (streak/cap only).
    ///
    /// Does **not** encode request eligibility — callers must also consult
    /// ``isInteractiveLiveActivityRequestEligible(areActivitiesEnabled:isApplicationActive:)``
    /// via ``shouldPerformStalledContentRecreation(consecutiveStalled:recreationsAttempted:isRecreationInProgress:isRequestEligible:threshold:maxRecreations:)``
    /// before ending the only interactive surface.
    ///
    /// - Parameters:
    ///   - consecutiveStalled: Streak of stalled pushes since system-held chrome last matched.
    ///   - recreationsAttempted: Recreations already performed this healthy match cycle.
    ///   - threshold: Minimum streak before recreation (production:
    ///     ``stalledContentPushRecreationThreshold``).
    ///   - maxRecreations: Cap per healthy match cycle (production:
    ///     ``maxInteractiveContentRecreations``).
    ///   - isRecreationInProgress: Nested push during end+start must not schedule recreation again.
    /// - Returns: `true` when stalled-push bookkeeping alone would schedule recreation.
    /// - SeeAlso: ``shouldPerformStalledContentRecreation(consecutiveStalled:recreationsAttempted:isRecreationInProgress:isRequestEligible:threshold:maxRecreations:)``,
    ///   ``updateCurrentActivity()``, docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldRecreateInteractiveLiveActivityAfterStalledPushes(
        consecutiveStalled: Int,
        recreationsAttempted: Int,
        threshold: Int = RadioLiveActivityManager.stalledContentPushRecreationThreshold,
        maxRecreations: Int = RadioLiveActivityManager.maxInteractiveContentRecreations,
        isRecreationInProgress: Bool
    ) -> Bool {
        guard !isRecreationInProgress else { return false }
        guard consecutiveStalled >= threshold else { return false }
        guard recreationsAttempted < maxRecreations else { return false }
        return true
    }

    /// Whether an interactive `Activity.request` is eligible for this process right now.
    ///
    /// End + request recreation must not run when this returns `false`: destroying the only
    /// interactive Live Activity under lock-screen / background **visibility** constraints
    /// leaves the user with audio-only chrome until a later foreground path succeeds.
    ///
    /// - Parameters:
    ///   - areActivitiesEnabled: `ActivityAuthorizationInfo().areActivitiesEnabled`.
    ///   - isApplicationActive: `UIApplication.shared.applicationState == .active` (presentable
    ///     for a replacement interactive request; inactive/background is not).
    /// - Returns: `true` when both Live Activities are enabled and the app is active.
    /// - SeeAlso: ``shouldPerformStalledContentRecreation(consecutiveStalled:recreationsAttempted:isRecreationInProgress:isRequestEligible:threshold:maxRecreations:)``,
    ///   ``recreateInteractiveLiveActivityAfterStalledContent()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func isInteractiveLiveActivityRequestEligible(
        areActivitiesEnabled: Bool,
        isApplicationActive: Bool
    ) -> Bool {
        areActivitiesEnabled && isApplicationActive
    }

    /// Full decision for end + request recreation: streak/cap **and** request eligibility.
    ///
    /// - Parameters:
    ///   - consecutiveStalled: Stalled-push streak.
    ///   - recreationsAttempted: Recreations already performed this healthy match cycle.
    ///   - isRecreationInProgress: Nested push guard.
    ///   - isRequestEligible: ``isInteractiveLiveActivityRequestEligible(areActivitiesEnabled:isApplicationActive:)``.
    ///   - threshold: Production ``stalledContentPushRecreationThreshold``.
    ///   - maxRecreations: Production ``maxInteractiveContentRecreations``.
    /// - Returns: `true` only when bookkeeping would recreate **and** a replacement request
    ///   is eligible (never end the only interactive surface when start cannot succeed).
    /// - SeeAlso: ``recreateInteractiveLiveActivityAfterStalledContent()``,
    ///   ``shouldRecreateInteractiveLiveActivityAfterStalledPushes(consecutiveStalled:recreationsAttempted:threshold:maxRecreations:isRecreationInProgress:)``.
    static func shouldPerformStalledContentRecreation(
        consecutiveStalled: Int,
        recreationsAttempted: Int,
        isRecreationInProgress: Bool,
        isRequestEligible: Bool,
        threshold: Int = RadioLiveActivityManager.stalledContentPushRecreationThreshold,
        maxRecreations: Int = RadioLiveActivityManager.maxInteractiveContentRecreations
    ) -> Bool {
        guard isRequestEligible else { return false }
        return shouldRecreateInteractiveLiveActivityAfterStalledPushes(
            consecutiveStalled: consecutiveStalled,
            recreationsAttempted: recreationsAttempted,
            threshold: threshold,
            maxRecreations: maxRecreations,
            isRecreationInProgress: isRecreationInProgress
        )
    }

    /// Whether a failed interactive start should record a pending foreground ensure.
    ///
    /// - Parameter currentActivityIsNil: Whether ownership is empty after the attempt.
    /// - Returns: `true` when no interactive activity is owned (recoverable absence).
    /// - SeeAlso: ``startActivity()``, ``ensureInteractiveLiveActivityIfNeeded()``.
    static func shouldMarkPendingInteractiveLiveActivityEnsureAfterStartAttempt(
        currentActivityIsNil: Bool
    ) -> Bool {
        currentActivityIsNil
    }

    /// Whether foreground ensure should request an interactive Live Activity.
    ///
    /// - Parameters:
    ///   - pendingEnsure: ``pendingInteractiveLiveActivityEnsure`` after a deferred recreation
    ///     or failed request.
    ///   - hasCurrentActivity: Whether this process already owns an interactive activity.
    ///   - sessionNeedsInteractiveLiveActivity: Playback session still needs LA chrome
    ///     (authoritative playing / Connecting / sticky pause with live session — see
    ///     ``sessionNeedsInteractiveLiveActivity(isPlaying:visualState:)``).
    ///   - areActivitiesEnabled: User/system Live Activities enabled.
    ///   - isRequestEligible: Application is active (presentable for `Activity.request`).
    /// - Returns: `true` when start should run once (no owned activity, enabled, eligible,
    ///   and either pending recovery or session still needs an interactive surface).
    /// - SeeAlso: ``ensureInteractiveLiveActivityIfNeeded()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldEnsureInteractiveLiveActivityStart(
        pendingEnsure: Bool,
        hasCurrentActivity: Bool,
        sessionNeedsInteractiveLiveActivity: Bool,
        areActivitiesEnabled: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        guard areActivitiesEnabled else { return false }
        guard isRequestEligible else { return false }
        guard !hasCurrentActivity else { return false }
        // Session must still need interactive chrome. Pending recovery alone after stop
        // must not invent a Live Activity (call sites clear pending when `sessionNeeds` is false).
        // Dual path once session needs chrome: deferred recovery (`pendingEnsure`) **or**
        // missing surface under active session (foreground correction without a prior flag).
        return sessionNeedsInteractiveLiveActivity
            && (pendingEnsure || !hasCurrentActivity)
    }

    /// Session policy for whether an interactive Live Activity is still meaningful.
    ///
    /// Matches background auto-start intent: authoritative playing, Connecting attach, or
    /// sticky pause while the main process still owns a live session (paused LA is intentional).
    ///
    /// - Parameters:
    ///   - isPlaying: Shared snapshot / App Group `isPlaying` (background auto-start input).
    ///   - visualState: In-memory ``PlayerVisualState``.
    /// - Returns: `true` when start/ensure should be considered for a missing activity.
    /// - SeeAlso: ``handleAppWillEnterBackground()``, ``ensureInteractiveLiveActivityIfNeeded()``.
    static func sessionNeedsInteractiveLiveActivity(
        isPlaying: Bool,
        visualState: PlayerVisualState
    ) -> Bool {
        if isPlaying { return true }
        if visualState.isActivelyPlaying { return true }
        if visualState == .prePlay { return true }
        if visualState == .userPaused { return true }
        return false
    }

    /// Ends the frozen interactive Live Activity and requests a fresh one with current
    /// language chrome + visual (destination stamp / attach language via
    /// ``SharedPlayerManager/liveActivityLanguageCodeForContentPush()``).
    ///
    /// **Why recreation:** Device captures show ActivityKit can stop applying
    /// `Activity.update` on an interactive id after pause while audio and widgets advance.
    /// Soft reconcile cannot change a system surface that never advances ContentState; a new
    /// `Activity.request` re-seeds flag/name/control chrome.
    ///
    /// **Eligibility gate:** Must not run when ``isInteractiveLiveActivityRequestEligible`` is
    /// false — callers gate via ``shouldPerformStalledContentRecreation``; this method
    /// re-checks and defers (keeps existing surface + pending ensure) if still ineligible.
    ///
    /// - Precondition: Main actor; not already inside recreation; test isolation short-circuits
    ///   via ``endActivityAsync`` / ``startActivity()`` guards.
    /// - Postcondition: When eligible: recreation attempt counted; stalled streak cleared;
    ///   either a new interactive activity exists or start failure left pending ensure.
    ///   When ineligible: existing activity retained; pending ensure set; recreation budget
    ///   not consumed.
    /// - Important: Does **not** invent `.playing` — initial ContentState comes from actor
    ///   visual + language SSOT (Connecting remains honest during stream-switch hold).
    /// - SeeAlso: ``updateCurrentActivity()``, ``startActivity()``, ``endActivityAsync(dismissalPolicy:)``,
    ///   ``ensureInteractiveLiveActivityIfNeeded()``,
    ///   ``isInteractiveLiveActivityRequestEligible(areActivitiesEnabled:isApplicationActive:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    @MainActor
    func recreateInteractiveLiveActivityAfterStalledContent() async {
        if SharedPlayerManager.isRunningInUITestMode { return }
        #if DEBUG
        if isRunningUnderTest { return }
        #endif
        guard !isRecreatingLiveActivityAfterStalledContent else { return }

        let requestEligible = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: ActivityAuthorizationInfo().areActivitiesEnabled,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        guard requestEligible else {
            // Defense-in-depth: never end the only interactive surface when request cannot
            // succeed (lock / background visibility). Soft retries + pending ensure remain.
            pendingInteractiveLiveActivityEnsure = true
            #if DEBUG
            print(
                "🔴 Live Activity recreation skipped — interactive request not eligible " +
                "(keeping existing surface; pending ensure recorded)"
            )
            #endif
            return
        }

        isRecreatingLiveActivityAfterStalledContent = true
        interactiveContentRecreationsAttempted += 1
        consecutiveStalledContentPushes = 0
        defer { isRecreatingLiveActivityAfterStalledContent = false }

        #if DEBUG
        print(
            "🔴 Live Activity recreating interactive surface after stalled system-held chrome " +
            "(recreation #\(interactiveContentRecreationsAttempted))"
        )
        #endif

        // Immediate dismissal so the frozen prior-language / pause frame does not linger
        // beside the replacement card. Safe only because request eligibility was verified.
        await endActivityAsync(dismissalPolicy: .immediate)
        await startActivity()
        // startActivity sets pending ensure on failure / clears it on success.
    }

    /// Whether ActivityKit IPC should be skipped for this candidate.
    ///
    /// Suppress is an optimization: never skip when the owned surface still disagrees with
    /// the candidate on **language** or **visual**, even if in-process ``lastPushedContent``
    /// already equals the candidate (optimistic stream-switch / toggle alignment or a push
    /// that did not change the visible surface).
    ///
    /// - Parameters:
    ///   - lastPushed: In-process suppress memory (may be optimistically advanced).
    ///   - candidate: Freshly built ContentState for this push.
    ///   - ownedContentLanguage: Owned `Activity.content.state.currentLanguage` when an
    ///     interactive activity is tracked; pass `nil` only when unowned (language gate skipped).
    ///   - ownedContentVisual: Owned `Activity.content.state.visualState` when tracked;
    ///     pass `nil` only when unowned (visual gate skipped).
    /// - Returns: `true` when the push would be a no-op against suppress memory **and**
    ///   owned language + visual chrome.
    /// - SeeAlso: ``updateCurrentActivity()``, ``ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``ensureAuthoritativePlayingContentIfNeeded()``,
    ///   ``_test_wouldSuppressLiveActivityUpdate(visualState:streamMetadata:currentLanguage:ownedContentLanguage:ownedContentVisual:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldSuppressLiveActivityContentPush(
        lastPushed: LutheranRadioLiveActivityAttributes.ContentState?,
        candidate: LutheranRadioLiveActivityAttributes.ContentState,
        ownedContentLanguage: String?,
        ownedContentVisual: PlayerVisualState? = nil
    ) -> Bool {
        // Language is the hard requirement for lock-screen flag/name/alt-current chrome.
        if !candidate.currentLanguage.isEmpty,
           let owned = ownedContentLanguage,
           owned != candidate.currentLanguage {
            return false
        }
        // Control glyph SSOT: optimistic lastPushed must not claim playing/pause while
        // the system-held surface still shows Connecting (or the reverse).
        if let ownedVisual = ownedContentVisual,
           ownedVisual != candidate.visualState {
            return false
        }
        if let last = lastPushed, last == candidate {
            return true
        }
        return false
    }

    /// Chooses suppress-memory ContentState after a real `Activity.update` await.
    ///
    /// Never claims the candidate language when the system-held `content.state` still
    /// reports a different language (failed acceptance, stale handle, silent no-op).
    ///
    /// - Parameters:
    ///   - candidate: Content that was submitted to ActivityKit.
    ///   - acceptedSystemContent: Re-read `activity.content.state` after the update await.
    /// - Returns: Value to store in ``lastPushedContent``.
    /// - SeeAlso: ``updateCurrentActivity()``, ``shouldSuppressLiveActivityContentPush(lastPushed:candidate:ownedContentLanguage:)``.
    static func suppressMemoryAfterActivityUpdate(
        candidate: LutheranRadioLiveActivityAttributes.ContentState,
        acceptedSystemContent: LutheranRadioLiveActivityAttributes.ContentState
    ) -> LutheranRadioLiveActivityAttributes.ContentState {
        if !candidate.currentLanguage.isEmpty,
           acceptedSystemContent.currentLanguage != candidate.currentLanguage {
            return acceptedSystemContent
        }
        // Prefer system-observed full tuple when language matched (or candidate language empty).
        return acceptedSystemContent
    }

    /// Whether a language reconcile push is needed for an interactive Live Activity.
    ///
    /// - Parameters:
    ///   - destinationLanguage: ``SharedPlayerManager/liveActivityLanguageCodeForContentPush()``.
    ///   - ownedContentLanguage: Owned `content.state.currentLanguage`, if any.
    ///   - lastPushedLanguage: ``lastPushedContent`` language, if any.
    /// - Returns: `true` when destination is non-empty and either owned or last-pushed
    ///   language does not match (or is missing).
    /// - Note: Does not invent `.playing` — only decides whether language chrome needs a push.
    /// - SeeAlso: ``ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``shouldRunLanguageContentEnsureSoftPushes(needsLanguageEnsure:destinationLanguage:quietPendingDestination:isRequestEligible:)``.
    static func shouldEnsureAuthoritativeLanguageContent(
        destinationLanguage: String,
        ownedContentLanguage: String?,
        lastPushedLanguage: String?
    ) -> Bool {
        guard !destinationLanguage.isEmpty else { return false }
        if ownedContentLanguage != destinationLanguage { return true }
        if lastPushedLanguage != destinationLanguage { return true }
        return false
    }

    /// Whether soft language-ensure pushes should run now, or stay quiet after budget exhaustion.
    ///
    /// After ``authoritativeLanguageContentEnsureMaxAttempts`` while request is ineligible,
    /// the manager records ``languageEnsureQuietPendingDestination``. Further ensure-driven
    /// soft pushes for the **same** destination stay quiet until re-arm so status-driven
    /// media-surface refreshes do not re-burn the soft-retry budget without acceptance.
    ///
    /// **Re-arm (returns true when language ensure is still needed):**
    /// - No quiet pending yet
    /// - Destination language changed (new stream-switch mutation — high-priority push)
    /// - Interactive request became eligible (presentable cycle / unlock)
    ///
    /// - Parameters:
    ///   - needsLanguageEnsure: ``shouldEnsureAuthoritativeLanguageContent(destinationLanguage:ownedContentLanguage:lastPushedLanguage:)``.
    ///   - destinationLanguage: Current ``liveActivityLanguageCodeForContentPush()``.
    ///   - quietPendingDestination: ``languageEnsureQuietPendingDestination`` (nil when not quiet).
    ///   - isRequestEligible: ``isInteractiveLiveActivityRequestEligible(areActivitiesEnabled:isApplicationActive:)``.
    /// - Returns: `true` when soft language pushes should run.
    /// - SeeAlso: ``ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``quietPendingDestinationAfterLanguageEnsureExhaustion(languageStillMismatches:isRequestEligible:destinationLanguage:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldRunLanguageContentEnsureSoftPushes(
        needsLanguageEnsure: Bool,
        destinationLanguage: String,
        quietPendingDestination: String?,
        isRequestEligible: Bool
    ) -> Bool {
        guard needsLanguageEnsure else { return false }
        guard !destinationLanguage.isEmpty else { return false }
        // Re-arm when request is eligible (unlock / presentable cycle).
        if isRequestEligible { return true }
        // Quiet only for the same destination while still ineligible.
        if let quiet = quietPendingDestination, quiet == destinationLanguage {
            return false
        }
        // No quiet yet, or destination changed → high-priority push for the new language.
        return true
    }

    /// Destination to store as quiet-pending after language soft-ensure budget exhaustion.
    ///
    /// - Parameters:
    ///   - languageStillMismatches: Owned / last language still ≠ destination after the last attempt.
    ///   - isRequestEligible: Whether interactive `Activity.request` could succeed now.
    ///   - destinationLanguage: Destination that failed acceptance.
    /// - Returns: `destinationLanguage` when quiet should engage; `nil` when request is eligible
    ///   (keep soft ensure available / let foreground recreation path own recovery) or language matched.
    /// - SeeAlso: ``shouldRunLanguageContentEnsureSoftPushes(needsLanguageEnsure:destinationLanguage:quietPendingDestination:isRequestEligible:)``.
    static func quietPendingDestinationAfterLanguageEnsureExhaustion(
        languageStillMismatches: Bool,
        isRequestEligible: Bool,
        destinationLanguage: String
    ) -> String? {
        guard languageStillMismatches else { return nil }
        guard !isRequestEligible else { return nil }
        guard !destinationLanguage.isEmpty else { return nil }
        return destinationLanguage
    }

    /// Whether a status-driven `Activity.update` that is only repairing language stall should
    /// defer while language ensure is quiet-pending for the same destination.
    ///
    /// Protects lock-stretch thrash: after soft language ensure exhausted while request is
    /// ineligible, every media-surface refresh would otherwise re-submit the same language
    /// candidate (owned-language suppress gate correctly denies suppress). Visual mutations
    /// still push — quiet is language-only.
    ///
    /// - Parameters:
    ///   - candidateLanguage: Candidate ``ContentState.currentLanguage``.
    ///   - ownedContentLanguage: Owned `content.state.currentLanguage`.
    ///   - ownedContentVisual: Owned `content.state.visualState`.
    ///   - candidateVisual: Candidate visual.
    ///   - quietPendingDestination: ``languageEnsureQuietPendingDestination``.
    ///   - isRequestEligible: Interactive request eligibility.
    /// - Returns: `true` when ActivityKit IPC should be skipped for this language-only stall.
    /// - SeeAlso: ``updateCurrentActivity()``, ``shouldRunLanguageContentEnsureSoftPushes(needsLanguageEnsure:destinationLanguage:quietPendingDestination:isRequestEligible:)``.
    static func shouldDeferRedundantLanguagePushWhileQuiet(
        candidateLanguage: String,
        ownedContentLanguage: String,
        ownedContentVisual: PlayerVisualState,
        candidateVisual: PlayerVisualState,
        quietPendingDestination: String?,
        isRequestEligible: Bool
    ) -> Bool {
        guard let quiet = quietPendingDestination else { return false }
        guard !isRequestEligible else { return false }
        guard quiet == candidateLanguage else { return false }
        // Visual still differs → push (pause honesty, playing ensure, Connecting hold).
        if ownedContentVisual != candidateVisual { return false }
        // Language already matches → not a language stall (suppress policy handles no-op).
        if ownedContentLanguage == candidateLanguage { return false }
        return true
    }

    /// Whether quiet-pending language ensure should clear after a system content yield or
    /// owned-language convergence.
    ///
    /// - Parameters:
    ///   - quietPendingDestination: Current quiet destination, if any.
    ///   - destinationLanguage: Current destination language code.
    ///   - ownedOrSystemLanguage: Owned or system-accepted `content.state.currentLanguage`.
    /// - Returns: `true` when quiet should clear (re-arm for a later lag, or destination advanced).
    /// - SeeAlso: ``handleActivityContentUpdate(_:)``, ``ensureAuthoritativeLanguageContentIfNeeded()``.
    static func shouldClearLanguageEnsureQuietPending(
        quietPendingDestination: String?,
        destinationLanguage: String,
        ownedOrSystemLanguage: String?
    ) -> Bool {
        guard quietPendingDestination != nil else { return false }
        // System / owned accepted destination — quiet work is done.
        if let ownedOrSystemLanguage, ownedOrSystemLanguage == destinationLanguage {
            return true
        }
        // Destination moved on — re-arm for the new language (caller also re-arms via
        // shouldRun when quiet != destination).
        if let quiet = quietPendingDestination, quiet != destinationLanguage {
            return true
        }
        return false
    }

    /// Whether soft playing-ensure pushes should run now, or stay quiet after budget exhaustion.
    ///
    /// After ``authoritativePlayingContentEnsureMaxAttempts`` while request is ineligible,
    /// the manager records ``playingEnsureQuietPending``. Further ensure-driven soft pushes
    /// stay quiet until re-arm so status-driven media-surface refreshes do not re-burn the
    /// soft-retry budget without acceptance.
    ///
    /// **Re-arm (returns true when playing ensure is still needed):**
    /// - No quiet pending yet
    /// - Interactive request became eligible (presentable cycle / unlock)
    /// - Caller cleared quiet before ensure (authoritative play mutation, optimistic toggle)
    ///
    /// - Parameters:
    ///   - needsPlayingEnsure: ``shouldEnsureAuthoritativePlayingContent(actorVisual:streamSwitchHold:isConnectingPlayback:lastPushedVisual:ownedVisual:)``.
    ///   - quietPending: ``playingEnsureQuietPending``.
    ///   - isRequestEligible: ``isInteractiveLiveActivityRequestEligible(areActivitiesEnabled:isApplicationActive:)``.
    /// - Returns: `true` when soft playing pushes should run.
    /// - SeeAlso: ``ensureAuthoritativePlayingContentIfNeeded()``,
    ///   ``shouldEnterPlayingEnsureQuietPending(playingStillStalled:isRequestEligible:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldRunPlayingContentEnsureSoftPushes(
        needsPlayingEnsure: Bool,
        quietPending: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        guard needsPlayingEnsure else { return false }
        // Re-arm when request is eligible (unlock / presentable cycle).
        if isRequestEligible { return true }
        // Quiet while still ineligible → stop thrash.
        if quietPending { return false }
        return true
    }

    /// Whether playing soft-ensure should enter quiet pending after budget exhaustion.
    ///
    /// - Parameters:
    ///   - playingStillStalled: Owned / last visual still lags authoritative `.playing`.
    ///   - isRequestEligible: Whether interactive `Activity.request` could succeed now.
    /// - Returns: `true` when quiet should engage (still stalled + request ineligible).
    /// - SeeAlso: ``shouldRunPlayingContentEnsureSoftPushes(needsPlayingEnsure:quietPending:isRequestEligible:)``.
    static func shouldEnterPlayingEnsureQuietPending(
        playingStillStalled: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        guard playingStillStalled else { return false }
        guard !isRequestEligible else { return false }
        return true
    }

    /// Whether a status-driven `Activity.update` that is only repairing a playing visual stall
    /// should defer while playing ensure is quiet-pending.
    ///
    /// Protects lock-stretch thrash: after soft playing ensure exhausted while request is
    /// ineligible, every media-surface refresh would otherwise re-submit the same `.playing`
    /// candidate (owned-visual suppress gate correctly denies suppress). Pause honesty
    /// (``.userPaused``) and language mutations still push — quiet is playing-visual-only.
    ///
    /// - Parameters:
    ///   - candidateVisual: Candidate ``ContentState.visualState``.
    ///   - ownedContentVisual: Owned `content.state.visualState`.
    ///   - ownedContentLanguage: Owned `content.state.currentLanguage`.
    ///   - candidateLanguage: Candidate language.
    ///   - quietPending: ``playingEnsureQuietPending``.
    ///   - isRequestEligible: Interactive request eligibility.
    /// - Returns: `true` when ActivityKit IPC should be skipped for this playing-visual stall.
    /// - SeeAlso: ``updateCurrentActivity()``, ``shouldRunPlayingContentEnsureSoftPushes(needsPlayingEnsure:quietPending:isRequestEligible:)``.
    static func shouldDeferRedundantPlayingPushWhileQuiet(
        candidateVisual: PlayerVisualState,
        ownedContentVisual: PlayerVisualState,
        ownedContentLanguage: String,
        candidateLanguage: String,
        quietPending: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        guard quietPending else { return false }
        guard !isRequestEligible else { return false }
        // Language still differs → push (language honesty + co-push both axes).
        if ownedContentLanguage != candidateLanguage { return false }
        // Visual already matches → not a visual stall (suppress policy handles no-op).
        if ownedContentVisual == candidateVisual { return false }
        // Pause honesty must still push even when owned was stuck Connecting.
        if candidateVisual == .userPaused { return false }
        // Only defer redundant playing-repair thrash (candidate .playing, owned lagging).
        guard candidateVisual == .playing else { return false }
        return true
    }

    /// Whether playing ensure quiet should clear after system content yield or owned convergence.
    ///
    /// - Parameters:
    ///   - quietPending: Current quiet flag.
    ///   - ownedOrSystemVisual: Owned or system-accepted `content.state.visualState`.
    /// - Returns: `true` when quiet should clear (owned visual reached `.playing`).
    /// - SeeAlso: ``handleActivityContentUpdate(_:)``, ``ensureAuthoritativePlayingContentIfNeeded()``.
    static func shouldClearPlayingEnsureQuietPending(
        quietPending: Bool,
        ownedOrSystemVisual: PlayerVisualState?
    ) -> Bool {
        guard quietPending else { return false }
        if ownedOrSystemVisual == .playing { return true }
        return false
    }

    /// Samples actor visual + stream-switch/connect gates into the ContentState visual for a push.
    ///
    /// Stream-switch hold / in-flight connect: never advertise `.playing` while the engine is
    /// tearing down or attaching. When hold is clear and the actor is already `.playing`,
    /// Connecting must not win (stale concurrent sampler safety).
    ///
    /// - Parameter manager: Main-app ``SharedPlayerManager`` instance.
    /// - Returns: Visual to encode in the next ActivityKit candidate.
    /// - SeeAlso: ``updateCurrentActivity()``, ``SharedPlayerManager/setPlaying()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    private static func resolveContentPushVisual(from manager: SharedPlayerManager) async -> PlayerVisualState {
        let visualState = await manager.currentVisualState
        let streamSwitchHold = await manager.isStreamSwitchPrePlayHoldActive
        let connecting = await manager.isConnectingPlayback
        return resolveContentPushVisual(
            visualState: visualState,
            streamSwitchHold: streamSwitchHold,
            isConnectingPlayback: connecting
        )
    }

    /// Pure ContentState visual policy for Live Activity pushes (testable without ActivityKit).
    ///
    /// - Parameters:
    ///   - visualState: Actor ``currentVisualState`` sample.
    ///   - streamSwitchHold: ``isStreamSwitchPrePlayHoldActive``.
    ///   - isConnectingPlayback: ``isConnectingPlayback`` (start pipeline without audible play).
    /// - Returns: `.prePlay` when hold/connect would lie about playing; otherwise `visualState`.
    /// - SeeAlso: ``updateCurrentActivity()``, ``_test_resolveContentPushVisual(visualState:streamSwitchHold:isConnectingPlayback:)``.
    static func resolveContentPushVisual(
        visualState: PlayerVisualState,
        streamSwitchHold: Bool,
        isConnectingPlayback: Bool
    ) -> PlayerVisualState {
        if (streamSwitchHold || isConnectingPlayback) && visualState == .playing {
            return .prePlay
        }
        return visualState
    }

    /// If the actor is authoritatively playing (no hold/connect) but suppress memory or owned
    /// content still shows Connecting (``.prePlay``) or sticky pause (``.userPaused``), push
    /// again so lock-screen chrome cannot stick after stream-switch deferred-setPlaying or
    /// soft-resume from pause.
    ///
    /// Performs up to ``authoritativePlayingContentEnsureMaxAttempts`` soft pushes, re-reading
    /// owned `content.state.visualState` after each ``updateCurrentActivity()``. Stops early when
    /// owned visual reaches `.playing`, the ensure gate clears, or the interactive activity
    /// disappears. Does **not** end+recreate — pure visual freezes recover via soft retries
    /// (and stalled-push bookkeeping when ActivityKit still rejects); recreation stays behind
    /// the eligibility gate on the general update path.
    ///
    /// **Quiet pending while request ineligible:** After the soft-retry budget is exhausted
    /// without owned `.playing` acceptance while ``isInteractiveLiveActivityRequestEligible``
    /// is false, records ``playingEnsureQuietPending`` and stops re-running soft pushes on
    /// every status callback. Re-arm when:
    /// - Authoritative play mutation (``rearmPlayingEnsureQuietPending()`` from setPlaying /
    ///   soft-resume)
    /// - Optimistic toggle or stream-switch ContentState
    /// - Interactive request becomes eligible
    /// - Foreground / become-active (``ensureAuthoritativeContentOnForegroundIfNeeded`` clears quiet)
    /// - System `contentUpdates` yield
    ///
    /// Called from ``SharedPlayerManager/setPlaying()`` after language ensure (serialize
    /// language then visual so one ContentState push can carry both), and from the soft-resume
    /// publish path when actor visual is already `.playing` (publish no-op) so a stuck
    /// Connecting glyph is still reconciled.
    ///
    /// - SeeAlso: ``updateCurrentActivity()``, ``shouldEnsureAuthoritativePlayingContent(actorVisual:streamSwitchHold:isConnectingPlayback:lastPushedVisual:ownedVisual:)``,
    ///   ``shouldRunPlayingContentEnsureSoftPushes(needsPlayingEnsure:quietPending:isRequestEligible:)``,
    ///   ``authoritativePlayingContentEnsureMaxAttempts``,
    ///   ``ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``recordOptimisticStreamSwitchContent(language:visualState:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    @MainActor
    func ensureAuthoritativePlayingContentIfNeeded() async {
        if SharedPlayerManager.isRunningInUITestMode { return }
        #if DEBUG
        if isRunningUnderTest { return }
        #endif
        guard currentActivity != nil else { return }

        let manager = SharedPlayerManager.shared
        let visual = await manager.currentVisualState
        let hold = await manager.isStreamSwitchPrePlayHoldActive
        let connecting = await manager.isConnectingPlayback
        let lastVisual = lastPushedContent?.visualState
        let ownedVisual = currentActivity?.content.state.visualState
        let needsEnsure = Self.shouldEnsureAuthoritativePlayingContent(
            actorVisual: visual,
            streamSwitchHold: hold,
            isConnectingPlayback: connecting,
            lastPushedVisual: lastVisual,
            ownedVisual: ownedVisual
        )
        // Owned visual converged → drop quiet.
        if Self.shouldClearPlayingEnsureQuietPending(
            quietPending: playingEnsureQuietPending,
            ownedOrSystemVisual: ownedVisual
        ) {
            playingEnsureQuietPending = false
        }
        guard needsEnsure else {
            playingEnsureQuietPending = false
            return
        }

        let requestEligible = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: ActivityAuthorizationInfo().areActivitiesEnabled,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        guard Self.shouldRunPlayingContentEnsureSoftPushes(
            needsPlayingEnsure: true,
            quietPending: playingEnsureQuietPending,
            isRequestEligible: requestEligible
        ) else {
            #if DEBUG
            print(
                "🔴 Live Activity playing ensure quiet (owned=\(String(describing: ownedVisual)); " +
                "wait for eligibility, become-active, or play mutation)"
            )
            #endif
            return
        }

        for attempt in 1...Self.authoritativePlayingContentEnsureMaxAttempts {
            guard currentActivity != nil else { return }

            let loopVisual = await manager.currentVisualState
            let loopHold = await manager.isStreamSwitchPrePlayHoldActive
            let loopConnecting = await manager.isConnectingPlayback
            let loopLastVisual = lastPushedContent?.visualState
            let loopOwnedVisual = currentActivity?.content.state.visualState

            guard Self.shouldEnsureAuthoritativePlayingContent(
                actorVisual: loopVisual,
                streamSwitchHold: loopHold,
                isConnectingPlayback: loopConnecting,
                lastPushedVisual: loopLastVisual,
                ownedVisual: loopOwnedVisual
            ) else {
                playingEnsureQuietPending = false
                return
            }

            #if DEBUG
            print(
                "🔴 Live Activity reconciling authoritative playing → last=\(String(describing: loopLastVisual)) " +
                "owned=\(String(describing: loopOwnedVisual)) attempt=\(attempt)/\(Self.authoritativePlayingContentEnsureMaxAttempts)"
            )
            #endif
            await updateCurrentActivity()

            // Post-update verification: owned visual is the surface honesty SSOT.
            let acceptedVisual = currentActivity?.content.state.visualState
            if acceptedVisual == .playing {
                playingEnsureQuietPending = false
                return
            }
            // Brief yield so ActivityKit / contentUpdates can converge before the next soft push.
            if attempt < Self.authoritativePlayingContentEnsureMaxAttempts {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        // Soft budget exhausted without acceptance.
        let finalVisual = await manager.currentVisualState
        let finalHold = await manager.isStreamSwitchPrePlayHoldActive
        let finalConnecting = await manager.isConnectingPlayback
        let stillStalled = Self.shouldEnsureAuthoritativePlayingContent(
            actorVisual: finalVisual,
            streamSwitchHold: finalHold,
            isConnectingPlayback: finalConnecting,
            lastPushedVisual: lastPushedContent?.visualState,
            ownedVisual: currentActivity?.content.state.visualState
        )
        let eligibleAfter = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: ActivityAuthorizationInfo().areActivitiesEnabled,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        if Self.shouldEnterPlayingEnsureQuietPending(
            playingStillStalled: stillStalled,
            isRequestEligible: eligibleAfter
        ) {
            playingEnsureQuietPending = true
            // Keep pending ensure so become-active owned-surface path re-arms recovery.
            pendingInteractiveLiveActivityEnsure = true
            #if DEBUG
            print(
                "🔴 Live Activity playing ensure quiet pending after max attempts " +
                "(recreation remains eligibility-gated)"
            )
            #endif
        }
    }

    /// Clears playing ensure quiet so the next soft-ensure cycle gets a full soft budget.
    ///
    /// Call on authoritative play mutations (``setPlaying`` / soft-resume ensure) so a prior
    /// lock-stretch exhaustion cannot block a high-priority visual reconcile after audible
    /// start. Does not invent `.playing` during hold — ensure gates still apply.
    ///
    /// - SeeAlso: ``ensureAuthoritativePlayingContentIfNeeded()``,
    ///   ``recordOptimisticToggleContent(visualState:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    @MainActor
    func rearmPlayingEnsureQuietPending() {
        playingEnsureQuietPending = false
    }

    /// Whether playing reconcile should force a content push.
    ///
    /// - Parameters:
    ///   - actorVisual: Actor ``currentVisualState``.
    ///   - streamSwitchHold: ``isStreamSwitchPrePlayHoldActive``.
    ///   - isConnectingPlayback: ``isConnectingPlayback``.
    ///   - lastPushedVisual: ``lastPushedContent`` visual, if any.
    ///   - ownedVisual: Owned `content.state.visualState`, if any.
    /// - Returns: `true` when the actor is authoritative playing without hold/connect and
    ///   last-pushed or owned visual is still Connecting or paused.
    /// - Note: Does not invent play during hold/connect — those remain Connecting honesty.
    /// - SeeAlso: ``ensureAuthoritativePlayingContentIfNeeded()``.
    static func shouldEnsureAuthoritativePlayingContent(
        actorVisual: PlayerVisualState,
        streamSwitchHold: Bool,
        isConnectingPlayback: Bool,
        lastPushedVisual: PlayerVisualState?,
        ownedVisual: PlayerVisualState?
    ) -> Bool {
        guard actorVisual == .playing else { return false }
        guard !streamSwitchHold, !isConnectingPlayback else { return false }
        if lastPushedVisual == .prePlay || lastPushedVisual == .userPaused {
            return true
        }
        if ownedVisual == .prePlay || ownedVisual == .userPaused {
            return true
        }
        // Owned still not playing while suppress memory already claims playing (extension /
        // optimistic path advanced lastPushed without system acceptance).
        if let ownedVisual, ownedVisual != .playing {
            return true
        }
        return false
    }

    /// Ensures interactive Live Activity `ContentState.currentLanguage` matches
    /// ``SharedPlayerManager/liveActivityLanguageCodeForContentPush()`` when they diverge.
    ///
    /// Peer to ``ensureAuthoritativePlayingContentIfNeeded()`` for **language chrome**
    /// (flag / name / alt-stream “current”). Does **not** invent `.playing` — Connecting
    /// (``.prePlay``) remains honest during stream-switch hold; only the language field is
    /// forced to the destination stamp / stream attach.
    ///
    /// Performs up to ``authoritativeLanguageContentEnsureMaxAttempts`` soft pushes, re-reading
    /// owned `content.state.currentLanguage` after each ``updateCurrentActivity()``. Stops early
    /// when owned language matches destination, the ensure gate clears, or the interactive
    /// activity disappears. Does **not** end+recreate — language freezes recover via soft
    /// retries first; eligible-only recreation is owned by
    /// ``ensureAuthoritativeContentOnForegroundIfNeeded()`` / the stalled-push path.
    ///
    /// **Quiet pending while request ineligible:** After the soft-retry budget is exhausted
    /// without owned language acceptance while ``isInteractiveLiveActivityRequestEligible``
    /// is false, records ``languageEnsureQuietPendingDestination`` and stops re-running soft
    /// pushes on every status callback for that destination. Re-arm when:
    /// - Destination language changes (new mutation — one high-priority ensure cycle)
    /// - Interactive request becomes eligible
    /// - Foreground / become-active (``ensureAuthoritativeContentOnForegroundIfNeeded`` clears quiet)
    /// - System `contentUpdates` yield
    ///
    /// Wire points (main app):
    /// - After media-surface Live Activity update/start (``refreshAllMediaSurfaces``)
    /// - After ``setPlaying()``’s playing reconcile
    /// - After optimistic stream-switch ContentState when this process owns the activity
    /// - Foreground / become-active owned-surface path via
    ///   ``ensureAuthoritativeContentOnForegroundIfNeeded()``
    ///
    /// Relies on ``shouldSuppressLiveActivityContentPush`` so optimistic ``lastPushedContent``
    /// that already claims destination language cannot block a push when owned
    /// `content.state.currentLanguage` is still the prior stream.
    ///
    /// - Precondition: Main actor; interactive ``currentActivity`` may be nil (no-op).
    /// - Postcondition: When a push was needed and not quiet-deferred, ``updateCurrentActivity()``
    ///   ran up to the soft-retry budget (subject to test isolation and ActivityKit acceptance).
    ///   Cheap no-op when owned + last language already match destination, or when quiet for
    ///   the same destination while request remains ineligible.
    /// - SeeAlso: ``updateCurrentActivity()``, ``shouldEnsureAuthoritativeLanguageContent(destinationLanguage:ownedContentLanguage:lastPushedLanguage:)``,
    ///   ``shouldRunLanguageContentEnsureSoftPushes(needsLanguageEnsure:destinationLanguage:quietPendingDestination:isRequestEligible:)``,
    ///   ``authoritativeLanguageContentEnsureMaxAttempts``,
    ///   ``ensureAuthoritativeContentOnForegroundIfNeeded()``,
    ///   ``recordOptimisticStreamSwitchContent(language:visualState:)``,
    ///   ``SharedPlayerManager/liveActivityLanguageCodeForContentPush()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   docs/Widget-Functionality-Roadmap.md (Live Activity language chrome SSOT).
    @MainActor
    func ensureAuthoritativeLanguageContentIfNeeded() async {
        if SharedPlayerManager.isRunningInUITestMode { return }
        #if DEBUG
        if isRunningUnderTest { return }
        #endif
        guard currentActivity != nil else { return }

        let destination = await SharedPlayerManager.shared.liveActivityLanguageCodeForContentPush()
        let ownedLanguage = currentActivity?.content.state.currentLanguage
        let lastLanguage = lastPushedContent?.currentLanguage
        let needsEnsure = Self.shouldEnsureAuthoritativeLanguageContent(
            destinationLanguage: destination,
            ownedContentLanguage: ownedLanguage,
            lastPushedLanguage: lastLanguage
        )
        // Destination moved on or owned converged → drop quiet for the prior destination.
        if Self.shouldClearLanguageEnsureQuietPending(
            quietPendingDestination: languageEnsureQuietPendingDestination,
            destinationLanguage: destination,
            ownedOrSystemLanguage: ownedLanguage
        ) {
            languageEnsureQuietPendingDestination = nil
        }
        guard needsEnsure else {
            languageEnsureQuietPendingDestination = nil
            return
        }

        let requestEligible = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: ActivityAuthorizationInfo().areActivitiesEnabled,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        guard Self.shouldRunLanguageContentEnsureSoftPushes(
            needsLanguageEnsure: true,
            destinationLanguage: destination,
            quietPendingDestination: languageEnsureQuietPendingDestination,
            isRequestEligible: requestEligible
        ) else {
            #if DEBUG
            print(
                "🔴 Live Activity language ensure quiet (destination=\(destination) " +
                "owned=\(ownedLanguage ?? "nil"); wait for eligibility, become-active, or language mutation)"
            )
            #endif
            return
        }

        // Destination change re-arms: clear any prior quiet so this cycle can enter quiet
        // for the *new* destination if it also exhausts while ineligible.
        if let quiet = languageEnsureQuietPendingDestination, quiet != destination {
            languageEnsureQuietPendingDestination = nil
        }

        for attempt in 1...Self.authoritativeLanguageContentEnsureMaxAttempts {
            guard currentActivity != nil else { return }

            let loopDestination = await SharedPlayerManager.shared.liveActivityLanguageCodeForContentPush()
            let loopOwned = currentActivity?.content.state.currentLanguage
            let loopLast = lastPushedContent?.currentLanguage

            guard Self.shouldEnsureAuthoritativeLanguageContent(
                destinationLanguage: loopDestination,
                ownedContentLanguage: loopOwned,
                lastPushedLanguage: loopLast
            ) else {
                languageEnsureQuietPendingDestination = nil
                return
            }

            #if DEBUG
            print(
                "🔴 Live Activity reconciling language chrome → destination=\(loopDestination) " +
                "owned=\(loopOwned ?? "nil") lastPushed=\(loopLast ?? "nil") " +
                "attempt=\(attempt)/\(Self.authoritativeLanguageContentEnsureMaxAttempts)"
            )
            #endif
            await updateCurrentActivity()

            // Post-update verification: owned language is the surface honesty SSOT.
            let acceptedLanguage = currentActivity?.content.state.currentLanguage
            if acceptedLanguage == loopDestination {
                languageEnsureQuietPendingDestination = nil
                return
            }
            if attempt < Self.authoritativeLanguageContentEnsureMaxAttempts {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        // Soft budget exhausted without acceptance.
        let finalDestination = await SharedPlayerManager.shared.liveActivityLanguageCodeForContentPush()
        let finalOwned = currentActivity?.content.state.currentLanguage
        let stillMismatches = Self.shouldEnsureAuthoritativeLanguageContent(
            destinationLanguage: finalDestination,
            ownedContentLanguage: finalOwned,
            lastPushedLanguage: lastPushedContent?.currentLanguage
        )
        let eligibleAfter = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: ActivityAuthorizationInfo().areActivitiesEnabled,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        if let quietDestination = Self.quietPendingDestinationAfterLanguageEnsureExhaustion(
            languageStillMismatches: stillMismatches,
            isRequestEligible: eligibleAfter,
            destinationLanguage: finalDestination
        ) {
            languageEnsureQuietPendingDestination = quietDestination
            // Keep pending ensure so become-active owned-surface path re-arms recovery.
            pendingInteractiveLiveActivityEnsure = true
            #if DEBUG
            print(
                "🔴 Live Activity language ensure quiet pending after max attempts " +
                "(destination=\(quietDestination); recreation remains eligibility-gated)"
            )
            #endif
        }
    }

    /// Whether an owned interactive Live Activity needs soft language and/or playing ensure
    /// on foreground / become-active (ownership non-nil; missing-card start is separate).
    ///
    /// - Parameters:
    ///   - hasCurrentActivity: Whether this process owns an interactive activity.
    ///   - destinationLanguage: ``SharedPlayerManager/liveActivityLanguageCodeForContentPush()``.
    ///   - ownedContentLanguage: Owned `content.state.currentLanguage`, if any.
    ///   - lastPushedLanguage: ``lastPushedContent`` language, if any.
    ///   - actorVisual: Actor ``currentVisualState``.
    ///   - streamSwitchHold: ``isStreamSwitchPrePlayHoldActive``.
    ///   - isConnectingPlayback: ``isConnectingPlayback``.
    ///   - lastPushedVisual: ``lastPushedContent`` visual, if any.
    ///   - ownedVisual: Owned `content.state.visualState`, if any.
    /// - Returns: `true` when ownership is non-nil and language and/or playing ensure gates fire.
    /// - Note: Does not invent `.playing` or decide end+request — soft ensure only.
    /// - SeeAlso: ``ensureAuthoritativeContentOnForegroundIfNeeded()``,
    ///   ``shouldInvokeOwnedSurfaceForegroundEnsure(hasCurrentActivity:lastOwnedSurfaceForegroundEnsureAt:now:debounceInterval:languageEnsureQuietPending:playingEnsureQuietPending:pendingInteractiveLiveActivityEnsure:contentEnsureStillNeeded:isRequestEligible:)``,
    ///   ``shouldEnsureAuthoritativeLanguageContent(destinationLanguage:ownedContentLanguage:lastPushedLanguage:)``,
    ///   ``shouldEnsureAuthoritativePlayingContent(actorVisual:streamSwitchHold:isConnectingPlayback:lastPushedVisual:ownedVisual:)``.
    static func shouldEnsureAuthoritativeContentOnForeground(
        hasCurrentActivity: Bool,
        destinationLanguage: String,
        ownedContentLanguage: String?,
        lastPushedLanguage: String?,
        actorVisual: PlayerVisualState,
        streamSwitchHold: Bool,
        isConnectingPlayback: Bool,
        lastPushedVisual: PlayerVisualState?,
        ownedVisual: PlayerVisualState?
    ) -> Bool {
        guard hasCurrentActivity else { return false }
        if shouldEnsureAuthoritativeLanguageContent(
            destinationLanguage: destinationLanguage,
            ownedContentLanguage: ownedContentLanguage,
            lastPushedLanguage: lastPushedLanguage
        ) {
            return true
        }
        if shouldEnsureAuthoritativePlayingContent(
            actorVisual: actorVisual,
            streamSwitchHold: streamSwitchHold,
            isConnectingPlayback: isConnectingPlayback,
            lastPushedVisual: lastPushedVisual,
            ownedVisual: ownedVisual
        ) {
            return true
        }
        return false
    }

    /// Whether the owned-surface foreground soft-ensure cycle should run now.
    ///
    /// ``SceneDelegate`` calls ``ensureInteractiveLiveActivityIfNeeded()`` from both
    /// ``sceneWillEnterForeground`` (via ``handleAppDidEnterForeground()``) and
    /// ``sceneDidBecomeActive``. Missing-card start already has its own debounce; this gate
    /// is the **owned-surface** peer so unlock recovery stays intentional without dual-hook
    /// soft-budget thrash.
    ///
    /// **Always invoke (consume pending) when:**
    /// - Language ensure quiet is set (lock-stretch thrash after max attempts while ineligible)
    /// - Playing ensure quiet is set
    /// - ``pendingInteractiveLiveActivityEnsure`` is set (deferred recreation / soft-exhaust)
    ///
    /// **Debounce skip when** none of the above and a cycle ran within ``debounceInterval``,
    /// **unless** content still needs soft ensure **and** request is now eligible — so a first
    /// pass that ran while application was not yet `.active` does not permanently skip the
    /// presentable become-active pass.
    ///
    /// - Parameters:
    ///   - hasCurrentActivity: Whether this process owns an interactive activity.
    ///   - lastOwnedSurfaceForegroundEnsureAt: Stamp of the last owned-surface soft cycle.
    ///   - now: Current time (injectable for tests).
    ///   - debounceInterval: Production ``ownedSurfaceForegroundEnsureDebounceInterval``.
    ///   - languageEnsureQuietPending: Whether ``languageEnsureQuietPendingDestination`` is set.
    ///   - playingEnsureQuietPending: ``playingEnsureQuietPending``.
    ///   - pendingInteractiveLiveActivityEnsure: Deferred ensure / soft-exhaust pending flag.
    ///   - contentEnsureStillNeeded: ``shouldEnsureAuthoritativeContentOnForeground`` result.
    ///   - isRequestEligible: ``isInteractiveLiveActivityRequestEligible``.
    /// - Returns: `true` when ``ensureAuthoritativeContentOnForegroundIfNeeded()`` should run.
    /// - Important: Does not decide end+request; never invents `.playing`. Unowned → `false`
    ///   (missing-card start path is separate).
    /// - SeeAlso: ``ensureInteractiveLiveActivityIfNeeded()``,
    ///   ``ensureAuthoritativeContentOnForegroundIfNeeded()``,
    ///   ``ownedSurfaceForegroundEnsureDebounceInterval``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldInvokeOwnedSurfaceForegroundEnsure(
        hasCurrentActivity: Bool,
        lastOwnedSurfaceForegroundEnsureAt: Date?,
        now: Date,
        debounceInterval: TimeInterval = RadioLiveActivityManager.ownedSurfaceForegroundEnsureDebounceInterval,
        languageEnsureQuietPending: Bool,
        playingEnsureQuietPending: Bool,
        pendingInteractiveLiveActivityEnsure: Bool,
        contentEnsureStillNeeded: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        guard hasCurrentActivity else { return false }

        // Consume lock-stretch quiet / deferred pending on a presentable cycle.
        // Quiet is for thrash while request was ineligible — not a freeze across unlock.
        if languageEnsureQuietPending
            || playingEnsureQuietPending
            || pendingInteractiveLiveActivityEnsure
        {
            return true
        }

        if let last = lastOwnedSurfaceForegroundEnsureAt,
           now.timeIntervalSince(last) < debounceInterval {
            // willEnterForeground may run before application is `.active`. become-active must
            // still soft-ensure when chrome lags and request is now eligible.
            if contentEnsureStillNeeded && isRequestEligible {
                return true
            }
            return false
        }

        // First owned-surface pass this debounce window (or never). Soft ensure is a cheap
        // no-op when language + visual already match destination / actor.
        return true
    }

    /// Whether eligible-only end+request may run after foreground soft ensure still leaves
    /// owned chrome lagging the destination language and/or authoritative playing visual.
    ///
    /// **Invariant:** Never true when request is ineligible — keep the only interactive
    /// surface while `Activity.request` cannot succeed (lock / background visibility).
    ///
    /// - Parameters:
    ///   - languageStillMismatches: Soft language ensure gate still true after retries.
    ///   - playingStillStalled: Soft playing ensure gate still true after retries.
    ///   - isRequestEligible: ``isInteractiveLiveActivityRequestEligible(areActivitiesEnabled:isApplicationActive:)``.
    ///   - recreationsAttempted: ``interactiveContentRecreationsAttempted`` this healthy cycle.
    ///   - maxRecreations: Production ``maxInteractiveContentRecreations``.
    /// - Returns: `true` only when soft path still fails **and** request is eligible **and**
    ///   recreation budget remains.
    /// - SeeAlso: ``ensureAuthoritativeContentOnForegroundIfNeeded()``,
    ///   ``recreateInteractiveLiveActivityAfterStalledContent()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldRecreateAfterForegroundSoftEnsureFailed(
        languageStillMismatches: Bool,
        playingStillStalled: Bool,
        isRequestEligible: Bool,
        recreationsAttempted: Int,
        maxRecreations: Int = RadioLiveActivityManager.maxInteractiveContentRecreations
    ) -> Bool {
        guard isRequestEligible else { return false }
        guard languageStillMismatches || playingStillStalled else { return false }
        guard recreationsAttempted < maxRecreations else { return false }
        return true
    }

    /// Soft language + playing ensure for an **owned** interactive Live Activity on
    /// foreground / become-active, then eligible-only recreation if soft ensure still fails.
    ///
    /// **Why:** Deferred recreation keeps the interactive card while request is ineligible;
    /// system-held `content.state` may still trail destination language/visual after unlock.
    /// Real-device unlock heal (system `contentUpdates` after become-active without an in-app
    /// stream switch) is the intentional recovery rail: clear lock-stretch quiet, soft-push
    /// both axes, then optionally recreate only when request-eligible.
    /// ``ensureInteractiveLiveActivityIfNeeded()`` restores a **missing** card only
    /// (`currentActivity == nil`); this is the owned-surface peer so become-active does not
    /// leave a present card on prior-stream chrome. Callers gate dual SceneDelegate hooks via
    /// ``shouldInvokeOwnedSurfaceForegroundEnsure`` so quiet/pending are still **consumed**
    /// while redundant soft cycles are debounced.
    ///
    /// **Order:**
    /// 1. Clear ``languageEnsureQuietPendingDestination`` + ``playingEnsureQuietPending``
    ///    (lock-stretch thrash protection must not freeze chrome across presentable cycles)
    /// 2. Bounded ``ensureAuthoritativeLanguageContentIfNeeded()``
    /// 3. Bounded ``ensureAuthoritativePlayingContentIfNeeded()``
    /// 4. If owned language/visual still lag **and** request is eligible → single
    ///    ``recreateInteractiveLiveActivityAfterStalledContent()`` (re-checks eligibility;
    ///    never ends while ineligible)
    ///
    /// - Precondition: Main actor; no-op under UITestMode / under-test; no-op when unowned.
    ///   Caller should have already decided invoke via
    ///   ``shouldInvokeOwnedSurfaceForegroundEnsure`` (or equivalent ownership check).
    /// - Postcondition: Quiet flags cleared; soft pushes attempted when needed; recreation
    ///   only when eligible and soft path still failed with budget remaining.
    /// - Important: Does not invent `.playing` during stream-switch hold; does not bypass
    ///   privacy write suppression or home-widget write gating. Does not end the only
    ///   activity while request is ineligible.
    /// - SeeAlso: ``ensureInteractiveLiveActivityIfNeeded()``, ``handleAppDidEnterForeground()``,
    ///   ``shouldInvokeOwnedSurfaceForegroundEnsure(hasCurrentActivity:lastOwnedSurfaceForegroundEnsureAt:now:debounceInterval:languageEnsureQuietPending:playingEnsureQuietPending:pendingInteractiveLiveActivityEnsure:contentEnsureStillNeeded:isRequestEligible:)``,
    ///   ``shouldEnsureAuthoritativeContentOnForeground(hasCurrentActivity:destinationLanguage:ownedContentLanguage:lastPushedLanguage:actorVisual:streamSwitchHold:isConnectingPlayback:lastPushedVisual:ownedVisual:)``,
    ///   ``shouldRecreateAfterForegroundSoftEnsureFailed(languageStillMismatches:playingStillStalled:isRequestEligible:recreationsAttempted:maxRecreations:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   docs/Widget-Functionality-Roadmap.md.
    @MainActor
    func ensureAuthoritativeContentOnForegroundIfNeeded() async {
        if SharedPlayerManager.isRunningInUITestMode { return }
        #if DEBUG
        if isRunningUnderTest { return }
        #endif
        guard currentActivity != nil else { return }

        // Re-arm language + playing ensure quiet so unlock / become-active always gets a soft cycle.
        // Quiet is for lock-stretch thrash only — not a permanent freeze across presentable cycles.
        // AGENT NOTE: Both axes clear together — language-only unlock must not leave playing
        // quiet blocking visual recovery (and the reverse).
        languageEnsureQuietPendingDestination = nil
        playingEnsureQuietPending = false

        // Soft path first — never end the only card while ActivityKit may still accept updates.
        // Language then visual so one ContentState push can co-converge both axes when possible.
        await ensureAuthoritativeLanguageContentIfNeeded()
        await ensureAuthoritativePlayingContentIfNeeded()

        guard currentActivity != nil else { return }

        let manager = SharedPlayerManager.shared
        let destination = await manager.liveActivityLanguageCodeForContentPush()
        let ownedLanguage = currentActivity?.content.state.currentLanguage
        let lastLanguage = lastPushedContent?.currentLanguage
        let languageStillMismatches = Self.shouldEnsureAuthoritativeLanguageContent(
            destinationLanguage: destination,
            ownedContentLanguage: ownedLanguage,
            lastPushedLanguage: lastLanguage
        )

        let visual = await manager.currentVisualState
        let hold = await manager.isStreamSwitchPrePlayHoldActive
        let connecting = await manager.isConnectingPlayback
        let lastVisual = lastPushedContent?.visualState
        let ownedVisual = currentActivity?.content.state.visualState
        let playingStillStalled = Self.shouldEnsureAuthoritativePlayingContent(
            actorVisual: visual,
            streamSwitchHold: hold,
            isConnectingPlayback: connecting,
            lastPushedVisual: lastVisual,
            ownedVisual: ownedVisual
        )

        let requestEligible = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: ActivityAuthorizationInfo().areActivitiesEnabled,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )

        guard Self.shouldRecreateAfterForegroundSoftEnsureFailed(
            languageStillMismatches: languageStillMismatches,
            playingStillStalled: playingStillStalled,
            isRequestEligible: requestEligible,
            recreationsAttempted: interactiveContentRecreationsAttempted
        ) else {
            return
        }

        #if DEBUG
        print(
            "🔴 Live Activity foreground soft ensure still lagged " +
            "(language=\(languageStillMismatches) playing=\(playingStillStalled)); " +
            "eligible recreation"
        )
        #endif
        // recreateInteractiveLiveActivityAfterStalledContent re-checks eligibility and never
        // ends the only surface while request is ineligible.
        await recreateInteractiveLiveActivityAfterStalledContent()
    }

    /// Aligns in-memory ``lastPushedContent`` with an intent-path optimistic Live Activity visual.
    ///
    /// Called from ``WidgetIntentExecution`` after ActivityKit content is published (or when
    /// no activity is visible in this process), including main-app ``SharedPlayerManager/stop()``
    /// sticky-lock pause honesty. Matching the optimistic visual here means the subsequent
    /// engine-complete ``updateCurrentActivity()`` typically sees an equal candidate and
    /// suppresses redundant IPC once the actor sticky-locks or setPlaying — **provided** owned
    /// system-held visual also matches (owned-visual suppress gate). Pause from stale Connecting
    /// does **not** require prior owned ``.playing``; language and program metadata are preserved.
    ///
    /// - Parameter visualState: Optimistic control visual (`.userPaused` or `.playing`).
    /// - Postcondition: ``lastPushedContent`` reflects `visualState` with preserved metadata
    ///   and language when any source is available; durable toggle mirrors stay the caller's
    ///   job (already written before this alignment); ``playingEnsureQuietPending`` cleared.
    /// - Note: Does not call `Activity.update` — the intent path owns that IPC via
    ///   `Activity.activities` so extension-hosted and main-hosted toggles share one push site.
    /// - SeeAlso: ``updateCurrentActivity()``, ``recordOptimisticStreamSwitchContent(language:visualState:)``,
    ///   ``WidgetIntentExecution/performLiveActivityToggle()``,
    ///   ``WidgetIntentExecution/executeOptimisticToggle(plan:language:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    @MainActor
    func recordOptimisticToggleContent(visualState: PlayerVisualState) {
        // Control mutation re-arms playing ensure quiet so pause honesty and later soft-resume
        // get a full soft budget even after prior lock-stretch playing thrash.
        playingEnsureQuietPending = false
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

    /// Aligns in-memory ``lastPushedContent`` with an intent-path optimistic stream-language switch.
    ///
    /// Called from ``WidgetIntentExecution/pushOptimisticLiveActivityStreamSwitchContent(languageCode:visualState:)``
    /// after ActivityKit content is published (or when no activity is visible). Destination
    /// language + Connecting / preserved-pause visual match the optimistic ContentState so
    /// main-app ``updateCurrentActivity()`` can suppress when the actor stamp **and** the
    /// owned surface language converge to the same tuple.
    ///
    /// **Owned language still wins for suppress:** Aligning ``lastPushedContent`` to the
    /// destination does **not** block a needed push when
    /// `currentActivity?.content.state.currentLanguage` still differs — see
    /// ``shouldSuppressLiveActivityContentPush(lastPushed:candidate:ownedContentLanguage:)``.
    /// Callers should also invoke ``ensureAuthoritativeLanguageContentIfNeeded()`` after the
    /// optimistic ActivityKit path when this process owns an interactive activity.
    ///
    /// **Language ensure re-arm:** A new destination clears ``languageEnsureQuietPendingDestination``
    /// when it differs so the next ensure cycle gets one high-priority soft budget for the
    /// new language (home-widget and Live Activity stream chips share this path).
    ///
    /// **Playing ensure re-arm:** Any stream-switch optimistic stamp clears
    /// ``playingEnsureQuietPending`` so post-attach audible start / soft-resume can run a full
    /// playing soft budget (Connecting honesty still gated by hold/connect).
    ///
    /// Program metadata is cleared (same as the ActivityKit push) so a prior-stream title
    /// cannot suppress a language-only destination push.
    ///
    /// - Parameters:
    ///   - language: Destination stream language code for language chrome.
    ///   - visualState: Optimistic control visual (typically `.prePlay` or `.userPaused`).
    /// - Postcondition: ``lastPushedContent`` holds `visualState`, `nil` stream metadata, and
    ///   `language` (in-process only — not proof of system acceptance). Quiet language ensure
    ///   is cleared when the destination differs from the prior quiet destination; playing
    ///   ensure quiet is always cleared for the new switch cycle.
    /// - Note: Does not call `Activity.update` — the intent path owns ActivityKit IPC.
    /// - SeeAlso: ``recordOptimisticToggleContent(visualState:)``, ``updateCurrentActivity()``,
    ///   ``ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``ensureAuthoritativePlayingContentIfNeeded()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   docs/Widget-Functionality-Roadmap.md (Live Activity language chrome SSOT).
    @MainActor
    func recordOptimisticStreamSwitchContent(language: String, visualState: PlayerVisualState) {
        guard !language.isEmpty else { return }
        // New language mutation re-arms soft language ensure for one high-priority cycle.
        if languageEnsureQuietPendingDestination != language {
            languageEnsureQuietPendingDestination = nil
        }
        // New stream-switch cycle re-arms playing ensure for post-attach audible start.
        playingEnsureQuietPending = false
        lastPushedContent = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: visualState,
            streamMetadata: nil,
            currentLanguage: language
        )
        #if DEBUG
        let owned = currentActivity?.content.state.currentLanguage
        if let owned, owned != language {
            print(
                "🔴 Live Activity lastPushedContent aligned to optimistic stream switch " +
                "visual=\(visualState) language=\(language) (owned content.state still \(owned); " +
                "suppress will not skip language reconcile)"
            )
        } else {
            print("🔴 Live Activity lastPushedContent aligned to optimistic stream switch visual=\(visualState) language=\(language)")
        }
        #endif
    }

    /// Ends every owned / system-held Live Activity and stops any fallback timer.
    ///
    /// ## Termination correctness (why this is not a fire-and-forget Task alone)
    /// Historically `endActivity` cleared local refs then launched an unstructured
    /// `Task { await activity.end(...) }`. On process exit (`applicationWillTerminate`,
    /// `sceneDidDisconnect`, `willTerminateNotification`) that Task frequently never
    /// ran before the process died, leaving Dynamic Island / Lock Screen with a stale
    /// interactive `ContentState` (often still `.playing`). The cleanup path therefore:
    /// 1. Sweeps **all** `Activity.activities` (not only `currentActivity`) so a nil local
    ///    reference cannot leave system-held surfaces orphaned.
    /// 2. Pushes a final coherent `.userPaused` ContentState that preserves last-known
    ///    language chrome (and program metadata when available).
    /// 3. On termination, **waits** for ActivityKit `update` + `end` via detached work
    ///    + run-loop pumping so the system accepts dismissal before process death.
    ///
    /// While the main process remains alive (privacy clear, cold-launch hygiene), prefer
    /// ``endActivityAsync(dismissalPolicy:)`` so callers can `await` completion. The
    /// synchronous entry point remains for termination and call sites that cannot hop async.
    ///
    /// `dismissalPolicy`:
    /// - `.default` (privacy clear while process lives): system may keep the ended
    ///   activity visible briefly so the user sees the final paused frame.
    /// - `.immediate` (termination / cold-launch reap): removes the surface right away.
    ///
    /// **Why `.immediate` on termination (Cleanup Invariant)**:
    /// Once the main app process has exited there is no longer an in-process actor that can
    /// service `AppIntent` taps from the Live Activity or push fresh `ContentState` updates.
    /// Leaving the LA visible would allow ActivityKit / Chrono to treat the surface as
    /// active with no live backing process. Immediate dismissal after the final
    /// `.userPaused` push stops that.
    ///
    /// The user can still launch the app via home-screen widget "tap to open", Control
    /// widget, app icon, or (while the LA is still present before termination completes)
    /// the standard Live Activity tap-to-launch ("open") URL.
    ///
    /// - Parameters:
    ///   - dismissalPolicy: ActivityKit dismissal policy (default `.default`).
    ///   - waitForSystemCompletion: When `true` (termination only), block the calling
    ///     context briefly until ActivityKit end finishes or a short timeout elapses.
    ///     Must not be used from paths that cannot afford run-loop pumping.
    /// - Lifecycle: Clears `lastPushedContent`, durable LA mirrors, and observation so a
    ///   future `startActivity` begins clean.
    /// - Note: Does **not** end on user pause — a paused LA with a working play control
    ///   is intentional while the main process is alive.
    /// - Precondition: Main-app process only (widget processes never own the Activity).
    /// - Important: Under `isRunningInUITestMode` / DEBUG `isRunningUnderTest` performs
    ///   only cheap local cleanup; real ActivityKit IPC is skipped (test isolation).
    /// - SeeAlso: ``endActivityAsync(dismissalPolicy:)``, ``handleAppWillTerminate()``,
    ///   ``observeExistingActivities()``, AppDelegate.applicationWillTerminate,
    ///   SharedPlayerManager.forceStaleLivenessTimestampForTermination,
    ///   SharedPlayerManager.performSessionTeardownSynchronouslyForTermination,
    ///   RadioLiveActivityManagerTests, docs/Widget-Presentation-Dataflow.md,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    func endActivity(
        dismissalPolicy: ActivityUIDismissalPolicy = .default,
        waitForSystemCompletion: Bool = false
    ) {
        let prepared = prepareLocalLiveActivityEndState()
        guard let prepared else { return }

        if waitForSystemCompletion {
            endActivitiesWaitingForSystem(
                prepared.activities,
                finalContentState: prepared.finalContentState,
                dismissalPolicy: dismissalPolicy
            )
        } else {
            endActivitiesInBackground(
                prepared.activities,
                finalContentState: prepared.finalContentState,
                dismissalPolicy: dismissalPolicy
            )
        }
    }

    /// Awaitable Live Activity end for session teardown while the process remains alive.
    ///
    /// Prefer this from ``SharedPlayerManager/performSessionAndWidgetTeardown`` (privacy
    /// clear, cold-launch factory reset) so ActivityKit dismissal completes before later
    /// work races with ``observeExistingActivities()`` re-query.
    ///
    /// - Parameter dismissalPolicy: ActivityKit dismissal policy.
    /// - Postcondition: Local tracking cleared; every interactive system activity for this
    ///   attribute type has been asked to end with a final coherent ContentState.
    /// - SeeAlso: ``endActivity(dismissalPolicy:waitForSystemCompletion:)``,
    ///   ``handleAppWillTerminate()``.
    func endActivityAsync(dismissalPolicy: ActivityUIDismissalPolicy = .default) async {
        let prepared = prepareLocalLiveActivityEndState()
        guard let prepared else { return }

        await endActivitiesAwaitingSystem(
            prepared.activities,
            finalContentState: prepared.finalContentState,
            dismissalPolicy: dismissalPolicy
        )
    }

    /// Local prep shared by sync/async end paths: cancel observation, build final
    /// ContentState, clear mirrors, and collect system activities to dismiss.
    ///
    /// Final language/metadata priority (chrome must not invent a live stream, but should
    /// not flash the wrong language on cold-launch reaping either):
    /// 1. ``lastPushedContent`` (this-process last accepted push)
    /// 2. `currentActivity?.content.state` (owned Activity)
    /// 3. Residual system activities' `content.state` (prior-process force-quit leftovers when
    ///    local tracking is empty on cold launch)
    /// 4. ``SharedPlayerManager/mainAppLiveActivityLanguageCode()`` (language only)
    ///
    /// Visual is always forced to `.userPaused` regardless of residual visual.
    ///
    /// - Returns: Activities + final state when ActivityKit work must run; `nil` when
    ///   test isolation short-circuits or there is nothing for the system to end.
    /// - SeeAlso: ``_test_finalEndContentState(lastPushed:activityState:residualState:fallbackLanguage:)``,
    ///   ``observeExistingActivities()``.
    private func prepareLocalLiveActivityEndState() -> (
        activities: [Activity<LutheranRadioLiveActivityAttributes>],
        finalContentState: LutheranRadioLiveActivityAttributes.ContentState
    )? {
        stopLocalUpdateTimer()
        activityEventObserver.cancel()
        activityObservationTask = nil

        // Snapshot local chrome *before* clearing tracking so an in-process end cannot
        // invent language or drop the stream the user was just watching.
        let languageFromLocal =
            lastPushedContent?.currentLanguage
            ?? currentActivity?.content.state.currentLanguage
        let metadataFromLocal =
            lastPushedContent?.streamMetadata
            ?? currentActivity?.content.state.streamMetadata

        // Defense-in-depth UI test isolation — no ActivityKit IPC under test hosts.
        if SharedPlayerManager.isRunningInUITestMode {
            currentActivity = nil
            lastPushedContent = nil
            consecutiveStalledContentPushes = 0
            interactiveContentRecreationsAttempted = 0
            languageEnsureQuietPendingDestination = nil
            playingEnsureQuietPending = false
            if !isRecreatingLiveActivityAfterStalledContent {
                pendingInteractiveLiveActivityEnsure = false
            }
            SharedPlayerManager.clearLiveActivityToggleVisualStateMirror()
            SharedPlayerManager.clearLiveActivityLanguageMirror()
            return nil
        }

        #if DEBUG
        if isRunningUnderTest {
            currentActivity = nil
            lastPushedContent = nil
            consecutiveStalledContentPushes = 0
            interactiveContentRecreationsAttempted = 0
            languageEnsureQuietPendingDestination = nil
            playingEnsureQuietPending = false
            if !isRecreatingLiveActivityAfterStalledContent {
                pendingInteractiveLiveActivityEnsure = false
            }
            SharedPlayerManager.clearLiveActivityToggleVisualStateMirror()
            SharedPlayerManager.clearLiveActivityLanguageMirror()
            return nil
        }
        #endif

        // Sweep system-held activities even when `currentActivity` is already nil
        // (observe race, prior partial end, force-quit residual reaped on next launch).
        let activities = collectActivitiesToEnd()

        currentActivity = nil
        lastPushedContent = nil
        consecutiveStalledContentPushes = 0
        languageEnsureQuietPendingDestination = nil
        playingEnsureQuietPending = false
        // Do not reset interactiveContentRecreationsAttempted here when recreation is mid-flight
        // (end clears tracking before start). Recreation counter is owned by the recreation cycle.
        // Pending ensure survives an in-flight recreation end so a failed replacement start
        // can still recover on foreground; session teardown clears it.
        if !isRecreatingLiveActivityAfterStalledContent {
            interactiveContentRecreationsAttempted = 0
            pendingInteractiveLiveActivityEnsure = false
        }
        SharedPlayerManager.clearLiveActivityToggleVisualStateMirror()
        SharedPlayerManager.clearLiveActivityLanguageMirror()

        guard !activities.isEmpty else { return nil }

        // Cold-launch reaping: local tracking is empty after process death. Seed final
        // language/metadata from residual system ContentState so the dismiss frame keeps
        // the stream chrome the user last saw (visual still forced to .userPaused).
        let residualChrome = Self.seedFinalEndChromeFromResidualActivities(activities)
        let finalLanguage =
            languageFromLocal
            ?? residualChrome.language
            ?? SharedPlayerManager.mainAppLiveActivityLanguageCode()
        let finalMetadata = metadataFromLocal ?? residualChrome.metadata

        // Final frame: never claim live audio after the owning process is leaving or
        // the session is torn down. Language chrome stays consistent with the last stream.
        let finalContentState = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .userPaused,
            streamMetadata: finalMetadata,
            currentLanguage: finalLanguage
        )
        return (activities, finalContentState)
    }

    /// Seeds language/metadata from residual system activities when this-process local
    /// tracking is empty (typical cold-launch reaping after force-quit).
    ///
    /// - Parameter activities: System-held activities collected for end.
    /// - Returns: First non-empty language and first non-nil program metadata found.
    private static func seedFinalEndChromeFromResidualActivities(
        _ activities: [Activity<LutheranRadioLiveActivityAttributes>]
    ) -> (language: String?, metadata: StreamProgramMetadata?) {
        var language: String?
        var metadata: StreamProgramMetadata?
        for activity in activities {
            let state = activity.content.state
            if language == nil, !state.currentLanguage.isEmpty {
                language = state.currentLanguage
            }
            if metadata == nil, let meta = state.streamMetadata {
                metadata = meta
            }
            if language != nil, metadata != nil { break }
        }
        return (language, metadata)
    }

    /// Collects unique Live Activities to dismiss: the local `currentActivity` plus every
    /// system-held activity for this attribute type.
    ///
    /// - Important: Relying solely on `currentActivity` leaves orphans when the local
    ///   reference was cleared (or never set after process death) while ActivityKit still
    ///   shows Dynamic Island / Lock Screen chrome.
    private func collectActivitiesToEnd() -> [Activity<LutheranRadioLiveActivityAttributes>] {
        var byId: [String: Activity<LutheranRadioLiveActivityAttributes>] = [:]
        if let current = currentActivity {
            byId[current.id] = current
        }
        for activity in Activity<LutheranRadioLiveActivityAttributes>.activities {
            byId[activity.id] = activity
        }
        return Array(byId.values)
    }

    /// Fire-and-forget ActivityKit end while the process remains alive (privacy clear).
    private func endActivitiesInBackground(
        _ activities: [Activity<LutheranRadioLiveActivityAttributes>],
        finalContentState: LutheranRadioLiveActivityAttributes.ContentState,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) {
        let content = ActivityContent(state: finalContentState, staleDate: nil)
        for activity in activities {
            // Hoist Sendable identity before the ActivityKit hop so DEBUG logs never
            // touch the nonisolated(unsafe) binding (SE-0458 / SWIFT_STRICT_MEMORY_SAFETY).
            let activityId = activity.id
            // SAFETY: Activity is not Sendable in the current SDK; local strong reference
            // for update/end only (same capture pattern as updateCurrentActivity).
            nonisolated(unsafe) let safeActivity = activity
            Task {
                unsafe await safeActivity.update(content)
                unsafe await safeActivity.end(content, dismissalPolicy: dismissalPolicy)
                #if DEBUG
                print("🔴 Live Activity ended (policy: \(dismissalPolicy)) id=\(activityId)")
                #endif
            }
        }
    }

    /// Awaits ActivityKit final push + end for each activity (session teardown while alive).
    private func endActivitiesAwaitingSystem(
        _ activities: [Activity<LutheranRadioLiveActivityAttributes>],
        finalContentState: LutheranRadioLiveActivityAttributes.ContentState,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) async {
        let content = ActivityContent(state: finalContentState, staleDate: nil)
        for activity in activities {
            // Hoist Sendable identity before the ActivityKit hop so DEBUG logs never
            // touch the nonisolated(unsafe) binding (SE-0458 / SWIFT_STRICT_MEMORY_SAFETY).
            let activityId = activity.id
            // SAFETY: Activity is not Sendable in the current SDK; local strong reference
            // for update/end only (same capture pattern as updateCurrentActivity).
            nonisolated(unsafe) let safeActivity = activity
            unsafe await safeActivity.update(content)
            unsafe await safeActivity.end(content, dismissalPolicy: dismissalPolicy)
            #if DEBUG
            print("🔴 Live Activity ended (awaited, policy: \(dismissalPolicy)) id=\(activityId)")
            #endif
        }
    }

    /// Termination-path end: ActivityKit work runs off the main actor and the caller
    /// pumps the run loop until completion or a short timeout.
    ///
    /// - Why not a plain MainActor `Task`: `applicationWillTerminate` returns and the
    ///   process may exit before a main-actor-scheduled Task runs. `Task.detached`
    ///   plus run-loop pumping keeps the process alive long enough for `end` to land.
    /// - Timeout: best-effort; if the system is wedged we still exit rather than hang.
    /// - SeeAlso: ``handleAppWillTerminate()``, ``endActivity(dismissalPolicy:waitForSystemCompletion:)``.
    private func endActivitiesWaitingForSystem(
        _ activities: [Activity<LutheranRadioLiveActivityAttributes>],
        finalContentState: LutheranRadioLiveActivityAttributes.ContentState,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) {
        let content = ActivityContent(state: finalContentState, staleDate: nil)
        let remaining = OSAllocatedUnfairLock(initialState: activities.count)

        for activity in activities {
            // Hoist Sendable identity before the detached hop so DEBUG logs never
            // touch the nonisolated(unsafe) binding (SE-0458 / SWIFT_STRICT_MEMORY_SAFETY).
            let activityId = activity.id
            // SAFETY: Activity is not Sendable in the current SDK; local strong reference
            // for Task.detached update/end only (same capture pattern as updateCurrentActivity).
            nonisolated(unsafe) let safeActivity = activity
            Task.detached {
                unsafe await safeActivity.update(content)
                unsafe await safeActivity.end(content, dismissalPolicy: dismissalPolicy)
                remaining.withLock { $0 = max(0, $0 - 1) }
                #if DEBUG
                print("🔴 Live Activity ended (termination wait, policy: \(dismissalPolicy)) id=\(activityId)")
                #endif
            }
        }

        // Bound wait so a stuck ActivityKit service cannot hang process exit forever.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let done = remaining.withLock { $0 == 0 }
            if done { break }
            // Pump the current run loop so detached work and any main hops can complete
            // while we still hold the termination callback stack.
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }

        #if DEBUG
        let leftover = remaining.withLock { $0 }
        if leftover > 0 {
            print("🔴 Live Activity termination wait timed out with \(leftover) activity end(s) outstanding")
        }
        #endif
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
    
    /// Runs once after singleton init to handle Live Activities that survived process death.
    ///
    /// ## Process-death residual reaping (not adoption)
    /// Earlier behavior re-attached `Activity.activities.first` as `currentActivity` and
    /// resumed attribute-events observation. That left Dynamic Island / Lock Screen showing
    /// a stale interactive ContentState (often `.playing`) after force-quit or a missed
    /// termination `end`, with no live audio engine behind it.
    ///
    /// Ownership rule: only this process lifetime may present an interactive LA. A fresh
    /// process must **reap** residuals (final `.userPaused` + `.immediate` end) rather than
    /// adopt them. New activities are created exclusively via ``startActivity()`` when
    /// playback becomes authoritative (or background auto-start while playing).
    ///
    /// **This-process ownership + sibling residual reaping:** if ``currentActivity`` is already
    /// non-nil when the deferred observe runs (``startActivity()`` raced ahead of the post-init
    /// yield), full ``endActivity`` is **not** used — that would dismiss the legitimate owned
    /// Activity and clear mirrors. Instead ``reapUnownedSystemResiduals(preservingOwnedActivityId:)``
    /// ends every system-held activity whose id differs from the owned one, preserving local
    /// tracking. This closes the hole where ownership skip alone could leave a second prior-
    /// process residual interactive while this process owns a new surface. Happy path:
    /// ``startActivity()`` already calls ``endActivity()`` first, so the sibling set is empty.
    ///
    /// Background audio with a living process never re-enters this path — the singleton
    /// is already initialized and `currentActivity` is managed by start/update/end.
    ///
    /// - Important: In DEBUG builds this performs a **robust test-environment short-circuit**
    ///   using the shared ``isRunningUnderTest`` helper. A real `Activity.activities` lookup
    ///   is a synchronous call into ActivityKit's system services that becomes extremely
    ///   slow under LLDB when any Live Activity is present in the simulator. The guard
    ///   prevents that cost during unit tests and guarantees `currentActivity` starts as `nil`.
    ///
    /// - Note: The four-condition detection (env var + class + two processName checks)
    ///   is required because `XCTestConfigurationFilePath` is reliable under `xcodebuild`
    ///   but often absent from Xcode GUI test runs (Product → Test / test navigator).
    ///
    /// - SeeAlso: ``RadioLiveActivityManager/init()``, ``endActivity(dismissalPolicy:waitForSystemCompletion:)``,
    ///   ``startActivity()``, ``isRunningUnderTest``, RadioLiveActivityManagerTests.setUp,
    ///   docs/Widget-Presentation-Dataflow.md (termination + residual reaping),
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md, <doc:Architecture>
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

        // This-process ownership: never full-end the owned Activity, but still reap any
        // sibling system residuals (ids other than currentActivity). Pure id policy lives
        // in ``systemResidualIdsToReap(systemActivityIds:ownedActivityId:)``.
        if let owned = currentActivity {
            reapUnownedSystemResiduals(preservingOwnedActivityId: owned.id)
            return
        }

        // No local ownership: never adopt a prior-process residual as interactive. Full
        // ``endActivity`` sweeps all system activities, pushes paused + residual language
        // chrome, and dismisses immediately. Local `currentActivity` stays nil until
        // ``startActivity()`` runs for this process lifetime.
        let residualCount = Activity<LutheranRadioLiveActivityAttributes>.activities.count
        if residualCount > 0 {
            #if DEBUG
            print("🔴 Reaping \(residualCount) residual Live Activity surface(s) from prior process lifetime")
            #endif
            endActivity(dismissalPolicy: .immediate, waitForSystemCompletion: false)
        } else {
            currentActivity = nil
        }
    }

    /// Ends system-held Live Activities that are **not** this process's owned surface.
    ///
    /// Used when deferred ``observeExistingActivities()`` finds ``currentActivity`` already
    /// set (start raced ahead of post-init yield, or any future assignment site that did not
    /// go through ``startActivity()``'s leading ``endActivity()``). Full ``endActivity`` would
    /// clear ownership and mirrors; this path must not.
    ///
    /// - Parameter ownedActivityId: ``currentActivity`` id to preserve.
    /// - Postcondition: Owned tracking, observation, and durable mirrors are unchanged.
    ///   Sibling residuals receive final `.userPaused` ContentState and `.immediate` end.
    /// - SeeAlso: ``systemResidualIdsToReap(systemActivityIds:ownedActivityId:)``,
    ///   ``seedFinalEndChromeFromResidualActivities(_:)``, ``observeExistingActivities()``.
    private func reapUnownedSystemResiduals(preservingOwnedActivityId ownedActivityId: String) {
        let systemActivities = Activity<LutheranRadioLiveActivityAttributes>.activities
        let siblingIds = Self.systemResidualIdsToReap(
            systemActivityIds: systemActivities.map(\.id),
            ownedActivityId: ownedActivityId
        )
        guard !siblingIds.isEmpty else {
            #if DEBUG
            print("🔴 No unowned system residuals — preserving owned currentActivity id=\(ownedActivityId)")
            #endif
            return
        }

        let siblingSet = Set(siblingIds)
        let siblings = systemActivities.filter { siblingSet.contains($0.id) }
        #if DEBUG
        print("🔴 Reaping \(siblings.count) unowned residual Live Activity surface(s); preserving owned id=\(ownedActivityId)")
        #endif

        // Residual-only chrome: do not read owned lastPushedContent into the dismiss frame
        // (owned surface keeps its live chrome). Visual still forced to .userPaused.
        let residualChrome = Self.seedFinalEndChromeFromResidualActivities(siblings)
        let finalLanguage =
            residualChrome.language
            ?? SharedPlayerManager.mainAppLiveActivityLanguageCode()
        let finalContentState = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .userPaused,
            streamMetadata: residualChrome.metadata,
            currentLanguage: finalLanguage
        )
        endActivitiesInBackground(
            siblings,
            finalContentState: finalContentState,
            dismissalPolicy: .immediate
        )
    }

    /// Pure residual-id policy for cold-launch / deferred observe reaping.
    ///
    /// - Parameters:
    ///   - systemActivityIds: Ids from `Activity.activities` (system-held surfaces).
    ///   - ownedActivityId: This-process ``currentActivity`` id, or `nil` when unowned.
    /// - Returns: Ids that must be ended. When unowned, every system id. When owned, every
    ///   system id **except** the owned one (sibling residuals only).
    /// - Important: Never returns the owned id when `ownedActivityId` is non-nil — that
    ///   would reintroduce the "end our new Activity as a residual" race.
    /// - SeeAlso: ``observeExistingActivities()``, ``reapUnownedSystemResiduals(preservingOwnedActivityId:)``.
    private static func systemResidualIdsToReap(
        systemActivityIds: [String],
        ownedActivityId: String?
    ) -> [String] {
        guard let ownedActivityId else {
            return systemActivityIds
        }
        return systemActivityIds.filter { $0 != ownedActivityId }
    }

    // MARK: - Live Activity Attribute Events Observation

    /// Records a system-accepted ``ContentState`` from the attribute-events stream.
    ///
    /// Keeps ``lastPushedContent`` aligned with the Live Activity surface so
    /// ``updateCurrentActivity()`` can suppress redundant `Activity.update` IPC.
    /// Clears language-ensure quiet pending so a real acceptance moment re-arms soft
    /// reconcile if destination still lags (or confirms convergence when it matches).
    private func handleActivityContentUpdate(
        _ content: ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>
    ) {
        lastPushedContent = content.state
        // System advanced content: clear stalled streak + recreation budget + ensure quiet.
        consecutiveStalledContentPushes = 0
        interactiveContentRecreationsAttempted = 0
        // Any contentUpdates yield is an ActivityKit acceptance moment — drop quiet so a
        // subsequent ensure can re-evaluate (or stay a no-op if language/visual already match).
        languageEnsureQuietPendingDestination = nil
        playingEnsureQuietPending = false
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
            consecutiveStalledContentPushes = 0
            languageEnsureQuietPendingDestination = nil
            playingEnsureQuietPending = false
            if !isRecreatingLiveActivityAfterStalledContent {
                interactiveContentRecreationsAttempted = 0
            }
            SharedPlayerManager.clearLiveActivityToggleVisualStateMirror()
            SharedPlayerManager.clearLiveActivityLanguageMirror()
            return
        }
        #endif
        guard currentActivity != nil else { return }
        currentActivity = nil
        lastPushedContent = nil
        consecutiveStalledContentPushes = 0
        languageEnsureQuietPendingDestination = nil
        playingEnsureQuietPending = false
        if !isRecreatingLiveActivityAfterStalledContent {
            interactiveContentRecreationsAttempted = 0
        }
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

    /// Returns whether ``updateCurrentActivity()`` would suppress an ActivityKit push under
    /// the production suppress policy (``lastPushedContent`` + owned language/visual gates).
    /// Performs no IPC.
    ///
    /// - Parameters:
    ///   - visualState: Candidate visual state from the player SSOT.
    ///   - streamMetadata: Candidate ICY metadata (nil when absent).
    ///   - currentLanguage: Candidate stream language code (defaults to last-pushed language,
    ///     or ``SharedPlayerManager/mainAppLiveActivityLanguageCode()`` when unset).
    ///   - ownedContentLanguage: Simulated `currentActivity?.content.state.currentLanguage`.
    ///     Defaults to `nil` (owned-language gate skipped).
    ///   - ownedContentVisual: Simulated `currentActivity?.content.state.visualState`.
    ///     Defaults to `nil` (owned-visual gate skipped).
    /// - Returns: `true` when production would skip ActivityKit IPC for this candidate.
    /// - SeeAlso: ``shouldSuppressLiveActivityContentPush(lastPushed:candidate:ownedContentLanguage:ownedContentVisual:)``,
    ///   ``shouldEnsureAuthoritativeLanguageContent(destinationLanguage:ownedContentLanguage:lastPushedLanguage:)``.
    func _test_wouldSuppressLiveActivityUpdate(
        visualState: PlayerVisualState,
        streamMetadata: StreamProgramMetadata?,
        currentLanguage: String? = nil,
        ownedContentLanguage: String? = nil,
        ownedContentVisual: PlayerVisualState? = nil
    ) -> Bool {
        let language = currentLanguage
            ?? lastPushedContent?.currentLanguage
            ?? SharedPlayerManager.mainAppLiveActivityLanguageCode()
        let candidate = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: visualState,
            streamMetadata: streamMetadata,
            currentLanguage: language
        )
        return Self.shouldSuppressLiveActivityContentPush(
            lastPushed: lastPushedContent,
            candidate: candidate,
            ownedContentLanguage: ownedContentLanguage,
            ownedContentVisual: ownedContentVisual
        )
    }

    /// White-box seam for language-reconcile decision (no ActivityKit / no actor hop).
    ///
    /// - SeeAlso: ``shouldEnsureAuthoritativeLanguageContent(destinationLanguage:ownedContentLanguage:lastPushedLanguage:)``,
    ///   ``ensureAuthoritativeLanguageContentIfNeeded()``.
    func _test_shouldEnsureAuthoritativeLanguageContent(
        destinationLanguage: String,
        ownedContentLanguage: String?,
        lastPushedLanguage: String?
    ) -> Bool {
        Self.shouldEnsureAuthoritativeLanguageContent(
            destinationLanguage: destinationLanguage,
            ownedContentLanguage: ownedContentLanguage,
            lastPushedLanguage: lastPushedLanguage
        )
    }

    /// White-box seam: whether soft language ensure should run or stay quiet (no ActivityKit).
    func _test_shouldRunLanguageContentEnsureSoftPushes(
        needsLanguageEnsure: Bool,
        destinationLanguage: String,
        quietPendingDestination: String?,
        isRequestEligible: Bool
    ) -> Bool {
        Self.shouldRunLanguageContentEnsureSoftPushes(
            needsLanguageEnsure: needsLanguageEnsure,
            destinationLanguage: destinationLanguage,
            quietPendingDestination: quietPendingDestination,
            isRequestEligible: isRequestEligible
        )
    }

    /// White-box seam: quiet destination after soft budget exhaustion while ineligible.
    func _test_quietPendingDestinationAfterLanguageEnsureExhaustion(
        languageStillMismatches: Bool,
        isRequestEligible: Bool,
        destinationLanguage: String
    ) -> String? {
        Self.quietPendingDestinationAfterLanguageEnsureExhaustion(
            languageStillMismatches: languageStillMismatches,
            isRequestEligible: isRequestEligible,
            destinationLanguage: destinationLanguage
        )
    }

    /// White-box seam: language-only status push defer while quiet (no ActivityKit).
    func _test_shouldDeferRedundantLanguagePushWhileQuiet(
        candidateLanguage: String,
        ownedContentLanguage: String,
        ownedContentVisual: PlayerVisualState,
        candidateVisual: PlayerVisualState,
        quietPendingDestination: String?,
        isRequestEligible: Bool
    ) -> Bool {
        Self.shouldDeferRedundantLanguagePushWhileQuiet(
            candidateLanguage: candidateLanguage,
            ownedContentLanguage: ownedContentLanguage,
            ownedContentVisual: ownedContentVisual,
            candidateVisual: candidateVisual,
            quietPendingDestination: quietPendingDestination,
            isRequestEligible: isRequestEligible
        )
    }

    /// White-box seam: clear quiet after ownership / system acceptance / destination change.
    func _test_shouldClearLanguageEnsureQuietPending(
        quietPendingDestination: String?,
        destinationLanguage: String,
        ownedOrSystemLanguage: String?
    ) -> Bool {
        Self.shouldClearLanguageEnsureQuietPending(
            quietPendingDestination: quietPendingDestination,
            destinationLanguage: destinationLanguage,
            ownedOrSystemLanguage: ownedOrSystemLanguage
        )
    }

    /// White-box seam: read language ensure quiet destination (no ActivityKit).
    func _test_languageEnsureQuietPendingDestinationValue() -> String? {
        languageEnsureQuietPendingDestination
    }

    /// White-box seam: set language ensure quiet destination (no ActivityKit).
    func _test_setLanguageEnsureQuietPendingDestination(_ value: String?) {
        languageEnsureQuietPendingDestination = value
    }

    /// White-box seam: whether soft playing ensure should run (quiet / eligibility).
    func _test_shouldRunPlayingContentEnsureSoftPushes(
        needsPlayingEnsure: Bool,
        quietPending: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        Self.shouldRunPlayingContentEnsureSoftPushes(
            needsPlayingEnsure: needsPlayingEnsure,
            quietPending: quietPending,
            isRequestEligible: isRequestEligible
        )
    }

    /// White-box seam: enter playing quiet after soft budget exhaustion while ineligible.
    func _test_shouldEnterPlayingEnsureQuietPending(
        playingStillStalled: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        Self.shouldEnterPlayingEnsureQuietPending(
            playingStillStalled: playingStillStalled,
            isRequestEligible: isRequestEligible
        )
    }

    /// White-box seam: visual-only playing push defer while quiet (no ActivityKit).
    func _test_shouldDeferRedundantPlayingPushWhileQuiet(
        candidateVisual: PlayerVisualState,
        ownedContentVisual: PlayerVisualState,
        ownedContentLanguage: String,
        candidateLanguage: String,
        quietPending: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        Self.shouldDeferRedundantPlayingPushWhileQuiet(
            candidateVisual: candidateVisual,
            ownedContentVisual: ownedContentVisual,
            ownedContentLanguage: ownedContentLanguage,
            candidateLanguage: candidateLanguage,
            quietPending: quietPending,
            isRequestEligible: isRequestEligible
        )
    }

    /// White-box seam: clear playing quiet after owned visual reaches `.playing`.
    func _test_shouldClearPlayingEnsureQuietPending(
        quietPending: Bool,
        ownedOrSystemVisual: PlayerVisualState?
    ) -> Bool {
        Self.shouldClearPlayingEnsureQuietPending(
            quietPending: quietPending,
            ownedOrSystemVisual: ownedOrSystemVisual
        )
    }

    /// White-box seam: read playing ensure quiet flag (no ActivityKit).
    func _test_playingEnsureQuietPendingValue() -> Bool {
        playingEnsureQuietPending
    }

    /// White-box seam: set playing ensure quiet flag (no ActivityKit).
    func _test_setPlayingEnsureQuietPending(_ value: Bool) {
        playingEnsureQuietPending = value
    }

    /// White-box seam: clear suppress memory between tests (singleton isolation).
    func _test_clearLastPushedContent() {
        lastPushedContent = nil
    }

    /// White-box seam for post-update suppress-memory policy (no ActivityKit).
    func _test_suppressMemoryAfterActivityUpdate(
        candidate: LutheranRadioLiveActivityAttributes.ContentState,
        acceptedSystemContent: LutheranRadioLiveActivityAttributes.ContentState
    ) -> LutheranRadioLiveActivityAttributes.ContentState {
        Self.suppressMemoryAfterActivityUpdate(
            candidate: candidate,
            acceptedSystemContent: acceptedSystemContent
        )
    }

    /// White-box seam: whether system-held content still lags the submitted candidate.
    func _test_isStalledLiveActivityContentPush(
        candidate: LutheranRadioLiveActivityAttributes.ContentState,
        accepted: LutheranRadioLiveActivityAttributes.ContentState
    ) -> Bool {
        Self.isStalledLiveActivityContentPush(candidate: candidate, accepted: accepted)
    }

    /// White-box seam: recreate decision after a stalled content-push streak (streak/cap only).
    func _test_shouldRecreateInteractiveLiveActivityAfterStalledPushes(
        consecutiveStalled: Int,
        recreationsAttempted: Int,
        threshold: Int = RadioLiveActivityManager.stalledContentPushRecreationThreshold,
        maxRecreations: Int = RadioLiveActivityManager.maxInteractiveContentRecreations,
        isRecreationInProgress: Bool
    ) -> Bool {
        Self.shouldRecreateInteractiveLiveActivityAfterStalledPushes(
            consecutiveStalled: consecutiveStalled,
            recreationsAttempted: recreationsAttempted,
            threshold: threshold,
            maxRecreations: maxRecreations,
            isRecreationInProgress: isRecreationInProgress
        )
    }

    /// White-box seam: end+request only when request is eligible (never end under visibility failure).
    func _test_shouldPerformStalledContentRecreation(
        consecutiveStalled: Int,
        recreationsAttempted: Int,
        isRecreationInProgress: Bool,
        isRequestEligible: Bool,
        threshold: Int = RadioLiveActivityManager.stalledContentPushRecreationThreshold,
        maxRecreations: Int = RadioLiveActivityManager.maxInteractiveContentRecreations
    ) -> Bool {
        Self.shouldPerformStalledContentRecreation(
            consecutiveStalled: consecutiveStalled,
            recreationsAttempted: recreationsAttempted,
            isRecreationInProgress: isRecreationInProgress,
            isRequestEligible: isRequestEligible,
            threshold: threshold,
            maxRecreations: maxRecreations
        )
    }

    /// White-box seam: interactive `Activity.request` eligibility (enabled + application active).
    func _test_isInteractiveLiveActivityRequestEligible(
        areActivitiesEnabled: Bool,
        isApplicationActive: Bool
    ) -> Bool {
        Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: areActivitiesEnabled,
            isApplicationActive: isApplicationActive
        )
    }

    /// White-box seam: pending ensure after a failed start when ownership is empty.
    func _test_shouldMarkPendingInteractiveLiveActivityEnsureAfterStartAttempt(
        currentActivityIsNil: Bool
    ) -> Bool {
        Self.shouldMarkPendingInteractiveLiveActivityEnsureAfterStartAttempt(
            currentActivityIsNil: currentActivityIsNil
        )
    }

    /// White-box seam: foreground ensure-start policy (no ActivityKit).
    func _test_shouldEnsureInteractiveLiveActivityStart(
        pendingEnsure: Bool,
        hasCurrentActivity: Bool,
        sessionNeedsInteractiveLiveActivity: Bool,
        areActivitiesEnabled: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        Self.shouldEnsureInteractiveLiveActivityStart(
            pendingEnsure: pendingEnsure,
            hasCurrentActivity: hasCurrentActivity,
            sessionNeedsInteractiveLiveActivity: sessionNeedsInteractiveLiveActivity,
            areActivitiesEnabled: areActivitiesEnabled,
            isRequestEligible: isRequestEligible
        )
    }

    /// White-box seam: session-needs policy for interactive LA ensure/start.
    func _test_sessionNeedsInteractiveLiveActivity(
        isPlaying: Bool,
        visualState: PlayerVisualState
    ) -> Bool {
        Self.sessionNeedsInteractiveLiveActivity(
            isPlaying: isPlaying,
            visualState: visualState
        )
    }

    /// White-box seam: read pending ensure flag (no ActivityKit).
    func _test_pendingInteractiveLiveActivityEnsure() -> Bool {
        pendingInteractiveLiveActivityEnsure
    }

    /// White-box seam: set pending ensure flag (no ActivityKit).
    func _test_setPendingInteractiveLiveActivityEnsure(_ value: Bool) {
        pendingInteractiveLiveActivityEnsure = value
    }

    /// White-box seam: owned-surface foreground soft-ensure decision (no ActivityKit).
    func _test_shouldEnsureAuthoritativeContentOnForeground(
        hasCurrentActivity: Bool,
        destinationLanguage: String,
        ownedContentLanguage: String?,
        lastPushedLanguage: String?,
        actorVisual: PlayerVisualState,
        streamSwitchHold: Bool,
        isConnectingPlayback: Bool,
        lastPushedVisual: PlayerVisualState?,
        ownedVisual: PlayerVisualState?
    ) -> Bool {
        Self.shouldEnsureAuthoritativeContentOnForeground(
            hasCurrentActivity: hasCurrentActivity,
            destinationLanguage: destinationLanguage,
            ownedContentLanguage: ownedContentLanguage,
            lastPushedLanguage: lastPushedLanguage,
            actorVisual: actorVisual,
            streamSwitchHold: streamSwitchHold,
            isConnectingPlayback: isConnectingPlayback,
            lastPushedVisual: lastPushedVisual,
            ownedVisual: ownedVisual
        )
    }

    /// White-box seam: owned-surface foreground invoke / debounce policy (no ActivityKit).
    func _test_shouldInvokeOwnedSurfaceForegroundEnsure(
        hasCurrentActivity: Bool,
        lastOwnedSurfaceForegroundEnsureAt: Date?,
        now: Date,
        debounceInterval: TimeInterval = RadioLiveActivityManager.ownedSurfaceForegroundEnsureDebounceInterval,
        languageEnsureQuietPending: Bool,
        playingEnsureQuietPending: Bool,
        pendingInteractiveLiveActivityEnsure: Bool,
        contentEnsureStillNeeded: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        Self.shouldInvokeOwnedSurfaceForegroundEnsure(
            hasCurrentActivity: hasCurrentActivity,
            lastOwnedSurfaceForegroundEnsureAt: lastOwnedSurfaceForegroundEnsureAt,
            now: now,
            debounceInterval: debounceInterval,
            languageEnsureQuietPending: languageEnsureQuietPending,
            playingEnsureQuietPending: playingEnsureQuietPending,
            pendingInteractiveLiveActivityEnsure: pendingInteractiveLiveActivityEnsure,
            contentEnsureStillNeeded: contentEnsureStillNeeded,
            isRequestEligible: isRequestEligible
        )
    }

    /// White-box seam: eligible-only recreation after foreground soft ensure still fails.
    func _test_shouldRecreateAfterForegroundSoftEnsureFailed(
        languageStillMismatches: Bool,
        playingStillStalled: Bool,
        isRequestEligible: Bool,
        recreationsAttempted: Int,
        maxRecreations: Int = RadioLiveActivityManager.maxInteractiveContentRecreations
    ) -> Bool {
        Self.shouldRecreateAfterForegroundSoftEnsureFailed(
            languageStillMismatches: languageStillMismatches,
            playingStillStalled: playingStillStalled,
            isRequestEligible: isRequestEligible,
            recreationsAttempted: recreationsAttempted,
            maxRecreations: maxRecreations
        )
    }

    /// White-box seam: playing reconcile decision (Connecting / pause stuck → playing).
    func _test_shouldEnsureAuthoritativePlayingContent(
        actorVisual: PlayerVisualState,
        streamSwitchHold: Bool,
        isConnectingPlayback: Bool,
        lastPushedVisual: PlayerVisualState?,
        ownedVisual: PlayerVisualState?
    ) -> Bool {
        Self.shouldEnsureAuthoritativePlayingContent(
            actorVisual: actorVisual,
            streamSwitchHold: streamSwitchHold,
            isConnectingPlayback: isConnectingPlayback,
            lastPushedVisual: lastPushedVisual,
            ownedVisual: ownedVisual
        )
    }

    /// Enables termination self-healing coverage in RadioLiveActivityManagerTests without
    /// creating a real ``Activity``.
    func _test_setHarnessSimulatesActiveActivity(_ simulates: Bool) {
        _test_harnessSimulatesActiveActivity = simulates
    }

    /// Cancels synthetic attribute-events observation through the consolidated observer.
    ///
    /// Mirrors the cancellation path in ``endActivity(dismissalPolicy:waitForSystemCompletion:)``
    /// without clearing ``currentActivity`` / ``lastPushedContent`` upfront so termination
    /// hygiene can be asserted in isolation.
    func _test_cancelAttributeEventObservation() {
        activityEventObserver.cancel()
        activityObservationTask = nil
    }

    /// Pure final-end ContentState assembly for white-box tests (no ActivityKit IPC).
    ///
    /// Mirrors production language/metadata priority in ``prepareLocalLiveActivityEndState()``:
    /// last-pushed → owned activity content → residual system content (cold-launch reaping) →
    /// fallback language. Visual is always `.userPaused` so the final frame never claims live
    /// audio after the owning process leaves.
    ///
    /// - Parameters:
    ///   - lastPushed: Simulated ``lastPushedContent``.
    ///   - activityState: Simulated `currentActivity?.content.state`.
    ///   - residualState: Simulated residual system `Activity.content.state` (force-quit leftover
    ///     when local tracking is empty). Defaults to `nil`.
    ///   - fallbackLanguage: Stand-in for ``SharedPlayerManager/mainAppLiveActivityLanguageCode()``.
    /// - Returns: The ContentState that would be pushed immediately before `Activity.end`.
    /// - SeeAlso: ``endActivity(dismissalPolicy:waitForSystemCompletion:)``,
    ///   ``handleAppWillTerminate()``, ``observeExistingActivities()``,
    ///   RadioLiveActivityManagerTests.
    func _test_finalEndContentState(
        lastPushed: LutheranRadioLiveActivityAttributes.ContentState?,
        activityState: LutheranRadioLiveActivityAttributes.ContentState?,
        residualState: LutheranRadioLiveActivityAttributes.ContentState? = nil,
        fallbackLanguage: String
    ) -> LutheranRadioLiveActivityAttributes.ContentState {
        let language =
            lastPushed?.currentLanguage
            ?? activityState?.currentLanguage
            ?? residualState?.currentLanguage
            ?? fallbackLanguage
        let metadata =
            lastPushed?.streamMetadata
            ?? activityState?.streamMetadata
            ?? residualState?.streamMetadata
        return LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .userPaused,
            streamMetadata: metadata,
            currentLanguage: language
        )
    }

    /// Cold-launch residual reaping policy seam (no ActivityKit IPC).
    ///
    /// - Parameters:
    ///   - systemActivityIds: Simulated `Activity.activities` ids.
    ///   - ownedActivityId: Simulated ``currentActivity`` id, or `nil` when unowned.
    /// - Returns: Ids production would end (all when unowned; siblings only when owned).
    /// - SeeAlso: ``systemResidualIdsToReap(systemActivityIds:ownedActivityId:)``,
    ///   ``observeExistingActivities()``, ``reapUnownedSystemResiduals(preservingOwnedActivityId:)``,
    ///   RadioLiveActivityManagerTests.
    func _test_systemResidualIdsToReap(
        systemActivityIds: [String],
        ownedActivityId: String?
    ) -> [String] {
        Self.systemResidualIdsToReap(
            systemActivityIds: systemActivityIds,
            ownedActivityId: ownedActivityId
        )
    }

    /// Whether deferred observe uses full ``endActivity`` (clears ownership) vs sibling-only reaping.
    ///
    /// - Parameter hasOwnedCurrentActivity: Whether this process already holds ``currentActivity``.
    /// - Returns: `true` when full residual end runs (no ownership); `false` when only unowned
    ///   siblings are reaped while ownership is preserved.
    /// - SeeAlso: ``observeExistingActivities()``, RadioLiveActivityManagerTests.
    func _test_shouldUseFullResidualEnd(hasOwnedCurrentActivity: Bool) -> Bool {
        !hasOwnedCurrentActivity
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
    /// 1. Ensures an interactive Live Activity when pending after a deferred recreation /
    ///    failed request, or when the session still needs chrome and none is owned.
    /// 2. When ownership is already non-nil, runs soft language + playing ensure (and
    ///    eligible-only recreation if soft ensure still fails) via
    ///    ``ensureAuthoritativeContentOnForegroundIfNeeded()`` inside
    ///    ``ensureInteractiveLiveActivityIfNeeded()``.
    /// 3. Pushes the current SSOT visual state so that any remaining stale LA content
    ///    (e.g. after a long background period) is corrected before the user sees it.
    ///
    /// Under DEBUG test runs we early-return to avoid even scheduling the no-op
    /// `updateCurrentActivity` Task.
    ///
    /// - SeeAlso: ``isRunningUnderTest``, ``ensureInteractiveLiveActivityIfNeeded()``,
    ///   ``ensureAuthoritativeContentOnForegroundIfNeeded()``,
    ///   ``handleAppWillEnterBackground()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    func handleAppDidEnterForeground() {
        // Defense-in-depth: suppress foreground LA pushes under UITestMode.
        if SharedPlayerManager.isRunningInUITestMode { return }

        #if DEBUG
        if isRunningUnderTest { return }
        #endif

        Task { @MainActor in
            await ensureInteractiveLiveActivityIfNeeded()
            await updateCurrentActivity()
        }
    }

    /// Debounced foreground ensure: start an interactive Live Activity when session policy
    /// needs one and none is owned (including after a deferred recreation or failed request);
    /// when ownership is already non-nil, soft-reconcile language/visual chrome and optionally
    /// recreate when request-eligible after soft ensure still fails.
    ///
    /// **Why:** `Activity.request` can fail with a visibility-class error while the process
    /// remains lock-screen / background driven. Ending the only interactive surface then leaves
    /// permanent absence until a later start succeeds. Recording
    /// ``pendingInteractiveLiveActivityEnsure`` and retrying on become-active restores the card
    /// without inventing playback. Separately, an **owned** surface may still hold prior-stream
    /// language/visual after deferred recreation while ineligible — soft
    /// ``ensureAuthoritativeContentOnForegroundIfNeeded()`` repairs that without a second SSOT.
    /// Dual SceneDelegate hooks (will-enter-foreground + become-active) are debounced for the
    /// owned-surface path via ``shouldInvokeOwnedSurfaceForegroundEnsure`` while still
    /// consuming language/playing quiet and pending ensure on unlock.
    ///
    /// - Precondition: Main actor; not UITestMode / under-test (callers and this method guard).
    /// - Postcondition: At most one start attempt per debounce window when unowned; when owned,
    ///   at most one soft language/playing ensure cycle per owned-surface debounce window
    ///   unless quiet/pending force consume or chrome still lags while request-eligible;
    ///   pending cleared when ownership is restored, owned soft ensure runs, or the session
    ///   no longer needs interactive chrome.
    /// - Important: Does not stack multiple interactive activities — ``startActivity()`` ends
    ///   any residual before request. Does not end while request is ineligible. Does not bypass
    ///   privacy write suppression.
    /// - SeeAlso: ``startActivity()``, ``handleAppDidEnterForeground()``,
    ///   ``ensureAuthoritativeContentOnForegroundIfNeeded()``,
    ///   ``shouldInvokeOwnedSurfaceForegroundEnsure(hasCurrentActivity:lastOwnedSurfaceForegroundEnsureAt:now:debounceInterval:languageEnsureQuietPending:playingEnsureQuietPending:pendingInteractiveLiveActivityEnsure:contentEnsureStillNeeded:isRequestEligible:)``,
    ///   ``shouldEnsureInteractiveLiveActivityStart(pendingEnsure:hasCurrentActivity:sessionNeedsInteractiveLiveActivity:areActivitiesEnabled:isRequestEligible:)``,
    ///   ``sessionNeedsInteractiveLiveActivity(isPlaying:visualState:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    @MainActor
    func ensureInteractiveLiveActivityIfNeeded() async {
        if SharedPlayerManager.isRunningInUITestMode { return }
        #if DEBUG
        if isRunningUnderTest { return }
        #endif

        // Owned surface: independent of missing-card start debounce. Dual SceneDelegate hooks
        // still reconcile chrome after unlock, but ``shouldInvokeOwnedSurfaceForegroundEnsure``
        // consumes quiet/pending without re-burning soft budgets on every resign/become thrash.
        if currentActivity != nil {
            let manager = SharedPlayerManager.shared
            let destination = await manager.liveActivityLanguageCodeForContentPush()
            let ownedLanguage = currentActivity?.content.state.currentLanguage
            let lastLanguage = lastPushedContent?.currentLanguage
            let visual = await manager.currentVisualState
            let hold = await manager.isStreamSwitchPrePlayHoldActive
            let connecting = await manager.isConnectingPlayback
            let lastVisual = lastPushedContent?.visualState
            let ownedVisual = currentActivity?.content.state.visualState
            let contentStillNeeded = Self.shouldEnsureAuthoritativeContentOnForeground(
                hasCurrentActivity: true,
                destinationLanguage: destination,
                ownedContentLanguage: ownedLanguage,
                lastPushedLanguage: lastLanguage,
                actorVisual: visual,
                streamSwitchHold: hold,
                isConnectingPlayback: connecting,
                lastPushedVisual: lastVisual,
                ownedVisual: ownedVisual
            )
            let requestEligible = Self.isInteractiveLiveActivityRequestEligible(
                areActivitiesEnabled: ActivityAuthorizationInfo().areActivitiesEnabled,
                isApplicationActive: UIApplication.shared.applicationState == .active
            )
            let shouldInvoke = Self.shouldInvokeOwnedSurfaceForegroundEnsure(
                hasCurrentActivity: true,
                lastOwnedSurfaceForegroundEnsureAt: lastOwnedSurfaceForegroundEnsureAt,
                now: Date(),
                debounceInterval: Self.ownedSurfaceForegroundEnsureDebounceInterval,
                languageEnsureQuietPending: languageEnsureQuietPendingDestination != nil,
                playingEnsureQuietPending: playingEnsureQuietPending,
                pendingInteractiveLiveActivityEnsure: pendingInteractiveLiveActivityEnsure,
                contentEnsureStillNeeded: contentStillNeeded,
                isRequestEligible: requestEligible
            )
            guard shouldInvoke else {
                #if DEBUG
                print(
                    "🔴 Live Activity owned-surface foreground ensure debounced " +
                    "(quietLang=\(languageEnsureQuietPendingDestination ?? "nil") " +
                    "quietPlay=\(playingEnsureQuietPending) pending=\(pendingInteractiveLiveActivityEnsure) " +
                    "contentNeeded=\(contentStillNeeded) eligible=\(requestEligible))"
                )
                #endif
                return
            }
            lastOwnedSurfaceForegroundEnsureAt = Date()
            // Consume missing-card / soft-exhaust pending; owned soft ensure is the recovery rail.
            pendingInteractiveLiveActivityEnsure = false
            await ensureAuthoritativeContentOnForegroundIfNeeded()
            return
        }

        if let last = lastInteractiveLiveActivityEnsureAt,
           Date().timeIntervalSince(last) < Self.interactiveLiveActivityEnsureDebounceInterval {
            return
        }

        let activitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        let requestEligible = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: activitiesEnabled,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )

        let manager = SharedPlayerManager.shared
        let isPlaying = manager.loadSharedState().isPlaying
        let visualState = await manager.currentVisualState
        let sessionNeeds = Self.sessionNeedsInteractiveLiveActivity(
            isPlaying: isPlaying,
            visualState: visualState
        )

        if !sessionNeeds {
            // Stop / teardown while pending: drop the recovery flag without requesting.
            pendingInteractiveLiveActivityEnsure = false
            return
        }

        guard Self.shouldEnsureInteractiveLiveActivityStart(
            pendingEnsure: pendingInteractiveLiveActivityEnsure,
            hasCurrentActivity: currentActivity != nil,
            sessionNeedsInteractiveLiveActivity: sessionNeeds,
            areActivitiesEnabled: activitiesEnabled,
            isRequestEligible: requestEligible
        ) else {
            return
        }

        lastInteractiveLiveActivityEnsureAt = Date()
        #if DEBUG
        print(
            "🔴 Live Activity ensure-start (pending=\(pendingInteractiveLiveActivityEnsure) " +
            "sessionNeeds=\(sessionNeeds))"
        )
        #endif
        await startActivity()
    }
    
    /// Called on process termination paths (AppDelegate, SceneDelegate disconnect,
    /// and `willTerminateNotification`).
    ///
    /// Ends every system-held Live Activity with `.immediate` dismissal and **waits**
    /// (bounded) for ActivityKit to accept the final `.userPaused` ContentState + end.
    /// Without the wait, process death races the unstructured end Task and Dynamic Island
    /// / Lock Screen keep a stale interactive frame (often still `.playing`).
    ///
    /// Force-quit and OOM still bypass this callback; residual surfaces are reaped on the
    /// next cold launch via ``observeExistingActivities()``.
    ///
    /// - Cleanup Invariant: After a delivered termination callback returns, no interactive
    ///   Live Activity for this app should remain that ActivityKit can treat as live.
    ///   Widgets fall back to passive "tap to open" via the staled liveness sentinel.
    /// - SeeAlso: ``endActivity(dismissalPolicy:waitForSystemCompletion:)``,
    ///   ``observeExistingActivities()``, AppDelegate.applicationWillTerminate,
    ///   SceneDelegate.sceneDidDisconnect,
    ///   SharedPlayerManager.performSessionTeardownSynchronouslyForTermination,
    ///   docs/Widget-Presentation-Dataflow.md.
    func handleAppWillTerminate() {
        endActivity(dismissalPolicy: .immediate, waitForSystemCompletion: true)
    }
}
