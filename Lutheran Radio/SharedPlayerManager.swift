//
//  SharedPlayerManager.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 7.6.2025.
//

// SHARED: Cross-target source (main app + LutheranRadioWidgetExtension)
//
// Single physical file on disk, compiled into both targets via Xcode
// File System Synchronized Group + membershipExceptions (see project.pbxproj).
//
// Purpose:
// The central actor and Single Source of Truth for all cross-process
// playback state between the main app, home screen widgets, Control Center
// widgets, Live Activities, and App Intents.
//
// Key invariants (see detailed tables in this file):
// - `PersistedWidgetState` (nested struct) + `loadPersistedWidgetState()` /
//   `savePersistedWidgetState(...)` is the authoritative snapshot for widgets/LAs.
// - `currentPlaybackIntent` / `PlaybackIntent` + `PlayerVisualState` drive all
//   resurrection, auto-play, and UI decisions. Widget paths must go through
//   the actor's static facade or signals; never duplicate intent logic.
// - `SharedPlayerManager` is the authoritative emitter of `PlayerEvent` for the
//   player domain. The `events` stream delivers decoupled notifications of
//   significant transitions (playback intent changes and other domain events)
//   to widgets, Live Activities, UI components, and recovery logic.
// - Sticky states (`.userPaused`, `.securityLocked`, `.cleared`) block
//   resurrection until the next explicit user play.
// - Privacy: `hasActiveLutheranWidgets` gate suppresses writes when no widgets
//   are present. All data is anonymous (no timestamps/history/PII).
// - This file contains *no* security policy or validation. Security lives
//   exclusively in `Core/` (see CODING_AGENT.md "Core Framework Surface Area").
//
// - SeeAlso: `PlayerVisualState.swift` (hosts `PlayerEvent` and `PlaybackIntent`),
//   `WidgetRefreshManager.swift`, `PersistedWidgetState`, `DirectStreamingPlayer.swift`
//   (owns AVPlayer), CODING_AGENT.md (Single Source of Truth Principles + the full
//   "Cross-target shared source files (non-Core)" guidance + event-driven direction),
//   README.md (Key Files table).
//
// New termination surfaces (see forceStaleLivenessTimestampForTermination +
// isMainAppProcessRecentlyActive): centralize the "main process alive" signal used
// by widgets to decide active UI vs. passive "tap to open" launch surface.
//
// AGENT NOTE: This is one of the documented single sources of truth.
// Bypassing it for widget or playback intent logic creates drift and is
// forbidden.
//
// SSOT consolidation (eb52d3b6): PersistedWidgetState became the complete
// authoritative snapshot (visualState + currentLanguage + hasError + streamMetadata).
// Legacy keys (isPlaying, playerVisualState, currentLanguage, hasError bool)
// are now read-only fallbacks for pre-snapshot installs only.

import Foundation
import AVFoundation
import Core
#if LUTHERAN_MAIN_APP
import os
#endif

/// - Article: Shared State Management for Widgets and Extensions
///
/// `SharedPlayerManager` is a **pure dispatcher** that enables safe state sharing
/// between the main app, widgets, and Live Activities via App Groups + `UserDefaults`.
///
/// **Division of responsibilities (Single Source of Truth)**:
/// - `DirectStreamingPlayer` owns actual playback state, stream selection, error state,
///   and all mutations to the AVPlayer.
/// - `SharedPlayerManager` owns the **visual/intent state** (`currentVisualState` of type
///   `PlayerVisualState`) and is the only place that should be consulted for "what should
///   the UI/widget/Live Activity show right now?".
///
/// Core responsibilities:
/// - **Visual State SSOT**: `PlayerVisualState` (`.prePlay`, `.playing`, `.userPaused`,
///   `.thermalPaused`, `.securityLocked`) with strict "sticky .userPaused" resurrection protection.
/// - **Widget / Intent actions**: Optimistic instant feedback via App Group + Darwin notifications;
///   the main app performs the real work and persists authoritative state.
/// - **State persistence**: `saveCurrentState()` + `saveVisualState()` for cross-process sync.
/// - **Privacy**: only anonymous data; no timestamps, no history, no PII.
///
/// Usage:
/// - Main app / recovery logic: `await SharedPlayerManager.shared.play()`, `.stop()`, etc.
/// - Widgets / Live Activities / intents: `SharedPlayerManager.shared.loadSharedState()`,
///   `loadPersistedVisualStateDirect()` (snapshot-first), `forcePersistVisualState(...)` (never instantiate a player).
///
/// See also: `DirectStreamingPlayer` (actual playback), `PlayerVisualState.swift` (the visual SSOT),
/// `WidgetRefreshManager.swift`, and `RadioLiveActivityManager.swift`.
///
/// ## Formal Documentation: State Machine & App Group Persistence Model
///
/// The tables below are the authoritative reference for this component.
/// They live in the source file so they are impossible to miss or drift from
/// the implementation.
///
/// ### Resurrection Protection & State Transition Rules
///
/// **Sticky States (never auto-resume)**:
/// - `.userPaused` — explicit user pause/stop. Set in `stop()`, `markAsUserPaused()`,
///   `setUserPaused()`. Cleared only by `setUserIntentToPlay()` or widget play paths
///   that call `clearUserPausedLockIfNeeded()`.
///   (Why this guard exists: an explicit user pause action must never be overridden by
///   cold-launch, resurrection, recovery, or KVO paths.)
/// - `.securityLocked` — permanent security failure (DNS TXT fail, 403, cert error).
///   Set in `play()` guard and `setSecurityLocked()`. Persists until next explicit play
///   that passes validation.
///   (Why this guard exists: a failing security validation is authoritative and permanent
///   for this process until an explicit user play succeeds; protects the security model.)
/// - `.cleared` — explicit privacy clear. Set via `resetStateToClearedForPrivacy()`
///   (called from `clearAllLocalState`). Cleared only by explicit play paths
///   (via `clearUserPausedLockIfNeeded()`).
///   (Why this guard exists: user-initiated privacy clear is a hard resurrection
///   blocker. Post-clear the *visual* is the dedicated .cleared (blue "Cleared" pill);
///   post-clear launches use .prePlay because we remove the snapshot.)
///
/// **Cold-Launch Grace Period** (defined in this actor):
/// - `initializationSettlingPeriod = 5.0` seconds (see `Constants`)
/// - Total window = 25 seconds (see `Constants.coldLaunchWindow`)
/// - `initialPlaybackHasRun` one-shot guard prevents duplicate automatic first-play attempts.
/// - `hasCompletedTrueColdLaunchPlay` records whether the app's first cold-launch play has run
///   (DEBUG classification only; does not drive resurrection guards).
/// - The window only relaxes resurrection protection for `.prePlay`; `.userPaused` is
///   *never* bypassed, even inside the window (enforced at the top of `play()`).
///
/// Cold-launch special casing is minimal; the one-shot and window logic are
/// subordinate to `currentPlaybackIntent`.
///
/// **Key Transition Methods**:
/// - `resetToPrePlayForNewStream()` — **only** place that intentionally sets `.prePlay`
///   after first launch (language/stream switches). Also clears `initialPlaybackHasRun`.
/// - `restoreVisualStateRespectingUserIntent()` — applies inline resurrection suppression (mustSuppressResurrection ? .userPaused : current).
/// - `attemptResurrectionIfAllowed()` — recovery path used by DirectStreamingPlayer nudges;
///   still respects `shouldAutoPlayOrResume`.
///
/// See `PlayerVisualState.swift` for `shouldAutoPlayOrResume`, `mustSuppressResurrection`,
/// and the `from(status:isManualPause:...)` mapper.
///
/// **Playback intent**: `currentPlaybackIntent` (owned exclusively by this actor via
/// `updatePlaybackIntent(to:)`) is the primary decision signal in the main resurrection paths:
///
/// - `play()` (top rule, central non-cold protection, one-shot simplification; now also
///   guards on `hasExplicitTerminationSentinel()` + explicit-play flag)
/// - `attemptResurrectionIfAllowed()`
/// - `restoreVisualStateRespectingUserIntent()`
///
/// The combination of `isStickyPauseOrLock` **plus** the post-termination liveness sentinel
/// (`lastUpdateTime == 0`) is the hard, reliable blocker on *every* auto-resume /
/// state-restore / wake path (including device power-up with a visible Live Activity).
/// Widgets and Live Activities may only perform optimistic UI, persist snapshots,
/// schedule pending actions, and post Darwin notifications — zero player side effects.
///
/// The old overlapping visualState guards have been collapsed in the decision logic while
/// preserving (and making explicit) sticky `.userPaused` / `.securityLocked` resurrection
/// protection. Visual state remains the source of truth for UI/widget display.
///
/// AGENT NOTE: Every explicit user play request surface must route through
/// `userRequestedPlay()`. Update this table + the `userRequestedPlay`/`play` docs +
/// the architecture block in RadioPlayerCoordinator together on any change.
///
/// | From State      | Trigger / Event                                   | Guard / Condition                                              | To State        | Resurrection Behavior / Notes |
/// |-----------------|---------------------------------------------------|-----------------------------------------------------------------|-----------------|-------------------------------|
/// | .prePlay        | Cold launch first play                            | Security valid + inside 25s window (or first time)              | .playing        | Sets `initialPlaybackHasRun = true` |
/// | .prePlay        | Explicit user play (button, widget, Siri, etc.)   | `userRequestedPlay()` → `setUserIntentToPlay()` first           | .playing        | Clears any prior .userPaused lock |
/// | .playing        | User taps pause/stop (any surface)                | `stop()` or `markAsUserPaused()` at top of method               | .userPaused     | Immediate sticky lock + early `saveVisualState()` |
/// | .playing        | User-initiated stream/language switch             | `resetToPrePlayForNewStream()` then `play()`                    | .prePlay → .playing | Special bypass of the ".playing guard" in play() |
/// | .playing        | AV interruption, stall, or thermal event          | `attemptResurrectionIfAllowed()` or player recovery nudges      | .playing        | Only proceeds if `shouldAutoPlayOrResume` |
/// | any             | Security validation failure (DNS/403/cert)        | Inside `play()` guard or StreamingSessionDelegate 403 handler   | .securityLocked | Permanent until explicit successful play |
/// | .userPaused     | User explicitly taps play (any surface)           | `userRequestedPlay()` (all explicit surfaces: button, widget-pending+check, LA, Siri, remote, URL) | .prePlay        | Resume via `.shouldBePlaying` in `play()` (widget signals reach here via Darwin → checkForPendingWidgetActions → userRequestedPlay) |
/// | .thermalPaused  | Device cools sufficiently                         | DirectStreamingPlayer thermal recovery logic                    | .playing        | Only via `shouldAutoResumeOnThermalRecovery` |
/// | any             | App foreground, interruption.ended(.shouldResume) | `restoreVisualStateRespectingUserIntent()`                      | (unchanged or forced .userPaused) | Applies inline resurrection suppression (if mustSuppressResurrection → .userPaused). Sentinel also blocks. |
/// | any (post-term) | Device wake / power-up with Lock Screen LA visible | All auto paths (play/restore/attemptResurrection) | (no playback) | `hasExplicitTerminationSentinel()` + !explicit-this-launch is hard blocker (even for prior .playing snapshot) |
///
/// ### Persistence Keys & Ownership (App Group "group.radio.lutheran.shared")
///
/// `persistedWidgetState` is the **single authoritative snapshot** for widget and Live Activity
/// display. It carries the visual state, the current language, *and* hasError, and is written on
/// every authoritative state change from the main app as well as optimistically from widget intents.
///
/// Widget providers and Live Activities are expected to consult `loadPersistedWidgetState()` first
/// (for visual + language + metadata) and `loadSharedState()` when the combined (isPlaying, language, hasError)
/// tuple is needed. This design allows the system to operate with minimal reliance on short-lived
/// optimistic keys or freshness heuristics for normal operation.
///
/// Legacy separate keys (`playerVisualState` JSON and the standalone `currentLanguage` key) are
/// no longer written by current code paths. They exist only for compatibility with very old
/// installs that have never written a combined snapshot. The legacy "isPlaying" / "hasError" bools
/// are likewise read-only fallbacks inside `loadSharedState()` and migration; they are not written
/// by normal `performActualSave` paths.
///
/// This is the authoritative shared state model. All values are anonymous. No PII, no listening history.
///
/// ---
///
/// | Key                     | Type                  | Primary Writers                                              | Primary Readers (widgets, recovery, UI)                              | Purpose & Semantics                                          | Lifetime / Notes |
/// |-------------------------|-----------------------|--------------------------------------------------------------|----------------------------------------------------------------------|--------------------------------------------------------------|------------------|
/// | playerVisualState       | Data (JSON)           | (Legacy — no longer written)                                 | `loadPersistedVisualStateDirect()` (prefers snapshot; falls back for old installs) | Legacy visual state key. Readers prefer the combined snapshot. | Migration / compat only |
/// | persistedWidgetState    | Data (JSON)           | `savePersistedWidgetState` (from performActualSave + saveCombined); also written optimistically by widget intents | `loadPersistedWidgetState()` (strongly preferred early return in providers); snapshot also read for hasError in loadSharedState | **Single Source of Truth** for widget / Live Activity display (visualState + language + hasError) | Primary SSOT |
/// | playing (legacy)        | Bool                  | (Legacy — no longer written)                                 | `ensureVisualStateLoaded` fallback, loadSharedState (migration path only) | Legacy "is radio playing" signal. Snapshot visualState is authoritative now. | Migration / compat only |
/// | isPlaying               | Bool                  | (Legacy — no longer written by performActualSave)            | `loadSharedState`, widget timeline providers                         | Derived at read time from snapshot.visualState.isActivelyPlaying (or legacy bool fallback) | Read-only fallback for pre-snapshot installs |
/// | currentLanguage         | String (languageCode) | (Legacy — no longer written by current paths)                | Migration fallbacks only in `loadPersistedWidgetState` / `preferredWidgetLanguage` | Legacy separate language key. Snapshot + `preferredWidgetLanguage()` are the SSOT. | Migration / compat only |
/// | hasError                | Bool                  | (Inside snapshot only)                                       | `loadSharedState` (prefers PersistedWidgetState.hasError), widgets   | Permanent error flag for UI chrome. Lives inside the snapshot SSOT since extension. | Set on security or unrecoverable network failures |
/// | lastUpdateTime          | Double (epoch)        | `performActualSave`, `bumpWidgetLivenessTimestamp`, widget handlers, lifecycle hooks | Widget providers (isAppRunning 60 s check), instant-feedback expiry | Liveness heartbeat — bumped on saves and throttled unchanged-snapshot skips | Keeps widget controls alive during background playback |
/// | lastUserPauseTime | Double (epoch) | ViewController (explicit pause paths) + widget pause round-trips | Cross-process / extension readers (for compatibility); legacy barrier consumers | 8-second pause window after any user pause (recovery paths in DirectStreamingPlayer now use authoritative actor `wasRecentlyUserPaused()` instead of raw UD + defensive sync) | Prevents resurrection attempts immediately after pause |
/// | isInstantFeedback       | Bool                  | Widget handlers (`handleWidgetPlay/Stop/Switch`)             | `loadSharedState` (checked first)                                    | Signals that a widget action just occurred (optimistic UI)   | Short-lived; cleared after 15s or next authoritative save |
/// | instantFeedbackTime     | Double (epoch)        | Widget handlers                                              | `loadSharedState`                                                    | Timestamp for the instant feedback validity window           | 15-second validity window |
/// | instantFeedbackLanguage | String                | Widget handlers                                              | `loadSharedState`                                                    | Language to show during the optimistic widget update         | Matches the language of the widget action |
/// | pendingAction           | String ("play","pause","switch") | Widget intent handlers, Control Center, some ViewController paths | `getPendingAction()`, SceneDelegate, widget providers          | One-shot command from extension process to main app          | Cleared by `clearPendingAction(actionId:)` after processing |
/// | pendingActionId         | String (UUID)         | Same writers as pendingAction                                | `getPendingAction()`, `clearPendingAction()`                         | Deduplication token to handle rapid repeated taps            | Prevents double-processing on race conditions |
/// | pendingActionTime       | Double (epoch)        | Same writers as pendingAction                                | Widget providers (staleness checks)                                  | Freshness timestamp for pending actions                      | Used to ignore very old pending actions |
/// | pendingLanguage         | String                | `scheduleWidgetAction` (only for "switch")                   | `getPendingAction()`, widget providers                               | Parameter for stream switch actions                          | Only meaningful when `pendingAction == "switch"` |
///
/// **Key invariants**:
/// - The main app is always the source of truth. Widgets write optimistic visual state +
///   `pendingAction`, then the main app performs real work and writes authoritative values.
/// - `saveCurrentState()` is the primary persistence path driven by the real player.
/// - Widget / extension code should prefer `loadPersistedVisualStateDirect()` or call
///   `syncVisualStateFromPersistence()` / `refreshVisualStateFromPersistence()` before
///   trusting in-memory `currentVisualState`.

#if LUTHERAN_MAIN_APP
/// Suppresses Darwin notify echoes when the main app posts a pause notification to itself
/// after already executing `stop()`. Genuine widget-originated pauses carry `pendingAction`
/// in the App Group and are never suppressed.
enum DarwinSelfEchoGuard {
    private static let lock = OSAllocatedUnfairLock(initialState: false)

    nonisolated static func markExpectingSelfPostedPauseEcho() {
        lock.withLock { $0 = true }
    }

    /// Returns true when the notification is a main-app self-echo with no widget pending action.
    nonisolated static func shouldSuppressPauseEcho(hasPendingAction: Bool) -> Bool {
        lock.withLock { expectingEcho in
            guard expectingEcho, !hasPendingAction else {
                if hasPendingAction {
                    expectingEcho = false
                }
                return false
            }
            expectingEcho = false
            return true
        }
    }
}
#endif

/// The central actor and Single Source of Truth (SSOT) for all cross-process
/// playback state between the main app, home-screen widgets, Control Center,
/// Live Activities, and App Intents.
///
/// `SharedPlayerManager` owns **visual + intent state** only. Actual AVPlayer
/// ownership and streaming remain exclusively in `DirectStreamingPlayer`.
///
/// The manager is the authoritative emitter of `PlayerEvent`. The `events`
/// `AsyncStream` provides the decoupled, primary signal path for domain
/// transitions alongside the imperative state surface.
///
/// ### Key Invariants
/// - `PersistedWidgetState` snapshot (via `loadPersistedWidgetState` / `persistWidgetSnapshot`)
///   is the sole authoritative source for widget/Live Activity visual state + language + hasError.
/// - `currentPlaybackIntent` (via `updatePlaybackIntent(to:)`) is the SSOT for
///   "does the user want audio playing right now?" and drives all resurrection decisions.
/// - `SharedPlayerManager` emits `PlayerEvent` (starting with `playbackIntentChanged`)
///   on all intent mutations so observers can react without polling state.
/// - Sticky states (`.userPaused`, `.securityLocked`, `.cleared`) are permanent
///   resurrection blockers until the next *explicit* user play.
/// - Privacy gate via `hasActiveWidgets` suppresses all writes when no Lutheran widgets
///   are configured.
/// - No security, certificate, or DNS logic lives here (see Core/ only).
///
/// All widget providers, intents, and Live Activities **must** obtain state via the
/// documented static facades or the actor. Bypassing creates drift.
///
/// - SeeAlso: ``PlayerVisualState``, ``PlaybackIntent``, ``PlayerEvent``, ``events``,
///   `WidgetRefreshManager`, `DirectStreamingPlayer`, CODING_AGENT.md (Single Source
///   of Truth Principles + "Cross-target shared source files (non-Core)"), README.md.
///
/// Actor isolation: all mutable state is protected by the actor. Nonisolated static
/// methods are safe for widget/extension call sites and hop internally when needed.
actor SharedPlayerManager {
    /// The shared singleton instance.
    ///
    /// All access (from main app or extensions) goes through this.
    ///
    /// - Important: Never store a strong reference to an actor instance obtained another
    ///   way; always use `SharedPlayerManager.shared`.
    static let shared = SharedPlayerManager()
    
    // MARK: - Cold Launch & Resurrection Guards
    private let appLaunchTime = Date()

    /// Timing constants and thresholds used by resurrection, cold-launch, and optimistic
    /// feedback logic. Centralised so the rationale for each value is documented in one place.
    private struct Constants {
        /// Grace period immediately after launch during which .prePlay is allowed to start
        /// playback even without an explicit user intent yet (first-launch auto-play).
        /// Combined with the additional window below yields the documented 25 s cold-launch
        /// opportunity.
        static let initializationSettlingPeriod: TimeInterval = 5.0

        /// Total wall time from process launch within which the one-shot cold-launch play
        /// is permitted (and resurrection protection is relaxed for non-sticky states).
        /// After this the normal sticky .userPaused / .securityLocked / .cleared rules apply
        /// even on first launch if the user has not tapped play.
        static let coldLaunchWindow: TimeInterval = 25.0

        /// How long a widget's optimistic "instant feedback" state (written before the main
        /// app processes the Darwin notification) is trusted by loadSharedState and providers.
        /// After this the authoritative snapshot (or player) is used.
        static let instantFeedbackTimeout: TimeInterval = 15.0

        /// Default interval used by `wasRecentlyUserPaused` to suppress immediate resurrection
        /// after an explicit pause (cross-process contract also exposed via lastUserPauseTime).
        static let recentUserPauseBarrier: TimeInterval = 8.0
    }

    // MARK: - UI Test Isolation (launch argument driven)
    //
    // When the app is launched by XCUITest (Lutheran RadioUITests), the test harness
    // passes "-UITestMode" via XCUIApplication.launchArguments. This is the explicit,
    // preferred signal (per CODING_AGENT.md) to keep the player in a clean non-playing
    // state, avoid all automatic streaming, and short-circuit security-critical network
    // paths (DNS TXT via SecurityModelValidator, real URL construction, AVPlayer attach).
    //
    // This ensures:
    // - No real audio starts before tests run.
    // - No long-running DNS / cert / stream operations during `xcodebuild ... test-without-building`.
    // - Tests remain fast + deterministic.
    // - Explicit test interactions (taps) may advance visual/intent for UI assertions
    //   but never perform real network or audio.
    //
    // Security invariants are not weakened: the full validation path is taken for all
    // non-UITest launches (normal app runs, widget intents, etc.).
    //
    // - SeeAlso: Lutheran_RadioUITests.swift, ViewController.viewDidLoad (the cold-launch Task),
    //   ``play()`` (the early return before validate), DirectStreamingPlayer (isTesting + init guard),
    //   RadioLiveActivityManager (similar isRunningUnderTest pattern), CODING_AGENT.md.

    /// Returns true if this process was launched under XCUITest control.
    ///
    /// **Primary signal**: the explicit "-UITestMode" launch argument passed by
    /// XCUIApplication.launchArguments in the UI test harness (see Lutheran_RadioUITests.swift).
    ///
    /// **Fallback (DEBUG only)**: standard XCTest environment indicators. This fallback
    /// exists only to support unit tests and legacy direct "Product › Test" launches
    /// that may omit the explicit argument. In Release builds the fallback is disabled.
    ///
    /// This is the **single source of truth** for UI test isolation. All auto-play paths,
    /// eager security validation, audio session configuration, and real streaming must
    /// consult this (directly or via `DirectStreamingPlayer.isTesting`) before performing
    /// work that would start network I/O or background audio.
    ///
    /// - Important: Never duplicate the detection logic elsewhere. Add new call sites
    ///   only by calling this property or a documented thin wrapper.
    ///
    /// - Returns: `true` when the process should remain silent (no DNS, no AVPlayer,
    ///   no audio session activation, no automatic `play()`).
    ///
    /// - Note: Nonisolated and safe for early call sites during app launch (ProcessInfo
    ///   is accessible before main actor bootstrap).
    ///
    /// - SeeAlso: ``play()``, ViewController.viewDidLoad, DirectStreamingPlayer.isTesting,
    ///   CODING_AGENT.md (UI test isolation requirements + "prefer the explicit -UITestMode"),
    ///   Lutheran_RadioUITests.swift (where the argument is injected).
    nonisolated static var isRunningInUITestMode: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-UITestMode") {
            return true
        }
        #if DEBUG
        // Fallback for unit tests and direct Xcode test runs that may not pass the launch argument.
        // This block is intentionally inside #if DEBUG so Release builds have only the explicit signal.
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.processName == "xctest"
            || ProcessInfo.processInfo.processName.contains("xctest") {
            return true
        }
        #endif
        return false
    }

    // AGENT NOTE (UI Test Isolation):
    // If you add any new automatic playback path (cold-launch Task, recovery timer,
    // network-restore handler, widget-driven auto-resume, Live Activity start, etc.),
    // you MUST consult `SharedPlayerManager.isRunningInUITestMode` (or ensure the
    // caller has already short-circuited) before:
    //   • calling `play()` / `userRequestedPlay()`
    //   • constructing or replacing AVPlayer / AVPlayerItem
    //   • calling `setupAudioSession` or activating AVAudioSession
    //   • starting SecurityModelValidator / CertificateValidator work
    // Failure to do so re-introduces the 5-minute launch hang for `test-without-building`.
    // The ViewController cold-launch guard + the early return in `play()` are the
    // two primary choke points; engine methods in DirectStreamingPlayer provide defense-in-depth.

    private let initializationSettlingPeriod: TimeInterval = Constants.initializationSettlingPeriod
    private var initialPlaybackHasRun = false
    /// True after the first true cold-launch `play()` proceeds (not stream-switch or resume).
    private var hasCompletedTrueColdLaunchPlay = false

    /// Set only by explicit user play surfaces (`userRequestedPlay`, `setUserIntentToPlay`).
    /// Combined with `hasExplicitTerminationSentinel()` this makes post-termination
    /// launches require a fresh user gesture before any `DirectStreamingPlayer` work.
    /// See play() and the cold-launch guard in ViewController.
    private var hasProcessedExplicitUserPlayRequest = false
    
    // MARK: - Recent user pause (in-actor barrier for recovery paths)
    /// Authoritative timestamp for `wasRecentlyUserPaused(within:)`.
    /// The UserDefaults `lastUserPauseTime` key remains the cross-process contract for extensions.
    private var lastUserPauseTimestamp: TimeInterval = 0
    
    #if LUTHERAN_MAIN_APP
    // MARK: - Sleep Timer (main app only; implementation in SharedPlayerManager+SleepTimer.swift)
    // SwiftUI (PlaybackControlsView) presents the options dialog. All scheduling, cancellation,
    // countdown, intent management and cross-sync remain here + the coordinator glue.
    /// Active sleep timer task. Cancellable.
    var sleepTimerTask: Task<Void, Never>?
    /// Remaining seconds on the active sleep timer (for UI countdown). Nil when inactive.
    /// Mutated only by sleep-timer logic in `SharedPlayerManager+SleepTimer.swift`.
    var sleepTimerRemainingSeconds: Int?
    #endif

    // MARK: - Now Playing (Lock Screen & Control Center)
    /// Latest ICY stream title for MPNowPlayingInfoCenter (main app only).
    var nowPlayingStreamMetadata: String?
    /// Parsed program metadata shared with widgets and Live Activities.
    var currentStreamMetadata: StreamProgramMetadata?
    var remoteCommandsConfigured = false

    /// Internal implementation detail: the actual assignment that clears both ICY stash fields.
    /// Used by language-change paths so there is one place that performs this specific nil-ing.
    ///
    /// Different clear sites (privacy reset, sleep-timer elapsed, full stop-to-cleared) keep
    /// their direct assignments + surrounding comments because they have distinct semantics
    /// and postconditions.
    private func _clearIcyMetadataStash() {
        currentStreamMetadata = nil
        nowPlayingStreamMetadata = nil
        // Emission after metadata mutation (clear). Language-change and other stash
        // clears use this helper so a single place owns the nil + event.
        emit(.metadataDidUpdate(nil))
    }

    /// Clears the soft-pause ICY stash (both raw `nowPlayingStreamMetadata` and parsed
    /// `currentStreamMetadata`) when the user changes language without resuming playback.
    ///
    /// This path is taken for paused language switches (e.g. `.userPaused` state) to avoid
    /// carrying a stale program title across languages. Immediately refreshes Now Playing
    /// (main app) so the system surface shows the new language's station name.
    ///
    /// This is the dedicated, single source of truth entry point for the "language change
    /// while paused" metadata-clear + Now Playing refresh action.
    ///
    /// - Postcondition: Both metadata properties are `nil`. Now Playing info has been updated
    ///   (main-app only).
    /// - SeeAlso: ``updateNowPlayingInfo()``, `_clearIcyMetadataStash()`,
    ///   `completeStreamSwitch(stream:index:)`, `switchToStreamFromWidget(to:index:actionId:)`,
    ///   `saveCombinedWidgetState(language:)`,
    ///   CODING_AGENT.md (Single Source of Truth Principles).
    func clearSoftPauseMetadataStashForLanguageChange() async {
        _clearIcyMetadataStash()

        #if LUTHERAN_MAIN_APP
        await updateNowPlayingInfo()
        #endif
    }
    
    // MARK: - Visual State (Single Source of Truth)
    /// Single source of truth for playback intent (UI + widget + Live Activity)
    /// This prevents the "play on pause" resurrection bug when set synchronously to .userPaused
    var currentVisualState: PlayerVisualState = .prePlay
    
    /// When true, `resetToPrePlayForNewStream()` has enabled a stream-switch hold: UI stays `.prePlay`
    /// until `play()` runs. `play()` then calls `setPlaying()` when intent is `.shouldBePlaying`
    /// (same as cold launch) so KVO does not leave yellow/prePlay after attach.
    private var holdPrePlayVisualUntilPlayback = false
    
    /// True when a stream-switch tap already reset to `.prePlay` and enabled the hold
    /// (`didSelectItemAt` optimistic yellow). `completeStreamSwitch` skips a second reset.
    var isStreamSwitchPrePlayHoldActive: Bool {
        currentVisualState == .prePlay && holdPrePlayVisualUntilPlayback
    }
    
    /// Guards one-time loading of the persisted PlayerVisualState JSON (or legacy "playing" bool fallback).
    /// Required for widget/extension processes which start with a fresh actor instance (default .prePlay).
    private var hasLoadedVisualStateFromPersistence = false

    // MARK: - Playback Intent
    //
    /// Owned exclusively by this actor via `updatePlaybackIntent(to:)`.
    //
    //
    //
    private var playbackIntent: PlaybackIntent = .shouldBePlaying

    /// Read-only view of the current authoritative playback intent.
    ///
    /// This is the **single source of truth** answering "does the user currently
    /// want audio to be playing?" for the entire app + widgets + recovery paths.
    ///
    /// - Returns: The current `PlaybackIntent` (never mutated except via `updatePlaybackIntent(to:)`).
    ///
    /// - Important: All decision sites (play guards, resurrection, `canProceedWithPlayback`,
    ///   DirectStreamingPlayer recovery) must consult this rather than deriving from
    ///   `currentVisualState`.
    ///
    /// Changes to intent also produce a `playbackIntentChanged` event on the
    /// manager's `events` stream.
    ///
    /// - SeeAlso: ``updatePlaybackIntent(to:)``, ``canProceedWithPlayback()``,
    ///   ``userRequestedPlay()``, ``events``, `PlayerVisualState.swift`, CODING_AGENT.md.
    ///
    /// Actor-isolated getter.
    var currentPlaybackIntent: PlaybackIntent {
        playbackIntent
    }

    // MARK: - Player Events

    private var eventContinuation: AsyncStream<PlayerEvent>.Continuation?
    private var _events: AsyncStream<PlayerEvent>?

    /// The stream of `PlayerEvent` instances emitted by this manager.
    ///
    /// `SharedPlayerManager` is the single source of truth and authoritative
    /// emitter of `PlayerEvent` for the player domain. The stream is created
    /// once and remains valid for the lifetime of the manager. All subscribers
    /// receive events yielded after they begin consuming the stream.
    ///
    /// Access from outside the actor requires `await`.
    ///
    /// - SeeAlso: ``emit(_:)``, ``updatePlaybackIntent(to:)``, ``setPlaying()``, ``stop()``,
    ///   ``markPlaybackStoppedByStreamFailure(_:)``, ``didUpdateStreamMetadata(_:)``,
    ///   `PlayerEvent`, `PlayerVisualState.swift`, CODING_AGENT.md (Single Source of Truth
    ///   Principles, event-driven direction, cross-target shared files),
    ///   docs/Event-Driven-Refactor-Roadmap.md.
    /// - Important: Emission is always additive. Existing imperative paths
    ///   (`setPlaying`, `stop`, `setUserPaused`, `markAsUserPaused`, `saveCurrentState`,
    ///   widget/Live Activity updates, notifications) are never bypassed or altered.
    /// - Note: The continuation is retained for the actor's lifetime; late subscribers
    ///   receive only events emitted after they start consuming (replay is future work).
    public var events: AsyncStream<PlayerEvent> {
        get async {
            if let existing = _events {
                return existing
            }
            let (stream, continuation) = AsyncStream.makeStream(of: PlayerEvent.self)
            _events = stream
            eventContinuation = continuation
            return stream
        }
    }

    /// Yields a `PlayerEvent` to all current subscribers.
    ///
    /// All event production in the manager routes through this single method.
    /// This guarantees `SharedPlayerManager` remains the authoritative emitter of
    /// `PlayerEvent` (Tier 1 coverage: stream transitions, metadata, visual, persisted
    /// widget state, and intent).
    ///
    /// - Parameter event: The domain event to deliver to observers of `events`.
    ///
    /// - Postcondition: If a continuation exists, the event has been yielded to
    ///   active subscribers. No other side effects.
    ///
    /// - SeeAlso: ``events``, ``updatePlaybackIntent(to:)``, ``setPlaying()``,
    ///   ``stop()``, ``setUserPaused()``, ``markAsUserPaused()``,
    ///   ``markPlaybackStoppedByStreamFailure(_:)``, ``didUpdateStreamMetadata(_:)``,
    ///   `PlayerEvent`, CODING_AGENT.md, docs/Event-Driven-Refactor-Roadmap.md.
    ///
    /// - Important: Never call `emit` from outside this actor or from widget-only paths
    ///   that would duplicate the main-app classification. Emissions for all Tier 1
    ///   events occur after the corresponding state mutation inside this actor.
    ///   The method is internal to allow coordinated emission sites inside the
    ///   type's implementation files (e.g. SharedPlayerManager+NowPlaying.swift).
    internal func emit(_ event: PlayerEvent) {
        // Widget processes perform optimistic visual/intent writes for instant feedback
        // but must never emit; authoritative emissions (and the single stream instance
        // intended for observers) come from the main app process only.
        guard !isRunningInWidget() else { return }
        eventContinuation?.yield(event)
    }

    // MARK: - Intent-Driven Playback Execution

    /// Returns whether the player execution engine (DirectStreamingPlayer) should
    /// be allowed to start, resume, or recover playback right now.
    ///
    /// This is the **preferred** intent-driven check for all playback command paths.
    /// It is driven exclusively by `currentPlaybackIntent` (the single source of truth
    /// updated only via `updatePlaybackIntent(to:)`).
    ///
    /// Callers (DirectStreamingPlayer) should use this instead of deriving decisions
    /// from `currentVisualState.shouldAutoPlayOrResume` where possible.
    ///
    /// Sticky rules are preserved exactly: `.userPaused`, `.securityLocked`, and `.cleared`
    /// (privacy clear) are permanent blockers (via isStickyPauseOrLock) until an explicit user play
    /// action clears them. For `.cleared` the visual is the dedicated .cleared (blue) so the
    /// current session shows explicit reset confirmation; the intent alone blocks; cold-launch
    /// (no snapshot) sees .prePlay.
    /// `.sleepTimer` permits execution only while visual state is still `.playing`
    /// (active countdown); after the timer fires, explicit play is required.
    func canProceedWithPlayback() async -> Bool {
        ensureVisualStateLoaded()
        if currentPlaybackIntent.isStickyPauseOrLock { return false }
        if currentPlaybackIntent == .sleepTimer {
            return currentVisualState == .playing || holdPrePlayVisualUntilPlayback
        }
        return currentPlaybackIntent == .shouldBePlaying
    }

    /// Returns whether the user paused within the given interval (default 8 s).
    ///
    /// Recovery paths should use this instead of reading `lastUserPauseTime` from UserDefaults.
    /// Extensions continue to use the UserDefaults key for cross-process reads.
    ///
    ///
    ///
    func wasRecentlyUserPaused(within interval: TimeInterval = Constants.recentUserPauseBarrier) async -> Bool {
        // For true cold-launch or first recovery before any pause has been recorded,
        // treat as "not recently paused".
        guard lastUserPauseTimestamp > 0 else { return false }
        return Date().timeIntervalSince1970 - lastUserPauseTimestamp < interval
    }

    /// Public helper for external callers (e.g. ViewController pause paths) to record
    /// an explicit user pause timestamp into the authoritative actor state.
    ///
    /// This keeps the in-actor `lastUserPauseTimestamp` (used by recovery paths via
    /// `wasRecentlyUserPaused()`) in sync when pauses are initiated from ViewController
    /// surfaces that also need to write the raw UserDefaults key for extension readers.
    ///
    nonisolated func recordUserPauseTimestamp() async {
        await _recordUserPauseTimestampInternal()
    }
    
    private func _recordUserPauseTimestampInternal() async {
        // Purpose: record authoritative in-actor timestamp for wasRecentlyUserPaused.
        // Key constraint: cross-process readers (widgets) continue to use lastUserPauseTime in UserDefaults.
        lastUserPauseTimestamp = Date().timeIntervalSince1970
    }

    /// Single internal entry point for all playback intent transitions.
    ///
    /// This is the **only** place that mutates the private `playbackIntent` backing
    /// store. All explicit user actions and sticky state changes must flow through here.
    ///
    /// After the intent is updated, `emit(.playbackIntentChanged(intent))` is called
    /// so that the authoritative `PlayerEvent` is delivered to all observers.
    ///
    /// - Parameter intent: The new authoritative intent.
    ///
    /// - Postcondition: `currentPlaybackIntent` reflects the value (sticky rules
    ///   for userPaused/securityLocked/cleared are enforced by callers before calling).
    ///   A `playbackIntentChanged` event has been emitted when the value actually changed.
    ///
    /// - SeeAlso: ``currentPlaybackIntent``, ``canProceedWithPlayback()``, ``emit(_:)``,
    ///   ``events``, CODING_AGENT.md.
    ///
    /// Internal to the actor.
    internal func updatePlaybackIntent(to intent: PlaybackIntent) {
        if playbackIntent != intent {
            #if DEBUG
            print("[SharedPlayerManager] playbackIntent: \(playbackIntent) → \(intent)")
            #endif
            playbackIntent = intent
            // Emit because a change to the current playback intent is a significant
            // domain transition observed by widgets, Live Activities, and UI.
            emit(.playbackIntentChanged(intent))
        }
    }
    
    // MARK: - Computed Properties (nonisolated safe access)
    
    // NEW: Make sharedDefaults easily accessible (nonisolated since it's read-only & safe)
    nonisolated private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: "group.radio.lutheran.shared")
    }
    
    // Widget-safe accessors for extension processes
    nonisolated var availableStreams: [DirectStreamingPlayer.Stream] {
        return DirectStreamingPlayer.availableStreams
    }
    
    // MARK: - Initialization
    private init() {
    }
    
    // MARK: - Nonisolated Public Surface (Widget / Extension Safe)
    //
    // These entry points are safe for widget intents, timeline providers, Control Center,
    // Live Activities, and other non-actor contexts. They either perform no actor work
    // or hop internally via Task.
    
    /// Returns the authoritative visual state for widget/extension decision paths and fallbacks.
    ///
    /// - Returns: `PlayerVisualState` from the `PersistedWidgetState` snapshot when present;
    ///   falls back to legacy JSON only for pre-snapshot installs, otherwise `.prePlay`.
    ///
    /// - SeeAlso: ``loadPersistedWidgetState()``, ``persistWidgetSnapshot``,
    ///   CODING_AGENT.md.
    ///
    /// Nonisolated static — safe for widget timeline providers.
    nonisolated static func loadPersistedVisualStateDirect() -> PlayerVisualState {
        // Preferred: the unified snapshot (written from both main app and widget intents)
        if let combined = loadPersistedWidgetState() {
            return combined.visualState
        }
        // Legacy migration fallback only
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared"),
              let data = defaults.data(forKey: "playerVisualState"),
              let decoded = try? JSONDecoder().decode(PlayerVisualState.self, from: data) else {
            return .prePlay
        }
        return decoded
    }
    
    nonisolated func isRunningInWidget() -> Bool {
        #if LUTHERAN_MAIN_APP
        // Main app never owns widget intent execution; WidgetKit env covers Xcode previews only.
        return ProcessInfo.processInfo.environment["WidgetKit"] != nil
        #else
        // Widget / Live Activity extension — bundle is radio.lutheran.Lutheran-Radio.LutheranRadioWidget
        // (no ".widget" suffix), and App Intent perform() does not set WidgetKit env.
        return true
        #endif
    }

    /// Returns true when executing inside the widget extension target.
    /// Used to bypass privacy write gates for optimistic updates originating from
    /// App Intents (proof that a Lutheran widget is present and was just interacted with).
    nonisolated static func isWidgetProcess() -> Bool {
        #if LUTHERAN_MAIN_APP
        return false
        #else
        return true
        #endif
    }
    
    /// Nonisolated convenience for widget/extension code paths that run outside actor isolation
    /// (e.g. handleWidgetPlay / handleWidgetStop). Fires a quick hop to ensure the persisted state is loaded
    /// before the method does its optimistic mutation.
    nonisolated public func ensureVisualStateLoadedForWidget() {
        Task { await Self.shared.ensureVisualStateLoaded() }
    }
    
    /// Nonisolated helper that widget intents can call to persist a visual state directly.
    /// This gives the next Provider run (even before the Darwin roundtrip completes) something
    /// authoritative to load.
    ///
    /// Writes the combined `PersistedWidgetState` snapshot (visual + current preferred language).
    /// This makes the snapshot the single source of truth for both authoritative saves from the
    /// main app and optimistic updates from widget intents. Providers that check the snapshot
    /// first see correct play/pause + language immediately.
    ///
    /// Also updates the in-memory currentVisualState in this process.
    /// Forces a PersistedWidgetState snapshot write for the given visual state.
    ///
    /// - Parameters:
    ///   - state: Target visual state (typically .playing or .userPaused from widget intent).
    ///   - language: Optional explicit language code. When nil, falls back to preferredWidgetLanguage().
    ///     Passing the language the widget entry was rendered with ensures optimistic UI and
    ///     persisted snapshot stay consistent (prevents "en" appearing for fi stream in refresh logs).
    ///
    /// Widget/AppIntent callers should prefer passing a language derived from
    /// loadPersistedWidgetState() so the snapshot reflects the station the user saw/tapped.
    ///
    /// - SeeAlso: ``signalWidgetPendingAction(visualState:action:language:)``,
    ///   ``WidgetToggleRadioIntent``, CODING_AGENT.md (SSOT).
    nonisolated public func forcePersistVisualState(_ state: PlayerVisualState, language: String? = nil) {
        let lang = language ?? Self.preferredWidgetLanguage()
        Self.persistWidgetSnapshot(visualState: state, language: lang)
        // Update in-memory so the widget process sees the fresh state on the next snapshot
        // without waiting for a Darwin round-trip or a full re-load.
        Task { await Self.shared._forceSetCurrentVisualState(state) }
    }

    private func _forceSetCurrentVisualState(_ state: PlayerVisualState) {
        // Purpose: apply forced visual update from widget forcePersistVisualState path.
        // Key constraint: only invoked via Task hop from nonisolated public surface; sets the loaded guard.
        currentVisualState = state
        hasLoadedVisualStateFromPersistence = true
    }

    /// Public entry point for widget/extension providers to guarantee they read the real persisted state.
    /// Call this once at the top of any Provider method before reading currentVisualState or loadSharedState for UI decisions.
    public func syncVisualStateFromPersistence() async {
        ensureVisualStateLoaded()
    }
    
    /// Forces a fresh load of the persisted PlayerVisualState JSON from the App Group container.
    /// Widget Providers (home screen + Control) should call this before reading currentVisualState
    /// for UI decisions. It resets the one-shot guard so that updates written by forcePersistVisualState
    /// (or by the main app via saveVisualState) are seen even in long-lived extension processes.
    public func refreshVisualStateFromPersistence() async {
        hasLoadedVisualStateFromPersistence = false
        ensureVisualStateLoaded()
    }
    
    // MARK: - Public Async API
    //
    // These are the primary methods called by the main app, DirectStreamingPlayer recovery logic,
    // user intent paths, and widget action handlers (after they have performed their optimistic updates).

    /// Safe, single entry point to change the visual state from anywhere.
    /// (Notification handlers, MainActor, background tasks, etc.)
    ///
    /// - Postcondition: `currentVisualState` updated (with special thermal handling);
    ///   `.visualStateDidChange` emitted.
    ///
    /// - SeeAlso: ``applyVisualState(_:)``, ``currentVisualState``, `PlayerEvent.visualStateDidChange`,
    ///   CODING_AGENT.md, docs/Event-Driven-Refactor-Roadmap.md.
    ///
    /// AGENT NOTE: All significant visual transitions should prefer this entry or the
    /// internal apply helper so that emission is centralized and never duplicated.
    func setVisualState(_ state: PlayerVisualState) async {
        #if LUTHERAN_MAIN_APP
        if state == .thermalPaused {
            await cancelSleepTimer()
        }
        #endif
        applyVisualState(state)
    }

    /// Internal helper that performs the visual state assignment and emits the change event.
    ///
    /// Centralizes Tier 1 emission for `visualStateDidChange`. Used by `setVisualState`
    /// and by direct transition sites inside the actor after their semantic mutation.
    ///
    /// - Postcondition: `currentVisualState` set; event yielded if continuation active.
    private func applyVisualState(_ state: PlayerVisualState) {
        currentVisualState = state
        emit(.visualStateDidChange(state))
    }
    
    /// Public async entry point for playing / resuming (the execution engine).
    ///
    /// This is the central implementation of playback start. It is **not** the public
    /// entry for new explicit user requests — those must go through `userRequestedPlay()`.
    ///
    /// Responsibilities (order matters for resurrection / one-shot / intent correctness):
    /// - ensureVisualStateLoaded + (main) configureNowPlaying + cancelSleep
    /// - `clearUserPausedLockIfNeeded()` (defensive top-level clear)
    /// - Classify context (cold / streamSwitch / resume) + resurrectionProtectionRelaxed
    /// - Early returns for stickyPauseOrLock, already-playing (outside relaxed), duplicate prePlay
    /// - Security validation (DNS TXT + cert) → on fail: securityLocked + return
    /// - setPlaying() (optimistic visual)
    /// - Widget branch (optimistic) or main: soft-pause resume, alignment, setStreamAndPlay
    ///
    /// UITestMode special case: when `isRunningInUITestMode` is true (via "-UITestMode" launch arg),
    /// we short-circuit *before* the SecurityModelValidator call and never reach setStreamAndPlay.
    /// This is the primary mechanism for UI test isolation (no real audio, no DNS, deterministic launch).
    /// Visual transition to .playing is still performed for explicit userRequestedPlay taps
    /// (so tests can assert on the resulting PlayerVisualState). Auto cold-launch play is
    /// prevented earlier in ViewController.viewDidLoad.
    ///
    /// Direct calls are permitted only for the cases documented on `userRequestedPlay()`.
    ///
    /// - SeeAlso: ``userRequestedPlay()``, ``setUserIntentToPlay()``,
    ///   ``clearUserPausedLockIfNeeded()``, ``canProceedWithPlayback()``,
    ///   ``attemptResurrectionIfAllowed()``,
    ///   RadioPlayerCoordinator (canonical switch methods + shims),
    ///   ``isRunningInUITestMode``, ViewController.viewDidLoad,
    ///   CODING_AGENT.md (test isolation requirements), <doc:Architecture>, <doc:Security-Invariants>.
    ///
    /// AGENT NOTE (SSOT): After any edit to guards, classification, or early returns here,
    /// re-verify:
    ///   1. widget resume after .userPaused reaches the engine when signaled
    ///   2. cold launch still allowed exactly once via the one-shot + relaxed window
    ///   3. explicit .userPaused remains sticky even inside 25s window
    /// Cross-update the resurrection table below, userRequestedPlay doc, and
    /// coordinator architecture comment.
    func play() async {
        ensureVisualStateLoaded()
        let preserveSleepTimerForStreamSwitch =
            holdPrePlayVisualUntilPlayback && currentPlaybackIntent == .sleepTimer
        #if LUTHERAN_MAIN_APP
        await configureNowPlayingControlsIfNeeded()
        if !preserveSleepTimerForStreamSwitch {
            await cancelSleepTimer()
        } else {
            #if DEBUG
            print("[SharedPlayerManager] play() — preserving active sleep timer during stream switch")
            #endif
        }
        #endif
        
        // Note: Always clear .userPaused / .cleared / elapsed-sleep-timer locks at the absolute top of play()
        // This covers widget play, Control Center, lock screen, and Siri — everything.
        await clearUserPausedLockIfNeeded()

        // ─────────────────────────────────────────────────────────────────────────────
        // Post-termination sentinel + sticky intent hard blocker (SSOT resurrection policy)
        //
        // `currentPlaybackIntent.isStickyPauseOrLock` already covers .userPaused / .securityLocked / .cleared.
        // The `hasExplicitTerminationSentinel()` (lastUpdateTime == 0) covers the case where the prior
        // session ended via termination (power off, force-quit, willTerminate) even if the snapshot
        // visual was .playing and intent defaulted to .shouldBePlaying.
        //
        // The `hasProcessedExplicitUserPlayRequest` flag (set only by `userRequestedPlay` / `setUserIntentToPlay`)
        // allows a *fresh* explicit user gesture on this launch (widget tap, button, LA "play", Siri, etc.)
        // to proceed even after a terminated prior session.
        //
        // Why: Device wake with a visible Lock Screen Live Activity must never synthesize playback
        // intent or cause DirectStreamingPlayer to emit the tuning sound / attach a stream.
        // Widgets + LAs are permitted only UI updates, forcePersist, pending actions, and Darwin
        // notifications — zero side-effects into the player.
        //
        // See also the matching guard before `playSpecialTuningSound` in ViewController.viewDidLoad.
        // ─────────────────────────────────────────────────────────────────────────────
        if Self.hasExplicitTerminationSentinel() && !hasProcessedExplicitUserPlayRequest {
            #if DEBUG
            print("[SharedPlayerManager] play() BLOCKED — hasExplicitTerminationSentinel() && !hasProcessedExplicitUserPlayRequest (device wake / LA visible / power-up protection)")
            #endif
            return
        }

        // AGENT NOTE: Explicit user play requests must have already run setUserIntentToPlay()
        // (via `userRequestedPlay()` or by establishing an active playback intent before an
        // internal `play()` call). See the Precondition on `userRequestedPlay()`. If you are
        // adding a call to `play()` here or in a caller, confirm it is one of the four
        // permitted cases or route via the designated entry.
        
        #if DEBUG
        print("[SharedPlayerManager] SharedPlayerManager.play() ENTERED – currentPlaybackIntent = \(currentPlaybackIntent), currentVisualState = \(currentVisualState)")
        #endif
        
        // ──────────────────────────────────────────────────────────────
        // Play-context classification (DEBUG labels + one-shot guard semantics).
        // `resurrectionProtectionRelaxed` preserves the prior cold-launch window behavior.
        //
        // `isStreamSwitchPlay` is also used to suppress snapshot-driven alignment and to
        // allow model-preferred language in saves — see the switch timing contract on
        // `resetToPrePlayForNewStream` and the defensive blocks in `saveCurrentState` + play().
        let isStreamSwitchPlay = holdPrePlayVisualUntilPlayback
        let isTrueColdLaunchPlay = !hasCompletedTrueColdLaunchPlay && !isStreamSwitchPlay
        let isResumePlay = hasCompletedTrueColdLaunchPlay && !isStreamSwitchPlay
        let resurrectionProtectionRelaxed = !initialPlaybackHasRun ||
            Date().timeIntervalSince(appLaunchTime) < Constants.coldLaunchWindow
        // ──────────────────────────────────────────────────────────────
        
        // Rule: Never bypass resurrection protection for explicit sticky blockers
        // (.userPaused, .cleared privacy clear, .securityLocked), even when resurrection
        // protection is relaxed. User intent wins.
        if currentPlaybackIntent.isStickyPauseOrLock {
            #if DEBUG
            print("[SharedPlayerManager] play() blocked — explicit \(currentPlaybackIntent) (resurrection bypass ignored)")
            #endif
            return
        }

        // Resurrection protection — relaxed during the settling window or explicit play paths.
        if !resurrectionProtectionRelaxed {
            if currentPlaybackIntent.isStickyPauseOrLock {
                #if DEBUG
                print("[SharedPlayerManager] play() BLOCKED by playbackIntent = \(currentPlaybackIntent)")
                #endif
                return
            }
        } else {
            #if DEBUG
            if isTrueColdLaunchPlay {
                print("[SharedPlayerManager] Cold-launch first play – resurrection protection relaxed")
            } else if isStreamSwitchPlay {
                print("[SharedPlayerManager] Stream-switch play – resurrection protection relaxed")
            } else if isResumePlay {
                print("[SharedPlayerManager] Resume play – resurrection protection relaxed")
            }
            #endif
        }
        
        // Re-entrancy guard : Detect actual AVPlayer state to break recovery loops.
        // Intent is the primary signal; this visual check is deliberately narrow (only outside relaxed window)
        // to protect against tight recovery-task loops when the player is already playing.
        if currentVisualState == .playing && !resurrectionProtectionRelaxed {
            #if DEBUG
            print("[SharedPlayerManager] SharedPlayerManager.play() — already .playing, skipping redundant call (recovery loop prevented)")
            #endif
            return
        }
        
        // === ONE-SHOT GUARD FOR AUTOMATIC PRE-PLAY INITIAL PLAYBACK ===
        // The authoritative `currentPlaybackIntent` is the primary signal; the one-shot flag
        // only prevents duplicate automatic first-play attempts without explicit `.shouldBePlaying`.
        if currentVisualState == .prePlay {
            if initialPlaybackHasRun && !currentPlaybackIntent.isActivePlaybackIntent {
                #if DEBUG
                print("SharedPlayerManager.play() – skipping duplicate automatic prePlay playback")
                #endif
                return
            } else {
                if currentPlaybackIntent.isActivePlaybackIntent {
                    initialPlaybackHasRun = false
                } else {
                    initialPlaybackHasRun = true
                }
                #if DEBUG
                if isStreamSwitchPlay {
                    print("SharedPlayerManager.play() – stream-switch play, proceeding")
                } else if isTrueColdLaunchPlay {
                    print("SharedPlayerManager.play() – cold-launch first play, proceeding")
                } else if isResumePlay {
                    print("SharedPlayerManager.play() – resume play, proceeding")
                } else {
                    print("SharedPlayerManager.play() – prePlay play, proceeding")
                }
                #endif
                if isTrueColdLaunchPlay {
                    hasCompletedTrueColdLaunchPlay = true
                }
            }
        }

        // UI Test isolation (launch arg driven):
        // Skip security validation (DNS TXT against securitymodels.lutheran.radio + time skew + model check)
        // and the entire real streaming attach path. This is safe because:
        // - No production audio/network is allowed during UITest runs.
        // - Visual + intent state transitions are still applied for explicit interactions
        //   (so a test tap of play can observe .playing UI state without side effects).
        // - Security invariants remain fully enforced for every non-test launch.
        // The check is after sticky/one-shot guards so resurrection semantics are preserved
        // in the actor state even under test.
        //
        // AGENT NOTE: If you add new early exits here, re-verify resurrection table and
        // that explicit userRequestedPlay paths still reach setPlaying() for UITest visual assertions.
        // - SeeAlso: SharedPlayerManager.isRunningInUITestMode, ViewController (cold launch Task guard),
        //   DirectStreamingPlayer.play / setStreamAndPlay (engine no-op opportunities),
        //   CODING_AGENT.md (test isolation + launch arguments preference).
        if Self.isRunningInUITestMode {
            #if DEBUG
            print("[SharedPlayerManager] play() UITestMode — skipping SecurityModelValidator, setStreamAndPlay, and all widget/Live Activity work")
            #endif
            holdPrePlayVisualUntilPlayback = false

            // Only set minimal visual state for test assertions. Do NOT call setPlaying()
            // because it triggers Live Activities and Now Playing.
            if currentPlaybackIntent.isActivePlaybackIntent {
                currentVisualState = .playing
            }
            return
        }
        
        let isValid = await SecurityModelValidator.shared.validateSecurityModel()
        
        #if DEBUG
        print("🔐 SecurityModelValidator returned: \(isValid)")
        if !isValid {
            print("[SharedPlayerManager] Validation failed → bailing out of playback")
        } else {
            print("[SharedPlayerManager] Validation passed → proceeding with playback")
        }
        #endif
        
        guard isValid else {
            #if DEBUG
            print("[SharedPlayerManager] Permanent security validation failure — locking UI to .securityLocked")
            #endif

            #if LUTHERAN_MAIN_APP
            await cancelSleepTimer(restorePlaybackIntent: false)
            #endif
            
            // Use apply so visualStateDidChange is emitted (Tier 1).
            applyVisualState(.securityLocked)
            
            updatePlaybackIntent(to: .securityLocked)
            
            await self.saveCurrentState()
            
            #if DEBUG
            print("[SharedPlayerManager] Security lock applied – currentVisualState is now .securityLocked")
            #endif
            return
        }
        
        // Set `.playing` before stream attach so KVO/status callbacks match UI intent.
        // Stream switches enable `holdPrePlayVisualUntilPlayback` during tuning/teardown (yellow only
        // until `play()`). Once `play()` runs with explicit `.shouldBePlaying`, apply the same
        // optimistic `.playing` as cold launch — do not defer to late `startPlayback()` only.
        let hadStreamSwitchHold = holdPrePlayVisualUntilPlayback
        if hadStreamSwitchHold {
            holdPrePlayVisualUntilPlayback = false
        }
        if !hadStreamSwitchHold || currentPlaybackIntent.isActivePlaybackIntent {
            await setPlaying()
            #if DEBUG
            if hadStreamSwitchHold {
                print("[SharedPlayerManager] Visual state set to .playing before setStreamAndPlay (stream switch)")
            } else {
                print("[SharedPlayerManager] Visual state set to .playing before setStreamAndPlay")
            }
            #endif
        }
        
        if isRunningInWidget() {
            handleWidgetPlay()
            return
        }
        
        #if LUTHERAN_MAIN_APP
        await waitForTuningSoundIfActive()
        #endif
        
        #if LUTHERAN_MAIN_APP
        var declinedSoftPauseForLanguageChange = false
        if isResumePlay {
            let resumed = await DirectStreamingPlayer.shared.resumeFromSoftPauseIfAvailable()
            if resumed {
                await rehydrateStreamMetadataFromStashIfNeeded()
                #if DEBUG
                print("[SharedPlayerManager] Resumed from soft pause — skipped setStreamAndPlay")
                #endif
                return
            }
            declinedSoftPauseForLanguageChange = await DirectStreamingPlayer.shared.softPauseResumeRequiresStreamReattach()
            if declinedSoftPauseForLanguageChange {
                DirectStreamingPlayer.shared.resetInitialPlaybackCountersForNewStream()
            }
        }
        #endif

        let attachContext: PlaybackAttachContext
        #if LUTHERAN_MAIN_APP
        if isStreamSwitchPlay || declinedSoftPauseForLanguageChange {
            attachContext = .streamSwitch
        } else if isResumePlay {
            attachContext = .resume
        } else {
            attachContext = .coldLaunch
        }
        #else
        if isStreamSwitchPlay {
            attachContext = .streamSwitch
        } else if isResumePlay {
            attachContext = .resume
        } else {
            attachContext = .coldLaunch
        }
        #endif

        // Defensive alignment for *widget switch* timing only (see Widget SwitchStreamIntent optimistic
        // persist + Darwin). We condition on the *existence of a persisted snapshot* so that we only
        // override the DirectStreamingPlayer model when a widget actually wrote a fresh language choice.
        //
        // Critically, when no snapshot exists (post-clearAllLocalState, first-run, or privacy no-widgets
        // paths) we must NOT clobber here. Those paths deliberately seed selectedStream (and
        // the LanguageSelectorView needle) via preferredMainAppInitialLanguageCode() which falls back to
        // DirectStreamingPlayer.bestInitialLanguageCode() (walks Locale.preferredLanguages for a
        // supported stream: en/de/fi/sv/et). Using preferredWidgetLanguage() would force the widget
        // privacy hard-default "en" and defeat the best-fitting-language initial selection.
        // The initial persistWidgetSnapshot in the post-clear cold path is itself privacy-gated, so
        // absence of snapshot is the correct signal to trust the main-app seeding.
        //
        // Stream-switch reconciliation exception (AGENT NOTE):
        // For widget (and main-app) language switches the orchestrator *first* calls
        // switchToStream(target) — which updates the Direct model — then resetToPrePlayForNewStream
        // + play(). Alignment must not blindly re-apply a snapshot that still contains the old
        // language (written by a KVO save during the silent stop, a save that raced the widget's
        // persist, or before the model-preference in saveCurrentState took effect).
        // Guarding here + the model preference in saveCurrentState prevents the reversion.
        if !isStreamSwitchPlay {
            if let snapshot = Self.loadPersistedWidgetState() {
                let preferredLang = snapshot.currentLanguage
                if DirectStreamingPlayer.shared.selectedStream.languageCode != preferredLang {
                    let synced = Self.streamForLanguageCode(preferredLang)
                    if synced.languageCode == preferredLang {
                        #if DEBUG
                        print("[SharedPlayerManager] Aligning selectedStream to persisted widget language \(preferredLang) (was \(DirectStreamingPlayer.shared.selectedStream.languageCode)) before setStreamAndPlay")
                        #endif
                        await DirectStreamingPlayer.shared.setSelectedStreamModelOnly(to: synced)
                    }
                }
            }
        }

        let stream = DirectStreamingPlayer.shared.selectedStream
        #if DEBUG
        print("[SharedPlayerManager] Setting stream to: \(stream)")
        #endif
        
        await DirectStreamingPlayer.shared.setStreamAndPlay(to: stream, context: attachContext)
        
        // No saveCurrentState() here — observer will handle it
    }
    
    /// Forces the visual state to `.securityLocked` (permanent failure) and persists it.
    /// Called from server 403 responses or unrecoverable validation failures.
    func setSecurityLocked() async {
        #if LUTHERAN_MAIN_APP
        await cancelSleepTimer(restorePlaybackIntent: false)
        #endif
        applyVisualState(.securityLocked)
        await self.saveCurrentState()
        
        #if DEBUG
        print("[SharedPlayerManager] Security lock applied from server 403 response")
        #endif
    }
    
    /// Safe resurrection entry point used by DirectStreamingPlayer recovery logic.
    /// Allows technical recovery (hiccups) even when visualState = .playing.
    ///
    /// `playbackIntent` is now the *primary* (and sole) decision signal for this path.
    /// The old visualState guard has been removed as part of collapsing parallel checks.
    /// All sticky transitions flow through `updatePlaybackIntent(to:)`.
    ///
    /// Also blocks on `hasExplicitTerminationSentinel()` so that post-termination
    /// wakes never auto-resume even via recovery nudges.
    func attemptResurrectionIfAllowed() async {
        // UI Test isolation (SSOT): never poke the real AVPlayer or start audio from recovery paths.
        if Self.isRunningInUITestMode {
            return
        }

        ensureVisualStateLoaded()
        
        #if DEBUG
        print("[SharedPlayerManager] SharedPlayerManager.attemptResurrectionIfAllowed() – currentPlaybackIntent = \(currentPlaybackIntent), currentVisualState = \(currentVisualState)")
        #endif

        // Block explicit user pause, elapsed sleep timer, permanent security lock,
        // or post-termination launch (sentinel). The sentinel + sticky combination is the
        // required hard blocker on all auto-resume paths (see CODING_AGENT.md).
        if currentPlaybackIntent.isStickyPauseOrLock
            || (currentPlaybackIntent == .sleepTimer && currentVisualState != .playing)
            || Self.hasExplicitTerminationSentinel() {
            #if DEBUG
            print("[SharedPlayerManager] resurrection BLOCKED by playbackIntent or termination sentinel")
            #endif
            return
        }

        // Light check — if the player is already playing, do nothing
        if DirectStreamingPlayer.shared.isActuallyPlaying() {
            #if DEBUG
            print("[SharedPlayerManager] SharedPlayerManager: already actually playing — skipping redundant recovery")
            #endif
            return
        }

        #if DEBUG
        print("[SharedPlayerManager] Resurrection proceeding — player is stalled, forcing light recovery")
        #endif

        // Light recovery: just force the existing player back to life (no full validation/tuning/stream switch)
        await MainActor.run {
            DirectStreamingPlayer.shared.player?.playImmediately(atRate: 1.0)
        }
    }
    
    /// Called whenever the *user* explicitly requests playback start or resume
    /// (in-app button, lock screen, Control Center, home widgets via pending, Live Activity,
    /// Siri/Shortcuts, CarPlay, URL schemes, security retry, etc.).
    ///
    /// This is the **single authoritative explicit-play entry point**.
    ///
    /// Contract (in order):
    /// 1. (Main-app only) `configureNowPlayingControlsIfNeeded()`
    /// 2. `setUserIntentToPlay()` — forces `.prePlay` on sticky pause/clear, does
    ///    `updatePlaybackIntent(to: .shouldBePlaying)`, double-saves.
    /// 3. `play()` — the execution engine (defensive clear, classify cold/stream-switch/resume,
    ///    sticky/one-shot/security guards, setPlaying, engine drive).
    ///
    /// - Precondition: Must be used for every *explicit user* "start playing" surface.
    ///   Raw `play()` is reserved for cold-launch initial, internal continuation when
    ///   playback intent is already active (end of the canonical switch resume paths),
    ///   technical recovery via `attemptResurrectionIfAllowed()`, and the private widget
    ///   branch inside `play()`.
    ///
    /// - Postcondition: `currentPlaybackIntent` is `.shouldBePlaying` (or derived) and
    ///   (if allowed) playback proceeds or is initiated.
    ///
    /// - SeeAlso: ``play()``, ``setUserIntentToPlay()``, ``clearUserPausedLockIfNeeded()``,
    ///   ``currentPlaybackIntent``, ``attemptResurrectionIfAllowed()``,
    ///   RadioPlayerCoordinator.completeStreamSwitch,
    ///   RadioPlayerCoordinator.switchToStreamFromWidget,
    ///   CODING_AGENT.md (Single Source of Truth Principles),
    ///   <doc:Architecture>, PlayerVisualState.swift (resurrection table cross-ref).
    ///
    /// AGENT NOTE: This method + `play()` are the SSOT for playback initiation semantics.
    /// Any new call site (new intent, CarPlay, etc.) must use `userRequestedPlay()` for
    /// explicit user play. Direct `play()` (without a preceding explicit play request)
    /// is only for the four permitted internal/recovery/cold cases listed in the
    /// Precondition. Update this doc, the resurrection table, and the architecture block
    /// in RadioPlayerCoordinator together.
    /// Never duplicate the set + play sequence.
    func userRequestedPlay() async {
        #if DEBUG
        print("SharedPlayerManager.userRequestedPlay() — setUserIntentToPlay + play() for explicit user intent")
        #endif
        
        hasProcessedExplicitUserPlayRequest = true
        #if LUTHERAN_MAIN_APP
        await configureNowPlayingControlsIfNeeded()
        #endif
        await setUserIntentToPlay()
        await play()   // ← Fixed: no try/catch needed (play() is now non-throwing)
    }
    
    /// Explicitly records that the user performed a manual pause or stop.
    /// This locks `.userPaused` (sticky resurrection blocker) so that resurrection
    /// paths are blocked until the next explicit user play.
    ///
    /// Called from DirectStreamingPlayer user-action stop paths and certain
    /// coordinator surfaces. The visual + intent mutations here are the SSOT.
    ///
    /// - Postcondition: visual = .userPaused, intent = .userPaused, timestamp set,
    ///   persisted, and `streamDidPause` emitted.
    ///
    /// - SeeAlso: ``setUserPaused()``, ``stop()``, ``emit(_:)``, `PlayerEvent.streamDidPause`,
    ///   `DirectStreamingPlayer.stop(reason:)`, CODING_AGENT.md (resurrection tables).
    ///
    /// AGENT NOTE: Emission site for pause is after mutation. This method is called
    /// by the player; do not move pause decision logic here.
    func markAsUserPaused() async {
        ensureVisualStateLoaded()

        #if LUTHERAN_MAIN_APP
        await cancelSleepTimer(restorePlaybackIntent: false)
        #endif
        
        #if DEBUG
        print("[SharedPlayerManager] markAsUserPaused() called – forcing .userPaused to block resurrection")
        #endif
        
        // We are inside the actor, so mutation is allowed
        applyVisualState(.userPaused)
        
        updatePlaybackIntent(to: .userPaused)
        
        // Record authoritative pause timestamp for recovery paths.
        // This lets wasRecentlyUserPaused() return correct answers without raw UD reads.
        lastUserPauseTimestamp = Date().timeIntervalSince1970
        
        // Emission after the state mutation (visual + intent). Authoritative for
        // streamDidPause. All save / notify paths remain exactly as before.
        emit(.streamDidPause)
        
        // Persist the locked state
        await saveCurrentState()
        
        #if LUTHERAN_MAIN_APP
        await updateNowPlayingInfo()
        #endif
        
        #if DEBUG
        print("[SharedPlayerManager] Visual state locked to .userPaused")
        #endif
    }
    
    /// Public async entry point for stopping playback.
    ///
    /// Immediately locks visual state to `.userPaused` (sticky resurrection protection) and persists it,
    /// then stops the real player (main app path) or schedules the widget stop action.
    ///
    /// - Postcondition: visual + intent forced to `.userPaused`, timestamp recorded,
    ///   early visual save for widgets/LA, `DirectStreamingPlayer.stop()` invoked (main),
    ///   authoritative save performed, surfaces notified, and `streamDidStop` emitted.
    ///
    /// - SeeAlso: ``setUserPaused()``, ``markAsUserPaused()``, ``emit(_:)``,
    ///   `PlayerEvent.streamDidStop`, `DirectStreamingPlayer.stop(reason:completion:silent:)`,
    ///   CODING_AGENT.md (resurrection protection, SSOT stop path).
    ///
    /// AGENT NOTE: `.streamDidStop` is emitted here after the immediate mutation
    /// because `stop()` is the public authoritative stop entry. Widget vs main paths
    /// preserved exactly; no removal of Direct.stop() or notify/save calls.
    public func stop() async {
        ensureVisualStateLoaded()

        #if LUTHERAN_MAIN_APP
        await cancelSleepTimer(restorePlaybackIntent: false)
        #endif
        
        #if DEBUG
        print("[SharedPlayerManager] SharedPlayerManager.stop() ENTERED – currentVisualState = \(currentVisualState)")
        #endif

        // Note: Lock .userPaused IMMEDIATELY at the very top
        // This closes the race window that causes resurrection after pause
        applyVisualState(.userPaused)
        saveVisualState()   // persist early so widgets, Live Activity, and Darwin notifications see the new state

        updatePlaybackIntent(to: .userPaused)

        // Record authoritative pause timestamp (used by recovery query).
        lastUserPauseTimestamp = Date().timeIntervalSince1970

        // Emission of streamDidStop after the core mutation (visual + intent).
        // Distinguishes terminal stop from transient pause for future observers.
        // Additive only.
        emit(.streamDidStop)

        #if DEBUG
        print("[SharedPlayerManager] userPaused locked immediately in stop() (resurrection protection active)")
        #endif

        if isRunningInWidget() {
            handleWidgetStop()
            return
        }

        // Main app path — soft pause keeps the secured item for gapless same-stream resume.
        DirectStreamingPlayer.shared.stop()

        // Keep parsed metadata in the snapshot so widgets can show a subdued last-known
        // program line while paused. Raw ICY in nowPlayingStreamMetadata is unchanged
        // for same-stream soft-pause resume re-hydrate.

        // Always save after stop
        await saveCurrentState()
        
        notifyMainApp(action: "pause")
        
        #if LUTHERAN_MAIN_APP
        await updateNowPlayingInfo()

        // Event-driven LA update (decoupled from the widget snapshot write above).
        // The saveCurrentState was required for PersistedWidgetState (widgets + relaunch).
        // LA sees the fresh in-memory state and pushes only on actual difference.
        Task { @MainActor in
            await RadioLiveActivityManager.shared.updateCurrentActivity()
        }
        #endif
        
        #if DEBUG
        print("[SharedPlayerManager] stop() completed – visualState locked to .userPaused")
        #endif
    }
    
    /// Nonisolated entry point for stream switching (signaling + dispatch).
    ///
    /// - Widget / extension paths (including Live Activity intents): immediately schedule
    ///   optimistic state + pending action via App Group + Darwin. The authoritative
    ///   main-app reconciliation then happens via `RadioPlayerCoordinator.handleWidgetSwitchToLanguage`
    ///   → `switchToStreamFromWidget(to:index:actionId:)`.
    /// - Main-app forwarding (Siri, shortcuts, some legacy): forwards directly to
    ///   `DirectStreamingPlayer.switchToStream` (the engine prep SSOT).
    ///
    /// **Full UI stream choice from flag taps in the main app** must go through
    /// `RadioPlayerCoordinator.completeStreamSwitch` (via `handleLanguageSelection`)
    /// so that main-app-only tuning sound, needle animation, prePlay hold coordination,
    /// and precise `resetToPrePlayForNewStream` + `play()` timing stay owned in one place.
    ///
    /// - SeeAlso: `DirectStreamingPlayer.switchToStream`,
    ///   `RadioPlayerCoordinator.completeStreamSwitch`,
    ///   `RadioPlayerCoordinator.switchToStreamFromWidget(to:index:actionId:)`,
    ///   `RadioPlayerCoordinator.handleWidgetSwitchToLanguage`,
    ///   `RadioPlayerCoordinator.handleLanguageSelection`,
    ///   CODING_AGENT.md (Single Source of Truth Principles + "Cross-target shared source files").
    nonisolated func switchToStream(_ stream: DirectStreamingPlayer.Stream) async {
        if isRunningInWidget() {
            // Widget path must stay nonisolated and synchronous/fast
            handleWidgetSwitch(to: stream)
            return
        }
        
        // Main app path
        await DirectStreamingPlayer.shared.switchToStream(stream)
    }
    
    // MARK: - Visual State Management (User Intent)
    //
    // These methods are the canonical ways to record explicit user intent and to
    // restore state while always respecting the sticky .userPaused / .securityLocked rules.

    /// Reset to `.prePlay` (and clear the cold-launch one-shot guard) so that
    /// a real language/stream switch behaves **exactly** like the initial
    /// cold-launch playback path.
    ///
    /// - Parameters:
    ///   - preserveActiveSleepTimer: When true, the sleep timer (if any) is left running
    ///     across the switch (rare; normally false).
    ///
    /// Called from stream-switch paths (`didSelectItemAt`, `completeStreamSwitch`,
    /// `switchToStreamFromWidget`, Siri intents, widget/shortcut).
    /// Enables the cold-launch-like first-play path after a switch while preserving
    /// `.userPaused` / `.securityLocked` protection.
    ///
    /// **Switch timing contract**: Callers that are performing a language change for an
    /// *active* playback intent are expected to have already executed
    /// `DirectStreamingPlayer.switchToStream(target)` (which updates the model) before
    /// calling this method. `saveCurrentState` (called from here) and `play()` will
    /// then see the updated model and prefer it over any prior snapshot value. This is
    /// what keeps widget language switches from reverting.
    ///
    /// - Postcondition: `currentVisualState == .prePlay`, `holdPrePlayVisualUntilPlayback == true`,
    ///   `initialPlaybackHasRun == false`. A snapshot save has occurred (language update
    ///   is driven by the caller via `updateUserDefaultsLanguage` → `saveCombinedWidgetState`).
    ///
    /// Documentation modernized to reflect that cold-launch special
    /// casing is now minimal and driven by the authoritative intent model.
    ///
    /// - SeeAlso: ``play()``, ``saveCurrentState()``, CODING_AGENT.md (Single Source of Truth Principles).
    func resetToPrePlayForNewStream(preserveActiveSleepTimer: Bool = false) async {
        #if LUTHERAN_MAIN_APP
        if !preserveActiveSleepTimer {
            await cancelSleepTimer(restorePlaybackIntent: false)
        }
        #endif
        // Note: Always clear .userPaused / .cleared lock for widget pure-play actions
        // This makes widget play/pause 100% reliable (was missing in pure-play path)
        await clearUserPausedLockIfNeeded()

        applyVisualState(.prePlay)
        holdPrePlayVisualUntilPlayback = true
        initialPlaybackHasRun = false
        saveVisualState()
        await saveCurrentState()

        // NOTE: We no longer write persistedWidgetState snapshot here.
        // resetToPrePlayForNewStream is the intentional cold-launch-style reset for
        // stream switches so the next play() call gets the correct first-play path.
        // Language changes are driven by callers via updateUserDefaultsLanguage() →
        // saveCombinedWidgetState(), which is the single place that authors the atomic
        // (visual + language) snapshot. This reduces a source of potentially-stale
        // language in the snapshot (the old read of "currentLanguage" here could race
        // with the update in some call orders, e.g. widget switch handler).
        // performActualSave will still write the snapshot if it detects a language
        // change via its internal check.
        
        #if DEBUG
        print("[SharedPlayerManager] resetToPrePlayForNewStream() — state reset to .prePlay for atomic stream switch")
        #endif
    }

    /// Internal helper **only** for the privacy "clear local state" path.
    /// Performs a clean reset of visual/intent/metadata/guards to .cleared visual ("Cleared" blue pill + clear_local_state_done)
    /// + .cleared intent. **without** any persistence side-effects (no saveCurrentState, no persistWidgetSnapshot, no liveness bump).
    /// The .cleared intent (in the current process) is the hard blocker (canProceedWithPlayback, play() top guard,
    /// recovery, startPlayback etc.). Visual .cleared gives explicit post-reset confirmation in the current session
    /// (distinct from yellow connecting). A subsequent cold launch sees .prePlay because removeAllLocalPlaybackKeys
    /// + hasActiveWidgets=false + no snapshot. This prevents grey .userPaused mixing or "connect" after clear.
    /// On next launch the no-snapshot path in ensureVisualStateLoaded allows the normal cold-launch flow.
    /// SECURITY: This touches only in-memory actor state for the current process.
    func resetStateToClearedForPrivacy() {
        applyVisualState(.cleared)
        holdPrePlayVisualUntilPlayback = false
        initialPlaybackHasRun = false
        updatePlaybackIntent(to: .cleared)
        // Use the canonical clear helper (which now also emits .metadataDidUpdate(nil)).
        // Distinct from language-change: no NowPlayingInfo or widget persist here.
        _clearIcyMetadataStash()
        lastUserPauseTimestamp = 0

        #if DEBUG
        print("[SharedPlayerManager] resetStateToClearedForPrivacy — in-memory SSOT reset to .cleared (blue) + .cleared intent (no persist; .cleared blocks recovery until explicit play)")
        #endif
    }
    
    /// Called only when the user taps the play button (or widget play action).
    /// Clears the .userPaused lock so resume is allowed.
    /// Clears `.userPaused` so `play()` can proceed via explicit `.shouldBePlaying` intent.
    func setUserIntentToPlay() async {
        ensureVisualStateLoaded()

        hasProcessedExplicitUserPlayRequest = true

        #if LUTHERAN_MAIN_APP
        await cancelSleepTimer(restorePlaybackIntent: false)
        #endif
        
        #if DEBUG
        print("[SharedPlayerManager] setUserIntentToPlay() called – clearing .userPaused / .cleared lock")
        #endif
        
        if currentVisualState == .userPaused || currentPlaybackIntent == .cleared || currentVisualState == .cleared {
            applyVisualState(.prePlay)
            
            #if DEBUG
            print("[SharedPlayerManager] setUserIntentToPlay() → .prePlay with .shouldBePlaying (resume/clear path)")
            #endif
        }
        
        updatePlaybackIntent(to: .shouldBePlaying)
        
        // Widget language selection while paused relies on optimistic PersistedWidgetState.
        // Explicitly align Direct's model here (before saveCurrentState) so that:
        // - the snapshot written by this resume path carries the user-chosen language, and
        // - setStreamAndPlay later in play() sees the correct stream even if the switch
        //   reconciliation was debounced or a prior model value lingered.
        // This upholds the "switch while paused + follow-on play uses preferred-lang alignment"
        // contract documented in handleWidgetSwitch + signalWidgetSwitchAction.
        if let snapshot = Self.loadPersistedWidgetState() {
            let preferredLang = snapshot.currentLanguage
            if !preferredLang.isEmpty,
               DirectStreamingPlayer.shared.selectedStream.languageCode != preferredLang {
                let synced = Self.streamForLanguageCode(preferredLang)
                if synced.languageCode == preferredLang {
                    #if DEBUG
                    print("[SharedPlayerManager] setUserIntentToPlay alignment: using persisted lang \(preferredLang) (was \(DirectStreamingPlayer.shared.selectedStream.languageCode))")
                    #endif
                    await DirectStreamingPlayer.shared.setSelectedStreamModelOnly(to: synced)
                }
            }
        }
        
        saveVisualState()
        await saveCurrentState()
    }
    
    /// Records that playback stopped due to stream failure (decode/network), not explicit user pause.
    ///
    /// Grey `.userPaused` visual supports error UI; `playbackIntent` stays unchanged (typically
    /// `.shouldBePlaying`) so language switches can auto-resume without an extra play tap.
    /// Does not bump `lastUserPauseTimestamp` — stream failure is not a sticky user pause.
    ///
    /// Emission of the classified `streamDidFail` occurs here after the mutation. This is the
    /// existing surface that DirectStreamingPlayer calls (passing the value it classified via
    /// `StreamErrorType.from(error:)`) for terminal failures.
    ///
    /// - Parameter errorType: The classified failure owned and computed by the player.
    ///   Default preserves behavior for coordinator/test call sites.
    ///
    /// - Postcondition: `currentVisualState == .userPaused`; `playbackIntent` unchanged;
    ///   snapshot saved; `.streamDidFail(errorType)` emitted via the authoritative emitter.
    ///   All classification, early-window retry, recreate, and stop decisions remain in
    ///   `DirectStreamingPlayer`.
    ///
    /// - SeeAlso: ``emit(_:)``, ``events``, `PlayerEvent.streamDidFail`,
    ///   ``setPlaying()``, ``stop()``, ``setUserPaused()``, ``markAsUserPaused()``,
    ///   `DirectStreamingPlayer.StreamErrorType`, `DirectStreamingPlayer.handleItemStatusFailure(_:)`,
    ///   `DirectStreamingPlayer.handleLoadingError(_:)`,
    ///   CODING_AGENT.md (Tier 1: "enhance the signature of the existing markPlaybackStoppedByStreamFailure" and "update its existing call sites in DirectStreamingPlayer"),
    ///   docs/Event-Driven-Refactor-Roadmap.md.
    ///
    /// AGENT NOTE: Single source of truth. Emission after mutation inside this existing method.
    /// No new Direct-called emission API. Classification logic never leaves DirectStreamingPlayer.
    func markPlaybackStoppedByStreamFailure(_ errorType: DirectStreamingPlayer.StreamErrorType = .permanentFailure) async {
        ensureVisualStateLoaded()

        #if DEBUG
        print("[SharedPlayerManager] markPlaybackStoppedByStreamFailure() — visual .userPaused, intent unchanged (\(playbackIntent))")
        #endif

        applyVisualState(.userPaused)

        // Emission *after* the state mutation (visual). This is the required location.
        // The payload carries the exact classified value from the player.
        emit(.streamDidFail(errorType))

        saveVisualState()
        await saveCurrentState()
        #if LUTHERAN_MAIN_APP
        await updateNowPlayingInfo()
        #endif
    }

    /// Sets the visual state to `.userPaused` (sticky) and the playback intent
    /// to `.userPaused`, records the pause timestamp, persists the snapshot, and
    /// notifies surfaces.
    ///
    /// This is the canonical surface for recording an explicit user-initiated pause
    /// (from DirectStreamingPlayer mark paths, remote commands, etc.).
    ///
    /// - Postcondition: visual = .userPaused, intent = .userPaused, timestamp recorded,
    ///   snapshot written, and `streamDidPause` emitted.
    ///
    /// - SeeAlso: ``markAsUserPaused()``, ``stop()``, ``emit(_:)``,
    ///   `PlayerEvent.streamDidPause`, `DirectStreamingPlayer.markAsUserPaused()`,
    ///   CODING_AGENT.md.
    ///
    /// AGENT NOTE: `.streamDidPause` is emitted after the mutation here. Callers
    /// (including Direct) continue to invoke `setUserPaused()` unchanged.
    func setUserPaused() async {
        ensureVisualStateLoaded()

        #if LUTHERAN_MAIN_APP
        await cancelSleepTimer(restorePlaybackIntent: false)
        #endif
        applyVisualState(.userPaused)
        
        updatePlaybackIntent(to: .userPaused)
        
        // Record authoritative pause timestamp.
        lastUserPauseTimestamp = Date().timeIntervalSince1970
        
        // Emission after state mutation. Authoritative emitter site for pause.
        // Additive: saveCurrentState + NowPlaying + LA paths are unaltered.
        emit(.streamDidPause)
        
        saveVisualState()
        await saveCurrentState()
        #if LUTHERAN_MAIN_APP
        await updateNowPlayingInfo()

        // Event-driven LA update after the widget-persisting save. The LA manager's
        // last-pushed comparison ensures we only perform ActivityKit work when the
        // visible content (status + controls) actually changed.
        Task { @MainActor in
            await RadioLiveActivityManager.shared.updateCurrentActivity()
        }
        #endif
    }
    
    /// Sets the visual state to `.playing` (and the intent to `.shouldBePlaying`
    /// unless a sleep timer is active) and persists the authoritative snapshot.
    ///
    /// Call after successful playback start or resume from the engine
    /// (`DirectStreamingPlayer.startPlayback` / `resumeFromSoftPauseIfAvailable`).
    ///
    /// - Postcondition: `currentVisualState == .playing` (except in UITestMode),
    ///   intent updated if appropriate, snapshot saved, Now Playing / Live Activity
    ///   surfaces notified (main app), and `streamDidStart` emitted.
    ///
    /// - SeeAlso: ``emit(_:)``, `DirectStreamingPlayer.startPlayback(context:)`,
    ///   ``play()``, ``markPlaybackStoppedByStreamFailure(_:)``, `PlayerEvent.streamDidStart`,
    ///   CODING_AGENT.md (SSOT for visual/intent, additive event emission).
    ///
    /// AGENT NOTE: Emission of `.streamDidStart` occurs here (after visual + intent
    /// mutation) because `setPlaying` is the canonical surface called by the player
    /// on successful streaming state transition to active. Do not duplicate in callers.
    /// Existing LA/NowPlaying/save paths are untouched.
    func setPlaying() async {
        // UI Test isolation (SSOT): never trigger Live Activities, Now Playing, or widget saves.
        // Visual is still set to .playing for explicit test assertions that observe
        // currentVisualState after a userRequestedPlay tap.
        if Self.isRunningInUITestMode {
            currentVisualState = .playing
            return
        }

        ensureVisualStateLoaded()
        holdPrePlayVisualUntilPlayback = false
        applyVisualState(.playing)
        
        if playbackIntent != .sleepTimer {
            updatePlaybackIntent(to: .shouldBePlaying)
        }
        
        // Emission after the core state mutation (visual + intent). This is the
        // authoritative site for "underlying streaming state became active".
        // Additive only: all prior save/NowPlaying/LA logic continues exactly.
        emit(.streamDidStart)
        
        saveVisualState()
        await saveCurrentState()
        #if LUTHERAN_MAIN_APP
        await updateNowPlayingInfo()

        // Drive Live Activity via the decoupled in-memory path.
        // We still performed the widget PersistedWidgetState save above (required for
        // widgets + liveness + relaunch). The LA surface now receives its own immediate
        // push (with change detection inside the manager) without depending on that write.
        // Start the Activity on the first successful transition to .playing.
        Task { @MainActor in
            if RadioLiveActivityManager.shared.currentActivity == nil {
                await RadioLiveActivityManager.shared.startActivity()
            } else {
                await RadioLiveActivityManager.shared.updateCurrentActivity()
            }
        }
        #endif
    }
    
    /// Safe restoration – ALWAYS respects .userPaused and blocks resurrection.
    /// Call this on:
    /// - App/scene foreground
    /// - AVAudioSession interruption .shouldResume
    /// - Widget timeline reload
    /// - Any other system resume signal
    ///
    /// Primary signal is now `currentPlaybackIntent`. The method is
    /// intentionally simple because most resurrection complexity has been collapsed
    /// Resurrection complexity lives in `currentPlaybackIntent`.
    func restoreVisualStateRespectingUserIntent() async {
        ensureVisualStateLoaded()
        
        // Combined blocker: sticky intent OR post-termination sentinel.
        // Prevents foreground / interruption.ended / wake paths from resurrecting playback
        // when the prior session ended via termination or the user had paused.
        // Widgets/Live Activities may still render from PersistedWidgetState; only the
        // player is blocked.
        if currentPlaybackIntent.isStickyPauseOrLock
            || (currentPlaybackIntent == .sleepTimer && currentVisualState != .playing)
            || Self.hasExplicitTerminationSentinel() {
            #if DEBUG
            print("[SharedPlayerManager] restoreVisualStateRespectingUserIntent BLOCKED by playbackIntent or termination sentinel")
            #endif
            return
        }
        
        // If we already loaded something sticky from JSON, keep it; otherwise do the normal restore logic.
        if !hasLoadedVisualStateFromPersistence {
            let loaded = loadVisualState()
            if loaded.mustSuppressResurrection {
                currentVisualState = .userPaused
            } else {
                currentVisualState = loaded
            }
        }
        
        saveVisualState()
        await saveCurrentState()
        
        if currentVisualState.mustSuppressResurrection {
            #if DEBUG
            print("[SharedPlayerManager] Resurrection suppressed — userPaused is sticky")
            #endif
        } else if currentVisualState.shouldAutoPlayOrResume {
            #if DEBUG
            print("[SharedPlayerManager] ▶ Allowed to resume playback")
            #endif
        }
    }
    
    // MARK: - Private Visual State Loading Guard
    
    /// Ensures the authoritative visual state is loaded from UserDefaults persistence.
    /// Safe to call repeatedly; only does work the first time per process (or after explicit reset).
    /// Widget providers and widget-side play/stop paths must call this (directly or via sync)
    /// before trusting currentVisualState.
    ///
    /// This method feeds the intent-driven paths. Any legacy fallback
    /// is only for very old installs that never wrote a PersistedWidgetState snapshot.
    private func ensureVisualStateLoaded() {
        // Run legacy isPlaying → PersistedWidgetState migration early. This is the primary
        // restoration point for actor-owned currentVisualState / currentPlaybackIntent on
        // cold launch and after process resurrection. Safe and idempotent.
        Self.migrateLegacyIsPlayingIfNeeded()

        guard !hasLoadedVisualStateFromPersistence else { return }
        
        // Remember if we already have an explicit sticky pause/lock in memory (from stop/mark).
        // We must not let a forced re-load from persistence (e.g. refreshVisualStateFromPersistence
        // called from widget providers or lifecycle) regress us back to a stale .prePlay snapshot
        // that was written during an earlier connecting or switch moment. This was a source of
        // "paused → KVO stopped → yellow prePlay + en lang" flips.
        let hadStickyUserPause = currentVisualState == .userPaused
        
        // Combined snapshot is authoritative — including `.prePlay` (cold launch / connecting).
        // Do not treat `.prePlay` as “missing data”; the old `loaded != .prePlay` branch wrongly
        // mapped snapshot prePlay + legacy playing=false to `.userPaused` (grey pause on launch).
        if let combined = Self.loadPersistedWidgetState() {
            var loadedVisual = combined.visualState
            // Defensive anti-regression for *user pause only*: if we had an explicit sticky .userPaused
            // in memory (from stop/mark) and the snapshot contains .prePlay (stale from prior switch/cold),
            // keep the grey paused visual and re-establish the intent. (Post-clear relaunches have no snapshot
            // and fall through to the .prePlay default below; the in-process clear uses .userPaused
            // visual + .cleared intent directly.) Security uses its own red visual.
            if hadStickyUserPause && loadedVisual == .prePlay {
                loadedVisual = .userPaused
            }
            currentVisualState = loadedVisual
            // Set the playback intent from persisted visual for sticky pause/lock cases.
            // This ensures `currentPlaybackIntent.isStickyPauseOrLock` (and thus canProceedWithPlayback
            // + recovery guards) remains correct after process resurrection, ensure calls from KVO
            // status paths, or widget timeline reloads. The snapshot is the SSOT for what to *show*;
            // syncing the intent here makes the blocker survive without requiring the full intent to
            // be stored in PersistedWidgetState.
            if currentVisualState == .userPaused {
                updatePlaybackIntent(to: .userPaused)
            } else if currentVisualState == .securityLocked {
                updatePlaybackIntent(to: .securityLocked)
            }
        } else if let data = sharedDefaults?.data(forKey: "playerVisualState"),
                  let decoded = try? JSONDecoder().decode(PlayerVisualState.self, from: data) {
            currentVisualState = decoded
        } else {
            // No snapshot (brand-new install or post-clearAllLocalState privacy clear, or
            // widgets were never added / snapshot was wiped) and no legacy JSON: treat as
            // clean first-play opportunity. This ensures the cold-launch "initial playback"
            // path (tuning + play() after the visual==.prePlay guard) works on launch when
            // there is no persisted widget state. The .cleared blocker from an in-process
            // clear lives only in the current actor instance; on relaunch we get a fresh
            // start with .prePlay (same as a fresh post-clear launch) and the initial locale stream.
            // Post-clear launches must not re-create deleted data (snapshot, lastUpdateTime,
            // etc.) until an explicit play or the successful post-clear cold-start play path.
            currentVisualState = .prePlay
            if currentPlaybackIntent.isStickyPauseOrLock {
                updatePlaybackIntent(to: .shouldBePlaying)
            }
        }
        
        hasLoadedVisualStateFromPersistence = true
        
        #if DEBUG
        if isRunningInWidget() {
            print("[SharedPlayerManager] [Widget] ensureVisualStateLoaded → currentVisualState = \(currentVisualState)")
        }
        #endif
    }
    
    // MARK: - Private Helpers for Playback Control
    
    /// Clears sticky pause/clear resurrection locks (.userPaused or .cleared) when an
    /// explicit user play action (widget, button, Siri, etc.) requests playback.
    /// Also handles sleepTimer special case. Called from play() and widget play paths.
    public func clearUserPausedLockIfNeeded() async {
        ensureVisualStateLoaded()

        // Keep .sleepTimer through stream-switch prePlay (yellow) and active playback.
        if currentPlaybackIntent == .sleepTimer {
            if currentVisualState == .playing || holdPrePlayVisualUntilPlayback {
                return
            }
        }

        guard currentVisualState == .userPaused
            || currentPlaybackIntent == .cleared
            || currentPlaybackIntent == .sleepTimer else { return }

        #if DEBUG
        print("[SharedPlayerManager] Cleared sticky lock for explicit play (visual=\(currentVisualState), intent=\(currentPlaybackIntent))")
        #endif

        if currentVisualState == .userPaused || currentPlaybackIntent == .cleared || currentVisualState == .cleared {
            applyVisualState(.prePlay)
        }

        updatePlaybackIntent(to: .shouldBePlaying)
    }
    
    #if LUTHERAN_MAIN_APP
    /// Waits for an active tuning clip to finish (delegate-driven) before main stream attach.
    /// No-op when ViewController already awaited the same clip (e.g. stream switch after `playTuningSound`).
    private func waitForTuningSoundIfActive() async {
        await TuningSoundCoordinator.shared.waitForActivePlaybackToFinishIfNeeded()
    }
    #endif
    
    private func handleWidgetPlay() {
        ensureVisualStateLoadedForWidget()
        
        // Instant visual feedback for widget
        Self.writeInstantFeedback(language: Self.preferredWidgetLanguage())
        
        // Important: Optimistic SSOT update (same pattern we already use in stop)
        applyVisualState(.playing)
        
        updatePlaybackIntent(to: .shouldBePlaying)
        
        saveVisualState()
        
        scheduleWidgetAction(action: "play")
        notifyMainApp(action: "play")
        
        // Small delay + optimistic widget refresh using the modern API
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            // Architectural shift: Prefer combined snapshot for optimistic language (no direct old key)
            let language = Self.preferredWidgetLanguage()
            
            await WidgetRefreshManager.shared.refreshIfNeeded(
                visualState: .playing,           // ← modern path
                currentLanguage: language,
                hasError: false,
                immediate: true
            )
            
            saveFireAndForget()
        }
    }
    
    private func handleWidgetStop() {
        ensureVisualStateLoadedForWidget()
        
        // Instant visual feedback for widget using the new authoritative state
        Self.writeInstantFeedback(language: Self.preferredWidgetLanguage())
        
        // Important: Set the paused state synchronously for widget path
        applyVisualState(.userPaused)
        
        updatePlaybackIntent(to: .userPaused)
        
        // Record authoritative pause timestamp for recovery paths.
        lastUserPauseTimestamp = Date().timeIntervalSince1970
        
        saveVisualState()
        
        scheduleWidgetAction(action: "pause")
        notifyMainApp(action: "pause")
        
        // Small delay + optimistic widget refresh using the modern API
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            // Architectural shift: Prefer combined snapshot for optimistic language (no direct old key)
            let language = Self.preferredWidgetLanguage()
            
            await WidgetRefreshManager.shared.refreshIfNeeded(
                visualState: currentVisualState,   // already .userPaused
                currentLanguage: language,
                hasError: false,
                immediate: true
            )
        }
    }
    
    // This helper must be nonisolated because it's called from the nonisolated switchToStream
    nonisolated private func handleWidgetSwitch(to stream: DirectStreamingPlayer.Stream) {
        // Preserve the current play/pause (or other) visual across language switch for the
        // optimistic PersistedWidgetState snapshot. Must use loadPersistedVisualStateDirect()
        // (prefers the combined snapshot written by widget pause/play signals via
        // forcePersistVisualState / persistWidgetSnapshot) rather than loadSharedState().isPlaying.
        //
        // Historical: the legacy "isPlaying" bool (written only by older performActualSave paths)
        // lagged after widget pause (snapshot would be .userPaused but the bool stayed true).
        // This caused "pause on widget → language switch on widget → resume on widget" to
        // erroneously synthesize a .playing snapshot. The migration to snapshot-as-SSOT
        // (visualState carried inside persistedWidgetState) eliminated the desync.
        //
        // Using the snapshot visual ensures switch while paused carries .userPaused + new
        // language; the follow-on "play" pending + preferred-lang alignment inside play()
        // then starts the correct stream.
        let visualForSwitch = Self.loadPersistedVisualStateDirect()
        signalWidgetSwitchAction(visualState: visualForSwitch, language: stream.languageCode)

        #if DEBUG
        print("[SharedPlayerManager] Widget stream switch scheduled: \(stream.languageCode)")
        #endif
    }
    
    // MARK: - Widget Action Scheduling & Darwin Notifications (nonisolated)
    //
    // These methods schedule work for the main app via App Group + Darwin notifications.
    // They are deliberately nonisolated so widget intent handlers can call them without
    // crossing the actor boundary on the hot path.

    /// Writes the short-lived instant-feedback keys used by widget providers for optimistic UI.
    nonisolated static func writeInstantFeedback(language: String) {
        // Privacy gate (write suppression: no widgets configured).
        //
        // Bypass in widget process for the same reason as persistWidgetSnapshot: the executing
        // intent is proof a widget exists; we must allow the instantFeedbackLanguage + liveness
        // so loadSharedState + providers see fresh optimistic state without main-app roundtrip.
        guard Self.hasActiveWidgets || Self.isWidgetProcess() else {
            if !Self.isWidgetProcess() {
                Self.refreshHasActiveWidgetsStatus()
            }
            #if DEBUG
            print("[SharedPlayerManager] Suppressing instant feedback write (no active widgets configured — write suppression)")
            #endif
            return
        }
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return }
        let now = Date().timeIntervalSince1970
        defaults.set(now, forKey: "lastUpdateTime")
        defaults.set(true, forKey: "isInstantFeedback")
        defaults.set(now, forKey: "instantFeedbackTime")
        defaults.set(language, forKey: "instantFeedbackLanguage")
        // Explicit synchronize() removed — unnecessary for App Group + Darwin on iOS 26+.
    }

    /// Refreshes the App Group `lastUpdateTime` heartbeat used by widget `isAppRunning()` (60 s window).
    /// Throttled by default so unchanged-snapshot save skips do not spam UserDefaults on every KVO tick.
    nonisolated static func bumpWidgetLivenessTimestamp(
        force: Bool = false,
        minInterval: TimeInterval = 30
    ) {
        // Privacy gate: suppress liveness timestamp (and thus "app was recently running" signal) when no widgets installed.
        //
        // Bypass when in widget process: widget intent (play/pause) must bump lastUpdateTime so that
        // isAppRunning() (used by all widget sizes to decide between controls vs "tap_to_open") returns
        // true immediately. Without this, tapping play on a widget could leave the widget stuck showing
        // the tap prompt even while audio plays.
        guard Self.hasActiveWidgets || Self.isWidgetProcess() else {
            #if DEBUG
            print("[SharedPlayerManager] Suppressing liveness timestamp bump (no active widgets — write suppression)")
            #endif
            return
        }
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return }
        let now = Date().timeIntervalSince1970
        if !force,
           let last = defaults.object(forKey: "lastUpdateTime") as? Double,
           now - last < minInterval {
            return
        }
        defaults.set(now, forKey: "lastUpdateTime")
        // Explicit synchronize() removed — unnecessary for App Group + Darwin on iOS 26+.
    }

    /// Unconditional liveness bump for lifecycle edges (background, foreground) where the widget
    /// must not flip to the offline prompt while audio continues.
    func recordWidgetLiveness() {
        Self.bumpWidgetLivenessTimestamp(force: true)
    }

    // MARK: - Widget / Live Activity Liveness Heuristic & Termination Cleanup (SSOT)

    /// Returns true if the main app process has signaled it is recently active via the
    /// `lastUpdateTime` heartbeat (within the 60 s window).
    ///
    /// This is the **single source of truth** for the widget "active UI vs. passive launch prompt"
    /// decision. Widget family views (Small/Medium/Large) use it to choose between rendering
    /// full status + PlayerControlPresentation buttons + flag grid (when true) vs. the
    /// "tap_to_open" icon + `widgetURL(URL(string: "lutheranradio://open"))` (when false).
    ///
    /// **Lifecycle contract (Cleanup Invariant)**:
    /// - While the main app process is alive (foreground or background audio), saves, fg/bg
    ///   transitions, and explicit liveness calls keep the timestamp recent → widgets render
    ///   interactive controls.
    /// - On observed main-app termination (applicationWillTerminate, sceneDidDisconnect,
    ///   willTerminateNotification), the main process **must** call
    ///   `forceStaleLivenessTimestampForTermination()` which sets the sentinel value 0.
    ///   Subsequent widget renders (system timelines or explicit) immediately see false and
    ///   render the stable passive "tap to open" surface.
    /// - Force-quit (no notification delivered) relies on natural aging + absence of further
    ///   main-process bumps/reloads. Worst case 60 s of "active" presentation.
    /// - Widget/App Intent processes may bump via the `isWidgetProcess()` bypass inside
    ///   `bumpWidgetLivenessTimestamp` only for their own optimistic feedback; they do not
    ///   keep the main app alive.
    /// - The passive path only launches the app via Apple-approved mechanisms (widgetURL,
    ///   Live Activity tap "open", or AppIntent surfaces marked `.openAppWhenRun`). No
    ///   implicit play, no reload side-effects, no resurrection.
    ///
    /// - Important: This is a *presentation heuristic only*. Never use for playback intent,
    ///   resurrection guards, or security decisions. Those use `PersistedWidgetState`,
    ///   `currentPlaybackIntent`, and `PlayerVisualState` directly.
    /// - Returns: `false` for missing key, explicit termination sentinel (0), or stale (>60 s).
    /// - Note: 60 s matches the original widget `isAppRunning` window; keep in sync.
    /// - SeeAlso: ``bumpWidgetLivenessTimestamp(force:minInterval:)``,
    ///   ``forceStaleLivenessTimestampForTermination()``, `LutheranRadioWidget.swift`
    ///   (the `if !isAppRunning()` branches and `widgetURL`), `WidgetRefreshManager`,
    ///   CODING_AGENT.md (Single Source of Truth Principles + cross-target shared files),
    ///   docs/Widget-Presentation-Dataflow.md (App Termination section).
    ///
    /// AGENT NOTE: Any change to the 60 s constant, sentinel value, or the decision here
    /// must also update the widget view branches, the termination call sites, and this doc.
    nonisolated static func isMainAppProcessRecentlyActive() -> Bool {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return false }
        guard let lastUpdate = defaults.object(forKey: "lastUpdateTime") as? Double else { return false }
        if lastUpdate == 0 { return false } // explicit termination sentinel written on quit paths
        return Date().timeIntervalSince1970 - lastUpdate < 60
    }

    /// Returns true when `lastUpdateTime` is the explicit termination sentinel value (0).
    ///
    /// - Returns: `true` only when the key exists *and* equals exactly 0.0 (written by
    ///   `forceStaleLivenessTimestampForTermination` on willTerminate / disconnect paths).
    /// - Note: Brand-new installs (missing key) and normal idle (positive timestamp, even if >60 s)
    ///   return `false`. Only the deliberate termination marker returns `true`.
    ///
    /// This is the **post-termination liveness heuristic** used in combination with
    /// `currentPlaybackIntent.isStickyPauseOrLock` to provide a hard blocker against
    /// unwanted auto-play / tuning sound on device power-up or wake while a Live Activity
    /// (or widget surface) remains visible on the Lock Screen.
    ///
    /// **Why this exists**: Termination of the main process (even if a paused or playing LA
    /// was present) must be treated as the end of any prior playback intent. Subsequent
    /// wakes must not cause `DirectStreamingPlayer` side effects. Widgets/LAs may still
    /// render last-known visuals or passive "tap to open", and may schedule pending actions
    /// or post Darwin notifications, but they (and launch paths) must never start audio.
    ///
    /// - Precondition: Callers combine this with intent checks or the explicit-play flag
    ///   (see `hasProcessedExplicitUserPlayRequest`).
    /// - SeeAlso: ``isMainAppProcessRecentlyActive()``, ``forceStaleLivenessTimestampForTermination()``,
    ///   ``play()``, ``restoreVisualStateRespectingUserIntent()``, ``attemptResurrectionIfAllowed()``,
    ///   ViewController (cold-launch guard before tuning), CODING_AGENT.md (SSOT + resurrection),
    ///   <doc:Architecture>.
    ///
    /// AGENT NOTE: This + sticky intent is the required combined blocker on *every*
    /// auto-resume / state-restore / wake path. Update all such sites + the resurrection
    /// table when changing. Never bypass for LA-visible cases.
    nonisolated static func hasExplicitTerminationSentinel() -> Bool {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return false }
        guard let lastUpdate = defaults.object(forKey: "lastUpdateTime") as? Double else { return false }
        return lastUpdate == 0
    }

    /// Forces the widget liveness timestamp to the explicit termination sentinel (0).
    ///
    /// Call this from main-app termination paths only. It makes `isMainAppProcessRecentlyActive()`
    /// return false on the next widget provider execution so all surfaces render the passive,
    /// launch-only UI ("tap to open") immediately rather than showing stale active controls.
    ///
    /// Also clears short-lived instant-feedback keys so no "just acted" optimistic state
    /// survives the quit visually.
    ///
    /// **Cleanup Invariant**: After this call (on any observed termination), widget timelines
    /// and Live Activity (which we also end) must not present interactive controls or cause
    /// the widget extension to believe the main process can service updates. Only Apple-approved
    /// launch surfaces remain functional.
    ///
    /// Safe to call from willTerminate (synchronous context) — only touches UserDefaults.
    ///
    /// - Note: Does **not** remove `persistedWidgetState` (last-known visual + language +
    ///   metadata remain for providers that fall back and for clean relaunch). Contrast with
    ///   `removeAllLocalPlaybackKeys` (privacy clear).
    /// - SeeAlso: ``isMainAppProcessRecentlyActive()``, AppDelegate.applicationWillTerminate,
    ///   SceneDelegate.sceneDidDisconnect, RadioLiveActivityManager.handleAppWillTerminate,
    ///   ``removeAllLocalPlaybackKeys()``.
    nonisolated static func forceStaleLivenessTimestampForTermination() {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return }
        defaults.set(0.0, forKey: "lastUpdateTime")
        // Clear optimistic transients so the widget does not flash a stale "just played" state
        // on its next render after the main process has died.
        defaults.removeObject(forKey: "isInstantFeedback")
        defaults.removeObject(forKey: "instantFeedbackTime")
        defaults.removeObject(forKey: "instantFeedbackLanguage")
        // Do not touch persistedWidgetState or language — last-known snapshot is useful
        // for providers and for a clean relaunch.
        #if DEBUG
        print("[SharedPlayerManager] Forced stale lastUpdateTime (0) + cleared instant feedback for post-termination passive widget state")
        #endif
    }

    /// Optimistic play/pause widget path: persist visual state, schedule pending action, notify main app.
    ///
    /// - Parameters:
    ///   - visualState: Target (.playing or .userPaused) for instant widget icon/state flip.
    ///   - action: "play" or "pause".
    ///   - language: Language code to pair with the snapshot (strongly recommended from widget).
    ///     If omitted, falls back inside forcePersist. Always pass the language the widget
    ///     timeline was using to avoid transient "en" in mixed-language initial-play scenarios.
    ///
    /// Always bypasses privacy gate (via force + isWidgetProcess) because intent execution
    /// proves the widget is present.
    @discardableResult
    nonisolated func signalWidgetPendingAction(
        visualState: PlayerVisualState,
        action: String,
        language: String? = nil
    ) -> String? {
        forcePersistVisualState(visualState, language: language)
        // Also bump liveness from the widget action itself so isAppRunning() flips true
        // without requiring main-app processing (prevents "tap_to_open" after widget play).
        Self.bumpWidgetLivenessTimestamp(force: true)
        let actionId = scheduleWidgetAction(action: action)
        notifyMainApp(action: action)
        return actionId
    }

    /// Optimistic stream-switch widget path: instant feedback, snapshot, schedule, notify.
    @discardableResult
    nonisolated func signalWidgetSwitchAction(
        visualState: PlayerVisualState,
        language: String
    ) -> String? {
        Self.writeInstantFeedback(language: language)
        Self.persistWidgetSnapshot(visualState: visualState, language: language, clearStreamMetadata: true)
        Self.bumpWidgetLivenessTimestamp(force: true)
        let actionId = scheduleWidgetAction(action: "switch", parameter: language)
        notifyMainApp(action: "switch", parameter: language)
        return actionId
    }

    /// Schedules a one-shot widget action for the main app via App Group UserDefaults.
    /// Returns the generated action ID, or `nil` if the App Group is unavailable.
    @discardableResult
    nonisolated func scheduleWidgetAction(action: String, parameter: String? = nil) -> String? {
        // Privacy gate for *persistent* state (snapshot, liveness, instantFeedbackLanguage, metadata).
        // Transient one-shot command keys (pendingAction*, pendingLanguage) are *still written*
        // even when !hasActiveWidgets (post-clear or no widgets configured). This guarantees the
        // first widget play/pause/switch after a privacy clear always delivers its Darwin +
        // pending so the main app can act.
        //
        // Note (post-fix): snapshot + liveness are now also written from widget process via
        // the isWidgetProcess() bypass inside persist/bump (see forcePersist + signal*).
        // Main processing still does explicit refreshHasActive + save for authoritative values.
        let isPrivacySuppressed = !Self.hasActiveWidgets
        if isPrivacySuppressed {
            Self.refreshHasActiveWidgetsStatus()
            #if DEBUG
            print("[SharedPlayerManager] Privacy gate active for scheduleWidgetAction (no active widgets) — allowing transient pending command, suppressing persistent writes")
            #endif
        }

        guard let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            #if DEBUG
            print("[SharedPlayerManager] ERROR: Failed to access shared UserDefaults in scheduleWidgetAction")
            #endif
            return nil
        }
        
        let actionId = UUID().uuidString
        sharedDefaults.set(action, forKey: "pendingAction")
        sharedDefaults.set(actionId, forKey: "pendingActionId")
        sharedDefaults.set(Date().timeIntervalSince1970, forKey: "pendingActionTime")
        
        // Note: Always set the language parameter for switch actions.
        if let param = parameter {
            sharedDefaults.set(param, forKey: "pendingLanguage")
            #if DEBUG
            print("[SharedPlayerManager] Set pendingLanguage: \(param)")
            #endif
        } else if action == "switch" {
            // Fallback: use preferred (combined snapshot first) for pendingLanguage
            // Fallback via preferredWidgetLanguage() when no parameter is supplied.
            let currentLanguage = Self.preferredWidgetLanguage()
            sharedDefaults.set(currentLanguage, forKey: "pendingLanguage")
            #if DEBUG
            print("[SharedPlayerManager] Set fallback pendingLanguage: \(currentLanguage)")
            #endif
        }
        
        // Explicit synchronize() removed — App Group writes are visible to the receiving
        // process via Darwin notification without an explicit flush on modern iOS.
        
        #if DEBUG
        print("[SharedPlayerManager] Scheduled widget action: \(action) \(parameter ?? "") [ID: \(actionId)]")
        #endif
        
        return actionId
    }
    
    /// Posts a Darwin notification so the main app processes a pending widget action.
    nonisolated func notifyMainApp(action: String, parameter: String? = nil) {
        #if LUTHERAN_MAIN_APP
        if !isRunningInWidget(), action == "pause" {
            DarwinSelfEchoGuard.markExpectingSelfPostedPauseEcho()
        }
        #endif

        let notificationName = "radio.lutheran.widget.action"
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(notificationName as CFString), nil, nil, true)
        
        #if DEBUG
        print("[SharedPlayerManager] Posted Darwin notification for action: \(action)")
        #endif
    }
    
    /// Returns whether any widget action is queued in the App Group (staleness not checked).
    nonisolated func hasPendingWidgetAction() -> Bool {
        getPendingAction() != nil
    }

    /// Returns the currently pending widget action (if any), along with its parameter and unique ID.
    /// Used by the main app (typically in SceneDelegate or a notification handler) to process
    /// play/stop/switch requests originating from widgets or Control Center.
    nonisolated func getPendingAction() -> (action: String, parameter: String?, actionId: String)? {
        guard let action = sharedDefaults?.string(forKey: "pendingAction"),
              let actionId = sharedDefaults?.string(forKey: "pendingActionId") else {
            return nil
        }

        let parameter = sharedDefaults?.string(forKey: "pendingLanguage")
        return (action, parameter, actionId)
    }

    /// Returns a pending widget action only if younger than `maxAge` seconds.
    /// Expired actions are cleared automatically.
    nonisolated func getPendingActionIfFresh(maxAge: TimeInterval = 30) -> (action: String, parameter: String?, actionId: String)? {
        guard let pending = getPendingAction() else { return nil }

        let pendingTime = sharedDefaults?.double(forKey: "pendingActionTime") ?? 0
        let actionAge = Date().timeIntervalSince1970 - pendingTime

        guard actionAge < maxAge else {
            #if DEBUG
            print("[SharedPlayerManager] Pending action expired (age: \(actionAge)s), clearing")
            #endif
            clearPendingAction(actionId: pending.actionId)
            return nil
        }

        return pending
    }
    
    /// Clears a pending widget action only if the provided `actionId` still matches the current one.
    /// Prevents race conditions when multiple rapid widget taps occur.
    nonisolated func clearPendingAction(actionId: String) {
        guard let currentActionId = sharedDefaults?.string(forKey: "pendingActionId"),
              currentActionId == actionId else { return }
        sharedDefaults?.removeObject(forKey: "pendingAction")
        sharedDefaults?.removeObject(forKey: "pendingActionId")
        sharedDefaults?.removeObject(forKey: "pendingActionTime")
        sharedDefaults?.removeObject(forKey: "pendingLanguage")
        #if DEBUG
        print("[SharedPlayerManager] Cleared pending action with ID: \(actionId)")
        #endif
    }
    
    // MARK: - PlayerVisualState Persistence & Restoration (Private)

    private func saveVisualState() {
        // Purpose: no-op retained after eb52d3b6 PersistedWidgetState SSOT consolidation.
        // Key constraint: authoritative writes now occur only via performActualSave +
        // persistWidgetSnapshot; call sites preserved solely for resurrection path structure.
    }

    private func loadVisualState() -> PlayerVisualState {
        // Purpose: legacy reader for actor in-memory state init / resurrection.
        // Key constraint: snapshot (PersistedWidgetState) is always preferred; legacy JSON only for pre-snapshot installs.
        // Prefer the combined snapshot for actor in-memory initialization
        // (both main app and widget extension processes). Legacy key is migration-only.
        if let combined = Self.loadPersistedWidgetState() {
            return combined.visualState
        }
        guard let data = sharedDefaults?.data(forKey: "playerVisualState"),
              let decoded = try? JSONDecoder().decode(PlayerVisualState.self, from: data) else {
            return .prePlay   // safe fallback for first launch
        }
        return decoded
    }

    // MARK: - Legacy Migration

    /// One-time legacy migration from the retired pre-snapshot `isPlaying` boolean
    /// (and related separate keys) into the unified `PersistedWidgetState` snapshot.
    ///
    /// This is **idempotent and a complete no-op** once any `persistedWidgetState`
    /// snapshot exists (enforced via direct key check to prevent recursion when called
    /// from `loadPersistedWidgetState`).
    ///
    /// Retained solely for very old installs that only ever wrote the legacy bool.
    ///
    /// - Note: Can safely be removed after all pre-snapshot installs have upgraded
    ///   (or after a major version bump + sufficient time). It is the final bridge
    ///   from the old bool model to PersistedWidgetState as the sole SSOT.
    ///
    /// Called from `loadPersistedWidgetState()` and `ensureVisualStateLoaded()`.
    nonisolated static func migrateLegacyIsPlayingIfNeeded() {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return }

        // Already have a snapshot → nothing to do. Direct key inspection prevents recursion
        // when this is invoked from inside loadPersistedWidgetState() (which covers static
        // widget timeline provider paths that read the snapshot without going through the actor).
        if defaults.data(forKey: "persistedWidgetState") != nil {
            return
        }

        // Check legacy key
        let hasLegacyKey = defaults.object(forKey: "isPlaying") != nil

        guard hasLegacyKey else {
            // No legacy data and no snapshot → nothing to migrate
            return
        }

        let legacyIsPlaying = defaults.bool(forKey: "isPlaying")

        // Create a minimal but valid PersistedWidgetState from the legacy value.
        let migratedVisualState: PlayerVisualState = legacyIsPlaying ? .playing : .userPaused

        // Build a snapshot. During migration there is (by definition) no snapshot yet,
        // so use the direct legacy "currentLanguage" fallback (same ultimate default that
        // preferredWidgetLanguage and load paths use). Do not call preferredWidgetLanguage()
        // here to keep the migration self-contained.
        let currentLanguage = defaults.string(forKey: "currentLanguage") ?? "en"

        // Persist the new snapshot (this becomes the new source of truth).
        // Uses the public static writer so lastLanguageChangeTime and metadata merge rules are applied.
        // hasError defaults to false for legacy visual-only migration.
        Self.persistWidgetSnapshot(visualState: migratedVisualState, language: currentLanguage)

        // Clean up the legacy key so we don't carry old data forever.
        defaults.removeObject(forKey: "isPlaying")

        #if DEBUG
        print("🔄 [SharedPlayerManager] Migrated legacy isPlaying=\(legacyIsPlaying) → PersistedWidgetState")
        #endif
    }

    // MARK: - Persisted Widget State (visual + language snapshot)

    /// Combined snapshot that carries both visual intent and language.
    /// This is the preferred path for cross-process widget and Live Activity correctness.
    ///
    /// Now also carries `hasError` so that `loadSharedState()` can derive both
    /// `isPlaying` and `hasError` strictly from the SSOT snapshot for normal operation
    /// (legacy bools are migration/compat only).
    struct PersistedWidgetState: Codable {
        let visualState: PlayerVisualState
        let currentLanguage: String
        let lastLanguageChangeTime: Date?
        let streamMetadata: StreamProgramMetadata?
        /// Permanent error flag persisted in the snapshot so widget/LA chrome and
        /// loadSharedState can source it from the single authoritative blob.
        let hasError: Bool

        private enum CodingKeys: String, CodingKey {
            case visualState
            case currentLanguage
            case lastLanguageChangeTime
            case streamMetadata
            case hasError
        }

        init(
            visualState: PlayerVisualState,
            currentLanguage: String,
            lastLanguageChangeTime: Date? = nil,
            streamMetadata: StreamProgramMetadata? = nil,
            hasError: Bool = false
        ) {
            self.visualState = visualState
            self.currentLanguage = currentLanguage
            self.lastLanguageChangeTime = lastLanguageChangeTime
            self.streamMetadata = streamMetadata
            self.hasError = hasError
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            visualState = try container.decode(PlayerVisualState.self, forKey: .visualState)
            currentLanguage = try container.decode(String.self, forKey: .currentLanguage)
            lastLanguageChangeTime = try container.decodeIfPresent(Date.self, forKey: .lastLanguageChangeTime)
            streamMetadata = try container.decodeIfPresent(StreamProgramMetadata.self, forKey: .streamMetadata)
            // Resilient: pre-hasError snapshots decode as no error.
            hasError = try container.decodeIfPresent(Bool.self, forKey: .hasError) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(visualState, forKey: .visualState)
            try container.encode(currentLanguage, forKey: .currentLanguage)
            try container.encodeIfPresent(lastLanguageChangeTime, forKey: .lastLanguageChangeTime)
            try container.encodeIfPresent(streamMetadata, forKey: .streamMetadata)
            try container.encode(hasError, forKey: .hasError)
        }
    }

    /// Saves the combined visual + language + metadata state as a single atomic blob.
    /// This is the new preferred path for cross-process widget correctness.
    private func savePersistedWidgetState(
        visualState: PlayerVisualState,
        language: String,
        streamMetadata: StreamProgramMetadata? = nil,
        hasError: Bool = false
    ) {
        // Privacy gate (see persistWidgetSnapshot for rationale and hasActiveWidgets docs).
        // Allow widget process bypass (optimistic paths from intents may route here in future).
        guard Self.hasActiveWidgets || Self.isWidgetProcess() else {
            #if DEBUG
            print("[SharedPlayerManager] Suppressing savePersistedWidgetState (no active widgets — write suppression)")
            #endif
            return
        }

        let metadataToPersist = streamMetadata ?? currentStreamMetadata
        let snapshot = PersistedWidgetState(
            visualState: visualState,
            currentLanguage: language,
            lastLanguageChangeTime: Date(),
            streamMetadata: metadataToPersist,
            hasError: hasError
        )
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(snapshot) {
            sharedDefaults?.set(data, forKey: "persistedWidgetState")
            // Explicit synchronize removed; App Group + Darwin notification coordination
            // does not require it on modern platforms.

            // Emission after the authoritative persisted snapshot write.
            // Only emitted on main-app actor paths that reach a real write (privacy
            // gate already passed). Widget-process optimistic writes do not emit.
            emit(.persistedWidgetStateDidUpdate)
        }
    }

    /// Loads the authoritative `PersistedWidgetState` snapshot.
    ///
    /// This is the **primary** reader for all widget providers, Live Activities,
    /// Control Center, and cross-process consumers that need the current visual state
    /// and language without instantiating a player.
    ///
    /// - Returns: A tuple of the stored visual state, language, and optional stream metadata,
    ///   or `nil` when no snapshot has ever been written (very fresh install or after
    ///   privacy clear). Callers must treat `nil` as "default to .prePlay + best initial language".
    ///
    /// - Note: Legacy migration from the old "isPlaying" bool is performed internally
    ///   (one-time only) before checking the snapshot key.
    ///
    /// - SeeAlso: ``persistWidgetSnapshot(visualState:language:streamMetadata:clearStreamMetadata:hasError:)``,
    ///   ``loadPersistedVisualStateDirect()``, `loadSharedState()`,
    ///   CODING_AGENT.md (Single Source of Truth Principles),
    ///   PlayerVisualState.swift.
    ///
    /// Thread-safety: nonisolated; safe from any widget/extension context.
    nonisolated static func loadPersistedWidgetState() -> (
        visualState: PlayerVisualState,
        currentLanguage: String,
        streamMetadata: StreamProgramMetadata?
    )? {
        // Run legacy migration first (cheap & idempotent). This ensures that pre-snapshot
        // installs that only ever wrote the "isPlaying" bool (and never a PersistedWidgetState)
        // get upgraded to the current SSOT before any reader decides "no snapshot present".
        // The migrate implementation uses a direct key check for the snapshot blob so there
        // is no recursion even though loadPersistedWidgetState is one of the trigger points.
        migrateLegacyIsPlayingIfNeeded()

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return nil }

        // Preferred (and now only) path: the unified PersistedWidgetState snapshot.
        // Written bidirectionally from performActualSave, saveCombined, forcePersist,
        // and persistWidgetSnapshot. All widget providers and Live Activities should
        // check this first.
        if let data = defaults.data(forKey: "persistedWidgetState"),
           let decoded = try? JSONDecoder().decode(PersistedWidgetState.self, from: data) {
            return (decoded.visualState, decoded.currentLanguage, decoded.streamMetadata)
        }

        // No migration fallback remains for the retired playerVisualState / currentLanguage keys.
        // Old installs without a snapshot get the safe .prePlay / "en" defaults at usage sites.
        return nil
    }

    /// Returns the latest persisted stream program metadata, if any.
    nonisolated static func loadPersistedStreamMetadata() -> StreamProgramMetadata? {
        loadPersistedWidgetState()?.streamMetadata
    }

    /// Nonisolated static writer for the combined `PersistedWidgetState` snapshot.
    ///
    /// Primary writer used by:
    /// - Main-app `performActualSave` / `saveCurrentState` (authoritative path)
    /// - Widget intents (optimistic instant-feedback path)
    /// - `forcePersistVisualState`
    ///
    /// The snapshot is the **single source of truth** for what widgets and Live
    /// Activities should display.
    ///
    /// - Parameters:
    ///   - visualState: The `PlayerVisualState` to persist (`.playing`, `.userPaused`, etc.).
    ///   - language: Current language code for the widget/LA.
    ///   - streamMetadata: Optional currently playing program metadata.
    ///   - clearStreamMetadata: When true, explicitly clears any prior metadata.
    ///   - hasError: Whether a permanent error condition should be shown.
    ///
    /// - Precondition: Must only be called on paths that have already performed
    ///   privacy gating via `hasActiveWidgets` (the method itself also guards).
    ///
    /// - Postcondition: The App Group key "persistedWidgetState" contains the new
    ///   snapshot (or the write is suppressed if no widgets are active).
    ///
    /// - SeeAlso: ``loadPersistedWidgetState()``, ``savePersistedWidgetState``,
    ///   CODING_AGENT.md (SSOT section), `WidgetRefreshManager`.
    ///
    /// Thread-safety: nonisolated static facade; performs no actor hop.
    nonisolated static func persistWidgetSnapshot(
        visualState: PlayerVisualState,
        language: String,
        streamMetadata: StreamProgramMetadata? = nil,
        clearStreamMetadata: Bool = false,
        hasError: Bool = false
    ) {
        // Privacy gate (write suppression when no Lutheran widgets configured).
        // When no Lutheran widgets are configured (or after explicit clearAllLocalState), suppress
        // re-writing the snapshot so no "last language / last visual state / recent metadata" signal
        // remains in the App Group. Widget providers fall back gracefully via loadPersistedWidgetState() == nil.
        //
        // Bypass for widget process: App Intent execution (Toggle, Switch) in the extension proves a
        // widget is configured and the user just interacted with it. We must write the optimistic
        // PersistedWidgetState + lang immediately so that subsequent timeline/provider runs and
        // isAppRunning() checks see the state without waiting for main-app re-detect + save roundtrip.
        // (See initial-play-widget.log and WidgetToggleRadioIntent for the race this fixes.)
        // Main-app writes continue to respect the gate (re-detect on foreground/widget-action processing
        // will flip it true for subsequent saves).
        guard Self.hasActiveWidgets || Self.isWidgetProcess() else {
            if !Self.isWidgetProcess() {
                Self.refreshHasActiveWidgetsStatus() // fire-and-forget re-detect so a later play/foreground after adding widget can resume writes
            }
            #if DEBUG
            print("[SharedPlayerManager] Suppressing widget state write (no active widgets configured — write suppression)")
            #endif
            return
        }

        let resolvedMetadata: StreamProgramMetadata?
        if clearStreamMetadata {
            resolvedMetadata = nil
        } else if let streamMetadata {
            resolvedMetadata = streamMetadata
        } else {
            resolvedMetadata = loadPersistedWidgetState()?.streamMetadata
        }

        let snapshot = PersistedWidgetState(
            visualState: visualState,
            currentLanguage: language,
            lastLanguageChangeTime: Date(),
            streamMetadata: resolvedMetadata,
            hasError: hasError
        )
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(snapshot) {
            if let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") {
                defaults.set(data, forKey: "persistedWidgetState")
                // Explicit synchronize removed; App Group + Darwin notification coordination
                // does not require it on modern platforms.
            }
        }
    }

    /// Convenience alias to the single-source hasActiveLutheranWidgets flag (WidgetRefreshManager).
    /// Used to gate all widget snapshot / optimistic / liveness / pending state writes.
    nonisolated static var hasActiveWidgets: Bool {
        WidgetRefreshManager.hasActiveLutheranWidgets
    }

    /// Fires a non-blocking re-query of WidgetCenter configs to update the privacy write gate.
    /// Safe to call from nonisolated static paths. Primary refresh points remain foreground + explicit clear.
    nonisolated static func refreshHasActiveWidgetsStatus() {
        Task { @MainActor in
            await WidgetRefreshManager.shared.refreshHasActiveWidgets()
        }
    }

    /// Preferred source for widget language (and callers that need display language for
    /// widgets and Live Activities). Strongly prefers the combined `PersistedWidgetState`
    /// snapshot. Falls back to the legacy separate "currentLanguage" key only for migration
    /// compatibility.
    ///
    /// When no snapshot exists:
    /// - If `hasActiveWidgets` is true (widget installed/configured and writes are allowed),
    ///   fall back via `DirectStreamingPlayer.bestInitialLanguageCode()` (respects the user's
    ///   `Locale.preferredLanguages` for a supported stream). This ensures first-run or post-clear
    ///   users with widgets get a good initial language instead of always English.
    /// - Otherwise (no widgets ever, or post-`clearAllLocalState` where the flag is forced false),
    ///   hard-default to "en" (no locale probing). Writes are suppressed by the `hasActiveWidgets`
    ///   guards in all persist/force paths, preserving the no-identifying-language-signal property
    ///   for the no-widgets / post-clear case.
    ///
    /// Using this helper (instead of reading the raw key directly) routes language reads
    /// through the snapshot and reduces the need for forcing or staleness heuristics.
    nonisolated static func preferredWidgetLanguage() -> String {
        if let combined = loadPersistedWidgetState() {
            return combined.currentLanguage
        }
        if Self.hasActiveWidgets {
            return DirectStreamingPlayer.bestInitialLanguageCode()
        }
        // Ultimate fallback (migration only, or privacy no-signal when no widgets / post-clear)
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return "en" }
        return defaults.string(forKey: "currentLanguage") ?? "en"
    }

    /// Preferred initial language for main-app UI (LanguageSelectorView needle, early cold-launch
    /// seeds, background images, post-clear cold-launch auto-play, etc.).
    ///
    /// Strongly prefers the last language from the PersistedWidgetState snapshot (so "last stream
    /// remembered" is reflected on resurrection / normal cold launch).
    ///
    /// When no snapshot (first-run, post-`clearAllLocalState`, or privacy-no-widgets case) falls back
    /// via `DirectStreamingPlayer.bestInitialLanguageCode()`, which walks `Locale.preferredLanguages`
    /// and picks the first supported radio stream (en/de/fi/sv/et) that matches the user's language
    /// preferences. This is the device locale reseed used for the post-clear / no-snapshot case.
    ///
    /// Distinct from `preferredWidgetLanguage()`: the widget helper now consults `hasActiveWidgets`
    /// for its no-snapshot fallback (bestInitial when writes are allowed; "en" + suppressed writes
    /// otherwise). This helper is the main-app path that always prefers bestInitial on no-snapshot.
    nonisolated static func preferredMainAppInitialLanguageCode() -> String {
        if let combined = loadPersistedWidgetState() {
            return combined.currentLanguage
        }
        return DirectStreamingPlayer.bestInitialLanguageCode()
    }

    /// Facade over `DirectStreamingPlayer.streamForLanguageCode`.
    /// Returns the Stream for the given code, or the English default (first stream) if not found.
    /// Use this (instead of inline `availableStreams.first(where:...) ?? availableStreams[0]`)
    /// from both main app and widget extension code for a single source of the defaulting rule.
    nonisolated static func streamForLanguageCode(_ languageCode: String) -> DirectStreamingPlayer.Stream {
        DirectStreamingPlayer.streamForLanguageCode(languageCode)
    }

    /// Facade over `DirectStreamingPlayer.indexForLanguageCode`.
    /// Returns the index for the given code (suitable for LanguageSelectorView etc.), or 0 if not found.
    nonisolated static func indexForLanguageCode(_ languageCode: String) -> Int {
        DirectStreamingPlayer.indexForLanguageCode(languageCode)
    }

    #if LUTHERAN_MAIN_APP
    /// Persists the current stream metadata into the combined widget snapshot.
    func persistStreamMetadataForWidgets() {
        guard Self.hasActiveWidgets else {
            #if DEBUG
            print("[SharedPlayerManager] Suppressing persistStreamMetadataForWidgets (no active widgets — privacy mode)")
            #endif
            return
        }
        savePersistedWidgetState(
            visualState: currentVisualState,
            language: Self.preferredWidgetLanguage(),
            streamMetadata: currentStreamMetadata
        )
        Self.bumpWidgetLivenessTimestamp(force: true)
    }
    #endif

    /// Public entry point for language changes. Persists visual state + language together
    /// in the combined snapshot so widgets receive correct language without extra forcing.
    func saveCombinedWidgetState(language: String) {
        guard Self.hasActiveWidgets else {
            #if DEBUG
            print("[SharedPlayerManager] Suppressing saveCombinedWidgetState (no active widgets — write suppression)")
            #endif
            return
        }
        // Language change path: clear stale program metadata for the snapshot.
        // Uses the same helper as the Now-Playing-oriented clear to keep the nil-ing in one place.
        _clearIcyMetadataStash()
        savePersistedWidgetState(visualState: currentVisualState, language: language, streamMetadata: nil)

        // 2026-05-29: Legacy separate "currentLanguage" key retired. lastUpdateTime
        // is still bumped for the 60 s "isAppRunning" widget check and general freshness.
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "lastUpdateTime")
        // Explicit synchronize removed (see UserDefaults hygiene note near other sites).
    }
}

// MARK: - UserDefaults Communication
extension SharedPlayerManager {
    
    /// Persists the current visual + language + error + metadata state to the App Group snapshot.
    ///
    /// This is the **primary authoritative writer** from the main app. It is driven by
    /// player KVO/status changes, explicit play/pause/switch paths, and lifecycle events.
    /// Widget and Live Activity consumers should read via `loadPersistedWidgetState()` (or
    /// the `loadSharedState` facade) rather than calling this.
    ///
    /// - Important: Language derivation prefers the PersistedWidgetState snapshot via
    ///   `preferredWidgetLanguage()`. During stream-switch reconciliation we additionally
    ///   prefer the Direct player model (already updated by `switchToStream`) when it
    ///   differs and we are in the `.prePlay`/hold window. This closes the exact race
    ///   that caused widget language taps to revert to the previous stream.
    ///
    /// - Postcondition: If a write occurs, `persistedWidgetState` contains the latest
    ///   (visualState, currentLanguage, hasError, metadata) and a refresh is scheduled.
    ///
    /// - SeeAlso: ``performActualSave(_:widgetState:at:)``, ``preferredWidgetLanguage()``,
    ///   ``persistWidgetSnapshot(visualState:language:streamMetadata:clearStreamMetadata:hasError:)``,
    ///   ``loadPersistedWidgetState()``, CODING_AGENT.md (Single Source of Truth Principles),
    ///   the resurrection and persistence tables in this file.
    ///
    /// Actor-isolated. Callers on the main path must `await`.
    // Now async – callers must await this when they want to save
    func saveCurrentState() async {
        guard !isRunningInWidget() else { return }
        
        let player = DirectStreamingPlayer.shared
        
        let now = Date()
        
        // Fetch current values from the real player
        // NOTE (architectural shift): Language read now goes through preferredWidgetLanguage()
        // which strongly prefers the combined PersistedWidgetState snapshot. The old direct
        // key read is only in the ultimate fallback inside the helper (migration path).
        var currentLanguageCode = Self.preferredWidgetLanguage()

        // Post-clear / no-snapshot repair (defense-in-depth for widget-present case and timing races):
        // With the change to preferredWidgetLanguage, when hasActiveWidgets is true we now get
        // bestInitial directly from the no-snapshot fallback. The repair below (prefer selectedStream
        // when no snapshot at write time, or repair stale "en") remains useful for early lifecycle
        // saves, widget signals that race the main cold-launch seed, or legacy "en" snapshots.
        // Launch / reseed paths seed the player model via preferredMainAppInitialLanguageCode() +
        // bestInitialLanguageCode. Persistence is still gated on hasActiveWidgets in performActualSave,
        // so the no-widget / post-clear (forced-false) case produces zero language signal in the App Group.
        if Self.loadPersistedWidgetState() == nil {
            let selected = DirectStreamingPlayer.shared.selectedStream.languageCode
            if !selected.isEmpty {
                currentLanguageCode = selected
            }
        } else if currentLanguageCode == "en" {
            // Existing snapshot present — repair a stale "en" from it or the player model (unchanged logic).
            if let previous = Self.loadPersistedWidgetState(), previous.currentLanguage != "en" {
                currentLanguageCode = previous.currentLanguage
            } else {
                let selected = DirectStreamingPlayer.shared.selectedStream.languageCode
                if selected != "en" {
                    currentLanguageCode = selected
                }
            }
        }

        // Stream-switch / widget-switch reconciliation safety.
        // In the canonical widget (and main) switch paths the caller performs
        // DirectStreamingPlayer.switchToStream(target) — which updates the selected model
        // to the desired language — *before* calling resetToPrePlayForNewStream + play().
        // A KVO during the silent stop, a save from setPlaying(), an async saveCombined
        // from updateUserDefaultsLanguage, or a refresh can otherwise read a prior snapshot
        // value (or perform a preferredWidgetLanguage read that races) and write the *old*
        // language back into the snapshot. That stale snapshot then feeds the alignment
        // block or WidgetRefresh, producing the exact "tap et, model briefly et, then
        // Aligning sv (was et), plays sv" reversion.
        //
        // IMPORTANT (paused selection case): We must NOT clobber a widget-provided language
        // in the snapshot simply because we set .prePlay for a resume from .userPaused.
        // Widget SwitchStreamIntent (while paused) + immediate play writes the desired lang
        // into PersistedWidgetState (the SSOT). The bare `|| currentVisualState == .prePlay`
        // would force the (potentially stale) Direct model value, defeating "paused sv -> en
        // then play yields en". Only override to model when we are inside an *active
        // orchestrated switch* (holdPrePlayVisualUntilPlayback set by switchToStreamFromWidget
        // / resetToPrePlayForNewStream). The alignment block later in play() + the defensive
        // alignment now in setUserIntentToPlay ensure the snapshot / model converge on the
        // widget choice for resume-after-lang-select.
        //
        // The snapshot (via preferredWidgetLanguage + loadPersistedWidgetState) remains the
        // long-term SSOT for widget + play resurrection language.
        let modelLang = DirectStreamingPlayer.shared.selectedStream.languageCode
        if !modelLang.isEmpty && modelLang != currentLanguageCode {
            if holdPrePlayVisualUntilPlayback {
                currentLanguageCode = modelLang
            }
        }

        let isPermanentError    = await player.isLastErrorPermanent()
        // Source the legacy "playing" bool from the authoritative visual state (SSOT),
        // not the racy snapshot in actualPlaybackState. The snapshot frequently returns
        // false during normal playback (KVO timing, brief buffering, rate reads) causing
        // the "playing" UserDefaults key (used by WidgetToggleRadioIntent decision logic
        // and loadSharedState fallbacks) to be wrong. This was the "elsewhere" causing
        // first-widget-interaction flakiness even after the pause throttle fix.
        let isPlaying           = currentVisualState.isActivelyPlaying
        let hasPermanentError   = player.hasPermanentError
        
        // === NEW: WidgetState is now a computed view of PlayerVisualState (SSOT) ===
        let widgetState = WidgetState(
            from: currentVisualState,                  // ← SharedPlayerManager's SSOT
            currentLanguage: currentLanguageCode,
            hasError: hasPermanentError || isPermanentError,
            isTransitioning: false
        )
        
        let currentState = (
            isPlaying: isPlaying,
            currentLanguage: currentLanguageCode,
            hasError: hasPermanentError || isPermanentError
        )
        
        performActualSave(currentState, widgetState: widgetState, at: now)
    }
    
    nonisolated func saveFireAndForget() {
        Task {
            await saveCurrentState()
        }
    }
    
    private func performActualSave(_ state: (isPlaying: Bool, currentLanguage: String, hasError: Bool),
                                   widgetState: WidgetState,
                                   at time: Date) {
        // Privacy gate: when !hasActiveWidgets we suppress all the legacy + snapshot writes
        // (savePersisted is also guarded, but we avoid the work and the downstream refreshIfNeeded scheduling).
        guard Self.hasActiveWidgets else {
            #if DEBUG
            print("[SharedPlayerManager] Suppressing performActualSave writes + refresh scheduling (no active widgets — write suppression)")
            #endif
            return
        }

        let previousSnapshot = Self.loadPersistedWidgetState()
        let previousLanguage = previousSnapshot?.currentLanguage ?? ""
        let isLanguageChange = !previousLanguage.isEmpty && previousLanguage != state.currentLanguage

        // Derive previous values from the snapshot (now SSOT) when present.
        // Legacy bool reads are retained only as fallback for the absolute oldest installs
        // during the transition off the separate bool keys.
        let previousHasError: Bool = {
            if let data = sharedDefaults?.data(forKey: "persistedWidgetState"),
               let snap = try? JSONDecoder().decode(PersistedWidgetState.self, from: data) {
                return snap.hasError
            }
            return sharedDefaults?.bool(forKey: "hasError") ?? false
        }()
        let previousIsPlaying = previousSnapshot?.visualState.isActivelyPlaying ?? (sharedDefaults?.bool(forKey: "isPlaying") ?? false)

        let metadataUnchanged = previousSnapshot?.streamMetadata == currentStreamMetadata
        let snapshotUnchanged =
            previousSnapshot?.visualState == currentVisualState &&
            previousSnapshot?.currentLanguage == state.currentLanguage &&
            previousHasError == state.hasError &&
            previousIsPlaying == state.isPlaying &&
            metadataUnchanged

        // Urgent refresh for errors, language changes, or the first transition into sticky
        // pause/security lock — not on every KVO save while already `.userPaused`.
        let visualStateChanged = previousSnapshot?.visualState != currentVisualState
        let isTransitionToStickyPause = visualStateChanged && currentVisualState.mustSuppressResurrection
        // Widget optimistic pause may pre-write .userPaused; still urgent when isPlaying flips false.
        let isPlayingStopped = previousIsPlaying && !state.isPlaying
        let isUrgentUpdate = state.hasError || isLanguageChange || isTransitionToStickyPause || isPlayingStopped

        if snapshotUnchanged && !isUrgentUpdate {
            Self.bumpWidgetLivenessTimestamp()
            #if DEBUG
            print("[SharedPlayerManager] performActualSave: snapshot unchanged — skipping persist")
            #endif
            return
        }

        // Persist the authoritative (visualState + language + hasError) snapshot.
        // Widget providers and Live Activities take the early loadPersistedWidgetState() path.
        // hasError is now carried in the snapshot so loadSharedState can derive exclusively
        // from it (plus direct player state where appropriate in the main app).
        savePersistedWidgetState(
            visualState: currentVisualState,
            language: state.currentLanguage,
            streamMetadata: currentStreamMetadata,
            hasError: state.hasError
        )

        // lastUpdateTime remains for the widget "isAppRunning" 60 s freshness heuristic.
        sharedDefaults?.set(time.timeIntervalSince1970, forKey: "lastUpdateTime")

        // Clear instant feedback flags (still required for widget responsiveness)
        sharedDefaults?.removeObject(forKey: "isInstantFeedback")
        sharedDefaults?.removeObject(forKey: "instantFeedbackTime")
        sharedDefaults?.removeObject(forKey: "instantFeedbackLanguage")

        let visualStateForRefresh = currentVisualState

        // Always hop to MainActor for WidgetRefreshManager (required in Swift 6)
        Task { @MainActor in
            if visualStateChanged {
                WidgetRefreshManager.shared.cancelPendingRefresh()
            }
            WidgetRefreshManager.shared.refreshIfNeeded(
                visualState: visualStateForRefresh,
                currentLanguage: state.currentLanguage,
                hasError: state.hasError,
                immediate: isUrgentUpdate
            )

            // Live Activity refresh (parallel to widget timeline reload).
            // The call goes through the manager's change detection (lastPushedContent).
            // This path exists for widget parity (a visual save always gives LA a chance
            // to catch up). The common fast path for LA is the direct event calls from
            // setPlaying / didUpdateStreamMetadata etc. which read in-memory state.
            // No disk I/O is performed inside the Live Activity update itself.
            #if LUTHERAN_MAIN_APP
            await RadioLiveActivityManager.shared.updateCurrentActivity()
            #endif
        }

        #if DEBUG
        print("[SharedPlayerManager] State saved: playing=\(state.isPlaying), language=\(state.currentLanguage)")
        #endif
    }
    
    nonisolated func loadSharedState() -> (isPlaying: Bool, currentLanguage: String, hasError: Bool) {
        // Check for instant feedback state first
        if let instantFeedbackTime = sharedDefaults?.object(forKey: "instantFeedbackTime") as? Double,
           let instantFeedbackLanguage = sharedDefaults?.string(forKey: "instantFeedbackLanguage"),
           sharedDefaults?.bool(forKey: "isInstantFeedback") == true {
            
            let age = Date().timeIntervalSince1970 - instantFeedbackTime
            
            // Use the documented instant-feedback timeout.
            if age < Constants.instantFeedbackTimeout {
                // Prefer the just-written PersistedWidgetState snapshot (SSOT) for both
                // isPlaying and hasError. Legacy bool fallbacks only for pre-snapshot installs.
                let isPlaying = Self.loadPersistedWidgetState()?.visualState.isActivelyPlaying
                    ?? (sharedDefaults?.bool(forKey: "isPlaying") ?? false)
                let hasError: Bool = {
                    if let data = sharedDefaults?.data(forKey: "persistedWidgetState"),
                       let snap = try? JSONDecoder().decode(PersistedWidgetState.self, from: data) {
                        return snap.hasError
                    }
                    return sharedDefaults?.bool(forKey: "hasError") ?? false
                }()
                
                #if DEBUG
                print("[SharedPlayerManager] Using instant feedback state: \(instantFeedbackLanguage), age: \(age)s")
                #endif
                
                return (isPlaying, instantFeedbackLanguage, hasError)
            } else {
                // Clear expired instant feedback
                sharedDefaults?.removeObject(forKey: "isInstantFeedback")
                sharedDefaults?.removeObject(forKey: "instantFeedbackTime")
                sharedDefaults?.removeObject(forKey: "instantFeedbackLanguage")
                
                #if DEBUG
                print("[SharedPlayerManager] Cleared expired instant feedback (age: \(age)s)")
                #endif
            }
        }
        
        // Normal state loading
        // Derive strictly from the PersistedWidgetState snapshot (sole SSOT for visual +
        // language + hasError). Legacy bools are only for one-time migration on installs
        // that predate the unified snapshot.
        let isPlaying = Self.loadPersistedWidgetState()?.visualState.isActivelyPlaying
            ?? (sharedDefaults?.bool(forKey: "isPlaying") ?? false)
        let hasError: Bool = {
            if let data = sharedDefaults?.data(forKey: "persistedWidgetState"),
               let snap = try? JSONDecoder().decode(PersistedWidgetState.self, from: data) {
                return snap.hasError
            }
            return sharedDefaults?.bool(forKey: "hasError") ?? false
        }()
        // Language is returned via the preferred helper (combined snapshot first).
        // This gives the large majority of call sites (Live Activities, many ViewController
        // paths, etc.) the authoritative language with no further changes.
        // The old direct key remains only as the ultimate migration fallback inside
        // preferredWidgetLanguage().
        let currentLanguage = Self.preferredWidgetLanguage()
        return (isPlaying, currentLanguage, hasError)
    }

    #if LUTHERAN_MAIN_APP
    /// Pauses playback when the sleep timer elapses.
    ///
    /// - Sets `currentVisualState = .userPaused` (so widgets/Live Activities render paused)
    ///   while `playbackIntent` remains `.sleepTimer` (non-sticky; distinguishable from
    ///   explicit `.userPaused` for resurrection and clear-lock logic).
    /// - Stops the engine with `reason: .interruption` (deliberately silent: no status
    ///   emission, teardown guard suppresses KVO).
    /// - Writes the PersistedWidgetState snapshot immediately.
    /// - Posts Darwin "pause" (primarily to wake widget providers) and the
    ///   `SleepTimerNotification.stateDidChange` (isActive=false) for main-app glue.
    ///
    /// **Main-app UI sync contract**:
    /// The live in-app visuals (RadioPlayerCoordinator + PlayerViewModel) are **not**
    /// updated by a status callback or by processing the Darwin pause (both are
    /// suppressed for this internal path). The `SleepTimerNotification` observer in the
    /// coordinator is responsible for pulling `currentVisualState` and calling
    /// `updateUI(for:)` after this method posts the inactive notification.
    ///
    /// - Precondition: Must only be called from the sleep timer task (after countdown
    ///   reaches zero and not cancelled).
    /// - Postcondition: `currentVisualState == .userPaused`, `currentPlaybackIntent == .sleepTimer`,
    ///   player is stopped, snapshot persisted, notifications posted.
    /// - Note: Does not set `lastUserPauseTimestamp` (contrast with `stop()` / `markAsUserPaused`).
    ///
    /// - SeeAlso: ``RadioPlayerCoordinator/sleepTimerStateDidChange(_:)``,
    ///   ``PlaybackIntent/sleepTimer``, ``currentVisualState``, ``saveVisualState()``,
    ///   `DirectStreamingPlayer.stop(reason:)`, CODING_AGENT.md (Single Source of Truth Principles),
    ///   SharedPlayerManager.swift (resurrection protection table + "sleepTimer" intent rules).
    ///
    /// AGENT NOTE: Any future change to stop reason, Darwin posting, or suppression guards
    /// here must also update the observer in RadioPlayerCoordinator so the main-app visual
    /// (green → grey) continues to match the SSOT. Widgets are protected by the snapshot write.
    func applySleepTimerElapsedPause() async {
        ensureVisualStateLoaded()

        applyVisualState(.userPaused)
        saveVisualState()
        updatePlaybackIntent(to: .sleepTimer)

        DirectStreamingPlayer.shared.stop(reason: .interruption)

        // Use canonical clear (emits metadataDidUpdate(nil)). Distinct from language stash.
        _clearIcyMetadataStash()

        await saveCurrentState()
        notifyMainApp(action: "pause")
        await updateNowPlayingInfo()

        await SleepTimerNotification.postStateChange(isActive: false)

        #if DEBUG
        print("[SharedPlayerManager] SleepTimer elapsed — paused with .sleepTimer intent (not sticky .userPaused)")
        #endif
    }
    #endif
}

// MARK: - Privacy: Clear Local Playback State and Write Suppression
//
// These entry points implement the user-initiated "Clear local playback state".
// It removes recent playback/widget/Live Activity signals from the App Group and forces the
// write-suppression gate until widgets are re-detected.
// 
// - removeAllLocalPlaybackKeys is nonisolated static (safe for widget/extension call sites in future).
// - clearAllLocalState is the @MainActor entry point used from UI (sleep timer menu / clear action etc.).
//   The timer preset/cancel UI itself is a SwiftUI confirmationDialog; the cancel + set paths still flow through here.
// - Intentionally reuses stop() + cancelSleepTimer() + the no-persist reset helper.
// - Never touches Core security keys (see explicit list in removeAllLocalPlaybackKeys).
extension SharedPlayerManager {
    /// Clears all local playback, widget snapshot, sleep, and optimistic intent state from the App Group.
    /// Does not affect security data or Core state.
    ///
    /// Does **not** touch:
    /// - "lastSecurityValidation" (Core DNS TXT 1-hour success cache — required for secure launch & streaming)
    /// - Any keys written by SecurityModelValidator / Core security
    /// - Certificate pinning data, app version, migration flags, volume prefs, or launch-critical state
    ///
    /// The clear always removes the primary snapshot even if widgets are configured (user explicitly requested it).
    /// After clear, `loadPersistedWidgetState()` returns nil and providers fall back to safe .prePlay / "en".
    nonisolated static func removeAllLocalPlaybackKeys() {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return }

        // Primary target (current SSOT)
        defaults.removeObject(forKey: "persistedWidgetState")

        // Legacy migration keys (be thorough)
        defaults.removeObject(forKey: "playerVisualState")
        defaults.removeObject(forKey: "isPlaying")
        defaults.removeObject(forKey: "playing")
        defaults.removeObject(forKey: "currentLanguage")

        // Playback-related transient / recent activity keys
        defaults.removeObject(forKey: "lastUserPauseTime")
        defaults.removeObject(forKey: "hasError")
        defaults.removeObject(forKey: "lastUpdateTime")

        // Optimistic widget feedback + pending intent keys (these can leak "I just interacted")
        defaults.removeObject(forKey: "isInstantFeedback")
        defaults.removeObject(forKey: "instantFeedbackTime")
        defaults.removeObject(forKey: "instantFeedbackLanguage")
        defaults.removeObject(forKey: "pendingAction")
        defaults.removeObject(forKey: "pendingActionId")
        defaults.removeObject(forKey: "pendingActionTime")
        defaults.removeObject(forKey: "pendingLanguage")

        // Explicit synchronize() removed — unnecessary (removals are visible cross-process
        // via subsequent loads and notifications; privacy clear is not performance-critical).

        #if DEBUG
        print("[SharedPlayerManager] Removed all local playback/widget keys (privacy clear)")
        #endif
    }

    /// Full clear entry point (call this). Stops playback (silent), resets actor SSOT state to
    /// .cleared visual + .cleared intent, removes persisted keys (including the snapshot), ends Live
    /// Activity, cancels sleep, notifies observers. Main UI gets blue "Cleared" pill immediately;
    /// widgets (no snapshot + write suppression) fall back to .prePlay on next load.
    ///
    /// - Important: After this call `loadPersistedWidgetState()` returns nil until the next
    ///   explicit play or widget-driven write.
    ///
    /// Must be called from @MainActor (UI surfaces, coordinator). Internally hops for actor work.
    ///
    /// - SeeAlso: ``removeAllLocalPlaybackKeys()``, ``resetStateToClearedForPrivacy()``,
    ///   CODING_AGENT.md.
    @MainActor
    static func clearAllLocalState() async {
        // 1. Stop the engine directly (silent) without going through SharedPlayerManager.stop().
        // Shared.stop() would force .userPaused visual + intent + early saves, which we must avoid
        // so that post-clear in-process UI and any status callbacks during clear do not mix sticky
        // paused semantics. The .cleared intent (set in the subsequent reset) is the blocker.
        // Direct player stop performs the actual AVPlayer teardown / session cleanup.
        #if LUTHERAN_MAIN_APP
        DirectStreamingPlayer.shared.stop(reason: .userAction, silent: true)
        #endif

        // 2. Cancel sleep (also clears internal task + posts its own notification)
        #if LUTHERAN_MAIN_APP
        await Self.shared.cancelSleepTimer(restorePlaybackIntent: false, notifyStateChange: true)
        #endif

        // 3. Reset in-memory SSOT (visual + intent + metadata). Use the dedicated no-persist helper
        // (public resetToPrePlayForNewStream would re-persist a snapshot we are trying to erase).
        await Self.shared.resetStateToClearedForPrivacy()

        // 4. Wipe the UD keys (works cross-process for widgets + Live Activities)
        Self.removeAllLocalPlaybackKeys()

        // 5. Privacy: after explicit clear, force the hasActiveWidgets flag false *even if*
        // WidgetCenter still reports configured widgets. This prevents the next play() / saveCurrentState
        // from immediately re-writing a fresh snapshot + language signal. The flag is only flipped
        // back to true by an explicit re-detect on foreground (sceneDidBecomeActive) or a later
        // refreshHasActiveWidgetsStatus once a widget has been re-added.
        WidgetRefreshManager.setHasActiveLutheranWidgets(false)
        #if DEBUG
        print("[SharedPlayerManager] hasActiveWidgets forced false after privacy clear (suppressing re-writes until re-detect)")
        #endif

        // 6. End any Live Activity (privacy: no visible "I was listening" on lock screen / Dynamic Island).
        // Uses .default policy (grace period) because the user explicitly requested clear while
        // the app is still running; they may still see the final state briefly.
        #if LUTHERAN_MAIN_APP
        RadioLiveActivityManager.shared.endActivity()   // .default
        #endif

        // 7. Notify (widgets, Live Activities, UI coordinator, SceneDelegate etc. can react and fall back to defaults)
        NotificationCenter.default.post(name: .localStateCleared, object: nil)

        #if DEBUG
        print("[SharedPlayerManager] Local state fully cleared — playback stopped, snapshot removed, LA ended")
        #endif
    }
}

extension Notification.Name {
    static let localStateCleared = Notification.Name("localStateCleared")
}
