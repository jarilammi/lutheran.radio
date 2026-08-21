//
//  WidgetSurfaceTests.swift
//  WidgetSurfaceTests
//
//  Pure WidgetSurface framework tests (no SharedPlayerManager / extension SPM).
//  Complements LutheranRadioWidgetTests, which exercise the extension compile profile.
//
//  - SeeAlso: ``WidgetIntentCoordinators``, ``WidgetLivenessPresentation``,
//    ``WidgetTimelineEntryFactory``, ``WidgetProviderPresentationAssembly``,
//    ``displayFlag(for:)``, ``displayLanguageName(for:preferredStreamLanguage:)``,
//    ``HomeWidgetLiveChrome``,
//    docs/Widget-Functionality-Roadmap.md,
//    docs/Home-Live-Chrome-App-Group-Mirror-Design.md.
//

import Foundation
import Testing
import WidgetSurface

struct WidgetSurfaceTests {

    // MARK: - Home live chrome payload (pure encode / tokens)

    /// Protects stable visual-token encode/decode for common home-chrome visuals.
    ///
    /// - SeeAlso: ``HomeWidgetLiveChrome``, docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§3, §10.1).
    @Test func homeWidgetLiveChromeRoundTripCommonVisuals() throws {
        let cases: [PlayerVisualState] = [.prePlay, .playing, .userPaused]
        for visual in cases {
            let chrome = HomeWidgetLiveChrome(
                visualState: visual,
                currentLanguage: "fi",
                hasError: false,
                updatedAt: 1_700_000_000,
                stampReason: "pureRoundTrip"
            )
            let data = try JSONEncoder().encode(chrome)
            let decoded = try JSONDecoder().decode(HomeWidgetLiveChrome.self, from: data)
            #expect(decoded.visualState == visual)
            #expect(decoded.currentLanguage == "fi")
            #expect(decoded.hasError == false)
            #expect(decoded.updatedAt == 1_700_000_000)
            #expect(decoded.stampReason == "pureRoundTrip")
        }
    }

    /// Unknown visual tokens must fail decode so App Group load treats the mirror as absent.
    ///
    /// - SeeAlso: ``HomeWidgetLiveChrome/playerVisualState(fromStableToken:)``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§3 encoding notes).
    @Test func homeWidgetLiveChromeUnknownVisualTokenFailsDecode() {
        let json = Data(
            #"{"visualState":"notARealVisual","currentLanguage":"en","hasError":false,"updatedAt":1.0}"#.utf8
        )
        #expect((try? JSONDecoder().decode(HomeWidgetLiveChrome.self, from: json)) == nil)
        #expect(HomeWidgetLiveChrome.playerVisualState(fromStableToken: "notARealVisual") == nil)
    }

    /// Identity skip ignores stampReason / updatedAt when visual + language + hasError match.
    ///
    /// - SeeAlso: ``shouldSkipIdenticalHomeWidgetLiveChromeWrite(existing:candidate:)``.
    @Test func homeWidgetLiveChromeIdentitySkipIgnoresReasonAndTime() {
        let a = HomeWidgetLiveChrome(
            visualState: .playing,
            currentLanguage: "en",
            hasError: false,
            updatedAt: 1,
            stampReason: "first"
        )
        let b = HomeWidgetLiveChrome(
            visualState: .playing,
            currentLanguage: "en",
            hasError: false,
            updatedAt: 99,
            stampReason: "second"
        )
        #expect(shouldSkipIdenticalHomeWidgetLiveChromeWrite(existing: a, candidate: b))
        let c = HomeWidgetLiveChrome(
            visualState: .userPaused,
            currentLanguage: "en",
            hasError: false,
            updatedAt: 99,
            stampReason: "second"
        )
        #expect(!shouldSkipIdenticalHomeWidgetLiveChromeWrite(existing: a, candidate: c))
        #expect(!shouldSkipIdenticalHomeWidgetLiveChromeWrite(existing: nil, candidate: b))
    }

    // MARK: - Session vs live-chrome freshness (Provider paint)

    /// Protects factory path when both session and mirror are absent.
    @Test func resolveHomeWidgetChromeFieldsFactoryWhenBothAbsent() {
        let resolved = resolveHomeWidgetChromeFields(
            sessionVisual: nil,
            sessionLanguage: nil,
            sessionHasError: nil,
            sessionUpdatedAt: nil,
            liveChrome: nil
        )
        #expect(resolved.visualState == .prePlay)
        #expect(resolved.currentLanguage == nil)
        #expect(resolved.hasError == false)
        #expect(resolved.source == .factory)
    }

    /// Protects mirror-only paint (extension cold wake after main-only settle).
    @Test func resolveHomeWidgetChromeFieldsMirrorOnlyPlaying() {
        let mirror = HomeWidgetLiveChrome(
            visualState: .playing,
            currentLanguage: "fi",
            hasError: false,
            updatedAt: 100,
            stampReason: "setPlaying"
        )
        let resolved = resolveHomeWidgetChromeFields(
            sessionVisual: nil,
            sessionLanguage: nil,
            sessionHasError: nil,
            sessionUpdatedAt: nil,
            liveChrome: mirror
        )
        #expect(resolved.visualState == .playing)
        #expect(resolved.currentLanguage == "fi")
        #expect(resolved.source == .liveChrome)
    }

    /// Protects fresher main-app mirror settle over stale extension-session Connecting hold (P0).
    ///
    /// - SeeAlso: ``resolveHomeWidgetChromeFields(sessionVisual:sessionLanguage:sessionHasError:sessionUpdatedAt:liveChrome:)``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§6.2).
    @Test func resolveHomeWidgetChromeFieldsFresherMirrorPlayingBeatsStaleSessionPrePlay() {
        let mirror = HomeWidgetLiveChrome(
            visualState: .playing,
            currentLanguage: "et",
            hasError: false,
            updatedAt: 200,
            stampReason: "setPlaying"
        )
        let resolved = resolveHomeWidgetChromeFields(
            sessionVisual: .prePlay,
            sessionLanguage: "et",
            sessionHasError: false,
            sessionUpdatedAt: 100,
            liveChrome: mirror
        )
        #expect(resolved.visualState == .playing)
        #expect(resolved.currentLanguage == "et")
        #expect(resolved.hasError == false)
        #expect(resolved.source == .liveChrome)
    }

    /// Protects fresher same-process optimistic pause over a staler residual playing mirror.
    @Test func resolveHomeWidgetChromeFieldsFresherSessionPauseBeatsStaleMirrorPlaying() {
        let mirror = HomeWidgetLiveChrome(
            visualState: .playing,
            currentLanguage: "sv",
            hasError: false,
            updatedAt: 100,
            stampReason: "staleMain"
        )
        let resolved = resolveHomeWidgetChromeFields(
            sessionVisual: .userPaused,
            sessionLanguage: "sv",
            sessionHasError: false,
            sessionUpdatedAt: 200,
            liveChrome: mirror
        )
        #expect(resolved.visualState == .userPaused)
        #expect(resolved.currentLanguage == "sv")
        #expect(resolved.source == .session)
    }

    /// Protects equal chrome fields preferring session (optimistic continuity).
    @Test func resolveHomeWidgetChromeFieldsAgreementPrefersSession() {
        let mirror = HomeWidgetLiveChrome(
            visualState: .userPaused,
            currentLanguage: "de",
            hasError: false,
            updatedAt: 999,
            stampReason: "mirror"
        )
        let resolved = resolveHomeWidgetChromeFields(
            sessionVisual: .userPaused,
            sessionLanguage: "de",
            sessionHasError: false,
            sessionUpdatedAt: 1,
            liveChrome: mirror
        )
        #expect(resolved.visualState == .userPaused)
        #expect(resolved.source == .session)
    }

    /// Protects timestamp tie on non-settle disagreement preferring session.
    ///
    /// Connecting vs playing on equal stamps stays session-first (same-tick optimistic continuity).
    /// Definitive pause/play settle pairs use a separate preference (see soft-resume / pause settle tests).
    @Test func resolveHomeWidgetChromeFieldsDisagreementTiePrefersSession() {
        let mirror = HomeWidgetLiveChrome(
            visualState: .playing,
            currentLanguage: "en",
            hasError: false,
            updatedAt: 50,
            stampReason: "mirror"
        )
        let resolved = resolveHomeWidgetChromeFields(
            sessionVisual: .prePlay,
            sessionLanguage: "en",
            sessionHasError: false,
            sessionUpdatedAt: 50,
            liveChrome: mirror
        )
        #expect(resolved.visualState == .prePlay)
        #expect(resolved.source == .session)
    }

    /// Soft-resume settle: equal-timestamp sticky session pause loses to App Group playing.
    ///
    /// **Invariant protected:** Default disagreement ties prefer session; sticky ``.userPaused``
    /// vs mirror ``.playing`` on equal stamps must prefer the mirror so residual Tauko cannot
    /// stick after ``setPlaying`` when wall-clock ties.
    @Test func resolveHomeWidgetChromeFieldsSoftResumeSettleTiePrefersMirrorPlaying() {
        let mirror = HomeWidgetLiveChrome(
            visualState: .playing,
            currentLanguage: "fi",
            hasError: false,
            updatedAt: 100,
            stampReason: "setPlaying"
        )
        let resolved = resolveHomeWidgetChromeFields(
            sessionVisual: .userPaused,
            sessionLanguage: "fi",
            sessionHasError: false,
            sessionUpdatedAt: 100,
            liveChrome: mirror
        )
        #expect(resolved.visualState == .playing)
        #expect(resolved.source == .liveChrome)
    }

    /// Home pause settle: equal-timestamp residual session playing loses to App Group pause.
    @Test func resolveHomeWidgetChromeFieldsPauseSettleTiePrefersMirrorUserPaused() {
        let mirror = HomeWidgetLiveChrome(
            visualState: .userPaused,
            currentLanguage: "fi",
            hasError: false,
            updatedAt: 200,
            stampReason: "optimisticToggle"
        )
        let resolved = resolveHomeWidgetChromeFields(
            sessionVisual: .playing,
            sessionLanguage: "fi",
            sessionHasError: false,
            sessionUpdatedAt: 200,
            liveChrome: mirror
        )
        #expect(resolved.visualState == .userPaused)
        #expect(resolved.source == .liveChrome)
    }

    /// Untimestamped session loses to a stamped mirror when fields disagree (heal residual).
    @Test func resolveHomeWidgetChromeFieldsUntimestampedSessionLosesToMirrorOnDisagree() {
        let mirror = HomeWidgetLiveChrome(
            visualState: .playing,
            currentLanguage: "nb",
            hasError: false,
            updatedAt: 1,
            stampReason: "setPlaying"
        )
        let resolved = resolveHomeWidgetChromeFields(
            sessionVisual: .prePlay,
            sessionLanguage: "nb",
            sessionHasError: false,
            sessionUpdatedAt: nil,
            liveChrome: mirror
        )
        #expect(resolved.visualState == .playing)
        #expect(resolved.source == .liveChrome)
    }

    /// Residual App Group chrome must not paint after terminate/reboot distrust (blob may remain).
    ///
    /// **Invariant protected:** ``resolveHomeWidgetChromeFields`` with ``distrustLiveChrome`` treats
    /// residual mirror as absent so Providers land factory (or process-local session only).
    ///
    /// - SeeAlso: ``resolveHomeWidgetChromeFields(sessionVisual:sessionLanguage:sessionHasError:sessionUpdatedAt:liveChrome:distrustLiveChrome:)``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§6.3).
    @Test func resolveHomeWidgetChromeFieldsDistrustIgnoresResidualMirrorPlaying() {
        let residual = HomeWidgetLiveChrome(
            visualState: .playing,
            currentLanguage: "fi",
            hasError: false,
            updatedAt: 9_999,
            stampReason: "preRebootResidual"
        )
        let resolved = resolveHomeWidgetChromeFields(
            sessionVisual: nil,
            sessionLanguage: nil,
            sessionHasError: nil,
            sessionUpdatedAt: nil,
            liveChrome: residual,
            distrustLiveChrome: true
        )
        #expect(resolved.visualState == .prePlay)
        #expect(resolved.currentLanguage == nil)
        #expect(resolved.hasError == false)
        #expect(resolved.source == .factory)
    }

    /// Distrust does not drop process-local session (same-process optimistic continuity).
    @Test func resolveHomeWidgetChromeFieldsDistrustKeepsSessionWhenPresent() {
        let residual = HomeWidgetLiveChrome(
            visualState: .playing,
            currentLanguage: "sv",
            hasError: false,
            updatedAt: 9_999,
            stampReason: "staleMirror"
        )
        let resolved = resolveHomeWidgetChromeFields(
            sessionVisual: .userPaused,
            sessionLanguage: "de",
            sessionHasError: false,
            sessionUpdatedAt: 100,
            liveChrome: residual,
            distrustLiveChrome: true
        )
        #expect(resolved.visualState == .userPaused)
        #expect(resolved.currentLanguage == "de")
        #expect(resolved.source == .session)
    }

    // MARK: - Intent coordinators

    @Test func planHomeWidgetTogglePlayingIsPause() {
        let plan = WidgetIntentCoordinators.planHomeWidgetToggle(from: .playing)
        #expect(plan.action == .pause)
        #expect(plan.targetVisualState == .userPaused)
    }

    @Test func planHomeWidgetTogglePausedIsPlay() {
        let plan = WidgetIntentCoordinators.planHomeWidgetToggle(from: .userPaused)
        #expect(plan.action == .play)
        // Soft-resume honesty: hold sticky pause chrome until engine setPlaying (not invent .playing).
        #expect(plan.targetVisualState == .userPaused)
        #expect(plan.targetVisualState == PlayerVisualState.userPaused.optimisticHomeWidgetVisualAfterPlayPlan)
    }

    @Test func planControlWidgetToggleBoolMatrix() {
        let play = WidgetIntentCoordinators.planControlWidgetToggle(isPlayingRequested: true)
        #expect(play.action == .play)
        #expect(play.targetVisualState == .playing)

        let pause = WidgetIntentCoordinators.planControlWidgetToggle(isPlayingRequested: false)
        #expect(pause.action == .pause)
        #expect(pause.targetVisualState == .userPaused)
    }

    @Test func planLiveActivityToggleMatrix() {
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(from: .playing) == .pause)
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(from: .userPaused) == .play)
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(from: .prePlay) == .play)
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(from: .cleared) == .play)
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(from: .securityLocked) == .play)
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(from: .thermalPaused) == .refuse)
    }

    @Test func planHomeWidgetToggleThermalRefusesAndSecurityConnects() {
        let thermal = WidgetIntentCoordinators.planHomeWidgetToggle(from: .thermalPaused)
        #expect(thermal.action == .none)
        #expect(thermal.targetVisualState == .thermalPaused)
        #expect(!thermal.shouldExecutePendingAction)

        let security = WidgetIntentCoordinators.planHomeWidgetToggle(from: .securityLocked)
        #expect(security.action == .play)
        #expect(security.targetVisualState == .prePlay)
        #expect(security.shouldExecutePendingAction)
    }

    /// Residual live chrome `.playing` with empty session must plan pause (Provider-aligned).
    @Test func planHomeWidgetToggleResolutionLiveChromePlayingIsPause() {
        let resolution = HomeWidgetResolvedChrome(
            visualState: .playing,
            currentLanguage: "fi",
            hasError: false,
            source: .liveChrome
        )
        let plan = WidgetIntentCoordinators.planHomeWidgetToggle(
            resolution: resolution,
            distrustDurableMirrorPlay: false,
            mainProcessRecentlyActive: true
        )
        #expect(plan.action == .pause)
        #expect(plan.targetVisualState == .userPaused)
    }

    /// After reboot distrust, residual live chrome / factory alone must not invent play.
    @Test func planHomeWidgetToggleRefusesPlayFromResidualChromeWhenDistrusted() {
        let residualPaused = HomeWidgetResolvedChrome(
            visualState: .userPaused,
            currentLanguage: "en",
            hasError: false,
            source: .liveChrome
        )
        let refused = WidgetIntentCoordinators.planHomeWidgetToggle(
            resolution: residualPaused,
            distrustDurableMirrorPlay: true,
            mainProcessRecentlyActive: false
        )
        #expect(refused.action == .none)
        #expect(refused.targetVisualState == .userPaused)
        #expect(!refused.shouldExecutePendingAction)

        let factory = HomeWidgetResolvedChrome(
            visualState: .prePlay,
            currentLanguage: nil,
            hasError: false,
            source: .factory
        )
        let factoryRefused = WidgetIntentCoordinators.planHomeWidgetToggle(
            resolution: factory,
            distrustDurableMirrorPlay: true,
            mainProcessRecentlyActive: false
        )
        #expect(factoryRefused.action == .none)
        #expect(factoryRefused.targetVisualState == .prePlay)
    }

    /// Main not recently active refuses residual/factory play even without reboot distrust.
    @Test func planHomeWidgetToggleRefusesPlayWhenMainNotRecentlyActive() {
        let residual = HomeWidgetResolvedChrome(
            visualState: .userPaused,
            currentLanguage: "sv",
            hasError: false,
            source: .liveChrome
        )
        let plan = WidgetIntentCoordinators.planHomeWidgetToggle(
            resolution: residual,
            distrustDurableMirrorPlay: false,
            mainProcessRecentlyActive: false
        )
        #expect(plan.action == .none)
        #expect(!plan.shouldExecutePendingAction)
    }

    /// Process-local session remains trusted while main is live (optimistic continuity).
    @Test func planHomeWidgetToggleSessionSourcePlayWhileMainActive() {
        let session = HomeWidgetResolvedChrome(
            visualState: .userPaused,
            currentLanguage: "de",
            hasError: false,
            source: .session
        )
        let plan = WidgetIntentCoordinators.planHomeWidgetToggle(
            resolution: session,
            distrustDurableMirrorPlay: false,
            mainProcessRecentlyActive: true
        )
        #expect(plan.action == .play)
        #expect(plan.targetVisualState == .userPaused)
    }

    /// Residual `.playing` still plans pause under distrust (glyph honesty; not play resurrection).
    ///
    /// Defense-in-depth when resolution source remains ``.liveChrome``. Production reboot path
    /// drops the mirror in ``resolveHomeWidgetChromeFields`` first (see chained test below).
    @Test func planHomeWidgetToggleResidualPlayingStillPausesUnderDistrust() {
        let resolution = HomeWidgetResolvedChrome(
            visualState: .playing,
            currentLanguage: "nb",
            hasError: false,
            source: .liveChrome
        )
        let plan = WidgetIntentCoordinators.planHomeWidgetToggle(
            resolution: resolution,
            distrustDurableMirrorPlay: true,
            mainProcessRecentlyActive: false
        )
        #expect(plan.action == .pause)
        #expect(plan.targetVisualState == .userPaused)
    }

    /// Production composition: reboot distrust resolve → factory → plan refuses play.
    ///
    /// **Invariant protected:** Same signal that sets ``distrustLiveChrome`` also sets
    /// ``distrustDurableMirrorPlay``. Residual ``.playing`` on disk does not reach the planner
    /// as ``.liveChrome`` after distrust — factory ``.prePlay`` refuses pending play.
    ///
    /// - SeeAlso: ``resolveHomeWidgetChromeFields(sessionVisual:sessionLanguage:sessionHasError:sessionUpdatedAt:liveChrome:distrustLiveChrome:)``,
    ///   ``WidgetIntentCoordinators/planHomeWidgetToggle(resolution:distrustDurableMirrorPlay:mainProcessRecentlyActive:)``.
    @Test func resolveThenPlanHomeWidgetToggleRefusesPlayUnderRebootDistrustChain() {
        let residual = HomeWidgetLiveChrome(
            visualState: .playing,
            currentLanguage: "fi",
            hasError: false,
            updatedAt: 9_999,
            stampReason: "preRebootResidual"
        )
        let resolved = resolveHomeWidgetChromeFields(
            sessionVisual: nil,
            sessionLanguage: nil,
            sessionHasError: nil,
            sessionUpdatedAt: nil,
            liveChrome: residual,
            distrustLiveChrome: true
        )
        #expect(resolved.source == .factory)
        #expect(resolved.visualState == .prePlay)

        let plan = WidgetIntentCoordinators.planHomeWidgetToggle(
            resolution: resolved,
            distrustDurableMirrorPlay: true,
            mainProcessRecentlyActive: false
        )
        #expect(plan.action == .none)
        #expect(!plan.shouldExecutePendingAction)
        #expect(plan.targetVisualState == .prePlay)
    }

    /// Trusted boot, main not recently active: residual chrome still resolves; play refused, pause kept.
    @Test func resolveThenPlanHomeWidgetToggleMainNotRecentlyActiveTrustedBootMatrix() {
        let residualPaused = HomeWidgetLiveChrome(
            visualState: .userPaused,
            currentLanguage: "sv",
            hasError: false,
            updatedAt: 500,
            stampReason: "stalePaused"
        )
        let pausedResolve = resolveHomeWidgetChromeFields(
            sessionVisual: nil,
            sessionLanguage: nil,
            sessionHasError: nil,
            sessionUpdatedAt: nil,
            liveChrome: residualPaused,
            distrustLiveChrome: false
        )
        #expect(pausedResolve.source == .liveChrome)
        let refusePlay = WidgetIntentCoordinators.planHomeWidgetToggle(
            resolution: pausedResolve,
            distrustDurableMirrorPlay: false,
            mainProcessRecentlyActive: false
        )
        #expect(refusePlay.action == .none)

        let residualPlaying = HomeWidgetLiveChrome(
            visualState: .playing,
            currentLanguage: "de",
            hasError: false,
            updatedAt: 500,
            stampReason: "stalePlaying"
        )
        let playingResolve = resolveHomeWidgetChromeFields(
            sessionVisual: nil,
            sessionLanguage: nil,
            sessionHasError: nil,
            sessionUpdatedAt: nil,
            liveChrome: residualPlaying,
            distrustLiveChrome: false
        )
        #expect(playingResolve.source == .liveChrome)
        let planPause = WidgetIntentCoordinators.planHomeWidgetToggle(
            resolution: playingResolve,
            distrustDurableMirrorPlay: false,
            mainProcessRecentlyActive: false
        )
        #expect(planPause.action == .pause)
        #expect(planPause.targetVisualState == .userPaused)
    }

    @Test func planLiveActivityToggleConnectingCancelsAsPause() {
        let resolution = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: .prePlay,
            durableMirror: .prePlay,
            actorVisualState: .prePlay,
            sessionSnapshot: nil
        )
        #expect(
            WidgetIntentCoordinators.planLiveActivityToggle(
                resolution: resolution,
                isConnectingPlayback: true
            ) == .pause,
            "Active start pipeline must plan pause to cancel connect, not duplicate play"
        )
        #expect(
            WidgetIntentCoordinators.planLiveActivityToggle(
                resolution: resolution,
                isConnectingPlayback: false
            ) == .play,
            "Idle Connecting chrome without pipeline still plans first play"
        )
    }

    @Test func playerVisualStateMediaToggleSemanticsHelpers() {
        #expect(PlayerVisualState.playing.plansMediaToggleAsPause)
        #expect(!PlayerVisualState.prePlay.plansMediaToggleAsPause)
        #expect(PlayerVisualState.thermalPaused.blocksPlannedPlay)
        #expect(!PlayerVisualState.securityLocked.blocksPlannedPlay)
        #expect(PlayerVisualState.securityLocked.optimisticVisualAfterPlayPlan == .prePlay)
        #expect(PlayerVisualState.userPaused.optimisticVisualAfterPlayPlan == .playing)
        #expect(PlayerVisualState.userPaused.optimisticHomeWidgetVisualAfterPlayPlan == .userPaused)
        #expect(PlayerVisualState.prePlay.optimisticHomeWidgetVisualAfterPlayPlan == .prePlay)
        #expect(PlayerVisualState.securityLocked.optimisticHomeWidgetVisualAfterPlayPlan == .prePlay)
    }

    @Test func resolveLiveActivityTogglePrefersContentThenMirror() {
        let fromContent = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: .playing,
            durableMirror: .userPaused,
            actorVisualState: .prePlay,
            sessionSnapshot: nil
        )
        #expect(fromContent.source == .liveActivityContent)
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(resolution: fromContent) == .pause)

        let fromMirror = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: nil,
            durableMirror: .playing,
            actorVisualState: .prePlay,
            sessionSnapshot: nil
        )
        #expect(fromMirror.source == .durableCrossProcessMirror)
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(resolution: fromMirror) == .pause)
    }

    /// Stale system-held Connecting must not invert pause when durable mirror already paused.
    ///
    /// After lock-stretch visual freeze, ContentState can remain `.prePlay` while the durable
    /// LA toggle mirror (and actor) already hold `.userPaused`. Planning from content alone
    /// would treat Connecting as "play-eligible" and invert a second pause/resume cycle.
    @Test func resolveLiveActivityToggleStaleConnectingDefersToUserPausedMirror() {
        let resolution = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: .prePlay,
            durableMirror: .userPaused,
            actorVisualState: .userPaused,
            sessionSnapshot: nil
        )
        #expect(resolution.source == .durableCrossProcessMirror)
        #expect(resolution.visualState == .userPaused)
        #expect(
            WidgetIntentCoordinators.planLiveActivityToggle(resolution: resolution) == .play,
            "Paused peer after stale Connecting must plan play (resume), not re-plan play from Connecting alone"
        )
    }

    /// Stale Connecting with still-playing audio prefers durable/actor playing → pause plan.
    @Test func resolveLiveActivityToggleStaleConnectingDefersToPlayingPeer() {
        let fromMirror = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: .prePlay,
            durableMirror: .playing,
            actorVisualState: .prePlay,
            sessionSnapshot: nil
        )
        #expect(fromMirror.source == .durableCrossProcessMirror)
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(resolution: fromMirror) == .pause)

        let fromActor = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: .prePlay,
            durableMirror: nil,
            actorVisualState: .playing,
            sessionSnapshot: nil
        )
        #expect(fromActor.source == .actorVisualState)
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(resolution: fromActor) == .pause)
    }

    /// Intentional Connecting with no control-definite peer remains content-authoritative.
    @Test func resolveLiveActivityToggleConnectingWithoutDefinitivePeerKeepsContent() {
        let resolution = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: .prePlay,
            durableMirror: .prePlay,
            actorVisualState: .prePlay,
            sessionSnapshot: nil
        )
        #expect(resolution.source == .liveActivityContent)
        #expect(resolution.visualState == .prePlay)
        #expect(WidgetIntentCoordinators.planLiveActivityToggle(resolution: resolution) == .play)
    }

    /// Optimistic visual replace preserves language and program metadata (pause honesty).
    @Test func contentStateReplacingVisualStateFromPrePlayPreservesLanguage() {
        let metadata = StreamProgramMetadata(programTitle: "Vesper", speaker: "Cantor")
        let connecting = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .prePlay,
            streamMetadata: metadata,
            currentLanguage: "de"
        )
        let paused = connecting.replacingVisualState(.userPaused)
        #expect(paused.visualState == .userPaused)
        #expect(paused.currentLanguage == "de")
        #expect(paused.streamMetadata == metadata)
        #expect(PlayerVisualState.userPaused.isDefinitiveMediaToggleVisual)
        #expect(!PlayerVisualState.prePlay.isDefinitiveMediaToggleVisual)
    }

    @Test func planLiveActivityToggleDistrustBlocksPlayFromDurableMirrorAlone() {
        let pausedMirror = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: nil,
            durableMirror: .userPaused,
            actorVisualState: .prePlay,
            sessionSnapshot: nil
        )
        #expect(
            WidgetIntentCoordinators.planLiveActivityToggle(
                resolution: pausedMirror,
                distrustDurableMirrorPlay: true
            ) == .pause
        )
        #expect(
            WidgetIntentCoordinators.planLiveActivityToggle(
                resolution: pausedMirror,
                distrustDurableMirrorPlay: false
            ) == .play
        )

        let contentPaused = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: .userPaused,
            durableMirror: .userPaused,
            actorVisualState: .prePlay,
            sessionSnapshot: nil
        )
        #expect(
            WidgetIntentCoordinators.planLiveActivityToggle(
                resolution: contentPaused,
                distrustDurableMirrorPlay: true
            ) == .play
        )
    }

    /// Optimistic ContentState visual flip preserves program metadata and language.
    @Test func contentStateReplacingVisualStatePreservesStreamMetadata() {
        let metadata = StreamProgramMetadata(programTitle: "Sunday Sermon", speaker: "Pastor")
        let playing = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .playing,
            streamMetadata: metadata,
            currentLanguage: "fi"
        )
        let paused = playing.replacingVisualState(.userPaused)
        #expect(paused.visualState == .userPaused)
        #expect(paused.streamMetadata == metadata)
        #expect(paused.currentLanguage == "fi")

        let resumed = paused.replacingVisualState(.playing)
        #expect(resumed.visualState == .playing)
        #expect(resumed.streamMetadata == metadata)
        #expect(resumed.currentLanguage == "fi")
    }

    /// Language-only ContentState replace preserves control visual and program metadata.
    ///
    /// Post-quiet language long-horizon after freeze must not force `.playing` into the
    /// sparse slot; dest language rides the owned glyph.
    @Test func contentStateReplacingCurrentLanguagePreservesVisualAndMetadata() {
        let metadata = StreamProgramMetadata(programTitle: "Psaltaren 34", speaker: "Lutheran Radio på svenska")
        let connecting = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .prePlay,
            streamMetadata: metadata,
            currentLanguage: "sv"
        )
        let dest = connecting.replacingCurrentLanguage("en")
        #expect(dest.visualState == .prePlay)
        #expect(dest.streamMetadata == metadata)
        #expect(dest.currentLanguage == "en")
        #expect(dest != connecting)
    }

    /// Optimistic stream-switch ContentState advances language and clears prior program metadata.
    ///
    /// Lock-screen language chips must update flag chrome without waiting for main-app attach,
    /// and must not leave the prior stream's ICY title under the new flag.
    @Test func contentStateReplacingStreamSwitchDestinationAdvancesLanguageAndClearsMetadata() {
        let metadata = StreamProgramMetadata(programTitle: "Psaltaren 34", speaker: "Lutheran Radio på svenska")
        let playing = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .playing,
            streamMetadata: metadata,
            currentLanguage: "sv"
        )
        let connecting = playing.replacingStreamSwitchDestination(
            language: "et",
            visualState: .prePlay,
            clearStreamMetadata: true
        )
        #expect(connecting.visualState == .prePlay)
        #expect(connecting.currentLanguage == "et")
        #expect(connecting.streamMetadata == nil)
        #expect(connecting != playing)

        let paused = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .userPaused,
            streamMetadata: metadata,
            currentLanguage: "de"
        )
        let pausedSwitch = paused.replacingStreamSwitchDestination(
            language: "fi",
            visualState: .userPaused,
            clearStreamMetadata: true
        )
        #expect(pausedSwitch.visualState == .userPaused)
        #expect(pausedSwitch.currentLanguage == "fi")
        #expect(pausedSwitch.streamMetadata == nil)
    }

    /// Shared stream-switch optimistic visual (home + LA): playing → Connecting; sticky pause preserved.
    ///
    /// Protects first-paint honesty for destination language during silent attach hold.
    @Test func optimisticStreamSwitchVisualPlayingMapsToConnectingPausePreserved() {
        #expect(
            WidgetIntentCoordinators.optimisticLiveActivityVisualForStreamSwitch(from: .playing)
                == .prePlay
        )
        #expect(
            WidgetIntentCoordinators.optimisticLiveActivityVisualForStreamSwitch(from: .userPaused)
                == .userPaused
        )
        #expect(
            WidgetIntentCoordinators.optimisticLiveActivityVisualForStreamSwitch(from: .prePlay)
                == .prePlay
        )
        #expect(
            WidgetIntentCoordinators.optimisticLiveActivityVisualForStreamSwitch(from: .thermalPaused)
                == .thermalPaused
        )
        #expect(
            WidgetIntentCoordinators.optimisticLiveActivityVisualForStreamSwitch(from: .cleared)
                == .cleared
        )
        #expect(
            WidgetIntentCoordinators.optimisticLiveActivityVisualForStreamSwitch(from: .securityLocked)
                == .securityLocked
        )
    }

    /// Older ActivityKit payloads without `currentLanguage` decode to `"en"` (stable default).
    @Test func contentStateDecodeDefaultsMissingLanguageToEnglish() throws {
        let metadata = StreamProgramMetadata(programTitle: "Vesper", speaker: "Cantor")
        // Encode only visual + metadata (pre-language-chrome shape).
        struct LegacyPayload: Encodable {
            let visualState: PlayerVisualState
            let streamMetadata: StreamProgramMetadata?
        }
        let data = try JSONEncoder().encode(
            LegacyPayload(visualState: .playing, streamMetadata: metadata)
        )
        let decoded = try JSONDecoder().decode(
            LutheranRadioLiveActivityAttributes.ContentState.self,
            from: data
        )
        #expect(decoded.visualState == .playing)
        #expect(decoded.streamMetadata == metadata)
        #expect(decoded.currentLanguage == "en")
    }

    /// Language-only ContentState inequality forces ActivityKit update eligibility.
    @Test func contentStateLanguageChangeBreaksEquality() {
        let metadata = StreamProgramMetadata(programTitle: "Matins", speaker: nil)
        let finnish = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .playing,
            streamMetadata: metadata,
            currentLanguage: "fi"
        )
        let estonian = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .playing,
            streamMetadata: metadata,
            currentLanguage: "et"
        )
        #expect(finnish != estonian)
        #expect(finnish.visualState == estonian.visualState)
        #expect(finnish.streamMetadata == estonian.streamMetadata)
    }

    /// Rapid second tap must plan from optimistic ContentState, not stale pre-tap content.
    ///
    /// Protects the lock-screen double-tap contract: after an optimistic pause content
    /// publish, resolve prefers ActivityKit content over a lagging durable mirror or actor.
    @Test func rapidSecondTapPlansFromOptimisticLiveActivityContent() {
        let afterOptimisticPause = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: .userPaused,
            durableMirror: .playing,
            actorVisualState: .playing,
            sessionSnapshot: nil
        )
        #expect(afterOptimisticPause.source == .liveActivityContent)
        #expect(afterOptimisticPause.visualState == .userPaused)
        #expect(
            WidgetIntentCoordinators.planLiveActivityToggle(resolution: afterOptimisticPause) == .play,
            "Second tap after optimistic pause content must plan play, not a second pause"
        )

        let afterOptimisticPlay = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: .playing,
            durableMirror: .userPaused,
            actorVisualState: .userPaused,
            sessionSnapshot: nil
        )
        #expect(
            WidgetIntentCoordinators.planLiveActivityToggle(resolution: afterOptimisticPlay) == .pause,
            "Second tap after optimistic play content must plan pause"
        )
    }

    // MARK: - Liveness presentation

    /// Passive `tap_to_open` is the inverse of recent activity; window stays at 60 s.
    @Test func livenessPassiveBranchAndWindow() {
        #expect(WidgetLivenessPresentation.shouldShowPassiveTapToOpen(isMainAppRecentlyActive: false))
        #expect(!WidgetLivenessPresentation.shouldShowPassiveTapToOpen(isMainAppRecentlyActive: true))
        #expect(WidgetLivenessPresentation.mainAppRecentActivityWindowSeconds == 60)
    }

    // MARK: - Timeline factory

    @Test func homeBlueprintCarriesPresentationSlices() {
        let fields = WidgetProviderSnapshotFields(
            currentLanguage: "fi",
            hasError: false,
            visualState: .playing,
            streamMetadata: nil
        )
        let status = PlayerVisualState.playing.makeStatusPresentation()
        let control = PlayerVisualState.playing.makeControlPresentation()
        let model = widgetNowPlayingDisplayModel(
            visualState: .playing,
            streamMetadata: nil,
            languageName: "Finnish"
        )
        let slices = WidgetProviderPresentationSlices(
            currentLanguageCode: "fi",
            currentStation: "🇫🇮 Finnish",
            statusPresentation: status,
            controlPresentation: control,
            widgetNowPlayingDisplayModel: model
        )
        let date = Date(timeIntervalSince1970: 0)
        let blueprint = WidgetTimelineEntryFactory.makeHomeWidgetBlueprint(
            date: date,
            fields: fields,
            slices: slices
        )
        #expect(blueprint.visualState == .playing)
        #expect(blueprint.currentLanguageCode == "fi")
        #expect(blueprint.statusPresentation == status)
        #expect(blueprint.controlPresentation == control)
        #expect(blueprint.date == date)
    }

    // MARK: - Presentation mappers (full matrix — pure WidgetSurface host)

    /// Full status presentation matrix for every visual state (authoritative pure host).
    /// Extension targets keep thin linkage smoke only.
    @Test func statusPresentationMatrixMapsEveryVisualState() {
        let states: [PlayerVisualState] = [
            .prePlay, .cleared, .playing, .userPaused, .thermalPaused, .securityLocked
        ]
        let expectedGlyphs: [PlayerVisualState: String?] = [
            .playing: "play.fill",
            .prePlay: "play.circle",
            .cleared: nil,
            .userPaused: "pause.fill",
            .thermalPaused: "pause.fill",
            .securityLocked: "lock.fill",
        ]
        for state in states {
            let presentation = state.makeStatusPresentation()
            #expect(!presentation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(presentation.systemImage == expectedGlyphs[state] ?? nil)
            #expect(presentation.background == PlayerVisualChromePalette.backgroundColor(for: state))
            #expect(presentation.foreground == PlayerVisualChromePalette.textColor(for: state))
        }
        // Distinct status chrome across states (no collapsed cases).
        let pairs = states.map { ($0, $0.makeStatusPresentation()) }
        for i in pairs.indices {
            for j in pairs.indices where j > i {
                #expect(pairs[i].1 != pairs[j].1)
            }
        }
    }

    /// Full control presentation matrix: pause glyph only when actively playing.
    @Test func controlPresentationMatrixMapsEveryVisualState() {
        let states: [PlayerVisualState] = [
            .prePlay, .cleared, .playing, .userPaused, .thermalPaused, .securityLocked
        ]
        for state in states {
            let presentation = state.makeControlPresentation()
            let expectedGlyph = state.isActivelyPlaying ? "pause.fill" : "play.fill"
            #expect(presentation.systemImage == expectedGlyph)
            #expect(presentation.tint == PlayerVisualChromePalette.buttonTintColor(for: state))
        }
    }

    @Test func statusPresentationPlayingUsesPlayGlyph() {
        let presentation = PlayerVisualState.playing.makeStatusPresentation()
        #expect(presentation.systemImage == "play.fill")
        #expect(!presentation.text.isEmpty)
    }

    @Test func controlPresentationPlayingUsesPauseGlyph() {
        let presentation = PlayerVisualState.playing.makeControlPresentation()
        #expect(presentation.systemImage == "pause.fill")
    }

    /// Status and control colors both derive from ``PlayerVisualChromePalette``.
    @Test func chromePaletteFeedsStatusAndControlPresentation() {
        let states: [PlayerVisualState] = [
            .prePlay, .cleared, .playing, .userPaused, .thermalPaused, .securityLocked
        ]
        for state in states {
            let status = state.makeStatusPresentation()
            #expect(status.background == PlayerVisualChromePalette.backgroundColor(for: state))
            #expect(status.foreground == PlayerVisualChromePalette.textColor(for: state))
            #expect(state.backgroundColor == PlayerVisualChromePalette.backgroundUIColor(for: state))
            #expect(state.textColor == PlayerVisualChromePalette.textUIColor(for: state))
            #expect(state.buttonTintColor == PlayerVisualChromePalette.buttonTintUIColor(for: state))
            #expect(
                state.makeControlPresentation().tint
                    == PlayerVisualChromePalette.buttonTintColor(for: state)
            )
        }
    }

    /// Typed toggle actions wire to App Group verbs at the mailbox boundary only.
    @Test func widgetToggleActionWireValuesMatchAppGroupVerbs() {
        #expect(WidgetToggleAction.play.wireValue == "play")
        #expect(WidgetToggleAction.pause.wireValue == "pause")
        #expect(WidgetToggleAction.none.wireValue == "none")
        #expect(WidgetToggleAction(wireValue: "play") == .play)
        #expect(WidgetToggleAction(wireValue: "switch") == nil)
    }

    // MARK: - Language display (pure)

    @Test func displayFlagMatrixForCuratedLanguageCodes() {
        #expect(displayFlag(for: "en") == "🇺🇸")
        #expect(displayFlag(for: "de") == "🇩🇪")
        #expect(displayFlag(for: "fi") == "🇫🇮")
        #expect(displayFlag(for: "sv") == "🇸🇪")
        #expect(displayFlag(for: "et") == "🇪🇪")
    }

    @Test func displayFlagUnknownCodeUsesGlobeFallback() {
        #expect(displayFlag(for: "xx") == "🌍")
        #expect(displayFlag(for: "") == "🌍")
        #expect(displayFlag(for: "nb") == "🌍")
    }

    @Test func displayLanguageNamePrefersStreamCatalogWhenProvided() {
        #expect(
            displayLanguageName(for: "fi", preferredStreamLanguage: "Suomi") == "Suomi"
        )
        #expect(
            displayLanguageName(for: "xx", preferredStreamLanguage: "Catalog Name") == "Catalog Name"
        )
    }

    @Test func displayLanguageNameUnknownCodeCapitalizesWithoutCatalog() {
        #expect(displayLanguageName(for: "xx") == "Xx")
        #expect(displayLanguageName(for: "zz") == "Zz")
    }

    // MARK: - Provider presentation assembly (pure)

    @Test func assemblePresentationSlicesMapsEveryVisualState() {
        let states: [PlayerVisualState] = [
            .prePlay, .cleared, .playing, .userPaused, .thermalPaused, .securityLocked
        ]
        for state in states {
            let fields = WidgetProviderSnapshotFields(
                currentLanguage: "en",
                hasError: false,
                visualState: state,
                streamMetadata: nil
            )
            let slices = WidgetProviderPresentationAssembly.assemblePresentationSlices(
                from: fields,
                languageName: "English",
                stationLabel: "🇺🇸 English"
            )
            #expect(slices.currentLanguageCode == "en")
            #expect(slices.currentStation == "🇺🇸 English")
            #expect(slices.statusPresentation == state.makeStatusPresentation())
            #expect(slices.controlPresentation == state.makeControlPresentation())
            #expect(
                slices.widgetNowPlayingDisplayModel == widgetNowPlayingDisplayModel(
                    visualState: state,
                    streamMetadata: nil,
                    languageName: "English"
                )
            )
        }
    }

    @Test func assemblePresentationSlicesUsesConnectionErrorWhenHasError() {
        let fields = WidgetProviderSnapshotFields(
            currentLanguage: "fi",
            hasError: true,
            visualState: .playing,
            streamMetadata: nil
        )
        let slices = WidgetProviderPresentationAssembly.assemblePresentationSlices(
            from: fields,
            languageName: "Suomi",
            stationLabel: "🇫🇮 Suomi"
        )
        let expectedError = String(
            localized: "Connection error",
            defaultValue: "Connection error",
            table: "Localizable"
        )
        let base = PlayerVisualState.playing.makeStatusPresentation()
        #expect(slices.statusPresentation.text == expectedError)
        #expect(slices.statusPresentation.background == base.background)
        #expect(slices.statusPresentation.foreground == base.foreground)
        #expect(slices.statusPresentation.systemImage == base.systemImage)
        #expect(slices.controlPresentation == PlayerVisualState.playing.makeControlPresentation())
    }

    @Test func assemblePresentationSlicesCarriesStreamMetadataIntoNowPlayingModel() {
        let meta = StreamProgramMetadata(programTitle: "Sunday Sermon", speaker: "Guest")
        let fields = WidgetProviderSnapshotFields(
            currentLanguage: "fi",
            hasError: false,
            visualState: .playing,
            streamMetadata: meta
        )
        let slices = WidgetProviderPresentationAssembly.assemblePresentationSlices(
            from: fields,
            languageName: "Suomi",
            stationLabel: "🇫🇮 Suomi"
        )
        let expected = widgetNowPlayingDisplayModel(
            visualState: .playing,
            streamMetadata: meta,
            languageName: "Suomi"
        )
        #expect(slices.widgetNowPlayingDisplayModel == expected)
        #expect(slices.widgetNowPlayingDisplayModel.programTitle == "Sunday Sermon")
        #expect(slices.widgetNowPlayingDisplayModel.speakerVisible)
    }
}
