# Core Module

Canonical `Core` documentation lives in DocC, not this leftover root file.

Read, in this order, for security work:

1. `Core/Core.docc/Core.md` — module overview
2. `Core/Core.docc/Articles/Security-Invariants.md`
3. `Core/Core.docc/Articles/Architecture.md`
4. `README.md` security sections (snapshot, pinning, verification commands)
5. `CODING_AGENT.md` (Core Framework Surface Area)

`SharedPlayerManager` is **not** a Core component. Security policy and validation live exclusively in `Core/Configuration/`, `Core/Actors/`, and `Core/Security/` (`SecurityConfiguration`, `SecurityModelValidator`, `CertificateValidator`, `CertificateFingerprint`).

Do not copy policy out of DocC into this file.
