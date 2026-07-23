//
//  SharedPlayerManager.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 7.6.2025.
//

// SHARED: Cross-target source (main app + LutheranRadioWidgetExtension)
//
// Primary actor file plus mechanical extensions (same actor, same module):
// `SharedPlayerManager+PlaybackPipeline.swift`, `+AppGroup.swift`,
// `+LiveActivityMirrors.swift`, `+Persistence.swift`, `+PrivacyClear.swift`,
// `+DebugTestSeams.swift`. Widget DirectStreamingPlayer stub lives in
// `DirectStreamingPlayer+WidgetStub.swift`. All membership-exception files are
// listed in project.pbxproj (extension + LutheranRadioWidgetTests).
//
// Compiled into both targets via Xcode File System Synchronized Group +
// membershipExceptions (see project.pbxproj).
//
// Purpose:
// The central actor and Single Source of Truth for all cross-process
// playback state between the main app, home screen widgets, Control Center
// widgets, Live Activities, and App Intents.
//
// `SharedPlayerManager` is the **authoritative emitter** of `PlayerEvent` via its
// `events` AsyncStream. This is the canonical non-forcing surface for the
// ongoing event-driven architecture: observers (widgets, Live Activities, UI
// bridges, recovery) react to typed domain transitions rather than polling or
// direct forcing. All emissions are strictly additive; legacy direct/imperative
// paths and snapshot writes for instant feedback remain the primary mechanism
// and are never bypassed.
//
// Key invariants (see detailed tables in this file):
// - `PersistedWidgetState` (nested struct) + in-memory `loadPersistedWidgetState()` /
//   session snapshot updates are the authoritative **in-session** model for widgets/LAs.
//   Visual/playback state is **never** written to UserDefaults; every cold launch resets
//   to factory `.prePlay` via ``resetToFactoryDefaultsOnLaunch()``.
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
// - SeeAlso: `PlayerVisualState.swift` (hosts `PlayerEvent`, `PlaybackIntent`, and
//   the full canonical vocabulary), `WidgetRefreshManager.swift`, `PersistedWidgetState`,
//   `DirectStreamingPlayer.swift` (owns AVPlayer and actual streaming),
//   CODING_AGENT.md (Single Source of Truth Principles + the full
//   "Cross-target shared source files (non-Core)" guidance + event-driven direction +
//   Documentation & Comment Standards),
//   README.md (Key Files table),
//   docs/Event-Driven-Refactor-Roadmap.md (current Tier status and non-forcing rules).
//
// New termination surfaces (see ``forceStaleLivenessTimestampForTermination()`` +
// ``isMainAppProcessRecentlyActive()``): centralize the "main process alive" signal used
// by widgets to decide active UI vs. passive "tap to open" launch surface.
//
// AGENT NOTE: This is one of the documented single sources of truth.
// Bypassing it for widget or playback intent logic creates drift and is
// forbidden. New observers should prefer the `events` stream over direct state reads
// or forcing shims where possible (additive only).
//
// Memory-only policy (2026-07-07): PersistedWidgetState is an in-process session
// snapshot only (visualState + currentLanguage + hasError + streamMetadata). Retired
// App Group keys (`persistedWidgetState`, `playerVisualState`, `isPlaying`, `playing`,
// `hasError`, bare `currentLanguage`, `lastUserPauseTime`, `preferredVolume`) are purged
// on cold launch / read via ``clearPersistedVisualStateKeysFromDisk()`` and are never written.

import Foundation
import Core
import WidgetSurface
#if LUTHERAN_MAIN_APP
import os
import WidgetKit
#endif

/// `SharedPlayerManager` is the central actor **and authoritative emitter** of
/// `PlayerEvent` for the player domain.
///
/// It enables safe state sharing between the main app, widgets, and Live Activities
/// via App Groups + `UserDefaults`, while the `events` AsyncStream (and its
/// replaying companion) provides the primary non-forcing, decoupled notification
/// path for significant transitions. `currentState` supplies initialization for
/// late subscribers. Event emission (via ``emit(_:)`` after mutations) is the
/// canonical direction for the event-driven architecture; direct state access and
/// widget snapshot writes remain fully supported for compatibility and instant feedback.
///
/// **Division of responsibilities (Single Source of Truth)**:
/// - `DirectStreamingPlayer` owns actual playback state, stream selection, error state,
///   and all mutations to the AVPlayer.
/// - `SharedPlayerManager` owns the **visual/intent state** (`currentVisualState` of type
///   `PlayerVisualState`) **and** is the sole emitter of `PlayerEvent`.
///
/// Core responsibilities:
/// - **Visual State + Intent SSOT**: `PlayerVisualState` + `currentPlaybackIntent`
///   (via `updatePlaybackIntent(to:)`) with strict sticky resurrection protection.
/// - **Event emission (non-forcing canonical)**: All Tier 1 `PlayerEvent` cases
///   (playbackIntentChanged, streamDid*, metadataDidUpdate, visualStateDidChange,
///   persistedWidgetStateDidUpdate) are emitted from inside this actor after the
///   corresponding mutation. See ``events``, ``currentState``, ``makeEventsStreamWithReplay()``,
///   and ``emit(_:)``.
/// - **Widget / Intent actions**: Optimistic instant feedback via App Group + Darwin notifications;
///   the main app performs the real work and persists authoritative state.
/// - **In-session state**: `saveCurrentState()` + in-memory session snapshot updates
///   (``persistWidgetSnapshot(visualState:language:clearStreamMetadata:)`` for widget optimistic
///   paths). Visual state is **not** persisted to UserDefaults across launches.
/// - **Privacy**: only anonymous data; no timestamps, no history, no PII.
///
/// Usage:
/// - Main app / recovery logic: `await SharedPlayerManager.shared.play()`, `.stop()`, etc.
/// - Widgets / Live Activities / intents: `SharedPlayerManager.shared.loadSharedState()`,
///   ``loadPersistedVisualStateDirect()`` (snapshot-first). Optimistic extension writes use
///   ``persistOptimisticWidgetSnapshot(_:language:)`` (permanent widget infrastructure;
///   not the preferred mechanism for new main-app observers).
///
/// - SeeAlso: `DirectStreamingPlayer` (actual playback),
///   ``PlayerVisualState``, ``PlayerEvent``, ``events``, ``currentState``,
///   ``makeEventsStreamWithReplay()``, ``emit(_:)``,
///   `WidgetRefreshManager.swift`, `RadioLiveActivityManager.swift`,
///   `WidgetEventObserver`, `PlayerCurrentState`,
///   CODING_AGENT.md (event-driven direction),
///   docs/Event-Driven-Refactor-Roadmap.md.
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
/// | .prePlay        | Cold launch first play                            | Security valid + inside 25s window (or first time)              | .prePlay (Connecting) → .playing | `.playing` only after engine soft-resume / readyToPlay kick (`setPlaying`); sets `initialPlaybackHasRun = true` when prePlay path proceeds |
/// | .userPaused     | Explicit user play (button, widget, Siri, etc.)   | `userRequestedPlay()` → `setUserIntentToPlay()` first           | .prePlay (Connecting) → .playing | Intent `.shouldBePlaying` immediately; chrome stays Connecting until engine `setPlaying` |
/// | .playing        | User taps pause/stop (any surface)                | `stop()` or `markAsUserPaused()` at top of method               | .userPaused     | Immediate sticky lock + early `saveVisualState()` |
/// | .playing        | Second explicit play / double-fire (same language)| `userRequestedPlay()` / `play()` — engine already audible       | .playing (unchanged) | **No-op** (optional surface reaffirm): never `setStreamAndPlay` / item rebuild; independent of cold-launch `resurrectionProtectionRelaxed` |
/// | .playing        | User-initiated stream/language switch             | `resetToPrePlayForNewStream(connectingLanguageCode:)` (chrome + clear ICY + destination language) **before** silent engine stop, then `play()` | .prePlay → .playing | Hold prePlay through attach; never advertise `.playing` mid teardown; never prior-language chrome with Connecting; engine `setPlaying` after readyToPlay |
/// | .playing        | AV interruption, stall, or thermal event          | `attemptResurrectionIfAllowed()` or player recovery nudges      | .playing        | Only proceeds if `shouldAutoPlayOrResume` |
/// | any             | Security validation failure (DNS/403/cert)        | Inside `play()` guard or StreamingSessionDelegate 403 handler   | .securityLocked | Permanent until explicit successful play |
/// | .thermalPaused  | Device cools sufficiently                         | DirectStreamingPlayer thermal recovery logic                    | .playing        | Only via `shouldAutoResumeOnThermalRecovery` |
/// | any             | App foreground, interruption.ended(.shouldResume) | `restoreVisualStateRespectingUserIntent()`                      | (unchanged or forced .userPaused) | Applies inline resurrection suppression (if mustSuppressResurrection → .userPaused). Sentinel also blocks. |
/// | any (post-term) | Device wake / power-up with Lock Screen LA visible | All auto paths (play/restore/attemptResurrection) | (no playback) | `hasExplicitTerminationSentinel()` + !explicit-this-launch is hard blocker (even for prior .playing snapshot) |
///
/// ### App Group Keys & Memory-Only Visual Policy (group.radio.lutheran.shared)
///
/// **Visual/playback state is in-memory only.** Every cold launch calls
/// ``resetToFactoryDefaultsOnLaunch()`` which clears on-disk visual keys and resets the actor to
/// `.prePlay`. The nested `PersistedWidgetState` struct is retained as an **in-process session
/// snapshot** updated by `savePersistedWidgetState` / `persistWidgetSnapshot` for the current
/// runtime only — never serialized to UserDefaults.
///
/// Widget providers and Live Activities consult `loadPersistedWidgetState()` (in-memory session,
/// `nil` after cold launch → safe `.prePlay` defaults) and `loadSharedState()` for the combined
/// tuple. Cross-process widget timelines therefore show factory "Tap to Play" after relaunch;
/// in-session updates flow via `WidgetRefreshManager.refreshIfNeeded` and short-lived instant
/// feedback keys.
///
/// Retired on-disk keys (`persistedWidgetState`, `playerVisualState`, `isPlaying`, `playing`,
/// `hasError`, bare `currentLanguage`, `lastUserPauseTime`, `preferredVolume`) are **purged** on
/// launch and read paths and never written. ``clearPersistedVisualStateKeysFromDisk()`` is the
/// sole purge entry point (upgrade hygiene for App Group leftovers). Visual state is never
/// restored from disk. Pause recovery uses in-actor ``lastUserPauseTimestamp``; volume uses
/// system output (`MPVolumeView`).
///
/// This is the authoritative shared state model. All values are anonymous. No PII, no listening history.
///
/// ---
///
/// | Key                     | Type                  | Primary Writers                                              | Primary Readers (widgets, recovery, UI)                              | Purpose & Semantics                                          | Lifetime / Notes |
/// |-------------------------|-----------------------|--------------------------------------------------------------|----------------------------------------------------------------------|--------------------------------------------------------------|------------------|
/// | playerVisualState       | Data (JSON)           | (Retired — purged on launch, never written)                  | (none — returns `.prePlay`) | Retired visual blob. Cleared by ``clearPersistedVisualStateKeysFromDisk()`` / ``resetToFactoryDefaultsOnLaunch()``. | Purged only |
/// | persistedWidgetState    | Data (JSON)           | (Retired — purged on launch, never written)                  | (none — in-memory session only) | Was on-disk SSOT; now in-process session snapshot via `inMemorySessionWidgetSnapshot`. | Memory-only |
/// | playing                 | Bool                  | (Retired — purged on launch, never written)                  | (none) | Retired playback bool. | Purged only |
/// | isPlaying               | Bool                  | (Retired — purged on launch, never written)                  | (none) | Retired playback bool. In-session playback chrome is derived only from the memory snapshot (`visualState.isActivelyPlaying`) and short-lived instant-feedback keys — never from this App Group bool. | Purged only |
/// | currentLanguage         | String (languageCode) | (Retired — purged on launch, never written)                  | (none) | Retired bare language key. Language SSOT is in-process `PersistedWidgetState.currentLanguage` plus ``preferredWidgetLanguage()`` (snapshot → `bestInitialLanguageCode()` when widgets active → hard `"en"` when not). | Purged only |
/// | hasError                | Bool                  | (Inside in-process snapshot only; retired App Group bool purged) | `loadSharedState` (from `PersistedWidgetState.hasError`), widgets   | Permanent error flag for UI chrome. Lives inside the in-process session snapshot. Retired standalone App Group bool is purged only. | In-session snapshot; set on security or unrecoverable network failures |
/// | lastUpdateTime          | Double (epoch)        | ``bumpWidgetLivenessTimestamp(policy:minInterval:)`` (canonical; ``WidgetLivenessWritePolicy``), `performActualSave` / `saveCombinedWidgetState` when home widgets active, widget-process optimistic handlers | Widget providers (`isMainAppProcessRecentlyActive` 60 s check) | Liveness heartbeat — bumped on saves and throttled unchanged-snapshot skips | Kept only while home/Control widgets are relevant; removed by privacy clear and when ``WidgetRefreshManager/hasActiveLutheranWidgets`` closes |
/// | lastUserPauseTime | Double (epoch) | (Retired — purged on launch, never written) | (none) | Was App Group pause barrier. Recovery uses in-actor ``lastUserPauseTimestamp`` / ``wasRecentlyUserPaused(within:)`` only. | Purged only |
/// | isInstantFeedback       | Bool                  | Widget handlers (`writeInstantFeedback` / switch path)       | `loadSharedState` (checked first)                                    | Signals that a widget action just occurred (optimistic UI)   | Short-lived; cleared after 15s, next authoritative save, privacy clear, or when the home-widget privacy gate closes |
/// | instantFeedbackTime     | Double (epoch)        | Widget handlers                                              | `loadSharedState`                                                    | Timestamp for the instant feedback validity window           | Same lifetime as `isInstantFeedback` |
/// | instantFeedbackLanguage | String                | Widget handlers                                              | `loadSharedState`                                                    | Language to show during the optimistic widget update         | Same lifetime as `isInstantFeedback` |
/// | pendingAction           | String ("play","pause","switch") | Widget intent handlers, Control Center, some ViewController paths | `getPendingAction()`, SceneDelegate, widget providers          | One-shot command from extension process to main app          | Cleared by `clearPendingAction(actionId:)` after processing |
/// | pendingActionId         | String (UUID)         | Same writers as pendingAction                                | `getPendingAction()`, `clearPendingAction()`                         | Deduplication token to handle rapid repeated taps            | Prevents double-processing on race conditions |
/// | pendingActionTime       | Double (epoch)        | Same writers as pendingAction                                | Widget providers (staleness checks)                                  | Freshness timestamp for pending actions                      | Used to ignore very old pending actions |
/// | pendingLanguage         | String                | `scheduleWidgetAction` (only for "switch")                   | `getPendingAction()`, widget providers                               | Parameter for stream switch actions                          | Only meaningful when `pendingAction == "switch"` |
/// | liveActivityToggleVisualState | String (case name) | `RadioLiveActivityManager` on every ContentState push; optimistic LA toggle | ``loadLiveActivityToggleVisualStateMirror()`` + ``WidgetIntentExecution/performLiveActivityToggle()`` | Durable cross-process LA play/pause plan signal when extension memory snapshot is empty | Cleared on LA end, termination, **factory reset**, privacy clear; **not** gated by home-widget `hasActiveWidgets` |
/// | liveActivityCurrentLanguage | String (languageCode) | `RadioLiveActivityManager` on every ContentState push; optimistic LA paths | ``loadLiveActivityLanguageMirror()`` + ``languageForLiveActivityOrWidgetOptimistic()`` | Durable LA language chrome / optimistic intent language when extension has no session snapshot and home-widget writes are suppressed | Same lifecycle as visual mirror; **not** gated by `hasActiveWidgets` |
/// | recordedSystemBootTime  | Double (epoch of boot) | ``recordCurrentSystemBootTime()`` on LA mirror write + factory reset | ``hasDeviceRebootedSinceLastRecordedBoot()`` / ``shouldDistrustDurableMirrorPlayPlanning()`` | Boot identity for post-reboot LA toggle hygiene | Lets lock-screen planning refuse durable-mirror-alone **play** after hard power-off |
/// | preferredVolume         | Float                 | (Retired — purged on launch, never written)                  | (none) | Was UIKit App Group volume preference. User-facing level is system volume (`MPVolumeView`); engine relative gain defaults to 1.0. | Purged only |
///
/// **Key invariants**:
/// - The main app is always the source of truth. Widgets write optimistic visual state +
///   `pendingAction`, then the main app performs real work and writes authoritative values.
/// - `saveCurrentState()` is the primary persistence path driven by the real player.
/// - Widget / extension code should prefer `loadPersistedVisualStateDirect()` or call
///   `syncVisualStateFromPersistence()` / `refreshVisualStateFromPersistence()` before
///   trusting in-memory `currentVisualState`.
/// - Live Activity lock-screen toggle plans prefer ActivityKit `ContentState` then
///   ``loadLiveActivityToggleVisualStateMirror()`` over extension-local actor defaults
///   (see ``WidgetIntentCoordinators/resolveLiveActivityToggleVisualState(liveActivityContent:durableMirror:actorVisualState:sessionSnapshot:)``).
/// - Live Activity language chrome rides ``ContentState.currentLanguage`` (main-app stream
///   attach language). Durable ``liveActivityCurrentLanguage`` mirrors that code for
///   extension-hosted optimistic paths when ActivityKit activities are briefly empty.
/// - After termination sentinel or device reboot, durable mirror alone must not plan **play**
///   (``shouldDistrustDurableMirrorPlayPlanning()`` + ``WidgetIntentCoordinators/planLiveActivityToggle(resolution:distrustDurableMirrorPlay:)``).

#if LUTHERAN_MAIN_APP
/// Suppresses Darwin notify echoes when the main app posts a pause notification to itself
/// after already executing `stop()`. Genuine widget-originated pauses carry `pendingAction`
/// in the App Group and are never suppressed.
enum DarwinSelfEchoGuard {
    internal static let lock = OSAllocatedUnfairLock(initialState: false)

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
/// - In-process `PersistedWidgetState` session snapshot (via `loadPersistedWidgetState` /
///   `persistWidgetSnapshot`) is authoritative **within the current runtime only**; never on disk.
///   Cold launch always resets to `.prePlay` via ``resetToFactoryDefaultsOnLaunch()``.
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
    internal let appLaunchTime = Date()

    /// Timing constants and thresholds used by resurrection, cold-launch, and optimistic
    /// feedback logic. Centralised so the rationale for each value is documented in one place.
    internal struct Constants {
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
        /// after an explicit pause (in-actor barrier only; no App Group pause-time key).
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

    internal let initializationSettlingPeriod: TimeInterval = Constants.initializationSettlingPeriod
    internal var initialPlaybackHasRun = false
    /// True after the first true cold-launch `play()` proceeds (not stream-switch or resume).
    internal var hasCompletedTrueColdLaunchPlay = false

    /// Set only by explicit user play surfaces (`userRequestedPlay`, `setUserIntentToPlay`).
    /// Combined with `hasExplicitTerminationSentinel()` this makes post-termination
    /// launches require a fresh user gesture before any `DirectStreamingPlayer` work.
    /// See play() and the cold-launch guard in ViewController.
    internal var hasProcessedExplicitUserPlayRequest = false
    
    // MARK: - Recent user pause (in-actor barrier for recovery paths)
    /// Authoritative timestamp for `wasRecentlyUserPaused(within:)`.
    /// In-process only — retired App Group `lastUserPauseTime` is purged and never written.
    internal var lastUserPauseTimestamp: TimeInterval = 0
    
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

    #if LUTHERAN_MAIN_APP
    /// Serial mailbox chain for Now Playing / headset / Live Activity transport verbs.
    ///
    /// Each ``submitMediaTransportCommand(_:)`` schedules work that either waits for this
    /// tail (play / toggle) or preempts it (pause / stop). See ``MediaTransportCommand``.
    ///
    /// - SeeAlso: ``submitMediaTransportCommand(_:)``, ``submitMediaTransportCommandAndWait(_:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    var mediaTransportChain: Task<Void, Never>?

    /// Monotonic epoch for media-transport submission. Every submit advances the value so
    /// a superseded play/toggle can exit before engine work or repair after preemption.
    var mediaTransportEpoch: UInt64 = 0

    /// Epoch of the most recent pause/stop submit. An in-flight play whose generation is
    /// older than this re-asserts ``stop()`` after `userRequestedPlay` so sticky pause wins
    /// when pause preempted the mailbox without cooperatively cancelling engine work.
    var mediaTransportPauseEpoch: UInt64 = 0
    #endif

    /// Re-entrancy guard for ``teardownNowPlayingSession()`` (main app only).
    ///
    /// Prevents stacked AVPlayer / audio-session work when cold-launch factory reset,
    /// privacy clear, and termination surfaces fire in quick succession.
    ///
    /// - SeeAlso: ``teardownNowPlayingSession()``, ``SharedPlayerManager+NowPlaying``,
    ///   `WidgetRefreshManager.isSessionTeardownInProgress`, docs/Event-Driven-Refactor-Roadmap.md.
    var isTeardownInProgress = false

    /// Internal implementation detail: the actual assignment that clears both ICY stash fields.
    /// Used by language-change paths so there is one place that performs this specific nil-ing.
    ///
    /// Different clear sites (privacy reset, sleep-timer elapsed, full stop-to-cleared) keep
    /// their direct assignments + surrounding comments because they have distinct semantics
    /// and postconditions.
    internal func _clearIcyMetadataStash() {
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
        await refreshAllMediaSurfaces(liveActivity: .updateIfActive)
        #endif
    }
    
    // MARK: - Visual State (Single Source of Truth)
    /// Single source of truth for playback intent (UI + widget + Live Activity)
    /// This prevents the "play on pause" resurrection bug when set synchronously to .userPaused
    var currentVisualState: PlayerVisualState = .prePlay
    
    /// When true, `resetToPrePlayForNewStream()` has enabled a stream-switch hold: UI stays `.prePlay`
    /// (Connecting) through validation and secured attach until the engine publishes authoritative
    /// `.playing` via ``setPlaying()`` (soft-resume or readyToPlay first-play kick). Cleared only
    /// inside ``setPlaying()`` / privacy reset / UITest short-circuit — not at the start of ``play()``.
    internal var holdPrePlayVisualUntilPlayback = false

    /// Target stream language for Live Activity / media-surface chrome while a stream-switch
    /// Connecting hold is active **before** ``DirectStreamingPlayer/selectedStream`` settles.
    ///
    /// Without this, the hold-time ``refreshAllMediaSurfaces`` push can publish `.prePlay` with
    /// the **prior** language (engine model still on the old stream), then a second push with the
    /// new language after `switchToStream` — a one-frame wrong flag/name on Lock Screen.
    /// Callers that know the destination language pass it to ``resetToPrePlayForNewStream``.
    /// Cleared with the hold (``setPlaying()``, privacy reset, UITest short-circuit).
    ///
    /// - SeeAlso: ``liveActivityLanguageCodeForContentPush()``, ``resetToPrePlayForNewStream(preserveActiveSleepTimer:connectingLanguageCode:)``
    internal var streamSwitchConnectingLanguageCode: String?

    /// True while ``play()`` has passed sticky/early guards and has not yet reached authoritative
    /// ``setPlaying()`` or an abort that clears the pipeline (security lock, sticky pause, stop).
    ///
    /// Used so media-transport / Live Activity toggles can **cancel connect** (plan pause) instead
    /// of re-entering play during Connecting chrome, and so a second ``userRequestedPlay()`` is
    /// idempotent while validation/attach is already in flight.
    ///
    /// - SeeAlso: ``isConnectingPlayback``, ``clearPlaybackStartPipeline()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    internal var isPlaybackStartPipelineActive = false

    /// Whether a user-visible start is in progress (Connecting) without audible ``isActivelyPlaying``.
    ///
    /// - Returns: `true` when the play start pipeline is active and visual is not yet `.playing`.
    /// - Important: Pure ``PlayerVisualState/prePlay`` without this flag is idle/cold chrome —
    ///   first play still plans play. Only an active pipeline means "cancel with pause."
    /// - SeeAlso: ``WidgetIntentCoordinators/planLiveActivityToggle(resolution:distrustDurableMirrorPlay:isConnectingPlayback:)``,
    ///   ``PlayerVisualState/isActivelyPlaying``
    var isConnectingPlayback: Bool {
        isPlaybackStartPipelineActive && !currentVisualState.isActivelyPlaying
    }

    /// Clears the in-flight play start pipeline (connect cancel, audible start, security fail, stop).
    internal func clearPlaybackStartPipeline() {
        isPlaybackStartPipelineActive = false
    }
    
    /// True when a stream-switch tap already reset to `.prePlay` and enabled the hold
    /// (`didSelectItemAt` optimistic yellow). `completeStreamSwitch` skips a second reset.
    var isStreamSwitchPrePlayHoldActive: Bool {
        currentVisualState == .prePlay && holdPrePlayVisualUntilPlayback
    }

    /// Clears stream-switch Connecting hold and any target-language override for LA chrome.
    ///
    /// Call only at hold-end sites (authoritative ``setPlaying()``, privacy cleared, UITest
    /// short-circuit). Does not touch visual or intent.
    internal func clearStreamSwitchPrePlayHold() {
        holdPrePlayVisualUntilPlayback = false
        streamSwitchConnectingLanguageCode = nil
    }

    /// Language code for Live Activity `ContentState.currentLanguage` (and durable mirror warm).
    ///
    /// Prefer ``streamSwitchConnectingLanguageCode`` while an active-intent switch hold is in
    /// flight so Connecting chrome and language chrome advance together before the engine model
    /// is updated. Otherwise falls back to ``mainAppLiveActivityLanguageCode()`` (stream attach).
    ///
    /// - Returns: Non-empty language code for ActivityKit content.
    /// - SeeAlso: ``resetToPrePlayForNewStream(preserveActiveSleepTimer:connectingLanguageCode:)``,
    ///   ``RadioLiveActivityManager/updateCurrentActivity()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   docs/Widget-Functionality-Roadmap.md (Live Activity language chrome SSOT).
    func liveActivityLanguageCodeForContentPush() -> String {
        if let pending = streamSwitchConnectingLanguageCode, !pending.isEmpty {
            return pending
        }
        return Self.mainAppLiveActivityLanguageCode()
    }
    
    /// Guards one-time application of the factory-default visual load path per process.
    /// Widget/extension processes start with a fresh actor instance (default `.prePlay`).
    internal var hasLoadedVisualStateFromPersistence = false

    /// In-process session snapshot for widget/LA derivation within the current runtime.
    ///
    /// **Never written to UserDefaults.** Cleared on every cold launch by
    /// ``resetToFactoryDefaultsOnLaunch()``. Widget extension processes maintain a separate
    /// copy (optimistic intent paths only); cross-process timelines default to `.prePlay`
    /// after relaunch.
    ///
    /// - SeeAlso: ``loadPersistedWidgetState()``, ``resetToFactoryDefaultsOnLaunch()``,
    ///   docs/Event-Driven-Refactor-Roadmap.md.
    // SAFETY: Updated only from actor-isolated writers and nonisolated static facades that
    // serialize through the same process; reads are best-effort for widget refresh derivation.
    // No cross-process sharing is required — disk persistence was intentionally removed.
    nonisolated(unsafe) internal static var inMemorySessionWidgetSnapshot: PersistedWidgetState?

    // MARK: - Playback Intent
    //
    /// Owned exclusively by this actor via `updatePlaybackIntent(to:)`.
    //
    //
    //
    internal var playbackIntent: PlaybackIntent = .shouldBePlaying

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

    internal var eventContinuation: AsyncStream<PlayerEvent>.Continuation?
    internal var _events: AsyncStream<PlayerEvent>?
    /// Live-forwarding task for the most recent ``makeEventsStreamWithReplay()`` consumer.
    ///
    /// ``AsyncStream`` admits one iterator on ``events``; this task is cancelled when a replay
    /// consumer ends or when a new replay stream is created so other observers can attach.
    internal var replayForwardingTask: Task<Void, Never>?

    /// The stream of `PlayerEvent` instances emitted by this manager.
    ///
    /// `SharedPlayerManager` is the **single source of truth and authoritative emitter**
    /// of `PlayerEvent` for the player domain. This `AsyncStream` is the canonical
    /// non-forcing surface for the event-driven architecture: all significant domain
    /// transitions are expressed here after their state mutations.
    ///
    /// The stream is created once and remains valid for the lifetime of the manager.
    /// All subscribers receive events yielded after they begin consuming the stream.
    ///
    /// Access from outside the actor requires `await`.
    ///
    /// - Parameters: none (async getter).
    /// - Returns: The `AsyncStream<PlayerEvent>` for this manager instance.
    /// - SeeAlso: ``emit(_:)``, ``updatePlaybackIntent(to:)``, ``setPlaying()``, ``stop()``,
    ///   ``markPlaybackStoppedByStreamFailure(_:)``, ``didUpdateStreamMetadata(_:)``,
    ///   ``currentState``, ``makeEventsStreamWithReplay()``, `PlayerEvent`, `PlayerVisualState.swift`,
    ///   `PlayerCurrentState`, CODING_AGENT.md (Single Source of Truth Principles,
    ///   event-driven direction, cross-target shared files, Documentation & Comment Standards),
    ///   docs/Event-Driven-Refactor-Roadmap.md.
    /// - Important: Emission is always additive. Existing imperative paths
    ///   (`setPlaying`, `stop`, `setUserPaused`, `markAsUserPaused`, `saveCurrentState`,
    ///   widget/Live Activity updates, notifications) are never bypassed or altered.
    ///   Direct state surfaces and optimistic widget shims (e.g. `persistOptimisticWidgetSnapshot`) continue
    ///   to operate for compatibility.
    /// - Note: The continuation is retained for the actor's lifetime. Late subscribers
    ///   obtain the state that existed before subscription through ``currentState`` or
    ///   ``makeEventsStreamWithReplay()``.
    /// - Precondition: Must be accessed via `await SharedPlayerManager.shared.events`.
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
    /// - Postcondition: If a continuation exists, the event has been yielded to
    ///   active subscribers. No other side effects.
    /// - SeeAlso: ``events``, ``currentState``, ``makeEventsStreamWithReplay()``,
    ///   ``updatePlaybackIntent(to:)``, ``setPlaying()``,
    ///   ``stop()``, ``setUserPaused()``, ``markAsUserPaused()``,
    ///   ``markPlaybackStoppedByStreamFailure(_:)``, ``didUpdateStreamMetadata(_:)``,
    ///   `PlayerEvent`, `PlayerCurrentState`, CODING_AGENT.md (Documentation & Comment Standards),
    ///   docs/Event-Driven-Refactor-Roadmap.md.
    /// - Important: Never call `emit` from outside this actor or from widget-only paths
    ///   that would duplicate the main-app classification. Emissions for all Tier 1
    ///   events occur after the corresponding state mutation inside this actor.
    ///   The method is internal to allow coordinated emission sites inside the
    ///   type's implementation files (e.g. SharedPlayerManager+NowPlaying.swift).
    /// - Note: Widget processes are explicitly guarded via ``isRunningInWidget()``; they
    ///   perform optimistic snapshot writes but authoritative events originate from the
    ///   main app. DEBUG tests simulate widget context through
    ///   ``_test_setSimulateWidgetProcessContext(_:)``.
    internal func emit(_ event: PlayerEvent) {
        // Widget processes perform optimistic visual/intent writes for instant feedback
        // but must never emit; authoritative emissions (and the single stream instance
        // intended for observers) come from the main app process only.
        guard !isRunningInWidget() else { return }
        eventContinuation?.yield(event)

        #if DEBUG
        // Test seam: allows unit tests (and debug tools) to reliably observe emissions
        // without depending solely on AsyncStream iterator scheduling in the test host.
        // Production code must not rely on this notification.
        print("[PlayerEventSeam] posting \(event)")
        NotificationCenter.default.post(
            name: Notification.Name("PlayerEventEmittedForTest"),
            object: nil,
            userInfo: ["event": event]
        )
        #endif
    }

    // MARK: - Current State & Replay (Tier 3)

    /// The current authoritative player-domain state.
    ///
    /// Late subscribers (UI views that appear after playback has started, future
    /// widget or Live Activity surfaces, test harnesses, or recovery observers)
    /// read this snapshot to initialize themselves to the present rather than
    /// waiting for the next transition.
    ///
    /// The snapshot is constructed from the same in-actor values that drive
    /// event emission (`currentVisualState`, `playbackIntent`, `currentStreamMetadata`)
    /// together with the persisted error flag.
    ///
    /// - Returns: A `PlayerCurrentState` reflecting the state at the moment of the call.
    /// - SeeAlso: ``events``, ``makeEventsStreamWithReplay()``, `PlayerCurrentState`,
    ///   `PlayerCurrentState.isActivelyPlaying`,
    ///   `PlayerCurrentState.isBlockedByStickyIntent`,
    ///   `PlayerCurrentState.isInPermanentError`,
    ///   ``loadPersistedWidgetState()``, `PlayerEvent.visualStateDidChange`,
    ///   `PlayerEvent.playbackIntentChanged`, `PlayerEvent.metadataDidUpdate`,
    ///   CODING_AGENT.md, docs/Event-Driven-Refactor-Roadmap.md.
    /// - Important: `currentState` is a read-only derived surface. All mutation
    ///   continues to occur through the existing canonical methods; the snapshot
    ///   simply observes.
    /// - Note: Safe to call from any context that can await the actor (main app
    ///   UI, recovery paths). Widget extension processes read equivalent data via
    ///   the persisted snapshot facades.
    public var currentState: PlayerCurrentState {
        get async {
            var errorFlag = currentVisualState == .securityLocked
            if let snapshot = Self.loadPersistedWidgetState() {
                errorFlag = errorFlag || snapshot.hasError
            }
            return PlayerCurrentState(
                visualState: currentVisualState,
                playbackIntent: playbackIntent,
                streamMetadata: currentStreamMetadata,
                hasError: errorFlag
            )
        }
    }

    /// Returns an `AsyncStream<PlayerEvent>` that replays the current state as the
    /// corresponding events and then forwards every subsequent live emission.
    ///
    /// This surface supplies replay for late subscribers while preserving the
    /// original `events` contract for existing observers.
    ///
    /// On first iteration the returned stream yields:
    /// - `.visualStateDidChange` with the present visual state
    /// - `.playbackIntentChanged` with the present intent
    /// - `.metadataDidUpdate` (with current or nil value)
    /// - `.persistedWidgetStateDidUpdate` (as a signal that snapshot state exists)
    ///
    /// All future events from the authoritative emitter follow immediately.
    ///
    /// Stream transition verbs (`streamDidStart`, `streamDidPause`, `streamDidStop`,
    /// `streamDidFail`) are deliberately not synthesized here. The resulting
    /// terminal state (including permanent errors) is expressed via the fields
    /// of the yielded `PlayerCurrentState` (in particular `hasError`). This is
    /// the finalized Tier 3 replay contract. See ``PlayerCurrentState`` and the
    /// architectural evaluation in the roadmap.
    ///
    /// - Returns: A stream whose first elements represent the state at the time
    ///   the stream was created, followed by live events.
    /// - SeeAlso: ``events``, ``currentState``, `PlayerCurrentState`, `PlayerEvent`,
    ///   `WidgetEventObserver`, `PlayerEventSubscriber`,
    ///   `PlayerCurrentState.isInPermanentError`,
    ///   `PlayerCurrentState.isBlockedByStickyIntent`,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 3 current-state replay + error and recovery surface).
    /// - Important: Each call produces an independent stream. Existing direct
    ///   observation of `events` and all imperative paths are unaffected.
    /// - Note: The replay events are synthesized from current state; they do not
    ///   represent historical transition ordering.
    /// Cancels the active replay live-forwarding attachment on ``events``.
    ///
    /// Called when a replay consumer ends (for example ``PlayerEventSubscriber/cancel()``)
    /// or before creating a new replay stream so the shared ``AsyncStream`` iterator is
    /// released for the Tier 2 refresh observer or direct test collectors.
    ///
    /// - SeeAlso: ``makeEventsStreamWithReplay()``, ``events``, ``PlayerEventSubscriber``.
    func cancelReplayForwarding() {
        replayForwardingTask?.cancel()
        replayForwardingTask = nil
    }

    public func makeEventsStreamWithReplay() async -> AsyncStream<PlayerEvent> {
        cancelReplayForwarding()

        let (stream, continuation) = AsyncStream.makeStream(of: PlayerEvent.self)

        // Replay current state as the events that would have produced it.
        // This gives late subscribers the present without requiring them to
        // read multiple SSOT surfaces before subscribing.
        //
        // NOTE (Tier 3 replay contract): Only the four state-carrying facts are
        // synthesized. No `streamDid*` verbs are emitted here; terminal conditions
        // (including errors) are carried by the `PlayerCurrentState` fields and
        // its convenience accessors. See ``makeEventsStreamWithReplay()`` docs.
        let state = await currentState
        continuation.yield(.visualStateDidChange(state.visualState))
        continuation.yield(.playbackIntentChanged(state.playbackIntent))
        continuation.yield(.metadataDidUpdate(state.streamMetadata))
        continuation.yield(.persistedWidgetStateDidUpdate)

        // Forward every future live event from the primary stream.
        // The forwarding task lives for the lifetime of this per-subscriber
        // stream (or until the process ends). Yields to a finished continuation
        // are ignored by AsyncStream.
        //
        // Materialize the shared live stream while already actor-isolated so the
        // forwarding task does not need a second actor hop before subscribing.
        let liveEvents = await events
        replayForwardingTask = Task {
            for await event in liveEvents {
                if Task.isCancelled { break }
                continuation.yield(event)
            }
            continuation.finish()
        }

        // Allow the forwarding task to reach its first suspended `for await` before
        // callers drive live mutations (closes the subscribe race in Tier 5 tests).
        await Task.yield()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))

        return stream
    }

    // MARK: - Computed Properties (nonisolated safe access)
    
    // NEW: Make sharedDefaults easily accessible (nonisolated since it's read-only & safe)
    /// App Group suite accessor shared by membership-exception extension files.
    nonisolated internal var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: "group.radio.lutheran.shared")
    }
    
    // Widget-safe accessors for extension processes
    nonisolated var availableStreams: [DirectStreamingPlayer.Stream] {
        return DirectStreamingPlayer.availableStreams
    }
    
    // MARK: - Initialization

    /// Synchronous factory reset invoked from ``init()`` before any caller can observe stale disk state.
    private init() {
        Self.clearPersistedVisualStateKeysFromDisk()
        Self.clearInMemorySessionSnapshot()
    }

    /// Forces factory-default visual/playback state on every cold launch and actor (re)initialization.
    ///
    /// **Memory-only policy:** Clears all on-disk visual/playback keys, drops the in-process session
    /// snapshot, resets `currentVisualState` to `.prePlay`, and clears parsed stream metadata.
    /// Playback intent is reset to `.shouldBePlaying` unless `.securityLocked` (same-process only).
    ///
    /// Auto-play on first launch / after tuning remains intact because intent returns to
    /// `.shouldBePlaying` and visual is `.prePlay`. In-session thermal sanitization and sticky
    /// pause/lock semantics continue to apply until the process ends.
    ///
    /// - Precondition: Safe to call from main-app launch (`ViewController` cold-launch Task) and tests.
    /// - Postcondition: `loadPersistedWidgetState()` returns `nil`; widgets show safe defaults;
    ///   system Now Playing metadata cleared (main app); durable LA toggle visual + language
    ///   mirrors cleared; recorded boot identity aligned to this boot.
    ///
    /// - SeeAlso: ``ensureVisualStateLoaded()``, ``loadPersistedWidgetState()``,
    ///   ``clearPersistedVisualStateKeysFromDisk()``, ``clearLiveActivityToggleVisualStateMirror()``,
    ///   ``clearLiveActivityLanguageMirror()``,
    ///   ViewController.viewDidLoad, docs/Event-Driven-Refactor-Roadmap.md, CODING_AGENT.md (SSOT principles).
    ///
    /// AGENT NOTE: Any new launch path that could observe stale App Group visual keys must call
    /// this (or rely on `init()` + this explicit await) before `refreshVisualStateFromPersistence`.
    func resetToFactoryDefaultsOnLaunch() async {
        #if LUTHERAN_MAIN_APP
        await performSessionAndWidgetTeardown(
            includeFactoryReset: true,
            liveActivityTeardown: .immediate,
            refreshWidgets: true,
            widgetVisualState: .prePlay,
            staleLiveness: false
        )
        #else
        Self.clearPersistedVisualStateKeysFromDisk()
        Self.clearInMemorySessionSnapshot()
        // Explicit LA toggle visual + language mirror clear (factory reset hygiene; not only LA-end paths).
        Self.clearLiveActivityToggleVisualStateMirror()
        Self.clearLiveActivityLanguageMirror()
        Self.recordCurrentSystemBootTime()
        currentVisualState = .prePlay
        currentStreamMetadata = nil
        hasLoadedVisualStateFromPersistence = false
        lastUserPauseTimestamp = 0
        if playbackIntent != .securityLocked {
            updatePlaybackIntent(to: .shouldBePlaying)
        }
        #endif
        #if DEBUG
        print("[SharedPlayerManager] resetToFactoryDefaultsOnLaunch → .prePlay (memory-only, disk visual keys cleared)")
        #endif
    }

    #if LUTHERAN_MAIN_APP
    /// How Live Activities are dismissed during session teardown.
    enum LiveActivityTeardownStyle: Sendable {
        /// Leave Live Activities unchanged.
        case none
        /// Graceful end while the app remains running (privacy clear).
        case graceful
        /// Immediate dismissal (termination, cold-launch hygiene).
        case immediate
    }

    /// Comprehensive session + widget teardown for privacy, termination, cold launch, and post-stop hygiene.
    ///
    /// Orchestrates optional factory reset, system Now Playing teardown (phase 1 + detached phase 2),
    /// Live Activity dismissal, liveness sentinel, and immediate widget timeline reload. Widget IPC runs
    /// only after the teardown gate is released so MediaRemoteUI launch watchdog windows stay safe.
    ///
    /// - Parameters:
    ///   - includeFactoryReset: When `true`, purges on-disk visual keys, drops the in-memory session
    ///     snapshot, resets visual state to `.prePlay` (preserving `.securityLocked` intent), clears
    ///     durable LA toggle visual + language mirrors, and records current boot identity.
    ///   - liveActivityTeardown: Whether to end Live Activities gracefully or immediately.
    ///   - refreshWidgets: When `true`, calls `WidgetCenter.reloadAllTimelines()` and
    ///     `WidgetRefreshManager.refreshIfNeeded(..., immediate: true)`.
    ///   - widgetVisualState: Target visual for the widget refresh; defaults to `currentVisualState`.
    ///   - staleLiveness: When `true`, writes the termination liveness sentinel (`lastUpdateTime = 0`).
    ///
    /// - Precondition: Main-app target only. Do not call while intentionally backgrounding live playback
    ///   unless `refreshWidgets` is `false` and factory reset is `false`.
    /// - Postcondition: System Now Playing cleared; optional LA ended; widgets reloaded when requested.
    ///   Factory reset also clears ``liveActivityToggleVisualStateAppGroupKey`` and
    ///   ``liveActivityCurrentLanguageAppGroupKey``.
    ///
    /// - SeeAlso: ``teardownNowPlayingSession()``, ``resetToFactoryDefaultsOnLaunch()``,
    ///   ``clearAllLocalState()``, ``performPostStopWidgetHygiene()``,
    ///   ``clearLiveActivityToggleVisualStateMirror()``, ``clearLiveActivityLanguageMirror()``,
    ///   ``performSessionTeardownSynchronouslyForTermination()``,
    ///   `WidgetRefreshManager.refreshIfNeeded(visualState:currentLanguage:hasError:immediate:)`,
    ///   docs/Event-Driven-Refactor-Roadmap.md, CODING_AGENT.md.
    func performSessionAndWidgetTeardown(
        includeFactoryReset: Bool = false,
        liveActivityTeardown: LiveActivityTeardownStyle = .immediate,
        refreshWidgets: Bool = true,
        widgetVisualState: PlayerVisualState? = nil,
        staleLiveness: Bool = false
    ) async {
        guard !isRunningInWidget() else { return }

        #if DEBUG
        print("[SessionTeardown] LOCK — performSessionAndWidgetTeardown entered (factoryReset: \(includeFactoryReset), staleLiveness: \(staleLiveness), refreshWidgets: \(refreshWidgets), la: \(liveActivityTeardown))")
        #endif

        if staleLiveness {
            Self.forceStaleLivenessTimestampForTermination()
        }

        if includeFactoryReset {
            Self.clearPersistedVisualStateKeysFromDisk()
            Self.clearInMemorySessionSnapshot()
            // Explicit factory-reset hygiene: drop durable LA toggle visual + language
            // plan signals even when Live Activity teardown is `.none` (callers may vary).
            // Stops cold extensions from planning play/pause or stamping language chrome
            // against pre-reset mirrors.
            Self.clearLiveActivityToggleVisualStateMirror()
            Self.clearLiveActivityLanguageMirror()
            // Align boot identity after reset so same-boot post-reset planning does not
            // treat the process as "rebooted" solely because mirror was cleared.
            Self.recordCurrentSystemBootTime()
            currentVisualState = .prePlay
            currentStreamMetadata = nil
            hasLoadedVisualStateFromPersistence = false
            lastUserPauseTimestamp = 0
            if playbackIntent != .securityLocked {
                updatePlaybackIntent(to: .shouldBePlaying)
            }
        }

        await MainActor.run {
            switch liveActivityTeardown {
            case .none:
                break
            case .graceful:
                RadioLiveActivityManager.shared.endActivity()
            case .immediate:
                RadioLiveActivityManager.shared.handleAppWillTerminate()
            }
        }

        await teardownNowPlayingSession()

        if refreshWidgets {
            let visual = widgetVisualState ?? currentVisualState
            let shared = loadSharedState()
            await MainActor.run {
                WidgetCenter.shared.reloadAllTimelines()
                WidgetRefreshManager.shared.refreshIfNeeded(
                    visualState: visual,
                    currentLanguage: shared.currentLanguage,
                    hasError: shared.hasError,
                    immediate: true
                )
            }
        }

        #if DEBUG
        print("[SessionTeardown] UNLOCK — performSessionAndWidgetTeardown complete")
        #endif
    }

    /// Post-stop widget hygiene after ``stop()``: immediate timeline reload without factory reset or LA end.
    ///
    /// Keeps home-screen widgets and Control Center in sync with the sticky `.userPaused` lock while
    /// preserving the Live Activity paused presentation.
    ///
    /// - SeeAlso: ``stop()``, ``performSessionAndWidgetTeardown(includeFactoryReset:liveActivityTeardown:refreshWidgets:widgetVisualState:staleLiveness:)``,
    ///   docs/Event-Driven-Refactor-Roadmap.md.
    func performPostStopWidgetHygiene() async {
        guard !isRunningInWidget() else { return }

        let shared = loadSharedState()
        await MainActor.run {
            WidgetCenter.shared.reloadAllTimelines()
            WidgetRefreshManager.shared.refreshIfNeeded(
                visualState: .userPaused,
                currentLanguage: shared.currentLanguage,
                hasError: shared.hasError,
                immediate: true
            )
        }

        #if DEBUG
        print("[SessionTeardown] Post-stop widget hygiene — immediate .userPaused refresh")
        #endif
    }

    /// Best-effort synchronous session teardown for process exit (`applicationWillTerminate`,
    /// `sceneDidDisconnect`) where async actor work may not complete before exit.
    ///
    /// - Important: Metadata clear is the critical privacy step; widget reload is best-effort on the
    ///   main thread before the process dies.
    ///
    /// - SeeAlso: ``performSessionAndWidgetTeardown(includeFactoryReset:liveActivityTeardown:refreshWidgets:widgetVisualState:staleLiveness:)``,
    ///   ``clearSystemNowPlayingMetadataSynchronously()``, AppDelegate.applicationWillTerminate,
    ///   SceneDelegate.sceneDidDisconnect, docs/Event-Driven-Refactor-Roadmap.md.
    nonisolated static func performSessionTeardownSynchronouslyForTermination() {
        forceStaleLivenessTimestampForTermination()
        // Termination callbacks run on the main thread; assumeIsolated satisfies strict Swift 6.
        MainActor.assumeIsolated {
            RadioLiveActivityManager.shared.handleAppWillTerminate()
            WidgetRefreshManager.shared.cancelPendingRefresh()
            WidgetCenter.shared.reloadAllTimelines()
            WidgetRefreshManager.shared.refreshIfNeeded(
                visualState: .prePlay,
                currentLanguage: preferredWidgetLanguage(),
                hasError: false,
                immediate: true
            )
        }
        clearSystemNowPlayingMetadataSynchronously()

        #if DEBUG
        print("[SessionTeardown] SYNC termination teardown — liveness staled, LA ended, widgets reloaded, Now Playing cleared")
        #endif
    }
    #endif
    
    // MARK: - Nonisolated Public Surface (Widget / Extension Safe)
    //
    // These entry points are safe for widget intents, timeline providers, Control Center,
    // Live Activities, and other non-actor contexts. They either perform no actor work
    // or hop internally via Task.
    
    /// Returns the authoritative visual state for widget/extension decision paths and fallbacks.
    ///
    /// - Returns: `PlayerVisualState` from the in-memory session snapshot when present;
    ///   otherwise `.prePlay` (including after cold launch).
    ///
    /// - SeeAlso: ``loadPersistedWidgetState()``, ``persistWidgetSnapshot``,
    ///   CODING_AGENT.md.
    ///
    /// Nonisolated static — safe for widget timeline providers.
    nonisolated static func loadPersistedVisualStateDirect() -> PlayerVisualState {
        if let combined = loadPersistedWidgetState() {
            return combined.visualState
        }
        return .prePlay
    }
    
    /// Returns whether the current execution context is a widget extension process.
    ///
    /// Authoritative ``PlayerEvent`` emission is suppressed when this returns `true`;
    /// widget processes use optimistic snapshot writes instead.
    ///
    /// - Returns: `true` in the widget extension target, or in the main app when the
    ///   WidgetKit preview environment is active.
    /// - SeeAlso: ``emit(_:)``, ``isWidgetProcess()``, ``persistOptimisticWidgetSnapshot(_:language:)``,
    ///   ``_test_setSimulateWidgetProcessContext(_:)`` (DEBUG), docs/Event-Driven-Refactor-Roadmap.md.
    nonisolated func isRunningInWidget() -> Bool {
        #if DEBUG
        if unsafe Self._test_simulateWidgetProcessContext { return true }
        #endif
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
    ///
    /// Used to bypass privacy write gates for optimistic updates originating from
    /// App Intents (proof that a Lutheran widget is present and was just interacted with)
    /// and to suppress main-app-only ``PlayerEvent`` observation in
    /// ``PlayerEventSubscriber/beginObserving()`` and
    /// ``WidgetRefreshManager/beginObservingPlayerEvents()``.
    ///
    /// - SeeAlso: ``isRunningInWidget()``, ``emit(_:)``,
    ///   ``_test_setSimulateWidgetProcessContext(_:)`` (DEBUG), ``PlayerEventSubscriber``,
    ///   docs/Event-Driven-Refactor-Roadmap.md.
    nonisolated static func isWidgetProcess() -> Bool {
        #if LUTHERAN_MAIN_APP
        #if DEBUG
        if unsafe Self._test_simulateWidgetProcessContext { return true }
        #endif
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
    
    /// Writes an optimistic widget snapshot for instant extension feedback (App Intents, Control Center, Live Activity).
    ///
    /// Permanent cross-process infrastructure: persists the in-memory session `PersistedWidgetState`
    /// (visual + language) and updates the actor's `currentVisualState` in the executing process so
    /// the next Provider run sees correct play/pause and language before the Darwin round-trip
    /// completes. Main-app authoritative saves via ``saveCurrentState()`` / ``performActualSave``
    /// overwrite without corrupting pending actions. Widget processes never emit ``PlayerEvent``
    /// (see ``emit(_:)`` guard).
    ///
    /// New main-app consumers should observe ``events`` (or snapshot reads) rather than adding
    /// optimistic write call sites in the main app.
    ///
    /// - Parameters:
    ///   - state: Target visual state (typically `.playing` or `.userPaused` from a widget intent).
    ///   - language: Optional explicit language code. When nil, falls back to ``preferredWidgetLanguage()``.
    ///     Passing the language the widget entry was rendered with keeps optimistic UI and the
    ///     snapshot consistent (prevents transient `"en"` for a `fi` stream in refresh logs).
    ///
    /// Widget/AppIntent callers should prefer a language derived from ``loadPersistedWidgetState()``
    /// so the snapshot reflects the station the user saw/tapped.
    ///
    /// - SeeAlso: ``signalWidgetPendingAction(visualState:action:language:)``,
    ///   ``persistWidgetSnapshot(visualState:language:streamMetadata:clearStreamMetadata:hasError:)``,
    ///   ``WidgetToggleRadioIntent``, ``events``, ``emit(_:)``,
    ///   docs/Widget-Functionality-Roadmap.md, docs/Widget-Presentation-Dataflow.md,
    ///   docs/Event-Driven-Refactor-Roadmap.md, CODING_AGENT.md (SSOT + event-driven direction).
    nonisolated public func persistOptimisticWidgetSnapshot(_ state: PlayerVisualState, language: String? = nil) {
        let lang = language ?? Self.preferredWidgetLanguage()
        Self.persistWidgetSnapshot(visualState: state, language: lang)
        // Update in-memory so the widget process sees the fresh state on the next snapshot
        // without waiting for a Darwin round-trip or a full re-load.
        Task { await Self.shared._forceSetCurrentVisualState(state) }
    }

    /// Applies an optimistic visual state on the actor after a nonisolated hop from
    /// ``persistOptimisticWidgetSnapshot(_:language:)``.
    ///
    /// Sets the persistence-loaded guard so subsequent `ensureVisualStateLoaded` calls
    /// see the value. Never emits (`emit(_:)` is main-app-only; widget processes are guarded).
    ///
    /// - Parameter state: The visual state written optimistically by a widget or Live Activity intent.
    /// - Important: Permanent infrastructure for cross-process instant feedback. Authoritative
    ///   transitions for main-app observers still flow through ``emit(_:)`` after engine mutations.
    /// - SeeAlso: ``persistOptimisticWidgetSnapshot(_:language:)``, ``events``,
    ///   docs/Widget-Functionality-Roadmap.md, docs/Widget-Presentation-Dataflow.md.
    internal func _forceSetCurrentVisualState(_ state: PlayerVisualState) {
        currentVisualState = state
        hasLoadedVisualStateFromPersistence = true
    }

    /// Public entry point for widget/extension providers to guarantee they read the real persisted state.
    /// Call this once at the top of any Provider method before reading currentVisualState or loadSharedState for UI decisions.
    public func syncVisualStateFromPersistence() async {
        ensureVisualStateLoaded()
    }
    
    /// Re-applies the factory-default visual load path for widget/extension hygiene.
    /// Widget Providers should call this before reading `currentVisualState` for UI decisions.
    /// Resets the one-shot guard so in-session updates from `persistOptimisticWidgetSnapshot` are visible
    /// in long-lived extension processes. Never reads visual state from UserDefaults.
    ///
    /// This is a read-side refresh helper for long-lived widget processes. It is unrelated to
    /// the event emission path; observers of ``events`` receive fresh values on the next yield
    /// without needing explicit refresh calls.
    ///
    /// - SeeAlso: ``syncVisualStateFromPersistence()``, ``loadPersistedWidgetState()``,
    ///   ``events``, docs/Event-Driven-Refactor-Roadmap.md.
    public func refreshVisualStateFromPersistence() async {
        hasLoadedVisualStateFromPersistence = false
        ensureVisualStateLoaded()
    }
    
}


extension Notification.Name {
    static let localStateCleared = Notification.Name("localStateCleared")
}

