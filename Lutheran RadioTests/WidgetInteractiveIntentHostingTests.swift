//
//  WidgetInteractiveIntentHostingTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 15.9.2026.
//
//  Main-app compile-profile contracts for interactive AppIntent hosting:
//  AudioPlaybackIntent / LiveActivityIntent conformance and supportedModes
//  background (Archive / lock-screen media wake without opening the UI).
//
//  Never calls ActivityKit IPC or WidgetCenter. Does not prove Archive lock-screen
//  with main suspended — physical-device / Archive eyes-on remains required.
//
//  - SeeAlso: ``LiveActivityTogglePlaybackIntent``, ``WidgetInteractiveIntents``,
//    ``WidgetIntentExecution/executeLiveActivityToggle(plan:)``,
//    docs/Live-Activity-Stacking-and-Media-Surfaces.md (lock-screen button hosting),
//    CODING_AGENT.md (fast test patterns).
//

import AppIntents
import XCTest
import WidgetSurface
@testable import Lutheran_Radio

/// Compile-time + unit gates that the main-app profile registers interactive
/// play/pause/switch intents as background media/Live Activity intents.
final class WidgetInteractiveIntentHostingTests: XCTestCase {

    private let manager = SharedPlayerManager.shared

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            prepareWidgetIntentContractTestIsolation()
        }
        SharedPlayerManager.removeAllLocalPlaybackKeys()
    }

    override func tearDown() async throws {
        await MainActor.run {
            tearDownWidgetIntentContractTestIsolation()
        }
        SharedPlayerManager.removeAllLocalPlaybackKeys()
        try await super.tearDown()
    }

    // MARK: - Protocol + mode (compile-time conformance)

    /// **Invariant protected:** Lock-screen play/pause is an ``AudioPlaybackIntent``
    /// and ``LiveActivityIntent`` on the main-app profile, with background modes
    /// and ``openAppWhenRun`` false so Archive buttons do not open the UI.
    func testLiveActivityToggleAdoptsAudioPlaybackAndLiveActivityIntents() {
        assertConformsToAudioPlaybackIntent(LiveActivityTogglePlaybackIntent.self)
        assertConformsToLiveActivityIntent(LiveActivityTogglePlaybackIntent.self)
        XCTAssertTrue(
            LiveActivityTogglePlaybackIntent.supportedModes.contains(.background),
            "Lock-screen play/pause must run in the background"
        )
        XCTAssertFalse(LiveActivityTogglePlaybackIntent.openAppWhenRun)
    }

    /// **Invariant protected:** LA language chips adopt ``LiveActivityIntent`` and
    /// stay background — never a way to open the app.
    func testLiveActivitySwitchAdoptsLiveActivityIntent() {
        assertConformsToLiveActivityIntent(LiveActivitySwitchStreamIntent.self)
        XCTAssertTrue(LiveActivitySwitchStreamIntent.supportedModes.contains(.background))
        XCTAssertFalse(LiveActivitySwitchStreamIntent.openAppWhenRun)
    }

    /// **Invariant protected:** Home play/pause are the same media-wake class.
    func testHomePlayPauseAdoptAudioPlaybackIntent() {
        assertConformsToAudioPlaybackIntent(WidgetPlayRadioIntent.self)
        assertConformsToAudioPlaybackIntent(WidgetPauseRadioIntent.self)
        assertConformsToAudioPlaybackIntent(WidgetToggleRadioIntent.self)
        XCTAssertTrue(WidgetPlayRadioIntent.supportedModes.contains(.background))
        XCTAssertTrue(WidgetPauseRadioIntent.supportedModes.contains(.background))
        XCTAssertTrue(WidgetToggleRadioIntent.supportedModes.contains(.background))
        XCTAssertFalse(WidgetPlayRadioIntent.openAppWhenRun)
        XCTAssertFalse(WidgetPauseRadioIntent.openAppWhenRun)
        XCTAssertFalse(WidgetToggleRadioIntent.openAppWhenRun)
    }

    /// **Invariant protected:** Control remains ``SetValueIntent`` and also adopts
    /// ``AudioPlaybackIntent`` on the app profile; background modes stay set.
    func testControlToggleAdoptsAudioPlaybackIntentAndStaysSetValueIntent() {
        assertConformsToAudioPlaybackIntent(ToggleRadioIntent.self)
        assertConformsToSetValueIntent(ToggleRadioIntent.self)
        XCTAssertTrue(ToggleRadioIntent.supportedModes.contains(.background))
        XCTAssertFalse(ToggleRadioIntent.openAppWhenRun)
    }

    /// **Invariant protected:** Home stream chips use background modes (media-modifying).
    func testHomeSwitchStreamSupportsBackgroundMode() {
        assertConformsToAudioPlaybackIntent(SwitchStreamIntent.self)
        XCTAssertTrue(SwitchStreamIntent.supportedModes.contains(.background))
        XCTAssertFalse(SwitchStreamIntent.openAppWhenRun)
    }

    // MARK: - No double Darwin drain

    /// **Invariant protected:** Main-app ``executeLiveActivityToggle`` uses the
    /// media-transport mailbox and must not write `pendingAction*` for the same tap.
    func testMainAppLiveActivityTogglePauseDoesNotWritePendingAction() async {
        clearPendingIfPresent()
        await WidgetIntentExecution.executeLiveActivityToggle(plan: .pause)
        XCTAssertNil(
            manager.getPendingAction(),
            "App-hosted LA pause must not enqueue Darwin pendingAction for the same tap"
        )
    }

    /// **Invariant protected:** Main-app home/Control optimistic pause persists chrome
    /// then mailboxes — no `pendingAction*` + Darwin on that tap.
    func testMainAppOptimisticHomePauseDoesNotWritePendingAction() async {
        await MainActor.run { WidgetRefreshManager.setHasActiveLutheranWidgets(true) }
        clearPendingIfPresent()
        let plan = WidgetIntentCoordinators.planHomeWidgetPause()
        await WidgetIntentExecution.executeOptimisticToggle(plan: plan, language: "en")
        XCTAssertNil(
            manager.getPendingAction(),
            "App-hosted home pause must not enqueue Darwin pendingAction for the same tap"
        )
    }

    private func clearPendingIfPresent() {
        if let stale = manager.getPendingAction() {
            manager.clearPendingAction(actionId: stale.actionId)
        }
    }
}

/// Compile-time gate: the type must conform to ``AudioPlaybackIntent``.
private func assertConformsToAudioPlaybackIntent<T: AudioPlaybackIntent>(_: T.Type) {}

/// Compile-time gate: the type must conform to ``LiveActivityIntent``.
private func assertConformsToLiveActivityIntent<T: LiveActivityIntent>(_: T.Type) {}

/// Compile-time gate: Control toggle must remain a ``SetValueIntent``.
private func assertConformsToSetValueIntent<T: SetValueIntent>(_: T.Type) {}
