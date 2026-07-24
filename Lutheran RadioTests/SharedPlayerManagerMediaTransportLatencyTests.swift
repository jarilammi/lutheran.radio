//
//  SharedPlayerManagerMediaTransportLatencyTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 24.7.2026.
//
//  DEBUG MediaTransportLatencyTimeline ordered milestone capture for pause / Live Activity toggle paths.
//
//  Shared collectors: `Lutheran RadioTests/Support/PlayerEventTestSupport.swift`.
//  Isolation: ``prepareSharedPlayerManagerEventTestIsolation`` /
//  ``tearDownSharedPlayerManagerEventTestIsolation``.
//
//  - SeeAlso: ``SharedPlayerManager``, ``PlayerEvent``,
//    docs/Event-Driven-Refactor-Roadmap.md,
//    CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
//

import MediaPlayer
import XCTest
import WidgetSurface
@testable import Lutheran_Radio

/// Unit tests for the DEBUG ``MediaTransportLatencyTimeline`` capture path.
///
/// Protects ordered, named milestones for intent → silence measurement on pause and
/// Live Activity toggle. Capture is DEBUG-only and must not alter sticky pause or
/// transport policy. Production media-surface coordination lives in
/// ``SharedPlayerManagerMediaSurfaceTests``.
///
/// - SeeAlso: ``MediaTransportLatencyTimeline``,
///   ``SharedPlayerManager/submitMediaTransportCommandAndWait(_:)``,
///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
final class SharedPlayerManagerMediaTransportLatencyTests: XCTestCase {

    private let manager = SharedPlayerManager.shared

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()
        await prepareSharedPlayerManagerEventTestIsolation(manager: manager)
    }

    override func tearDown() async throws {
        await tearDownSharedPlayerManagerEventTestIsolation(manager: manager)
        try await super.tearDown()
    }

    // MARK: - Media transport latency timeline (DEBUG)

    /// Protects the DEBUG ``MediaTransportLatencyTimeline`` pause path: mailbox enqueue →
    /// execute → soft silence after ``stop()`` via ``stopAndWait``.
    ///
    /// Why: Device QA needs ordered, named milestones for intent → silence measurement.
    /// Capture is DEBUG-only and must not alter sticky pause or transport policy.
    /// Each milestone appears **once** in capture (console uses a single `print` sink so Xcode
    /// does not mirror identical `[MediaTransportLatency]` lines via stdout + os.Logger).
    ///
    /// - SeeAlso: ``MediaTransportLatencyTimeline``, ``SharedPlayerManager/submitMediaTransportCommandAndWait(_:)``,
    ///   ``DirectStreamingPlayer/stopAndWait(reason:silent:applyUserPauseVisualLock:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    func testMediaTransportLatencyTimelineRecordsPauseMailboxAndSoftSilence() async {
        MediaTransportLatencyTimeline._test_resetAndStartCapture()
        defer { MediaTransportLatencyTimeline._test_clearCapture() }

        await manager.setPlaying()
        await manager.submitMediaTransportCommandAndWait(.pause)

        let milestones = MediaTransportLatencyTimeline._test_milestones()
        assertEventsContainMilestones(
            milestones,
            [
                .mediaTransportEnqueued,
                .mediaTransportExecuteStarted,
                .softSilenceComplete,
                .mediaTransportExecuteFinished
            ]
        )
        // No duplicate marks for the same hop within one pause path (single-sink console contract).
        XCTAssertEqual(
            milestones.filter { $0 == .softSilenceComplete }.count,
            1,
            "softSilenceComplete must be recorded once per pause path; got: \(milestones.map(\.rawValue))"
        )

        let visual = await manager.currentVisualState
        XCTAssertEqual(visual, .userPaused, "Timeline marks must not change pause policy")
    }

    /// Protects the DEBUG latency timeline around main-app Live Activity toggle execution
    /// (optimistic ContentState path + mailbox pause): plan → optimistic → execute → soft silence.
    ///
    /// - SeeAlso: ``WidgetIntentExecution/performLiveActivityToggle()``,
    ///   ``MediaTransportLatencyTimeline``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    func testMediaTransportLatencyTimelineRecordsLiveActivityTogglePauseChain() async {
        MediaTransportLatencyTimeline._test_resetAndStartCapture()
        defer { MediaTransportLatencyTimeline._test_clearCapture() }

        // Seed playing visual so multi-source resolve plans pause (no ActivityKit activities
        // under UITestMode; actor/session fallback still yields pause from .playing).
        await manager.setPlaying()
        await WidgetIntentExecution.performLiveActivityToggle()

        let milestones = MediaTransportLatencyTimeline._test_milestones()
        assertEventsContainMilestones(
            milestones,
            [
                .liveActivityToggleStarted,
                .liveActivityTogglePlanResolved,
                .liveActivityToggleOptimisticPublished,
                .liveActivityToggleExecuteStarted,
                .mediaTransportEnqueued,
                .mediaTransportExecuteStarted,
                .softSilenceComplete,
                .mediaTransportExecuteFinished,
                .liveActivityToggleExecuteFinished
            ]
        )

        let visual = await manager.currentVisualState
        XCTAssertEqual(visual, .userPaused)
    }

    /// Ordered-subsequence matcher for DEBUG latency milestones (same pattern as
    /// ``assertEvents(_:containInOrder:)`` for `PlayerEvent`).
    private func assertEventsContainMilestones(
        _ actual: [MediaTransportLatencyTimeline.Milestone],
        _ expectedSubsequence: [MediaTransportLatencyTimeline.Milestone],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var searchFrom = actual.startIndex
        for expected in expectedSubsequence {
            guard let found = actual[searchFrom...].firstIndex(of: expected) else {
                XCTFail(
                    "Missing milestone \(expected.rawValue) in \(actual.map(\.rawValue)); expected subsequence \(expectedSubsequence.map(\.rawValue))",
                    file: file,
                    line: line
                )
                return
            }
            searchFrom = actual.index(after: found)
        }
    }
}
