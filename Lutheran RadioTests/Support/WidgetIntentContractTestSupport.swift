//
//  WidgetIntentContractTestSupport.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 26.7.2026.
//
//  Shared host factories and cross-process isolation helpers for main-app
//  widget intent / pending-action / joined drain contract suites.
//  Extracted from ``WidgetIntentContractTests`` suite helpers during the same split.
//
//  - SeeAlso: ``WidgetIntentContractTests``, ``WidgetIntentPendingDrainTests``,
//    ``WidgetIntentJoinedRoundTripTests``,
//    ``RadioPlayerCoordinator/checkForPendingWidgetActions()``,
//    docs/Widget-Functionality-Roadmap.md (Tier 2),
//    CODING_AGENT.md (fast test patterns).
//

import XCTest
import WidgetSurface
@testable import Lutheran_Radio

// MARK: - Suite isolation

/// Resets Live Activity local state, widget refresh seams, and pending-action DEBUG flags
/// for main-host widget intent contract suites.
///
/// Call from each suite's ``setUp`` / ``tearDown`` so sibling files stay independent.
@MainActor
func prepareWidgetIntentContractTestIsolation() {
    let la = RadioLiveActivityManager.shared
    la.stopLocalUpdateTimer()
    la.activityObservationTask?.cancel()
    la.currentActivity = nil
    WidgetRefreshManager.setHasActiveLutheranWidgets(true)
    SharedPlayerManager._test_setSimulateWidgetProcessContext(false)
    ViewController._test_setBypassUITestModeForPendingActionProcessing(false)
    WidgetRefreshManager._test_setBypassUITestModeForRefreshGateObservation(false)
    WidgetRefreshManager._test_setRecordRefreshIfNeededGateOutcomes(false)
    WidgetRefreshManager._test_setBypassUITestModeForDebounceObservation(false)
    WidgetRefreshManager.shared._test_suspendPlayerEventObservation()
    WidgetRefreshManager._test_setSuppressPlayerEventObservation(true)
}

/// Plants ``instantFeedbackLanguage`` on the App Group suite without going through
/// ``SharedPlayerManager/writeInstantFeedback(language:)``.
///
/// Use when a test must exercise ``loadSharedState()``'s ignore of a disagreeing
/// leftover key. The production writer coerces to ``settledLanguageForInstantFeedback()``.
func plantInstantFeedbackLanguage(_ language: String) {
    guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
        XCTFail("App Group UserDefaults unavailable")
        return
    }
    defaults.set(true, forKey: "isInstantFeedback")
    defaults.set(Date().timeIntervalSince1970, forKey: "instantFeedbackTime")
    defaults.set(language, forKey: "instantFeedbackLanguage")
}

/// In-process leftover session with an explicit stamp (does not restamp live chrome).
func plantLeftoverSessionLanguage(_ language: String, sessionStamp: TimeInterval) {
    SharedPlayerManager.inMemorySessionWidgetSnapshot = SharedPlayerManager.PersistedWidgetState(
        visualState: .playing,
        currentLanguage: language,
        lastLanguageChangeTime: Date(timeIntervalSince1970: sessionStamp),
        streamMetadata: nil,
        hasError: false
    )
}

/// Privacy-gated live chrome with an explicit `updatedAt` (does not touch session RAM).
func plantHomeWidgetLiveChrome(language: String, updatedAt: TimeInterval) {
    SharedPlayerManager.persistHomeWidgetLiveChromeMirror(
        HomeWidgetLiveChrome(
            visualState: .playing,
            currentLanguage: language,
            hasError: false,
            updatedAt: updatedAt,
            stampReason: "testFreshnessPlant"
        )
    )
}

/// Symmetric tear-down for ``prepareWidgetIntentContractTestIsolation()``.
@MainActor
func tearDownWidgetIntentContractTestIsolation() {
    SharedPlayerManager._test_setSimulateWidgetProcessContext(false)
    ViewController._test_setBypassUITestModeForPendingActionProcessing(false)
    WidgetRefreshManager._test_setBypassUITestModeForRefreshGateObservation(false)
    WidgetRefreshManager._test_setRecordRefreshIfNeededGateOutcomes(false)
    WidgetRefreshManager._test_setBypassUITestModeForDebounceObservation(false)
    WidgetRefreshManager.shared._test_suspendPlayerEventObservation()
    WidgetRefreshManager._test_setSuppressPlayerEventObservation(true)
}

// MARK: - Drain host + visual restore

/// Builds a host with a real ``RadioPlayerCoordinator`` (single pending-action drain owner).
///
/// `ViewController()` already constructs a definite coordinator in designated init.
/// Drain contracts reassign a fresh coordinator for isolation; they do not call
/// `viewDidLoad` / `wireAndInitialSetup` (shims still forward to the assigned instance).
/// Set `bypassUITestMode` false to exercise the production UITestMode clear-without-execute path.
///
/// - Parameter bypassUITestMode: When true, allows real play/pause/switch execution under the
///   XCTest host (`isRunningInUITestMode`).
/// - SeeAlso: ``RadioPlayerCoordinator/checkForPendingWidgetActions()``
@MainActor
func makePendingActionDrainHost(bypassUITestMode: Bool = true) -> ViewController {
    let host = ViewController()
    host.radioPlayerCoordinator = RadioPlayerCoordinator(
        backgroundImageController: BackgroundImageController(),
        streamingPlayer: DirectStreamingPlayer.shared
    )
    ViewController._test_setBypassUITestModeForPendingActionProcessing(bypassUITestMode)
    if bypassUITestMode {
        host._test_resetWidgetActionDebounceForTests()
    }
    return host
}

@MainActor
func waitUntilWidgetIntentCondition(
    timeout: TimeInterval = 3.0,
    pollIntervalMs: UInt64 = 50,
    condition: @MainActor () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(pollIntervalMs))
    }
    return false
}

/// Undoes the same-process side effect of ``persistOptimisticWidgetSnapshot`` so drain
/// observes main-app visual authority.
///
/// Extension-shaped ``signalWidgetPendingAction`` force-sets the shared actor’s
/// `currentVisualState` via ``persistOptimisticWidgetSnapshot``. In production that
/// mutation lives only in the extension process; the main app still holds the
/// pre-signal visual until ``checkForPendingWidgetActions`` executes. The unit host
/// shares one actor, so tests must restore the main-app visual before drain while
/// keeping the optimistic session snapshot and pending command.
///
/// - Parameters:
///   - visual: Main-app visual that should remain until drain (e.g. `.playing` before pause).
///   - optimisticSnapshot: Session snapshot left by the extension write (re-applied after restore).
///   - language: Language for the re-applied optimistic snapshot.
/// - SeeAlso: ``SharedPlayerManager/persistOptimisticWidgetSnapshot(_:language:)``,
///   ``SharedPlayerManager/persistWidgetSnapshot(visualState:language:clearStreamMetadata:)``,
///   docs/Widget-Functionality-Roadmap.md (Tier 2 cross-process intents).
@MainActor
func restoreMainAppVisualPreservingOptimisticSnapshot(
    to visual: PlayerVisualState,
    optimisticSnapshot: PlayerVisualState,
    language: String
) async {
    // Wait for the fire-and-forget optimistic force-set Task to land.
    _ = await waitUntilWidgetIntentCondition(timeout: 1.0) {
        let current = await SharedPlayerManager.shared.currentVisualState
        return current == optimisticSnapshot
    }
    await SharedPlayerManager.shared.setVisualState(visual)
    // `setVisualState` may rewrite the session snapshot; re-apply the extension optimistic write.
    SharedPlayerManager.persistWidgetSnapshot(
        visualState: optimisticSnapshot,
        language: language
    )
}
