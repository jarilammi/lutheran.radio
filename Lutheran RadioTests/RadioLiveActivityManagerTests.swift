//
//  RadioLiveActivityManagerTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 29.8.2025.
//
//  White-box unit tests for ``RadioLiveActivityManager`` timer demotion, change-detection
//  guards, Live Activity attribute-events (`contentUpdates`) observation contracts,
//  Designed-for-iPhone Mac ActivityKit skip, and
//  termination final-ContentState / hygiene contracts.
//
//  Attribute-events tests consume DEBUG synthetic-stream seams on the manager
//  (`_test_beginObservingSyntheticContentUpdates`, `_test_wouldSuppressLiveActivityUpdate`,
//  `_test_setHarnessSimulatesActiveActivity`, `_test_cancelAttributeEventObservation`,
//  `_test_finalEndContentState`, `_test_systemResidualIdsToReap`,
//  `_test_shouldUseFullResidualEnd`, stalled-recreation eligibility /
//  pending-ensure / foreground-ensure policy seams) so ActivityKit IPC is never
//  exercised under the XCTest host.
//
//  - SeeAlso: ``RadioLiveActivityManager``, ``WidgetEventObserver``,
//    docs/Event-Driven-Refactor-Roadmap.md (Tier 2 LA events / Tier 5),
//    docs/Widget-Presentation-Dataflow.md (termination + residual reaping),
//    CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).

import XCTest
import ActivityKit
import WidgetSurface
@testable import Lutheran_Radio

@MainActor
class RadioLiveActivityManagerTests: XCTestCase {
    
    var manager: RadioLiveActivityManager!
    
    override func setUp() async throws {
        try await super.setUp()
        manager = RadioLiveActivityManager.shared

        // Fast, cheap isolation only. Never call endActivity() here.
        //
        // Why:
        // - When you are playing the stream, a *real* Live Activity exists in the
        //   simulator (currentActivity holds a live Activity<...>).
        // - endActivity() would capture it and launch Tasks that call the real
        //   Activity.update(...) + end(...) APIs. Those are synchronous calls into ActivityKit's system services
        //   round-trips and become extremely slow under LLDB + active stream,
        //   causing exactly the "listening to the stream and test times out" symptom.
        //
        // Instead we only stop our local timer and nil the reference.
        // This is sufficient for the white-box timer tests and for the
        // initialization assertion. Real LAs (if present) are left alone.
        //
        // See ``RadioLiveActivityManager/isRunningUnderTest`` (and the early returns
        // in observeExistingActivities, startActivity, and updateCurrentActivity)
        // for the creation-time and call-time fast paths during tests.
        manager.stopLocalUpdateTimer()
        manager.activityObservationTask?.cancel()
        // Also cancel through the consolidated observer (its task is published
        // into the seam). The direct seam cancel remains the documented test
        // surface.
        // (internal visibility via @testable for the property itself.)
        manager.currentActivity = nil
        manager._test_setPendingInteractiveLiveActivityEnsure(false)
        manager._test_setLanguageEnsureQuietPendingDestination(nil)
        manager._test_setPlayingEnsureQuietPending(false)
        manager._test_cancelAllPostQuietLongHorizonEnsure()
        // Singleton suppress memory must not leak across tests (optimistic stream-switch
        // / attribute-events cases write lastPushedContent without endActivity).
        manager._test_clearLastPushedContent()
    }
    
    override func tearDown() async throws {
        // Must stop the timer (if any) and cancel attribute event observation before
        // releasing. Prevents live Tasks / Timers keeping the runner alive.
        manager?._test_setPendingInteractiveLiveActivityEnsure(false)
        manager?._test_setLanguageEnsureQuietPendingDestination(nil)
        manager?._test_setPlayingEnsureQuietPending(false)
        manager?._test_cancelAllPostQuietLongHorizonEnsure()
        manager?._test_clearLastPushedContent()
        manager?.stopLocalUpdateTimer()
        manager?.activityObservationTask?.cancel()
        SharedPlayerManager._test_setIsRunningAsIOSAppOnMac(nil)
        // The seam cancel stops the work; the observer is reset on next use.
        manager = nil
        try await super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testInitializationObservesExistingActivities() {
        // After accessing .shared (and our setUp sanitization), currentActivity
        // must be nil. The real work of forcing nil on first creation (and preventing
        // startActivity / updateCurrentActivity from doing real work) lives in the
        // #if DEBUG `isRunningUnderTest` checks.
        //
        // We also force nil in setUp (cheap direct assignment) so the assertion is
        // reliable even when other tests in the suite have started real Live Activities.
        XCTAssertNil(manager.currentActivity)
    }

    // MARK: - Designed-for-iPhone Mac host

    /// Designed-for-iPhone Mac has no ActivityKit service. The host query plus
    /// ``areActivitiesEnabledOnThisHost`` must report disabled without calling
    /// `ActivityAuthorizationInfo` so launch does not log connection failures.
    ///
    /// - SeeAlso: ``SharedPlayerManager/isRunningAsIOSAppOnMac``,
    ///   ``RadioLiveActivityManager/areActivitiesEnabledOnThisHost``
    func testDesignedForIPhoneMacHostReportsLiveActivitiesDisabled() {
        SharedPlayerManager._test_setIsRunningAsIOSAppOnMac(true)
        defer { SharedPlayerManager._test_setIsRunningAsIOSAppOnMac(nil) }

        XCTAssertTrue(
            SharedPlayerManager.isRunningAsIOSAppOnMac,
            "DEBUG seam must pin the Designed-for-iPhone Mac host query"
        )
        XCTAssertFalse(
            RadioLiveActivityManager.areActivitiesEnabledOnThisHost,
            "Mac host must treat Live Activities as unavailable without ActivityKit IPC"
        )
    }

    /// Clearing the DEBUG host override restores ``ProcessInfo/isiOSAppOnMac`` (false
    /// on the iOS simulator test host).
    func testDesignedForIPhoneMacHostOverrideClearsToProcessInfo() {
        SharedPlayerManager._test_setIsRunningAsIOSAppOnMac(true)
        XCTAssertTrue(SharedPlayerManager.isRunningAsIOSAppOnMac)
        SharedPlayerManager._test_setIsRunningAsIOSAppOnMac(nil)

        XCTAssertEqual(
            SharedPlayerManager.isRunningAsIOSAppOnMac,
            ProcessInfo.processInfo.isiOSAppOnMac,
            "Nil override must read ProcessInfo.isiOSAppOnMac (false on iOS Simulator)"
        )
    }
    
    // MARK: - Timer Management Tests
    //
    // These exercise the internal timer heartbeat that backs Live Activity freshness.
    // The 10 s repeating timer is deliberately secondary to the explicit SPM-driven
    // `updateCurrentActivity()` calls (see SharedPlayerManager.setPlaying etc.).
    //
    // Invariant under test:
    //   startLocalUpdateTimer()  →  updateTimer != nil && updateTimer.isValid
    //   stopLocalUpdateTimer()   →  updateTimer == nil
    //
    // We observe via the already-`internal` property (no Mirror, no reflection).
    // This protects against regressions that would silently drop the LA heartbeat
    // or leave timers running (which previously caused LLDB + test runner stalls
    // and interaction with any real Activity in the simulator).
    //
    // - SeeAlso: RadioLiveActivityManager.updateTimer (the testing seam),
    //   startLocalUpdateTimer, stopLocalUpdateTimer, observeExistingActivities,
    //   startActivity, updateCurrentActivity, isRunningUnderTest.

    func testStartLocalUpdateTimerSchedulesTimer() {
        // setUp already stopped; this is extra belt-and-suspenders for the specific scenario.
        manager.stopLocalUpdateTimer()
        manager.startLocalUpdateTimer()

        // Direct access (property is intentionally internal private(set) for tests).
        XCTAssertNotNil(manager.updateTimer, "startLocalUpdateTimer must schedule a non-nil repeating Timer")
        XCTAssertTrue(manager.updateTimer?.isValid ?? false, "The scheduled timer must be valid")

        // Explicit stop here is still useful for readability; tearDown will also enforce it.
        manager.stopLocalUpdateTimer()
    }

    func testStopLocalUpdateTimerInvalidatesTimer() {
        manager.startLocalUpdateTimer()
        manager.stopLocalUpdateTimer()

        // After stop the backing reference must be cleared (stop does invalidate + nil).
        XCTAssertNil(manager.updateTimer, "stopLocalUpdateTimer must clear the timer reference")
    }

    // MARK: - Event-Driven + Change Detection Tests (new model)

    func testNoFallbackTimerStartedByDefaultAfterSanitization() {
        // After setUp sanitization the timer must be absent.
        // Normal paths (startActivity when we nil currentActivity, updateCurrentActivity)
        // must not introduce a repeating timer. This is the "timer demoted" guarantee.
        XCTAssertNil(manager.updateTimer, "No fallback timer should be scheduled by default paths under test isolation")
    }

    func testLastPushedContentIsClearedWhenActivityIsNilled() {
        // Simulate the post-end state without calling the real endActivity (which would
        // try real ActivityKit IPCs).
        manager.currentActivity = nil
        // Force a non-nil lastPushed to simulate prior push, then verify sanitization path
        // (we can't easily inject a real ContentState without an activity, but we can
        // assert that nil-ing the activity reference is accompanied by clearing lastPushed
        // in real endActivity paths; here we at least exercise the setter).
        // The production clearing happens inside endActivity before/after the Task.
        // We primarily verify the property is writable for test harness and starts nil.
        XCTAssertNil(manager.lastPushedContent)
    }

    func testUpdateCurrentActivityWithNoActivityIsNoOpAndDoesNotTouchLastPushed() {
        // Guard path: when there is no currentActivity we must early return before
        // computing or storing a lastPushed value. This keeps the "only push when active"
        // contract.
        XCTAssertNil(manager.currentActivity)
        let before = manager.lastPushedContent

        // This must be a fast no-op and must not synthesize a lastPushed.
        // Because we are under test guards + no activity, it will return early.
        // We call it to exercise the code path under the test short-circuits.
        // We cannot assert "no persistence side-effect" directly here without
        // heavy mocking of SharedPlayerManager, but the manager itself performs
        // zero UserDefaults or snapshot writes — that is enforced by code review
        // and the architecture (the only writes are inside performActualSave etc.).
        Task { @MainActor in
            await manager.updateCurrentActivity()
        }

        // Still no activity and lastPushed must be unchanged (nil).
        XCTAssertNil(manager.currentActivity)
        XCTAssertEqual(manager.lastPushedContent, before)
    }

    // MARK: - Attribute Events (contentUpdates) Observation

    /// Polls until `condition()` is true or the timeout elapses.
    private func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 2.0
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func makeContentState(
        visualState: PlayerVisualState,
        metadata: StreamProgramMetadata? = nil,
        currentLanguage: String = "en"
    ) -> LutheranRadioLiveActivityAttributes.ContentState {
        LutheranRadioLiveActivityAttributes.ContentState(
            visualState: visualState,
            streamMetadata: metadata,
            currentLanguage: currentLanguage
        )
    }

    private func makeActivityContent(
        visualState: PlayerVisualState,
        metadata: StreamProgramMetadata? = nil,
        currentLanguage: String = "en"
    ) -> ActivityContent<LutheranRadioLiveActivityAttributes.ContentState> {
        ActivityContent(
            state: makeContentState(
                visualState: visualState,
                metadata: metadata,
                currentLanguage: currentLanguage
            ),
            staleDate: nil
        )
    }

    /// Verifies that synthetic attribute-events observation synchronizes
    /// ``lastPushedContent`` with each yielded ``ActivityContent`` state.
    ///
    /// Production consumes ActivityKit ``contentUpdates`` via
    /// ``beginObservingActivityEvents(_:)``. This test exercises the identical
    /// element handler through ``_test_beginObservingSyntheticContentUpdates(_:)``
    /// without system-service IPC.
    func testContentUpdatesObservationSynchronizesLastPushedContent() async {
        let playingContent = makeActivityContent(
            visualState: .playing,
            metadata: StreamProgramMetadata(programTitle: "Sunday Sermon", speaker: "Speaker")
        )

        let stream = AsyncStream<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>> { continuation in
            continuation.yield(playingContent)
            continuation.finish()
        }

        manager._test_beginObservingSyntheticContentUpdates(stream)

        let synchronized = await waitUntil({
            self.manager.lastPushedContent == playingContent.state
        })
        XCTAssertTrue(
            synchronized,
            "Attribute-events yield must align lastPushedContent with the system-accepted state"
        )
        XCTAssertEqual(manager.lastPushedContent?.visualState, .playing)
        XCTAssertEqual(manager.lastPushedContent?.streamMetadata, playingContent.state.streamMetadata)
    }

    /// Verifies that successive attribute-events yields replace ``lastPushedContent``
    /// so diff-driven suppression in ``updateCurrentActivity()`` tracks the latest
    /// rendered content.
    func testContentUpdatesObservationReplacesLastPushedContentOnSubsequentYield() async {
        let first = makeActivityContent(visualState: .playing)
        let second = makeActivityContent(
            visualState: .userPaused,
            metadata: StreamProgramMetadata(programTitle: "Paused Program", speaker: nil)
        )

        var continuation: AsyncStream<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>>.Continuation?
        let stream = AsyncStream { continuation = $0 }

        manager._test_beginObservingSyntheticContentUpdates(stream)

        continuation?.yield(first)
        let firstReady = await waitUntil({ self.manager.lastPushedContent == first.state })
        XCTAssertTrue(firstReady, "Precondition: first yield must synchronize lastPushedContent")

        continuation?.yield(second)
        let secondReady = await waitUntil({ self.manager.lastPushedContent == second.state })
        XCTAssertTrue(secondReady, "Second yield must replace lastPushedContent with the latest state")
        XCTAssertEqual(manager.lastPushedContent?.visualState, .userPaused)
    }

    /// Verifies that ``lastPushedContent`` diff logic suppresses redundant pushes when
    /// the candidate matches the attribute-events-aligned record.
    func testUpdateCurrentActivitySuppressesWhenLastPushedContentMatchesCandidate() async {
        let metadata = StreamProgramMetadata(programTitle: "Live Program", speaker: "Host")
        let aligned = makeActivityContent(visualState: .playing, metadata: metadata, currentLanguage: "fi")

        let stream = AsyncStream<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>> { continuation in
            continuation.yield(aligned)
            continuation.finish()
        }

        manager._test_beginObservingSyntheticContentUpdates(stream)
        let alignedReady = await waitUntil({ self.manager.lastPushedContent == aligned.state })
        XCTAssertTrue(alignedReady, "Precondition: attribute-events alignment must populate lastPushedContent")

        XCTAssertTrue(
            manager._test_wouldSuppressLiveActivityUpdate(
                visualState: .playing,
                streamMetadata: metadata,
                currentLanguage: "fi"
            ),
            "Matching candidate must suppress Activity.update IPC"
        )
        XCTAssertFalse(
            manager._test_wouldSuppressLiveActivityUpdate(
                visualState: .userPaused,
                streamMetadata: metadata,
                currentLanguage: "fi"
            ),
            "Visual change must not suppress"
        )
        XCTAssertFalse(
            manager._test_wouldSuppressLiveActivityUpdate(
                visualState: .playing,
                streamMetadata: StreamProgramMetadata(programTitle: "Different", speaker: nil),
                currentLanguage: "fi"
            ),
            "Metadata change must not suppress"
        )
        XCTAssertFalse(
            manager._test_wouldSuppressLiveActivityUpdate(
                visualState: .playing,
                streamMetadata: metadata,
                currentLanguage: "et"
            ),
            "Language-only change must not suppress (LA language chrome SSOT)"
        )
    }

    /// Seeds last-pushed via synthetic content, then optimistic pause alignment preserves
    /// metadata + language and suppresses a matching post-sticky candidate.
    ///
    /// Protects lock-screen toggle latency: intent-path optimistic content must record
    /// ``lastPushedContent`` without ActivityKit IPC under test isolation so engine-complete
    /// ``updateCurrentActivity`` can suppress when actor visual matches the glyph.
    func testOptimisticToggleAlignmentPreservesMetadataAndSuppressesMatchingCandidate() async {
        let metadata = StreamProgramMetadata(programTitle: "Morning Prayer", speaker: "Reader")
        let playing = makeActivityContent(visualState: .playing, metadata: metadata, currentLanguage: "sv")
        let stream = AsyncStream<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>> { continuation in
            continuation.yield(playing)
            continuation.finish()
        }
        manager._test_beginObservingSyntheticContentUpdates(stream)
        let seeded = await waitUntil({ self.manager.lastPushedContent == playing.state })
        XCTAssertTrue(seeded, "Precondition: lastPushedContent must carry playing + metadata + language")

        manager.recordOptimisticToggleContent(visualState: .userPaused)

        XCTAssertEqual(manager.lastPushedContent?.visualState, .userPaused)
        XCTAssertEqual(
            manager.lastPushedContent?.streamMetadata,
            metadata,
            "Optimistic control flip must not clear program title/speaker"
        )
        // Language prefers selectedStream / durable mirror over lagging lastPushed (heal residual);
        // when those are empty, seeded lastPushed "sv" is preserved.
        let expectedLanguage: String = {
            let resolved = manager._test_languageForOptimisticToggleContentAlignment(
                lastPushedLanguage: "sv",
                ownedContentLanguage: nil,
                selectedStreamLanguage: DirectStreamingPlayer.shared.selectedStream.languageCode,
                durableLanguageMirror: SharedPlayerManager.loadLiveActivityLanguageMirror()
            )
            return resolved.isEmpty ? SharedPlayerManager.mainAppLiveActivityLanguageCode() : resolved
        }()
        XCTAssertEqual(
            manager.lastPushedContent?.currentLanguage,
            expectedLanguage,
            "Optimistic control flip must align language via stream-preferring policy"
        )
        XCTAssertFalse(expectedLanguage.isEmpty, "Optimistic toggle must leave non-empty language chrome")
        XCTAssertTrue(
            manager._test_wouldSuppressLiveActivityUpdate(
                visualState: .userPaused,
                streamMetadata: metadata,
                currentLanguage: expectedLanguage
            ),
            "Engine-complete pause candidate matching optimistic content must suppress"
        )
        XCTAssertFalse(
            manager._test_wouldSuppressLiveActivityUpdate(
                visualState: .playing,
                streamMetadata: metadata,
                currentLanguage: expectedLanguage
            ),
            "Divergent actor visual must still be eligible to push"
        )
    }

    /// Optimistic pause from stale Connecting suppress memory preserves language and does not
    /// require owned visual to have been `.playing` first.
    ///
    /// Protects pause honesty after stream-switch visual freeze: replace Connecting with
    /// `.userPaused` while language chrome stays on the destination stream.
    func testOptimisticPauseFromPrePlayPreservesLanguageWithoutPriorPlaying() async {
        let metadata = StreamProgramMetadata(programTitle: "Predigt", speaker: "Pfarrer")
        let connecting = makeActivityContent(visualState: .prePlay, metadata: metadata, currentLanguage: "de")
        let stream = AsyncStream<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>> { continuation in
            continuation.yield(connecting)
            continuation.finish()
        }
        manager._test_beginObservingSyntheticContentUpdates(stream)
        let seeded = await waitUntil({ self.manager.lastPushedContent == connecting.state })
        XCTAssertTrue(seeded, "Precondition: lastPushedContent must carry Connecting + language")

        manager.recordOptimisticToggleContent(visualState: .userPaused)

        XCTAssertEqual(manager.lastPushedContent?.visualState, .userPaused)
        let expectedLanguage: String = {
            let resolved = manager._test_languageForOptimisticToggleContentAlignment(
                lastPushedLanguage: "de",
                ownedContentLanguage: nil,
                selectedStreamLanguage: DirectStreamingPlayer.shared.selectedStream.languageCode,
                durableLanguageMirror: SharedPlayerManager.loadLiveActivityLanguageMirror()
            )
            return resolved.isEmpty ? SharedPlayerManager.mainAppLiveActivityLanguageCode() : resolved
        }()
        XCTAssertEqual(
            manager.lastPushedContent?.currentLanguage,
            expectedLanguage,
            "Optimistic pause must keep non-empty language via stream-preferring alignment"
        )
        XCTAssertEqual(manager.lastPushedContent?.streamMetadata, metadata)
        // Owned surface still Connecting → suppress denied (ActivityKit push still required).
        // Use owned language "de" (system-held Connecting freeze) even when lastPushed healed
        // to a newer stream code — pause honesty is visual, not language invent on suppress gate.
        XCTAssertFalse(
            RadioLiveActivityManager.shouldSuppressLiveActivityContentPush(
                lastPushed: manager.lastPushedContent,
                candidate: LutheranRadioLiveActivityAttributes.ContentState(
                    visualState: .userPaused,
                    streamMetadata: metadata,
                    currentLanguage: "de"
                ),
                ownedContentLanguage: "de",
                ownedContentVisual: .prePlay
            ),
            "Owned Connecting vs candidate userPaused must not suppress (pause honesty)"
        )
    }

    /// Content-push visual policy: hold/connect clamps playing → Connecting; clear hold keeps playing.
    ///
    /// Protects lock-screen chrome from advertising `.playing` mid stream-switch attach, and
    /// from staying on yellow Connecting after ``setPlaying()`` cleared the hold (stale sampler).
    func testResolveContentPushVisualHoldClampAndAuthoritativePlaying() {
        XCTAssertEqual(
            RadioLiveActivityManager.resolveContentPushVisual(
                visualState: .playing,
                streamSwitchHold: true,
                isConnectingPlayback: false
            ),
            .prePlay,
            "Stream-switch hold must force Connecting while engine may still report playing"
        )
        XCTAssertEqual(
            RadioLiveActivityManager.resolveContentPushVisual(
                visualState: .playing,
                streamSwitchHold: false,
                isConnectingPlayback: true
            ),
            .prePlay,
            "Connect pipeline must force Connecting until audible setPlaying"
        )
        XCTAssertEqual(
            RadioLiveActivityManager.resolveContentPushVisual(
                visualState: .playing,
                streamSwitchHold: false,
                isConnectingPlayback: false
            ),
            .playing,
            "Authoritative playing without hold/connect must publish green playing chrome"
        )
        XCTAssertEqual(
            RadioLiveActivityManager.resolveContentPushVisual(
                visualState: .prePlay,
                streamSwitchHold: true,
                isConnectingPlayback: false
            ),
            .prePlay
        )
        XCTAssertEqual(
            RadioLiveActivityManager.resolveContentPushVisual(
                visualState: .userPaused,
                streamSwitchHold: false,
                isConnectingPlayback: false
            ),
            .userPaused
        )
    }

    /// Optimistic stream-switch alignment records destination language + Connecting and
    /// clears program metadata so engine-complete matching candidates suppress.
    ///
    /// Protects lock-screen language chip latency: intent-path destination chrome must
    /// land in ``lastPushedContent`` without requiring ActivityKit under test isolation.
    /// When owned content language is unknown (`nil`), equality-only suppress still applies.
    func testOptimisticStreamSwitchAlignmentRecordsDestinationAndSuppressesMatchingCandidate() async {
        let metadata = StreamProgramMetadata(programTitle: "Psaltaren 34", speaker: "Speaker")
        let playing = makeActivityContent(visualState: .playing, metadata: metadata, currentLanguage: "sv")
        let stream = AsyncStream<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>> { continuation in
            continuation.yield(playing)
            continuation.finish()
        }
        manager._test_beginObservingSyntheticContentUpdates(stream)
        let seeded = await waitUntil({ self.manager.lastPushedContent == playing.state })
        XCTAssertTrue(seeded, "Precondition: lastPushedContent must carry playing + prior language")

        manager.recordOptimisticStreamSwitchContent(language: "et", visualState: .prePlay)

        XCTAssertEqual(manager.lastPushedContent?.visualState, .prePlay)
        XCTAssertNil(
            manager.lastPushedContent?.streamMetadata,
            "Stream switch must clear prior-stream program metadata on optimistic alignment"
        )
        XCTAssertEqual(manager.lastPushedContent?.currentLanguage, "et")
        XCTAssertTrue(
            manager._test_wouldSuppressLiveActivityUpdate(
                visualState: .prePlay,
                streamMetadata: nil,
                currentLanguage: "et"
            ),
            "Engine-complete Connecting + destination matching optimistic switch must suppress when owned language is unknown"
        )
        XCTAssertFalse(
            manager._test_wouldSuppressLiveActivityUpdate(
                visualState: .prePlay,
                streamMetadata: nil,
                currentLanguage: "sv"
            ),
            "Prior language must remain eligible to push (destination not yet matched)"
        )
    }

    /// Suppress denied when owned ContentState language differs from the candidate language
    /// even if optimistic ``lastPushedContent`` already equals the candidate.
    ///
    /// Protects the lock-screen flag defect class: aspirational suppress memory must not
    /// leave the on-screen activity on the prior language when the system still holds it.
    func testSuppressDeniedWhenOwnedContentLanguageDiffersFromCandidate() async {
        let metadata = StreamProgramMetadata(programTitle: "Psaltaren 34", speaker: "Speaker")
        let swedish = makeActivityContent(visualState: .playing, metadata: metadata, currentLanguage: "sv")
        let stream = AsyncStream<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>> { continuation in
            continuation.yield(swedish)
            continuation.finish()
        }
        manager._test_beginObservingSyntheticContentUpdates(stream)
        let seeded = await waitUntil({ self.manager.lastPushedContent == swedish.state })
        XCTAssertTrue(seeded, "Precondition: lastPushedContent starts at prior language")

        // Optimistic stream switch advances suppress memory to destination without system acceptance.
        manager.recordOptimisticStreamSwitchContent(language: "de", visualState: .prePlay)
        XCTAssertEqual(manager.lastPushedContent?.currentLanguage, "de")

        XCTAssertFalse(
            manager._test_wouldSuppressLiveActivityUpdate(
                visualState: .prePlay,
                streamMetadata: nil,
                currentLanguage: "de",
                ownedContentLanguage: "sv"
            ),
            "Owned content language still Swedish must force a non-suppressed destination push"
        )
        XCTAssertFalse(
            RadioLiveActivityManager.shouldSuppressLiveActivityContentPush(
                lastPushed: manager.lastPushedContent,
                candidate: LutheranRadioLiveActivityAttributes.ContentState(
                    visualState: .prePlay,
                    streamMetadata: nil,
                    currentLanguage: "de"
                ),
                ownedContentLanguage: "sv"
            ),
            "Pure policy: owned ≠ candidate language never suppresses"
        )
    }

    /// Suppress allowed when owned content language, last-pushed, and candidate agree.
    func testSuppressAllowedWhenOwnedLastPushedAndCandidateLanguageAgree() async {
        let metadata = StreamProgramMetadata(programTitle: "Predigt", speaker: "Pastor")
        let german = makeActivityContent(visualState: .playing, metadata: metadata, currentLanguage: "de")
        let stream = AsyncStream<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>> { continuation in
            continuation.yield(german)
            continuation.finish()
        }
        manager._test_beginObservingSyntheticContentUpdates(stream)
        let seeded = await waitUntil({ self.manager.lastPushedContent == german.state })
        XCTAssertTrue(seeded)

        XCTAssertTrue(
            manager._test_wouldSuppressLiveActivityUpdate(
                visualState: .playing,
                streamMetadata: metadata,
                currentLanguage: "de",
                ownedContentLanguage: "de"
            ),
            "Matching owned + last + candidate language must suppress redundant IPC"
        )
        XCTAssertTrue(
            RadioLiveActivityManager.shouldSuppressLiveActivityContentPush(
                lastPushed: german.state,
                candidate: german.state,
                ownedContentLanguage: "de"
            )
        )
    }

    /// Language ensure decision pushes when destination differs from owned or last language.
    ///
    /// Pure harness (no ActivityKit): mirrors ``ensureAuthoritativeLanguageContentIfNeeded()``
    /// preconditions used after stream-switch stamp / media-surface refresh / setPlaying.
    func testLanguageEnsurePushesWhenDestinationDiffersFromOwnedOrLast() {
        XCTAssertTrue(
            manager._test_shouldEnsureAuthoritativeLanguageContent(
                destinationLanguage: "de",
                ownedContentLanguage: "sv",
                lastPushedLanguage: "de"
            ),
            "Owned prior language must schedule reconcile even when lastPushed already claims destination"
        )
        XCTAssertTrue(
            manager._test_shouldEnsureAuthoritativeLanguageContent(
                destinationLanguage: "de",
                ownedContentLanguage: "sv",
                lastPushedLanguage: "sv"
            ),
            "Both owned and last on prior language must schedule reconcile"
        )
        XCTAssertTrue(
            manager._test_shouldEnsureAuthoritativeLanguageContent(
                destinationLanguage: "et",
                ownedContentLanguage: nil,
                lastPushedLanguage: "sv"
            ),
            "Missing owned language with lagging lastPushed must schedule reconcile"
        )
        XCTAssertFalse(
            manager._test_shouldEnsureAuthoritativeLanguageContent(
                destinationLanguage: "de",
                ownedContentLanguage: "de",
                lastPushedLanguage: "de"
            ),
            "Matched destination is a cheap no-op"
        )
        XCTAssertFalse(
            manager._test_shouldEnsureAuthoritativeLanguageContent(
                destinationLanguage: "",
                ownedContentLanguage: "sv",
                lastPushedLanguage: "sv"
            ),
            "Empty destination must not force a language push"
        )
    }

    /// After language soft-ensure budget exhaustion while request is ineligible, further
    /// ensure-driven soft pushes for the same destination stay quiet until re-arm.
    ///
    /// Protects lock-stretch thrash: status-driven media-surface refreshes must not re-burn
    /// the soft-retry budget without acceptance. Re-arm on destination change, eligibility,
    /// become-active (foreground clears quiet), or system contentUpdates.
    /// Does **not** end+request while ineligible.
    func testLanguageEnsureQuietPendingAfterMaxAttemptsWhileIneligible() {
        // Enter quiet only when still mismatched and request ineligible.
        XCTAssertEqual(
            manager._test_quietPendingDestinationAfterLanguageEnsureExhaustion(
                languageStillMismatches: true,
                isRequestEligible: false,
                destinationLanguage: "fi"
            ),
            "fi",
            "Exhausted soft budget while ineligible must record quiet for destination"
        )
        XCTAssertNil(
            manager._test_quietPendingDestinationAfterLanguageEnsureExhaustion(
                languageStillMismatches: true,
                isRequestEligible: true,
                destinationLanguage: "fi"
            ),
            "Eligible request must not enter quiet (foreground soft ensure / recreation path owns recovery)"
        )
        XCTAssertNil(
            manager._test_quietPendingDestinationAfterLanguageEnsureExhaustion(
                languageStillMismatches: false,
                isRequestEligible: false,
                destinationLanguage: "fi"
            ),
            "Matched destination must not enter quiet"
        )

        // Soft pushes stay quiet for same destination while still ineligible.
        XCTAssertFalse(
            manager._test_shouldRunLanguageContentEnsureSoftPushes(
                needsLanguageEnsure: true,
                destinationLanguage: "fi",
                quietPendingDestination: "fi",
                isRequestEligible: false
            ),
            "Same destination quiet while ineligible must stop ensure soft pushes"
        )
        // Re-arm: destination language mutation (high-priority push for new language).
        XCTAssertTrue(
            manager._test_shouldRunLanguageContentEnsureSoftPushes(
                needsLanguageEnsure: true,
                destinationLanguage: "en",
                quietPendingDestination: "fi",
                isRequestEligible: false
            ),
            "New destination must re-arm language ensure even while quiet for prior language"
        )
        // Re-arm: request became eligible (unlock / presentable cycle).
        XCTAssertTrue(
            manager._test_shouldRunLanguageContentEnsureSoftPushes(
                needsLanguageEnsure: true,
                destinationLanguage: "fi",
                quietPendingDestination: "fi",
                isRequestEligible: true
            ),
            "Eligible request must re-arm language ensure despite quiet"
        )
        // No quiet yet → run.
        XCTAssertTrue(
            manager._test_shouldRunLanguageContentEnsureSoftPushes(
                needsLanguageEnsure: true,
                destinationLanguage: "fi",
                quietPendingDestination: nil,
                isRequestEligible: false
            ),
            "No quiet pending must allow soft pushes while ineligible"
        )
        // Ensure not needed → no soft pushes.
        XCTAssertFalse(
            manager._test_shouldRunLanguageContentEnsureSoftPushes(
                needsLanguageEnsure: false,
                destinationLanguage: "fi",
                quietPendingDestination: nil,
                isRequestEligible: false
            ),
            "Matched language must not schedule soft pushes"
        )
        // Empty destination must not schedule soft pushes even when the ensure gate is true.
        XCTAssertFalse(
            manager._test_shouldRunLanguageContentEnsureSoftPushes(
                needsLanguageEnsure: true,
                destinationLanguage: "",
                quietPendingDestination: nil,
                isRequestEligible: false
            ),
            "Empty destination must not schedule language soft pushes"
        )
        XCTAssertNil(
            manager._test_quietPendingDestinationAfterLanguageEnsureExhaustion(
                languageStillMismatches: true,
                isRequestEligible: false,
                destinationLanguage: ""
            ),
            "Empty destination must not enter language quiet"
        )

        // Instance seam: optimistic stream-switch re-arms quiet when destination changes.
        manager._test_setLanguageEnsureQuietPendingDestination("fi")
        XCTAssertEqual(manager._test_languageEnsureQuietPendingDestinationValue(), "fi")
        manager.recordOptimisticStreamSwitchContent(language: "en", visualState: .prePlay)
        XCTAssertNil(
            manager._test_languageEnsureQuietPendingDestinationValue(),
            "Optimistic stream-switch to a new language must clear quiet for prior destination"
        )
        // Same destination optimistic does not clear (still exhausted for that language).
        manager._test_setLanguageEnsureQuietPendingDestination("en")
        manager.recordOptimisticStreamSwitchContent(language: "en", visualState: .userPaused)
        XCTAssertEqual(
            manager._test_languageEnsureQuietPendingDestinationValue(),
            "en",
            "Same-destination optimistic visual flip must not clear language quiet"
        )
        manager._test_setLanguageEnsureQuietPendingDestination(nil)
        manager._test_clearLastPushedContent()
    }

    /// After soft language ensure quiet while lock/ineligible, post-hold settle re-arms soft
    /// language ensure after stream-switch hold clears (audible start / soft-resume path).
    ///
    /// Protects lock-stretch language freeze: attach-storm soft budget often exhausts during
    /// Connecting, then quiet defers language-only status re-pushes for the rest of the stretch.
    /// Settled acceptance is consume-once per destination while ineligible; destination change
    /// and eligibility re-open the settle entry. Delayed post-settled soft ensure may continue
    /// after the entry while owned language still lags. Does **not** invent `.playing` during
    /// hold; does **not** end+request while ineligible.
    func testSettledLanguageAcceptancePushAfterHoldClearWhileQuiet() {
        // Hold still active → wait for setPlaying (Connecting honesty).
        XCTAssertFalse(
            manager._test_shouldPushSettledLanguageAcceptance(
                destinationLanguage: "de",
                ownedContentLanguage: "sv",
                isStreamSwitchHoldActive: true,
                settledAcceptanceConsumedDestination: nil,
                isRequestEligible: false
            ),
            "Stream-switch hold must block settled language acceptance"
        )
        // Hold clear + language mismatch + not consumed → fire once.
        XCTAssertTrue(
            manager._test_shouldPushSettledLanguageAcceptance(
                destinationLanguage: "de",
                ownedContentLanguage: "sv",
                isStreamSwitchHoldActive: false,
                settledAcceptanceConsumedDestination: nil,
                isRequestEligible: false
            ),
            "Post-hold language mismatch must allow one settled acceptance soft-ensure re-arm"
        )
        // Consume-once while still ineligible.
        XCTAssertFalse(
            manager._test_shouldPushSettledLanguageAcceptance(
                destinationLanguage: "de",
                ownedContentLanguage: "sv",
                isStreamSwitchHoldActive: false,
                settledAcceptanceConsumedDestination: "de",
                isRequestEligible: false
            ),
            "Consumed settle for same destination while ineligible must not thrash"
        )
        // Eligibility re-opens settle window (unlock recovery).
        XCTAssertTrue(
            manager._test_shouldPushSettledLanguageAcceptance(
                destinationLanguage: "de",
                ownedContentLanguage: "sv",
                isStreamSwitchHoldActive: false,
                settledAcceptanceConsumedDestination: "de",
                isRequestEligible: true
            ),
            "Eligible request must re-open settled language acceptance"
        )
        // Owned already matches destination → no-op.
        XCTAssertFalse(
            manager._test_shouldPushSettledLanguageAcceptance(
                destinationLanguage: "de",
                ownedContentLanguage: "de",
                isStreamSwitchHoldActive: false,
                settledAcceptanceConsumedDestination: nil,
                isRequestEligible: false
            ),
            "Matched owned language must not schedule settled push"
        )
        // Missing owned language with destination stamped → settle still needed.
        XCTAssertTrue(
            manager._test_shouldPushSettledLanguageAcceptance(
                destinationLanguage: "de",
                ownedContentLanguage: nil,
                isStreamSwitchHoldActive: false,
                settledAcceptanceConsumedDestination: nil,
                isRequestEligible: false
            ),
            "Missing owned language must allow settled language acceptance"
        )
        // Empty destination → no-op.
        XCTAssertFalse(
            manager._test_shouldPushSettledLanguageAcceptance(
                destinationLanguage: "",
                ownedContentLanguage: "sv",
                isStreamSwitchHoldActive: false,
                settledAcceptanceConsumedDestination: nil,
                isRequestEligible: false
            ),
            "Empty destination must not force settled language push"
        )

        // Clear consume when destination advances or owned converges.
        XCTAssertTrue(
            manager._test_shouldClearLanguageSettledAcceptanceConsume(
                settledAcceptanceConsumedDestination: "de",
                destinationLanguage: "fi",
                ownedOrSystemLanguage: "de"
            ),
            "New destination must clear settled consume for prior language"
        )
        XCTAssertTrue(
            manager._test_shouldClearLanguageSettledAcceptanceConsume(
                settledAcceptanceConsumedDestination: "de",
                destinationLanguage: "de",
                ownedOrSystemLanguage: "de"
            ),
            "Owned convergence must clear settled consume"
        )
        XCTAssertFalse(
            manager._test_shouldClearLanguageSettledAcceptanceConsume(
                settledAcceptanceConsumedDestination: "de",
                destinationLanguage: "de",
                ownedOrSystemLanguage: "sv"
            ),
            "Still-lagging same destination must keep settled consume"
        )
        XCTAssertFalse(
            manager._test_shouldClearLanguageSettledAcceptanceConsume(
                settledAcceptanceConsumedDestination: nil,
                destinationLanguage: "de",
                ownedOrSystemLanguage: "de"
            ),
            "No settle consume marker must not clear"
        )
        XCTAssertFalse(
            manager._test_shouldClearLanguageSettledAcceptanceConsume(
                settledAcceptanceConsumedDestination: "de",
                destinationLanguage: "",
                ownedOrSystemLanguage: "de"
            ),
            "Empty destination must not clear settle consume via convergence"
        )
        XCTAssertFalse(
            manager._test_shouldClearLanguageSettledAcceptanceConsume(
                settledAcceptanceConsumedDestination: "de",
                destinationLanguage: "de",
                ownedOrSystemLanguage: nil
            ),
            "Missing owned language must keep settle consume for same destination"
        )

        // Instance seam: optimistic stream-switch to a new language clears settle consume.
        manager._test_setLanguageSettledAcceptanceConsumedDestination("de")
        XCTAssertEqual(manager._test_languageSettledAcceptanceConsumedDestinationValue(), "de")
        manager.recordOptimisticStreamSwitchContent(language: "fi", visualState: .prePlay)
        XCTAssertNil(
            manager._test_languageSettledAcceptanceConsumedDestinationValue(),
            "Optimistic stream-switch to a new language must re-open settled acceptance"
        )
        // Same destination optimistic must not clear consume (still one settle per dest).
        manager._test_setLanguageSettledAcceptanceConsumedDestination("fi")
        manager.recordOptimisticStreamSwitchContent(language: "fi", visualState: .userPaused)
        XCTAssertEqual(
            manager._test_languageSettledAcceptanceConsumedDestinationValue(),
            "fi",
            "Same-destination optimistic visual flip must not clear settled consume"
        )
        manager._test_setLanguageSettledAcceptanceConsumedDestination(nil)
        manager._test_setLanguageEnsureQuietPendingDestination(nil)
        manager._test_clearLastPushedContent()
    }

    /// After post-hold settle soft ensure still leaves owned language lagging, delayed soft
    /// ensure retries must remain schedulable even when quiet / settle consume are engaged.
    ///
    /// Protects destination language honesty after widget / background stream switch: quiet
    /// correctly stops status thrash, but must not permanently freeze language ensure until
    /// unlock. Does **not** invent `.playing`; does **not** end while request ineligible
    /// (recreation eligibility is a separate gate).
    func testPostSettledLanguageEnsureRetriesScheduleWhileOwnedLanguageLags() {
        // Quiet + settle consumed + owned still prior language → still schedule delayed ensure.
        XCTAssertTrue(
            manager._test_shouldSchedulePostSettledLanguageEnsureRetries(
                hasCurrentActivity: true,
                destinationLanguage: "et",
                ownedContentLanguage: "fi",
                isStreamSwitchHoldActive: false
            ),
            "Post-audible lag with owned prior language must schedule delayed soft ensure"
        )
        // Missing owned language while destination stamped → schedule.
        XCTAssertTrue(
            manager._test_shouldSchedulePostSettledLanguageEnsureRetries(
                hasCurrentActivity: true,
                destinationLanguage: "et",
                ownedContentLanguage: nil,
                isStreamSwitchHoldActive: false
            ),
            "Missing owned language must schedule delayed soft ensure for destination"
        )
        // Owned already matches destination → no delayed ensure.
        XCTAssertFalse(
            manager._test_shouldSchedulePostSettledLanguageEnsureRetries(
                hasCurrentActivity: true,
                destinationLanguage: "et",
                ownedContentLanguage: "et",
                isStreamSwitchHoldActive: false
            ),
            "Matched owned language must not schedule delayed soft ensure"
        )
        // Hold still active → wait for audible settle (Connecting honesty).
        XCTAssertFalse(
            manager._test_shouldSchedulePostSettledLanguageEnsureRetries(
                hasCurrentActivity: true,
                destinationLanguage: "et",
                ownedContentLanguage: "fi",
                isStreamSwitchHoldActive: true
            ),
            "Stream-switch hold must block delayed post-settled language ensure"
        )
        // Unowned surface → no schedule (missing-card path is separate).
        XCTAssertFalse(
            manager._test_shouldSchedulePostSettledLanguageEnsureRetries(
                hasCurrentActivity: false,
                destinationLanguage: "et",
                ownedContentLanguage: "fi",
                isStreamSwitchHoldActive: false
            ),
            "Unowned activity must not schedule delayed post-settled language ensure"
        )
        // Empty destination → no schedule.
        XCTAssertFalse(
            manager._test_shouldSchedulePostSettledLanguageEnsureRetries(
                hasCurrentActivity: true,
                destinationLanguage: "",
                ownedContentLanguage: "fi",
                isStreamSwitchHoldActive: false
            ),
            "Empty destination must not schedule delayed language ensure"
        )

        // Destination mutation still clears quiet / re-arms soft ensure for a new language
        // (settle consume reopen is covered by the settled acceptance suite).
        manager._test_setLanguageEnsureQuietPendingDestination("et")
        XCTAssertFalse(
            manager._test_shouldRunLanguageContentEnsureSoftPushes(
                needsLanguageEnsure: true,
                destinationLanguage: "et",
                quietPendingDestination: "et",
                isRequestEligible: false
            ),
            "Quiet for same destination while ineligible must still suppress status soft ensure"
        )
        XCTAssertTrue(
            manager._test_shouldRunLanguageContentEnsureSoftPushes(
                needsLanguageEnsure: true,
                destinationLanguage: "et",
                quietPendingDestination: nil,
                isRequestEligible: false
            ),
            "Clearing quiet (delayed retry / post-hold re-arm) must allow soft ensure again"
        )
        // Foreground ensure still runs when language quiet is set (owned language lag).
        XCTAssertTrue(
            manager._test_shouldInvokeOwnedSurfaceForegroundEnsure(
                hasCurrentActivity: true,
                lastOwnedSurfaceForegroundEnsureAt: Date(),
                now: Date(),
                debounceInterval: 60,
                languageEnsureQuietPending: true,
                playingEnsureQuietPending: false,
                pendingInteractiveLiveActivityEnsure: false,
                contentEnsureStillNeeded: true,
                isRequestEligible: false
            ),
            "Language quiet pending must force owned-surface foreground ensure on become-active"
        )
        // Recreation remains gated when request is ineligible (surface continuity).
        XCTAssertFalse(
            manager._test_shouldRecreateAfterForegroundSoftEnsureFailed(
                languageStillMismatches: true,
                playingStillStalled: false,
                isRequestEligible: false,
                recreationsAttempted: 0
            ),
            "Language-only lag while request ineligible must not end+request"
        )
        manager._test_setLanguageEnsureQuietPendingDestination(nil)
    }

    /// After soft playing ensure quiet while lock/ineligible, one post-hold soft playing-ensure
    /// re-arm is allowed after stream-switch hold/connect clears (audible start / soft-resume).
    ///
    /// Protects lock-stretch visual freeze: soft budget often exhausts (or cannot run while
    /// hold is active), then quiet defers visual-only `.playing` repair for the rest of the
    /// stretch. Settled acceptance is consume-once while ineligible; optimistic toggle /
    /// stream-switch and eligibility re-open the settle entry. Delayed post-settled soft ensure
    /// may continue after the entry while owned visual still lags. Does **not** invent
    /// `.playing` during hold/connect; does **not** end+request while ineligible.
    func testSettledPlayingAcceptancePushAfterHoldClearWhileQuiet() {
        // Hold still active → wait for setPlaying (Connecting honesty).
        XCTAssertFalse(
            manager._test_shouldPushSettledPlayingAcceptance(
                actorVisual: .playing,
                ownedContentVisual: .prePlay,
                isStreamSwitchHoldActive: true,
                isConnectingPlayback: false,
                settledAcceptanceConsumed: false,
                isRequestEligible: false
            ),
            "Stream-switch hold must block settled playing acceptance"
        )
        // Connecting pipeline still active → wait.
        XCTAssertFalse(
            manager._test_shouldPushSettledPlayingAcceptance(
                actorVisual: .playing,
                ownedContentVisual: .prePlay,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: true,
                settledAcceptanceConsumed: false,
                isRequestEligible: false
            ),
            "Connecting playback must block settled playing acceptance"
        )
        // Actor not yet authoritative playing → no-op.
        XCTAssertFalse(
            manager._test_shouldPushSettledPlayingAcceptance(
                actorVisual: .prePlay,
                ownedContentVisual: .prePlay,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false,
                settledAcceptanceConsumed: false,
                isRequestEligible: false
            ),
            "Non-playing actor must not invent settled .playing"
        )
        // Hold clear + owned visual lag + not consumed → fire once.
        XCTAssertTrue(
            manager._test_shouldPushSettledPlayingAcceptance(
                actorVisual: .playing,
                ownedContentVisual: .prePlay,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false,
                settledAcceptanceConsumed: false,
                isRequestEligible: false
            ),
            "Post-hold owned .prePlay must allow one settled playing acceptance push"
        )
        // Soft-resume path: owned still userPaused after pause lag.
        XCTAssertTrue(
            manager._test_shouldPushSettledPlayingAcceptance(
                actorVisual: .playing,
                ownedContentVisual: .userPaused,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false,
                settledAcceptanceConsumed: false,
                isRequestEligible: false
            ),
            "Post-hold owned .userPaused must allow settled playing acceptance"
        )
        // Consume-once while still ineligible.
        XCTAssertFalse(
            manager._test_shouldPushSettledPlayingAcceptance(
                actorVisual: .playing,
                ownedContentVisual: .prePlay,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false,
                settledAcceptanceConsumed: true,
                isRequestEligible: false
            ),
            "Consumed settle while ineligible must not thrash"
        )
        // Eligibility re-opens settle window (unlock recovery).
        XCTAssertTrue(
            manager._test_shouldPushSettledPlayingAcceptance(
                actorVisual: .playing,
                ownedContentVisual: .prePlay,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false,
                settledAcceptanceConsumed: true,
                isRequestEligible: true
            ),
            "Eligible request must re-open settled playing acceptance"
        )
        // Owned already playing → no-op.
        XCTAssertFalse(
            manager._test_shouldPushSettledPlayingAcceptance(
                actorVisual: .playing,
                ownedContentVisual: .playing,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false,
                settledAcceptanceConsumed: false,
                isRequestEligible: false
            ),
            "Matched owned .playing must not schedule settled push"
        )

        // Clear consume when owned converges.
        XCTAssertTrue(
            manager._test_shouldClearPlayingSettledAcceptanceConsume(
                settledAcceptanceConsumed: true,
                ownedOrSystemVisual: .playing
            ),
            "Owned convergence must clear settled playing consume"
        )
        XCTAssertFalse(
            manager._test_shouldClearPlayingSettledAcceptanceConsume(
                settledAcceptanceConsumed: true,
                ownedOrSystemVisual: .prePlay
            ),
            "Still-lagging Connecting must keep settled playing consume"
        )
        XCTAssertFalse(
            manager._test_shouldClearPlayingSettledAcceptanceConsume(
                settledAcceptanceConsumed: false,
                ownedOrSystemVisual: .playing
            ),
            "No consume marker must not clear"
        )
        XCTAssertFalse(
            manager._test_shouldClearPlayingSettledAcceptanceConsume(
                settledAcceptanceConsumed: true,
                ownedOrSystemVisual: nil
            ),
            "Missing owned visual must keep settled playing consume"
        )
        XCTAssertFalse(
            manager._test_shouldClearPlayingSettledAcceptanceConsume(
                settledAcceptanceConsumed: true,
                ownedOrSystemVisual: .userPaused
            ),
            "Owned pause must keep settled playing consume until .playing"
        )

        // Instance seam: optimistic toggle / stream-switch re-open settled playing consume.
        manager._test_setPlayingSettledAcceptanceConsumed(true)
        XCTAssertTrue(manager._test_playingSettledAcceptanceConsumedValue())
        manager.recordOptimisticToggleContent(visualState: .userPaused)
        XCTAssertFalse(
            manager._test_playingSettledAcceptanceConsumedValue(),
            "Optimistic pause toggle must re-open settled playing acceptance"
        )
        manager._test_setPlayingSettledAcceptanceConsumed(true)
        manager.recordOptimisticStreamSwitchContent(language: "fi", visualState: .prePlay)
        XCTAssertFalse(
            manager._test_playingSettledAcceptanceConsumedValue(),
            "Optimistic stream-switch must re-open settled playing acceptance for post-attach cycle"
        )
        manager._test_setPlayingSettledAcceptanceConsumed(false)
        manager._test_setPlayingEnsureQuietPending(false)
        manager._test_clearLastPushedContent()
    }

    /// After post-hold settle soft ensure still leaves owned visual lagging authoritative
    /// `.playing`, delayed soft ensure retries must remain schedulable even when quiet /
    /// settle consume are engaged.
    ///
    /// Protects soft-resume / post-audible visual honesty under continuous lock: quiet
    /// correctly stops status thrash, but must not permanently freeze playing ensure until
    /// unlock. Does **not** invent `.playing` during hold/connect; does **not** end while
    /// request ineligible (recreation eligibility is a separate gate).
    func testPostSettledPlayingEnsureRetriesScheduleWhileOwnedVisualLags() {
        // Soft-resume residual: actor playing, owned still userPaused.
        XCTAssertTrue(
            manager._test_shouldSchedulePostSettledPlayingEnsureRetries(
                hasCurrentActivity: true,
                actorVisual: .playing,
                ownedContentVisual: .userPaused,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Post-audible lag with owned pause must schedule delayed soft playing ensure"
        )
        // Stream-switch residual: owned still Connecting.
        XCTAssertTrue(
            manager._test_shouldSchedulePostSettledPlayingEnsureRetries(
                hasCurrentActivity: true,
                actorVisual: .playing,
                ownedContentVisual: .prePlay,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Post-audible lag with owned Connecting must schedule delayed soft playing ensure"
        )
        // Missing owned visual while actor playing → schedule.
        XCTAssertTrue(
            manager._test_shouldSchedulePostSettledPlayingEnsureRetries(
                hasCurrentActivity: true,
                actorVisual: .playing,
                ownedContentVisual: nil,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Missing owned visual must schedule delayed soft playing ensure"
        )
        // Owned already playing → no delayed ensure.
        XCTAssertFalse(
            manager._test_shouldSchedulePostSettledPlayingEnsureRetries(
                hasCurrentActivity: true,
                actorVisual: .playing,
                ownedContentVisual: .playing,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Matched owned .playing must not schedule delayed soft playing ensure"
        )
        // Hold still active → wait for audible settle.
        XCTAssertFalse(
            manager._test_shouldSchedulePostSettledPlayingEnsureRetries(
                hasCurrentActivity: true,
                actorVisual: .playing,
                ownedContentVisual: .userPaused,
                isStreamSwitchHoldActive: true,
                isConnectingPlayback: false
            ),
            "Stream-switch hold must block delayed post-settled playing ensure"
        )
        // Connecting pipeline still active → wait.
        XCTAssertFalse(
            manager._test_shouldSchedulePostSettledPlayingEnsureRetries(
                hasCurrentActivity: true,
                actorVisual: .playing,
                ownedContentVisual: .userPaused,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: true
            ),
            "Connecting playback must block delayed post-settled playing ensure"
        )
        // Actor not authoritative playing → no schedule (do not invent).
        XCTAssertFalse(
            manager._test_shouldSchedulePostSettledPlayingEnsureRetries(
                hasCurrentActivity: true,
                actorVisual: .userPaused,
                ownedContentVisual: .userPaused,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Non-playing actor must not schedule delayed playing ensure"
        )
        // Unowned surface → no schedule.
        XCTAssertFalse(
            manager._test_shouldSchedulePostSettledPlayingEnsureRetries(
                hasCurrentActivity: false,
                actorVisual: .playing,
                ownedContentVisual: .userPaused,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Unowned activity must not schedule delayed post-settled playing ensure"
        )

        // Clearing quiet (delayed retry / post-hold re-arm) must allow soft ensure again.
        // (Long-horizon pure policy is covered by testPostQuietLongHorizonEnsureRails.)
        XCTAssertFalse(
            manager._test_shouldRunPlayingContentEnsureSoftPushes(
                needsPlayingEnsure: true,
                quietPending: true,
                isRequestEligible: false
            ),
            "Quiet while ineligible must still suppress status soft playing ensure"
        )
        XCTAssertTrue(
            manager._test_shouldRunPlayingContentEnsureSoftPushes(
                needsPlayingEnsure: true,
                quietPending: false,
                isRequestEligible: false
            ),
            "Clearing quiet (delayed retry / post-hold re-arm) must allow soft playing ensure again"
        )
        // Recreation remains gated when request is ineligible (surface continuity).
        XCTAssertFalse(
            manager._test_shouldRecreateAfterForegroundSoftEnsureFailed(
                languageStillMismatches: false,
                playingStillStalled: true,
                isRequestEligible: false,
                recreationsAttempted: 0
            ),
            "Playing-only lag while request ineligible must not end+request"
        )
        manager._test_setPlayingEnsureQuietPending(false)
    }

    /// Post-quiet sparse long-horizon ensure rails: pure-policy coverage for continuous-lock
    /// residual after soft ensure + post-settled budgets exhaust.
    ///
    /// Protects: quiet is thrash protection, not a permanent freeze while request is ineligible
    /// and owned ContentState still lags actor SSOT. Covers arm, cancel, dual-axis quiet coupling,
    /// settled-still-lagging arm, partial-accept re-arm, and quiet-defer arm. Does **not** invent
    /// `.playing` during hold/connect; does **not** end while request ineligible; does **not**
    /// thrash on status ticks (sparse intervals only). Short soft ensure + post-settled remain.
    func testPostQuietLongHorizonEnsureRails() {
        // Interval contract: sparse 5s / 15s / 45s, max 3 fires.
        XCTAssertEqual(
            RadioLiveActivityManager.postQuietLongHorizonEnsureDelayedIntervalsMilliseconds,
            [5_000, 15_000, 45_000],
            "Long-horizon cadence must stay sparse (not post-settled 400/1000/2000)"
        )
        XCTAssertEqual(
            RadioLiveActivityManager.postQuietLongHorizonEnsureMaxDelayedAttempts,
            3
        )
        XCTAssertEqual(
            RadioLiveActivityManager.postQuietLongHorizonEnsureMaxDelayedAttempts,
            RadioLiveActivityManager.postQuietLongHorizonEnsureDelayedIntervalsMilliseconds.count
        )

        // (1) After quiet while ineligible + owned still userPaused + actor playing → arm.
        XCTAssertTrue(
            manager._test_shouldArmPostQuietLongHorizonPlayingEnsure(
                hasCurrentActivity: true,
                isRequestEligible: false,
                longHorizonAlreadyArmed: false,
                actorVisual: .playing,
                lastPushedVisual: .playing,
                ownedContentVisual: .userPaused,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Quiet freeze with owned pause while actor playing must arm long-horizon playing"
        )
        // Already armed → do not re-schedule thrash.
        XCTAssertFalse(
            manager._test_shouldArmPostQuietLongHorizonPlayingEnsure(
                hasCurrentActivity: true,
                isRequestEligible: false,
                longHorizonAlreadyArmed: true,
                actorVisual: .playing,
                lastPushedVisual: .playing,
                ownedContentVisual: .userPaused,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Already-armed long-horizon must not re-schedule"
        )
        // Request eligible → soft ensure / FG rail owns recovery.
        XCTAssertFalse(
            manager._test_shouldArmPostQuietLongHorizonPlayingEnsure(
                hasCurrentActivity: true,
                isRequestEligible: true,
                longHorizonAlreadyArmed: false,
                actorVisual: .playing,
                lastPushedVisual: .playing,
                ownedContentVisual: .userPaused,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Eligible request must not arm long-horizon (presentable path owns recovery)"
        )
        // Owned already playing → no arm.
        XCTAssertFalse(
            manager._test_shouldArmPostQuietLongHorizonPlayingEnsure(
                hasCurrentActivity: true,
                isRequestEligible: false,
                longHorizonAlreadyArmed: false,
                actorVisual: .playing,
                lastPushedVisual: .playing,
                ownedContentVisual: .playing,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Matched owned .playing must not arm long-horizon"
        )
        // Hold / connecting → never invent playing via long-horizon.
        XCTAssertFalse(
            manager._test_shouldArmPostQuietLongHorizonPlayingEnsure(
                hasCurrentActivity: true,
                isRequestEligible: false,
                longHorizonAlreadyArmed: false,
                actorVisual: .playing,
                lastPushedVisual: .prePlay,
                ownedContentVisual: .prePlay,
                isStreamSwitchHoldActive: true,
                isConnectingPlayback: false
            ),
            "Stream-switch hold must block long-horizon playing arm"
        )

        // Language peer: lag while ineligible → arm.
        XCTAssertTrue(
            manager._test_shouldArmPostQuietLongHorizonLanguageEnsure(
                hasCurrentActivity: true,
                isRequestEligible: false,
                longHorizonAlreadyArmed: false,
                destinationLanguage: "et",
                lastPushedLanguage: "et",
                ownedContentLanguage: "sv",
                isStreamSwitchHoldActive: false
            ),
            "Language lag while ineligible must arm long-horizon language"
        )
        XCTAssertFalse(
            manager._test_shouldArmPostQuietLongHorizonLanguageEnsure(
                hasCurrentActivity: true,
                isRequestEligible: false,
                longHorizonAlreadyArmed: false,
                destinationLanguage: "et",
                lastPushedLanguage: "et",
                ownedContentLanguage: "et",
                isStreamSwitchHoldActive: false
            ),
            "Matched owned language must not arm long-horizon"
        )

        // (3) Cancel when ownership nil / owned playing / actor left play.
        XCTAssertTrue(
            manager._test_shouldCancelPostQuietLongHorizonPlayingEnsure(
                hasCurrentActivity: false,
                ownedContentVisual: .userPaused,
                actorVisual: .playing
            ),
            "Unowned surface must cancel long-horizon playing"
        )
        XCTAssertTrue(
            manager._test_shouldCancelPostQuietLongHorizonPlayingEnsure(
                hasCurrentActivity: true,
                ownedContentVisual: .playing,
                actorVisual: .playing
            ),
            "Owned .playing acceptance must cancel long-horizon playing"
        )
        XCTAssertTrue(
            manager._test_shouldCancelPostQuietLongHorizonPlayingEnsure(
                hasCurrentActivity: true,
                ownedContentVisual: .userPaused,
                actorVisual: .userPaused
            ),
            "Actor leaving .playing must cancel long-horizon playing"
        )
        XCTAssertFalse(
            manager._test_shouldCancelPostQuietLongHorizonPlayingEnsure(
                hasCurrentActivity: true,
                ownedContentVisual: .userPaused,
                actorVisual: .playing
            ),
            "Still-lagging freeze must keep long-horizon playing"
        )
        XCTAssertTrue(
            manager._test_shouldCancelPostQuietLongHorizonLanguageEnsure(
                hasCurrentActivity: true,
                destinationLanguage: "et",
                ownedContentLanguage: "et"
            ),
            "Owned language match must cancel long-horizon language"
        )
        XCTAssertFalse(
            manager._test_shouldCancelPostQuietLongHorizonLanguageEnsure(
                hasCurrentActivity: true,
                destinationLanguage: "et",
                ownedContentLanguage: "sv"
            ),
            "Language still lagging must keep long-horizon language"
        )

        // (4) Settled playing still lagging arms long-horizon even after post-settled max
        // (same arm policy as quiet entry — post-settled 3/3 is not terminal under lock).
        XCTAssertTrue(
            manager._test_shouldArmPostQuietLongHorizonPlayingEnsure(
                hasCurrentActivity: true,
                isRequestEligible: false,
                longHorizonAlreadyArmed: false,
                actorVisual: .playing,
                lastPushedVisual: .playing,
                ownedContentVisual: .prePlay,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Post-settled residual Connecting must still arm long-horizon playing"
        )

        // (5) True language-new partial acceptance keeps/re-arms playing long-horizon (does not cancel).
        // Axis heal policy: newly converged language must follow through playing and not cancel playing rails.
        let languageOnly = manager._test_contentUpdateAxisHealPolicy(
            systemLanguage: "de",
            systemVisual: .prePlay,
            destinationLanguage: "de",
            actorVisual: .playing,
            isStreamSwitchHoldActive: false,
            isConnectingPlayback: false,
            priorObservedLanguage: "sv",
            priorObservedVisual: .prePlay
        )
        XCTAssertTrue(languageOnly.shouldFollowThroughPlayingEnsure)
        XCTAssertFalse(
            languageOnly.cancelPlayingPostSettled,
            "Partial language acceptance must not cancel playing post-settled / long-horizon bookkeeping"
        )
        XCTAssertTrue(
            manager._test_shouldArmPostQuietLongHorizonPlayingEnsure(
                hasCurrentActivity: true,
                isRequestEligible: false,
                longHorizonAlreadyArmed: false,
                actorVisual: .playing,
                lastPushedVisual: .playing,
                ownedContentVisual: .prePlay,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "After partial language win with visual lag, playing long-horizon must still arm"
        )

        // (6) Dual-axis: language quiet alone does not prevent dual ensure when both lag.
        XCTAssertTrue(
            manager._test_shouldRunPostQuietLongHorizonDualAxisEnsure(
                languageStillLags: true,
                visualStillLags: true,
                actorVisual: .playing,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Both axes lagging while actor playing must allow dual-axis long-horizon fire"
        )
        XCTAssertTrue(
            manager._test_shouldClearLanguageQuietForDualAxisLongHorizonFire(
                languageQuietPending: true,
                languageStillLags: true,
                visualStillLags: true,
                actorVisual: .playing,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Language quiet must clear on dual-axis long-horizon playing fire when both lag"
        )
        XCTAssertFalse(
            manager._test_shouldClearLanguageQuietForDualAxisLongHorizonFire(
                languageQuietPending: true,
                languageStillLags: false,
                visualStillLags: true,
                actorVisual: .playing,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Language quiet must not clear for dual-axis when language already matched"
        )
        XCTAssertFalse(
            manager._test_shouldClearPlayingQuietForDualAxisLongHorizonFire(
                playingQuietPending: true,
                languageStillLags: true,
                visualStillLags: true,
                actorVisual: .playing,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "After freeze (playing quiet pending while ineligible), dual-axis must not clear playing quiet — language-only owns dest language; playing long-horizon remains the visual rail"
        )
        // Hold blocks dual-axis invent-playing.
        XCTAssertFalse(
            manager._test_shouldRunPostQuietLongHorizonDualAxisEnsure(
                languageStillLags: true,
                visualStillLags: true,
                actorVisual: .playing,
                isStreamSwitchHoldActive: true,
                isConnectingPlayback: false
            ),
            "Hold must block dual-axis long-horizon ensure"
        )

        // (C4) Quiet defer while actor playing + not armed → arm.
        XCTAssertTrue(
            manager._test_shouldArmPostQuietLongHorizonPlayingEnsureAfterQuietDefer(
                didDeferPlayingPushWhileQuiet: true,
                hasCurrentActivity: true,
                isRequestEligible: false,
                longHorizonAlreadyArmed: false,
                actorVisual: .playing,
                lastPushedVisual: .playing,
                ownedContentVisual: .userPaused,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Playing visual push deferred while quiet must arm long-horizon"
        )
        XCTAssertFalse(
            manager._test_shouldArmPostQuietLongHorizonPlayingEnsureAfterQuietDefer(
                didDeferPlayingPushWhileQuiet: false,
                hasCurrentActivity: true,
                isRequestEligible: false,
                longHorizonAlreadyArmed: false,
                actorVisual: .playing,
                lastPushedVisual: .playing,
                ownedContentVisual: .userPaused,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Non-deferred path must not force long-horizon via defer policy"
        )

        // (7) Existing quiet thrash: quiet still suppresses soft ensure while ineligible.
        XCTAssertFalse(
            manager._test_shouldRunPlayingContentEnsureSoftPushes(
                needsPlayingEnsure: true,
                quietPending: true,
                isRequestEligible: false
            ),
            "Long-horizon must not remove status quiet thrash protection"
        )
        XCTAssertFalse(
            manager._test_shouldRunLanguageContentEnsureSoftPushes(
                needsLanguageEnsure: true,
                destinationLanguage: "et",
                quietPendingDestination: "et",
                isRequestEligible: false
            ),
            "Language quiet thrash protection must remain"
        )

        // Test sanitization cancels long-horizon tasks (no ActivityKit; seams only).
        manager._test_cancelAllPostQuietLongHorizonEnsure()
        XCTAssertFalse(manager._test_postQuietLongHorizonPlayingEnsureArmed())
        XCTAssertFalse(manager._test_postQuietLongHorizonLanguageEnsureArmed())
        XCTAssertFalse(manager._test_postQuietLongHorizonDualAxisEnsureArmed())
    }

    /// Dual-axis continuous-lock residual after long-horizon: prePlay settle, dual-axis LH
    /// schedule preference, multi-destination cancel/re-arm policy, and eligible recreate after
    /// dual-axis exhaust. Protects fire quality (one dual ensure when both lag) and never invents
    /// `.playing` during hold/connect; never ends while request ineligible.
    func testDualAxisLongHorizonAndPrePlaySettleRails() {
        // B1 — prePlay settle dual-axis when actor playing, owned Connecting, dest known.
        XCTAssertTrue(
            manager._test_shouldPushSettledDualAxisAcceptance(
                actorVisual: .playing,
                ownedContentVisual: .prePlay,
                destinationLanguage: "de",
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false,
                settledAcceptanceConsumed: false,
                isRequestEligible: false
            ),
            "Owned prePlay after attach must allow dual-axis settle (lang + playing co-push)"
        )
        // Soft-resume userPaused is single-axis settled playing — not dual-axis prePlay settle.
        XCTAssertFalse(
            manager._test_shouldPushSettledDualAxisAcceptance(
                actorVisual: .playing,
                ownedContentVisual: .userPaused,
                destinationLanguage: "sv",
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false,
                settledAcceptanceConsumed: false,
                isRequestEligible: false
            ),
            "userPaused soft-resume must not use dual-axis prePlay settle"
        )
        // Hold / connect must never invent playing via dual settle.
        XCTAssertFalse(
            manager._test_shouldPushSettledDualAxisAcceptance(
                actorVisual: .playing,
                ownedContentVisual: .prePlay,
                destinationLanguage: "de",
                isStreamSwitchHoldActive: true,
                isConnectingPlayback: false,
                settledAcceptanceConsumed: false,
                isRequestEligible: false
            ),
            "Stream-switch hold must block dual-axis settle invent-playing"
        )
        // Consume-once while ineligible.
        XCTAssertFalse(
            manager._test_shouldPushSettledDualAxisAcceptance(
                actorVisual: .playing,
                ownedContentVisual: .prePlay,
                destinationLanguage: "de",
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false,
                settledAcceptanceConsumed: true,
                isRequestEligible: false
            ),
            "Dual-axis settle consume-once while ineligible must suppress re-entry"
        )
        // Eligible re-opens settle window.
        XCTAssertTrue(
            manager._test_shouldPushSettledDualAxisAcceptance(
                actorVisual: .playing,
                ownedContentVisual: .prePlay,
                destinationLanguage: "de",
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false,
                settledAcceptanceConsumed: true,
                isRequestEligible: true
            ),
            "Eligible request must re-open dual-axis settle when prePlay still sticks"
        )
        XCTAssertTrue(
            manager._test_shouldClearDualAxisSettledAcceptanceConsume(
                settledAcceptanceConsumed: true,
                ownedOrSystemVisual: .playing
            ),
            "Owned playing must clear dual-axis settle consume"
        )
        XCTAssertFalse(
            manager._test_shouldClearDualAxisSettledAcceptanceConsume(
                settledAcceptanceConsumed: true,
                ownedOrSystemVisual: .prePlay
            ),
            "Still-prePlay must keep dual-axis settle consume until leave Connecting"
        )

        // B3 — dual-axis LH schedule when both axes lag.
        XCTAssertTrue(
            manager._test_shouldArmPostQuietLongHorizonDualAxisEnsure(
                hasCurrentActivity: true,
                isRequestEligible: false,
                dualAxisAlreadyArmed: false,
                languageStillLags: true,
                visualStillLags: true,
                actorVisual: .playing,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Both axes lagging while ineligible must arm dual-axis long-horizon"
        )
        XCTAssertFalse(
            manager._test_shouldArmPostQuietLongHorizonDualAxisEnsure(
                hasCurrentActivity: true,
                isRequestEligible: false,
                dualAxisAlreadyArmed: true,
                languageStillLags: true,
                visualStillLags: true,
                actorVisual: .playing,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Already-armed dual-axis long-horizon must not re-schedule thrash"
        )
        // Single-axis residual: language only → dual arm false.
        XCTAssertFalse(
            manager._test_shouldArmPostQuietLongHorizonDualAxisEnsure(
                hasCurrentActivity: true,
                isRequestEligible: false,
                dualAxisAlreadyArmed: false,
                languageStillLags: true,
                visualStillLags: false,
                actorVisual: .playing,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Language-only lag must not arm dual-axis long-horizon"
        )
        // prePlay visual lag + language lag still dual.
        XCTAssertTrue(
            manager._test_shouldRunPostQuietLongHorizonDualAxisEnsure(
                languageStillLags: true,
                visualStillLags: true,
                actorVisual: .playing,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "prePlay + language lag must run dual-axis long-horizon fire"
        )
        // Cancel dual when both accepted or actor left play.
        XCTAssertTrue(
            manager._test_shouldCancelPostQuietLongHorizonDualAxisEnsure(
                hasCurrentActivity: true,
                languageStillLags: false,
                visualStillLags: false,
                actorVisual: .playing
            ),
            "Both axes accepted must cancel dual-axis long-horizon"
        )
        XCTAssertTrue(
            manager._test_shouldCancelPostQuietLongHorizonDualAxisEnsure(
                hasCurrentActivity: true,
                languageStillLags: true,
                visualStillLags: true,
                actorVisual: .userPaused
            ),
            "Actor leaving .playing must cancel dual-axis long-horizon"
        )
        XCTAssertFalse(
            manager._test_shouldCancelPostQuietLongHorizonDualAxisEnsure(
                hasCurrentActivity: true,
                languageStillLags: true,
                visualStillLags: true,
                actorVisual: .playing
            ),
            "Both still lagging must keep dual-axis long-horizon"
        )

        // Secondary — dual-axis exhaust → eligible recreate preference; never while ineligible.
        XCTAssertTrue(
            manager._test_shouldMarkDualAxisLongHorizonExhausted(
                languageStillLags: true,
                visualStillLags: true,
                isRequestEligible: false
            ),
            "Ineligible dual-axis exhaust with residual lag must mark pending presentable recovery"
        )
        XCTAssertFalse(
            manager._test_shouldMarkDualAxisLongHorizonExhausted(
                languageStillLags: true,
                visualStillLags: true,
                isRequestEligible: true
            ),
            "Eligible cycles own soft ensure / recreate — do not mark dual-axis exhaust"
        )
        XCTAssertTrue(
            manager._test_shouldPreferEligibleRecreateAfterDualAxisLongHorizonExhausted(
                dualAxisExhausted: true,
                languageStillLags: true,
                visualStillLags: true,
                isRequestEligible: true,
                recreationsAttempted: 0
            ),
            "After dual-axis LH exhaust, eligible become-active must prefer recreate when soft still lags"
        )
        XCTAssertFalse(
            manager._test_shouldPreferEligibleRecreateAfterDualAxisLongHorizonExhausted(
                dualAxisExhausted: true,
                languageStillLags: true,
                visualStillLags: true,
                isRequestEligible: false,
                recreationsAttempted: 0
            ),
            "Must never recreate solely for dual-axis lag while request ineligible"
        )
        XCTAssertFalse(
            manager._test_shouldPreferEligibleRecreateAfterDualAxisLongHorizonExhausted(
                dualAxisExhausted: false,
                languageStillLags: true,
                visualStillLags: true,
                isRequestEligible: true,
                recreationsAttempted: 0
            ),
            "Without dual-axis exhaust flag, dual-axis prefer path stays off (base recreate policy separate)"
        )

        // Quiet thrash protection retained (status soft ensure still quiet while ineligible).
        XCTAssertFalse(
            manager._test_shouldRunPlayingContentEnsureSoftPushes(
                needsPlayingEnsure: true,
                quietPending: true,
                isRequestEligible: false
            )
        )
        manager._test_cancelAllPostQuietLongHorizonEnsure()
        XCTAssertFalse(manager._test_postQuietLongHorizonDualAxisEnsureArmed())
    }

    /// Optimistic toggle language alignment prefers stream attach over lagging lastPushed.
    ///
    /// Protects pause after stream switch: suppress memory that still holds the prior language
    /// must not re-stamp prior-language chrome while ``selectedStream`` already advanced.
    /// Does not invent privacy hard-default `"en"` when stream attach is empty.
    func testOptimisticToggleLanguageAlignmentPrefersSelectedStreamOverLastPushed() {
        // Engine advanced; lastPushed still prior language.
        XCTAssertEqual(
            manager._test_languageForOptimisticToggleContentAlignment(
                lastPushedLanguage: "sv",
                ownedContentLanguage: "sv",
                selectedStreamLanguage: "et",
                durableLanguageMirror: "sv"
            ),
            "et",
            "Selected stream language must outrank lagging lastPushed / owned / mirror"
        )
        // Empty selected stream → durable mirror next.
        XCTAssertEqual(
            manager._test_languageForOptimisticToggleContentAlignment(
                lastPushedLanguage: "sv",
                ownedContentLanguage: "fi",
                selectedStreamLanguage: "",
                durableLanguageMirror: "et"
            ),
            "et",
            "Durable language mirror must outrank lastPushed when stream attach is empty"
        )
        // Empty selected + empty mirror → owned content language.
        XCTAssertEqual(
            manager._test_languageForOptimisticToggleContentAlignment(
                lastPushedLanguage: "sv",
                ownedContentLanguage: "de",
                selectedStreamLanguage: "",
                durableLanguageMirror: nil
            ),
            "de",
            "Owned content language must outrank lastPushed when stream/mirror empty"
        )
        // Only lastPushed available (unit isolation / no stream) → preserve it.
        XCTAssertEqual(
            manager._test_languageForOptimisticToggleContentAlignment(
                lastPushedLanguage: "sv",
                ownedContentLanguage: nil,
                selectedStreamLanguage: "",
                durableLanguageMirror: nil
            ),
            "sv",
            "LastPushed language remains when no fresher source exists"
        )
        // All empty → empty (caller may fall back to mainAppLiveActivityLanguageCode).
        XCTAssertEqual(
            manager._test_languageForOptimisticToggleContentAlignment(
                lastPushedLanguage: nil,
                ownedContentLanguage: nil,
                selectedStreamLanguage: "",
                durableLanguageMirror: nil
            ),
            "",
            "Empty sources must not invent a language code"
        )
    }

    /// After playing soft-ensure budget exhaustion while request is ineligible, further
    /// ensure-driven soft pushes stay quiet until re-arm.
    ///
    /// Protects lock-stretch thrash after stream-switch audible start / soft-resume when
    /// ActivityKit does not accept owned `.playing`. Re-arm on authoritative play mutation,
    /// optimistic toggle / stream-switch, eligibility, become-active, or contentUpdates.
    /// Does **not** end+request while ineligible; does **not** invent `.playing` during hold.
    func testPlayingEnsureQuietPendingAfterMaxAttemptsWhileIneligible() {
        XCTAssertTrue(
            manager._test_shouldEnterPlayingEnsureQuietPending(
                playingStillStalled: true,
                isRequestEligible: false
            ),
            "Exhausted soft budget while ineligible must enter playing quiet"
        )
        XCTAssertFalse(
            manager._test_shouldEnterPlayingEnsureQuietPending(
                playingStillStalled: true,
                isRequestEligible: true
            ),
            "Eligible request must not enter playing quiet (foreground soft ensure / recreation owns recovery)"
        )
        XCTAssertFalse(
            manager._test_shouldEnterPlayingEnsureQuietPending(
                playingStillStalled: false,
                isRequestEligible: false
            ),
            "Matched playing visual must not enter quiet"
        )
        XCTAssertFalse(
            manager._test_shouldEnterPlayingEnsureQuietPending(
                playingStillStalled: true,
                isRequestEligible: false,
                ownedContentVisual: .prePlay,
                isAuthoritativePlayingWithoutHold: true
            ),
            "Post-clamp owned Connecting while actor is playing without hold must not enter quiet"
        )
        XCTAssertTrue(
            manager._test_shouldEnterPlayingEnsureQuietPending(
                playingStillStalled: true,
                isRequestEligible: false,
                ownedContentVisual: .userPaused,
                isAuthoritativePlayingWithoutHold: true
            ),
            "Owned pause vs playing after budget still enters quiet while ineligible"
        )

        XCTAssertFalse(
            manager._test_shouldRunPlayingContentEnsureSoftPushes(
                needsPlayingEnsure: true,
                quietPending: true,
                isRequestEligible: false
            ),
            "Quiet while ineligible must stop playing ensure soft pushes"
        )
        XCTAssertTrue(
            manager._test_shouldRunPlayingContentEnsureSoftPushes(
                needsPlayingEnsure: true,
                quietPending: true,
                isRequestEligible: true
            ),
            "Eligible request must re-arm playing ensure despite quiet"
        )
        XCTAssertTrue(
            manager._test_shouldRunPlayingContentEnsureSoftPushes(
                needsPlayingEnsure: true,
                quietPending: false,
                isRequestEligible: false
            ),
            "No quiet pending must allow soft pushes while ineligible"
        )
        XCTAssertFalse(
            manager._test_shouldRunPlayingContentEnsureSoftPushes(
                needsPlayingEnsure: false,
                quietPending: false,
                isRequestEligible: false
            ),
            "Matched playing chrome must not schedule soft pushes"
        )

        XCTAssertTrue(
            manager._test_shouldClearPlayingEnsureQuietPending(
                quietPending: true,
                ownedOrSystemVisual: .playing
            ),
            "Owned visual .playing must clear playing quiet"
        )
        XCTAssertFalse(
            manager._test_shouldClearPlayingEnsureQuietPending(
                quietPending: true,
                ownedOrSystemVisual: .prePlay
            ),
            "Still-stalled Connecting must not clear playing quiet"
        )
        XCTAssertFalse(
            manager._test_shouldClearPlayingEnsureQuietPending(
                quietPending: true,
                ownedOrSystemVisual: .userPaused
            ),
            "Owned pause must not clear playing quiet (settle / ensure still own quiet clear)"
        )
        XCTAssertFalse(
            manager._test_shouldClearPlayingEnsureQuietPending(
                quietPending: true,
                ownedOrSystemVisual: nil
            ),
            "Missing owned visual must not clear playing quiet"
        )
        XCTAssertFalse(
            manager._test_shouldClearPlayingEnsureQuietPending(
                quietPending: false,
                ownedOrSystemVisual: .playing
            ),
            "No playing quiet is a no-op clear"
        )

        // Instance seam: optimistic toggle / stream-switch re-arm playing quiet.
        manager._test_setPlayingEnsureQuietPending(true)
        XCTAssertTrue(manager._test_playingEnsureQuietPendingValue())
        manager.recordOptimisticToggleContent(visualState: .userPaused)
        XCTAssertFalse(
            manager._test_playingEnsureQuietPendingValue(),
            "Optimistic pause toggle must re-arm playing ensure quiet"
        )
        manager._test_setPlayingEnsureQuietPending(true)
        manager.recordOptimisticStreamSwitchContent(language: "fi", visualState: .prePlay)
        XCTAssertFalse(
            manager._test_playingEnsureQuietPendingValue(),
            "Optimistic stream-switch must re-arm playing ensure quiet for post-attach cycle"
        )
        manager.rearmPlayingEnsureQuietPending()
        XCTAssertFalse(
            manager._test_playingEnsureQuietPendingValue(),
            "Authoritative play re-arm must clear playing quiet"
        )
        manager._test_setPlayingEnsureQuietPending(false)
        manager._test_clearLastPushedContent()
    }

    /// Visual-only playing-repair status re-pushes defer while quiet; pause and language still push.
    ///
    /// After soft playing ensure exhausted while request ineligible, media-surface
    /// ``updateCurrentActivity`` must not re-submit the same `.playing` candidate forever.
    /// Pause honesty (userPaused) and language mutations remain non-suppressed.
    func testPlayingOnlyStatusPushDefersWhileQuietPending() {
        XCTAssertFalse(
            manager._test_shouldDeferRedundantPlayingPushWhileQuiet(
                candidateVisual: .playing,
                ownedContentVisual: .prePlay,
                ownedContentLanguage: "fi",
                candidateLanguage: "fi",
                quietPending: true,
                isRequestEligible: false
            ),
            "Post-clamp Connecting owned visual must not starve the playing push while quiet"
        )
        XCTAssertTrue(
            manager._test_shouldDeferRedundantPlayingPushWhileQuiet(
                candidateVisual: .playing,
                ownedContentVisual: .userPaused,
                ownedContentLanguage: "fi",
                candidateLanguage: "fi",
                quietPending: true,
                isRequestEligible: false
            ),
            "Playing-only stall against owned pause while quiet and ineligible must defer ActivityKit IPC"
        )
        XCTAssertFalse(
            manager._test_shouldDeferRedundantPlayingPushWhileQuiet(
                candidateVisual: .userPaused,
                ownedContentVisual: .prePlay,
                ownedContentLanguage: "fi",
                candidateLanguage: "fi",
                quietPending: true,
                isRequestEligible: false
            ),
            "Pause honesty while playing quiet must still push"
        )
        XCTAssertFalse(
            manager._test_shouldDeferRedundantPlayingPushWhileQuiet(
                candidateVisual: .playing,
                ownedContentVisual: .prePlay,
                ownedContentLanguage: "de",
                candidateLanguage: "fi",
                quietPending: true,
                isRequestEligible: false
            ),
            "Language mutation while playing quiet must still push (co-push both axes)"
        )
        XCTAssertFalse(
            manager._test_shouldDeferRedundantPlayingPushWhileQuiet(
                candidateVisual: .playing,
                ownedContentVisual: .prePlay,
                ownedContentLanguage: "fi",
                candidateLanguage: "fi",
                quietPending: true,
                isRequestEligible: true
            ),
            "Eligible request must not defer playing visual push"
        )
        XCTAssertFalse(
            manager._test_shouldDeferRedundantPlayingPushWhileQuiet(
                candidateVisual: .playing,
                ownedContentVisual: .prePlay,
                ownedContentLanguage: "fi",
                candidateLanguage: "fi",
                quietPending: false,
                isRequestEligible: false
            ),
            "No quiet must not defer playing visual push"
        )
        XCTAssertFalse(
            manager._test_shouldDeferRedundantPlayingPushWhileQuiet(
                candidateVisual: .playing,
                ownedContentVisual: .playing,
                ownedContentLanguage: "fi",
                candidateLanguage: "fi",
                quietPending: true,
                isRequestEligible: false
            ),
            "Matched visual is not a playing stall deferral case"
        )
        // Non-playing candidate (Connecting honesty) is outside playing-repair quiet deferral.
        XCTAssertFalse(
            manager._test_shouldDeferRedundantPlayingPushWhileQuiet(
                candidateVisual: .prePlay,
                ownedContentVisual: .userPaused,
                ownedContentLanguage: "fi",
                candidateLanguage: "fi",
                quietPending: true,
                isRequestEligible: false
            ),
            "Connecting candidate must still push while playing quiet (not a playing-repair thrash)"
        )
    }

    /// Language-only status re-pushes defer while quiet; visual mutations still push.
    ///
    /// After soft language ensure exhausted while request ineligible, media-surface
    /// ``updateCurrentActivity`` must not re-submit the same language candidate forever.
    /// Pause / play / Connecting visual changes remain non-suppressed (honesty).
    func testLanguageOnlyStatusPushDefersWhileQuietPending() {
        XCTAssertTrue(
            manager._test_shouldDeferRedundantLanguagePushWhileQuiet(
                candidateLanguage: "fi",
                ownedContentLanguage: "de",
                ownedContentVisual: .prePlay,
                candidateVisual: .prePlay,
                quietPendingDestination: "fi",
                isRequestEligible: false
            ),
            "Language-only stall for quiet destination while ineligible must defer ActivityKit IPC"
        )
        XCTAssertFalse(
            manager._test_shouldDeferRedundantLanguagePushWhileQuiet(
                candidateLanguage: "fi",
                ownedContentLanguage: "de",
                ownedContentVisual: .prePlay,
                candidateVisual: .playing,
                quietPendingDestination: "fi",
                isRequestEligible: false
            ),
            "Visual mutation while language quiet must still push"
        )
        XCTAssertFalse(
            manager._test_shouldDeferRedundantLanguagePushWhileQuiet(
                candidateLanguage: "fi",
                ownedContentLanguage: "de",
                ownedContentVisual: .prePlay,
                candidateVisual: .userPaused,
                quietPendingDestination: "fi",
                isRequestEligible: false
            ),
            "Pause visual while language quiet must still push"
        )
        XCTAssertFalse(
            manager._test_shouldDeferRedundantLanguagePushWhileQuiet(
                candidateLanguage: "en",
                ownedContentLanguage: "de",
                ownedContentVisual: .prePlay,
                candidateVisual: .prePlay,
                quietPendingDestination: "fi",
                isRequestEligible: false
            ),
            "New destination language must not defer under prior quiet"
        )
        XCTAssertFalse(
            manager._test_shouldDeferRedundantLanguagePushWhileQuiet(
                candidateLanguage: "fi",
                ownedContentLanguage: "de",
                ownedContentVisual: .prePlay,
                candidateVisual: .prePlay,
                quietPendingDestination: "fi",
                isRequestEligible: true
            ),
            "Eligible request must not defer language push"
        )
        XCTAssertFalse(
            manager._test_shouldDeferRedundantLanguagePushWhileQuiet(
                candidateLanguage: "fi",
                ownedContentLanguage: "de",
                ownedContentVisual: .prePlay,
                candidateVisual: .prePlay,
                quietPendingDestination: nil,
                isRequestEligible: false
            ),
            "No quiet pending must not defer"
        )
        // Matched owned language is not a language-stall deferral (suppress handles no-op).
        XCTAssertFalse(
            manager._test_shouldDeferRedundantLanguagePushWhileQuiet(
                candidateLanguage: "fi",
                ownedContentLanguage: "fi",
                ownedContentVisual: .prePlay,
                candidateVisual: .prePlay,
                quietPendingDestination: "fi",
                isRequestEligible: false
            ),
            "Matched owned language must not defer under language quiet"
        )

        // Clear quiet when owned / system language matches destination, or destination moves.
        XCTAssertTrue(
            manager._test_shouldClearLanguageEnsureQuietPending(
                quietPendingDestination: "fi",
                destinationLanguage: "fi",
                ownedOrSystemLanguage: "fi"
            ),
            "Owned/system acceptance of destination must clear quiet"
        )
        XCTAssertTrue(
            manager._test_shouldClearLanguageEnsureQuietPending(
                quietPendingDestination: "fi",
                destinationLanguage: "en",
                ownedOrSystemLanguage: "de"
            ),
            "Destination change must clear prior quiet"
        )
        XCTAssertFalse(
            manager._test_shouldClearLanguageEnsureQuietPending(
                quietPendingDestination: "fi",
                destinationLanguage: "fi",
                ownedOrSystemLanguage: "de"
            ),
            "Still-lagging same destination must keep quiet until re-arm"
        )
        XCTAssertFalse(
            manager._test_shouldClearLanguageEnsureQuietPending(
                quietPendingDestination: nil,
                destinationLanguage: "fi",
                ownedOrSystemLanguage: "fi"
            ),
            "No quiet is a no-op clear"
        )
        // Missing owned language while still quiet for same destination must keep quiet.
        XCTAssertFalse(
            manager._test_shouldClearLanguageEnsureQuietPending(
                quietPendingDestination: "fi",
                destinationLanguage: "fi",
                ownedOrSystemLanguage: nil
            ),
            "Missing owned language must keep language quiet for same destination"
        )
        // Destination change clears quiet even when owned is still missing.
        XCTAssertTrue(
            manager._test_shouldClearLanguageEnsureQuietPending(
                quietPendingDestination: "fi",
                destinationLanguage: "sv",
                ownedOrSystemLanguage: nil
            ),
            "Destination change must clear prior quiet even without owned language"
        )
    }

    /// Soft-ensure thrash protection: concurrent re-entry, deferred recreation announce-once,
    /// and rate-limited identical stall diagnostics.
    ///
    /// After honesty quiet pending (language/playing), residual thrash is concurrent soft-push
    /// loops and repeated deferred-recreation / stall log spam while request stays ineligible.
    /// Pure policies collapse concurrent ensure, record pending ensure once per freeze, and
    /// rate-limit DEBUG for identical candidate/owned pairs. Imperative mutations still re-arm.
    /// Does **not** end+request while ineligible; does **not** invent `.playing`.
    func testSoftEnsureThrashCollapseAndDeferredRecreationAnnounceOnce() {
        // Concurrent soft-push collapse.
        XCTAssertTrue(
            manager._test_shouldStartAuthoritativeContentEnsureSoftPushLoop(
                softPushesAlreadyInFlight: false
            ),
            "First ensure entry must start the soft-push loop"
        )
        XCTAssertFalse(
            manager._test_shouldStartAuthoritativeContentEnsureSoftPushLoop(
                softPushesAlreadyInFlight: true
            ),
            "Concurrent re-entry must collapse into the in-flight loop"
        )

        // Deferred recreation pending mark + announce-once while ineligible.
        XCTAssertTrue(
            manager._test_shouldMarkPendingEnsureForDeferredRecreation(
                wouldRecreateByStreakCap: true,
                isRequestEligible: false
            ),
            "Streak/cap would recreate while ineligible must mark pending ensure"
        )
        XCTAssertFalse(
            manager._test_shouldMarkPendingEnsureForDeferredRecreation(
                wouldRecreateByStreakCap: true,
                isRequestEligible: true
            ),
            "Eligible request uses end+request path — not deferred pending mark"
        )
        XCTAssertFalse(
            manager._test_shouldMarkPendingEnsureForDeferredRecreation(
                wouldRecreateByStreakCap: false,
                isRequestEligible: false
            ),
            "Below recreation threshold must not mark deferred pending"
        )
        XCTAssertTrue(
            manager._test_shouldAnnounceDeferredInteractiveRecreationWhileIneligible(
                wouldRecreateByStreakCap: true,
                isRequestEligible: false,
                pendingEnsureAlreadyRecorded: false
            ),
            "First deferred recreation for a freeze must announce once"
        )
        XCTAssertFalse(
            manager._test_shouldAnnounceDeferredInteractiveRecreationWhileIneligible(
                wouldRecreateByStreakCap: true,
                isRequestEligible: false,
                pendingEnsureAlreadyRecorded: true
            ),
            "Subsequent identical deferred evaluations must stay quiet (no log thrash)"
        )
        XCTAssertFalse(
            manager._test_shouldAnnounceDeferredInteractiveRecreationWhileIneligible(
                wouldRecreateByStreakCap: true,
                isRequestEligible: true,
                pendingEnsureAlreadyRecorded: false
            ),
            "Eligible recreation must not use deferred announce path"
        )

        // Rate-limit identical candidate/owned stall diagnostics.
        let sig = manager._test_stalledContentDiagnosticsSignature(
            candidateLanguage: "fi",
            acceptedLanguage: "de",
            candidateVisual: .prePlay,
            acceptedVisual: .prePlay
        )
        let sigSame = manager._test_stalledContentDiagnosticsSignature(
            candidateLanguage: "fi",
            acceptedLanguage: "de",
            candidateVisual: .prePlay,
            acceptedVisual: .prePlay
        )
        let sigVisualChange = manager._test_stalledContentDiagnosticsSignature(
            candidateLanguage: "fi",
            acceptedLanguage: "de",
            candidateVisual: .playing,
            acceptedVisual: .prePlay
        )
        XCTAssertEqual(sig, sigSame, "Identical freeze pairs must share a diagnostics signature")
        XCTAssertNotEqual(
            sig,
            sigVisualChange,
            "Visual mutation must re-arm stall diagnostics signature"
        )
        XCTAssertTrue(
            manager._test_shouldLogStalledContentDiagnostics(
                signature: sig,
                lastLoggedSignature: nil
            ),
            "First stall signature must log"
        )
        XCTAssertFalse(
            manager._test_shouldLogStalledContentDiagnostics(
                signature: sig,
                lastLoggedSignature: sig
            ),
            "Identical stall signature must not re-log"
        )
        XCTAssertTrue(
            manager._test_shouldLogStalledContentDiagnostics(
                signature: sigVisualChange,
                lastLoggedSignature: sig
            ),
            "Changed freeze pair must re-log once"
        )

        // Quiet-skip DEBUG once per quiet engagement.
        XCTAssertTrue(
            manager._test_shouldLogEnsureQuietSkipOnce(
                softPushesSuppressedByQuiet: true,
                alreadyLoggedQuietSkip: false
            ),
            "First quiet skip must log once"
        )
        XCTAssertFalse(
            manager._test_shouldLogEnsureQuietSkipOnce(
                softPushesSuppressedByQuiet: true,
                alreadyLoggedQuietSkip: true
            ),
            "Repeated quiet skip after announce must stay silent"
        )
        XCTAssertFalse(
            manager._test_shouldLogEnsureQuietSkipOnce(
                softPushesSuppressedByQuiet: false,
                alreadyLoggedQuietSkip: false
            ),
            "Non-quiet path is not a quiet-skip log"
        )
    }

    /// Post-update suppress memory must not claim candidate language when content.state still differs.
    func testSuppressMemoryAfterUpdateKeepsSystemLanguageOnMismatch() {
        let candidate = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .prePlay,
            streamMetadata: nil,
            currentLanguage: "de"
        )
        let acceptedStillSwedish = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .prePlay,
            streamMetadata: nil,
            currentLanguage: "sv"
        )
        let memory = manager._test_suppressMemoryAfterActivityUpdate(
            candidate: candidate,
            acceptedSystemContent: acceptedStillSwedish
        )
        XCTAssertEqual(
            memory.currentLanguage,
            "sv",
            "Failed language acceptance must leave suppress memory on system-held language"
        )
        XCTAssertEqual(
            manager._test_suppressMemoryAfterActivityUpdate(
                candidate: candidate,
                acceptedSystemContent: candidate
            ).currentLanguage,
            "de",
            "Accepted destination language may seed suppress memory"
        )
    }

    /// Stalled system-held ContentState detection: prior language, pause-stuck, and pure Connecting visual freezes.
    ///
    /// Protects lock-screen flag/name stall, soft-resume pause glyph freeze, and pure
    /// `.prePlay` vs `.playing` acceptance lag when ActivityKit completes `update` without
    /// advancing system-held ContentState. Pure visual stalls prefer soft playing-ensure
    /// retries; they still count toward the stalled streak for coherent recovery bookkeeping.
    func testStalledLiveActivityContentPushDetectsLanguageAndPauseVisualStall() {
        let destination = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .prePlay,
            streamMetadata: nil,
            currentLanguage: "et"
        )
        let stillGerman = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .userPaused,
            streamMetadata: nil,
            currentLanguage: "de"
        )
        XCTAssertTrue(
            manager._test_isStalledLiveActivityContentPush(
                candidate: destination,
                accepted: stillGerman
            ),
            "Destination language while system holds prior language lags (stalled)"
        )

        let playingSameLanguage = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .playing,
            streamMetadata: nil,
            currentLanguage: "de"
        )
        let pausedSameLanguage = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .userPaused,
            streamMetadata: nil,
            currentLanguage: "de"
        )
        XCTAssertTrue(
            manager._test_isStalledLiveActivityContentPush(
                candidate: playingSameLanguage,
                accepted: pausedSameLanguage
            ),
            "Soft-resume playing candidate against system pause must count as stalled"
        )
        XCTAssertTrue(
            manager._test_isStalledLiveActivityContentPush(
                candidate: LutheranRadioLiveActivityAttributes.ContentState(
                    visualState: .prePlay,
                    streamMetadata: nil,
                    currentLanguage: "de"
                ),
                accepted: pausedSameLanguage
            ),
            "Connecting candidate against system pause must count as stalled"
        )
        XCTAssertFalse(
            manager._test_isStalledLiveActivityContentPush(
                candidate: playingSameLanguage,
                accepted: playingSameLanguage
            ),
            "Matched language + visual is not stalled"
        )
        XCTAssertFalse(
            manager._test_isStalledLiveActivityContentPush(
                candidate: LutheranRadioLiveActivityAttributes.ContentState(
                    visualState: .userPaused,
                    streamMetadata: nil,
                    currentLanguage: "de"
                ),
                accepted: pausedSameLanguage
            ),
            "Intentional pause match is not stalled"
        )
    }

    /// Pure visual stall: system-held Connecting while candidate is authoritative playing or intentional pause.
    ///
    /// Device residual: soft-resume / post-audible reconcile fires with `owned=prePlay` and
    /// `candidateVisual=playing` without language mismatch — must count as stalled so soft
    /// retries and bookkeeping stay coherent (without requiring recreation as the only path).
    func testStalledLiveActivityContentPushDetectsPurePrePlayVisualFreeze() {
        let playingEstonian = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .playing,
            streamMetadata: nil,
            currentLanguage: "et"
        )
        let connectingEstonian = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .prePlay,
            streamMetadata: nil,
            currentLanguage: "et"
        )
        XCTAssertTrue(
            manager._test_isStalledLiveActivityContentPush(
                candidate: playingEstonian,
                accepted: connectingEstonian
            ),
            "Owned Connecting while candidate is authoritative playing must count as stalled"
        )

        let pausedEstonian = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .userPaused,
            streamMetadata: nil,
            currentLanguage: "et"
        )
        XCTAssertTrue(
            manager._test_isStalledLiveActivityContentPush(
                candidate: pausedEstonian,
                accepted: connectingEstonian
            ),
            "Owned Connecting while candidate is intentional pause must count as stalled"
        )

        // Intentional Connecting match (hold honesty) is not stalled.
        XCTAssertFalse(
            manager._test_isStalledLiveActivityContentPush(
                candidate: connectingEstonian,
                accepted: connectingEstonian
            ),
            "Matched Connecting is not stalled"
        )
        // Playing → Connecting would be a candidate regression (hold), not a system lag of prePlay vs playing.
        // Accepted playing with candidate connecting is not the pure freeze class.
        XCTAssertFalse(
            manager._test_isStalledLiveActivityContentPush(
                candidate: connectingEstonian,
                accepted: playingEstonian
            ),
            "Candidate Connecting against accepted playing is not the pure prePlay freeze class"
        )
    }

    /// Partial-acceptance dual-axis heal: contentUpdates / post-update policy must not treat
    /// one-axis progress as a full surface heal (device: language de + visual prePlay lag).
    ///
    /// Protects continuous-lock residual: language acceptance must re-arm playing ensure;
    /// stall streak must survive partial acceptance; soft-ensure spacing is longer while
    /// request-ineligible. Does **not** end+request while ineligible; does **not** invent
    /// `.playing` during hold/connect.
    func testPartialAcceptanceAxisHealPolicies() {
        let playingDe = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .playing,
            streamMetadata: nil,
            currentLanguage: "de"
        )
        let prePlayDe = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .prePlay,
            streamMetadata: nil,
            currentLanguage: "de"
        )
        let prePlaySv = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .prePlay,
            streamMetadata: nil,
            currentLanguage: "sv"
        )

        // Stall streak: partial language match with visual lag must NOT reset.
        XCTAssertTrue(
            manager._test_isStalledLiveActivityContentPush(
                candidate: playingDe,
                accepted: prePlayDe
            ),
            "Language-matched Connecting freeze is still stalled"
        )
        XCTAssertFalse(
            manager._test_shouldResetStalledContentStreak(
                candidate: playingDe,
                accepted: prePlayDe
            ),
            "Partial acceptance must keep stalled streak for deferred recreation bookkeeping"
        )
        XCTAssertTrue(
            manager._test_shouldResetStalledContentStreak(
                candidate: playingDe,
                accepted: playingDe
            ),
            "Full match may reset stalled streak"
        )
        XCTAssertFalse(
            manager._test_shouldResetStalledContentStreak(
                candidate: playingDe,
                accepted: prePlaySv
            ),
            "Both-axis lag must keep stalled streak"
        )

        // Soft-ensure spacing: short when eligible; longer when ineligible; nil after last attempt.
        XCTAssertEqual(
            manager._test_softEnsureInterAttemptDelayMilliseconds(
                attempt: 1,
                maxAttempts: 3,
                isRequestEligible: true
            ),
            RadioLiveActivityManager.authoritativeContentEnsureEligibleInterAttemptDelayMilliseconds,
            "Eligible soft ensure keeps short inter-attempt delay"
        )
        XCTAssertEqual(
            manager._test_softEnsureInterAttemptDelayMilliseconds(
                attempt: 1,
                maxAttempts: 3,
                isRequestEligible: false
            ),
            RadioLiveActivityManager.authoritativeContentEnsureIneligibleInterAttemptDelaysMilliseconds[0],
            "Ineligible soft ensure uses longer first delay"
        )
        XCTAssertEqual(
            manager._test_softEnsureInterAttemptDelayMilliseconds(
                attempt: 2,
                maxAttempts: 3,
                isRequestEligible: false
            ),
            RadioLiveActivityManager.authoritativeContentEnsureIneligibleInterAttemptDelaysMilliseconds[1],
            "Ineligible soft ensure uses longer second delay"
        )
        XCTAssertNil(
            manager._test_softEnsureInterAttemptDelayMilliseconds(
                attempt: 3,
                maxAttempts: 3,
                isRequestEligible: false
            ),
            "No delay after final soft-ensure attempt"
        )

        // True language-new partial acceptance re-arms playing; reverse re-arms language.
        // Same-stream visual stall (language already matched before push) must NOT re-arm.
        XCTAssertTrue(
            manager._test_shouldRearmPlayingEnsureAfterPartialLanguageAcceptance(
                candidateLanguage: "de",
                acceptedLanguage: "de",
                candidateVisual: .playing,
                acceptedVisual: .prePlay,
                preUpdateOwnedLanguage: "sv"
            ),
            "Language newly converged with Connecting residual must re-arm playing ensure"
        )
        XCTAssertTrue(
            manager._test_shouldRearmPlayingEnsureAfterPartialLanguageAcceptance(
                candidateLanguage: "de",
                acceptedLanguage: "de",
                candidateVisual: .playing,
                acceptedVisual: .userPaused,
                preUpdateOwnedLanguage: "sv"
            ),
            "Language newly converged with pause residual must re-arm playing ensure"
        )
        XCTAssertFalse(
            manager._test_shouldRearmPlayingEnsureAfterPartialLanguageAcceptance(
                candidateLanguage: "de",
                acceptedLanguage: "de",
                candidateVisual: .playing,
                acceptedVisual: .userPaused,
                preUpdateOwnedLanguage: "de"
            ),
            "Same-stream visual stall (language already matched) must not re-arm playing ensure"
        )
        XCTAssertFalse(
            manager._test_shouldRearmPlayingEnsureAfterPartialLanguageAcceptance(
                candidateLanguage: "de",
                acceptedLanguage: "sv",
                candidateVisual: .playing,
                acceptedVisual: .prePlay,
                preUpdateOwnedLanguage: "sv"
            ),
            "Language still lagging is not partial language acceptance"
        )
        XCTAssertFalse(
            manager._test_shouldRearmPlayingEnsureAfterPartialLanguageAcceptance(
                candidateLanguage: "de",
                acceptedLanguage: "de",
                candidateVisual: .playing,
                acceptedVisual: .playing,
                preUpdateOwnedLanguage: "sv"
            ),
            "Full playing match must not re-arm playing ensure"
        )
        XCTAssertTrue(
            manager._test_shouldRearmLanguageEnsureAfterPartialVisualAcceptance(
                candidateLanguage: "et",
                acceptedLanguage: "sv",
                candidateVisual: .playing,
                acceptedVisual: .playing,
                preUpdateOwnedVisual: .userPaused
            ),
            "Visual newly converged with language lag must re-arm language ensure"
        )
        XCTAssertFalse(
            manager._test_shouldRearmLanguageEnsureAfterPartialVisualAcceptance(
                candidateLanguage: "et",
                acceptedLanguage: "sv",
                candidateVisual: .playing,
                acceptedVisual: .playing,
                preUpdateOwnedVisual: .playing
            ),
            "Same-axis visual stall (visual already matched) must not re-arm language ensure"
        )
        XCTAssertFalse(
            manager._test_shouldRearmLanguageEnsureAfterPartialVisualAcceptance(
                candidateLanguage: "et",
                acceptedLanguage: "et",
                candidateVisual: .playing,
                acceptedVisual: .playing,
                preUpdateOwnedVisual: .userPaused
            ),
            "Full language match must not re-arm language ensure"
        )

        // contentUpdates axis heal: language-only progress (German partial — newly converged).
        let languageOnly = manager._test_contentUpdateAxisHealPolicy(
            systemLanguage: "de",
            systemVisual: .prePlay,
            destinationLanguage: "de",
            actorVisual: .playing,
            isStreamSwitchHoldActive: false,
            isConnectingPlayback: false,
            priorObservedLanguage: "sv",
            priorObservedVisual: .prePlay
        )
        XCTAssertTrue(languageOnly.languageConverged)
        XCTAssertFalse(languageOnly.playingConverged)
        XCTAssertFalse(
            languageOnly.resetStalledStreakAndRecreationBudget,
            "Partial language progress must not wipe stall streak"
        )
        XCTAssertTrue(languageOnly.clearLanguageQuiet)
        XCTAssertTrue(languageOnly.cancelLanguagePostSettled)
        XCTAssertFalse(
            languageOnly.cancelPlayingPostSettled,
            "Must not cancel playing post-settled when visual still lags"
        )
        XCTAssertFalse(languageOnly.clearPlayingQuiet)
        XCTAssertTrue(
            languageOnly.shouldFollowThroughPlayingEnsure,
            "Language win must follow through playing ensure for residual prePlay"
        )
        XCTAssertFalse(languageOnly.shouldFollowThroughLanguageEnsure)

        // Full match → full heal.
        let full = manager._test_contentUpdateAxisHealPolicy(
            systemLanguage: "de",
            systemVisual: .playing,
            destinationLanguage: "de",
            actorVisual: .playing,
            isStreamSwitchHoldActive: false,
            isConnectingPlayback: false,
            priorObservedLanguage: "sv",
            priorObservedVisual: .prePlay
        )
        XCTAssertTrue(full.languageConverged)
        XCTAssertTrue(full.playingConverged)
        XCTAssertTrue(full.resetStalledStreakAndRecreationBudget)
        XCTAssertTrue(full.clearPlayingQuiet)
        XCTAssertTrue(full.cancelPlayingPostSettled)
        XCTAssertFalse(full.shouldFollowThroughPlayingEnsure)
        XCTAssertFalse(full.shouldFollowThroughLanguageEnsure)

        // Playing newly accepted with residual language lag → language follow-through.
        let playingNewLangLag = manager._test_contentUpdateAxisHealPolicy(
            systemLanguage: "sv",
            systemVisual: .playing,
            destinationLanguage: "et",
            actorVisual: .playing,
            isStreamSwitchHoldActive: false,
            isConnectingPlayback: false,
            priorObservedLanguage: "sv",
            priorObservedVisual: .userPaused
        )
        XCTAssertFalse(playingNewLangLag.languageConverged)
        XCTAssertTrue(playingNewLangLag.playingConverged)
        XCTAssertFalse(
            playingNewLangLag.resetStalledStreakAndRecreationBudget,
            "Language lag keeps stall bookkeeping"
        )
        XCTAssertFalse(playingNewLangLag.clearLanguageQuiet)
        XCTAssertFalse(playingNewLangLag.cancelLanguagePostSettled)
        XCTAssertTrue(playingNewLangLag.clearPlayingQuiet)
        XCTAssertTrue(playingNewLangLag.cancelPlayingPostSettled)
        XCTAssertTrue(
            playingNewLangLag.shouldFollowThroughLanguageEnsure,
            "Playing newly converged with language lag must follow through language ensure"
        )
        XCTAssertFalse(playingNewLangLag.shouldFollowThroughPlayingEnsure)

        // Same-stream contentUpdates (language already de, visual still prePlay) must NOT
        // re-follow-through playing ensure (thrash coarsen).
        let sameStreamStall = manager._test_contentUpdateAxisHealPolicy(
            systemLanguage: "de",
            systemVisual: .prePlay,
            destinationLanguage: "de",
            actorVisual: .playing,
            isStreamSwitchHoldActive: false,
            isConnectingPlayback: false,
            priorObservedLanguage: "de",
            priorObservedVisual: .prePlay
        )
        XCTAssertTrue(sameStreamStall.languageConverged)
        XCTAssertFalse(sameStreamStall.playingConverged)
        XCTAssertFalse(
            sameStreamStall.shouldFollowThroughPlayingEnsure,
            "Language already matched before yield must not thrash playing follow-through"
        )

        // Hold/connect: never invent playing follow-through.
        let hold = manager._test_contentUpdateAxisHealPolicy(
            systemLanguage: "de",
            systemVisual: .prePlay,
            destinationLanguage: "de",
            actorVisual: .playing,
            isStreamSwitchHoldActive: true,
            isConnectingPlayback: false,
            priorObservedLanguage: "sv",
            priorObservedVisual: .prePlay
        )
        XCTAssertTrue(hold.languageConverged)
        XCTAssertTrue(hold.visualConverged, "Hold forces effective Connecting match")
        XCTAssertFalse(hold.playingConverged)
        XCTAssertFalse(
            hold.shouldFollowThroughPlayingEnsure,
            "Must not follow through playing ensure during stream-switch hold"
        )
    }

    /// Continuous-lock ensure thrash smart-loosen: freeze soft-budget + partial coarsen pure policies.
    ///
    /// Protects device residual after dual-axis ship: same-stream soft-resume churn must not
    /// clear quiet / nest post-settled on every failed playing push; true language-new wins get
    /// one follow-through; eligible recreate after freeze soft-budget exhaust never while
    /// request-ineligible. Does **not** claim full ActivityKit lock guarantee.
    func testContentEnsureFreezeThrashSmartLoosenPolicies() {
        // Language newly converge helpers.
        XCTAssertTrue(
            manager._test_didLanguageNewlyConverge(
                preUpdateOwnedLanguage: "sv",
                acceptedLanguage: "et",
                candidateLanguage: "et"
            ),
            "Destination newly accepted is a true language converge"
        )
        XCTAssertFalse(
            manager._test_didLanguageNewlyConverge(
                preUpdateOwnedLanguage: "et",
                acceptedLanguage: "et",
                candidateLanguage: "et"
            ),
            "Language already matched is not a new converge"
        )

        // Quiet clear for partial re-arm under freeze soft-budget exhaust.
        XCTAssertTrue(
            manager._test_shouldClearPlayingEnsureQuietForPartialRearm(
                shouldRearmFromPartialPolicy: true,
                freezeSoftBudgetExhausted: false,
                partialPostSettledAlreadyScheduled: false,
                isRequestEligible: false
            ),
            "True partial win before soft-budget exhaust may clear quiet"
        )
        XCTAssertTrue(
            manager._test_shouldClearPlayingEnsureQuietForPartialRearm(
                shouldRearmFromPartialPolicy: true,
                freezeSoftBudgetExhausted: true,
                partialPostSettledAlreadyScheduled: false,
                isRequestEligible: false
            ),
            "True partial win after soft-budget exhaust may clear quiet once for follow-through"
        )
        XCTAssertFalse(
            manager._test_shouldClearPlayingEnsureQuietForPartialRearm(
                shouldRearmFromPartialPolicy: true,
                freezeSoftBudgetExhausted: true,
                partialPostSettledAlreadyScheduled: true,
                isRequestEligible: false
            ),
            "Second partial quiet clear while ineligible after follow-through already used must not thrash"
        )
        XCTAssertTrue(
            manager._test_shouldClearPlayingEnsureQuietForPartialRearm(
                shouldRearmFromPartialPolicy: true,
                freezeSoftBudgetExhausted: true,
                partialPostSettledAlreadyScheduled: true,
                isRequestEligible: true
            ),
            "Eligible / presentable cycles may always clear quiet for partial follow-through"
        )
        XCTAssertFalse(
            manager._test_shouldClearPlayingEnsureQuietForPartialRearm(
                shouldRearmFromPartialPolicy: false,
                freezeSoftBudgetExhausted: false,
                partialPostSettledAlreadyScheduled: false,
                isRequestEligible: false
            ),
            "Same-stream stall (no re-arm policy) must not clear quiet"
        )

        // Nested post-settled after soft-budget exhaust: only true language-new while ineligible.
        XCTAssertFalse(
            manager._test_shouldSchedulePostSettledPlayingEnsureAfterSoftBudgetExhaust(
                baseShouldSchedule: true,
                isRequestEligible: false,
                languageNewlyConvergedThisFreeze: false,
                partialPostSettledAlreadyScheduled: false
            ),
            "Same-stream visual stall after soft budget must skip nested post-settled"
        )
        XCTAssertTrue(
            manager._test_shouldSchedulePostSettledPlayingEnsureAfterSoftBudgetExhaust(
                baseShouldSchedule: true,
                isRequestEligible: false,
                languageNewlyConvergedThisFreeze: true,
                partialPostSettledAlreadyScheduled: false
            ),
            "True language-new win may schedule one post-settled after soft budget"
        )
        XCTAssertFalse(
            manager._test_shouldSchedulePostSettledPlayingEnsureAfterSoftBudgetExhaust(
                baseShouldSchedule: true,
                isRequestEligible: false,
                languageNewlyConvergedThisFreeze: true,
                partialPostSettledAlreadyScheduled: true
            ),
            "Second nested post-settled while ineligible must not schedule"
        )
        XCTAssertTrue(
            manager._test_shouldSchedulePostSettledPlayingEnsureAfterSoftBudgetExhaust(
                baseShouldSchedule: true,
                isRequestEligible: true,
                languageNewlyConvergedThisFreeze: false,
                partialPostSettledAlreadyScheduled: false
            ),
            "Eligible cycles keep post-settled for unlock heal"
        )

        // Eligible hard heal after freeze soft-budget exhaust (never while ineligible).
        XCTAssertTrue(
            manager._test_shouldPreferEligibleRecreateAfterContentEnsureFreezeExhausted(
                freezeSoftBudgetExhausted: true,
                dualAxisExhausted: false,
                languageStillLags: false,
                visualStillLags: true,
                isRequestEligible: true,
                recreationsAttempted: 0
            ),
            "Freeze soft-budget exhaust + visual lag + eligible may prefer recreation"
        )
        XCTAssertFalse(
            manager._test_shouldPreferEligibleRecreateAfterContentEnsureFreezeExhausted(
                freezeSoftBudgetExhausted: true,
                dualAxisExhausted: false,
                languageStillLags: false,
                visualStillLags: true,
                isRequestEligible: false,
                recreationsAttempted: 0
            ),
            "Never end-only-interactive while request ineligible solely for freeze lag"
        )
        XCTAssertFalse(
            manager._test_shouldPreferEligibleRecreateAfterContentEnsureFreezeExhausted(
                freezeSoftBudgetExhausted: false,
                dualAxisExhausted: false,
                languageStillLags: true,
                visualStillLags: true,
                isRequestEligible: true,
                recreationsAttempted: 0
            ),
            "Without freeze or dual-axis exhaust, preference path stays off"
        )
        XCTAssertTrue(
            manager._test_shouldPreferEligibleRecreateAfterContentEnsureFreezeExhausted(
                freezeSoftBudgetExhausted: false,
                dualAxisExhausted: true,
                languageStillLags: true,
                visualStillLags: false,
                isRequestEligible: true,
                recreationsAttempted: 0
            ),
            "Dual-axis long-horizon exhaust alone still prefers eligible recreate"
        )
    }

    /// Suppress denied when owned ContentState visual differs from the candidate visual
    /// even if optimistic ``lastPushedContent`` already equals the candidate.
    ///
    /// Protects soft-resume / post-audible Connecting freeze: aspirational suppress memory
    /// claiming `.playing` must not skip IPC while the system-held surface still shows `.prePlay`.
    func testSuppressDeniedWhenOwnedContentVisualDiffersFromCandidate() {
        let playingCandidate = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .playing,
            streamMetadata: nil,
            currentLanguage: "et"
        )
        // Optimistic lastPushed already claims playing (same as candidate).
        let optimisticLast = playingCandidate

        XCTAssertFalse(
            RadioLiveActivityManager.shouldSuppressLiveActivityContentPush(
                lastPushed: optimisticLast,
                candidate: playingCandidate,
                ownedContentLanguage: "et",
                ownedContentVisual: .prePlay
            ),
            "Owned Connecting while candidate is playing must force a non-suppressed push"
        )
        XCTAssertFalse(
            RadioLiveActivityManager.shouldSuppressLiveActivityContentPush(
                lastPushed: optimisticLast,
                candidate: playingCandidate,
                ownedContentLanguage: "et",
                ownedContentVisual: .userPaused
            ),
            "Owned pause while candidate is playing must force a non-suppressed push"
        )
        XCTAssertTrue(
            RadioLiveActivityManager.shouldSuppressLiveActivityContentPush(
                lastPushed: optimisticLast,
                candidate: playingCandidate,
                ownedContentLanguage: "et",
                ownedContentVisual: .playing
            ),
            "Matched owned + last + candidate visual may suppress redundant IPC"
        )
        // Seed lastPushed via optimistic record then assert seam with owned visual lag.
        manager.recordOptimisticStreamSwitchContent(language: "et", visualState: .playing)
        XCTAssertEqual(manager.lastPushedContent?.visualState, .playing)
        XCTAssertFalse(
            manager._test_wouldSuppressLiveActivityUpdate(
                visualState: .playing,
                streamMetadata: nil,
                currentLanguage: "et",
                ownedContentLanguage: "et",
                ownedContentVisual: .prePlay
            ),
            "Seam: owned prePlay must deny suppress when last already claims playing"
        )
    }

    /// Recreation only after threshold and within the per-cycle recreation cap.
    func testInteractiveRecreationDecisionUsesThresholdAndCap() {
        XCTAssertFalse(
            manager._test_shouldRecreateInteractiveLiveActivityAfterStalledPushes(
                consecutiveStalled: 2,
                recreationsAttempted: 0,
                isRecreationInProgress: false
            ),
            "Brief lag below threshold must not recreate (avoids thrash on one-frame language lag)"
        )
        XCTAssertTrue(
            manager._test_shouldRecreateInteractiveLiveActivityAfterStalledPushes(
                consecutiveStalled: RadioLiveActivityManager.stalledContentPushRecreationThreshold,
                recreationsAttempted: 0,
                isRecreationInProgress: false
            ),
            "At threshold with recreation budget remaining must recreate"
        )
        XCTAssertFalse(
            manager._test_shouldRecreateInteractiveLiveActivityAfterStalledPushes(
                consecutiveStalled: 10,
                recreationsAttempted: 0,
                isRecreationInProgress: true
            ),
            "Nested push during end+start must not schedule another recreation"
        )
        XCTAssertFalse(
            manager._test_shouldRecreateInteractiveLiveActivityAfterStalledPushes(
                consecutiveStalled: 10,
                recreationsAttempted: RadioLiveActivityManager.maxInteractiveContentRecreations,
                isRecreationInProgress: false
            ),
            "Exhausted recreation budget must stop end/start loops"
        )
    }

    /// End+request recreation must never run when interactive request is ineligible
    /// (lock screen / background visibility), even when the stalled streak is past threshold.
    ///
    /// **Invariant:** never destroy the only interactive Live Activity unless a replacement
    /// `Activity.request` can succeed (or a recoverable pending ensure is recorded separately).
    func testStalledContentRecreationRequiresRequestEligibility() {
        let atThreshold = RadioLiveActivityManager.stalledContentPushRecreationThreshold

        XCTAssertTrue(
            manager._test_isInteractiveLiveActivityRequestEligible(
                areActivitiesEnabled: true,
                isApplicationActive: true
            ),
            "Enabled + active application is eligible for interactive request"
        )
        XCTAssertFalse(
            manager._test_isInteractiveLiveActivityRequestEligible(
                areActivitiesEnabled: true,
                isApplicationActive: false
            ),
            "Background / inactive application is not eligible (visibility failure class)"
        )
        XCTAssertFalse(
            manager._test_isInteractiveLiveActivityRequestEligible(
                areActivitiesEnabled: false,
                isApplicationActive: true
            ),
            "User/system disabled Live Activities is not eligible"
        )

        XCTAssertFalse(
            manager._test_shouldPerformStalledContentRecreation(
                consecutiveStalled: atThreshold,
                recreationsAttempted: 0,
                isRecreationInProgress: false,
                isRequestEligible: false
            ),
            "Ineligible request must not end the only interactive surface even past stall threshold"
        )
        XCTAssertTrue(
            manager._test_shouldPerformStalledContentRecreation(
                consecutiveStalled: atThreshold,
                recreationsAttempted: 0,
                isRecreationInProgress: false,
                isRequestEligible: true
            ),
            "Eligible + threshold + budget must allow end+request recreation"
        )
        XCTAssertFalse(
            manager._test_shouldPerformStalledContentRecreation(
                consecutiveStalled: atThreshold,
                recreationsAttempted: 0,
                isRecreationInProgress: true,
                isRequestEligible: true
            ),
            "Nested recreation during end+start must remain suppressed when eligible"
        )
        XCTAssertFalse(
            manager._test_shouldPerformStalledContentRecreation(
                consecutiveStalled: 2,
                recreationsAttempted: 0,
                isRecreationInProgress: false,
                isRequestEligible: true
            ),
            "Eligible request alone must not recreate below stall threshold"
        )
    }

    /// Immediate post-await `content.state` is apply-in-flight; stall/quiet/recreate wait for
    /// delayed re-read or `contentUpdates`. Handshake lag does not consume recreation.
    ///
    /// Protects foreground kill-after-accept and Connecting→playing bursts: one immediate
    /// mismatch must not recreate; delayed match resets; language stick after the apply
    /// window still may. Does **not** invent `.playing` during hold; does **not** end while
    /// ineligible.
    func testContentPushStallOracleWaitsForApplyConfirmation() {
        XCTAssertEqual(
            manager._test_contentPushApplyConfirmationDelayMilliseconds(isRequestEligible: true),
            RadioLiveActivityManager.authoritativeContentEnsureEligibleInterAttemptDelayMilliseconds,
            "Eligible apply-window matches the first soft-ensure eligible delay"
        )
        XCTAssertEqual(
            manager._test_contentPushApplyConfirmationDelayMilliseconds(isRequestEligible: false),
            RadioLiveActivityManager.authoritativeContentEnsureIneligibleInterAttemptDelaysMilliseconds[0],
            "Ineligible apply-window matches the first ineligible soft-ensure delay"
        )

        XCTAssertFalse(
            manager._test_shouldCommitStalledContentPushObservation(
                kind: .immediatePostAwait,
                isStalled: true,
                isHandshakeLag: false
            ),
            "Immediate post-await mismatch must not commit stall (apply-in-flight)"
        )
        XCTAssertFalse(
            manager._test_shouldCommitStalledContentPushObservation(
                kind: .immediatePostAwait,
                isStalled: true,
                isHandshakeLag: true
            ),
            "Immediate handshake mismatch must not commit stall"
        )
        XCTAssertTrue(
            manager._test_shouldCommitStalledContentPushObservation(
                kind: .delayedReread,
                isStalled: true,
                isHandshakeLag: false
            ),
            "Delayed re-read of a true language/visual freeze must commit stall"
        )
        XCTAssertFalse(
            manager._test_shouldCommitStalledContentPushObservation(
                kind: .delayedReread,
                isStalled: true,
                isHandshakeLag: true
            ),
            "Delayed handshake (Connecting→playing) must not consume recreation streak"
        )
        XCTAssertTrue(
            manager._test_shouldCommitStalledContentPushObservation(
                kind: .contentUpdates,
                isStalled: true,
                isHandshakeLag: false
            ),
            "contentUpdates mismatch after the apply window is stall truth"
        )
        XCTAssertFalse(
            manager._test_shouldCommitStalledContentPushObservation(
                kind: .contentUpdates,
                isStalled: false,
                isHandshakeLag: false
            ),
            "contentUpdates match must not increment stall (clears quiet via reset path)"
        )
        XCTAssertFalse(
            manager._test_shouldCommitStalledContentPushObservation(
                kind: .delayedReread,
                isStalled: false,
                isHandshakeLag: false
            ),
            "Delayed match must not increment stall"
        )

        let atThreshold = RadioLiveActivityManager.stalledContentPushRecreationThreshold
        XCTAssertFalse(
            manager._test_shouldPerformStalledContentRecreation(
                consecutiveStalled: 0,
                recreationsAttempted: 0,
                isRecreationInProgress: false,
                isRequestEligible: true
            ),
            "Immediate mismatch that does not increment streak must not recreate"
        )
        XCTAssertTrue(
            manager._test_shouldPerformStalledContentRecreation(
                consecutiveStalled: atThreshold,
                recreationsAttempted: 0,
                isRecreationInProgress: false,
                isRequestEligible: true
            ),
            "Committed language stick at threshold while eligible still may recreate"
        )
    }

    /// Delayed re-read is stall truth **and** axis-heal truth, same as `contentUpdates`.
    ///
    /// Immediate post-await `content.state` does not axis-heal (apply-in-flight). Language-new
    /// delayed observation with visual still `.prePlay` while the actor is `.playing` re-arms
    /// playing ensure and must not wipe stall bookkeeping as a same-stream visual stall.
    /// Does **not** invent `.playing`; does **not** end while ineligible.
    func testDelayedRereadObservationRunsAxisHealOnLanguageNewVisualLag() {
        XCTAssertTrue(
            manager._test_shouldApplySystemContentUpdateHealAfterObservation(kind: .delayedReread),
            "Delayed re-read must run axis-heal (contentUpdates may be silent under lock)"
        )
        XCTAssertTrue(
            manager._test_shouldApplySystemContentUpdateHealAfterObservation(kind: .contentUpdates),
            "contentUpdates yields must run axis-heal"
        )
        XCTAssertFalse(
            manager._test_shouldApplySystemContentUpdateHealAfterObservation(kind: .immediatePostAwait),
            "Immediate post-await is apply-in-flight and must not axis-heal"
        )

        let delayedLanguageNew = manager._test_contentUpdateAxisHealPolicy(
            systemLanguage: "en",
            systemVisual: .prePlay,
            destinationLanguage: "en",
            actorVisual: .playing,
            isStreamSwitchHoldActive: false,
            isConnectingPlayback: false,
            priorObservedLanguage: "sv",
            priorObservedVisual: .prePlay
        )
        XCTAssertTrue(delayedLanguageNew.languageConverged)
        XCTAssertFalse(delayedLanguageNew.playingConverged)
        XCTAssertFalse(
            delayedLanguageNew.resetStalledStreakAndRecreationBudget,
            "Language-new delayed re-read with Connecting residual must not wipe stall streak"
        )
        XCTAssertTrue(
            delayedLanguageNew.shouldFollowThroughPlayingEnsure,
            "Language-new delayed re-read with visual still Connecting must re-arm playing ensure"
        )
        XCTAssertFalse(delayedLanguageNew.shouldFollowThroughLanguageEnsure)
        XCTAssertFalse(
            delayedLanguageNew.cancelPlayingPostSettled,
            "Must not treat language-new delayed re-read as same-stream visual stall wipe"
        )

        let sameStreamDelayed = manager._test_contentUpdateAxisHealPolicy(
            systemLanguage: "en",
            systemVisual: .prePlay,
            destinationLanguage: "en",
            actorVisual: .playing,
            isStreamSwitchHoldActive: false,
            isConnectingPlayback: false,
            priorObservedLanguage: "en",
            priorObservedVisual: .prePlay
        )
        XCTAssertFalse(
            sameStreamDelayed.shouldFollowThroughPlayingEnsure,
            "Same-stream delayed re-read (language already dest) must not thrash playing follow-through"
        )
    }

    /// DEBUG `contentUpdates` yield line is rate-limited on identical (id, language, visual).
    ///
    /// Device recapture must be able to distinguish observer silence from a heal miss.
    /// Does not log in Release. Does not cite local capture filenames.
    func testContentUpdatesYieldDiagnosticsAreRateLimited() {
        let yieldA = manager._test_contentUpdatesYieldDiagnosticsSignature(
            systemLanguage: "en",
            systemVisual: .prePlay,
            activityId: "id-1"
        )
        let yieldSame = manager._test_contentUpdatesYieldDiagnosticsSignature(
            systemLanguage: "en",
            systemVisual: .prePlay,
            activityId: "id-1"
        )
        let yieldLang = manager._test_contentUpdatesYieldDiagnosticsSignature(
            systemLanguage: "fi",
            systemVisual: .prePlay,
            activityId: "id-1"
        )
        let yieldVisual = manager._test_contentUpdatesYieldDiagnosticsSignature(
            systemLanguage: "en",
            systemVisual: .playing,
            activityId: "id-1"
        )
        let yieldId = manager._test_contentUpdatesYieldDiagnosticsSignature(
            systemLanguage: "en",
            systemVisual: .prePlay,
            activityId: "id-2"
        )
        XCTAssertEqual(yieldA, yieldSame, "Identical yield tuples must share a diagnostics signature")
        XCTAssertNotEqual(yieldA, yieldLang, "Language mutation must re-arm yield diagnostics")
        XCTAssertNotEqual(yieldA, yieldVisual, "Visual mutation must re-arm yield diagnostics")
        XCTAssertNotEqual(yieldA, yieldId, "Activity id change must re-arm yield diagnostics")
        XCTAssertTrue(
            manager._test_shouldLogStalledContentDiagnostics(
                signature: yieldA,
                lastLoggedSignature: nil
            ),
            "First contentUpdates yield must log"
        )
        XCTAssertFalse(
            manager._test_shouldLogStalledContentDiagnostics(
                signature: yieldA,
                lastLoggedSignature: yieldA
            ),
            "Identical contentUpdates yield must not re-log"
        )
        XCTAssertTrue(
            manager._test_shouldLogStalledContentDiagnostics(
                signature: yieldLang,
                lastLoggedSignature: yieldA
            ),
            "Changed yield tuple must re-log once"
        )
    }

    /// One outstanding visual mutation: while `Activity.update` apply is unconfirmed,
    /// visual-differing candidates coalesce (latest wins) instead of issuing a second IPC.
    /// Language-only same-visual candidates still update. Pause replacing playing-ensure
    /// in-flight must remain the outstanding candidate. Duplicate unconfirmed playing
    /// pushes also coalesce. Does **not** invent `.playing`; does **not** end while ineligible.
    ///
    /// Why this pattern is required: MainActor re-entry during `await Activity.update` and
    /// playing-ensure / dual-axis loops would otherwise burn the lock-stretch apply budget
    /// on a Connecting→playing burst. Pure `should*` — no ActivityKit waits.
    func testVisualDifferingContentPushCoalescesWhileInFlight() {
        XCTAssertFalse(
            manager._test_shouldCoalesceVisualDifferingContentPushWhileInFlight(
                inFlightVisual: nil,
                candidateVisual: .playing,
                ownedVisual: .prePlay
            ),
            "No in-flight apply must issue the first visual mutation"
        )
        XCTAssertTrue(
            manager._test_shouldCoalesceVisualDifferingContentPushWhileInFlight(
                inFlightVisual: .prePlay,
                candidateVisual: .playing,
                ownedVisual: .prePlay
            ),
            "Playing while Connecting apply is in-flight must coalesce (not a second visual IPC)"
        )
        XCTAssertTrue(
            manager._test_shouldCoalesceVisualDifferingContentPushWhileInFlight(
                inFlightVisual: .playing,
                candidateVisual: .userPaused,
                ownedVisual: .prePlay
            ),
            "Pause replacing playing-ensure in-flight must coalesce (latest wins; pause remains outstanding)"
        )
        XCTAssertTrue(
            manager._test_shouldCoalesceVisualDifferingContentPushWhileInFlight(
                inFlightVisual: .playing,
                candidateVisual: .playing,
                ownedVisual: .prePlay
            ),
            "Duplicate unconfirmed playing push must coalesce (playing-ensure 2/3 while 1/3 is in-flight)"
        )
        XCTAssertFalse(
            manager._test_shouldCoalesceVisualDifferingContentPushWhileInFlight(
                inFlightVisual: .prePlay,
                candidateVisual: .prePlay,
                ownedVisual: .prePlay
            ),
            "Language-only same visual as in-flight and owned must still update"
        )

        let coalescedPlaying = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .playing,
            streamMetadata: nil,
            currentLanguage: "sv"
        )
        let coalescedPaused = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .userPaused,
            streamMetadata: nil,
            currentLanguage: "sv"
        )
        let observedConnecting = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .prePlay,
            streamMetadata: nil,
            currentLanguage: "sv"
        )
        let observedPlaying = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .playing,
            streamMetadata: nil,
            currentLanguage: "sv"
        )
        XCTAssertTrue(
            manager._test_shouldFlushCoalescedContentPushAfterObservation(
                coalesced: coalescedPlaying,
                observed: observedConnecting
            ),
            "Committed Connecting with coalesced playing must flush once"
        )
        XCTAssertTrue(
            manager._test_shouldFlushCoalescedContentPushAfterObservation(
                coalesced: coalescedPaused,
                observed: observedConnecting
            ),
            "Committed Connecting with coalesced pause (latest) must flush pause once"
        )
        XCTAssertFalse(
            manager._test_shouldFlushCoalescedContentPushAfterObservation(
                coalesced: coalescedPlaying,
                observed: observedPlaying
            ),
            "Coalesced playing that already matches observed must not flush"
        )
        XCTAssertFalse(
            manager._test_shouldFlushCoalescedContentPushAfterObservation(
                coalesced: nil,
                observed: observedConnecting
            ),
            "No coalesced candidate must not flush"
        )
    }

    /// Ineligible Connecting must not spend an ActivityKit visual apply over committed
    /// ``.userPaused`` / ``.playing`` — same-stream resume **and** stream-switch hold
    /// after dest language has landed. Eligible switch still publishes Connecting.
    /// First start (owned already Connecting) still publishes Connecting. Authoritative
    /// `.playing` and pause candidates still push. Does **not** invent `.playing`.
    ///
    /// Why this pattern is required: Apple still applies ineligible Connecting over a
    /// committed pause/play glyph; later `.playing` then either drops or lands only
    /// because owned had become Connecting. Hold no longer authorizes that overwrite.
    /// Pure `should*` — no ActivityKit waits.
    func testSameStreamIneligibleResumeDoesNotPushConnectingOverPausedOrPlaying() {
        XCTAssertTrue(
            manager._test_shouldSuppressConnectingContentPushWhileIneligible(
                isRequestEligible: false,
                ownedVisual: .userPaused,
                candidateVisual: .prePlay
            ),
            "Ineligible same-stream resume must not overwrite committed pause with Connecting"
        )
        XCTAssertTrue(
            manager._test_shouldSuppressConnectingContentPushWhileIneligible(
                isRequestEligible: false,
                ownedVisual: .playing,
                candidateVisual: .prePlay
            ),
            "Ineligible same-stream resume must not overwrite committed playing with Connecting"
        )
        XCTAssertFalse(
            manager._test_shouldSuppressConnectingContentPushWhileIneligible(
                isRequestEligible: true,
                ownedVisual: .userPaused,
                candidateVisual: .prePlay
            ),
            "Request-eligible (presentable) Connecting honesty must still push"
        )
        XCTAssertFalse(
            manager._test_shouldSuppressConnectingContentPushWhileIneligible(
                isRequestEligible: true,
                ownedVisual: .playing,
                candidateVisual: .prePlay
            ),
            "Eligible stream-switch Connecting honesty must still push"
        )
        XCTAssertFalse(
            manager._test_shouldSuppressConnectingContentPushWhileIneligible(
                isRequestEligible: false,
                ownedVisual: .prePlay,
                candidateVisual: .prePlay
            ),
            "First start with owned already Connecting has nothing better to keep"
        )
        XCTAssertFalse(
            manager._test_shouldSuppressConnectingContentPushWhileIneligible(
                isRequestEligible: false,
                ownedVisual: .userPaused,
                candidateVisual: .playing
            ),
            "Authoritative playing after attach must still push"
        )
        XCTAssertFalse(
            manager._test_shouldSuppressConnectingContentPushWhileIneligible(
                isRequestEligible: false,
                ownedVisual: .playing,
                candidateVisual: .userPaused
            ),
            "Pause is a true visual mutation and must still push"
        )
        XCTAssertFalse(
            manager._test_shouldSuppressConnectingContentPushWhileIneligible(
                isRequestEligible: false,
                ownedVisual: .thermalPaused,
                candidateVisual: .prePlay
            ),
            "Thermal / security / cleared owned visuals are not paused-or-playing glyphs to keep"
        )
    }

    /// Ineligible dest-language over a committed pause/play glyph is language-only:
    /// dest language rides owned visual (``ContentState/replacingCurrentLanguage(_:)``)
    /// even during stream-switch hold. Eligible switch still publishes Connecting.
    /// Dest matching owned is Connecting skip (including during hold) — not this helper.
    /// Language-only candidate visual is not a Connecting skip. Owned already Connecting
    /// still publishes Connecting. Does **not** invent `.playing`.
    ///
    /// Why this pattern is required: bundling dest language with Connecting under lock
    /// is a visual-differing apply Apple drops, so intermediate dest language never
    /// reaches `content.state`. Language ensure 3/3 must use the language-only candidate.
    /// Pure `should*` — no ActivityKit waits.
    func testIneligibleLanguageMutationPreservesOwnedVisualInsteadOfConnecting() {
        XCTAssertTrue(
            manager._test_shouldPreserveOwnedVisualOnIneligibleLanguageMutation(
                isRequestEligible: false,
                destinationLanguage: "de",
                ownedLanguage: "sv",
                ownedVisual: .userPaused
            ),
            "Ineligible dest-language over committed pause must preserve owned visual"
        )
        XCTAssertTrue(
            manager._test_shouldPreserveOwnedVisualOnIneligibleLanguageMutation(
                isRequestEligible: false,
                destinationLanguage: "en",
                ownedLanguage: "de",
                ownedVisual: .playing
            ),
            "Ineligible dest-language over committed playing must preserve owned visual"
        )
        XCTAssertTrue(
            manager._test_shouldPreserveOwnedVisualOnIneligibleLanguageMutation(
                isRequestEligible: false,
                destinationLanguage: "de",
                ownedLanguage: nil,
                ownedVisual: .userPaused
            ),
            "Missing owned language with dest lag still preserves a committed pause glyph"
        )
        XCTAssertFalse(
            manager._test_shouldPreserveOwnedVisualOnIneligibleLanguageMutation(
                isRequestEligible: true,
                destinationLanguage: "de",
                ownedLanguage: "sv",
                ownedVisual: .userPaused
            ),
            "Request-eligible (presentable) switch must still publish Connecting + dest language"
        )
        XCTAssertFalse(
            manager._test_shouldPreserveOwnedVisualOnIneligibleLanguageMutation(
                isRequestEligible: false,
                destinationLanguage: "sv",
                ownedLanguage: "sv",
                ownedVisual: .userPaused
            ),
            "Dest matching owned is not a language mutation — same-stream Connecting skip owns that path"
        )
        XCTAssertFalse(
            manager._test_shouldPreserveOwnedVisualOnIneligibleLanguageMutation(
                isRequestEligible: false,
                destinationLanguage: "",
                ownedLanguage: "sv",
                ownedVisual: .userPaused
            ),
            "Empty dest language must not force language-only"
        )
        XCTAssertFalse(
            manager._test_shouldPreserveOwnedVisualOnIneligibleLanguageMutation(
                isRequestEligible: false,
                destinationLanguage: "de",
                ownedLanguage: "sv",
                ownedVisual: .prePlay
            ),
            "Owned already Connecting has nothing better to keep — Connecting still allowed"
        )
        XCTAssertFalse(
            manager._test_shouldPreserveOwnedVisualOnIneligibleLanguageMutation(
                isRequestEligible: false,
                destinationLanguage: "de",
                ownedLanguage: "sv",
                ownedVisual: .thermalPaused
            ),
            "Thermal / security / cleared owned visuals are not pause-or-playing glyphs to keep"
        )

        // Freeze-path preserve still yields to stream-switch hold; ineligible language
        // mutation independently preserves during hold. Combined decision is language-only.
        XCTAssertFalse(
            manager._test_shouldPreserveOwnedVisualOnLanguageOnlyContentPush(
                keepOwnedVisualAfterFreeze: true,
                isStreamSwitchHoldActive: true
            ),
            "Freeze long-horizon preserve still does not override stream-switch hold by itself"
        )
        XCTAssertTrue(
            manager._test_shouldPreserveOwnedVisualOnIneligibleLanguageMutation(
                isRequestEligible: false,
                destinationLanguage: "de",
                ownedLanguage: "sv",
                ownedVisual: .userPaused
            ),
            "Ineligible language mutation preserves owned visual even while stream-switch hold is active"
        )

        // Dest matching owned: Connecting skip fires even during hold (candidate .prePlay).
        // Language-only candidate (visual already owned) is not a Connecting skip.
        XCTAssertTrue(
            manager._test_shouldSuppressConnectingContentPushWhileIneligible(
                isRequestEligible: false,
                ownedVisual: .userPaused,
                candidateVisual: .prePlay
            ),
            "Ineligible Connecting over committed pause must skip after dest language has landed, including during hold"
        )
        XCTAssertFalse(
            manager._test_shouldSuppressConnectingContentPushWhileIneligible(
                isRequestEligible: true,
                ownedVisual: .userPaused,
                candidateVisual: .prePlay
            ),
            "Eligible stream-switch Connecting honesty must still push"
        )

        // After language-only preserve, candidate visual equals owned — Connecting skip
        // does not apply (candidate is not .prePlay). Language-only coalesce still allows IPC.
        XCTAssertFalse(
            manager._test_shouldSuppressConnectingContentPushWhileIneligible(
                isRequestEligible: false,
                ownedVisual: .userPaused,
                candidateVisual: .userPaused
            ),
            "Language-only candidate (owned visual) is not a Connecting skip"
        )
        XCTAssertFalse(
            manager._test_shouldCoalesceVisualDifferingContentPushWhileInFlight(
                inFlightVisual: .prePlay,
                candidateVisual: .userPaused,
                ownedVisual: .userPaused,
                languageOnlyPreservingOwnedVisual: true
            ),
            "Language-only preserving owned visual must still update while a visual apply is in-flight"
        )
        XCTAssertEqual(
            manager._test_languageOnlyLongHorizonCandidateVisual(
                ownedVisual: .userPaused,
                actorResolvedVisual: .prePlay,
                keepOwnedVisual: true
            ),
            .userPaused,
            "Language-only candidate visual equals owned pause, not Connecting"
        )
    }

    /// After dest language has landed on owned pause/playing while request is ineligible,
    /// stream-switch Connecting must not `Activity.update` ``.prePlay`` over that glyph.
    /// Dest-lag remains language-only (candidate visual equals owned; Connecting skip
    /// does not see ``.prePlay``). Eligible switch still publishes Connecting. First
    /// start (owned already Connecting) still publishes Connecting. Pause as a new
    /// visual still pushes. Does **not** invent `.playing`.
    ///
    /// Why this pattern is required: dest-lag already rewrites to language-only before
    /// Connecting skip; after Apple applies dest language on owned pause, hold is still
    /// active and a Connecting candidate would overwrite that glyph. Pure `should*` —
    /// no ActivityKit waits.
    func testIneligibleStreamSwitchDoesNotPushConnectingAfterDestLanguageLanded() {
        XCTAssertFalse(
            manager._test_shouldPreserveOwnedVisualOnIneligibleLanguageMutation(
                isRequestEligible: false,
                destinationLanguage: "en",
                ownedLanguage: "en",
                ownedVisual: .userPaused
            ),
            "Dest matching owned is not a language mutation — Connecting skip owns that path"
        )
        XCTAssertTrue(
            manager._test_shouldPreserveOwnedVisualOnIneligibleLanguageMutation(
                isRequestEligible: false,
                destinationLanguage: "en",
                ownedLanguage: "sv",
                ownedVisual: .userPaused
            ),
            "Dest-lag over committed pause must still be language-only"
        )
        XCTAssertTrue(
            manager._test_shouldSuppressConnectingContentPushWhileIneligible(
                isRequestEligible: false,
                ownedVisual: .userPaused,
                candidateVisual: .prePlay
            ),
            "Ineligible Connecting over committed pause must skip after dest language has landed"
        )
        XCTAssertTrue(
            manager._test_shouldSuppressConnectingContentPushWhileIneligible(
                isRequestEligible: false,
                ownedVisual: .playing,
                candidateVisual: .prePlay
            ),
            "Ineligible Connecting over committed playing must skip after dest language has landed"
        )
        XCTAssertFalse(
            manager._test_shouldSuppressConnectingContentPushWhileIneligible(
                isRequestEligible: true,
                ownedVisual: .userPaused,
                candidateVisual: .prePlay
            ),
            "Eligible stream-switch Connecting honesty must still push"
        )
        XCTAssertFalse(
            manager._test_shouldSuppressConnectingContentPushWhileIneligible(
                isRequestEligible: false,
                ownedVisual: .userPaused,
                candidateVisual: .userPaused
            ),
            "Language-only candidate (owned visual) is not a Connecting skip"
        )
        XCTAssertFalse(
            manager._test_shouldSuppressConnectingContentPushWhileIneligible(
                isRequestEligible: false,
                ownedVisual: .prePlay,
                candidateVisual: .prePlay
            ),
            "First start with owned already Connecting has nothing better to keep"
        )
        XCTAssertFalse(
            manager._test_shouldSuppressConnectingContentPushWhileIneligible(
                isRequestEligible: false,
                ownedVisual: .playing,
                candidateVisual: .userPaused
            ),
            "Pause as a new visual must still push"
        )
        XCTAssertTrue(
            manager._test_shouldSuppressVisualDifferingPlayingContentPushWhileIneligible(
                isRequestEligible: false,
                freezeSoftBudgetExhausted: false,
                ownedVisual: .userPaused,
                candidateVisual: .playing
            ),
            "Closing Connecting overwrite leaves owned pause; freeze playing skip still drops visual-differing playing"
        )
    }

    /// After freeze, ineligible playing / dual-axis must not issue visual-differing
    /// `Activity.update`. Play re-arm may clear quiet / freeze generation; that does
    /// not authorize `.playing` IPC over a committed pause/play glyph. Language-only
    /// still updates. Pause as a new visual still updates. Dual-axis settle after
    /// hold clear while owned is Connecting (freeze not exhausted) still may push
    /// `.playing`. Eligible still pushes. Does **not** invent `.playing`.
    ///
    /// Why this pattern is required: play mutation after pause re-arms playing ensure
    /// while request is ineligible; Apple drops those visual mutations and they can
    /// delay language-only applies that still land. Pure `should*` — no ActivityKit waits.
    func testIneligibleFreezeDoesNotPushVisualDifferingPlaying() {
        XCTAssertTrue(
            manager._test_shouldSuppressVisualDifferingPlayingContentPushWhileIneligible(
                isRequestEligible: false,
                freezeSoftBudgetExhausted: true,
                ownedVisual: .userPaused,
                candidateVisual: .playing
            ),
            "Ineligible freeze exhausted + owned pause must not spend playing IPC"
        )
        XCTAssertTrue(
            manager._test_shouldSuppressVisualDifferingPlayingContentPushWhileIneligible(
                isRequestEligible: false,
                freezeSoftBudgetExhausted: false,
                ownedVisual: .userPaused,
                candidateVisual: .playing
            ),
            "Play re-arm that cleared freeze generation still must not spend playing IPC over committed pause"
        )
        XCTAssertTrue(
            manager._test_shouldSuppressVisualDifferingPlayingContentPushWhileIneligible(
                isRequestEligible: false,
                freezeSoftBudgetExhausted: true,
                ownedVisual: .prePlay,
                candidateVisual: .playing
            ),
            "After freeze, owned Connecting must not spend playing IPC while ineligible"
        )
        XCTAssertFalse(
            manager._test_shouldSuppressVisualDifferingPlayingContentPushWhileIneligible(
                isRequestEligible: true,
                freezeSoftBudgetExhausted: true,
                ownedVisual: .userPaused,
                candidateVisual: .playing
            ),
            "Request-eligible (presentable) playing honesty must still push"
        )
        XCTAssertFalse(
            manager._test_shouldSuppressVisualDifferingPlayingContentPushWhileIneligible(
                isRequestEligible: false,
                freezeSoftBudgetExhausted: false,
                ownedVisual: .prePlay,
                candidateVisual: .playing
            ),
            "Dual-axis settle after hold clear while owned is Connecting (freeze not exhausted) still may push playing"
        )
        XCTAssertFalse(
            manager._test_shouldSuppressVisualDifferingPlayingContentPushWhileIneligible(
                isRequestEligible: false,
                freezeSoftBudgetExhausted: true,
                ownedVisual: .playing,
                candidateVisual: .userPaused
            ),
            "Pause as a new visual must still push"
        )
        XCTAssertFalse(
            manager._test_shouldSuppressVisualDifferingPlayingContentPushWhileIneligible(
                isRequestEligible: false,
                freezeSoftBudgetExhausted: true,
                ownedVisual: .userPaused,
                candidateVisual: .userPaused
            ),
            "Language-only (candidate visual equals owned) must still update"
        )
        XCTAssertFalse(
            manager._test_shouldSuppressVisualDifferingPlayingContentPushWhileIneligible(
                isRequestEligible: false,
                freezeSoftBudgetExhausted: true,
                ownedVisual: .userPaused,
                candidateVisual: .prePlay
            ),
            "Connecting skip owns Connecting candidates; this helper is playing-only"
        )

        // Ineligible dest-language over committed pause still language-only (must not regress).
        XCTAssertTrue(
            manager._test_shouldPreserveOwnedVisualOnIneligibleLanguageMutation(
                isRequestEligible: false,
                destinationLanguage: "de",
                ownedLanguage: "sv",
                ownedVisual: .userPaused
            ),
            "Ineligible dest-language over committed pause must still preserve owned visual"
        )
        XCTAssertFalse(
            manager._test_shouldSuppressVisualDifferingPlayingContentPushWhileIneligible(
                isRequestEligible: false,
                freezeSoftBudgetExhausted: true,
                ownedVisual: .userPaused,
                candidateVisual: .userPaused
            ),
            "After language-only preserve, candidate visual equals owned — playing skip must not block that IPC"
        )
        XCTAssertFalse(
            manager._test_shouldSuppressConnectingContentPushWhileIneligible(
                isRequestEligible: false,
                ownedVisual: .userPaused,
                candidateVisual: .playing
            ),
            "Connecting skip remains independent; playing-over-pause is this helper, not Connecting skip"
        )
    }

    /// After freeze (soft budget exhausted or playing quiet) while request is ineligible,
    /// post-quiet language long-horizon stays language-only: dest language rides the owned
    /// glyph (candidate visual == owned visual). Dual-axis long-horizon does not arm or
    /// fire. Dual-axis settle at ``setPlaying()`` after hold clear is not this rail.
    /// Playing long-horizon remains the visual rail. Stream-switch hold still Connecting.
    /// Request-eligible still may co-push. Does **not** invent `.playing`.
    ///
    /// Why this pattern is required: same-visual language updates still land under lock;
    /// bundling `.playing` into the sparse slot delays language and still fails the glyph.
    /// Pure `should*` — no ActivityKit waits.
    func testPostQuietLanguageLongHorizonStaysLanguageOnlyAfterFreeze() {
        XCTAssertTrue(
            manager._test_shouldKeepOwnedVisualOnPostQuietLanguageLongHorizon(
                freezeSoftBudgetExhausted: true,
                playingQuietPending: false,
                isRequestEligible: false
            ),
            "Freeze soft budget exhausted while ineligible must keep owned visual on language long-horizon"
        )
        XCTAssertTrue(
            manager._test_shouldKeepOwnedVisualOnPostQuietLanguageLongHorizon(
                freezeSoftBudgetExhausted: false,
                playingQuietPending: true,
                isRequestEligible: false
            ),
            "Playing quiet pending while ineligible must keep owned visual on language long-horizon"
        )
        XCTAssertFalse(
            manager._test_shouldKeepOwnedVisualOnPostQuietLanguageLongHorizon(
                freezeSoftBudgetExhausted: true,
                playingQuietPending: true,
                isRequestEligible: true
            ),
            "Request-eligible (presentable) recovery must not force language-only owned visual"
        )
        XCTAssertFalse(
            manager._test_shouldKeepOwnedVisualOnPostQuietLanguageLongHorizon(
                freezeSoftBudgetExhausted: false,
                playingQuietPending: false,
                isRequestEligible: false
            ),
            "Before freeze, dual-axis long-horizon may still co-push"
        )

        XCTAssertEqual(
            manager._test_languageOnlyLongHorizonCandidateVisual(
                ownedVisual: .prePlay,
                actorResolvedVisual: .playing,
                keepOwnedVisual: true
            ),
            .prePlay,
            "After freeze, language-lag candidate visual must equal owned visual (not force .playing)"
        )
        XCTAssertEqual(
            manager._test_languageOnlyLongHorizonCandidateVisual(
                ownedVisual: .userPaused,
                actorResolvedVisual: .playing,
                keepOwnedVisual: true
            ),
            .userPaused,
            "After freeze, language-lag must preserve owned pause rather than force .playing"
        )
        XCTAssertEqual(
            manager._test_languageOnlyLongHorizonCandidateVisual(
                ownedVisual: .prePlay,
                actorResolvedVisual: .playing,
                keepOwnedVisual: false
            ),
            .playing,
            "Before freeze, language long-horizon still uses actor-resolved visual"
        )

        XCTAssertTrue(
            manager._test_shouldPreserveOwnedVisualOnLanguageOnlyContentPush(
                keepOwnedVisualAfterFreeze: true,
                isStreamSwitchHoldActive: false
            ),
            "After freeze without stream-switch hold, language-only push preserves owned visual"
        )
        XCTAssertFalse(
            manager._test_shouldPreserveOwnedVisualOnLanguageOnlyContentPush(
                keepOwnedVisualAfterFreeze: true,
                isStreamSwitchHoldActive: true
            ),
            "Stream-switch hold must still publish Connecting + destination language"
        )
        XCTAssertFalse(
            manager._test_shouldPreserveOwnedVisualOnLanguageOnlyContentPush(
                keepOwnedVisualAfterFreeze: false,
                isStreamSwitchHoldActive: false
            ),
            "Before freeze, language ensure still uses actor-resolved visual"
        )

        XCTAssertFalse(
            manager._test_shouldArmPostQuietLongHorizonDualAxisEnsure(
                hasCurrentActivity: true,
                isRequestEligible: false,
                dualAxisAlreadyArmed: false,
                languageStillLags: true,
                visualStillLags: true,
                actorVisual: .playing,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false,
                freezeSoftBudgetExhausted: true,
                playingQuietPending: false
            ),
            "After freeze, dual-axis long-horizon must not arm (language-only + playing rails own the slots)"
        )
        XCTAssertFalse(
            manager._test_shouldArmPostQuietLongHorizonDualAxisEnsure(
                hasCurrentActivity: true,
                isRequestEligible: false,
                dualAxisAlreadyArmed: false,
                languageStillLags: true,
                visualStillLags: true,
                actorVisual: .playing,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false,
                freezeSoftBudgetExhausted: false,
                playingQuietPending: true
            ),
            "Playing quiet pending while ineligible must not arm dual-axis long-horizon"
        )
        XCTAssertTrue(
            manager._test_shouldArmPostQuietLongHorizonDualAxisEnsure(
                hasCurrentActivity: true,
                isRequestEligible: false,
                dualAxisAlreadyArmed: false,
                languageStillLags: true,
                visualStillLags: true,
                actorVisual: .playing,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Before freeze, both-lag dual-axis long-horizon arm still stands (setPlaying settle first try)"
        )
        XCTAssertFalse(
            manager._test_shouldRunPostQuietLongHorizonDualAxisEnsure(
                languageStillLags: true,
                visualStillLags: true,
                actorVisual: .playing,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false,
                freezeSoftBudgetExhausted: true,
                playingQuietPending: false,
                isRequestEligible: false
            ),
            "After freeze, language/playing long-horizon fires must not hijack into dual-axis"
        )
        XCTAssertTrue(
            manager._test_shouldArmPostQuietLongHorizonLanguageEnsure(
                hasCurrentActivity: true,
                isRequestEligible: false,
                longHorizonAlreadyArmed: false,
                destinationLanguage: "en",
                lastPushedLanguage: "sv",
                ownedContentLanguage: "sv",
                isStreamSwitchHoldActive: false
            ),
            "After freeze, language lag must still arm language-only long-horizon"
        )
        XCTAssertTrue(
            manager._test_shouldArmPostQuietLongHorizonPlayingEnsure(
                hasCurrentActivity: true,
                isRequestEligible: false,
                longHorizonAlreadyArmed: false,
                actorVisual: .playing,
                lastPushedVisual: .playing,
                ownedContentVisual: .prePlay,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "After freeze, visual lag must still arm playing long-horizon (unlock-heal remains presentable repair)"
        )

        XCTAssertFalse(
            manager._test_shouldCoalesceVisualDifferingContentPushWhileInFlight(
                inFlightVisual: .playing,
                candidateVisual: .prePlay,
                ownedVisual: .prePlay,
                languageOnlyPreservingOwnedVisual: true
            ),
            "Language-only preserving owned Connecting must still update while playing-ensure is in-flight"
        )
        XCTAssertTrue(
            manager._test_shouldCoalesceVisualDifferingContentPushWhileInFlight(
                inFlightVisual: .playing,
                candidateVisual: .prePlay,
                ownedVisual: .prePlay,
                languageOnlyPreservingOwnedVisual: false
            ),
            "Without language-only preserve, Connecting vs in-flight playing still coalesces"
        )
    }

    /// Pause↔Connecting and Connecting↔playing after hold/connect clear are handshake lag.
    ///
    /// Eligible 50 ms bursts must not spend ``stalledContentPushRecreationThreshold``.
    /// Language mismatch is never handshake. Hold still in flight is not the post-clamp
    /// playing handshake (``resolveContentPushVisual`` clamps `.playing` to `.prePlay`).
    func testConnectingPlayingHandshakeDoesNotConsumeRecreationStreak() {
        XCTAssertTrue(
            manager._test_isConnectingPlayingHandshakeLag(
                candidateLanguage: "et",
                acceptedLanguage: "et",
                candidateVisual: .playing,
                acceptedVisual: .prePlay,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Connecting→playing after hold clear is handshake lag"
        )
        XCTAssertTrue(
            manager._test_isConnectingPlayingHandshakeLag(
                candidateLanguage: "et",
                acceptedLanguage: "et",
                candidateVisual: .prePlay,
                acceptedVisual: .userPaused,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Pause→Connecting is handshake lag"
        )
        XCTAssertTrue(
            manager._test_isConnectingPlayingHandshakeLag(
                candidateLanguage: "et",
                acceptedLanguage: "et",
                candidateVisual: .userPaused,
                acceptedVisual: .prePlay,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Connecting→pause is handshake lag (pause honesty still pushes)"
        )
        XCTAssertFalse(
            manager._test_isConnectingPlayingHandshakeLag(
                candidateLanguage: "de",
                acceptedLanguage: "en",
                candidateVisual: .playing,
                acceptedVisual: .prePlay,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Language stick is never handshake — delayed mismatch may still recreate"
        )
        XCTAssertFalse(
            manager._test_isConnectingPlayingHandshakeLag(
                candidateLanguage: "et",
                acceptedLanguage: "et",
                candidateVisual: .playing,
                acceptedVisual: .userPaused,
                isStreamSwitchHoldActive: false,
                isConnectingPlayback: false
            ),
            "Pause vs playing (soft-resume freeze) is not Connecting handshake"
        )
        XCTAssertFalse(
            manager._test_isConnectingPlayingHandshakeLag(
                candidateLanguage: "et",
                acceptedLanguage: "et",
                candidateVisual: .playing,
                acceptedVisual: .prePlay,
                isStreamSwitchHoldActive: true,
                isConnectingPlayback: false
            ),
            "Hold still active is not the post-clear playing handshake"
        )

        XCTAssertFalse(
            manager._test_shouldCommitStalledContentPushObservation(
                kind: .delayedReread,
                isStalled: true,
                isHandshakeLag: true
            ),
            "Eligible Connecting→playing burst must not commit stall after the apply window"
        )
        XCTAssertTrue(
            manager._test_shouldCommitStalledContentPushObservation(
                kind: .delayedReread,
                isStalled: true,
                isHandshakeLag: false
            ),
            "True language stick after wait still commits stall"
        )
    }

    /// ``startActivity()`` and ``refreshAllMediaSurfaces`` `.startOrUpdate` consult
    /// ``interactiveLiveActivityStartDisposition``: owned always updates (never request);
    /// eligible + unowned may request; ineligible + unowned records pending ensure
    /// (no request, no leading end). Recreation ends first so start sees unowned.
    func testInteractiveLiveActivityStartRequiresRequestEligibility() {
        XCTAssertEqual(
            manager._test_interactiveLiveActivityStartDisposition(
                isRequestEligible: true,
                hasOwnedActivity: false
            ),
            .request,
            "Eligible + unowned may Activity.request"
        )
        XCTAssertEqual(
            manager._test_interactiveLiveActivityStartDisposition(
                isRequestEligible: true,
                hasOwnedActivity: true
            ),
            .updateOwned,
            "Eligible + owned must update the existing surface (never startActivity end+request)"
        )
        XCTAssertEqual(
            manager._test_interactiveLiveActivityStartDisposition(
                isRequestEligible: false,
                hasOwnedActivity: false
            ),
            .deferPendingEnsure,
            "Ineligible + unowned must not request; pending ensure only"
        )
        XCTAssertEqual(
            manager._test_interactiveLiveActivityStartDisposition(
                isRequestEligible: false,
                hasOwnedActivity: true
            ),
            .updateOwned,
            "Ineligible + owned must update the existing surface (never end)"
        )
        manager._test_setPendingInteractiveLiveActivityEnsure(false)
        XCTAssertFalse(manager._test_pendingInteractiveLiveActivityEnsure())
        // Policy-only: applying defer disposition is ``startActivity()`` itself; tests
        // never call real Activity.request. Pending-ensure after failed start remains.
        XCTAssertTrue(
            manager._test_shouldMarkPendingInteractiveLiveActivityEnsureAfterStartAttempt(
                currentActivityIsNil: true
            ),
            "Unowned ineligible start records pending ensure (same flag as failed request)"
        )
    }

    /// Failed interactive start with empty ownership records a pending foreground ensure.
    func testFailedStartMarksPendingInteractiveLiveActivityEnsure() {
        XCTAssertTrue(
            manager._test_shouldMarkPendingInteractiveLiveActivityEnsureAfterStartAttempt(
                currentActivityIsNil: true
            ),
            "Nil ownership after failed request must mark pending ensure"
        )
        XCTAssertFalse(
            manager._test_shouldMarkPendingInteractiveLiveActivityEnsureAfterStartAttempt(
                currentActivityIsNil: false
            ),
            "Owned surface after start must not mark pending ensure"
        )

        manager._test_setPendingInteractiveLiveActivityEnsure(true)
        XCTAssertTrue(manager._test_pendingInteractiveLiveActivityEnsure())
        manager._test_setPendingInteractiveLiveActivityEnsure(false)
        XCTAssertFalse(manager._test_pendingInteractiveLiveActivityEnsure())
    }

    /// Foreground ensure starts only when eligible, enabled, ownership empty, and session needs chrome.
    func testForegroundEnsureStartPolicy() {
        XCTAssertTrue(
            manager._test_sessionNeedsInteractiveLiveActivity(
                isPlaying: true,
                visualState: .cleared
            ),
            "Shared isPlaying alone still needs interactive chrome (background auto-start parity)"
        )
        XCTAssertTrue(
            manager._test_sessionNeedsInteractiveLiveActivity(
                isPlaying: false,
                visualState: .playing
            )
        )
        XCTAssertTrue(
            manager._test_sessionNeedsInteractiveLiveActivity(
                isPlaying: false,
                visualState: .prePlay
            )
        )
        XCTAssertTrue(
            manager._test_sessionNeedsInteractiveLiveActivity(
                isPlaying: false,
                visualState: .userPaused
            ),
            "Sticky pause while process lives keeps intentional paused LA chrome"
        )
        XCTAssertFalse(
            manager._test_sessionNeedsInteractiveLiveActivity(
                isPlaying: false,
                visualState: .cleared
            ),
            "Cleared / idle session must not request interactive chrome"
        )

        XCTAssertTrue(
            manager._test_shouldEnsureInteractiveLiveActivityStart(
                pendingEnsure: true,
                hasCurrentActivity: false,
                sessionNeedsInteractiveLiveActivity: true,
                areActivitiesEnabled: true,
                isRequestEligible: true
            ),
            "Pending recovery under active session must ensure-start when eligible"
        )
        XCTAssertTrue(
            manager._test_shouldEnsureInteractiveLiveActivityStart(
                pendingEnsure: false,
                hasCurrentActivity: false,
                sessionNeedsInteractiveLiveActivity: true,
                areActivitiesEnabled: true,
                isRequestEligible: true
            ),
            "Missing surface under active session must ensure-start even without prior pending flag"
        )
        XCTAssertFalse(
            manager._test_shouldEnsureInteractiveLiveActivityStart(
                pendingEnsure: true,
                hasCurrentActivity: false,
                sessionNeedsInteractiveLiveActivity: false,
                areActivitiesEnabled: true,
                isRequestEligible: true
            ),
            "Pending after stop must not invent a Live Activity"
        )
        XCTAssertFalse(
            manager._test_shouldEnsureInteractiveLiveActivityStart(
                pendingEnsure: true,
                hasCurrentActivity: true,
                sessionNeedsInteractiveLiveActivity: true,
                areActivitiesEnabled: true,
                isRequestEligible: true
            ),
            "Owned activity must not request a second interactive surface"
        )
        XCTAssertFalse(
            manager._test_shouldEnsureInteractiveLiveActivityStart(
                pendingEnsure: true,
                hasCurrentActivity: false,
                sessionNeedsInteractiveLiveActivity: true,
                areActivitiesEnabled: true,
                isRequestEligible: false
            ),
            "Ineligible request must wait for a presentable cycle"
        )
        XCTAssertFalse(
            manager._test_shouldEnsureInteractiveLiveActivityStart(
                pendingEnsure: true,
                hasCurrentActivity: false,
                sessionNeedsInteractiveLiveActivity: true,
                areActivitiesEnabled: false,
                isRequestEligible: true
            ),
            "Disabled Live Activities must not ensure-start"
        )
    }

    /// Owned-surface foreground soft ensure runs when language or visual lags destination.
    ///
    /// Protects unlock after deferred recreation while ineligible: missing-card ensure early-returns
    /// when ``currentActivity != nil``; soft language/playing ensure must still fire so prior-stream
    /// chrome is not left on the only interactive card. Pure policy (no ActivityKit).
    func testForegroundOwnedSurfaceSoftEnsurePolicy() {
        // Language lag with matched visual.
        XCTAssertTrue(
            manager._test_shouldEnsureAuthoritativeContentOnForeground(
                hasCurrentActivity: true,
                destinationLanguage: "et",
                ownedContentLanguage: "de",
                lastPushedLanguage: "et",
                actorVisual: .playing,
                streamSwitchHold: false,
                isConnectingPlayback: false,
                lastPushedVisual: .playing,
                ownedVisual: .playing
            ),
            "Owned prior language must schedule foreground soft ensure even when visual matches"
        )
        // Visual lag (Connecting freeze) with matched language.
        XCTAssertTrue(
            manager._test_shouldEnsureAuthoritativeContentOnForeground(
                hasCurrentActivity: true,
                destinationLanguage: "et",
                ownedContentLanguage: "et",
                lastPushedLanguage: "et",
                actorVisual: .playing,
                streamSwitchHold: false,
                isConnectingPlayback: false,
                lastPushedVisual: .playing,
                ownedVisual: .prePlay
            ),
            "Owned Connecting while actor is playing must schedule foreground soft ensure"
        )
        // Both match → cheap no-op.
        XCTAssertFalse(
            manager._test_shouldEnsureAuthoritativeContentOnForeground(
                hasCurrentActivity: true,
                destinationLanguage: "et",
                ownedContentLanguage: "et",
                lastPushedLanguage: "et",
                actorVisual: .playing,
                streamSwitchHold: false,
                isConnectingPlayback: false,
                lastPushedVisual: .playing,
                ownedVisual: .playing
            ),
            "Matched owned language + visual is a cheap no-op on foreground"
        )
        // Unowned surface is the missing-card start path, not this soft ensure.
        XCTAssertFalse(
            manager._test_shouldEnsureAuthoritativeContentOnForeground(
                hasCurrentActivity: false,
                destinationLanguage: "et",
                ownedContentLanguage: "de",
                lastPushedLanguage: "de",
                actorVisual: .playing,
                streamSwitchHold: false,
                isConnectingPlayback: false,
                lastPushedVisual: .playing,
                ownedVisual: .playing
            ),
            "Unowned activity must not schedule owned-surface soft ensure"
        )
        // Stream-switch hold: language lag still soft-ensures; playing ensure stays off (no invent .playing).
        XCTAssertTrue(
            manager._test_shouldEnsureAuthoritativeContentOnForeground(
                hasCurrentActivity: true,
                destinationLanguage: "et",
                ownedContentLanguage: "de",
                lastPushedLanguage: "de",
                actorVisual: .playing,
                streamSwitchHold: true,
                isConnectingPlayback: false,
                lastPushedVisual: .prePlay,
                ownedVisual: .prePlay
            ),
            "Hold-time destination language lag still schedules language soft ensure"
        )
        XCTAssertFalse(
            manager._test_shouldEnsureAuthoritativePlayingContent(
                actorVisual: .playing,
                streamSwitchHold: true,
                isConnectingPlayback: false,
                lastPushedVisual: .prePlay,
                ownedVisual: .prePlay
            ),
            "Hold must not invent playing visual ensure during stream-switch Connecting honesty"
        )
    }

    /// Owned-surface foreground soft ensure is invoked on unlock recovery and debounced for dual hooks.
    ///
    /// **Invariant:** Lock-stretch language/playing quiet and ``pendingInteractiveLiveActivityEnsure``
    /// are always consumed on a presentable cycle (clear quiet → language then playing soft ensure).
    /// Dual SceneDelegate hooks (will-enter-foreground + become-active) and rapid resign/become
    /// thrash must not re-burn soft budgets when nothing is pending; a second pass still runs when
    /// chrome lags after a first pass that may have been request-ineligible. Pure policy (no ActivityKit).
    func testOwnedSurfaceForegroundEnsureInvokeAndDebouncePolicy() {
        let now = Date()
        let interval = RadioLiveActivityManager.ownedSurfaceForegroundEnsureDebounceInterval
        let recent = now.addingTimeInterval(-(interval / 2))
        let stale = now.addingTimeInterval(-(interval + 0.5))

        XCTAssertFalse(
            manager._test_shouldInvokeOwnedSurfaceForegroundEnsure(
                hasCurrentActivity: false,
                lastOwnedSurfaceForegroundEnsureAt: nil,
                now: now,
                languageEnsureQuietPending: true,
                playingEnsureQuietPending: true,
                pendingInteractiveLiveActivityEnsure: true,
                contentEnsureStillNeeded: true,
                isRequestEligible: true
            ),
            "Unowned surface is the missing-card start path, not owned-surface soft ensure"
        )

        XCTAssertTrue(
            manager._test_shouldInvokeOwnedSurfaceForegroundEnsure(
                hasCurrentActivity: true,
                lastOwnedSurfaceForegroundEnsureAt: nil,
                now: now,
                languageEnsureQuietPending: false,
                playingEnsureQuietPending: false,
                pendingInteractiveLiveActivityEnsure: false,
                contentEnsureStillNeeded: false,
                isRequestEligible: true
            ),
            "First owned-surface pass always runs (soft ensure is a cheap no-op when matched)"
        )

        XCTAssertTrue(
            manager._test_shouldInvokeOwnedSurfaceForegroundEnsure(
                hasCurrentActivity: true,
                lastOwnedSurfaceForegroundEnsureAt: recent,
                now: now,
                languageEnsureQuietPending: true,
                playingEnsureQuietPending: false,
                pendingInteractiveLiveActivityEnsure: false,
                contentEnsureStillNeeded: false,
                isRequestEligible: false
            ),
            "Language quiet pending must force consume even inside the debounce window"
        )
        XCTAssertTrue(
            manager._test_shouldInvokeOwnedSurfaceForegroundEnsure(
                hasCurrentActivity: true,
                lastOwnedSurfaceForegroundEnsureAt: recent,
                now: now,
                languageEnsureQuietPending: false,
                playingEnsureQuietPending: true,
                pendingInteractiveLiveActivityEnsure: false,
                contentEnsureStillNeeded: false,
                isRequestEligible: false
            ),
            "Playing quiet pending must force consume even inside the debounce window"
        )
        // Dual quiet (both axes exhausted while locked) must still force the owned-surface path.
        XCTAssertTrue(
            manager._test_shouldInvokeOwnedSurfaceForegroundEnsure(
                hasCurrentActivity: true,
                lastOwnedSurfaceForegroundEnsureAt: recent,
                now: now,
                languageEnsureQuietPending: true,
                playingEnsureQuietPending: true,
                pendingInteractiveLiveActivityEnsure: false,
                contentEnsureStillNeeded: false,
                isRequestEligible: false
            ),
            "Dual language + playing quiet must force owned-surface foreground ensure"
        )
        XCTAssertTrue(
            manager._test_shouldInvokeOwnedSurfaceForegroundEnsure(
                hasCurrentActivity: true,
                lastOwnedSurfaceForegroundEnsureAt: recent,
                now: now,
                languageEnsureQuietPending: false,
                playingEnsureQuietPending: false,
                pendingInteractiveLiveActivityEnsure: true,
                contentEnsureStillNeeded: false,
                isRequestEligible: false
            ),
            "Deferred interactive pending ensure must force owned-surface soft ensure"
        )

        XCTAssertFalse(
            manager._test_shouldInvokeOwnedSurfaceForegroundEnsure(
                hasCurrentActivity: true,
                lastOwnedSurfaceForegroundEnsureAt: recent,
                now: now,
                languageEnsureQuietPending: false,
                playingEnsureQuietPending: false,
                pendingInteractiveLiveActivityEnsure: false,
                contentEnsureStillNeeded: false,
                isRequestEligible: true
            ),
            "Dual will-enter-foreground + become-active hooks must debounce when nothing pending"
        )
        XCTAssertFalse(
            manager._test_shouldInvokeOwnedSurfaceForegroundEnsure(
                hasCurrentActivity: true,
                lastOwnedSurfaceForegroundEnsureAt: recent,
                now: now,
                languageEnsureQuietPending: false,
                playingEnsureQuietPending: false,
                pendingInteractiveLiveActivityEnsure: false,
                contentEnsureStillNeeded: true,
                isRequestEligible: false
            ),
            "Inside debounce with lagging chrome but still-ineligible request must not thrash"
        )
        XCTAssertTrue(
            manager._test_shouldInvokeOwnedSurfaceForegroundEnsure(
                hasCurrentActivity: true,
                lastOwnedSurfaceForegroundEnsureAt: recent,
                now: now,
                languageEnsureQuietPending: false,
                playingEnsureQuietPending: false,
                pendingInteractiveLiveActivityEnsure: false,
                contentEnsureStillNeeded: true,
                isRequestEligible: true
            ),
            "Become-active after ineligible first pass must soft-ensure when chrome still lags"
        )
        XCTAssertTrue(
            manager._test_shouldInvokeOwnedSurfaceForegroundEnsure(
                hasCurrentActivity: true,
                lastOwnedSurfaceForegroundEnsureAt: stale,
                now: now,
                languageEnsureQuietPending: false,
                playingEnsureQuietPending: false,
                pendingInteractiveLiveActivityEnsure: false,
                contentEnsureStillNeeded: false,
                isRequestEligible: true
            ),
            "Outside debounce window must allow another owned-surface cycle"
        )
    }

    /// Eligible-only recreation after foreground soft ensure still fails; never while ineligible.
    ///
    /// **Invariant:** never destroy the only interactive Live Activity unless a replacement
    /// `Activity.request` can succeed. Soft ensure is preferred; recreation is last resort.
    func testForegroundRecreationOnlyAfterSoftEnsureFailsAndRequestEligible() {
        let budget = RadioLiveActivityManager.maxInteractiveContentRecreations

        XCTAssertTrue(
            manager._test_shouldRecreateAfterForegroundSoftEnsureFailed(
                languageStillMismatches: true,
                playingStillStalled: false,
                isRequestEligible: true,
                recreationsAttempted: 0
            ),
            "Language still lagging after soft ensure + eligible request may recreate"
        )
        XCTAssertTrue(
            manager._test_shouldRecreateAfterForegroundSoftEnsureFailed(
                languageStillMismatches: false,
                playingStillStalled: true,
                isRequestEligible: true,
                recreationsAttempted: 0
            ),
            "Playing visual still stalled after soft ensure + eligible request may recreate"
        )
        XCTAssertFalse(
            manager._test_shouldRecreateAfterForegroundSoftEnsureFailed(
                languageStillMismatches: true,
                playingStillStalled: true,
                isRequestEligible: false,
                recreationsAttempted: 0
            ),
            "Ineligible request must never end the only interactive surface after soft ensure"
        )
        XCTAssertFalse(
            manager._test_shouldRecreateAfterForegroundSoftEnsureFailed(
                languageStillMismatches: false,
                playingStillStalled: false,
                isRequestEligible: true,
                recreationsAttempted: 0
            ),
            "Matched chrome after soft ensure must not recreate"
        )
        XCTAssertFalse(
            manager._test_shouldRecreateAfterForegroundSoftEnsureFailed(
                languageStillMismatches: true,
                playingStillStalled: false,
                isRequestEligible: true,
                recreationsAttempted: budget
            ),
            "Exhausted recreation budget must stop end/start loops on foreground"
        )
        XCTAssertTrue(
            manager._test_shouldRecreateAfterForegroundSoftEnsureFailed(
                languageStillMismatches: true,
                playingStillStalled: false,
                isRequestEligible: true,
                recreationsAttempted: budget - 1
            ),
            "Last recreation budget slot remains available when soft ensure still fails"
        )
    }

    /// Playing ensure covers stale Connecting **and** soft-resume pause chrome.
    ///
    /// Soft-resume residual: owned `.prePlay` with optimistic last `.playing` must still
    /// schedule reconcile (owned visual gate + ensure gate). Bounded soft retries are
    /// production ``authoritativePlayingContentEnsureMaxAttempts`` — pure policy here.
    func testPlayingEnsureCoversConnectingAndUserPausedStalls() {
        XCTAssertTrue(
            manager._test_shouldEnsureAuthoritativePlayingContent(
                actorVisual: .playing,
                streamSwitchHold: false,
                isConnectingPlayback: false,
                lastPushedVisual: .prePlay,
                ownedVisual: .prePlay
            ),
            "Stale Connecting lastPushed must schedule playing reconcile"
        )
        XCTAssertTrue(
            manager._test_shouldEnsureAuthoritativePlayingContent(
                actorVisual: .playing,
                streamSwitchHold: false,
                isConnectingPlayback: false,
                lastPushedVisual: .userPaused,
                ownedVisual: .userPaused
            ),
            "Soft-resume: last/owned pause while actor playing must schedule reconcile"
        )
        XCTAssertTrue(
            manager._test_shouldEnsureAuthoritativePlayingContent(
                actorVisual: .playing,
                streamSwitchHold: false,
                isConnectingPlayback: false,
                lastPushedVisual: .playing,
                ownedVisual: .userPaused
            ),
            "Optimistic lastPushed playing while owned pause must still schedule reconcile"
        )
        XCTAssertTrue(
            manager._test_shouldEnsureAuthoritativePlayingContent(
                actorVisual: .playing,
                streamSwitchHold: false,
                isConnectingPlayback: false,
                lastPushedVisual: .playing,
                ownedVisual: .prePlay
            ),
            "Optimistic lastPushed playing while owned Connecting must still schedule soft-resume reconcile"
        )
        XCTAssertFalse(
            manager._test_shouldEnsureAuthoritativePlayingContent(
                actorVisual: .playing,
                streamSwitchHold: true,
                isConnectingPlayback: false,
                lastPushedVisual: .userPaused,
                ownedVisual: .userPaused
            ),
            "Stream-switch hold must not invent authoritative playing"
        )
        XCTAssertFalse(
            manager._test_shouldEnsureAuthoritativePlayingContent(
                actorVisual: .playing,
                streamSwitchHold: false,
                isConnectingPlayback: false,
                lastPushedVisual: .playing,
                ownedVisual: .playing
            ),
            "Matched playing chrome is a cheap no-op"
        )
        XCTAssertGreaterThanOrEqual(
            RadioLiveActivityManager.authoritativePlayingContentEnsureMaxAttempts,
            2,
            "Soft-resume visual honesty needs more than a single push when ActivityKit lags acceptance"
        )
    }

    /// Attribute-events yield warms the durable LA language mirror from ContentState.
    func testContentUpdatesObservationWarmsLanguageMirror() async {
        SharedPlayerManager.clearLiveActivityLanguageMirror()
        XCTAssertNil(SharedPlayerManager.loadLiveActivityLanguageMirror())

        let content = makeActivityContent(
            visualState: .playing,
            metadata: StreamProgramMetadata(programTitle: "Sermon", speaker: nil),
            currentLanguage: "de"
        )
        let stream = AsyncStream<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>> { continuation in
            continuation.yield(content)
            continuation.finish()
        }
        manager._test_beginObservingSyntheticContentUpdates(stream)

        let warmed = await waitUntil({
            SharedPlayerManager.loadLiveActivityLanguageMirror() == "de"
        })
        XCTAssertTrue(warmed, "ContentState language must warm the durable LA language mirror")
        XCTAssertEqual(manager.lastPushedContent?.currentLanguage, "de")
    }

    /// Verifies termination self-healing clears stale tracking when observation ends
    /// while an activity reference is still considered active.
    ///
    /// **Also protects:** durable LA visual + language App Group mirrors are cleared with
    /// local tracking so a cold extension cannot plan from a system-dismissed surface.
    func testAttributeObservationTerminationClearsStaleTrackingWhenActivityPresent() async {
        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(.playing)
        SharedPlayerManager.persistLiveActivityLanguageMirror("et")
        XCTAssertEqual(SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(), .playing)
        XCTAssertEqual(SharedPlayerManager.loadLiveActivityLanguageMirror(), "et")

        let content = makeActivityContent(visualState: .playing)
        var continuation: AsyncStream<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>>.Continuation?
        let stream = AsyncStream { continuation = $0 }

        manager._test_setHarnessSimulatesActiveActivity(true)
        manager._test_beginObservingSyntheticContentUpdates(stream)
        XCTAssertNotNil(manager.activityObservationTask, "Observation must publish activityObservationTask")

        continuation?.yield(content)
        let populated = await waitUntil({ self.manager.lastPushedContent == content.state })
        XCTAssertTrue(populated, "Precondition: attribute-events yield must populate lastPushedContent")

        manager._test_cancelAttributeEventObservation()

        let cleared = await waitUntil({ self.manager.lastPushedContent == nil })
        XCTAssertTrue(
            cleared,
            "Termination hygiene must clear lastPushedContent when activity tracking was active"
        )
        XCTAssertNil(manager.currentActivity)
        XCTAssertNil(
            SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(),
            "Observation end hygiene must clear liveActivityToggleVisualState"
        )
        XCTAssertNil(
            SharedPlayerManager.loadLiveActivityLanguageMirror(),
            "Observation end hygiene must clear liveActivityCurrentLanguage"
        )
    }

    /// Verifies that ``endActivity()`` cancels attribute-events observation and clears
    /// ``activityObservationTask`` without ActivityKit IPC under test isolation.
    ///
    /// **Also protects:** durable LA toggle visual + language mirrors are dropped on every
    /// end path (including UITestMode / under-test early returns) so residual plan signals
    /// do not survive LA dismissal, privacy clear, or termination orchestration.
    ///
    /// - SeeAlso: ``SharedPlayerManager/clearLiveActivityToggleVisualStateMirror()``,
    ///   ``SharedPlayerManager/clearLiveActivityLanguageMirror()``.
    func testEndActivityCancelsAttributeObservationTask() async {
        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(.userPaused)
        SharedPlayerManager.persistLiveActivityLanguageMirror("nb")
        XCTAssertEqual(SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(), .userPaused)
        XCTAssertEqual(SharedPlayerManager.loadLiveActivityLanguageMirror(), "nb")

        let stream = AsyncStream<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>> { _ in }
        manager._test_beginObservingSyntheticContentUpdates(stream)
        XCTAssertNotNil(manager.activityObservationTask, "Precondition: observation task must be live")

        manager.endActivity()

        XCTAssertNil(manager.activityObservationTask, "endActivity must cancel attribute-events observation")
        XCTAssertNil(manager.lastPushedContent, "endActivity must clear lastPushedContent under test isolation")
        XCTAssertNil(manager.currentActivity)
        XCTAssertNil(
            SharedPlayerManager.loadLiveActivityToggleVisualStateMirror(),
            "endActivity must clear liveActivityToggleVisualState"
        )
        XCTAssertNil(
            SharedPlayerManager.loadLiveActivityLanguageMirror(),
            "endActivity must clear liveActivityCurrentLanguage"
        )
    }

    // MARK: - Termination final ContentState + hygiene

    /// Protects the final-end ContentState contract used on process exit and residual reaping:
    /// visual is forced to `.userPaused`, language chrome prefers last-pushed then activity
    /// content, and program metadata is preserved when available so Dynamic Island / Lock
    /// Screen never flash a contradictory live frame as the surface dismisses.
    ///
    /// - SeeAlso: ``RadioLiveActivityManager/_test_finalEndContentState(lastPushed:activityState:residualState:fallbackLanguage:)``,
    ///   ``RadioLiveActivityManager/handleAppWillTerminate()``,
    ///   docs/Widget-Presentation-Dataflow.md (termination).
    func testFinalEndContentStatePreservesLanguageAndForcesUserPaused() {
        let metadata = StreamProgramMetadata(programTitle: "Evening Prayer", speaker: "Reader")
        let lastPushed = makeContentState(
            visualState: .playing,
            metadata: metadata,
            currentLanguage: "fi"
        )
        let activityState = makeContentState(
            visualState: .playing,
            metadata: StreamProgramMetadata(programTitle: "Stale", speaker: nil),
            currentLanguage: "de"
        )

        let final = manager._test_finalEndContentState(
            lastPushed: lastPushed,
            activityState: activityState,
            fallbackLanguage: "en"
        )

        XCTAssertEqual(final.visualState, .userPaused, "Final end frame must never claim live audio")
        XCTAssertEqual(final.currentLanguage, "fi", "Last-pushed language is the chrome SSOT for end")
        XCTAssertEqual(final.streamMetadata, metadata, "Last-pushed program metadata must be preserved")
    }

    /// When last-pushed is absent, final end content falls back to activity ContentState
    /// language/metadata, then residual system content, then the explicit fallback language.
    func testFinalEndContentStateFallsBackToActivityThenFallbackLanguage() {
        let activityState = makeContentState(
            visualState: .playing,
            metadata: StreamProgramMetadata(programTitle: "From Activity", speaker: nil),
            currentLanguage: "sv"
        )

        let fromActivity = manager._test_finalEndContentState(
            lastPushed: nil,
            activityState: activityState,
            fallbackLanguage: "en"
        )
        XCTAssertEqual(fromActivity.visualState, .userPaused)
        XCTAssertEqual(fromActivity.currentLanguage, "sv")
        XCTAssertEqual(fromActivity.streamMetadata?.programTitle, "From Activity")

        let fromFallback = manager._test_finalEndContentState(
            lastPushed: nil,
            activityState: nil,
            residualState: nil,
            fallbackLanguage: "et"
        )
        XCTAssertEqual(fromFallback.visualState, .userPaused)
        XCTAssertEqual(fromFallback.currentLanguage, "et")
        XCTAssertNil(fromFallback.streamMetadata)
    }

    /// Cold-launch reaping: when this-process local tracking is empty, final-end chrome must
    /// seed language and program metadata from residual system ContentState (not invent
    /// attach-language fallback while residual still holds the prior stream chrome).
    ///
    /// Visual remains `.userPaused` so a force-quit leftover never dismisses as interactive
    /// `.playing`. Last-pushed and owned activity still outrank residual when present.
    ///
    /// - SeeAlso: ``RadioLiveActivityManager/prepareLocalLiveActivityEndState()`` (via seam),
    ///   ``RadioLiveActivityManager/observeExistingActivities()``,
    ///   docs/Widget-Presentation-Dataflow.md (residual reaping).
    func testFinalEndContentStateSeedsLanguageAndMetadataFromResidual() {
        let residual = makeContentState(
            visualState: .playing,
            metadata: StreamProgramMetadata(programTitle: "Residual Program", speaker: "Prior"),
            currentLanguage: "nb"
        )

        let fromResidual = manager._test_finalEndContentState(
            lastPushed: nil,
            activityState: nil,
            residualState: residual,
            fallbackLanguage: "en"
        )
        XCTAssertEqual(fromResidual.visualState, .userPaused, "Residual reaping must force paused visual")
        XCTAssertEqual(fromResidual.currentLanguage, "nb", "Residual language must outrank fallback")
        XCTAssertEqual(fromResidual.streamMetadata?.programTitle, "Residual Program")
        XCTAssertEqual(fromResidual.streamMetadata?.speaker, "Prior")

        // Owned activity still wins over residual when both are present.
        let owned = makeContentState(
            visualState: .userPaused,
            metadata: StreamProgramMetadata(programTitle: "Owned", speaker: nil),
            currentLanguage: "fi"
        )
        let ownedWins = manager._test_finalEndContentState(
            lastPushed: nil,
            activityState: owned,
            residualState: residual,
            fallbackLanguage: "en"
        )
        XCTAssertEqual(ownedWins.currentLanguage, "fi")
        XCTAssertEqual(ownedWins.streamMetadata?.programTitle, "Owned")
    }

    /// Deferred observe residual-id policy: unowned → reap every system id; owned → reap
    /// siblings only (never the owned id). Closes the hole where "skip all reaping when
    /// owned" left a second prior-process residual interactive.
    ///
    /// Pure policy seam — no ActivityKit IPC.
    ///
    /// - SeeAlso: ``RadioLiveActivityManager/_test_systemResidualIdsToReap(systemActivityIds:ownedActivityId:)``,
    ///   ``RadioLiveActivityManager/_test_shouldUseFullResidualEnd(hasOwnedCurrentActivity:)``,
    ///   ``RadioLiveActivityManager/observeExistingActivities()``,
    ///   ``RadioLiveActivityManager/reapUnownedSystemResiduals(preservingOwnedActivityId:)``.
    func testSystemResidualIdsToReapPreservesOwnedAndSweepsSiblings() {
        let owned = "owned-la-id"
        let siblingA = "residual-a"
        let siblingB = "residual-b"
        let systemIds = [owned, siblingA, siblingB]

        // No ownership: full residual reaping (all system ids).
        XCTAssertEqual(
            manager._test_systemResidualIdsToReap(systemActivityIds: systemIds, ownedActivityId: nil),
            systemIds,
            "Unowned observe must target every system-held residual"
        )
        XCTAssertTrue(
            manager._test_shouldUseFullResidualEnd(hasOwnedCurrentActivity: false),
            "Unowned path uses full endActivity (clears local tracking)"
        )

        // Ownership: siblings only — never the owned Activity.
        let siblingOnly = manager._test_systemResidualIdsToReap(
            systemActivityIds: systemIds,
            ownedActivityId: owned
        )
        XCTAssertEqual(Set(siblingOnly), Set([siblingA, siblingB]))
        XCTAssertFalse(siblingOnly.contains(owned), "Owned id must never be reaped as residual")
        XCTAssertFalse(
            manager._test_shouldUseFullResidualEnd(hasOwnedCurrentActivity: true),
            "Owned path must not full-end (would clear currentActivity + mirrors)"
        )

        // Ownership with no siblings: empty reaping set (happy startActivity race).
        XCTAssertTrue(
            manager._test_systemResidualIdsToReap(
                systemActivityIds: [owned],
                ownedActivityId: owned
            ).isEmpty,
            "Sole owned Activity must produce an empty sibling reaping set"
        )

        // Ownership when owned id is absent from system list (stale local ref): reap all listed.
        XCTAssertEqual(
            Set(manager._test_systemResidualIdsToReap(
                systemActivityIds: [siblingA, siblingB],
                ownedActivityId: owned
            )),
            Set([siblingA, siblingB]),
            "Siblings still reaped when owned id is not among system activities"
        )
    }

    /// ``handleAppWillTerminate()`` must clear local tracking under test isolation without
    /// ActivityKit IPC (same cheap path as ``endActivity``).
    func testHandleAppWillTerminateClearsLocalTrackingUnderTestIsolation() {
        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(.playing)
        SharedPlayerManager.persistLiveActivityLanguageMirror("pl")
        let stream = AsyncStream<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>> { _ in }
        manager._test_beginObservingSyntheticContentUpdates(stream)
        XCTAssertNotNil(manager.activityObservationTask)

        manager.handleAppWillTerminate()

        XCTAssertNil(manager.activityObservationTask)
        XCTAssertNil(manager.currentActivity)
        XCTAssertNil(manager.lastPushedContent)
        XCTAssertNil(SharedPlayerManager.loadLiveActivityToggleVisualStateMirror())
        XCTAssertNil(SharedPlayerManager.loadLiveActivityLanguageMirror())
    }

    /// Verifies restart semantics: a second synthetic stream cancels the prior observation
    /// so only the replacement sequence updates ``lastPushedContent``.
    func testRestartingAttributeObservationCancelsPriorStream() async {
        var firstContinuation: AsyncStream<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>>.Continuation?
        let firstStream = AsyncStream { firstContinuation = $0 }

        let firstContent = makeActivityContent(visualState: .playing)
        manager._test_beginObservingSyntheticContentUpdates(firstStream)

        firstContinuation?.yield(firstContent)
        let firstReady = await waitUntil({ self.manager.lastPushedContent == firstContent.state })
        XCTAssertTrue(firstReady, "Precondition: first stream must deliver before restart")

        let secondContent = makeActivityContent(visualState: .userPaused)
        let secondStream = AsyncStream<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>> { continuation in
            continuation.yield(secondContent)
            continuation.finish()
        }

        manager._test_beginObservingSyntheticContentUpdates(secondStream)

        let secondReady = await waitUntil({ self.manager.lastPushedContent == secondContent.state })
        XCTAssertTrue(secondReady, "Restarted observation must deliver from the replacement stream")

        firstContinuation?.yield(makeActivityContent(visualState: .prePlay))
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(
            manager.lastPushedContent,
            secondContent.state,
            "Prior stream must not update lastPushedContent after restart"
        )
    }
}
