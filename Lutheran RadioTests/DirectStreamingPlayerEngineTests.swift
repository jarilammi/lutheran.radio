//
//  DirectStreamingPlayerEngineTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 24.7.2026.
//
//  Real-engine integration coverage for ``DirectStreamingPlayer`` under the XCTest
//  host: attach-generation discard, hard-teardown barriers, early-window recovery,
//  UITestMode audio short-circuits (construction does not activate AVAudioSession;
//  first clip / play / attach await configure, which waits for factory deactivate),
//  production type / DNSSEC factory surfaces, and pure
//  ``shouldSkipForceWidgetSaveOnStableStatus`` policy.
//
//  - SeeAlso: ``DirectStreamingPlayer``, ``SharedPlayerManager``,
//    ``DirectStreamingPlayer/configureAudioSessionAsync()``,
//    ``DirectStreamingPlayer/shouldSkipForceWidgetSaveOnStableStatus(isPlaying:reasonKey:visual:)``,
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
        DirectStreamingPlayer.shared.test_resetAudioSessionMutationProbe()
    }

    override func tearDown() async throws {
        DirectStreamingPlayer.shared.test_resetAudioSessionMutationProbe()
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

    /// Engine publish helper is the sole readyToPlay / soft-resume bridge to ``setPlaying()``.
    /// First call from Connecting (``.prePlay``) must flip chrome; a second call must no-op so
    /// readyToPlay + timeControl KVO cannot double-emit ``streamDidStart``.
    ///
    /// - SeeAlso: `DirectStreamingPlayer.publishAuthoritativePlayingIfNeeded`,
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
    /// normal progressive loading inside the attach grace window — not an immediate recreate.
    ///
    /// - SeeAlso: `DirectStreamingPlayer.shouldAttemptEarlyAttachStallRecovery`,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§8 loading grace).
    func testEarlyAttachStallRecoveryRespectsLoadingGraceForUnknownItem() async {
        let engine = DirectStreamingPlayer.shared
        engine.test_resetInitialPlaybackCountersForNewStream()
        await Task.yield()

        // Fresh dummy item stays at .unknown without a real network load under UITest isolation.
        let loadingItem = AVPlayerItem(url: URL(string: "https://example.invalid/stream.mp3")!)

        engine.test_markCurrentAttachBegan(at: Date())
        XCTAssertFalse(
            engine.test_shouldAttemptEarlyAttachStallRecovery(item: loadingItem, rate: 0),
            "Unknown item inside loading grace must not be treated as an early stall"
        )

        engine.test_markCurrentAttachBegan(at: Date().addingTimeInterval(-10))
        XCTAssertTrue(
            engine.test_shouldAttemptEarlyAttachStallRecovery(item: loadingItem, rate: 0),
            "After loading grace expires, unknown + rate 0 may enter stall recovery"
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
}
