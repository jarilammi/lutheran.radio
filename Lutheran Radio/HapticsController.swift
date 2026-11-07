//
//  HapticsController.swift
//  Lutheran Radio
//
//  Owner of one-shot play / privacy-clear haptics. RadioPlayerCoordinator is
//  the only caller (wire + play).
//
//  Invariant: do not create or keep a CHHapticEngine. Playback session
//  activation stops that engine (`audioSessionInterrupt`); start() then
//  times out (-4808) and player.start fails (OSStatus `what`). The catch
//  path already played UIImpactFeedbackGenerator — that is the haptic that
//  worked on device. Promote that fallback to the only surface. A warm
//  engine also holds the Taptic Engine and mutes later UIKit impacts.
//
//  UIImpactFeedbackGenerator is the sole playback surface. It works while
//  the streaming AVAudioSession is active and does not need a private haptic
//  session. Playback session setCategory / setActive stay in
//  DirectStreamingPlayer+AudioSession.
//
//  Created by Jari Lammi on 13.6.2026.
//

import UIKit
import WidgetSurface

/// When the status adapter may play the became-playing confirmation haptic.
///
/// Device log `haptics_doesnt_work_anymore_on_the_device.txt`: every audible
/// start arrives as `reasonKey: status_playing`. The previous `reasonKey == nil`
/// gate never fired on that path (nil is interruption resume only), so
/// ``HapticsController/playHapticFeedback(style:)`` was not called.
///
/// - SeeAlso: ``HapticsController``,
///   ``RadioPlayerCoordinator/handleStatusChange(_:reasonKey:)``,
///   CODING_AGENT.md (fast test patterns).
enum HapticPlaybackPolicy {

    /// Whether this status delivery should play the light became-playing haptic.
    ///
    /// - Parameters:
    ///   - status: Engine status from the streaming delegate.
    ///   - reasonKey: Exact Localizable key, or `nil` on interruption resume.
    ///   - alreadyPlayedForCurrentAudibleStart: Latch so a later `nil` resume
    ///     plus `status_playing` (or duplicate adapter deliveries) do not buzz twice.
    ///     ``shouldClearAudibleStartHapticLatch(status:reasonKey:)`` keeps this set
    ///     across `status_buffering` and `status_connecting`.
    /// - Returns: `true` for the first `.playing` + (`status_playing` or `nil`) of a start.
    /// - SeeAlso: ``shouldClearAudibleStartHapticLatch(status:reasonKey:)``,
    ///   ``DirectStreamingPlayer/invokeStatusCallbacks(isPlaying:reasonKey:)``
    static func shouldPlayPlayingConfirmation(
        status: PlayerStatus,
        reasonKey: String?,
        alreadyPlayedForCurrentAudibleStart: Bool
    ) -> Bool {
        guard status == .playing, !alreadyPlayedForCurrentAudibleStart else { return false }
        return reasonKey == nil || reasonKey == "status_playing"
    }

    /// Whether ``hasPlayedHapticForCurrentAudibleStart`` must clear so the next audible start can haptic.
    ///
    /// ``invokeStatusCallbacks(isPlaying:reasonKey:)`` maps every non-playing delegate
    /// delivery to coarse ``PlayerStatus/stopped`` and keeps the Localizable key.
    /// `status_buffering` and `status_connecting` sit between the race-lead
    /// `status_playing` and the stable `status_playing` of the same start.
    /// ``handleStatusChange(_:reasonKey:)`` awaits visual and intent before this
    /// latch, so a buffering handler can run after the first impact has already
    /// set it. Clearing on those keys plays a second light impact. The callback
    /// is still delivered; chrome and the status adapter use it.
    ///
    /// A real pause, stop, failure, or interruption still clears. Soft resume can
    /// become audible with no later `status_connecting`, so the pause itself has
    /// to clear the latch. Interruption resume is `reasonKey == nil` with
    /// ``PlayerStatus/playing`` and does not clear.
    ///
    /// - Parameters:
    ///   - status: Coarse engine status. Non-playing deliveries from
    ///     ``invokeStatusCallbacks(isPlaying:reasonKey:)`` are `.stopped`.
    ///   - reasonKey: Exact Localizable key, or `nil` on interruption resume.
    /// - Returns: `false` when `reasonKey` is `status_buffering` or
    ///   `status_connecting`, and when `status` is `.playing`. `true` for every
    ///   other non-playing status.
    /// - SeeAlso: ``shouldPlayPlayingConfirmation(status:reasonKey:alreadyPlayedForCurrentAudibleStart:)``,
    ///   ``RadioPlayerCoordinator/handleStatusChange(_:reasonKey:)``,
    ///   ``DirectStreamingPlayer/invokeStatusCallbacks(isPlaying:reasonKey:)``
    static func shouldClearAudibleStartHapticLatch(
        status: PlayerStatus,
        reasonKey: String?
    ) -> Bool {
        if reasonKey == "status_buffering" || reasonKey == "status_connecting" {
            return false
        }
        return status != .playing
    }
}

/// Dedicated owner for one-shot UIKit impact haptics.
///
/// - Important: Never introduce `CHHapticEngine` here. A warm engine is what
///   silenced the device after playback started.
/// - Note: `@MainActor` — play is a UI turn. UITestMode and Low Power Mode skip.
/// - SeeAlso: ``HapticPlaybackPolicy``, ``RadioPlayerCoordinator/playHapticFeedback(style:)``,
///   ``SharedPlayerManager/isRunningInUITestMode``,
///   `DirectStreamingPlayer+AudioSession` (playback session SSOT),
///   CODING_AGENT.md.
@MainActor
final class HapticsController {

    private let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private let heavyGenerator = UIImpactFeedbackGenerator(style: .heavy)

    /// Warms the impact generators. Does not touch Core Haptics or AVAudioSession.
    ///
    /// Idempotent; safe to call from ``RadioPlayerCoordinator/wireAndInitialSetup()``.
    /// No-op under UITestMode.
    ///
    /// - SeeAlso: ``playHapticFeedback(style:)``
    func prepareIfSupported() {
        guard !SharedPlayerManager.isRunningInUITestMode else { return }
        lightGenerator.prepare()
        heavyGenerator.prepare()
    }

    /// Plays a one-shot impact. Skips under Low Power Mode and UITestMode.
    ///
    /// - Parameter style: `.light` (became playing) or `.heavy` (clear-local-state).
    /// - SeeAlso: ``HapticPlaybackPolicy``, ``prepareIfSupported()``
    func playHapticFeedback(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard !SharedPlayerManager.isRunningInUITestMode else { return }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            #if DEBUG
            print("[HapticsController] Haptics skipped in Low Power Mode")
            #endif
            return
        }

        let generator = (style == .heavy) ? heavyGenerator : lightGenerator
        generator.impactOccurred()
        generator.prepare()
        #if DEBUG
        print("[HapticsController] Impact played: style=\(style)")
        #endif
    }
}
