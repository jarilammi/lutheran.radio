//
//  AppShortcutsLocalizationTests.swift
//  Lutheran RadioTests
//
//  Protects native-language Siri invocation for App Shortcuts. Apple trains
//  utterances from the dedicated `AppShortcuts` table only — Localizable titles
//  do not register "Toista Lutheran Radio" / "Spiele Lutheran Radio".
//
//  Invariant: every play / pause / language phrase in `LutheranRadioShortcuts`
//  is extracted as `Play ${applicationName}` (etc.) and `AppShortcuts.xcstrings`
//  ships a translated value for every UI language in README Localizations (the
//  55 language codes). Sleep-timer phrases are native in en, de, fi, sv, and et
//  only; other languages fall back to English. Every value keeps
//  `${applicationName}`; parameterized phrases also keep `${language}` or
//  `${duration}`. Xcode binds only the first phrase of each `AppShortcut`
//  initializer, so the provider must register one shortcut per utterance
//  (no stale keys). The provider is capped at 10 shortcuts.
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
    /// (the 55 language codes). Playback catalog remains the five radio streams.
    private let supportedLanguages: [String] = [
        "af", "am", "bem", "bg", "bn", "cs", "da", "de", "el", "en", "es", "et", "fi", "fit",
        "fo", "fr", "gag", "ha", "haw", "hi", "hr", "hu", "id", "is", "it", "kl", "lt",
        "lv", "mg", "nb", "ng", "nl", "nn", "ny", "om", "pl", "pt", "pt-BR", "ro", "ru",
        "se", "sk", "sl", "sq", "sv", "sw", "ta", "te", "ti", "tr", "uk", "yo", "zu",
        "zh-Hans", "zh-Hant",
    ]

    private let requiredPhraseKeys: [String] = [
        "Play ${applicationName}",
        "Start ${applicationName}",
        "Play ${applicationName} in ${language}",
        "Pause ${applicationName}",
        "Stop ${applicationName}",
        "Switch ${applicationName} to ${language}",
    ]

    /// Sleep-timer utterances. Native in en, de, fi, sv, and et only.
    /// Other UI languages fall back to the English phrase. Siri may not speak
    /// Estonian yet; the et strings are still required here.
    /// One parameterized set phrase and one cancel phrase. The other 50 UI
    /// languages are not translated here.
    private let sleepTimerPhraseKeys: [String] = [
        "Set a ${duration} sleep timer in ${applicationName}",
        "Cancel the ${applicationName} sleep timer",
    ]

    private let sleepTimerPhraseLanguages: [String] = ["en", "de", "fi", "sv", "et"]

    private let parameterizedPhraseKeys: Set<String> = [
        "Play ${applicationName} in ${language}",
        "Switch ${applicationName} to ${language}",
    ]

    private let sleepTimerParameterizedPhraseKeys: Set<String> = [
        "Set a ${duration} sleep timer in ${applicationName}",
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

    /// Sleep-timer phrases are native for five languages and keep their tokens.
    ///
    /// Estonian is included even though Siri may not speak it yet. A non-English
    /// value equal to the English key means the catalog fell back instead of
    /// shipping the reviewed phrase.
    func testSleepTimerPhrasesCoverFiveLanguages() throws {
        let catalog = try loadSourceCatalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        XCTAssertEqual(
            Set(strings.keys),
            Set(requiredPhraseKeys + sleepTimerPhraseKeys),
            "AppShortcuts.xcstrings must stay the six playback phrases plus the two sleep-timer phrases"
        )

        for key in sleepTimerPhraseKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing entry \(key)")
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                "Missing localizations for \(key)"
            )
            let english = try phraseValue(localizations, language: "en", key: key)
            XCTAssertEqual(english, key, "\(key) English value drifted from the source phrase")

            for language in sleepTimerPhraseLanguages {
                let value = try phraseValue(localizations, language: language, key: key)
                XCTAssertFalse(value.isEmpty, "\(language) \(key) is empty")
                XCTAssertTrue(
                    value.contains("${applicationName}"),
                    "\(language) \(key) dropped ${applicationName}: \(value)"
                )
                if sleepTimerParameterizedPhraseKeys.contains(key) {
                    XCTAssertTrue(
                        value.contains("${duration}"),
                        "\(language) \(key) dropped ${duration}: \(value)"
                    )
                }
                if language != "en" {
                    XCTAssertNotEqual(
                        value,
                        english,
                        "\(language) \(key) is still the English phrase"
                    )
                }
            }

            let comment = entry["comment"] as? String ?? ""
            XCTAssertTrue(
                comment.localizedCaseInsensitiveContains("Estonian"),
                "\(key) is missing the Estonian Siri review note"
            )
        }
    }

    func testUtteranceTokenKeysAreNotInLocalizable() {
        for key in requiredPhraseKeys + sleepTimerPhraseKeys {
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

    /// Compiled Nyanja phrases stay Malawian Chichewa and keep the Siri tokens.
    ///
    /// The every-language check only rejects an English fallback. These strings
    /// are the catalog values for locale `ny`.
    func testCompiledNyanjaPlayAndPausePhrasesAreNative() {
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName}", language: "ny"),
            "Sewerani ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Pause ${applicationName}", language: "ny"),
            "Imitsani ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName} in ${language}", language: "ny"),
            "Sewerani ${applicationName} m'chinenero ${language}"
        )
        XCTAssertEqual(
            compiledPhrase("Switch ${applicationName} to ${language}", language: "ny"),
            "Sinthani ${applicationName} kukhala ${language}"
        )
    }

    /// Compiled Bengali phrases stay Bangladeshi Bangla and keep the Siri tokens.
    ///
    /// The every-language check only rejects an English fallback. These strings
    /// are the catalog values for locale `bn`.
    func testCompiledBengaliPlayAndPausePhrasesAreNative() {
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName}", language: "bn"),
            "${applicationName} চালান"
        )
        XCTAssertEqual(
            compiledPhrase("Pause ${applicationName}", language: "bn"),
            "${applicationName} বিরতি দিন"
        )
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName} in ${language}", language: "bn"),
            "${applicationName} ${language} ভাষায় চালান"
        )
        XCTAssertEqual(
            compiledPhrase("Switch ${applicationName} to ${language}", language: "bn"),
            "${applicationName} ${language} ভাষায় বদলান"
        )
    }

    /// Compiled Turkish phrases stay Turkey Turkish and keep the Siri tokens.
    ///
    /// The every-language check only rejects an English fallback. These strings
    /// are the catalog values for locale `tr`.
    func testCompiledTurkishPlayAndPausePhrasesAreNative() {
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName}", language: "tr"),
            "${applicationName} uygulamasını oynat"
        )
        XCTAssertEqual(
            compiledPhrase("Pause ${applicationName}", language: "tr"),
            "${applicationName} uygulamasını duraklat"
        )
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName} in ${language}", language: "tr"),
            "${applicationName} uygulamasını ${language} dilinde oynat"
        )
        XCTAssertEqual(
            compiledPhrase("Switch ${applicationName} to ${language}", language: "tr"),
            "${applicationName} uygulamasını ${language} diline geçir"
        )
    }

    /// Compiled Bemba phrases stay Zambian Icibemba and keep the Siri tokens.
    ///
    /// The every-language check only rejects an English fallback. These strings
    /// are the catalog values for locale `bem`. School orthography uses c, not ch.
    func testCompiledBembaPlayAndPausePhrasesAreNative() {
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName}", language: "bem"),
            "Angaleni ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Pause ${applicationName}", language: "bem"),
            "Imikeni ${applicationName}"
        )
        XCTAssertEqual(
            compiledPhrase("Play ${applicationName} in ${language}", language: "bem"),
            "Angaleni ${applicationName} mu ululimi ${language}"
        )
        XCTAssertEqual(
            compiledPhrase("Switch ${applicationName} to ${language}", language: "bem"),
            "Aluleni ${applicationName} ku ${language}"
        )
    }

    /// Compiled sleep-timer phrases for the five spoken languages.
    ///
    /// German, Finnish, Swedish, and Estonian are native-review candidates.
    /// Siri may not speak Estonian yet; the compiled et table still has the phrase.
    func testCompiledSleepTimerPhrasesAreNativeForFiveLanguages() {
        let expected: [String: [String: String]] = [
            "Set a ${duration} sleep timer in ${applicationName}": [
                "en": "Set a ${duration} sleep timer in ${applicationName}",
                "de": "Stelle einen Schlaf-Timer für ${duration} in ${applicationName}",
                "fi": "Aseta uniajastin ${duration} ajaksi sovelluksessa ${applicationName}",
                "sv": "Sätt en insomningstimer på ${duration} i ${applicationName}",
                "et": "Sea uinumise taimer ${duration} peale rakenduses ${applicationName}",
            ],
            "Cancel the ${applicationName} sleep timer": [
                "en": "Cancel the ${applicationName} sleep timer",
                "de": "Beende den Schlaf-Timer in ${applicationName}",
                "fi": "Peru uniajastin sovelluksessa ${applicationName}",
                "sv": "Avbryt insomningstimern i ${applicationName}",
                "et": "Tühista uinumise taimer rakenduses ${applicationName}",
            ],
        ]
        for (key, byLanguage) in expected {
            for (language, phrase) in byLanguage {
                XCTAssertEqual(
                    compiledPhrase(key, language: language),
                    phrase,
                    "\(language) compiled phrase for \(key)"
                )
            }
        }
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
            requiredPhraseKeys.count + sleepTimerPhraseKeys.count,
            "Xcode extracts only the first phrase of each AppShortcut into AppShortcuts.xcstrings; keep one utterance per shortcut"
        )
        XCTAssertLessThanOrEqual(
            shortcuts.count,
            10,
            "appintentsmetadataprocessor rejects more than 10 App Shortcuts"
        )
    }

    func testAppShortcutsCatalogHasNoStaleUtteranceKeys() throws {
        let catalog = try loadSourceCatalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        for key in requiredPhraseKeys + sleepTimerPhraseKeys {
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

    private func phraseValue(
        _ localizations: [String: Any],
        language: String,
        key: String
    ) throws -> String {
        let localization = try XCTUnwrap(
            localizations[language] as? [String: Any],
            "\(key) missing \(language)"
        )
        let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
        return try XCTUnwrap(unit["value"] as? String)
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
