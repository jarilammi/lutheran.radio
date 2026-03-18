//
//  PlayerVisualState.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 18.3.2026.
//

import Foundation
import UIKit

/// Single source of truth for all playback UI colors.
/// Pre-play = always yellow, pause/stop = always grey (exactly what you asked for).
/// Apple-idiomatic, fully testable, dark-mode safe.
enum PlayerVisualState {
    case prePlay        // Initial load / connecting / never played yet
    case playing
    case inactive       // User paused OR stopped — grey
    case error          // Security failure
    
    var backgroundColor: UIColor {
        switch self {
        case .prePlay:     return .systemYellow
        case .playing:     return .systemGreen
        case .inactive:    return .systemGray
        case .error:       return .systemRed
        }
    }
    
    var textColor: UIColor {
        switch self {
        case .prePlay, .inactive: return .label
        case .playing, .error:    return .white
        }
    }
    
    var buttonTintColor: UIColor {
        switch self {
        case .prePlay:     return .systemYellow
        case .playing:     return .systemGreen
        case .inactive:    return .secondaryLabel   // beautiful subtle grey
        case .error:       return .systemRed
        }
    }
}

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
            // THIS IS THE RULE YOU WANTED
            // Never played yet or user-initiated pause/stop → grey
            // Otherwise stay yellow until first play
            return (isManualPause || !hasEverPlayed) ? .inactive : .prePlay
        }
    }
}
