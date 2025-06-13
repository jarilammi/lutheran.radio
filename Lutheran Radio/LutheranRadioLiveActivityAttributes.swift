//
//  LutheranRadioLiveActivityAttributes.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 13.6.2025.
//

import ActivityKit
import Foundation

struct LutheranRadioLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        let isPlaying: Bool
        let currentMetadata: String?
        let streamStatus: String
        let lastUpdated: Date
        let currentStreamLanguage: String
        let currentStreamFlag: String
    }
    
    let appName: String
    let startTime: Date
}
