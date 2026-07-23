//
//  SharedPlayerManager+DebugTestSeams.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 23.7.2026.
//
//  SHARED: Cross-target membership-exception source (main app + extension +
//  LutheranRadioWidgetTests). Mechanical split of SharedPlayerManager — same actor,
//  no API renames, no behavior change.
//
//  Purpose: DEBUG-only test seams for widget-process simulation and isolation (compiled out of Release).
//
//  - SeeAlso: SharedPlayerManager.swift, CODING_AGENT.md (cross-target membership exceptions).
//

import Foundation
import Core
import WidgetSurface
#if LUTHERAN_MAIN_APP
import os
import WidgetKit
#endif

// MARK: - DEBUG test seams (compiled out of Release)

#if DEBUG
extension SharedPlayerManager {

    // SAFETY: DEBUG-only process-context flag written from XCTest entry points; reads occur
    // from actor-isolated and nonisolated ``isRunningInWidget()`` during unit tests. Matches
    // the established nonisolated(unsafe) pattern for gate-observation seams in WidgetRefreshManager.
    nonisolated(unsafe) internal static var _test_simulateWidgetProcessContext = false

    /// Simulates widget-extension process context for unit tests of cross-process guards.
    ///
    /// When `true` in the main-app test host, ``isRunningInWidget()`` and
    /// ``isWidgetProcess()`` report widget context so ``emit(_:)`` suppresses stream delivery,
    /// ``PlayerEventSubscriber/beginObserving()`` returns before replay attachment, and
    /// ``WidgetRefreshManager`` does not start the Tier 2 live observer.
    ///
    /// - Parameter simulate: Pass `true` to exercise widget-process suppression; `false`
    ///   restores normal main-app behavior.
    /// - SeeAlso: ``isRunningInWidget()``, ``isWidgetProcess()``, ``emit(_:)``,
    ///   ``PlayerEventSubscriber``, ``SharedPlayerManagerEventTests``,
    ///   ``PlayerEventSubscriberEventTests``, CODING_AGENT.md (fast test patterns),
    ///   docs/Event-Driven-Refactor-Roadmap.md.
    nonisolated static func _test_setSimulateWidgetProcessContext(_ simulate: Bool) {
        unsafe _test_simulateWidgetProcessContext = simulate
    }

    /// Unit-test seam: force or clear the play start pipeline for Connecting-cancel / idempotent-play gates.
    ///
    /// - Parameter active: When `true`, ``isConnectingPlayback`` is true until visual is `.playing`
    ///   or ``stop()`` / ``setPlaying()`` clears the pipeline.
    /// - SeeAlso: ``isConnectingPlayback``,
    ///   ``WidgetIntentCoordinators/planLiveActivityToggle(resolution:distrustDurableMirrorPlay:isConnectingPlayback:)``
    func _test_setPlaybackStartPipelineActive(_ active: Bool) {
        isPlaybackStartPipelineActive = active
    }

    /// Recreates the authoritative ``events`` ``AsyncStream`` for XCTest isolation.
    ///
    /// ``AsyncStream`` admits one iterator at a time. A cancelled Tier 2 observer or replay
    /// forwarding task can leave the shared stream in a state where new collectors receive
    /// no yields even though ``emit(_:)`` continues to post the DEBUG notification seam.
    /// Emitter live-stream contract tests call this after suspending ``WidgetRefreshManager``
    /// observation and before attaching a fresh collector.
    ///
    /// - Important: DEBUG and XCTest only. Production observers must never call this.
    /// - SeeAlso: ``events``, ``cancelReplayForwarding()``,
    ///   ``WidgetRefreshManager/_test_suspendPlayerEventObservation()``,
    ///   ``testLiveEventsStreamDeliversStreamDidStartFromSetPlaying``,
    ///   CODING_AGENT.md (fast test patterns).
    func _test_resetEventsStreamForIsolation() {
        cancelReplayForwarding()
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
    }
}
#endif
