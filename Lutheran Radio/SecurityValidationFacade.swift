//
//  SecurityValidationFacade.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 24.7.2026.
//
//  Named main-app intents for security-model validation call sites.
//
//  Policy, DNS TXT validation, and certificate pinning remain exclusively in Core
//  (`SecurityModelValidator`, `CertificateValidator`, `SecurityConfiguration`).
//  This façade does not reimplement validation — it names why the main app is asking
//  Core so call-site sprawl stays inventoryable and UITest skips stay at the edge.
//
//  Call-site table (SSOT for main-app named intents):
//
//  | Intent | Core entry | Primary call sites |
//  |--------|------------|--------------------|
//  | `.eagerWarm` | `validateSecurityModel()` | `DirectStreamingPlayer` designated / convenience init |
//  | `.beforeAttach` | `validateSecurityModel()` | `SharedPlayerManager.play()` after early gates |
//  | `.onReconnect` | `validateSecurityModel()` | `ViewController` network restore; DSP path monitor reconnect |
//  | `.securityRetry` | `validateSecurityModel()` | `RadioPlayerCoordinator` security-lock alert Retry |
//  | `.recoveryValidityCheck` | `isCurrentlyValid()` | `DirectStreamingPlayer.play()` recovery path (cached/current) |
//
//  Permanent invalidity reads (`isPermanentlyInvalid`) and transient reset remain thin
//  passthroughs — they are not separate product intents.
//
//  - SeeAlso: <doc:Security-Invariants>, <doc:Architecture>, CODING_AGENT.md (Core surface),
//    SecurityModelValidator, SharedPlayerManager.play().
//  - AGENT NOTE: Never bypass Core validators. Never add security policy here.
//    UITestMode short-circuits stay at call sites (or early gates) before this façade.
//

import Foundation
import Core

// MARK: - Intent

/// Why the main app is requesting security-model validation from Core.
///
/// - Important: These names document call-site purpose only. They do not weaken
///   DNS TXT validation, pinning, time-skew, or permanent-lock semantics.
@frozen public enum SecurityValidationIntent: Sendable, Equatable {
    /// Cold init / process start eager DNS TXT warm (status chrome only).
    case eagerWarm
    /// `SharedPlayerManager.play()` immediately before soft-resume / attach.
    case beforeAttach
    /// Network path restored or active connectivity probe success.
    case onReconnect
    /// User tapped Retry on security-locked chrome.
    case securityRetry
    /// Engine recovery `play()` — use current/cached validity, not a forced re-fetch intent.
    case recoveryValidityCheck
}

// MARK: - Façade

/// Thin named entry to Core security-model validation for main-app call sites.
///
/// - SeeAlso: ``SecurityValidationIntent``, `SecurityModelValidator`.
public enum SecurityValidationFacade {

    /// Validates (or reads current validity) according to ``SecurityValidationIntent``.
    ///
    /// - Parameter intent: Named call-site purpose (see file header table).
    /// - Returns: `true` when the security model allows streaming to proceed.
    /// - Precondition: Callers under UITestMode must skip this path entirely when
    ///   product policy forbids DNS/network (see `SharedPlayerManager.play` early gates).
    public static func validate(_ intent: SecurityValidationIntent) async -> Bool {
        switch intent {
        case .recoveryValidityCheck:
            return await SecurityModelValidator.shared.isCurrentlyValid()
        case .eagerWarm, .beforeAttach, .onReconnect, .securityRetry:
            return await SecurityModelValidator.shared.validateSecurityModel()
        }
    }

    /// Whether Core reports a permanent security-model failure (not a transient DNS miss).
    public static func isPermanentlyInvalid() async -> Bool {
        await SecurityModelValidator.shared.isPermanentlyInvalid
    }

    /// Clears transient Core validation state so the next full validate may re-query DNS.
    ///
    /// Used on network reconnect before ``validate(_:)`` with `.onReconnect`.
    public static func resetTransientState() async {
        await SecurityModelValidator.shared.resetTransientState()
    }
}
