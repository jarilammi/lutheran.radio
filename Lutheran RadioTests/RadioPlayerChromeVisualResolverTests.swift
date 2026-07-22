//
//  RadioPlayerChromeVisualResolverTests.swift
//  Lutheran RadioTests
//
//  Pure resolver + coordinator handleStatusChange chrome contracts for
//  Connecting-until-audible vs sticky pause / privacy clear.
//
//  Created by Jari Lammi on 22.7.2026.
//

import XCTest
import WidgetSurface
@testable import Lutheran_Radio

/// Asserts in-app chrome mapping after deferred ``setPlaying()`` / engine `status_playing`.
///
/// Protects the invariant that Connecting (`.prePlay`) chrome must not **stick** after the
/// engine reports authoritative audible play, while sticky `.userPaused` and privacy
/// `.cleared` remain protected on residual engine chatter.
///
/// Why pure + light integration:
/// - ``RadioPlayerChromeVisualResolver`` is side-effect free (fast, no AVPlayer / ActivityKit).
/// - ``handleStatusChange`` integration proves the coordinator applies the resolver into
///   ``PlayerViewModel`` without requiring a full streaming attach.
///
/// - SeeAlso: ``RadioPlayerChromeVisualResolver``, ``RadioPlayerCoordinator/handleStatusChange(_:reasonKey:)``,
///   ``SharedPlayerManager/setPlaying()``, CODING_AGENT.md (fast test patterns).
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
        }
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        await SharedPlayerManager.clearAllLocalState()
        await manager.setUserIntentToPlay()
    }

    override func tearDown() async throws {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        try await super.tearDown()
    }

    // MARK: - Pure resolver: authoritative playing vs deferred Connecting

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

    // MARK: - Pure resolver: sticky pause + privacy clear

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

    // MARK: - Coordinator integration: handleStatusChange → PlayerViewModel

    /// Simulates the deferred-setPlaying race: SPM still `.prePlay`, engine reports `status_playing`.
    /// In-app VM chrome must apply `.playing` (not skip as already-applied prePlay).
    func testHandleStatusChangeAppliesPlayingWhileSPMStillPrePlay() async {
        // Arrange: Connecting chrome + active intent (mirrors first-play / soft-resume hold).
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
}
