# Widget Functionality Roadmap

**Purpose**

This document is the authoritative living record of **WidgetKit home-screen widgets**, the **Control Center control widget**, and **ActivityKit Live Activity presentation** in Lutheran Radio — including cross-process state, App Intents, timeline refresh, and the snapshot-driven presentation model.

It serves as both the project backlog for remaining widget work and a self-contained reference for developers and coding agents. It complements (does not replace) the player **event** backlog in [`docs/Event-Driven-Refactor-Roadmap.md`](Event-Driven-Refactor-Roadmap.md) and the presentation contract in [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md).

**Target Architecture (Ultimate Goal)**

The finish line is a **hybrid, two-zone model** — not a migration from snapshots to cross-process events. WidgetKit and ActivityKit require frozen value-type snapshots; that constraint is permanent.

| Zone | Mechanism | Ultimate state |
|------|-----------|----------------|
| Main app | `SharedPlayerManager` actor + imperative snapshot saves + `PlayerEvent` | Hybrid: events are an **additive** in-process consumer path; authoritative mutations and snapshot writes remain primary |
| Extension + LA presentation | `PersistedWidgetState` → `SimpleEntry` / `ContentState` + `reloadTimelines` / LA push | **Snapshot-driven permanently**; extension never observes `PlayerEvent` (OI-W2) |

**Cross-process (widgets, Control Center, Live Activity UI)**

- Frozen value-type snapshots are the permanent integration model. See [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md).
- Freshness stacks: session snapshot (`loadPersistedWidgetState` / `savePersistedWidgetState`), App Group optimistic instant-feedback keys, pending-action round-trips, and main-app-driven `WidgetRefreshManager.refreshIfNeeded` / `WidgetCenter.reloadTimelines`.
- Live Activity hot path uses in-memory pushes from `RadioLiveActivityManager`; widgets and Control widgets read persisted snapshots.

**Presentation**

- Three narrow, `Equatable` surfaces derived **once per snapshot**: `PlayerStatusPresentation`, `PlayerControlPresentation`, `WidgetNowPlayingDisplayModel`.
- Leaf views and LA regions consume explicit slices — not full `PlayerVisualState` policy re-derived in `body`.

**Commands & shims (permanent, not legacy)**

- Optimistic `forcePersistVisualState`, `refreshVisualStateFromPersistence`, liveness sentinel (`lastUpdateTime = 0`), and pending-action App Group keys stay in place. Tier 3 “consolidation” does not remove them.

**What “done” means**

- **Required:** Tier 1 presentation hygiene + Tier 2 snapshot/intent test contracts (OI-W3 strategy).
- **Optional, late-stage:** Tier 3–4 main-app refresh dedup and media-surface coordination — observable widget/LA behavior unchanged; no architectural model change.

**Core Principles (Never Violate)**

- Progress must be **slow and piece-by-piece**. Every micro-step must be small, reviewable, and non-breaking.
- **Nothing is forced**: Imperative snapshot reads, direct `refreshIfNeeded` calls, Darwin notification round-trips, and widget optimistic writes remain primary. Event-driven refresh and additive observation run in parallel (see Event-Driven Refactor Roadmap).
- **Documentation voice & reference discipline** (applies to every touched file, including this roadmap):
  - **Voice:** Comments and `///` documentation describe the system as it exists *now* — present tense, final architecture language. Source must not read like a plan in progress: no "phase", "step", "temporary", "will be", "TODO migrate", or migration scaffolding in production code.
  - **Canonical references only:** `SeeAlso:`, file headers, and cross-links cite documents that are **committed and tracked** on the branch being edited. Staged-but-unmerged drafts, untracked scratch files, agent prompts, and one-off analysis notes are not authoritative until they ship — do not point future readers at them. When uncertain whether a path is canonical, confirm with `git ls-files <path>` (empty output means do not cite).
- **Security invariants come first.** No changes may touch `Core/`, certificate validation, DNS TXT validation, or `SecurityModelValidator`. Widget extension code must not duplicate security logic.
- Every user-visible string uses `String(localized:)` / `NSLocalizedString` with table `"Localizable"` (all 21 languages).
- Every change must follow `CODING_AGENT.md` (structured documentation, `SeeAlso`, AGENT NOTE where appropriate, build gates).
- After every micro-step, this roadmap document must be updated to reflect completed work and adjust priorities.

**Relationship to Other Docs**

| Document | Role |
|----------|------|
| [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md) | Permanent presentation contract (three narrow surfaces, pre-derivation, termination invariant) |
| [`docs/Event-Driven-Refactor-Roadmap.md`](Event-Driven-Refactor-Roadmap.md) | Player `PlayerEvent` emission + `WidgetRefreshManager` as Tier 2 consumer |
| [`docs/cold-launch-streamplay-regression-checklist.md`](cold-launch-streamplay-regression-checklist.md) | Regression guard for widget pause/play/switch SSOT (§6 stream switch, §7 widget persistence) |
| `SharedPlayerManager+NowPlaying.swift`, `StreamProgramMetadata.swift` | Now Playing metadata SSOT (`nowPlayingDisplayStrings`) shared with widget/LA formatters |
| `README.md` (SSOT section) | Index + cross-links |
| ``<doc:Architecture>`` (Core DocC) | Event-driven player architecture + cross-process widget reality |

---

**Current State (as of 2026-07-10)**

## Completed

### Presentation & Display Model

- **Three narrow presentation surfaces** established and documented: `PlayerStatusPresentation` (`makeStatusPresentation()`), `PlayerControlPresentation` (`makeControlPresentation()`), `WidgetNowPlayingDisplayModel` (`widgetNowPlayingDisplayModel(...)`). See `PlayerVisualState.swift`, `WidgetDisplayModels.swift`, [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md).
- **P0 control migration complete (2026-06-27):** All play/pause glyph + tint sites in Small/Medium/Large widgets, Dynamic Island trailing/compactTrailing, Lock Screen, and Control widget consume `PlayerControlPresentation` exclusively. Remaining `isActivelyPlaying` / `buttonTintColor` reads are non-control (LIVE indicator, animation bars, decorative radio glyph) and are documented.
- **Widget Provider pre-derivation complete:** `SimpleEntry` carries `statusPresentation`, `controlPresentation`, and `widgetNowPlayingDisplayModel`, each computed once in `Provider.placeholder`, `snapshot`, `timeline` / `createEntry`. Family views read narrow fields from the entry; `WidgetMetadataRegion` receives only `WidgetNowPlayingDisplayModel`.
- **Live Activity outer-closure pre-derivation complete:** `dynamicIsland` closure hoists `statusPres`, `controlPres`, `metadataModel`, `isPlaying`, and `radioIconTint` once; expanded, compact, and minimal regions close over these values (no inline `makeStatusPresentation()` in region builders). `LockScreenLiveActivityView` derives status/metadata/control at the top of `body`.
- **Narrow family view inputs (2026-07-13):** `LutheranRadioWidgetEntryView` projects explicit slices into `SmallWidgetView` / `MediumWidgetView` / `LargeWidgetView` instead of passing full `SimpleEntry`. Reduces WidgetKit invalidation surface when unrelated entry fields change.
- **Control widget provider pre-derivation (2026-07-13):** `LutheranRadioWidgetControl.Value` carries pre-derived `statusPresentation` and `controlPresentation`; `Provider` derives once per read; toggle label consumes narrow fields only (symmetric with `SimpleEntry`).
- **Exhaustive `#Preview` matrix** in `LutheranRadioWidget.swift` exercises visual states × metadata presence/absence.
- **Canonical presentation reference doc** [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md) (termination invariant, LA event-driven update model, contributor guidance). README SSOT subsection cross-links it.

### Cross-Process State & Intents

- **`PersistedWidgetState` in-process session snapshot** (memory-only visual policy, 2026-07-07): `loadPersistedWidgetState()` reads `inMemorySessionWidgetSnapshot` only; cold launch resets to factory `.prePlay` via `resetToFactoryDefaultsOnLaunch()`. Resolves event-roadmap **OI-1** for widgets. Protected by `testColdLaunchFactoryResetClearsDiskVisualStateAndReturnsPrePlay`.
- **App Group + Darwin round-trip** for widget/Control/LA intents: extension writes optimistic snapshot + `pendingAction` (+ `pendingActionId`); main app processes via `checkForPendingWidgetActions` / `handleWidgetAction` / coordinator SSOT paths. Widget pause uses `SharedPlayerManager.stop()` (no duplicated player logic). Widget switch mirrors `completeStreamSwitch` SSOT (**P5-1 shipped**).
- **Optimistic instant feedback** (`isInstantFeedback`, `instantFeedbackTime`, `instantFeedbackLanguage`) for sub-round-trip UI; 15 s validity window.
- **Legacy forcing shim** `forcePersistVisualState(_:language:)` documented and scoped to widget optimistic paths only; `emit(_:)` guard suppresses `PlayerEvent` yields in widget process.
- **Liveness heuristic SSOT:** `SharedPlayerManager.isMainAppProcessRecentlyActive()` (60 s window + `lastUpdateTime = 0` termination sentinel). Passive "tap_to_open" branch in all widget family views when `!isAppRunning()`. Protected by `testForceStaleLivenessMakesIsRecentlyActiveFalse_AndBumpRestores`.
- **WML-1 (2026-06-11):** Pause retains parsed metadata in snapshot for subdued widget display; resume rehydrates when needed (**P5-12**).

### Refresh, Teardown & Live Activity

- **`WidgetRefreshManager`** debouncing/coalescing coordinator: privacy gate (`hasActiveLutheranWidgets`), teardown gate (`isSessionTeardownInProgress`), adaptive debounce, `.prePlay`→`.playing` coalesce, `immediate: true` for `.prePlay`/`.cleared`.
- **Tier 2 event consumer** (Event-Driven Roadmap): internal `PlayerEvent` observer routes through identical `refreshIfNeeded` surface. **19 tests** in `WidgetRefreshManagerEventTests.swift` (derivation matrix, event-path gates, debounce timing, privacy, immediate delivery).
- **Session teardown orchestration (2026-07-08):** `performSessionAndWidgetTeardown()`, `performPostStopWidgetHygiene()`, `forceStaleLivenessTimestampForTermination()`, post-teardown `reloadAllTimelines`. Protected by teardown + post-stop tests in `SharedPlayerManagerEventTests.swift`.
- **`RadioLiveActivityManager`** event-driven LA updates (no default fallback timer); `contentUpdates` observation via `WidgetEventObserver`; `lastPushedContent` dedup. Attribute-events subset protected in `RadioLiveActivityManagerTests.swift`.
- **MediaRemoteUI watchdog fix (2026-07-08):** async `teardownNowPlayingSession()` + teardown gate suppressing `reloadTimelines` during Now Playing detach.

### Widget Surfaces Inventory

| Surface | Entry point | State read | User actions |
|---------|-------------|------------|--------------|
| Small / Medium / Large home widgets | `Provider` (`AppIntentTimelineProvider`) | `refreshVisualStateFromPersistence` → `loadPersistedWidgetState` | `WidgetToggleRadioIntent`, `SwitchStreamIntent` |
| Control Center widget | `LutheranRadioWidgetControl` (`ControlWidgetToggle`) | `loadPersistedWidgetState` + liveness | Toggle via `ControlWidgetToggle` value provider |
| Live Activity (Lock Screen + DI) | `RadioLiveActivityManager` pushes `ContentState` | In-memory SPM + persisted fallback | `LiveActivityTogglePlaybackIntent`, `LiveActivitySwitchStreamIntent` |
| Widget configuration | `RadioWidgetConfiguration` (`WidgetConfigurationIntent`) | N/A | Stream picker for widget config |

### Documentation & Tests (Widget-Adjacent, Complete)

- **Event-driven consumer tests:** `WidgetRefreshManagerEventTests.swift` (19), `WidgetEventObserverTests.swift` (6), `RadioLiveActivityManagerTests.swift` attribute-events subset (6), widget-process guards in `SharedPlayerManagerEventTests.swift` / `PlayerEventSubscriberEventTests.swift`.
- **Snapshot / lifecycle tests:** cold-launch factory reset, liveness sentinel, session teardown, post-stop hygiene, Now Playing metadata clear.
- **Now Playing metadata alignment (2026-06-25/26):** `updateNowPlayingInfo()` delegates to `StreamProgramMetadata.nowPlayingDisplayStrings(...)`; language-switch metadata clear triggers immediate Now Playing refresh. Same formatter family as widget/LA title resolution.
- **README + Architecture DocC** cross-link widget presentation surfaces and event-driven refresh.

---

## Architecture Status

### Snapshot-Driven Cross-Process Model

WidgetKit and ActivityKit receive **frozen value-type snapshots** across process boundaries. The widget extension process **cannot** observe `SharedPlayerManager.events` (main-app emission guard). Cross-process freshness therefore relies on:

1. **In-process session snapshot** (`PersistedWidgetState` via `loadPersistedWidgetState` / `savePersistedWidgetState`)
2. **App Group instant-feedback + pending-action keys** (optimistic + one-shot commands)
3. **Main-app-driven** `WidgetCenter.reloadTimelines` / `WidgetRefreshManager.refreshIfNeeded`
4. **Live Activity** in-memory pushes from `RadioLiveActivityManager` (hot path avoids disk)

This is **permanent architecture**, not a gap to close with events.

### Authoritative Writers & Readers

| Concern | SSOT | Writers | Readers |
|---------|------|---------|---------|
| Visual state (session) | `PersistedWidgetState.visualState` | Main app `savePersistedWidgetState`; widget `forcePersistVisualState` (optimistic) | All Providers, Control widget, `loadSharedState` |
| Stream metadata (session) | `PersistedWidgetState.streamMetadata` | `didUpdateStreamMetadata`, widget handlers | Provider metadata resolver, LA fallback |
| Language | `PersistedWidgetState.currentLanguage` / `preferredWidgetLanguage()` | Saves, widget switch intents | Flag grids, metadata fallback strings |
| Permanent error | `PersistedWidgetState.hasError` | Security / unrecoverable failure paths | Widget chrome, `deriveRefreshParameters` |
| Liveness | `lastUpdateTime` (+ sentinel `0`) | Saves, `bumpWidgetLivenessTimestamp`, termination | `isMainAppProcessRecentlyActive`, passive branch |
| Pending commands | `pendingAction` + `pendingActionId` + `pendingLanguage` | Widget/LA/Control intents | `getPendingAction`, main-app processors |

### Presentation Derivation Sites (Canonical)

| Surface | WidgetKit (`SimpleEntry`) | Control Center (`Value`) | ActivityKit (`ContentState` views) |
|---------|---------------------------|--------------------------|-------------------------------------|
| Status | Once in `Provider` → projected in `LutheranRadioWidgetEntryView` | Once in `Provider` → `Value.statusPresentation` | Once at top of `LockScreenLiveActivityView` and outer `dynamicIsland` closure |
| Control | Once in `Provider` | Once in `Provider` → `Value.controlPresentation` | Once in outer `dynamicIsland` + `LockScreenLiveActivityView` |
| Metadata | Once in `Provider` → `entry.widgetNowPlayingDisplayModel` | N/A (not shown) | Once in outer `dynamicIsland` + `LockScreenLiveActivityView` |

Leaf views (`WidgetMetadataRegion`, play/pause buttons) must not re-derive canonical mapping rules.

### Non-Forcing Refresh Model

`WidgetRefreshManager.refreshIfNeeded` is invoked from **many** imperative call sites (SharedPlayerManager saves, AppDelegate, SceneDelegate, coordinator, ViewController, widget intents) **and** from the internal `PlayerEvent` observer. Duplicate triggers are harmless (debounce/coalesce/regress guards). Future consolidation is Tier 3 (late stage); see Event-Driven Roadmap Tier 4 inventory.

---

## Open Issues (Tracked Outside Tier Backlog)

### OI-W1 — Force-quit liveness window (accepted)

**Status:** Documented, no code change planned

After abrupt force-quit, `lastUpdateTime` may remain non-zero for up to **60 seconds**, so widgets can briefly show interactive chrome instead of "tap_to_open". Termination notification paths write sentinel `0` immediately; force-quit cannot. Documented in `LutheranRadioWidget.swift` (`isAppRunning()`), `Widget-Presentation-Dataflow.md`, and `SharedPlayerManager` resurrection tables.

**SeeAlso:** `forceStaleLivenessTimestampForTermination()`, `isMainAppProcessRecentlyActive()`.

### OI-W2 — Widget extension cannot observe `PlayerEvent` (permanent)

**Status:** By design

Emission is guarded to the main app (`isRunningInWidgetProcess`). Extension processes rely on snapshot reads + `refreshVisualStateFromPersistence()` hygiene. Any future "consolidation" must preserve optimistic `forcePersistVisualState` and provider read-refresh.

**SeeAlso:** Event-Driven Refactor Roadmap "Cross-process and extension reality".

### OI-W3 — No widget extension unit test target

**Status:** Open gap

All widget contract tests run in `Lutheran RadioTests` (main-app host) via DEBUG seams and white-box helpers. There is no `LutheranRadioWidgetTests` target for `WidgetDisplayModels` resolver rules, `SimpleEntry` synthesis, or snapshot fixture tests. Resolver and Provider logic is protected only indirectly.

### OI-W4 — Now Playing + Live Activity stacking (user education / strategy)

**Status:** Documented (2026-07-14); dual-card UX accepted

iOS renders **both** system Now Playing and Live Activity when both are active — expected behavior, not a bug. Program metadata is aligned via `StreamProgramMetadata.nowPlayingDisplayStrings(...)`. Stacking scenarios, LA start policy, metadata push cost, and QA screenshot matrix are canonical in [`docs/Live-Activity-Stacking-and-Media-Surfaces.md`](Live-Activity-Stacking-and-Media-Surfaces.md). Coordinated refresh uses ``SharedPlayerManager/refreshAllMediaSurfaces(liveActivity:widgetRefresh:widgetRefreshImmediate:)``.

**SeeAlso:** `SharedPlayerManager+NowPlaying.swift`, `RadioLiveActivityManager.swift`, `StreamProgramMetadata.swift`.

---

## Remaining Backlog (Prioritized for Slow, Safe Progress)

Ordered by increasing risk and decreasing isolation. Earlier items are safer.

### Tier 1 – Presentation Surface Hygiene (Low Risk, High Value)

**Goal:** Complete the narrow-input presentation migration (see `Widget-Presentation-Dataflow.md`). No behavior change.

- [x] Introduce `PlayerControlPresentation` + `makeControlPresentation()` and migrate all control-glyph sites (2026-06-27).
- [x] Pre-derive `widgetNowPlayingDisplayModel` onto `SimpleEntry` in Provider (widgets).
- [x] Hoist metadata + control derivation to outer `dynamicIsland` closure.
- [x] **Narrow family view inputs (2026-07-13):** `SmallWidgetView` / `MediumWidgetView` / `LargeWidgetView` accept explicit slices (`statusPresentation`, `controlPresentation`, `metadataModel`, `currentStation`, `currentLanguageCode`, `availableStreams`); projected at `LutheranRadioWidgetEntryView`. No `visualState` on family views (semantic policy not required in bodies).
- [x] **LA expanded-region status dedup (2026-07-13):** `statusPres` hoisted in outer `dynamicIsland` closure; expanded `.center`, `.bottom`, and `minimal` close over it (no inline `makeStatusPresentation()` in region builders).
- [x] **Control widget provider pre-derivation (2026-07-13):** `LutheranRadioWidgetControl.Value` stores `statusPresentation` + `controlPresentation`; `Provider` derives once; toggle label reads narrow fields only (symmetric with `SimpleEntry`).
- [ ] **Optional `WidgetDisplayProjection` bundle:** Single `Equatable` struct bundling the three presentation surfaces for explicit Provider → view handoff. Only if narrow-parameter migration proves noisy.

**Rule:** Presentation-only. No changes to snapshot writes, intents, or refresh timing.

### Tier 2 – Cross-Process Intent & Snapshot Contracts (Medium Risk)

**Goal:** Protect widget/LA/Control intent round-trips and optimistic snapshot semantics with fast unit tests (main-app host + DEBUG seams).

- [x] **`widgetNowPlayingDisplayModel` resolver matrix (2026-07-13):** `WidgetDisplayModelsTests.swift` — title/speaker/emphasis for every `PlayerVisualState` × metadata presence/absence × language fallback. Pure function; no WidgetCenter IPC.
- [x] **Pending-action dedup contract (2026-07-13):** `WidgetIntentContractTests` — rapid schedule replaces pending; `clearPendingAction(actionId:)` ignores stale IDs; `getPendingActionIfFresh` clears expired `pendingActionTime`.
- [x] **Optimistic `persistOptimisticWidgetSnapshot` contract (2026-07-13):** `WidgetIntentContractTests.testPersistOptimisticWidgetSnapshotWritesSnapshotWithoutPlayerEventYield` + authoritative overwrite + pending preservation; extends `testEmitSuppressesYieldWhenRunningInWidgetProcess`.
- [x] **Rename `forcePersistVisualState` → `persistOptimisticWidgetSnapshot` (2026-07-13):** Renamed public API; deprecated `forcePersistVisualState` forwarding wrapper retained; `///` headers updated in `SharedPlayerManager.swift`.
- [x] **Widget switch SSOT regression (2026-07-13):** `WidgetIntentContractTests` — paused optimistic snapshot preserved on widget switch; `handleWidgetSwitchToLanguage` paused reconciliation + `processedActionIds` dedup (checklist §6.11 / §6.13).
- [x] **Instant-feedback expiry (2026-07-13):** `WidgetIntentContractTests` — `loadSharedState` prefers instant-feedback within 15 s, falls back after expiry.

**Rule:** Use UITestMode / DEBUG seams; never call real `WidgetCenter.reloadTimelines` or ActivityKit IPC in unit tests. Follow fast-test patterns in `CODING_AGENT.md`.

### Tier 3 – Refresh & Provider Orchestration (Medium–High Risk, Late Stage)

**Goal:** Reduce redundant work without altering observable widget behavior.

**Scope:** Consolidation here is **main-app `refreshIfNeeded` call-site dedup only** — not replacing the snapshot model, not streaming `PlayerEvent` across process boundaries, and not removing optimistic extension writes or provider read-refresh hygiene.

- [x] **Provider `refreshVisualStateFromPersistence` audit (2026-07-13):** Documented in **Provider snapshot audit** below and implemented via ``WidgetProviderSnapshotResolver`` in `WidgetDisplayModels.swift`. Home-widget and Control-widget Providers call ``resolveWithActorHygiene(manager:)``; snapshot fields remain static ``loadPersistedWidgetState()`` reads. Actor hop retained for extension hygiene (not removed — device-proven removal deferred).
- [x] **Imperative `refreshIfNeeded` deduplication (main app only, 2026-07-13):** Removed duplicate imperative calls from ``performActualSave``, ``didUpdateStreamMetadata``, and ``RadioPlayerCoordinator/updateUserDefaultsLanguage``. Tier 2 observer is now the sole driver for mutation-path timeline reloads; ``refreshUsesImmediateDelivery(for:hasError:)`` extended for sticky-pause and error urgency parity. Retained imperative paths: lifecycle/teardown (`performSessionAndWidgetTeardown`, ``performPostStopWidgetHygiene``, termination), AppDelegate foreground, widget-extension optimistic intents, widget-process ``handleWidgetPlay``/``handleWidgetStop`` delayed refresh.
- [x] **Widget-action polling timer evaluation (2026-07-13):** Removed `ViewController.setupWidgetActionPolling()` (30 s repeating timer). Darwin notify + 1…5 s launch burst + `SceneDelegate` become-active/foreground hooks are sufficient; background timers are unreliable while suspended.
- [x] **Control widget value-provider freshness (2026-07-13):** ``LutheranRadioWidgetControl/Provider`` uses ``WidgetProviderSnapshotResolver`` (symmetric hygiene with home-widget ``getPendingOrCurrentState``).

**Rule:** Nothing removed until event + imperative paths produce identical observable widget/LA behavior on device.

#### Provider snapshot audit (canonical)

| Provider path | Actor hop (`refreshVisualStateFromPersistence`) | Snapshot read | Notes |
|---------------|--------------------------------------------------|---------------|-------|
| Home widget `placeholder` | No | N/A (synthetic `.prePlay`) | Static preview only |
| Home widget `snapshot` / `timeline` / `createEntry` | **Yes** (via ``WidgetProviderSnapshotResolver``) | ``loadPersistedWidgetState()`` only | Never falls back to ``currentVisualState``; hop resets loaded-guard for long-lived extension processes |
| Control widget `previewValue` | No | N/A (synthetic `.prePlay`) | Static preview only |
| Control widget `currentValue` | **Yes** (via resolver) | ``loadPersistedWidgetState()`` primary | Actor fallback when App Group unavailable or snapshot absent |
| Widget AppIntent optimistic (`ToggleRadioIntent`, etc.) | No | ``loadPersistedWidgetState()`` before write | Followed by extension-local ``refreshIfNeeded(..., immediate: true)`` |

**Safe direct-read rule:** Code that reads **only** ``loadPersistedWidgetState()`` / ``resolveFromSnapshot()`` and never ``currentVisualState`` could skip the actor hop in theory; Providers keep the hop as permanent extension hygiene until device-proven otherwise.

#### Imperative `refreshIfNeeded` inventory post-dedup

| Caller | Status | Reason |
|--------|--------|--------|
| ``WidgetRefreshManager/handlePlayerEvent`` | **Primary** (mutation path) | Tier 2 observer; urgency via ``refreshUsesImmediateDelivery`` |
| ``performActualSave`` | Removed (2026-07-13) | Duplicate with observer + ``cancelPendingRefresh`` retained |
| ``didUpdateStreamMetadata`` | Removed (2026-07-13) | ``metadataDidUpdate`` + ``persistedWidgetStateDidUpdate`` |
| ``updateUserDefaultsLanguage`` | Removed (2026-07-13) | ``persistedWidgetStateDidUpdate``; language branch in ``refreshIfNeeded`` |
| ``performSessionAndWidgetTeardown`` / ``performPostStopWidgetHygiene`` / termination | Retained | Lifecycle + explicit ``reloadAllTimelines`` |
| `AppDelegate.applicationWillEnterForeground` | Retained | Foreground liveness; no ``PlayerEvent`` |
| Widget extension intents | Retained | Cross-process optimistic; no event emission in extension |
| Widget-process ``handleWidgetPlay``/``handleWidgetStop`` | Retained | Extension-only; ``emit`` guarded |

### Tier 4 – Media Surface Coordination (Cross-Cutting)

**Goal:** Keep Now Playing, Live Activity, and widget metadata visually aligned without duplicating formatters.

- [x] **Shared metadata formatter:** `StreamProgramMetadata.nowPlayingDisplayStrings(...)` SSOT; `updateNowPlayingInfo()` delegates; language-switch metadata clear triggers immediate Now Playing update.
- [x] **Stacking & LA policy validation (2026-07-14):** [`docs/Live-Activity-Stacking-and-Media-Surfaces.md`](Live-Activity-Stacking-and-Media-Surfaces.md) — LA start policy, stacking matrix, metadata push cost (`lastPushedContent` dedup), manual QA screenshot scenarios.
- [x] **`refreshAllMediaSurfaces()` wrapper (2026-07-14):** ``SharedPlayerManager/refreshAllMediaSurfaces(liveActivity:widgetRefresh:widgetRefreshImmediate:)`` in `SharedPlayerManager+NowPlaying.swift`; consolidated `setPlaying` / `stop` / pause surfaces; fixed `markAsUserPaused` / `markPlaybackStoppedByStreamFailure` LA drift; removed redundant coordinator NP+LA duplicates.

**Rule:** No security surface changes. Metadata formatters stay in shared non-Core types.

### Tier 5 – Documentation & Tests

**Goal:** Close OI-W3 and make widget contracts discoverable alongside the event-driven roadmap.

- [x] [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md) — canonical presentation reference.
- [x] README SSOT widget presentation subsection + Architecture DocC event-driven section (cross-links widgets).
- [x] `WidgetRefreshManager` consumer test suite (19 tests) + teardown/post-stop + liveness + cold-launch factory reset.
- [x] **This roadmap** — living document; update after each micro-step.
- [x] **Cross-link from Event-Driven Refactor Roadmap (2026-07-13):** Tier 3 completion entry + mutation-path dedup inventory cross-link added.
- [x] **README subsection (2026-07-14):** "Widget & Live Activity functionality" table (presentation, stacking doc, wrapper, test index).
- [ ] **Tier 2 test items above** — track completion here with test method names.

**Tier 5 complete when:** Tier 2 checklist is green, OI-W3 has a documented test strategy (even if extension target remains deferred), and all touched files carry production `///` docs with `SeeAlso:` to this roadmap.

---

## Identified Candidates for Future Consolidation

Authoritative inventory (no behavior change until device-proven). Mirrors Event-Driven Roadmap Tier 4 style.

**1. Legacy forcing & lifecycle shims (permanent)**

- `persistOptimisticWidgetSnapshot` (formerly `forcePersistVisualState`) — widget optimistic instant feedback; permanent infrastructure, not a removal target.
- `forceStaleLivenessTimestampForTermination` — process-lifecycle sentinel; not a player event.
- `refreshVisualStateFromPersistence` / `syncVisualStateFromPersistence` — extension hygiene; expected to remain.

**2. Imperative `refreshIfNeeded` call sites (parallel to event observer)**

SharedPlayerManager saves, AppDelegate, SceneDelegate, RadioPlayerCoordinator, ViewController, widget intents, Now Playing shim. See Event-Driven Roadmap Tier 4 §2 for full call-site list.

**3. Provider persistence refresh on every timeline request**

```swift
await manager.refreshVisualStateFromPersistence()
if let combined = SharedPlayerManager.loadPersistedWidgetState() { ... }
```

Present in `LutheranRadioWidget.swift:getPendingOrCurrentState` and `LutheranRadioWidgetControl.swift`. WidgetKit-driven, not a CPU poll loop. Late-stage: rely more on main-app `reloadTimelines` so refresh hop is optional.

**4. Fallback timers (non-candidates or demoted)**

- LA `updateTimer` — demoted; not started by default.
- ViewController widget-action polling (30 s) — complements Darwin; Tier 3 audit.
- ViewController connectivity timer (5 s) — unrelated to widget presentation.

**5. Surfaces already event-driven or complete**

- `WidgetRefreshManager` `PlayerEvent` observer.
- `RadioLiveActivityManager` `contentUpdates` via `WidgetEventObserver`.
- Provider pre-derivation of three presentation surfaces.
- Session teardown + post-stop hygiene.

**Selection criteria:** Identical to Event-Driven Roadmap Tier 4 — multiple independent consumers, weeks on device, tiny isolated edits, documentation upgrade, full build + test gates.

---

## Selecting and Implementing Micro-Steps

The next item is always the highest-priority unchecked entry in the backlog above.

**Recommended starting order (2026-07-14):**

1. Tier 1 optional `WidgetDisplayProjection` bundle (only if future call-site churn warrants it).
2. Tier 5 remaining test-index maintenance as new contracts land.

Each micro-step: read target files first, minimal diff, apply the documentation voice & reference discipline above, update this roadmap Completed + Update Log, run build + test gates per `CODING_AGENT.md`.

An item is marked complete only when wired, documented, and the project compiles with zero warnings.

---

## Usage of This Document

This file is the **single source of truth for widget-specific backlog and architecture status**.

Contributors consult it when touching:

- `LutheranRadioWidget/` (home widgets, Control widget, LA views, intents)
- `WidgetDisplayModels.swift`
- `WidgetRefreshManager.swift`
- Widget-related surfaces in `SharedPlayerManager.swift` (persistence, intents, liveness, `forcePersist*`)
- Widget-adjacent tests

When a backlog item splits or priorities shift, update this document in the same change.

For player **event** emission and `PlayerEvent` consumers, use [`docs/Event-Driven-Refactor-Roadmap.md`](Event-Driven-Refactor-Roadmap.md).

For presentation mapping rules and termination invariants, use [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md).

---

## Update Log

- **2026-07-14:** Tier 4 complete — [`docs/Live-Activity-Stacking-and-Media-Surfaces.md`](Live-Activity-Stacking-and-Media-Surfaces.md) (stacking matrix, LA start policy, push-cost validation); ``refreshAllMediaSurfaces`` wrapper + call-site consolidation; OI-W4 closed; README functionality table; `testRefreshAllMediaSurfacesCompletesAndOptionalWidgetRefreshPassesGates`.
- **2026-07-13:** Tier 3 complete — ``WidgetProviderSnapshotResolver`` + provider audit table; imperative ``refreshIfNeeded`` dedup in ``performActualSave``, ``didUpdateStreamMetadata``, ``updateUserDefaultsLanguage``; ``refreshUsesImmediateDelivery`` urgency parity on event path; removed `setupWidgetActionPolling`; Control widget Provider aligned with home-widget hygiene; tests in `WidgetRefreshManagerEventTests` + `WidgetDisplayModelsTests`.
- **2026-07-13:** Tier 2 complete — `WidgetDisplayModelsTests.swift` (resolver matrix), `WidgetIntentContractTests.swift` (pending-action dedup, instant-feedback expiry, optimistic persist contract, widget switch SSOT); `forcePersistVisualState` renamed to `persistOptimisticWidgetSnapshot` with deprecated forwarding wrapper.
- **2026-07-13:** Tier 1 — Control widget `Value` pre-derivation (`statusPresentation` + `controlPresentation` in Provider; toggle label consumes narrow fields; symmetric with `SimpleEntry`).
- **2026-07-13:** Core Principles — added **Documentation voice & reference discipline** (production-grade source language; cross-links only to committed, tracked docs).
- **2026-07-13:** Tier 1 complete — narrow family view inputs (`LutheranRadioWidgetEntryView` projection) and LA expanded-region `statusPres` dedup (outer `dynamicIsland` closure).
- **2026-07-10:** Tier 2 backlog: rename `forcePersistVisualState` → `persistOptimisticWidgetSnapshot` (permanent widget infrastructure naming); consolidation inventory updated.
- **2026-07-10:** Added **Target Architecture (Ultimate Goal)** section (two-zone hybrid model, permanent snapshot cross-process boundary, definition of “done”) and Tier 3 scope note clarifying consolidation is main-app refresh dedup only.
- **2026-07-10:** Initial roadmap drafted from codebase inventory + canonical docs (`Widget-Presentation-Dataflow.md`, `Event-Driven-Refactor-Roadmap.md`, `cold-launch-streamplay-regression-checklist.md`, `SharedPlayerManager+NowPlaying.swift`, `StreamProgramMetadata.swift`). Completed section consolidates control presentation migration, Provider/LA pre-derivation, memory-only snapshot policy, refresh/teardown/event-consumer tests, and cross-process intent SSOT. Open issues OI-W1–W4 recorded. Backlog Tiers 1–5 populated; Tier 2 tests and Tier 1 presentation hygiene are highest priority.

---

This document is consulted at the beginning of any work on widget, Control widget, or Live Activity **functionality** (as distinct from player event emission).