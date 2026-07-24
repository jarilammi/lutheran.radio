# Security Invariants

@Metadata {
    @TechnologyRoot
}

This document defines the **required security invariants** of the Lutheran Radio application. These rules are enforced in code and must not be weakened, bypassed, or duplicated outside the `Core` framework.

## Core Principles

- **Security requirements take precedence.** All other concerns (performance, convenience, code size) are secondary.
- The `Core` framework is the **single source of truth** for every security decision.
- No security logic may be duplicated in the main app target, widget extension, or tests (except test seams explicitly marked `#if DEBUG`).

## Invariant 1: Security Model Validation (DNS TXT)

- The app **must** successfully validate that its embedded `expectedSecurityModel` appears in the comma-separated TXT record returned by `securitymodels.lutheran.radio` (or the backup domain) before any streaming is allowed.
- The query uses `kDNSServiceFlagsValidate`; the callback in ``SecurityModelValidator`` **requires** the validation bit in the returned flags before parsing or accepting rdata. Responses without successful DNSSEC validation are treated as transient failures (never trusted).
- Validation is performed exclusively by ``SecurityModelValidator``.
- On **permanent failure** (model not present in a *validated* TXT record), streaming is **permanently disabled** for the lifetime of the process. The only recovery is installing a new app build with an updated model.
- On **transient failure** (network, timeout, *or DNSSEC validation not asserted*), the app may retry, but must eventually succeed or fall back to a safe error state.
- Successful validations (validated response + model present) are cached for exactly 1 hour in `UserDefaults` (key: `lastSecurityValidation`). The cache applies **only** to successes.
- The validator is an `actor` and all mutation of validation state is isolated.

## Invariant 2: DNSSEC-protected name resolution for streaming hosts

- All `URLSession` instances created for contacting `*.lutheran.radio` hosts (media streaming via resource loader, proactive certificate HEAD checks, and cluster latency pings) are configured through ``SecurityConfiguration/makeSecureEphemeralConfiguration()`` (or the equivalent `applySecureNetworkingRequirements(to:)`).
- When ``SecurityConfiguration/requiresDNSSECValidationForStreaming`` is true (the default), `URLSessionConfiguration.requiresDNSSECValidation` is set. This causes the system resolver to be asked for DNSSEC-validated answers; unvalidated answers cause the session task to fail.
- DNSSEC validation failures at this layer are **transient** (see `StreamErrorType` classification and player recovery paths). This keeps the requirement "opt-in safe".
- This layer authenticates the mapping from hostname to IP address **before** TLS is attempted and before ``CertificateValidator`` sees any server trust object.
- The low-level `kDNSServiceFlagsValidate` + bit check in ``SecurityModelValidator`` remains the only place used for TXT record policy fetches; the two mechanisms are complementary.

## Invariant 3: Certificate Pinning (Runtime Full-Chain)

- Runtime certificate validation is performed exclusively by ``CertificateValidator``.
- The validator performs **full-certificate SHA-256 DER digest pinning** against ``SecurityConfiguration/pinnedFingerprintDigests`` (``CertificateFingerprint`` values).
- Comparison uses ``CertificateFingerprint/constantTimeMatches(_:)``; runtime code must not compare colon-hex strings.
- App Transport Security (ATS) SPKI pinning in `Info.plist` provides the baseline. The runtime validator adds a second, independent layer.
- ``SecurityConfiguration/pinnedLeafFingerprintDigest`` is the authoritative pin; ``pinnedLeafFingerprint`` and ``pinnedFingerprints`` are derived colon-hex views for operators and docs only. Never duplicate or override digest values elsewhere.
- Successful runtime pin results are cached for exactly ``SecurityConfiguration/certificateValidationCacheDuration`` (**10 minutes** / 600 s). This duration is **independent** of the DNS TXT model success cache (``modelCacheDuration`` = 1 hour). Call sites (including the streaming engine’s periodic HEAD timer) must read the configuration constant rather than hard-coding 600.

## Invariant 4: Transition Window & Time-Skew Protection

- A one-month transition window exists (currently 2026-07-27 00:00:00 GMT through 2026-08-26 23:59:59 GMT).
- During the window, a fingerprint mismatch is tolerated (falls back to ATS trust) **only if**:
  - `allowTransitionLeniency` remains `true`, **and**
  - Device time vs. HTTP `Date` header skew is ≤ 5 minutes (`maxAllowedTimeSkew`).
- Any detected time manipulation or window mismatch **permanently disables** leniency for the remainder of the process.
- Outside the window (before start or after end), fingerprint mismatches cause **hard failure** regardless of ATS result.

## Invariant 5: Configuration Centralization

All of the following values exist **only** inside ``SecurityConfiguration`` and are never hard-coded elsewhere:

- `expectedSecurityModel` ("dallas")
- `pinnedLeafFingerprintDigest` (authoritative 32-byte pin; ``CertificateFingerprint``)
- `pinnedFingerprintDigests` (acceptable digests for ``CertificateValidator``)
- `pinnedLeafFingerprint` / `pinnedFingerprints` (derived colon-hex; operator and README parity only)
- `transitionWindowStart` / `transitionWindowEnd`
- `maxAllowedTimeSkew`
- `modelCacheDuration` (DNS TXT success cache only — 1 hour)
- `certificateValidationCacheDuration` (runtime pin-result cache — 10 minutes; never reuse `modelCacheDuration`)
- Domain list (`securityModelDomains`)

## Invariant 6: No Bypass Paths

- There is no build-time or runtime flag that disables DNS TXT validation, certificate fingerprint checking, or time-skew detection.
- Debug/test seams (`_test_*` methods and `currentDate` injection) are compiled out of Release builds and have zero effect on production behavior.
- The `Core` module is linked into both the main app and the widget extension; both must obey the same rules.

## Enforcement

These invariants are primarily enforced by:

- ``SecurityConfiguration`` — constants and policy (including ``requiresDNSSECValidationForStreaming`` and the secure session factory)
- ``SecurityModelValidator`` — DNS TXT actor (its own `kDNSServiceFlagsValidate` path)
- ``CertificateFingerprint`` — digest type, hashing, constant-time equality
- ``CertificateValidator`` — runtime pinning actor
- `DirectStreamingPlayer` + `StreamingSessionDelegate` — consumption of secure configurations for the data plane (must not bypass the Core factory)

Any proposed change that touches these files, the DNS TXT record contents, the pinned digest(s), or the transition dates requires explicit security review.

## References

- ``<doc:Architecture>`` — How the three components interact
- README.md — "Security Model Validation", "Certificate Pinning", and "Why DNS TXT Records?" sections
- AGENTS.md / CODING_AGENT.md — Permanent rules for all contributors and AI agents

> Note: Changes that weaken any invariant above are treated as a security regression and are not accepted.
