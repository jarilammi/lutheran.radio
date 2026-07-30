//
//  RadioPlayerChromeVisualResolverTests.swift
//  Lutheran RadioTests
//
//  Complete in-app chrome policy matrix + coordinator contracts:
//  pure resolver rows (sticky pause, soft-resume hold promote, Connecting race,
//  switch hold, privacy/security/thermal), status-path adapter, visual SSOT paint
//  without status, and status supersession gate.
//
//  Created by Jari Lammi on 22.7.2026.
//

import XCTest
import WidgetSurface
@testable import Lutheran_Radio

/// Asserts pure ``RadioPlayerChromeVisualResolver`` policy and light coordinator application.
///
/// ## Required pure policy matrix
///
/// | # | Situation | Expected chrome |
/// |---|-----------|-----------------|
/// | 1 | Privacy clear intent | `.cleared` |
/// | 2 | True sticky pause + late `status_playing` | `.userPaused` |
/// | 3 | Soft-resume hold (residual pause visual, active intent, audible) | `.playing` |
/// | 4 | Connecting race (`.prePlay` + audible) | `.playing` |
/// | 5 | True Connecting (`.prePlay` + connecting key, silent) | `.prePlay` |
/// | 6 | Switch hold (`.prePlay` + buffer chatter, silent) | `.prePlay` |
/// | 7 | Security / thermal policy chrome | keep policy visual |
/// | 8 | Terminal stop/pause while sticky | `.userPaused` |
///
/// ## Required integration contracts
///
/// - Soft-resume / sticky / deferred Connecting via ``handleStatusChange`` → ``PlayerViewModel``.
/// - After ``setPlaying()``, main chrome is `.playing` **without** status delivery.
/// - Explicit ``setUserPaused()`` / ``stop()`` paint grey via visual SSOT (no status).
/// - Status supersession: race-lead promote allowed; settled SSOT not regressively overwritten.
///
/// Why pure + light integration:
/// - ``RadioPlayerChromeVisualResolver`` is side-effect free (fast, no AVPlayer / ActivityKit).
/// - ``handleStatusChange`` integration proves the coordinator applies the policy into
///   ``PlayerViewModel`` without requiring a full streaming attach.
/// - SSOT observation integration proves chrome follows ``visualStateDidChange`` without status.
///
/// - SeeAlso: ``RadioPlayerChromeVisualResolver``,
///   ``RadioPlayerChromeVisualResolver/shouldApplyStatusPathChromePaint(policyResult:latestVisual:latestIntent:lastApplied:)``,
///   ``RadioPlayerCoordinator/handleStatusChange(_:reasonKey:)``,
///   ``RadioPlayerCoordinator/beginObservingVisualStateForChrome()``,
///   ``SharedPlayerManager/setPlaying()``, ``SharedPlayerManager/stop()``,
///   ``SharedPlayerManager/makeEventsStreamWithReplay()``,
///   ``PlaybackIntent/isActivePlaybackIntent``, CODING_AGENT.md (fast test patterns),
///   docs/Widget-Presentation-Dataflow.md (Main-App Chrome Authority).
@MainActor
final class RadioPlayerChromeVisualResolverTests: XCTestCase {

    private let manager = SharedPlayerManager.shared

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            let la = RadioLiveActivityManager.shared
            la.stopLocalUpdateTimer()
            la.activityObservationTask?.cancel()
            la.currentActivity = nil
            WidgetRefreshManager.setHasActiveLutheranWidgets(true)
            // Keep WidgetRefreshManager off the multi-cast fan-out so SSOT chrome
            // observation tests are not contending with a second consumer.
            WidgetRefreshManager._test_setSuppressPlayerEventObservation(true)
            WidgetRefreshManager.shared._test_suspendPlayerEventObservation()
        }
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        await SharedPlayerManager.clearAllLocalState()
        await manager.setUserIntentToPlay()
        // Fresh multi-cast + primary stream so SSOT chrome observation tests start clean.
        await manager._test_resetEventsStreamForIsolation()
        await Task.yield()
        await Task.yield()
        _ = await manager.events
    }

    override func tearDown() async throws {
        await manager.cancelReplayForwarding()
        await MainActor.run {
            WidgetRefreshManager._test_setSuppressPlayerEventObservation(false)
        }
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        try await super.tearDown()
    }

    // MARK: - Pure policy matrix (authoritative table lock)

    /// Exhaustive pure-policy rows for in-app chrome. Individual tests below expand edge
    /// variants; this matrix is the single place that locks rows 1–8 as a complete set.
    ///
    /// Protects: sticky freeze is **intent**-gated; soft-resume residual visual promotes;
    /// Connecting / switch hold never invent green; soft-resume intermediate never invents
    /// Connecting; privacy / security / thermal stay authoritative; terminal stop keeps grey.
    func testPureChromePolicyMatrixRows1Through8() {
        struct Row {
            let name: String
            let status: PlayerStatus
            let reasonKey: String?
            let visual: PlayerVisualState
            let intent: PlaybackIntent
            let engineAudible: Bool
            let expected: PlayerVisualState
        }

        let rows: [Row] = [
            // 1 — Privacy clear
            Row(
                name: "1 privacy clear on connecting chatter",
                status: .stopped, reasonKey: "status_connecting",
                visual: .cleared, intent: .cleared, engineAudible: false,
                expected: .cleared
            ),
            Row(
                name: "1 privacy clear on late status_playing",
                status: .playing, reasonKey: "status_playing",
                visual: .cleared, intent: .cleared, engineAudible: true,
                expected: .cleared
            ),
            // 2 — True sticky pause
            Row(
                name: "2 sticky pause freezes late status_playing",
                status: .playing, reasonKey: "status_playing",
                visual: .userPaused, intent: .userPaused, engineAudible: false,
                expected: .userPaused
            ),
            Row(
                name: "2 sticky pause freezes while engine still audible",
                status: .playing, reasonKey: "status_playing",
                visual: .userPaused, intent: .userPaused, engineAudible: true,
                expected: .userPaused
            ),
            // 3 — Soft-resume hold promote
            Row(
                name: "3 soft-resume hold promote on status_playing + audible",
                status: .playing, reasonKey: "status_playing",
                visual: .userPaused, intent: .shouldBePlaying, engineAudible: true,
                expected: .playing
            ),
            Row(
                name: "3 soft-resume hold promote on status_playing without engine flag",
                status: .playing, reasonKey: "status_playing",
                visual: .userPaused, intent: .shouldBePlaying, engineAudible: false,
                expected: .playing
            ),
            Row(
                name: "3 soft-resume hold promote via engine audible on buffer chatter",
                status: .stopped, reasonKey: "status_buffering",
                visual: .userPaused, intent: .shouldBePlaying, engineAudible: true,
                expected: .playing
            ),
            Row(
                name: "3 soft-resume intermediate stays grey (no invented Connecting)",
                status: .playing, reasonKey: "status_connecting",
                visual: .userPaused, intent: .shouldBePlaying, engineAudible: false,
                expected: .userPaused
            ),
            // 4 — Connecting race
            Row(
                name: "4 Connecting race promote prePlay → playing",
                status: .playing, reasonKey: "status_playing",
                visual: .prePlay, intent: .shouldBePlaying, engineAudible: true,
                expected: .playing
            ),
            // 5 — True Connecting
            Row(
                name: "5 true Connecting holds prePlay while silent",
                status: .playing, reasonKey: "status_connecting",
                visual: .prePlay, intent: .shouldBePlaying, engineAudible: false,
                expected: .prePlay
            ),
            // 6 — Switch hold
            Row(
                name: "6 switch hold holds prePlay on buffering while silent",
                status: .stopped, reasonKey: "status_buffering",
                visual: .prePlay, intent: .shouldBePlaying, engineAudible: false,
                expected: .prePlay
            ),
            // 7 — Policy chrome
            Row(
                name: "7 security locked against late status_playing",
                status: .playing, reasonKey: "status_playing",
                visual: .securityLocked, intent: .securityLocked, engineAudible: true,
                expected: .securityLocked
            ),
            Row(
                name: "7 thermal paused against late status_playing",
                status: .playing, reasonKey: "status_playing",
                visual: .thermalPaused, intent: .shouldBePlaying, engineAudible: true,
                expected: .thermalPaused
            ),
            // 8 — Terminal stop / pause while sticky
            Row(
                name: "8 terminal status_stopped keeps sticky grey",
                status: .stopped, reasonKey: "status_stopped",
                visual: .userPaused, intent: .userPaused, engineAudible: false,
                expected: .userPaused
            ),
            Row(
                name: "8 terminal status_paused keeps sticky grey",
                status: .paused, reasonKey: "status_paused",
                visual: .userPaused, intent: .userPaused, engineAudible: false,
                expected: .userPaused
            ),
        ]

        for row in rows {
            let resolved = RadioPlayerChromeVisualResolver.resolve(
                status: row.status,
                reasonKey: row.reasonKey,
                visualState: row.visual,
                playbackIntent: row.intent,
                engineIsActuallyPlaying: row.engineAudible
            )
            XCTAssertEqual(resolved, row.expected, row.name)
        }
    }

    // MARK: - Pure policy: soft-resume hold promote (residual userPaused + active intent)

    /// Soft-resume hold: residual `.userPaused` visual + active intent + `status_playing` → `.playing`.
    /// Sticky freeze must require sticky **intent**, not residual visual alone.
    func testResolverPromotesSoftResumeHoldUserPausedToPlayingOnStatusPlaying() {
        let resolved = RadioPlayerChromeVisualResolver.resolve(
            status: .playing,
            reasonKey: "status_playing",
            visualState: .userPaused,
            playbackIntent: .shouldBePlaying,
            engineIsActuallyPlaying: true
        )
        XCTAssertEqual(
            resolved,
            .playing,
            "Soft-resume hold residual .userPaused visual must not freeze chrome after audible start when intent is active"
        )
    }

    /// Soft-resume hold promote still applies when sleep-timer intent is the active play intent.
    func testResolverPromotesSoftResumeHoldWithSleepTimerIntentOnStatusPlaying() {
        let resolved = RadioPlayerChromeVisualResolver.resolve(
            status: .playing,
            reasonKey: "status_playing",
            visualState: .userPaused,
            playbackIntent: .sleepTimer,
            engineIsActuallyPlaying: true
        )
        XCTAssertEqual(resolved, .playing)
    }

    /// Authoritative `status_playing` alone promotes soft-resume hold even if engine flag is false
    /// (status path is the race lead; engine sample may lag one hop).
    func testResolverPromotesSoftResumeHoldOnStatusPlayingWithoutEngineFlag() {
        let resolved = RadioPlayerChromeVisualResolver.resolve(
            status: .playing,
            reasonKey: "status_playing",
            visualState: .userPaused,
            playbackIntent: .shouldBePlaying,
            engineIsActuallyPlaying: false
        )
        XCTAssertEqual(resolved, .playing)
    }

    /// Engine-audible truth + active intent promotes soft-resume hold on buffer chatter
    /// without waiting for a second `status_playing` emission.
    func testResolverPromotesSoftResumeHoldOnBufferingWhileEngineAudible() {
        let resolved = RadioPlayerChromeVisualResolver.resolve(
            status: .stopped,
            reasonKey: "status_buffering",
            visualState: .userPaused,
            playbackIntent: .shouldBePlaying,
            engineIsActuallyPlaying: true
        )
        XCTAssertEqual(
            resolved,
            .playing,
            "Soft-resume hold must promote when engine is already audible during buffer chatter"
        )
    }

    /// Soft-resume intermediate (active intent, residual grey, engine not yet audible) stays grey —
    /// must not invent Connecting yellow (soft-resume Connecting skip honesty).
    func testResolverHoldsSoftResumeIntermediateUserPausedOnConnectingWhileSilent() {
        let resolved = RadioPlayerChromeVisualResolver.resolve(
            status: .playing,
            reasonKey: "status_connecting",
            visualState: .userPaused,
            playbackIntent: .shouldBePlaying,
            engineIsActuallyPlaying: false
        )
        XCTAssertEqual(
            resolved,
            .userPaused,
            "Soft-resume hold intermediate must keep residual pause chrome; never invent Connecting before audible start"
        )
    }

    // MARK: - Pure policy: authoritative playing vs deferred Connecting

    /// Engine `status_playing` while SPM still holds deferred Connecting must promote chrome to `.playing`.
    func testResolverPromotesPrePlayToPlayingOnStatusPlaying() {
        let resolved = RadioPlayerChromeVisualResolver.resolve(
            status: .playing,
            reasonKey: "status_playing",
            visualState: .prePlay,
            playbackIntent: .shouldBePlaying,
            engineIsActuallyPlaying: true
        )
        XCTAssertEqual(
            resolved,
            .playing,
            "status_playing must not freeze Connecting chrome after audible start (deferred setPlaying race)"
        )
    }

    /// Same promotion when SPM already flipped (setPlaying won the race).
    func testResolverKeepsPlayingWhenSPMAlreadyPlaying() {
        let resolved = RadioPlayerChromeVisualResolver.resolve(
            status: .playing,
            reasonKey: "status_playing",
            visualState: .playing,
            playbackIntent: .shouldBePlaying,
            engineIsActuallyPlaying: true
        )
        XCTAssertEqual(resolved, .playing)
    }

    /// True Connecting must remain yellow until audible start.
    func testResolverHoldsPrePlayOnStatusConnecting() {
        let resolved = RadioPlayerChromeVisualResolver.resolve(
            status: .playing, // connecting is emitted with isPlaying:true → .playing status
            reasonKey: "status_connecting",
            visualState: .prePlay,
            playbackIntent: .shouldBePlaying,
            engineIsActuallyPlaying: false
        )
        XCTAssertEqual(
            resolved,
            .prePlay,
            "status_connecting must keep Connecting chrome while engine is not yet audible"
        )
    }

    /// Stream-switch hold: silent attach keeps Connecting; never invent green mid-switch.
    func testResolverHoldsPrePlayOnSwitchHoldWhileEngineSilent() {
        let resolved = RadioPlayerChromeVisualResolver.resolve(
            status: .stopped,
            reasonKey: "status_buffering",
            visualState: .prePlay,
            playbackIntent: .shouldBePlaying,
            engineIsActuallyPlaying: false
        )
        XCTAssertEqual(
            resolved,
            .prePlay,
            "Stream-switch / attach hold must keep Connecting until engine is audible"
        )
    }

    /// Buffering while engine is already audible and SPM still prePlay must not re-stick yellow.
    func testResolverKeepsPlayingOnBufferingDuringDeferredSetPlayingRace() {
        let resolved = RadioPlayerChromeVisualResolver.resolve(
            status: .stopped,
            reasonKey: "status_buffering",
            visualState: .prePlay,
            playbackIntent: .shouldBePlaying,
            engineIsActuallyPlaying: true
        )
        XCTAssertEqual(
            resolved,
            .playing,
            "Buffering chatter during deferred setPlaying must not re-stick Connecting while audio is live"
        )
    }

    /// Buffering during true attach (engine silent) keeps Connecting.
    func testResolverHoldsPrePlayOnBufferingWhileEngineSilent() {
        let resolved = RadioPlayerChromeVisualResolver.resolve(
            status: .stopped,
            reasonKey: "status_buffering",
            visualState: .prePlay,
            playbackIntent: .shouldBePlaying,
            engineIsActuallyPlaying: false
        )
        XCTAssertEqual(resolved, .prePlay)
    }

    // MARK: - Pure policy: sticky pause + privacy clear + security / thermal

    /// Sticky user pause wins over a late status_playing (engine kick should already be suppressed).
    func testResolverPreservesUserPausedOnLateStatusPlaying() {
        let resolved = RadioPlayerChromeVisualResolver.resolve(
            status: .playing,
            reasonKey: "status_playing",
            visualState: .userPaused,
            playbackIntent: .userPaused,
            engineIsActuallyPlaying: false
        )
        XCTAssertEqual(resolved, .userPaused)
    }

    /// Sticky pause still freezes even when engine samples as audible (late chatter after pause).
    func testResolverPreservesUserPausedOnLateStatusPlayingWhileEngineAudible() {
        let resolved = RadioPlayerChromeVisualResolver.resolve(
            status: .playing,
            reasonKey: "status_playing",
            visualState: .userPaused,
            playbackIntent: .userPaused,
            engineIsActuallyPlaying: true
        )
        XCTAssertEqual(
            resolved,
            .userPaused,
            "Sticky pause intent must freeze chrome even when engine still reports audible briefly"
        )
    }

    /// Terminal stop while paused must not regress grey → yellow Connecting.
    func testResolverPreservesUserPausedOnStatusStopped() {
        let resolved = RadioPlayerChromeVisualResolver.resolve(
            status: .stopped,
            reasonKey: "status_stopped",
            visualState: .userPaused,
            playbackIntent: .userPaused,
            engineIsActuallyPlaying: false
        )
        XCTAssertEqual(resolved, .userPaused)
    }

    /// Privacy clear intent keeps blue `.cleared` through residual engine chatter.
    func testResolverPreservesClearedIntentOnConnectingChatter() {
        let resolved = RadioPlayerChromeVisualResolver.resolve(
            status: .stopped,
            reasonKey: "status_connecting",
            visualState: .cleared,
            playbackIntent: .cleared,
            engineIsActuallyPlaying: false
        )
        XCTAssertEqual(resolved, .cleared)
    }

    /// Security lock chrome is not overwritten by late status_playing.
    func testResolverPreservesSecurityLockedOnStatusPlaying() {
        let resolved = RadioPlayerChromeVisualResolver.resolve(
            status: .playing,
            reasonKey: "status_playing",
            visualState: .securityLocked,
            playbackIntent: .securityLocked,
            engineIsActuallyPlaying: false
        )
        XCTAssertEqual(resolved, .securityLocked)
    }

    /// Thermal policy chrome is not overwritten by late status_playing.
    func testResolverPreservesThermalPausedOnStatusPlaying() {
        let resolved = RadioPlayerChromeVisualResolver.resolve(
            status: .playing,
            reasonKey: "status_playing",
            visualState: .thermalPaused,
            playbackIntent: .shouldBePlaying,
            engineIsActuallyPlaying: false
        )
        XCTAssertEqual(resolved, .thermalPaused)
    }

    // MARK: - Status-path supersession gate (demoted adapter)

    /// Race lead remains allowed: pure policy promotes `.playing` while SPM still holds Connecting.
    func testStatusPathChromePaintAllowsConnectingRaceLead() {
        let allowed = RadioPlayerChromeVisualResolver.shouldApplyStatusPathChromePaint(
            policyResult: .playing,
            latestVisual: .prePlay,
            latestIntent: .shouldBePlaying,
            lastApplied: .prePlay
        )
        XCTAssertTrue(
            allowed,
            "Status adapter must still race-lead promote while SPM holds .prePlay under active intent"
        )
    }

    /// Race lead remains allowed: soft-resume residual `.userPaused` + active intent → promote.
    func testStatusPathChromePaintAllowsSoftResumeHoldRaceLead() {
        let allowed = RadioPlayerChromeVisualResolver.shouldApplyStatusPathChromePaint(
            policyResult: .playing,
            latestVisual: .userPaused,
            latestIntent: .shouldBePlaying,
            lastApplied: .userPaused
        )
        XCTAssertTrue(
            allowed,
            "Status adapter must still race-lead promote soft-resume hold residual under active intent"
        )
    }

    /// Settled SSOT chrome matching SPM `.playing` must not be overwritten by a divergent policy.
    func testStatusPathChromePaintBlocksDivergentResultWhenSSOTSettled() {
        let allowed = RadioPlayerChromeVisualResolver.shouldApplyStatusPathChromePaint(
            policyResult: .prePlay,
            latestVisual: .playing,
            latestIntent: .shouldBePlaying,
            lastApplied: .playing
        )
        XCTAssertFalse(
            allowed,
            "Status adapter must not regress settled SSOT .playing chrome with a divergent pure-policy result"
        )
    }

    /// Settled sticky pause chrome: policy agreeing with SSOT may paint (updateUI dedupes).
    func testStatusPathChromePaintAllowsIdempotentStickyWhenSSOTSettled() {
        let allowed = RadioPlayerChromeVisualResolver.shouldApplyStatusPathChromePaint(
            policyResult: .userPaused,
            latestVisual: .userPaused,
            latestIntent: .userPaused,
            lastApplied: .userPaused
        )
        XCTAssertTrue(
            allowed,
            "Identical pure-policy sticky result against settled SSOT is allowed (updateUI no-op)"
        )
    }

    /// Chrome lags SSOT: status may paint pure policy (including catch-up / sticky freeze).
    func testStatusPathChromePaintAllowsWhenChromeLagsSSOT() {
        let allowed = RadioPlayerChromeVisualResolver.shouldApplyStatusPathChromePaint(
            policyResult: .userPaused,
            latestVisual: .userPaused,
            latestIntent: .userPaused,
            lastApplied: .playing
        )
        XCTAssertTrue(
            allowed,
            "When chrome lags SPM SSOT, status pure policy may correct toward sticky pause"
        )
    }

    // MARK: - Coordinator integration: handleStatusChange → PlayerViewModel

    /// Simulates the deferred-setPlaying race: SPM still `.prePlay`, engine reports `status_playing`.
    /// In-app VM chrome must apply `.playing` (not skip as already-applied prePlay).
    func testHandleStatusChangeAppliesPlayingWhileSPMStillPrePlay() async {
        // Arrange: Connecting chrome + active intent (mirrors first-play attach hold).
        await manager.setUserIntentToPlay()
        // Force visual to prePlay without calling setPlaying (deferred Connecting window).
        await manager.setVisualState(.prePlay)

        let coordinator = RadioPlayerCoordinator(
            backgroundImageController: BackgroundImageController(),
            streamingPlayer: DirectStreamingPlayer.shared
        )
        let viewModel = PlayerViewModel()
        coordinator.viewModel = viewModel
        // Seed chrome as Connecting so updateUI is not a no-op when promoting to playing.
        coordinator.updateUI(for: .prePlay)
        XCTAssertEqual(viewModel.visualState, .prePlay)

        // Act: engine status_playing while SPM visual is still prePlay.
        await coordinator.handleStatusChange(.playing, reasonKey: "status_playing")

        // Assert: in-app chrome follows audible start even though SPM may still be prePlay.
        XCTAssertEqual(
            viewModel.visualState,
            .playing,
            "handleStatusChange must apply .playing chrome when engine reports status_playing during deferred setPlaying"
        )

        let spmVisual = await manager.currentVisualState
        // SPM may still be prePlay in this simulated race (we did not call setPlaying).
        XCTAssertEqual(spmVisual, .prePlay, "Test fixture must leave SPM at deferred Connecting")
    }

    /// Soft-resume hold via status path: residual SPM `.userPaused` + active intent + status_playing
    /// must paint green (policy promote), not leave grey pause chrome.
    func testHandleStatusChangePromotesSoftResumeHoldUserPausedToPlaying() async {
        await manager.setUserIntentToPlay()
        // Soft-resume intermediate: sticky visual retained until setPlaying; intent already active.
        await manager.setVisualState(.userPaused)

        let coordinator = RadioPlayerCoordinator(
            backgroundImageController: BackgroundImageController(),
            streamingPlayer: DirectStreamingPlayer.shared
        )
        let viewModel = PlayerViewModel()
        coordinator.viewModel = viewModel
        coordinator.updateUI(for: .userPaused)
        XCTAssertEqual(viewModel.visualState, .userPaused)

        await coordinator.handleStatusChange(.playing, reasonKey: "status_playing")

        XCTAssertEqual(
            viewModel.visualState,
            .playing,
            "handleStatusChange must promote soft-resume hold residual .userPaused chrome when intent is active and engine reports status_playing"
        )
        let spmVisual = await manager.currentVisualState
        XCTAssertEqual(spmVisual, .userPaused, "Test fixture must leave SPM at soft-resume residual visual until setPlaying")
    }

    /// Sticky pause via status path: late `status_playing` must not resurrect green when intent is still paused.
    /// Contrasts soft-resume hold promote (active intent) — freeze is intent-gated, not residual-visual-only.
    func testHandleStatusChangePreservesStickyPauseOnLateStatusPlaying() async {
        await manager.setUserPaused()

        let coordinator = RadioPlayerCoordinator(
            backgroundImageController: BackgroundImageController(),
            streamingPlayer: DirectStreamingPlayer.shared
        )
        let viewModel = PlayerViewModel()
        coordinator.viewModel = viewModel
        coordinator.updateUI(for: .userPaused)
        XCTAssertEqual(viewModel.visualState, .userPaused)

        await coordinator.handleStatusChange(.playing, reasonKey: "status_playing")

        XCTAssertEqual(
            viewModel.visualState,
            .userPaused,
            "handleStatusChange must keep sticky pause chrome when intent is still .userPaused despite late status_playing"
        )
        let intent = await manager.currentPlaybackIntent
        XCTAssertEqual(intent, .userPaused, "Test fixture must leave sticky pause intent")
    }

    /// After setPlaying, a follow-on status_playing keeps chrome at playing (idempotent).
    func testHandleStatusChangeKeepsPlayingAfterSetPlaying() async {
        await manager.setUserIntentToPlay()
        await manager.setPlaying()

        let coordinator = RadioPlayerCoordinator(
            backgroundImageController: BackgroundImageController(),
            streamingPlayer: DirectStreamingPlayer.shared
        )
        let viewModel = PlayerViewModel()
        coordinator.viewModel = viewModel
        coordinator.updateUI(for: .playing)

        await coordinator.handleStatusChange(.playing, reasonKey: "status_playing")

        XCTAssertEqual(viewModel.visualState, .playing)
        let spmVisual = await manager.currentVisualState
        XCTAssertEqual(spmVisual, .playing)
    }

    /// Status demotion: after SSOT settled to `.playing`, a status path that would propose a
    /// divergent chrome must not regress the pill (status is race lead + errors, not sole SSOT).
    ///
    /// Integration uses sticky-pause freeze (policy agrees) for the positive path above; this
    /// case seeds settled `.playing` chrome + SPM and proves late `status_playing` stays green
    /// without thrash — supersession pure tests cover divergent-block; race-lead tests cover promote.
    func testHandleStatusChangeDoesNotThrashSettledPlayingChrome() async {
        await manager.setUserIntentToPlay()
        await manager.setPlaying()

        let coordinator = RadioPlayerCoordinator(
            backgroundImageController: BackgroundImageController(),
            streamingPlayer: DirectStreamingPlayer.shared
        )
        let viewModel = PlayerViewModel()
        coordinator.viewModel = viewModel
        coordinator.updateUI(for: .playing)
        XCTAssertEqual(coordinator.lastAppliedVisualState, .playing)

        await coordinator.handleStatusChange(.playing, reasonKey: "status_playing")

        XCTAssertEqual(viewModel.visualState, .playing)
        XCTAssertEqual(coordinator.lastAppliedVisualState, .playing)
    }

    /// Sticky pause: status_stopped must not paint Connecting yellow.
    func testHandleStatusChangePreservesUserPausedOnStop() async {
        await manager.setUserPaused()

        let coordinator = RadioPlayerCoordinator(
            backgroundImageController: BackgroundImageController(),
            streamingPlayer: DirectStreamingPlayer.shared
        )
        let viewModel = PlayerViewModel()
        coordinator.viewModel = viewModel
        coordinator.updateUI(for: .userPaused)

        await coordinator.handleStatusChange(.stopped, reasonKey: "status_stopped")

        XCTAssertEqual(viewModel.visualState, .userPaused)
    }

    // MARK: - Coordinator integration: visual SSOT paint (no status path)

    /// Soft-resume hold closes via visual SSOT: after residual `.userPaused` + active intent,
    /// ``setPlaying()`` must paint main chrome `.playing` **without** ``handleStatusChange``.
    ///
    /// Protects the stuck-grey class where status is raced, suppressed, or last-value-deduped
    /// after the actor is already `.playing`. Production paint follows
    /// ``PlayerEvent/visualStateDidChange`` observed by the coordinator.
    func testSetPlayingPaintsMainChromeViaVisualSSOTWithoutStatusPath() async {
        await manager.setUserIntentToPlay()
        // Soft-resume intermediate: residual sticky visual until setPlaying; intent active.
        await manager.setVisualState(.userPaused)

        let coordinator = RadioPlayerCoordinator(
            backgroundImageController: BackgroundImageController(),
            streamingPlayer: DirectStreamingPlayer.shared
        )
        let viewModel = PlayerViewModel()
        coordinator.viewModel = viewModel
        coordinator.updateUI(for: .userPaused)
        XCTAssertEqual(viewModel.visualState, .userPaused)
        XCTAssertEqual(coordinator.lastAppliedVisualState, .userPaused)

        // Attach SSOT chrome observation (multi-cast replay — no status hop).
        await coordinator.beginObservingVisualStateForChrome()
        // Prefix may re-apply residual .userPaused (deduped). Chrome still grey.
        XCTAssertEqual(viewModel.visualState, .userPaused)

        // Act: authoritative setPlaying without any handleStatusChange delivery.
        await manager.setPlaying()

        // Allow multi-cast live yield → MainActor handler.
        await Task.yield()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(
            viewModel.visualState,
            .playing,
            "setPlaying must paint main chrome .playing via visualStateDidChange without handleStatusChange"
        )
        XCTAssertEqual(coordinator.lastAppliedVisualState, .playing)
        let spmVisual = await manager.currentVisualState
        XCTAssertEqual(spmVisual, .playing)

        coordinator.stopObservingVisualStateForChrome()
    }

    /// Explicit sticky pause still paints grey via visual SSOT observation (no status path).
    func testSetUserPausedPaintsMainChromeViaVisualSSOTWithoutStatusPath() async {
        await manager.setUserIntentToPlay()
        await manager.setPlaying()

        let coordinator = RadioPlayerCoordinator(
            backgroundImageController: BackgroundImageController(),
            streamingPlayer: DirectStreamingPlayer.shared
        )
        let viewModel = PlayerViewModel()
        coordinator.viewModel = viewModel
        coordinator.updateUI(for: .playing)
        XCTAssertEqual(viewModel.visualState, .playing)

        await coordinator.beginObservingVisualStateForChrome()
        // Prefix applies current .playing (deduped).
        XCTAssertEqual(viewModel.visualState, .playing)

        await manager.setUserPaused()

        await Task.yield()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(
            viewModel.visualState,
            .userPaused,
            "setUserPaused must paint main chrome .userPaused via visualStateDidChange without handleStatusChange"
        )
        XCTAssertEqual(coordinator.lastAppliedVisualState, .userPaused)

        coordinator.stopObservingVisualStateForChrome()
    }

    /// White-box: ``handleVisualChromePlayerEvent`` applies carried visual without SPM mutation.
    func testVisualChromeHandlerAppliesCarriedVisualDirectly() async {
        let coordinator = RadioPlayerCoordinator(
            backgroundImageController: BackgroundImageController(),
            streamingPlayer: DirectStreamingPlayer.shared
        )
        let viewModel = PlayerViewModel()
        coordinator.viewModel = viewModel
        coordinator.updateUI(for: .userPaused)

        await coordinator._test_applyVisualChromePlayerEvent(.visualStateDidChange(.playing))

        XCTAssertEqual(viewModel.visualState, .playing)
        XCTAssertEqual(coordinator.lastAppliedVisualState, .playing)

        // Non-visual events must not paint.
        await coordinator._test_applyVisualChromePlayerEvent(.streamDidStart)
        XCTAssertEqual(viewModel.visualState, .playing, "Non-visual events must not change chrome")
    }

    /// Explicit ``stop()`` paints sticky grey via visual SSOT observation (no status path).
    /// Completes the pause/stop paint contract alongside ``setUserPaused``.
    func testStopPaintsMainChromeViaVisualSSOTWithoutStatusPath() async {
        await manager.setUserIntentToPlay()
        await manager.setPlaying()

        let coordinator = RadioPlayerCoordinator(
            backgroundImageController: BackgroundImageController(),
            streamingPlayer: DirectStreamingPlayer.shared
        )
        let viewModel = PlayerViewModel()
        coordinator.viewModel = viewModel
        coordinator.updateUI(for: .playing)
        XCTAssertEqual(viewModel.visualState, .playing)

        await coordinator.beginObservingVisualStateForChrome()
        XCTAssertEqual(viewModel.visualState, .playing)

        // Act: stop locks visual + intent to sticky pause and emits visualStateDidChange.
        await manager.stop()

        await Task.yield()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(
            viewModel.visualState,
            .userPaused,
            "stop must paint main chrome .userPaused via visualStateDidChange without handleStatusChange"
        )
        XCTAssertEqual(coordinator.lastAppliedVisualState, .userPaused)
        let spmVisual = await manager.currentVisualState
        XCTAssertEqual(spmVisual, .userPaused)
        let intent = await manager.currentPlaybackIntent
        XCTAssertEqual(intent, .userPaused)

        coordinator.stopObservingVisualStateForChrome()
    }

    // MARK: - Coordinator integration: status-path hold honesty (Connecting / switch)

    /// True Connecting via status path: `status_connecting` while SPM is `.prePlay` and
    /// engine is not audible must keep yellow — never invent green mid-attach.
    func testHandleStatusChangeHoldsPrePlayOnTrueConnecting() async {
        await manager.setUserIntentToPlay()
        await manager.setVisualState(.prePlay)

        let coordinator = RadioPlayerCoordinator(
            backgroundImageController: BackgroundImageController(),
            streamingPlayer: DirectStreamingPlayer.shared
        )
        let viewModel = PlayerViewModel()
        coordinator.viewModel = viewModel
        coordinator.updateUI(for: .prePlay)
        XCTAssertEqual(viewModel.visualState, .prePlay)

        // connecting is delivered with isPlaying:true → PlayerStatus.playing; reasonKey is truth.
        await coordinator.handleStatusChange(.playing, reasonKey: "status_connecting")

        XCTAssertEqual(
            viewModel.visualState,
            .prePlay,
            "handleStatusChange must keep Connecting chrome on status_connecting while engine is not audible"
        )
        let spmVisual = await manager.currentVisualState
        XCTAssertEqual(spmVisual, .prePlay)
    }

    /// Stream-switch / attach hold via status path: silent buffering must not invent green.
    func testHandleStatusChangeHoldsPrePlayOnSwitchHoldBuffering() async {
        await manager.setUserIntentToPlay()
        await manager.setVisualState(.prePlay)

        let coordinator = RadioPlayerCoordinator(
            backgroundImageController: BackgroundImageController(),
            streamingPlayer: DirectStreamingPlayer.shared
        )
        let viewModel = PlayerViewModel()
        coordinator.viewModel = viewModel
        coordinator.updateUI(for: .prePlay)

        await coordinator.handleStatusChange(.stopped, reasonKey: "status_buffering")

        XCTAssertEqual(
            viewModel.visualState,
            .prePlay,
            "handleStatusChange must keep Connecting chrome during silent switch/attach buffer chatter"
        )
    }

    /// Soft-resume intermediate via status path: residual grey + active intent + connecting
    /// chatter (not audible) must stay grey — never invent Connecting yellow to "fix" hold.
    func testHandleStatusChangeHoldsSoftResumeIntermediateOnConnectingChatter() async {
        await manager.setUserIntentToPlay()
        await manager.setVisualState(.userPaused)

        let coordinator = RadioPlayerCoordinator(
            backgroundImageController: BackgroundImageController(),
            streamingPlayer: DirectStreamingPlayer.shared
        )
        let viewModel = PlayerViewModel()
        coordinator.viewModel = viewModel
        coordinator.updateUI(for: .userPaused)

        await coordinator.handleStatusChange(.playing, reasonKey: "status_connecting")

        XCTAssertEqual(
            viewModel.visualState,
            .userPaused,
            "Soft-resume intermediate must keep residual pause chrome on connecting chatter; never invent Connecting"
        )
        let spmVisual = await manager.currentVisualState
        XCTAssertEqual(spmVisual, .userPaused)
    }

    /// Status supersession integration: when chrome already matches settled SPM `.playing`,
    /// a late `status_playing` must remain green (idempotent; no thrash to Connecting).
    /// Divergent-block pure gate is covered by ``testStatusPathChromePaintBlocksDivergentResultWhenSSOTSettled``.
    func testHandleStatusChangeKeepsSettledPlayingAgainstLateConnectingKey() async {
        await manager.setUserIntentToPlay()
        await manager.setPlaying()

        let coordinator = RadioPlayerCoordinator(
            backgroundImageController: BackgroundImageController(),
            streamingPlayer: DirectStreamingPlayer.shared
        )
        let viewModel = PlayerViewModel()
        coordinator.viewModel = viewModel
        coordinator.updateUI(for: .playing)
        XCTAssertEqual(coordinator.lastAppliedVisualState, .playing)

        // Late connecting key after setPlaying: pure policy with SPM .playing preserves .playing
        // through buffer/connecting chatter; status may paint idempotent .playing (deduped).
        await coordinator.handleStatusChange(.playing, reasonKey: "status_connecting")

        XCTAssertEqual(
            viewModel.visualState,
            .playing,
            "Settled SSOT .playing chrome must not regress to Connecting on late status_connecting chatter"
        )
        XCTAssertEqual(coordinator.lastAppliedVisualState, .playing)
    }
}
