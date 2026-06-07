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
}
