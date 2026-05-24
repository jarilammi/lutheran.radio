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
/// - prePlay:        yellow, auto-plays on first launch only
/// - playing:        green
/// - userPaused:     grey, NEVER auto-resumes
/// - thermalPaused:  amber, device is overheating (blocks auto-resume)
/// - securityLocked: red
///
/// This version makes .userPaused "sticky" after any manual interaction.
enum PlayerVisualState: Codable, Equatable {
    
    case prePlay            // Initial load / connecting / never played yet → yellow
    case playing            // Actively playing → green
    case userPaused         // Explicit user pause/stop → grey (sticky)
    case thermalPaused      // Device overheating → amber/orange warning
    case securityLocked     // Security / certificate failure → red
    
    // MARK: - Visual properties
    
    var backgroundColor: UIColor {
        switch self {
        case .prePlay:        return .systemYellow
        case .playing:        return .systemGreen
        case .userPaused:     return .systemGray
        case .thermalPaused:  return .systemOrange
        case .securityLocked: return .systemRed
        }
    }
    
    var textColor: UIColor {
        switch self {
        case .prePlay, .userPaused, .playing, .thermalPaused:
            return .label
        case .securityLocked:
            return .white
        }
    }
    
    var buttonTintColor: UIColor {
        switch self {
        case .prePlay:        return .systemYellow
        case .playing:        return .systemGreen
        case .userPaused:     return .secondaryLabel
        case .thermalPaused:  return .systemOrange
        case .securityLocked: return .systemRed
        }
    }
    
    // MARK: - Semantic properties
    
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
        case .userPaused, .thermalPaused, .securityLocked:
            return false
        }
    }
    
    var shouldAutoResumeOnThermalRecovery: Bool {
        self == .thermalPaused
    }
    
    var mustSuppressResurrection: Bool {
        self == .userPaused || self == .securityLocked
    }
}

// MARK: - Stop Reason

/// Why we are stopping playback.
/// This lets us preserve user intent during stream switches
/// instead of blindly setting `.userPaused`.
enum StopReason {
    case userAction          // explicit pause button → become sticky .userPaused
    case streamSwitch        // language change → keep playing intent
    case interruption        // background / call / AirPlay / etc.
    case error               // security failure, network loss, etc.
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
        hasEverPlayed: Bool,
        currentVisualState: PlayerVisualState = .prePlay
    ) -> PlayerVisualState {
        
        // 🔥 CRITICAL: Once userPaused, stay there for any non-playing status
        // This defeats the status-callback flip-back bug
        if currentVisualState == .userPaused && status != .playing {
            #if DEBUG
            print("🔒 [PlayerVisualState] preserving sticky .userPaused for status=\(status)")
            #endif
            return .userPaused
        }
        
        switch status {
        case .playing:
            return .playing
            
        case .connecting:
            // Only show prePlay on true first launch (never played before)
            return hasEverPlayed ? .userPaused : .prePlay
            
        case .security:
            return .securityLocked
            
        case .paused, .stopped:
            // Once user has ever interacted (paused or played), stay in userPaused
            if isManualPause || hasEverPlayed || currentVisualState == .userPaused {
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
