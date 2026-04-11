//
//  PlayerVisualState.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 18.3.2026.
//

import Foundation
import UIKit

/// Single source of truth for playback UI **and** intent.
///
/// - prePlay:     yellow, auto-plays on first launch only
/// - playing:     green
/// - userPaused:  grey, NEVER auto-resumes (this is the resurrection protection)
/// - error:       red
///
/// This version makes .userPaused "sticky" after any manual interaction.
enum PlayerVisualState: Codable, Equatable {
    
    case prePlay        // Initial load / connecting / never played yet → yellow, should auto-play
    case playing        // Actively playing → green
    case userPaused     // Explicit user pause/stop → grey, NEVER auto-resume
    case error          // Security failure → red
    
    // MARK: - Visual properties
    
    var backgroundColor: UIColor {
        switch self {
        case .prePlay:     return .systemYellow
        case .playing:     return .systemGreen
        case .userPaused:  return .systemGray
        case .error:       return .systemRed
        }
    }
    
    var textColor: UIColor {
        switch self {
        case .prePlay, .userPaused: return .label
        case .playing, .error:      return .white
        }
    }
    
    var buttonTintColor: UIColor {
        switch self {
        case .prePlay:     return .systemYellow
        case .playing:     return .systemGreen
        case .userPaused:  return .secondaryLabel
        case .error:       return .systemRed
        }
    }
    
    // MARK: - Semantic properties (key to fixing "play on pause")
    
    /// True only when audio is actively playing
    var isActivelyPlaying: Bool {
        self == .playing
    }
    
    /// Single source of truth.
    /// Returns false for .userPaused and .error — this blocks ALL resurrection paths
    /// (viewDidAppear, completeStreamSwitch, widget callbacks, etc.)
    var shouldAutoPlayOrResume: Bool {
        switch self {
        case .prePlay, .playing:
            return true
        case .userPaused, .error:
            return false
        }
    }
    
    // NEW: Explicit resurrection block – call this whenever the system wants to resume
    /// Returns true if we must force a pause because the user explicitly paused earlier.
    var mustSuppressResurrection: Bool {
        self == .userPaused || self == .error
    }
}

// MARK: - State mapping

extension PlayerVisualState {
    /// Maps PlayerStatus + flags → visual state with strict "userPaused is sticky" rule.
    ///
    /// Once the user has manually paused (or ever played), we lock into .userPaused
    /// until they explicitly tap Play again. This prevents the yellow resurrection.
    static func from(
        status: PlayerStatus,
        isManualPause: Bool,
        hasEverPlayed: Bool
    ) -> PlayerVisualState {
        
        switch status {
        case .playing:
            return .playing
            
        case .connecting:
            // Only show prePlay on true first launch (never played before)
            return hasEverPlayed ? .userPaused : .prePlay
            
        case .security:
            return .error
            
        case .paused, .stopped:
            // 🔥 CRITICAL CHANGE:
            // Once user has ever interacted (paused or played), stay in userPaused.
            // Only true initial state (never played) stays prePlay.
            if isManualPause || hasEverPlayed {
                return .userPaused
            }
            return .prePlay   // only for brand-new launch
        }
    }
    
    // NEW helper – call from DirectStreamingPlayer whenever a resurrection event occurs
    /// Use this when AVAudioSession interruption ended with .shouldResume,
    /// when app returns from background, or any other system resume signal.
    static func suppressResurrectionIfNeeded(currentState: PlayerVisualState) -> PlayerVisualState {
        if currentState.mustSuppressResurrection {
            return .userPaused
        }
        return currentState
    }
}
