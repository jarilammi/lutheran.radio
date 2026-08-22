//
//  PlaybackKeyboardMenuTests.swift
//  Lutheran RadioTests
//
//  Protects keyboard / menu playback verbs: wrapping adjacent-stream index math,
//  Localizable titles for every UI language, and AppDelegate selectors that
//  forward to ``handleTogglePlayback()`` / ``handleAdjacentLanguageSelection(offset:)``
//  (existing play and switch SSOTs — not a new play entry).
//
//  Does not exercise audio session, volume, ActivityKit, or WidgetCenter.
//
//  - SeeAlso: ``PlaybackKeyboardMenu``, ``AppDelegate/buildMenu(with:)``,
//    ``RadioPlayerCoordinator/handleAdjacentLanguageSelection(offset:)``,
//    ``SharedPlayerManager/userRequestedPlay()``, ``SharedPlayerManager/stop()``,
//    README.md (iOS App Store binary on Apple Silicon), CODING_AGENT.md.
//
//  Created by Jari Lammi on 15.8.2026.
//

import XCTest
@testable import Lutheran_Radio

final class PlaybackKeyboardMenuTests: XCTestCase {

    /// UI catalog languages: README Localizations / Localizable coverage (29 stream
    /// codes plus French and Italian). Portuguese remains in `knownRegions` only.
    private let supportedLanguages: [String] = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fit",
        "fo", "fr", "gag", "hr", "hu", "is", "it", "kl", "lt", "lv", "nb", "nl",
        "nn", "pl", "ro", "ru", "se", "sk", "sl", "sq", "sv",
    ]

    private let menuKeys: [String] = [
        "menu_playback",
        "menu_play_pause",
        "menu_previous_language",
        "menu_next_language",
    ]

    // MARK: - Adjacent index wrap

    /// Catalog wrap: next from the last stream is the first; previous from the first is the last.
    ///
    /// Invariant: ``handleAdjacentLanguageSelection(offset:)`` must land on a valid
    /// ``DirectStreamingPlayer/availableStreams`` index without inventing a sixth stream.
    func testAdjacentStreamIndexWrapsTheFiveStreamCatalog() {
        let count = 5
        XCTAssertEqual(PlaybackKeyboardMenu.adjacentStreamIndex(current: 0, offset: 1, count: count), 1)
        XCTAssertEqual(PlaybackKeyboardMenu.adjacentStreamIndex(current: 4, offset: 1, count: count), 0)
        XCTAssertEqual(PlaybackKeyboardMenu.adjacentStreamIndex(current: 0, offset: -1, count: count), 4)
        XCTAssertEqual(PlaybackKeyboardMenu.adjacentStreamIndex(current: 2, offset: -1, count: count), 1)
        XCTAssertEqual(PlaybackKeyboardMenu.adjacentStreamIndex(current: 2, offset: 0, count: count), 2)
    }

    /// Empty catalog returns nil so the coordinator no-ops instead of trapping.
    func testAdjacentStreamIndexReturnsNilWhenCatalogIsEmpty() {
        XCTAssertNil(PlaybackKeyboardMenu.adjacentStreamIndex(current: 0, offset: 1, count: 0))
        XCTAssertNil(PlaybackKeyboardMenu.adjacentStreamIndex(current: -1, offset: 1, count: 0))
    }

    /// Out-of-range current is normalized before applying offset (stale index after a catalog edit).
    func testAdjacentStreamIndexNormalizesOutOfRangeCurrent() {
        XCTAssertEqual(PlaybackKeyboardMenu.adjacentStreamIndex(current: 7, offset: 1, count: 5), 3)
        XCTAssertEqual(PlaybackKeyboardMenu.adjacentStreamIndex(current: -1, offset: 0, count: 5), 4)
    }

    // MARK: - Menu actions stay on existing SSOTs

    /// AppDelegate exposes the three menu selectors that forward to VC shims
    /// (toggle → ``userRequestedPlay()`` / ``stop()``; adjacent → ``handleLanguageSelection``).
    func testAppDelegateRespondsToPlaybackMenuSelectors() {
        XCTAssertTrue(AppDelegate.instancesRespond(to: #selector(AppDelegate.menuTogglePlayback(_:))))
        XCTAssertTrue(AppDelegate.instancesRespond(to: #selector(AppDelegate.menuPreviousLanguage(_:))))
        XCTAssertTrue(AppDelegate.instancesRespond(to: #selector(AppDelegate.menuNextLanguage(_:))))
    }

    func testEnglishMenuTitlesAreNonEmpty() {
        XCTAssertFalse(PlaybackKeyboardMenu.playbackMenuTitle.isEmpty)
        XCTAssertFalse(PlaybackKeyboardMenu.playPauseTitle.isEmpty)
        XCTAssertFalse(PlaybackKeyboardMenu.previousLanguageTitle.isEmpty)
        XCTAssertFalse(PlaybackKeyboardMenu.nextLanguageTitle.isEmpty)
    }

    // MARK: - Localizable catalog completeness

    /// Every menu title key ships a translated value for every UI catalog language.
    func testLocalizableCatalogCoversEveryMenuKeyAndLanguage() throws {
        let catalog = try loadLocalizableCatalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        for key in menuKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing Localizable key \(key)")
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
            }
        }
    }

    // MARK: - Helpers

    private func loadLocalizableCatalog() throws -> [String: Any] {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let catalogURL = testsDir
            .deletingLastPathComponent()
            .appendingPathComponent("Lutheran Radio/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], "Localizable.xcstrings is not a dictionary")
    }
}
