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
    /// - `locale` — which CLDR plural rules pick `one`/`few`/`many`/`two`/`other`.
    /// A Finnish simulator with only `locale: "pl"` still loads Finnish strings;
    /// a Polish `.lproj` without `locale: "pl"` still applies Finnish one/other rules.
    private let appBundle = Bundle(for: PlayerViewModel.self)

    // MARK: - sleep_timer_accessibility_remaining

    func testEnglishSleepTimerUsesSingularAndPlural() {
        XCTAssertEqual(minutesRemaining(1, locale: "en"), "1 minute remaining")
        XCTAssertEqual(minutesRemaining(2, locale: "en"), "2 minutes remaining")
        XCTAssertEqual(minutesRemaining(12, locale: "en"), "12 minutes remaining")
    }

    func testPolishSleepTimerUsesOneFewMany() {
        XCTAssertEqual(minutesRemaining(1, locale: "pl"), "Pozostała 1 minuta")
        XCTAssertEqual(minutesRemaining(2, locale: "pl"), "Pozostały 2 minuty")
        XCTAssertEqual(minutesRemaining(5, locale: "pl"), "Pozostało 5 minut")
        XCTAssertEqual(minutesRemaining(22, locale: "pl"), "Pozostały 22 minuty")
    }

    func testCroatianSleepTimerUsesOneFewOther() {
        XCTAssertEqual(minutesRemaining(1, locale: "hr"), "Još 1 minuta")
        XCTAssertEqual(minutesRemaining(2, locale: "hr"), "Još 2 minute")
        XCTAssertEqual(minutesRemaining(5, locale: "hr"), "Još 5 minuta")
        XCTAssertEqual(minutesRemaining(21, locale: "hr"), "Još 21 minuta")
    }

    func testRussianSleepTimerUsesOneFewMany() {
        XCTAssertEqual(minutesRemaining(1, locale: "ru"), "Осталась 1 минута")
        XCTAssertEqual(minutesRemaining(2, locale: "ru"), "Осталось 2 минуты")
        XCTAssertEqual(minutesRemaining(5, locale: "ru"), "Осталось 5 минут")
        XCTAssertEqual(minutesRemaining(21, locale: "ru"), "Осталась 21 минута")
    }

    func testLithuanianSleepTimerUsesOneFewAndOther() {
        // Lithuanian `many` is decimals only; 10 is `other` (genitive plural).
        XCTAssertEqual(minutesRemaining(1, locale: "lt"), "Liko 1 minutė")
        XCTAssertEqual(minutesRemaining(2, locale: "lt"), "Liko 2 minutės")
        XCTAssertEqual(minutesRemaining(10, locale: "lt"), "Liko 10 minučių")
    }

    func testCzechSleepTimerUsesOneFewOther() {
        XCTAssertEqual(minutesRemaining(1, locale: "cs"), "Zbývá 1 minuta")
        XCTAssertEqual(minutesRemaining(3, locale: "cs"), "Zbývají 3 minuty")
        XCTAssertEqual(minutesRemaining(5, locale: "cs"), "Zbývá 5 minut")
    }

    func testFrenchSleepTimerUsesSingularAndPlural() {
        XCTAssertEqual(minutesRemaining(1, locale: "fr"), "1 minute restante")
        XCTAssertEqual(minutesRemaining(2, locale: "fr"), "2 minutes restantes")
        XCTAssertEqual(minutesRemaining(12, locale: "fr"), "12 minutes restantes")
    }

    // MARK: - %lld languages

    func testEnglishLanguageCountUsesSingularAndPlural() {
        XCTAssertEqual(languageCount(1, locale: "en"), "1 language")
        XCTAssertEqual(languageCount(5, locale: "en"), "5 languages")
    }

    func testFrenchLanguageCountUsesSingularAndPlural() {
        XCTAssertEqual(languageCount(1, locale: "fr"), "1 langue")
        XCTAssertEqual(languageCount(5, locale: "fr"), "5 langues")
    }

    func testPolishLanguageCountUsesOneFewMany() {
        XCTAssertEqual(languageCount(1, locale: "pl"), "1 język")
        XCTAssertEqual(languageCount(2, locale: "pl"), "2 języki")
        XCTAssertEqual(languageCount(5, locale: "pl"), "5 języków")
        XCTAssertEqual(languageCount(22, locale: "pl"), "22 języki")
    }

    func testRussianLanguageCountUsesOneFewMany() {
        XCTAssertEqual(languageCount(1, locale: "ru"), "1 язык")
        XCTAssertEqual(languageCount(3, locale: "ru"), "3 языка")
        XCTAssertEqual(languageCount(5, locale: "ru"), "5 языков")
    }

    func testSlovenianLanguageCountUsesOneTwoFewOther() {
        XCTAssertEqual(languageCount(1, locale: "sl"), "1 jezik")
        XCTAssertEqual(languageCount(2, locale: "sl"), "2 jezika")
        XCTAssertEqual(languageCount(3, locale: "sl"), "3 jeziki")
        XCTAssertEqual(languageCount(5, locale: "sl"), "5 jezikov")
    }

    // MARK: - accessibility_value_volume / volume_set_to

    func testPolishVolumePercentUsesOneFewMany() {
        XCTAssertEqual(volumePercent(1, locale: "pl"), "1 procent")
        XCTAssertEqual(volumePercent(2, locale: "pl"), "2 procenty")
        XCTAssertEqual(volumePercent(5, locale: "pl"), "5 procentów")
    }

    func testRussianVolumeSetToUsesOneFewMany() {
        XCTAssertEqual(volumeSetTo(1, locale: "ru"), "Громкость установлена на 1 процент")
        XCTAssertEqual(volumeSetTo(2, locale: "ru"), "Громкость установлена на 2 процента")
        XCTAssertEqual(volumeSetTo(5, locale: "ru"), "Громкость установлена на 5 процентов")
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
        return unsafe String(format: format, locale: Locale(identifier: language), count)
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
}
