//
//  WidgetLivenessPresentationTests.swift
//  LutheranRadioWidgetTests
//
//  Created by Jari Lammi on 15.7.2026.
//
//  Extension-profile unit tests for ``WidgetLivenessPresentation`` passive `tap_to_open` policy.
//  Family views use only ``shouldShowPassiveTapToOpen(isMainAppRecentlyActive:)``; interactive
//  chrome is the complementary branch when that helper is `false`.
//
//  - SeeAlso: ``WidgetLivenessPresentation``, ``SharedPlayerManager/isMainAppProcessRecentlyActive()``,
//    docs/Widget-Functionality-Roadmap.md (force-quit liveness window), docs/Widget-Presentation-Dataflow.md.
//

import XCTest
import WidgetSurface

/// Protects the presentation-only liveness policy (`tap_to_open` vs interactive chrome).
///
/// The heartbeat remains in ``SharedPlayerManager``; this suite locks the pure passive-branch decision.
final class WidgetLivenessPresentationTests: XCTestCase {

    /// Passive `tap_to_open` when main app is not recently active; interactive chrome otherwise.
    func testShouldShowPassiveTapToOpenWhenMainAppNotRecentlyActive() {
        XCTAssertTrue(
            WidgetLivenessPresentation.shouldShowPassiveTapToOpen(isMainAppRecentlyActive: false),
            "Stale / terminated main must force passive tap_to_open"
        )
        XCTAssertFalse(
            WidgetLivenessPresentation.shouldShowPassiveTapToOpen(isMainAppRecentlyActive: true),
            "Recently active main must allow interactive chrome (passive == false)"
        )
    }

    /// Passive branch is the exact inverse of the recent-activity flag for every input.
    func testPassiveBranchIsInverseOfRecentActivity() {
        for active in [true, false] {
            let passive = WidgetLivenessPresentation.shouldShowPassiveTapToOpen(
                isMainAppRecentlyActive: active
            )
            XCTAssertEqual(
                passive,
                !active,
                "Passive must equal !isMainAppRecentlyActive when active=\(active)"
            )
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
