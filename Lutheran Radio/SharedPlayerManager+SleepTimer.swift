//
//  SharedPlayerManager+SleepTimer.swift
//  Lutheran Radio
//
//  Sleep timer: schedules automatic pause via SharedPlayerManager.stop().
//  Main app target only (no widget / Live Activity countdown in v1).
//
//  Created by Jari Lammi on 5.6.2026.
//

#if LUTHERAN_MAIN_APP
import Foundation

extension SharedPlayerManager {

    /// Schedules a sleep timer that automatically pauses playback after the given duration.
    ///
    /// Replaces any existing timer. `duration` is in seconds (e.g. `30 * 60` for 30 minutes).
    /// Countdown updates in-memory only (`sleepTimerRemainingSeconds`); persistence runs on fire via `stop()`.
    /// Best-effort while backgrounded (actor task may suspend with the app).
    func setSleepTimer(duration: TimeInterval) async {
        await cancelSleepTimer()
        guard duration > 0 else { return }

        let totalSeconds = max(1, Int(duration.rounded(.up)))
        sleepTimerRemainingSeconds = totalSeconds

        sleepTimerTask = Task {
            await runSleepTimerCountdown(totalSeconds: totalSeconds)
        }

        #if DEBUG
        print("⏱️ [SleepTimer] scheduled for \(totalSeconds)s")
        #endif
    }

    /// Cancels any active sleep timer without changing playback state.
    func cancelSleepTimer() async {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerRemainingSeconds = nil
    }

    private func runSleepTimerCountdown(totalSeconds: Int) async {
        let clock = ContinuousClock()
        var remaining = totalSeconds

        while remaining > 0 {
            if Task.isCancelled {
                sleepTimerRemainingSeconds = nil
                return
            }

            sleepTimerRemainingSeconds = remaining

            do {
                try await Task.sleep(for: .seconds(1), clock: clock)
            } catch {
                sleepTimerRemainingSeconds = nil
                return
            }

            remaining -= 1
        }

        guard !Task.isCancelled else {
            sleepTimerRemainingSeconds = nil
            return
        }

        sleepTimerRemainingSeconds = nil
        sleepTimerTask = nil

        #if DEBUG
        print("⏱️ [SleepTimer] fired — stopping playback")
        #endif

        await sleepTimerDidFire()
    }

    private func sleepTimerDidFire() async {
        await stop()
    }
}
#endif