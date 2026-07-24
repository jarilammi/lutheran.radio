//
//  WidgetSurfaceTests.swift
//  WidgetSurfaceTests
//
//  Pure WidgetSurface framework tests (no SharedPlayerManager / extension SPM).
//  Complements LutheranRadioWidgetTests, which exercise the extension compile profile.
//
//  - SeeAlso: ``WidgetIntentCoordinators``, ``WidgetLivenessPresentation``,
//    ``WidgetTimelineEntryFactory``, ``WidgetProviderPresentationAssembly``,
//    ``displayFlag(for:)``, ``displayLanguageName(for:preferredStreamLanguage:)``,
//    docs/Widget-Functionality-Roadmap.md.
//

import Foundation
import Testing
import WidgetSurface

struct WidgetSurfaceTests {

    // MARK: - Intent coordinators

    @Test func planHomeWidgetTogglePlayingIsPause() {
        let plan = WidgetIntentCoordinators.planHomeWidgetToggle(from: .playing)
        #expect(plan.action == .pause)
        #expect(plan.targetVisualState == .userPaused)
    }

    @Test func planHomeWidgetTogglePausedIsPlay() {
        let plan = WidgetIntentCoordinators.planHomeWidgetToggle(from: .userPaused)
        #expect(plan.action == .play)
        #expect(plan.targetVisualState == .playing)
    }

    @Test func planControlWidgetToggleBoolMatrix() {
        let play = WidgetIntentCoordinators.planControlWidgetToggle(isPlayingRequested: true)
        #expect(play.action == .play)
        #expect(play.targetVisualState == .playing)

        let pause = WidgetIntentCoordinators.planControlWidgetToggle(isPlayingRequested: false)
        #expect(pause.action == .pause)
        #expect(pause.targetVisualState == .userPaused)
    }

    @Test func planLiveActivityToggleMatrix() {
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(from: .playing) == .pause)
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(from: .userPaused) == .play)
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(from: .prePlay) == .play)
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(from: .cleared) == .play)
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(from: .securityLocked) == .play)
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(from: .thermalPaused) == .refuse)
    }

    @Test func planHomeWidgetToggleThermalRefusesAndSecurityConnects() {
        let thermal = WidgetIntentCoordinators.planHomeWidgetToggle(from: .thermalPaused)
        #expect(thermal.action == .none)
        #expect(thermal.targetVisualState == .thermalPaused)
        #expect(!thermal.shouldExecutePendingAction)

        let security = WidgetIntentCoordinators.planHomeWidgetToggle(from: .securityLocked)
        #expect(security.action == .play)
        #expect(security.targetVisualState == .prePlay)
        #expect(security.shouldExecutePendingAction)
    }

    @Test func planLiveActivityToggleConnectingCancelsAsPause() {
        let resolution = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: .prePlay,
            durableMirror: .prePlay,
            actorVisualState: .prePlay,
            sessionSnapshot: nil
        )
        #expect(
            WidgetIntentCoordinators.planLiveActivityToggle(
                resolution: resolution,
                isConnectingPlayback: true
            ) == .pause,
            "Active start pipeline must plan pause to cancel connect, not duplicate play"
        )
        #expect(
            WidgetIntentCoordinators.planLiveActivityToggle(
                resolution: resolution,
                isConnectingPlayback: false
            ) == .play,
            "Idle Connecting chrome without pipeline still plans first play"
        )
    }

    @Test func playerVisualStateMediaToggleSemanticsHelpers() {
        #expect(PlayerVisualState.playing.plansMediaToggleAsPause)
        #expect(!PlayerVisualState.prePlay.plansMediaToggleAsPause)
        #expect(PlayerVisualState.thermalPaused.blocksPlannedPlay)
        #expect(!PlayerVisualState.securityLocked.blocksPlannedPlay)
        #expect(PlayerVisualState.securityLocked.optimisticVisualAfterPlayPlan == .prePlay)
        #expect(PlayerVisualState.userPaused.optimisticVisualAfterPlayPlan == .playing)
    }

    @Test func resolveLiveActivityTogglePrefersContentThenMirror() {
        let fromContent = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: .playing,
            durableMirror: .userPaused,
            actorVisualState: .prePlay,
            sessionSnapshot: nil
        )
        #expect(fromContent.source == .liveActivityContent)
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(resolution: fromContent) == .pause)

        let fromMirror = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: nil,
            durableMirror: .playing,
            actorVisualState: .prePlay,
            sessionSnapshot: nil
        )
        #expect(fromMirror.source == .durableCrossProcessMirror)
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(resolution: fromMirror) == .pause)
    }

    @Test func planLiveActivityToggleDistrustBlocksPlayFromDurableMirrorAlone() {
        let pausedMirror = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: nil,
            durableMirror: .userPaused,
            actorVisualState: .prePlay,
            sessionSnapshot: nil
        )
        #expect(
            WidgetIntentCoordinators.planLiveActivityToggle(
                resolution: pausedMirror,
                distrustDurableMirrorPlay: true
            ) == .pause
        )
        #expect(
            WidgetIntentCoordinators.planLiveActivityToggle(
                resolution: pausedMirror,
                distrustDurableMirrorPlay: false
            ) == .play
        )

        let contentPaused = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: .userPaused,
            durableMirror: .userPaused,
            actorVisualState: .prePlay,
            sessionSnapshot: nil
        )
        #expect(
            WidgetIntentCoordinators.planLiveActivityToggle(
                resolution: contentPaused,
                distrustDurableMirrorPlay: true
            ) == .play
        )
    }

    /// Optimistic ContentState visual flip preserves program metadata and language.
    @Test func contentStateReplacingVisualStatePreservesStreamMetadata() {
        let metadata = StreamProgramMetadata(programTitle: "Sunday Sermon", speaker: "Pastor")
        let playing = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .playing,
            streamMetadata: metadata,
            currentLanguage: "fi"
        )
        let paused = playing.replacingVisualState(.userPaused)
        #expect(paused.visualState == .userPaused)
        #expect(paused.streamMetadata == metadata)
        #expect(paused.currentLanguage == "fi")

        let resumed = paused.replacingVisualState(.playing)
        #expect(resumed.visualState == .playing)
        #expect(resumed.streamMetadata == metadata)
        #expect(resumed.currentLanguage == "fi")
    }

    /// Older ActivityKit payloads without `currentLanguage` decode to `"en"` (stable default).
    @Test func contentStateDecodeDefaultsMissingLanguageToEnglish() throws {
        let metadata = StreamProgramMetadata(programTitle: "Vesper", speaker: "Cantor")
        // Encode only visual + metadata (pre-language-chrome shape).
        struct LegacyPayload: Encodable {
            let visualState: PlayerVisualState
            let streamMetadata: StreamProgramMetadata?
        }
        let data = try JSONEncoder().encode(
            LegacyPayload(visualState: .playing, streamMetadata: metadata)
        )
        let decoded = try JSONDecoder().decode(
            LutheranRadioLiveActivityAttributes.ContentState.self,
            from: data
        )
        #expect(decoded.visualState == .playing)
        #expect(decoded.streamMetadata == metadata)
        #expect(decoded.currentLanguage == "en")
    }

    /// Language-only ContentState inequality forces ActivityKit update eligibility.
    @Test func contentStateLanguageChangeBreaksEquality() {
        let metadata = StreamProgramMetadata(programTitle: "Matins", speaker: nil)
        let finnish = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .playing,
            streamMetadata: metadata,
            currentLanguage: "fi"
        )
        let estonian = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .playing,
            streamMetadata: metadata,
            currentLanguage: "et"
        )
        #expect(finnish != estonian)
        #expect(finnish.visualState == estonian.visualState)
        #expect(finnish.streamMetadata == estonian.streamMetadata)
    }

    /// Rapid second tap must plan from optimistic ContentState, not stale pre-tap content.
    ///
    /// Protects the lock-screen double-tap contract: after an optimistic pause content
    /// publish, resolve prefers ActivityKit content over a lagging durable mirror or actor.
    @Test func rapidSecondTapPlansFromOptimisticLiveActivityContent() {
        let afterOptimisticPause = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: .userPaused,
            durableMirror: .playing,
            actorVisualState: .playing,
            sessionSnapshot: nil
        )
        #expect(afterOptimisticPause.source == .liveActivityContent)
        #expect(afterOptimisticPause.visualState == .userPaused)
        #expect(
            WidgetIntentCoordinators.planLiveActivityToggle(resolution: afterOptimisticPause) == .play,
            "Second tap after optimistic pause content must plan play, not a second pause"
        )

        let afterOptimisticPlay = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: .playing,
            durableMirror: .userPaused,
            actorVisualState: .userPaused,
            sessionSnapshot: nil
        )
        #expect(
            WidgetIntentCoordinators.planLiveActivityToggle(resolution: afterOptimisticPlay) == .pause,
            "Second tap after optimistic play content must plan pause"
        )
    }

    // MARK: - Liveness presentation

    @Test func livenessBranchesAreInverses() {
        #expect(WidgetLivenessPresentation.shouldShowInteractiveChrome(isMainAppRecentlyActive: true))
        #expect(WidgetLivenessPresentation.shouldShowPassiveTapToOpen(isMainAppRecentlyActive: false))
        #expect(WidgetLivenessPresentation.mainAppRecentActivityWindowSeconds == 60)
    }

    // MARK: - Timeline factory

    @Test func homeBlueprintCarriesPresentationSlices() {
        let fields = WidgetProviderSnapshotFields(
            currentLanguage: "fi",
            hasError: false,
            visualState: .playing,
            streamMetadata: nil
        )
        let status = PlayerVisualState.playing.makeStatusPresentation()
        let control = PlayerVisualState.playing.makeControlPresentation()
        let model = widgetNowPlayingDisplayModel(
            visualState: .playing,
            streamMetadata: nil,
            languageName: "Finnish"
        )
        let slices = WidgetProviderPresentationSlices(
            currentLanguageCode: "fi",
            currentStation: "🇫🇮 Finnish",
            statusPresentation: status,
            controlPresentation: control,
            widgetNowPlayingDisplayModel: model
        )
        let date = Date(timeIntervalSince1970: 0)
        let blueprint = WidgetTimelineEntryFactory.makeHomeWidgetBlueprint(
            date: date,
            fields: fields,
            slices: slices
        )
        #expect(blueprint.visualState == .playing)
        #expect(blueprint.currentLanguageCode == "fi")
        #expect(blueprint.statusPresentation == status)
        #expect(blueprint.controlPresentation == control)
        #expect(blueprint.date == date)
    }

    // MARK: - Presentation mappers

    @Test func statusPresentationPlayingUsesPlayGlyph() {
        let presentation = PlayerVisualState.playing.makeStatusPresentation()
        #expect(presentation.systemImage == "play.fill")
        #expect(!presentation.text.isEmpty)
    }

    @Test func controlPresentationPlayingUsesPauseGlyph() {
        let presentation = PlayerVisualState.playing.makeControlPresentation()
        #expect(presentation.systemImage == "pause.fill")
    }

    /// Status and control colors both derive from ``PlayerVisualChromePalette``.
    @Test func chromePaletteFeedsStatusAndControlPresentation() {
        let states: [PlayerVisualState] = [
            .prePlay, .cleared, .playing, .userPaused, .thermalPaused, .securityLocked
        ]
        for state in states {
            let status = state.makeStatusPresentation()
            #expect(status.background == PlayerVisualChromePalette.backgroundColor(for: state))
            #expect(status.foreground == PlayerVisualChromePalette.textColor(for: state))
            #expect(state.backgroundColor == PlayerVisualChromePalette.backgroundUIColor(for: state))
            #expect(state.textColor == PlayerVisualChromePalette.textUIColor(for: state))
            #expect(state.buttonTintColor == PlayerVisualChromePalette.buttonTintUIColor(for: state))
            #expect(
                state.makeControlPresentation().tint
                    == PlayerVisualChromePalette.buttonTintColor(for: state)
            )
        }
    }

    /// Typed toggle actions wire to App Group verbs at the mailbox boundary only.
    @Test func widgetToggleActionWireValuesMatchAppGroupVerbs() {
        #expect(WidgetToggleAction.play.wireValue == "play")
        #expect(WidgetToggleAction.pause.wireValue == "pause")
        #expect(WidgetToggleAction.none.wireValue == "none")
        #expect(WidgetToggleAction(wireValue: "play") == .play)
        #expect(WidgetToggleAction(wireValue: "switch") == nil)
    }

    // MARK: - Language display (pure)

    @Test func displayFlagMatrixForCuratedLanguageCodes() {
        #expect(displayFlag(for: "en") == "🇺🇸")
        #expect(displayFlag(for: "de") == "🇩🇪")
        #expect(displayFlag(for: "fi") == "🇫🇮")
        #expect(displayFlag(for: "sv") == "🇸🇪")
        #expect(displayFlag(for: "et") == "🇪🇪")
    }

    @Test func displayFlagUnknownCodeUsesGlobeFallback() {
        #expect(displayFlag(for: "xx") == "🌍")
        #expect(displayFlag(for: "") == "🌍")
        #expect(displayFlag(for: "nb") == "🌍")
    }

    @Test func displayLanguageNamePrefersStreamCatalogWhenProvided() {
        #expect(
            displayLanguageName(for: "fi", preferredStreamLanguage: "Suomi") == "Suomi"
        )
        #expect(
            displayLanguageName(for: "xx", preferredStreamLanguage: "Catalog Name") == "Catalog Name"
        )
    }

    @Test func displayLanguageNameUnknownCodeCapitalizesWithoutCatalog() {
        #expect(displayLanguageName(for: "xx") == "Xx")
        #expect(displayLanguageName(for: "zz") == "Zz")
    }

    // MARK: - Provider presentation assembly (pure)

    @Test func assemblePresentationSlicesMapsEveryVisualState() {
        let states: [PlayerVisualState] = [
            .prePlay, .cleared, .playing, .userPaused, .thermalPaused, .securityLocked
        ]
        for state in states {
            let fields = WidgetProviderSnapshotFields(
                currentLanguage: "en",
                hasError: false,
                visualState: state,
                streamMetadata: nil
            )
            let slices = WidgetProviderPresentationAssembly.assemblePresentationSlices(
                from: fields,
                languageName: "English",
                stationLabel: "🇺🇸 English"
            )
            #expect(slices.currentLanguageCode == "en")
            #expect(slices.currentStation == "🇺🇸 English")
            #expect(slices.statusPresentation == state.makeStatusPresentation())
            #expect(slices.controlPresentation == state.makeControlPresentation())
            #expect(
                slices.widgetNowPlayingDisplayModel == widgetNowPlayingDisplayModel(
                    visualState: state,
                    streamMetadata: nil,
                    languageName: "English"
                )
            )
        }
    }

    @Test func assemblePresentationSlicesUsesConnectionErrorWhenHasError() {
        let fields = WidgetProviderSnapshotFields(
            currentLanguage: "fi",
            hasError: true,
            visualState: .playing,
            streamMetadata: nil
        )
        let slices = WidgetProviderPresentationAssembly.assemblePresentationSlices(
            from: fields,
            languageName: "Suomi",
            stationLabel: "🇫🇮 Suomi"
        )
        let expectedError = String(
            localized: "Connection error",
            defaultValue: "Connection error",
            table: "Localizable"
        )
        let base = PlayerVisualState.playing.makeStatusPresentation()
        #expect(slices.statusPresentation.text == expectedError)
        #expect(slices.statusPresentation.background == base.background)
        #expect(slices.statusPresentation.foreground == base.foreground)
        #expect(slices.statusPresentation.systemImage == base.systemImage)
        #expect(slices.controlPresentation == PlayerVisualState.playing.makeControlPresentation())
    }

    @Test func assemblePresentationSlicesCarriesStreamMetadataIntoNowPlayingModel() {
        let meta = StreamProgramMetadata(programTitle: "Sunday Sermon", speaker: "Guest")
        let fields = WidgetProviderSnapshotFields(
            currentLanguage: "fi",
            hasError: false,
            visualState: .playing,
            streamMetadata: meta
        )
        let slices = WidgetProviderPresentationAssembly.assemblePresentationSlices(
            from: fields,
            languageName: "Suomi",
            stationLabel: "🇫🇮 Suomi"
        )
        let expected = widgetNowPlayingDisplayModel(
            visualState: .playing,
            streamMetadata: meta,
            languageName: "Suomi"
        )
        #expect(slices.widgetNowPlayingDisplayModel == expected)
        #expect(slices.widgetNowPlayingDisplayModel.programTitle == "Sunday Sermon")
        #expect(slices.widgetNowPlayingDisplayModel.speakerVisible)
    }
}
