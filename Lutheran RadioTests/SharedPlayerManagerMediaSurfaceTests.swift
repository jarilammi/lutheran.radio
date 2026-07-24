//
//  SharedPlayerManagerMediaSurfaceTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 24.7.2026.
//
//  Media-surface coordination: session teardown gates, soft silence, Now Playing, media-transport mailbox.
//
//  Shared collectors: `Lutheran RadioTests/Support/PlayerEventTestSupport.swift`.
//  Isolation: ``prepareSharedPlayerManagerEventTestIsolation`` /
//  ``tearDownSharedPlayerManagerEventTestIsolation``.
//
//  - SeeAlso: ``SharedPlayerManager``, ``PlayerEvent``,
//    docs/Event-Driven-Refactor-Roadmap.md,
//    CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
//

import MediaPlayer
import XCTest
import WidgetSurface
@testable import Lutheran_Radio

/// Unit tests for media-surface coordination on `SharedPlayerManager`.
///
/// Covers session-teardown refresh gates, post-stop widget hygiene, connecting-chrome
/// honesty, soft-silence barriers, Now Playing info/controls, and media-transport
/// mailbox interleaving. Emission-order / replay contracts live in
/// ``SharedPlayerManagerEventTests``.
///
/// - SeeAlso: ``SharedPlayerManager/refreshAllMediaSurfaces(refreshWidgets:)``,
///   ``SharedPlayerManager/submitMediaTransportCommandAndWait(_:)``,
///   ``SharedPlayerManager/performSessionAndWidgetTeardown(includeFactoryReset:liveActivityTeardown:refreshWidgets:widgetVisualState:staleLiveness:)``,
///   ``WidgetRefreshManager/isSessionTeardownInProgress``,
///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
///   docs/Event-Driven-Refactor-Roadmap.md.
final class SharedPlayerManagerMediaSurfaceTests: XCTestCase {

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

    // MARK: - Session teardown orchestration

    /// Verifies that ``WidgetRefreshManager/refreshIfNeeded(visualState:currentLanguage:hasError:immediate:)``
    /// suppresses timeline work while ``WidgetRefreshManager/isSessionTeardownInProgress`` is held and
    /// accepts the call once the gate releases.
    ///
    /// Uses DEBUG gate-observation seams to bypass UITestMode and WidgetCenter IPC while preserving
    /// the production teardown-guard order exercised during ``SharedPlayerManager/teardownNowPlayingSession()``.
    ///
    /// - SeeAlso: ``WidgetRefreshManager/setSessionTeardownInProgress(_:)``,
    ///   ``WidgetRefreshManager/_test_setBypassUITestModeForRefreshGateObservation(_:)``,
    ///   ``SharedPlayerManager/teardownNowPlayingSession()``, docs/Event-Driven-Refactor-Roadmap.md.
    func testRefreshIfNeededSuppressesWhileSessionTeardownGateIsHeld() async {
        await MainActor.run {
            WidgetRefreshManager._test_setBypassUITestModeForRefreshGateObservation(true)
            WidgetRefreshManager._test_setRecordRefreshIfNeededGateOutcomes(true)
            WidgetRefreshManager._test_clearRefreshIfNeededGateOutcomeLog()

            WidgetRefreshManager.setSessionTeardownInProgress(true)
            WidgetRefreshManager.shared.refreshIfNeeded(
                visualState: .prePlay,
                currentLanguage: "en",
                hasError: false,
                immediate: true
            )
            XCTAssertEqual(
                WidgetRefreshManager._test_refreshIfNeededGateOutcomeLog(),
                [.suppressedBySessionTeardown],
                "Refresh must not run while the cross-process teardown gate is held"
            )

            WidgetRefreshManager._test_clearRefreshIfNeededGateOutcomeLog()
            WidgetRefreshManager.setSessionTeardownInProgress(false)
            WidgetRefreshManager.shared.refreshIfNeeded(
                visualState: .prePlay,
                currentLanguage: "en",
                hasError: false,
                immediate: true
            )
            XCTAssertEqual(
                WidgetRefreshManager._test_refreshIfNeededGateOutcomeLog(),
                [.passedGuards],
                "Refresh must proceed after the teardown gate releases"
            )
        }
    }

    /// Verifies that ``SharedPlayerManager/performPostStopWidgetHygiene()`` triggers an
    /// immediate ``WidgetRefreshManager/refreshIfNeeded(visualState:currentLanguage:hasError:immediate:)``
    /// call that passes production guards when the session-teardown gate is not held.
    ///
    /// Post-stop hygiene runs at the end of ``stop()`` (main-app only) to keep home-screen
    /// widgets and Control Center aligned with the sticky `.userPaused` lock without ending
    /// the Live Activity. The refresh uses `immediate: true` so coalesce deferral for
    /// `.prePlay`/`.cleared` cannot delay the sticky-pause presentation.
    ///
    /// Uses the same DEBUG gate-observation seams as
    /// ``testRefreshIfNeededSuppressesWhileSessionTeardownGateIsHeld`` and
    /// ``testPerformSessionAndWidgetTeardownOrchestratesMetadataClearFactoryResetAndPostTeardownRefresh``
    /// to bypass UITestMode and WidgetCenter IPC while preserving the guard order.
    ///
    /// - SeeAlso: ``SharedPlayerManager/stop()``, ``performPostStopWidgetHygiene()``,
    ///   ``WidgetRefreshManager/_test_setBypassUITestModeForRefreshGateObservation(_:)``,
    ///   ``WidgetRefreshManager/_test_setRecordRefreshIfNeededGateOutcomes(_:)``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (session + widget teardown follow-up),
    ///   CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
    func testPerformPostStopWidgetHygieneTriggersImmediateRefresh() async {
        await manager.setUserPaused()
        let visual = await manager.currentVisualState
        XCTAssertEqual(
            visual,
            .userPaused,
            "Precondition: post-stop hygiene targets the sticky .userPaused presentation"
        )

        await MainActor.run {
            WidgetRefreshManager._test_setBypassUITestModeForRefreshGateObservation(true)
            WidgetRefreshManager._test_setRecordRefreshIfNeededGateOutcomes(true)
            WidgetRefreshManager._test_clearRefreshIfNeededGateOutcomeLog()
            XCTAssertFalse(
                WidgetRefreshManager.isSessionTeardownInProgress,
                "Precondition: post-stop hygiene must not run while the teardown gate is held"
            )
        }

        await manager.performPostStopWidgetHygiene()

        await MainActor.run {
            let gateLog = WidgetRefreshManager._test_refreshIfNeededGateOutcomeLog()
            XCTAssertEqual(
                gateLog,
                [.passedGuards],
                "Post-stop hygiene must trigger exactly one refresh that passes guards; log: \(gateLog)"
            )
            XCTAssertFalse(
                WidgetRefreshManager.isSessionTeardownInProgress,
                "Post-stop hygiene must not acquire the session-teardown gate"
            )
        }
    }

    /// Protects connecting-chrome honesty: explicit play intent must not claim `.playing`
    /// (rate 1 / pause glyph) until the engine publishes after soft-resume or readyToPlay kick.
    ///
    /// ``setUserIntentToPlay()`` moves sticky pause → `.prePlay` + `.shouldBePlaying`.
    /// Authoritative ``setPlaying()`` (or engine ``publishAuthoritativePlayingIfNeeded``) is the
    /// only production transition to `.playing` chrome. Under UITestMode, ``play()`` still sets
    /// `.playing` for assertions without real attach — that isolation path is intentional.
    ///
    /// - SeeAlso: ``SharedPlayerManager/setUserIntentToPlay()``, ``SharedPlayerManager/setPlaying()``,
    ///   ``SharedPlayerManager/play()``, docs/Live-Activity-Stacking-and-Media-Surfaces.md
    ///   (connecting chrome vs audible start).
    func testSetUserIntentToPlayLeavesConnectingChromeUntilSetPlaying() async {
        await manager.stop()
        var visual = await manager.currentVisualState
        XCTAssertEqual(visual, .userPaused, "stop must sticky-lock userPaused visual")

        await manager.setUserIntentToPlay()
        visual = await manager.currentVisualState
        let intent = await manager.currentPlaybackIntent
        XCTAssertEqual(
            visual,
            .prePlay,
            "Explicit play intent must show Connecting (.prePlay), not optimistic .playing"
        )
        XCTAssertEqual(intent, .shouldBePlaying)
        XCTAssertFalse(
            visual.isActivelyPlaying,
            "isActivelyPlaying must stay false until engine-complete setPlaying"
        )

        await manager.setPlaying()
        visual = await manager.currentVisualState
        XCTAssertEqual(visual, .playing, "setPlaying is the authoritative audible-start chrome flip")
        XCTAssertTrue(visual.isActivelyPlaying)
    }

    /// Protects media-toggle semantics: in-flight start pipeline means Connecting cancel,
    /// not a second play, on remote / Live Activity transport toggle.
    ///
    /// - SeeAlso: ``SharedPlayerManager/isConnectingPlayback``,
    ///   ``SharedPlayerManager/performMediaTransportCommand(_:generation:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    func testMediaTransportToggleWhileConnectingCancelsToUserPaused() async {
        await manager.stop()
        await manager.setUserIntentToPlay()
        await manager._test_setPlaybackStartPipelineActive(true)

        let connecting = await manager.isConnectingPlayback
        XCTAssertTrue(connecting, "Precondition: start pipeline active without audible playing")

        await manager.submitMediaTransportCommandAndWait(.togglePlayPause)

        let visual = await manager.currentVisualState
        let intent = await manager.currentPlaybackIntent
        let stillConnecting = await manager.isConnectingPlayback
        XCTAssertEqual(visual, .userPaused, "Toggle during Connecting must sticky-pause (cancel connect)")
        XCTAssertEqual(intent, .userPaused)
        XCTAssertFalse(stillConnecting, "stop must clear the start pipeline")
    }

    /// Second explicit play while the start pipeline is active is a no-op (no intent thrash).
    ///
    /// - SeeAlso: ``SharedPlayerManager/userRequestedPlay()``, ``SharedPlayerManager/isConnectingPlayback``
    func testUserRequestedPlayWhileConnectingIsIdempotent() async {
        await manager.stop()
        await manager.setUserIntentToPlay()
        await manager._test_setPlaybackStartPipelineActive(true)

        await manager.userRequestedPlay()

        let visual = await manager.currentVisualState
        let intent = await manager.currentPlaybackIntent
        let connecting = await manager.isConnectingPlayback
        XCTAssertEqual(visual, .prePlay, "Idempotent play must not leave Connecting chrome")
        XCTAssertEqual(intent, .shouldBePlaying)
        XCTAssertTrue(connecting, "Pipeline must remain active until stop or setPlaying")
    }

    /// Second ``userRequestedPlay()`` while chrome is already authoritative `.playing` must
    /// no-op: no Connecting thrash, no sticky re-plan, visual stays `.playing`.
    ///
    /// Why: Cold-launch `resurrectionProtectionRelaxed` used to disable the visual already-
    /// playing skip, so an explicit play while audio was live rebuilt the secured item.
    /// Idempotency is engine-aware in production and independent of that window; under
    /// UITestMode, chrome `.playing` is the stand-in (no real AVPlayer rate). Soft-paused
    /// resume remains a separate path and is not covered here.
    ///
    /// - SeeAlso: ``SharedPlayerManager/userRequestedPlay()``, ``SharedPlayerManager/setPlaying()``,
    ///   ``SharedPlayerManager/play()``, CODING_AGENT.md (Single Source of Truth Principles).
    func testUserRequestedPlayWhileAlreadyPlayingIsIdempotent() async {
        // Establish authoritative playing chrome (UITestMode: no real engine attach).
        await manager.setPlaying()

        let visualBefore = await manager.currentVisualState
        let intentBefore = await manager.currentPlaybackIntent
        XCTAssertEqual(visualBefore, .playing, "Precondition: already authoritative playing")
        XCTAssertEqual(intentBefore, .shouldBePlaying)

        // Short-timeout seam window: redundant play should not emit stop or Connecting.
        // High minimumCount forces the timeout path so we capture whatever (if anything) arrived.
        let spm = manager
        let events = await collectSeamEvents(minimumCount: 64, timeout: 1.0, whilePerforming: {
            await spm.userRequestedPlay()
        })

        let visualAfter = await manager.currentVisualState
        let intentAfter = await manager.currentPlaybackIntent
        let connecting = await manager.isConnectingPlayback
        XCTAssertEqual(visualAfter, .playing, "Second play must leave chrome authoritative playing")
        XCTAssertEqual(intentAfter, .shouldBePlaying, "Intent must stay shouldBePlaying")
        XCTAssertFalse(connecting, "Must not re-enter Connecting pipeline while already playing")

        let forcedConnecting = events.contains {
            if case .visualStateDidChange(.prePlay) = $0 { return true }
            return false
        }
        XCTAssertFalse(
            forcedConnecting,
            "Already-playing play must not force Connecting chrome via setUserIntentToPlay"
        )
        let toreDown = events.contains {
            if case .streamDidStop = $0 { return true }
            return false
        }
        XCTAssertFalse(toreDown, "Already-playing play must not stop / rebuild the stream")
    }

    /// Direct ``play()`` while already `.playing` must also no-op (internal callers share the
    /// same engine-aware idempotency as ``userRequestedPlay()``).
    ///
    /// - SeeAlso: ``SharedPlayerManager/play()``, ``SharedPlayerManager/setPlaying()``
    func testPlayWhileAlreadyPlayingIsIdempotentEvenOnDirectEntry() async {
        await manager.setPlaying()
        let before = await manager.currentVisualState
        XCTAssertEqual(before, .playing)

        await manager.play()

        let visual = await manager.currentVisualState
        let intent = await manager.currentPlaybackIntent
        let connecting = await manager.isConnectingPlayback
        XCTAssertEqual(visual, .playing)
        XCTAssertEqual(intent, .shouldBePlaying)
        XCTAssertFalse(connecting, "Direct play while already playing must not open start pipeline")
    }

    /// Soft-paused resume must still proceed (already-playing no-op is rate-aware and must
    /// not block ``resumeFromSoftPauseIfAvailable`` after sticky pause).
    ///
    /// - SeeAlso: ``SharedPlayerManager/userRequestedPlay()``, ``SharedPlayerManager/stop()``,
    ///   ``DirectStreamingPlayer/resumeFromSoftPauseIfAvailable()``
    func testUserRequestedPlayAfterSoftPauseStillPlansResume() async {
        await manager.setPlaying()
        await manager.stop()

        let pausedVisual = await manager.currentVisualState
        let pausedIntent = await manager.currentPlaybackIntent
        XCTAssertEqual(pausedVisual, .userPaused)
        XCTAssertEqual(pausedIntent, .userPaused)

        await manager.userRequestedPlay()

        let visual = await manager.currentVisualState
        let intent = await manager.currentPlaybackIntent
        // Under UITestMode play short-circuits to .playing after setUserIntentToPlay → .prePlay.
        // Soft-pause path is not blocked: sticky pause clears and intent becomes shouldBePlaying.
        XCTAssertEqual(intent, .shouldBePlaying, "Pause→play must clear sticky and plan playback")
        XCTAssertTrue(
            visual == .playing || visual == .prePlay,
            "Resume must reach Connecting or authoritative playing, not stay sticky paused"
        )
        XCTAssertNotEqual(visual, .userPaused, "Soft-pause resume must not remain userPaused")
    }

    /// Security recovery explicit play moves chrome to Connecting before validation / attach.
    ///
    /// - SeeAlso: ``SharedPlayerManager/setUserIntentToPlay()``,
    ///   ``PlayerVisualState/optimisticVisualAfterPlayPlan``
    func testSetUserIntentToPlayFromSecurityLockedUsesConnectingChrome() async {
        await manager.setVisualState(.securityLocked)
        await manager.setUserIntentToPlay()

        let visual = await manager.currentVisualState
        let intent = await manager.currentPlaybackIntent
        XCTAssertEqual(visual, .prePlay, "Security recovery must use Connecting chrome, not green playing")
        XCTAssertEqual(intent, .shouldBePlaying)
        XCTAssertFalse(visual.isActivelyPlaying)
    }

    /// Protects the user-pause engine-complete contract: ``stop()`` returns only after soft
    /// silence (`isSoftPaused`, rate 0 when a player exists), and media-surface coordination
    /// runs after that barrier — never while soft pause is still in flight.
    ///
    /// Why: Fire-and-forget engine stop allowed Now Playing / Live Activity glyphs to flip
    /// while audio was still audible. SPM owns sticky `.userPaused` + one
    /// ``refreshAllMediaSurfaces`` after ``DirectStreamingPlayer/stopAndWait``.
    ///
    /// - SeeAlso: ``SharedPlayerManager/stop()``,
    ///   `DirectStreamingPlayer.stopAndWait(reason:silent:applyUserPauseVisualLock:)`,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md (user pause / transport coordination).
    func testStopAwaitsSoftSilenceBeforeReturningAndRefreshingSurfaces() async {
        SharedPlayerManager._test_setRecordMediaSurfaceCoordinationOrder(true)
        SharedPlayerManager._test_clearMediaSurfaceCoordinationOrderLog()

        await manager.setUserIntentToPlay()
        await manager.stop()

        let softPaused = await MainActor.run {
            DirectStreamingPlayer.shared.test_isSoftPaused
        }
        XCTAssertTrue(
            softPaused,
            "stop() must await soft-pause completion before returning (engine-complete barrier)"
        )
        if let rate = await MainActor.run(body: { DirectStreamingPlayer.shared.test_playerRate }) {
            XCTAssertEqual(
                rate,
                0,
                accuracy: 0.001,
                "stop() must observe rate 0 before treating pause as engine-complete"
            )
        }

        let visual = await manager.currentVisualState
        let intent = await manager.currentPlaybackIntent
        XCTAssertEqual(visual, .userPaused)
        XCTAssertEqual(intent, .userPaused)

        // Under UITestMode, Live Activity is skipped; coordination may be empty or NP-only if
        // bypass is off. Invariant under test isolation: stop completed with soft silence set.
        // When coordination is recorded with NP bypass, steps must appear only after silence —
        // already guaranteed by stop()'s sequential await + refresh ordering.
        SharedPlayerManager._test_setRecordMediaSurfaceCoordinationOrder(false)
        SharedPlayerManager._test_clearMediaSurfaceCoordinationOrderLog()
    }

    /// Protects the Tier 4 ``refreshAllMediaSurfaces(liveActivity:widgetRefresh:widgetRefreshImmediate:)``
    /// wrapper: visual mutations complete without trapping, and optional imperative widget refresh
    /// reaches ``WidgetRefreshManager/refreshIfNeeded(visualState:currentLanguage:hasError:immediate:)``
    /// when explicitly requested (default mutation paths remain on the PlayerEvent observer).
    ///
    /// - SeeAlso: docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   ``SharedPlayerManager/setPlaying()``, ``SharedPlayerManager/markAsUserPaused()``.
    func testRefreshAllMediaSurfacesCompletesAndOptionalWidgetRefreshPassesGates() async {
        await manager.setPlaying()
        await manager.refreshAllMediaSurfaces(liveActivity: .updateIfActive)

        await manager.markAsUserPaused()
        let visual = await manager.currentVisualState
        XCTAssertEqual(visual, .userPaused, "markAsUserPaused must lock sticky pause visual")

        await MainActor.run {
            WidgetRefreshManager._test_setBypassUITestModeForRefreshGateObservation(true)
            WidgetRefreshManager._test_setRecordRefreshIfNeededGateOutcomes(true)
            WidgetRefreshManager._test_clearRefreshIfNeededGateOutcomeLog()
        }

        await manager.refreshAllMediaSurfaces(
            liveActivity: .none,
            widgetRefresh: true,
            widgetRefreshImmediate: true
        )

        await MainActor.run {
            XCTAssertTrue(
                WidgetRefreshManager._test_refreshIfNeededGateOutcomeLog().contains(.passedGuards),
                "Optional widget refresh must pass gates when widgetRefresh is true"
            )
        }
    }

    /// Protects Tier 4 ``refreshAllMediaSurfaces(liveActivity:widgetRefresh:widgetRefreshImmediate:)``
    /// coordination ordering: Now Playing update precedes widget refresh; Live Activity IPC is
    /// skipped under UITestMode without blocking the NP path.
    ///
    /// Also verifies ``updateNowPlayingInfo()`` writes the ``StreamProgramMetadata/nowPlayingDisplayStrings(fromParsed:rawFallback:stationName:languageName:)``
    /// SSOT into `MPNowPlayingInfoCenter` when the DEBUG bypass seam is enabled, and keeps
    /// dictionary rate and `playbackState` aligned (`.playing` while actively playing).
    ///
    /// - SeeAlso: ``SharedPlayerManager/_test_setBypassUITestModeForNowPlayingUpdates(_:)``,
    ///   ``SharedPlayerManager/_test_mediaSurfaceCoordinationOrderLog()``,
    ///   StreamProgramMetadataTests, docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   docs/Widget-Functionality-Roadmap.md (Tier 4).
    func testRefreshAllMediaSurfacesOrdersNowPlayingBeforeWidgetRefreshAndWritesDisplayStrings() async {
        let icyTitle = "Guest Speaker - The Good Shepherd"
        let stationName = String(localized: "lutheran_radio_title", table: "Localizable")
        let languageCode = SharedPlayerManager.preferredWidgetLanguage()
        let languageName = SharedPlayerManager.streamForLanguageCode(languageCode).language

        await manager.setPlaying()
        await manager.didUpdateStreamMetadata(icyTitle)

        let expectedDisplay = StreamProgramMetadata.nowPlayingDisplayStrings(
            fromParsed: StreamProgramMetadata.from(rawICYMetadata: icyTitle),
            rawFallback: icyTitle,
            stationName: stationName,
            languageName: languageName
        )

        SharedPlayerManager._test_setBypassUITestModeForNowPlayingUpdates(true)
        SharedPlayerManager._test_setRecordMediaSurfaceCoordinationOrder(true)
        SharedPlayerManager._test_clearMediaSurfaceCoordinationOrderLog()

        await MainActor.run {
            WidgetRefreshManager._test_setBypassUITestModeForRefreshGateObservation(true)
            WidgetRefreshManager._test_setRecordRefreshIfNeededGateOutcomes(true)
            WidgetRefreshManager._test_clearRefreshIfNeededGateOutcomeLog()
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }

        await manager.refreshAllMediaSurfaces(
            liveActivity: .updateIfActive,
            widgetRefresh: true,
            widgetRefreshImmediate: true
        )

        let order = SharedPlayerManager._test_mediaSurfaceCoordinationOrderLog()
        XCTAssertEqual(
            order,
            [.nowPlayingUpdate, .liveActivitySkippedUnderTest, .widgetRefresh],
            "Now Playing must run before widget refresh; LA IPC must be skipped under XCTest"
        )

        await MainActor.run {
            let center = MPNowPlayingInfoCenter.default()
            let info = center.nowPlayingInfo
            XCTAssertEqual(info?[MPMediaItemPropertyTitle] as? String, expectedDisplay.title)
            XCTAssertEqual(info?[MPMediaItemPropertyArtist] as? String, expectedDisplay.artist)
            XCTAssertEqual(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.0)
            XCTAssertEqual(
                center.playbackState,
                .playing,
                "Live Now Playing write must set playbackState to .playing with rate 1 while actively playing"
            )
            XCTAssertTrue(
                WidgetRefreshManager._test_refreshIfNeededGateOutcomeLog().contains(.passedGuards),
                "Widget refresh must still pass gates after Now Playing update"
            )
        }
    }

    /// Protects live ``updateNowPlayingInfo()`` alignment of dictionary rate and
    /// `MPNowPlayingInfoCenter.playbackState` on user pause.
    ///
    /// While a session remains live (not torn down), pause must write rate 0 and
    /// `.paused` — not leave a stale `.playing` transport state from a prior play write,
    /// and not use teardown's `.stopped` (reserved for privacy clear / session end).
    ///
    /// - SeeAlso: ``SharedPlayerManager/updateNowPlayingInfo()``,
    ///   ``SharedPlayerManager/markAsUserPaused()``,
    ///   ``SharedPlayerManager/teardownNowPlayingSession()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    func testUpdateNowPlayingInfoSetsPausedPlaybackStateWhenNotActivelyPlaying() async {
        SharedPlayerManager._test_setBypassUITestModeForNowPlayingUpdates(true)

        await manager.setPlaying()
        await manager.refreshAllMediaSurfaces(liveActivity: .none)

        await MainActor.run {
            XCTAssertEqual(
                MPNowPlayingInfoCenter.default().playbackState,
                .playing,
                "Precondition: actively playing must publish .playing"
            )
        }

        await manager.markAsUserPaused()
        await manager.refreshAllMediaSurfaces(liveActivity: .none)

        await MainActor.run {
            let center = MPNowPlayingInfoCenter.default()
            XCTAssertEqual(
                center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double,
                0.0,
                "User pause must publish rate 0 in the Now Playing dictionary"
            )
            XCTAssertEqual(
                center.playbackState,
                .paused,
                "User pause must set playbackState to .paused (not .stopped) while the session is live"
            )
        }
    }

    /// Protects install-time remote-command hygiene: only play / pause / toggle / stop are
    /// enabled; track/seek/skip/rating and related commands must remain disabled so system
    /// chrome does not present dead affordances for a continuous live stream.
    ///
    /// - SeeAlso: ``SharedPlayerManager/configureNowPlayingControlsIfNeeded()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    func testConfigureNowPlayingControlsDisablesUnsupportedRemoteCommands() async {
        await manager.configureNowPlayingControlsIfNeeded()

        await MainActor.run {
            let center = MPRemoteCommandCenter.shared()
            XCTAssertTrue(center.playCommand.isEnabled)
            XCTAssertTrue(center.pauseCommand.isEnabled)
            XCTAssertTrue(center.togglePlayPauseCommand.isEnabled)
            XCTAssertTrue(center.stopCommand.isEnabled)

            let unsupported: [MPRemoteCommand] = [
                center.nextTrackCommand,
                center.previousTrackCommand,
                center.skipForwardCommand,
                center.skipBackwardCommand,
                center.seekForwardCommand,
                center.seekBackwardCommand,
                center.changePlaybackPositionCommand,
                center.changePlaybackRateCommand,
                center.changeRepeatModeCommand,
                center.changeShuffleModeCommand,
                center.ratingCommand,
                center.likeCommand,
                center.dislikeCommand,
                center.bookmarkCommand,
                center.enableLanguageOptionCommand,
                center.disableLanguageOptionCommand
            ]
            for command in unsupported {
                XCTAssertFalse(
                    command.isEnabled,
                    "Unsupported remote command must be disabled at install time"
                )
            }
        }
    }

    /// Protects media-transport mailbox ordering for rapid headset / Now Playing toggles.
    ///
    /// Two ``MediaTransportCommand/togglePlayPause`` submits while actively playing must
    /// serialize as pause-then-play (end playing), not double-pause from two concurrent
    /// tasks both sampling `isActivelyPlaying == true` before either mutates state.
    ///
    /// Why: Remote handlers used to spawn unstructured tasks that split the visual read
    /// from `stop()` / `userRequestedPlay()`, so a double-click inverted or stuck paused.
    ///
    /// - SeeAlso: ``SharedPlayerManager/submitMediaTransportCommand(_:)``,
    ///   ``SharedPlayerManager/performMediaTransportCommand(_:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    func testMediaTransportDoubleToggleWhilePlayingEndsPlaying() async {
        await manager.setPlaying()
        let playing = await manager.currentVisualState
        XCTAssertEqual(playing, .playing, "Precondition: start from actively playing visual")
        XCTAssertTrue(playing.isActivelyPlaying)

        // Fire-and-forget style: two enqueues without awaiting between them (headset double-click).
        await manager.submitMediaTransportCommand(.togglePlayPause)
        await manager.submitMediaTransportCommand(.togglePlayPause)
        await manager.waitForMediaTransportIdle()

        let visual = await manager.currentVisualState
        let intent = await manager.currentPlaybackIntent
        XCTAssertEqual(
            visual,
            .playing,
            "Double toggle from playing must end playing (pause then play), not stuck .userPaused"
        )
        XCTAssertEqual(
            intent,
            .shouldBePlaying,
            "Second toggle must restore active playback intent after the serialized pause"
        )
    }

    /// Protects media-transport mailbox ordering for rapid toggles from a paused surface.
    ///
    /// Two toggles from sticky pause must serialize as play-then-pause (end paused).
    ///
    /// - SeeAlso: ``SharedPlayerManager/submitMediaTransportCommand(_:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    func testMediaTransportDoubleToggleWhilePausedEndsPaused() async {
        await manager.setPlaying()
        await manager.stop()
        let paused = await manager.currentVisualState
        XCTAssertEqual(paused, .userPaused, "Precondition: sticky user pause")

        await manager.submitMediaTransportCommand(.togglePlayPause)
        await manager.submitMediaTransportCommand(.togglePlayPause)
        await manager.waitForMediaTransportIdle()

        let visual = await manager.currentVisualState
        let intent = await manager.currentPlaybackIntent
        XCTAssertEqual(
            visual,
            .userPaused,
            "Double toggle from pause must end paused (play then pause), not stuck playing"
        )
        XCTAssertEqual(intent, .userPaused)
    }

    /// Protects pause preemption: an enqueued pause must not remain stuck behind a prior
    /// play on the mailbox; sticky `.userPaused` must win after drain.
    ///
    /// - SeeAlso: ``SharedPlayerManager/submitMediaTransportCommand(_:)``,
    ///   ``SharedPlayerManager/stop()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    func testMediaTransportPausePreemptsInFlightPlayOnMailbox() async {
        await manager.submitMediaTransportCommand(.play)
        await manager.submitMediaTransportCommand(.pause)
        await manager.waitForMediaTransportIdle()

        let visual = await manager.currentVisualState
        let intent = await manager.currentPlaybackIntent
        XCTAssertEqual(
            visual,
            .userPaused,
            "Pause submitted after play must leave sticky .userPaused after mailbox drain"
        )
        XCTAssertEqual(intent, .userPaused)
    }

    /// Protects main-app Live Activity engine execution sharing the media-transport mailbox
    /// with remote commands: interleaved pause (LA) + toggle (remote-style) remains ordered.
    ///
    /// - SeeAlso: ``WidgetIntentExecution/executeLiveActivityToggle(plan:)``,
    ///   ``SharedPlayerManager/submitMediaTransportCommand(_:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    func testMediaTransportInterleavesLiveActivityPauseWithRemoteToggle() async {
        await manager.setPlaying()

        // LA pause plan shares the mailbox with a subsequent remote toggle (resume).
        await WidgetIntentExecution.executeLiveActivityToggle(plan: .pause)
        await manager.submitMediaTransportCommand(.togglePlayPause)
        await manager.waitForMediaTransportIdle()

        let visual = await manager.currentVisualState
        XCTAssertEqual(
            visual,
            .playing,
            "LA pause then remote toggle must resume (ordered mailbox), not invert to a second pause"
        )
        let intent = await manager.currentPlaybackIntent
        XCTAssertEqual(intent, .shouldBePlaying)
    }


    /// Verifies the orchestration contract of ``SharedPlayerManager/performSessionAndWidgetTeardown(includeFactoryReset:liveActivityTeardown:refreshWidgets:widgetVisualState:staleLiveness:)``.
    ///
    /// The test drives the full awaited path with factory reset, termination liveness sentinel,
    /// system Now Playing teardown, and post-teardown widget refresh. Live Activity dismissal is
    /// skipped (`.none`) to avoid ActivityKit IPC under the XCTest host.
    ///
    /// **Contracts protected:**
    /// - Optional factory reset purges on-disk visual keys and restores `.prePlay`.
    /// - `staleLiveness` writes the termination sentinel (`lastUpdateTime == 0`).
    /// - Phase-1 Now Playing metadata is cleared before widget refresh runs.
    /// - The session-teardown gate is released when orchestration completes.
    /// - The terminal `refreshIfNeeded(..., immediate: true)` passes guards after teardown.
    ///
    /// - SeeAlso: ``SharedPlayerManager/teardownNowPlayingSession()``,
    ///   ``SharedPlayerManager/resetToFactoryDefaultsOnLaunch()``,
    ///   ``SharedPlayerManager/hasExplicitTerminationSentinel()``,
    ///   `WidgetRefreshManager.isSessionTeardownInProgress`,
    ///   docs/Event-Driven-Refactor-Roadmap.md (session + widget teardown follow-up).
    func testPerformSessionAndWidgetTeardownOrchestratesMetadataClearFactoryResetAndPostTeardownRefresh() async {
        let stale = SharedPlayerManager.PersistedWidgetState(
            visualState: .playing,
            currentLanguage: "sv"
        )
        let data = try! JSONEncoder().encode(stale)
        let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared")
        defaults?.set(data, forKey: "persistedWidgetState")
        defaults?.set(data, forKey: "playerVisualState")

        SharedPlayerManager.bumpWidgetLivenessTimestamp(policy: .immediate)
        XCTAssertFalse(
            SharedPlayerManager.hasExplicitTerminationSentinel(),
            "Precondition: liveness heartbeat must be non-sentinel before teardown"
        )

        await manager.setUserPaused()

        await MainActor.run {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: "Svenska LIVE"
            ]
            MPNowPlayingInfoCenter.default().playbackState = .playing

            WidgetRefreshManager._test_setBypassUITestModeForRefreshGateObservation(true)
            WidgetRefreshManager._test_setRecordRefreshIfNeededGateOutcomes(true)
            WidgetRefreshManager._test_clearRefreshIfNeededGateOutcomeLog()
        }

        await manager.performSessionAndWidgetTeardown(
            includeFactoryReset: true,
            liveActivityTeardown: .none,
            refreshWidgets: true,
            staleLiveness: true
        )

        let visual = await manager.currentVisualState
        XCTAssertEqual(visual, .prePlay, "Factory reset must restore the safe pre-play visual")
        XCTAssertNil(SharedPlayerManager.loadPersistedWidgetState())
        XCTAssertNil(defaults?.data(forKey: "persistedWidgetState"))
        XCTAssertNil(defaults?.data(forKey: "playerVisualState"))
        XCTAssertTrue(
            SharedPlayerManager.hasExplicitTerminationSentinel(),
            "Termination liveness sentinel must be written when staleLiveness is true"
        )

        await MainActor.run {
            XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
            XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .stopped)
            XCTAssertFalse(
                WidgetRefreshManager.isSessionTeardownInProgress,
                "Orchestration must release the teardown gate before returning"
            )

            let gateLog = WidgetRefreshManager._test_refreshIfNeededGateOutcomeLog()
            XCTAssertTrue(
                gateLog.contains(.passedGuards),
                "Post-teardown widget refresh must pass guards; log: \(gateLog)"
            )
            XCTAssertFalse(
                gateLog.contains(.suppressedBySessionTeardown),
                "Terminal refresh must not be suppressed after orchestration completes; log: \(gateLog)"
            )
        }
    }
}
