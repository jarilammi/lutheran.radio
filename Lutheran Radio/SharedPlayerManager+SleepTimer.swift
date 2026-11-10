//
//  SharedPlayerManager+SleepTimer.swift
//  Lutheran Radio
//
//  Sleep timer: countdown authority on SharedPlayerManager; elapsed pause is
//  ``applySleepTimerElapsedPause()`` (engine-complete interruption stop + audio-session
//  deactivation; not sticky ``stop()``). Main app target only (no widget / Live
//  Activity countdown in v1).
//
//  The last ``SleepTimerFadePolicy/defaultDuration`` seconds ramp `AVPlayer.volume`
//  from 1 to 0 (one cancellable fade task, ease-out, at least 10 steps per second).
//  A shorter timer fades across its whole remaining time. The Off duration (0) keeps
//  the hard stop. Relative gain is in-memory only — never UserDefaults or the App Group.
//  Backgrounding does not cancel the ramp; the next playback start restores unity.
//
//  UI: SwiftUI `.confirmationDialog` in PlaybackControlsView is the sole in-app
//  presentation; presets/cancel route through PlayerViewModel into
//  RadioPlayerCoordinator+SleepTimer. Siri and Shortcuts use the same
//  setSleepTimer / cancelSleepTimer entry points (SleepTimerIntents.swift).
//  Actor-side setSleepTimer / cancelSleepTimer + countdown task + SleepTimerNotification
//  remain the timer authority; the coordinator extension owns display glue only.
//  A schedule posts one state notification so the moon updates when the caller
//  is an intent, not only the in-app preset handler.
//
//  Created by Jari Lammi on 5.6.2026.
//

#if LUTHERAN_MAIN_APP
import Foundation
import WidgetSurface

/// How the sleep-timer ramp approaches silence.
///
/// Production uses ``defaultDuration`` (30 seconds). ``offDuration`` (0) keeps the
/// existing hard stop. A timer shorter than the configured fade uses the remaining
/// time instead. The curve is quadratic ease-out: most of the drop is early, and the
/// last step is exactly `0`.
///
/// - Important: This policy never reads or writes system volume. The only output is
///   a unit-interval gain for `AVPlayer.volume`.
/// - SeeAlso: ``SharedPlayerManager/setSleepTimer(duration:)``,
///   ``DirectStreamingPlayer/restoreUnityPlaybackGain()``,
///   `docs/cold-launch-streamplay-regression-checklist.md` (Sleep timer).
enum SleepTimerFadePolicy: Sendable {
    /// Production ramp length, in seconds.
    static let defaultDuration: TimeInterval = 30
    /// Off. The deadline still stops playback; volume stays at unity the whole time.
    static let offDuration: TimeInterval = 0
    /// Lower bound on ramp resolution. Short fades use at least this many steps.
    static let minimumStepsPerSecond: Int = 10

    /// Seconds the ramp actually runs.
    ///
    /// - Parameters:
    ///   - totalSeconds: Armed timer length, already rounded up to a whole second.
    ///   - configured: Requested fade length. `<= 0` selects Off.
    /// - Returns: `0` when Off or the timer is empty; otherwise `min(configured, totalSeconds)`.
    static func fadeDuration(totalSeconds: Int, configured: TimeInterval) -> TimeInterval {
        guard configured > 0, totalSeconds > 0 else { return 0 }
        return min(configured, TimeInterval(totalSeconds))
    }

    /// Step count for a fade of `duration` seconds.
    ///
    /// - Parameter duration: Fade length in seconds. `0` yields no steps.
    /// - Returns: At least ``minimumStepsPerSecond`` steps when `duration > 0`, and at
    ///   least that many steps per second for longer fades.
    static func stepCount(forFadeDuration duration: TimeInterval) -> Int {
        guard duration > 0 else { return 0 }
        let scaled = Int((duration * Double(minimumStepsPerSecond)).rounded(.up))
        return max(minimumStepsPerSecond, scaled)
    }

    /// Ease-out gain for a 1-based step.
    ///
    /// - Parameters:
    ///   - step: 1-based index. `0` is still full volume (the ramp has not moved).
    ///   - stepCount: Total steps from ``stepCount(forFadeDuration:)``.
    /// - Returns: `1` before the first step, `0` on the last step, and a quadratic
    ///   ease-out in between.
    static func gain(atStep step: Int, of stepCount: Int) -> Float {
        guard stepCount > 0 else { return 1 }
        let clampedStep = min(max(step, 0), stepCount)
        guard clampedStep > 0 else { return 1 }
        let progress = Double(clampedStep) / Double(stepCount)
        let remaining = 1.0 - progress
        return Float(remaining * remaining)
    }
}

/// How an owned fade task finished. `steps` is how many gains were applied.
enum SleepTimerFadeResult: Sendable, Equatable {
    case completed(steps: Int)
    case cancelled(steps: Int)

    var steps: Int {
        switch self {
        case .completed(let steps), .cancelled(let steps):
            return steps
        }
    }
}

#if DEBUG
/// Samples from the ramp plus the moment the elapsed pause begins.
/// Unity restores are intentionally absent so tests can see the ramp reach 0
/// before the stop.
enum SleepTimerFadeTraceEvent: Equatable, Sendable {
    case gain(Float)
    case elapsedPause
}
#endif

/// In-process sleep-timer state broadcasts (main app only).
/// `RadioPlayerCoordinator` (+SleepTimer domain) owns local countdown display; these avoid
/// polling the actor every second.
enum SleepTimerNotification {
    static let stateDidChange = Notification.Name("SleepTimerStateDidChange")

    enum Key {
        static let isActive = "isActive"
        static let remainingSeconds = "remainingSeconds"
    }

    /// Posts on MainActor — coordinator observer is MainActor-isolated; posting from
    /// SharedPlayerManager's actor executor traps under Swift 6 strict concurrency.
    @MainActor
    static func postStateChange(isActive: Bool, remainingSeconds: Int? = nil) {
        var userInfo: [String: Any] = [Key.isActive: isActive]
        if let remainingSeconds {
            userInfo[Key.remainingSeconds] = remainingSeconds
        }
        NotificationCenter.default.post(name: stateDidChange, object: nil, userInfo: userInfo)
    }

    /// Seconds to seed into the in-app countdown, or nil when the moon should stay as it is.
    ///
    /// A schedule posts once with the armed length. The same length already cached
    /// is a duplicate delivery before the first local tick, not a new arm.
    /// A different positive length replaces the countdown, including an intent
    /// that sets a new preset while one is already showing. Inactive notifications
    /// are handled by the caller (clear the moon); this returns nil for those.
    ///
    /// - Parameters:
    ///   - isActive: ``Key/isActive`` from the notification.
    ///   - announcedRemaining: ``Key/remainingSeconds``, if present.
    ///   - cachedRemaining: The coordinator's local countdown, or nil when the moon is idle.
    /// - Returns: The length to pass to the local countdown, or nil to leave it.
    /// - SeeAlso: ``RadioPlayerCoordinator/sleepTimerStateDidChange(_:)``,
    ///   ``SharedPlayerManager/setSleepTimer(duration:)``.
    static func countdownSeed(
        isActive: Bool,
        announcedRemaining: Int?,
        cachedRemaining: Int?
    ) -> Int? {
        guard isActive, let announcedRemaining, announcedRemaining > 0 else { return nil }
        guard cachedRemaining != announcedRemaining else { return nil }
        return announcedRemaining
    }
}

extension SharedPlayerManager {

    /// Schedules a sleep timer that pauses playback after the given duration.
    ///
    /// Replaces any existing timer and cancels a ramp already in progress. `duration`
    /// is in seconds (e.g. `30 * 60` for 30 minutes). The last
    /// ``SleepTimerFadePolicy/defaultDuration`` seconds fade `AVPlayer.volume` to 0,
    /// then ``sleepTimerDidFire()`` runs the existing elapsed-pause stop. A shorter
    /// timer fades across its whole length. Off (configured duration `0`) does not ramp.
    ///
    /// `sleepTimerRemainingSeconds` is written once at schedule. The countdown loop
    /// does not mutate actor state every second — coordinator UI glue decrements
    /// locally. This method posts one ``SleepTimerNotification`` with that length
    /// so the moon updates for an App Intent as well as a later foreground sync.
    /// Best-effort while backgrounded (the actor task may suspend with the app).
    /// Backgrounding does not cancel the fade.
    ///
    /// A stopped or paused session still arms the countdown. ``playbackIntent``
    /// changes to ``.sleepTimer`` only when ``currentVisualState`` is ``.playing``
    /// or the intent is already an active playback intent. ``.userPaused`` stays
    /// ``.userPaused`` until the deadline, when ``applySleepTimerElapsedPause()``
    /// runs anyway. The in-app preset button uses this same rule.
    ///
    /// - Parameter duration: Timer length in seconds. `<= 0` leaves the timer disarmed.
    /// - Returns: Whole seconds armed, or `nil` when `duration` is not positive.
    /// - SeeAlso: ``cancelSleepTimer(restorePlaybackIntent:notifyStateChange:)``,
    ///   ``isSleepTimerArmed``, ``SleepTimerFadePolicy``,
    ///   ``applySleepTimerElapsedPause()``, ``SleepTimerNotification/countdownSeed(isActive:announcedRemaining:cachedRemaining:)``.
    @discardableResult
    func setSleepTimer(duration: TimeInterval) async -> Int? {
        await cancelSleepTimer(restorePlaybackIntent: false, notifyStateChange: false)
        guard duration > 0 else { return nil }

        let totalSeconds = max(1, Int(duration.rounded(.up)))
        sleepTimerRemainingSeconds = totalSeconds

        if currentVisualState == .playing || currentPlaybackIntent.isActivePlaybackIntent {
            updatePlaybackIntent(to: .sleepTimer)
            DirectStreamingPlayer.shared.cancelPendingStartupRecovery()
        }

        sleepTimerTask = Task {
            await runSleepTimerCountdown(totalSeconds: totalSeconds)
        }

        #if DEBUG
        print("[SharedPlayerManager] SleepTimer scheduled for \(totalSeconds)s (playbackIntent = .sleepTimer)")
        #endif
        await SleepTimerNotification.postStateChange(isActive: true, remainingSeconds: totalSeconds)
        return totalSeconds
    }

    /// True while a countdown task is armed.
    ///
    /// ``cancelSleepTimer(restorePlaybackIntent:notifyStateChange:)`` posts the
    /// inactive UI broadcast only when this is true. ``CancelSleepTimerIntent``
    /// speaks the existing cancel-timer title when this is true, and returns
    /// no dialog when it is not.
    ///
    /// - SeeAlso: ``setSleepTimer(duration:)``, ``CancelSleepTimerIntent``.
    var isSleepTimerArmed: Bool {
        sleepTimerTask != nil
    }

    /// Cancels any active sleep timer without changing playback transport.
    ///
    /// Also cancels the fade task and restores relative gain to `1` immediately so a
    /// mid-ramp cancel cannot leave `AVPlayer.volume` low.
    ///
    /// - Parameter restorePlaybackIntent: When `true`, an active countdown that still shows
    ///   `.playing` reverts intent to `.shouldBePlaying`. Pass `false` when the caller will
    ///   set a new intent immediately (e.g. `stop()`, `play()`, timer replacement).
    /// - Parameter notifyStateChange: When `false`, skips the UI broadcast (timer replacement).
    /// - SeeAlso: ``restoreUnityPlaybackGainForPlaybackStart()``,
    ///   ``invalidateSleepTimerFadeKeepingDeadline()``.
    func cancelSleepTimer(restorePlaybackIntent: Bool = true, notifyStateChange: Bool = true) async {
        let hadTimer = sleepTimerTask != nil
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerRemainingSeconds = nil
        invalidateSleepTimerFadeTask()
        await restoreUnityGainOnEngine()

        if restorePlaybackIntent,
           currentPlaybackIntent == .sleepTimer,
           currentVisualState == .playing {
            updatePlaybackIntent(to: .shouldBePlaying)
        }

        if notifyStateChange, hadTimer {
            await SleepTimerNotification.postStateChange(isActive: false)
        }
    }

    /// Stops the in-flight ramp and restores full relative gain.
    ///
    /// Does not cancel the countdown. A stream switch or any ``play()`` entry uses this
    /// so the deadline can still elapse. The fade task ending as ``cancelled`` makes the
    /// countdown wait out the rest of the window at unity, then hard-stop.
    ///
    /// - Postcondition: ``playbackRelativeGain`` is `1`. No fade task is running.
    /// - SeeAlso: ``preparePlayEntrySurfaces()``, ``resetToPrePlayForNewStream(preserveActiveSleepTimer:connectingLanguageCode:)``.
    func restoreUnityPlaybackGainForPlaybackStart() async {
        invalidateSleepTimerFadeTask()
        await restoreUnityGainOnEngine()
    }

    /// Stops the in-flight ramp without changing the current gain.
    ///
    /// Interruptions and route changes pause the player where it is. The next playback
    /// start calls ``restoreUnityPlaybackGainForPlaybackStart()`` so resume is not quiet.
    /// The countdown keeps its deadline.
    ///
    /// - SeeAlso: ``DirectStreamingPlayer`` interruption and route-change observers.
    func invalidateSleepTimerFadeKeepingDeadline() {
        invalidateSleepTimerFadeTask()
    }

    private func runSleepTimerCountdown(totalSeconds: Int) async {
        let requestedFade = SleepTimerFadePolicy.fadeDuration(
            totalSeconds: totalSeconds,
            configured: configuredSleepTimerFadeDuration
        )
        // Whole seconds so the lead plus the ramp equals the armed timer.
        let fadeWholeSeconds = requestedFade > 0
            ? max(1, Int(requestedFade.rounded(.towardZero)))
            : 0
        let leadSeconds = max(0, totalSeconds - fadeWholeSeconds)
        let fadeSeconds = TimeInterval(fadeWholeSeconds)

        guard await sleepTimerWait(seconds: leadSeconds) else { return }
        guard !Task.isCancelled else { return }

        let stepCount = SleepTimerFadePolicy.stepCount(forFadeDuration: fadeSeconds)
        if stepCount > 0 {
            let stepDelay = Duration.seconds(fadeSeconds / Double(stepCount))
            let fadeTask = startSleepTimerFade(stepCount: stepCount, stepDelay: stepDelay)
            let outcome = await fadeTask.value
            guard !Task.isCancelled else { return }
            if case .cancelled(let steps) = outcome {
                let leftover = max(0, stepCount - steps)
                guard await sleepTimerWait(steps: leftover, delay: stepDelay) else { return }
            }
        }

        guard !Task.isCancelled else { return }

        sleepTimerRemainingSeconds = nil
        sleepTimerTask = nil

        #if DEBUG
        print("[SharedPlayerManager] SleepTimer elapsed — stopping playback")
        #endif

        await sleepTimerDidFire()
    }

    /// One owned ramp. Cancels whatever fade is already running before starting.
    private func startSleepTimerFade(
        stepCount: Int,
        stepDelay: Duration
    ) -> Task<SleepTimerFadeResult, Never> {
        sleepTimerFadeTask?.cancel()
        sleepTimerFadeGeneration &+= 1
        let generation = sleepTimerFadeGeneration
        let task = Task { [generation, stepCount, stepDelay] in
            await self.runSleepTimerFade(
                generation: generation,
                stepCount: stepCount,
                stepDelay: stepDelay
            )
        }
        sleepTimerFadeTask = task
        return task
    }

    private func runSleepTimerFade(
        generation: UInt64,
        stepCount: Int,
        stepDelay: Duration
    ) async -> SleepTimerFadeResult {
        // Known start. A reused player may still be at an old gain.
        guard generation == sleepTimerFadeGeneration, !Task.isCancelled else {
            return .cancelled(steps: 0)
        }
        await restoreUnityGainOnEngine()

        var completed = 0
        for step in 1...stepCount {
            if Task.isCancelled || generation != sleepTimerFadeGeneration {
                return .cancelled(steps: completed)
            }
            let gain = SleepTimerFadePolicy.gain(atStep: step, of: stepCount)
            let applied = await applySleepTimerFadeGain(gain, generation: generation)
            guard applied else { return .cancelled(steps: completed) }
            completed = step
            if step == stepCount { break }
            do {
                try await sleepForSleepTimer(stepDelay)
            } catch {
                return .cancelled(steps: completed)
            }
        }
        if Task.isCancelled || generation != sleepTimerFadeGeneration {
            return .cancelled(steps: completed)
        }
        return .completed(steps: completed)
    }

    private func sleepTimerDidFire() async {
        #if DEBUG
        sleepTimerFadeTrace.append(.elapsedPause)
        #endif
        // Delegates to applySleepTimerElapsedPause (SharedPlayerManager+AppGroup.swift).
        // That method writes the .userPaused visual + .sleepTimer intent, awaits
        // engine-complete interruption stop, deactivates the audio session, persists
        // the widget snapshot, and posts SleepTimerNotification so the main-app
        // coordinator can sync its live UI (see sleepTimerStateDidChange).
        // Relative gain is restored after that stop so a faded player cannot linger.
        await applySleepTimerElapsedPause()
        invalidateSleepTimerFadeTask()
        await restoreUnityGainOnEngine()
    }

    /// Drops the fade task and bumps the generation so a step already queued on the
    /// main actor cannot land after the restore.
    private func invalidateSleepTimerFadeTask() {
        sleepTimerFadeGeneration &+= 1
        sleepTimerFadeTask?.cancel()
        sleepTimerFadeTask = nil
    }

    private func restoreUnityGainOnEngine() async {
        await MainActor.run {
            DirectStreamingPlayer.shared.restoreUnityPlaybackGain()
        }
    }

    /// Writes one ramp sample. Returns `false` when this generation is no longer current
    /// (the write is repaired back to unity in that case).
    private func applySleepTimerFadeGain(_ gain: Float, generation: UInt64) async -> Bool {
        guard generation == sleepTimerFadeGeneration else { return false }
        await MainActor.run {
            DirectStreamingPlayer.shared.applyPlaybackRelativeGain(gain)
        }
        guard generation == sleepTimerFadeGeneration else {
            await MainActor.run {
                DirectStreamingPlayer.shared.restoreUnityPlaybackGain()
            }
            return false
        }
        #if DEBUG
        sleepTimerFadeTrace.append(.gain(gain))
        #endif
        return true
    }

    private func sleepTimerWait(seconds: Int) async -> Bool {
        guard seconds > 0 else { return !Task.isCancelled }
        for _ in 0..<seconds {
            if Task.isCancelled { return false }
            do {
                try await sleepForSleepTimer(.seconds(1))
            } catch {
                return false
            }
        }
        return !Task.isCancelled
    }

    private func sleepTimerWait(steps: Int, delay: Duration) async -> Bool {
        guard steps > 0 else { return !Task.isCancelled }
        for _ in 0..<steps {
            if Task.isCancelled { return false }
            do {
                try await sleepForSleepTimer(delay)
            } catch {
                return false
            }
        }
        return !Task.isCancelled
    }

    private func sleepForSleepTimer(_ duration: Duration) async throws {
        #if DEBUG
        try await sleepTimerDelayHandler(duration)
        #else
        try await Task.sleep(for: duration)
        #endif
    }

    private var configuredSleepTimerFadeDuration: TimeInterval {
        #if DEBUG
        sleepTimerFadeConfiguredDuration
        #else
        SleepTimerFadePolicy.defaultDuration
        #endif
    }

    #if DEBUG
    /// Pins the fade length for unit tests. `0` is Off (hard stop).
    func _test_setSleepTimerFadeDuration(_ duration: TimeInterval) {
        sleepTimerFadeConfiguredDuration = duration
    }

    /// Replaces countdown and fade waits. Pass a manual clock from tests.
    func _test_setSleepTimerDelay(_ handler: @escaping @Sendable (Duration) async throws -> Void) {
        sleepTimerDelayHandler = handler
    }

    /// Restores the wall clock, the 30 s fade, and an empty trace.
    func _test_resetSleepTimerTiming() {
        sleepTimerFadeConfiguredDuration = SleepTimerFadePolicy.defaultDuration
        sleepTimerDelayHandler = { duration in
            try await Task.sleep(for: duration)
        }
        sleepTimerFadeTrace.removeAll()
    }

    func _test_sleepTimerFadeTrace() -> [SleepTimerFadeTraceEvent] {
        sleepTimerFadeTrace
    }
    #endif
}
#endif
