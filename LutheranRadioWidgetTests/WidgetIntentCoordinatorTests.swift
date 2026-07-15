//
//  WidgetIntentCoordinatorTests.swift
//  LutheranRadioWidgetTests
//
//  Created by Jari Lammi on 15.7.2026.
//
//  Extension-profile unit tests for ``WidgetIntentCoordinators`` (pure plan mapping).
//
//  Compile profile: no `LUTHERAN_MAIN_APP` — same as LutheranRadioWidgetExtension.
//  These planners are pure WidgetSurface APIs; the suite also proves the framework
//  links correctly into the extension-profile test host.
//
//  - SeeAlso: ``WidgetIntentCoordinators``, docs/Widget-Functionality-Roadmap.md,
//    docs/WidgetSurface-OI-W3-Plan-and-Status.md (PR 3).
//

import XCTest
import WidgetSurface

/// Protects home/control/LA toggle plan matrices and optimistic language resolution.
///
/// **Invariant:** Extension `perform()` and this suite must call the same planner SSOT —
/// never duplicate bool matrices in test helpers.
final class WidgetIntentCoordinatorTests: XCTestCase {

    private let allVisualStates: [PlayerVisualState] = [
        .prePlay, .cleared, .playing, .userPaused, .thermalPaused, .securityLocked
    ]

    // MARK: - Home widget toggle

    /// Home-widget toggle: only `.playing` maps to pause; every other state maps to play.
    func testPlanHomeWidgetToggleMatrix() {
        for state in allVisualStates {
            let plan = WidgetIntentCoordinators.planHomeWidgetToggle(from: state)
            if state.isActivelyPlaying {
                XCTAssertEqual(plan.action, "pause", "Playing must plan pause for \(state)")
                XCTAssertEqual(plan.targetVisualState, .userPaused)
            } else {
                XCTAssertEqual(plan.action, "play", "Non-playing must plan play for \(state)")
                XCTAssertEqual(plan.targetVisualState, .playing)
            }
        }
    }

    // MARK: - Control widget toggle

    /// Control-widget bool: `true` → play/`.playing`, `false` → pause/`.userPaused`.
    func testPlanControlWidgetToggleMatrix() {
        let playPlan = WidgetIntentCoordinators.planControlWidgetToggle(isPlayingRequested: true)
        XCTAssertEqual(playPlan.action, "play")
        XCTAssertEqual(playPlan.targetVisualState, .playing)

        let pausePlan = WidgetIntentCoordinators.planControlWidgetToggle(isPlayingRequested: false)
        XCTAssertEqual(pausePlan.action, "pause")
        XCTAssertEqual(pausePlan.targetVisualState, .userPaused)
    }

    // MARK: - Live Activity toggle

    /// Live Activity: actively playing → `.pause`; otherwise → `.play`.
    func testPlanLiveActivityToggleMatrix() {
        for state in allVisualStates {
            let plan = WidgetIntentCoordinators.planLiveActivityToggle(from: state)
            if state.isActivelyPlaying {
                XCTAssertEqual(plan, .pause, "Playing must plan LA pause for \(state)")
            } else {
                XCTAssertEqual(plan, .play, "Non-playing must plan LA play for \(state)")
            }
        }
    }

    /// Multi-source resolution: LA ContentState wins over empty extension actor/snapshot.
    ///
    /// Protects lock-screen pause when home-widget write suppression leaves the extension
    /// memory-only session empty (default actor `.prePlay` would otherwise invert to play).
    func testResolveLiveActivityTogglePrefersContentOverEmptyActor() {
        let resolution = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: .playing,
            durableMirror: nil,
            actorVisualState: .prePlay,
            sessionSnapshot: nil
        )
        XCTAssertEqual(resolution.visualState, .playing)
        XCTAssertEqual(resolution.source, .liveActivityContent)
        XCTAssertEqual(
            WidgetIntentCoordinators.planLiveActivityToggle(resolution: resolution),
            .pause
        )
    }

    /// When ActivityKit activities are empty, durable App Group mirror still plans pause.
    func testResolveLiveActivityToggleUsesDurableMirrorWhenContentMissing() {
        let resolution = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: nil,
            durableMirror: .playing,
            actorVisualState: .prePlay,
            sessionSnapshot: nil
        )
        XCTAssertEqual(resolution.visualState, .playing)
        XCTAssertEqual(resolution.source, .durableCrossProcessMirror)
        XCTAssertEqual(
            WidgetIntentCoordinators.planLiveActivityToggle(resolution: resolution),
            .pause
        )
    }

    /// Actor actively playing is preferred over a stale paused session snapshot when content/mirror are absent.
    func testResolveLiveActivityTogglePrefersActivelyPlayingActorOverSnapshot() {
        let resolution = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: nil,
            durableMirror: nil,
            actorVisualState: .playing,
            sessionSnapshot: .userPaused
        )
        XCTAssertEqual(resolution.visualState, .playing)
        XCTAssertEqual(resolution.source, .actorVisualState)
        XCTAssertEqual(
            WidgetIntentCoordinators.planLiveActivityToggle(resolution: resolution),
            .pause
        )
    }

    /// Empty signals default to `.prePlay` → play (factory / cold extension).
    func testResolveLiveActivityToggleDefaultsToPrePlayWhenNoSignals() {
        let resolution = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: nil,
            durableMirror: nil,
            actorVisualState: nil,
            sessionSnapshot: nil
        )
        XCTAssertEqual(resolution.visualState, .prePlay)
        XCTAssertEqual(resolution.source, .defaultPrePlay)
        XCTAssertEqual(
            WidgetIntentCoordinators.planLiveActivityToggle(resolution: resolution),
            .play
        )
    }

    /// Post-term / reboot: durable mirror alone must not plan play (stale App Group hygiene).
    ///
    /// In-session empty-extension pause (mirror `.playing` → pause) remains intact with
    /// `distrustDurableMirrorPlay: false` (default).
    func testPlanLiveActivityToggleDistrustBlocksPlayFromDurableMirrorAlone() {
        let pausedMirror = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: nil,
            durableMirror: .userPaused,
            actorVisualState: .prePlay,
            sessionSnapshot: nil
        )
        XCTAssertEqual(pausedMirror.source, .durableCrossProcessMirror)
        XCTAssertEqual(
            WidgetIntentCoordinators.planLiveActivityToggle(
                resolution: pausedMirror,
                distrustDurableMirrorPlay: false
            ),
            .play,
            "Without distrust, non-playing mirror still plans play (normal toggle)"
        )
        XCTAssertEqual(
            WidgetIntentCoordinators.planLiveActivityToggle(
                resolution: pausedMirror,
                distrustDurableMirrorPlay: true
            ),
            .pause,
            "With distrust, durable mirror alone must not synthesize play after term/reboot"
        )

        let playingMirror = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: nil,
            durableMirror: .playing,
            actorVisualState: .prePlay,
            sessionSnapshot: nil
        )
        XCTAssertEqual(
            WidgetIntentCoordinators.planLiveActivityToggle(
                resolution: playingMirror,
                distrustDurableMirrorPlay: true
            ),
            .pause,
            "Distrust must not invert playing-mirror → pause (lock-screen pause still works)"
        )
    }

    /// ActivityKit ContentState remains trusted under distrust (explicit lock-screen glyph).
    func testPlanLiveActivityToggleDistrustStillAllowsPlayFromLiveActivityContent() {
        let resolution = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: .userPaused,
            durableMirror: .playing,
            actorVisualState: .prePlay,
            sessionSnapshot: nil
        )
        XCTAssertEqual(resolution.source, .liveActivityContent)
        XCTAssertEqual(
            WidgetIntentCoordinators.planLiveActivityToggle(
                resolution: resolution,
                distrustDurableMirrorPlay: true
            ),
            .play,
            "Real ContentState pause glyph may plan play even under term/reboot distrust"
        )
    }

    // MARK: - Language resolution

    /// Prefers persisted snapshot language over preferred fallback.
    func testLanguageForOptimisticUpdatePrefersPersisted() {
        let resolved = WidgetIntentCoordinators.languageForOptimisticUpdate(
            persistedLanguage: "fi",
            preferredLanguage: "en"
        )
        XCTAssertEqual(resolved, "fi")
    }

    /// Falls back to preferred when no persisted language exists.
    func testLanguageForOptimisticUpdateFallsBackToPreferred() {
        let resolved = WidgetIntentCoordinators.languageForOptimisticUpdate(
            persistedLanguage: nil,
            preferredLanguage: "de"
        )
        XCTAssertEqual(resolved, "de")
    }
}
