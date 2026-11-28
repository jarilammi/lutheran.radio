//
//  DirectStreamingPlayerEngineTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 24.7.2026.
//
//  Real-engine integration coverage for ``DirectStreamingPlayer`` under the XCTest
//  host: attach-generation discard, hard-teardown barriers, early-window recovery,
//  UITestMode audio short-circuits (construction does not activate AVAudioSession;
//  first clip / play / attach await configure, which waits for factory deactivate;
//  SessionCore deactivate of a never-configured session is skipped;
//  first presentable setCategory settles SessionCore before the call),
//  production type / DNSSEC factory surfaces, and pure
//  ``shouldSkipForceWidgetSaveOnStableStatus`` /
//  ``shouldSkipSessionCoreDeactivate`` /
//  ``audiblePlaybackKickTiming`` /
//  ``explicitBackgroundPlayHoldDecision`` /
//  ``shouldReplaceCurrentItemWithNilOnStop`` /
//  ``shouldAllowAudiblePlaybackKick(startedAt:)`` /
//  ``admitAuthoritativePlayingPublish(inFlight:generation:currentGeneration:nextTicketID:)``
//  policy (same-generation in-flight ``setPlaying``).
//
//  - SeeAlso: ``DirectStreamingPlayer``, ``SharedPlayerManager``,
//    ``DirectStreamingPlayer/configureAudioSessionAsync()``,
//    ``DirectStreamingPlayer/shouldSkipSessionCoreDeactivate(hasAppliedPlaybackSessionThisProcess:categoryIsPlayback:)``,
//    ``DirectStreamingPlayer/shouldSettleSessionCoreBeforeFirstPlaybackCategory(hasAppliedPlaybackSessionThisProcess:categoryIsPlayback:)``,
//    ``DirectStreamingPlayer/shouldSkipForceWidgetSaveOnStableStatus(isPlaying:reasonKey:visual:)``,
//    ``DirectStreamingPlayer/audiblePlaybackKickTiming(itemIsReadyToPlay:isPlaybackLikelyToKeepUp:isSoftPauseSameStreamResume:)``,
//    ``DirectStreamingPlayer/explicitBackgroundPlayHoldDecision(signal:context:)``,
//    ``DirectStreamingPlayer/shouldReplaceCurrentItemWithNilOnStop(reason:)``,
//    ``DirectStreamingPlayer/shouldAllowAudiblePlaybackKick(startedAt:)``,
//    docs/Live-Activity-Stacking-and-Media-Surfaces.md,
//    docs/Widget-Presentation-Dataflow.md (user-initiated main open),
//    docs/cold-launch-streamplay-regression-checklist.md.
//

import XCTest
import AVFoundation
import Network
@testable import Lutheran_Radio
import Core
import WidgetSurface

@MainActor
final class DirectStreamingPlayerEngineTests: XCTestCase {

    // MARK: - Setup & Teardown

    /// Minimal isolation only: avoid full `clearAllLocalState` / `stop()` in suite setUp
    /// (those paths sticky-pause intent). User-action `stop()` now arms the Icecast teardown
    /// guard; clear it here so a prior pause case cannot suppress the next attach/recovery test.
    /// Production attach clears the same guard in ``createAndStartPlayer`` / ``preparePlayerItem``.
    override func setUp() async throws {
        try await super.setUp()
        sanitizeLiveActivityLocalState()
        DirectStreamingPlayer.shared.test_clearPlaybackTeardownGuard()
        DirectStreamingPlayer.shared.test_clearAuthoritativePlayingPublishClaim()
        DirectStreamingPlayer.shared.test_resetAudioSessionMutationProbe()
        DirectStreamingPlayer.shared.test_resetEmbeddedSecurityModelClusterRejections()
    }

    override func tearDown() async throws {
        DirectStreamingPlayer.shared.test_clearAuthoritativePlayingPublishClaim()
        DirectStreamingPlayer.shared.test_resetAudioSessionMutationProbe()
        DirectStreamingPlayer.shared.test_resetEmbeddedSecurityModelClusterRejections()
        sanitizeLiveActivityLocalState()
        try await super.tearDown()
    }

    func testRealAudioSessionConfiguration() {
        // Test that we can access AVAudioSession in test environment
        // This verifies the audio session setup would work without actually creating a DirectStreamingPlayer
        
        // Verify we're in test environment (this is how DirectStreamingPlayer detects test mode)
        let isTestEnvironment = NSClassFromString("XCTestCase") != nil
        XCTAssertTrue(isTestEnvironment, "Should detect test environment")
        
        // Verify that AVAudioSession can be accessed and configured in test mode
        let audioSession = AVAudioSession.sharedInstance()
        XCTAssertNotNil(audioSession)
        
        // Test that we can access audio session properties without throwing
        XCTAssertNoThrow(audioSession.category)
        XCTAssertNoThrow(audioSession.mode)
        
        // In test environment, DirectStreamingPlayer should skip actual audio session configuration
        // This test verifies that the basic audio session infrastructure is available
        
        // Test that isTesting detection works correctly
        // (this is the same logic DirectStreamingPlayer uses)
        let detectedTestMode = NSClassFromString("XCTestCase") != nil
        XCTAssertTrue(detectedTestMode, "Should detect test mode correctly")
    }

    /// Local file-clip start must no-op under UITestMode / XCTest host so unit tests never
    /// construct `AVAudioPlayer` or activate the shared session (same isolation contract as
    /// `configureAudioSessionAsync` / `play()`).
    ///
    /// - SeeAlso: `DirectStreamingPlayer.startLocalClipPlayer(contentsOf:volume:numberOfLoops:)`,
    ///   `SharedPlayerManager.isRunningInUITestMode`.
    func testStartLocalClipPlayerNoOpsUnderUITestMode() async throws {
        XCTAssertTrue(
            SharedPlayerManager.isRunningInUITestMode,
            "XCTest host must report UITestMode so engine audio paths stay silent"
        )
        // Missing file is fine: isTesting short-circuits before open/play.
        let missing = URL(fileURLWithPath: "/tmp/lutheran-radio-local-clip-test-missing.wav")
        let result = try await DirectStreamingPlayer.shared.startLocalClipPlayer(contentsOf: missing)
        XCTAssertNil(result, "startLocalClipPlayer must return nil under UITestMode without throwing")
    }

    /// Construction does not activate `AVAudioSession`. Factory-reset teardown deactivates
    /// the session on the same process start; first clip / play / attach await
    /// ``configureAudioSessionAsync()``, which waits for that deactivate. This gate asserts
    /// the UITestMode no-op seam on that first-use path — it does not activate a real session.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/configureAudioSessionAsync()``,
    ///   ``DirectStreamingPlayer/setupAudioSession()``,
    ///   ``DirectStreamingPlayer/deactivateAudioSessionAsync()``,
    ///   ``SharedPlayerManager/resetToFactoryDefaultsOnLaunch()``,
    ///   docs/Widget-Presentation-Dataflow.md (user-initiated main open).
    func testConfigureAndSetupAudioSessionNoOpUnderUITestMode() async {
        XCTAssertTrue(
            SharedPlayerManager.isRunningInUITestMode,
            "XCTest host must report UITestMode so engine audio paths stay silent"
        )
        await DirectStreamingPlayer.shared.setupAudioSession()
        let configured = await DirectStreamingPlayer.shared.configureAudioSessionAsync()
        XCTAssertFalse(
            configured,
            "configureAudioSessionAsync must no-op under UITestMode (first clip/play await this; construction does not activate)"
        )
    }

    /// Factory-reset Now Playing phase 2 starts ``deactivateAudioSessionAsync()`` without
    /// waiting for SessionCore. First clip / ``play()`` configure must wait for that
    /// deactivate: overlapping `setCategory` returns SessionCore OSStatus -50.
    /// Construction does not activate the session.
    ///
    /// **Why this pattern is required:** UITestMode no-ops SessionCore, so the gate uses the
    /// DEBUG serialized-region hold to prove order without activating `AVAudioSession`.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/configureAudioSessionAsync()``,
    ///   ``DirectStreamingPlayer/deactivateAudioSessionAsync()``,
    ///   ``SharedPlayerManager/teardownNowPlayingSession()``,
    ///   docs/Widget-Presentation-Dataflow.md (user-initiated main open).
    func testConfigureWaitsForInFlightAudioSessionDeactivate() async {
        XCTAssertTrue(
            SharedPlayerManager.isRunningInUITestMode,
            "XCTest host must report UITestMode so engine audio paths stay silent"
        )
        let player = DirectStreamingPlayer.shared
        player.test_resetAudioSessionMutationProbe()
        player.test_setAudioSessionMutationSerializedHoldNanoseconds(200_000_000)

        let deactivateTask = Task { @MainActor in
            let deactivated = await player.deactivateAudioSessionAsync()
            XCTAssertTrue(deactivated, "deactivate remains a UITestMode success no-op")
        }

        for _ in 0..<40 {
            if player.test_audioSessionMutationLog.contains("deactivate-begin") {
                break
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(
            player.test_audioSessionMutationLog.contains("deactivate-begin"),
            "deactivate must begin before configure starts"
        )

        let configureTask = Task { @MainActor in
            let configured = await player.configureAudioSessionAsync()
            XCTAssertFalse(configured, "configure remains a UITestMode no-op")
        }

        _ = await deactivateTask.value
        _ = await configureTask.value

        XCTAssertEqual(
            player.test_audioSessionMutationLog,
            [
                "deactivate-begin",
                "deactivate-end",
                "configure-begin",
                "configure-end"
            ],
            "configure begins only after the in-flight factory deactivate finishes"
        )
    }

    /// Factory-reset Now Playing phase 2 still *enqueues* deactivate, but SessionCore
    /// deactivate of a session this process never configured (category not `.playback`)
    /// poisons the next `setCategory(.playback)` with OSStatus -50 even after that
    /// deactivate’s completion. Skip that SessionCore call; keep the tail.
    ///
    /// **Why this pattern is required:** UITestMode no-ops SessionCore, so this gate is
    /// the pure skip policy. It does not claim the wait-order test covers the completed-
    /// deactivate -50 hole, and it does not activate `AVAudioSession`.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/shouldSkipSessionCoreDeactivate(hasAppliedPlaybackSessionThisProcess:categoryIsPlayback:)``,
    ///   ``DirectStreamingPlayer/configureAudioSessionAsync()``,
    ///   ``DirectStreamingPlayer/deactivateAudioSessionAsync()``,
    ///   `testConfigureWaitsForInFlightAudioSessionDeactivate`,
    ///   docs/Widget-Presentation-Dataflow.md (user-initiated main open).
    func testShouldSkipSessionCoreDeactivateWhenNeverAppliedAndCategoryNotPlayback() {
        XCTAssertTrue(
            DirectStreamingPlayer.shouldSkipSessionCoreDeactivate(
                hasAppliedPlaybackSessionThisProcess: false,
                categoryIsPlayback: false
            ),
            "never-configured factory deactivate must not call SessionCore"
        )
        XCTAssertFalse(
            DirectStreamingPlayer.shouldSkipSessionCoreDeactivate(
                hasAppliedPlaybackSessionThisProcess: true,
                categoryIsPlayback: false
            ),
            "privacy / stop after this process applied playback must still deactivate"
        )
        XCTAssertFalse(
            DirectStreamingPlayer.shouldSkipSessionCoreDeactivate(
                hasAppliedPlaybackSessionThisProcess: false,
                categoryIsPlayback: true
            ),
            "category already .playback (including implicit clip apply) must still deactivate"
        )
        XCTAssertFalse(
            DirectStreamingPlayer.shouldSkipSessionCoreDeactivate(
                hasAppliedPlaybackSessionThisProcess: true,
                categoryIsPlayback: true
            )
        )
    }

    /// SessionCore `setCategory` paramErr is OSStatus -50 (``AVAudioSession.ErrorCode.badParam``).
    /// Configure settles before first-process `setCategory` and retries that code once
    /// if SessionCore still returns paramErr; other errors must not retry.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/isAudioSessionParamError(_:)``,
    ///   ``DirectStreamingPlayer/shouldSettleSessionCoreBeforeFirstPlaybackCategory(hasAppliedPlaybackSessionThisProcess:categoryIsPlayback:)``,
    ///   ``DirectStreamingPlayer/shouldSkipSessionCoreDeactivate(hasAppliedPlaybackSessionThisProcess:categoryIsPlayback:)``.
    func testIsAudioSessionParamErrorMatchesBadParamOnly() {
        let paramErr = NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(AVAudioSession.ErrorCode.badParam.rawValue)
        )
        XCTAssertTrue(
            DirectStreamingPlayer.isAudioSessionParamError(paramErr),
            "OSStatus -50 / badParam is the completed-deactivate setCategory hole"
        )
        let other = NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(AVAudioSession.ErrorCode.cannotStartPlaying.rawValue)
        )
        XCTAssertFalse(
            DirectStreamingPlayer.isAudioSessionParamError(other),
            "non-paramErr session failures must not take the settle retry"
        )
    }

    /// First presentable `setCategory(.playback)` after never-configured skip still
    /// raced SessionCore (OSStatus -50) even though that deactivate never ran. Settle
    /// before that first call when this process has not applied playback and category
    /// is not `.playback`. Construction does not activate. Does not restore init-time
    /// ``setupAudioSession()``.
    ///
    /// **Why this pattern is required:** UITestMode no-ops SessionCore, so this gate is
    /// the pure settle policy. It does not claim the wait-order test or the skip test
    /// covers the first-configure -50 leftover, and it does not activate `AVAudioSession`.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/shouldSettleSessionCoreBeforeFirstPlaybackCategory(hasAppliedPlaybackSessionThisProcess:categoryIsPlayback:)``,
    ///   ``DirectStreamingPlayer/shouldSkipSessionCoreDeactivate(hasAppliedPlaybackSessionThisProcess:categoryIsPlayback:)``,
    ///   `testShouldSkipSessionCoreDeactivateWhenNeverAppliedAndCategoryNotPlayback`,
    ///   `testIsAudioSessionParamErrorMatchesBadParamOnly`,
    ///   docs/Widget-Presentation-Dataflow.md (user-initiated main open).
    func testShouldSettleSessionCoreBeforeFirstPlaybackCategoryWhenNeverAppliedAndCategoryNotPlayback() {
        XCTAssertTrue(
            DirectStreamingPlayer.shouldSettleSessionCoreBeforeFirstPlaybackCategory(
                hasAppliedPlaybackSessionThisProcess: false,
                categoryIsPlayback: false
            ),
            "first presentable setCategory must settle SessionCore after never-configured skip"
        )
        XCTAssertFalse(
            DirectStreamingPlayer.shouldSettleSessionCoreBeforeFirstPlaybackCategory(
                hasAppliedPlaybackSessionThisProcess: true,
                categoryIsPlayback: false
            ),
            "after this process applied playback, do not add first-configure settle on later setCategory"
        )
        XCTAssertFalse(
            DirectStreamingPlayer.shouldSettleSessionCoreBeforeFirstPlaybackCategory(
                hasAppliedPlaybackSessionThisProcess: false,
                categoryIsPlayback: true
            ),
            "already-.playback skips setCategory, so first-configure settle is not needed"
        )
        XCTAssertFalse(
            DirectStreamingPlayer.shouldSettleSessionCoreBeforeFirstPlaybackCategory(
                hasAppliedPlaybackSessionThisProcess: true,
                categoryIsPlayback: true
            )
        )
        XCTAssertEqual(
            DirectStreamingPlayer.sessionCorePlaybackCategorySettleDuration,
            Duration.milliseconds(50),
            "first-configure settle matches the paramErr retry that recovered on device"
        )
    }

    // MARK: - Static Type Tests (testing real types without creating instances)
    
    func testStreamErrorTypeClassification() {
        // Test security error - need to check the actual implementation
        let securityError = URLError(.userAuthenticationRequired)
        let securityType = StreamErrorType.from(error: securityError)
        
        // Debug: Let's see what we actually get
        print("Security error type: \(securityType)")
        print("Security error code: \(securityError.code.rawValue)")
        
        // Based on the StreamErrorType.from implementation,
        // userAuthenticationRequired might not be classified as securityFailure
        // Let's check what it actually returns and test accordingly
        
        // Test permanent errors that should definitely be permanent
        let permanentError = URLError(.fileDoesNotExist)
        let permanentType = StreamErrorType.from(error: permanentError)
        XCTAssertEqual(permanentType, .permanentFailure)
        XCTAssertTrue(permanentType.isPermanent)
        
        // Test transient error
        let transientError = URLError(.timedOut)
        let transientType = StreamErrorType.from(error: transientError)
        XCTAssertEqual(transientType, .transientFailure)
        XCTAssertFalse(transientType.isPermanent)
        
        // Test the actual security-related errors that the implementation handles
        let secureConnectionError = URLError(.secureConnectionFailed)
        let secureConnectionType = StreamErrorType.from(error: secureConnectionError)
        XCTAssertEqual(secureConnectionType, .securityFailure)
        XCTAssertTrue(secureConnectionType.isPermanent)
        
        let certificateError = URLError(.serverCertificateUntrusted)
        let certificateType = StreamErrorType.from(error: certificateError)
        XCTAssertEqual(certificateType, .securityFailure)
        XCTAssertTrue(certificateType.isPermanent)
        
        // Test status strings - use base string keys to avoid localization issues
        // Instead of checking localized strings, test the structure
        XCTAssertFalse(secureConnectionType.statusString.isEmpty)
        XCTAssertFalse(permanentType.statusString.isEmpty)
        XCTAssertFalse(transientType.statusString.isEmpty)
        
        // Test that different error types have different status strings
        XCTAssertNotEqual(secureConnectionType.statusString, permanentType.statusString)
        XCTAssertNotEqual(permanentType.statusString, transientType.statusString)
        
        // Test other permanent errors
        let badServerError = URLError(.badServerResponse)
        let badServerType = StreamErrorType.from(error: badServerError)
        XCTAssertEqual(badServerType, .transientFailure)  // Updated to match new classification treating .badServerResponse as transient for fallback support
        XCTAssertFalse(badServerType.isPermanent)  // Updated to match new classification
        
        let cannotConnectError = URLError(.cannotConnectToHost)
        let cannotConnectType = StreamErrorType.from(error: cannotConnectError)
        XCTAssertEqual(cannotConnectType, .permanentFailure)
        XCTAssertTrue(cannotConnectType.isPermanent)

        // DNS lookup errors (the codes that `requiresDNSSECValidation` failures surface as)
        // must be transient so that DNSSEC requirement is "opt-in safe".
        let cannotFindError = URLError(.cannotFindHost)
        let cannotFindType = StreamErrorType.from(error: cannotFindError)
        XCTAssertEqual(cannotFindType, .transientFailure)
        XCTAssertFalse(cannotFindType.isPermanent)

        let dnsLookupError = URLError(.dnsLookupFailed)
        let dnsLookupType = StreamErrorType.from(error: dnsLookupError)
        XCTAssertEqual(dnsLookupType, .transientFailure)
        XCTAssertFalse(dnsLookupType.isPermanent)

        // Live ICY / media-services noise must remain recoverable (early-window recreate).
        let mediaServicesReset = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.Code.mediaServicesWereReset.rawValue,
            userInfo: nil
        )
        let mediaServicesType = StreamErrorType.from(error: mediaServicesReset)
        XCTAssertEqual(mediaServicesType, .transientFailure)
        XCTAssertFalse(mediaServicesType.isPermanent)

        let decodeFailed = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.Code.decodeFailed.rawValue,
            userInfo: nil
        )
        let decodeType = StreamErrorType.from(error: decodeFailed)
        XCTAssertEqual(decodeType, .transientFailure)
        XCTAssertFalse(decodeType.isPermanent)

        // Terminal AV content failures must not auto-recreate forever.
        let contentUnavailable = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.Code.contentIsUnavailable.rawValue,
            userInfo: nil
        )
        let contentType = StreamErrorType.from(error: contentUnavailable)
        XCTAssertEqual(contentType, .permanentFailure)
        XCTAssertTrue(contentType.isPermanent)

        let timedOut = URLError(.timedOut)
        XCTAssertEqual(StreamErrorType.from(error: timedOut), .transientFailure)
        let connectionLost = URLError(.networkConnectionLost)
        XCTAssertEqual(StreamErrorType.from(error: connectionLost), .transientFailure)
    }

    func testSecureNetworkingConfigurationFactory() {
        // The factory is the single source of truth for DNSSEC-enabled sessions.
        let config = SecurityConfiguration.makeSecureEphemeralConfiguration()

        // Policy bits that the secure factory is responsible for
        XCTAssertTrue(config.urlCache == nil)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertTrue(config.urlCredentialStorage == nil)

        // DNSSEC requirement must be on (the point of this change)
        XCTAssertTrue(config.requiresDNSSECValidation,
                      "Streaming and validation sessions must request DNSSEC-validated resolutions")

        // Protected host helper (sole media apex: siikkari.net)
        XCTAssertTrue(SecurityConfiguration.hostRequiresDNSSECValidation("livestream.siikkari.net"))
        XCTAssertTrue(SecurityConfiguration.hostRequiresDNSSECValidation("european.siikkari.net"))
        XCTAssertTrue(SecurityConfiguration.hostRequiresDNSSECValidation("finnish-eu.siikkari.net"))
        XCTAssertTrue(SecurityConfiguration.hostRequiresDNSSECValidation("siikkari.net"))
        // Retired media apex must not be treated as a protected streaming host.
        XCTAssertFalse(SecurityConfiguration.hostRequiresDNSSECValidation("livestream.lutheran.radio"))
        XCTAssertFalse(SecurityConfiguration.hostRequiresDNSSECValidation("en-eu.lutheran.radio"))
        XCTAssertFalse(SecurityConfiguration.hostRequiresDNSSECValidation("lutheran.radio"))
        XCTAssertFalse(SecurityConfiguration.hostRequiresDNSSECValidation("apple.com"))
        XCTAssertFalse(SecurityConfiguration.hostRequiresDNSSECValidation(nil))
    }
    
    /// Cluster list must prefer Core streaming apex (`siikkari.net`) with the
    /// operational ping hosts `european.siikkari.net` and `livestream.siikkari.net`.
    func testServerConfiguration() {
        let servers = DirectStreamingPlayer.servers
        let apex = SecurityConfiguration.current.preferredStreamingDomainSuffix
        
        XCTAssertEqual(apex, "siikkari.net")
        XCTAssertEqual(servers.count, 2)
        XCTAssertTrue(servers.contains { $0.name == "EU" })
        XCTAssertTrue(servers.contains { $0.name == "US" })
        
        let euServer = servers.first { $0.name == "EU" }
        XCTAssertNotNil(euServer)
        XCTAssertEqual(euServer?.subdomain, "eu")
        XCTAssertEqual(euServer?.baseHostname, apex)
        XCTAssertEqual(euServer?.pingURL.host, "european.siikkari.net")
        XCTAssertEqual(euServer?.pingURL.path, "/ping")
        
        let usServer = servers.first { $0.name == "US" }
        XCTAssertNotNil(usServer)
        XCTAssertEqual(usServer?.subdomain, "us")
        XCTAssertEqual(usServer?.baseHostname, apex)
        XCTAssertEqual(usServer?.pingURL.host, "livestream.siikkari.net")
        XCTAssertEqual(usServer?.pingURL.path, "/ping")
    }

    /// Stream catalog hosts must use preferred apex (e.g. finnish-eu.siikkari.net).
    func testStreamCatalogPrefersSiikkariApex() {
        let url = StreamCatalog.streamURL(languageCode: "fi", region: "eu")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "finnish-eu.siikkari.net")
        XCTAssertEqual(url.path, "/lutheranradio.mp3")
        XCTAssertTrue(url.query?.contains("security_model=\(SecurityConfiguration.current.expectedSecurityModel)") == true)
    }
    
    func testAvailableStreamsFromRealClass() {
        // Test the real DirectStreamingPlayer.availableStreams without creating an instance
        let streams = DirectStreamingPlayer.availableStreams
        
        XCTAssertEqual(streams.count, 5)
        XCTAssertTrue(streams.contains { $0.languageCode == "en" })
        XCTAssertTrue(streams.contains { $0.languageCode == "de" })
        XCTAssertTrue(streams.contains { $0.languageCode == "fi" })
        XCTAssertTrue(streams.contains { $0.languageCode == "sv" })
        XCTAssertTrue(streams.contains { $0.languageCode == "et" })
    }

    // MARK: - In-flight attach discard (user pause during connect)

    /// User pause must advance attach generation so post-`await` start paths discard without
    /// audible output. Protects the engine half of "pause during connect / first play".
    ///
    /// - SeeAlso: `DirectStreamingPlayer.invalidateInFlightPlaybackAttach`,
    ///   `shouldContinueInFlightAttach(startedAt:)`, SharedPlayerManager sticky `.userPaused`.
    func testStopInvalidatesInFlightAttachGeneration() async {
        let engine = DirectStreamingPlayer.shared
        await SharedPlayerManager.shared.setUserIntentToPlay()

        let generation = engine.test_beginInFlightPlaybackAttach()
        XCTAssertTrue(engine.test_isCurrentlyAttemptingPlayback)
        let mayContinueBeforeStop = await engine.test_shouldContinueInFlightAttach(startedAt: generation)
        XCTAssertTrue(
            mayContinueBeforeStop,
            "Live generation + active play intent must allow attach to continue"
        )

        // Await Icecast hard teardown — same completion contract SharedPlayerManager.stop uses.
        await engine.test_stopAndWait(
            reason: .userAction,
            silent: true,
            applyUserPauseVisualLock: false
        )

        XCTAssertNotEqual(
            engine.test_playbackAttachGeneration,
            generation,
            "stop must advance playbackAttachGeneration so in-flight attach discards"
        )
        let mayContinueAfterStop = await engine.test_shouldContinueInFlightAttach(startedAt: generation)
        XCTAssertFalse(
            mayContinueAfterStop,
            "Stale generation must fail shouldContinueInFlightAttach after stop"
        )
        XCTAssertFalse(
            engine.test_isSoftPaused,
            "user-action stopAndWait must not leave a retained Icecast item (loaders must be cancelled)"
        )
        XCTAssertFalse(
            engine.test_hasAttachedPlayerItem,
            "user-action stop must nil the player item so the keep-alive URLSession is cancelled"
        )
        XCTAssertTrue(
            engine.test_isPlaybackTeardownActive,
            "hard teardown must activate the playback teardown guard"
        )
        if let rate = engine.test_playerRate {
            XCTAssertEqual(rate, 0, accuracy: 0.001, "hard teardown must zero player rate before stopAndWait returns")
        }

        engine.test_endInFlightPlaybackAttach()
        XCTAssertFalse(engine.test_isCurrentlyAttemptingPlayback)
    }

    /// Hard-teardown completion is the engine-complete barrier for user pause: callers that
    /// refresh Now Playing / Live Activity must not observe return while the Icecast
    /// URLSession is still running.
    ///
    /// Protects: paused chrome cannot sit on a live keep-alive data task (Icecast still downloading).
    ///
    /// - SeeAlso: `DirectStreamingPlayer.stopAndWait`, `SharedPlayerManager.stop`,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md (user pause / transport coordination).
    func testStopAndWaitCompletesOnlyAfterHardTeardown() async {
        let engine = DirectStreamingPlayer.shared

        await engine.test_stopAndWait(
            reason: .userAction,
            silent: true,
            applyUserPauseVisualLock: false
        )

        XCTAssertFalse(
            engine.test_isSoftPaused,
            "user-action stopAndWait must clear isSoftPaused (no retained live item)"
        )
        XCTAssertFalse(
            engine.test_hasAttachedPlayerItem,
            "user-action stop must nil the player item"
        )
        XCTAssertTrue(
            engine.test_isPlaybackTeardownActive,
            "audible kick must stay blocked via the teardown guard after user pause"
        )
        if let rate = engine.test_playerRate {
            XCTAssertEqual(
                rate,
                0,
                accuracy: 0.001,
                "stopAndWait must apply rate 0 before resuming the caller"
            )
        }
        let canKick = await engine.test_shouldAllowAudiblePlaybackKick()
        XCTAssertFalse(
            canKick,
            "Audible kick must remain blocked after hard teardown"
        )
    }

    /// Pure Icecast kick policy: live attach waits for keep-up; soft-pause resume may kick immediately.
    ///
    /// Protects: `.readyToPlay` is not a healthy live MP3 buffer. `playImmediately` is reserved
    /// for already-buffered same-stream soft-resume. ``preferredLiveForwardBufferDuration`` is
    /// not a kick delay.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/audiblePlaybackKickTiming(itemIsReadyToPlay:isPlaybackLikelyToKeepUp:isSoftPauseSameStreamResume:)``,
    ///   ``DirectStreamingPlayer/shouldAllowAudiblePlaybackKick(startedAt:)``.
    func testAudiblePlaybackKickTimingPolicy() {
        XCTAssertEqual(
            DirectStreamingPlayer.audiblePlaybackKickTiming(
                itemIsReadyToPlay: false,
                isPlaybackLikelyToKeepUp: false,
                isSoftPauseSameStreamResume: false
            ),
            .waitForReadyToPlay,
            "Live attach must not play() / playImmediately before readyToPlay"
        )
        XCTAssertEqual(
            DirectStreamingPlayer.audiblePlaybackKickTiming(
                itemIsReadyToPlay: true,
                isPlaybackLikelyToKeepUp: false,
                isSoftPauseSameStreamResume: false
            ),
            .waitForLikelyToKeepUp,
            "Icecast readyToPlay without keep-up must stall-wait, not playImmediately"
        )
        XCTAssertEqual(
            DirectStreamingPlayer.audiblePlaybackKickTiming(
                itemIsReadyToPlay: true,
                isPlaybackLikelyToKeepUp: true,
                isSoftPauseSameStreamResume: false
            ),
            .kickNow(usePlayImmediately: false),
            "Live attach at keep-up uses play() (stall-wait remains on)"
        )
        XCTAssertEqual(
            DirectStreamingPlayer.audiblePlaybackKickTiming(
                itemIsReadyToPlay: true,
                isPlaybackLikelyToKeepUp: false,
                isSoftPauseSameStreamResume: true
            ),
            .kickNow(usePlayImmediately: true),
            "Soft-pause same-stream resume may playImmediately on an already-buffered item"
        )
        XCTAssertEqual(
            DirectStreamingPlayer.audiblePlaybackKickTiming(
                itemIsReadyToPlay: false,
                isPlaybackLikelyToKeepUp: false,
                isSoftPauseSameStreamResume: true
            ),
            .kickNow(usePlayImmediately: true),
            "Soft-pause resume must not wait for a cold live keep-up window"
        )
    }

    /// Explicit background Play may keep the process scheduled until the existing kick.
    ///
    /// Protects: an unknown item does not call `play()`; foreground cold launch does not
    /// take the hold; system expiration does not call `play()`; pause or a discarded
    /// attach ends the hold. UITestMode does not arm. `play()` stays on
    /// ``audiblePlaybackKickTiming`` (`.waitForReadyToPlay` while the item is unknown).
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/explicitBackgroundPlayHoldDecision(signal:context:)``,
    ///   ``DirectStreamingPlayer/audiblePlaybackKickTiming(itemIsReadyToPlay:isPlaybackLikelyToKeepUp:isSoftPauseSameStreamResume:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   docs/cold-launch-streamplay-regression-checklist.md.
    func testExplicitBackgroundPlayHoldPolicy() {
        let backgroundExplicit = DirectStreamingPlayer.ExplicitBackgroundPlayHoldContext(
            explicitUserPlay: true,
            itemAttached: true,
            isDeferringFirstPlayKick: true,
            playbackIntentAllowsAudio: true,
            sceneIsForeground: false,
            isTesting: false
        )

        XCTAssertEqual(
            DirectStreamingPlayer.explicitBackgroundPlayHoldDecision(
                signal: .deferredFirstKick,
                context: backgroundExplicit
            ),
            .armWithoutPlay,
            "Explicit background Play with a deferred kick arms without play()"
        )
        XCTAssertEqual(
            DirectStreamingPlayer.audiblePlaybackKickTiming(
                itemIsReadyToPlay: false,
                isPlaybackLikelyToKeepUp: false,
                isSoftPauseSameStreamResume: false
            ),
            .waitForReadyToPlay,
            "Unknown item must not play() or playImmediately; the hold does not change that"
        )

        var foregroundColdLaunch = backgroundExplicit
        foregroundColdLaunch.explicitUserPlay = false
        foregroundColdLaunch.sceneIsForeground = true
        XCTAssertEqual(
            DirectStreamingPlayer.explicitBackgroundPlayHoldDecision(
                signal: .deferredFirstKick,
                context: foregroundColdLaunch
            ),
            .leaveUnarmed,
            "Foreground cold launch must not take the background hold"
        )

        var inAppForeground = backgroundExplicit
        inAppForeground.sceneIsForeground = true
        XCTAssertEqual(
            DirectStreamingPlayer.explicitBackgroundPlayHoldDecision(
                signal: .deferredFirstKick,
                context: inAppForeground
            ),
            .leaveUnarmed,
            "Foreground explicit Play must not begin the background task"
        )

        var nobodyTappedPlay = backgroundExplicit
        nobodyTappedPlay.explicitUserPlay = false
        XCTAssertEqual(
            DirectStreamingPlayer.explicitBackgroundPlayHoldDecision(
                signal: .deferredFirstKick,
                context: nobodyTappedPlay
            ),
            .leaveUnarmed,
            "Factory reset and residual relaunch must not arm when nobody tapped Play"
        )

        var underTest = backgroundExplicit
        underTest.isTesting = true
        XCTAssertEqual(
            DirectStreamingPlayer.explicitBackgroundPlayHoldDecision(
                signal: .deferredFirstKick,
                context: underTest
            ),
            .leaveUnarmed,
            "UITestMode must not call beginBackgroundTask"
        )

        for signal in [
            DirectStreamingPlayer.ExplicitBackgroundPlayHoldSignal.systemExpired,
            .userPaused,
            .attachDiscarded,
            .audibleKickRan,
        ] {
            XCTAssertEqual(
                DirectStreamingPlayer.explicitBackgroundPlayHoldDecision(
                    signal: signal,
                    context: backgroundExplicit
                ),
                .endWithoutPlay,
                "\(signal) ends the hold and does not call play()"
            )
        }
    }

    /// Stream-switch hard stop nils `AVPlayer.currentItem`; other hard-stop reasons do not
    /// use that HAL detach. Soft-pause resume is not this path.
    ///
    /// Protects: language switch must not attach the next secured item onto a dirty player graph.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/shouldReplaceCurrentItemWithNilOnStop(reason:)``,
    ///   ``DirectStreamingPlayer/performActualStop(reason:silent:)``,
    ///   ``DirectStreamingPlayer/teardownSystemMediaSessionSynchronously()``.
    func testShouldReplaceCurrentItemWithNilOnStreamSwitchStop() {
        XCTAssertTrue(
            DirectStreamingPlayer.shouldReplaceCurrentItemWithNilOnStop(reason: .streamSwitch),
            "streamSwitch stop must replaceCurrentItem(nil) after pause + loader cancel"
        )
        XCTAssertFalse(
            DirectStreamingPlayer.shouldReplaceCurrentItemWithNilOnStop(reason: .userAction),
            "user pause is Icecast hard teardown of the same language — not the stream-switch HAL detach"
        )
        XCTAssertFalse(
            DirectStreamingPlayer.shouldReplaceCurrentItemWithNilOnStop(reason: .interruption)
        )
        XCTAssertFalse(
            DirectStreamingPlayer.shouldReplaceCurrentItemWithNilOnStop(reason: .error)
        )
    }

    /// Stream-switch `stopAndWait` leaves the same item-nil postcondition as system-media
    /// teardown for `playerItem` / current item, without requiring a live AVPlayer in XCTest.
    ///
    /// Protects: ``prepareStreamChoice(_:preparation:)`` `.switchPrep` finishes teardown
    /// before the next secured item attaches.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/stopAndWait(reason:silent:applyUserPauseVisualLock:)``,
    ///   ``DirectStreamingPlayer/shouldReplaceCurrentItemWithNilOnStop(reason:)``.
    func testStreamSwitchStopAndWaitNilsCurrentItem() async {
        let engine = DirectStreamingPlayer.shared
        await engine.test_stopAndWait(
            reason: .streamSwitch,
            silent: true,
            applyUserPauseVisualLock: false
        )
        XCTAssertFalse(
            engine.test_hasAttachedPlayerItem,
            "streamSwitch stop must nil playerItem"
        )
        XCTAssertFalse(
            engine.test_playerHasCurrentItem,
            "streamSwitch stop must leave AVPlayer.currentItem nil"
        )
        XCTAssertFalse(engine.test_isSoftPaused)
        XCTAssertTrue(
            engine.test_isPlaybackTeardownActive,
            "streamSwitch hard teardown must still arm the playback teardown guard"
        )
    }

    /// Sticky `.userPaused` alone (intent lock without generation bump) must still block audible kick.
    /// Generation and intent are complementary; readyToPlay uses the intent/soft-pause gate.
    func testAudibleKickBlockedWhenStickyUserPaused() async {
        let engine = DirectStreamingPlayer.shared
        await SharedPlayerManager.shared.stop()

        let canKick = await engine.test_shouldAllowAudiblePlaybackKick()
        XCTAssertFalse(
            canKick,
            "shouldAllowAudiblePlaybackKick must be false under sticky .userPaused (readyToPlay / head-start / recreate)"
        )
    }

    /// User-action stop advances ``playbackAttachGeneration`` first. A deferred keep-up KVO
    /// Task that still holds the pre-stop snapshot must not `play()` / publish after that bump
    /// even when teardown is already cleared and play intent is re-armed (the leftover hole:
    /// generation was not in ``shouldAllowAudiblePlaybackKick(startedAt:)``).
    ///
    /// Protects: stale live-attach kick after userAction stop. Current generation must still
    /// allow kick after attach returns — do not gate on ``isCurrentlyAttemptingPlayback``.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/shouldAllowAudiblePlaybackKick(startedAt:)``,
    ///   ``DirectStreamingPlayer/applyLiveAttachAudibleKickIfReady(itemIsReadyToPlay:isPlaybackLikelyToKeepUp:startedAt:)``,
    ///   ``DirectStreamingPlayer/shouldContinueInFlightAttach(startedAt:)``.
    func testAudibleKickRejectedForStaleAttachGeneration() async {
        let engine = DirectStreamingPlayer.shared

        await engine.test_stopAndWait(
            reason: .userAction,
            silent: true,
            applyUserPauseVisualLock: false
        )
        engine.test_clearPlaybackTeardownGuard()
        await SharedPlayerManager.shared.setUserIntentToPlay()

        let staleGeneration = engine.test_beginInFlightPlaybackAttach()
        engine.test_invalidateInFlightPlaybackAttach()
        engine.test_endInFlightPlaybackAttach()

        XCTAssertFalse(
            engine.test_isCurrentlyAttemptingPlayback,
            "Kick policy must not require an in-flight attach flag"
        )
        XCTAssertFalse(engine.test_isSoftPaused)
        XCTAssertFalse(engine.test_isPlaybackTeardownActive)
        XCTAssertNotEqual(
            staleGeneration,
            engine.test_playbackAttachGeneration,
            "invalidateInFlightPlaybackAttach must advance generation"
        )

        let staleKick = await engine.test_shouldAllowAudiblePlaybackKick(startedAt: staleGeneration)
        XCTAssertFalse(
            staleKick,
            "Stale attach generation must fail shouldAllowAudiblePlaybackKick even without teardown or sticky pause"
        )

        let currentKick = await engine.test_shouldAllowAudiblePlaybackKick(
            startedAt: engine.test_playbackAttachGeneration
        )
        XCTAssertTrue(
            currentKick,
            "Current generation + play intent + no teardown must still allow kick after attach returns"
        )

        let applied = await engine.test_applyLiveAttachAudibleKickIfReady(
            itemIsReadyToPlay: true,
            isPlaybackLikelyToKeepUp: true,
            startedAt: staleGeneration
        )
        XCTAssertFalse(
            applied,
            "Stale generation must not run the live-attach audible kick"
        )
    }

    /// Engine publish helper is the sole readyToPlay / soft-resume bridge to ``setPlaying()``.
    /// First call from Connecting (``.prePlay``) must flip chrome. A second call in sequence
    /// sees visual `.playing` and takes the already-playing no-op. That sequential no-op is
    /// this test. Two calls that both pass the visual read before either ``setPlaying``
    /// returns join one in-flight publish; that contract is
    /// ``testInFlightAuthoritativePlayingPublishLeavesPrePlayUntilTheClaimIsReleased``.
    ///
    /// - SeeAlso: `DirectStreamingPlayer.publishAuthoritativePlayingIfNeeded`,
    ///   ``DirectStreamingPlayer/admitAuthoritativePlayingPublish(inFlight:generation:currentGeneration:nextTicketID:)``,
    ///   ``SharedPlayerManager/setPlaying()``, docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    func testPublishAuthoritativePlayingIfNeededIsIdempotent() async {
        let engine = DirectStreamingPlayer.shared
        let manager = SharedPlayerManager.shared

        await manager.stop()
        await manager.setUserIntentToPlay()
        var visual = await manager.currentVisualState
        XCTAssertEqual(visual, .prePlay, "Arrange: Connecting chrome before engine publish")

        await engine.test_publishAuthoritativePlayingIfNeeded()
        visual = await manager.currentVisualState
        XCTAssertEqual(
            visual,
            .playing,
            "First publish after audible-start contract must call setPlaying"
        )

        await engine.test_publishAuthoritativePlayingIfNeeded()
        visual = await manager.currentVisualState
        XCTAssertEqual(
            visual,
            .playing,
            "Second publish must leave .playing (no-op when already authoritative)"
        )

        await manager.stop()
        await engine.test_publishAuthoritativePlayingIfNeeded()
        visual = await manager.currentVisualState
        XCTAssertEqual(
            visual,
            .userPaused,
            "Publish must not override sticky user pause after stop"
        )
    }

    /// Same-generation overlap joins one ``setPlaying``. A newer generation replaces the
    /// claim. The replaced ticket’s release leaves the new claim. A stale snapshot does
    /// not replace storage. Pure: no player and no `UserDefaults`.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/admitAuthoritativePlayingPublish(inFlight:generation:currentGeneration:nextTicketID:)``,
    ///   ``DirectStreamingPlayer/releaseAuthoritativePlayingPublish(inFlight:ticketID:)``.
    func testAuthoritativePlayingPublishAdmissionJoinsRefusesReplacesAndReleasesByTicket() {
        let began = DirectStreamingPlayer.admitAuthoritativePlayingPublish(
            inFlight: nil,
            generation: 4,
            currentGeneration: 4,
            nextTicketID: 10
        )
        let firstClaim = DirectStreamingPlayer.AuthoritativePlayingPublishClaim(
            ticketID: 10,
            generation: 4
        )
        XCTAssertEqual(began.admission, .begin(firstClaim))
        XCTAssertEqual(began.inFlight, firstClaim)

        let joined = DirectStreamingPlayer.admitAuthoritativePlayingPublish(
            inFlight: began.inFlight,
            generation: 4,
            currentGeneration: 4,
            nextTicketID: 11
        )
        XCTAssertEqual(joined.admission, .joinInFlight(firstClaim))
        XCTAssertEqual(
            joined.inFlight,
            firstClaim,
            "Join must not consume nextTicketID into a new claim"
        )

        let stale = DirectStreamingPlayer.admitAuthoritativePlayingPublish(
            inFlight: began.inFlight,
            generation: 3,
            currentGeneration: 4,
            nextTicketID: 12
        )
        XCTAssertEqual(stale.admission, .refuseStaleGeneration)
        XCTAssertEqual(stale.inFlight, firstClaim, "A stale snapshot must leave the stored claim")

        let replaced = DirectStreamingPlayer.admitAuthoritativePlayingPublish(
            inFlight: began.inFlight,
            generation: 5,
            currentGeneration: 5,
            nextTicketID: 20
        )
        let replacement = DirectStreamingPlayer.AuthoritativePlayingPublishClaim(
            ticketID: 20,
            generation: 5
        )
        XCTAssertEqual(replaced.admission, .begin(replacement))
        XCTAssertEqual(replaced.inFlight, replacement)

        let afterOldRelease = DirectStreamingPlayer.releaseAuthoritativePlayingPublish(
            inFlight: replaced.inFlight,
            ticketID: 10
        )
        XCTAssertEqual(afterOldRelease, replacement, "The replaced ticket must not clear the new claim")

        let afterNewRelease = DirectStreamingPlayer.releaseAuthoritativePlayingPublish(
            inFlight: afterOldRelease,
            ticketID: 20
        )
        XCTAssertNil(afterNewRelease, "Release of the stored ticket id clears the claim")
    }

    /// Holding the claim keeps visual `.prePlay` and records `reason=inFlightPublish`
    /// without `authoritativePlayingPublished`. Releasing it lets one publish reach
    /// `.playing` with one published mark.
    ///
    /// Why this pattern is required: the visual `!= .playing` read is after an `await`,
    /// so two callers can both pass it. This test holds the claim the publisher stores
    /// and does not sleep to overlap two kicks.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/publishAuthoritativePlayingIfNeeded(attachGenerationSnapshot:)``,
    ///   ``testPublishAuthoritativePlayingIfNeededIsIdempotent``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    func testInFlightAuthoritativePlayingPublishLeavesPrePlayUntilTheClaimIsReleased() async {
        let engine = DirectStreamingPlayer.shared
        let manager = SharedPlayerManager.shared

        await manager.stop()
        await manager.setUserIntentToPlay()
        var visual = await manager.currentVisualState
        XCTAssertEqual(visual, .prePlay, "Arrange: Connecting chrome before the in-flight claim")

        MediaTransportLatencyTimeline._test_resetAndStartCapture()
        let ticket = engine.test_holdAuthoritativePlayingPublishClaim(
            generation: engine.test_playbackAttachGeneration
        )
        defer {
            engine.test_releaseAuthoritativePlayingPublishClaim(ticketID: ticket)
            MediaTransportLatencyTimeline._test_clearCapture()
        }
        XCTAssertNotEqual(ticket, 0, "The current generation must begin a claim")

        await engine.test_publishAuthoritativePlayingIfNeeded()
        visual = await manager.currentVisualState
        XCTAssertEqual(visual, .prePlay, "An in-flight claim must not call setPlaying")
        let held = MediaTransportLatencyTimeline._test_samples()
        XCTAssertTrue(
            held.contains {
                $0.milestone == .authoritativePlayingSkipped && $0.detail == "reason=inFlightPublish"
            },
            "Join records authoritativePlayingSkipped reason=inFlightPublish"
        )
        XCTAssertFalse(
            held.contains { $0.milestone == .authoritativePlayingPublished },
            "Join must not record authoritativePlayingPublished"
        )

        engine.test_releaseAuthoritativePlayingPublishClaim(ticketID: ticket)
        MediaTransportLatencyTimeline._test_resetAndStartCapture()
        await engine.test_publishAuthoritativePlayingIfNeeded()
        visual = await manager.currentVisualState
        XCTAssertEqual(visual, .playing, "After release, one publish must call setPlaying")
        let published = MediaTransportLatencyTimeline._test_samples().filter {
            $0.milestone == .authoritativePlayingPublished
        }
        XCTAssertEqual(published.count, 1, "One admitted publish records one authoritativePlayingPublished")

        await manager.stop()
    }

    /// A snapshot that is not ``playbackAttachGeneration`` refuses at admission
    /// (`reason=staleGeneration`) and does not replace a claim the current generation holds.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/admitAuthoritativePlayingPublish(inFlight:generation:currentGeneration:nextTicketID:)``,
    ///   ``testInFlightAuthoritativePlayingPublishLeavesPrePlayUntilTheClaimIsReleased``.
    func testStaleGenerationAuthoritativePlayingPublishDoesNotTakeTheClaim() async {
        let engine = DirectStreamingPlayer.shared
        let manager = SharedPlayerManager.shared

        await manager.stop()
        await manager.setUserIntentToPlay()
        var visual = await manager.currentVisualState
        XCTAssertEqual(visual, .prePlay, "Arrange: Connecting chrome before a stale snapshot")

        MediaTransportLatencyTimeline._test_resetAndStartCapture()
        let current = engine.test_playbackAttachGeneration
        let ticket = engine.test_holdAuthoritativePlayingPublishClaim(generation: current)
        defer {
            engine.test_releaseAuthoritativePlayingPublishClaim(ticketID: ticket)
            MediaTransportLatencyTimeline._test_clearCapture()
        }
        XCTAssertNotEqual(ticket, 0, "The current generation must begin a claim")

        let stale = await engine.publishAuthoritativePlayingIfNeeded(
            attachGenerationSnapshot: current &+ 1
        )
        XCTAssertEqual(stale, .skipped)
        visual = await manager.currentVisualState
        XCTAssertEqual(visual, .prePlay, "A stale snapshot must not call setPlaying")
        let staleSamples = MediaTransportLatencyTimeline._test_samples()
        XCTAssertTrue(
            staleSamples.contains {
                $0.milestone == .authoritativePlayingSkipped && $0.detail == "reason=staleGeneration"
            },
            "Stale admission records authoritativePlayingSkipped reason=staleGeneration"
        )
        XCTAssertFalse(
            staleSamples.contains { $0.milestone == .authoritativePlayingPublished },
            "A stale snapshot must not record authoritativePlayingPublished"
        )

        MediaTransportLatencyTimeline._test_resetAndStartCapture()
        await engine.test_publishAuthoritativePlayingIfNeeded()
        visual = await manager.currentVisualState
        XCTAssertEqual(
            visual,
            .prePlay,
            "The stale call must not have replaced the current generation's claim"
        )
        let stillHeld = MediaTransportLatencyTimeline._test_samples()
        XCTAssertTrue(
            stillHeld.contains {
                $0.milestone == .authoritativePlayingSkipped && $0.detail == "reason=inFlightPublish"
            },
            "The original claim still joins"
        )

        await manager.stop()
    }

    /// An attaching hold whose destination differs from ``attachedItemLanguageCode``
    /// does not clear the hold and does not publish ``.playing``.
    ///
    /// ``canProceedWithPlayback()`` true is not enough. A ``playbackAttachGeneration``
    /// mismatch does not allow the publish. A matching destination language still
    /// clears the hold on the new station's audible start. Does **not** claim
    /// lock-screen paint.
    ///
    /// Why this pattern is required: the previous item can still be ``.playing`` after
    /// the chip sets the destination stamp. ``setPlaying()`` would clear the hold and
    /// the pause glyph would show during the silent teardown.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/shouldPublishAuthoritativePlayingForAudibleItem(canProceedWithPlayback:isStreamSwitchPrePlayHoldActive:attachedItemLanguageCode:destinationLanguageCode:attachGenerationSnapshot:currentAttachGeneration:)``,
    ///   ``DirectStreamingPlayer/publishAuthoritativePlayingIfNeeded(attachGenerationSnapshot:)``,
    ///   ``SharedPlayerManager/beginAttachingStreamSwitchPrePlayHold(languageCode:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    func testStaleAttachingAudiblePublishDoesNotClearConnectingHold() async {
        XCTAssertFalse(
            DirectStreamingPlayer.shouldPublishAuthoritativePlayingForAudibleItem(
                canProceedWithPlayback: true,
                isStreamSwitchPrePlayHoldActive: true,
                attachedItemLanguageCode: "et",
                destinationLanguageCode: "fi",
                attachGenerationSnapshot: nil,
                currentAttachGeneration: 1
            ),
            "canProceed true does not publish the previous station while the attaching hold is active"
        )
        XCTAssertTrue(
            DirectStreamingPlayer.shouldPublishAuthoritativePlayingForAudibleItem(
                canProceedWithPlayback: true,
                isStreamSwitchPrePlayHoldActive: true,
                attachedItemLanguageCode: "fi",
                destinationLanguageCode: "fi",
                attachGenerationSnapshot: 7,
                currentAttachGeneration: 7
            ),
            "A matching destination language still publishes on the new station's audible start"
        )
        XCTAssertFalse(
            DirectStreamingPlayer.shouldPublishAuthoritativePlayingForAudibleItem(
                canProceedWithPlayback: true,
                isStreamSwitchPrePlayHoldActive: false,
                attachedItemLanguageCode: "fi",
                destinationLanguageCode: "fi",
                attachGenerationSnapshot: 3,
                currentAttachGeneration: 4
            ),
            "A playbackAttachGeneration mismatch does not call publishAuthoritativePlayingIfNeeded"
        )
        XCTAssertTrue(
            DirectStreamingPlayer.shouldPublishAuthoritativePlayingForAudibleItem(
                canProceedWithPlayback: true,
                isStreamSwitchPrePlayHoldActive: false,
                attachedItemLanguageCode: "et",
                destinationLanguageCode: "fi",
                attachGenerationSnapshot: nil,
                currentAttachGeneration: 1
            ),
            "Without an attaching hold, language mismatch is not this gate"
        )
        XCTAssertFalse(
            DirectStreamingPlayer.shouldPublishAuthoritativePlayingForAudibleItem(
                canProceedWithPlayback: false,
                isStreamSwitchPrePlayHoldActive: false,
                attachedItemLanguageCode: "fi",
                destinationLanguageCode: "fi",
                attachGenerationSnapshot: nil,
                currentAttachGeneration: 1
            ),
            "Sticky pause still blocks publish"
        )

        let engine = DirectStreamingPlayer.shared
        let manager = SharedPlayerManager.shared
        await manager.stop()
        await manager.setUserIntentToPlay()
        await manager.beginAttachingStreamSwitchPrePlayHold(languageCode: "fi")
        engine.attachedItemLanguageCode = "et"

        await engine.test_publishAuthoritativePlayingIfNeeded()
        var visual = await manager.currentVisualState
        var hold = await manager.isStreamSwitchPrePlayHoldActive
        XCTAssertEqual(
            visual,
            .prePlay,
            "Previous-station audible publish must not call setPlaying"
        )
        XCTAssertTrue(hold, "Previous-station audible publish must not clear the Connecting hold")
        let destination = await manager.streamSwitchConnectingLanguageCode
        XCTAssertEqual(destination, "fi")

        engine.attachedItemLanguageCode = "fi"
        await engine.test_publishAuthoritativePlayingIfNeeded()
        visual = await manager.currentVisualState
        hold = await manager.isStreamSwitchPrePlayHoldActive
        XCTAssertEqual(visual, .playing, "Matching destination language still clears the hold")
        XCTAssertFalse(hold)

        engine.clearAttachedItemBinding()
        await manager.stop()
    }

    // MARK: - Early-window attach recovery (stream-switch / cold launch)

    /// Early-window recovery must hard-cap secured recreates so progressive ICY loading
    /// cannot thrash `recreatePlayerItem` while first-byte settles after a stream switch.
    ///
    /// Protects: each admitted recovery increments the shared budget; after
    /// `maxInitialRetries` admissions, further stall-class recoveries are refused.
    ///
    /// - SeeAlso: `DirectStreamingPlayer.attemptEarlyWindowTransientRecovery`,
    ///   `shouldAttemptEarlyAttachStallRecovery`,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§8).
    func testEarlyWindowRecoveryBudgetIsHardCapped() async {
        let engine = DirectStreamingPlayer.shared
        await SharedPlayerManager.shared.setUserIntentToPlay()
        engine.test_resetInitialPlaybackCountersForNewStream()
        // Allow the async counter-reset Task (if any) to settle.
        await Task.yield()
        engine.test_markCurrentAttachBegan(at: Date().addingTimeInterval(-10))

        let maxRetries = engine.test_maxInitialRetries
        XCTAssertGreaterThan(maxRetries, 0)

        for attempt in 1...maxRetries {
            let admitted = await engine.test_attemptEarlyWindowTransientRecovery(
                reason: "test-budget-\(attempt)",
                allowWhileDeferringFirstPlayKick: true
            )
            XCTAssertTrue(
                admitted,
                "Recovery attempt \(attempt)/\(maxRetries) must be admitted under active play intent"
            )
            XCTAssertEqual(
                engine.test_initialPlaybackRetryCount,
                attempt,
                "Each admission must increment the shared recreate budget"
            )
        }

        let overBudget = await engine.test_attemptEarlyWindowTransientRecovery(
            reason: "test-budget-exhausted",
            allowWhileDeferringFirstPlayKick: true
        )
        XCTAssertFalse(
            overBudget,
            "After maxInitialRetries admissions, early-window recovery must refuse further recreates"
        )
        XCTAssertEqual(
            engine.test_initialPlaybackRetryCount,
            maxRetries,
            "Exhausted budget must not keep incrementing"
        )

        await SharedPlayerManager.shared.stop()
    }

    /// Stall-class recovery must treat `AVPlayerItem.Status.unknown` without error as
    /// normal progressive loading inside the **first-byte** grace window — not an immediate recreate.
    ///
    /// Protects: the 4 s ready-but-silent window must not admit unknown items; cold DNSSEC
    /// first-byte often exceeds 5 s. Failed / error items are admitted immediately.
    ///
    /// - SeeAlso: `DirectStreamingPlayer.shouldAttemptEarlyAttachStallRecovery`,
    ///   ``DirectStreamingPlayer/earlyAttachFirstByteGraceSeconds``,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§8 loading grace).
    func testEarlyAttachStallRecoveryRespectsFirstByteGraceForUnknownItem() async {
        let engine = DirectStreamingPlayer.shared
        engine.test_resetInitialPlaybackCountersForNewStream()
        await Task.yield()

        let firstByte = engine.test_earlyAttachFirstByteGraceSeconds
        XCTAssertGreaterThanOrEqual(firstByte, 15.0, "First-byte grace must outlast cold DNSSEC first-byte")
        XCTAssertLessThanOrEqual(firstByte, 20.0, "First-byte grace must stay in the documented 15–20 s band")

        // Fresh dummy item stays at .unknown without a real network load under UITest isolation.
        let loadingItem = AVPlayerItem(url: URL(string: "https://example.invalid/stream.mp3")!)

        engine.test_markCurrentAttachBegan(at: Date())
        XCTAssertFalse(
            engine.test_shouldAttemptEarlyAttachStallRecovery(item: loadingItem, rate: 0),
            "Unknown item inside first-byte grace must not be treated as an early stall"
        )
        XCTAssertFalse(
            engine.test_shouldStartupSafetyNetRecreate(item: loadingItem, rate: 0),
            "Startup safety net must refuse unknown-within-grace (no 5 s recreate)"
        )

        engine.test_markCurrentAttachBegan(at: Date().addingTimeInterval(-10))
        XCTAssertFalse(
            engine.test_shouldAttemptEarlyAttachStallRecovery(item: loadingItem, rate: 0),
            "10 s is still inside first-byte grace — unknown must not recreate"
        )
        XCTAssertFalse(
            engine.test_shouldStartupSafetyNetRecreate(item: loadingItem, rate: 0),
            "Safety net must not admit unknown at 10 s"
        )

        engine.test_markCurrentAttachBegan(at: Date().addingTimeInterval(-(firstByte + 1)))
        XCTAssertTrue(
            engine.test_shouldAttemptEarlyAttachStallRecovery(item: loadingItem, rate: 0),
            "After first-byte grace expires, unknown + rate 0 may enter stall recovery"
        )
        XCTAssertTrue(
            engine.test_shouldStartupSafetyNetRecreate(item: loadingItem, rate: 0),
            "After first-byte grace, safety net may last-resort recreate"
        )
    }

    /// Pure policy: `.failed` / item error admits stall recovery immediately; ready-but-silent
    /// is admitted; unknown inside first-byte grace is refused.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/shouldAttemptEarlyAttachStallRecovery(hasStartedPlaying:retryCount:maxRetries:rate:itemStatus:itemHasError:remainingFirstByteGraceSeconds:)``
    func testEarlyAttachStallRecoveryPolicyAdmitsFailedAndRefusesUnknownInGrace() {
        XCTAssertTrue(
            DirectStreamingPlayer.shouldAttemptEarlyAttachStallRecovery(
                hasStartedPlaying: false,
                retryCount: 0,
                maxRetries: 2,
                rate: 0,
                itemStatus: .failed,
                itemHasError: true,
                remainingFirstByteGraceSeconds: 18
            ),
            "Failed item must be admitted even while first-byte grace remains"
        )
        XCTAssertTrue(
            DirectStreamingPlayer.shouldAttemptEarlyAttachStallRecovery(
                hasStartedPlaying: false,
                retryCount: 0,
                maxRetries: 2,
                rate: 0,
                itemStatus: .readyToPlay,
                itemHasError: false,
                remainingFirstByteGraceSeconds: 18
            ),
            "Ready-but-silent uses the short loading grace (caller debounce), not first-byte"
        )
        XCTAssertFalse(
            DirectStreamingPlayer.shouldAttemptEarlyAttachStallRecovery(
                hasStartedPlaying: false,
                retryCount: 0,
                maxRetries: 2,
                rate: 0,
                itemStatus: .unknown,
                itemHasError: false,
                remainingFirstByteGraceSeconds: 18
            ),
            "Unknown + no error inside first-byte grace is normal loading"
        )
        XCTAssertTrue(
            DirectStreamingPlayer.shouldAttemptEarlyAttachStallRecovery(
                hasStartedPlaying: false,
                retryCount: 0,
                maxRetries: 2,
                rate: 0,
                itemStatus: .unknown,
                itemHasError: false,
                remainingFirstByteGraceSeconds: 0
            ),
            "Unknown after first-byte grace may recreate as last resort"
        )
    }

    /// Safety-net recreate may leave a cluster that never delivered this mount’s first
    /// byte. It must not leave a cluster that already started audio, a ready or failed
    /// item, or a mount that did not inherit an earlier cluster. Soft-pause resume does
    /// not set the inherited flag, so it cannot take this path.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/shouldLeaveInheritedClusterOnFirstByteSafetyNet(hasStartedPlaying:itemStatusUnknown:itemHasError:inheritedClusterFromEarlierMount:)``,
    ///   ``DirectStreamingPlayer/alternateProductionClusterSubdomain(currentSubdomain:productionSubdomains:)``,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§8).
    func testSafetyNetMayLeaveInheritedClusterThatNeverDeliveredFirstByte() {
        XCTAssertTrue(
            DirectStreamingPlayer.shouldLeaveInheritedClusterOnFirstByteSafetyNet(
                hasStartedPlaying: false,
                itemStatusUnknown: true,
                itemHasError: false,
                inheritedClusterFromEarlierMount: true
            )
        )
        XCTAssertFalse(
            DirectStreamingPlayer.shouldLeaveInheritedClusterOnFirstByteSafetyNet(
                hasStartedPlaying: true,
                itemStatusUnknown: true,
                itemHasError: false,
                inheritedClusterFromEarlierMount: true
            ),
            "A cluster that already started audio must stay"
        )
        XCTAssertFalse(
            DirectStreamingPlayer.shouldLeaveInheritedClusterOnFirstByteSafetyNet(
                hasStartedPlaying: false,
                itemStatusUnknown: true,
                itemHasError: false,
                inheritedClusterFromEarlierMount: false
            ),
            "Soft-pause resume and measured mounts must not change host"
        )
        XCTAssertFalse(
            DirectStreamingPlayer.shouldLeaveInheritedClusterOnFirstByteSafetyNet(
                hasStartedPlaying: false,
                itemStatusUnknown: false,
                itemHasError: false,
                inheritedClusterFromEarlierMount: true
            ),
            "Ready items recreate on the same URL"
        )
        XCTAssertFalse(
            DirectStreamingPlayer.shouldLeaveInheritedClusterOnFirstByteSafetyNet(
                hasStartedPlaying: false,
                itemStatusUnknown: true,
                itemHasError: true,
                inheritedClusterFromEarlierMount: true
            ),
            "Item errors stay on the secured same-URL recreate"
        )
        XCTAssertEqual(
            DirectStreamingPlayer.alternateProductionClusterSubdomain(
                currentSubdomain: "us",
                productionSubdomains: ["eu", "us"]
            ),
            "eu"
        )
        XCTAssertEqual(
            DirectStreamingPlayer.alternateProductionClusterSubdomain(
                currentSubdomain: "eu",
                productionSubdomains: ["eu", "us"]
            ),
            "us"
        )
        XCTAssertNil(
            DirectStreamingPlayer.alternateProductionClusterSubdomain(
                currentSubdomain: "eu",
                productionSubdomains: ["eu"]
            )
        )
        XCTAssertFalse(PlaybackAttachContext.resume.schedulesFirstAttachRecovery)
        XCTAssertTrue(PlaybackAttachContext.freshAttachAfterHardTeardown.schedulesFirstAttachRecovery)
    }

    /// Startup safety net delay must follow first-byte remaining time, not a magic 5 s.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/nextStartupSafetyNetDelaySeconds()``,
    ///   ``DirectStreamingPlayer/earlyAttachFirstByteGraceSeconds``
    func testStartupSafetyNetDelayFollowsFirstByteGrace() async {
        let engine = DirectStreamingPlayer.shared
        engine.test_resetInitialPlaybackCountersForNewStream()
        await Task.yield()

        engine.test_markCurrentAttachBegan(at: Date())
        let freshDelay = engine.test_nextStartupSafetyNetDelaySeconds()
        XCTAssertGreaterThan(
            freshDelay,
            14.0,
            "Fresh unknown attach must wait first-byte grace, not 5 s"
        )

        engine.test_markCurrentAttachBegan(
            at: Date().addingTimeInterval(-(engine.test_earlyAttachFirstByteGraceSeconds + 1))
        )
        let expiredDelay = engine.test_nextStartupSafetyNetDelaySeconds()
        XCTAssertLessThan(
            expiredDelay,
            1.0,
            "After first-byte grace the safety net may evaluate almost immediately"
        )
    }

    // MARK: - Force widget-save skip (attach / sticky chrome)

    /// Pure policy: status force-save skips sticky pause and sticky Connecting; still
    /// forces for error keys and for audible playing when visual is already ``.playing``.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/shouldSkipForceWidgetSaveOnStableStatus(isPlaying:reasonKey:visual:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    func testShouldSkipForceWidgetSaveOnStableStatusPolicy() {
        // Sticky pause: always skip force save.
        XCTAssertTrue(
            DirectStreamingPlayer.shouldSkipForceWidgetSaveOnStableStatus(
                isPlaying: false,
                reasonKey: "status_stopped",
                visual: .userPaused
            )
        )
        XCTAssertTrue(
            DirectStreamingPlayer.shouldSkipForceWidgetSaveOnStableStatus(
                isPlaying: false,
                reasonKey: "status_stopped",
                visual: .securityLocked
            )
        )

        // Sticky Connecting: skip status_stopped / connecting / buffering / deferred playing.
        XCTAssertTrue(
            DirectStreamingPlayer.shouldSkipForceWidgetSaveOnStableStatus(
                isPlaying: false,
                reasonKey: "status_stopped",
                visual: .prePlay
            ),
            "status_stopped during attach must not force-save while already Connecting"
        )
        XCTAssertTrue(
            DirectStreamingPlayer.shouldSkipForceWidgetSaveOnStableStatus(
                isPlaying: false,
                reasonKey: "status_connecting",
                visual: .prePlay
            )
        )
        XCTAssertTrue(
            DirectStreamingPlayer.shouldSkipForceWidgetSaveOnStableStatus(
                isPlaying: false,
                reasonKey: "status_buffering",
                visual: .cleared
            )
        )
        XCTAssertTrue(
            DirectStreamingPlayer.shouldSkipForceWidgetSaveOnStableStatus(
                isPlaying: true,
                reasonKey: "status_playing",
                visual: .prePlay
            ),
            "Deferred setPlaying while visual still Connecting must not force-save"
        )

        // Error / unavailability keys still force a save even on Connecting chrome.
        XCTAssertFalse(
            DirectStreamingPlayer.shouldSkipForceWidgetSaveOnStableStatus(
                isPlaying: false,
                reasonKey: "status_security_failed",
                visual: .prePlay
            )
        )
        XCTAssertFalse(
            DirectStreamingPlayer.shouldSkipForceWidgetSaveOnStableStatus(
                isPlaying: false,
                reasonKey: "status_stream_unavailable",
                visual: .prePlay
            )
        )
        XCTAssertFalse(
            DirectStreamingPlayer.shouldSkipForceWidgetSaveOnStableStatus(
                isPlaying: false,
                reasonKey: "status_failed",
                visual: .prePlay
            )
        )

        // Audible playing with visual already playing must force save (not skip).
        XCTAssertFalse(
            DirectStreamingPlayer.shouldSkipForceWidgetSaveOnStableStatus(
                isPlaying: true,
                reasonKey: "status_playing",
                visual: .playing
            )
        )

        // Transient connect/buffer while already playing → skip.
        XCTAssertTrue(
            DirectStreamingPlayer.shouldSkipForceWidgetSaveOnStableStatus(
                isPlaying: false,
                reasonKey: "status_connecting",
                visual: .playing
            )
        )
        XCTAssertTrue(
            DirectStreamingPlayer.shouldSkipForceWidgetSaveOnStableStatus(
                isPlaying: false,
                reasonKey: "status_buffering",
                visual: .playing
            )
        )
    }

    /// Protects: one HTTP 403 for the embedded model excludes that cluster for the
    /// process, schedules one URL on the other cluster, and does not same-URL recreate.
    /// A second cluster's 403 does not schedule a third URL. The query stays the
    /// embedded model.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/noteEmbeddedSecurityModelRejection(url:statusCode:)``,
    ///   ``DirectStreamingPlayer/performEmbeddedSecurityModelClusterFailover()``,
    ///   ``DirectStreamingPlayer/recreatePlayerItem(securedURL:)``
    func testEmbeddedSecurityModelRejectionDoesNotReopenThatCluster() async throws {
        let player = DirectStreamingPlayer.shared
        let previous = player.currentSelectedServer
        player.test_resetEmbeddedSecurityModelClusterRejections()
        defer {
            player.currentSelectedServer = previous
            player.test_resetEmbeddedSecurityModelClusterRejections()
        }

        let apex = SecurityConfiguration.current.preferredStreamingDomainSuffix
        let model = SecurityConfiguration.current.expectedSecurityModel
        let finnishEU = URL(string: "https://finnish-eu.\(apex)/lutheranradio.mp3?security_model=\(model)")!
        let finnishUS = URL(string: "https://finnish-us.\(apex)/lutheranradio.mp3?security_model=\(model)")!

        let first = player.noteEmbeddedSecurityModelRejection(url: finnishEU, statusCode: 403)
        guard case .failoverOnce(let subdomain) = first else {
            XCTFail("First refusal must failover once, got \(first)")
            return
        }
        XCTAssertEqual(subdomain, "us")
        XCTAssertEqual(player.embeddedSecurityModelRejectedSubdomains(), ["eu"])
        XCTAssertTrue(player.streamRequestTargetsRejectedEmbeddedSecurityModelCluster(finnishEU))

        let duplicate = player.noteEmbeddedSecurityModelRejection(url: finnishEU, statusCode: 403)
        XCTAssertEqual(duplicate, .waitForInFlightFailover)

        let recreatesBefore = player.test_recreatePlayerItemEntryCount
        player.recreatePlayerItem(securedURL: finnishEU)
        await Task.yield()
        await Task.yield()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(
            player.test_recreatePlayerItemEntryCount,
            recreatesBefore,
            "Same-URL recreate must not run for a cluster that refused the embedded model"
        )

        await player.performEmbeddedSecurityModelClusterFailover()
        let failoverURL = player.test_lastEmbeddedSecurityModelFailoverURL
        XCTAssertEqual(
            DirectStreamingPlayer.productionClusterSubdomain(
                host: failoverURL?.host ?? "",
                apex: apex,
                productionSubdomains: DirectStreamingPlayer.servers.map(\.subdomain)
            ),
            "us"
        )
        let items = URLComponents(url: failoverURL ?? finnishUS, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertTrue(items?.contains { $0.name == "security_model" && $0.value == model } == true)
        XCTAssertEqual(player.test_recreatePlayerItemEntryCount, recreatesBefore)

        let secondCluster = player.noteEmbeddedSecurityModelRejection(url: finnishUS, statusCode: 403)
        XCTAssertEqual(secondCluster, .terminalLock)
        XCTAssertFalse(player.hasEligibleProductionCluster())
        XCTAssertEqual(
            player.noteEmbeddedSecurityModelRejection(url: finnishUS, statusCode: 403),
            .terminalLock,
            "A later 403 on a refused cluster must not schedule another stream URL"
        )
    }

    /// Protects: HTTP 503 and 429 are crowded, 404/502/504 are resource, and HTTP 500
    /// stays a transient `badServerResponse` with no capacity condition.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer/stationCapacityURLError(statusCode:)``,
    ///   ``DirectStreamingPlayer/stationCapacityCondition(for:)``,
    ///   ``StreamErrorType/from(error:)``
    func testStationCapacityStatusMapLeavesHTTP500Transient() {
        let resourceKey = DirectStreamingPlayer.stationCapacityResourceUserInfoKey
        let crowded503 = DirectStreamingPlayer.stationCapacityURLError(statusCode: 503)
        let crowded429 = DirectStreamingPlayer.stationCapacityURLError(statusCode: 429)
        XCTAssertEqual(crowded503?.code, .resourceUnavailable)
        XCTAssertEqual(crowded429?.code, .resourceUnavailable)
        XCTAssertEqual(DirectStreamingPlayer.stationCapacityCondition(statusCode: 503), .crowded)
        XCTAssertEqual(DirectStreamingPlayer.stationCapacityCondition(statusCode: 429), .crowded)
        XCTAssertEqual(DirectStreamingPlayer.stationCapacityCondition(for: URLError(.resourceUnavailable)), .crowded)

        let missing = DirectStreamingPlayer.stationCapacityURLError(statusCode: 404)
        XCTAssertEqual(missing?.code, .fileDoesNotExist)
        XCTAssertEqual(DirectStreamingPlayer.stationCapacityCondition(for: URLError(.fileDoesNotExist)), .resource)

        for status in [502, 504] {
            let error = DirectStreamingPlayer.stationCapacityURLError(statusCode: status)
            XCTAssertEqual(error?.code, .badServerResponse)
            XCTAssertEqual(error?.userInfo[resourceKey] as? Bool, true)
            if let error {
                XCTAssertEqual(DirectStreamingPlayer.stationCapacityCondition(for: error), .resource)
            }
        }

        XCTAssertNil(DirectStreamingPlayer.stationCapacityURLError(statusCode: 500))
        XCTAssertNil(DirectStreamingPlayer.stationCapacityURLError(statusCode: 403))
        XCTAssertNil(DirectStreamingPlayer.stationCapacityCondition(statusCode: 500))
        XCTAssertNil(DirectStreamingPlayer.stationCapacityCondition(statusCode: 403))
        XCTAssertNil(DirectStreamingPlayer.stationCapacityCondition(for: URLError(.badServerResponse)))
        XCTAssertEqual(StreamErrorType.from(error: URLError(.badServerResponse)), .transientFailure)
        XCTAssertEqual(StreamErrorType.from(error: URLError(.resourceUnavailable)), .permanentFailure)
        let contentUnavailable = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.Code.contentIsUnavailable.rawValue
        )
        XCTAssertEqual(DirectStreamingPlayer.stationCapacityCondition(for: contentUnavailable), .resource)
        XCTAssertTrue(DirectStreamingPlayer.isPlayedResourceUnavailable(contentUnavailable))
    }

    /// Protects: one 503 moves to the other region, a duplicate of that region joins,
    /// and Europe 503 plus US 502 selects resource. The refused URL is not recreated.
    func testStationCapacityOneFailoverThenResourceStops() async {
        let player = DirectStreamingPlayer.shared
        let previous = player.currentSelectedServer
        player.test_resetStationCapacityAttempt()
        player.test_resetEmbeddedSecurityModelClusterRejections()
        defer {
            player.currentSelectedServer = previous
            player.test_resetStationCapacityAttempt()
            player.test_resetEmbeddedSecurityModelClusterRejections()
        }
        let finnishEU = stationCapacityFinnishURL(region: "eu")
        let recreatesBefore = player.test_recreatePlayerItemEntryCount

        let first = player.noteStationCapacityHTTPResponse(url: finnishEU, statusCode: 503)
        XCTAssertEqual(first, .failoverOnce("us"))
        XCTAssertTrue(player.embeddedSecurityModelRejectedSubdomains().isEmpty)

        player.recreatePlayerItem(securedURL: finnishEU)
        await Task.yield()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(player.test_recreatePlayerItemEntryCount, recreatesBefore)

        await player.performStationCapacityFailover()
        let failoverHost = player.test_lastStationCapacityFailoverURL?.host ?? ""
        XCTAssertEqual(
            DirectStreamingPlayer.productionClusterSubdomain(
                host: failoverHost,
                apex: SecurityConfiguration.current.preferredStreamingDomainSuffix,
                productionSubdomains: DirectStreamingPlayer.servers.map(\.subdomain)
            ),
            "us"
        )
        XCTAssertEqual(player.test_recreatePlayerItemEntryCount, recreatesBefore)

        let duplicate = player.noteStationCapacityHTTPResponse(url: finnishEU, statusCode: 503)
        XCTAssertEqual(duplicate, .joinInFlight)

        let unitedStates = stationCapacityFinnishURL(region: "us")
        let second = player.noteStationCapacityHTTPResponse(url: unitedStates, statusCode: 502)
        XCTAssertEqual(second, .terminal(.resource))
        await player.finishStationCapacityAttempt()
        XCTAssertEqual(player.test_lastStationCapacityReasonKey, "status_resource")
        XCTAssertNotEqual(player.test_lastStationCapacityReasonKey, "status_security_failed")
        XCTAssertTrue(player.embeddedSecurityModelRejectedSubdomains().isEmpty)
    }

    /// Protects: both regions answering 503 selects crowded, and the attempt does not loop.
    func testStationCapacityBothRegionsCrowded() async {
        let player = DirectStreamingPlayer.shared
        player.test_resetStationCapacityAttempt()
        defer { player.test_resetStationCapacityAttempt() }
        let first = player.noteStationCapacityHTTPResponse(url: stationCapacityFinnishURL(region: "eu"), statusCode: 503)
        XCTAssertEqual(first, .failoverOnce("us"))
        let second = player.noteStationCapacityHTTPResponse(url: stationCapacityFinnishURL(region: "us"), statusCode: 503)
        XCTAssertEqual(second, .terminal(.crowded))
        await player.finishStationCapacityAttempt()
        XCTAssertEqual(player.test_lastStationCapacityReasonKey, "status_crowded")
        let again = player.noteStationCapacityHTTPResponse(url: stationCapacityFinnishURL(region: "eu"), statusCode: 429)
        if case .failoverOnce = again {
            XCTFail("A spent generation must not open another capacity attach")
        }
    }

    /// Protects: a 503 or 502 whose query is the embedded model does not security-lock
    /// and does not enter the rejection set. HTTP 403 with that query still failovers once.
    func testStationCapacityDoesNotTreatEmbeddedModelQueryAsSecurityFailure() async {
        let player = DirectStreamingPlayer.shared
        player.test_resetStationCapacityAttempt()
        player.test_resetEmbeddedSecurityModelClusterRejections()
        defer {
            player.test_resetStationCapacityAttempt()
            player.test_resetEmbeddedSecurityModelClusterRejections()
        }
        let finnishEU = stationCapacityFinnishURL(region: "eu")
        XCTAssertEqual(
            player.noteEmbeddedSecurityModelRejection(url: finnishEU, statusCode: 503),
            .notThisFailure
        )
        XCTAssertEqual(
            player.noteEmbeddedSecurityModelRejection(url: finnishEU, statusCode: 502),
            .notThisFailure
        )
        XCTAssertTrue(player.embeddedSecurityModelRejectedSubdomains().isEmpty)
        let capacity = player.noteStationCapacityHTTPResponse(url: finnishEU, statusCode: 503)
        XCTAssertEqual(capacity, .failoverOnce("us"))
        XCTAssertTrue(player.embeddedSecurityModelRejectedSubdomains().isEmpty)
        XCTAssertNotEqual(player.test_lastStationCapacityReasonKey, "status_security_failed")

        player.test_resetStationCapacityAttempt()
        player.test_resetEmbeddedSecurityModelClusterRejections()
        let security = player.noteEmbeddedSecurityModelRejection(url: finnishEU, statusCode: 403)
        XCTAssertEqual(security, .failoverOnce("us"))
        XCTAssertEqual(
            player.noteStationCapacityHTTPResponse(url: finnishEU, statusCode: 403),
            .notThisResponse
        )
        XCTAssertEqual(player.embeddedSecurityModelRejectedSubdomains(), ["eu"])
    }

    /// Protects: content unavailable after headers is resource and does not open the other region.
    func testStationCapacityContentUnavailableDoesNotFailover() async {
        let player = DirectStreamingPlayer.shared
        player.test_resetStationCapacityAttempt()
        defer { player.test_resetStationCapacityAttempt() }
        let disposition = player.noteStationContentUnavailable(url: stationCapacityFinnishURL(region: "eu"))
        XCTAssertEqual(disposition, .terminal(.resource))
        await player.finishStationCapacityAttempt()
        XCTAssertEqual(player.test_lastStationCapacityReasonKey, "status_resource")
        XCTAssertNil(player.test_lastStationCapacityFailoverURL)
        let later = player.noteStationCapacityHTTPResponse(url: stationCapacityFinnishURL(region: "us"), statusCode: 503)
        XCTAssertEqual(later, .terminal(.resource))
    }

    /// Protects: a region already refused for the embedded model is not used as the capacity failover.
    func testStationCapacitySkipsSecurityRejectedRegion() {
        let player = DirectStreamingPlayer.shared
        player.test_resetStationCapacityAttempt()
        player.test_resetEmbeddedSecurityModelClusterRejections()
        defer {
            player.test_resetStationCapacityAttempt()
            player.test_resetEmbeddedSecurityModelClusterRejections()
        }
        let rejection = player.noteEmbeddedSecurityModelRejection(
            url: stationCapacityFinnishURL(region: "eu"),
            statusCode: 403
        )
        XCTAssertEqual(rejection, .failoverOnce("us"))
        let crowded = player.noteStationCapacityHTTPResponse(
            url: stationCapacityFinnishURL(region: "us"),
            statusCode: 503
        )
        XCTAssertEqual(crowded, .terminal(.crowded))
        XCTAssertNil(player.test_lastStationCapacityFailoverURL)
    }

    /// Protects: after one capacity move, a 403 on the destination uses only the
    /// embedded-model walk. A later 503 stops instead of opening another capacity attach.
    func testStationCapacitySecurityTakeoverDoesNotLoop() async {
        let player = DirectStreamingPlayer.shared
        let previous = player.currentSelectedServer
        player.test_resetStationCapacityAttempt()
        player.test_resetEmbeddedSecurityModelClusterRejections()
        defer {
            player.currentSelectedServer = previous
            player.test_resetStationCapacityAttempt()
            player.test_resetEmbeddedSecurityModelClusterRejections()
        }
        let first = player.noteStationCapacityHTTPResponse(
            url: stationCapacityFinnishURL(region: "eu"),
            statusCode: 503
        )
        XCTAssertEqual(first, .failoverOnce("us"))
        await player.performStationCapacityFailover()
        let security = player.noteEmbeddedSecurityModelRejection(
            url: stationCapacityFinnishURL(region: "us"),
            statusCode: 403
        )
        XCTAssertEqual(security, .failoverOnce("eu"))
        player.stationCapacitySecurityModelTookOver()
        let later = player.noteStationCapacityHTTPResponse(
            url: stationCapacityFinnishURL(region: "eu"),
            statusCode: 503
        )
        XCTAssertEqual(later, .terminal(.crowded))
        XCTAssertEqual(player.embeddedSecurityModelRejectedSubdomains(), ["us"])
        await player.finishStationCapacityAttempt()
        XCTAssertEqual(player.test_lastStationCapacityReasonKey, "status_crowded")
        XCTAssertNotEqual(player.test_lastStationCapacityReasonKey, "status_security_failed")
    }

    /// Protects: a new attach generation can failover once after the previous attempt stopped.
    func testStationCapacityNewGenerationCanFailoverAgain() async {
        let player = DirectStreamingPlayer.shared
        player.test_resetStationCapacityAttempt()
        defer { player.test_resetStationCapacityAttempt() }
        let first = player.noteStationCapacityHTTPResponse(
            url: stationCapacityFinnishURL(region: "eu"),
            statusCode: 503
        )
        XCTAssertEqual(first, .failoverOnce("us"))
        player.test_invalidateInFlightPlaybackAttach()
        let late = player.noteStationCapacityHTTPResponse(
            url: stationCapacityFinnishURL(region: "eu"),
            statusCode: 503
        )
        XCTAssertEqual(late, .ignored)
        player.test_resetStationCapacityAttempt()
        let again = player.noteStationCapacityHTTPResponse(
            url: stationCapacityFinnishURL(region: "eu"),
            statusCode: 503
        )
        XCTAssertEqual(again, .failoverOnce("us"))
    }

    /// Protects: loading errors for crowded and resource do not recreate or spend the early-window budget.
    func testHandleLoadingErrorCapacityDoesNotRecreate() async {
        let player = DirectStreamingPlayer.shared
        player.test_resetStationCapacityAttempt()
        defer { player.test_resetStationCapacityAttempt() }
        let recreatesBefore = player.test_recreatePlayerItemEntryCount
        let retriesBefore = player.initialPlaybackRetryCount

        await player.handleLoadingError(URLError(.resourceUnavailable))
        XCTAssertEqual(player.test_lastStationCapacityReasonKey, "status_crowded")
        XCTAssertEqual(player.test_recreatePlayerItemEntryCount, recreatesBefore)
        XCTAssertEqual(player.initialPlaybackRetryCount, retriesBefore)

        player.test_resetStationCapacityAttempt()
        await player.handleLoadingError(URLError(.fileDoesNotExist))
        XCTAssertEqual(player.test_lastStationCapacityReasonKey, "status_resource")
        XCTAssertEqual(player.test_recreatePlayerItemEntryCount, recreatesBefore)
        XCTAssertEqual(player.initialPlaybackRetryCount, retriesBefore)

        player.test_resetStationCapacityAttempt()
        let upstream = URLError(
            .badServerResponse,
            userInfo: [DirectStreamingPlayer.stationCapacityResourceUserInfoKey: true]
        )
        await player.handleLoadingError(upstream)
        XCTAssertEqual(player.test_lastStationCapacityReasonKey, "status_resource")
        XCTAssertEqual(player.test_recreatePlayerItemEntryCount, recreatesBefore)
        XCTAssertEqual(player.initialPlaybackRetryCount, retriesBefore)
    }

    /// Protects: the pill is one word on failure chrome, and the alert keys are the sentences.
    /// Playing and an explicit clear hide the word. `status_stopped` does not.
    func testStationCapacityPillKeepsFailureChromeAndAlertKeysAreSentences() throws {
        let model = PlayerViewModel()
        model.visualState = .userPaused
        let paused = PlayerVisualState.userPaused.makeStatusPresentation()
        model.noteStationTerminalStatusReason("status_crowded")
        XCTAssertEqual(model.statusPresentation.background, paused.background)
        XCTAssertEqual(model.statusPresentation.foreground, paused.foreground)
        XCTAssertEqual(model.statusPresentation.systemImage, paused.systemImage)
        let crowdedWord = String(localized: "status_crowded", table: "Localizable")
        XCTAssertEqual(model.statusPresentation.text, crowdedWord)
        XCTAssertNotEqual(model.statusPresentation.text, paused.text)
        XCTAssertNil(crowdedWord.rangeOfCharacter(from: .whitespacesAndNewlines))

        model.visualState = .playing
        let playing = PlayerVisualState.playing.makeStatusPresentation()
        XCTAssertEqual(model.statusPresentation.text, playing.text)

        model.clearStationTerminalStatusReason()
        model.visualState = .userPaused
        XCTAssertEqual(model.statusPresentation.text, paused.text)

        XCTAssertEqual(
            PlayerViewModel.stationCapacityAlertLocalizationKeys(for: "status_crowded")?.title,
            "crowded_title"
        )
        XCTAssertEqual(
            PlayerViewModel.stationCapacityAlertLocalizationKeys(for: "status_crowded")?.message,
            "crowded_message"
        )
        XCTAssertEqual(
            PlayerViewModel.stationCapacityAlertLocalizationKeys(for: "status_resource")?.title,
            "resource_title"
        )
        XCTAssertNil(PlayerViewModel.stationCapacityAlertLocalizationKeys(for: "status_failed"))

        XCTAssertTrue(PlayerViewModel.shouldClearStationTerminalStatus(reasonKey: "status_playing", visualState: nil))
        XCTAssertTrue(PlayerViewModel.shouldClearStationTerminalStatus(reasonKey: "status_paused", visualState: nil))
        XCTAssertTrue(PlayerViewModel.shouldClearStationTerminalStatus(reasonKey: "status_paused_call", visualState: nil))
        XCTAssertTrue(PlayerViewModel.shouldClearStationTerminalStatus(reasonKey: "status_connecting", visualState: nil))
        XCTAssertTrue(PlayerViewModel.shouldClearStationTerminalStatus(reasonKey: "status_security_failed", visualState: nil))
        XCTAssertFalse(PlayerViewModel.shouldClearStationTerminalStatus(reasonKey: "status_crowded", visualState: nil))
        XCTAssertFalse(PlayerViewModel.shouldClearStationTerminalStatus(reasonKey: "status_stopped", visualState: nil))
        XCTAssertTrue(PlayerViewModel.shouldClearStationTerminalStatus(reasonKey: nil, visualState: .playing))
        XCTAssertTrue(PlayerViewModel.shouldClearStationTerminalStatus(reasonKey: nil, visualState: .securityLocked))
        XCTAssertTrue(PlayerViewModel.shouldClearStationTerminalStatus(reasonKey: nil, visualState: .thermalPaused))
        XCTAssertTrue(PlayerViewModel.shouldClearStationTerminalStatus(reasonKey: nil, visualState: .cleared))
        XCTAssertFalse(PlayerViewModel.shouldClearStationTerminalStatus(reasonKey: nil, visualState: .userPaused))
        XCTAssertFalse(PlayerViewModel.shouldClearStationTerminalStatus(reasonKey: nil, visualState: .prePlay))

        let catalog = try stationCapacityCatalogStrings()
        let failedLanguages = try XCTUnwrap(catalog["status_failed"])
        for key in ["status_crowded", "status_resource"] {
            let entry = try XCTUnwrap(catalog[key])
            XCTAssertEqual(Set(entry.keys), Set(failedLanguages.keys))
            for (language, word) in entry {
                XCTAssertNil(
                    word.rangeOfCharacter(from: .whitespacesAndNewlines),
                    "\(key) \(language) must be one word"
                )
            }
        }
        XCTAssertEqual(
            catalog["crowded_message"]?["en"],
            "The station is full of people listening together right now. There will be room for you in a few minutes."
        )
        XCTAssertTrue(
            (catalog["crowded_message"]?["en"] ?? "").hasPrefix("The station is full of people listening together")
        )
        XCTAssertEqual(catalog["crowded_title"]?["en"], "Station is full")
        XCTAssertEqual(catalog["resource_title"]?["en"], "Station unavailable")
        XCTAssertEqual(
            catalog["resource_message"]?["en"],
            "This station is not being sent from the server right now. Please try again later."
        )
        for key in ["crowded_message", "resource_message", "crowded_title", "resource_title"] {
            let entry = try XCTUnwrap(catalog[key])
            XCTAssertEqual(Set(entry.keys), Set(failedLanguages.keys), key)
            if key.hasSuffix("message") {
                for (language, sentence) in entry {
                    let hasSpace = sentence.rangeOfCharacter(from: .whitespaces) != nil
                    let hasStop = sentence.contains("。") || sentence.contains("।") || sentence.contains("።")
                    XCTAssertTrue(hasSpace || hasStop, "\(key) \(language) must be a sentence")
                }
            }
        }
        let spoken = PlayerViewModel.stationTerminalStatusAnnouncement(for: "status_crowded")
        XCTAssertEqual(spoken, crowdedWord)
    }

    private func stationCapacityFinnishURL(region: String) -> URL {
        let apex = SecurityConfiguration.current.preferredStreamingDomainSuffix
        let model = SecurityConfiguration.current.expectedSecurityModel
        return URL(string: "https://finnish-\(region).\(apex)/lutheranradio.mp3?security_model=\(model)")!
    }

    /// Language code → translated value for the capacity catalog keys.
    private func stationCapacityCatalogStrings() throws -> [String: [String: String]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Lutheran Radio/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        let catalog = try XCTUnwrap(object as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        var flattened: [String: [String: String]] = [:]
        for key in [
            "status_failed", "status_crowded", "status_resource",
            "crowded_title", "crowded_message", "resource_title", "resource_message",
        ] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any])
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            var values: [String: String] = [:]
            for (language, payload) in localizations {
                let unit = try XCTUnwrap(payload as? [String: Any])
                let stringUnit = try XCTUnwrap(unit["stringUnit"] as? [String: Any])
                values[language] = try XCTUnwrap(stringUnit["value"] as? String)
            }
            flattened[key] = values
        }
        return flattened
    }
}
