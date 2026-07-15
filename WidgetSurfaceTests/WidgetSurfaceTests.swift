//
//  WidgetSurfaceTests.swift
//  WidgetSurfaceTests
//
//  Pure WidgetSurface framework tests (no SharedPlayerManager / extension SPM).
//  Complements LutheranRadioWidgetTests, which exercise the extension compile profile.
//
//  - SeeAlso: ``WidgetIntentCoordinators``, ``WidgetLivenessPresentation``,
//    ``WidgetTimelineEntryFactory``, docs/Widget-Functionality-Roadmap.md.
//

import Foundation
import Testing
import WidgetSurface

struct WidgetSurfaceTests {

    // MARK: - Intent coordinators

    @Test func planHomeWidgetTogglePlayingIsPause() {
        let plan = WidgetIntentCoordinators.planHomeWidgetToggle(from: .playing)
        #expect(plan.action == "pause")
        #expect(plan.targetVisualState == .userPaused)
    }

    @Test func planHomeWidgetTogglePausedIsPlay() {
        let plan = WidgetIntentCoordinators.planHomeWidgetToggle(from: .userPaused)
        #expect(plan.action == "play")
        #expect(plan.targetVisualState == .playing)
    }

    @Test func planControlWidgetToggleBoolMatrix() {
        let play = WidgetIntentCoordinators.planControlWidgetToggle(isPlayingRequested: true)
        #expect(play.action == "play")
        #expect(play.targetVisualState == .playing)

        let pause = WidgetIntentCoordinators.planControlWidgetToggle(isPlayingRequested: false)
        #expect(pause.action == "pause")
        #expect(pause.targetVisualState == .userPaused)
    }

    @Test func planLiveActivityToggleMatrix() {
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(from: .playing) == .pause)
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(from: .userPaused) == .play)
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(from: .prePlay) == .play)
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
            statusMessage: status.text,
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
}
