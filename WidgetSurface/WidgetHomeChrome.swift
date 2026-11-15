//
//  WidgetHomeChrome.swift
//  WidgetSurface
//
//  Created by Jari Lammi on 24.7.2026.
//
//  Shared home-widget presentation chrome: passive tap-to-open surface and stream chips.
//  Presentation-only — no security logic (see Core/). Does not import SharedPlayerManager
//  or AppIntents; Providers supply liveness booleans and wrap chips in Button(intent:).
//
//  Why this file exists: Small / Medium / Large family views previously triplicated
//  passive `tap_to_open` stacks and stream-flag selection chrome. Size-specific
//  layout tokens live here; family views only compose intent wrappers around chips.
//
//  Stream-chip fill/stroke uses ``WidgetStreamChipLabel``: `clipShape` +
//  `overlay(alignment:content:)` so the 6 pt circular clip and 1 pt ring share one
//  path. No security, playback, or Live Activity logic belongs here.
//
//  VoiceOver: each home stream chip is one element. The spoken label is the
//  localized language name from
//  ``widgetStreamChipAccessibility(languageName:isCurrentLanguage:)``. The flag
//  Text is accessibility-hidden so the emoji is not spoken as a country name.
//  The system selected trait follows the visual ``isSelected`` Bool. A labeled
//  chip's visible name is not a second element. There is no accessibility hint
//  and no catalog string for the selected trait.
//
//  - SeeAlso: ``WidgetLivenessPresentation``, ``displayFlag(for:)``,
//    ``displayLanguageName(for:preferredStreamLanguage:)``,
//    ``widgetStreamChipAccessibility(languageName:isCurrentLanguage:)``,
//    ``WidgetStreamChipLabel``, docs/Widget-Presentation-Dataflow.md,
//    docs/Widget-Functionality-Roadmap.md, CODING_AGENT.md (WidgetSurface surface area).
//

import SwiftUI

// MARK: - Alternative stream codes (pure)

/// Default max alternative codes for Lock Screen Live Activity language rows.
public let liveActivityLockScreenAlternativeStreamMaxCount: Int = 4

/// Default max alternative codes for Dynamic Island expanded language chips.
///
/// Intentionally lower than Lock Screen: expanded DI bottom is a fixed-width
/// non-scrolling band. More chips force overflow and trigger the OS yellow
/// ActivityKit layout-compliance overlay.
///
/// - SeeAlso: ``alternativeStreamCodes(current:availableLanguageCodes:maxCount:fallbackCodes:)``,
///   ``LiveActivityStreamSwitchChipDensity/flagOnly``.
public let liveActivityDynamicIslandAlternativeStreamMaxCount: Int = 3

/// Returns up to `maxCount` language codes for Live Activity quick-switch rows.
///
/// Prefers the caller's authoritative catalog (`availableLanguageCodes`), excluding
/// `current`. Falls back to the curated en/de/fi/sv/et set only when the catalog is empty
/// (defensive; normal production always supplies streams).
///
/// - Parameters:
///   - current: Active language code to exclude from the result.
///   - availableLanguageCodes: Catalog codes (e.g. from stream list), in display order.
///   - maxCount: Layout cap for non-scrolling chip rows. Use
///     ``liveActivityDynamicIslandAlternativeStreamMaxCount`` for Dynamic Island and
///     ``liveActivityLockScreenAlternativeStreamMaxCount`` for Lock Screen (default 4).
///   - fallbackCodes: Used only when `availableLanguageCodes` is empty.
/// - Returns: Ordered alternative codes, length at most `maxCount`.
/// - Important: Dynamic Island must not wrap the result in a `ScrollView`. Cap
///   `maxCount` so a plain `HStack` always fits the expanded bottom band.
/// - SeeAlso: ``displayFlag(for:)``, ``displayLanguageName(for:preferredStreamLanguage:)``,
///   docs/Widget-Functionality-Roadmap.md.
public func alternativeStreamCodes(
    current: String,
    availableLanguageCodes: [String],
    maxCount: Int = liveActivityLockScreenAlternativeStreamMaxCount,
    fallbackCodes: [String] = ["en", "de", "fi", "sv", "et"]
) -> [String] {
    let source = availableLanguageCodes.isEmpty ? fallbackCodes : availableLanguageCodes
    return Array(source.filter { $0 != current }.prefix(maxCount))
}

// MARK: - Passive tap-to-open chrome

/// Size tokens for the privacy-passive home-widget launch surface.
public enum WidgetPassiveTapToOpenStyle: Sendable, Equatable {
    case small
    case medium
    case large

    var iconFont: Font {
        switch self {
        case .small: .title2
        case .medium: .largeTitle
        case .large: .system(size: 60)
        }
    }

    var titleFont: Font {
        switch self {
        case .small: .caption
        case .medium: .subheadline
        case .large: .title3
        }
    }

    var showsSecondaryCaption: Bool {
        self != .small
    }

    var secondaryFont: Font {
        switch self {
        case .small: .caption2
        case .medium: .caption
        case .large: .subheadline
        }
    }

    var stackSpacing: CGFloat {
        switch self {
        case .small: 8
        case .medium: 8
        case .large: 16
        }
    }
}

/// Passive home-widget chrome when the main app process is not recently active.
///
/// Renders radio glyph + localized `tap_to_open` (and optional `open_app_first`).
/// Callers apply `.widgetURL` and outer padding so family views keep control of
/// launch URL and container insets.
///
/// - Note: `tap_to_open` and `open_app_first` are marked `extractionState: manual` in
///   the main-app `Localizable.xcstrings` catalog. The call sites live in WidgetSurface,
///   so Xcode auto-extraction on catalog-owning targets does not see them (same pattern as
///   `Connection error` in ``WidgetProviderPresentationAssembly``).
/// - SeeAlso: ``WidgetLivenessPresentation/shouldShowPassiveTapToOpen(isMainAppRecentlyActive:)``.
public struct WidgetPassiveTapToOpenChrome: View {
    public let style: WidgetPassiveTapToOpenStyle

    public init(style: WidgetPassiveTapToOpenStyle) {
        self.style = style
    }

    public var body: some View {
        VStack(spacing: style.stackSpacing) {
            if style == .large {
                Spacer(minLength: 0)
            }
            Image(systemName: "radio")
                .font(style.iconFont)
                .foregroundStyle(.secondary)
            Text(String(localized: "tap_to_open", table: "Localizable"))
                .font(style.titleFont)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(style == .small ? 2 : 1)
                .minimumScaleFactor(style == .small ? 0.8 : 1)
            if style.showsSecondaryCaption {
                Text(String(localized: "open_app_first", table: "Localizable"))
                    .font(style.secondaryFont)
                    .foregroundStyle(.secondary)
            }
            if style == .large {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: style == .medium || style == .large ? .infinity : nil)
    }
}

// MARK: - Stream flag chips

/// Visual density for home-widget stream-selection chips.
public enum WidgetStreamChipStyle: Sendable, Equatable {
    /// Compact flag-only chip (small / medium rows).
    ///
    /// Draws the flag alone. VoiceOver still speaks ``WidgetStreamChipLabel/languageName``.
    case flagOnly
    /// Flag + language label (large grid).
    ///
    /// Draws the flag and ``WidgetStreamChipLabel/languageName``. The name is spoken once.
    case labeled

    var flagFont: Font {
        switch self {
        case .flagOnly: .subheadline
        case .labeled: .caption
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .flagOnly: 6
        case .labeled: 8
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .flagOnly: 4
        case .labeled: 6
        }
    }

    var unselectedBackgroundOpacity: Double {
        switch self {
        case .flagOnly: 0.08
        case .labeled: 0.1
        }
    }

    var expandsHorizontally: Bool {
        // Medium row gives each flag equal width; small and large size to content.
        false
    }
}

/// Spoken label and selected-trait flag for one home-widget stream chip.
///
/// ``label`` is the language name unchanged. ``isSelected`` is the system
/// selected trait, not a word appended to the label.
///
/// - SeeAlso: ``widgetStreamChipAccessibility(languageName:isCurrentLanguage:)``,
///   ``WidgetStreamChipLabel``.
public struct WidgetStreamChipAccessibility: Sendable, Equatable {
    /// VoiceOver label. The language name the caller supplied.
    public let label: String

    /// When `true`, the chip adds ``AccessibilityTraits/isSelected``.
    public let isSelected: Bool

    public init(label: String, isSelected: Bool) {
        self.label = label
        self.isSelected = isSelected
    }
}

/// Resolves the VoiceOver label and selected trait for a home-widget stream chip.
///
/// The label is `languageName` with no fallback. An empty name stays empty.
/// Production streams always supply a catalog name from
/// ``displayLanguageName(for:preferredStreamLanguage:)`` (the stream's `language`
/// string). This function does not append a selected word and does not read a
/// Localizable key.
///
/// `isCurrentLanguage` is the chip's visual selection Bool: home widgets set it
/// by comparing the chip's language code with the current language code. That
/// comparison stays true while playback is paused, so the trait does too.
///
/// - Parameters:
///   - languageName: Localized language name already resolved by the caller.
///   - isCurrentLanguage: `true` when this chip is the current language.
/// - Returns: The spoken label and whether to add the system selected trait.
/// - Important: Do not substitute a flag emoji, a language code, or a
///   "selected" string when `languageName` is empty.
/// - SeeAlso: ``WidgetStreamChipLabel``, ``WidgetStreamChipAccessibility``,
///   ``displayLanguageName(for:preferredStreamLanguage:)``.
public func widgetStreamChipAccessibility(
    languageName: String,
    isCurrentLanguage: Bool
) -> WidgetStreamChipAccessibility {
    WidgetStreamChipAccessibility(
        label: languageName,
        isSelected: isCurrentLanguage
    )
}

/// Selected / unselected stream chip chrome shared by small, medium, and large home widgets.
///
/// Draws the flag, or the flag plus ``languageName``, with one blue fill and a
/// 1 pt stroke when ``isSelected`` is true. Extension views wrap this in
/// `Button(intent: SwitchStreamIntent(...))`.
///
/// VoiceOver sees one element. The label comes from
/// ``widgetStreamChipAccessibility(languageName:isCurrentLanguage:)`` and is the
/// language name alone. The flag `Text` is accessibility-hidden so the emoji is
/// not spoken. The system selected trait is added only when ``isSelected`` is
/// true. Child elements are ignored, so the visible name on a labeled chip is
/// not spoken a second time. The chip sets no accessibility hint.
///
/// Fill clip and stroke share ``chipCornerRadius`` so the ring sits on the same
/// circular path as the clipped fill. `clipShape` replaces `.cornerRadius`;
/// `overlay(alignment:content:)` replaces the view-taking `.overlay` form.
/// Both remain on the iOS 26.2 deployment floor — no iOS 27-only API.
///
/// - Important: Keep ``RoundedRectangle`` at the default circular style. A
///   `.continuous` squircle would change small / medium / large home chips.
///   ``languageName`` is the spoken label for every style. ``.flagOnly`` does
///   not draw it. A missing or empty name is not replaced.
/// - SeeAlso: ``widgetStreamChipAccessibility(languageName:isCurrentLanguage:)``,
///   ``displayLanguageName(for:preferredStreamLanguage:)``,
///   ``WidgetStreamChipStyle``, ``WidgetPassiveTapToOpenChrome``,
///   docs/Widget-Presentation-Dataflow.md, docs/Widget-Functionality-Roadmap.md,
///   CODING_AGENT.md (WidgetSurface presentation-only surface area).
public struct WidgetStreamChipLabel: View {
    public let flag: String
    public let languageName: String?
    public let isSelected: Bool
    public let style: WidgetStreamChipStyle
    public let expandsToFill: Bool

    /// Circular corner radius for the selected fill clip and the 1 pt selection stroke.
    /// Shared so the ring cannot drift off the fill path.
    private static let chipCornerRadius: CGFloat = 6

    /// Creates home-widget stream-chip chrome.
    ///
    /// - Parameters:
    ///   - flag: Flag emoji drawn for every style. Hidden from VoiceOver.
    ///   - languageName: Localized language name. Spoken for every style. Drawn
    ///     only for ``WidgetStreamChipStyle/labeled``. `nil` and `""` stay empty
    ///     in the spoken label.
    ///   - isSelected: Visual selection and the source of the selected trait.
    ///     Home widgets pass the current-language comparison, including while paused.
    ///   - style: Flag-only or flag plus name. Does not change the spoken label.
    ///   - expandsToFill: Gives a flag-only chip flexible width in the medium row.
    /// - SeeAlso: ``widgetStreamChipAccessibility(languageName:isCurrentLanguage:)``,
    ///   ``displayLanguageName(for:preferredStreamLanguage:)``.
    public init(
        flag: String,
        languageName: String? = nil,
        isSelected: Bool,
        style: WidgetStreamChipStyle,
        expandsToFill: Bool = false
    ) {
        self.flag = flag
        self.languageName = languageName
        self.isSelected = isSelected
        self.style = style
        self.expandsToFill = expandsToFill
    }

    /// Flag emoji. Decorative for VoiceOver; the chip label is the language name.
    ///
    /// Hidden on this `Text` only. The chip and its `Button` stay exposed.
    private var decorativeFlag: some View {
        Text(flag)
            .font(style.flagFont)
            .accessibilityHidden(true)
    }

    public var body: some View {
        let spoken = widgetStreamChipAccessibility(
            languageName: languageName ?? "",
            isCurrentLanguage: isSelected
        )
        Group {
            switch style {
            case .flagOnly:
                decorativeFlag
                    .frame(maxWidth: expandsToFill ? .infinity : nil)
            case .labeled:
                HStack(spacing: 4) {
                    decorativeFlag
                    if let languageName {
                        Text(languageName)
                            .font(.caption)
                            .fontWeight(isSelected ? .semibold : .regular)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, style.horizontalPadding)
        .padding(.vertical, style.verticalPadding)
        .background(isSelected ? Color.blue.opacity(0.2) : Color.gray.opacity(style.unselectedBackgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Self.chipCornerRadius))
        .overlay(alignment: .center) {
            RoundedRectangle(cornerRadius: Self.chipCornerRadius)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1)
        }
        // One element. Ignoring children keeps the large chip's visible name
        // from being spoken again beside this label. The flag Text is also hidden.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken.label)
        .accessibilityAddTraits(spoken.isSelected ? .isSelected : AccessibilityTraits())
    }
}
