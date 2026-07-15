//
//  WidgetLivenessPresentationTests.swift
//  LutheranRadioWidgetTests
//
//  Created by Jari Lammi on 15.7.2026.
//
//  Extension-profile unit tests for ``WidgetLivenessPresentation`` passive vs interactive chrome.
//
//  - SeeAlso: ``WidgetLivenessPresentation``, ``SharedPlayerManager/isMainAppProcessRecentlyActive()``,
//    docs/Widget-Functionality-Roadmap.md (OI-W1), docs/Widget-Presentation-Dataflow.md.
//

import XCTest
import WidgetSurface

/// Protects the presentation-only liveness policy (interactive chrome vs `tap_to_open`).
///
/// The heartbeat remains in ``SharedPlayerManager``; this suite locks the pure branch decision.
final class WidgetLivenessPresentationTests: XCTestCase {

    /// Interactive chrome when main app is recently active.
    func testShouldShowInteractiveChromeWhenMainAppRecentlyActive() {
        XCTAssertTrue(
            WidgetLivenessPresentation.shouldShowInteractiveChrome(isMainAppRecentlyActive: true)
        )
        XCTAssertFalse(
            WidgetLivenessPresentation.shouldShowInteractiveChrome(isMainAppRecentlyActive: false)
        )
    }

    /// Passive `tap_to_open` is the inverse of recent activity.
    func testShouldShowPassiveTapToOpenWhenMainAppNotRecentlyActive() {
        XCTAssertTrue(
            WidgetLivenessPresentation.shouldShowPassiveTapToOpen(isMainAppRecentlyActive: false)
        )
        XCTAssertFalse(
            WidgetLivenessPresentation.shouldShowPassiveTapToOpen(isMainAppRecentlyActive: true)
        )
    }

    /// Interactive and passive branches are mutually exclusive for every input.
    func testInteractiveAndPassiveBranchesAreMutuallyExclusive() {
        for active in [true, false] {
            let interactive = WidgetLivenessPresentation.shouldShowInteractiveChrome(
                isMainAppRecentlyActive: active
            )
            let passive = WidgetLivenessPresentation.shouldShowPassiveTapToOpen(
                isMainAppRecentlyActive: active
            )
            XCTAssertNotEqual(interactive, passive, "Branches must be exclusive when active=\(active)")
            XCTAssertEqual(interactive || passive, true)
        }
    }

    /// Window constant must stay aligned with SharedPlayerManager (60 s).
    func testMainAppRecentActivityWindowIsSixtySeconds() {
        XCTAssertEqual(
            WidgetLivenessPresentation.mainAppRecentActivityWindowSeconds,
            60,
            "AGENT NOTE: Keep in sync with SharedPlayerManager.isMainAppProcessRecentlyActive()"
        )
    }
}
