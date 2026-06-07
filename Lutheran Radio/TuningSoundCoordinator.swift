//
//  TuningSoundCoordinator.swift
//  Lutheran Radio
//
//  Coordinates AVAudioPlayer tuning clips with SharedPlayerManager.play().
//  ViewController signals start/finish; play() awaits delegate completion instead of a fixed delay.
//
//  Created by Jari Lammi on 5.6.2026.
//

import Foundation

/// Bridges `AVAudioPlayer` tuning clips in ViewController with `SharedPlayerManager.play()`.
actor TuningSoundCoordinator {
    static let shared = TuningSoundCoordinator()

    private var isPlaybackActive = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var safetyTimeoutTask: Task<Void, Never>?

    private init() {}

    /// Tuning clip began (`AVAudioPlayer.play()` returned true).
    func notifyPlaybackStarted(estimatedDuration: TimeInterval) {
        safetyTimeoutTask?.cancel()
        isPlaybackActive = true

        let cappedSeconds = min(max(estimatedDuration, 0.25), 5.0)
        let safetyDuration = Duration.seconds(cappedSeconds + 0.25)

        safetyTimeoutTask = Task {
            try? await Task.sleep(for: safetyDuration)
            await TuningSoundCoordinator.shared.notifyPlaybackFinished(source: .safetyTimeout)
        }
    }

    /// No clip is playing (load failure, debounced skip, or `play()` returned false).
    func notifyNoActivePlayback() {
        safetyTimeoutTask?.cancel()
        safetyTimeoutTask = nil
        guard isPlaybackActive else { return }
        isPlaybackActive = false
        resumeFinishWaiters()
    }

    enum FinishSource: Sendable {
        case delegate
        case safetyTimeout
        case cancelled
    }

    /// Delegate completion, safety timeout, or explicit stop before main `AVPlayer` attach.
    func notifyPlaybackFinished(source: FinishSource = .delegate) {
        safetyTimeoutTask?.cancel()
        safetyTimeoutTask = nil
        guard isPlaybackActive else { return }
        isPlaybackActive = false

        #if DEBUG
        switch source {
        case .delegate:
            break
        case .safetyTimeout:
            print("[TuningSoundCoordinator] Tuning wait safety timeout — resuming main playback")
        case .cancelled:
            print("[TuningSoundCoordinator] Tuning playback cancelled — resuming waiters")
        }
        #endif

        resumeFinishWaiters()
    }

    /// Waits until the active clip finishes (delegate) or the safety cap elapses. No-op when idle.
    func waitForActivePlaybackToFinishIfNeeded() async {
        guard isPlaybackActive else {
            #if DEBUG
            print("[TuningSoundCoordinator] Tuning wait skipped — no active tuning clip")
            #endif
            return
        }

        #if DEBUG
        print("⏳ Waiting for tuning sound delegate completion before main playback...")
        #endif

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if !isPlaybackActive {
                continuation.resume()
                return
            }
            finishWaiters.append(continuation)
        }

        #if DEBUG
        print("[TuningSoundCoordinator] Tuning sound wait completed")
        #endif
    }

    private func resumeFinishWaiters() {
        let waiters = finishWaiters
        finishWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
