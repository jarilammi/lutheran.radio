//
//  PlayerStatus.swift
//  WidgetSurface
//
//  Created by Jari Lammi on 14.7.2026.
//
//  Semantic playback status for mapping into ``PlayerVisualState`` and delegate callbacks.
//
//  - SeeAlso: ``PlayerVisualState/from(status:isManualPause:hasEverPlayed:currentVisualState:)``,
//    `DirectStreamingPlayer`, `StreamingPlayerDelegate`.
//

import Foundation

/// Player status enum for callbacks and visual-state mapping.
public enum PlayerStatus: Sendable, Hashable, Equatable {
    case playing
    case paused
    case stopped
    case connecting
    case security
}
