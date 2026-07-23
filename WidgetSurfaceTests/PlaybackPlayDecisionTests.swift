//
//  PlaybackPlayDecisionTests.swift
//  WidgetSurfaceTests
//
//  Created by Jari Lammi on 24.7.2026.
//
//  Table-driven pure play-entry gates and attach-context classification.
//  Protects early-gate ordering for SharedPlayerManager.play() without engine I/O.
//
//  - SeeAlso: ``PlaybackPlayDecision``, ``PlaybackPlayDecisionInputs``,
//    ``PlaybackAttachContext``, SharedPlayerManager.play().
//

import Foundation
import Testing
import WidgetSurface

struct PlaybackPlayDecisionTests {

    // MARK: - Classification

    @Test func classifyStreamSwitchHoldWins() {
        #expect(
            PlaybackPlayDecision.classify(
                holdPrePlayVisualUntilPlayback: true,
                hasCompletedTrueColdLaunchPlay: false
            ) == .streamSwitch
        )
        #expect(
            PlaybackPlayDecision.classify(
                holdPrePlayVisualUntilPlayback: true,
                hasCompletedTrueColdLaunchPlay: true
            ) == .streamSwitch
        )
    }

    @Test func classifyColdLaunchThenResume() {
        #expect(
            PlaybackPlayDecision.classify(
                holdPrePlayVisualUntilPlayback: false,
                hasCompletedTrueColdLaunchPlay: false
            ) == .trueColdLaunch
        )
        #expect(
            PlaybackPlayDecision.classify(
                holdPrePlayVisualUntilPlayback: false,
                hasCompletedTrueColdLaunchPlay: true
            ) == .resume
        )
    }

    @Test func attachContextFromClassificationAndSoftPauseDecline() {
        #expect(
            PlaybackPlayDecision.attachContext(
                classification: .streamSwitch,
                declinedSoftPauseForLanguageChange: false
            ) == .streamSwitch
        )
        #expect(
            PlaybackPlayDecision.attachContext(
                classification: .resume,
                declinedSoftPauseForLanguageChange: true
            ) == .streamSwitch
        )
        #expect(
            PlaybackPlayDecision.attachContext(
                classification: .resume,
                declinedSoftPauseForLanguageChange: false
            ) == .resume
        )
        #expect(
            PlaybackPlayDecision.attachContext(
                classification: .trueColdLaunch,
                declinedSoftPauseForLanguageChange: false
            ) == .coldLaunch
        )
    }

    // MARK: - Early gates (table)

    private func baseInputs(
        sentinel: Bool = false,
        explicitPlay: Bool = true,
        sticky: Bool = false,
        pipeline: Bool = false,
        alreadyAudible: Bool = false,
        prePlay: Bool = false,
        initialRun: Bool = false,
        activeIntent: Bool = true,
        trueCold: Bool = false,
        uiTest: Bool = false
    ) -> PlaybackPlayDecisionInputs {
        PlaybackPlayDecisionInputs(
            hasTerminationSentinel: sentinel,
            hasProcessedExplicitUserPlayRequest: explicitPlay,
            isStickyPauseOrLock: sticky,
            isPlaybackStartPipelineActive: pipeline,
            alreadyAudibleMatchingSelection: alreadyAudible,
            isPrePlayVisual: prePlay,
            initialPlaybackHasRun: initialRun,
            isActivePlaybackIntent: activeIntent,
            isTrueColdLaunchPlay: trueCold,
            isUITestMode: uiTest
        )
    }

    @Test func blocksTerminationSentinelWithoutExplicitPlay() {
        let decision = PlaybackPlayDecision.evaluateEarlyGates(
            baseInputs(sentinel: true, explicitPlay: false)
        )
        #expect(decision.outcome == .blockTerminationSentinel)
        #expect(!decision.shouldActivateStartPipeline)
    }

    @Test func allowsTerminationSentinelWhenExplicitPlayProcessed() {
        let decision = PlaybackPlayDecision.evaluateEarlyGates(
            baseInputs(sentinel: true, explicitPlay: true)
        )
        #expect(decision.outcome == .proceedToSecurityValidation)
        #expect(decision.shouldActivateStartPipeline)
    }

    @Test func stickyPauseBlocksBeforePipeline() {
        let decision = PlaybackPlayDecision.evaluateEarlyGates(
            baseInputs(sticky: true, pipeline: true, alreadyAudible: true)
        )
        #expect(decision.outcome == .blockStickyPauseOrLock)
        #expect(decision.shouldClearStartPipelineOnReturn)
    }

    @Test func skipDuplicateStartPipeline() {
        let decision = PlaybackPlayDecision.evaluateEarlyGates(
            baseInputs(pipeline: true)
        )
        #expect(decision.outcome == .skipDuplicateStartPipeline)
    }

    @Test func skipAlreadyAudible() {
        let decision = PlaybackPlayDecision.evaluateEarlyGates(
            baseInputs(alreadyAudible: true)
        )
        #expect(decision.outcome == .skipAlreadyAudible)
    }

    @Test func skipDuplicateAutomaticPrePlay() {
        let decision = PlaybackPlayDecision.evaluateEarlyGates(
            baseInputs(prePlay: true, initialRun: true, activeIntent: false)
        )
        #expect(decision.outcome == .skipDuplicateAutomaticPrePlay)
    }

    @Test func prePlayActiveIntentResetsOneShotAndProceeds() {
        let decision = PlaybackPlayDecision.evaluateEarlyGates(
            baseInputs(prePlay: true, initialRun: true, activeIntent: true, trueCold: true)
        )
        #expect(decision.outcome == .proceedToSecurityValidation)
        #expect(decision.setInitialPlaybackHasRun == false)
        #expect(decision.markTrueColdLaunchCompleted)
    }

    @Test func prePlayAutomaticMarksInitialRun() {
        let decision = PlaybackPlayDecision.evaluateEarlyGates(
            baseInputs(prePlay: true, initialRun: false, activeIntent: false, trueCold: true)
        )
        #expect(decision.outcome == .proceedToSecurityValidation)
        #expect(decision.setInitialPlaybackHasRun == true)
        #expect(decision.markTrueColdLaunchCompleted)
    }

    @Test func uiTestIsolationAfterGates() {
        let decision = PlaybackPlayDecision.evaluateEarlyGates(
            baseInputs(activeIntent: true, uiTest: true)
        )
        #expect(decision.outcome == .enterUITestIsolation)
        #expect(decision.shouldActivateStartPipeline)
        #expect(decision.shouldClearStartPipelineOnReturn)
    }

    @Test func stickyWinsOverUITestAndAlreadyAudible() {
        let decision = PlaybackPlayDecision.evaluateEarlyGates(
            baseInputs(sticky: true, alreadyAudible: true, uiTest: true)
        )
        #expect(decision.outcome == .blockStickyPauseOrLock)
    }
}
