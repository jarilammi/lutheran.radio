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

    /// Stale system-held Connecting must not invert pause when durable mirror already paused.
    ///
    /// After lock-stretch visual freeze, ContentState can remain `.prePlay` while the durable
    /// LA toggle mirror (and actor) already hold `.userPaused`. Planning from content alone
    /// would treat Connecting as "play-eligible" and invert a second pause/resume cycle.
    @Test func resolveLiveActivityToggleStaleConnectingDefersToUserPausedMirror() {
        let resolution = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: .prePlay,
            durableMirror: .userPaused,
            actorVisualState: .userPaused,
            sessionSnapshot: nil
        )
        #expect(resolution.source == .durableCrossProcessMirror)
        #expect(resolution.visualState == .userPaused)
        #expect(
            WidgetIntentCoordinators.planLiveActivityToggle(resolution: resolution) == .play,
            "Paused peer after stale Connecting must plan play (resume), not re-plan play from Connecting alone"
        )
    }

    /// Stale Connecting with still-playing audio prefers durable/actor playing → pause plan.
    @Test func resolveLiveActivityToggleStaleConnectingDefersToPlayingPeer() {
        let fromMirror = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: .prePlay,
            durableMirror: .playing,
            actorVisualState: .prePlay,
            sessionSnapshot: nil
        )
        #expect(fromMirror.source == .durableCrossProcessMirror)
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(resolution: fromMirror) == .pause)

        let fromActor = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: .prePlay,
            durableMirror: nil,
            actorVisualState: .playing,
            sessionSnapshot: nil
        )
        #expect(fromActor.source == .actorVisualState)
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(resolution: fromActor) == .pause)
    }

    /// Intentional Connecting with no control-definite peer remains content-authoritative.
    @Test func resolveLiveActivityToggleConnectingWithoutDefinitivePeerKeepsContent() {
        let resolution = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: .prePlay,
            durableMirror: .prePlay,
            actorVisualState: .prePlay,
            sessionSnapshot: nil
        )
        #expect(resolution.source == .liveActivityContent)
        #expect(resolution.visualState == .prePlay)
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(resolution: resolution) == .play)
    }

    /// Optimistic visual replace preserves language and program metadata (pause honesty).
    @Test func contentStateReplacingVisualStateFromPrePlayPreservesLanguage() {
        let metadata = StreamProgramMetadata(programTitle: "Vesper", speaker: "Cantor")
        let connecting = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .prePlay,
            streamMetadata: metadata,
            currentLanguage: "de"
        )
        let paused = connecting.replacingVisualState(.userPaused)
        #expect(paused.visualState == .userPaused)
        #expect(paused.currentLanguage == "de")
        #expect(paused.streamMetadata == metadata)
        #expect(PlayerVisualState.userPaused.isDefinitiveMediaToggleVisual)
        #expect(!PlayerVisualState.prePlay.isDefinitiveMediaToggleVisual)
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

    /// Optimistic stream-switch ContentState advances language and clears prior program metadata.
    ///
    /// Lock-screen language chips must update flag chrome without waiting for main-app attach,
    /// and must not leave the prior stream's ICY title under the new flag.
    @Test func contentStateReplacingStreamSwitchDestinationAdvancesLanguageAndClearsMetadata() {
        let metadata = StreamProgramMetadata(programTitle: "Psaltaren 34", speaker: "Lutheran Radio på svenska")
        let playing = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .playing,
            streamMetadata: metadata,
            currentLanguage: "sv"
        )
        let connecting = playing.replacingStreamSwitchDestination(
            language: "et",
            visualState: .prePlay,
            clearStreamMetadata: true
        )
        #expect(connecting.visualState == .prePlay)
        #expect(connecting.currentLanguage == "et")
        #expect(connecting.streamMetadata == nil)
        #expect(connecting != playing)

        let paused = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .userPaused,
            streamMetadata: metadata,
            currentLanguage: "de"
        )
        let pausedSwitch = paused.replacingStreamSwitchDestination(
            language: "fi",
            visualState: .userPaused,
            clearStreamMetadata: true
        )
        #expect(pausedSwitch.visualState == .userPaused)
        #expect(pausedSwitch.currentLanguage == "fi")
        #expect(pausedSwitch.streamMetadata == nil)
    }

    /// Stream-switch optimistic visual: playing → Connecting; sticky pause preserved.
    @Test func optimisticLiveActivityVisualForStreamSwitchHonesty() {
        #expect(
            WidgetIntentCoordinators.optimisticLiveActivityVisualForStreamSwitch(from: .playing)
                == .prePlay
        )
        #expect(
            WidgetIntentCoordinators.optimisticLiveActivityVisualForStreamSwitch(from: .userPaused)
                == .userPaused
        )
        #expect(
            WidgetIntentCoordinators.optimisticLiveActivityVisualForStreamSwitch(from: .prePlay)
                == .prePlay
        )
        #expect(
            WidgetIntentCoordinators.optimisticLiveActivityVisualForStreamSwitch(from: .thermalPaused)
                == .thermalPaused
        )
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

    // MARK: - Presentation mappers (full matrix — pure WidgetSurface host)

    /// Full status presentation matrix for every visual state (authoritative pure host).
    /// Extension targets keep thin linkage smoke only.
    @Test func statusPresentationMatrixMapsEveryVisualState() {
        let states: [PlayerVisualState] = [
            .prePlay, .cleared, .playing, .userPaused, .thermalPaused, .securityLocked
        ]
        let expectedGlyphs: [PlayerVisualState: String?] = [
            .playing: "play.fill",
            .prePlay: "play.circle",
            .cleared: nil,
            .userPaused: "pause.fill",
            .thermalPaused: "pause.fill",
            .securityLocked: "lock.fill",
        ]
        for state in states {
            let presentation = state.makeStatusPresentation()
            #expect(!presentation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(presentation.systemImage == expectedGlyphs[state] ?? nil)
            #expect(presentation.background == PlayerVisualChromePalette.backgroundColor(for: state))
            #expect(presentation.foreground == PlayerVisualChromePalette.textColor(for: state))
        }
        // Distinct status chrome across states (no collapsed cases).
        let pairs = states.map { ($0, $0.makeStatusPresentation()) }
        for i in pairs.indices {
            for j in pairs.indices where j > i {
                #expect(pairs[i].1 != pairs[j].1)
            }
        }
    }

    /// Full control presentation matrix: pause glyph only when actively playing.
    @Test func controlPresentationMatrixMapsEveryVisualState() {
        let states: [PlayerVisualState] = [
            .prePlay, .cleared, .playing, .userPaused, .thermalPaused, .securityLocked
        ]
        for state in states {
            let presentation = state.makeControlPresentation()
            let expectedGlyph = state.isActivelyPlaying ? "pause.fill" : "play.fill"
            #expect(presentation.systemImage == expectedGlyph)
            #expect(presentation.tint == PlayerVisualChromePalette.buttonTintColor(for: state))
        }
    }

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
