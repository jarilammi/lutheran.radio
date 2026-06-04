# Security Invariants

@Metadata {
    @TechnologyRoot
}

This document defines the **non-negotiable security invariants** of the Lutheran Radio application. These rules are enforced in code and must never be weakened, bypassed, or duplicated outside the `Core` framework.

## Core Principles

- **Security is non-negotiable.** All other concerns (performance, convenience, code size) are secondary.
- The `Core` framework is the **single source of truth** for every security decision.
- No security logic may be duplicated in the main app target, widget extension, or tests (except test seams explicitly marked `#if DEBUG`).

## Invariant 1: Security Model Validation (DNS TXT)

- The app **must** successfully validate that its embedded `expectedSecurityModel` appears in the comma-separated TXT record returned by `securitymodels.lutheran.radio` (or the backup domain) before any streaming is allowed.
- Validation is performed exclusively by ``SecurityModelValidator``.
- On **permanent failure** (model not present in TXT), streaming is **permanently disabled** for the lifetime of the process. The only recovery is installing a new app build with an updated model.
- On **transient failure**, the app may retry, but must eventually succeed or fall back to a safe error state.
- Successful validations are cached for exactly 1 hour in `UserDefaults` (key: `lastSecurityValidation`). The cache applies **only** to successes.
- The validator is an `actor` and all mutation of validation state is isolated.

## Invariant 2: Certificate Pinning (Runtime Full-Chain)

- Runtime certificate validation is performed exclusively by ``CertificateValidator``.
- The validator performs **full-certificate SHA-256 DER digest pinning** against ``SecurityConfiguration/pinnedFingerprintDigests`` (``CertificateFingerprint`` values).
- Comparison uses ``CertificateFingerprint/constantTimeMatches(_:)``; runtime code must not compare colon-hex strings.
- App Transport Security (ATS) SPKI pinning in `Info.plist` provides the baseline. The runtime validator adds a second, independent layer.
- ``SecurityConfiguration/pinnedLeafFingerprintDigest`` is the authoritative pin; ``pinnedLeafFingerprint`` and ``pinnedFingerprints`` are derived colon-hex views for operators and docs only. Never duplicate or override digest values elsewhere.

## Invariant 3: Transition Window & Time-Skew Protection

- A one-month transition window exists (currently 2026-07-27 00:00:00 GMT through 2026-08-26 23:59:59 GMT).
- During the window, a fingerprint mismatch is tolerated (falls back to ATS trust) **only if**:
  - `allowTransitionLeniency` remains `true`, **and**
  - Device time vs. HTTP `Date` header skew is ≤ 5 minutes (`maxAllowedTimeSkew`).
- Any detected time manipulation or window mismatch **permanently disables** leniency for the remainder of the process.
- Outside the window (before start or after end), fingerprint mismatches cause **hard failure** regardless of ATS result.

## Invariant 4: Configuration Centralization

All of the following values exist **only** inside ``SecurityConfiguration`` and are never hard-coded elsewhere:

- `expectedSecurityModel` ("brenham")
- `pinnedLeafFingerprintDigest` (authoritative 32-byte pin; ``CertificateFingerprint``)
- `pinnedFingerprintDigests` (acceptable digests for ``CertificateValidator``)
- `pinnedLeafFingerprint` / `pinnedFingerprints` (derived colon-hex; operator and README parity only)
- `transitionWindowStart` / `transitionWindowEnd`
- `maxAllowedTimeSkew`
- `modelCacheDuration`
- Domain list (`securityModelDomains`)

## Invariant 5: No Bypass Paths

- There is no build-time or runtime flag that disables DNS TXT validation, certificate fingerprint checking, or time-skew detection.
- Debug/test seams (`_test_*` methods and `currentDate` injection) are compiled out of Release builds and have zero effect on production behavior.
- The `Core` module is linked into both the main app and the widget extension; both must obey the same rules.

## Enforcement

These invariants are primarily enforced by:

- ``SecurityConfiguration`` — constants and policy
- ``SecurityModelValidator`` — DNS TXT actor
- ``CertificateFingerprint`` — digest type, hashing, constant-time equality
- ``CertificateValidator`` — runtime pinning actor

Any proposed change that touches these files, the DNS TXT record contents, the pinned digest(s), or the transition dates requires explicit security review.

## References

- ``<doc:Architecture>`` — How the three components interact
- README.md — "Security Model Validation", "Certificate Pinning", and "Why DNS TXT Records?" sections
- AGENTS.md / CODING_AGENT.md — Permanent rules for all contributors and AI agents

> Warning: Violating any invariant above constitutes a security regression and will be rejected.
