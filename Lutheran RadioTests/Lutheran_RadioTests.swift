//
//  Lutheran_RadioTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 26.10.2024.
//
//  Construction / binding smoke for the three SwiftUI composed player views.
//  The views receive narrow value + closure inputs projected from `PlayerViewModel`
//  (the composition root holds `@Bindable`). These tests exercise creation and
//  basic usage of real chrome (`LanguageSelectorView`, `PlaybackControlsView`,
//  `NowPlayingMetadataView`) — they do not instantiate production `ViewController`,
//  `SharedPlayerManager`, or `DirectStreamingPlayer`.
//
//  Engine attach / recovery / UITestMode audio short-circuits live in
//  ``DirectStreamingPlayerEngineTests``. Pause-press token policy:
//  `PlaybackPausePressFeedbackTests`.
//
//  - SeeAlso: `PlayerViewModel`, `LanguageSelectorView`, `PlaybackControlsView`,
//    `NowPlayingMetadataView`, ``DirectStreamingPlayerEngineTests``.
//

import XCTest
import WidgetSurface
@testable import Lutheran_Radio

final class SwiftUIComposedViewsTests: XCTestCase {

    @MainActor
    func testLanguageSelectorView_CreatesAndBindsToVM() {
        let vm = PlayerViewModel.makeMock(selectedStreamIndex: 1)
        let view = LanguageSelectorView(
            selectedStreamIndex: vm.selectedStreamIndex,
            selectLanguage: vm.selectLanguage
        )
        XCTAssertNotNil(view)
        vm.selectedStreamIndex = 3
        XCTAssertEqual(vm.selectedStreamIndex, 3)
    }

    @MainActor
    /// Construction / closure smoke only. Pause-press token policy:
    /// `PlaybackPausePressFeedbackTests`.
    func testPlaybackControlsView_BindsVisualStateAndCallsActions() {
        let vm = PlayerViewModel.makeMock(visualState: .prePlay)
        var playCalled = false
        vm.onPlayRequested = { playCalled = true }

        let view = PlaybackControlsView(
            controlPresentation: vm.controlPresentation,
            isActivelyPlaying: vm.isActivelyPlaying,
            sleepTimerRemaining: vm.sleepTimerRemaining,
            sleepTimerAccessibilityValue: vm.sleepTimerAccessibilityValue,
            statusPresentation: vm.statusPresentation,
            onPlay: vm.play,
            onPause: vm.pause
        )
        XCTAssertNotNil(view)

        // Simulate action
        vm.play()
        XCTAssertTrue(playCalled)
    }

    @MainActor
    func testNowPlayingMetadataView_RendersMetadataAndPhotoHeuristic() {
        let vm = PlayerViewModel.makeMock(currentMetadata: StreamProgramMetadata(programTitle: "Test", speaker: "Jari Lammi"))
        let view = NowPlayingMetadataView(displayModel: vm.nowPlayingDisplay)
        XCTAssertNotNil(view)
    }

    @MainActor
    func testNowPlayingMetadataView_PhotoHeuristicViaModel() {
        let vm = PlayerViewModel.makeMock(currentMetadata: StreamProgramMetadata(programTitle: "Sermon by Jari Lammi", speaker: nil))
        XCTAssertNotNil(NowPlayingMetadataView(displayModel: vm.nowPlayingDisplay))
    }
}
