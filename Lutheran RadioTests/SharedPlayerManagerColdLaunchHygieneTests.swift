//
//  SharedPlayerManagerColdLaunchHygieneTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 24.7.2026.
//
//  Cold-launch factory reset and Now Playing / language hygiene contracts.
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

/// Unit tests for cold-launch factory reset and system Now Playing hygiene.
///
/// Protects purge-only visual-state disk cleanup, termination / language SSOT rules,
/// and Live Activity language tracking independent of privacy-gated preferred widget
/// language. Emission and media-surface suites are separate files.
///
/// - SeeAlso: ``SharedPlayerManager/resetToFactoryDefaultsOnLaunch()``,
///   ``SharedPlayerManager/teardownNowPlayingSession()``,
///   ``SharedPlayerManager/preferredWidgetLanguage()``,
///   ``SharedPlayerManager/mainAppLiveActivityLanguageCode()``,
///   docs/Event-Driven-Refactor-Roadmap.md.
final class SharedPlayerManagerColdLaunchHygieneTests: XCTestCase {

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

    // MARK: - Cold launch and Now Playing hygiene

    /// System Now Playing metadata must be cleared on factory reset / teardown so stale
    /// Lock Screen / Control Center cards do not survive relaunch or reboot.
    ///
    /// - SeeAlso: ``SharedPlayerManager/teardownNowPlayingSession()``,
    ///   ``SharedPlayerManager/resetToFactoryDefaultsOnLaunch()``.
    func testTeardownNowPlayingSessionClearsSystemMetadata() async {
        await MainActor.run {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: "Svenska LIVE"
            ]
            MPNowPlayingInfoCenter.default().playbackState = .playing
        }

        await manager.teardownNowPlayingSession()

        await MainActor.run {
            XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
            XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .stopped)
        }
    }

    /// Protects cold-launch factory reset: stale on-disk visual state must never restore after relaunch.
    ///
    /// Seeds retired App Group keys left by pre-memory-only installs (snapshot blobs, playback
    /// bools, bare language). ``resetToFactoryDefaultsOnLaunch()`` must purge them via
    /// ``clearPersistedVisualStateKeysFromDisk()`` and leave `.prePlay` with no in-memory session
    /// snapshot so auto-play on first launch remains viable. Visual state is never upgraded from
    /// disk — purge only.
    ///
    /// - SeeAlso: ``SharedPlayerManager/resetToFactoryDefaultsOnLaunch()``,
    ///   ``SharedPlayerManager/clearPersistedVisualStateKeysFromDisk()``,
    ///   ``SharedPlayerManager/loadPersistedWidgetState()``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (OI-1).
    func testColdLaunchFactoryResetClearsDiskVisualStateAndReturnsPrePlay() async {
        let stale = SharedPlayerManager.PersistedWidgetState(
            visualState: .thermalPaused,
            currentLanguage: "sv"
        )
        let data = try! JSONEncoder().encode(stale)
        let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared")
        defaults?.set(data, forKey: "persistedWidgetState")
        defaults?.set(data, forKey: "playerVisualState")
        defaults?.set(true, forKey: "isPlaying")
        defaults?.set(true, forKey: "playing")
        defaults?.set(true, forKey: "hasError")
        defaults?.set("fi", forKey: "currentLanguage")
        // Retired operational App Group leftovers (no writers; must purge on factory reset).
        defaults?.set(Date().timeIntervalSince1970, forKey: "lastUserPauseTime")
        defaults?.set(0.75, forKey: "preferredVolume")
        // Stale durable LA toggle visual + language mirrors must not survive factory reset.
        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(.playing)
        SharedPlayerManager.persistLiveActivityLanguageMirror("fi")
        XCTAssertEqual(SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(), .playing)
        XCTAssertEqual(SharedPlayerManager.loadLiveActivityLanguageMirror(), "fi")

        await manager.resetToFactoryDefaultsOnLaunch()

        let visual = await manager.currentVisualState
        XCTAssertEqual(visual, .prePlay)
        XCTAssertTrue(visual.shouldAutoPlayOrResume)
        XCTAssertNil(SharedPlayerManager.loadPersistedWidgetState())
        XCTAssertEqual(SharedPlayerManager.loadPersistedVisualStateDirect(), .prePlay)
        XCTAssertNil(defaults?.data(forKey: "persistedWidgetState"))
        XCTAssertNil(defaults?.data(forKey: "playerVisualState"))
        XCTAssertNil(defaults?.object(forKey: "isPlaying"))
        XCTAssertNil(defaults?.object(forKey: "playing"))
        XCTAssertNil(defaults?.object(forKey: "hasError"))
        XCTAssertNil(
            defaults?.object(forKey: "currentLanguage"),
            "Retired bare currentLanguage must be purged with other visual keys"
        )
        XCTAssertNil(
            defaults?.object(forKey: "lastUserPauseTime"),
            "Retired lastUserPauseTime must be purged (in-actor pause barrier only)"
        )
        XCTAssertNil(
            defaults?.object(forKey: "preferredVolume"),
            "Retired preferredVolume must be purged (system volume is SSOT)"
        )
        XCTAssertNil(
            SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(),
            "Factory reset must explicitly clear liveActivityToggleVisualState"
        )
        XCTAssertNil(
            SharedPlayerManager.loadLiveActivityLanguageMirror(),
            "Factory reset must explicitly clear liveActivityCurrentLanguage"
        )
        // Boot identity realigned so same-boot post-reset planning is not false-reboot.
        XCTAssertFalse(SharedPlayerManager.hasDeviceRebootedSinceLastRecordedBoot())
    }

    /// With no session snapshot and no active home widgets, ``preferredWidgetLanguage()``
    /// hard-defaults to `"en"` even when a retired App Group `currentLanguage` value is present.
    ///
    /// **Privacy invariant protected:** bare language leftovers from pre-memory-only installs
    /// must not influence home-widget language when writes are suppressed. Resolution is
    /// snapshot → `bestInitialLanguageCode()` (widgets active) → hard `"en"` only — never the
    /// bare App Group key (which is also purged by ``clearPersistedVisualStateKeysFromDisk()``).
    ///
    /// - SeeAlso: ``SharedPlayerManager/preferredWidgetLanguage()``,
    ///   ``SharedPlayerManager/clearPersistedVisualStateKeysFromDisk()``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (OI-1).
    func testPreferredWidgetLanguageIgnoresRetiredBareCurrentLanguageKey() async {
        await manager.resetToFactoryDefaultsOnLaunch()
        await MainActor.run {
            WidgetRefreshManager.setHasActiveLutheranWidgets(false)
        }

        let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared")
        // Seed after factory purge so a pre-memory-only leftover is the only disk language signal.
        defaults?.set("sv", forKey: "currentLanguage")

        XCTAssertEqual(
            SharedPlayerManager.preferredWidgetLanguage(),
            "en",
            "No-widgets path must hard-default to en; bare currentLanguage is not a language SSOT"
        )

        SharedPlayerManager.clearPersistedVisualStateKeysFromDisk()
    }

    /// Main-app LA language SSOT tracks engine ``selectedStream``, not privacy-gated preferred widget language.
    ///
    /// When home widgets are absent, ``preferredWidgetLanguage()`` hard-defaults to `"en"`.
    /// Live Activity ContentState must still carry the stream attach language so Lock Screen
    /// flag/name chrome match the playing stream.
    func testMainAppLiveActivityLanguageCodeTracksSelectedStream() async {
        // `availableStreams` is a nonisolated sync property; no await required.
        let streams = manager.availableStreams
        guard let finnish = streams.first(where: { $0.languageCode == "fi" }) else {
            XCTFail("Expected Finnish stream in catalog")
            return
        }
        await manager.switchToStream(finnish)

        let selected = await MainActor.run {
            DirectStreamingPlayer.shared.selectedStream.languageCode
        }
        XCTAssertEqual(selected, "fi")
        XCTAssertEqual(
            SharedPlayerManager.mainAppLiveActivityLanguageCode(),
            "fi",
            "LA ContentState language source must follow stream attach language"
        )
    }
}
