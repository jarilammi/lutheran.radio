//
//  SharedPlayerManager+SleepTimer.swift
//  Lutheran Radio
//
//  Sleep timer: schedules automatic pause via SharedPlayerManager.stop().
//  Main app target only (no widget / Live Activity countdown in v1).
//
//  UI: SwiftUI confirmationDialog in PlaybackControlsView drives presets/cancel via
//  coordinator. The core setSleepTimer / cancelSleepTimer + actor task + notifications
//  are unchanged.
//
//  Created by Jari Lammi on 5.6.2026.
//

#if LUTHERAN_MAIN_APP
import Foundation
import WidgetSurface

/// In-process sleep-timer state broadcasts (main app only).
/// ViewController owns countdown UI locally; these avoid polling the actor every second.
enum SleepTimerNotification {
    static let stateDidChange = Notification.Name("SleepTimerStateDidChange")

    enum Key {
        static let isActive = "isActive"
        static let remainingSeconds = "remainingSeconds"
    }

    /// Posts on MainActor — ViewController's observer is MainActor-isolated; posting from
    /// SharedPlayerManager's actor executor traps under Swift 6 strict concurrency.
    @MainActor
    static func postStateChange(isActive: Bool, remainingSeconds: Int? = nil) {
        var userInfo: [String: Any] = [Key.isActive: isActive]
        if let remainingSeconds {
            userInfo[Key.remainingSeconds] = remainingSeconds
        }
        NotificationCenter.default.post(name: stateDidChange, object: nil, userInfo: userInfo)
    }
}

extension SharedPlayerManager {

    /// Schedules a sleep timer that automatically pauses playback after the given duration.
    ///
    /// Replaces any existing timer. `duration` is in seconds (e.g. `30 * 60` for 30 minutes).
    /// `sleepTimerRemainingSeconds` is written once at schedule (for one-shot UI sync on foreground).
    /// The countdown loop does not mutate actor state every second — ViewController decrements locally.
    /// Best-effort while backgrounded (actor task may suspend with the app).
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
        return totalSeconds
    }

    /// Cancels any active sleep timer without changing playback state.
    ///
    /// - Parameter restorePlaybackIntent: When `true`, an active countdown that still shows
    ///   `.playing` reverts intent to `.shouldBePlaying`. Pass `false` when the caller will
    ///   set a new intent immediately (e.g. `stop()`, `play()`, timer replacement).
    /// - Parameter notifyStateChange: When `false`, skips the UI broadcast (timer replacement).
    func cancelSleepTimer(restorePlaybackIntent: Bool = true, notifyStateChange: Bool = true) async {
        let hadTimer = sleepTimerTask != nil
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerRemainingSeconds = nil

        if restorePlaybackIntent,
           currentPlaybackIntent == .sleepTimer,
           currentVisualState == .playing {
            updatePlaybackIntent(to: .shouldBePlaying)
        }

        if notifyStateChange, hadTimer {
            await SleepTimerNotification.postStateChange(isActive: false)
        }
    }

    private func runSleepTimerCountdown(totalSeconds: Int) async {
        let clock = ContinuousClock()
        var remaining = totalSeconds

        while remaining > 0 {
            if Task.isCancelled {
                return
            }

            do {
                try await Task.sleep(for: .seconds(1), clock: clock)
            } catch {
                return
            }

            remaining -= 1
        }

        guard !Task.isCancelled else {
            return
        }

        sleepTimerRemainingSeconds = nil
        sleepTimerTask = nil

        #if DEBUG
        print("[SharedPlayerManager] SleepTimer elapsed — stopping playback")
        #endif

        await sleepTimerDidFire()
    }

    private func sleepTimerDidFire() async {
        // Delegates to applySleepTimerElapsedPause (defined in SharedPlayerManager.swift).
        // That method writes the .userPaused visual + .sleepTimer intent, stops the player
        // silently, persists the widget snapshot, and posts SleepTimerNotification so the
        // main-app coordinator can sync its live UI (see sleepTimerStateDidChange).
        await applySleepTimerElapsedPause()
    }
}
#endif
