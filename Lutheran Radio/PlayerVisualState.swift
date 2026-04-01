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
    
    case prePlay        // Initial load / connecting / never played yet
    case playing        // Actively playing
    case userPaused     // Explicit user pause/stop — grey, do NOT auto-resume
    case error          // Security failure
    
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
    
    /// Should the player be allowed to start/resume automatically?
    /// We block auto-play if user explicitly paused.
    var shouldAutoPlayOrResume: Bool {
        self == .playing || self == .prePlay
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
            // Explicit user pause/stop → userPaused (grey + no auto-resume)
            // Never played yet → still prePlay (yellow)
            return (isManualPause || !hasEverPlayed) ? .userPaused : .prePlay
        }
    }
}
