# Widget Functionality Roadmap

**Purpose**

This document is the authoritative living record of **WidgetKit home-screen widgets**, the **Control Center control widget**, and **ActivityKit Live Activity presentation** in Lutheran Radio — including cross-process state, App Intents, timeline refresh, and the snapshot-driven presentation model.

It serves as both the project backlog for remaining widget work and a self-contained reference for developers and coding agents. It complements (does not replace) the player **event** backlog in [`docs/Event-Driven-Refactor-Roadmap.md`](Event-Driven-Refactor-Roadmap.md) and the presentation contract in [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md).

**Core Principles (Never Violate)**

- Progress must be **slow and piece-by-piece**. Every micro-step must be small, reviewable, and non-breaking.
- **Nothing is forced**: Imperative snapshot reads, direct `refreshIfNeeded` calls, Darwin notification round-trips, and widget optimistic writes remain primary. Event-driven refresh and additive observation run in parallel (see Event-Driven Refactor Roadmap).
- All comments and documentation must be written at **production level** (present tense, final architecture language). No "phase", "step", "temporary", "will be", or migration language is allowed in source.
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
- **Live Activity outer-closure pre-derivation complete:** `dynamicIsland` closure hoists `controlPres`, `metadataModel`, `isPlaying`, and `radioIconTint` once; `LockScreenLiveActivityView` derives status/metadata/control at the top of `body`.
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

| Surface | WidgetKit (`SimpleEntry`) | ActivityKit (`ContentState` views) |
|---------|---------------------------|-------------------------------------|
| Status | Once in `Provider` | Once at top of `LockScreenLiveActivityView`; some expanded DI regions still call `makeStatusPresentation()` inline |
| Control | Once in `Provider` | Once in outer `dynamicIsland` + `LockScreenLiveActivityView` |
| Metadata | Once in `Provider` → `entry.widgetNowPlayingDisplayModel` | Once in outer `dynamicIsland` + `LockScreenLiveActivityView` |

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

**Status:** Partially addressed; strategic validation open

iOS renders **both** system Now Playing and Live Activity when both are active — expected behavior, not a bug. Program metadata is aligned via `StreamProgramMetadata.nowPlayingDisplayStrings(...)`, but the dual-card UX remains. Open work: document LA start policy (foreground start on first `.playing` is intentional), capture stacking scenarios with/without user-added lock widgets, and confirm metadata push cost is negligible.

**SeeAlso:** `SharedPlayerManager+NowPlaying.swift`, `RadioLiveActivityManager.swift`, `StreamProgramMetadata.swift`.

---

## Remaining Backlog (Prioritized for Slow, Safe Progress)

Ordered by increasing risk and decreasing isolation. Earlier items are safer.

### Tier 1 – Presentation Surface Hygiene (Low Risk, High Value)

**Goal:** Complete the narrow-input presentation migration (see `Widget-Presentation-Dataflow.md`). No behavior change.

- [x] Introduce `PlayerControlPresentation` + `makeControlPresentation()` and migrate all control-glyph sites (2026-06-27).
- [x] Pre-derive `widgetNowPlayingDisplayModel` onto `SimpleEntry` in Provider (widgets).
- [x] Hoist metadata + control derivation to outer `dynamicIsland` closure.
- [ ] **Narrow family view inputs:** Change `SmallWidgetView` / `MediumWidgetView` / `LargeWidgetView` to accept explicit slices (`statusPresentation`, `controlPresentation`, `metadataModel`, `currentLanguageCode`, `availableStreams`, `visualState` only where semantic policy required) instead of full `SimpleEntry`. Project at `LutheranRadioWidgetEntryView` level. Reduces WidgetKit invalidation surface when unrelated `SimpleEntry` fields change.
- [ ] **LA expanded-region status dedup:** Remove remaining inline `makeStatusPresentation()` calls inside Dynamic Island expanded regions (lines ~428, ~484, ~587 in `LutheranRadioWidgetLiveActivity.swift`); close over hoisted `statusPres` from outer closure (Lock Screen path already hoists).
- [ ] **Optional `WidgetDisplayProjection` bundle:** Single `Equatable` struct bundling the three presentation surfaces for explicit Provider → view handoff. Only if narrow-parameter migration proves noisy.

**Rule:** Presentation-only. No changes to snapshot writes, intents, or refresh timing.

### Tier 2 – Cross-Process Intent & Snapshot Contracts (Medium Risk)

**Goal:** Protect widget/LA/Control intent round-trips and optimistic snapshot semantics with fast unit tests (main-app host + DEBUG seams).

- [ ] **`widgetNowPlayingDisplayModel` resolver matrix:** New `WidgetDisplayModelsTests.swift` (or section in existing test target) asserting title/speaker/emphasis for every `PlayerVisualState` × metadata presence/absence × language fallback. Pure function; no WidgetCenter IPC.
- [ ] **Pending-action dedup contract:** Test `scheduleWidgetAction` / `clearPendingAction(actionId:)` — rapid double-tap produces one processing path; stale `pendingActionTime` ignored by providers.
- [ ] **Optimistic `forcePersistVisualState` contract:** Snapshot visual + optional language written in widget context; main-app authoritative save overwrites without corrupting intent; no `PlayerEvent` yield under simulated widget process (extends existing `testEmitSuppressesYieldWhenRunningInWidgetProcess`).
- [ ] **Widget switch SSOT regression:** Automated coverage for checklist §6 — `handleWidgetSwitchToLanguage` → model-only `switchToStream` → single `stop(.streamSwitch)` → `play()`; selector needle matches audible stream (2026-06-12 desync fix must not regress). See `ViewController.handleWidgetSwitchToLanguage`, `RadioPlayerCoordinator`, `SharedPlayerManager.handleWidgetSwitch`.
- [ ] **Instant-feedback expiry:** Assert `loadSharedState` prefers instant-feedback tuple within 15 s window, then falls back to authoritative snapshot.

**Rule:** Use UITestMode / DEBUG seams; never call real `WidgetCenter.reloadTimelines` or ActivityKit IPC in unit tests. Follow fast-test patterns in `CODING_AGENT.md`.

### Tier 3 – Refresh & Provider Orchestration (Medium–High Risk, Late Stage)

**Goal:** Reduce redundant work without altering observable widget behavior.

- [ ] **Provider `refreshVisualStateFromPersistence` audit:** Document which Provider paths require the actor hop vs. safe direct `loadPersistedWidgetState` after main-app `reloadTimelines`. Any removal gated on device-proven timeline freshness.
- [ ] **Imperative `refreshIfNeeded` deduplication (main app only):** After event path is device-proven for weeks, audit duplicate call sites inside SharedPlayerManager mutation paths (Event-Driven Roadmap Tier 4 inventory §2). Observer becomes sole driver only when proven identical timing/coalescing/privacy behavior.
- [ ] **Widget-action polling timer evaluation:** `ViewController.setupWidgetActionPolling()` (30 s) complements Darwin listener — measure whether event-driven + foreground `checkForPendingWidgetActions` makes it removable (very late).
- [ ] **Control widget value-provider freshness:** Verify `LutheranRadioWidgetControl.Provider` read path matches home-widget Provider hygiene after long-lived extension process (read-refresh guard).

**Rule:** Nothing removed until event + imperative paths produce identical observable widget/LA behavior on device.

### Tier 4 – Media Surface Coordination (Cross-Cutting)

**Goal:** Keep Now Playing, Live Activity, and widget metadata visually aligned without duplicating formatters.

- [x] **Shared metadata formatter:** `StreamProgramMetadata.nowPlayingDisplayStrings(...)` SSOT; `updateNowPlayingInfo()` delegates; language-switch metadata clear triggers immediate Now Playing update.
- [ ] **Stacking & LA policy validation:** Document LA start policy (foreground start on first `.playing` is intentional); capture stacking screenshots with/without user-added lock widgets; confirm metadata push cost is negligible.
- [ ] **Thin `refreshAllMediaSurfaces()` wrapper (optional):** Actor method calling Now Playing update + LA update + `WidgetRefreshManager.refreshIfNeeded` to prevent drift. Add only if call-site audit shows divergence risk.

**Rule:** No security surface changes. Metadata formatters stay in shared non-Core types.

### Tier 5 – Documentation & Tests

**Goal:** Close OI-W3 and make widget contracts discoverable alongside the event-driven roadmap.

- [x] [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md) — canonical presentation reference.
- [x] README SSOT widget presentation subsection + Architecture DocC event-driven section (cross-links widgets).
- [x] `WidgetRefreshManager` consumer test suite (19 tests) + teardown/post-stop + liveness + cold-launch factory reset.
- [ ] **This roadmap** — initial draft (2026-07-10). Update after each micro-step.
- [ ] **Cross-link from Event-Driven Refactor Roadmap** — add SeeAlso entry pointing here for widget-specific backlog.
- [ ] **DocC article or README subsection:** "Widget & Live Activity Functionality" summarizing intent table, App Group keys, and test file index (if this roadmap grows too large for README).
- [ ] **Tier 2 test items above** — track completion here with test method names.

**Tier 5 complete when:** Tier 2 checklist is green, OI-W3 has a documented test strategy (even if extension target remains deferred), and all touched files carry production `///` docs with `SeeAlso:` to this roadmap.

---

## Identified Candidates for Future Consolidation

Authoritative inventory (no behavior change until device-proven). Mirrors Event-Driven Roadmap Tier 4 style.

**1. Legacy forcing & lifecycle shims (permanent)**

- `forcePersistVisualState` — widget optimistic instant feedback; cannot remove.
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

**Recommended starting order (2026-07-10):**

1. Tier 2 `widgetNowPlayingDisplayModel` resolver tests (pure, fast, high value for OI-W3).
2. Tier 1 narrow family view inputs (presentation-only, no IPC).
3. Tier 1 LA expanded-region status dedup (small diff in one file).

Each micro-step: read target files first, minimal diff, production docs, update this roadmap Completed + Update Log, run build + test gates per `CODING_AGENT.md`.

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

- **2026-07-10:** Initial roadmap drafted from codebase inventory + canonical docs (`Widget-Presentation-Dataflow.md`, `Event-Driven-Refactor-Roadmap.md`, `cold-launch-streamplay-regression-checklist.md`, `SharedPlayerManager+NowPlaying.swift`, `StreamProgramMetadata.swift`). Completed section consolidates control presentation migration, Provider/LA pre-derivation, memory-only snapshot policy, refresh/teardown/event-consumer tests, and cross-process intent SSOT. Open issues OI-W1–W4 recorded. Backlog Tiers 1–5 populated; Tier 2 tests and Tier 1 presentation hygiene are highest priority.

---

This document is consulted at the beginning of any work on widget, Control widget, or Live Activity **functionality** (as distinct from player event emission).