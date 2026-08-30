//
//  RadioPlayerCoordinator+Tuning.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.7.2026.
//
//  Tuning-sound domain for RadioPlayerCoordinator (mechanical split).
//
//  Owns: cold-launch special clip (`playSpecialTuningSound`), stream-switch
//  delight clip (`playTuningSound`), interrupt/stop (`stopTuningSound`), and
//  `AVAudioPlayerDelegate` finish/error paths that resume `TuningSoundCoordinator`
//  waiters after the special clip.
//
//  Does not own: engine clip construction/session activate
//  (`DirectStreamingPlayer.startLocalClipPlayer` / audio-session domain),
//  cold-launch attach sequencing (`SharedPlayerManager.play` after
//  `TuningSoundCoordinator` wait), stream-switch orchestration
//  (`completeStreamSwitch` / language selection live in `+StreamSwitch` and
//  call into this domain for delight clips), or secured stream playback.
//
//  Stored clip stamps (`tuningPlayer`, `isTuningSoundPlaying`,
//  `hasPlayedSpecialTuningSound`, `lastTuningSoundTime`) remain on the primary
//  type body (extensions cannot declare stored properties); this file owns the
//  behavior that mutates them.
//
//  Public/entry surfaces on the same type:
//  - ``playSpecialTuningSound(completion:)`` — presentable cold launch
//  - ``playTuningSound(animateNeedleTo:)`` — language / stream-switch paths
//  - ``stopTuningSound()`` — host interruption / route / disconnect chrome stop
//
//  - SeeAlso: ``DirectStreamingPlayer/startLocalClipPlayer(contentsOf:volume:numberOfLoops:)``,
//    ``DirectStreamingPlayer/configureAudioSessionAsync()``, `TuningSoundCoordinator`,
//    ``SharedPlayerManager/play()``, RadioPlayerCoordinator.swift (isolation map),
//    CODING_AGENT.md (Single Source of Truth Principles).
//

import UIKit
@unsafe @preconcurrency import AVFoundation
import WidgetSurface

extension RadioPlayerCoordinator {

    // MARK: - Tuning sounds (stream selection delight + cold-launch special clip)

    /// Plays the cold-launch special tuning clip, then signals ``TuningSoundCoordinator``.
    ///
    /// Session configuration and clip start go through
    /// ``DirectStreamingPlayer/startLocalClipPlayer(contentsOf:volume:numberOfLoops:)`` so
    /// `AVAudioPlayer` prepare/play never runs on the main actor. Initial stream attach remains
    /// `SharedPlayerManager.play()` after the coordinator wait — this method must not start the
    /// secured stream.
    ///
    /// AGENT NOTE: Single production owner for the special cold-launch clip. Presentable
    /// cold launch invokes this after factory hygiene + first become-active; the host does not
    /// retain clip state or conform to `AVAudioPlayerDelegate`. Session configure inside
    /// ``startLocalClipPlayer`` waits for factory-reset Now Playing phase 2 deactivate on
    /// ``audioSessionMutationTail``. SessionCore deactivate of a never-configured session
    /// is skipped so the first presentable `setCategory` is not poisoned with OSStatus -50.
    /// First presentable configure still settles SessionCore before that `setCategory`.
    ///
    /// - Parameter completion: Optional early-exit hook; successful start finishes via
    ///   `AVAudioPlayerDelegate` → ``TuningSoundCoordinator/notifyPlaybackFinished(source:)``.
    /// - SeeAlso: ``DirectStreamingPlayer/startLocalClipPlayer(contentsOf:volume:numberOfLoops:)``,
    ///   ``DirectStreamingPlayer/configureAudioSessionAsync()``, `TuningSoundCoordinator`,
    ///   `SharedPlayerManager.play()`.
    func playSpecialTuningSound(completion: (() -> Void)? = nil) async {
        guard !hasPlayedSpecialTuningSound else {
            #if DEBUG
            print("[RadioPlayerCoordinator] Special tuning sound already played, skipping")
            #endif
            completion?()
            return
        }

        guard let tuningURL = Bundle.main.url(forResource: "special_tuning_sound", withExtension: "wav") else {
            #if DEBUG
            print("[RadioPlayerCoordinator] Error: special_tuning_sound.wav not found in bundle")
            #endif
            await TuningSoundCoordinator.shared.notifyNoActivePlayback()
            completion?()
            return
        }

        do {
            // SSOT: session activate + off-main AVAudioPlayer construct/prepare/play.
            // Retain the returned player on MainActor; delegate finish still owns waiters.
            // Volume default 1.0 (full relative gain). System output volume is SSOT.
            guard let clip = try await streamingPlayer.startLocalClipPlayer(
                contentsOf: tuningURL,
                volume: 1.0,
                numberOfLoops: 0
            ) else {
                await TuningSoundCoordinator.shared.notifyNoActivePlayback()
                completion?()
                return
            }

            let player = clip.player
            player.delegate = self
            tuningPlayer = player
            isTuningSoundPlaying = clip.didStart
            hasPlayedSpecialTuningSound = true
            lastTuningSoundTime = Date()

            #if DEBUG
            print("[RadioPlayerCoordinator] Set special tuning sound volume to \(player.volume)")
            print(clip.didStart
                  ? "[RadioPlayerCoordinator] Special tuning sound started playing"
                  : "[RadioPlayerCoordinator] Failed to start special tuning sound")
            #endif

            // Never trigger secured stream playback after tuning sound.
            // Initial playback is SharedPlayerManager.play() after the TuningSoundCoordinator wait.
            if clip.didStart {
                await TuningSoundCoordinator.shared.notifyPlaybackStarted(estimatedDuration: player.duration)
            } else {
                await TuningSoundCoordinator.shared.notifyNoActivePlayback()
                tuningPlayer = nil
            }
        } catch {
            #if DEBUG
            print("[RadioPlayerCoordinator] Error loading special tuning sound: \(error.localizedDescription)")
            #endif
            await TuningSoundCoordinator.shared.notifyNoActivePlayback()
            completion?()
            tuningPlayer = nil
        }
    }

    // MARK: - AVAudioPlayerDelegate (special cold-launch clip finish only)

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard player === self.tuningPlayer else { return }
            #if DEBUG
            print("[RadioPlayerCoordinator] Special tuning sound finished playing, success: \(flag)")
            #endif
            self.isTuningSoundPlaying = false
            self.tuningPlayer = nil
            await TuningSoundCoordinator.shared.notifyPlaybackFinished()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard player === self.tuningPlayer else { return }
            #if DEBUG
            print("[RadioPlayerCoordinator] Special tuning decode error: \(error?.localizedDescription ?? "Unknown")")
            #endif
            self.isTuningSoundPlaying = false
            self.tuningPlayer = nil
            await TuningSoundCoordinator.shared.notifyPlaybackFinished()
        }
    }

    /// Stream-switch / language-selector tuning delight clip.
    ///
    /// Uses ``DirectStreamingPlayer/startLocalClipPlayer(contentsOf:volume:numberOfLoops:)`` so
    /// session configuration and `AVAudioPlayer` prepare/play stay off the main-actor
    /// activation path. Needle index is applied on the main actor after start returns.
    ///
    /// - Parameter index: Optional stream index to commit to the view model while the clip plays.
    /// - SeeAlso: ``DirectStreamingPlayer/startLocalClipPlayer(contentsOf:volume:numberOfLoops:)``,
    ///   ``DirectStreamingPlayer/configureAudioSessionAsync()``.
    func playTuningSound(animateNeedleTo index: Int? = nil) async {
        guard let tuningURL = Bundle.main.url(forResource: "tuning_sound_1", withExtension: "wav") else {
            #if DEBUG
            print("[RadioPlayerCoordinator] Error: tuning_sound_1.wav not found in bundle")
            #endif
            if let idx = index {
                viewModel?.selectedStreamIndex = idx
            }
            return
        }

        // Debounce rapid calls (verbatim)
        if let lastTime = lastTuningSoundTime, Date().timeIntervalSince(lastTime) < 0.3 {
            #if DEBUG
            print("[RadioPlayerCoordinator] playTuningSound: Debouncing rapid tuning sound call")
            #endif
            if let idx = index {
                viewModel?.selectedStreamIndex = idx
            }
            return
        }

        do {
            guard let clip = try await streamingPlayer.startLocalClipPlayer(
                contentsOf: tuningURL,
                numberOfLoops: 0
            ) else {
                if let idx = index {
                    viewModel?.selectedStreamIndex = idx
                }
                return
            }

            clip.player.delegate = nil
            tuningPlayer = clip.player
            isTuningSoundPlaying = clip.didStart
            lastTuningSoundTime = Date()

            #if DEBUG
            print("[RadioPlayerCoordinator] Playing tuning sound (duration: \(clip.player.duration)s, didStart=\(clip.didStart))")
            #endif

            if let idx = index {
                viewModel?.selectedStreamIndex = idx
            }

            let duration = clip.player.duration > 0 ? clip.player.duration : 0.8
            try? await Task.sleep(for: .seconds(duration + 0.1))
            isTuningSoundPlaying = false
        } catch {
            #if DEBUG
            print("[RadioPlayerCoordinator] Failed to play tuning sound: \(error)")
            #endif
            isTuningSoundPlaying = false
            if let idx = index {
                viewModel?.selectedStreamIndex = idx
            }
        }
    }

    /// Stops any in-flight tuning clip and resumes ``TuningSoundCoordinator`` waiters when needed.
    ///
    /// Called from host interruption / route / disconnect paths that must silence delight audio
    /// without sticky-pausing secured playback. When a special cold-launch clip was active,
    /// notifies the coordinator so `SharedPlayerManager.play()` waiters can proceed.
    ///
    /// - SeeAlso: ``playSpecialTuningSound(completion:)``, `TuningSoundCoordinator`
    func stopTuningSound() {
        let wasActive = tuningPlayer != nil || isTuningSoundPlaying
        tuningPlayer?.stop()
        tuningPlayer = nil
        isTuningSoundPlaying = false
        if wasActive {
            // Resume any SharedPlayerManager.play() waiters if special clip was interrupted.
            Task { await TuningSoundCoordinator.shared.notifyPlaybackFinished(source: .cancelled) }
        }
        #if DEBUG
        print("[RadioPlayerCoordinator] Tuning sound stopped")
        #endif
    }
}
