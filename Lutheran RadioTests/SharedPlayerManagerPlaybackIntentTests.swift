//
//  SharedPlayerManagerPlaybackIntentTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 7.6.2026.
//

import XCTest
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
        XCTAssertEqual(visual, .prePlay, "Clear resets visual to .prePlay (clean ready) + .cleared intent; .userPaused (grey) is reserved for explicit user pauses so post-clear cold launches and early status callbacks do not mix sticky paused state or produce transient yellow. The intent alone blocks recovery until explicit play or successful post-clear cold-start play.")
        XCTAssertFalse(canProceed, "canProceedWithPlayback must be false for .cleared (prevents recreate / recovery after privacy clear)")

        // Explicit user play (setUserIntentToPlay or widget play) must clear the blocker.
        await manager.setUserIntentToPlay()

        let intentAfter = await manager.currentPlaybackIntent
        let canProceedAfter = await manager.canProceedWithPlayback()

        XCTAssertEqual(intentAfter, .shouldBePlaying)
        XCTAssertTrue(canProceedAfter)
    }
}
