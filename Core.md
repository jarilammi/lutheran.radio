# Core Module

The `Core` module is the central, isolated foundation of **lutheran.radio**. It contains all security-critical logic and shared infrastructure, designed with strict separation of concerns and full Swift 6 concurrency compliance.

## Purpose

- Act as the **single source of truth** for all security policies and configuration.
- Isolate security validation logic to make it auditable, testable, and impossible to accidentally bypass.
- Provide shared utilities and managers used across the rest of the app.

## Key Components

### SecurityConfiguration
- Centralized constants and rules (expected security model, pinned certificate fingerprints, cache durations, time skew tolerance, etc.).
- Non-negotiable security parameters — any deviation from these values is treated as a hard failure.

### SecurityModelValidator
- `@MainActor`-isolated actor responsible for DNS TXT record validation against `securitymodels.lutheran.radio`.
- Handles caching (1-hour TTL), transient vs. permanent failures, and safe bridging for C callbacks.
- Used by `DirectStreamingPlayer` and other components instead of scattered local security state.

### Other
- Updated `CertificateValidator`
- `SharedPlayerManager` and related session handling
- Initial unit tests (`SecurityModelValidatorTests`)

## Design Principles

- **Security First**: All security logic lives here. No other part of the app is allowed to make independent security decisions.
- **Strict Concurrency**: Full Swift 6 isolation.
- **Testability**: Clear inputs/outputs and minimal side effects.
- **No Runtime Behavior Change**: Existing security guarantees (DNS validation, dual certificate pinning, hardened runtime, etc.) remain exactly the same.

This module was introduced in PR #67 (`refactor/security-isolation-extraction`).

---

For more details, see:
- `SecurityConfiguration.swift`
- `SecurityModelValidator.swift`
- `README.md`
