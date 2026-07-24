//
//  CellularPermissionManager.swift
//  Lutheran Radio
//
//  Extracted manager for cellular / metered data usage permission state, persistence,
//  one-way migration from the pre-ternary boolean, per-launch prompting discipline, and
//  the 3-choice decision logic.
//
//  Ownership: main-app UI surface only (ViewController hosts the alert). No App Group,
//  security, streaming, or URL logic.
//
//  Durable preference SSOT: UserDefaults.standard key `cellularDataPermission`
//  (`ask` / `alwaysAllow` / `sessionAllow`). The legacy key
//  `hasDismissedDataUsageNotification` is migration-read only (when the ternary key is
//  absent); it is never dual-written and is removed after a successful ternary load or
//  migration so residual dual-written installs clean up on next launch.
//
//  Created by Jari Lammi on 15.6.2025.
//

import Foundation

/// Owns all state, persistence, migration, and decision logic for the smarter cellular data usage prompt.
///
/// - The 3 persistent choices reduce alert fatigue vs the prior once-per-launch boolean.
/// - "Not Now" choice causes stopPlayback() (routed by caller through SharedPlayerManager SSOT).
/// - Per-launch flags (session allow + prompted guard) are reset at cold launch.
/// - Migration: when `cellularDataPermission` is absent and
///   `hasDismissedDataUsageNotification == true`, seeds `.alwaysAllow` (one way), writes the
///   ternary key, then removes the legacy key.
/// - Durable writes always target the ternary key only — never re-write the legacy bool.
/// - No security, streaming, or URL logic here. UI presentation of the alert remains in the ViewController
///   network host surface (per decomposition guardrails).
///
/// - Important: Do not reintroduce dual-writes of `hasDismissedDataUsageNotification`. Keep the
///   migration **read** as a cheap one-way path for older App Store install bases that still
///   only have the boolean.
/// - SeeAlso: ViewController network / expensive-path prompt presentation;
///   `CODING_AGENT.md` (canonical citations — use production key/method names only).
@MainActor
final class CellularPermissionManager {

    // MARK: - Permission States (public for any future settings surface)

    /// Ternary cellular data preference stored under `cellularDataPermission`.
    enum CellularDataPermission: String {
        case ask
        case alwaysAllow
        case sessionAllow
    }

    // MARK: - Private Keys

    /// `UserDefaults.standard` keys. Ternary is the only durable write target; legacy is
    /// migration-read only and removed after successful ternary load or migration.
    private enum UserDefaultsKeys {
        static let cellularDataPermission = "cellularDataPermission"
        /// Pre-ternary "Don't show again" flag. Read only when ternary is absent; never dual-written.
        static let hasDismissedDataUsageNotification = "hasDismissedDataUsageNotification"
    }

    // MARK: - Observable State (read-only to callers; mutated only via the explicit setters + reset)

    private(set) var currentPermission: CellularDataPermission = .ask
    private(set) var hasAllowedThisSession = false
    private(set) var hasPromptedThisLaunch = false

    // MARK: - Initialization

    init() {
        loadPersistedPermission()
        // Per-launch flags start false (explicit resetPerLaunchFlags() is called by owner at launch time
        // for clarity; the stored properties default to false and load only touches persisted permission).
    }

    // MARK: - Load + Migration (called once at init)

    /// Loads `cellularDataPermission`, or migrates from the legacy dismissed flag when ternary is absent.
    ///
    /// - Postcondition: `currentPermission` reflects ternary (or `.ask` default). Any present
    ///   legacy dismissed key is removed once ternary is authoritative (load or migration write).
    private func loadPersistedPermission() {
        let ud = UserDefaults.standard

        if let raw = ud.string(forKey: UserDefaultsKeys.cellularDataPermission),
           let perm = CellularDataPermission(rawValue: raw) {
            currentPermission = perm
            // Ternary is authoritative; drop dual-written legacy residue from older builds.
            removeLegacyDismissedFlagIfPresent(from: ud)
            return
        }

        // One-time migration from the pre-ternary boolean flag.
        // Old installs that chose "Don't show again" become "Always Allow".
        if ud.bool(forKey: UserDefaultsKeys.hasDismissedDataUsageNotification) {
            currentPermission = .alwaysAllow
            ud.set(CellularDataPermission.alwaysAllow.rawValue, forKey: UserDefaultsKeys.cellularDataPermission)
            removeLegacyDismissedFlagIfPresent(from: ud)
            return
        }

        currentPermission = .ask
    }

    /// Removes `hasDismissedDataUsageNotification` when present.
    ///
    /// - Note: Called after ternary load/migration and from `setAlwaysAllow()` so installs that
    ///   previously dual-wrote both keys clean up without waiting for a reinstall. Safe no-op
    ///   when the key is already absent.
    private func removeLegacyDismissedFlagIfPresent(from ud: UserDefaults) {
        guard ud.object(forKey: UserDefaultsKeys.hasDismissedDataUsageNotification) != nil else { return }
        ud.removeObject(forKey: UserDefaultsKeys.hasDismissedDataUsageNotification)
    }

    // MARK: - Launch-time reset (owner calls this early, e.g. viewDidLoad before network monitoring)

    /// Resets the in-memory per-launch guards so that:
    /// - .ask users see the prompt again on next cold launch while on cellular.
    /// - .sessionAllow users get exactly one prompt opportunity per launch.
    func resetPerLaunchFlags() {
        hasAllowedThisSession = false
        hasPromptedThisLaunch = false
    }

    // MARK: - Decision (called from the expensive-network branch inside the path handler)

    /// Returns whether the 3-choice alert should be presented for the current expensive path event.
    /// The caller is responsible for also calling `markPromptedThisLaunch()` immediately before/after showing.
    func shouldShowPrompt(isConnected: Bool, isExpensive: Bool) -> Bool {
        guard isConnected && isExpensive else { return false }
        if hasPromptedThisLaunch { return false }

        switch currentPermission {
        case .alwaysAllow:
            return false
        case .sessionAllow:
            return !hasAllowedThisSession
        case .ask:
            return true
        }
    }

    func markPromptedThisLaunch() {
        hasPromptedThisLaunch = true
    }

    // MARK: - User Choice Recorders (called from alert action handlers in owner)

    /// Persists `.alwaysAllow` to the ternary key only (no legacy dual-write).
    ///
    /// - Postcondition: `cellularDataPermission == alwaysAllow`; legacy dismissed key is absent.
    func setAlwaysAllow() {
        currentPermission = .alwaysAllow
        let ud = UserDefaults.standard
        ud.set(CellularDataPermission.alwaysAllow.rawValue, forKey: UserDefaultsKeys.cellularDataPermission)
        // Single durable write path is the ternary. Drop any residual legacy flag; do not re-write it.
        removeLegacyDismissedFlagIfPresent(from: ud)
        hasAllowedThisSession = false // irrelevant for always
    }

    func setSessionAllow() {
        currentPermission = .sessionAllow
        UserDefaults.standard.set(CellularDataPermission.sessionAllow.rawValue, forKey: UserDefaultsKeys.cellularDataPermission)
        hasAllowedThisSession = true
    }

    func setAsk() {
        currentPermission = .ask
        UserDefaults.standard.set(CellularDataPermission.ask.rawValue, forKey: UserDefaultsKeys.cellularDataPermission)
        // hasAllowedThisSession remains as-is (will be cleared on next reset or not relevant)
    }
}
