//
//  LutheranRadioLiveActivityAttributes.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 13.6.2025.
//

import ActivityKit
import Foundation

struct LutheranRadioLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {   // ← added Sendable for Swift 6
        // MARK: - Single Source of Truth
        let visualState: PlayerVisualState          // ← NEW: authoritative state
        
        // Legacy properties (kept for backward compatibility with existing views)
        let currentMetadata: String?
        let streamStatus: String
        let lastUpdated: Date
        let currentStreamLanguage: String
        let currentStreamFlag: String
        
        // Computed properties (so all existing code continues to work)
        var isPlaying: Bool {
            visualState.isActivelyPlaying
        }
    }
    
    let appName: String
    let startTime: Date
}
