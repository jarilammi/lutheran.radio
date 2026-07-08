//
//  WidgetEventObserver.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 4.7.2026.
//
//  SHARED: Cross-target source (main app + LutheranRadioWidgetExtension)
//
//  Single physical file on disk, compiled into both targets via Xcode
//  File System Synchronized Group + membershipExceptions (see project.pbxproj).
//
//  Purpose:
//  Internal lightweight helper that factors the common long-lived AsyncSequence
//  observation pattern used by widget / Live Activity managers.
//
//  Key invariants:
//  - Strictly additive extraction. Existing direct observation sites and all
//    imperative paths remain unchanged and primary.
//  - Test seams (`xxxObservationTask` properties) continue to expose the
//    underlying cancellable Task exactly as before.
//  - No polling is introduced. Observation lifetime is tied to explicit
//    begin / cancel call sites in the managers.
//  - This file contains *no* security logic. Security decisions live only in
//    `Core/` (see CODING_AGENT.md "Core Framework Surface Area").
//
//  - SeeAlso: `WidgetRefreshManager` (PlayerEvent observation),
//    `RadioLiveActivityManager` (Live Activity contentUpdates / attribute events),
//    `SharedPlayerManager.events`, `SharedPlayerManager.currentState`,
//    `SharedPlayerManager.makeEventsStreamWithReplay()`, `PlayerEvent`,
//    `PlayerCurrentState`,
//    CODING_AGENT.md (Single Source of Truth Principles, "Cross-target shared
//    source files (non-Core)", Documentation & Comment Standards),
//    docs/Widget-Presentation-Dataflow.md (Live Activity Event-Driven + events observation),
//    docs/Event-Driven-Refactor-Roadmap.md (Tier 2 polish item + Tier 3 replay),
//    <doc:Architecture>.
//

import Foundation

// MARK: - WidgetEventObserver

/// Lightweight internal helper that owns a cancellable `Task` observing an
/// `AsyncSequence` and delivers elements via a caller-supplied `@MainActor` handler.
///
/// This extracts the repeated boilerplate used by the Tier 2 observers:
/// - `WidgetRefreshManager` observing `SharedPlayerManager.events` (PlayerEvent sequence)
/// - `RadioLiveActivityManager` observing `Activity.contentUpdates` (attribute events for ContentState)
///
/// The helper centralizes:
/// - Cancel-before-start semantics
/// - Weak-self safe handler delivery on the main actor
/// - Optional terminal handler (for stream end / dismissal self-healing)
/// - Exposure of the raw `task` for existing test seams and explicit cancellation sites
///
/// ## Why a dedicated helper
/// The two observation surfaces differ (global player-domain `AsyncStream` vs.
/// per-ActivityKit attribute stream), but the wiring, lifetime rules, and
/// main-actor handoff are identical. Consolidating here improves maintainability
/// for future Tier 3/4 consumers without altering any public contract or adding
/// polling / forcing behavior.
///
/// ## Usage (internal)
/// ```swift
/// let observer = WidgetEventObserver<PlayerEvent>()
/// observer.beginObserving(stream) { [weak self] event in
///     await self?.handle(event)
/// }
/// myTaskProperty = observer.task   // preserves white-box test seam
/// ```
///
/// For sequences that require `@preconcurrency` / non-Sendable bridging (ActivityKit
/// `contentUpdates`), use the `unsafe` overload after a `nonisolated(unsafe)` binding
/// at the call site.
///
/// - Important: This type is additive only. Callers retain full control over when
///   observation starts and stops. No automatic lifetime tying beyond explicit cancel.
/// - Note: The helper itself performs no interpretation of elements and introduces
///   zero new scheduling or timers.
/// - SeeAlso: ``beginObserving(_:onElement:onTermination:)``,
///   ``beginObserving(unsafeSequence:onElement:onTermination:)``,
///   `WidgetRefreshManager.beginObservingPlayerEvents`,
///   `RadioLiveActivityManager.beginObservingActivityEvents`,
///   `SharedPlayerManager.makeEventsStreamWithReplay()`,
///   `SharedPlayerManager.currentState`,
///   `PlayerCurrentState`,
///   `PlayerCurrentState.isInPermanentError`,
///   docs/Widget-Presentation-Dataflow.md,
///   docs/Event-Driven-Refactor-Roadmap.md,
///   CODING_AGENT.md,
///   `WidgetEventObserverTests` (cancel/restart, delivery, termination contracts).
///
/// AGENT NOTE: Single source of truth for the common event/attribute observation
/// pattern in widget surfaces. Any evolution of delivery (e.g. adding replay,
/// error propagation, or structured cancellation) must be made here and the
/// two manager sites updated together. Preserve the `task` seam for tests.
@MainActor
final class WidgetEventObserver<Element> where Element: Sendable {
    /// The underlying observation task.
    ///
    /// Exposed as `internal` (via the managers' stored properties) so that
    /// white-box tests can cancel, assert presence, and observe lifetime
    /// without reflection. Production code outside the two managers must not
    /// read or assign this directly.
    private(set) var task: Task<Void, Never>?

    /// Creates a new observer. Observation does not start until `beginObserving`.
    init() {}

    /// Begins observation of the provided sequence.
    ///
    /// Any prior task is cancelled first. Elements are delivered to `onElement`
    /// on the main actor. When the sequence terminates, `onTermination` (if
    /// supplied) is invoked once on the main actor.
    ///
    /// - Parameters:
    ///   - sequence: The `AsyncSequence` to consume (typically an `AsyncStream`
    ///     such as `SharedPlayerManager.events`).
    ///   - onElement: Handler invoked for every yielded element. Executed on the
    ///     main actor.
    ///   - onTermination: Optional handler invoked exactly once after the
    ///     sequence ends (stream completion, cancellation, or terminal state).
    ///     Executed on the main actor.
    /// - Postcondition: `task` holds the live observation task (or nil after cancel).
    /// - Note: The handler should capture `[weak self]` when it needs to call
    ///   back into the owning manager.
    func beginObserving<S: AsyncSequence & Sendable>(
        _ sequence: S,
        onElement: @MainActor @escaping (Element) async -> Void,
        onTermination: (@MainActor () async -> Void)? = nil
    ) where S.Element == Element {
        task?.cancel()

        task = Task { @MainActor in
            // Use try await to satisfy the general AsyncSequence protocol
            // (iterator next() is throwing in the protocol definition). The
            // concrete sequences used (AsyncStream, ActivityKit contentUpdates)
            // do not produce errors on these paths; normal termination ends
            // the loop.
            do {
                for try await element in sequence {
                    await onElement(element)
                }
            } catch {
                // No-op: observed sequences signal completion by ending iteration.
            }
            if let onTermination {
                await onTermination()
            }
        }
    }

    /// Begins observation for a sequence obtained from a non-Sendable framework
    /// surface (e.g. `Activity<LutheranRadioLiveActivityAttributes>.contentUpdates`).
    ///
    /// Callers must materialize the sequence under `nonisolated(unsafe)` (see
    /// established pattern in `RadioLiveActivityManager`) and pass the value
    /// here using the `unsafe` expression at the call site. The unsafe overload
    /// intentionally omits the Sendable requirement on S.
    ///
    /// - Parameters:
    ///   - sequence: The sequence value previously bound via nonisolated(unsafe).
    ///   - onElement: Per-element handler (main actor).
    ///   - onTermination: Optional terminal handler (main actor).
    /// - SeeAlso: ``beginObserving(_:onElement:onTermination:)``
    func beginObserving<S: AsyncSequence>(
        unsafeSequence sequence: S,
        onElement: @MainActor @escaping (Element) async -> Void,
        onTermination: (@MainActor () async -> Void)? = nil
    ) where S.Element == Element {
        task?.cancel()

        // SAFETY: The `unsafe` use here is the consolidated site for sequences
        // that originate from ActivityKit (or similar) non-Sendable surfaces.
        // The caller has already performed the nonisolated(unsafe) extraction
        // (matching the prior direct implementation). This keeps the unsafe
        // surface small, documented, and identical in risk profile to the code
        // it replaced. The iteration itself performs no additional bridging.
        task = Task { @MainActor in
            do {
                // The `unsafe` form acknowledges the caller's nonisolated(unsafe)
                // materialization of a non-Sendable framework sequence. No further
                // unsafe operations occur inside the loop body.
                for try await element in sequence {
                    await onElement(element)
                }
            } catch {
                // No-op: observed sequences signal completion by ending iteration.
            }
            if let onTermination {
                await onTermination()
            }
        }
    }

    /// Cancels the current observation task (if any) and clears the reference.
    ///
    /// Idempotent. Called from end paths, test sanitization, and termination
    /// handlers in the managers.
    func cancel() {
        task?.cancel()
        task = nil
    }
}
