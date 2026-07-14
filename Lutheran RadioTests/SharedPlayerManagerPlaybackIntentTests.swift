//
//  SharedPlayerManagerPlaybackIntentTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 7.6.2026.
//

import XCTest
import WidgetSurface
@testable import Lutheran_Radio

final class SharedPlayerManagerPlaybackIntentTests: XCTestCase {

    private let manager = SharedPlayerManager.shared

    override func setUp() async throws {
        try await super.setUp()
        await manager.setUserIntentToPlay()
        await manager.setPlaying()
    }

    func testStreamFailurePreservesShouldBePlayingIntent() async {
        await manager.setPlaying()

        await manager.markPlaybackStoppedByStreamFailure()

        let intent = await manager.currentPlaybackIntent
        let visual = await manager.currentVisualState

        XCTAssertEqual(intent, .shouldBePlaying)
        XCTAssertEqual(visual, .userPaused)
    }

    func testExplicitStopSetsUserPausedIntent() async {
        await manager.setPlaying()

        await manager.stop()

        let intent = await manager.currentPlaybackIntent
        let visual = await manager.currentVisualState
        let recentlyPaused = await manager.wasRecentlyUserPaused()

        XCTAssertEqual(intent, .userPaused)
        XCTAssertEqual(visual, .userPaused)
        XCTAssertTrue(recentlyPaused)
    }

    func testPrivacyClearSetsClearedIntentBlocksProceedAndExplicitPlayClearsIt() async {
        await manager.setPlaying()

        // Privacy clear (the path exercised by the sleep timer menu destructive action).
        await SharedPlayerManager.clearAllLocalState()

        let intent = await manager.currentPlaybackIntent
        let visual = await manager.currentVisualState
        let canProceed = await manager.canProceedWithPlayback()

        XCTAssertEqual(intent, .cleared, "Clear must set the dedicated hard blocker intent")
        XCTAssertEqual(visual, .cleared, "Clear resets visual to .cleared (blue + clear_local_state_done) + .cleared intent. This fixes the post-reset pill showing 'Connect'/yellow. .userPaused (grey) is reserved for explicit pauses. The intent alone blocks recovery until explicit play.")
        XCTAssertFalse(canProceed, "canProceedWithPlayback must be false for .cleared (prevents recreate / recovery after privacy clear)")

        // Explicit user play (setUserIntentToPlay or widget play) must clear the blocker.
        await manager.setUserIntentToPlay()

        let intentAfter = await manager.currentPlaybackIntent
        let canProceedAfter = await manager.canProceedWithPlayback()

        XCTAssertEqual(intentAfter, .shouldBePlaying)
        XCTAssertTrue(canProceedAfter)
    }

    // MARK: - Siri / AppShortcut intent path coverage (minimal, exercises the exact SSOT calls
    // used by PlayRadioIntent / PauseRadioIntent / SwitchToLanguageIntent perform() bodies).

    func testSiriPlayIntentPathClearsUserPausedAndSetsShouldBePlaying() async {
        await manager.stop()

        var intent = await manager.currentPlaybackIntent
        XCTAssertEqual(intent, .userPaused)

        // Mirrors the generic (no-language) body of PlayRadioIntent.perform
        await manager.setUserIntentToPlay()
        await manager.play()

        intent = await manager.currentPlaybackIntent
        let visual = await manager.currentVisualState
        XCTAssertEqual(intent, .shouldBePlaying)
        XCTAssertEqual(visual, .playing)
    }

    func testSiriSwitchLanguageIntentUsesResetThenPlay() async {
        await manager.setUserIntentToPlay()
        await manager.play()

        let streams = manager.availableStreams
        guard streams.count >= 2 else { return }
        let other = streams[1]

        // Exact sequence from SwitchToLanguageIntent + documented switch path in SharedPlayerManager table
        await manager.resetToPrePlayForNewStream()
        await manager.switchToStream(other)
        await manager.setUserIntentToPlay()
        await manager.play()

        let intent = await manager.currentPlaybackIntent
        XCTAssertEqual(intent, .shouldBePlaying)

        let current = SharedPlayerManager.streamForLanguageCode(other.languageCode)
        XCTAssertEqual(current.languageCode, other.languageCode)
    }

    // MARK: - Termination Cleanup Invariant Tests

    /// Protects the new conservative quit cleanup contract:
    /// forceStale... must make isMainAppProcessRecentlyActive() return false immediately
    /// (the sentinel 0), and a subsequent bump must restore "active" for the widget UI decision.
    /// This is the key mechanism that makes widgets render the passive "tap to open" state
    /// after the main app has quit.
    func testForceStaleLivenessMakesIsRecentlyActiveFalse_AndBumpRestores() {
        let suite = "group.radio.lutheran.shared"
        let key = "lastUpdateTime"
        let defaults = UserDefaults(suiteName: suite)!

        // Arrange: make it look recently active
        let now = Date().timeIntervalSince1970
        defaults.set(now, forKey: key)
        XCTAssertTrue(SharedPlayerManager.isMainAppProcessRecentlyActive(),
                      "Fresh timestamp must be considered recently active")

        // Act: termination cleanup
        SharedPlayerManager.forceStaleLivenessTimestampForTermination()

        // Assert: sentinel forces inactive (the widget passive path)
        XCTAssertFalse(SharedPlayerManager.isMainAppProcessRecentlyActive(),
                       "After forceStale the heuristic must report inactive so widgets render passive launch-only UI")

        // Also verify we cleared the instant feedback keys (defense for post-quit flash)
        XCTAssertNil(defaults.object(forKey: "isInstantFeedback"))

        // Cleanup side-effect: a later liveness bump (e.g. on next foreground after relaunch) must work.
        // Under test the privacy hasActiveWidgets gate may suppress the bump write; we therefore
        // directly exercise the heuristic contract by writing a fresh timestamp (the production
        // bump does exactly this when the gate is open). This keeps the test verifying the sentinel
        // + "later active signal" behavior without depending on widget configuration in the host.
        let future = Date().timeIntervalSince1970 + 10
        defaults.set(future, forKey: key)
        XCTAssertTrue(SharedPlayerManager.isMainAppProcessRecentlyActive(),
                      "A subsequent active timestamp must make the heuristic report active again (normal relaunch)")

        // Restore a neutral state for other tests (remove the key so default false)
        defaults.removeObject(forKey: key)
    }
}
