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
