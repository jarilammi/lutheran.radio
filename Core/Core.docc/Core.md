# ``Core``

The `Core` framework is the **single source of truth** for all security policy, DNS TXT validation, and runtime certificate pinning in Lutheran Radio.

## Overview

`Core` isolates every security-critical decision into a tiny, auditable Swift module compiled as a framework. It is linked by both the main application and the widget extension.

The framework enforces three fundamental security mechanisms:

- **Security model validation** via DNS TXT records (`securitymodels.lutheran.radio`)
- **Runtime full-certificate SHA-256 fingerprint pinning** with transition support
- **Time-skew detection** to protect transition windows from clock manipulation

All constants, policy, and validation logic live exclusively inside `Core/`. Duplication outside this framework is forbidden.

## Security Invariants

The authoritative list of non-negotiable rules is maintained in:

- ``<doc:Security-Invariants>``

Any change that could affect these invariants requires security review.

## Architecture

For a detailed explanation of the three-layer design (Configuration / Actors / Security), actor isolation strategy, and testing approach, see:

- ``<doc:Architecture>``

## Topics

### Configuration

- ``SecurityConfiguration``

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
