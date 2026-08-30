//
//  AppShortcutsLocalizationTests.swift
//  Lutheran RadioTests
//
//  Protects native-language Siri invocation for App Shortcuts. Apple trains
//  utterances from the dedicated `AppShortcuts` table only — Localizable titles
//  do not register "Toista Lutheran Radio" / "Spiele Lutheran Radio".
//
//  Invariant: every phrase in `LutheranRadioShortcuts` is extracted as
//  `Play ${applicationName}` (etc.) and `AppShortcuts.xcstrings` ships a
//  translated value for every UI language in README Localizations (the 33
//  language codes). Every value keeps
//  `${applicationName}`; parameterized phrases also keep `${language}`.
//  Xcode binds only the first phrase of each `AppShortcut` initializer, so
//  the provider must register one shortcut per utterance (no stale keys).
//
//  - SeeAlso: `LutheranRadioShortcuts`, `AppShortcuts.xcstrings`,
//    `RadioPlaybackIntents.swift` (file header AGENT NOTE), README.md
//    Localizations, CODING_AGENT.md (Localization — AppShortcuts table is the
//    Apple-mandated exception to the Localizable default).
//
//  Created by Jari Lammi on 13.8.2026.
//

import XCTest
@testable import Lutheran_Radio

final class AppShortcutsLocalizationTests: XCTestCase {

    /// UI catalog languages: README Localizations / Localizable + AppShortcuts coverage
    /// (the 33 language codes). Playback catalog remains the five radio streams.
    private let supportedLanguages: [String] = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fit",
        "fo", "fr", "gag", "hr", "hu", "is", "it", "kl", "lt", "lv", "nb", "nl",
        "nn", "pl", "pt", "ro", "ru", "se", "sk", "sl", "sq", "sv", "uk",
    ]

    private let requiredPhraseKeys: [String] = [
        "Play ${applicationName}",
        "Start ${applicationName}",
        "Play ${applicationName} in ${language}",
        "Pause ${applicationName}",
        "Stop ${applicationName}",
        "Switch ${applicationName} to ${language}",
    ]

    private let parameterizedPhraseKeys: Set<String> = [
        "Play ${applicationName} in ${language}",
        "Switch ${applicationName} to ${language}",
    ]

    private let appBundle = Bundle(for: PlayerViewModel.self)

    // MARK: - Source catalog (authoritative for translator completeness)

    func testAppShortcutsCatalogCoversEveryPhraseAndLanguage() throws {
        let catalog = try loadSourceCatalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        let missingKeys = Set(requiredPhraseKeys).subtracting(strings.keys)
        XCTAssertTrue(
            missingKeys.isEmpty,
            "AppShortcuts.xcstrings is missing utterance keys: \(missingKeys.sorted())"
        )

        for key in requiredPhraseKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing entry \(key)")
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                "Missing localizations for \(key)"
            )
            let missingLanguages = Set(supportedLanguages).subtracting(localizations.keys)
            XCTAssertTrue(
                missingLanguages.isEmpty,
                "\(key) is missing languages: \(missingLanguages.sorted())"
            )

            for language in supportedLanguages {
                let localization = try XCTUnwrap(
                    localizations[language] as? [String: Any],
                    "\(key) missing \(language)"
                )
                let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
                let value = try XCTUnwrap(unit["value"] as? String)
                XCTAssertFalse(value.isEmpty, "\(language) \(key) is empty")
                XCTAssertTrue(
                    value.contains("${applicationName}"),
                    "\(language) \(key) dropped ${applicationName}: \(value)"
                )
                if parameterizedPhraseKeys.contains(key) {
                    XCTAssertTrue(
                        value.contains("${language}"),
                        "\(language) \(key) dropped ${language}: \(value)"
                    )
                }
            }
        }
    }

    func testUtteranceTokenKeysAreNotInLocalizable() {
        for key in requiredPhraseKeys {
            let fromLocalizable = appBundle.localizedString(
                forKey: key,
                value: "MISSING",
                table: "Localizable"
            )
            XCTAssertEqual(
                fromLocalizable,
                "MISSING",
                "Utterance key \(key) leaked into Localizable.xcstrings — Siri will not train it there"
            )
        }
    }

    // MARK: - Compiled table (what Siri / Foundation actually loads)

    func testCompiledFinnishPlayPhraseIsNative() {
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName}", language: "fi"),
            "Toista ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName} in ${language}", language: "fi"),
            "Toista ${applicationName} kielellä ${language}"
        )
    }

    func testCompiledGermanPlayAndPausePhrasesAreNative() {
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName}", language: "de"),
            "Spiele ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Pause ${applicationName}", language: "de"),
            "Pausiere ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Switch ${applicationName} to ${language}", language: "de"),
            "Wechsle ${applicationName} zu ${language}"
        )
    }

    func testCompiledSwedishStartAndStopPhrasesAreNative() {
        XCTAssertEqual(
            compiledPhrase("Start ${applicationName}", language: "sv"),
            "Starta ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Stop ${applicationName}", language: "sv"),
            "Stoppa ${applicationName}"
        )
    }

    func testCompiledFrenchPlayAndPausePhrasesAreNative() {
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName}", language: "fr"),
            "Joue ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Pause ${applicationName}", language: "fr"),
            "Mets ${applicationName} en pause"
        )
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName} in ${language}", language: "fr"),
            "Joue ${applicationName} en ${language}"
        )
        XCTAssertEqual(
            compiledPhrase("Switch ${applicationName} to ${language}", language: "fr"),
            "Passe ${applicationName} en ${language}"
        )
    }

    func testCompiledItalianPlayAndPausePhrasesAreNative() {
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName}", language: "it"),
            "Riproduci ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Pause ${applicationName}", language: "it"),
            "Metti in pausa ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName} in ${language}", language: "it"),
            "Riproduci ${applicationName} in ${language}"
        )
        XCTAssertEqual(
            compiledPhrase("Switch ${applicationName} to ${language}", language: "it"),
            "Passa ${applicationName} a ${language}"
        )
    }

    func testCompiledPortuguesePlayAndPausePhrasesAreNative() {
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName}", language: "pt"),
            "Reproduzir ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Pause ${applicationName}", language: "pt"),
            "Pausar ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName} in ${language}", language: "pt"),
            "Reproduzir ${applicationName} em ${language}"
        )
        XCTAssertEqual(
            compiledPhrase("Switch ${applicationName} to ${language}", language: "pt"),
            "Mudar ${applicationName} para ${language}"
        )
    }

    func testCompiledUkrainianPlayAndPausePhrasesAreNative() {
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName}", language: "uk"),
            "Увімкни ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Pause ${applicationName}", language: "uk"),
            "Призупини ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName} in ${language}", language: "uk"),
            "Увімкни ${applicationName} мовою ${language}"
        )
        XCTAssertEqual(
            compiledPhrase("Switch ${applicationName} to ${language}", language: "uk"),
            "Перемкни ${applicationName} на ${language}"
        )
    }

    /// Every compiled `.lproj` AppShortcuts table must resolve the English key
    /// to a native string, not fall back to the key itself.
    func testCompiledAppShortcutsTableResolvesEverySupportedLanguage() {
        for language in supportedLanguages {
            let play = compiledPhrase("Play ${applicationName}", language: language)
            XCTAssertNotEqual(play, "MISSING", "\(language).lproj is missing the AppShortcuts table")
            XCTAssertTrue(
                play.contains("${applicationName}"),
                "\(language) compiled Play phrase dropped ${applicationName}: \(play)"
            )
            if language == "en" {
                XCTAssertEqual(play, "Play ${applicationName}")
            } else {
                XCTAssertNotEqual(
                    play,
                    "Play ${applicationName}",
                    "\(language).lproj AppShortcuts fell back to the English key (untranslated?)"
                )
            }
        }
    }

    func testProviderRegistersOneShortcutPerUtterance() {
        let shortcuts = LutheranRadioShortcuts.appShortcuts
        XCTAssertEqual(
            shortcuts.count,
            requiredPhraseKeys.count,
            "Xcode extracts only the first phrase of each AppShortcut into AppShortcuts.xcstrings; keep one utterance per shortcut"
        )
    }

    func testAppShortcutsCatalogHasNoStaleUtteranceKeys() throws {
        let catalog = try loadSourceCatalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        for key in requiredPhraseKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing entry \(key)")
            let state = entry["extractionState"] as? String
            XCTAssertNotEqual(
                state,
                "stale",
                "\(key) is stale — Xcode did not bind this phrase (one phrase per AppShortcut required)"
            )
        }
    }

    // MARK: - Helpers

    private func loadSourceCatalog() throws -> [String: Any] {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let catalogURL = testsDir
            .deletingLastPathComponent()
            .appendingPathComponent("Lutheran Radio/AppShortcuts.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], "AppShortcuts.xcstrings is not a dictionary")
    }

    private func compiledPhrase(_ key: String, language: String) -> String {
        guard let path = appBundle.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            XCTFail("App bundle is missing \(language).lproj")
            return ""
        }
        return bundle.localizedString(forKey: key, value: "MISSING", table: "AppShortcuts")
    }
}
