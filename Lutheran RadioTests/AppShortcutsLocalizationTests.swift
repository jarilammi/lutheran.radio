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
//  translated value for every UI language in README Localizations (the 45
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
    /// (the 45 language codes). Playback catalog remains the five radio streams.
    private let supportedLanguages: [String] = [
        "af", "am", "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fit",
        "fo", "fr", "gag", "ha", "hi", "hr", "hu", "id", "is", "it", "kl", "lt",
        "lv", "mg", "nb", "ng", "nl", "nn", "om", "pl", "pt", "pt-BR", "ro", "ru",
        "se", "sk", "sl", "sq", "sv", "sw", "ta", "te", "uk",
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

    func testCompiledBrazilianPortuguesePlayAndPausePhrasesAreNative() {
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName}", language: "pt-BR"),
            "Tocar ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Pause ${applicationName}", language: "pt-BR"),
            "Pausar ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName} in ${language}", language: "pt-BR"),
            "Tocar ${applicationName} em ${language}"
        )
        XCTAssertEqual(
            compiledPhrase("Switch ${applicationName} to ${language}", language: "pt-BR"),
            "Trocar ${applicationName} para ${language}"
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

    func testCompiledTeluguPlayAndPausePhrasesAreNative() {
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName}", language: "te"),
            "${applicationName} ప్లే చేయి"
        )
        XCTAssertEqual(
            compiledPhrase("Pause ${applicationName}", language: "te"),
            "${applicationName} పాజ్ చేయి"
        )
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName} in ${language}", language: "te"),
            "${applicationName}ని ${language}లో ప్లే చేయి"
        )
        XCTAssertEqual(
            compiledPhrase("Switch ${applicationName} to ${language}", language: "te"),
            "${applicationName}ని ${language}కి మార్చు"
        )
    }

    func testCompiledAmharicPlayAndPausePhrasesAreNative() {
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName}", language: "am"),
            "${applicationName}ን አጫውት"
        )
        XCTAssertEqual(
            compiledPhrase("Pause ${applicationName}", language: "am"),
            "${applicationName}ን ለአፍታ አቁም"
        )
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName} in ${language}", language: "am"),
            "${applicationName}ን በ${language} አጫውት"
        )
        XCTAssertEqual(
            compiledPhrase("Switch ${applicationName} to ${language}", language: "am"),
            "${applicationName}ን ወደ ${language} ቀይር"
        )
    }

    func testCompiledSwahiliPlayAndPausePhrasesAreNative() {
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName}", language: "sw"),
            "Cheza ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Pause ${applicationName}", language: "sw"),
            "Sitisha ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName} in ${language}", language: "sw"),
            "Cheza ${applicationName} kwa ${language}"
        )
        XCTAssertEqual(
            compiledPhrase("Switch ${applicationName} to ${language}", language: "sw"),
            "Badilisha ${applicationName} kuwa ${language}"
        )
    }

    func testCompiledIndonesianPlayAndPausePhrasesAreNative() {
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName}", language: "id"),
            "Putar ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Pause ${applicationName}", language: "id"),
            "Jeda ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName} in ${language}", language: "id"),
            "Putar ${applicationName} dalam bahasa ${language}"
        )
        XCTAssertEqual(
            compiledPhrase("Switch ${applicationName} to ${language}", language: "id"),
            "Alihkan ${applicationName} ke bahasa ${language}"
        )
    }

    func testCompiledMalagasyPlayAndPausePhrasesAreNative() {
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName}", language: "mg"),
            "Alefaso ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Pause ${applicationName}", language: "mg"),
            "Ajanony ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName} in ${language}", language: "mg"),
            "Alefaso ${applicationName} amin'ny ${language}"
        )
        XCTAssertEqual(
            compiledPhrase("Switch ${applicationName} to ${language}", language: "mg"),
            "Ovay ${applicationName} ho ${language}"
        )
    }

    func testCompiledAfrikaansPlayAndPausePhrasesAreNative() {
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName}", language: "af"),
            "Speel ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Pause ${applicationName}", language: "af"),
            "Pouseer ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName} in ${language}", language: "af"),
            "Speel ${applicationName} in ${language}"
        )
        XCTAssertEqual(
            compiledPhrase("Switch ${applicationName} to ${language}", language: "af"),
            "Skakel ${applicationName} oor na ${language}"
        )
    }

    func testCompiledOromoPlayAndPausePhrasesAreNative() {
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName}", language: "om"),
            "${applicationName} taphachiisi"
        )
        XCTAssertEqual(
            compiledPhrase("Pause ${applicationName}", language: "om"),
            "${applicationName} yeroof dhaabi"
        )
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName} in ${language}", language: "om"),
            "${applicationName} afaan ${language} taphachiisi"
        )
        XCTAssertEqual(
            compiledPhrase("Switch ${applicationName} to ${language}", language: "om"),
            "${applicationName} gara ${language} jijjiiri"
        )
    }

    func testCompiledNdongaPlayAndPausePhrasesAreNative() {
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName}", language: "ng"),
            "Dhana ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Pause ${applicationName}", language: "ng"),
            "Kala po ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName} in ${language}", language: "ng"),
            "Dhana ${applicationName} mElaka ${language}"
        )
        XCTAssertEqual(
            compiledPhrase("Switch ${applicationName} to ${language}", language: "ng"),
            "Lundulula ${applicationName} ko ${language}"
        )
    }

    func testCompiledHausaPlayAndPausePhrasesAreNative() {
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName}", language: "ha"),
            "Kunna ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Pause ${applicationName}", language: "ha"),
            "Dakata ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName} in ${language}", language: "ha"),
            "Kunna ${applicationName} a ${language}"
        )
        XCTAssertEqual(
            compiledPhrase("Switch ${applicationName} to ${language}", language: "ha"),
            "Canza ${applicationName} zuwa ${language}"
        )
    }

    func testCompiledTamilPlayAndPausePhrasesAreNative() {
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName}", language: "ta"),
            "${applicationName} பிளே செய்"
        )
        XCTAssertEqual(
            compiledPhrase("Pause ${applicationName}", language: "ta"),
            "${applicationName} பாஸ் செய்"
        )
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName} in ${language}", language: "ta"),
            "${applicationName}ஐ ${language}இல் பிளே செய்"
        )
        XCTAssertEqual(
            compiledPhrase("Switch ${applicationName} to ${language}", language: "ta"),
            "${applicationName}ஐ ${language}க்கு மாற்று"
        )
    }

    func testCompiledHindiPlayAndPausePhrasesAreNative() {
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName}", language: "hi"),
            "${applicationName} प्ले करें"
        )
        XCTAssertEqual(
            compiledPhrase("Pause ${applicationName}", language: "hi"),
            "${applicationName} पॉज़ करें"
        )
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName} in ${language}", language: "hi"),
            "${applicationName} को ${language} में प्ले करें"
        )
        XCTAssertEqual(
            compiledPhrase("Switch ${applicationName} to ${language}", language: "hi"),
            "${applicationName} को ${language} में बदलें"
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
