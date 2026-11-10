//
//  SleepTimerFadeTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 10.11.2026.
//
//  Sleep-timer fade: the ramp reaches silence before the elapsed pause, and every
//  cancel / play / switch / interruption path restores AVPlayer relative gain to 1.
//  The manual clock keeps a 30 s production ramp from blocking the suite.
//
//  - SeeAlso: ``SleepTimerFadePolicy``,
//    ``SharedPlayerManager/setSleepTimer(duration:)``,
//    ``SharedPlayerManager/restoreUnityPlaybackGainForPlaybackStart()``,
//    `docs/cold-launch-streamplay-regression-checklist.md` (Sleep timer),
//    CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
//

import AVFoundation
import XCTest
@testable import Lutheran_Radio

/// Quadratic ease-out and step-count contract. No actor, no audio.
final class SleepTimerFadePolicyTests: XCTestCase {

    func testDefaultFadeIsThirtySecondsAndOffIsZero() {
        XCTAssertEqual(SleepTimerFadePolicy.defaultDuration, 30)
        XCTAssertEqual(SleepTimerFadePolicy.offDuration, 0)
        XCTAssertEqual(
            SleepTimerFadePolicy.fadeDuration(totalSeconds: 45, configured: 30),
            30
        )
        XCTAssertEqual(
            SleepTimerFadePolicy.fadeDuration(totalSeconds: 10, configured: 30),
            10,
            "A timer shorter than the fade uses the remaining time"
        )
        XCTAssertEqual(
            SleepTimerFadePolicy.fadeDuration(totalSeconds: 45, configured: 0),
            0
        )
    }

    func testStepCountIsAtLeastTenPerSecondAndEndsAtSilence() {
        XCTAssertEqual(SleepTimerFadePolicy.stepCount(forFadeDuration: 0), 0)
        XCTAssertEqual(SleepTimerFadePolicy.stepCount(forFadeDuration: 30), 300)
        XCTAssertEqual(SleepTimerFadePolicy.stepCount(forFadeDuration: 2), 20)

        let steps = SleepTimerFadePolicy.stepCount(forFadeDuration: 30)
        var previous = SleepTimerFadePolicy.gain(atStep: 0, of: steps)
        XCTAssertEqual(previous, 1, accuracy: 0.0001)
        for step in 1...steps {
            let gain = SleepTimerFadePolicy.gain(atStep: step, of: steps)
            XCTAssertLessThanOrEqual(gain, previous)
            previous = gain
        }
        XCTAssertEqual(previous, 0, accuracy: 0.0001)
    }
}

/// Countdown integration against a manual clock and the shared engine's relative gain.
///
/// Why the clock: the production ramp is 30 s at ≥10 steps per second. Tests release
/// one wait at a time so cancel / play / switch can land on a known step.
final class SleepTimerFadeTests: XCTestCase {

    private let manager = SharedPlayerManager.shared
    private let clock = ManualSleepTimerClock()

    override func setUp() async throws {
        try await super.setUp()
        await prepareSharedPlayerManagerEventTestIsolation(manager: manager)
        await MainActor.run {
            let engine = DirectStreamingPlayer.shared
            engine.player = AVPlayer()
            engine.restoreUnityPlaybackGain()
        }
        await manager._test_resetSleepTimerTiming()
        await manager._test_setSleepTimerDelay { [clock] duration in
            try await clock.sleep(for: duration)
        }
    }

    override func tearDown() async throws {
        await manager.cancelSleepTimer(restorePlaybackIntent: false, notifyStateChange: false)
        await manager._test_resetSleepTimerTiming()
        await MainActor.run {
            let engine = DirectStreamingPlayer.shared
            engine.restoreUnityPlaybackGain()
            engine.player = nil
        }
        await tearDownSharedPlayerManagerEventTestIsolation(manager: manager)
        try await super.tearDown()
    }

    func testFadeReachesZeroBeforeSleepTimerStop() async {
        let suite = UserDefaults(suiteName: "group.radio.lutheran.shared")
        await manager.setPlaying()
        _ = await manager.setSleepTimer(duration: 2)

        let steps = SleepTimerFadePolicy.stepCount(forFadeDuration: 2)
        await driveUntil(gainCount: steps)
        let sawPause = await waitUntil(timeoutMs: 4_000) {
            await self.traceContainsPause()
        }
        XCTAssertTrue(sawPause, "Elapsed pause must follow the ramp")

        let trace = await manager._test_sleepTimerFadeTrace()
        let gains = gains(in: trace)
        XCTAssertEqual(gains.count, steps)
        XCTAssertEqual(gains.last ?? 1, 0, accuracy: 0.0001)
        if let pauseIndex = trace.firstIndex(of: .elapsedPause),
           let zeroIndex = trace.lastIndex(where: { event in
               if case .gain(let value) = event { return value == 0 } else { return false }
           }) {
            XCTAssertLessThan(zeroIndex, pauseIndex, "Silence is applied before stop")
        } else {
            XCTFail("Trace missing silence or elapsed pause: \(trace)")
        }

        let restored = await waitUntil(timeoutMs: 8_000) {
            let gain = await self.readGain()
            return abs(gain - 1) < 0.0001
        }
        XCTAssertTrue(restored, "Gain must return to 1 after the elapsed stop")
        let volume = await readPlayerVolume()
        XCTAssertEqual(volume ?? -1, 1, accuracy: 0.0001)
        XCTAssertNil(suite?.object(forKey: "playbackRelativeGain"))
        XCTAssertNil(suite?.object(forKey: "preferredVolume"))
        let visual = await manager.currentVisualState
        XCTAssertEqual(visual, .userPaused)
    }

    func testCancellingTimerMidFadeRestoresUnityGain() async {
        await manager.setPlaying()
        _ = await manager.setSleepTimer(duration: 2)
        await driveUntil(gainCount: 8)

        let mid = await readGain()
        XCTAssertLessThan(mid, 1)
        XCTAssertGreaterThan(mid, 0)
        let midVolume = await readPlayerVolume()
        XCTAssertEqual(midVolume ?? -1, mid, accuracy: 0.0001)

        await manager.cancelSleepTimer()
        let restored = await waitUntil(timeoutMs: 1_000) {
            let gain = await self.readGain()
            return abs(gain - 1) < 0.0001
        }
        XCTAssertTrue(restored)
        let volume = await readPlayerVolume()
        XCTAssertEqual(volume ?? -1, 1, accuracy: 0.0001)
        let visual = await manager.currentVisualState
        XCTAssertEqual(visual, .playing, "Cancel restores gain and leaves playback up")
        let sawPause = await traceContainsPause()
        XCTAssertFalse(sawPause)
    }

    func testPlayMidFadeRestoresUnityGainAndKeepsPlaying() async {
        await manager.setPlaying()
        _ = await manager.setSleepTimer(duration: 2)
        await driveUntil(gainCount: 8)
        let faded = await readGain()
        XCTAssertLessThan(faded, 1)

        await manager.userRequestedPlay()

        let restored = await waitUntil(timeoutMs: 1_000) {
            abs(await self.readGain() - 1) < 0.0001
        }
        XCTAssertTrue(restored)
        let volume = await readPlayerVolume()
        XCTAssertEqual(volume ?? -1, 1, accuracy: 0.0001)
        let visual = await manager.currentVisualState
        let intent = await manager.currentPlaybackIntent
        XCTAssertEqual(visual, .playing)
        XCTAssertEqual(intent, .shouldBePlaying)
        let sawPause = await traceContainsPause()
        XCTAssertFalse(sawPause)
    }

    func testStreamSwitchMidFadeRestoresUnityGain() async {
        await manager.setPlaying()
        _ = await manager.setSleepTimer(duration: 2)
        await driveUntil(gainCount: 8)
        let faded = await readGain()
        XCTAssertLessThan(faded, 1)

        await manager.resetToPrePlayForNewStream(
            preserveActiveSleepTimer: true,
            connectingLanguageCode: "de"
        )

        let restored = await waitUntil(timeoutMs: 1_000) {
            abs(await self.readGain() - 1) < 0.0001
        }
        XCTAssertTrue(restored)
        let volume = await readPlayerVolume()
        XCTAssertEqual(volume ?? -1, 1, accuracy: 0.0001)
        let intent = await manager.currentPlaybackIntent
        XCTAssertEqual(intent, .sleepTimer, "Stream switch keeps the timer armed")
        let sawPause = await traceContainsPause()
        XCTAssertFalse(sawPause)
    }

    func testInterruptionThenWidgetPlayStartsAtUnityGain() async {
        await manager.setPlaying()
        _ = await manager.setSleepTimer(duration: 2)
        await driveUntil(gainCount: 8)
        let faded = await readGain()
        XCTAssertLessThan(faded, 1)
        XCTAssertGreaterThan(faded, 0)

        await manager.invalidateSleepTimerFadeKeepingDeadline()
        let stillFaded = await readGain()
        XCTAssertEqual(stillFaded, faded, accuracy: 0.0001)

        await manager.applyVisualState(.userPaused)
        await manager.userRequestedPlay()

        let restored = await waitUntil(timeoutMs: 1_000) {
            abs(await self.readGain() - 1) < 0.0001
        }
        XCTAssertTrue(restored, "Widget / intent play must start at unity after a mid-fade interruption")
        let volume = await readPlayerVolume()
        XCTAssertEqual(volume ?? -1, 1, accuracy: 0.0001)
    }

    func testOffFadePolicyKeepsHardStop() async {
        await manager._test_setSleepTimerFadeDuration(SleepTimerFadePolicy.offDuration)
        await manager.setPlaying()
        _ = await manager.setSleepTimer(duration: 3)
        clock.release(3)

        let sawPause = await waitUntil(timeoutMs: 2_000) {
            await self.traceContainsPause()
        }
        XCTAssertTrue(sawPause)
        let gains = gains(in: await manager._test_sleepTimerFadeTrace())
        XCTAssertTrue(gains.isEmpty, "Off must not ramp volume before the hard stop")
        let gain = await readGain()
        let volume = await readPlayerVolume()
        let visual = await manager.currentVisualState
        XCTAssertEqual(gain, 1, accuracy: 0.0001)
        XCTAssertEqual(volume ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(visual, .userPaused)
    }

    func testTimerShorterThanFadeUsesRemainingTime() async {
        await manager._test_setSleepTimerFadeDuration(SleepTimerFadePolicy.defaultDuration)
        await manager.setPlaying()
        _ = await manager.setSleepTimer(duration: 2)

        let shortSteps = SleepTimerFadePolicy.stepCount(forFadeDuration: 2)
        let fullSteps = SleepTimerFadePolicy.stepCount(forFadeDuration: 30)
        XCTAssertLessThan(shortSteps, fullSteps)

        await driveUntil(gainCount: shortSteps)
        let sawPause = await waitUntil(timeoutMs: 4_000) {
            await self.traceContainsPause()
        }
        XCTAssertTrue(sawPause)
        let applied = gains(in: await manager._test_sleepTimerFadeTrace())
        XCTAssertEqual(applied.count, shortSteps)
        XCTAssertEqual(applied.last ?? 1, 0, accuracy: 0.0001)
    }

    // MARK: - Clock driving

    private func driveUntil(gainCount target: Int) async {
        for _ in 0..<target + 5 {
            let before = await gainCount()
            if before >= target { return }
            clock.release(1)
            let moved = await waitUntil(timeoutMs: 1_000) {
                await self.gainCount() > before
            }
            if !moved {
                XCTFail("Fade did not advance past \(before) gains (target \(target))")
                return
            }
        }
    }

    private func gainCount() async -> Int {
        gains(in: await manager._test_sleepTimerFadeTrace()).count
    }

    private func gains(in trace: [SleepTimerFadeTraceEvent]) -> [Float] {
        trace.compactMap { event in
            if case .gain(let value) = event { return value }
            return nil
        }
    }

    private func traceContainsPause() async -> Bool {
        let trace = await manager._test_sleepTimerFadeTrace()
        return trace.contains(.elapsedPause)
    }

    private func readGain() async -> Float {
        await MainActor.run { DirectStreamingPlayer.shared.playbackRelativeGain }
    }

    private func readPlayerVolume() async -> Float? {
        await MainActor.run { DirectStreamingPlayer.shared.player?.volume }
    }

    private func waitUntil(
        timeoutMs: Int,
        _ condition: @escaping () async -> Bool
    ) async -> Bool {
        let iterations = max(1, timeoutMs / 10)
        for _ in 0..<iterations {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

/// Manual clock for sleep-timer waits. Credits released before the sleeper arrives
/// are kept so a test can step without racing the actor.
private final class ManualSleepTimerClock: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingReleases = 0
    private var waiters: [OnceResume] = []

    func sleep(for duration: Duration) async throws {
        _ = duration
        try Task.checkCancellation()
        let ticket = OnceResume()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                ticket.arm(continuation)
                self.lock.lock()
                if self.pendingReleases > 0 {
                    self.pendingReleases -= 1
                    self.lock.unlock()
                    ticket.resume()
                } else {
                    self.waiters.append(ticket)
                    self.lock.unlock()
                }
            }
        } onCancel: {
            ticket.cancel()
            self.lock.lock()
            self.waiters.removeAll { $0 === ticket }
            self.lock.unlock()
        }
    }

    func release(_ count: Int = 1) {
        var ready: [OnceResume] = []
        lock.lock()
        var remaining = max(0, count)
        while remaining > 0, !waiters.isEmpty {
            ready.append(waiters.removeFirst())
            remaining -= 1
        }
        pendingReleases += remaining
        lock.unlock()
        for ticket in ready {
            ticket.resume()
        }
    }
}

private final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private enum State { case pending, success, cancelled }
    private var state: State = .pending

    func arm(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        switch state {
        case .pending:
            self.continuation = continuation
            lock.unlock()
        case .success:
            lock.unlock()
            continuation.resume()
        case .cancelled:
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        }
    }

    func resume() {
        finish(.success)
    }

    func cancel() {
        finish(.cancelled)
    }

    private func finish(_ newState: State) {
        lock.lock()
        guard state == .pending else {
            lock.unlock()
            return
        }
        state = newState
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return }
        if newState == .success {
            continuation.resume()
        } else {
            continuation.resume(throwing: CancellationError())
        }
    }
}
