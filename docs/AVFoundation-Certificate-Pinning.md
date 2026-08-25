# SSL Certificate Pinning with iOS AVFoundation

## Overview

Lutheran Radio streams over HTTPS using AVFoundation (`DirectStreamingPlayer`). Runtime full-certificate pinning lives in `Core/`, not in the player. App Transport Security (ATS) SPKI pinning in `Info.plist` is the TLS baseline; `CertificateValidator` adds an independent DER digest check.

Minimum deployment is iOS 26.2. Agents validate on Xcode 27 / iOS 27 simulators.

Do not duplicate pin values outside `SecurityConfiguration`. Do not keep retired pre-cutover leaves on the acceptance list.

## Two complementary layers

### 1. ATS SPKI pinning (`Info.plist`)

- Enforced by App Transport Security for every apex under `NSAppTransportSecurity > NSPinnedDomains` (subdomains included when `NSIncludesSubdomains` is true).
- Sole media apex: `siikkari.net` (covers `european.siikkari.net`, `livestream.siikkari.net`, language hosts).
- Current SPKI-SHA256-BASE64: `7J4okayjKUOwgtAfSzN/iLvm/cUyoajGABocw7CkRWE=`

Verify (copy-paste):

```bash
openssl s_client -connect livestream.siikkari.net:443 -servername livestream.siikkari.net < /dev/null 2>/dev/null \
  | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64
```

Expected: `7J4okayjKUOwgtAfSzN/iLvm/cUyoajGABocw7CkRWE=`

### 2. Runtime full-certificate DER pinning (`CertificateValidator`)

- Authoritative acceptance list: `SecurityConfiguration.pinnedFingerprintDigests` (array of 32-byte `CertificateFingerprint` values).
- Sole production leaf: live `*.siikkari.net` via `pinnedLeafFingerprintDigest` / `pinnedSiikkariLeafFingerprintDigest` (alias).
- Colon-hex (operator / docs only; never compared at runtime):
  `32:82:5E:97:8C:F7:1F:F1:0C:F6:80:9D:2D:15:C8:1D:AA:85:65:28:F4:67:D6:E5:1B:6F:7A:5F:B2:18:70:CD`
- Comparison: `CertificateFingerprint.constantTimeMatches` (constant-time). Colon-hex strings are never used for runtime decisions.
- Success cache: `certificateValidationCacheDuration` (10 minutes). Independent of DNS TXT `modelCacheDuration` (1 hour).
- Call sites: `StreamingSessionDelegate` (per-request trust) and `DirectStreamingPlayer` (initial + periodic HEAD revalidation using the same cache duration).

Verify leaf DER SHA-256 (copy-paste):

```bash
openssl s_client -connect livestream.siikkari.net:443 -servername livestream.siikkari.net < /dev/null 2>/dev/null \
  | openssl x509 -outform DER | openssl dgst -sha256
```

Match against `pinnedSiikkariLeafFingerprintDigest` / `pinnedFingerprintDigests` in `SecurityConfiguration` (openssl prints lowercase hex without colons).

## Transition window and time skew

Authoritative dates: `SecurityConfiguration.transitionWindowStart` / `transitionWindowEnd`.

- Window: **2027-01-01 00:00:00 GMT** through **2027-02-10 23:59:59 GMT**.
- End aligns with live `*.siikkari.net` leaf `notAfter` on `livestream.siikkari.net`; start is a deliberate calendar lead-in.
- During the window, if the runtime pin list rejects the leaf, the validator may still trust ATS evaluation **only when** `allowTransitionLeniency` remains true **and** device vs HTTP `Date` skew is ≤ 5 minutes (`maxAllowedTimeSkew`).
- Any detected time manipulation or window mismatch permanently disables leniency for the remainder of the process.
- Outside the window, fingerprint mismatches are hard failures regardless of ATS.

Review and update the window on each leaf rotation via app release.

## Stream control

- Initial runtime validation runs before playback.
- Periodic HEAD checks reuse `certificateValidationCacheDuration`. Outside the transition window, a pin failure stops the stream and notifies via `onStatusChange`. Transient connection issues (server reboot, DNSSEC name-resolution failure) remain classified as non-security errors with recovery / alternate-server fallback.
- Streaming hosts use `preferredStreamingDomainSuffixes` (`siikkari.net` only). Media apex and DNS TXT hosts (`securityModelDomains`) are independent lists.

## What this is not

- There is no `currentCertHash` string. Runtime pins are `CertificateFingerprint` digests in `pinnedFingerprintDigests`.
- SPKI pinning is ATS-only in `Info.plist`. Do not reimplement SPKI comparison in Swift.
- Retired pre-cutover leaves (for example former `CC:F7:…:3D:CC`) are **not** on the acceptance list. Obsolete pins enlarge the set of certificates the runtime will accept.

## Earlier approach (historical)

Per-request SPKI and certificate-hash pinning inside `StreamingSessionDelegate` was overly restrictive, carried complex custom transition logic, and used custom URL-scheme workarounds. That path was replaced by centralized `CertificateValidator` plus ATS SPKI.

## See also

- ``<doc:Security-Invariants>`` (Invariants 2–4)
- ``<doc:Architecture>``
- `Core/Configuration/SecurityConfiguration.swift`
- `Core/Security/CertificateValidator.swift`
- `Core/Security/CertificateFingerprint.swift`
- README.md “Current Security Snapshot”, “Certificate Pinning”, “Media Apex Cutover”
- `CODING_AGENT.md` (never bypass full-certificate fingerprint pinning; never weaken Info.plist SPKI)
