# Architecture

@Metadata {
    @TechnologyRoot
}

The `Core` framework isolates all security policy and validation logic into a small, auditable module. This separation is intentional and mandatory.

## Layered Design

The framework is deliberately split into three subdirectories, each with a single responsibility:

| Layer                        | Location                        | Responsibility                                      | Concurrency Model      |
|-----------------------------|---------------------------------|-----------------------------------------------------|------------------------|
| **Configuration**           | `Core/Configuration/`           | Single source of truth for all constants and policy | Plain struct           |
| **Actors**                  | `Core/Actors/`                  | DNS TXT security model validation                   | `actor` (strict isolation) |
| **Security**                | `Core/Security/`                | Runtime full-certificate fingerprint pinning        | `actor` + URLSession delegate |

### Why This Split?

- **Configuration** owns every magic number, date, fingerprint, and domain. No other file is allowed to contain these values.
- **Actors** provide the strong isolation guarantees required for security state machines that must not race.
- **Security** owns the complex, stateful certificate validation logic (caching, time-skew detection, transition leniency) while remaining fully testable.

This design makes security review, testing, and future rotation of certificates or models straightforward and localized.

## Key Components

### SecurityConfiguration

A plain `struct` (value type) that exposes only the minimal public surface required by consumers:

- `expectedSecurityModel`
- `pinnedLeafFingerprintDigest` / `pinnedFingerprintDigests` (authoritative runtime pins)
- `pinnedLeafFingerprint` / `pinnedFingerprints` (derived colon-hex)
- `isInTransitionWindow`
- `requiresDNSSECValidationForStreaming` + `makeSecureEphemeralConfiguration()` / `applySecureNetworkingRequirements(to:)` (the single place that turns on `URLSessionConfiguration.requiresDNSSECValidation` and related hardening for streaming hosts)
- `current` (the canonical instance)

All other properties are internal by design. The struct is deliberately not an actor because it contains only immutable policy after initialization.

Callers outside Core (DirectStreamingPlayer, CertificateValidator) obtain secure `URLSessionConfiguration` values exclusively through these APIs. This is the "one place to configure secure networking".

### SecurityModelValidator

An `actor` that:

- Performs DNS-SD TXT queries with `kDNSServiceFlagsValidate` against the configured domains.
- In the C callback: requires the validation bit before accepting any rdata (DNSSEC hardening); parses length-prefixed TXT rdata with `Span<UInt8>` and `UTF8Span` (zero-copy borrow of dns_sd `rdata`).
- Implements a one-hour success-only cache persisted in `UserDefaults`.
- Distinguishes **permanent** failures (model not in *validated* TXT → streaming must stay disabled) from **transient** failures (network/DNS/DNSSEC-unvalidated → safe to retry).
- Exposes a tiny set of test seams under `#if DEBUG` that have zero production impact.

The actor uses a carefully constructed non-isolated static C callback + `Unmanaged` context to satisfy Swift 6 strict concurrency while still using the classic `dnssd` API.

### CertificateFingerprint

A `Sendable` value type that:

- Holds the raw 32-byte SHA-256 digest of a certificate DER encoding.
- Computes digests via stack-local storage and `Data.span` (see `sha256DERDigest(of:)`).
- Exposes constant-time equality for runtime pinning (`constantTimeMatches`) via borrowed `Span<UInt8>` views (tuple → `withUnsafeBytes` boundary only).
- Materializes OpenSSL-style colon-hex only for documentation and operator tooling.

### CertificateValidator

An `actor` that:

- Implements `URLSessionTaskDelegate` for modern async challenge handling.
- Performs full SHA-256 DER leaf certificate digest validation against ``SecurityConfiguration/pinnedFingerprintDigests``.
- Maintains a 10-minute validation cache.
- Implements the transition window + device/server time-skew protection logic.
- Can be driven either via `validateServerTrust(_:)` (during live challenges) or `validateServerCertificate(for:)` (periodic HEAD checks).

## Integration Points

- `DirectStreamingPlayer` calls both validators and embeds the security model in stream URLs.
- `StreamingSessionDelegate` (or equivalent) uses `CertificateValidator` for per-task challenges.
- The widget extension links the same `Core` module and is subject to identical rules.

## Testing Strategy

- Production code paths contain **zero** test-only logic.
- All test seams are guarded by `#if DEBUG` and are compiled out of Release builds.
- `SecurityModelValidator` and `CertificateValidator` both accept injectable time providers in DEBUG builds.
- The TXT record parser is exposed via a static `_test_` method so that parsing logic can be exercised without network or DNS.

## Documentation & Invariants

All security invariants are documented in ``<doc:Security-Invariants>``. This article is the authoritative reference and is linked from both the source code and the project README.

High-level operational details (DNSSEC status, certificate rotation procedures, cache behavior) live in the main `README.md` under the "Security Model Validation" and "Certificate Pinning" sections.

## Future Evolution

Any new security mechanism (additional pinning layers, OCSP, certificate transparency, stricter DNS requirements, etc.) must be added inside the appropriate subdirectory of `Core/` and exposed through the existing public types. Duplication outside `Core` is not permitted.

The DNSSEC requirement for streaming (`requiresDNSSECValidationForStreaming`) is deliberately centralised here so that future changes (e.g. combining with swift-async-dns-resolver, adding AVAssetResourceLoaderDelegate custom-scheme protection for segmented media, or exposing a diagnostic flag) have exactly one place to update.

## See Also

- ``<doc:Security-Invariants>``
- ``SecurityConfiguration``
- ``SecurityModelValidator``
- ``CertificateFingerprint``
- ``CertificateValidator``
