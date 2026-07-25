//
//  RadioPlayerCoordinator+SleepTimer.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 25.7.2026.
//
//  Sleep-timer UI glue domain for RadioPlayerCoordinator (mechanical split).
//
//  Owns: SwiftUI dialog settle windows, preset/cancel handlers, local countdown
//  Task + VM remaining sync, SleepTimerNotification observer, interaction window
//  that defers Now Playing title apply during modal settle, and the deferred
//  metadata apply on finish.
//
//  Does not own: timer duration authority or elapsed pause semantics
//  (SharedPlayerManager.setSleepTimer / cancelSleepTimer / applySleepTimerElapsedPause),
//  dialog presentation (PlaybackControlsView `.confirmationDialog`), privacy clear
//  (`confirmAndClearLocalState` remains on the main coordinator file), or App Group keys.
//
//  Public/entry surfaces on the same type: wireSleepTimerUIGlue() from
//  wireAndInitialSetup; syncSleepTimerDisplayFromActorIfNeeded from view-appear
//  resurrection; stopLocalSleepTimerDisplay from privacy-clear observer.
//
//  - SeeAlso: ``SharedPlayerManager/setSleepTimer(duration:)``,
//    ``SharedPlayerManager/cancelSleepTimer(restorePlaybackIntent:notifyStateChange:)``,
//    ``SharedPlayerManager/applySleepTimerElapsedPause()``,
//    ``SleepTimerNotification``, ``PlayerViewModel``, `PlaybackControlsView`,
//    CODING_AGENT.md (Single Source of Truth Principles).
//

import UIKit
import WidgetSurface

extension RadioPlayerCoordinator {

    // MARK: - Sleep timer UI glue
    //
    // Presentation: sole surface is SwiftUI `.confirmationDialog` in PlaybackControlsView
    // (15/30/45/60 presets + conditional Cancel + always-present Clear local state).
    // Choices arrive via PlayerViewModel action closures into the handle* methods below.
    //
    // This domain owns settle timing, interaction flags, local countdown Task, VM sync,
    // and SharedPlayerManager set/cancel calls. SPM remains the timer authority.

    /// Wires sleep-timer VM action closures and the `SleepTimerNotification` observer.
    ///
    /// Called once from ``wireAndInitialSetup()`` after the view model is attached.
    /// Idempotent with respect to observer identity only if setup runs once per coordinator
    /// lifetime (production path); deinit removes the observer by name.
    ///
    /// - SeeAlso: ``handleSleepTimerPresetSelected(minutes:)``,
    ///   ``handleSleepTimerCancelSelected()``, ``sleepTimerStateDidChange(_:)``
    func wireSleepTimerUIGlue() {
        if let vm = viewModel {
            // The SwiftUI .confirmationDialog in PlaybackControlsView calls these;
            // this domain owns preset/cancel + settle + display + SPM set/cancel.
            vm.onSleepTimerPresetSelected = { [weak self] minutes in
                self?.handleSleepTimerPresetSelected(minutes: minutes)
            }
            vm.onSleepTimerCancelSelected = { [weak self] in
                self?.handleSleepTimerCancelSelected()
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sleepTimerStateDidChange(_:)),
            name: SleepTimerNotification.stateDidChange,
            object: nil
        )
    }

    /// Pushes the remaining sleep timer seconds into the VM (if wired).
    ///
    /// Moon glyph and accessibility value on `PlaybackControlsView` observe
    /// `PlayerViewModel.sleepTimerRemaining`.
    ///
    /// - Parameter remaining: Whole seconds remaining, or `nil` when inactive.
    /// - SeeAlso: ``beginLocalSleepTimerDisplay(remaining:)``, ``stopLocalSleepTimerDisplay()``
    @MainActor
    func syncSleepTimerToViewModel(remaining: Int?) {
        viewModel?.sleepTimerRemaining = remaining.map { TimeInterval($0) }
    }

    @MainActor
    func handleSleepTimerPresetSelected(minutes: Int) {
        isSleepTimerInteractionActive = true
        backgroundImageController.cancelDeferredForModalInteraction()

        let totalSeconds = max(1, minutes * 60)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: Self.sleepTimerDialogSettleNs)
            let confirmed = await SharedPlayerManager.shared.setSleepTimer(
                duration: TimeInterval(totalSeconds)
            )
            guard let confirmed else {
                self.finishSleepTimerInteraction(applyDeferredVisuals: false)
                return
            }
            try? await Task.sleep(nanoseconds: Self.sleepTimerPostScheduleUISettleNs)
            guard !Task.isCancelled else { return }
            self.beginLocalSleepTimerDisplay(remaining: confirmed)
            try? await Task.sleep(nanoseconds: Self.sleepTimerDeferredVisualSettleNs)
            guard !Task.isCancelled else { return }
            self.finishSleepTimerInteraction(applyDeferredVisuals: true)
            self.backgroundImageController.rescheduleDeferredAfterModalIfNeeded()
        }
    }

    @MainActor
    func handleSleepTimerCancelSelected() {
        isSleepTimerInteractionActive = true
        backgroundImageController.cancelDeferredForModalInteraction()

        Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            self.stopLocalSleepTimerDisplay()
            await SharedPlayerManager.shared.cancelSleepTimer()
            self.finishSleepTimerInteraction(applyDeferredVisuals: true)
            self.backgroundImageController.rescheduleDeferredAfterModalIfNeeded()
        }
    }

    @MainActor
    private func finishSleepTimerInteraction(applyDeferredVisuals: Bool) {
        isSleepTimerInteractionActive = false
        guard applyDeferredVisuals, let metadata = pendingMetadataVisualRefresh else { return }
        pendingMetadataVisualRefresh = nil
        updateNowPlayingInfo(title: metadata)
        // SwiftUI photo logic reacts to VM metadata change.
    }

    /// Receives broadcasts from SleepTimerNotification when a sleep timer is scheduled,
    /// ticks (first value only), or becomes inactive (elapsed or cancelled).
    ///
    /// - Important: This observer is the **main-app-only** channel that reconciles the
    ///   authoritative `currentVisualState` (from SharedPlayerManager SSOT) into the live
    ///   in-app UI after an internal sleep-timer pause. Widget/Live Activity consumers use
    ///   the persisted snapshot written by `applySleepTimerElapsedPause`; the main app
    ///   does not receive a status callback or actionable Darwin "pause" for this path.
    ///
    /// When the timer elapses:
    /// - `applySleepTimerElapsedPause` forces `currentVisualState = .userPaused` (so
    ///   widgets show paused) while leaving `playbackIntent = .sleepTimer` (non-sticky
    ///   so resurrection logic and clearUserPausedLockIfNeeded can distinguish it).
    /// - Direct stop uses `reason: .interruption` (effectiveSilent + teardown guard
    ///   suppresses KVO/status callbacks).
    /// - The self-posted Darwin pause is suppressed by `DarwinSelfEchoGuard`.
    /// - Therefore this observer must explicitly pull `currentVisualState` and call
    ///   `updateUI(for:)` so the main app chrome (VM → SwiftUI controls tint/glyph,
    ///   colors, pill) leaves the stale `.playing` (green) state.
    ///
    /// The `lastAppliedVisualState` guard inside `updateUI` makes the call a cheap no-op
    /// on cancel paths where visual state did not change.
    ///
    /// - SeeAlso: ``SharedPlayerManager/applySleepTimerElapsedPause()``,
    ///   `PlaybackIntent.sleepTimer`, `SleepTimerNotification`,
    ///   `handleStatusChange(_:reasonKey:)`, CODING_AGENT.md (Single Source of Truth Principles),
    ///   SharedPlayerManager.swift (resurrection table + applySleepTimerElapsedPause).
    ///
    /// - Note: Only the first remaining-seconds value seeds the local countdown to avoid
    ///   per-second actor hops; this domain owns decrementing locally.
    @objc func sleepTimerStateDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let isActive = notification.userInfo?[SleepTimerNotification.Key.isActive] as? Bool ?? false
            if !isActive {
                self.stopLocalSleepTimerDisplay()

                // AGENT NOTE (sleep timer visual SSOT sync):
                // The main-app UI (green playing state) can diverge from the PersistedWidgetState
                // snapshot after sleep fire because the stop is silent and the Darwin pause is
                // intentionally suppressed as a self-echo. We must re-read the actor SSOT here
                // and drive updateUI so the in-app controls, VM, and chrome match .userPaused.
                // Widgets are already correct via the snapshot write + WidgetRefreshManager.
                // This is the designated place for the main-app side effect of timer completion.
                let visualState = await SharedPlayerManager.shared.currentVisualState
                self.updateUI(for: visualState)
                return
            }
            if let remaining = notification.userInfo?[SleepTimerNotification.Key.remainingSeconds] as? Int,
               remaining > 0,
               self.cachedSleepTimerRemaining == nil {
                self.beginLocalSleepTimerDisplay(remaining: remaining)
                self.syncSleepTimerToViewModel(remaining: remaining)
            }
        }
    }

    /// Seeds or clears local countdown display from actor-held remaining seconds
    /// (e.g. after view appear when a timer may still be running).
    ///
    /// - SeeAlso: ``SharedPlayerManager/sleepTimerRemainingSeconds``,
    ///   ``beginLocalSleepTimerDisplay(remaining:)``, ``stopLocalSleepTimerDisplay()``
    @MainActor
    func syncSleepTimerDisplayFromActorIfNeeded() async {
        let remaining = await SharedPlayerManager.shared.sleepTimerRemainingSeconds
        if let remaining, remaining > 0 {
            beginLocalSleepTimerDisplay(remaining: remaining)
            syncSleepTimerToViewModel(remaining: remaining)
        } else if cachedSleepTimerRemaining != nil {
            stopLocalSleepTimerDisplay()
        }
    }

    @MainActor
    private func beginLocalSleepTimerDisplay(remaining: Int) {
        cachedSleepTimerRemaining = remaining
        // Drive SwiftUI VM countdown (moon glyph + accessibility value observe sleepTimerRemaining).
        syncSleepTimerToViewModel(remaining: remaining)

        sleepTimerDisplayTask?.cancel()
        sleepTimerDisplayTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            var remainingSeconds = self.cachedSleepTimerRemaining ?? 0

            while remainingSeconds > 0, !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }

                remainingSeconds -= 1
                self.cachedSleepTimerRemaining = remainingSeconds > 0 ? remainingSeconds : nil
                // SwiftUI observes sleepTimerRemaining on VM; countdown Task only mutates cache.
            }
        }
    }

    /// Cancels the local countdown Task and clears VM remaining.
    ///
    /// Called on timer cancel/elapse, privacy clear observer, and when actor remaining is gone.
    /// Does not call `SharedPlayerManager.cancelSleepTimer` — callers that need actor cancel
    /// do so explicitly (e.g. ``handleSleepTimerCancelSelected()``).
    ///
    /// - SeeAlso: ``beginLocalSleepTimerDisplay(remaining:)``, ``syncSleepTimerToViewModel(remaining:)``
    @MainActor
    func stopLocalSleepTimerDisplay() {
        sleepTimerDisplayTask?.cancel()
        sleepTimerDisplayTask = nil
        cachedSleepTimerRemaining = nil
        syncSleepTimerToViewModel(remaining: nil)
    }
}
