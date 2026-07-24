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
//  - SeeAlso: ``WidgetLivenessPresentation``, ``displayFlag(for:)``,
//    docs/Widget-Presentation-Dataflow.md, docs/Widget-Functionality-Roadmap.md,
//    CODING_AGENT.md (WidgetSurface surface area).
//

import SwiftUI

// MARK: - Alternative stream codes (pure)

/// Returns up to `maxCount` language codes for Live Activity quick-switch rows.
///
/// Prefers the caller's authoritative catalog (`availableLanguageCodes`), excluding
/// `current`. Falls back to the curated en/de/fi/sv/et set only when the catalog is empty
/// (defensive; normal production always supplies streams).
///
/// - Parameters:
///   - current: Active language code to exclude from the result.
///   - availableLanguageCodes: Catalog codes (e.g. from stream list), in display order.
///   - maxCount: Layout cap for DI center ScrollView and Lock Screen HStack (default 4).
///   - fallbackCodes: Used only when `availableLanguageCodes` is empty.
/// - Returns: Ordered alternative codes, length at most `maxCount`.
/// - SeeAlso: ``displayFlag(for:)``, ``displayLanguageName(for:preferredStreamLanguage:)``,
///   docs/Widget-Functionality-Roadmap.md.
public func alternativeStreamCodes(
    current: String,
    availableLanguageCodes: [String],
    maxCount: Int = 4,
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
    case flagOnly
    /// Flag + language label (large grid).
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

/// Selected / unselected stream chip chrome shared by small, medium, and large home widgets.
///
/// Content is flag-only or flag+label; selection styling (blue fill + stroke) is unified.
/// Extension views wrap this in `Button(intent: SwitchStreamIntent(...))`.
public struct WidgetStreamChipLabel: View {
    public let flag: String
    public let languageName: String?
    public let isSelected: Bool
    public let style: WidgetStreamChipStyle
    public let expandsToFill: Bool

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

    public var body: some View {
        Group {
            switch style {
            case .flagOnly:
                Text(flag)
                    .font(style.flagFont)
                    .frame(maxWidth: expandsToFill ? .infinity : nil)
            case .labeled:
                HStack(spacing: 4) {
                    Text(flag)
                        .font(style.flagFont)
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
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1)
        )
    }
}
