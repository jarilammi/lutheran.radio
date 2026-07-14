//
//  StreamErrorType.swift
//  WidgetSurface
//
//  Created by Jari Lammi on 14.7.2026.
//
//  Cross-target stream failure classification vocabulary shared by `PlayerEvent`,
//  `DirectStreamingPlayer`, and `SharedPlayerManager`.
//
//  Classification logic (`from(error:)`, `isPermanent`, localized status strings)
//  lives in `DirectStreamingPlayer.swift` (main app only).
//
//  - SeeAlso: ``PlayerEvent``, `DirectStreamingPlayer`, docs/Event-Driven-Refactor-Roadmap.md.
//

import Foundation

/// Classified stream failure used by player-domain events and recovery policy.
@frozen public enum StreamErrorType: Sendable, Hashable, Equatable {
    /// Hard security failure (certificate, model validation). Never auto-retried.
    case securityFailure

    /// Genuine permanent failure (resource gone, TCP connect after DNS success, etc.).
    case permanentFailure

    /// Recoverable network / decoder / early ICY framing noise.
    case transientFailure

    /// Unclassified. Treated conservatively as transient in early-window recovery paths.
    case unknown
}
