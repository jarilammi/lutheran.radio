//
//  CellularPermissionManagerTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 24.7.2026.
//
//  Protects the cellular data preference SSOT: durable writes use only
//  `cellularDataPermission` (ask / alwaysAllow / sessionAllow). The pre-ternary
//  `hasDismissedDataUsageNotification` bool is migration-read only when ternary is
//  absent, is never dual-written by `setAlwaysAllow()`, and is removed after a
//  successful ternary load or migration.
//
//  - SeeAlso: `CellularPermissionManager`, ViewController expensive-path prompt host.
//

import XCTest
@testable import Lutheran_Radio

/// Ternary cellular preference + one-way legacy migration contracts.
///
/// Uses `UserDefaults.standard` with save/restore of the two production keys so
/// suite isolation does not depend on injecting a suite into the manager.
@MainActor
final class CellularPermissionManagerTests: XCTestCase {

    /// Production key strings (must match `CellularPermissionManager` private keys).
    private enum Keys {
        static let ternary = "cellularDataPermission"
        static let legacyDismissed = "hasDismissedDataUsageNotification"
    }

    private var savedTernary: Any?
    private var savedLegacy: Any?
    private var hadTernary = false
    private var hadLegacy = false

    override func setUp() async throws {
        try await super.setUp()
        let ud = UserDefaults.standard
        hadTernary = ud.object(forKey: Keys.ternary) != nil
        hadLegacy = ud.object(forKey: Keys.legacyDismissed) != nil
        savedTernary = ud.object(forKey: Keys.ternary)
        savedLegacy = ud.object(forKey: Keys.legacyDismissed)
        clearBothKeys()
    }

    override func tearDown() async throws {
        let ud = UserDefaults.standard
        clearBothKeys()
        if hadTernary {
            ud.set(savedTernary, forKey: Keys.ternary)
        }
        if hadLegacy {
            ud.set(savedLegacy, forKey: Keys.legacyDismissed)
        }
        try await super.tearDown()
    }

    private func clearBothKeys() {
        let ud = UserDefaults.standard
        ud.removeObject(forKey: Keys.ternary)
        ud.removeObject(forKey: Keys.legacyDismissed)
    }

    // MARK: - Migration (legacy read only when ternary absent)

    /// Pre-ternary "Don't show again" installs seed `.alwaysAllow`, write ternary, remove legacy.
    func testLegacyDismissedTrueMigratesToAlwaysAllowAndRemovesLegacy() {
        let ud = UserDefaults.standard
        ud.set(true, forKey: Keys.legacyDismissed)

        let manager = CellularPermissionManager()

        XCTAssertEqual(manager.currentPermission, .alwaysAllow)
        XCTAssertEqual(ud.string(forKey: Keys.ternary), "alwaysAllow")
        XCTAssertNil(ud.object(forKey: Keys.legacyDismissed),
                     "Legacy dismissed flag must be removed after successful migration")
    }

    /// Absent ternary + legacy false/absent defaults to `.ask` without inventing keys.
    func testNoTernaryAndNoLegacyDefaultsToAsk() {
        let manager = CellularPermissionManager()

        XCTAssertEqual(manager.currentPermission, .ask)
        XCTAssertNil(UserDefaults.standard.object(forKey: Keys.ternary))
        XCTAssertNil(UserDefaults.standard.object(forKey: Keys.legacyDismissed))
    }

    /// Ternary wins over a leftover dual-written legacy bool; legacy is cleaned up.
    func testTernaryAlwaysAllowWinsAndStripsLegacyResidue() {
        let ud = UserDefaults.standard
        ud.set("alwaysAllow", forKey: Keys.ternary)
        ud.set(true, forKey: Keys.legacyDismissed)

        let manager = CellularPermissionManager()

        XCTAssertEqual(manager.currentPermission, .alwaysAllow)
        XCTAssertEqual(ud.string(forKey: Keys.ternary), "alwaysAllow")
        XCTAssertNil(ud.object(forKey: Keys.legacyDismissed),
                     "Dual-written legacy residue must be removed once ternary is loaded")
    }

    /// Ternary `.ask` is authoritative even if legacy true remains (edge dual-write residue).
    func testTernaryAskWinsOverLegacyTrue() {
        let ud = UserDefaults.standard
        ud.set("ask", forKey: Keys.ternary)
        ud.set(true, forKey: Keys.legacyDismissed)

        let manager = CellularPermissionManager()

        XCTAssertEqual(manager.currentPermission, .ask)
        XCTAssertNil(ud.object(forKey: Keys.legacyDismissed))
    }

    // MARK: - Durable write path is ternary only

    /// `setAlwaysAllow()` must not dual-write the pre-ternary bool.
    func testSetAlwaysAllowWritesTernaryOnlyAndDoesNotCreateLegacy() {
        let ud = UserDefaults.standard
        let manager = CellularPermissionManager()

        manager.setAlwaysAllow()

        XCTAssertEqual(manager.currentPermission, .alwaysAllow)
        XCTAssertEqual(ud.string(forKey: Keys.ternary), "alwaysAllow")
        XCTAssertNil(ud.object(forKey: Keys.legacyDismissed),
                     "setAlwaysAllow must not dual-write hasDismissedDataUsageNotification")
    }

    /// If legacy is still present when the user chooses Always Allow, remove it.
    func testSetAlwaysAllowRemovesExistingLegacyFlag() {
        let ud = UserDefaults.standard
        ud.set(true, forKey: Keys.legacyDismissed)
        // Seed ternary so init does not migrate/remove before setAlwaysAllow.
        ud.set("ask", forKey: Keys.ternary)

        let manager = CellularPermissionManager()
        XCTAssertEqual(manager.currentPermission, .ask)
        // Init already strips legacy when ternary loads; re-seed to prove setAlwaysAllow cleans.
        ud.set(true, forKey: Keys.legacyDismissed)

        manager.setAlwaysAllow()

        XCTAssertEqual(ud.string(forKey: Keys.ternary), "alwaysAllow")
        XCTAssertNil(ud.object(forKey: Keys.legacyDismissed))
    }

    func testSetSessionAllowAndSetAskDoNotTouchLegacy() {
        let ud = UserDefaults.standard
        let manager = CellularPermissionManager()

        manager.setSessionAllow()
        XCTAssertEqual(manager.currentPermission, .sessionAllow)
        XCTAssertEqual(ud.string(forKey: Keys.ternary), "sessionAllow")
        XCTAssertNil(ud.object(forKey: Keys.legacyDismissed))

        manager.setAsk()
        XCTAssertEqual(manager.currentPermission, .ask)
        XCTAssertEqual(ud.string(forKey: Keys.ternary), "ask")
        XCTAssertNil(ud.object(forKey: Keys.legacyDismissed))
    }

    // MARK: - Prompt decision (sanity; unchanged semantics)

    func testAlwaysAllowNeverShowsPrompt() {
        UserDefaults.standard.set("alwaysAllow", forKey: Keys.ternary)
        let manager = CellularPermissionManager()

        XCTAssertFalse(manager.shouldShowPrompt(isConnected: true, isExpensive: true))
    }

    func testAskShowsPromptOncePerLaunchOnExpensivePath() {
        UserDefaults.standard.set("ask", forKey: Keys.ternary)
        let manager = CellularPermissionManager()

        XCTAssertTrue(manager.shouldShowPrompt(isConnected: true, isExpensive: true))
        manager.markPromptedThisLaunch()
        XCTAssertFalse(manager.shouldShowPrompt(isConnected: true, isExpensive: true))
    }
}
