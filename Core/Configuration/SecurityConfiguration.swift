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
//  - Distinct cache durations: `modelCacheDuration` (DNS TXT success, 1 h) and
//    `certificateValidationCacheDuration` (runtime pin-result success, 10 min)
//  - Streaming media apex list (`preferredStreamingDomainSuffixes` — sole active
//    apex: `siikkari.net`) and DNS TXT security-model host list
//  - DNSSEC streaming policy (`requiresDNSSECValidationForStreaming`)
//  - The factory `makeSecureEphemeralConfiguration()` used by all streaming paths
//
//  AGENT NOTE: Any new security constant, DNS policy knob, streaming-domain
//  preference, or secure-session helper must be added here (never duplicated in
//  DirectStreamingPlayer or elsewhere). Consumers obtain policy exclusively via
//  `SecurityConfiguration.current` or the static factory methods. Never point
//  certificate caching at `modelCacheDuration`.
//
//  Media vs TXT separation:
//  - Media / ping / resource-loader hosts use preferredStreamingDomainSuffixes only
//    (`siikkari.net`). The former dual-apex fallback (`lutheran.radio` media hosts)
//    was removed after live confirmation that european.siikkari.net /
//    livestream.siikkari.net and language hosts are the sole data plane.
//  - securityModelDomains remains an independent ordered list for DNS TXT allow-list
//    queries (`securitymodels.siikkari.net` primary, then
//    `securitymodels.lutheranradio.eu`, then `securitymodels.lutheranradio.sk` backup).
//    Transient DNS failures advance the list (existing validator policy). Streaming
//    apex and TXT query hosts are separate SSOTs — do not assume they share apexes.
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
    ///
    /// First entry in ``securityModelDomains``. Aligns with the media apex brand
    /// (`siikkari.net`). Live production allow-list is published here (DNSSEC-signed
    /// TXT + RRSIG). Transient DNS-SD failure / no-record responses still advance
    /// ``SecurityModelValidator`` down ``securityModelDomains`` without changing
    /// permanent-vs-transient semantics.
    ///
    /// Independent of ``preferredStreamingDomainSuffixes`` (media hosts vs TXT hosts
    /// are separate SSOTs even when both use the siikkari brand).
    let primarySecurityModelDomain: String = "securitymodels.siikkari.net"
    
    /// Secondary DNS TXT host (transient-only redundancy).
    ///
    /// Queried on **transient** failure of the primary only (existing validator
    /// policy — no permanent failure falls through). Mirrors the primary allow-list
    /// for resilience across apexes. Replaced former secondary
    /// `securitymodels.lutheran.radio` after the allow-list published on
    /// `lutheranradio.eu` (DNSSEC-signed TXT + RRSIG).
    let secondarySecurityModelDomain: String = "securitymodels.lutheranradio.eu"
    
    /// Final backup domain for redundancy (different TLD / apex).
    ///
    /// Queried only on transient failure of earlier hosts (see ``SecurityModelValidator``).
    /// Long-standing DNS TXT backup — not a streaming media apex.
    let backupSecurityModelDomain: String = "securitymodels.lutheranradio.sk"
    
    /// DNS TXT security-model hosts in query priority order (primary → secondary → backup).
    ///
    /// Computed property to avoid Swift property initializer ordering issues.
    /// This list is **not** the same as ``preferredStreamingDomainSuffixes``: TXT
    /// validation hosts and media host preference are separate SSOTs.
    ///
    /// Transient DNS errors (including unimplemented / empty primary) advance to the
    /// next entry; an authoritative “model not in TXT” on a responding domain remains
    /// permanent and does **not** continue the list (existing validator contract).
    ///
    /// - SeeAlso: ``preferredStreamingDomainSuffixes``, ``SecurityModelValidator``
    var securityModelDomains: [String] {
        [
            primarySecurityModelDomain,
            secondarySecurityModelDomain,
            backupSecurityModelDomain
        ]
    }
    
    // MARK: - Streaming Domain Preference (media apex SSOT)
    
    /// Apex domain suffixes for media / ping / certificate-validation hosts.
    ///
    /// Sole active media apex (production data plane confirmed on
    /// `european.siikkari.net`, `livestream.siikkari.net`, and language hosts):
    /// 1. `siikkari.net` — SSL streaming apex for this app build
    ///
    /// The list remains ordered so a future second apex can be reintroduced as an
    /// explicit preference without call-site rewrites. Today there is **no** media
    /// fallback to `lutheran.radio` — that apex is not used for streaming in this
    /// binary. DNS TXT allow-list hosts stay on ``securityModelDomains`` (still
    /// `securitymodels.lutheranradio.eu` / `.lutheranradio.sk`) and are unrelated.
    ///
    /// **Security Invariant:** Host matching for DNSSEC session policy
    /// (``hostRequiresDNSSECValidation(_:)`` / ``isProtectedStreamingHost(_:)``)
    /// must cover **every** suffix in this list. Do not hard-code apex strings in
    /// `DirectStreamingPlayer`, resource loader, or tests — read this SSOT.
    ///
    /// **Operational requirements** for the media apex: leaf (or multi-SAN) coverage
    /// for `*.siikkari.net`, matching `NSPinnedDomains` SPKI for that apex in
    /// Info.plist, and the live leaf DER in ``pinnedFingerprintDigests``.
    ///
    /// - SeeAlso: ``securityModelDomains``, ``hostRequiresDNSSECValidation(_:)``,
    ///   ``streamingHostCandidates(leadingLabel:)``, ``<doc:Security-Invariants>``
    public var preferredStreamingDomainSuffixes: [String] {
        [
            "siikkari.net"
        ]
    }
    
    /// Active streaming apex (first element of ``preferredStreamingDomainSuffixes``).
    ///
    /// Today identical to the only list entry (`siikkari.net`). Prefer
    /// ``streamingHostCandidates(leadingLabel:)`` when building hosts so callers
    /// stay list-driven if a second apex is ever re-added.
    public var preferredStreamingDomainSuffix: String {
        // SAFETY: The ordered list is a compile-time constant with ≥1 entry; first is defined.
        preferredStreamingDomainSuffixes[0]
    }
    
    /// Whether `host` is a bare apex or subdomain under any preferred streaming suffix.
    ///
    /// - Parameter host: Hostname (comparison is case-insensitive).
    /// - Returns: `true` if the host is covered by streaming DNSSEC / secure-session policy.
    /// - SeeAlso: ``hostRequiresDNSSECValidation(_:)``, ``preferredStreamingDomainSuffixes``
    public func isProtectedStreamingHost(_ host: String) -> Bool {
        let h = host.lowercased()
        for suffix in preferredStreamingDomainSuffixes {
            if h == suffix || h.hasSuffix("." + suffix) {
                return true
            }
        }
        return false
    }
    
    /// Candidate hostnames for a single leading label under each preferred apex, in order.
    ///
    /// Example: `leadingLabel` `"english-eu"` → `["english-eu.siikkari.net"]`.
    ///
    /// Use this when building stream / ping / HEAD URLs so callers stay list-driven
    /// without hard-coding domain strings.
    ///
    /// - Parameter leadingLabel: Subdomain label(s) before the apex (no trailing dot).
    /// - Returns: Host strings in ``preferredStreamingDomainSuffixes`` order.
    /// - Precondition: `leadingLabel` is non-empty and does not include a scheme or path.
    public func streamingHostCandidates(leadingLabel: String) -> [String] {
        preferredStreamingDomainSuffixes.map { suffix in
            "\(leadingLabel).\(suffix)"
        }
    }
    
    /// Cache duration for **successful** DNS TXT security-model validation only.
    ///
    /// After this interval, ``SecurityModelValidator`` re-queries the TXT record.
    /// Failures are never cached. This value must **not** be reused for certificate
    /// validation — use ``certificateValidationCacheDuration`` instead.
    ///
    /// - Important: Distinct from runtime certificate pin-result caching. Coupling the
    ///   two previously caused a 1-hour cert cache while permanent docs specified 10 minutes.
    /// - SeeAlso: ``SecurityModelValidator``, ``certificateValidationCacheDuration``,
    ///   ``<doc:Security-Invariants>``
    let modelCacheDuration: TimeInterval = 3_600  // 1 hour
    
    
    // MARK: - Certificate Pinning (runtime full-chain validation)
    
    /// How long a **successful** runtime full-certificate pin result may be reused.
    ///
    /// ``CertificateValidator`` returns the cached success for this interval without
    /// re-evaluating trust / leaf digest. Failures are not treated as long-lived success.
    /// Periodic HEAD revalidation in the streaming engine (``DirectStreamingPlayer``)
    /// uses the same duration so proactive checks and challenge-path caching stay aligned.
    ///
    /// - Note: Independent of ``modelCacheDuration`` (DNS TXT success cache = 1 hour).
    /// - Important: Never hard-code 600 / 10 minutes at call sites; read this constant.
    /// - SeeAlso: ``CertificateValidator``, ``modelCacheDuration``, ``<doc:Security-Invariants>``,
    ///   ``<doc:Architecture>``
    public let certificateValidationCacheDuration: TimeInterval = 600  // 10 minutes
    
    /// Live leaf DER SHA-256 for the sole production media apex (`CN=*.siikkari.net`).
    ///
    /// Verified against `european.siikkari.net` and `livestream.siikkari.net` (same wildcard leaf).
    /// This is the **only** runtime full-certificate pin in production: the retired pre-cutover
    /// leaf (`CC:F7:…:3D:CC`, former `*.lutheran.radio` era) is intentionally **not** accepted.
    /// Keeping a retired leaf on the acceptance list would enlarge the set of valid certificates
    /// after the media apex cutover without operational need.
    ///
    /// Operator verify:
    /// ```bash
    /// openssl s_client -connect livestream.siikkari.net:443 -servername livestream.siikkari.net < /dev/null 2>/dev/null \
    /// | openssl x509 -outform DER | openssl dgst -sha256
    /// ```
    /// Expected lowercase hex: `32825e978cf71ff10cf6809d2d15c81daa856528f467d6e51b6f7a5fb21870cd`
    ///
    /// - SeeAlso: ``pinnedFingerprintDigests``, ``preferredStreamingDomainSuffixes``,
    ///   Info.plist `NSPinnedDomains` (`siikkari.net` SPKI)
    private static let pinnedLeafFingerprintHex =
        "32:82:5E:97:8C:F7:1F:F1:0C:F6:80:9D:2D:15:C8:1D:AA:85:65:28:F4:67:D6:E5:1B:6F:7A:5F:B2:18:70:CD"
    
    /// SHA-256 digest of the sole production leaf certificate DER (`*.siikkari.net`).
    ///
    /// - Important: Never duplicate or override this value elsewhere in the codebase.
    /// - Note: ``CertificateValidator`` accepts **any** digest in ``pinnedFingerprintDigests``.
    ///   Today the list is a single entry (this digest). Prefer that list for membership checks
    ///   so rotation can append a new leaf without call-site rewrites.
    /// - SeeAlso: ``pinnedFingerprintDigests``, ``<doc:Security-Invariants>``
    let pinnedLeafFingerprintDigest: CertificateFingerprint = {
        // SAFETY: `pinnedLeafFingerprintHex` is a compile-time constant validated at first access.
        guard let digest = CertificateFingerprint(colonHexUppercase: pinnedLeafFingerprintHex) else {
            fatalError("Invalid pinnedLeafFingerprintHex in SecurityConfiguration")
        }
        return digest
    }()
    
    /// Alias for the sole live preferred-apex leaf pin (same value as ``pinnedLeafFingerprintDigest``).
    ///
    /// Retained so operator docs and SeeAlso links that name the siikkari-specific symbol still resolve.
    /// Do not reintroduce a second, distinct digest here without a coordinated rotation.
    ///
    /// - SeeAlso: ``pinnedFingerprintDigests``, ``pinnedLeafFingerprintDigest``
    var pinnedSiikkariLeafFingerprintDigest: CertificateFingerprint {
        pinnedLeafFingerprintDigest
    }
    
    /// Colon-hex view of ``pinnedLeafFingerprintDigest`` (documentation / external tooling).
    public var pinnedLeafFingerprint: String {
        pinnedLeafFingerprintDigest.colonHexUppercase
    }
    
    /// Colon-hex view of ``pinnedSiikkariLeafFingerprintDigest`` (operator / openssl parity).
    ///
    /// Identical to ``pinnedLeafFingerprint`` while the sole production pin is the siikkari leaf.
    public var pinnedSiikkariLeafFingerprint: String {
        pinnedSiikkariLeafFingerprintDigest.colonHexUppercase
    }
    
    /// Acceptable leaf certificate SHA-256 digests used by ``CertificateValidator``.
    ///
    /// Production acceptance is **only** the live preferred streaming apex leaf
    /// (``pinnedLeafFingerprintDigest`` / ``pinnedSiikkariLeafFingerprintDigest`` —
    /// `*.siikkari.net`). Retired pre-cutover leaves must not remain on this list:
    /// that would accept certificates the media plane no longer serves and expand
    /// the MITM target set without benefit.
    ///
    /// Exposed as an array (not a `Set`) so comparison walks pins without hash short-circuits
    /// and a future rotation can **append** the next leaf for a deliberate overlap window
    /// without removing the current pin mid-cutover. Drop retired digests once the old leaf
    /// is no longer operationally required.
    ///
    /// **Security Invariant:** Runtime validation must succeed against this list for media hosts
    /// under ``preferredStreamingDomainSuffixes``. Do not hard-code digests outside this file.
    ///
    /// - SeeAlso: ``CertificateValidator/validateServerTrust(_:)``, ``<doc:Security-Invariants>``,
    ///   ``preferredStreamingDomainSuffixes``
    var pinnedFingerprintDigests: [CertificateFingerprint] {
        [
            pinnedLeafFingerprintDigest
        ]
    }
    
    /// Colon-hex fingerprints (derived from ``pinnedFingerprintDigests``).
    ///
    /// - SeeAlso: ``<doc:Security-Invariants>``, ``CertificateValidator/validateServerTrust(_:)``
    public var pinnedFingerprints: Set<String> {
        Set(pinnedFingerprintDigests.map(\.colonHexUppercase))
    }
    
    
    // MARK: - Certificate Transition Window
    
    /// Start of the grace period before the next preferred-apex leaf expiry/rotation.
    ///
    /// During this window: runtime pinning failures may be lenient (fall back to ATS),
    /// subject to ``maxAllowedTimeSkew`` and ``CertificateValidator`` process flags.
    ///
    /// **Anchored to live `*.siikkari.net` leaf** (`CN=*.siikkari.net` on
    /// `livestream.siikkari.net` / `european.siikkari.net`):
    /// - `notAfter` = **2027-02-10 23:59:59 GMT** (operator verify via openssl)
    /// - Window start is intentionally **2027-01-01 00:00:00 GMT** (calendar-month
    ///   lead-in before expiry, slightly longer than a strict 30-day window)
    ///
    /// Outside this window, ``pinnedFingerprintDigests`` membership is the
    /// normal acceptance path; leniency is only needed when rotating to a leaf
    /// not yet on the pin list (or when ATS SPKI still matches during cutover).
    ///
    /// - SeeAlso: ``transitionWindowEnd``, ``isInTransitionWindow``, ``<doc:Security-Invariants>``,
    ///   README “Media Apex Cutover & SSL Certificate Rotation”
    let transitionWindowStart: Date = {
        var components = DateComponents(calendar: .current, timeZone: .gmt)
        components.year   = 2027
        components.month  = 1
        components.day    = 1
        components.hour   = 0
        components.minute = 0
        components.second = 0
        return Calendar.current.date(from: components) ?? Date.distantFuture
    }()
    
    /// End of the transition window (inclusive), aligned with live leaf `notAfter`.
    ///
    /// After this date: strict runtime pinning enforcement (no ATS leniency on pin mismatch).
    /// Must stay in sync with the current preferred-apex certificate expiry
    /// (`*.siikkari.net` → 2027-02-10 23:59:59 GMT until the next rotation).
    ///
    /// - SeeAlso: ``transitionWindowStart``, ``isInTransitionWindow``
    let transitionWindowEnd: Date = {
        var components = DateComponents(calendar: .current, timeZone: .gmt)
        components.year   = 2027
        components.month  = 2
        components.day    = 10
        components.hour   = 23
        components.minute = 59
        components.second = 59
        return Calendar.current.date(from: components) ?? Date.distantPast
    }()
    
    /// Whether the current device date falls inside the certificate transition grace period.
    ///
    /// During this window, ``CertificateValidator`` may (under strict additional conditions)
    /// accept a certificate whose fingerprint does not match ``pinnedFingerprintDigests``.
    ///
    /// The window is defined by ``transitionWindowStart`` and ``transitionWindowEnd``
    /// (currently **2027-01-01** through **2027-02-10** GMT, keyed to the live
    /// `*.siikkari.net` leaf expiry). Time-skew protection (``maxAllowedTimeSkew``)
    /// can disable leniency even inside the window.
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
    /// All production sessions that talk to protected streaming hosts
    /// (any apex in ``preferredStreamingDomainSuffixes``) for media or validation
    /// must be configured through the helpers below.
    ///
    /// - SeeAlso: ``applySecureNetworkingRequirements(to:)``, ``makeSecureEphemeralConfiguration()``,
    ///   ``preferredStreamingDomainSuffixes``, ``<doc:Security-Invariants>``,
    ///   DirectStreamingPlayer (resource loader + pings), CertificateValidator (HEAD validation path)
    public let requiresDNSSECValidationForStreaming: Bool = true
    
    /// Returns whether the supplied host is covered by streaming DNSSEC policy.
    ///
    /// Used by call sites to decide whether to obtain a secure session configuration.
    /// Matches bare apex and any subdomain under **every** entry of
    /// ``preferredStreamingDomainSuffixes`` (today `siikkari.net` only).
    /// Never hard-code apex strings at call sites.
    ///
    /// - Parameter host: A hostname (case-insensitive comparison performed).
    /// - Returns: `true` for hosts whose DNS answers should be required to be DNSSEC-validated.
    /// - SeeAlso: ``isProtectedStreamingHost(_:)``, ``preferredStreamingDomainSuffixes``
    public static func hostRequiresDNSSECValidation(_ host: String?) -> Bool {
        guard let h = host else { return false }
        return current.isProtectedStreamingHost(h)
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
