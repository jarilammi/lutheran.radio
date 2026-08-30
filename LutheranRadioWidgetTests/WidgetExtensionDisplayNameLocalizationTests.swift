//
//  WidgetExtensionDisplayNameLocalizationTests.swift
//  LutheranRadioWidgetTests
//
//  Protects the widget gallery **section** name. WidgetKit groups widgets
//  under the extension `CFBundleDisplayName`. The OS loads that key from
//  `InfoPlist.strings` compiled from `LutheranRadioWidget/InfoPlist.xcstrings`,
//  not from `Localizable.xcstrings`. The English fallback is the generated
//  Info.plist value from `INFOPLIST_KEY_CFBundleDisplayName`.
//
//  Invariant: every README Localizations language has a non-empty
//  `CFBundleDisplayName` equal to `"lutheran_radio_title"`. The development
//  fallback is `"Lutheran Radio"`, never the target identifier
//  `LutheranRadioWidget`.
//
//  - SeeAlso: `LutheranRadioWidget/InfoPlist.xcstrings`, `lutheran_radio_title`,
//    `LutheranRadioWidget.swift` (`.configurationDisplayName`),
//    README.md Localizations, CODING_AGENT.md (Localization).
//
//  Created by Jari Lammi on 24.8.2026.
//

import XCTest

/// Source-catalog completeness for the widget extension gallery section name.
final class WidgetExtensionDisplayNameLocalizationTests: XCTestCase {

    /// UI catalog languages: README Localizations / Localizable coverage (the 33
    /// language codes). Playback catalog remains the five radio streams.
    private let supportedLanguages: [String] = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fit",
        "fo", "fr", "gag", "hr", "hu", "is", "it", "kl", "lt", "lv", "nb", "nl",
        "nn", "pl", "pt", "ro", "ru", "se", "sk", "sl", "sq", "sv", "uk",
    ]

    private let displayNameKey = "CFBundleDisplayName"
    private let stationTitleKey = "lutheran_radio_title"
    private let expectedEnglishDisplayName = "Lutheran Radio"
    private let forbiddenTargetIdentifier = "LutheranRadioWidget"

    /// `CFBundleDisplayName` ships a translated value for every UI catalog language.
    func testInfoPlistCatalogCoversCFBundleDisplayNameForEveryLanguage() throws {
        let localizations = try displayNameLocalizations()
        let missingLanguages = Set(supportedLanguages).subtracting(localizations.keys)
        XCTAssertTrue(
            missingLanguages.isEmpty,
            "\(displayNameKey) is missing languages: \(missingLanguages.sorted())"
        )
        XCTAssertEqual(
            try stringUnitValue(localizations, language: "en"),
            expectedEnglishDisplayName,
            "English \(displayNameKey) must be the product title, not the target identifier"
        )
        for language in supportedLanguages {
            let value = try stringUnitValue(localizations, language: language)
            XCTAssertFalse(value.isEmpty, "\(language) \(displayNameKey) is empty")
            XCTAssertNotEqual(
                value,
                forbiddenTargetIdentifier,
                "\(language) \(displayNameKey) leaked the target identifier"
            )
        }
    }

    /// Gallery section name stays in lockstep with the Localizable station title.
    func testInfoPlistDisplayNameMatchesLutheranRadioTitleInEveryLanguage() throws {
        let displayNames = try displayNameLocalizations()
        let titles = try lutheranRadioTitleLocalizations()
        for language in supportedLanguages {
            let displayName = try stringUnitValue(displayNames, language: language)
            let title = try stringUnitValue(titles, language: language)
            XCTAssertEqual(
                displayName,
                title,
                "\(language) \(displayNameKey) drifted from \(stationTitleKey)"
            )
        }
    }

    /// Generated Info.plist fallback must be the product title, not `LutheranRadioWidget`.
    func testBuildSettingDisplayNameIsProductTitleNotTargetIdentifier() throws {
        let pbxproj = try String(contentsOf: repoRoot().appendingPathComponent("Lutheran Radio.xcodeproj/project.pbxproj"))
        XCTAssertFalse(
            pbxproj.contains("INFOPLIST_KEY_CFBundleDisplayName = \(forbiddenTargetIdentifier);"),
            "INFOPLIST_KEY_CFBundleDisplayName must not be the target identifier \(forbiddenTargetIdentifier)"
        )
        XCTAssertTrue(
            pbxproj.contains("INFOPLIST_KEY_CFBundleDisplayName = \"\(expectedEnglishDisplayName)\";"),
            "INFOPLIST_KEY_CFBundleDisplayName must be \"\(expectedEnglishDisplayName)\" (quoted; space in the product title)"
        )
    }

    // MARK: - Helpers

    private func displayNameLocalizations() throws -> [String: Any] {
        let catalog = try loadJSONCatalog("LutheranRadioWidget/InfoPlist.xcstrings")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let entry = try XCTUnwrap(strings[displayNameKey] as? [String: Any], "Missing \(displayNameKey)")
        return try XCTUnwrap(entry["localizations"] as? [String: Any])
    }

    private func lutheranRadioTitleLocalizations() throws -> [String: Any] {
        let catalog = try loadJSONCatalog("Lutheran Radio/Localizable.xcstrings")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let entry = try XCTUnwrap(strings[stationTitleKey] as? [String: Any], "Missing \(stationTitleKey)")
        return try XCTUnwrap(entry["localizations"] as? [String: Any])
    }

    private func stringUnitValue(_ localizations: [String: Any], language: String) throws -> String {
        let localization = try XCTUnwrap(
            localizations[language] as? [String: Any],
            "missing \(language)"
        )
        let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
        return try XCTUnwrap(unit["value"] as? String)
    }

    private func loadJSONCatalog(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent(relativePath))
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], "\(relativePath) is not a dictionary")
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
