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

    /// Prior-process termination liveness is not an input to pure play gates.
    /// Sticky intent remains the only hard blocker at this table layer.
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

    /// Active intent + clean prePlay must proceed even when a prior process left termination
    /// liveness in the App Group — that key is intentionally not an early-gate input.
    @Test func processIsolation_activePrePlayProceedsWithoutPriorProcessKeys() {
        let decision = PlaybackPlayDecision.evaluateEarlyGates(
            baseInputs(prePlay: true, initialRun: false, activeIntent: true, trueCold: true)
        )
        #expect(decision.outcome == .proceedToSecurityValidation)
        #expect(decision.shouldActivateStartPipeline)
    }

    // MARK: - Connecting chrome (post-security)

    @Test func connectingPrePlayChromeOnlyWhenActiveAndNotAlreadyConnectingOrPlaying() {
        #expect(
            PlaybackPlayDecision.shouldApplyConnectingPrePlayChrome(
                visualState: .userPaused,
                isActivePlaybackIntent: true
            )
        )
        #expect(
            !PlaybackPlayDecision.shouldApplyConnectingPrePlayChrome(
                visualState: .prePlay,
                isActivePlaybackIntent: true
            )
        )
        #expect(
            !PlaybackPlayDecision.shouldApplyConnectingPrePlayChrome(
                visualState: .playing,
                isActivePlaybackIntent: true
            )
        )
        #expect(
            !PlaybackPlayDecision.shouldApplyConnectingPrePlayChrome(
                visualState: .userPaused,
                isActivePlaybackIntent: false
            )
        )
    }

    /// Soft-pause same-stream resume must not stamp Connecting — gapless audio outruns yellow chrome.
    @Test func connectingPrePlayChromeSkippedWhenSoftResumeSameStreamAvailable() {
        #expect(
            !PlaybackPlayDecision.shouldApplyConnectingPrePlayChrome(
                visualState: .userPaused,
                isActivePlaybackIntent: true,
                canSoftResumeSameStream: true
            )
        )
        #expect(
            PlaybackPlayDecision.shouldApplyConnectingPrePlayChrome(
                visualState: .userPaused,
                isActivePlaybackIntent: true,
                canSoftResumeSameStream: false
            )
        )
    }
}
