# Architecture

@Metadata {
    @TechnologyRoot
}

This article documents two complementary layers of Lutheran Radio architecture:

1. **Security layering inside `Core/`** — the mandatory, auditable module for DNS TXT validation and certificate pinning.
2. **Event-driven player architecture outside `Core/`** — the canonical `PlayerEvent` vocabulary, emission surfaces, replay contract, and consumer model.

Security decisions never flow through player events. Player state never duplicates security policy. The boundary is deliberate and permanent.

## Security Layering (`Core`)

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

---

## Event-Driven Player Architecture (Outside `Core`)

Player-domain state transitions are expressed through a typed event vocabulary that lives **outside** `Core/`. `SharedPlayerManager` is the sole authoritative emitter. Security actors (`SecurityModelValidator`, `CertificateValidator`) remain deliberately excluded from this surface.

### Why Player Events Are Outside `Core`

| Concern | Location | Rationale |
|---------|----------|-----------|
| DNS TXT validation, certificate pinning, time-skew protection | `Core/` | Security invariants; single auditable module |
| Playback intent, visual state, stream verbs, widget snapshots | Cross-target shared sources under the main app target | Widget/Live Activity presentation; no certificate or DNS logic |
| `PlayerEvent` vocabulary | `PlayerVisualState.swift` | Compiled into main app **and** widget extension; pure `Sendable` types only |

Mixing player presentation events into `Core/` would couple widget compilation to security internals and blur the security review boundary. The split preserves the rule that **all security decisions flow exclusively through `Core/Configuration/`, `Core/Actors/`, and `Core/Security/`**.

### Governing Principles

- **Nothing is forced.** Event emission and observation are strictly additive. Imperative paths (direct `setPlaying()`, `stop()`, snapshot writes, `refreshIfNeeded`, widget optimistic writes) remain the primary mechanism everywhere.
- **Emit after mutation.** Every `PlayerEvent` is yielded from `SharedPlayerManager` only after the corresponding in-actor state change completes.
- **Per-actor streams, not a global bus.** `SharedPlayerManager` owns one long-lived `AsyncStream<PlayerEvent>`. A higher-level typed event bus wrapping multiple domain actors is not used. Clear ownership, process guards, and independent replay are preserved.
- **Main-app emission only.** `emit(_:)` guards against widget-process yields. Widget extensions perform optimistic snapshot writes for instant feedback but never originate authoritative events.

### `PlayerEvent` Vocabulary

`PlayerEvent` is the single source of truth for player-domain events. It is a pure `Sendable` enum with no side effects. All associated values use existing SSOT types (`PlaybackIntent`, `PlayerVisualState`, `StreamProgramMetadata`, `DirectStreamingPlayer.StreamErrorType`).

| Case | Meaning | Typical emission surface |
|------|---------|--------------------------|
| `playbackIntentChanged` | Authoritative intent changed | `updatePlaybackIntent(to:)` |
| `streamDidStart` | Audio successfully rendering | `setPlaying()`, engine recovery |
| `streamDidPause` | Entered paused state | `setUserPaused()`, `markAsUserPaused()` |
| `streamDidStop` | Terminal stop | `stop()` |
| `streamDidFail` | Classified stream failure | `markPlaybackStoppedByStreamFailure(_:)` |
| `metadataDidUpdate` | ICY program metadata changed or cleared | `didUpdateStreamMetadata(_:)`, metadata clears |
| `visualStateDidChange` | In-memory visual state changed | `applyVisualState` / `setVisualState` |
| `persistedWidgetStateDidUpdate` | Session widget snapshot written | After `savePersistedWidgetState` |

**Security invariant:** Do not add certificate, DNS, or security-model cases to `PlayerEvent`. Security events stay inside `Core/`.

### Authoritative Emitter: `SharedPlayerManager`

`SharedPlayerManager` is an actor and the **single source of truth** for both player state and event emission.

```
┌─────────────────────────────────────────────────────────────┐
│                    SharedPlayerManager (actor)              │
│                                                             │
│  Canonical mutations (setPlaying, stop, saveCurrentState…)  │
│           │                                                 │
│           ▼                                                 │
│      emit(_:)  ──guard──▶  events: AsyncStream<PlayerEvent> │
│           │                      │                          │
│           │                      ├──▶ WidgetRefreshManager  │
│           │                      ├──▶ PlayerEventSubscriber │
│           │                      └──▶ test observers (DEBUG)│
│           │                                                 │
│      currentState ──▶ PlayerCurrentState snapshot           │
│      makeEventsStreamWithReplay() ──▶ prefix + live forward │
└─────────────────────────────────────────────────────────────┘
```

All production emission routes through internal `emit(_:)`. The `events` stream is created once per manager lifetime. Access requires `await SharedPlayerManager.shared.events`.

### Stream Surfaces

Three complementary surfaces serve different subscriber needs:

| Surface | Purpose | Late-subscriber support |
|---------|---------|-------------------------|
| `events` | Live `AsyncStream<PlayerEvent>` | Events after subscription only |
| `currentState` | `PlayerCurrentState` snapshot | Full present state at read time |
| `makeEventsStreamWithReplay()` | Per-subscriber replaying stream | Four synthesized prefix events, then live forward |

#### Replay contract (finalized)

`makeEventsStreamWithReplay()` yields exactly four prefix events synthesized from `currentState`:

1. `.visualStateDidChange`
2. `.playbackIntentChanged`
3. `.metadataDidUpdate`
4. `.persistedWidgetStateDidUpdate`

Stream transition verbs (`streamDidStart`, `streamDidPause`, `streamDidStop`, `streamDidFail`) are **not** synthesized during replay. Terminal conditions (including permanent errors) are expressed through `PlayerCurrentState` fields — especially `hasError` and the convenience accessors `isActivelyPlaying`, `isBlockedByStickyIntent`, and `isInPermanentError`.

Each replay stream forwards subsequent live emissions from the authoritative `events` stream. `makeEventsStreamWithReplay()` materializes the live stream while already actor-isolated and yields before returning so forwarding iterators attach before callers drive mutations.

### Error and Recovery Contract

Failures and recovery use the established vocabulary without additional cases:

- **Failure:** `streamDidFail(StreamErrorType)` with classifications `transientFailure`, `permanentFailure`, `securityFailure`, and `unknown`.
- **Recovery:** A subsequent `streamDidStart` after successful engine recovery.
- **Late subscribers:** `PlayerCurrentState.hasError` supplies the terminal error condition in replay prefixes.

`markPlaybackStoppedByStreamFailure(_:)` preserves `currentPlaybackIntent` for transient failures (auto-resume semantics). Explicit user pause (`setUserPaused()`) sets sticky `.userPaused` intent. Replay distinguishes these paths even when both show grey `.userPaused` visual state.

### Consumers

Tier 2 observers consume events additively. Imperative snapshot and refresh paths remain primary.

| Consumer | Observes | Behavior |
|----------|----------|----------|
| `WidgetRefreshManager` | `SharedPlayerManager.events` (main app only) | Derives refresh parameters from carried events or persisted SSOT; routes through existing `refreshIfNeeded(visualState:currentLanguage:hasError:immediate:)` |
| `PlayerEventSubscriber` | `makeEventsStreamWithReplay()` in `RadioPlayerView` | UI-only observable state (`eventCount`, `lastObservedIntent`); does not replace `@Bindable` view model bindings |
| `RadioLiveActivityManager` | `Activity.contentUpdates` (attribute events) | Aligns `lastPushedContent`, diff-suppresses redundant `update(using:)`, self-heals on dismissal |
| `WidgetEventObserver` | Generic `AsyncSequence` helper | Shared cancel-before-start, main-actor handoff, and task lifetime for both `PlayerEvent` and Live Activity attribute streams |

`WidgetRefreshManager` applies privacy gating (`hasActiveLutheranWidgets`), session-teardown suppression (`isSessionTeardownInProgress`), debouncing, and coalescing inside `refreshIfNeeded`. The event observer and direct call sites share the identical public surface.

### Cross-Process Reality

Widget extension processes (home widget, Control Center widget, Live Activity UI) **cannot** observe `SharedPlayerManager.events`:

- Emission is guarded to the main app process.
- Extensions read `loadPersistedWidgetState()` and call `refreshVisualStateFromPersistence()` at provider entry points.
- Widget and Live Activity intents use ``persistOptimisticWidgetSnapshot(_:language:)`` for optimistic instant feedback before Darwin round-trips.

Cross-process presentation therefore relies on snapshot reads plus main-app-driven `WidgetCenter.reloadTimelines` and Live Activity attribute updates. This is permanent architecture.

### Relationship to Imperative Paths

Direct mutation, snapshot writes, and lifecycle refresh calls coexist with the event path. Consolidation candidates (imperative `refreshIfNeeded` call sites, coordinator eager sync) are inventoried in `docs/Event-Driven-Refactor-Roadmap.md` under Tier 4. Imperative paths remain primary until the event path proves reliable on device. Permanent cross-process surfaces include ``persistOptimisticWidgetSnapshot(_:language:)`` for optimistic widget writes and `forceStaleLivenessTimestampForTermination()` for the termination liveness sentinel.

### Cross-Target Shared Sources

These files are compiled into both the main app and `LutheranRadioWidgetExtension` (File System Synchronized Group with membership exceptions):

- `SharedPlayerManager.swift`
- `PlayerVisualState.swift` (`PlayerEvent`, `PlayerCurrentState`, `PlaybackIntent`, `PlayerVisualState`)
- `WidgetRefreshManager.swift`
- `WidgetEventObserver.swift`
- `StreamProgramMetadata.swift`
- `LutheranRadioLiveActivityAttributes.swift`

Security logic is **never** placed in this cross-target set.

### Testing

Emitter and consumer contracts are protected by 71 event-driven unit tests (as of 2026-07-09):

- `SharedPlayerManagerEventTests` — emission order, replay prefix, live stream delivery, session teardown, privacy gate
- `WidgetRefreshManagerEventTests` — derivation matrix, event-path gates, debounce/coalesce timing
- `PlayerEventSubscriberEventTests` — replay prefix, observable rules, widget-process guard
- `WidgetEventObserverTests` — delivery, termination, cancel, restart
- `RadioLiveActivityManagerTests` — attribute-events (`contentUpdates`) via DEBUG synthetic seams

Tests use fast/reliable patterns documented in `CODING_AGENT.md`: UITestMode short-circuits for DNS/streaming/ActivityKit IPC, subscribe-before-action collection on `AsyncStream`, and a DEBUG notification seam posted from `emit(_:)` for deterministic emission-order assertions. Replay live-forwarding in the XCTest host is best-effort only; primary contracts gate on the DEBUG seam and replay prefix.

Canonical test files live under `Lutheran RadioTests/` (`SharedPlayerManagerEventTests.swift`, `WidgetRefreshManagerEventTests.swift`, `PlayerEventSubscriberEventTests.swift`, `WidgetEventObserverTests.swift`, and the attribute-events subset in `RadioLiveActivityManagerTests.swift`). The Tier 5 checklist in `docs/Event-Driven-Refactor-Roadmap.md` records the protected contracts.

## See Also

### Security (`Core`)

- ``<doc:Security-Invariants>``
- ``SecurityConfiguration``
- ``SecurityModelValidator``
- ``CertificateFingerprint``
- ``CertificateValidator``

### Event-driven player architecture (outside `Core`)

- `PlayerEvent` and `PlayerCurrentState` in `PlayerVisualState.swift`
- `SharedPlayerManager` — `events`, `currentState`, `makeEventsStreamWithReplay()`, `emit(_:)`
- `WidgetEventObserver`, `WidgetRefreshManager`, `PlayerEventSubscriber`
- `docs/Event-Driven-Refactor-Roadmap.md` — authoritative backlog, architectural evaluation, and Tier 5 test checklist
- `docs/Widget-Presentation-Dataflow.md` — widget and Live Activity data flow
- `Lutheran RadioTests/SharedPlayerManagerEventTests.swift` — canonical emission-order and replay helpers
- `CODING_AGENT.md` — Single Source of Truth Principles, cross-target shared files, test execution patience
