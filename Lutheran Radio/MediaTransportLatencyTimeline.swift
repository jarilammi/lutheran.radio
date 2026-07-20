//
//  MediaTransportLatencyTimeline.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 20.7.2026.
//

// SHARED: Cross-target source (main app + LutheranRadioWidgetExtension)
//
// Single physical file on disk, compiled into both targets via Xcode
// File System Synchronized Group + membershipExceptions (see project.pbxproj).
//
// Purpose:
// DEBUG-only structured latency timeline for media-transport measurement across
// system Now Playing remotes, Live Activity toggle, soft-silence completion,
// authoritative audible start, and extension pending-action drain.
//
// Key invariants:
// - Entire type is wrapped in `#if DEBUG` and is stripped from Release.
// - Marks never change transport policy, audio paths, or surface refresh order.
// - No security logic. Security decisions live only in `Core/`.
// - Safe from actor-isolated and MainActor call sites (internal lock).
//
// Console format (device QA greps this prefix):
//   [MediaTransportLatency] #n t=+Tms dt=+Dms <milestone> [detail]
//   - t  = elapsed since last ``reset()`` (or first mark after process start)
//   - dt = delta since previous mark (the useful per-hop latency)
//
// - SeeAlso: ``SharedPlayerManager/submitMediaTransportCommand(_:)``,
//   ``WidgetIntentExecution/performLiveActivityToggle()``,
//   ``DirectStreamingPlayer/stopAndWait(reason:silent:applyUserPauseVisualLock:)``,
//   ``DirectStreamingPlayer`` `publishAuthoritativePlayingIfNeeded`,
//   ``ViewController/checkForPendingWidgetActions()``,
//   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
//   CODING_AGENT.md (cross-target widget sources).

#if DEBUG

import Foundation
import os

/// DEBUG-only structured latency timeline for lock-screen and media-transport paths.
///
/// Captures ordered milestones so device QA can measure intent → soft silence and
/// intent → first audio with numbers rather than anecdotes. Does **not** alter
/// transport policy, mailbox ordering, soft-pause, or surface refresh.
///
/// **Thread-safety:** Marks are serialized with ``OSAllocatedUnfairLock``. Safe to call
/// from ``SharedPlayerManager`` (actor), MainActor UI, and extension intent hosts.
///
/// **Release:** The entire type is compiled out under non-DEBUG configurations.
///
/// - SeeAlso: docs/Live-Activity-Stacking-and-Media-Surfaces.md (media-transport latency timeline),
///   ``SharedPlayerManager/submitMediaTransportCommand(_:)``,
///   ``WidgetIntentExecution/performLiveActivityToggle()``.
enum MediaTransportLatencyTimeline: Sendable {

    /// Named milestones along the media-transport and cross-process drain path.
    ///
    /// Names are stable for log grepping and unit-test subsequence matching.
    enum Milestone: String, Sendable, Equatable, CaseIterable {
        /// ``WidgetIntentExecution/performLiveActivityToggle()`` entered.
        case liveActivityToggleStarted
        /// Plan resolved (detail carries plan + source summary).
        case liveActivityTogglePlanResolved
        /// Optimistic ContentState / durable mirror published.
        case liveActivityToggleOptimisticPublished
        /// Engine execute path entered (mailbox or extension stop/play).
        case liveActivityToggleExecuteStarted
        /// Engine execute path returned.
        case liveActivityToggleExecuteFinished

        /// ``submitMediaTransportCommand(_:)`` enqueued a verb (detail = command).
        case mediaTransportEnqueued
        /// ``performMediaTransportCommand(_:generation:)`` started (detail = command).
        case mediaTransportExecuteStarted
        /// ``performMediaTransportCommand(_:generation:)`` finished (detail = command).
        case mediaTransportExecuteFinished

        /// Soft-pause / ``stopAndWait`` completed (engine rate 0 / soft path done).
        case softSilenceComplete

        /// ``publishAuthoritativePlayingIfNeeded`` called ``setPlaying()`` after audible start.
        case authoritativePlayingPublished
        /// Authoritative playing publish skipped (sticky pause or already playing).
        case authoritativePlayingSkipped

        /// ``checkForPendingWidgetActions()`` found a fresh pending action (detail = action).
        case pendingActionDrainEntered
        /// Same-direction play/pause debounce dropped the drain (detail = action).
        case pendingActionDrainDebounced
        /// Extension-originated play drain started mailbox play.
        case pendingActionDrainPlayStarted
        /// Extension-originated play drain finished mailbox play.
        case pendingActionDrainPlayFinished
        /// Extension-originated pause drain started coordinator pause.
        case pendingActionDrainPauseStarted
        /// Extension-originated pause drain finished (or ignored as already paused).
        case pendingActionDrainPauseFinished
    }

    /// One captured milestone for unit-test inspection.
    struct Sample: Sendable, Equatable {
        /// Monotonic sequence within the current capture window.
        let sequence: UInt64
        /// Milestone name.
        let milestone: Milestone
        /// Elapsed since the last ``reset()`` (or process-first mark).
        let elapsedSinceReset: Duration
        /// Delta since the previous mark (zero for the first mark after reset).
        let deltaSincePrevious: Duration
        /// Optional structured detail (command name, plan, action verb, skip reason).
        let detail: String?
    }

    private struct State: Sendable {
        var origin: ContinuousClock.Instant
        var lastMark: ContinuousClock.Instant?
        var sequence: UInt64
        var samples: [Sample]
        var captureEnabled: Bool
    }

    /// SAFETY: DEBUG-only shared mutable state; locked on every access. Not used in Release.
    private static let state = OSAllocatedUnfairLock(
        initialState: State(
            origin: ContinuousClock.now,
            lastMark: nil,
            sequence: 0,
            samples: [],
            captureEnabled: false
        )
    )

    private static let maxCapturedSamples = 256

    private static let log = Logger(
        subsystem: "radio.lutheran",
        category: "MediaTransportLatency"
    )

    // MARK: - Public API

    /// Resets the elapsed-time origin and clears captured samples.
    ///
    /// Call from unit tests before driving a transport path, or from a DEBUG console
    /// session before a manual lock-screen scenario.
    ///
    /// - Parameter reason: Optional detail printed with the reset (not a milestone).
    static func reset(reason: String? = nil) {
        state.withLock { s in
            s.origin = ContinuousClock.now
            s.lastMark = nil
            s.sequence = 0
            s.samples = []
        }
        let suffix = reason.map { " reason=\($0)" } ?? ""
        print("[MediaTransportLatency] reset\(suffix)")
        log.debug("reset\(suffix, privacy: .public)")
    }

    /// Records a milestone, prints a structured console line, and optionally captures for tests.
    ///
    /// - Parameters:
    ///   - milestone: Named hop along the transport / drain path.
    ///   - detail: Compact context (e.g. `pause`, `plan=pause source=contentState`).
    /// - Important: No-op with respect to product behavior — logging and test capture only.
    static func mark(_ milestone: Milestone, detail: String? = nil) {
        let now = ContinuousClock.now
        let sample: Sample = state.withLock { s in
            let elapsed = now - s.origin
            let delta = s.lastMark.map { now - $0 } ?? .zero
            s.lastMark = now
            s.sequence &+= 1
            let sample = Sample(
                sequence: s.sequence,
                milestone: milestone,
                elapsedSinceReset: elapsed,
                deltaSincePrevious: delta,
                detail: detail
            )
            if s.captureEnabled {
                s.samples.append(sample)
                if s.samples.count > maxCapturedSamples {
                    s.samples.removeFirst(s.samples.count - maxCapturedSamples)
                }
            }
            return sample
        }

        let line = formatConsoleLine(sample)
        print(line)
        log.debug("\(line, privacy: .public)")
    }

    // MARK: - Test seams

    /// Enables in-memory sample capture for unit tests (still prints).
    static func _test_setCaptureEnabled(_ enabled: Bool) {
        state.withLock { $0.captureEnabled = enabled }
    }

    /// Resets origin, clears samples, and enables capture.
    static func _test_resetAndStartCapture() {
        state.withLock { s in
            s.origin = ContinuousClock.now
            s.lastMark = nil
            s.sequence = 0
            s.samples = []
            s.captureEnabled = true
        }
    }

    /// Returns a snapshot of captured samples (empty when capture is off).
    static func _test_samples() -> [Sample] {
        state.withLock { $0.samples }
    }

    /// Convenience: milestone names only, in capture order.
    static func _test_milestones() -> [Milestone] {
        state.withLock { $0.samples.map(\.milestone) }
    }

    /// Disables capture and clears samples (leaves console origin unchanged unless ``reset()``).
    static func _test_clearCapture() {
        state.withLock { s in
            s.captureEnabled = false
            s.samples = []
        }
    }

    // MARK: - Formatting

    private static func formatConsoleLine(_ sample: Sample) -> String {
        let tMs = milliseconds(sample.elapsedSinceReset)
        let dtMs = milliseconds(sample.deltaSincePrevious)
        var line =
            "[MediaTransportLatency] #\(sample.sequence) t=+\(tMs)ms dt=+\(dtMs)ms \(sample.milestone.rawValue)"
        if let detail = sample.detail, !detail.isEmpty {
            line += " \(detail)"
        }
        return line
    }

    /// Formats a ``Duration`` as milliseconds with one fractional digit (device-QA friendly).
    private static func milliseconds(_ duration: Duration) -> String {
        let components = duration.components
        let ms =
            Double(components.seconds) * 1000.0
            + Double(components.attoseconds) / 1_000_000_000_000_000.0
        return String(format: "%.1f", ms)
    }
}

#endif
