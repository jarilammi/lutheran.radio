//
//  PlayerPresentation.swift
//  WidgetSurface
//
//  Created by Jari Lammi on 23.7.2026.
//
//  Narrow presentation types, chrome color palette, and pure presentation mappers.
//
//  WidgetSurface framework — presentation-only (no security logic).
//
//  Separation of concerns:
//  - ``PlayerVisualState`` owns policy (resurrection, sticky pause, media-toggle semantics).
//  - This file owns display derivation only: status pill, play/pause control, and
//    the single chrome palette that feeds both UIKit (`UIColor`) and SwiftUI (`Color`).
//
//  Presentation surfaces:
//  - `PlayerStatusPresentation` + `makeStatusPresentation()`: status pill/indicator
//  - `PlayerControlPresentation` + `makeControlPresentation()`: primary play/pause control
//  - `PlayerVisualChromePalette`: SSOT for background / text / button-tint colors
//
//  - SeeAlso: ``PlayerVisualState``, docs/Widget-Presentation-Dataflow.md,
//    CODING_AGENT.md (narrow inputs, value types).
//  - AGENT NOTE: Do not re-derive status/control colors in view bodies. Consume the
//    narrow types produced here (Providers pre-derive; Live Activities derive once
//    at the outer closure).
//

import Foundation
import UIKit
import SwiftUI

// MARK: - PlayerVisualChromePalette

/// Single source of truth for `PlayerVisualState` chrome colors across UIKit and SwiftUI.
///
/// Why this exists: UIKit surfaces historically exposed `backgroundColor` / `textColor` /
/// `buttonTintColor` while status presentation hard-coded SwiftUI semantic colors
/// (`.green`, `.white`, …). Those two tables could drift. All chrome color decisions
/// now flow through this palette; SwiftUI `Color` values are bridged once from the
/// authoritative `UIColor` policy.
///
/// - Important: Policy semantics (when audio is playing, sticky pause, thermal refuse)
///   stay on ``PlayerVisualState``. This type only maps a visual case → colors.
/// - SeeAlso: ``PlayerVisualState/backgroundColor``, ``PlayerVisualState/makeStatusPresentation()``,
///   ``PlayerVisualState/makeControlPresentation()``.
public enum PlayerVisualChromePalette: Sendable {

    /// Status-pill / host background fill for the given visual state.
    public static func backgroundUIColor(for state: PlayerVisualState) -> UIColor {
        switch state {
        case .prePlay:        return .systemYellow
        case .cleared:        return .systemBlue
        case .playing:        return .systemGreen
        case .userPaused:     return .systemGray
        case .thermalPaused:  return .systemOrange
        case .securityLocked: return .systemRed
        }
    }

    /// Primary text / glyph foreground on the status background.
    public static func textUIColor(for state: PlayerVisualState) -> UIColor {
        switch state {
        case .prePlay, .userPaused, .playing, .thermalPaused:
            return .label
        case .cleared, .securityLocked:
            return .white
        }
    }

    /// Play/pause control tint (and non-control decorative radio glyphs).
    public static func buttonTintUIColor(for state: PlayerVisualState) -> UIColor {
        switch state {
        case .prePlay:        return .systemYellow
        case .cleared:        return .systemBlue
        case .playing:        return .systemGreen
        case .userPaused:     return .secondaryLabel
        case .thermalPaused:  return .systemOrange
        case .securityLocked: return .systemRed
        }
    }

    /// SwiftUI bridge of ``backgroundUIColor(for:)``.
    public static func backgroundColor(for state: PlayerVisualState) -> Color {
        Color(uiColor: backgroundUIColor(for: state))
    }

    /// SwiftUI bridge of ``textUIColor(for:)``.
    public static func textColor(for state: PlayerVisualState) -> Color {
        Color(uiColor: textUIColor(for: state))
    }

    /// SwiftUI bridge of ``buttonTintUIColor(for:)``.
    public static func buttonTintColor(for state: PlayerVisualState) -> Color {
        Color(uiColor: buttonTintUIColor(for: state))
    }
}

// MARK: - PlayerStatusPresentation

/// Narrow value type containing only the data required to render the player status indicator.
///
/// This type is intentionally minimal and value-semantic so that SwiftUI leaf views,
/// widget entries, and Live Activity content can depend on a tiny Equatable input instead of
/// the full policy-rich `PlayerVisualState`.
///
/// It carries SwiftUI-native `Color` (no repeated `Color(uiColor:)` bridging in bodies) plus
/// localized text and an optional system image name for glyphs.
///
/// Parallel narrow type: `PlayerControlPresentation` + `makeControlPresentation()` handles
/// the play/pause button glyph and tint decisions for widgets and Live Activities.
///
/// - Important: `PlayerVisualState` remains the Single Source of Truth for both presentation
///   *and* resurrection/policy semantics. This type is a derived snapshot for display only.
/// - Note: Color decisions live in ``PlayerVisualChromePalette``; copy/glyph decisions live
///   in ``PlayerVisualState/makeStatusPresentation()``.
/// - SeeAlso: ``PlayerVisualState/makeStatusPresentation()``, ``PlayerControlPresentation``,
///   ``PlayerVisualState/makeControlPresentation()``, ``PlayerViewModel/statusPresentation``,
///   `SimpleEntry.statusPresentation`, CODING_AGENT.md (narrow inputs, value types,
///   cached derived on @Observable, docs/Widget-Presentation-Dataflow.md).
public struct PlayerStatusPresentation: Sendable, Equatable {
    /// Background fill color for the status pill / indicator.
    public let background: Color

    /// Foreground color for text (and optional image) drawn on the background.
    public let foreground: Color

    /// Localized status text (e.g. "Playing", "Paused", "Connecting", ...).
    public let text: String

    /// Optional SF Symbol name to accompany the text (e.g. "play.fill", "pause.fill", "lock.fill").
    /// Consumers may ignore this if they render the glyph elsewhere (main player controls do).
    public let systemImage: String?

    public init(background: Color, foreground: Color, text: String, systemImage: String?) {
        self.background = background
        self.foreground = foreground
        self.text = text
        self.systemImage = systemImage
    }
}

// MARK: - PlayerControlPresentation

/// Narrow value type containing only the data required to render the primary playback control (play/pause button).
///
/// This is the direct parallel to `PlayerStatusPresentation` for the control affordance axis.
/// It exists so that WidgetKit TimelineEntry consumers (`SimpleEntry`) and ActivityKit
/// `ContentState` / `ActivityViewContext` consumers can depend on a tiny `Equatable` input
/// for glyph choice and tint instead of the full policy `PlayerVisualState`.
///
/// **Single Source of Truth**: `PlayerControlPresentation` + `makeControlPresentation()`
/// is the only place that decides "play.fill" vs "pause.fill" + tint for control affordances.
/// All widget family views, Dynamic Island regions, Lock Screen Live Activity, and the
/// Control widget consume this type (or its fields) for the primary button.
///
/// - `systemImage`: The SF Symbol name to use for the toggle ("play.fill" when not actively playing,
///   "pause.fill" when `isActivelyPlaying`). Consumers may append ".circle" or other variants
///   for specific chrome (Lock Screen uses circle variants) while still sourcing the base decision here.
/// - `tint`: SwiftUI `Color` (derived once via `makeControlPresentation`) so repeated
///   `Color(uiColor:)` or `.swiftUIColor` bridging does not occur inside view bodies or region closures.
///
/// Why this narrow type (even without @Observable):
/// WidgetKit and ActivityKit deliver frozen value-type snapshots. Re-evaluation of bodies
/// and Dynamic Island regions happens on field-wise comparison of the supplied input.
/// A `SimpleEntry` or `ContentState` carrying the full `visualState` means any change
/// (even an unrelated field) can cause re-execution of control button rendering. By pre-deriving
/// (widgets: in Provider) or computing once at the top of the view/outer closure (Live Activities)
/// and handing only `PlayerControlPresentation`, we shrink the invalidation surface for the
/// control button and keep derivation logic out of the view layer (see swiftui-specialist
/// dataflow.md principles applied to snapshot model).
///
/// - Important: `PlayerVisualState` remains the Single Source of Truth for policy and
///   resurrection semantics. This type is a pure derived snapshot for display only.
/// - Note: Glyph decision is intentionally driven by `isActivelyPlaying` (playing → pause
///   affordance). Tint comes from ``PlayerVisualChromePalette/buttonTintColor(for:)``.
/// - SeeAlso: ``PlayerStatusPresentation``, ``PlayerVisualState/makeStatusPresentation()``,
///   ``PlayerVisualState/makeControlPresentation()``, `SimpleEntry.controlPresentation`,
///   `LutheranRadioLiveActivityAttributes.ContentState`,
///   CODING_AGENT.md (narrow inputs for value types + WidgetKit/ActivityKit snapshot constraints),
///   WidgetDisplayModels.swift (sibling presentation axis for metadata/emphasis).
public struct PlayerControlPresentation: Sendable, Equatable {
    /// SF Symbol name for the playback toggle control.
    ///
    /// Typically "play.fill" or "pause.fill". Consumers are free to use variant forms
    /// (e.g. "play.circle.fill") when the design calls for it, but the choice of which
    /// base glyph (play vs pause) must be driven by this value.
    public let systemImage: String

    /// Tint color to apply to the control glyph (and commonly to its enclosing circle or background).
    ///
    /// Already a SwiftUI `Color` so leaf buttons and regions do not perform UIColor bridging.
    public let tint: Color

    public init(systemImage: String, tint: Color) {
        self.systemImage = systemImage
        self.tint = tint
    }
}

// MARK: - Presentation mapping (pure, for SwiftUI + widgets)

public extension PlayerVisualState {
    /// Returns a narrow `PlayerStatusPresentation` derived from this visual state.
    ///
    /// This is the single canonical place that maps `PlayerVisualState` cases to
    /// status colors (via ``PlayerVisualChromePalette``), localized status text, and
    /// an optional system image.
    ///
    /// Status presentation is the "indicator" axis (pill / caption text + background).
    /// See the sibling `makeControlPresentation()` for the orthogonal "primary action
    /// affordance" axis (play/pause glyph + tint).
    ///
    /// - Important: Keep `PlayerVisualState` focused on policy and semantics
    ///   (resurrection, auto-play, sticky pauses). Presentation details live here.
    /// - Returns: A value-type struct suitable for direct use as a SwiftUI view input.
    /// - Note: Uses the same localized keys as `PlaybackControlsView` so all 21 languages stay in sync.
    /// - SeeAlso: ``PlayerStatusPresentation``, ``makeControlPresentation()``,
    ///   ``PlayerControlPresentation``, ``PlayerVisualChromePalette``,
    ///   ``PlayerViewModel/statusPresentation``,
    ///   `SimpleEntry.statusPresentation`, CODING_AGENT.md (cache derived values on @Observable,
    ///   narrow inputs for leaves, WidgetKit/ActivityKit snapshot constraints).
    func makeStatusPresentation() -> PlayerStatusPresentation {
        let background = PlayerVisualChromePalette.backgroundColor(for: self)
        let foreground = PlayerVisualChromePalette.textColor(for: self)

        switch self {
        case .playing:
            return PlayerStatusPresentation(
                background: background,
                foreground: foreground,
                text: String(localized: "status_playing", table: "Localizable"),
                systemImage: "play.fill"
            )

        case .prePlay:
            return PlayerStatusPresentation(
                background: background,
                foreground: foreground,
                text: String(localized: "status_connecting", table: "Localizable"),
                systemImage: "play.circle"
            )

        case .cleared:
            return PlayerStatusPresentation(
                background: background,
                foreground: foreground,
                text: String(localized: "clear_local_state_done", table: "Localizable"),
                systemImage: nil
            )

        case .userPaused:
            return PlayerStatusPresentation(
                background: background,
                foreground: foreground,
                text: String(localized: "status_paused", table: "Localizable"),
                systemImage: "pause.fill"
            )

        case .thermalPaused:
            return PlayerStatusPresentation(
                background: background,
                foreground: foreground,
                text: String(localized: "status_thermal_paused", table: "Localizable"),
                systemImage: "pause.fill"
            )

        case .securityLocked:
            return PlayerStatusPresentation(
                background: background,
                foreground: foreground,
                text: String(localized: "status_security_failed", table: "Localizable"),
                systemImage: "lock.fill"
            )
        }
    }

    /// Returns a narrow `PlayerControlPresentation` derived from this visual state.
    ///
    /// This is the single canonical mapper for the play/pause control glyph and its tint.
    /// It is the control-axis counterpart to `makeStatusPresentation()`.
    ///
    /// - Returns: A minimal Equatable value type carrying only `systemImage` ("play.fill"/"pause.fill")
    ///   and `tint` (as SwiftUI Color). Suitable for direct consumption by widget buttons,
    ///   Dynamic Island region closures, Lock Screen Live Activity controls, and the Control widget.
    /// - Precondition: Called on any `PlayerVisualState`; always produces a defined presentation.
    /// - Note: The glyph choice is deliberately based on `isActivelyPlaying` (the semantic
    ///   "audio is flowing" flag) so that the affordance matches user expectation:
    ///   actively playing → pause control visible; otherwise → play control.
    ///   Tint comes from ``PlayerVisualChromePalette/buttonTintColor(for:)``.
    /// - Complexity: O(1) switch + Color(uiColor:) conversion.
    /// - SeeAlso: ``PlayerControlPresentation``, ``PlayerStatusPresentation``,
    ///   ``PlayerVisualChromePalette``, ``makeStatusPresentation()``,
    ///   `SimpleEntry` (receives the pre-derived value in providers),
    ///   `LutheranRadioWidgetLiveActivityWidget` (derives once per DynamicIsland / LockScreen),
    ///   CODING_AGENT.md (narrow inputs, value-type snapshot comparison cost,
    ///   "Pass views only the data they read"), WidgetDisplayModels.swift.
    ///
    /// AGENT NOTE: This is the Single Source of Truth for control glyph + tint decisions.
    /// Do not duplicate the mapping logic in view bodies, region builders, or WidgetDisplayModels.
    /// All play/pause `Image(systemName:)` + tint decisions for widgets, Live Activities,
    /// and the Control widget must flow through `makeControlPresentation()`.
    func makeControlPresentation() -> PlayerControlPresentation {
        let imageName = isActivelyPlaying ? "pause.fill" : "play.fill"
        let tint = PlayerVisualChromePalette.buttonTintColor(for: self)
        return PlayerControlPresentation(systemImage: imageName, tint: tint)
    }
}
