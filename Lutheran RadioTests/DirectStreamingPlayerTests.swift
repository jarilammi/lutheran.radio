//
//  DirectStreamingPlayerTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 15.3.2025.
//

import XCTest
import AVFoundation
@testable import Lutheran_Radio

final class TestDirectStreamingPlayer: DirectStreamingPlayer, @unchecked Sendable {
    var didCallPlay = false
    var didCallStop = false
    var playCompletion: ((Bool) -> Void)?
    var simulatedStatus: AVPlayerItem.Status?

    override func play(completion: @escaping (Bool) -> Void) {
        didCallPlay = true
        playCompletion = completion
        let mockURL = URL(string: "https://test.stream/test.mp3")!
        player = AVPlayer()
        let asset = AVURLAsset(url: mockURL)
        playerItem = AVPlayerItem(asset: asset)
        player?.replaceCurrentItem(with: playerItem)
        if let status = simulatedStatus {
            simulateStatusChange(status)
        }
        if simulatedStatus == .readyToPlay {
            completion(true)
        } else if simulatedStatus == .failed {
            completion(false)
        }
    }

    override func stop() {
        didCallStop = true
        super.stop()
    }

    func simulateStatusChange(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            onStatusChange?(true, String(localized: "status_playing"))
        case .failed:
            onStatusChange?(false, String(localized: "status_stream_unavailable"))
        case .unknown:
            onStatusChange?(false, String(localized: "status_buffering"))
        @unknown default:
            break
        }
    }
}

@MainActor
class DirectStreamingPlayerTests: XCTestCase {
    var player: TestDirectStreamingPlayer!

    override func setUp() {
        super.setUp()
        player = TestDirectStreamingPlayer()
    }

    override func tearDown() {
        player.stop()
        player = nil
        super.tearDown()
    }

    func testInitializationSelectsLocaleStream() {
        let currentLocale = Locale.current
        let languageCode = currentLocale.language.languageCode?.identifier ?? "en"
        let expectedStream = DirectStreamingPlayer.availableStreams.first { $0.languageCode == languageCode }
            ?? DirectStreamingPlayer.availableStreams[0]
        
        var initialTitle: String?
        player.onMetadataChange = { title in
            initialTitle = title
        }
        
        XCTAssertEqual(initialTitle, expectedStream.title, "Initial stream should match locale or default to first stream")
    }

    func testPlaySetsUpPlayerAndCallsCompletion() {
        let expectation = self.expectation(description: "Play completes successfully")
        player.simulatedStatus = .readyToPlay

        var statusChangedToPlaying = false
        player.onStatusChange = { isPlaying, statusText in
            if isPlaying && statusText == String(localized: "status_playing") {
                statusChangedToPlaying = true
            }
        }

        player.play { success in
            XCTAssertTrue(success, "Completion should indicate success when ready to play")
            expectation.fulfill()
        }

        waitForExpectations(timeout: 1.0, handler: nil)
        XCTAssertTrue(player.didCallPlay, "Play method should be called")
        XCTAssertTrue(statusChangedToPlaying, "Status should change to playing")
    }

    func testStopRemovesObserversAndPauses() {
        player.simulatedStatus = .readyToPlay
        player.play { _ in }
        var statusStopped = false
        player.onStatusChange = { isPlaying, statusText in
            if !isPlaying && statusText == String(localized: "status_stopped") {
                statusStopped = true
            }
        }
        player.stop()

        XCTAssertTrue(player.didCallStop, "Stop method should be called")
        XCTAssertTrue(statusStopped, "Status should change to stopped")
    }

    func testSetStreamUpdatesStreamAndPlays() {
        let newStream = DirectStreamingPlayer.availableStreams[1]
        let expectation = self.expectation(description: "Stream switch completes")
        player.simulatedStatus = .readyToPlay

        var metadataChangedToNewStream = false
        player.onMetadataChange = { title in
            if title == newStream.title {
                metadataChangedToNewStream = true
            }
        }

        var statusChangedToPlaying = false
        player.onStatusChange = { isPlaying, statusText in
            if isPlaying && statusText == String(localized: "status_playing") {
                statusChangedToPlaying = true
            }
        }

        player.setStream(to: newStream)
        player.play { success in
            XCTAssertTrue(success, "Completion should indicate success")
            expectation.fulfill()
        }

        waitForExpectations(timeout: 1.0, handler: nil)
        XCTAssertTrue(metadataChangedToNewStream, "Metadata should reflect new stream")
        XCTAssertTrue(player.didCallPlay, "Play should be called after setting stream")
        XCTAssertTrue(statusChangedToPlaying, "Status should change to playing")
    }

    func testPlaybackFailureTriggersErrorStatus() {
        let expectation = self.expectation(description: "Handles playback failure")
        player.simulatedStatus = .failed

        var errorStatusReceived = false
        player.onStatusChange = { isPlaying, statusText in
            if !isPlaying && statusText == String(localized: "status_stream_unavailable") {
                errorStatusReceived = true
                expectation.fulfill()
            }
        }

        player.play { success in
            XCTAssertFalse(success, "Completion should indicate failure")
        }

        waitForExpectations(timeout: 1.0, handler: nil)
        XCTAssertTrue(errorStatusReceived, "Status should indicate stream unavailable")
    }
}
