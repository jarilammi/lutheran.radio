//
//  WidgetRefreshManagerExtensionTests.swift
//  LutheranRadioWidgetTests
//
//  Created by Jari Lammi on 15.7.2026.
//
//  Extension-profile subset of ``WidgetRefreshManager`` contracts.
//  Focus: derivation matrix + privacy gate (no Tier 2 event observer in extension).
//
//  - SeeAlso: ``WidgetRefreshManager``, docs/Widget-Functionality-Roadmap.md,
//    docs/Event-Driven-Refactor-Roadmap.md.
//

import XCTest
import WidgetSurface

/// Extension-profile refresh derivation and process-profile invariants.
final class WidgetRefreshManagerExtensionTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            WidgetRefreshManager.setHasActiveLutheranWidgets(true)
            WidgetRefreshManager.shared.cancelPendingRefresh()
        }
        SharedPlayerManager.removeAllLocalPlaybackKeys()
    }

    override func tearDown() async throws {
        await MainActor.run {
            WidgetRefreshManager.shared.cancelPendingRefresh()
        }
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        try await super.tearDown()
    }

    /// Extension process must not start the Tier 2 PlayerEvent observer.
    func testExtensionProcessDoesNotObservePlayerEvents() async {
        XCTAssertTrue(SharedPlayerManager.isWidgetProcess())

        await MainActor.run {
            // Calling the test seam must still no-op under isWidgetProcess() guard.
            WidgetRefreshManager.shared._test_beginObservingPlayerEventsForTests()
        }

        // Short poll: extension profile must never attach (isWidgetProcess() gate).
        let attached = await WidgetRefreshManager.shared._test_waitForPlayerEventObservationAttached(
            timeout: 0.35
        )
        XCTAssertFalse(
            attached,
            "Widget extension compile profile must not attach PlayerEvent observation"
        )
    }

    /// Immediate refresh path completes under the privacy gate for sticky pause.
    func testRefreshIfNeededImmediateCompletesForUserPaused() async {
        await MainActor.run {
            WidgetRefreshManager.setHasActiveLutheranWidgets(true)
        }

        await WidgetRefreshManager.shared.refreshIfNeeded(
            visualState: .userPaused,
            currentLanguage: "fi",
            hasError: false,
            immediate: true
        )

        // No crash / hang is the contract; cancel any residual debounce.
        await MainActor.run {
            WidgetRefreshManager.shared.cancelPendingRefresh()
        }
    }

    /// Privacy gate: when no widgets are active, refresh is a quiet no-op.
    func testRefreshIfNeededRespectsInactiveWidgetsGate() async {
        await MainActor.run {
            WidgetRefreshManager.setHasActiveLutheranWidgets(false)
        }

        await WidgetRefreshManager.shared.refreshIfNeeded(
            visualState: .playing,
            currentLanguage: "en",
            hasError: false,
            immediate: true
        )

        await MainActor.run {
            WidgetRefreshManager.setHasActiveLutheranWidgets(true)
            WidgetRefreshManager.shared.cancelPendingRefresh()
        }
    }
}
