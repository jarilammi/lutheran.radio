//
//  SecurityConfiguration.swift
//  Core
//
//  Single source of truth for every security constant and networking policy.
//
//  This file owns:
//  - The embedded `expectedSecurityModel` ("dallas")
//  - Authoritative certificate fingerprints (DER digest form)
//  - Transition window + time-skew parameters
//  - DNSSEC streaming policy (`requiresDNSSECValidationForStreaming`)
//  - The factory `makeSecureEphemeralConfiguration()` used by all streaming paths
//
//  AGENT NOTE: Any new security constant, DNS policy knob, or secure-session
//  helper must be added here (never duplicated in DirectStreamingPlayer or elsewhere).
//  Consumers obtain policy exclusively via `SecurityConfiguration.current` or
//  the static factory methods.
//
//  - SeeAlso: <doc:Security-Invariants>, <doc:Architecture>, SecurityModelValidator,
//    CertificateValidator, DirectStreamingPlayer (urlWithOptimalServer + resource loader)
//
//  Created by Jari Lammi on 18.3.2026.
//

import Foundation

public struct SecurityConfiguration: Sendable {
    
    // MARK: - Security Model (DNS TXT validated)
    
    /// The embedded security model this app build enforces.
    ///
    /// This value **must** appear in the comma-separated TXT record returned by the domains
    /// listed in ``securityModelDomains`` (queried by ``SecurityModelValidator``).
    ///
    /// If validation fails permanently, streaming is disabled for the lifetime of the process.
    ///
    /// - SeeAlso: ``<doc:Security-Invariants>``, ``SecurityModelValidator/validateSecurityModel()``
    public let expectedSecurityModel: String = "dallas"
    
    /// Primary domain queried for TXT record containing valid models (comma-separated).
    let primarySecurityModelDomain: String = "securitymodels.lutheran.radio"
    
    /// Backup domain for redundancy (different TLD).
    let backupSecurityModelDomain: String = "securitymodels.lutheranradio.sk"
    
    /// All domains in priority order (primary → backup)
    /// Computed property to avoid Swift property initializer ordering issues.
    var securityModelDomains: [String] {
        [
            primarySecurityModelDomain,
            backupSecurityModelDomain
        ]
    }
    
    /// Cache duration for successful security model validation results.
    /// After this interval, re-query the TXT record.
    let modelCacheDuration: TimeInterval = 3_600  // 1 hour
    
    
    // MARK: - Certificate Pinning (runtime full-chain validation)
    
    /// OpenSSL-style leaf fingerprint (README / operator tooling parity only).
    private static let pinnedLeafFingerprintHex =
        "CC:F7:8E:09:EF:F3:3D:9A:5D:8B:B0:5C:74:28:0D:F6:BE:14:1C:C4:47:F9:69:C2:90:2C:43:97:66:8B:3D:CC"
    
    /// SHA-256 digest of the leaf certificate DER (authoritative runtime pin, beyond ATS SPKI).
    ///
    /// - Important: Never duplicate or override this value elsewhere in the codebase.
    let pinnedLeafFingerprintDigest: CertificateFingerprint = {
        // SAFETY: `pinnedLeafFingerprintHex` is a compile-time constant validated at first access.
        guard let digest = CertificateFingerprint(colonHexUppercase: pinnedLeafFingerprintHex) else {
            fatalError("Invalid pinnedLeafFingerprintHex in SecurityConfiguration")
        }
        return digest
    }()
    
    /// Colon-hex view of ``pinnedLeafFingerprintDigest`` (documentation / external tooling).
    public var pinnedLeafFingerprint: String {
        pinnedLeafFingerprintDigest.colonHexUppercase
    }
    
    /// Acceptable leaf certificate SHA-256 digests used by ``CertificateValidator``.
    ///
    /// Exposed as a list to support future rotation overlap without `Set` hash short-circuits.
    var pinnedFingerprintDigests: [CertificateFingerprint] {
        [pinnedLeafFingerprintDigest]
    }
    
    /// Colon-hex fingerprints (derived from ``pinnedFingerprintDigests``).
    ///
    /// - SeeAlso: ``<doc:Security-Invariants>``, ``CertificateValidator/validateServerTrust(_:)``
    public var pinnedFingerprints: Set<String> {
        Set(pinnedFingerprintDigests.map(\.colonHexUppercase))
    }
    
    
    // MARK: - Certificate Transition Window
    
    /// Start of the one-month grace period before certificate expiry/rotation.
    /// During this window: runtime pinning failures are lenient (fall back to ATS).
    let transitionWindowStart: Date = {
        var components = DateComponents(calendar: .current, timeZone: .gmt)
        components.year   = 2026
        components.month  = 7
        components.day    = 27
        components.hour   = 0
        components.minute = 0
        components.second = 0
        return Calendar.current.date(from: components) ?? Date.distantFuture
    }()
    
    /// End of the transition window (inclusive).
    /// After this date: strict runtime pinning enforcement (no leniency).
    let transitionWindowEnd: Date = {
        var components = DateComponents(calendar: .current, timeZone: .gmt)
        components.year   = 2026
        components.month  = 8
        components.day    = 26
        components.hour   = 23
        components.minute = 59
        components.second = 59
        return Calendar.current.date(from: components) ?? Date.distantPast
    }()
    
    /// Whether the current device date falls inside the certificate transition grace period.
    ///
    /// During this window, ``CertificateValidator`` may (under strict additional conditions)
    /// accept a certificate whose fingerprint does not match ``pinnedFingerprints``.
    ///
    /// The window is defined by ``transitionWindowStart`` and ``transitionWindowEnd``.
    /// Time-skew protection (``maxAllowedTimeSkew``) can disable leniency even inside the window.
    ///
    /// - SeeAlso: ``<doc:Security-Invariants>``, ``CertificateValidator``
    public var isInTransitionWindow: Bool {
        let now = Date()
        return now >= transitionWindowStart && now <= transitionWindowEnd
    }
    
    
    // MARK: - Time Skew Protection
    
    /// Maximum allowed difference between device time and server Date header (seconds).
    /// If exceeded → disable transition leniency even inside window (anti-clock-manipulation).
    let maxAllowedTimeSkew: TimeInterval = 300  // ±5 minutes
    
    
    // MARK: - DNSSEC-Protected Streaming Resolution (requiresDNSSECValidation)
    
    /// When true, URLSession-based streaming, proactive certificate validation, and server-selection
    /// pings require that DNS resolutions for protected hosts are DNSSEC-validated.
    ///
    /// This is applied at the `URLSessionConfiguration` level via `requiresDNSSECValidation`.
    /// It provides authenticated DNS resolution (integrity + origin of the A/AAAA answers)
    /// before any TLS handshake or certificate pinning occurs.
    ///
    /// - Session-level only: the flag lives on the configuration, not individual requests.
    ///   All streaming-related sessions are short-lived or task-specific, so this is the
    ///   appropriate and Apple-recommended granularity (see WWDC guidance on DNS security).
    /// - Opt-in safe: the flag can be observed; when the local resolver cannot supply a
    ///   validated answer the affected `URLSession` task fails. Callers (e.g. DirectStreamingPlayer)
    ///   treat such failures as transient (retry / server failover) rather than permanent.
    /// - Complements, does not replace:
    ///   - `SecurityModelValidator` (low-level `kDNSServiceFlagsValidate` + bit check for TXT allow-list)
    ///   - ATS SPKI pinning (Info.plist)
    ///   - `CertificateValidator` runtime full-DER pinning
    ///
    /// All production sessions that talk to `*.lutheran.radio` hosts for media or validation
    /// must be configured through the helpers below.
    ///
    /// - SeeAlso: ``applySecureNetworkingRequirements(to:)``, ``makeSecureEphemeralConfiguration()``,
    ///   ``<doc:Security-Invariants>``, DirectStreamingPlayer (resource loader + pings),
    ///   CertificateValidator (HEAD validation path)
    public let requiresDNSSECValidationForStreaming: Bool = true
    
    /// Returns whether the supplied host is covered by streaming DNSSEC policy.
    ///
    /// Used by call sites to decide whether to obtain a secure session configuration.
    /// Matches both the bare domain and any subdomain under lutheran.radio.
    ///
    /// - Parameter host: A hostname (case-insensitive comparison performed).
    /// - Returns: true for hosts whose DNS answers should be required to be DNSSEC-validated.
    public static func hostRequiresDNSSECValidation(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "lutheran.radio" || h.hasSuffix(".lutheran.radio")
    }
    
    /// Applies the current secure networking policy (DNSSEC requirement + cache/credential hardening)
    /// to an existing `URLSessionConfiguration`.
    ///
    /// Call this (or use the factory) for every session that will contact protected streaming hosts.
    /// Safe to call on any configuration; the method is intentionally side-effecting on the passed object
    /// because `URLSessionConfiguration` is a mutable bag of properties.
    ///
    /// Effects when ``requiresDNSSECValidationForStreaming`` is true:
    /// - `configuration.requiresDNSSECValidation = true`
    ///
    /// Always applied for sessions we create for protected hosts:
    /// - `urlCache = nil`
    /// - `requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData`
    /// - `urlCredentialStorage = nil`
    ///
    /// - Parameter configuration: The configuration that will be used to create a `URLSession`.
    ///   Typically an `.ephemeral` instance supplied by the caller so that per-call timeouts
    ///   and other tunables can still be set after this call.
    ///
    /// - Important: After calling this, further customize timeouts etc. The DNSSEC flag must not
    ///   be overridden back to false for protected hosts.
    ///
    /// - SeeAlso: ``makeSecureEphemeralConfiguration()``, ``hostRequiresDNSSECValidation(_:)``
    public func applySecureNetworkingRequirements(to configuration: URLSessionConfiguration) {
        // Cache and credential hardening (defense-in-depth for security-sensitive sessions).
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCredentialStorage = nil
        
        if requiresDNSSECValidationForStreaming {
            configuration.requiresDNSSECValidation = true
        }
    }
    
    /// Returns a fresh ephemeral `URLSessionConfiguration` with the current secure networking
    /// policy already applied.
    ///
    /// This is the recommended single place to obtain a baseline configuration for any
    /// networking that touches livestream or security model hosts.
    ///
    /// Callers are expected to layer additional settings (timeouts, connection limits, etc.)
    /// on the returned value before creating the `URLSession`.
    ///
    /// Example (typical streaming data session):
    /// ```swift
    /// let config = SecurityConfiguration.makeSecureEphemeralConfiguration()
    /// config.timeoutIntervalForRequest = 60
    /// config.timeoutIntervalForResource = 120
    /// let session = URLSession(configuration: config, delegate: myDelegate, delegateQueue: q)
    /// ```
    ///
    /// - Returns: An ephemeral configuration with `requiresDNSSECValidation` (when enabled)
    ///   and cache-disabling policy set.
    ///
    /// - SeeAlso: ``applySecureNetworkingRequirements(to:)``
    public static func makeSecureEphemeralConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        current.applySecureNetworkingRequirements(to: config)
        return config
    }
    
    
    // MARK: - Convenience / Current Instance
    
    /// The canonical, shared instance of the security policy.
    ///
    /// All production code should obtain configuration via `SecurityConfiguration.current`
    /// rather than constructing new instances. This ensures a single source of truth
    /// for every security constant and policy decision.
    ///
    /// - SeeAlso: ``<doc:Security-Invariants>``
    public static let current = SecurityConfiguration()
}
