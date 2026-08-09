//
//  WidgetDisplayModelsExtensionTests.swift
//  LutheranRadioWidgetTests
//
//  Created by Jari Lammi on 15.7.2026.
//
//  Extension-profile linkage for membership-exception display models and Provider
//  synthesis. Full pure presentation matrices (every visual state, flag map) live
//  in WidgetSurfaceTests. This suite keeps snapshot / catalog / blueprint smoke that
//  exercises SharedPlayerManager under the widget compile profile, including
//  ``WidgetProviderSnapshotResolver`` live-chrome resolution (session vs mirror freshness)
//  and ``WidgetInteractivePaintHeal`` (lagging TimelineEntry wake tokens + fresher suite).
//
//  - SeeAlso: ``widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)``,
//    ``WidgetProviderSnapshotResolver``, ``WidgetInteractivePaintHeal``,
//    ``WidgetProviderPresentationAssembly``,
//    ``displayFlag(for:)``, ``displayLanguageName(for:)``,
//    docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§6),
//    docs/Widget-Functionality-Roadmap.md,
//    docs/Live-Activity-Stacking-and-Media-Surfaces.md (ContentState lag class — peer).
//

import XCTest
import WidgetSurface

/// Extension-profile snapshot resolver + thin presentation linkage smoke.
final class WidgetDisplayModelsExtensionTests: XCTestCase {

    private let manager = SharedPlayerManager.shared
    private let languageName = "TestLang"
    private let programTitle = "Sunday Sermon"
    private let speaker = "Guest Speaker"

    private var liveFallback: String {
        widgetLiveStreamFallback(languageName: languageName)
    }

    private var noTrackPlaceholder: String {
        String(localized: "no_track_info", defaultValue: "No track information", table: "Localizable")
    }

    private func metadata(title: String?, speaker: String? = nil) -> StreamProgramMetadata? {
        guard title != nil || speaker != nil else { return nil }
        return StreamProgramMetadata(programTitle: title, speaker: speaker)
    }

    private func resolve(
        visualState: PlayerVisualState,
        metadata: StreamProgramMetadata?
    ) -> WidgetNowPlayingDisplayModel {
        widgetNowPlayingDisplayModel(
            visualState: visualState,
            streamMetadata: metadata,
            languageName: languageName
        )
    }

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            WidgetRefreshManager.setHasActiveLutheranWidgets(true)
        }
        SharedPlayerManager.removeAllLocalPlaybackKeys()
    }

    override func tearDown() async throws {
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        try await super.tearDown()
    }

    // MARK: - Metadata resolver (representative extension-profile samples)

    func testPlayingWithoutMetadataUsesLiveFallbackActiveEmphasis() {
        let model = resolve(visualState: .playing, metadata: nil)
        XCTAssertEqual(model.programTitle, liveFallback)
        XCTAssertEqual(model.emphasis, .active)
        XCTAssertFalse(model.speakerVisible)
    }

    func testPlayingWithTitleAndSpeakerShowsSpeakerLine() {
        let model = resolve(visualState: .playing, metadata: metadata(title: programTitle, speaker: speaker))
        XCTAssertEqual(model.programTitle, programTitle)
        XCTAssertEqual(model.speakerLine, speaker)
        XCTAssertTrue(model.speakerVisible)
        XCTAssertEqual(model.emphasis, .active)
    }

    func testUserPausedWithoutMetadataUsesNoTrackPlaceholder() {
        let model = resolve(visualState: .userPaused, metadata: nil)
        XCTAssertEqual(model.programTitle, noTrackPlaceholder)
        XCTAssertEqual(model.emphasis, .placeholder)
    }

    // MARK: - Provider snapshot resolver (membership-exception SSOT)

    func testProviderSnapshotResolverReturnsPersistedFields() {
        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .userPaused,
            language: "sv",
            streamMetadata: metadata(title: programTitle, speaker: speaker),
            hasError: false
        )

        let fields = WidgetProviderSnapshotResolver.resolveFromSnapshot()
        XCTAssertEqual(fields.visualState, .userPaused)
        XCTAssertEqual(fields.currentLanguage, "sv")
        XCTAssertFalse(fields.hasError)
        XCTAssertEqual(fields.streamMetadata?.programTitle, programTitle)
    }

    func testProviderSnapshotResolverDefaultsToPrePlayWhenSnapshotAbsent() async {
        await SharedPlayerManager.clearAllLocalState()
        XCTAssertNil(SharedPlayerManager.loadPersistedWidgetState())

        let fields = WidgetProviderSnapshotResolver.resolveFromSnapshot()
        XCTAssertEqual(fields.visualState, .prePlay)
        XCTAssertFalse(fields.hasError)
        XCTAssertFalse(fields.currentLanguage.isEmpty)
    }

    // MARK: - Live chrome Provider resolution (session vs mirror freshness → factory)

    /// Protects design §6.1: when session RAM is nil, privacy-gated ``homeWidgetLiveChrome``
    /// paints visual + language + hasError (typical extension cold wake after main-only settle).
    ///
    /// - SeeAlso: ``WidgetProviderSnapshotResolver/resolveFromSnapshot()``,
    ///   ``SharedPlayerManager/loadHomeWidgetLiveChromeMirror()``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§6.1).
    func testProviderResolveUsesLiveChromeWhenSessionNil() {
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.clearHomeWidgetLiveChromeMirror()
        XCTAssertNil(SharedPlayerManager.loadPersistedWidgetState())

        SharedPlayerManager.stampHomeWidgetLiveChromeFromSession(
            visualState: .playing,
            language: "fi",
            hasError: false,
            reason: "testMirrorOnly"
        )
        XCTAssertNil(
            SharedPlayerManager.loadPersistedWidgetState(),
            "Precondition: session RAM must remain nil so mirror is the paint source"
        )

        let fields = WidgetProviderSnapshotResolver.resolveFromSnapshot()
        XCTAssertEqual(fields.visualState, .playing, "Nil session + mirror playing → paint playing")
        XCTAssertEqual(fields.currentLanguage, "fi")
        XCTAssertFalse(fields.hasError)
    }

    /// Protects fresher same-process optimistic session over a staler residual mirror.
    ///
    /// Seeds an older playing mirror, then a newer pause session without re-stamping the mirror
    /// to the same tick, so disagreement + freshness selects session.
    ///
    /// - SeeAlso: ``resolveHomeWidgetChromeFields(sessionVisual:sessionLanguage:sessionHasError:sessionUpdatedAt:liveChrome:)``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§6.2).
    func testProviderResolveFresherSessionWinsOverStaleLiveChromeMirror() {
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.clearHomeWidgetLiveChromeMirror()

        // Older residual main-style mirror still holding .playing.
        SharedPlayerManager.persistHomeWidgetLiveChromeMirror(
            HomeWidgetLiveChrome(
                visualState: .playing,
                currentLanguage: "en",
                hasError: false,
                updatedAt: 1_000,
                stampReason: "staleMainMirror"
            )
        )
        // Newer extension-session pause (do not call persistWidgetSnapshot — that would re-stamp
        // the mirror and collapse the disagreement under identity agreement).
        SharedPlayerManager.inMemorySessionWidgetSnapshot = SharedPlayerManager.PersistedWidgetState(
            visualState: .userPaused,
            currentLanguage: "sv",
            lastLanguageChangeTime: Date(timeIntervalSince1970: 2_000),
            streamMetadata: nil,
            hasError: false
        )

        let fields = WidgetProviderSnapshotResolver.resolveFromSnapshot()
        XCTAssertEqual(
            fields.visualState,
            .userPaused,
            "Fresher session pause must win over a staler mirror still holding .playing"
        )
        XCTAssertEqual(fields.currentLanguage, "sv")
        XCTAssertFalse(fields.hasError)
    }

    /// Protects P0 paint heal: fresher main-app ``homeWidgetLiveChrome`` ``.playing`` must beat
    /// a stale extension-session switch-hold ``.prePlay`` so home does not stay yellow Connecting
    /// after main settle + ``reloadTimelines``.
    ///
    /// - SeeAlso: ``resolveHomeWidgetChromeFields(sessionVisual:sessionLanguage:sessionHasError:sessionUpdatedAt:liveChrome:)``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§6.2).
    func testProviderResolveFresherLiveChromePlayingBeatsStaleSessionPrePlay() {
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.clearHomeWidgetLiveChromeMirror()

        // Stale extension optimistic switch hold left process-local Connecting chrome.
        SharedPlayerManager.inMemorySessionWidgetSnapshot = SharedPlayerManager.PersistedWidgetState(
            visualState: .prePlay,
            currentLanguage: "et",
            lastLanguageChangeTime: Date(timeIntervalSince1970: 1_000),
            streamMetadata: nil,
            hasError: false
        )
        // Main-app setPlaying settle projected a newer App Group live chrome.
        SharedPlayerManager.persistHomeWidgetLiveChromeMirror(
            HomeWidgetLiveChrome(
                visualState: .playing,
                currentLanguage: "et",
                hasError: false,
                updatedAt: 2_000,
                stampReason: "setPlaying"
            )
        )

        let fields = WidgetProviderSnapshotResolver.resolveFromSnapshot()
        XCTAssertEqual(
            fields.visualState,
            .playing,
            "Fresher live chrome .playing must heal stale extension-session .prePlay"
        )
        XCTAssertEqual(fields.currentLanguage, "et")
        XCTAssertFalse(fields.hasError)
    }

    /// Protects factory defaults when both session and live chrome are absent.
    ///
    /// - SeeAlso: docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§6.1 factory).
    func testProviderResolveFactoryWhenSessionAndLiveChromeAbsent() {
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.clearHomeWidgetLiveChromeMirror()
        XCTAssertNil(SharedPlayerManager.loadPersistedWidgetState())
        XCTAssertNil(SharedPlayerManager.loadHomeWidgetLiveChromeMirror())

        let fields = WidgetProviderSnapshotResolver.resolveFromSnapshot()
        XCTAssertEqual(fields.visualState, .prePlay)
        XCTAssertFalse(fields.hasError)
        XCTAssertFalse(fields.currentLanguage.isEmpty, "Factory language is preferredWidgetLanguage()")
    }

    /// Residual live chrome must not paint after simulated reboot (boot-identity distrust).
    ///
    /// **Invariant protected:** ``shouldDistrustDurableMirrorPlayPlanning()`` →
    /// ``resolveFromSnapshot`` ignores residual ``homeWidgetLiveChrome`` even when the App Group
    /// blob still holds ``.playing`` (dirty power-off never cleared the mirror).
    ///
    /// - SeeAlso: ``WidgetProviderSnapshotResolver/resolveFromSnapshot()``,
    ///   ``SharedPlayerManager/shouldDistrustDurableMirrorPlayPlanning()``,
    ///   ``resolveHomeWidgetChromeFields(sessionVisual:sessionLanguage:sessionHasError:sessionUpdatedAt:liveChrome:distrustLiveChrome:)``.
    func testProviderResolveIgnoresResidualLiveChromeAfterSimulatedReboot() {
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        SharedPlayerManager.recordCurrentSystemBootTime()
        XCTAssertNil(SharedPlayerManager.loadPersistedWidgetState())

        // Seed residual while still on a trusted boot identity (pre-reboot main-app stamp).
        SharedPlayerManager.persistHomeWidgetLiveChromeMirror(
            HomeWidgetLiveChrome(
                visualState: .playing,
                currentLanguage: "fi",
                hasError: false,
                updatedAt: Date().timeIntervalSince1970,
                stampReason: "preRebootResidual"
            )
        )
        XCTAssertEqual(SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.visualState, .playing)

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        // Simulate hard power-off: prior boot epoch remains; live-chrome blob survives.
        defaults.set(1.0, forKey: SharedPlayerManager.recordedSystemBootTimeAppGroupKey)
        XCTAssertTrue(SharedPlayerManager.hasDeviceRebootedSinceLastRecordedBoot())
        XCTAssertTrue(SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning())
        XCTAssertEqual(
            SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.visualState,
            .playing,
            "Precondition: residual blob still on disk after boot-identity mismatch"
        )

        let fields = WidgetProviderSnapshotResolver.resolveFromSnapshot()
        XCTAssertEqual(
            fields.visualState,
            .prePlay,
            "Reboot distrust must paint factory, not residual .playing"
        )
        XCTAssertFalse(fields.hasError)
        XCTAssertFalse(fields.currentLanguage.isEmpty, "Factory language is preferredWidgetLanguage()")
    }

    /// Termination sentinel alone also drops residual live chrome for Provider paint.
    ///
    /// Force-quit class residual: delivered terminate clears the mirror, but a residual blob can
    /// remain when `willTerminate` never ran. Seed residual first, then write the sentinel
    /// without re-clearing via the full terminate helper, by restoring a post-sentinel blob
    /// with a non-playing visual that the write path still allows under distrust.
    ///
    /// - SeeAlso: ``SharedPlayerManager/forceStaleLivenessTimestampForTermination()``,
    ///   ``WidgetProviderSnapshotResolver/resolveFromSnapshot()``.
    func testProviderResolveIgnoresResidualLiveChromeAfterTerminationSentinel() {
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        SharedPlayerManager.recordCurrentSystemBootTime()

        SharedPlayerManager.persistHomeWidgetLiveChromeMirror(
            HomeWidgetLiveChrome(
                visualState: .userPaused,
                currentLanguage: "sv",
                hasError: false,
                updatedAt: Date().timeIntervalSince1970,
                stampReason: "preTerminateResidual"
            )
        )
        XCTAssertEqual(SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.visualState, .userPaused)

        // Full terminate hygiene clears the mirror; re-seed residual after sentinel to model
        // force-quit residual (clear never ran) while distrust remains true.
        SharedPlayerManager.forceStaleLivenessTimestampForTermination()
        XCTAssertTrue(SharedPlayerManager.hasExplicitTerminationSentinel())
        XCTAssertTrue(SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning())
        XCTAssertNil(
            SharedPlayerManager.loadHomeWidgetLiveChromeMirror(),
            "Delivered terminate clears live chrome"
        )

        SharedPlayerManager.persistHomeWidgetLiveChromeMirror(
            HomeWidgetLiveChrome(
                visualState: .userPaused,
                currentLanguage: "sv",
                hasError: false,
                updatedAt: Date().timeIntervalSince1970,
                stampReason: "forceQuitClassResidual"
            )
        )
        XCTAssertEqual(
            SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.visualState,
            .userPaused,
            "Non-playing residual may remain on disk under distrust"
        )

        let fields = WidgetProviderSnapshotResolver.resolveFromSnapshot()
        XCTAssertEqual(
            fields.visualState,
            .prePlay,
            "Termination distrust must paint factory, not residual .userPaused"
        )
    }

    /// Extension must not re-stamp ``.playing`` live chrome while terminate/reboot distrust is true.
    ///
    /// - SeeAlso: ``SharedPlayerManager/persistHomeWidgetLiveChromeMirror(_:)``,
    ///   ``SharedPlayerManager/shouldDistrustDurableMirrorPlayPlanning()``.
    func testExtensionRefusesPlayingLiveChromeStampUnderRebootDistrust() {
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.clearHomeWidgetLiveChromeMirror()
        SharedPlayerManager.recordCurrentSystemBootTime()

        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            XCTFail("App Group UserDefaults unavailable")
            return
        }
        defaults.set(1.0, forKey: SharedPlayerManager.recordedSystemBootTimeAppGroupKey)
        XCTAssertTrue(SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning())

        SharedPlayerManager.persistHomeWidgetLiveChromeMirror(
            HomeWidgetLiveChrome(
                visualState: .playing,
                currentLanguage: "en",
                hasError: false,
                updatedAt: Date().timeIntervalSince1970,
                stampReason: "optimisticToggle"
            )
        )
        XCTAssertNil(
            SharedPlayerManager.loadHomeWidgetLiveChromeMirror(),
            "Extension must not project residual .playing under reboot distrust"
        )
    }

    /// Protects hasError fall-through: session absent → live chrome hasError paints.
    func testProviderResolveHasErrorFromLiveChromeWhenSessionNil() {
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.clearHomeWidgetLiveChromeMirror()
        SharedPlayerManager.stampHomeWidgetLiveChromeFromSession(
            visualState: .securityLocked,
            language: "de",
            hasError: true,
            reason: "testErrorChrome"
        )

        let fields = WidgetProviderSnapshotResolver.resolveFromSnapshot()
        XCTAssertEqual(fields.visualState, .securityLocked)
        XCTAssertEqual(fields.currentLanguage, "de")
        XCTAssertTrue(fields.hasError, "Live chrome hasError must paint when session is nil")
    }

    /// Protects program-metadata peer: session metadata still preferred; mirror metadata when
    /// session is nil (unchanged single-concern path alongside live chrome visual).
    func testProviderResolveProgramMetadataUnchangedWithLiveChrome() {
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.clearHomeWidgetLiveChromeMirror()
        SharedPlayerManager.clearHomeWidgetStreamMetadataMirror()

        let titleMeta = StreamProgramMetadata(programTitle: "Mirror Title", speaker: "Speaker")
        SharedPlayerManager.persistHomeWidgetStreamMetadataMirror(titleMeta)
        SharedPlayerManager.stampHomeWidgetLiveChromeFromSession(
            visualState: .playing,
            language: "nb",
            hasError: false,
            reason: "testMetaPeer"
        )

        let fields = WidgetProviderSnapshotResolver.resolveFromSnapshot()
        XCTAssertEqual(fields.visualState, .playing)
        XCTAssertEqual(fields.currentLanguage, "nb")
        XCTAssertEqual(fields.streamMetadata?.programTitle, "Mirror Title")
    }

    /// Protects stamped-session paint under the extension profile: ``resolveFromSnapshot()``
    /// is the sole Provider happy-path resolver (no actor hop).
    func testResolveFromSnapshotReturnsStampedSessionUnderExtensionProfile() {
        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .playing,
            language: "de",
            streamMetadata: metadata(title: programTitle, speaker: speaker)
        )

        let fields = WidgetProviderSnapshotResolver.resolveFromSnapshot()

        XCTAssertEqual(fields.visualState, .playing)
        XCTAssertEqual(fields.currentLanguage, "de")
        XCTAssertEqual(fields.streamMetadata?.programTitle, programTitle)
    }

    /// Live-chrome write bumps interactive paint epoch; resolve stays snapshot-SSOT (no hop).
    ///
    /// **Invariant protected:** Residual play/pause LIVE lag is healed by epoch wake +
    /// ``resolveFromSnapshot`` — not by reintroducing ``resolveWithActorHygiene``.
    ///
    /// - SeeAlso: ``SharedPlayerManager/bumpHomeWidgetInteractivePaintEpoch(reason:)``,
    ///   ``SharedPlayerManager/persistHomeWidgetLiveChromeMirror(_:)``.
    func testLiveChromeWriteBumpsInteractivePaintEpochAndResolveFollowsMirror() {
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.clearHomeWidgetLiveChromeMirror()
        let epochBefore = SharedPlayerManager.loadHomeWidgetInteractivePaintEpoch()

        SharedPlayerManager.persistHomeWidgetLiveChromeMirror(
            HomeWidgetLiveChrome(
                visualState: .userPaused,
                currentLanguage: "fi",
                hasError: false,
                updatedAt: Date().timeIntervalSince1970,
                stampReason: "testPaintEpoch"
            )
        )

        XCTAssertGreaterThan(
            SharedPlayerManager.loadHomeWidgetInteractivePaintEpoch(),
            epochBefore,
            "Live-chrome write must bump interactive paint epoch"
        )
        let fields = WidgetProviderSnapshotResolver.resolveFromSnapshot()
        XCTAssertEqual(fields.visualState, .userPaused)
        XCTAssertEqual(fields.currentLanguage, "fi")
    }

    /// Sticky pause identity skip still advances paint epoch under extension profile.
    ///
    /// - SeeAlso: ``SharedPlayerManager/stampHomeWidgetLiveChromeFromSession(visualState:language:hasError:reason:)``.
    func testUserPausedIdentitySkipBumpsPaintEpochUnderExtensionProfile() {
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.clearHomeWidgetLiveChromeMirror()
        SharedPlayerManager.stampHomeWidgetLiveChromeFromSession(
            visualState: .userPaused,
            language: "et",
            hasError: false,
            reason: "optimisticToggle"
        )
        let epochAfterWrite = SharedPlayerManager.loadHomeWidgetInteractivePaintEpoch()
        let firstUpdatedAt = SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.updatedAt
        SharedPlayerManager.stampHomeWidgetLiveChromeFromSession(
            visualState: .userPaused,
            language: "et",
            hasError: false,
            reason: "sessionSave"
        )
        XCTAssertGreaterThan(
            SharedPlayerManager.loadHomeWidgetInteractivePaintEpoch(),
            epochAfterWrite,
            "Extension-profile sticky pause identity skip must wake interactive paint epoch"
        )
        XCTAssertEqual(
            SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.updatedAt,
            firstUpdatedAt,
            "Identity skip must not rewrite live-chrome JSON under extension profile"
        )
        XCTAssertEqual(
            WidgetProviderSnapshotResolver.resolveFromSnapshot().visualState,
            .userPaused
        )
    }

    /// Soft-resume ``.playing`` identity skip also advances paint epoch (residual Tauko wake).
    ///
    /// - SeeAlso: ``SharedPlayerManager/stampHomeWidgetLiveChromeFromSession(visualState:language:hasError:reason:)``.
    func testPlayingIdentitySkipBumpsPaintEpochUnderExtensionProfile() {
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.clearHomeWidgetLiveChromeMirror()
        SharedPlayerManager.stampHomeWidgetLiveChromeFromSession(
            visualState: .playing,
            language: "fi",
            hasError: false,
            reason: "setPlaying"
        )
        let epochAfterWrite = SharedPlayerManager.loadHomeWidgetInteractivePaintEpoch()
        let firstUpdatedAt = SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.updatedAt
        SharedPlayerManager.stampHomeWidgetLiveChromeFromSession(
            visualState: .playing,
            language: "fi",
            hasError: false,
            reason: "sessionSave"
        )
        XCTAssertGreaterThan(
            SharedPlayerManager.loadHomeWidgetInteractivePaintEpoch(),
            epochAfterWrite,
            "Playing identity skip must wake interactive paint epoch for residual Tauko heal"
        )
        XCTAssertEqual(
            SharedPlayerManager.loadHomeWidgetLiveChromeMirror()?.updatedAt,
            firstUpdatedAt,
            "Playing identity skip must not rewrite live-chrome JSON"
        )
        XCTAssertEqual(
            WidgetProviderSnapshotResolver.resolveFromSnapshot().visualState,
            .playing
        )
    }

    /// Live-chrome write publishes stable paint signature (epoch|visualToken|lang) for LIVE identity.
    ///
    /// **Invariant protected:** Signature uses ``HomeWidgetLiveChrome/stableToken(for:)`` so
    /// ``SimpleEntry/paintSignature`` and ``@AppStorage`` observers flip on pause/play without
    /// inventing visual from the token alone.
    ///
    /// - SeeAlso: ``SharedPlayerManager/makeHomeWidgetInteractivePaintSignature(visualState:language:epoch:)``,
    ///   ``SharedPlayerManager/loadHomeWidgetInteractivePaintSignature()``.
    func testLiveChromeWritePublishesStableInteractivePaintSignature() {
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.clearHomeWidgetLiveChromeMirror()

        SharedPlayerManager.persistHomeWidgetLiveChromeMirror(
            HomeWidgetLiveChrome(
                visualState: .userPaused,
                currentLanguage: "fi",
                hasError: false,
                updatedAt: Date().timeIntervalSince1970,
                stampReason: "testPaintSignature"
            )
        )

        let epoch = SharedPlayerManager.loadHomeWidgetInteractivePaintEpoch()
        let expected = SharedPlayerManager.makeHomeWidgetInteractivePaintSignature(
            visualState: .userPaused,
            language: "fi",
            epoch: epoch
        )
        XCTAssertEqual(
            SharedPlayerManager.loadHomeWidgetInteractivePaintSignature(),
            expected,
            "Paint signature must use stable visual token + current epoch after live-chrome write"
        )
        XCTAssertTrue(
            expected.contains("|userPaused|fi"),
            "Stable token form epoch|userPaused|lang (not String(describing:) enum dump)"
        )
    }

    /// Soft-resume settle: fresher live-chrome ``.playing`` wins over sticky pause session.
    ///
    /// **Invariant protected:** log5 inverse residual (grey Tauko after audio playing) must not
    /// come from chrome selection preferring stale extension session over main App Group settle.
    /// Heal always rebuilds from this resolve (never keeps lagging entry pause chrome).
    ///
    /// - SeeAlso: ``resolveHomeWidgetChromeFields``, ``WidgetProviderSnapshotResolver/resolveFromSnapshot()``.
    func testFresherLiveChromePlayingBeatsStaleSessionUserPausedForSoftResumeSettle() {
        let sessionTime = Date().timeIntervalSince1970 - 2
        let mirrorTime = Date().timeIntervalSince1970
        let resolution = resolveHomeWidgetChromeFields(
            sessionVisual: .userPaused,
            sessionLanguage: "fi",
            sessionHasError: false,
            sessionUpdatedAt: sessionTime,
            liveChrome: HomeWidgetLiveChrome(
                visualState: .playing,
                currentLanguage: "fi",
                hasError: false,
                updatedAt: mirrorTime,
                stampReason: "setPlaying"
            ),
            distrustLiveChrome: false
        )
        XCTAssertEqual(resolution.visualState, .playing)
        XCTAssertEqual(resolution.source, .liveChrome)
        XCTAssertEqual(resolution.currentLanguage, "fi")
    }

    // MARK: - Interactive home paint heal (snapshot rebuild + wake-token merge)

    /// Lagging TimelineEntry wake tokens + fresher suite → heal projects suite chrome.
    ///
    /// **Invariant protected:** ``WidgetInteractivePaintHeal/projectHomeInteractivePaint``
    /// rebuilds status/control from ``resolveFromSnapshot()`` and merges wake tokens
    /// (`max` epoch; suite signature wins). Residual system-held chrome is modeled only via
    /// lagging epoch/signature — entry status/control slices are never heal inputs — so App
    /// Group ``.userPaused`` after optimistic home pause cannot lose to a lagging ``.playing``
    /// archive once heal runs.
    ///
    /// **Soft-resume inverse (second half):** Fresher live-chrome ``.playing`` over sticky
    /// session pause projects ``.playing`` — heal must not keep residual pause chrome.
    ///
    /// **Out of scope for this test:** Whether WidgetKit re-evaluated the on-screen home
    /// widget after the suite stamp (body re-eval is driven by ``@AppStorage``, Darwin/local
    /// paint-advanced wake, and timeline reload — not by this method alone).
    ///
    /// - SeeAlso: ``WidgetInteractivePaintHeal/projectHomeInteractivePaint(laggingPaintEpoch:laggingPaintSignature:date:)``,
    ///   ``WidgetInteractivePaintHealProjection``,
    ///   ``SharedPlayerManager/makeHomeWidgetInteractivePaintSignature(visualState:language:epoch:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md (ContentState lag class).
    func testLaggingEntryWakeTokensPlusFresherSuiteProjectsHealChromeNotLaggingPlaying() {
        SharedPlayerManager.clearInMemorySessionSnapshot()
        SharedPlayerManager.clearHomeWidgetLiveChromeMirror()

        // Residual playing archive after home pause (suite already userPaused).
        // Durable SSOT after optimistic pause (audio/main path honest).
        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: "fi")
        SharedPlayerManager.persistHomeWidgetLiveChromeMirror(
            HomeWidgetLiveChrome(
                visualState: .userPaused,
                currentLanguage: "fi",
                hasError: false,
                updatedAt: Date().timeIntervalSince1970,
                stampReason: "testLaggingEntryHealPause"
            )
        )

        let suiteEpochAfterPause = SharedPlayerManager.loadHomeWidgetInteractivePaintEpoch()
        let suiteSignatureAfterPause = SharedPlayerManager.loadHomeWidgetInteractivePaintSignature()
        XCTAssertGreaterThan(suiteEpochAfterPause, 0, "Live-chrome write must advance paint epoch")
        XCTAssertFalse(suiteSignatureAfterPause.isEmpty, "Live-chrome write must publish paint signature")

        // Model system-held residual LIVE: older playing-era wake tokens only.
        // Heal never consumes lagging status/control slices — proving chrome comes from suite.
        let laggingPlayingEpoch = max(0, suiteEpochAfterPause - 1)
        let laggingPlayingSignature = SharedPlayerManager.makeHomeWidgetInteractivePaintSignature(
            visualState: .playing,
            language: "fi",
            epoch: laggingPlayingEpoch
        )
        let laggingDate = Date(timeIntervalSince1970: 1_700_000_000)

        let pauseProjection = WidgetInteractivePaintHeal.projectHomeInteractivePaint(
            laggingPaintEpoch: laggingPlayingEpoch,
            laggingPaintSignature: laggingPlayingSignature,
            date: laggingDate
        )

        XCTAssertEqual(
            pauseProjection.fields.visualState,
            .userPaused,
            "Heal fields must follow fresher suite resolve, not lagging playing wake token"
        )
        XCTAssertEqual(pauseProjection.blueprint.visualState, .userPaused)
        XCTAssertEqual(
            pauseProjection.blueprint.statusPresentation,
            PlayerVisualState.userPaused.makeStatusPresentation()
        )
        XCTAssertEqual(
            pauseProjection.blueprint.controlPresentation,
            PlayerVisualState.userPaused.makeControlPresentation()
        )
        XCTAssertEqual(pauseProjection.blueprint.currentLanguageCode, "fi")
        XCTAssertEqual(pauseProjection.blueprint.date, laggingDate, "Lagging entry date is retained")
        XCTAssertEqual(
            pauseProjection.paintEpoch,
            max(laggingPlayingEpoch, suiteEpochAfterPause),
            "Paint epoch must max(lagging entry, suite)"
        )
        XCTAssertEqual(
            pauseProjection.paintSignature,
            suiteSignatureAfterPause,
            "Non-empty suite signature must win over lagging playing signature"
        )
        XCTAssertNotEqual(
            pauseProjection.paintSignature,
            laggingPlayingSignature,
            "Lagging playing signature must not stick when suite advanced"
        )

        // Soft-resume settle: fresher playing suite beats sticky session pause.
        // Process-local sticky pause is older than main setPlaying live chrome (soft-resume hold).
        SharedPlayerManager.inMemorySessionWidgetSnapshot = SharedPlayerManager.PersistedWidgetState(
            visualState: .userPaused,
            currentLanguage: "fi",
            lastLanguageChangeTime: Date().addingTimeInterval(-3),
            streamMetadata: nil,
            hasError: false
        )
        SharedPlayerManager.persistHomeWidgetLiveChromeMirror(
            HomeWidgetLiveChrome(
                visualState: .playing,
                currentLanguage: "fi",
                hasError: false,
                updatedAt: Date().timeIntervalSince1970,
                stampReason: "testLaggingEntryHealSoftResume"
            )
        )

        let suiteEpochAfterPlay = SharedPlayerManager.loadHomeWidgetInteractivePaintEpoch()
        let suiteSignatureAfterPlay = SharedPlayerManager.loadHomeWidgetInteractivePaintSignature()
        let laggingPauseEpoch = max(0, suiteEpochAfterPlay - 1)
        let laggingPauseSignature = SharedPlayerManager.makeHomeWidgetInteractivePaintSignature(
            visualState: .userPaused,
            language: "fi",
            epoch: laggingPauseEpoch
        )

        let playProjection = WidgetInteractivePaintHeal.projectHomeInteractivePaint(
            laggingPaintEpoch: laggingPauseEpoch,
            laggingPaintSignature: laggingPauseSignature,
            date: laggingDate
        )

        XCTAssertEqual(
            playProjection.fields.visualState,
            .playing,
            "Soft-resume heal must project fresher live-chrome .playing over sticky session"
        )
        XCTAssertEqual(playProjection.blueprint.visualState, .playing)
        XCTAssertEqual(
            playProjection.blueprint.controlPresentation,
            PlayerVisualState.playing.makeControlPresentation()
        )
        XCTAssertEqual(
            playProjection.paintEpoch,
            max(laggingPauseEpoch, suiteEpochAfterPlay)
        )
        XCTAssertEqual(playProjection.paintSignature, suiteSignatureAfterPlay)
    }

    // MARK: - Presentation assembly + factory blueprint (thin linkage smoke)

    /// Single-state assembly smoke under extension linkage (full matrix in WidgetSurfaceTests).
    func testAssemblePresentationSlicesPlayingSmokeLinksUnderExtensionProfile() {
        let fields = WidgetProviderSnapshotFields(
            currentLanguage: "en",
            hasError: false,
            visualState: .playing,
            streamMetadata: nil
        )
        let slices = WidgetProviderSnapshotResolver.assemblePresentationSlices(from: fields)
        XCTAssertEqual(slices.statusPresentation, PlayerVisualState.playing.makeStatusPresentation())
        XCTAssertEqual(slices.controlPresentation, PlayerVisualState.playing.makeControlPresentation())
    }

    func testHomeBlueprintFromResolverMatchesProviderContract() {
        let meta = metadata(title: programTitle, speaker: speaker)
        SharedPlayerManager.persistWidgetSnapshot(
            visualState: .playing,
            language: "fi",
            streamMetadata: meta
        )

        let fields = WidgetProviderSnapshotResolver.resolveFromSnapshot()
        let slices = WidgetProviderSnapshotResolver.assemblePresentationSlices(from: fields)
        let blueprint = WidgetTimelineEntryFactory.makeHomeWidgetBlueprint(
            date: Date(),
            fields: fields,
            slices: slices
        )

        XCTAssertEqual(blueprint.visualState, .playing)
        XCTAssertEqual(blueprint.currentLanguageCode, "fi")
        XCTAssertEqual(blueprint.statusPresentation, slices.statusPresentation)
        XCTAssertEqual(blueprint.controlPresentation, slices.controlPresentation)
        XCTAssertEqual(blueprint.widgetNowPlayingDisplayModel, slices.widgetNowPlayingDisplayModel)
        XCTAssertEqual(blueprint.streamMetadata?.programTitle, programTitle)
    }

    func testControlBlueprintFromResolverMatchesProviderContract() {
        SharedPlayerManager.persistWidgetSnapshot(visualState: .userPaused, language: "de")

        let fields = WidgetProviderSnapshotResolver.resolveFromSnapshot()
        let slices = WidgetProviderSnapshotResolver.assemblePresentationSlices(from: fields)
        let blueprint = WidgetTimelineEntryFactory.makeControlWidgetBlueprint(
            fields: fields,
            slices: slices
        )

        XCTAssertEqual(blueprint.visualState, .userPaused)
        XCTAssertEqual(blueprint.statusPresentation, slices.statusPresentation)
        XCTAssertEqual(blueprint.controlPresentation, slices.controlPresentation)
        XCTAssertEqual(blueprint.currentStation, slices.currentStation)
    }

    // MARK: - Catalog-aware display helpers (extension stream stub linkage)

    /// Known codes prefer ``SharedPlayerManager/availableStreams`` language names.
    func testDisplayLanguageNamePrefersAvailableStreams() {
        let streams = manager.availableStreams
        guard let en = streams.first(where: { $0.languageCode == "en" }),
              let fi = streams.first(where: { $0.languageCode == "fi" }) else {
            XCTFail("Stub streams must include en and fi")
            return
        }
        XCTAssertEqual(displayLanguageName(for: "en"), en.language)
        XCTAssertEqual(displayLanguageName(for: "fi"), fi.language)
        XCTAssertFalse(en.language.isEmpty)
        XCTAssertNotEqual(displayLanguageName(for: "en"), "en")
    }

    /// Curated codes match stream-list flags when present (LA button consistency).
    func testDisplayFlagMatchesStreamListFlagsWhenAvailable() {
        for stream in manager.availableStreams {
            XCTAssertEqual(
                displayFlag(for: stream.languageCode),
                stream.flag,
                "displayFlag must match stream.flag for \(stream.languageCode)"
            )
        }
    }
}
