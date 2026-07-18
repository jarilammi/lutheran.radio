//
//  WidgetLanguageDisplay.swift
//  WidgetSurface
//
//  Created by Jari Lammi on 18.7.2026.
//
//  Pure language flag and display-name helpers for WidgetKit / ActivityKit surfaces.
//  Presentation-only — no security logic (see Core/). Does not read
//  ``SharedPlayerManager``; callers that prefer the stream catalog pass a preferred name.
//
//  - SeeAlso: ``WidgetProviderPresentationAssembly``, docs/Widget-Presentation-Dataflow.md,
//    docs/Widget-Functionality-Roadmap.md, CODING_AGENT.md (WidgetSurface surface area).
//

import Foundation

/// Emoji flag for a stream language code (Live Activity alt buttons and previews).
///
/// Curated codes match the production stream-list flag set for en/de/fi/sv/et.
/// Unknown codes use the globe fallback so UI never receives an empty string.
///
/// - Parameter code: BCP-47-style language code (e.g. `"de"`).
/// - Returns: Single-cluster flag emoji (or globe fallback).
/// - SeeAlso: ``displayLanguageName(for:preferredStreamLanguage:)``,
///   docs/Widget-Functionality-Roadmap.md.
public func displayFlag(for code: String) -> String {
    switch code {
    case "en": return "🇺🇸"
    case "de": return "🇩🇪"
    case "fi": return "🇫🇮"
    case "sv": return "🇸🇪"
    case "et": return "🇪🇪"
    default: return "🌍"
    }
}

/// Localized display name for a stream language code (Live Activity alt buttons and previews).
///
/// Prefer the stream catalog name when the caller supplies ``preferredStreamLanguage``
/// (full 21-language list with locale-correct labels). Otherwise uses curated
/// `Localizable` keys for en/de/fi/sv/et, then `code.capitalized`.
///
/// - Parameters:
///   - code: BCP-47-style language code (e.g. `"fi"`).
///   - preferredStreamLanguage: Authoritative language label from the app stream catalog
///     when available; pass `nil` for pure curated/capitalized resolution only.
/// - Returns: Non-empty display name suitable for UI.
/// - SeeAlso: ``displayFlag(for:)``, docs/Widget-Functionality-Roadmap.md.
public func displayLanguageName(
    for code: String,
    preferredStreamLanguage: String? = nil
) -> String {
    if let preferred = preferredStreamLanguage, !preferred.isEmpty {
        return preferred
    }
    switch code {
    case "en": return String(localized: "language_english", table: "Localizable")
    case "de": return String(localized: "language_german", table: "Localizable")
    case "fi": return String(localized: "language_finnish", table: "Localizable")
    case "sv": return String(localized: "language_swedish", table: "Localizable")
    case "et": return String(localized: "language_estonian", table: "Localizable")
    default: return code.capitalized
    }
}
