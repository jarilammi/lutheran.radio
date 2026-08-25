//
//  CatalogPluralizationTests.swift
//  Lutheran RadioTests
//
//  Protects String Catalog `variations.plural` on count keys. The catalog cannot
//  inflect if the call site uses `String(format: String(localized:), n)` — that
//  localizes first (always `other`) and only then substitutes the number
//  ("1 minutes remaining"). Production uses String(localized:defaultValue:)
//  interpolation so Foundation can select the CLDR category.
//
//  Coverage is both catalog structure and compiled runtime for every README
//  Localizations language (32 codes), not a 10-locale subset. A missing or
//  wrong Slovak `few` string, a dropped Northern Sami `two`, or a missing
//  Latvian `zero` must fail CI. Integer-unreachable `many` (cs, sk, lt) and
//  decimal-only `other` (pl, ru) are catalog-gated; integer probes skip them.
//
//  - SeeAlso: `Localizable.xcstrings` (`%lld languages`,
//    `sleep_timer_accessibility_remaining`, `accessibility_value_volume`,
//    `volume_set_to`), `PlayerViewModel.sleepTimerAccessibilityValue`,
//    `SystemVolume.accessibilityValueText(for:)`, README.md Localizations.
//
//  Created by Jari Lammi on 13.8.2026.
//

import XCTest
@testable import Lutheran_Radio

final class CatalogPluralizationTests: XCTestCase {

    /// App bundle that contains the compiled `*.lproj` catalogs.
    ///
    /// Two axes must both match the language under test:
    /// - `bundle` — which `*.lproj` table is loaded (preferred localizations).
    /// - `locale` — which CLDR plural rules pick `zero`/`one`/`two`/`few`/`many`/`other`.
    /// A Finnish simulator with only `locale: "pl"` still loads Finnish strings;
    /// a Polish `.lproj` without `locale: "pl"` still applies Finnish one/other rules.
    private let appBundle = Bundle(for: PlayerViewModel.self)

    /// UI catalog languages: README Localizations / Localizable coverage (the 32
    /// language codes). Playback catalog remains the five radio streams.
    private let supportedLanguages: [String] = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fit",
        "fo", "fr", "gag", "hr", "hu", "is", "it", "kl", "lt", "lv", "nb", "nl",
        "nn", "pl", "pt", "ro", "ru", "se", "sk", "sl", "sq", "sv",
    ]

    private let pluralKeys: [String] = [
        "%lld languages",
        "sleep_timer_accessibility_remaining",
        "accessibility_value_volume",
        "volume_set_to",
    ]

    /// CLDR cardinal categories the String Catalog must ship per locale.
    ///
    /// AGENT NOTE: Single source of truth for which slots CI requires — do not
    /// derive this from the current catalog, or a deleted Slovak `few` would
    /// still pass. Integer-unreachable `many` (cs, sk, lt) and decimal-only
    /// `other` (pl, ru) stay in this map because Xcode still compiles them.
    /// - SeeAlso: README.md Localizations, `Localizable.xcstrings` variations.plural.
    private let requiredCatalogCategories: [String: Set<String>] = [
        "bg": ["one", "other"],
        "cs": ["one", "few", "many", "other"],
        "da": ["one", "other"],
        "de": ["one", "other"],
        "el": ["one", "other"],
        "en": ["one", "other"],
        "es": ["one", "other"],
        "et": ["one", "other"],
        "fi": ["one", "other"],
        "fit": ["one", "other"],
        "fo": ["one", "other"],
        "fr": ["one", "other"],
        "gag": ["one", "other"],
        "hr": ["one", "few", "other"],
        "hu": ["one", "other"],
        "is": ["one", "other"],
        "it": ["one", "other"],
        "kl": ["one", "other"],
        "lt": ["one", "few", "many", "other"],
        "lv": ["zero", "one", "other"],
        "nb": ["one", "other"],
        "nl": ["one", "other"],
        "nn": ["one", "other"],
        "pl": ["one", "few", "many", "other"],
        "pt": ["one", "other"],
        "ro": ["one", "few", "other"],
        "ru": ["one", "few", "many", "other"],
        "se": ["one", "two", "other"],
        "sk": ["one", "few", "many", "other"],
        "sl": ["one", "two", "few", "other"],
        "sq": ["one", "other"],
        "sv": ["one", "other"],
    ]

    /// Locales whose CLDR `many` is decimals only — runtime `%lld` probes cannot hit it.
    private let decimalOnlyManyLocales: Set<String> = ["cs", "lt", "sk"]

    /// Locales whose CLDR `other` is decimals only — integer `5` is `many`.
    private let decimalOnlyOtherLocales: Set<String> = ["pl", "ru"]

    // MARK: - Source catalog (authoritative for translator completeness)

    /// Every count key ships every UI language and the CLDR slots that locale needs.
    ///
    /// Why this is required: compiled stringsdict falls back to `other` when `few`
    /// is absent. For keys where `few` and `other` happen to share wording (Croatian
    /// volume `%lld posto`), only this structural gate fails a missing slot.
    func testPluralKeysCoverEveryLanguageAndRequiredCLDRCategory() throws {
        XCTAssertEqual(
            Set(requiredCatalogCategories.keys),
            Set(supportedLanguages),
            "requiredCatalogCategories must list exactly the 32 UI catalog languages"
        )

        let catalog = try loadLocalizableCatalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        for key in pluralKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing plural key \(key)")
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
                let variations = try XCTUnwrap(
                    localization["variations"] as? [String: Any],
                    "\(key) \(language) is not a variations.plural entry"
                )
                let plural = try XCTUnwrap(
                    variations["plural"] as? [String: Any],
                    "\(key) \(language) is missing variations.plural"
                )
                let required = try XCTUnwrap(
                    requiredCatalogCategories[language],
                    "No required categories for \(language)"
                )
                XCTAssertEqual(
                    Set(plural.keys),
                    required,
                    "\(key) \(language) CLDR categories \(Set(plural.keys).sorted()) != required \(required.sorted())"
                )
                for category in required {
                    let slot = try XCTUnwrap(
                        plural[category] as? [String: Any],
                        "\(key) \(language) missing \(category)"
                    )
                    let unit = try XCTUnwrap(slot["stringUnit"] as? [String: Any])
                    let value = try XCTUnwrap(unit["value"] as? String)
                    XCTAssertFalse(
                        value.isEmpty,
                        "\(key) \(language) \(category) is empty"
                    )
                    XCTAssertTrue(
                        value.contains("%lld"),
                        "\(key) \(language) \(category) dropped the integer placeholder: \(value)"
                    )
                    // stringsdict is a format string: a literal `%` (Kalaallisut/Northern
                    // Sami allative/illative "%-mut" / "%-ii") must be `%%` or Foundation
                    // consumes it as a specifier (`%-i`).
                    let withoutIntegerPlaceholder = value.replacingOccurrences(of: "%lld", with: "")
                    var index = withoutIntegerPlaceholder.startIndex
                    while index < withoutIntegerPlaceholder.endIndex {
                        if withoutIntegerPlaceholder[index] == "%" {
                            let next = withoutIntegerPlaceholder.index(after: index)
                            XCTAssertTrue(
                                next < withoutIntegerPlaceholder.endIndex
                                    && withoutIntegerPlaceholder[next] == "%",
                                "\(key) \(language) \(category) has an unescaped %: \(value)"
                            )
                            if next < withoutIntegerPlaceholder.endIndex {
                                index = withoutIntegerPlaceholder.index(after: next)
                                continue
                            }
                        }
                        index = withoutIntegerPlaceholder.index(after: index)
                    }
                }
            }
        }
    }

    // MARK: - Compiled runtime (Foundation CLDR selection + golden strings)

    /// Sleep-timer VoiceOver values inflect for every UI language, including
    /// Slovak `few`, Northern Sami `two`, and Latvian `zero`.
    func testSleepTimerPluralizesEverySupportedLocale() {
        assertCases(sleepTimerCases, format: minutesRemaining)
    }

    /// Siri / Shortcuts language-count strings inflect for every UI language.
    func testLanguageCountPluralizesEverySupportedLocale() {
        assertCases(languageCountCases, format: languageCount)
    }

    /// Volume VoiceOver values inflect for every UI language.
    func testVolumePercentPluralizesEverySupportedLocale() {
        assertCases(volumePercentCases, format: volumePercent)
    }

    /// Volume-set confirmation strings inflect for every UI language.
    func testVolumeSetToPluralizesEverySupportedLocale() {
        assertCases(volumeSetToCases, format: volumeSetTo)
    }

    /// Runtime tables must execute every UI language and every integer-reachable
    /// CLDR slot. Prevents shrinking coverage back to a 10-locale subset.
    func testRuntimeProbesCoverEveryLocaleAndIntegerReachableCategory() {
        let tables: [(String, [PluralCase])] = [
            ("sleep_timer_accessibility_remaining", sleepTimerCases),
            ("%lld languages", languageCountCases),
            ("accessibility_value_volume", volumePercentCases),
            ("volume_set_to", volumeSetToCases),
        ]
        for (key, cases) in tables {
            let locales = Set(cases.map(\.locale))
            XCTAssertEqual(
                locales,
                Set(supportedLanguages),
                "\(key) runtime table skipped languages: \(Set(supportedLanguages).subtracting(locales).sorted())"
            )
            for language in supportedLanguages {
                let required = requiredCatalogCategories[language] ?? []
                var expected = required
                if decimalOnlyManyLocales.contains(language) {
                    expected.remove("many")
                }
                if decimalOnlyOtherLocales.contains(language) {
                    expected.remove("other")
                }
                let probed = Set(cases.filter { $0.locale == language }.map(\.category))
                XCTAssertEqual(
                    probed,
                    expected,
                    "\(key) \(language) probes \(probed.sorted()) != integer-reachable \(expected.sorted())"
                )
            }
        }
    }

    // MARK: - View-model rounding still feeds the catalog

    @MainActor
    func testSleepTimerAccessibilityValueIsNilWhenInactive() {
        let vm = PlayerViewModel.makeMock(sleepTimerRemaining: nil)
        XCTAssertNil(vm.sleepTimerAccessibilityValue)
    }

    @MainActor
    func testSleepTimerAccessibilityValueRoundsUpToAtLeastOneMinute() {
        let vm = PlayerViewModel.makeMock(sleepTimerRemaining: 30)
        let value = vm.sleepTimerAccessibilityValue
        XCTAssertNotNil(value)
        XCTAssertTrue(value?.contains("1") == true, "30s remaining must surface 1 minute; got \(value ?? "nil")")
    }

    // MARK: - Production lookup shape (must stay interpolation)

    private func minutesRemaining(_ count: Int, locale: String) -> String {
        formatCount(
            key: "sleep_timer_accessibility_remaining",
            count: count,
            language: locale
        )
    }

    private func languageCount(_ count: Int, locale: String) -> String {
        formatCount(key: "%lld languages", count: count, language: locale)
    }

    private func volumePercent(_ count: Int, locale: String) -> String {
        formatCount(key: "accessibility_value_volume", count: count, language: locale)
    }

    private func volumeSetTo(_ count: Int, locale: String) -> String {
        formatCount(key: "volume_set_to", count: count, language: locale)
    }

    /// Loads the compiled stringsdict format (`%#@value@`) from `language.lproj`
    /// and applies that locale's CLDR plural rules.
    ///
    /// Production uses `String(localized:defaultValue:)` interpolation (see
    /// `PlayerViewModel.sleepTimerAccessibilityValue`). That API follows the
    /// process preferred language; tests cannot switch it per assertion, so they
    /// go through the compiled stringsdict with an explicit `Locale`.
    private func formatCount(key: String, count: Int, language: String) -> String {
        let format = localizationBundle(language: language)
            .localizedString(forKey: key, value: "", table: "Localizable")
        // SAFETY: format is the trusted stringsdict template from our catalog;
        // the argument is a single Int. Tests inherit SWIFT_STRICT_MEMORY_SAFETY.
        return unsafe String(
            format: format,
            locale: Locale(identifier: cldrLocaleIdentifier(for: language)),
            count
        )
    }

    /// ICU locale whose cardinal rules select slots in `language.lproj`.
    ///
    /// Meänkieli (`fit`) has no ICU plural table; `Locale(identifier: "fit")`
    /// treats every integer as `other` ("1 kieltä"). Finnish `one`/`other` is
    /// the grammar those translations were written for. The bundle is still
    /// `fit.lproj`.
    ///
    /// - SeeAlso: README.md Localizations (Tornedalen Finnish).
    private func cldrLocaleIdentifier(for language: String) -> String {
        language == "fit" ? "fi" : language
    }

    private func localizationBundle(language: String) -> Bundle {
        guard let path = appBundle.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            XCTFail("App bundle is missing \(language).lproj")
            return appBundle
        }
        return bundle
    }

    private func loadLocalizableCatalog() throws -> [String: Any] {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let catalogURL = testsDir
            .deletingLastPathComponent()
            .appendingPathComponent("Lutheran Radio/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], "Localizable.xcstrings is not a dictionary")
    }

    private func assertCases(
        _ cases: [PluralCase],
        format: (Int, String) -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for testCase in cases {
            let actual = format(testCase.count, testCase.locale)
            XCTAssertEqual(
                actual,
                testCase.expected,
                "\(testCase.locale) count \(testCase.count) (\(testCase.category)): got \(actual.debugDescription)",
                file: file,
                line: line
            )
        }
    }

    /// Golden strings are independent of parsing the catalog at assertion time
    /// so a wrong Slovak `few` (or a `two` copied onto Northern Sami `other`) fails.
    private struct PluralCase {
        let locale: String
        let count: Int
        let category: String
        let expected: String

        init(_ locale: String, _ count: Int, _ category: String, _ expected: String) {
            self.locale = locale
            self.count = count
            self.category = category
            self.expected = expected
        }
    }

    private let sleepTimerCases: [PluralCase] = [
        .init("bg", 1, "one", "Остава 1 минута"),
        .init("bg", 2, "other", "Остават 2 минути"),
        .init("cs", 1, "one", "Zbývá 1 minuta"),
        .init("cs", 3, "few", "Zbývají 3 minuty"),
        .init("cs", 5, "other", "Zbývá 5 minut"),
        .init("da", 1, "one", "1 minut tilbage"),
        .init("da", 2, "other", "2 minutter tilbage"),
        .init("de", 1, "one", "Noch 1 Minute"),
        .init("de", 2, "other", "Noch 2 Minuten"),
        .init("el", 1, "one", "Απομένει 1 λεπτό"),
        .init("el", 2, "other", "Απομένουν 2 λεπτά"),
        .init("en", 1, "one", "1 minute remaining"),
        .init("en", 2, "other", "2 minutes remaining"),
        .init("en", 12, "other", "12 minutes remaining"),
        .init("es", 1, "one", "Queda 1 minuto"),
        .init("es", 2, "other", "Quedan 2 minutos"),
        .init("et", 1, "one", "1 minut jäänud"),
        .init("et", 2, "other", "2 minutit jäänud"),
        .init("fi", 1, "one", "1 minuutti jäljellä"),
        .init("fi", 2, "other", "2 minuuttia jäljellä"),
        .init("fit", 1, "one", "1 minuutti jäljellä"),
        .init("fit", 2, "other", "2 minuuttia jäljellä"),
        .init("fo", 1, "one", "1 minuttur eftir"),
        .init("fo", 2, "other", "2 minuttir eftir"),
        .init("fr", 1, "one", "1 minute restante"),
        .init("fr", 2, "other", "2 minutes restantes"),
        .init("fr", 12, "other", "12 minutes restantes"),
        .init("gag", 1, "one", "1 minut kaldı"),
        .init("gag", 2, "other", "2 minut kaldı"),
        .init("hr", 1, "one", "Još 1 minuta"),
        .init("hr", 2, "few", "Još 2 minute"),
        .init("hr", 5, "other", "Još 5 minuta"),
        .init("hr", 21, "one", "Još 21 minuta"),
        .init("hu", 1, "one", "1 perc van hátra"),
        .init("hu", 2, "other", "2 perc van hátra"),
        .init("is", 1, "one", "1 mínúta eftir"),
        .init("is", 2, "other", "2 mínútur eftir"),
        .init("is", 21, "one", "21 mínúta eftir"),
        .init("it", 1, "one", "1 minuto rimanente"),
        .init("it", 2, "other", "2 minuti rimanenti"),
        .init("it", 12, "other", "12 minuti rimanenti"),
        .init("kl", 1, "one", "1 minuti sinnerusoq"),
        .init("kl", 2, "other", "2 minutsit sinnerusoq"),
        .init("lt", 1, "one", "Liko 1 minutė"),
        .init("lt", 2, "few", "Liko 2 minutės"),
        .init("lt", 10, "other", "Liko 10 minučių"),
        .init("lv", 0, "zero", "Atlicis 0 minūšu"),
        .init("lv", 1, "one", "Atlikusi 1 minūte"),
        .init("lv", 2, "other", "Atlikušas 2 minūtes"),
        .init("lv", 10, "zero", "Atlicis 10 minūšu"),
        .init("nb", 1, "one", "1 minutt igjen"),
        .init("nb", 2, "other", "2 minutter igjen"),
        .init("nl", 1, "one", "Nog 1 minuut"),
        .init("nl", 2, "other", "Nog 2 minuten"),
        .init("nn", 1, "one", "1 minutt att"),
        .init("nn", 2, "other", "2 minutt att"),
        .init("pl", 1, "one", "Pozostała 1 minuta"),
        .init("pl", 2, "few", "Pozostały 2 minuty"),
        .init("pl", 5, "many", "Pozostało 5 minut"),
        .init("pl", 22, "few", "Pozostały 22 minuty"),
        .init("pt", 1, "one", "1 minuto restante"),
        .init("pt", 2, "other", "2 minutos restantes"),
        .init("pt", 12, "other", "12 minutos restantes"),
        .init("ro", 1, "one", "1 minut rămas"),
        .init("ro", 2, "few", "2 minute rămase"),
        .init("ro", 20, "other", "20 de minute rămase"),
        .init("ru", 1, "one", "Осталась 1 минута"),
        .init("ru", 2, "few", "Осталось 2 минуты"),
        .init("ru", 5, "many", "Осталось 5 минут"),
        .init("ru", 21, "one", "Осталась 21 минута"),
        .init("se", 1, "one", "1 minuhtta báhcán"),
        .init("se", 2, "two", "2 minuhta báhcán"),
        .init("se", 5, "other", "5 minuhtta báhcán"),
        .init("sk", 1, "one", "Zostáva 1 minúta"),
        .init("sk", 3, "few", "Zostávajú 3 minúty"),
        .init("sk", 5, "other", "Zostáva 5 minút"),
        .init("sl", 1, "one", "Še 1 minuta"),
        .init("sl", 2, "two", "Še 2 minuti"),
        .init("sl", 3, "few", "Še 3 minute"),
        .init("sl", 5, "other", "Še 5 minut"),
        .init("sq", 1, "one", "1 minutë e mbetur"),
        .init("sq", 2, "other", "2 minuta të mbetura"),
        .init("sv", 1, "one", "1 minut kvar"),
        .init("sv", 2, "other", "2 minuter kvar"),
    ]

    private let languageCountCases: [PluralCase] = [
        .init("bg", 1, "one", "1 език"),
        .init("bg", 2, "other", "2 езика"),
        .init("cs", 1, "one", "1 jazyk"),
        .init("cs", 3, "few", "3 jazyky"),
        .init("cs", 5, "other", "5 jazyků"),
        .init("da", 1, "one", "1 sprog"),
        .init("da", 2, "other", "2 sprog"),
        .init("de", 1, "one", "1 Sprache"),
        .init("de", 2, "other", "2 Sprachen"),
        .init("el", 1, "one", "1 γλώσσα"),
        .init("el", 2, "other", "2 γλώσσες"),
        .init("en", 1, "one", "1 language"),
        .init("en", 2, "other", "2 languages"),
        .init("en", 12, "other", "12 languages"),
        .init("es", 1, "one", "1 idioma"),
        .init("es", 2, "other", "2 idiomas"),
        .init("et", 1, "one", "1 keel"),
        .init("et", 2, "other", "2 keelt"),
        .init("fi", 1, "one", "1 kieli"),
        .init("fi", 2, "other", "2 kieltä"),
        .init("fit", 1, "one", "1 kieli"),
        .init("fit", 2, "other", "2 kieltä"),
        .init("fo", 1, "one", "1 mál"),
        .init("fo", 2, "other", "2 mál"),
        .init("fr", 1, "one", "1 langue"),
        .init("fr", 2, "other", "2 langues"),
        .init("fr", 12, "other", "12 langues"),
        .init("gag", 1, "one", "1 dil"),
        .init("gag", 2, "other", "2 dil"),
        .init("hr", 1, "one", "1 jezik"),
        .init("hr", 2, "few", "2 jezika"),
        .init("hr", 5, "other", "5 jezika"),
        .init("hr", 21, "one", "21 jezik"),
        .init("hu", 1, "one", "1 nyelv"),
        .init("hu", 2, "other", "2 nyelv"),
        .init("is", 1, "one", "1 tungumál"),
        .init("is", 2, "other", "2 tungumál"),
        .init("is", 21, "one", "21 tungumál"),
        .init("it", 1, "one", "1 lingua"),
        .init("it", 2, "other", "2 lingue"),
        .init("it", 12, "other", "12 lingue"),
        .init("kl", 1, "one", "1 oqaaseq"),
        .init("kl", 2, "other", "2 oqaatsit"),
        .init("lt", 1, "one", "1 kalba"),
        .init("lt", 2, "few", "2 kalbos"),
        .init("lt", 10, "other", "10 kalbų"),
        .init("lv", 0, "zero", "0 valodu"),
        .init("lv", 1, "one", "1 valoda"),
        .init("lv", 2, "other", "2 valodas"),
        .init("lv", 10, "zero", "10 valodu"),
        .init("nb", 1, "one", "1 språk"),
        .init("nb", 2, "other", "2 språk"),
        .init("nl", 1, "one", "1 taal"),
        .init("nl", 2, "other", "2 talen"),
        .init("nn", 1, "one", "1 språk"),
        .init("nn", 2, "other", "2 språk"),
        .init("pl", 1, "one", "1 język"),
        .init("pl", 2, "few", "2 języki"),
        .init("pl", 5, "many", "5 języków"),
        .init("pl", 22, "few", "22 języki"),
        .init("pt", 1, "one", "1 língua"),
        .init("pt", 2, "other", "2 línguas"),
        .init("pt", 12, "other", "12 línguas"),
        .init("ro", 1, "one", "1 limbă"),
        .init("ro", 2, "few", "2 limbi"),
        .init("ro", 20, "other", "20 de limbi"),
        .init("ru", 1, "one", "1 язык"),
        .init("ru", 2, "few", "2 языка"),
        .init("ru", 5, "many", "5 языков"),
        .init("ru", 21, "one", "21 язык"),
        .init("se", 1, "one", "1 giella"),
        .init("se", 2, "two", "2 giela"),
        .init("se", 5, "other", "5 giela"),
        .init("sk", 1, "one", "1 jazyk"),
        .init("sk", 3, "few", "3 jazyky"),
        .init("sk", 5, "other", "5 jazykov"),
        .init("sl", 1, "one", "1 jezik"),
        .init("sl", 2, "two", "2 jezika"),
        .init("sl", 3, "few", "3 jeziki"),
        .init("sl", 5, "other", "5 jezikov"),
        .init("sq", 1, "one", "1 gjuhë"),
        .init("sq", 2, "other", "2 gjuhë"),
        .init("sv", 1, "one", "1 språk"),
        .init("sv", 2, "other", "2 språk"),
    ]

    private let volumePercentCases: [PluralCase] = [
        .init("bg", 1, "one", "1 процент"),
        .init("bg", 2, "other", "2 процента"),
        .init("cs", 1, "one", "1 procento"),
        .init("cs", 3, "few", "3 procenta"),
        .init("cs", 5, "other", "5 procent"),
        .init("da", 1, "one", "1 procent"),
        .init("da", 2, "other", "2 procent"),
        .init("de", 1, "one", "1 Prozent"),
        .init("de", 2, "other", "2 Prozent"),
        .init("el", 1, "one", "1 τοις εκατό"),
        .init("el", 2, "other", "2 τοις εκατό"),
        .init("en", 1, "one", "1 percent"),
        .init("en", 2, "other", "2 percent"),
        .init("en", 12, "other", "12 percent"),
        .init("es", 1, "one", "1 por ciento"),
        .init("es", 2, "other", "2 por ciento"),
        .init("et", 1, "one", "1 protsent"),
        .init("et", 2, "other", "2 protsenti"),
        .init("fi", 1, "one", "1 prosentti"),
        .init("fi", 2, "other", "2 prosenttia"),
        .init("fit", 1, "one", "1 prosentti"),
        .init("fit", 2, "other", "2 prosenttia"),
        .init("fo", 1, "one", "1 prosent"),
        .init("fo", 2, "other", "2 prosent"),
        .init("fr", 1, "one", "1 pour cent"),
        .init("fr", 2, "other", "2 pour cent"),
        .init("fr", 12, "other", "12 pour cent"),
        .init("gag", 1, "one", "1 proţent"),
        .init("gag", 2, "other", "2 proţent"),
        .init("hr", 1, "one", "1 posto"),
        .init("hr", 2, "few", "2 posto"),
        .init("hr", 5, "other", "5 posto"),
        .init("hr", 21, "one", "21 posto"),
        .init("hu", 1, "one", "1 százalék"),
        .init("hu", 2, "other", "2 százalék"),
        .init("is", 1, "one", "1 prósent"),
        .init("is", 2, "other", "2 prósent"),
        .init("is", 21, "one", "21 prósent"),
        .init("it", 1, "one", "1 percento"),
        .init("it", 2, "other", "2 percento"),
        .init("it", 12, "other", "12 percento"),
        .init("kl", 1, "one", "1 pisumi"),
        .init("kl", 2, "other", "2 pisumi"),
        .init("lt", 1, "one", "1 procentas"),
        .init("lt", 2, "few", "2 procentai"),
        .init("lt", 10, "other", "10 procentų"),
        .init("lv", 0, "zero", "0 procentu"),
        .init("lv", 1, "one", "1 procents"),
        .init("lv", 2, "other", "2 procenti"),
        .init("lv", 10, "zero", "10 procentu"),
        .init("nb", 1, "one", "1 prosent"),
        .init("nb", 2, "other", "2 prosent"),
        .init("nl", 1, "one", "1 procent"),
        .init("nl", 2, "other", "2 procent"),
        .init("nn", 1, "one", "1 prosent"),
        .init("nn", 2, "other", "2 prosent"),
        .init("pl", 1, "one", "1 procent"),
        .init("pl", 2, "few", "2 procenty"),
        .init("pl", 5, "many", "5 procentów"),
        .init("pl", 22, "few", "22 procenty"),
        .init("pt", 1, "one", "1 por cento"),
        .init("pt", 2, "other", "2 por cento"),
        .init("pt", 12, "other", "12 por cento"),
        .init("ro", 1, "one", "1 la sută"),
        .init("ro", 2, "few", "2 la sută"),
        .init("ro", 20, "other", "20 la sută"),
        .init("ru", 1, "one", "1 процент"),
        .init("ru", 2, "few", "2 процента"),
        .init("ru", 5, "many", "5 процентов"),
        .init("ru", 21, "one", "21 процент"),
        .init("se", 1, "one", "1 proseanta"),
        .init("se", 2, "two", "2 proseantta"),
        .init("se", 5, "other", "5 proseantta"),
        .init("sk", 1, "one", "1 percento"),
        .init("sk", 3, "few", "3 percentá"),
        .init("sk", 5, "other", "5 percent"),
        .init("sl", 1, "one", "1 odstotek"),
        .init("sl", 2, "two", "2 odstotka"),
        .init("sl", 3, "few", "3 odstotki"),
        .init("sl", 5, "other", "5 odstotkov"),
        .init("sq", 1, "one", "1 për qind"),
        .init("sq", 2, "other", "2 për qind"),
        .init("sv", 1, "one", "1 procent"),
        .init("sv", 2, "other", "2 procent"),
    ]

    private let volumeSetToCases: [PluralCase] = [
        .init("bg", 1, "one", "Силата на звука е зададена на 1 процент"),
        .init("bg", 2, "other", "Силата на звука е зададена на 2 процента"),
        .init("cs", 1, "one", "Hlasitost nastavena na 1 procento"),
        .init("cs", 3, "few", "Hlasitost nastavena na 3 procenta"),
        .init("cs", 5, "other", "Hlasitost nastavena na 5 procent"),
        .init("da", 1, "one", "Lydstyrke sat til 1 procent"),
        .init("da", 2, "other", "Lydstyrke sat til 2 procent"),
        .init("de", 1, "one", "Lautstärke auf 1 Prozent eingestellt"),
        .init("de", 2, "other", "Lautstärke auf 2 Prozent eingestellt"),
        .init("el", 1, "one", "Η ένταση ορίστηκε στο 1 τοις εκατό"),
        .init("el", 2, "other", "Η ένταση ορίστηκε στο 2 τοις εκατό"),
        .init("en", 1, "one", "Volume set to 1 percent"),
        .init("en", 2, "other", "Volume set to 2 percent"),
        .init("en", 12, "other", "Volume set to 12 percent"),
        .init("es", 1, "one", "Volumen ajustado al 1 por ciento"),
        .init("es", 2, "other", "Volumen ajustado al 2 por ciento"),
        .init("et", 1, "one", "Helitugevus seatud 1 protsendile"),
        .init("et", 2, "other", "Helitugevus seatud 2 protsendile"),
        .init("fi", 1, "one", "Äänenvoimakkuus asetettu 1 prosenttiin"),
        .init("fi", 2, "other", "Äänenvoimakkuus asetettu 2 prosenttiin"),
        .init("fit", 1, "one", "Äänenvoimakkuus asetettu 1 prosenttiin"),
        .init("fit", 2, "other", "Äänenvoimakkuus asetettu 2 prosenttiin"),
        .init("fo", 1, "one", "Ljóðstyrki stillaður til 1 prosent"),
        .init("fo", 2, "other", "Ljóðstyrki stillaður til 2 prosent"),
        .init("fr", 1, "one", "Volume réglé sur 1 pour cent"),
        .init("fr", 2, "other", "Volume réglé sur 2 pour cent"),
        .init("fr", 12, "other", "Volume réglé sur 12 pour cent"),
        .init("gag", 1, "one", "Ses 1 proţentä ayarlandı"),
        .init("gag", 2, "other", "Ses 2 proţentä ayarlandı"),
        .init("hr", 1, "one", "Glasnoća postavljena na 1 posto"),
        .init("hr", 2, "few", "Glasnoća postavljena na 2 posto"),
        .init("hr", 5, "other", "Glasnoća postavljena na 5 posto"),
        .init("hr", 21, "one", "Glasnoća postavljena na 21 posto"),
        .init("hu", 1, "one", "Hangerő 1 százalékra állítva"),
        .init("hu", 2, "other", "Hangerő 2 százalékra állítva"),
        .init("is", 1, "one", "Hljóðstyrkur stilltur á 1 prósent"),
        .init("is", 2, "other", "Hljóðstyrkur stilltur á 2 prósent"),
        .init("is", 21, "one", "Hljóðstyrkur stilltur á 21 prósent"),
        .init("it", 1, "one", "Volume impostato al 1 percento"),
        .init("it", 2, "other", "Volume impostato al 2 percento"),
        .init("it", 12, "other", "Volume impostato al 12 percento"),
        .init("kl", 1, "one", "Hørigutit 1 %-mut settet"),
        .init("kl", 2, "other", "Hørigutit 2 %-mut settet"),
        .init("lt", 1, "one", "Garsumas nustatytas 1 procento"),
        .init("lt", 2, "few", "Garsumas nustatytas 2 procentų"),
        .init("lt", 10, "other", "Garsumas nustatytas 10 procentų"),
        .init("lv", 0, "zero", "Skaļums iestatīts uz 0 procentiem"),
        .init("lv", 1, "one", "Skaļums iestatīts uz 1 procentu"),
        .init("lv", 2, "other", "Skaļums iestatīts uz 2 procentiem"),
        .init("lv", 10, "zero", "Skaļums iestatīts uz 10 procentiem"),
        .init("nb", 1, "one", "Volum satt til 1 prosent"),
        .init("nb", 2, "other", "Volum satt til 2 prosent"),
        .init("nl", 1, "one", "Volume ingesteld op 1 procent"),
        .init("nl", 2, "other", "Volume ingesteld op 2 procent"),
        .init("nn", 1, "one", "Volum sett til 1 prosent"),
        .init("nn", 2, "other", "Volum sett til 2 prosent"),
        .init("pl", 1, "one", "Głośność ustawiona na 1 procent"),
        .init("pl", 2, "few", "Głośność ustawiona na 2 procenty"),
        .init("pl", 5, "many", "Głośność ustawiona na 5 procentów"),
        .init("pl", 22, "few", "Głośność ustawiona na 22 procenty"),
        .init("pt", 1, "one", "Volume definido para 1 por cento"),
        .init("pt", 2, "other", "Volume definido para 2 por cento"),
        .init("pt", 12, "other", "Volume definido para 12 por cento"),
        .init("ro", 1, "one", "Volum setat la 1 la sută"),
        .init("ro", 2, "few", "Volum setat la 2 la sută"),
        .init("ro", 20, "other", "Volum setat la 20 la sută"),
        .init("ru", 1, "one", "Громкость установлена на 1 процент"),
        .init("ru", 2, "few", "Громкость установлена на 2 процента"),
        .init("ru", 5, "many", "Громкость установлена на 5 процентов"),
        .init("ru", 21, "one", "Громкость установлена на 21 процент"),
        .init("se", 1, "one", "Hárdu lea settet 1 %-ii"),
        .init("se", 2, "two", "Hárdu lea settet 2 %-ii"),
        .init("se", 5, "other", "Hárdu lea settet 5 %-ii"),
        .init("sk", 1, "one", "Hlasitosť nastavená na 1 percento"),
        .init("sk", 3, "few", "Hlasitosť nastavená na 3 percentá"),
        .init("sk", 5, "other", "Hlasitosť nastavená na 5 percent"),
        .init("sl", 1, "one", "Glasnost nastavljena na 1 odstotek"),
        .init("sl", 2, "two", "Glasnost nastavljena na 2 odstotka"),
        .init("sl", 3, "few", "Glasnost nastavljena na 3 odstotke"),
        .init("sl", 5, "other", "Glasnost nastavljena na 5 odstotkov"),
        .init("sq", 1, "one", "Volumi u vendos në 1 për qind"),
        .init("sq", 2, "other", "Volumi u vendos në 2 për qind"),
        .init("sv", 1, "one", "Volym inställd på 1 procent"),
        .init("sv", 2, "other", "Volym inställd på 2 procent"),
    ]
}
