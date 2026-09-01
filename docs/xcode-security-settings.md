# Xcode Security Settings

Security build-setting and Enhanced Security entitlement decisions for **Lutheran Radio**.

This file is the single source of truth for `audit-xcode-security-settings` catalog decisions (Enabled / Disabled / Deferred). Runtime DNS TXT validation, certificate pinning, ATS SPKI, media apex, and `expectedSecurityModel` stay in `Core/` and `Info.plist` — this document does not replace them.

**Inventory (2026-08-31):** Project-level Debug/Release configurations `B7AFC6D82CCD7D0C00BDDD83` / `B7AFC6D92CCD7D0C00BDDD83`. No `.xcconfig`. Tracked first-party C / Objective-C / C++ sources: none. `LutheranRadio-Bridging-Header.h` imports Apple `<dns_sd.h>` only; the DNS walk lives in `SecurityModelValidator`.

**Security Invariant:** Do not weaken `expectedSecurityModel`, the ordered DNS TXT host walk, `kDNSServiceFlagsValidate`, `pinnedFingerprintDigests`, ATS SPKI, media apex `siikkari.net`, device/server time-skew, or MIE/EMTE. Do not strip `com.apple.security.hardened-process*` keys (including already-ON `checked-allocations` / `enable-pure-data` / `no-tagged-receive`). Do not flip `ENABLE_POINTER_AUTHENTICATION` off. Do not enable `ENABLE_C_BOUNDS_SAFETY`. Do not annotate `dns_sd.h`. `Core/` remains the only DNS / cert / security-model place.

- SeeAlso: ``<doc:Security-Invariants>``, ``<doc:Architecture>``, [README.md](../README.md) (Swift Build Settings + Memory Safety), [CODING_AGENT.md](../CODING_AGENT.md) (Security Model + Core Framework Surface Area), `SecurityConfiguration`, `SecurityModelValidator`, `CertificateValidator`.

## Enabled settings

### Enhanced Security (build settings)

- `ENABLE_ENHANCED_SECURITY` to `YES` (project Debug + Release; also restated on the main app and widget extension targets). Cascades `GCC_WARN_SHADOW`, `ENABLE_SECURITY_COMPILER_WARNINGS`, typed-allocator support, and libc++ hardening — those cascaded keys are not set by hand.
- `ENABLE_POINTER_AUTHENTICATION` to `YES` (project Debug + Release; restated on the main app and widget extension). First-party `Core` + `WidgetSurface` + Apple SDK only; no unsigned vendor binaries, xcframeworks, or Swift packages. Do not override to `NO` on arm64e-capable iOS targets.

### Enhanced Security (entitlements)

Supported product type in this project is the main application only (`com.apple.product-type.application`). The widget extension is `com.apple.product-type.app-extension` (skill apply-skip); extra-on keys stay. Frameworks and test bundles are not Enhanced Security product types — do not add entitlements files to `Core` or `WidgetSurface`.

**Lutheran Radio** (`Lutheran Radio/Lutheran Radio.entitlements`) — up-to-date plus default-OFF MTE family already ON:

- `com.apple.security.hardened-process`
- `com.apple.security.hardened-process.enhanced-security-version-string` to `"2"`
- `com.apple.security.hardened-process.hardened-heap`
- `com.apple.security.hardened-process.dyld-ro`
- `com.apple.security.hardened-process.platform-restrictions-string` to `"2"`
- `com.apple.security.hardened-process.checked-allocations`
- `com.apple.security.hardened-process.checked-allocations.enable-pure-data`
- `com.apple.security.hardened-process.checked-allocations.no-tagged-receive`

Deprecated keys (`…platform-restrictions`, `…enhanced-security-version`) are absent. Soft-mode (`…checked-allocations.soft-mode`) is not present — production enforcement, not simulated crashes.

**LutheranRadioWidgetExtension** (`LutheranRadioWidget/LutheranRadioWidget.entitlements`) — same key set as the app. Skill catalog would skip this product type on apply; do not strip extra-on keys to “match the catalog.”

### Swift 6 strictness (project Debug + Release)

- `SWIFT_STRICT_CONCURRENCY` to `complete`
- `SWIFT_STRICT_MEMORY_SAFETY` to `YES`
- `SWIFT_APPROACHABLE_CONCURRENCY` to `NO`

All targets keep `SWIFT_VERSION = 6` (or `6.0`). Do not weaken these without owner approval and a security impact assessment. `IPHONEOS_DEPLOYMENT_TARGET` at project level stays `26.2`.

### Basic Clang safety warnings

- `GCC_WARN_ABOUT_RETURN_TYPE` to `YES_ERROR`
- `GCC_WARN_UNINITIALIZED_AUTOS` to `YES_AGGRESSIVE`
- `GCC_WARN_64_TO_32_BIT_CONVERSION` to `YES`
- `CLANG_WARN_IMPLICIT_FALLTHROUGH` to `YES` (enabled 2026-08-31 at project Debug + Release; compile-time only, covers the `dns_sd.h` bridging import)
- `GCC_TREAT_IMPLICIT_FUNCTION_DECLARATIONS_AS_ERRORS` to `YES` (enabled 2026-08-31 at project Debug + Release; same bridging-import coverage)

### Clang static analyzer security checkers

- `CLANG_ANALYZER_SECURITY_FLOATLOOPCOUNTER` to `YES` (enabled 2026-08-31 at project Debug + Release)
- `CLANG_ANALYZER_SECURITY_INSECUREAPI_RAND` to `YES` (enabled 2026-08-31 at project Debug + Release)
- `CLANG_ANALYZER_SECURITY_INSECUREAPI_STRCPY` to `YES` (enabled 2026-08-31 at project Debug + Release)

These five keys were the catalog gaps versus an already-hardened project. They are analyzer / warning only. If a future Xcode / SDK makes Apple `dns_sd.h` warn under them, move the noisy key to Disabled rather than annotating the system header.

Default-ON analyzer checkers (`CLANG_ANALYZER_SECURITY_KEYCHAIN_API`, `CLANG_ANALYZER_SECURITY_INSECUREAPI_UNCHECKEDRETURN`, `CLANG_ANALYZER_SECURITY_INSECUREAPI_GETPW_GETS`, `CLANG_ANALYZER_SECURITY_INSECUREAPI_MKSTEMP`, `CLANG_ANALYZER_SECURITY_INSECUREAPI_VFORK`, `GCC_WARN_TYPECHECK_CALLS_TO_PRINTF`) are not overridden; they keep Xcode defaults.

### Additional diagnostics (already adopted)

- `CLANG_ANALYZER_SECURITY_BUFFER_OVERFLOW_EXPERIMENTAL` to `YES`
- `CLANG_TIDY_BUGPRONE_REDUNDANT_BRANCH_CONDITION` to `YES`
- `CLANG_WARN_ASSIGN_ENUM` to `YES`
- `CLANG_WARN_SUSPICIOUS_IMPLICIT_CONVERSION` to `YES`
- `GCC_WARN_SIGN_COMPARE` to `YES`
- `CLANG_WARN_EMPTY_BODY` to `YES` (also cascaded by Enhanced Security)
- `CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF` to `YES`

## Disabled settings

None of the catalog settings are explicitly set to `NO`. `SWIFT_APPROACHABLE_CONCURRENCY = NO` is a Swift 6 strictness enablement (no relaxed concurrency), not a catalog opt-out.

## Deferred

Settings considered but not enabled. Revisit only with an explicit owner request.

- `ENABLE_C_BOUNDS_SAFETY`: Requires an annotation-based C programming model. There is no first-party C to annotate. Enabling it would pressure annotating Apple `dns_sd.h`, which this project will not do. DNS validation stays in `SecurityModelValidator` (`DNSServiceQueryRecord` + `kDNSServiceFlagsValidate`).
- `ENABLE_CPLUSPLUS_BOUNDS_SAFE_BUFFERS`: No first-party C++ buffer code.
- `CLANG_ANALYZER_OSOBJECT_C_STYLE_CAST`: C++ / DriverKit / IOKit checker; no first-party C++.
- `CLANG_WARN_COMPLETION_HANDLER_MISUSE`: Blocks / ObjC completion-handler warning; no first-party ObjC.
- `CLANG_WARN_OBJC_REPEATED_USE_OF_WEAK`: ObjC-specific; no first-party ObjC.

Non-catalog observation (do not invent a settings slice from this): `WidgetSurfaceTests` Debug/Release set `IPHONEOS_DEPLOYMENT_TARGET = 27.0` while the project and app stay at `26.2`. Do not raise the app deployment target to match the test bundle.
