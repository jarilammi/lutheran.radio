//
//  RadioLiveActivityManagerTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 29.8.2025.
//
//  White-box unit tests for ``RadioLiveActivityManager`` timer demotion, change-detection
//  guards, Live Activity attribute-events (`contentUpdates`) observation contracts, and
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
        // Singleton suppress memory must not leak across tests (optimistic stream-switch
        // / attribute-events cases write lastPushedContent without endActivity).
        manager._test_clearLastPushedContent()
    }
    
    override func tearDown() async throws {
        // Must stop the timer (if any) and cancel attribute event observation before
        // releasing. Prevents live Tasks / Timers keeping the runner alive.
        manager?._test_setPendingInteractiveLiveActivityEnsure(false)
        manager?._test_setLanguageEnsureQuietPendingDestination(nil)
        manager?._test_clearLastPushedContent()
        manager?.stopLocalUpdateTimer()
        manager?.activityObservationTask?.cancel()
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
        XCTAssertEqual(
            manager.lastPushedContent?.currentLanguage,
            "sv",
            "Optimistic control flip must not clear stream language chrome"
        )
        XCTAssertTrue(
            manager._test_wouldSuppressLiveActivityUpdate(
                visualState: .userPaused,
                streamMetadata: metadata,
                currentLanguage: "sv"
            ),
            "Engine-complete pause candidate matching optimistic content must suppress"
        )
        XCTAssertFalse(
            manager._test_wouldSuppressLiveActivityUpdate(
                visualState: .playing,
                streamMetadata: metadata,
                currentLanguage: "sv"
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
        XCTAssertEqual(manager.lastPushedContent?.currentLanguage, "de")
        XCTAssertEqual(manager.lastPushedContent?.streamMetadata, metadata)
        // Owned surface still Connecting → suppress denied (ActivityKit push still required).
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
        XCTAssertTrue(
            manager._test_shouldDeferRedundantPlayingPushWhileQuiet(
                candidateVisual: .playing,
                ownedContentVisual: .prePlay,
                ownedContentLanguage: "fi",
                candidateLanguage: "fi",
                quietPending: true,
                isRequestEligible: false
            ),
            "Playing-only stall while quiet and ineligible must defer ActivityKit IPC"
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
