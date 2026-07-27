# ``Core``

The `Core` framework is the **single source of truth** for all security policy, DNS TXT validation, and runtime certificate pinning in Lutheran Radio.

## Overview

`Core` isolates every security-critical decision into a tiny, auditable Swift module compiled as a framework. It is linked by both the main application and the widget extension.

The framework enforces three fundamental security mechanisms:

- **Security model validation** via DNS TXT records on ordered ``SecurityConfiguration/securityModelDomains`` (`securitymodels.siikkari.net` → `securitymodels.lutheran.radio` → `securitymodels.lutheranradio.sk`)
- **Runtime full-certificate SHA-256 digest pinning** against ``pinnedFingerprintDigests`` (sole production leaf: live preferred-apex `*.siikkari.net`; ``CertificateFingerprint`` + constant-time comparison) with transition support
- **Time-skew detection** to protect transition windows from clock manipulation
- **Streaming media apex policy** via ``preferredStreamingDomainSuffixes`` (sole apex `siikkari.net`) — independent of DNS TXT host order

All constants, policy, and validation logic live exclusively inside `Core/`. Duplication outside this framework is not permitted.

## Security Invariants

The authoritative list of required rules is maintained in:

- ``<doc:Security-Invariants>``

Any change that could affect these invariants requires security review.

## Architecture

For a detailed explanation of the three-layer design (Configuration / Actors / Security), actor isolation strategy, and testing approach, see:

- ``<doc:Architecture>``

## Topics

### Configuration

- ``SecurityConfiguration``

### Security Types

- ``CertificateFingerprint``

### Validation Actors

- ``SecurityModelValidator``
- ``CertificateValidator``

### Articles

- ``<doc:Security-Invariants>``
- ``<doc:Architecture>``

## See Also

- [Security Model Validation](https://github.com/jarilammi/lutheran.radio/blob/main/README.md#security-model-validation) in the project README
- [Certificate Pinning](https://github.com/jarilammi/lutheran.radio/blob/main/README.md#certificate-pinning) in the project README
- CODING_AGENT.md — Permanent rules for all contributors and AI agents working on this codebase
