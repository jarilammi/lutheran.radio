//
//  PlaybackPlayDecision.swift
//  WidgetSurface
//
//  Created by Jari Lammi on 24.7.2026.
//
//  Pure play-entry decision surfaces for SharedPlayerManager.play() early gates.
//
//  WidgetSurface framework — presentation/policy vocabulary only (no security logic,
//  no App Group I/O, no engine side effects). Side effects remain in SharedPlayerManager.
//
//  Ownership:
//  - Decision tables are pure and table-testable here.
//  - SharedPlayerManager.play() applies outcomes (pipeline flags, security, attach).
//
//  - SeeAlso: ``PlaybackIntent``, ``PlaybackAttachContext``, ``PlayerVisualState``,
//    SharedPlayerManager.play(), SharedPlayerManager.userRequestedPlay(),
//    CODING_AGENT.md (Single Source of Truth Principles).
//  - AGENT NOTE: Any change to early-gate ordering must keep sticky pause, termination
//    sentinel, already-audible idempotency, and UITest isolation semantics unchanged.
//

import Foundation

// MARK: - Play classification

/// High-level classification of a play entry for attach-context and debug labels.
///
/// Derived only from stream-switch hold + cold-launch one-shot flags — no engine state.
@frozen public enum PlaybackPlayClassification: Sendable, Equatable {
    /// Orchestrated language switch (`holdPrePlayVisualUntilPlayback`).
    case streamSwitch
    /// First automatic/cold play on this process (one-shot window).
    case trueColdLaunch
    /// Subsequent play after cold launch has completed (resume / re-attach).
    case resume
}

// MARK: - Early play outcome

/// Pure early-gate result for ``SharedPlayerManager/play()`` before security / attach.
///
/// Order is fixed and must match the actor implementation:
/// termination sentinel → sticky → duplicate pipeline → already audible → prePlay one-shot
/// → activate pipeline → UITest vs production security path.
@frozen public enum PlaybackPlayEarlyOutcome: Sendable, Equatable {
    /// Post-termination wake without an explicit user play this launch.
    case blockTerminationSentinel
    /// Sticky `.userPaused` / `.securityLocked` / `.cleared` — resurrection blocked.
    case blockStickyPauseOrLock
    /// Start pipeline already active (Connecting); keep in-flight work.
    case skipDuplicateStartPipeline
    /// Engine already audible on matching selection (or UITest chrome equivalent).
    case skipAlreadyAudible
    /// Automatic prePlay already consumed and intent is not active.
    case skipDuplicateAutomaticPrePlay
    /// UITest isolation: skip validators and engine attach; apply test visual only.
    case enterUITestIsolation
    /// Production path: proceed to security validation then soft-resume / attach.
    case proceedToSecurityValidation
}

/// Pure decision bundle applied by `SharedPlayerManager.play()` after evaluation.
public struct PlaybackPlayEarlyDecision: Sendable, Equatable {
    public let outcome: PlaybackPlayEarlyOutcome
    /// When non-nil, set `initialPlaybackHasRun` to this value (prePlay one-shot bookkeeping).
    public let setInitialPlaybackHasRun: Bool?
    /// When true, set `hasCompletedTrueColdLaunchPlay = true`.
    public let markTrueColdLaunchCompleted: Bool

    /// Whether the actor must set `isPlaybackStartPipelineActive = true` before side effects.
    public var shouldActivateStartPipeline: Bool {
        switch outcome {
        case .enterUITestIsolation, .proceedToSecurityValidation:
            return true
        case .blockTerminationSentinel, .blockStickyPauseOrLock,
             .skipDuplicateStartPipeline, .skipAlreadyAudible,
             .skipDuplicateAutomaticPrePlay:
            return false
        }
    }

    /// Whether the actor must clear the start pipeline on this early return.
    public var shouldClearStartPipelineOnReturn: Bool {
        switch outcome {
        case .blockStickyPauseOrLock:
            return true
        case .enterUITestIsolation:
            // Cleared after UITest visual side effects.
            return true
        default:
            return false
        }
    }

    public init(
        outcome: PlaybackPlayEarlyOutcome,
        setInitialPlaybackHasRun: Bool? = nil,
        markTrueColdLaunchCompleted: Bool = false
    ) {
        self.outcome = outcome
        self.setInitialPlaybackHasRun = setInitialPlaybackHasRun
        self.markTrueColdLaunchCompleted = markTrueColdLaunchCompleted
    }
}

// MARK: - Inputs

/// Snapshot of actor / process state needed for pure play-entry evaluation.
///
/// Engine-truth for already-audible is computed by the actor (`shouldNoOpPlayWhileAlreadyAudible`)
/// and passed in — the pure table never reaches AVPlayer.
public struct PlaybackPlayDecisionInputs: Sendable, Equatable {
    public var hasTerminationSentinel: Bool
    public var hasProcessedExplicitUserPlayRequest: Bool
    public var isStickyPauseOrLock: Bool
    public var isPlaybackStartPipelineActive: Bool
    public var alreadyAudibleMatchingSelection: Bool
    public var isPrePlayVisual: Bool
    public var initialPlaybackHasRun: Bool
    public var isActivePlaybackIntent: Bool
    public var isTrueColdLaunchPlay: Bool
    public var isUITestMode: Bool

    public init(
        hasTerminationSentinel: Bool,
        hasProcessedExplicitUserPlayRequest: Bool,
        isStickyPauseOrLock: Bool,
        isPlaybackStartPipelineActive: Bool,
        alreadyAudibleMatchingSelection: Bool,
        isPrePlayVisual: Bool,
        initialPlaybackHasRun: Bool,
        isActivePlaybackIntent: Bool,
        isTrueColdLaunchPlay: Bool,
        isUITestMode: Bool
    ) {
        self.hasTerminationSentinel = hasTerminationSentinel
        self.hasProcessedExplicitUserPlayRequest = hasProcessedExplicitUserPlayRequest
        self.isStickyPauseOrLock = isStickyPauseOrLock
        self.isPlaybackStartPipelineActive = isPlaybackStartPipelineActive
        self.alreadyAudibleMatchingSelection = alreadyAudibleMatchingSelection
        self.isPrePlayVisual = isPrePlayVisual
        self.initialPlaybackHasRun = initialPlaybackHasRun
        self.isActivePlaybackIntent = isActivePlaybackIntent
        self.isTrueColdLaunchPlay = isTrueColdLaunchPlay
        self.isUITestMode = isUITestMode
    }
}

// MARK: - Evaluator

/// Pure play-entry gates and attach-context classification.
///
/// - SeeAlso: ``PlaybackPlayDecisionInputs``, ``PlaybackPlayEarlyDecision``,
///   ``PlaybackAttachContext``, SharedPlayerManager.play().
public enum PlaybackPlayDecision {

    /// Classifies play entry from stream-switch hold and cold-launch completion flags.
    ///
    /// - Parameters:
    ///   - holdPrePlayVisualUntilPlayback: Stream-switch prePlay hold from orchestrated switch.
    ///   - hasCompletedTrueColdLaunchPlay: One-shot cold-launch play already completed this process.
    /// - Returns: Stream-switch, true cold launch, or resume classification.
    public static func classify(
        holdPrePlayVisualUntilPlayback: Bool,
        hasCompletedTrueColdLaunchPlay: Bool
    ) -> PlaybackPlayClassification {
        if holdPrePlayVisualUntilPlayback {
            return .streamSwitch
        }
        if !hasCompletedTrueColdLaunchPlay {
            return .trueColdLaunch
        }
        return .resume
    }

    /// Maps play classification (+ soft-pause language reattach decline) to engine attach context.
    ///
    /// - Parameters:
    ///   - classification: From ``classify(holdPrePlayVisualUntilPlayback:hasCompletedTrueColdLaunchPlay:)``.
    ///   - declinedSoftPauseForLanguageChange: Soft-resume declined because attached language ≠ selected.
    /// - Returns: ``PlaybackAttachContext`` for `attachAndPlay` / `setStreamAndPlay`.
    public static func attachContext(
        classification: PlaybackPlayClassification,
        declinedSoftPauseForLanguageChange: Bool
    ) -> PlaybackAttachContext {
        if classification == .streamSwitch || declinedSoftPauseForLanguageChange {
            return .streamSwitch
        }
        switch classification {
        case .streamSwitch:
            return .streamSwitch
        case .resume:
            return .resume
        case .trueColdLaunch:
            return .coldLaunch
        }
    }

    /// Evaluates early play gates in production order. Side-effect free.
    ///
    /// - Parameter inputs: Actor-gathered snapshot (see ``PlaybackPlayDecisionInputs``).
    /// - Returns: Outcome plus optional one-shot flag mutations for the actor to apply.
    /// - Important: Sticky pause always wins over cold-launch relaxed resurrection.
    ///   Already-audible is independent of the cold-launch window (passed in as a bool).
    public static func evaluateEarlyGates(
        _ inputs: PlaybackPlayDecisionInputs
    ) -> PlaybackPlayEarlyDecision {
        // 1. Post-termination sentinel without explicit user play this launch.
        if inputs.hasTerminationSentinel && !inputs.hasProcessedExplicitUserPlayRequest {
            return PlaybackPlayEarlyDecision(outcome: .blockTerminationSentinel)
        }

        // 2. Sticky pause / security lock / privacy clear — never bypass.
        if inputs.isStickyPauseOrLock {
            return PlaybackPlayEarlyDecision(outcome: .blockStickyPauseOrLock)
        }

        // 3. Duplicate entry while Connecting / start pipeline active.
        if inputs.isPlaybackStartPipelineActive {
            return PlaybackPlayEarlyDecision(outcome: .skipDuplicateStartPipeline)
        }

        // 4. Already audibly playing matching selection (engine-truth from actor).
        if inputs.alreadyAudibleMatchingSelection {
            return PlaybackPlayEarlyDecision(outcome: .skipAlreadyAudible)
        }

        // 5. Automatic prePlay one-shot (active intent re-opens the gate).
        var setInitial: Bool?
        var markCold = false
        if inputs.isPrePlayVisual {
            if inputs.initialPlaybackHasRun && !inputs.isActivePlaybackIntent {
                return PlaybackPlayEarlyDecision(outcome: .skipDuplicateAutomaticPrePlay)
            }
            if inputs.isActivePlaybackIntent {
                setInitial = false
            } else {
                setInitial = true
            }
            if inputs.isTrueColdLaunchPlay {
                markCold = true
            }
        }

        // 6. Pipeline activates; UITest vs production security path.
        if inputs.isUITestMode {
            return PlaybackPlayEarlyDecision(
                outcome: .enterUITestIsolation,
                setInitialPlaybackHasRun: setInitial,
                markTrueColdLaunchCompleted: markCold
            )
        }

        return PlaybackPlayEarlyDecision(
            outcome: .proceedToSecurityValidation,
            setInitialPlaybackHasRun: setInitial,
            markTrueColdLaunchCompleted: markCold
        )
    }
}
