//
//  PlayerVisualState.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 18.3.2026.
//

import Foundation
import UIKit

/// Single source of truth for playback UI **and** intent.
/// Pre-play = always yellow, user pause/stop = always grey.
/// Now prevents the "play on pause" resurrection bug across app, widget, and Live Activity.
enum PlayerVisualState: Codable, Equatable {
    
    case prePlay        // Initial load / connecting / never played yet → yellow, should auto-play
    case playing        // Actively playing → green
    case userPaused     // Explicit user pause → grey, NEVER auto-resume
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
    
    /// Should we allow automatic playback or resume?
    /// This is the key protection against the resurrection bug.
    var shouldAutoPlayOrResume: Bool {
        switch self {
        case .prePlay, .playing:
            return true
        case .userPaused, .error:
            return false
        }
    }
}

// MARK: - State mapping

extension PlayerVisualState {
    /// Maps your existing PlayerStatus + flags → visual state
    static func from(
        status: PlayerStatus,
        isManualPause: Bool,
        hasEverPlayed: Bool
    ) -> PlayerVisualState {
        
        switch status {
        case .playing:
            return .playing
            
        case .connecting:
            return .prePlay
            
        case .security:
            return .error
            
        case .paused, .stopped:
            // Key logic: userPaused takes priority over prePlay once user has interacted
            if isManualPause {
                return .userPaused
            }
            return hasEverPlayed ? .userPaused : .prePlay
        }
    }
}
