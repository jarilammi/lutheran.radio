//
//  DirectStreamingPlayer+StreamCatalog.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 23.7.2026.
//
//  Stream list, language lookup helpers, and secure stream URL construction inputs
//  for the main-app DirectStreamingPlayer. Mechanical extraction — no behavior change.
//
//  Widget-extension stream list parity lives in DirectStreamingPlayer+WidgetStub.swift
//  (display/lookup only; no security_model URL construction).
//
//  SECURITY: URL construction embeds SecurityConfiguration.current.expectedSecurityModel.
//  Do not duplicate this outside Core + this main-app surface.
//
//  - SeeAlso: DirectStreamingPlayer.swift, Core/Configuration/SecurityConfiguration.swift,
//    CODING_AGENT.md.
//

import Foundation
import Core

extension DirectStreamingPlayer {
    // MARK: - Stream URL Construction Rules
    //
    // All stream URLs follow this exact pattern:
    //
    //   https://<language-slug>-<region>.lutheran.radio/lutheranradio.mp3?security_model=<model>
    //
    // Breakdown:
    // • <language-slug>  → hardcoded mapping from language code:
    //     "en" → "english"   | "de" → "german"   | "fi" → "finnish"
    //     "sv" → "swedish"   | "et" → "estonian" | others → fallback to "english"
    //
    // • <region> → determined at runtime via TimeZone.current:
    //     - Europe/, GMT/UTC/WET/CET/EET/Atlantic/Reykjavik/Faroe → "eu"
    //     - America/, US/, Canada/, EST/CST/MST/PST → "us"
    //     - Everything else → "us" (US cluster has higher capacity)
    //
    // • Port is always 443 (TLS on standard port)
    // • Path is always "/lutheranradio.mp3"
    // • Query parameter "security_model" = current expected security model (from SecurityConfiguration)
    //
    // This design achieves:
    // 1. Geographic load distribution (lower latency)
    // 2. Simple automatic failover (if one cluster is down, the other is used next launch)
    // 3. Future-proof version gating via DNS TXT record
    //
    // WHEN RELEASING A NEW SECURITY MODEL (certificate rotation, etc.):
    // 1. Update `expectedSecurityModel` in `Core/Configuration/SecurityConfiguration.swift`
    // 2. Add the new codename to the TXT record on securitymodels.lutheran.radio
    // 3. Append a row to the Security Model History table in README.md
    // 4. Ship the app update → users on the new version will validate against the new model
    //
    // DO NOT reuse old codenames — see the history table in README.md to avoid collisions.
    private enum RegionDetector {
        static var currentRegion: Region {
            let tz = TimeZone.current.identifier
            
            if tz.hasPrefix("Europe/") ||
                ["GMT", "UTC", "WET", "CET", "EET", "Atlantic/Reykjavik", "Atlantic/Faroe"].contains(where: tz.hasPrefix) {
                return .eu
            }
            
            if tz.hasPrefix("America/") || tz.hasPrefix("US/") || tz.hasPrefix("Canada/") ||
                ["EST", "CST", "MST", "PST"].contains(where: tz.hasPrefix) {
                return .us
            }
            
            return .us // safe default – US cluster has higher capacity
        }
        
        enum Region: String {
            case eu = "eu"
            case us = "us"
        }
    }
    
    private struct LanguageSlugMapper {
        static func slug(for code: String) -> String {
            switch code {
            case "en": return "english"
            case "de": return "german"
            case "fi": return "finnish"
            case "sv": return "swedish"
            case "et": return "estonian"
            default: return "english"
            }
        }
    }
    
    private struct StreamURLBuilder {
        static func url(for languageCode: String,
                        region: String = DirectStreamingPlayer.shared.currentSelectedServer.subdomain) -> URL {
            
            let languageSlug = LanguageSlugMapper.slug(for: languageCode)
            
            var components = URLComponents()
            components.scheme = "https"
            components.host = "\(languageSlug)-\(region).lutheran.radio"
            components.path = "/lutheranradio.mp3"
            components.queryItems = [
                URLQueryItem(name: "security_model", value: SecurityConfiguration.current.expectedSecurityModel)
            ]
            
            // This construction is guaranteed to succeed with valid inputs.
            // We use a helper so we have a single place for all hardcoded URL fallbacks.
            return components.url ?? makeURL("https://livestream.lutheran.radio")
        }
    }
    
    // MARK: - Server and Stream Structs
    /// A radio stream configuration.
    /// - Example: `Stream(title: "English", language: "English", languageCode: "en", flag: "🇺🇸")
    struct Stream {
        /// Display title (localized).
        let title: String
        /// Streaming URL (HTTPS required).
        var url: URL {
            StreamURLBuilder.url(for: languageCode)
        }
        /// Language name (localized).
        let language: String
        /// ISO language code (e.g., "en").
        let languageCode: String
        /// Emoji flag for UI.
        let flag: String
    }
    
    /// Available streams by language.
    /// - Note: Static array; URLs must be HTTPS for security.
    static let availableStreams = [
        Stream(title: String(localized: "lutheran_radio_title", defaultValue: "Lutheran Radio", table: "Localizable", comment: "Title for Lutheran Radio") + " - " +
               String(localized: "language_english", defaultValue: "English", table: "Localizable", comment: "English language option"),
               language: String(localized: "language_english", defaultValue: "English", table: "Localizable", comment: "English language option"),
               languageCode: "en",
               flag: "🇺🇸"),
        Stream(title: String(localized: "lutheran_radio_title", defaultValue: "Lutheran Radio", table: "Localizable", comment: "Title for Lutheran Radio") + " - " +
               String(localized: "language_german", defaultValue: "German", table: "Localizable", comment: "German language option"),
               language: String(localized: "language_german", defaultValue: "German", table: "Localizable", comment: "German language option"),
               languageCode: "de",
               flag: "🇩🇪"),
        Stream(title: String(localized: "lutheran_radio_title", defaultValue: "Lutheran Radio", table: "Localizable", comment: "Title for Lutheran Radio") + " - " +
               String(localized: "language_finnish", defaultValue: "Finnish", table: "Localizable", comment: "Finnish language option"),
               language: String(localized: "language_finnish", defaultValue: "Finnish", table: "Localizable", comment: "Finnish language option"),
               languageCode: "fi",
               flag: "🇫🇮"),
        Stream(title: String(localized: "lutheran_radio_title", defaultValue: "Lutheran Radio", table: "Localizable", comment: "Title for Lutheran Radio") + " - " +
               String(localized: "language_swedish", defaultValue: "Swedish", table: "Localizable", comment: "Swedish language option"),
               language: String(localized: "language_swedish", defaultValue: "Swedish", table: "Localizable", comment: "Swedish language option"),
               languageCode: "sv",
               flag: "🇸🇪"),
        Stream(title: String(localized: "lutheran_radio_title", defaultValue: "Lutheran Radio", table: "Localizable", comment: "Title for Lutheran Radio") + " - " +
               String(localized: "language_estonian", defaultValue: "Estonian", table: "Localizable", comment: "Estonian language option"),
               language: String(localized: "language_estonian", defaultValue: "Estonian", table: "Localizable", comment: "Estonian language option"),
               languageCode: "et",
               flag: "🇪🇪"),
    ]

    // MARK: - Initial language helpers (centralized for main-app reseed + cold launch)

    /// Best initial radio stream languageCode for the main app UI (LanguageSelectorView needle position,
    /// early cold-launch seeds, background images, and the post-clear cold-launch auto-play choice).
    ///
    /// Prefers the localizations that the *main bundle actually resolved* for the current run
    /// (Bundle.main.preferredLocalizations, in user preference order). This captures the effective
    /// app language the UI is presenting ("Finnish on a fi device", simulator Application Language
    /// overrides via -AppleLanguages, etc.). We walk the full ordered list and return the first
    /// subtag that matches one of our five supported radio streams (en, de, fi, sv, et). This ensures
    /// the initial needle and auto-play stream match the localized experience when the presented
    /// language is a supported radio language.
    ///
    /// Falls back to walking the user's `Locale.preferredLanguages` (the list that also drives
    /// Localizable.xcstrings), then Locale.current. Ultimate fallback "en".
    ///
    /// This produces a user-friendly starting selection on first-run or after privacy clear,
    /// while still being a non-identifying default.
    ///
    /// Distinct from widget privacy paths: `SharedPlayerManager.preferredWidgetLanguage()` (and all
    /// widget/Live Activity providers) intentionally hard-fallback to "en" with *no* device locale
    /// probing when `loadPersistedWidgetState()` is absent (or hasActiveWidgets is false post-clear).
    /// This prevents writing any language signal into the App Group when no widgets are configured
    /// (writes suppressed). The main-app path (preferredMainAppInitialLanguageCode) always uses
    /// bestInitial on no-snapshot so post-clear reseed + launch play get the right lang.
    static func bestInitialLanguageCode() -> String {
        let supported = Set(Self.availableStreams.map { $0.languageCode })

        // 1. Bundle's resolved preferredLocalizations first (the localizations the app actually
        //    selected for strings/UI this run). Walking the full list (not just .first) gives the
        //    highest user-preference radio lang that the bundle accepted, which reliably reflects
        //    simulator scheme overrides and device UI language even when Locale.preferredLanguages
        //    leads with the dev language or another entry.
        for raw in Bundle.main.preferredLocalizations {
            let candidate = raw.split(separator: "-").first.map(String.init) ?? raw
            if supported.contains(candidate) {
                return candidate
            }
        }

        // 2. User's ordered preferredLanguages (drives strings + explicit user ordering).
        for raw in Locale.preferredLanguages {
            // preferredLanguages values are BCP-47-like: "fi", "fi-FI", "en-US", "zh-Hans-CN" etc.
            let candidate = raw.split(separator: "-").first.map(String.init) ?? raw
            if supported.contains(candidate) {
                return candidate
            }
        }

        // 3. Last-chance current locale subtag.
        if let current = Locale.current.language.languageCode?.identifier,
           supported.contains(current) {
            return current
        }

        return "en"
    }

    /// Returns the index of the stream for the given languageCode (suitable for LanguageSelectorView
    /// and selectedStreamIndex). Returns 0 (English) if the code is not one of the supported streams.
    /// Replaces all the previous repeated `firstIndex(where: ...) ?? 0` for initial selection paths.
    static func indexForLanguageCode(_ languageCode: String) -> Int {
        availableStreams.firstIndex(where: { $0.languageCode == languageCode }) ?? 0
    }

    /// Returns the Stream matching the languageCode, or the English default (index 0) if not found.
    /// Used for safe lookup from a code we believe is valid (initial choice, model-only set, etc.).
    static func streamForLanguageCode(_ languageCode: String) -> Stream {
        availableStreams.first(where: { $0.languageCode == languageCode }) ?? availableStreams[0]
    }
}
