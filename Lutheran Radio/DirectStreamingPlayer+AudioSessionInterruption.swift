//
//  DirectStreamingPlayer+AudioSessionInterruption.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 24.7.2026.
//
//  AVAudioSession interruption and route-change observers for the streaming engine façade.
//
//  Behavior-preserving domain split from DirectStreamingPlayer.swift.
//  DirectStreamingPlayer remains the public façade; this file owns one domain.
//
//  AGENT NOTE: Members used across files are `internal` (Swift `private` is
//  file-scoped). Prefer this domain file over re-implementing attach / recovery
//  / catalog logic in call sites.
//
//  - SeeAlso: DirectStreamingPlayer.swift,
//    CODING_AGENT.md (Single Source of Truth Principles).
//

import Foundation
@unsafe @preconcurrency import AVFoundation

// MARK: - Audio Session Interruption Handling
extension DirectStreamingPlayer {
    /// Sets up AVAudioSession observers for interruptions and route changes.
    /// - Note: Called in play() to avoid overhead when idle. Uses NotificationCenter for loose coupling.
    nonisolated func setupAudioSessionObservers() {
        guard interruptionObserver == nil else { return }  // Idempotent
        
        let session = AVAudioSession.sharedInstance()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            // NEW — only Sendable values cross the boundary
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            
            Task { @MainActor [weak self, typeValue, optionsValue] in
                let type = AVAudioSession.InterruptionType(rawValue: typeValue ?? 0)
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
                guard let self else { return }
                
                switch type {
                case .began:
                    #if DEBUG
                    print("[DirectStreamingPlayer] [AudioSession] Interruption began")
                    #endif
                    self.isHandlingInterruption = true
                    self.wasPlayingBeforeInterruption = self.isPlaying  // Use refined check
                    
                    if self.wasPlayingBeforeInterruption {
                        self.player?.pause()  // Graceful pause
                        self.delegate?.onStatusChange(.paused, reasonKey: "Interruption")  // ← fixed
                        
                        // Persist paused state for widget — non-blocking
                        Task {
                            await SharedPlayerManager.shared.saveCurrentState()
                        }
                    }
                    
                case .ended:
                    #if DEBUG
                    print("[DirectStreamingPlayer] [AudioSession] Interruption ended — options.contains(.shouldResume): \(options.contains(.shouldResume))")
                    #endif
                    
                    // Reset flags immediately
                    self.isHandlingInterruption = false
                    self.wasPlayingBeforeInterruption = false
                    
                    guard options.contains(.shouldResume) else {
                        #if DEBUG
                        print("[DirectStreamingPlayer] [AudioSession] No .shouldResume — doing nothing")
                        #endif
                        return
                    }
                    
                    // Respect PlayerVisualState resurrection suppression before resuming.
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        
                        await SharedPlayerManager.shared.restoreVisualStateRespectingUserIntent()
                        
                        if case .playing = await SharedPlayerManager.shared.currentVisualState {
                            #if DEBUG
                            print("[DirectStreamingPlayer] ▶ [AudioSession] Resurrection allowed — resuming playback")
                            #endif
                            
                            // Small delay helps AVPlayer settle after interruption
                            try? await Task.sleep(for: .milliseconds(100))
                            
                            self.player?.play()
                            
                            if self.isPlaying {
                                self.delegate?.onStatusChange(.playing, reasonKey: nil)  // ← fixed
                            }
                            
                            await self.markAsPlaying()
                            
                            // Persist resumed state — non-blocking
                            Task {
                                await SharedPlayerManager.shared.saveCurrentState()
                            }
                        } else {
                            #if DEBUG
                            print("🚫 [AudioSession] Resurrection suppressed — user intent remains .userPaused")
                            #endif
                            self.safeOnStatusChange(isPlaying: false, reasonKey: "status_paused")
                        }
                    }
                    
                default:
                    // Fallback for unknown cases (exhaustive without @unknown)
                    #if DEBUG
                    print("[DirectStreamingPlayer] [AudioSession] Unknown interruption type: \(String(describing: type))")
                    #endif
                    break
                }
            }
        }
        
        // Optional: Handle route changes (e.g., AirPlay disconnect) for completeness
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                #if DEBUG
                print("[DirectStreamingPlayer] [AudioSession] Route changed")
                #endif
                // If disconnected during play, pause and notify
                if self.player?.rate ?? 0 > 0 {
                    self.player?.pause()
                    self.delegate?.onStatusChange(.paused, reasonKey: "Route Change")  // ← fixed
                    
                    // Optional: persist paused state after route change
                    Task {
                        await SharedPlayerManager.shared.saveCurrentState()
                    }
                }
            }
        }
    }

    /// Cleans up observers.
    nonisolated func removeAudioSessionObservers() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
    }
}
