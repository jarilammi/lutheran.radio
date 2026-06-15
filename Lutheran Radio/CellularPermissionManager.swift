//
//  CellularPermissionManager.swift
//  Lutheran Radio
//
//  Extracted manager for cellular / metered data usage permission state, persistence, migration from legacy
//  boolean, per-launch prompting discipline, and the 3-choice decision logic.
//
//  Created by Jari Lammi on 15.6.2025.
//

import Foundation

/// Owns all state, persistence, migration, and decision logic for the smarter cellular data usage prompt.
///
/// - The 3 persistent choices reduce alert fatigue vs the prior once-per-launch boolean.
/// - "Not Now" choice causes stopPlayback() (routed by caller through SharedPlayerManager SSOT).
/// - Per-launch flags (session allow + prompted guard) are reset at cold launch.
/// - Migration: old `hasDismissedDataUsageNotification == true` seeds `.alwaysAllow` (one way).
/// - No security, streaming, or URL logic here. UI presentation of the alert remains in the ViewController
///   network host surface (per decomposition guardrails).
@MainActor
final class CellularPermissionManager {

    // MARK: - Permission States (public for any future settings surface)

    enum CellularDataPermission: String {
        case ask
        case alwaysAllow
        case sessionAllow
    }

    // MARK: - Private Keys (legacy key retained only for one-time migration compat writes/reads)

    private enum UserDefaultsKeys {
        static let cellularDataPermission = "cellularDataPermission"
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

    private func loadPersistedPermission() {
        let ud = UserDefaults.standard

        if let raw = ud.string(forKey: UserDefaultsKeys.cellularDataPermission),
           let perm = CellularDataPermission(rawValue: raw) {
            currentPermission = perm
            return
        }

        // One-time migration from the pre-ternary boolean flag.
        // Old installs that chose "Don't show again" become "Always Allow" (and we write the new key).
        if ud.bool(forKey: UserDefaultsKeys.hasDismissedDataUsageNotification) {
            currentPermission = .alwaysAllow
            ud.set(CellularDataPermission.alwaysAllow.rawValue, forKey: UserDefaultsKeys.cellularDataPermission)
            // Intentionally leave the legacy key as true for any other legacy readers during transition window.
            return
        }

        currentPermission = .ask
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

    func setAlwaysAllow() {
        currentPermission = .alwaysAllow
        let ud = UserDefaults.standard
        ud.set(CellularDataPermission.alwaysAllow.rawValue, forKey: UserDefaultsKeys.cellularDataPermission)
        // Cheap compat for any remaining readers of the old boolean during the transition.
        ud.set(true, forKey: UserDefaultsKeys.hasDismissedDataUsageNotification)
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
