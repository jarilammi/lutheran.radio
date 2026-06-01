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
        // MARK: - Single Source of Truth (authoritative)
        let visualState: PlayerVisualState
    }
    
    let appName: String
    let startTime: Date
}
