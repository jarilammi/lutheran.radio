//
//  WidgetLivenessPresentation.swift
//  WidgetSurface
//
//  Created by Jari Lammi on 14.7.2026.
//
//  Passive `tap_to_open` presentation policy for home-screen widget family views.
//  The underlying heartbeat is ``SharedPlayerManager/isMainAppProcessRecentlyActive()``;
//  this module encodes the pure branch decision only. Family views call
//  ``shouldShowPassiveTapToOpen(isMainAppRecentlyActive:)`` and render interactive
//  controls in the complementary branch (`false`).
//
//  - SeeAlso: ``SharedPlayerManager/isMainAppProcessRecentlyActive()``,
//    ``SharedPlayerManager/forceStaleLivenessTimestampForTermination()``,
//    docs/Widget-Functionality-Roadmap.md (force-quit liveness window),
//    docs/Widget-Presentation-Dataflow.md, CODING_AGENT.md.
//

import Foundation

/// Presentation policy for widget liveness: passive `tap_to_open` vs full interactive chrome.
///
/// Production family views gate on ``shouldShowPassiveTapToOpen(isMainAppRecentlyActive:)`` only.
/// Interactive chrome is the complementary branch when that helper returns `false` (main app
/// recently active per the App Group heartbeat SSOT).
///
/// - Important: Liveness owns interactive vs passive. Privacy-gated live chrome mirrors are
///   never proof the main process is still interactive.
/// - SeeAlso: ``SharedPlayerManager/isMainAppProcessRecentlyActive()``,
///   docs/Widget-Presentation-Dataflow.md, docs/Widget-Functionality-Roadmap.md.
public enum WidgetLivenessPresentation {

    /// Window matching ``SharedPlayerManager/isMainAppProcessRecentlyActive()`` (60 s).
    ///
    /// AGENT NOTE: Keep in sync with the SSOT implementation in SharedPlayerManager.
    public static let mainAppRecentActivityWindowSeconds: TimeInterval = 60

    /// Whether family views should render the passive `tap_to_open` launch surface.
    ///
    /// When `false`, family views render full interactive chrome (controls, metadata, flags).
    /// Post-termination sentinel (`lastUpdateTime == 0`) yields `true` immediately via the SSOT check.
    /// Device reboot (boot-identity mismatch) also yields passive chrome even when a residual
    /// pre-reboot `lastUpdateTime` is still inside the 60 s wall-clock window.
    /// Force-quit without reboot may leave a sub-60 s residual interactive window until the
    /// heartbeat ages (extension must not re-open a new window after it expires).
    ///
    /// - Parameter isMainAppRecentlyActive: Result of ``SharedPlayerManager/isMainAppProcessRecentlyActive()``.
    /// - Returns: `true` when only the passive branch should render; `false` for interactive chrome.
    /// - SeeAlso: ``mainAppRecentActivityWindowSeconds``,
    ///   ``SharedPlayerManager/isMainAppProcessRecentlyActive()``.
    public static func shouldShowPassiveTapToOpen(isMainAppRecentlyActive: Bool) -> Bool {
        !isMainAppRecentlyActive
    }
}
