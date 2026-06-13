//
//  HapticsController.swift
//  Lutheran Radio
//
//  Tiny extraction of the CHHapticEngine lifecycle (lazy creation + reset/stopped handlers),
//  LPM skip, hardware capability gate, transient pattern playback, and UIImpact fallback.
//  Owned by RadioPlayerCoordinator (or thin host in future).
//
//  Exposes prepareIfSupported() (called once in wire) and playHapticFeedback(style:).
//  All observable behavior (skips in LPM, intensity/sharpness mapping, fallback, debug tags)
//  preserved verbatim.
//
//  Created by Jari Lammi on 13.6.2026.
//

import UIKit
import CoreHaptics

/// Tiny dedicated owner for the haptic engine and playback.
/// - Single source for CHHaptic transient events + fallback.
/// - LPM guard and supportsHaptics check centralized (no behavior change).
/// - Coordinator (or future thin owner) calls the narrow surface; no intent or security logic here.
@MainActor
final class HapticsController {

    // MARK: - Engine (moved verbatim from RadioPlayerCoordinator + SAFETY / ownership note)

    // The engine + handlers are self-contained. Handlers restart on reset/stopped (non-system).
    private lazy var hapticEngine: CHHapticEngine? = {
        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true

            engine.resetHandler = { [weak self] in
                do {
                    try self?.hapticEngine?.start()
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        #if DEBUG
                        print("[HapticsController] Haptic engine restarted after reset")
                        #endif
                    }
                } catch {
                    #if DEBUG
                    print("[HapticsController] Failed to restart haptic engine after reset: \(error)")
                    #endif
                }
            }

            engine.stoppedHandler = { reason in
                #if DEBUG
                print("[HapticsController] Haptic engine stopped: reason \(reason.rawValue)")
                #endif
                if reason != .systemError && reason != .engineDestroyed {
                    do {
                        try engine.start()
                        #if DEBUG
                        print("[HapticsController] Haptic engine auto-restarted")
                        #endif
                    } catch {
                        #if DEBUG
                        print("[HapticsController] Failed to auto-restart haptic engine: \(error)")
                        #endif
                    }
                }
            }
            return engine
        } catch {
            #if DEBUG
            print("[HapticsController] Haptics unavailable during creation: \(error)")
            #endif
            return nil
        }
    }()

    // MARK: - Public surface (called by coordinator at wire time and on user interactions)

    /// Touch the lazy (to create + register handlers) and start if the device supports haptics.
    /// Idempotent; safe to call from wireAndInitialSetup.
    func prepareIfSupported() {
        if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            _ = hapticEngine
            startHapticEngine()
        }
    }

    private func startHapticEngine() {
        guard let engine = hapticEngine else { return }
        do {
            try engine.start()
            #if DEBUG
            print("[HapticsController] Haptic engine started successfully")
            #endif
        } catch {
            #if DEBUG
            print("[HapticsController] Failed to start haptic engine: \(error)")
            #endif
        }
    }

    /// Play a transient haptic (or fallback impact). Skips entirely under Low Power Mode.
    /// Intensity/sharpness, pattern, player, fallback, and all debug output preserved exactly.
    func playHapticFeedback(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            #if DEBUG
            print("[HapticsController] Haptics skipped in Low Power Mode")
            #endif
            return
        }

        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics,
              let engine = hapticEngine else {
            #if DEBUG
            print("[HapticsController] Haptics not supported or engine unavailable")
            #endif
            return
        }

        do {
            try engine.start()

            let intensityValue: Float = (style == .heavy) ? 1.0 : 0.7
            let sharpnessValue: Float = (style == .heavy) ? 1.0 : 0.5

            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: intensityValue)
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpnessValue)
            let event = CHHapticEvent(eventType: .hapticTransient, parameters: [intensity, sharpness], relativeTime: 0)

            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)

            try player.start(atTime: CHHapticTimeImmediate)

            #if DEBUG
            print("[HapticsController] Haptic played: style=\(style), intensity=\(intensityValue), sharpness=\(sharpnessValue)")
            #endif
        } catch {
            #if DEBUG
            print("[HapticsController] Failed to play haptic: \(error.localizedDescription)")
            #endif
            let fallback = UIImpactFeedbackGenerator(style: style)
            fallback.impactOccurred()
        }
    }
}
