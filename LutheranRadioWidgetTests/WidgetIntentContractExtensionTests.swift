//
//  WidgetIntentContractExtensionTests.swift
//  LutheranRadioWidgetTests
//
//  Created by Jari Lammi on 15.7.2026.
//
//  Extension-profile contract tests for optimistic snapshots, pending actions,
//  and AppIntent perform-path SSOT (``WidgetIntentExecution/perform*``).
//
//  **Compile profile:** No `LUTHERAN_MAIN_APP`. ``SharedPlayerManager/isWidgetProcess()``
//  returns `true` by construction — the natural widget extension process model.
//  Never calls real ActivityKit IPC. WidgetCenter reloads may run behind the
//  privacy gate; tests set ``WidgetRefreshManager/setHasActiveLutheranWidgets(_:)``.
//
//  - SeeAlso: ``WidgetIntentExecution``, ``WidgetIntentCoordinators``,
//    docs/Widget-Functionality-Roadmap.md, CODING_AGENT.md (fast test patterns).
//

import XCTest
import WidgetSurface

/// Extension-profile contracts for optimistic intent + perform-path SSOT.
final class WidgetIntentContractExtensionTests: XCTestCase {

    private let manager = SharedPlayerManager.shared

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            WidgetRefreshManager.setHasActiveLutheranWidgets(true)
        }
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        // Extension profile: isWidgetProcess() is always true — no simulate flag needed.
        XCTAssertTrue(
            SharedPlayerManager.isWidgetProcess(),
            "LutheranRadioWidgetTests must compile without LUTHERAN_MAIN_APP"
        )
        XCTAssertTrue(manager.isRunningInWidget())
    }

    override func tearDown() async throws {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        try await super.tearDown()
    }

    // MARK: - Process profile

    /// Confirms the extension compile profile: widget process, emit suppressed by default.
    func testExtensionCompileProfileIsWidgetProcess() async {
        XCTAssertTrue(SharedPlayerManager.isWidgetProcess())
        XCTAssertTrue(manager.isRunningInWidget())

        let liveStream = await manager.events
        let collectionTask = Task<[PlayerEvent], Never> {
            var collected: [PlayerEvent] = []
            for await event in liveStream {
                if Task.isCancelled { break }
                collected.append(event)
                if collected.count >= 1 { break }
            }
            return collected
        }

        await Task.yield()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))

        await manager.emit(.visualStateDidChange(.playing))

        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
        collectionTask.cancel()
        try? await Task.sleep(for: .milliseconds(150))
        let streamEvents = await collectionTask.value

        XCTAssertTrue(streamEvents.isEmpty, "Widget process must suppress AsyncStream yields")
    }

    // MARK: - Pending action / optimistic persist

    func testRapidScheduleWidgetActionReplacesPendingWithLatest() {
        let firstId = manager.scheduleWidgetAction(action: "play")
        let secondId = manager.scheduleWidgetAction(action: "pause")

        XCTAssertNotNil(firstId)
        XCTAssertNotNil(secondId)
        XCTAssertNotEqual(firstId, secondId)

        guard let pending = manager.getPendingAction() else {
            XCTFail("Expected pending action after rapid schedule")
            return
        }
        XCTAssertEqual(pending.action, "pause")
        XCTAssertEqual(pending.actionId, secondId)
    }

    func testPersistOptimisticWidgetSnapshotWritesWithoutPlayerEventYield() async {
        let liveStream = await manager.events
        let collectionTask = Task<[PlayerEvent], Never> {
            var collected: [PlayerEvent] = []
            for await event in liveStream {
                if Task.isCancelled { break }
                collected.append(event)
                if collected.count >= 1 { break }
            }
            return collected
        }

        await Task.yield()
        try? await Task.sleep(for: .milliseconds(80))

        manager.persistOptimisticWidgetSnapshot(.playing, language: "de")
        await manager.emit(.visualStateDidChange(.playing))

        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
        collectionTask.cancel()
        try? await Task.sleep(for: .milliseconds(150))
        let streamEvents = await collectionTask.value

        XCTAssertTrue(streamEvents.isEmpty)
        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(snapshot?.visualState, .playing)
        XCTAssertEqual(snapshot?.currentLanguage, "de")
    }

    func testSignalWidgetPendingActionPlayWritesOptimisticSnapshotAndPending() {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: "fi")

        let actionId = manager.signalWidgetPendingAction(
            visualState: .playing,
            action: "play",
            language: "fi"
        )

        XCTAssertNotNil(actionId)
        guard let pending = manager.getPendingActionIfFresh() else {
            XCTFail("Expected fresh play pending")
            return
        }
        XCTAssertEqual(pending.action, "play")
        XCTAssertEqual(SharedPlayerManager.loadPersistedWidgetState()?.visualState, .playing)
    }

    func testSignalWidgetPendingActionPauseWritesOptimisticSnapshotAndPending() {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: "de")

        let actionId = manager.signalWidgetPendingAction(
            visualState: .userPaused,
            action: "pause",
            language: "de"
        )

        XCTAssertNotNil(actionId)
        guard let pending = manager.getPendingActionIfFresh() else {
            XCTFail("Expected fresh pause pending")
            return
        }
        XCTAssertEqual(pending.action, "pause")
        XCTAssertEqual(SharedPlayerManager.loadPersistedWidgetState()?.visualState, .userPaused)
    }

    // MARK: - AppIntent perform-path SSOT (extension profile)

    // Note on pending-action assertions under TEST_HOST:
    // `signalWidgetPendingAction` posts a Darwin notify. When this suite runs inside the
    // Lutheran Radio app host, the main-app observer may drain App Group pending keys
    // before the next assertion. The reliable extension-profile contract is the
    // in-process optimistic snapshot written by the same module that compiled without
    // `LUTHERAN_MAIN_APP` (this test target). Pending is covered by the synchronous
    // signal tests above (and main-app host drain tests in Lutheran RadioTests).

    /// ``performHomeWidgetToggle()`` mirrors ``WidgetToggleRadioIntent/perform()``.
    func testPerformHomeWidgetToggleFromPausedPlansPlay() async {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: "fi")

        await WidgetIntentExecution.performHomeWidgetToggle()

        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        // Soft-resume honesty: hold sticky pause until main setPlaying (not invent .playing).
        XCTAssertEqual(snapshot?.visualState, .userPaused, "Optimistic home play holds sticky pause chrome")
        XCTAssertEqual(snapshot?.currentLanguage, "fi")
    }

    /// ``performHomeWidgetToggle()`` from playing plans pause.
    func testPerformHomeWidgetToggleFromPlayingPlansPause() async {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: "en")

        await WidgetIntentExecution.performHomeWidgetToggle()

        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(snapshot?.visualState, .userPaused, "Optimistic pause snapshot after home toggle")
        XCTAssertEqual(snapshot?.currentLanguage, "en")
    }

    /// Optimistic home pause advances snapshot, live chrome, paint epoch, and Provider resolve together.
    ///
    /// **Invariant protected:** After ``performHomeWidgetToggle`` from ``.playing``, interactive
    /// LIVE heal inputs must all report ``.userPaused`` and the paint epoch must strictly increase
    /// so ``LutheranRadioWidgetEntryView`` re-resolves residual Toistaa without restoring the
    /// hygiene hop. A second identical pause stamp (identity skip) must still bump the epoch.
    ///
    /// - SeeAlso: ``WidgetIntentExecution/executeOptimisticToggle(plan:language:)``,
    ///   ``SharedPlayerManager/bumpHomeWidgetInteractivePaintEpoch(reason:)``,
    ///   ``WidgetProviderSnapshotResolver/resolveFromSnapshot()``.
    func testPerformHomeWidgetTogglePauseAdvancesPaintEpochAndResolveHonesty() async {
        SharedPlayerManager.clearHomeWidgetLiveChromeMirror()
        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: "fi")
        let epochBefore = SharedPlayerManager.loadHomeWidgetInteractivePaintEpoch()

        await WidgetIntentExecution.performHomeWidgetToggle()

        XCTAssertEqual(SharedPlayerManager.loadPersistedWidgetState()?.visualState, .userPaused)
        XCTAssertEqual(
            SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.visualState,
            .userPaused,
            "Live chrome must hold pause for cross-process interactive heal"
        )
        let epochAfterPause = SharedPlayerManager.loadHomeWidgetInteractivePaintEpoch()
        XCTAssertGreaterThan(
            epochAfterPause,
            epochBefore,
            "Optimistic pause must bump interactive paint epoch for LIVE body re-eval"
        )
        XCTAssertEqual(
            WidgetProviderSnapshotResolver.resolveFromSnapshot().visualState,
            .userPaused,
            "Provider resolve SSOT must match optimistic pause"
        )
        let signatureAfterPause = SharedPlayerManager.loadHomeWidgetInteractivePaintSignature()
        XCTAssertEqual(
            signatureAfterPause,
            SharedPlayerManager.makeHomeWidgetInteractivePaintSignature(
                visualState: .userPaused,
                language: "fi",
                epoch: epochAfterPause
            ),
            "Optimistic pause must publish stable paint signature for LIVE @AppStorage / entry identity"
        )

        // Identity-skip path: chrome already userPaused — toggle play then pause again is heavier;
        // instead re-run executeOptimisticToggle with an explicit pause plan to force the always-bump.
        let plan = WidgetToggleActionPlan(action: .pause, targetVisualState: .userPaused)
        await WidgetIntentExecution.executeOptimisticToggle(plan: plan, language: "fi")
        XCTAssertGreaterThan(
            SharedPlayerManager.loadHomeWidgetInteractivePaintEpoch(),
            epochAfterPause,
            "Re-toggle pause must bump epoch even when live-chrome identity skip applies"
        )
        XCTAssertEqual(
            WidgetProviderSnapshotResolver.resolveFromSnapshot().visualState,
            .userPaused
        )
        XCTAssertNotEqual(
            SharedPlayerManager.loadHomeWidgetInteractivePaintSignature(),
            signatureAfterPause,
            "Re-toggle pause must flip paint signature even when chrome identity skips"
        )
    }

    /// Optimistic home play advances paint epoch while holding sticky pause (soft-resume honesty).
    ///
    /// - SeeAlso: ``WidgetIntentExecution/performHomeWidgetToggle()``,
    ///   ``PlayerVisualState/optimisticHomeWidgetVisualAfterPlayPlan``,
    ///   ``SharedPlayerManager/bumpHomeWidgetInteractivePaintEpoch(reason:)``.
    func testPerformHomeWidgetTogglePlayAdvancesPaintEpochAndResolveHonesty() async {
        SharedPlayerManager.clearHomeWidgetLiveChromeMirror()
        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: "et")
        let epochBefore = SharedPlayerManager.loadHomeWidgetInteractivePaintEpoch()

        await WidgetIntentExecution.performHomeWidgetToggle()

        XCTAssertEqual(SharedPlayerManager.loadPersistedWidgetState()?.visualState, .userPaused)
        XCTAssertEqual(SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.visualState, .userPaused)
        XCTAssertGreaterThan(
            SharedPlayerManager.loadHomeWidgetInteractivePaintEpoch(),
            epochBefore,
            "Optimistic play must bump interactive paint epoch"
        )
        XCTAssertEqual(
            WidgetProviderSnapshotResolver.resolveFromSnapshot().visualState,
            .userPaused,
            "Home play must not invent .playing before engine setPlaying"
        )
    }

    /// Direction-explicit pause intent always stamps ``.userPaused`` (residual-glyph safe).
    func testPerformHomeWidgetPauseAlwaysStampsUserPaused() async {
        SharedPlayerManager.clearHomeWidgetLiveChromeMirror()
        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: "fi")

        await WidgetIntentExecution.performHomeWidgetPause()

        XCTAssertEqual(SharedPlayerManager.loadPersistedWidgetState()?.visualState, .userPaused)
        XCTAssertEqual(SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.visualState, .userPaused)
        XCTAssertEqual(
            WidgetProviderSnapshotResolver.resolveFromSnapshot().visualState,
            .userPaused
        )
    }

    /// Direction-explicit play from pause holds sticky chrome; from connecting stays Connecting.
    func testPerformHomeWidgetPlayHonestyMatrix() async {
        SharedPlayerManager.clearHomeWidgetLiveChromeMirror()
        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: "sv")
        await WidgetIntentExecution.performHomeWidgetPlay()
        XCTAssertEqual(
            SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.visualState,
            .userPaused,
            "Soft-resume play must hold Tauko chrome until setPlaying"
        )

        SharedPlayerManager.persistWidgetSnapshot(visualState: .prePlay, language: "sv")
        await WidgetIntentExecution.performHomeWidgetPlay()
        XCTAssertEqual(
            SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.visualState,
            .prePlay,
            "Connect play must stay Connecting (play glyph), not invent pause glyph"
        )
    }

    /// Empty session + residual live chrome `.playing` plans pause (not factory `.prePlay` play).
    ///
    /// **Invariant protected:** After dirty process exit the extension session is empty (OI-1)
    /// while privacy-gated ``homeWidgetLiveChrome`` may still paint the last visual. Planning
    /// must use the same resolve path as Providers, not bare ``loadPersistedVisualStateDirect()``.
    ///
    /// - SeeAlso: ``WidgetIntentExecution/performHomeWidgetToggle()``,
    ///   ``resolveHomeWidgetChromeFields(sessionVisual:sessionLanguage:sessionHasError:sessionUpdatedAt:liveChrome:)``,
    ///   ``SharedPlayerManager/loadHomeWidgetLiveChromeMirror()``.
    func testPerformHomeWidgetToggleEmptySessionUsesResidualLiveChromePlayingAsPause() async {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.recordCurrentSystemBootTime()
        // Residual interactive window so main is "recently active" without a session snapshot.
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        defaults.set(Date().timeIntervalSince1970 - 5, forKey: "lastUpdateTime")
        XCTAssertTrue(SharedPlayerManager.isMainAppProcessRecentlyActive())
        XCTAssertNil(SharedPlayerManager.loadPersistedWidgetState())

        SharedPlayerManager.persistHomeWidgetLiveChromeMirror(
            HomeWidgetLiveChrome(
                visualState: .playing,
                currentLanguage: "fi",
                hasError: false,
                updatedAt: Date().timeIntervalSince1970,
                stampReason: "testResidual"
            )
        )
        XCTAssertEqual(SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.visualState, .playing)
        XCTAssertEqual(
            SharedPlayerManager.loadPersistedVisualStateDirect(),
            .prePlay,
            "Empty session still reports factory .prePlay via loadPersistedVisualStateDirect"
        )

        await WidgetIntentExecution.performHomeWidgetToggle()

        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(
            snapshot?.visualState,
            .userPaused,
            "Residual live chrome .playing must plan pause, not invent play from empty-session .prePlay"
        )
        XCTAssertEqual(snapshot?.currentLanguage, "fi")
    }

    /// Reboot distrust + residual live chrome alone must not invent optimistic play.
    ///
    /// **Invariant protected:** ``shouldDistrustDurableMirrorPlayPlanning()`` + residual
    /// ``homeWidgetLiveChrome`` / empty factory refuse pending play after dirty exit / reboot.
    ///
    /// - SeeAlso: ``WidgetIntentExecution/performHomeWidgetToggle()``,
    ///   ``SharedPlayerManager/shouldDistrustDurableMirrorPlayPlanning()``.
    func testPerformHomeWidgetToggleRefusesPlayAfterSimulatedRebootResidualChrome() async {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.recordCurrentSystemBootTime()

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        // Prior boot epoch left across hard power-off.
        defaults.set(1.0, forKey: SharedPlayerManager.recordedSystemBootTimeAppGroupKey)
        XCTAssertTrue(SharedPlayerManager.hasDeviceRebootedSinceLastRecordedBoot())
        XCTAssertTrue(SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning())
        XCTAssertFalse(SharedPlayerManager.isMainAppProcessRecentlyActive())

        SharedPlayerManager.persistHomeWidgetLiveChromeMirror(
            HomeWidgetLiveChrome(
                visualState: .userPaused,
                currentLanguage: "sv",
                hasError: false,
                updatedAt: Date().timeIntervalSince1970,
                stampReason: "testResidual"
            )
        )

        await WidgetIntentExecution.performHomeWidgetToggle()

        XCTAssertNil(
            SharedPlayerManager.loadPersistedWidgetState(),
            "Refuse must not write an optimistic session snapshot after reboot residual-chrome play"
        )
        // Residual chrome left unchanged (no optimistic flip to .playing).
        XCTAssertEqual(
            SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.visualState,
            .userPaused
        )
    }

    /// Residual ``.playing`` blob under reboot distrust must not plan play *or* invent an
    /// optimistic pause session — Provider resolve ignores the mirror first, then planning
    /// sees factory ``.prePlay`` and refuses.
    ///
    /// **Invariant protected:** Production wires ``distrustLiveChrome`` and
    /// ``distrustDurableMirrorPlay`` from the same
    /// ``shouldDistrustDurableMirrorPlayPlanning()`` signal. Pure planner pause-from-residual
    /// ``.playing`` remains defense-in-depth when resolution source is still ``.liveChrome``;
    /// after reboot the resolve path drops the mirror so perform lands refuse.
    ///
    /// - SeeAlso: ``WidgetIntentExecution/performHomeWidgetToggle()``,
    ///   ``WidgetProviderSnapshotResolver/resolveFromSnapshot()``,
    ///   ``resolveHomeWidgetChromeFields(sessionVisual:sessionLanguage:sessionHasError:sessionUpdatedAt:liveChrome:distrustLiveChrome:)``.
    func testPerformHomeWidgetToggleRefusesAfterRebootDespiteResidualPlayingBlob() async {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.recordCurrentSystemBootTime()

        // Seed residual while boot identity is still trusted (pre-power-off stamp).
        SharedPlayerManager.persistHomeWidgetLiveChromeMirror(
            HomeWidgetLiveChrome(
                visualState: .playing,
                currentLanguage: "fi",
                hasError: false,
                updatedAt: Date().timeIntervalSince1970,
                stampReason: "preRebootPlaying"
            )
        )
        XCTAssertEqual(SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.visualState, .playing)

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        defaults.set(1.0, forKey: SharedPlayerManager.recordedSystemBootTimeAppGroupKey)
        XCTAssertTrue(SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning())
        XCTAssertFalse(SharedPlayerManager.isMainAppProcessRecentlyActive())

        await WidgetIntentExecution.performHomeWidgetToggle()

        XCTAssertNil(
            SharedPlayerManager.loadPersistedWidgetState(),
            "Reboot distrust + ignored residual .playing must refuse — no optimistic session"
        )
        // Blob may remain on disk; paint/plan must not resurrect it.
        XCTAssertEqual(
            SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.visualState,
            .playing,
            "Refuse path must not rewrite residual blob"
        )
    }

    /// Termination sentinel alone (clean observed quit) must refuse empty-session play.
    ///
    /// **Invariant protected:** ``hasExplicitTerminationSentinel()`` →
    /// ``shouldDistrustDurableMirrorPlayPlanning()`` → home toggle refuse without reboot.
    ///
    /// - SeeAlso: ``SharedPlayerManager/forceStaleLivenessTimestampForTermination()``,
    ///   ``WidgetIntentExecution/performHomeWidgetToggle()``.
    func testPerformHomeWidgetToggleRefusesPlayAfterTerminationSentinel() async {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.recordCurrentSystemBootTime()
        SharedPlayerManager.forceStaleLivenessTimestampForTermination()

        XCTAssertTrue(SharedPlayerManager.hasExplicitTerminationSentinel())
        XCTAssertTrue(SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning())
        XCTAssertFalse(SharedPlayerManager.isMainAppProcessRecentlyActive())
        XCTAssertNil(SharedPlayerManager.loadPersistedWidgetState())

        await WidgetIntentExecution.performHomeWidgetToggle()

        XCTAssertNil(
            SharedPlayerManager.loadPersistedWidgetState(),
            "Termination sentinel must refuse factory .prePlay play invention"
        )
    }

    /// Main not recently active without reboot/sentinel: residual non-playing chrome must not invent play.
    ///
    /// **Invariant protected:** ``mainProcessRecentlyActive == false`` alone refuses residual
    /// / factory play even when boot identity is trusted (stale 60 s window expired / missing).
    ///
    /// - SeeAlso: ``SharedPlayerManager/isMainAppProcessRecentlyActive()``,
    ///   ``WidgetIntentExecution/performHomeWidgetToggle()``.
    func testPerformHomeWidgetToggleRefusesPlayWhenMainNotRecentlyActiveTrustedBoot() async {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.recordCurrentSystemBootTime()

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        // Outside the 60 s interactive window; no termination sentinel.
        defaults.set(Date().timeIntervalSince1970 - 120, forKey: "lastUpdateTime")
        XCTAssertFalse(SharedPlayerManager.isMainAppProcessRecentlyActive())
        XCTAssertFalse(SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning())

        SharedPlayerManager.persistHomeWidgetLiveChromeMirror(
            HomeWidgetLiveChrome(
                visualState: .userPaused,
                currentLanguage: "de",
                hasError: false,
                updatedAt: Date().timeIntervalSince1970 - 120,
                stampReason: "staleResidual"
            )
        )

        await WidgetIntentExecution.performHomeWidgetToggle()

        XCTAssertNil(
            SharedPlayerManager.loadPersistedWidgetState(),
            "Main not recently active + residual pause must refuse play (no reboot required)"
        )
        XCTAssertEqual(
            SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.visualState,
            .userPaused
        )
    }

    /// Main not recently active without reboot: residual ``.playing`` still plans pause (glyph honesty).
    ///
    /// Unlike reboot distrust, trusted-boot resolve still paints residual live chrome, so
    /// ``.playing`` → pause remains available while main is not recently active.
    ///
    /// - SeeAlso: ``WidgetIntentExecution/performHomeWidgetToggle()``,
    ///   ``resolveHomeWidgetChromeFields(sessionVisual:sessionLanguage:sessionHasError:sessionUpdatedAt:liveChrome:distrustLiveChrome:)``.
    func testPerformHomeWidgetTogglePausesResidualPlayingWhenMainNotRecentlyActiveTrustedBoot() async {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.recordCurrentSystemBootTime()

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        defaults.set(Date().timeIntervalSince1970 - 120, forKey: "lastUpdateTime")
        XCTAssertFalse(SharedPlayerManager.isMainAppProcessRecentlyActive())
        XCTAssertFalse(SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning())

        SharedPlayerManager.persistHomeWidgetLiveChromeMirror(
            HomeWidgetLiveChrome(
                visualState: .playing,
                currentLanguage: "nb",
                hasError: false,
                updatedAt: Date().timeIntervalSince1970 - 90,
                stampReason: "stalePlayingResidual"
            )
        )

        await WidgetIntentExecution.performHomeWidgetToggle()

        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(
            snapshot?.visualState,
            .userPaused,
            "Trusted-boot residual .playing must still plan pause for glyph honesty"
        )
        XCTAssertEqual(snapshot?.currentLanguage, "nb")
    }

    // MARK: - Home live chrome optimistic stamps (extension profile)

    /// Protects design §5.3: home toggle → pause stamps privacy-gated ``homeWidgetLiveChrome``
    /// with ``.userPaused`` + current language (same pure plan as session optimistic snapshot).
    ///
    /// - SeeAlso: ``WidgetIntentExecution/performHomeWidgetToggle()``,
    ///   ``SharedPlayerManager/loadHomeWidgetLiveChromeMirror()``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§5.3).
    func testPerformHomeWidgetTogglePauseStampsLiveChromeUserPaused() async {
        SharedPlayerManager.clearHomeWidgetLiveChromeMirror()
        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: "en")

        await WidgetIntentExecution.performHomeWidgetToggle()

        let chrome = SharedPlayerManager.loadHomeWidgetLiveChromeMirror()
        XCTAssertEqual(chrome?.visualState, .userPaused, "Optimistic pause must stamp live chrome .userPaused")
        XCTAssertEqual(chrome?.currentLanguage, "en")
        XCTAssertEqual(chrome?.hasError, false)
    }

    /// Protects design §5.3: stream switch while playing stamps ``.prePlay`` + destination language
    /// (same honesty as ``optimisticLiveActivityVisualForStreamSwitch``).
    ///
    /// - SeeAlso: ``WidgetIntentExecution/performHomeWidgetStreamSwitch(languageCode:)``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§5.3, §9).
    func testPerformHomeWidgetStreamSwitchFromPlayingStampsLiveChromePrePlayPlusDestLang() async {
        let streams = manager.availableStreams
        guard streams.count >= 2 else {
            XCTFail("Stub stream list must include ≥2 languages")
            return
        }
        let source = streams[0]
        let target = streams[1]

        SharedPlayerManager.clearHomeWidgetLiveChromeMirror()
        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: source.languageCode)

        await WidgetIntentExecution.performHomeWidgetStreamSwitch(languageCode: target.languageCode)

        let chrome = SharedPlayerManager.loadHomeWidgetLiveChromeMirror()
        XCTAssertEqual(
            chrome?.visualState,
            .prePlay,
            "Switch while playing must stamp Connecting (.prePlay), never invent destination .playing"
        )
        XCTAssertEqual(chrome?.currentLanguage, target.languageCode)
        XCTAssertEqual(chrome?.hasError, false)
    }

    /// Protects design §5.3: stream switch while paused stamps ``.userPaused`` + destination language.
    func testPerformHomeWidgetStreamSwitchFromPausedStampsLiveChromeUserPausedPlusDestLang() async {
        let streams = manager.availableStreams
        guard streams.count >= 2 else {
            XCTFail("Stub stream list must include ≥2 languages")
            return
        }
        let source = streams[0]
        let target = streams[1]

        SharedPlayerManager.clearHomeWidgetLiveChromeMirror()
        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: source.languageCode)

        await WidgetIntentExecution.performHomeWidgetStreamSwitch(languageCode: target.languageCode)

        let chrome = SharedPlayerManager.loadHomeWidgetLiveChromeMirror()
        XCTAssertEqual(chrome?.visualState, .userPaused)
        XCTAssertEqual(chrome?.currentLanguage, target.languageCode)
    }

    /// Protects connect / security recovery honesty: pure play plan from ``.securityLocked`` uses
    /// ``optimisticVisualAfterPlayPlan`` → ``.prePlay`` (Connecting), never invents ``.playing``.
    ///
    /// - SeeAlso: ``PlayerVisualState/optimisticVisualAfterPlayPlan``,
    ///   ``WidgetIntentCoordinators/planHomeWidgetToggle(from:)``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§5.3 soft-resume / connect).
    func testHomeToggleFromSecurityLockedStampsLiveChromeConnectingNotPlaying() async {
        SharedPlayerManager.clearHomeWidgetLiveChromeMirror()
        SharedPlayerManager.persistWidgetSnapshot(visualState: .securityLocked, language: "fi")

        let plan = WidgetIntentCoordinators.planHomeWidgetToggle(from: .securityLocked)
        XCTAssertEqual(plan.action, .play)
        XCTAssertEqual(
            plan.targetVisualState,
            .prePlay,
            "Security recovery play plan must be Connecting, not invent .playing"
        )

        await WidgetIntentExecution.performHomeWidgetToggle()

        let chrome = SharedPlayerManager.loadHomeWidgetLiveChromeMirror()
        XCTAssertEqual(
            chrome?.visualState,
            .prePlay,
            "Optimistic connect plan must not stamp .playing when plan is Connecting"
        )
        XCTAssertEqual(chrome?.currentLanguage, "fi")
        XCTAssertNotEqual(chrome?.visualState, .playing)
    }

    /// Protects identity skip on repeated identical optimistic toggle stamps (no App Group spam).
    ///
    /// Sticky pause still wakes paint epoch/signature; JSON ``updatedAt`` stays stable so we do
    /// not thrash suite writes (force-rewrite thrash regression).
    func testOptimisticToggleLiveChromeIdentitySkipLeavesUpdatedAtUnchanged() async {
        SharedPlayerManager.clearHomeWidgetLiveChromeMirror()
        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: "de")
        await WidgetIntentExecution.performHomeWidgetToggle()

        let first = SharedPlayerManager.loadHomeWidgetLiveChromeMirror()
        XCTAssertEqual(first?.visualState, .userPaused)
        let firstUpdatedAt = first?.updatedAt ?? 0
        let epochAfterPause = SharedPlayerManager.loadHomeWidgetInteractivePaintEpoch()

        // Re-stamp identical pause chrome via the same optimistic writer.
        manager.persistOptimisticWidgetSnapshot(.userPaused, language: "de")
        let second = SharedPlayerManager.loadHomeWidgetLiveChromeMirror()
        XCTAssertEqual(second?.updatedAt, firstUpdatedAt, "Identity skip must not refresh updatedAt")
        XCTAssertEqual(second?.visualState, .userPaused)
        XCTAssertGreaterThan(
            SharedPlayerManager.loadHomeWidgetInteractivePaintEpoch(),
            epochAfterPause,
            "Sticky pause identity skip must still bump paint epoch"
        )
    }

    /// ``performControlWidgetToggle(isPlayingRequested:)`` mirrors Control ``ToggleRadioIntent``.
    ///
    /// In-session trusted-boot matrix: distrust is false and main is recently active, so
    /// play then pause still execute.
    ///
    /// - SeeAlso: ``WidgetIntentExecution/performControlWidgetToggle(isPlayingRequested:)``,
    ///   ``SharedPlayerManager/shouldDistrustDurableMirrorPlayPlanning()``,
    ///   ``SharedPlayerManager/isMainAppProcessRecentlyActive()``.
    func testPerformControlWidgetTogglePlayAndPause() async {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.recordCurrentSystemBootTime()
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        defaults.set(Date().timeIntervalSince1970 - 5, forKey: "lastUpdateTime")
        XCTAssertFalse(SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning())
        XCTAssertTrue(SharedPlayerManager.isMainAppProcessRecentlyActive())

        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: "sv")

        await WidgetIntentExecution.performControlWidgetToggle(isPlayingRequested: true)
        XCTAssertEqual(
            SharedPlayerManager.loadPersistedWidgetState()?.visualState,
            .playing,
            "Trusted boot + recently active + Control true → optimistic .playing"
        )

        await WidgetIntentExecution.performControlWidgetToggle(isPlayingRequested: false)
        XCTAssertEqual(
            SharedPlayerManager.loadPersistedWidgetState()?.visualState,
            .userPaused,
            "Control toggle false → optimistic .userPaused"
        )
    }

    /// Reboot distrust + Control `true` must not invent optimistic play.
    ///
    /// **Invariant protected:** ``shouldDistrustDurableMirrorPlayPlanning()`` (boot-identity
    /// mismatch) refuses Control play — no session snapshot, no pending play, residual
    /// live chrome unchanged. Same honesty flags as ``performHomeWidgetToggle()``.
    ///
    /// - SeeAlso: ``WidgetIntentExecution/performControlWidgetToggle(isPlayingRequested:)``,
    ///   ``WidgetIntentExecution/performHomeWidgetToggle()``,
    ///   ``SharedPlayerManager/shouldDistrustDurableMirrorPlayPlanning()``.
    func testPerformControlWidgetToggleRefusesPlayAfterSimulatedRebootResidualChrome() async {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.recordCurrentSystemBootTime()

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        defaults.set(1.0, forKey: SharedPlayerManager.recordedSystemBootTimeAppGroupKey)
        XCTAssertTrue(SharedPlayerManager.hasDeviceRebootedSinceLastRecordedBoot())
        XCTAssertTrue(SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning())
        XCTAssertFalse(SharedPlayerManager.isMainAppProcessRecentlyActive())

        SharedPlayerManager.persistHomeWidgetLiveChromeMirror(
            HomeWidgetLiveChrome(
                visualState: .userPaused,
                currentLanguage: "sv",
                hasError: false,
                updatedAt: Date().timeIntervalSince1970,
                stampReason: "testResidual"
            )
        )

        await WidgetIntentExecution.performControlWidgetToggle(isPlayingRequested: true)

        XCTAssertNil(
            SharedPlayerManager.loadPersistedWidgetState(),
            "Refuse must not write an optimistic session snapshot after reboot Control play"
        )
        XCTAssertNotEqual(
            manager.getPendingAction()?.action,
            "play",
            "Refuse must not write pending play"
        )
        XCTAssertEqual(
            SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.visualState,
            .userPaused,
            "Refuse must leave residual chrome unchanged"
        )
    }

    /// Main not recently active without reboot: Control `true` must refuse play.
    ///
    /// **Invariant protected:** ``isMainAppProcessRecentlyActive() == false`` alone refuses
    /// Control play even when boot identity is trusted (stale 60 s window expired / missing).
    ///
    /// - SeeAlso: ``WidgetIntentExecution/performControlWidgetToggle(isPlayingRequested:)``,
    ///   ``SharedPlayerManager/isMainAppProcessRecentlyActive()``.
    func testPerformControlWidgetToggleRefusesPlayWhenMainNotRecentlyActiveTrustedBoot() async {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.recordCurrentSystemBootTime()

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        defaults.set(Date().timeIntervalSince1970 - 120, forKey: "lastUpdateTime")
        XCTAssertFalse(SharedPlayerManager.isMainAppProcessRecentlyActive())
        XCTAssertFalse(SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning())

        SharedPlayerManager.persistHomeWidgetLiveChromeMirror(
            HomeWidgetLiveChrome(
                visualState: .userPaused,
                currentLanguage: "de",
                hasError: false,
                updatedAt: Date().timeIntervalSince1970 - 120,
                stampReason: "staleResidual"
            )
        )

        await WidgetIntentExecution.performControlWidgetToggle(isPlayingRequested: true)

        XCTAssertNil(
            SharedPlayerManager.loadPersistedWidgetState(),
            "Main not recently active + Control true must refuse play (no reboot required)"
        )
        XCTAssertNotEqual(
            manager.getPendingAction()?.action,
            "play",
            "Refuse must not write pending play"
        )
        XCTAssertEqual(
            SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.visualState,
            .userPaused
        )
    }

    /// Control `false` under reboot distrust still stamps pause (glyph honesty).
    ///
    /// **Invariant protected:** Residual-play refuse is play-only. Control pause still
    /// writes optimistic ``.userPaused`` so the Control glyph can settle after distrust.
    ///
    /// - SeeAlso: ``WidgetIntentExecution/performControlWidgetToggle(isPlayingRequested:)``,
    ///   ``SharedPlayerManager/shouldDistrustDurableMirrorPlayPlanning()``.
    func testPerformControlWidgetTogglePauseStillStampsUnderDistrust() async {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.recordCurrentSystemBootTime()

        // Seed residual while boot identity is still trusted (pre-power-off stamp).
        SharedPlayerManager.persistHomeWidgetLiveChromeMirror(
            HomeWidgetLiveChrome(
                visualState: .playing,
                currentLanguage: "fi",
                hasError: false,
                updatedAt: Date().timeIntervalSince1970,
                stampReason: "preRebootPlaying"
            )
        )
        XCTAssertEqual(SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.visualState, .playing)

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        defaults.set(1.0, forKey: SharedPlayerManager.recordedSystemBootTimeAppGroupKey)
        XCTAssertTrue(SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning())
        XCTAssertFalse(SharedPlayerManager.isMainAppProcessRecentlyActive())

        await WidgetIntentExecution.performControlWidgetToggle(isPlayingRequested: false)

        XCTAssertEqual(
            SharedPlayerManager.loadPersistedWidgetState()?.visualState,
            .userPaused,
            "Control false under distrust must still stamp pause"
        )
        XCTAssertEqual(
            SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.visualState,
            .userPaused,
            "Control pause under distrust must stamp live chrome .userPaused"
        )
    }

    /// ``performHomeWidgetStreamSwitch`` preserves paused visual on optimistic switch (checklist §6).
    func testPerformHomeWidgetStreamSwitchPreservesUserPaused() async {
        let streams = manager.availableStreams
        guard streams.count >= 2 else {
            XCTFail("Stub stream list must include ≥2 languages")
            return
        }
        let source = streams[0]
        let target = streams[1]

        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: source.languageCode)

        await WidgetIntentExecution.performHomeWidgetStreamSwitch(languageCode: target.languageCode)

        // Snapshot is process-local SSOT under the extension compile profile.
        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(snapshot?.visualState, .userPaused, "Paused visual must survive optimistic switch")
        XCTAssertEqual(snapshot?.currentLanguage, target.languageCode)
    }

    /// Active-play home stream switch: first optimistic session visual for destination language is
    /// Connecting (``.prePlay``), never mid-switch ``.playing``.
    ///
    /// Protects home first-paint honesty during silent attach hold. Terminal ``.playing`` after
    /// main-app attach is a later authoritative write — not part of this optimistic snapshot.
    ///
    /// - SeeAlso: ``WidgetIntentCoordinators/optimisticLiveActivityVisualForStreamSwitch(from:)``,
    ///   ``WidgetIntentExecution/executeHomeWidgetStreamSwitch(languageCode:)``,
    ///   docs/Widget-Presentation-Dataflow.md.
    func testPerformHomeWidgetStreamSwitchFromPlayingUsesConnectingOptimisticVisual() async {
        let streams = manager.availableStreams
        guard streams.count >= 2 else {
            XCTFail("Stub stream list must include ≥2 languages")
            return
        }
        let source = streams[0]
        let target = streams[1]

        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: source.languageCode)

        await WidgetIntentExecution.performHomeWidgetStreamSwitch(languageCode: target.languageCode)

        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(
            snapshot?.visualState,
            .prePlay,
            "Leaving active play for home stream switch must paint Connecting, not destination playing"
        )
        XCTAssertEqual(snapshot?.currentLanguage, target.languageCode)
        XCTAssertNotEqual(
            snapshot?.visualState,
            .playing,
            "Must not invent mid-switch playing chrome for a stream that has not attached"
        )
    }

    /// Durable LA toggle mirror + empty session: first lock-screen-style toggle plans pause.
    ///
    /// Reproduces the lockscreen regression: extension actor defaults to `.prePlay` and the
    /// memory-only session snapshot is nil under home-widget write suppression, while audio
    /// (and the LA glyph) are still playing. The durable App Group mirror must drive `.pause`.
    func testPerformLiveActivityToggleUsesDurableMirrorWhenSessionEmpty() async {
        // Ensure no leftover in-process snapshot from prior tests in this process.
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        await MainActor.run {
            WidgetRefreshManager.setHasActiveLutheranWidgets(false)
        }

        // Authoritative LA surface says playing (what the lock screen showed).
        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(.playing)

        XCTAssertNil(
            SharedPlayerManager.loadPersistedWidgetState(),
            "Session snapshot must be empty to model cold extension + write suppression"
        )
        XCTAssertEqual(SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(), .playing)

        // Plan-only check (same inputs performLiveActivityToggle resolves) — avoid relying on
        // DirectStreamingPlayer soft-pause side effects under the widget stub.
        let resolution = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: nil,
            durableMirror: SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(),
            actorVisualState: .prePlay,
            sessionSnapshot: SharedPlayerManager.loadPersistedWidgetState()?.visualState
        )
        XCTAssertEqual(resolution.source, .durableCrossProcessMirror)
        XCTAssertEqual(resolution.visualState, .playing)
        XCTAssertEqual(
            WidgetIntentCoordinators.planLiveActivityToggle(resolution: resolution),
            .pause,
            "Empty extension memory must not invert lock-screen pause to play"
        )

        await WidgetIntentExecution.performLiveActivityToggle()

        // Optimistic mirror advances to paused for the next rapid tap.
        XCTAssertEqual(
            SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(),
            .userPaused,
            "After planned pause, durable mirror should optimistically flip to userPaused"
        )

        // Rapid second-tap contract without ActivityKit: durable mirror alone (content nil)
        // must plan play after the optimistic pause write — same direction as ContentState
        // once the optimistic Activity.update lands on device.
        let secondTap = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: nil,
            durableMirror: SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(),
            actorVisualState: .prePlay,
            sessionSnapshot: nil
        )
        XCTAssertEqual(secondTap.source, .durableCrossProcessMirror)
        XCTAssertEqual(
            WidgetIntentCoordinators.planLiveActivityToggle(resolution: secondTap),
            .play,
            "Second rapid tap after optimistic pause mirror must plan play"
        )
    }

    /// Optimistic ContentState builder preserves stream metadata and language when flipping control visual.
    ///
    /// Lock-screen toggle must not clear program title/speaker/language while flipping play/pause.
    func testOptimisticLiveActivityContentPreservesStreamMetadata() {
        let metadata = StreamProgramMetadata(programTitle: "Vesper", speaker: "Cantor")
        let before = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .playing,
            streamMetadata: metadata,
            currentLanguage: "et"
        )
        let after = before.replacingVisualState(.userPaused)
        XCTAssertEqual(after.visualState, .userPaused)
        XCTAssertEqual(after.streamMetadata, metadata)
        XCTAssertEqual(after.currentLanguage, "et")
    }

    /// Durable mirror alone: persist/load/clear contract (no ActivityKit IPC).
    func testLiveActivityToggleVisualStateMirrorRoundTrip() {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        XCTAssertNil(SharedPlayerManager.loadLiveActivityToggleVisualStateMirror())

        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(.playing)
        XCTAssertEqual(SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(), .playing)

        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(.userPaused)
        XCTAssertEqual(SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(), .userPaused)

        SharedPlayerManager.clearLiveActivityToggleVisualStateMirror()
        XCTAssertNil(SharedPlayerManager.loadLiveActivityToggleVisualStateMirror())
    }

    /// Durable LA language mirror: persist/load/clear; optimistic language prefers mirror over
    /// session-less preferredWidgetLanguage fallback.
    ///
    /// Protects LA-only sessions (no home widgets / empty session snapshot) so play/pause
    /// instant-feedback language is not stamped from the privacy-gated default when
    /// ContentState already held a non-English stream code on the durable mirror.
    func testLiveActivityLanguageMirrorRoundTripAndOptimisticLanguageResolve() {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        XCTAssertNil(SharedPlayerManager.loadLiveActivityLanguageMirror())
        XCTAssertNil(SharedPlayerManager.loadPersistedWidgetState())

        let fallbackWithoutMirror = SharedPlayerManager.languageForLiveActivityOrWidgetOptimistic()
        // Without session or mirror, optimistic language falls through to preferredWidgetLanguage.
        XCTAssertEqual(fallbackWithoutMirror, SharedPlayerManager.preferredWidgetLanguage())

        SharedPlayerManager.persistLiveActivityLanguageMirror("fi")
        XCTAssertEqual(SharedPlayerManager.loadLiveActivityLanguageMirror(), "fi")
        XCTAssertEqual(
            SharedPlayerManager.languageForLiveActivityOrWidgetOptimistic(),
            "fi",
            "Optimistic LA language must prefer durable language mirror over privacy-gated preferredWidgetLanguage"
        )

        SharedPlayerManager.clearLiveActivityLanguageMirror()
        XCTAssertNil(SharedPlayerManager.loadLiveActivityLanguageMirror())
        XCTAssertEqual(
            SharedPlayerManager.languageForLiveActivityOrWidgetOptimistic(),
            SharedPlayerManager.preferredWidgetLanguage()
        )
    }

    /// Privacy clear removes both durable LA visual and language mirrors.
    func testRemoveAllLocalPlaybackKeysClearsLiveActivityLanguageMirror() {
        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(.playing)
        SharedPlayerManager.persistLiveActivityLanguageMirror("de")
        XCTAssertEqual(SharedPlayerManager.loadLiveActivityLanguageMirror(), "de")

        SharedPlayerManager.removeAllLocalPlaybackKeys()

        XCTAssertNil(SharedPlayerManager.loadLiveActivityToggleVisualStateMirror())
        XCTAssertNil(SharedPlayerManager.loadLiveActivityLanguageMirror())
    }

    /// Simulated reboot (stale recorded boot) distrusts durable-mirror-alone play planning.
    ///
    /// Boot identity is warmed by the main app (LA push / factory reset), not by extension
    /// optimistic mirror writes — so this test records boot explicitly then ages it.
    func testShouldDistrustDurableMirrorPlayPlanningWhenBootIdentityStale() {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(.userPaused)
        // Simulate main-app LA push having recorded a healthy boot for this session.
        SharedPlayerManager.recordCurrentSystemBootTime()
        XCTAssertFalse(
            SharedPlayerManager.hasDeviceRebootedSinceLastRecordedBoot(),
            "Current boot identity must not report reboot"
        )

        let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared")
        // Simulate a prior boot epoch left in the App Group across hard power-off.
        defaults?.set(1.0, forKey: SharedPlayerManager.recordedSystemBootTimeAppGroupKey)

        XCTAssertTrue(SharedPlayerManager.hasDeviceRebootedSinceLastRecordedBoot())
        XCTAssertTrue(SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning())

        let resolution = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: nil,
            durableMirror: .userPaused,
            actorVisualState: .prePlay,
            sessionSnapshot: nil
        )
        XCTAssertEqual(
            WidgetIntentCoordinators.planLiveActivityToggle(
                resolution: resolution,
                distrustDurableMirrorPlay: SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning()
            ),
            .pause
        )
    }

    /// Termination sentinel alone distrusts durable-mirror-alone play.
    func testShouldDistrustDurableMirrorPlayPlanningWhenTerminationSentinel() {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        SharedPlayerManager.recordCurrentSystemBootTime()
        SharedPlayerManager.forceStaleLivenessTimestampForTermination()

        XCTAssertTrue(SharedPlayerManager.hasExplicitTerminationSentinel())
        XCTAssertTrue(SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning())
    }

    // MARK: - Extension liveness honesty (main not recently active / reboot)

    /// Extension must not open a new 60 s interactive chrome window when main is not
    /// recently active (stale / missing `lastUpdateTime`).
    ///
    /// **Invariant protected:** ``bumpWidgetLivenessTimestamp(policy:minInterval:)`` in the
    /// widget process returns without writing when ``isMainAppProcessRecentlyActive()`` is
    /// false before the call. Instant-feedback language keys may still write.
    ///
    /// - SeeAlso: ``SharedPlayerManager/bumpWidgetLivenessTimestamp(policy:minInterval:)``,
    ///   ``SharedPlayerManager/writeInstantFeedback(language:)``,
    ///   ``SharedPlayerManager/isMainAppProcessRecentlyActive()``.
    func testExtensionLivenessBumpDoesNotResurrectWhenMainNotRecentlyActive() {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        SharedPlayerManager.recordCurrentSystemBootTime()

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        XCTAssertFalse(SharedPlayerManager.isMainAppProcessRecentlyActive())
        XCTAssertFalse(SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning())

        SharedPlayerManager.bumpWidgetLivenessTimestamp(policy: .immediate)
        SharedPlayerManager.writeInstantFeedback(language: "fi")

        XCTAssertNil(
            defaults.object(forKey: "lastUpdateTime"),
            "Extension must not invent lastUpdateTime when main was not recently active"
        )
        XCTAssertFalse(SharedPlayerManager.isMainAppProcessRecentlyActive())
        XCTAssertEqual(
            defaults.string(forKey: "instantFeedbackLanguage"),
            "fi",
            "Instant-feedback language may still write without resurrecting interactive liveness"
        )
    }

    /// Termination sentinel must not be cleared by an extension liveness bump.
    ///
    /// **Invariant protected:** When ``hasExplicitTerminationSentinel()`` is true,
    /// ``shouldDistrustDurableMirrorPlayPlanning()`` blocks extension `lastUpdateTime` writes.
    ///
    /// - SeeAlso: ``SharedPlayerManager/forceStaleLivenessTimestampForTermination()``,
    ///   ``SharedPlayerManager/bumpWidgetLivenessTimestamp(policy:minInterval:)``.
    func testExtensionLivenessBumpDoesNotClearTerminationSentinel() {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        SharedPlayerManager.recordCurrentSystemBootTime()
        SharedPlayerManager.forceStaleLivenessTimestampForTermination()

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        XCTAssertTrue(SharedPlayerManager.hasExplicitTerminationSentinel())
        XCTAssertTrue(SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning())

        SharedPlayerManager.bumpWidgetLivenessTimestamp(policy: .immediate)
        SharedPlayerManager.writeInstantFeedback(language: "sv")

        XCTAssertEqual(
            defaults.double(forKey: "lastUpdateTime"),
            0,
            "Extension must leave termination sentinel (0) intact"
        )
        XCTAssertFalse(SharedPlayerManager.isMainAppProcessRecentlyActive())
        XCTAssertEqual(defaults.string(forKey: "instantFeedbackLanguage"), "sv")
    }

    /// Simulated reboot (stale boot identity) must not allow extension to open interactive chrome.
    ///
    /// **Invariant protected:** ``hasDeviceRebootedSinceLastRecordedBoot()`` →
    /// ``shouldDistrustDurableMirrorPlayPlanning()`` suppresses extension liveness stamps even
    /// when a residual positive `lastUpdateTime` would otherwise still be inside the 60 s window.
    ///
    /// - SeeAlso: ``SharedPlayerManager/recordCurrentSystemBootTime()``,
    ///   ``SharedPlayerManager/bumpWidgetLivenessTimestamp(policy:minInterval:)``.
    func testExtensionLivenessBumpDoesNotResurrectAfterSimulatedReboot() {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        SharedPlayerManager.recordCurrentSystemBootTime()

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        // Residual pre-reboot heartbeat that would still look "fresh" by wall clock alone.
        let residual = Date().timeIntervalSince1970 - 10
        defaults.set(residual, forKey: "lastUpdateTime")
        // Prior boot epoch left across hard power-off.
        defaults.set(1.0, forKey: SharedPlayerManager.recordedSystemBootTimeAppGroupKey)

        XCTAssertTrue(SharedPlayerManager.hasDeviceRebootedSinceLastRecordedBoot())
        XCTAssertTrue(SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning())
        // Residual wall-clock heartbeat must not keep interactive chrome after reboot.
        XCTAssertFalse(
            SharedPlayerManager.isMainAppProcessRecentlyActive(),
            "Boot-identity mismatch must force passive home chrome even with residual lastUpdateTime"
        )

        SharedPlayerManager.bumpWidgetLivenessTimestamp(policy: .immediate)

        XCTAssertEqual(
            defaults.double(forKey: "lastUpdateTime"),
            residual,
            "Extension must not refresh lastUpdateTime after reboot distrust"
        )
        XCTAssertFalse(SharedPlayerManager.isMainAppProcessRecentlyActive())
    }

    /// When main is already recently active on this boot, extension may refresh the heartbeat.
    ///
    /// **Invariant protected:** Extension refresh path remains available for in-window
    /// optimistic actions while the main process liveness window is open.
    ///
    /// - SeeAlso: ``SharedPlayerManager/bumpWidgetLivenessTimestamp(policy:minInterval:)``.
    func testExtensionLivenessBumpRefreshesWhenMainAlreadyRecentlyActive() {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        SharedPlayerManager.recordCurrentSystemBootTime()

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        let seed = Date().timeIntervalSince1970 - 20
        defaults.set(seed, forKey: "lastUpdateTime")
        XCTAssertTrue(SharedPlayerManager.isMainAppProcessRecentlyActive())
        XCTAssertFalse(SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning())

        SharedPlayerManager.bumpWidgetLivenessTimestamp(policy: .immediate)

        let after = defaults.double(forKey: "lastUpdateTime")
        XCTAssertGreaterThan(after, seed, "Extension may refresh an already-open interactive window")
        XCTAssertTrue(SharedPlayerManager.isMainAppProcessRecentlyActive())
    }

    // MARK: - LiveActivitySwitchStreamIntent contract (symmetric to home switch + LA toggle)

    /// Unknown language codes must not invoke ``switchToStream`` (Bool false).
    ///
    /// Mirrors the thin AppIntent guard in ``LiveActivitySwitchStreamIntent/perform()`` via
    /// ``WidgetIntentExecution/performLiveActivityStreamSwitch(languageCode:)``.
    func testPerformLiveActivityStreamSwitchRejectsUnknownLanguage() async {
        let streams = manager.availableStreams
        guard let source = streams.first else {
            XCTFail("Expected stub streams")
            return
        }
        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: source.languageCode)

        let switched = await WidgetIntentExecution.performLiveActivityStreamSwitch(languageCode: "xx-unknown")
        XCTAssertFalse(switched)

        // Reject path must leave optimistic snapshot untouched.
        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(snapshot?.visualState, .userPaused)
        XCTAssertEqual(snapshot?.currentLanguage, source.languageCode)
    }

    /// Known language codes return true (stream list match + ``switchToStream`` invoked).
    func testPerformLiveActivityStreamSwitchAcceptsKnownLanguage() async {
        let streams = manager.availableStreams
        guard let target = streams.last else {
            XCTFail("Expected stub streams")
            return
        }
        let switched = await WidgetIntentExecution.performLiveActivityStreamSwitch(
            languageCode: target.languageCode
        )
        XCTAssertTrue(switched)
    }

    /// LA stream switch preserves explicit pause and updates language (checklist §6 parity
    /// with ``performHomeWidgetStreamSwitch`` / home-widget optimistic switch SSOT).
    ///
    /// Extension profile: ``switchToStream`` is the shared optimistic path; LA does not
    /// re-plan play/pause (unlike ``performLiveActivityToggle`` multi-source resolution).
    func testPerformLiveActivityStreamSwitchPreservesUserPausedAndUpdatesLanguage() async {
        let streams = manager.availableStreams
        guard streams.count >= 2 else {
            XCTFail("Stub stream list must include ≥2 languages")
            return
        }
        let source = streams[0]
        let target = streams[1]

        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: source.languageCode)

        let switched = await WidgetIntentExecution.performLiveActivityStreamSwitch(
            languageCode: target.languageCode
        )
        XCTAssertTrue(switched)

        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(snapshot?.visualState, .userPaused, "Paused visual must survive LA optimistic switch")
        XCTAssertEqual(snapshot?.currentLanguage, target.languageCode)
    }

    /// Playing snapshot: LA switch updates language and applies Connecting honesty on the shared
    /// optimistic session visual (same pure rule as home-widget stream switch).
    ///
    /// Live Activity ContentState also uses Connecting when leaving active play; the session
    /// snapshot must not keep mid-switch ``.playing`` for a stream that has not attached.
    func testPerformLiveActivityStreamSwitchFromPlayingUsesConnectingOptimisticVisual() async {
        let streams = manager.availableStreams
        guard streams.count >= 2 else {
            XCTFail("Stub stream list must include ≥2 languages")
            return
        }
        let source = streams[0]
        let target = streams[1]

        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: source.languageCode)

        let switched = await WidgetIntentExecution.performLiveActivityStreamSwitch(
            languageCode: target.languageCode
        )
        XCTAssertTrue(switched)

        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(
            snapshot?.visualState,
            .prePlay,
            "Leaving play for LA stream switch must pin session visual to Connecting"
        )
        XCTAssertEqual(snapshot?.currentLanguage, target.languageCode)
    }

    /// LA stream switch warms durable language mirror with destination before main-app drain.
    ///
    /// Protects lock-screen flag chrome: ActivityKit may be empty under test isolation, but
    /// the language mirror (and Connecting toggle mirror when leaving play) must still advance
    /// so extension-hosted second taps and main-app stamp paths do not fall through to a
    /// prior-language preferredWidgetLanguage default.
    func testPerformLiveActivityStreamSwitchWarmsLanguageMirrorAndConnectingToggleMirror() async {
        let streams = manager.availableStreams
        guard streams.count >= 2 else {
            XCTFail("Stub stream list must include ≥2 languages")
            return
        }
        let source = streams[0]
        let target = streams[1]

        SharedPlayerManager.removeAllLocalPlaybackKeys()
        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: source.languageCode)
        SharedPlayerManager.persistLiveActivityLanguageMirror(source.languageCode)
        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(.playing)

        let switched = await WidgetIntentExecution.performLiveActivityStreamSwitch(
            languageCode: target.languageCode
        )
        XCTAssertTrue(switched)

        XCTAssertEqual(
            SharedPlayerManager.loadLiveActivityLanguageMirror(),
            target.languageCode,
            "Destination language must warm durable LA language mirror at intent time"
        )
        XCTAssertEqual(
            SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(),
            .prePlay,
            "Leaving play for stream switch must pin toggle mirror to Connecting (not false playing)"
        )
        XCTAssertEqual(
            SharedPlayerManager.languageForLiveActivityOrWidgetOptimistic(),
            target.languageCode
        )
    }

    /// Paused LA stream switch keeps pause chrome on the toggle mirror while updating language.
    func testPerformLiveActivityStreamSwitchWhilePausedPreservesToggleMirrorPause() async {
        let streams = manager.availableStreams
        guard streams.count >= 2 else {
            XCTFail("Stub stream list must include ≥2 languages")
            return
        }
        let source = streams[0]
        let target = streams[1]

        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: source.languageCode)
        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(.userPaused)

        let switched = await WidgetIntentExecution.performLiveActivityStreamSwitch(
            languageCode: target.languageCode
        )
        XCTAssertTrue(switched)

        XCTAssertEqual(SharedPlayerManager.loadLiveActivityLanguageMirror(), target.languageCode)
        XCTAssertEqual(
            SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(),
            .userPaused,
            "Sticky pause must not invent Connecting on language-only switch"
        )
    }

    /// Cold extension (empty session): known-language LA switch still succeeds.
    ///
    /// Symmetric to LA toggle’s empty-session planning path — switch does not require a
    /// pre-existing session snapshot or durable toggle mirror.
    func testPerformLiveActivityStreamSwitchSucceedsWithEmptySessionSnapshot() async {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        XCTAssertNil(SharedPlayerManager.loadPersistedWidgetState())

        let streams = manager.availableStreams
        guard let target = streams.first else {
            XCTFail("Expected stub streams")
            return
        }

        let switched = await WidgetIntentExecution.performLiveActivityStreamSwitch(
            languageCode: target.languageCode
        )
        XCTAssertTrue(switched)

        // Widget switch path writes optimistic language even from an empty session.
        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(snapshot?.currentLanguage, target.languageCode)
    }

    // MARK: - Immediate refresh gate (extension optimistic path)

    /// Optimistic toggle requests `immediate: true` refresh (extension-local reload path).
    ///
    /// Asserts the optimistic snapshot write completed under the privacy gate;
    /// does not require observing WidgetCenter IPC. Darwin may drain App Group pending
    /// when hosted by the main app (see perform-path note above).
    func testExecuteOptimisticToggleCompletesImmediateRefreshPath() async {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: "et")
        let plan = WidgetIntentCoordinators.planHomeWidgetToggle(from: .userPaused)
        XCTAssertEqual(plan.action, .play)
        XCTAssertEqual(plan.targetVisualState, .userPaused, "Home play holds sticky pause until setPlaying")

        await WidgetIntentExecution.executeOptimisticToggle(plan: plan, language: "et")

        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(snapshot?.visualState, .userPaused)
        XCTAssertEqual(snapshot?.currentLanguage, "et")
    }

    /// Home-widget pause warms durable LA toggle mirror to `.userPaused` (not home-widget gated).
    ///
    /// Protects pause honesty when system-held LA ContentState is still Connecting: multi-source
    /// resolve can plan from the durable mirror, and optimistic ContentState push preserves
    /// language while replacing the control visual (ActivityKit IPC skipped under UITestMode).
    func testExecuteOptimisticTogglePauseWarmsDurableLiveActivityMirror() async {
        SharedPlayerManager.clearLiveActivityToggleVisualStateMirror()
        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: "de")
        SharedPlayerManager.persistLiveActivityLanguageMirror("de")

        let plan = WidgetIntentCoordinators.planHomeWidgetToggle(from: .playing)
        XCTAssertEqual(plan.action, .pause)
        XCTAssertEqual(plan.targetVisualState, .userPaused)

        await WidgetIntentExecution.executeOptimisticToggle(plan: plan, language: "de")

        XCTAssertEqual(
            SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(),
            .userPaused,
            "Home pause must pin durable LA toggle mirror for lock-screen planning"
        )
        let snapshot = SharedPlayerManager.loadPersistedWidgetState()
        XCTAssertEqual(snapshot?.visualState, .userPaused)
        XCTAssertEqual(snapshot?.currentLanguage, "de")
    }

    // MARK: - Instant feedback

    /// Instant feedback still wins inside the 15 s window when it **agrees** with the
    /// settled session / live-chrome language (optimistic switch after persist).
    func testLoadSharedStatePrefersInstantFeedbackWithinFifteenSecondWindow() {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: "fi")
        SharedPlayerManager.writeInstantFeedback(language: "fi")

        let state = manager.loadSharedState()
        XCTAssertEqual(state.currentLanguage, "fi")
        XCTAssertTrue(state.isPlaying)
    }

    /// Play/pause must not let a lagging instant-feedback language override a settled
    /// session / live-chrome stream (`et` must not become `sv`).
    ///
    /// **Invariant protected:** ``loadSharedState()`` ignores ``instantFeedbackLanguage``
    /// when it disagrees with session / ``homeWidgetLiveChrome``.
    /// ``languageForLiveActivityOrWidgetOptimistic()`` prefers those sources over the
    /// durable Live Activity language mirror. The leftover `sv` is planted on the suite
    /// (the production writer coerces — this test keeps the read gate).
    ///
    /// - SeeAlso: ``SharedPlayerManager/loadSharedState()``,
    ///   ``SharedPlayerManager/languageForLiveActivityOrWidgetOptimistic()``,
    ///   ``WidgetIntentExecution/executeOptimisticToggle(plan:language:)``.
    func testLoadSharedStateDoesNotOverrideSettledEtWithDisagreeingInstantFeedbackSv() {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: "et")
        SharedPlayerManager.persistLiveActivityLanguageMirror("sv")
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        defaults.set(true, forKey: "isInstantFeedback")
        defaults.set(Date().timeIntervalSince1970, forKey: "instantFeedbackTime")
        defaults.set("sv", forKey: "instantFeedbackLanguage")

        XCTAssertEqual(
            SharedPlayerManager.languageForLiveActivityOrWidgetOptimistic(),
            "et",
            "Play/pause optimistic language must prefer session/live chrome over a lagging LA mirror"
        )
        let state = manager.loadSharedState()
        XCTAssertEqual(state.currentLanguage, "et")
        XCTAssertTrue(state.isPlaying)
    }

    /// Play/pause instant-feedback **write** must persist settled chrome, not locale `sv`.
    ///
    /// **Invariant protected:** ``writeInstantFeedback(language:)`` stores `et` when
    /// session / ``homeWidgetLiveChrome`` are `et`.
    ///
    /// - SeeAlso: ``SharedPlayerManager/writeInstantFeedback(language:)``,
    ///   ``SharedPlayerManager/languageForInstantFeedbackWrite(_:)``.
    func testWriteInstantFeedbackStoresSettledEtNotCallerSv() {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: "et")
        SharedPlayerManager.writeInstantFeedback(language: "sv")

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        XCTAssertEqual(defaults.string(forKey: "instantFeedbackLanguage"), "et")
        XCTAssertEqual(manager.loadSharedState().currentLanguage, "et")
    }

    /// Empty extension session RAM still follows stamped ``homeWidgetLiveChrome``.
    ///
    /// **Invariant protected:** ``languageForInstantFeedbackWrite(_:)`` re-syncs live
    /// chrome and coerces locale `sv` to chrome `et`.
    func testWriteInstantFeedbackStoresLiveChromeEtWhenSessionIsEmpty() {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: "et")
        SharedPlayerManager.inMemorySessionWidgetSnapshot = nil
        XCTAssertNil(SharedPlayerManager.loadPersistedWidgetState())
        XCTAssertEqual(
            SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.currentLanguage,
            "et"
        )

        SharedPlayerManager.writeInstantFeedback(language: "sv")

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        XCTAssertEqual(defaults.string(forKey: "instantFeedbackLanguage"), "et")
        XCTAssertEqual(SharedPlayerManager.languageForInstantFeedbackWrite("sv"), "et")
    }

    /// Leftover in-process session `sv` must not re-plant instant feedback when
    /// ``homeWidgetLiveChrome`` is already strictly fresher `et`.
    ///
    /// **Invariant protected:** ``settledLanguageForInstantFeedback()`` prefers chrome
    /// when `updatedAt` is strictly newer than session ``lastLanguageChangeTime``
    /// (same freshness rule as ``resolveHomeWidgetChromeFields``).
    /// ``writeInstantFeedback(language:)`` / ``languageForInstantFeedbackWrite(_:)``
    /// coerce caller `sv` to `et`; ``loadSharedState()`` does not treat leftover
    /// session `sv` as a valid instant-feedback match. Durable LA language is unused.
    ///
    /// - SeeAlso: ``SharedPlayerManager/settledLanguageForInstantFeedback()``,
    ///   ``SharedPlayerManager/writeInstantFeedback(language:)``,
    ///   ``SharedPlayerManager/loadSharedState()``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§5.3).
    func testWriteInstantFeedbackCoercesLeftoverSessionSvWhenLiveChromeEtIsFresher() {
        plantLeftoverSessionLanguage("sv", sessionStamp: 1_000)
        plantHomeWidgetLiveChrome(language: "et", updatedAt: 2_000)

        XCTAssertEqual(SharedPlayerManager.languageForInstantFeedbackWrite("sv"), "et")
        SharedPlayerManager.writeInstantFeedback(language: "sv")

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        XCTAssertEqual(defaults.string(forKey: "instantFeedbackLanguage"), "et")
        XCTAssertEqual(manager.loadSharedState().currentLanguage, "et")
        XCTAssertEqual(SharedPlayerManager.settledLanguageForInstantFeedback(), "et")
    }

    /// Older chrome must not beat a fresher session `et` (ties stay session).
    ///
    /// **Invariant protected:** Leftover ``instantFeedbackLanguage`` `sv` is ignored
    /// when session `et` is fresher or tied vs chrome.
    ///
    /// - SeeAlso: ``SharedPlayerManager/settledLanguageForInstantFeedback()``,
    ///   ``SharedPlayerManager/loadSharedState()``.
    func testLoadSharedStateKeepsFresherSessionEtWhenChromeAndInstantFeedbackAreSv() {
        plantLeftoverSessionLanguage("et", sessionStamp: 2_000)
        plantHomeWidgetLiveChrome(language: "sv", updatedAt: 1_000)
        plantExtensionInstantFeedbackLanguage("sv")

        XCTAssertEqual(SharedPlayerManager.languageForInstantFeedbackWrite("sv"), "et")
        XCTAssertEqual(manager.loadSharedState().currentLanguage, "et")

        plantLeftoverSessionLanguage("et", sessionStamp: 1_500)
        plantHomeWidgetLiveChrome(language: "sv", updatedAt: 1_500)
        plantExtensionInstantFeedbackLanguage("sv")
        XCTAssertEqual(
            SharedPlayerManager.settledLanguageForInstantFeedback(),
            "et",
            "Equal stamps prefer session, matching resolveHomeWidgetChromeFields"
        )
        XCTAssertEqual(manager.loadSharedState().currentLanguage, "et")
    }

    /// Optimistic switch destination still flashes when it already matches fresher chrome.
    ///
    /// **Invariant protected:** ``writeInstantFeedback(language:)`` stores `fi` when
    /// chrome is already `fi` (strictly fresher) even if leftover session is `sv`.
    ///
    /// - SeeAlso: ``SharedPlayerManager/languageForInstantFeedbackWrite(_:)``,
    ///   ``SharedPlayerManager/signalWidgetSwitchAction(visualState:language:)``.
    func testWriteInstantFeedbackStoresFresherChromeFiWhenCallerProposesSwitchDestination() {
        plantLeftoverSessionLanguage("sv", sessionStamp: 1_000)
        plantHomeWidgetLiveChrome(language: "fi", updatedAt: 2_000)

        XCTAssertEqual(SharedPlayerManager.languageForInstantFeedbackWrite("fi"), "fi")
        SharedPlayerManager.writeInstantFeedback(language: "fi")

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        XCTAssertEqual(defaults.string(forKey: "instantFeedbackLanguage"), "fi")
        XCTAssertEqual(manager.loadSharedState().currentLanguage, "fi")
    }

    /// Home-widget pause of a settled `et` stream must write `et` instant feedback and
    /// keep ``loadSharedState()`` on `et` even if the LA language mirror is still `sv`.
    ///
    /// **Invariant protected:** ``executeOptimisticToggle(plan:language:)`` stamps
    /// instant feedback with the plan language (session / live chrome), not a lagging
    /// ContentState / durable-mirror code.
    ///
    /// - SeeAlso: ``WidgetIntentExecution/executeOptimisticToggle(plan:language:)``,
    ///   ``SharedPlayerManager/writeInstantFeedback(language:)``.
    func testExecuteOptimisticTogglePauseWritesEtInstantFeedbackNotLaggingSv() async {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: "et")
        SharedPlayerManager.persistLiveActivityLanguageMirror("sv")
        SharedPlayerManager.writeInstantFeedback(language: "sv")

        let plan = WidgetIntentCoordinators.planHomeWidgetToggle(from: .playing)
        XCTAssertEqual(plan.action, .pause)
        await WidgetIntentExecution.executeOptimisticToggle(plan: plan, language: "et")

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        XCTAssertEqual(defaults.string(forKey: "instantFeedbackLanguage"), "et")
        XCTAssertEqual(manager.loadSharedState().currentLanguage, "et")
        XCTAssertEqual(SharedPlayerManager.loadLiveActivityLanguageMirror(), "et")
    }

    /// First backgrounded pause with empty extension RAM must not plant locale `sv`
    /// when ``homeWidgetLiveChrome`` is already `et`.
    ///
    /// **Invariant protected:** ``executeOptimisticToggle(plan:language:)`` coerces
    /// via ``languageForInstantFeedbackWrite(_:)`` before persist + instant feedback.
    func testExecuteOptimisticTogglePauseCoercesCallerSvToLiveChromeEt() async {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .playing, language: "et")
        SharedPlayerManager.inMemorySessionWidgetSnapshot = nil
        SharedPlayerManager.persistLiveActivityLanguageMirror("sv")

        let plan = WidgetIntentCoordinators.planHomeWidgetToggle(from: .playing)
        XCTAssertEqual(plan.action, .pause)
        await WidgetIntentExecution.executeOptimisticToggle(plan: plan, language: "sv")

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        XCTAssertEqual(defaults.string(forKey: "instantFeedbackLanguage"), "et")
        XCTAssertEqual(SharedPlayerManager.loadPersistedWidgetState()?.currentLanguage, "et")
        XCTAssertEqual(
            SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.currentLanguage,
            "et"
        )
        XCTAssertEqual(manager.loadSharedState().currentLanguage, "et")
    }

    func testLoadSharedStateFallsBackAfterInstantFeedbackExpiry() {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: "en")

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        defaults.set(true, forKey: "isInstantFeedback")
        defaults.set("fi", forKey: "instantFeedbackLanguage")
        defaults.set(Date().timeIntervalSince1970 - 16, forKey: "instantFeedbackTime")

        let state = manager.loadSharedState()
        XCTAssertEqual(state.currentLanguage, "en")
        XCTAssertFalse(state.isPlaying)
    }

    /// In-process leftover session with an explicit older/newer stamp (does not restamp chrome).
    private func plantLeftoverSessionLanguage(_ language: String, sessionStamp: TimeInterval) {
        SharedPlayerManager.inMemorySessionWidgetSnapshot = SharedPlayerManager.PersistedWidgetState(
            visualState: .playing,
            currentLanguage: language,
            lastLanguageChangeTime: Date(timeIntervalSince1970: sessionStamp),
            streamMetadata: nil,
            hasError: false
        )
    }

    /// Privacy-gated live chrome with an explicit `updatedAt` (does not touch session RAM).
    private func plantHomeWidgetLiveChrome(language: String, updatedAt: TimeInterval) {
        SharedPlayerManager.persistHomeWidgetLiveChromeMirror(
            HomeWidgetLiveChrome(
                visualState: .playing,
                currentLanguage: language,
                hasError: false,
                updatedAt: updatedAt,
                stampReason: "testFreshnessPlant"
            )
        )
    }

    /// Plants leftover instant-feedback keys without going through the coercing writer.
    private func plantExtensionInstantFeedbackLanguage(_ language: String) {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        defaults.set(true, forKey: "isInstantFeedback")
        defaults.set(Date().timeIntervalSince1970, forKey: "instantFeedbackTime")
        defaults.set(language, forKey: "instantFeedbackLanguage")
    }
}
