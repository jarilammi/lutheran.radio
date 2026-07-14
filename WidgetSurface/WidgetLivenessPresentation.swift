//
//  WidgetLivenessPresentation.swift
//  WidgetSurface
//
//  Created by Jari Lammi on 14.7.2026.
//
//  Passive "tap_to_open" vs interactive chrome policy for home-screen widget family views.
//  The underlying heartbeat is ``SharedPlayerManager/isMainAppProcessRecentlyActive()``;
//  this module encodes the presentation decision only.
//
//  - SeeAlso: ``SharedPlayerManager/isMainAppProcessRecentlyActive()``,
//    ``SharedPlayerManager/forceStaleLivenessTimestampForTermination()``,
//    docs/Widget-Functionality-Roadmap.md (OI-W1), CODING_AGENT.md.
//

import Foundation

/// Presentation policy for widget liveness (interactive chrome vs passive launch surface).
public enum WidgetLivenessPresentation {

    /// Window matching ``SharedPlayerManager/isMainAppProcessRecentlyActive()`` (60 s).
    ///
    /// AGENT NOTE: Keep in sync with the SSOT implementation in SharedPlayerManager.
    public static let mainAppRecentActivityWindowSeconds: TimeInterval = 60

    /// Whether family views should render full interactive chrome (controls, metadata, flags).
    ///
    /// - Parameter isMainAppRecentlyActive: Result of ``SharedPlayerManager/isMainAppProcessRecentlyActive()``.
    /// - Returns: `true` when interactive chrome is appropriate.
    public static func shouldShowInteractiveChrome(isMainAppRecentlyActive: Bool) -> Bool {
        isMainAppRecentlyActive
    }

    /// Whether family views should render the passive `tap_to_open` launch surface.
    ///
    /// Post-termination sentinel (`lastUpdateTime == 0`) yields `true` immediately via the SSOT check.
    /// Force-quit may leave a sub-60 s window where interactive chrome still appears (OI-W1, accepted).
    ///
    /// - Parameter isMainAppRecentlyActive: Result of ``SharedPlayerManager/isMainAppProcessRecentlyActive()``.
    /// - Returns: `true` when only the passive branch should render.
    public static func shouldShowPassiveTapToOpen(isMainAppRecentlyActive: Bool) -> Bool {
        !isMainAppRecentlyActive
    }
}
