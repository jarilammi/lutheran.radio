[![CodeQL](https://github.com/jarilammi/lutheran.radio/actions/workflows/codeql-analysis.yml/badge.svg)](https://github.com/jarilammi/lutheran.radio/actions/workflows/codeql-analysis.yml)

# Lutheran Radio

📱 [Available on the App Store](https://apps.apple.com/fi/app/lutheran-radio/id6738301787?l=fi)

Listen to Lutheran Radio on iOS.

Siri Shortcuts and voice control are supported out of the box ("Hey Siri, play Lutheran Radio", "Play Lutheran Radio in Finnish", "Pause Lutheran Radio", etc.). The shortcuts appear automatically in the Shortcuts app and Spotlight with zero configuration.

## Contents

- [Localizations](#localizations)
- [Local Development and Contributing](#local-development-and-contributing)
  - [AI Coding Instructions](#ai-coding-instructions)
  - [Agent Verification Commands](#agent-verification-commands)
  - [Prerequisites](#prerequisites)
  - [Swift Build Settings](#swift-build-settings)
  - [Troubleshooting](#troubleshooting)
- [Security Implementation](#security-implementation)
  - [Certificate Pinning](#certificate-pinning)
  - [Memory Safety (Compile-Time and Runtime)](#memory-safety-compile-time-and-runtime)
  - [Security Model Validation](#security-model-validation)
  - [Single Sources of Truth — Key Files Agents Must Know Intimately](#single-sources-of-truth--key-files-agents-must-know-intimately)
  - [Security Model History](#security-model-history)

## Localizations
<table style="border: none;">
<tr>
<td width="40%" style="border: none;">

The app is fully localized in the following languages:
- English (en)
- Danish (da)
- Dutch (nl)
- Estonian (et)
- Faroese (fo)
- Finnish (fi)
- Gagauz (gag)
- German (de)
- Icelandic (is)
- Kalaallisut (kl)
- Latvian (lv)
- Lithuanian (lt)
- North Sámi (se)
- Norwegian Bokmål (nb)
- Norwegian Nynorsk (nn)
- Polish (pl)
- Russian (ru)
- Slovak (sk)
- Spanish (es)
- Swedish (sv)
- Tornedalen Finnish (fit)

</td>
<td width="60%" style="border: none;">

![Geographic distribution of supported languages](docs/language-map.svg)

</td>
</tr>
</table>

## Local Development and Contributing

### AI Coding Instructions

All AI coding agents (Claude, Grok, Cursor, Aider, Windsurf, etc.) **must** follow [`CODING_AGENT.md`](CODING_AGENT.md) as their permanent system prompt / project instructions.

`CODING_AGENT.md` is the authoritative source. `AGENTS.md` is a local non-authoritative convenience copy (for tooling or environments that expect a file named `AGENTS.md` at the repository root). Permanent changes to rules, security policy, or build requirements must be made in `CODING_AGENT.md`; the copy may be refreshed from it as needed.

This ensures every single change respects the same required security model, localization rules, and build gates.

Grok users should also read [`GROK_TOOLS.md`](GROK_TOOLS.md). It documents the tools available to Grok and contains Lutheran Radio-specific examples and verification commands.

**Reading order for security work (mandatory for agents):**

When performing work that touches security, certificates, DNS validation, streaming URLs, the `Core/` framework, or this README's security sections, read in this exact order:

1. [`CODING_AGENT.md`](CODING_AGENT.md) (permanent rules, build gates, Documentation & Comment Standards, defensive Swift practices, single-source-of-truth principles)
2. `Core/Core.docc/Articles/Security-Invariants.md` (formal invariants — best read as built DocC in Xcode)
3. `Core/Core.docc/Articles/Architecture.md` (layered design and component responsibilities)
4. This README (operational details, live verification commands, Security Model History table, cache/transition behavior)

**Agent checklist before any security-related edit:**
- Run: `find . -name "CertificateFingerprint.swift" -o -name "CertificateValidator.swift" -o -name "SecurityConfiguration.swift" -o -name "SecurityModelValidator.swift" | head -5` and confirm every result is under `./Core/`.
- Re-confirm current values via `SecurityConfiguration.current` (never hard-code).
- Use exact symbols: `expectedSecurityModel`, `pinnedLeafFingerprintDigest`, `pinnedFingerprintDigests`, `isInTransitionWindow`, `pinnedLeafFingerprint`, `SecurityConfiguration.current`, `SecurityModelValidator`, `CertificateValidator`.
- After the change, the edited files (including docs) must be strictly more self-contained, with stronger "Why", explicit invariants, and cross-links than before.
- Run the clean build + test gates (see below) and include status in the PR.

See the "Documentation & Comment Standards for AI Coding Agents" section in `CODING_AGENT.md` — every edit must apply them (self-contained sections, "Why" over "what", `// SAFETY:` / `Security Invariant:` callouts, `- SeeAlso:`, consistent terminology).

### Agent Verification Commands

These commands are the minimum set agents (and humans) should run at the start of any session involving security, Core changes, or docs updates to this README. All blocks are copy-paste ready.

**1. Confirm you are reading the correct single source of truth (mandatory before any security edit):**

```bash
find . -name "CertificateFingerprint.swift" -o -name "CertificateValidator.swift" -o -name "SecurityConfiguration.swift" -o -name "SecurityModelValidator.swift" | head -5
```

Expected: All four results must be under `./Core/`. If not, stop and ask.

**2. Fetch current live security models (cross-check against snapshot and `expectedSecurityModel`):**

```bash
# Current active models (primary domain)
dig +short +dnssec TXT securitymodels.lutheran.radio

# Full response with DNSSEC details and RRSIG
dig +dnssec TXT securitymodels.lutheran.radio | grep -E "(^securitymodels|flags:|AD:|RRSIG)"
```

**3. Verify pinned certificate material (SPKI for ATS + leaf for runtime parity):**

```bash
# SPKI (matches Info.plist NSPinnedLeafIdentities)
openssl s_client -connect livestream.lutheran.radio:443 -servername livestream.lutheran.radio < /dev/null 2>/dev/null \
| openssl x509 -pubkey -noout \
| openssl pkey -pubin -inform pem -outform der \
| openssl dgst -sha256 -binary \
| base64

# Note: The authoritative runtime pin is the DER SHA-256 digest in SecurityConfiguration (see snapshot above). Colon-hex is for docs only.
```

**4. Run the mandatory build & test gates (execute sequentially; see CODING_AGENT.md for mechanical-work exceptions):**

First discover available simulators:
```bash
xcrun simctl list devices available
```

**Stable development (Xcode 26.6+, recommended for contributors and CI):**
```bash
# Clean build (stable reference)
xcodebuild -scheme "Lutheran Radio" \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17 Pro' clean build-for-testing
# Look for: ** TEST BUILD SUCCEEDED **

# Full test suite
xcodebuild -scheme "Lutheran Radio" \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17 Pro' test-without-building
# Look for: ** TEST SUCCEEDED **

# Fast path (Core / security / networking)
xcodebuild -scheme "Lutheran Radio" \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17 Pro' clean test -only-testing:CoreTests
# Look for: ** TEST EXECUTE SUCCEEDED **
```

Any iPhone 17-class device on iOS 26.5 or newer satisfies the gate on stable Xcode 26. The project minimum deployment target is iOS 26.2.

**Bleeding-edge (full EMTE/MIE and latest simulator testing):** Use Xcode 27+ with iOS 27 simulators. See the canonical commands in `CODING_AGENT.md`.

**5. (Optional but recommended for security work) Build DocC for the best invariants/architecture reading experience:**

```bash
# In Xcode: Product → Build Documentation, then search for "Core" or "Security-Invariants"
```

Cross-reference: "Current Security Snapshot" and "Single Sources of Truth — Key Files" tables above, the AI checklist, and the exact gates in [`CODING_AGENT.md`](CODING_AGENT.md).

### Prerequisites
 - Xcode 26.6+ (Swift 6.3 toolchain; language mode `SWIFT_VERSION = 6`) for stable development
 - Minimum deployment target: iOS 26.2 (required for EMTE + MIE hardened memory protections)
 - Recommended for most work and contributions: iPhone 17-class simulator on iOS 26.5 (stable Xcode 26)
 - For complete security feature validation (latest MIE/EMTE): Xcode 27+ with iOS 27 simulators (see CODING_AGENT.md)

### Swift Build Settings

All targets (main app, widget extension, `Core` framework, and test bundles) use the same Swift hardening flags:

| Setting                                           | Value      | Purpose                                              |
|---------------------------------------------------|------------|------------------------------------------------------|
| `SWIFT_VERSION`                                   | `6`        | Swift 6 language mode                                |
| `SWIFT_STRICT_CONCURRENCY`                        | `complete` | Full data-race checking                              |
| `SWIFT_APPROACHABLE_CONCURRENCY`                  | `NO`       | No relaxed concurrency downgrade                     |
| `SWIFT_STRICT_MEMORY_SAFETY`                      | `YES`      | SE-0458 strict memory-safety checking (compile-time) |
| `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` | `YES`      | Explicit import visibility                           |

Legacy Apple framework imports that still rely on `@preconcurrency` must be written as `@unsafe @preconcurrency import …` (currently `Security` in `Core` and streaming code, `AVFoundation` in the main app). This documents an existing concurrency boundary; it does not weaken runtime security.

Clean builds should produce **zero Swift compiler warnings**. If enabling a new checker surfaces warnings, fix or explicitly annotate them in the same PR — do not leave new warnings behind.

To ensure a smooth development experience, follow these steps before contributing:

First run `xcrun simctl list devices available` to confirm a suitable simulator.

**Stable path (Xcode 26):**
1. **Verify Project Build:** ```xcodebuild -scheme "Lutheran Radio" -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17 Pro' clean build```
   Ensure the output includes: **```** BUILD SUCCEEDED **```**

2. **Run Test Suite:** ```xcodebuild -scheme "Lutheran Radio" -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17 Pro' clean test```
   Check that the output includes: **```** TEST SUCCEEDED **```**

3. **Run Core Module Tests Only (Fast Path):** ```xcodebuild -scheme "Lutheran Radio" -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17 Pro' clean test -testPlan Core```
   Check that the output includes: **```** TEST SUCCEEDED **```**

Bleeding-edge verification (Xcode 27+) is documented in `CODING_AGENT.md`.

By verifying these steps on your local machine, you'll help maintain a consistent development environment for the project.

### Troubleshooting

If you encounter build or test issues, try these steps:

1. **Set Xcode Path:** If Xcode commands aren't found, run: ```sudo xcode-select -s /Applications/Xcode.app```
   List available simulators with: ```xcrun simctl list devices available```. Use an iPhone 17-class device on iOS 26.5 for stable development.

2. **Clean Build Folder**: ```xcodebuild clean```

3. **Clean Derived Data**: This removes all derived data for all projects, so use with caution: ```rm -rf ~/Library/Developer/Xcode/DerivedData/*```

After cleaning, retry the build and test steps above.

**Test runs that appear to hang (especially after manual simulator use)**

`xcodebuild test` (and sometimes the initial app launch under the test host) can appear completely stuck for many minutes. This is most often caused by expensive calls to ActivityKit's system services against stale Live Activities that were left on the simulator by a previous streaming session.

- Allow the test process sufficient time (often well beyond 5 minutes on first runs). The fixes in commit `10e0e46f` (cheap sanitization in test setUp, deferral of `observeExistingActivities`, `withTaskGroup`-bounded collection from live streams, and UITestMode short-circuits) were designed so waits are bounded and the expensive paths are avoided.
- Prematurely terminating and restarting the process frequently makes the *next* run slower because more stale state accumulates.
- See the full agent guidance in [`CODING_AGENT.md`](CODING_AGENT.md) (section "Test Execution Patience and Fast, Reliable Test Patterns") and the reference implementations in `SharedPlayerManagerEventTests.swift` (the `collectEvents` helper and setUp) plus `RadioLiveActivityManager.swift`.

# Security Implementation

> **For AI coding agents and security reviewers**  
> Read sources in this exact order before proposing or reviewing any change that touches security, DNS, certificates, streaming URLs, the `Core/` framework, or this README's security content (per [`CODING_AGENT.md`](CODING_AGENT.md)):
>
> 1. `CODING_AGENT.md` (permanent rules + Documentation & Comment Standards)
> 2. `Core/Core.docc/Articles/Security-Invariants.md` (formal invariants)
> 3. `Core/Core.docc/Articles/Architecture.md`
> 4. This README (operational details, verification commands, history table)
>
> **Security Invariant:** The `Core` framework (exactly three subdirectories) is the single source of truth for every security decision. No security logic, constants, or validation may be duplicated in the main app, widget, or tests (except narrow `#if DEBUG` test seams that are compiled out of Release). See the full table of invariants in ``<doc:Security-Invariants>``.

### Current Security Snapshot (Authoritative Values for Agents & Reviewers)

| Item                          | Value / Note                                                                                                                                                                                                 | Source (always use via `Core/`)                                                    |
|-------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------|
| `expectedSecurityModel`       | `"dallas"` (must be present in the live TXT for streaming to be allowed)                                                                                                                                    | `SecurityConfiguration.swift` (via `SecurityConfiguration.current`)                |
| Live active models (DNS TXT)  | `houston,starbase,fredericksburg,brenham,dallas`                                                                                                                                                             | `dig +short +dnssec TXT securitymodels.lutheran.radio` (primary + backup fallback) |
| Runtime leaf pin (authoritative) | `CertificateFingerprint` (raw 32-byte SHA-256 DER digest). Never compare hex strings at runtime.                                                                                                          | `pinnedLeafFingerprintDigest`                                                      |
| Operator/docs view of pin     | Colon-hex (uppercase): `CC:F7:8E:09:EF:F3:3D:9A:5D:8B:B0:5C:74:28:0D:F6:BE:14:1C:C4:47:F9:69:C2:90:2C:43:97:66:8B:3D:CC`                                                                                     | `pinnedLeafFingerprint` (derived)                                                  |
| Acceptable digests for validator | `pinnedFingerprintDigests` (list form; currently contains only the leaf)                                                                                                                                  | `SecurityConfiguration.current`                                                    |
| Transition window             | 2026-07-27 00:00:00 GMT through 2026-08-26 23:59:59 GMT (`isInTransitionWindow`)                                                                                                                             | `transitionWindowStart` / `transitionWindowEnd`                                    |
| Time-skew protection          | `maxAllowedTimeSkew = 300` seconds. Any device vs. server `Date` header skew > 5 min disables leniency even inside the window.                                                                               | `SecurityConfiguration`                                                            |
| Model validation cache        | 1 hour (3600 s), success-only, in `UserDefaults` (`modelCacheDuration`). Failures always re-query.                                                                                                           | `SecurityConfiguration` + `SecurityModelValidator`                                 |
| Certificate validation cache  | 10 minutes (in `CertificateValidator`)                                                                                                                                                                       | `Core/Security/CertificateValidator.swift`                                         |

**AGENT NOTE:** Obtain everything via `SecurityConfiguration.current`. Before editing any file listed in the "Single Sources of Truth" table below (or touching DNS TXT / certificate logic), re-run the `find` command from the AI checklist above and confirm results are inside `./Core/`. The dallas row in the history table is the current model (previous models are retained for the historical record and to prevent name reuse).

See also: ``<doc:Security-Invariants>``, ``<doc:Architecture>``, [`CODING_AGENT.md`](CODING_AGENT.md#documentation--comment-standards-for-ai-coding-agents) (Documentation Standards).

## Certificate Pinning

**Security Invariant:** Runtime full-certificate pinning is performed exclusively by `CertificateValidator` (in `Core/Security/`) against `SecurityConfiguration.pinnedFingerprintDigests` (via `pinnedLeafFingerprintDigest`). Comparison uses constant-time `CertificateFingerprint.constantTimeMatches`. ATS SPKI pinning in `Info.plist` provides the baseline; the runtime layer adds defense-in-depth. Colon-hex values are never used for runtime decisions.

The app implements certificate pinning to prevent man-in-the-middle (MITM) attacks. Key details:

1. **Domain:** ```lutheran.radio``` (including subdomains)
2. **Pinned Value (runtime):** SHA-256 digest of the leaf certificate DER (32 bytes), stored as ```CertificateFingerprint``` in ```Core/Configuration/SecurityConfiguration.swift``` as ```pinnedLeafFingerprintDigest```
3. **Pinned Value (operator / docs):** OpenSSL-style colon-hex (uppercase), derived from the digest — ```CC:F7:8E:09:EF:F3:3D:9A:5D:8B:B0:5C:74:28:0D:F6:BE:14:1C:C4:47:F9:69:C2:90:2C:43:97:66:8B:3D:CC```
4. **Location:** SPKI in ```Info.plist``` (```NSAppTransportSecurity > NSPinnedDomains```); runtime digest policy in ```SecurityConfiguration```; comparison in ```Core/Security/CertificateValidator.swift``` via ```Core/Security/CertificateFingerprint.swift```

See also: ``<doc:Security-Invariants>`` (Invariant 2), the "Current Security Snapshot" table, "Single Sources of Truth" table, and [`CODING_AGENT.md`](CODING_AGENT.md) (pinned fingerprint rules + never bypass full-certificate pinning).

### Dual Pinning Methods

For enhanced security, the app uses two complementary pinning approaches:

1. **SPKI Pinning (via Info.plist - Primary ATS Enforcement)**:
   - Pins the SHA-256 fingerprint of the certificate's public key (SPKI) in Base64 format.
   - Enforced by App Transport Security (ATS) for all connections to `lutheran.radio` (including subdomains).
   - Allows certificate rotations without app updates, as long as the public key remains consistent.
   - Current Pinned SPKI Fingerprints (from `Info.plist` under `NSAppTransportSecurity > NSPinnedDomains > lutheran.radio > NSPinnedLeafIdentities`):
     - `fwp4KADDyKqDa3qN5vy6UUJlffXBnjzrei3QTuYofYY=`
     - `XuAdGZ5Hy28pa2OHHMOry/fzpW8XyA5AV5bEDwSX2Ys=`
   - Verification: Use `openssl s_client -connect livestream.lutheran.radio:443 -servername livestream.lutheran.radio < /dev/null | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64` and match against these values.

2. **Full Certificate Fingerprint Pinning (via Core/Security/ - Runtime Validation)**:
   - Authoritative pin: ```SecurityConfiguration.pinnedLeafFingerprintDigest``` (32-byte ```CertificateFingerprint```).
   - ```CertificateValidator``` hashes the leaf DER with stack-local storage and compares digests using constant-time equality (no runtime hex string comparison).
   - Colon-hex views (```pinnedLeafFingerprint```, ```pinnedFingerprints```) exist for README, tests, and ```openssl``` parity only.
   - Performed at runtime with caching (10 minutes) and transition support; complements SPKI with exact DER matches, with ATS fallback during the transition period.

This dual approach provides defense-in-depth: SPKI handles baseline TLS security and rotations, while full pinning adds runtime enforcement. During the transition period (July 27–August 26, 2026), runtime validation allows pinning mismatches to the known alternate key (trusting ATS/SPKI) to prevent disruptions from certificate updates.

The app also detects potential device time manipulation by comparing the device time with the server's Date header during validation. If a significant discrepancy (beyond 5 minutes) is detected, or if the device is in the transition period but the server is not, transition leniency is disabled. This mitigates risks of exploiting the transition window through time manipulation, ensuring stricter enforcement when anomalies are present.

This check enhances security without additional dependencies, while protecting app users and preserving a seamless streaming experience under normal conditions.

See also: ``<doc:Security-Invariants>`` (Invariant 3 — Transition Window & Time-Skew Protection), `CertificateValidator`, and the snapshot table above.

### Certificate Renewal Strategy

To ensure uninterrupted service during SSL certificate renewals, the app includes a strategic transition system:

- **Transition Period:** One month before certificate expiry
- **User Experience:** During the transition period, the app trusts ATS validation if the pinned fingerprint fails, allowing streaming to continue with a debug warning (visible in DEBUG builds)
- **Security Protection:** Transition support is automatically enabled during the defined period, with strict enforcement of the pinned fingerprint outside this window
- **Implementation:** Controlled via `Core/Security/CertificateValidator.swift` with predefined transition start and expiry dates (exposed via `isInTransitionWindow` on `SecurityConfiguration.current`)

This approach prevents service disruption during certificate updates while maintaining security through continued ATS enforcement and time-bounded operation.

See also: the "Current Security Snapshot" (exact window dates) and ``<doc:Security-Invariants>``.

### Why SHA-256?

- Strong collision resistance
- Fast verification for frequent connections
- Suitable for public key pinning (not sensitive data)

### Verifying the Certificate Fingerprint

To check or update the pinned fingerprint:

```bash
openssl s_client -connect livestream.lutheran.radio:443 -servername livestream.lutheran.radio < /dev/null 2>/dev/null \
| openssl x509 -pubkey -noout \
| openssl pkey -pubin -inform pem -outform der \
| openssl dgst -sha256 -binary \
| base64
```

Match the output against the ```SPKI-SHA256-BASE64``` value in ```Info.plist```. Update if necessary.

## Memory Safety (Compile-Time and Runtime)

Defense-in-depth uses **two complementary layers**:

1. **Compile-time (Swift / Xcode)** — `SWIFT_STRICT_MEMORY_SAFETY = YES` on every target (SE-0458). The compiler flags unsafe memory operations, legacy `@preconcurrency` imports without `@unsafe`, and related patterns. Security-critical code in `Core/` uses explicit `unsafe { … }` only at C/Security framework boundaries (DNS-SD, `SecTrust`, hashing). Hot paths prefer `Span<UInt8>` / `UTF8Span` over `subdata` copies (DNS TXT rdata in `SecurityModelValidator` zero-copy borrows dns_sd `rdata` in the DNS-SD callback; DER hashing in `CertificateFingerprint` uses `Data.span`).

2. **Runtime (iOS hardware)** — Memory Integrity Enforcement (MIE), including the Enhanced Memory Tagging Extension (EMTE), on compatible devices (e.g., iPhone 17 and later with A19 or newer chips). Requires Xcode 26+ and iOS 26.2+ deployment. This mitigates memory corruption, use-after-free, and similar issues via tagged allocations, bounds checking, and pointer authentication at runtime.

These layers are independent: strict Swift checking hardens source before ship; MIE/EMTE hardens execution on supported hardware.

The app enables additional MIE options for stricter memory protections:
- `com.apple.security.hardened-process.checked-allocations.enable-pure-data = true`: Enforces pure data allocations to prevent executable code in data regions.
- `com.apple.security.hardened-process.checked-allocations.no-tagged-receive = true`: Disallows receipt of tagged pointers from untrusted sources, preserving tag integrity.

See also: [`CODING_AGENT.md`](CODING_AGENT.md) (Strict Memory Safety (SE-0458) + "Defensive Swift Practices" + force-unwrap rules), `docs/SAFETY_PATTERNS.tex` (authoritative safe Swift idioms and preferred alternatives to `!` / `as!`), and the "Single Sources of Truth" table (zero-copy patterns in `SecurityModelValidator` and `CertificateFingerprint`).

## Security Model Validation

**Security Invariant:** The app **must** successfully validate that its embedded `expectedSecurityModel` (from `SecurityConfiguration.current`) appears in the comma-separated TXT record returned by `securitymodels.lutheran.radio` (or the backup) **before any streaming is allowed**. Validation is performed exclusively by `SecurityModelValidator` (an actor). Permanent failure (model absent) disables streaming for the lifetime of the process. Successful validations are cached for exactly 1 hour (success-only).

The app performs security model validation to confirm that the version in use matches an approved security implementation before streaming content. This protects against compromised or obsolete app versions.

1. **Primary domain:** `securitymodels.lutheran.radio`
   **Backup domain:** `securitymodels.lutheranradio.sk` (smart fallback)
2. **Mechanism:** Queries DNS TXT records (via `DNSServiceQueryRecord` + `kDNSServiceFlagsValidate`) from the ordered list of domains. On success (**DNSSEC-validated response** *and* expected model present), caches result for 1 hour. Permanent failure (model absent from validated record) aborts immediately; transient errors (network, no validation bit, timeout) trigger fallback to the backup domain only.
3. **Pinned Value:** Defined in `Core/Configuration/SecurityConfiguration.swift` as `expectedSecurityModel` (currently `"dallas"`, always read via `SecurityConfiguration.current`)
4. **Location:** Enforced by the actor `Core/Actors/SecurityModelValidator.swift` (single source of truth for validation — see the Key Files table)
5. **Behavior:** If the app’s security model isn’t in the TXT record, playback is permanently disabled with a user-facing error message

See also: "Current Security Snapshot", "Agent Verification Commands", ``<doc:Security-Invariants>`` (Invariant 1), and [`CODING_AGENT.md`](CODING_AGENT.md) (Security Model + DNS TXT Validation Specifics).

### Why DNS TXT Records?

The app uses a DNS TXT record on `securitymodels.lutheran.radio` for lightweight, dynamic security model validation. This mechanism allows central updating of approved security models without requiring an immediate App Store update for every user.

**DNSSEC Protection**

The `lutheran.radio` zone, including the `securitymodels` subdomain, is protected by **DNSSEC with signed delegation**. The zone is properly signed (visible RRSIG records) and the chain of trust is established from the `.radio` TLD upward.

When queried with the DO (DNSSEC OK) bit set (e.g. `dig +dnssec`), the response includes:
- The TXT record containing the comma-separated list of valid models:
  `"houston,starbase,fredericksburg,brenham,dallas"`
- An accompanying **RRSIG** signature.

In the current observed responses, the **AD (Authenticated Data)** flag is **not** set (`;; flags: qr rd ra`), indicating that the recursive resolver did not perform (or did not assert) full DNSSEC validation when answering the query.

**Current Validation Behavior (DNSSEC-hardened)**

The app performs the TXT query via `DNSServiceQueryRecord` **with `kDNSServiceFlagsValidate`** (strict, not `ValidateOptional`). In the C reply callback:
- The echoed `flags` value is checked for the `kDNSServiceFlagsValidate` bit.
- Only responses where the bit is set (mDNSResponder/system resolver successfully performed DNSSEC validation) are accepted.
- If `DNSServiceQueryRecord` succeeds but the validation bit is absent, the query is treated as a transient failure: the backup domain is tried; if both fail validation, the validator enters `.failedTransient` (subject to retry + 1h cache bypass).

This provides data integrity and authenticity protection for the security model allow-list using the zone's existing DNSSEC signatures (RRSIG) and Apple's resolver, with zero new dependencies.

Unvalidated (or validation-failing) responses never result in a successful model list. Permanent failure only occurs when the expected model is provably absent from a validated response.

See also: ``<doc:Security-Invariants>`` (Invariant 1), [`CODING_AGENT.md`](CODING_AGENT.md) (DNS TXT Validation Specifics), and the implementation in `Core/Actors/SecurityModelValidator.swift`.

**DNSSEC for streaming host resolution (in addition to TXT)**

In addition to the hardened TXT lookup for the security model allow-list, the app requires DNSSEC-validated DNS answers for all actual streaming, certificate-probing, and server-selection traffic:

- Every `URLSession` that talks to `*.lutheran.radio` hosts (livestream, european, language-specific subdomains, etc.) is created from `SecurityConfiguration.makeSecureEphemeralConfiguration()`.
- This sets `URLSessionConfiguration.requiresDNSSECValidation = true` (session level).
- The actual media bytes, HEAD probes used by `CertificateValidator`, and latency pings therefore obtain authenticated name-to-IP mappings before TLS + full-certificate pinning.
- If the client's resolver cannot supply a validated answer, the request fails at the URLSession layer. These failures are classified as **transient** by `DirectStreamingPlayer.StreamErrorType` (allowing recreate + cluster fallback) so that the feature remains safe on networks where full DNSSEC validation is not yet available from the recursive resolver.

This gives three orthogonal DNS/TLS layers:
1. TXT allow-list (low-level dnssd + `kDNSServiceFlagsValidate`)
2. Streaming host resolution (URLSession + `requiresDNSSECValidation`)
3. Certificate (ATS SPKI + runtime DER pinning)

See ``<doc:Security-Invariants>`` (new Invariant 2) and `Core/Configuration/SecurityConfiguration.swift`.

**Verifying DNSSEC Status**
To check the current TXT record and DNSSEC-related information:

```bash
# Full response with flags and signatures
dig +dnssec TXT securitymodels.lutheran.radio | grep -E "(^securitymodels|flags:|AD:|RRSIG)"

# Short version (TXT + RRSIG)
dig +short +dnssec TXT securitymodels.lutheran.radio
```

Look for the **AD** flag (Authenticated Data) in the `;; flags:` line (useful diagnostic). For the app, success is determined by the `kDNSServiceFlagsValidate` bit returned to the `DNSServiceQueryRecord` callback (checked in `SecurityModelValidator.dnsQueryCallback`), not solely by the AD bit in `dig` output. The system resolver behavior controls whether the bit is set.

### Verifying the Security Model

To check the current valid security models:

```bash
dig +short +dnssec TXT securitymodels.lutheran.radio
```

Example output (captured live; always re-verify with `dig` before relying on it):

```
"houston,starbase,fredericksburg,brenham,dallas"
TXT 13 3 600 20260624194857 20260622174857 34505 lutheran.radio. C9XoaKK97ftWW9H86LM8+a3fEyBbNnQCh60q8BrvIeyCSVG8dTerIS1w ei0hZS/M5qB9YEBfqLWFMMR6TTT4Ng==
```

Compare this output to ```expectedSecurityModel``` in ```Core/Configuration/SecurityConfiguration.swift``` (currently ```dallas```, obtained via `SecurityConfiguration.current`). If the app’s model isn’t listed, validation fails permanently. To update the list, modify the TXT record for ```securitymodels.lutheran.radio``` through the DNS management interface for the ```lutheran.radio``` domain.

See also: ``<doc:Security-Invariants>`` (Invariant 1), [`CODING_AGENT.md`](CODING_AGENT.md) (Security Model rules).

### Security Model Validation Cache

To improve resilience against transient DNS failures (e.g., network instability or temporary outages), the app implements a 1-hour persistent cache for successful security model validations. This cache is stored securely in `UserDefaults` and only applies to successful checks, ensuring the app can skip redundant DNS queries during short disruptions without compromising security.

#### Key Details:
- **Duration:** 1 hour (3600 seconds) from the last successful validation.
- **Storage:** A non-sensitive timestamp (`Date`) is stored in `UserDefaults` under the key `"lastSecurityValidation"`. No actual security models or TXT records are cached.
- **Behavior:**
  - On app launch or validation trigger: If a valid cache exists (timestamp within 1 hour), the app assumes success and proceeds with streaming.
  - Cache is only updated on successful DNS fetches (i.e., when `SecurityConfiguration.expectedSecurityModel` appears in the TXT record).
  - Failures are **not** cached—full validation (DNS query) is always performed on failure, with permanent disablement if the model is invalid.
  - Time handling uses an injectable `currentDate()` closure for testability and consistency.
- **Security Considerations:**
  - The cache provides a short window during which a previously successful validation remains valid. If the DNS TXT record changes, devices with a recent cache may continue for up to 1 hour. This supports availability in low-connectivity scenarios.
  - Mitigates risks like time manipulation (complements existing device/server time skew detection in certificate validation).
  - No new attack surfaces: `UserDefaults` is app-sandboxed; tampering requires device compromise.

#### Verifying the Cache
For debugging (e.g., in Xcode Console during development):
- Successful cache hit: Logs `"🔒 [Security] Using cached validation (last: [timestamp])"` (DEBUG builds only).
- Cache update: Logs `"🔒 [Security] Cached new successful validation"` on success.

To manually inspect or clear the cache:
- Use `UserDefaults.standard.object(forKey: "lastSecurityValidation") as? Date` in code or via debugger.
- Clear via app deletion/reinstall or `UserDefaults.standard.removeObject(forKey: "lastSecurityValidation")`.

This feature enhances availability while maintaining the app's privacy-first principles, reducing unnecessary network calls.

### Single Sources of Truth — Key Files Agents Must Know Intimately

**Security Invariant:** All security-critical constants, policy, and validation logic live **only** inside the `Core/` framework (exactly three subdirectories). `DirectStreamingPlayer.swift` and other consumers must obtain values exclusively through the public surface of `SecurityConfiguration.current`, `SecurityModelValidator`, and `CertificateValidator`. Duplication of policy or validation outside `Core/` is forbidden and will not pass security review.

| File / Symbol                                              | Responsibility                                                                 | Important notes for agents |
|------------------------------------------------------------|--------------------------------------------------------------------------------|----------------------------|
| `Core/Configuration/SecurityConfiguration.swift`           | Single source of truth for all policy and constants (`expectedSecurityModel`, `pinnedLeafFingerprintDigest`, `pinnedFingerprintDigests`, `isInTransitionWindow`, `transitionWindow*`, `maxAllowedTimeSkew`, `modelCacheDuration`, `securityModelDomains`, `requiresDNSSECValidationForStreaming`, `makeSecureEphemeralConfiguration`, `current`) | Never duplicate these values elsewhere. Colon-hex views (`pinnedLeafFingerprint`, `pinnedFingerprints`) are for README/openssl parity only. The secure session factory is the central point for `requiresDNSSECValidation` + cache hardening on streaming sessions. |
| `Core/Actors/SecurityModelValidator.swift`                 | Actor-isolated DNS TXT security model validation against `securitymodels.lutheran.radio` (and backup) | Uses `kDNSServiceFlagsValidate` + explicit callback bit check for DNSSEC (strict). `Span<UInt8>` / `UTF8Span` zero-copy rdata borrow in `dns_sd` callback. 1-hour success-only cache. Permanent vs. transient failures. Entry point: `validateSecurityModel()`. The **only** place DNS TXT logic is allowed. |
| `Core/Security/CertificateFingerprint.swift`               | 32-byte SHA-256 DER digest type + stack-local hashing via `Data.span` + constant-time `constantTimeMatches` | Runtime code must never compare hex strings. Materializes colon-hex only for docs/tooling. |
| `Core/Security/CertificateValidator.swift`                 | Runtime full-certificate (DER) pinning + 10-minute cache + transition window + device/server time-skew protection | Complements (does not replace) ATS SPKI pinning from `Info.plist`. Uses `pinnedFingerprintDigests`. Time skew > 5 min permanently disables leniency for the process. |
| `DirectStreamingPlayer.swift` (and streaming delegates)    | Main audio engine; embeds security model in stream URLs; consumes validators; creates resource-loader sessions via the Core secure factory | Consumes the Core single sources of truth (including DNSSEC-enabled sessions). No policy duplication. Error classification treats DNSSEC-unavailable cases as transient. |

**Core Framework Surface Area (mandatory rule):** Any new security logic, certificate handling, or validation must be added inside `Core/` under the appropriate subdirectory (`Configuration/`, `Actors/`, or `Security/`) and exposed through the existing public types. Duplication in the main app, `LutheranRadioWidget/`, or elsewhere is not permitted.

The authoritative security invariants and architecture are documented in the `Core` framework's DocC catalog (preferred reading experience: build DocC in Xcode via Product → Build Documentation, or search "Core" in the Developer Documentation window).

Source articles (also on GitHub):
- [Security Invariants](https://github.com/jarilammi/lutheran.radio/blob/HEAD/Core/Core.docc/Articles/Security-Invariants.md)
- [Architecture](https://github.com/jarilammi/lutheran.radio/blob/HEAD/Core/Core.docc/Articles/Architecture.md)

See also: the "Current Security Snapshot" table above, [`CODING_AGENT.md`](CODING_AGENT.md) (Key Files table + Core Framework Surface Area rule + "before writing any code..." checklist), ``<doc:Security-Invariants>``, ``<doc:Architecture>``.

**Non-security cross-target shared sources (app + widget)**

A small number of files under `Lutheran Radio/` are compiled into both the main app and `LutheranRadioWidgetExtension` (via File System Synchronized Group membership exceptions, no separate framework). These implement widget / Live Activity state and the player event vocabulary:

- `SharedPlayerManager.swift` (actor + `PersistedWidgetState` + authoritative `PlayerEvent` emission)
- `PlayerVisualState.swift` (`PlayerEvent`, `PlayerCurrentState`, `PlaybackIntent`, `PlayerVisualState`)
- `WidgetRefreshManager.swift`, `WidgetEventObserver.swift`, `StreamProgramMetadata.swift`, `LutheranRadioLiveActivityAttributes.swift`

Each carries an explicit "SHARED" header block listing the invariants and pointing back here and to `CODING_AGENT.md`. New non-security shared logic should be added to one of these (or documented here) rather than duplicated. Security items stay in `Core/`.

**Event-driven player state (outside `Core/`)**

Player-domain transitions are expressed through typed `PlayerEvent` notifications. Security actors (`SecurityModelValidator`, `CertificateValidator`) remain deliberately excluded from this surface. The vocabulary and replay snapshot type live in `PlayerVisualState.swift`; emission and mutation live in `SharedPlayerManager`.

| File / Symbol | Responsibility | Important notes for agents |
|---------------|----------------|----------------------------|
| `PlayerVisualState.swift` — `PlayerEvent` | Canonical player-domain event vocabulary (`playbackIntentChanged`, `visualStateDidChange`, `streamDidStart` / `Pause` / `Stop` / `Fail`, `metadataDidUpdate`, `persistedWidgetStateDidUpdate`) | Pure `Sendable` enum; no side effects. Do not add certificate, DNS, or security-model cases. |
| `PlayerVisualState.swift` — `PlayerCurrentState` | Replay snapshot for late subscribers (`visualState`, `playbackIntent`, `streamMetadata`, `hasError`) | Convenience accessors: `isActivelyPlaying`, `isBlockedByStickyIntent`, `isInPermanentError`. No synthesized `streamDid*` verbs in replay prefix. |
| `SharedPlayerManager` — `emit(_:)` | Central emission point after in-actor state mutations | Main-app process only (`isRunningInWidgetProcess` guard suppresses yields). Emission is strictly additive; imperative mutation paths remain primary. |
| `SharedPlayerManager` — `events` | Live `AsyncStream<PlayerEvent>` | Delivers events after subscription only. Widget extensions cannot observe this stream. |
| `SharedPlayerManager` — `currentState` | Authoritative present-state snapshot | Read at observation start; use with `makeEventsStreamWithReplay()` for late subscribers. |
| `SharedPlayerManager` — `makeEventsStreamWithReplay()` | Per-subscriber stream: four synthesized prefix events from `currentState`, then live forward | Materializes the shared live stream while actor-isolated and yields before return so forwarding iterators attach before callers drive mutations. |
| `SharedPlayerManager` — `PersistedWidgetState` / `loadPersistedWidgetState()` / `savePersistedWidgetState()` | In-process session snapshot for widget refresh derivation | Memory-only within a runtime; cold launch resets to factory `.prePlay` via `resetToFactoryDefaultsOnLaunch()`. Cross-process widget timelines read snapshots, not `events`. |
| `SharedPlayerManager` — `currentPlaybackIntent` / `PlaybackIntent` | Authoritative playback intent decisions | Sticky pause/lock semantics; stream-failure paths preserve intent for auto-resume. |
| `WidgetRefreshManager` — `handlePlayerEvent` | Tier 2 consumer: derives refresh parameters from carried events or persisted SSOT | Routes through existing `refreshIfNeeded(visualState:currentLanguage:hasError:immediate:)`; privacy gate, teardown gate, debouncing, and coalescing unchanged. |
| `WidgetEventObserver` | Shared observation helper for `PlayerEvent` streams and Live Activity `contentUpdates` | Cancel-before-start task lifetime; used by `WidgetRefreshManager` and `RadioLiveActivityManager`. |
| `PlayerEventSubscriber` (`RadioPlayerView`) | UI-only consumer of `makeEventsStreamWithReplay()` | Local observable state (`eventCount`, `lastObservedIntent`); does not replace `@Bindable` view model bindings. |

**Non-forcing rule:** Event emission and observation are additive. Direct calls (`setPlaying()`, `stop()`, snapshot writes, `refreshIfNeeded`, widget optimistic `forcePersistVisualState`) remain the primary mechanism. Nothing is removed from imperative paths until the event path proves reliable on device. Widget extension processes perform optimistic snapshot writes for instant feedback but never originate authoritative `PlayerEvent` yields.

Canonical architecture detail: ``<doc:Architecture>`` ("Event-Driven Player Architecture (Outside `Core/`)"). Backlog and protected test contracts: [`docs/Event-Driven-Refactor-Roadmap.md`](docs/Event-Driven-Refactor-Roadmap.md). Widget/Live Activity presentation flow: [`docs/Widget-Presentation-Dataflow.md`](docs/Widget-Presentation-Dataflow.md). Canonical test files: `Lutheran RadioTests/SharedPlayerManagerEventTests.swift`, `WidgetRefreshManagerEventTests.swift`, `PlayerEventSubscriberEventTests.swift`, `WidgetEventObserverTests.swift`.

**Widget & Live Activity presentation surfaces**

Home widgets (via `SimpleEntry`) and Live Activities (via `ContentState`) consume three narrow, pre-derived presentation value types:

- `PlayerStatusPresentation` (status indicator)
- `PlayerControlPresentation` (play/pause control)
- `WidgetNowPlayingDisplayModel` (program title + speaker + emphasis)

Derivation happens once in the WidgetKit `Provider` (for `SimpleEntry`) or once at the top of Live Activity view bodies / outer Dynamic Island closures. Leaf views and region builders read only the narrow slices.

See [docs/Widget-Presentation-Dataflow.md](docs/Widget-Presentation-Dataflow.md) for the snapshot-driven pattern, rationale, terminology, and contributor guidance. The same surfaces are used by the Control widget and the main player UI.

`DirectStreamingPlayer.swift` and `Core/Security/CertificateValidator.swift` now consume these shared components instead of duplicating logic. The prior refactor improved maintainability/testability while enforcing Swift 6 strict concurrency + `SWIFT_STRICT_MEMORY_SAFETY = YES` on all targets and preserving identical runtime behavior and security guarantees.

### Security Model TXT Record Usage

Lutheran Radio's security system uses a DNS TXT record to ensure only trusted app versions can stream content. The longest practical TXT record length for this purpose is about 450 bytes, which fits within standard DNS limits and supports up to 40-50 security model names (like "landvetter" or "nuuk"). This is more than enough for the current 47-byte record. If you need to use more names in the future, check that your DNS supports larger messages (EDNS0) and test the app to confirm it can handle them. Keep an eye on how your DNS behaves to ensure everything works smoothly, keeping the app secure and reliable for all users.

### Security Model History

This table is the source of truth for the historical record of security models (per [`CODING_AGENT.md`](CODING_AGENT.md)). 

**Security Invariant:** Each security model name must be unique and never reused. Reusing a prior name could allow an obsolete app version to pass DNS TXT validation. Live active models are determined solely by the current DNS TXT record (see "Current Security Snapshot" and verification commands above). The table below records introduction and deprecation for auditing and safe name selection.

| Security Model Name | Valid From         | Valid Until        | App Version Introduced |
|---------------------|--------------------|--------------------|------------------------|
| `turku`             | April 8, 2025      | April 20, 2025     | 1.0.4                  |
| `mariehamn`         | April 15, 2025     | July 26, 2025      | 1.0.7                  |
| `visby`             | May 26, 2025       | July 26, 2025      | 1.1.1                  |
| `landvetter`        | June 1, 2025       | July 26, 2025      | 1.1.2                  |
| `nuuk`              | June 15, 2025      | July 26, 2025      | 1.2.1                  |
| `stjohns`           | July 22, 2025      | August 20, 2025    | 1.2.3                  |
| `dc`                | July 27, 2025      | April 18, 2026     | 1.2.4                  |
| `florida`           | August 24, 2025    | April 18, 2026     | 1.2.7                  |
| `tampa`             | August 31, 2025    | April 18, 2026     | 1.2.8                  |
| `atlanta`           | October 6, 2025    | April 18, 2026     | 26.0.1                 |
| `birmingham`        | November 9, 2025   | April 18, 2026     | 26.0.2                 |
| `houston`           | March 3, 2026      | (ongoing)          | 26.3.0                 |
| `starbase`          | May 18, 2026       | (ongoing)          | 26.5.0                 |
| `fredericksburg`    | June 2, 2026       | (ongoing)          | 26.5.1                 |
| `brenham`           | June 23, 2026      | (ongoing)          | 26.5.2                 |
| `dallas`            | (pending)          | (pending)          | 26.6.0                 |

**Notes:**
- **Valid From:** The date when the security model was first published to the App Store.
- **Valid Until:** The date when the security model was deprecated (or "(ongoing)" if still active).
- **App Version Introduced:** The app version where this security model was first implemented.
- **Valid From Dates:** Reflect the App Store publication date for the app version introducing the security model, ensuring alignment with public availability.
- Cross-check live TXT (via the Agent Verification Commands) for the set of currently active models. This table is the historical source of truth.

When introducing a new security model (requires security review + documentation upgrade):

1. Choose a unique name not listed in the table (e.g., a distinct city or codename). Confirm it has never been used.
2. Update `expectedSecurityModel` in `Core/Configuration/SecurityConfiguration.swift` (the only allowed location).
3. Add the new name to the DNS TXT record for `securitymodels.lutheran.radio` (primary) and ensure the backup is consistent.
4. Append a new row to the table above with the current date, app version, and name.
5. Update the "Current Security Snapshot" and any live example outputs in this README.
6. Improve surrounding documentation per the Documentation & Comment Standards in [`CODING_AGENT.md`](CODING_AGENT.md) (add "Why", Security Invariant callouts, cross-links to ``<doc:Security-Invariants>`` and the Architecture article, update agent checklist context if needed).
7. Run the mandatory find command + build/test gates. Include security impact assessment in the PR.

See also: ``<doc:Security-Invariants>`` (Invariant 1 and "Enforcement"), "Verifying the Security Model" section above, [`CODING_AGENT.md`](CODING_AGENT.md) (Security Model rules + "Current model = dallas" + response style requirements).

### Why Track Security Model Names?

Security model names (e.g., ```dallas```) are embedded in the app and validated against the DNS TXT record before any streaming is permitted. Once a name is used, it becomes part of the app's permanent history and may still exist in older App Store versions. Reusing a name could allow an older version to pass validation in some cases.

**Why this matters (explicit invariant):** The DNS TXT mechanism plus the history table together provide a forward-only, collision-resistant way to rotate the approved security implementation without breaking the "no bypass" rule or requiring clients to trust arbitrary future names.

By maintaining this table we ensure that:

- New security model names are unique and avoid collisions with past names.
- The complete history of security models is transparent for debugging, auditing, and security reviews.
- Contributors and agents can easily pick a fresh name (e.g., a unique city, codename, or identifier) when implementing a new security model.
- Future agents reading this file have the full context required by the layered permanent sources order in `CODING_AGENT.md`.

Every change that touches this section must leave the file strictly more usable for the next agent (better self-contained reasoning, explicit links, and up-to-date verification commands).
