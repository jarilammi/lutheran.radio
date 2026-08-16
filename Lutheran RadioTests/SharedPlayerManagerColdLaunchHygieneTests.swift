//
//  SharedPlayerManagerColdLaunchHygieneTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 24.7.2026.
//
//  Cold-launch factory reset, Now Playing / language hygiene, and the product split
//  between **user-initiated main open** vs **residual post-reboot surprise**.
//
//  Shared collectors: `Lutheran RadioTests/Support/PlayerEventTestSupport.swift`.
//  Isolation: ``prepareSharedPlayerManagerEventTestIsolation`` /
//  ``tearDownSharedPlayerManagerEventTestIsolation``.
//
//  - SeeAlso: ``SharedPlayerManager``, ``PlayerEvent``,
//    docs/Widget-Presentation-Dataflow.md (Cold launch vs passive widget open),
//    docs/Event-Driven-Refactor-Roadmap.md,
//    CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
//

import MediaPlayer
import XCTest
import WidgetSurface
@testable import Lutheran_Radio

/// Unit tests for cold-launch factory reset and system Now Playing hygiene.
///
/// Protects purge-only visual-state disk cleanup, termination / language SSOT rules,
/// Live Activity durable mirror clear completeness (visual + language App Group keys),
/// Live Activity language tracking independent of privacy-gated preferred widget language,
/// and the **two distinct cold-start stories** documented in
/// docs/Widget-Presentation-Dataflow.md:
///
/// 1. **User-initiated main open** — icon, Siri open, or `lutheranradio://open` starts a new
///    main process. After ``resetToFactoryDefaultsOnLaunch()``, product policy is “open = radio”
///    (special tuning then ``play()`` when sticky intent is absent). That path is **user-driven**:
///    the human brought the main app to the foreground.
/// 2. **Residual post-reboot / dirty-exit surprise** — App Group liveness, live chrome, pending
///    mailbox, or OS Now Playing left over after force-quit or power cycle must **not** look like
///    a live session or attach audio **without** that main-open path. Extension refuse / passive
///    chrome / residual clear are honesty for (2); they must not invent sticky pause that cancels (1).
///
/// Emission and media-surface suites are separate files.
///
/// - SeeAlso: ``SharedPlayerManager/resetToFactoryDefaultsOnLaunch()``,
///   ``SharedPlayerManager/teardownNowPlayingSession()``,
///   ``SharedPlayerManager/clearSystemNowPlayingMetadataSynchronously()``,
///   ``SharedPlayerManager/forceStaleLivenessTimestampForTermination()``,
///   ``SharedPlayerManager/clearAllLocalState()``,
///   ``SharedPlayerManager/preferredWidgetLanguage()``,
///   ``SharedPlayerManager/mainAppLiveActivityLanguageCode()``,
///   ``SharedPlayerManager/clearLiveActivityToggleVisualStateMirror()``,
///   ``SharedPlayerManager/clearLiveActivityLanguageMirror()``,
///   ``SharedPlayerManager/discardResidualPendingActionsAndArmMailboxForThisProcess()``,
///   ``SharedPlayerManager/getPendingActionIfFresh(maxAge:)``,
///   docs/Widget-Presentation-Dataflow.md,
///   docs/Event-Driven-Refactor-Roadmap.md,
///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
final class SharedPlayerManagerColdLaunchHygieneTests: XCTestCase {

    private let manager = SharedPlayerManager.shared

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()
        await prepareSharedPlayerManagerEventTestIsolation(manager: manager)
    }

    override func tearDown() async throws {
        await tearDownSharedPlayerManagerEventTestIsolation(manager: manager)
        try await super.tearDown()
    }

    // MARK: - Cold launch and Now Playing hygiene

    /// System Now Playing metadata must be cleared on factory reset / teardown so stale
    /// Lock Screen / Control Center cards do not survive relaunch or reboot.
    ///
    /// - SeeAlso: ``SharedPlayerManager/teardownNowPlayingSession()``,
    ///   ``SharedPlayerManager/resetToFactoryDefaultsOnLaunch()``.
    func testTeardownNowPlayingSessionClearsSystemMetadata() async {
        await MainActor.run {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: "Svenska LIVE"
            ]
            MPNowPlayingInfoCenter.default().playbackState = .playing
        }

        await manager.teardownNowPlayingSession()

        await MainActor.run {
            XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
            XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .stopped)
        }
    }

    /// Synchronous OS Now Playing clear used at process start and observed termination.
    ///
    /// **Invariant protected:** ``clearSystemNowPlayingMetadataSynchronously()`` nils
    /// `nowPlayingInfo` and sets `.stopped` without requiring the SharedPlayerManager actor.
    /// AppDelegate uses this on `didFinishLaunching` so residual reboot cards wipe before
    /// scene attach; termination uses the same helper when async teardown cannot complete.
    ///
    /// - SeeAlso: ``SharedPlayerManager/clearSystemNowPlayingMetadataSynchronously()``,
    ///   AppDelegate.application(_:didFinishLaunchingWithOptions:),
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    func testClearSystemNowPlayingMetadataSynchronouslyClearsResidualCard() async {
        await MainActor.run {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: "Pre-reboot residual LIVE"
            ]
            MPNowPlayingInfoCenter.default().playbackState = .playing

            SharedPlayerManager.clearSystemNowPlayingMetadataSynchronously()

            XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
            XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .stopped)
        }
    }

    /// Residual OS Now Playing from dirty exit must clear before user-initiated main open
    /// can re-publish via ``updateNowPlayingInfo()``.
    ///
    /// **Invariant protected:** Dirty force-quit / reboot skip observed terminate clear, so a
    /// pre-exit media card can survive. ``resetToFactoryDefaultsOnLaunch()`` →
    /// ``performSessionAndWidgetTeardown`` → ``teardownNowPlayingSession()`` phase 1 leaves
    /// `nowPlayingInfo == nil` and `playbackState == .stopped` **before** special tuning on
    /// user-initiated main open. A **new** card may appear only after intentional attach —
    /// not as leftover residual “radio is still on.”
    ///
    /// - SeeAlso: ``SharedPlayerManager/resetToFactoryDefaultsOnLaunch()``,
    ///   ``SharedPlayerManager/teardownNowPlayingSession()``,
    ///   ViewController cold-launch Task, docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   docs/Widget-Presentation-Dataflow.md (residual post-reboot surprise).
    func testFactoryResetClearsResidualSystemNowPlayingBeforeUserInitiatedMainOpen() async {
        await MainActor.run {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: "Dirty-exit residual LIVE"
            ]
            MPNowPlayingInfoCenter.default().playbackState = .playing
        }

        await manager.resetToFactoryDefaultsOnLaunch()

        let visual = await manager.currentVisualState
        XCTAssertEqual(visual, .prePlay, "Factory reset must land .prePlay before user-initiated open play")

        await MainActor.run {
            XCTAssertNil(
                MPNowPlayingInfoCenter.default().nowPlayingInfo,
                "Residual OS Now Playing must clear on factory reset before special tuning"
            )
            XCTAssertEqual(
                MPNowPlayingInfoCenter.default().playbackState,
                .stopped,
                "Residual playbackState must be .stopped until attach after user-initiated open"
            )
        }
    }

    /// Protects cold-launch factory reset: stale on-disk visual state must never restore after relaunch.
    ///
    /// Seeds retired App Group keys left by pre-memory-only installs (snapshot blobs, playback
    /// bools, bare language). ``resetToFactoryDefaultsOnLaunch()`` must purge them via
    /// ``clearPersistedVisualStateKeysFromDisk()`` and leave `.prePlay` with no in-memory session
    /// snapshot so auto-play on first launch remains viable. Visual state is never upgraded from
    /// disk — purge only.
    ///
    /// - SeeAlso: ``SharedPlayerManager/resetToFactoryDefaultsOnLaunch()``,
    ///   ``SharedPlayerManager/clearPersistedVisualStateKeysFromDisk()``,
    ///   ``SharedPlayerManager/loadPersistedWidgetState()``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (OI-1).
    func testColdLaunchFactoryResetClearsDiskVisualStateAndReturnsPrePlay() async {
        let stale = SharedPlayerManager.PersistedWidgetState(
            visualState: .thermalPaused,
            currentLanguage: "sv"
        )
        let data = try! JSONEncoder().encode(stale)
        let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared")
        defaults?.set(data, forKey: "persistedWidgetState")
        defaults?.set(data, forKey: "playerVisualState")
        defaults?.set(true, forKey: "isPlaying")
        defaults?.set(true, forKey: "playing")
        defaults?.set(true, forKey: "hasError")
        defaults?.set("fi", forKey: "currentLanguage")
        // Retired operational App Group leftovers (no writers; must purge on factory reset).
        defaults?.set(Date().timeIntervalSince1970, forKey: "lastUserPauseTime")
        defaults?.set(0.75, forKey: "preferredVolume")
        // Stale durable LA toggle visual + language mirrors must not survive factory reset.
        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(.playing)
        SharedPlayerManager.persistLiveActivityLanguageMirror("fi")
        XCTAssertEqual(SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(), .playing)
        XCTAssertEqual(SharedPlayerManager.loadLiveActivityLanguageMirror(), "fi")
        // Seed live chrome with widget-process bypass so residual is present before factory reset
        // (main-app gate may be closed under test isolation).
        SharedPlayerManager._test_setSimulateWidgetProcessContext(true)
        SharedPlayerManager.persistHomeWidgetLiveChromeMirror(
            HomeWidgetLiveChrome(
                visualState: .playing,
                currentLanguage: "fi",
                hasError: false,
                updatedAt: Date().timeIntervalSince1970
            )
        )
        SharedPlayerManager._test_setSimulateWidgetProcessContext(false)
        XCTAssertNotNil(SharedPlayerManager.loadHomeWidgetLiveChromeMirror())

        await manager.resetToFactoryDefaultsOnLaunch()

        let visual = await manager.currentVisualState
        XCTAssertEqual(visual, .prePlay)
        XCTAssertTrue(visual.shouldAutoPlayOrResume)
        XCTAssertNil(SharedPlayerManager.loadPersistedWidgetState())
        XCTAssertEqual(SharedPlayerManager.loadPersistedVisualStateDirect(), .prePlay)
        XCTAssertNil(defaults?.data(forKey: "persistedWidgetState"))
        XCTAssertNil(defaults?.data(forKey: "playerVisualState"))
        XCTAssertNil(defaults?.object(forKey: "isPlaying"))
        XCTAssertNil(defaults?.object(forKey: "playing"))
        XCTAssertNil(defaults?.object(forKey: "hasError"))
        XCTAssertNil(
            defaults?.object(forKey: "currentLanguage"),
            "Retired bare currentLanguage must be purged with other visual keys"
        )
        XCTAssertNil(
            defaults?.object(forKey: "lastUserPauseTime"),
            "Retired lastUserPauseTime must be purged (sticky PlaybackIntent is pause recovery SSOT)"
        )
        XCTAssertNil(
            defaults?.object(forKey: "preferredVolume"),
            "Retired preferredVolume must be purged (system volume is SSOT)"
        )
        XCTAssertNil(
            SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(),
            "Factory reset must explicitly clear liveActivityToggleVisualState"
        )
        XCTAssertNil(
            SharedPlayerManager.loadLiveActivityLanguageMirror(),
            "Factory reset must explicitly clear liveActivityCurrentLanguage"
        )
        XCTAssertNil(
            SharedPlayerManager.loadHomeWidgetLiveChromeMirror(),
            "Factory reset must clear privacy-gated homeWidgetLiveChrome (OI-1 residual hygiene)"
        )
        // Boot identity realigned so same-boot post-reset planning is not false-reboot.
        XCTAssertFalse(SharedPlayerManager.hasDeviceRebootedSinceLastRecordedBoot())
    }

    /// With no session snapshot and no active home widgets, ``preferredWidgetLanguage()``
    /// hard-defaults to `"en"` even when a retired App Group `currentLanguage` value is present.
    ///
    /// **Privacy invariant protected:** bare language leftovers from pre-memory-only installs
    /// must not influence home-widget language when writes are suppressed. Resolution is
    /// snapshot → `bestInitialLanguageCode()` (widgets active) → hard `"en"` only — never the
    /// bare App Group key (which is also purged by ``clearPersistedVisualStateKeysFromDisk()``).
    ///
    /// - SeeAlso: ``SharedPlayerManager/preferredWidgetLanguage()``,
    ///   ``SharedPlayerManager/clearPersistedVisualStateKeysFromDisk()``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (OI-1).
    func testPreferredWidgetLanguageIgnoresRetiredBareCurrentLanguageKey() async {
        await manager.resetToFactoryDefaultsOnLaunch()
        await MainActor.run {
            WidgetRefreshManager.setHasActiveLutheranWidgets(false)
        }

        let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared")
        // Seed after factory purge so a pre-memory-only leftover is the only disk language signal.
        defaults?.set("sv", forKey: "currentLanguage")

        XCTAssertEqual(
            SharedPlayerManager.preferredWidgetLanguage(),
            "en",
            "No-widgets path must hard-default to en; bare currentLanguage is not a language SSOT"
        )

        SharedPlayerManager.clearPersistedVisualStateKeysFromDisk()
    }

    /// Main-app LA language SSOT tracks engine ``selectedStream``, not privacy-gated preferred widget language.
    ///
    /// When home widgets are absent, ``preferredWidgetLanguage()`` hard-defaults to `"en"`.
    /// Live Activity ContentState must still carry the stream attach language so Lock Screen
    /// flag/name chrome match the playing stream.
    func testMainAppLiveActivityLanguageCodeTracksSelectedStream() async {
        // `availableStreams` is a nonisolated sync property; no await required.
        let streams = manager.availableStreams
        guard let finnish = streams.first(where: { $0.languageCode == "fi" }) else {
            XCTFail("Expected Finnish stream in catalog")
            return
        }
        await manager.switchToStream(finnish)

        let selected = await MainActor.run {
            DirectStreamingPlayer.shared.selectedStream.languageCode
        }
        XCTAssertEqual(selected, "fi")
        XCTAssertEqual(
            SharedPlayerManager.mainAppLiveActivityLanguageCode(),
            "fi",
            "LA ContentState language source must follow stream attach language"
        )
    }

    // MARK: - User-initiated main open vs residual reboot surprise
    //
    // Two different “cold start” stories (do not conflate in assertions or product language):
    //
    // | Story | Who chose radio? | Expected audio / chrome |
    // |-------|------------------|-------------------------|
    // | **User-initiated main open** | Human opened main (icon, Siri, `lutheranradio://open`) | Special tuning + stream after factory reset when sticky intent is absent |
    // | **Residual post-reboot surprise** | Nobody — dirty power-off left App Group / OS media | Passive home, refuse residual-only play, clear residual NP/pending; **no** multi-minute “still playing” without a resident main process |
    //
    // Reboot then **icon open** is still user-initiated main open (row 1). Residual keys must
    // not cancel that eligibility. Residual keys also must not present row-1 behavior while
    // main is not resident (row 2). See docs/Widget-Presentation-Dataflow.md.

    /// User-initiated main open stays eligible after factory reset (“open app = radio”).
    ///
    /// **Invariant protected:** After ``resetToFactoryDefaultsOnLaunch()`` the new process has
    /// ``.prePlay`` + active ``PlaybackIntent`` + ``shouldAutoPlayOrResume``. That is the
    /// precondition for the `ViewController` cold-launch Task (special tuning then
    /// ``play()``) when the **user** starts main — icon, Siri, or passive-widget open URL.
    ///
    /// Residual post-reboot honesty (passive home, NP clear, pending discard, durable-mirror
    /// distrust while main is not resident) must **not** leave sticky pause, empty intent, or a
    /// stuck reboot-distrust gate that would cancel this **user-driven** path once factory reset
    /// has realigned boot identity.
    ///
    /// **Not covered here:** surprise attach without main open (pending residual, extension
    /// inventing play, residual OS media card). Those are separate tests in this suite and in
    /// extension contract suites.
    ///
    /// - SeeAlso: ``SharedPlayerManager/resetToFactoryDefaultsOnLaunch()``,
    ///   ``PlayerVisualState/shouldAutoPlayOrResume``, ViewController cold-launch Task,
    ///   docs/Widget-Presentation-Dataflow.md (User-initiated main open vs residual surprise).
    func testUserInitiatedMainOpenRemainsEligibleAfterFactoryReset() async {
        await manager.resetToFactoryDefaultsOnLaunch()

        let visual = await manager.currentVisualState
        let intent = await manager.currentPlaybackIntent
        XCTAssertEqual(visual, .prePlay)
        XCTAssertTrue(
            visual.shouldAutoPlayOrResume,
            "User-initiated main open: factory .prePlay must stay auto-play eligible"
        )
        XCTAssertTrue(
            intent.isActivePlaybackIntent,
            "User-initiated main open: factory reset must not invent sticky pause that blocks special tuning + play"
        )
        XCTAssertFalse(
            SharedPlayerManager.hasDeviceRebootedSinceLastRecordedBoot(),
            "Factory reset realigns boot identity so *this* open is not stuck in false-reboot distrust"
        )
        XCTAssertFalse(
            SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning(),
            "After factory realign, user-initiated open must not remain in durable-mirror distrust"
        )
    }

    /// Residual pre-reboot heartbeat must not look like a live main session after power cycle.
    ///
    /// **Invariant protected (residual surprise, not user open):** When
    /// ``hasDeviceRebootedSinceLastRecordedBoot()`` is true, ``isMainAppProcessRecentlyActive()``
    /// is false even if wall-clock `lastUpdateTime` is still inside the 60 s window. That forces
    /// passive home chrome **without** the user having opened main. This is the opposite of
    /// user-initiated main open: residual App Group alone must not advertise “still playing.”
    ///
    /// Main-app profile (``LUTHERAN_MAIN_APP``) must match extension passive-chrome honesty.
    /// When the user later opens the app, factory reset realigns boot identity (see
    /// ``testUserInitiatedMainOpenRemainsEligibleAfterFactoryReset``).
    ///
    /// - SeeAlso: ``SharedPlayerManager/isMainAppProcessRecentlyActive()``,
    ///   ``SharedPlayerManager/hasDeviceRebootedSinceLastRecordedBoot()``,
    ///   ``SharedPlayerManager/shouldDistrustDurableMirrorPlayPlanning()``,
    ///   docs/Widget-Presentation-Dataflow.md.
    func testResidualRebootHeartbeatDoesNotImplyLiveMainSession() {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        SharedPlayerManager.recordCurrentSystemBootTime()

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        let residual = Date().timeIntervalSince1970 - 10
        defaults.set(residual, forKey: "lastUpdateTime")
        XCTAssertTrue(
            SharedPlayerManager.isMainAppProcessRecentlyActive(),
            "Precondition: residual heartbeat is inside the 60 s window on a trusted boot"
        )

        // Prior boot epoch left across hard power-off (main never opened after reboot).
        defaults.set(1.0, forKey: SharedPlayerManager.recordedSystemBootTimeAppGroupKey)
        XCTAssertTrue(SharedPlayerManager.hasDeviceRebootedSinceLastRecordedBoot())
        XCTAssertTrue(SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning())
        XCTAssertFalse(
            SharedPlayerManager.isMainAppProcessRecentlyActive(),
            "Residual post-reboot surprise: boot-identity mismatch must force passive chrome without user open"
        )
    }

    // MARK: - Live Activity durable mirror clear completeness

    /// Prior-process termination liveness must not block this-process `play()` when intent is active.
    ///
    /// **Invariant protected (process isolation):** ``hasExplicitTerminationSentinel()`` is a
    /// widget passive-chrome / durable-mirror-distrust marker only. After factory reset to
    /// `.prePlay` + active intent, ``play()`` proceeds (UITest isolation path under XCTest)
    /// even when `lastUpdateTime == 0` is present (prior quit). Sticky this-process intent
    /// remains the sole hard play blocker.
    ///
    /// - SeeAlso: ``SharedPlayerManager/play()``, ``PlaybackPlayDecision/evaluateEarlyGates(_:)``,
    ///   ``SharedPlayerManager/hasExplicitTerminationSentinel()``,
    ///   ViewController cold-launch guard, SharedPlayerManager resurrection table.
    func testTerminationSentinelDoesNotBlockPlayWhenIntentActive() async {
        let suite = "group.radio.lutheran.shared"
        let defaults = UserDefaults(suiteName: suite)
        defer {
            defaults?.removeObject(forKey: "lastUpdateTime")
        }

        // Clean this-process play status first (mirrors cold launch factory reset).
        await manager.resetToFactoryDefaultsOnLaunch()
        let visualAfterReset = await manager.currentVisualState
        let intentAfterReset = await manager.currentPlaybackIntent
        XCTAssertEqual(visualAfterReset, .prePlay)
        XCTAssertTrue(
            intentAfterReset.isActivePlaybackIntent,
            "Factory reset must restore active intent so cold play remains viable"
        )

        // Model a leftover prior-process quit marker still present in the App Group.
        // (Privacy residual cleanup may remove liveness keys when no widgets are configured;
        // re-stamp after reset so the play gate is exercised against a live sentinel.)
        SharedPlayerManager.forceStaleLivenessTimestampForTermination()
        XCTAssertTrue(
            SharedPlayerManager.hasExplicitTerminationSentinel(),
            "Precondition: prior-process quit marker must be present"
        )

        await manager.play()

        let visualAfterPlay = await manager.currentVisualState
        let intentAfterPlay = await manager.currentPlaybackIntent
        XCTAssertTrue(intentAfterPlay.isActivePlaybackIntent)
        XCTAssertEqual(
            visualAfterPlay,
            .playing,
            "play() must not no-op solely because lastUpdateTime is the termination sentinel"
        )
        XCTAssertTrue(
            SharedPlayerManager.hasExplicitTerminationSentinel(),
            "play() must not require clearing presentation sentinel to proceed"
        )
    }

    // MARK: - Residual pending-action cold-launch hygiene

    /// Main process starts with the pending mailbox unarmed so early SceneDelegate / Darwin
    /// drains cannot execute leftover App Group commands before factory reset + special tuning.
    ///
    /// **Invariant protected:** While ``pendingActionMailboxAcceptingExecution`` is false,
    /// ``getPendingActionIfFresh(maxAge:)`` drops residual keys and returns `nil`.
    ///
    /// - SeeAlso: ``SharedPlayerManager/discardResidualPendingActionsAndArmMailboxForThisProcess()``,
    ///   ``SharedPlayerManager/getPendingActionIfFresh(maxAge:)``.
    func testUnarmedPendingMailboxDiscardsResidualWithoutReturning() {
        // SAFETY: Test-only flip of process-local nonisolated(unsafe) arm flag.
        unsafe SharedPlayerManager.pendingActionMailboxAcceptingExecution = false
        defer {
            SharedPlayerManager.discardResidualPendingActionsAndArmMailboxForThisProcess()
        }

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        defaults.set("play", forKey: "pendingAction")
        defaults.set(UUID().uuidString, forKey: "pendingActionId")
        defaults.set(Date().timeIntervalSince1970, forKey: "pendingActionTime")

        XCTAssertNil(
            manager.getPendingActionIfFresh(),
            "Unarmed main mailbox must not honor residual pending"
        )
        XCTAssertNil(defaults.object(forKey: "pendingAction"), "Residual pending must be cleared")
        XCTAssertFalse(unsafe SharedPlayerManager.pendingActionMailboxAcceptingExecution)
    }

    /// Factory reset discards residual pending and arms this-process drains **before**
    /// special tuning on user-initiated main open.
    ///
    /// **Invariant protected:** Pre-reboot / pre-quit `pendingAction*` must not surprise-attach
    /// when the user opens main. ``resetToFactoryDefaultsOnLaunch()`` → empty mailbox +
    /// ``pendingActionMailboxAcceptingExecution == true``; only a **new** this-boot schedule
    /// is honor-able after arm.
    ///
    /// - SeeAlso: ``SharedPlayerManager/resetToFactoryDefaultsOnLaunch()``,
    ///   ``SharedPlayerManager/scheduleWidgetAction(action:parameter:)``,
    ///   docs/Widget-Presentation-Dataflow.md (residual post-reboot surprise).
    func testFactoryResetDiscardsResidualPendingAndArmsMailbox() async {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        // SAFETY: Test-only flip of process-local nonisolated(unsafe) arm flag.
        unsafe SharedPlayerManager.pendingActionMailboxAcceptingExecution = false
        defaults.set("play", forKey: "pendingAction")
        defaults.set(UUID().uuidString, forKey: "pendingActionId")
        defaults.set(Date().timeIntervalSince1970 - 5, forKey: "pendingActionTime")

        await manager.resetToFactoryDefaultsOnLaunch()

        XCTAssertTrue(
            unsafe SharedPlayerManager.pendingActionMailboxAcceptingExecution,
            "Factory reset must arm pending drains for this process"
        )
        XCTAssertNil(defaults.object(forKey: "pendingAction"), "Residual pending must be dropped on factory reset")
        XCTAssertNil(manager.getPendingActionIfFresh())

        let actionId = manager.scheduleWidgetAction(action: "play")
        XCTAssertNotNil(actionId)
        let fresh = manager.getPendingActionIfFresh()
        XCTAssertEqual(fresh?.action, "play")
        XCTAssertEqual(fresh?.actionId, actionId)
    }

    /// Pending wall-clock time before the current boot epoch is never executable (reboot residual).
    ///
    /// **Invariant protected:** Even when the mailbox is armed and age < 30 s wall-clock,
    /// ``getPendingActionIfFresh(maxAge:)`` discards entries with `pendingActionTime` before
    /// ``currentSystemBootTimeIntervalSince1970()``.
    ///
    /// - SeeAlso: ``SharedPlayerManager/getPendingActionIfFresh(maxAge:)``,
    ///   ``SharedPlayerManager/currentSystemBootTimeIntervalSince1970()``.
    func testPendingActionWrittenBeforeCurrentBootIsDiscarded() {
        SharedPlayerManager.discardResidualPendingActionsAndArmMailboxForThisProcess()
        SharedPlayerManager.recordCurrentSystemBootTime()

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        let boot = SharedPlayerManager.currentSystemBootTimeIntervalSince1970()
        defaults.set("pause", forKey: "pendingAction")
        defaults.set(UUID().uuidString, forKey: "pendingActionId")
        // Simulate pre-reboot write that still looks "fresh" by wall-clock age alone.
        defaults.set(boot - 60, forKey: "pendingActionTime")

        XCTAssertNil(
            manager.getPendingActionIfFresh(maxAge: 30),
            "Pre-boot pending must not execute after reboot"
        )
        XCTAssertNil(defaults.object(forKey: "pendingAction"))
    }

    /// Termination sentinel residual pending must not execute even when mailbox is armed.
    ///
    /// **Invariant protected:** ``hasExplicitTerminationSentinel()`` →
    /// ``getPendingActionIfFresh(maxAge:)`` clears without returning.
    ///
    /// - SeeAlso: ``SharedPlayerManager/forceStaleLivenessTimestampForTermination()``,
    ///   ``SharedPlayerManager/getPendingActionIfFresh(maxAge:)``.
    func testPendingActionDiscardedWhileTerminationSentinelPresent() {
        SharedPlayerManager.discardResidualPendingActionsAndArmMailboxForThisProcess()
        SharedPlayerManager.recordCurrentSystemBootTime()
        SharedPlayerManager.forceStaleLivenessTimestampForTermination()
        XCTAssertTrue(SharedPlayerManager.hasExplicitTerminationSentinel())

        let actionId = manager.scheduleWidgetAction(action: "play")
        XCTAssertNotNil(actionId)

        XCTAssertNil(
            manager.getPendingActionIfFresh(),
            "Termination sentinel residual must not execute pending play"
        )
        XCTAssertNil(
            UserDefaults(suiteName: "group.radio.lutheran.shared")?.object(forKey: "pendingAction")
        )
    }

    /// Termination hygiene must clear both durable LA mirrors so a cold extension cannot
    /// plan play/pause or stamp language chrome against a Lock Screen surface without a live engine.
    ///
    /// **Invariant protected:** ``forceStaleLivenessTimestampForTermination()`` (called from
    /// ``performSessionTeardownSynchronouslyForTermination()`` and session teardown with
    /// `staleLiveness: true`) drops ``liveActivityToggleVisualState`` and
    /// ``liveActivityCurrentLanguage`` while writing the liveness sentinel. Snapshot keys are
    /// intentionally retained on this path (contrast privacy clear).
    ///
    /// - SeeAlso: ``SharedPlayerManager/forceStaleLivenessTimestampForTermination()``,
    ///   ``SharedPlayerManager/performSessionTeardownSynchronouslyForTermination()``,
    ///   AppDelegate.applicationWillTerminate.
    func testForceStaleLivenessClearsLiveActivityDurableMirrors() {
        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(.playing)
        SharedPlayerManager.persistLiveActivityLanguageMirror("sv")
        XCTAssertEqual(SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(), .playing)
        XCTAssertEqual(SharedPlayerManager.loadLiveActivityLanguageMirror(), "sv")

        SharedPlayerManager.forceStaleLivenessTimestampForTermination()

        XCTAssertNil(
            SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(),
            "Termination must clear liveActivityToggleVisualState"
        )
        XCTAssertNil(
            SharedPlayerManager.loadLiveActivityLanguageMirror(),
            "Termination must clear liveActivityCurrentLanguage"
        )
        XCTAssertTrue(
            SharedPlayerManager.hasExplicitTerminationSentinel(),
            "Precondition of termination path: liveness sentinel must be written"
        )
    }

    /// Full privacy clear must remove both durable LA mirrors (and not leave plan signals
    /// after the user explicitly clears local playback state).
    ///
    /// **Invariant protected:** ``clearAllLocalState()`` → ``removeAllLocalPlaybackKeys()``
    /// clears ``liveActivityToggleVisualState`` and ``liveActivityCurrentLanguage``. Security
    /// DNS cache on the standard suite is never touched.
    ///
    /// - SeeAlso: ``SharedPlayerManager/clearAllLocalState()``,
    ///   ``SharedPlayerManager/removeAllLocalPlaybackKeys()``.
    func testClearAllLocalStateClearsLiveActivityDurableMirrors() async {
        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(.userPaused)
        SharedPlayerManager.persistLiveActivityLanguageMirror("de")
        XCTAssertEqual(SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(), .userPaused)
        XCTAssertEqual(SharedPlayerManager.loadLiveActivityLanguageMirror(), "de")

        let securityKey = "lastSecurityValidation"
        let securityMarker = "la-mirror-privacy-clear-\(UUID().uuidString)"
        UserDefaults.standard.set(securityMarker, forKey: securityKey)
        defer { UserDefaults.standard.removeObject(forKey: securityKey) }

        await SharedPlayerManager.clearAllLocalState()

        XCTAssertNil(
            SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(),
            "Privacy clear must clear liveActivityToggleVisualState"
        )
        XCTAssertNil(
            SharedPlayerManager.loadLiveActivityLanguageMirror(),
            "Privacy clear must clear liveActivityCurrentLanguage"
        )
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: securityKey),
            securityMarker,
            "Privacy clear must never touch lastSecurityValidation"
        )
    }

    /// Privacy-clear write suppression must stay closed through a teardown-style
    /// WidgetCenter presence detect. Home paints factory from **absent** keys; leftover
    /// Home Screen widgets must not restamp ``homeWidgetLiveChrome`` until SceneDelegate
    /// lifts the hold on foreground.
    ///
    /// **Invariant protected:** ``clearAllLocalState()`` arms
    /// ``WidgetRefreshManager/holdPrivacyClearWriteSuppressionClosedUntilForeground()``.
    /// ``applyDetectedWidgetPresence(true)`` (the ``performRefresh`` / opportunistic
    /// ``refreshHasActiveWidgets`` seam — no WidgetCenter IPC) must not reopen the gate
    /// or schedule ``restampHomeWidgetLiveChromeAfterPrivacyGateOpenIfNeeded()``.
    /// ``liftPrivacyClearWriteSuppressionHoldForForegroundDetect()`` then allows the
    /// next detect to open the gate.
    ///
    /// - SeeAlso: ``SharedPlayerManager/clearAllLocalState()``,
    ///   ``WidgetRefreshManager/applyDetectedWidgetPresence(_:)``,
    ///   ``WidgetRefreshManager/liftPrivacyClearWriteSuppressionHoldForForegroundDetect()``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§7).
    func testPrivacyClearHoldsWriteSuppressionClosedThroughTeardownWidgetPresenceDetect() async {
        await MainActor.run {
            WidgetRefreshManager.liftPrivacyClearWriteSuppressionHoldForForegroundDetect()
            WidgetRefreshManager.setHasActiveLutheranWidgets(true)
        }
        SharedPlayerManager.stampHomeWidgetLiveChromeFromSession(
            visualState: .playing,
            language: "sv",
            hasError: false,
            reason: "prePrivacyClearSeed"
        )
        XCTAssertEqual(
            SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.currentLanguage,
            "sv",
            "Precondition: live chrome must be present so a false restamp is observable"
        )

        await SharedPlayerManager.clearAllLocalState()

        XCTAssertFalse(
            WidgetRefreshManager.hasActiveLutheranWidgets,
            "Privacy clear must force the write gate closed"
        )
        XCTAssertTrue(
            WidgetRefreshManager.isPrivacyClearWriteSuppressionHeldClosed,
            "Privacy clear must hold WidgetCenter re-detect closed until foreground"
        )
        XCTAssertNil(
            SharedPlayerManager.loadHomeWidgetLiveChromeMirror(),
            "Privacy clear must remove homeWidgetLiveChrome"
        )

        await MainActor.run {
            WidgetRefreshManager.applyDetectedWidgetPresence(true)
        }
        // Allow a mistaken false→true restamp Task to land if the hold failed.
        for _ in 0..<10 {
            if SharedPlayerManager.loadHomeWidgetLiveChromeMirror() != nil { break }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertFalse(
            WidgetRefreshManager.hasActiveLutheranWidgets,
            "Teardown WidgetCenter true-detect must not reopen the gate while hold-closed"
        )
        XCTAssertNil(
            SharedPlayerManager.loadHomeWidgetLiveChromeMirror(),
            "Hold-closed detect must not restamp live chrome (Home paints factory from absent keys)"
        )

        await MainActor.run {
            WidgetRefreshManager.liftPrivacyClearWriteSuppressionHoldForForegroundDetect()
            WidgetRefreshManager.applyDetectedWidgetPresence(true)
        }
        XCTAssertFalse(
            WidgetRefreshManager.isPrivacyClearWriteSuppressionHeldClosed,
            "Foreground lift must release the hold"
        )
        XCTAssertTrue(
            WidgetRefreshManager.hasActiveLutheranWidgets,
            "After foreground lift, WidgetCenter true-detect may reopen the write gate"
        )
    }

    /// Closing the home-widget privacy gate alone must **not** clear durable LA mirrors.
    ///
    /// **Invariant protected:** Mirrors are intentionally **not** gated by `hasActiveWidgets`.
    /// LA-only sessions (no home widgets) still need durable plan + language signals until
    /// LA end, termination, factory reset, or full privacy clear. Residual liveness/instant
    /// keys are cleared; LA mirrors are not.
    ///
    /// - SeeAlso: ``SharedPlayerManager/clearHomeWidgetLivenessAndInstantFeedbackResiduals()``,
    ///   ``WidgetRefreshManager/setHasActiveLutheranWidgets(_:)``,
    ///   App Group SSOT table (`liveActivityToggleVisualState` / `liveActivityCurrentLanguage`).
    func testClosingHomeWidgetPrivacyGateDoesNotClearLiveActivityDurableMirrors() async {
        await MainActor.run {
            WidgetRefreshManager.setHasActiveLutheranWidgets(true)
        }
        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(.playing)
        SharedPlayerManager.persistLiveActivityLanguageMirror("fi")
        SharedPlayerManager.bumpWidgetLivenessTimestamp(policy: .immediate)
        SharedPlayerManager.writeInstantFeedback(language: "fi")

        await MainActor.run {
            WidgetRefreshManager.setHasActiveLutheranWidgets(false)
        }

        XCTAssertEqual(
            SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(),
            .playing,
            "Home-widget gate close must not clear liveActivityToggleVisualState"
        )
        XCTAssertEqual(
            SharedPlayerManager.loadLiveActivityLanguageMirror(),
            "fi",
            "Home-widget gate close must not clear liveActivityCurrentLanguage"
        )

        // Residual home-widget signals still drop (orthogonal contract).
        let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared")
        XCTAssertNil(defaults?.object(forKey: "lastUpdateTime"))
        XCTAssertNil(defaults?.object(forKey: "isInstantFeedback"))

        // Leave a clean App Group for sibling suites.
        SharedPlayerManager.clearLiveActivityToggleVisualStateMirror()
        SharedPlayerManager.clearLiveActivityLanguageMirror()
    }
}
