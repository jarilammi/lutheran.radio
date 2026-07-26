//
//  SharedPlayerManagerEventStreamSwitchTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 26.7.2026.
//
//  Stream-switch / language-change emission contracts on `SharedPlayerManager`.
//  Split from ``SharedPlayerManagerEventTests``; method names preserved.
//
//  Shared collectors: `Lutheran RadioTests/Support/PlayerEventTestSupport.swift`.
//  Isolation: ``prepareSharedPlayerManagerEventTestIsolation`` /
//  ``tearDownSharedPlayerManagerEventTestIsolation``.
//
//  - SeeAlso: ``SharedPlayerManager``, ``PlayerEvent``,
//    ``SharedPlayerManagerEventTests``,
//    docs/Event-Driven-Refactor-Roadmap.md,
//    CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
//

import MediaPlayer
import XCTest
import WidgetSurface
@testable import Lutheran_Radio

/// Language / stream-switch emission contracts for active and paused paths.
///
/// Covers ``resetToPrePlayForNewStream``, hold-time destination language mirrors,
/// and paused switch metadata clear without visual/intent mutation.
///
/// - SeeAlso: ``SharedPlayerManagerEventTests``,
///   ``targetStreamDifferentFromCurrent(in:)``,
///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
///   docs/Event-Driven-Refactor-Roadmap.md,
///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).

final class SharedPlayerManagerEventStreamSwitchTests: XCTestCase {

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

    /// Verifies the full active-intent language-switch path emission contract.
    ///
    /// Mirrors the resume branch of `RadioPlayerCoordinator.completeStreamSwitch` /
    /// `switchToStreamFromWidget`: ``resetToPrePlayForNewStream()`` (yellow `.prePlay` hold
    /// **before** engine silent stop), engine prep via ``switchToStream(_:)``, then successful
    /// attach via ``setPlaying()`` (stand-in for ``play()`` under UITestMode).
    ///
    /// **Reset phase:** `visualStateDidChange(.prePlay)` and metadata clear precede engine prep;
    /// intent stays `.shouldBePlaying` (no `playbackIntentChanged`, no stream verbs).
    ///
    /// **Resume phase:** `visualStateDidChange(.playing)` → `streamDidStart` → persist signal;
    /// intent still unchanged.
    ///
    /// Collection uses the DEBUG notification seam. Ordered subsequence matching tolerates
    /// extra `.persistedWidgetStateDidUpdate` / `.metadataDidUpdate(nil)` emissions from the
    /// hold path and engine silent-stop save.
    ///
    /// - SeeAlso: ``resetToPrePlayForNewStream(preserveActiveSleepTimer:connectingLanguageCode:)``,
    ///   ``switchToStream(_:)``, ``setPlaying()``, ``isStreamSwitchPrePlayHoldActive``,
    ///   `RadioPlayerCoordinator.completeStreamSwitch`,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5),
    ///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
    func testActiveLanguageSwitchResetThenResumeEmissionOrderPreservesIntent() async {
        let streams = manager.availableStreams
        guard streams.count >= 2 else { return }
        let other = await targetStreamDifferentFromCurrent(in: streams)

        await manager.setPlaying()
        let intentBefore = await manager.currentPlaybackIntent
        XCTAssertEqual(
            intentBefore,
            .shouldBePlaying,
            "Precondition: active switch path preserves an already-active playback intent"
        )

        let m = self.manager
        let liveEmissions = await collectSeamEvents(minimumCount: 4, timeout: 8.0) {
            await m.resetToPrePlayForNewStream()
            await m.switchToStream(other)
            await m.setPlaying()
        }

        assertEvents(liveEmissions, containInOrder: [
            { if case .visualStateDidChange(.prePlay) = $0 { return true }; return false },
            { if case .visualStateDidChange(.playing) = $0 { return true }; return false },
            { if case .streamDidStart = $0 { return true }; return false },
        ])
        XCTAssertTrue(
            liveEmissions.contains(.persistedWidgetStateDidUpdate),
            "Active switch path should persist at least once; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .playbackIntentChanged = $0 { return true }; return false },
            "Active language switch must not emit playbackIntentChanged — intent stays \(intentBefore); got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidPause = $0 { return true }; return false } ||
            liveEmissions.contains { if case .streamDidStop = $0 { return true }; return false } ||
            liveEmissions.contains { if case .streamDidFail = $0 { return true }; return false },
            "Active switch must not emit terminal stream verbs; got: \(liveEmissions)"
        )

        let visualAfter = await manager.currentVisualState
        let intentAfter = await manager.currentPlaybackIntent
        XCTAssertEqual(visualAfter, .playing)
        XCTAssertEqual(intentAfter, .shouldBePlaying)

        let current = SharedPlayerManager.streamForLanguageCode(other.languageCode)
        XCTAssertEqual(current.languageCode, other.languageCode)
    }

    /// Active-intent stream switch must establish Connecting chrome and clear prior-language
    /// program metadata **before** engine silent stop, so lock-screen surfaces cannot keep
    /// `.playing` mid teardown.
    ///
    /// Protects the coordinator contract: ``resetToPrePlayForNewStream()`` then
    /// ``switchToStream(_:)`` leaves ``isStreamSwitchPrePlayHoldActive`` true with nil metadata
    /// until authoritative ``setPlaying()``.
    ///
    /// - SeeAlso: ``resetToPrePlayForNewStream(preserveActiveSleepTimer:connectingLanguageCode:)``,
    ///   ``isStreamSwitchPrePlayHoldActive``, ``switchToStream(_:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§6).
    func testActiveStreamSwitchHoldClearsPlayingChromeAndMetadataBeforeEnginePrep() async {
        let streams = manager.availableStreams
        guard streams.count >= 2 else { return }
        let other = await targetStreamDifferentFromCurrent(in: streams)

        await manager.setPlaying()
        await manager.didUpdateStreamMetadata("Prior Language Program • Speaker")
        var meta = await manager.currentStreamMetadata
        XCTAssertNotNil(meta, "Arrange: prior-language ICY title present before switch")

        await manager.resetToPrePlayForNewStream(connectingLanguageCode: other.languageCode)

        let visualDuringHold = await manager.currentVisualState
        let holdActive = await manager.isStreamSwitchPrePlayHoldActive
        meta = await manager.currentStreamMetadata
        XCTAssertEqual(visualDuringHold, .prePlay, "Hold must force Connecting chrome before silent stop")
        XCTAssertTrue(holdActive, "Stream-switch prePlay hold must be active before engine prep")
        XCTAssertNil(meta, "Prior-language program title must clear with the hold")

        await manager.switchToStream(other)

        let visualAfterEnginePrep = await manager.currentVisualState
        let holdAfterEnginePrep = await manager.isStreamSwitchPrePlayHoldActive
        XCTAssertEqual(
            visualAfterEnginePrep,
            .prePlay,
            "Silent streamSwitch stop must not restore .playing while hold is active"
        )
        XCTAssertTrue(
            holdAfterEnginePrep,
            "Hold must remain until authoritative setPlaying after attach"
        )

        let intent = await manager.currentPlaybackIntent
        XCTAssertTrue(
            intent.isActivePlaybackIntent,
            "Active-intent switch must preserve play intent through hold + engine prep"
        )
    }

    /// Stream-switch Connecting hold must publish the **destination** language for Live Activity
    /// content **before** ``selectedStream`` updates, so Lock Screen chrome does not show
    /// `.prePlay` with the prior stream’s flag/name for one content push.
    ///
    /// After ``setPlaying()`` the hold-time override clears and language follows stream attach.
    ///
    /// - SeeAlso: ``resetToPrePlayForNewStream(preserveActiveSleepTimer:connectingLanguageCode:)``,
    ///   ``liveActivityLanguageCodeForContentPush()``, ``mainAppLiveActivityLanguageCode()``,
    ///   ``persistLiveActivityLanguageMirror(_:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   docs/Widget-Functionality-Roadmap.md (Live Activity language chrome SSOT).
    func testStreamSwitchHoldContentLanguageMatchesDestinationBeforeEnginePrep() async {
        let streams = manager.availableStreams
        guard streams.count >= 2 else { return }
        let other = await targetStreamDifferentFromCurrent(in: streams)
        let priorLanguage = await MainActor.run {
            DirectStreamingPlayer.shared.selectedStream.languageCode
        }
        XCTAssertNotEqual(
            priorLanguage,
            other.languageCode,
            "Arrange: destination must differ from engine selection before hold"
        )

        await manager.setPlaying()
        await manager.resetToPrePlayForNewStream(connectingLanguageCode: other.languageCode)

        let holdActive = await manager.isStreamSwitchPrePlayHoldActive
        let contentLanguage = await manager.liveActivityLanguageCodeForContentPush()
        let engineLanguage = SharedPlayerManager.mainAppLiveActivityLanguageCode()
        let mirror = SharedPlayerManager.loadLiveActivityLanguageMirror()

        XCTAssertTrue(holdActive, "Hold must be active for the content-language override")
        XCTAssertEqual(
            contentLanguage,
            other.languageCode,
            "LA ContentState language must be destination during Connecting hold"
        )
        XCTAssertEqual(
            engineLanguage,
            priorLanguage,
            "Engine selectedStream may still be prior until switchToStream — that is the race this override covers"
        )
        XCTAssertEqual(
            mirror,
            other.languageCode,
            "Durable LA language mirror must warm destination on hold (extension optimistic paths)"
        )

        await manager.switchToStream(other)
        let contentAfterPrep = await manager.liveActivityLanguageCodeForContentPush()
        XCTAssertEqual(contentAfterPrep, other.languageCode)

        await manager.setPlaying()
        let contentAfterPlay = await manager.liveActivityLanguageCodeForContentPush()
        let engineAfterPlay = SharedPlayerManager.mainAppLiveActivityLanguageCode()
        XCTAssertEqual(contentAfterPlay, other.languageCode)
        XCTAssertEqual(engineAfterPlay, other.languageCode)
        XCTAssertEqual(
            contentAfterPlay,
            engineAfterPlay,
            "After setPlaying, content language must equal stream-attach language (hold override cleared)"
        )
    }

    /// Verifies the full paused language-switch path emission contract.
    ///
    /// Mirrors the explicit-paused branch of `RadioPlayerCoordinator.completeStreamSwitch` /
    /// `switchToStreamFromWidget`: engine prep via ``switchToStream(_:)`` (no auto-resume),
    /// then ``clearSoftPauseMetadataStashForLanguageChange()`` to drop stale ICY titles.
    ///
    /// Visual and intent must remain sticky `.userPaused`. The canonical clear must be the
    /// final `.metadataDidUpdate` in the collected window (engine prep may emit a prior
    /// non-nil update). Engine silent-stop may add `.persistedWidgetStateDidUpdate`
    /// without changing visual or intent.
    ///
    /// - SeeAlso: ``clearSoftPauseMetadataStashForLanguageChange()``,
    ///   ``switchToStream(_:)``, `RadioPlayerCoordinator.completeStreamSwitch`,
    ///   docs/Event-Driven-Refactor-Roadmap.md (Tier 5),
    ///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
    func testPausedLanguageSwitchFullPathClearsMetadataWithoutVisualOrIntentMutation() async {
        let streams = manager.availableStreams
        guard streams.count >= 2 else { return }
        let other = await targetStreamDifferentFromCurrent(in: streams)

        await manager.setUserPaused()
        await manager.didUpdateStreamMetadata("Test Program • Speaker")

        let visualBefore = await manager.currentVisualState
        let intentBefore = await manager.currentPlaybackIntent
        XCTAssertEqual(visualBefore, .userPaused)
        XCTAssertEqual(intentBefore, .userPaused)

        let m = self.manager
        let liveEmissions = await collectSeamEventsUntil(timeout: 8.0, until: { event in
            if case .metadataDidUpdate(nil) = event { return true }
            return false
        }) {
            await m.switchToStream(other)
            await m.clearSoftPauseMetadataStashForLanguageChange()
        }

        XCTAssertTrue(
            liveEmissions.contains { if case .metadataDidUpdate(nil) = $0 { return true }; return false },
            "Paused switch must emit .metadataDidUpdate(nil); got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .visualStateDidChange = $0 { return true }; return false },
            "Paused switch must not mutate visual state via events; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .playbackIntentChanged = $0 { return true }; return false },
            "Paused switch must not emit playbackIntentChanged; got: \(liveEmissions)"
        )
        XCTAssertFalse(
            liveEmissions.contains { if case .streamDidStart = $0 { return true }; return false } ||
            liveEmissions.contains { if case .streamDidPause = $0 { return true }; return false } ||
            liveEmissions.contains { if case .streamDidStop = $0 { return true }; return false } ||
            liveEmissions.contains { if case .streamDidFail = $0 { return true }; return false },
            "Paused switch must not emit stream transition verbs; got: \(liveEmissions)"
        )

        // Visual + intent postconditions only: engine async callbacks may repopulate display
        // metadata after the authoritative clear returns (race under full-suite ordering).
        let visualAfter = await manager.currentVisualState
        let intentAfter = await manager.currentPlaybackIntent
        XCTAssertEqual(visualAfter, visualBefore)
        XCTAssertEqual(intentAfter, intentBefore)

        let current = SharedPlayerManager.streamForLanguageCode(other.languageCode)
        XCTAssertEqual(current.languageCode, other.languageCode)
    }

}
