[![CodeQL](https://github.com/jarilammi/lutheran.radio/actions/workflows/codeql-analysis.yml/badge.svg)](https://github.com/jarilammi/lutheran.radio/actions/workflows/codeql-analysis.yml)

# Lutheran Radio

📱 [Available on the App Store](https://apps.apple.com/fi/app/lutheran-radio/id6738301787?l=fi)

Listen to Lutheran Radio on iOS.

Siri Shortcuts and voice control are supported out of the box ("Hey Siri, play Lutheran Radio", "Play Lutheran Radio in Finnish", "Pause Lutheran Radio", etc.). The shortcuts appear automatically in the Shortcuts app and Spotlight with zero configuration.

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

### Prerequisites
 - Xcode 26+ (Swift 6.3 toolchain; language mode `SWIFT_VERSION = 6`)
 - Minimum deployment target: iOS 26.2 (required for EMTE + MIE hardened memory protections)
 - Recommended local/CI test environment: iOS 26.5 simulator (iPhone 17) — used in the xcodebuild commands below

### Swift Build Settings

All targets (main app, widget extension, `Core` framework, and test bundles) use the same Swift hardening flags:

| Setting | Value | Purpose |
|---------|-------|---------|
| `SWIFT_VERSION` | `6` | Swift 6 language mode |
| `SWIFT_STRICT_CONCURRENCY` | `complete` | Full data-race checking |
| `SWIFT_APPROACHABLE_CONCURRENCY` | `NO` | No relaxed concurrency downgrade |
| `SWIFT_STRICT_MEMORY_SAFETY` | `YES` | SE-0458 strict memory-safety checking (compile-time) |
| `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` | `YES` | Explicit import visibility |

Legacy Apple framework imports that still rely on `@preconcurrency` must be written as `@unsafe @preconcurrency import …` (currently `Security` in `Core` and streaming code, `AVFoundation` in the main app). This documents an existing concurrency boundary; it does not weaken runtime security.

Clean builds should produce **zero Swift compiler warnings**. If enabling a new checker surfaces warnings, fix or explicitly annotate them in the same PR — do not leave new warnings behind.

To ensure a smooth development experience, follow these steps before contributing:

1. **Verify Project Build:** Confirm the project builds successfully with: ```xcodebuild -scheme "Lutheran Radio" -sdk iphonesimulator26.5 -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17' clean build```
   Ensure the output includes: **```** BUILD SUCCEEDED **```**

2. **Run Test Suite:** Validate the test suite passes with: ```xcodebuild -scheme "Lutheran Radio" -sdk iphonesimulator26.5 -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17' clean test```
   Check that the output includes: **```** TEST SUCCEEDED **```**

3. **Run Core Module Tests Only (Fast Path):** When working on security, networking, or the Core framework, use this much faster command: ```xcodebuild -scheme "Lutheran Radio" -sdk iphonesimulator26.5 -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17' clean test -testPlan Core```
   Check that the output includes: **```** TEST SUCCEEDED **```**

By verifying these steps on your local machine, you'll help maintain a consistent development environment for the project.

### Troubleshooting

If you encounter build or test issues, try these steps:

1. **Set Xcode Path:** If Xcode commands aren't found, run: ```sudo xcode-select -s /Applications/Xcode.app```
   Verify that your desired iPhone model is available with: ```xcrun simctl list```

2. **Clean Build Folder**: ```xcodebuild clean```

3. **Clean Derived Data**: This removes all derived data for all projects, so use with caution: ```rm -rf ~/Library/Developer/Xcode/DerivedData/*```

After cleaning, retry the build and test steps above.

# Security Implementation

## Certificate Pinning

The app implements certificate pinning to prevent man-in-the-middle (MITM) attacks. Key details:

1. **Domain:** ```lutheran.radio``` (including subdomains)
2. **Pinned Value (runtime):** SHA-256 digest of the leaf certificate DER (32 bytes), stored as ```CertificateFingerprint``` in ```Core/Configuration/SecurityConfiguration.swift``` as ```pinnedLeafFingerprintDigest```
3. **Pinned Value (operator / docs):** OpenSSL-style colon-hex (uppercase), derived from the digest — ```CC:F7:8E:09:EF:F3:3D:9A:5D:8B:B0:5C:74:28:0D:F6:BE:14:1C:C4:47:F9:69:C2:90:2C:43:97:66:8B:3D:CC```
4. **Location:** SPKI in ```Info.plist``` (```NSAppTransportSecurity > NSPinnedDomains```); runtime digest policy in ```SecurityConfiguration```; comparison in ```Core/Security/CertificateValidator.swift``` via ```Core/Security/CertificateFingerprint.swift```

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

### Certificate Renewal Strategy

To ensure uninterrupted service during SSL certificate renewals, the app includes a strategic transition system:

- **Transition Period:** One month before certificate expiry
- **User Experience:** During the transition period, the app trusts ATS validation if the pinned fingerprint fails, allowing streaming to continue with a debug warning (visible in DEBUG builds)
- **Security Protection:** Transition support is automatically enabled during the defined period, with strict enforcement of the pinned fingerprint outside this window
- **Implementation:** Controlled via `Core/Security/CertificateValidator.swift` with predefined transition start and expiry dates

This approach prevents service disruption during certificate updates while maintaining security through continued ATS enforcement and time-bounded operation.

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

## Security Model Validation

The app performs security model validation to confirm that the version in use matches an approved security implementation before streaming content. This protects against compromised or obsolete app versions.

1. **Primary domain:** `securitymodels.lutheran.radio`
   **Backup domain:** `securitymodels.lutheranradio.sk` (smart fallback)
2. **Mechanism:** Queries DNS TXT records from the ordered list of domains. On success (expected model present), caches result for 1 hour. Permanent failure aborts immediately; transient errors trigger fallback to the backup domain only.
3. **Pinned Value:** Defined in `Core/Configuration/SecurityConfiguration.swift` as `expectedSecurityModel` (currently `"brenham"`)
4. **Location:** Enforced by the actor `Core/Actors/SecurityModelValidator.swift` (single source of truth for validation)
5. **Behavior:** If the app’s security model isn’t in the TXT record, playback is permanently disabled with a user-facing error message

### Why DNS TXT Records?

The app uses a DNS TXT record on `securitymodels.lutheran.radio` for lightweight, dynamic security model validation. This mechanism allows central updating of approved security models without requiring an immediate App Store update for every user.

**DNSSEC Protection**

The `lutheran.radio` zone, including the `securitymodels` subdomain, is protected by **DNSSEC with signed delegation**. The zone is properly signed (visible RRSIG records) and the chain of trust is established from the `.radio` TLD upward.

When queried with the DO (DNSSEC OK) bit set (e.g. `dig +dnssec`), the response includes:
- The TXT record containing the comma-separated list of valid models:
  `"houston,starbase,fredericksburg,brenham"`
- An accompanying **RRSIG** signature.

In the current observed responses, the **AD (Authenticated Data)** flag is **not** set (`;; flags: qr rd ra`), indicating that the recursive resolver did not perform (or did not assert) full DNSSEC validation when answering the query.

**Current Validation Behavior**

The app performs the TXT query via `DNSServiceQueryRecord` **without** the `kDNSServiceFlagsValidate` (or `kDNSServiceFlagsValidateOptional`) flag. Therefore:
- It does **not** perform client-side DNSSEC validation itself.
- It relies on the device’s configured recursive resolver for any DNSSEC checking.
- The mechanism still benefits from the signed zone, making off-path forgery and cache poisoning significantly harder.

Because of these characteristics, the DNS TXT record serves as a useful but not absolute dynamic validation signal. It is supported by certificate pinning on the streaming infrastructure and the app’s failure model: if validation does not succeed, streaming does not proceed until the user installs a version with an updated security model.

This design provides a practical balance between security, simplicity, and resilience (aided by the 1-hour success-only cache).

**Verifying DNSSEC Status**
To check the current TXT record and DNSSEC-related information:

```bash
# Full response with flags and signatures
dig +dnssec TXT securitymodels.lutheran.radio | grep -E "(^securitymodels|flags:|AD:|RRSIG)"

# Short version (TXT + RRSIG)
dig +short +dnssec TXT securitymodels.lutheran.radio
```

Look for the **AD** flag (Authenticated Data) in the `;; flags:` line. Its presence indicates that the resolver performed and accepted DNSSEC validation.

### Verifying the Security Model

To check the current valid security models:

```bash
dig +short +dnssec TXT securitymodels.lutheran.radio
```

Example output:

```
"dc,florida,tampa,atlanta,birmingham,houston,starbase"
TXT 13 3 600 20260328052556 20260326032556 34505 lutheran.radio. CEZx+X3J947EaeiH/hevPZUJvaovpylfY9vLdMb75ohAW3MFuNg9RbnZ 5cjnVglSPo43UCk97UZwkQcREaNY0Q==
```

Compare this output to ```expectedSecurityModel``` in ```Core/Configuration/SecurityConfiguration.swift``` (currently ```brenham```). If the app’s model isn’t listed, validation fails permanently. To update the list, modify the TXT record for ```securitymodels.lutheran.radio``` through the DNS management interface for the ```lutheran.radio``` domain.

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

### Security Isolation Architecture

All security-critical constants (expected model name, `pinnedLeafFingerprintDigest`, transition window dates) are centralized in `Core/Configuration/SecurityConfiguration.swift` (colon-hex fingerprint strings are derived views for operators and docs).
The DNS TXT record validation logic lives in `Core/Actors/SecurityModelValidator.swift` (actor-isolated; `Span<UInt8>` TXT parser with zero-copy `rdata` borrow in the DNS-SD callback; entry point `validateSecurityModel()`).
Runtime full-certificate (DER SHA-256) digest validation with transition-window leniency lives in `Core/Security/CertificateValidator.swift`, using `Core/Security/CertificateFingerprint.swift` for digest storage, hashing, and constant-time comparison.

This refactor:
- Improves maintainability and testability
- Enforces Swift 6 strict concurrency and strict memory-safety build settings on all targets
- Keeps identical runtime behavior and security guarantees
- Does **not** change the current model ("brenham"), fingerprints, transition period, or any validation rules

`DirectStreamingPlayer.swift` and `Core/Security/CertificateValidator.swift` now consume these shared components instead of duplicating logic.

**Core module layout (three subdirectories only):**
- `Core/Configuration/` — policy and constants (`SecurityConfiguration`)
- `Core/Actors/` — DNS TXT validation actor (`SecurityModelValidator`)
- `Core/Security/` — digest type and hashing (`CertificateFingerprint`) + runtime validator (`CertificateValidator`)

The authoritative security invariants and architecture are documented in the
`Core` framework's DocC catalog. The best reading experience is inside Xcode:

- Open the **Developer Documentation** window and search for “Core”, or
- Build documentation for the `Core` target (Product → Build Documentation).

The source articles are also available on GitHub:
- [Security Invariants](https://github.com/jarilammi/lutheran.radio/blob/HEAD/Core/Core.docc/Articles/Security-Invariants.md)
- [Architecture](https://github.com/jarilammi/lutheran.radio/blob/HEAD/Core/Core.docc/Articles/Architecture.md).

New security logic must be placed inside the appropriate `Core/` subdirectory. Duplication in the main app or widget is not permitted.

### Security Model TXT Record Usage

Lutheran Radio's security system uses a DNS TXT record to ensure only trusted app versions can stream content. The longest practical TXT record length for this purpose is about 450 bytes, which fits within standard DNS limits and supports up to 40-50 security model names (like "landvetter" or "nuuk"). This is more than enough for the current 40-byte record. If you need to use more names in the future, check that your DNS supports larger messages (EDNS0) and test the app to confirm it can handle them. Keep an eye on how your DNS behaves to ensure everything works smoothly, keeping the app secure and reliable for all users.

### Security Model History

To avoid naming collisions, each security model name should be unique and not match any previously used name. This helps prevent unintended compatibility with older app versions.

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
| `brenham`           | (pending)          | (pending)          | 26.6.0                 |

**Notes:**
- **Valid From:** The date when the security model was first published to the App Store.
- **Valid Until:** The date when the security model was deprecated (or "(ongoing)" if still active).
- **App Version Introduced:** The app version where this security model was first implemented.
- **Valid From Dates:** Reflect the App Store publication date for the app version introducing the security model, ensuring alignment with public availability.
- When adding a new security model, append a new row to this table and update the DNS TXT record accordingly (see "Verifying the Security Model" above).

When introducing a new security model:

1. Choose a unique name not listed in the table (e.g., a distinct city or codename).
2. Update `expectedSecurityModel` in `Core/Configuration/SecurityConfiguration.swift`.
3. Add the new name to the DNS TXT record for `securitymodels.lutheran.radio`.
4. Append a new row to the table above with the current date, app version, and name.

### Why Track Security Model Names?

Security model names (e.g., ```brenham```) are embedded in the app and validated against the DNS TXT record. Once a name is used, it becomes part of the app's history and may still exist in older versions. Reusing a name could allow an older version to pass validation in some cases. By maintaining this table, we ensure that:

- New security model names are unique and avoid collisions with past names.
- The history of security models is transparent for debugging and auditing.
- Contributors can easily pick a fresh name (e.g., a unique city, codename, or identifier) when implementing a new security model.
