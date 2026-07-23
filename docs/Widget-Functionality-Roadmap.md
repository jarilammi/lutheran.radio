# Widget Functionality Roadmap

**Purpose**

This document is the authoritative living record of **WidgetKit home-screen widgets**, the **Control Center control widget**, and **ActivityKit Live Activity presentation** in Lutheran Radio — including cross-process state, App Intents, timeline refresh, and the snapshot-driven presentation model.

It serves as both the project backlog for remaining widget work and a self-contained reference for developers and coding agents. It complements (does not replace) the player **event** backlog in [`docs/Event-Driven-Refactor-Roadmap.md`](Event-Driven-Refactor-Roadmap.md) and the presentation contract in [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md).

**Target Architecture (Ultimate Goal)**

The finish line is a **hybrid, two-zone model** — not a migration from snapshots to cross-process events. WidgetKit and ActivityKit require frozen value-type snapshots; that constraint is permanent.

| Zone | Mechanism | Ultimate state |
|------|-----------|----------------|
| Main app | `SharedPlayerManager` actor + imperative snapshot saves + `PlayerEvent` | Hybrid: events are an **additive** in-process consumer path; authoritative mutations and snapshot writes remain primary |
| Extension + LA presentation | `PersistedWidgetState` → `SimpleEntry` / `ContentState` + `reloadTimelines` / LA push | **Snapshot-driven permanently**; extension never observes `PlayerEvent` |

**Cross-process (widgets, Control Center, Live Activity UI)**

- Frozen value-type snapshots are the permanent integration model. See [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md).
- Freshness stacks: session snapshot (`loadPersistedWidgetState` / `savePersistedWidgetState`), App Group optimistic instant-feedback keys, pending-action round-trips, and main-app-driven `WidgetRefreshManager.refreshIfNeeded` / `WidgetCenter.reloadTimelines`.
- Live Activity hot path uses in-memory pushes from `RadioLiveActivityManager`; widgets and Control widgets read persisted snapshots.

**Presentation**

- Three narrow, `Equatable` surfaces derived **once per snapshot**: `PlayerStatusPresentation`, `PlayerControlPresentation`, `WidgetNowPlayingDisplayModel`.
- Leaf views and LA regions consume explicit slices — not full `PlayerVisualState` policy re-derived in `body`.

**Commands & shims (permanent infrastructure)**

- Optimistic ``persistOptimisticWidgetSnapshot``, `refreshVisualStateFromPersistence`, liveness sentinel (`lastUpdateTime = 0`), and pending-action App Group keys are permanent cross-process surfaces. Main-app refresh consolidation does not remove them.

**What “done” means**

- **Required:** Tier 1 presentation hygiene + Tier 2 snapshot/intent test contracts (main-app test host + `WidgetSurface` coordinators).
- **Optional, late-stage:** Tier 3–4 main-app refresh dedup and media-surface coordination — observable widget/LA behavior unchanged; no architectural model change.

**Core Principles (Never Violate)**

- Progress must be **slow and piece-by-piece**. Every micro-step must be small, reviewable, and non-breaking.
- **Nothing is forced**: Imperative snapshot reads, direct `refreshIfNeeded` calls, Darwin notification round-trips, and widget optimistic writes remain primary. Event-driven refresh and additive observation run in parallel (see Event-Driven Refactor Roadmap).
- **Documentation standards & canonical references** (applies to every touched file, including this roadmap):
  - **Describe what ships today:** Comments and `///` documentation describe the system as it exists *now* — present tense, final architecture language. Source must not read like a plan in progress: no "phase", "step", "temporary", "will be", "TODO migrate", or migration scaffolding in production code.
  - **Link only to committed docs:** `SeeAlso:`, file headers, and cross-links cite documents that are **committed and tracked** on the branch being edited. Staged-but-unmerged drafts, untracked scratch files, agent prompts, and one-off analysis notes are not authoritative until they ship — do not point future readers at them. When uncertain whether a path is canonical, confirm with `git ls-files <path>` (empty output means do not cite).
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
| `WidgetSurface/` | Presentation-only embedded framework: intent coordinators, timeline factory, liveness policy, narrow display models, language chrome, pure Provider presentation assembly |
| Membership-exception `WidgetDisplayModels.swift` | ``WidgetIntentExecution`` + ``WidgetProviderSnapshotResolver`` (SPM-coupled hygiene / catalog labels) |
| `SharedPlayerManager+NowPlaying.swift`, `StreamProgramMetadata.swift` | Now Playing metadata SSOT (`nowPlayingDisplayStrings`) shared with widget/LA formatters |
| `README.md` (SSOT section) | Index + cross-links |
| ``<doc:Architecture>`` (Core DocC) | Event-driven player architecture + cross-process widget reality |

---

**Current State (as of 2026-07-18)**

## Completed

### Presentation & Display Model

- **Three narrow presentation surfaces** established and documented: `PlayerStatusPresentation` (`makeStatusPresentation()`), `PlayerControlPresentation` (`makeControlPresentation()`), `WidgetNowPlayingDisplayModel` (`widgetNowPlayingDisplayModel(...)`). Status/control mappers live in `WidgetSurface/PlayerVisualState.swift`; metadata/emphasis types and resolver live in `WidgetSurface/WidgetNowPlayingDisplay.swift`. Provider assembly remains in `WidgetDisplayModels.swift`. See [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md).
- **P0 control migration complete (2026-06-27):** All play/pause glyph + tint sites in Small/Medium/Large widgets, Dynamic Island trailing/compactTrailing, Lock Screen, and Control widget consume `PlayerControlPresentation` exclusively. Remaining `isActivelyPlaying` / `buttonTintColor` reads are non-control (LIVE indicator, animation bars, decorative radio glyph) and are documented.
- **Widget Provider pre-derivation complete:** `SimpleEntry` carries `statusPresentation`, `controlPresentation`, and `widgetNowPlayingDisplayModel`, each computed once in `Provider.placeholder`, `snapshot`, `timeline` / `createEntry`. Family views read narrow fields from the entry; `WidgetMetadataRegion` receives only `WidgetNowPlayingDisplayModel`.
- **Live Activity outer-closure pre-derivation complete:** `dynamicIsland` closure hoists `statusPres`, `controlPres`, `metadataModel`, `isPlaying`, and `radioIconTint` once; expanded, compact, and minimal regions close over these values (no inline `makeStatusPresentation()` in region builders). `LockScreenLiveActivityView` derives status/metadata/control at the top of `body`.
- **Narrow family view inputs (2026-07-13):** `LutheranRadioWidgetEntryView` projects explicit slices into `SmallWidgetView` / `MediumWidgetView` / `LargeWidgetView` instead of passing full `SimpleEntry`. Reduces WidgetKit invalidation surface when unrelated entry fields change.
- **Control widget provider pre-derivation (2026-07-13):** `LutheranRadioWidgetControl.Value` carries pre-derived `statusPresentation` and `controlPresentation`; `Provider` derives once per read; toggle label consumes narrow fields only (symmetric with `SimpleEntry`).
- **Exhaustive `#Preview` matrix** in `LutheranRadioWidget.swift` exercises visual states × metadata presence/absence.
- **Canonical presentation reference doc** [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md) (termination invariant, LA event-driven update model, contributor guidance). README SSOT subsection cross-links it.

### Cross-Process State & Intents

- **`PersistedWidgetState` in-process session snapshot** (memory-only visual policy, 2026-07-07): `loadPersistedWidgetState()` reads `inMemorySessionWidgetSnapshot` only; cold launch resets to factory `.prePlay` via `resetToFactoryDefaultsOnLaunch()`. Retired App Group visual/playback/language keys are purged only via ``clearPersistedVisualStateKeysFromDisk()`` (no disk restore). ``preferredWidgetLanguage()`` resolves snapshot → `bestInitialLanguageCode()` when widgets active → hard `"en"` (never bare App Group `currentLanguage`). Resolves event-roadmap **OI-1** for widgets. Protected by `testColdLaunchFactoryResetClearsDiskVisualStateAndReturnsPrePlay` + `testPreferredWidgetLanguageIgnoresRetiredBareCurrentLanguageKey`.
- **App Group + Darwin round-trip** for widget/Control/LA intents: extension writes optimistic snapshot + `pendingAction` (+ `pendingActionId`); main app processes via `checkForPendingWidgetActions` / `handleWidgetAction` / coordinator SSOT paths. Widget pause uses `SharedPlayerManager.stop()` (no duplicated player logic). Widget switch mirrors `completeStreamSwitch` SSOT (**P5-1 shipped**).
- **Optimistic instant feedback** (`isInstantFeedback`, `instantFeedbackTime`, `instantFeedbackLanguage`) for sub-round-trip UI; 15 s validity window.
- **Optimistic snapshot write** ``persistOptimisticWidgetSnapshot(_:language:)`` — permanent widget/LA infrastructure for instant feedback; scoped to extension optimistic paths; `emit(_:)` guard suppresses `PlayerEvent` yields in the widget process.
- **Liveness heuristic SSOT:** `SharedPlayerManager.isMainAppProcessRecentlyActive()` (60 s window + `lastUpdateTime = 0` termination sentinel). Family views delegate the passive-branch decision to ``WidgetLivenessPresentation/shouldShowPassiveTapToOpen(isMainAppRecentlyActive:)`` (heartbeat remains in `SharedPlayerManager`). Protected by `testForceStaleLivenessMakesIsRecentlyActiveFalse_AndBumpRestores`.
- **WidgetSurface intent + entry SSOT (2026-07-14):** ``WidgetIntentCoordinators`` (toggle plans), ``WidgetIntentExecution`` in membership-exception `WidgetDisplayModels.swift` (cross-target side effects), ``WidgetTimelineEntryFactory`` (home/control blueprints). Extension `perform()` and Provider paths are thin delegates. Toggle-mapping tests in `WidgetIntentContractTests` call coordinators directly (no mirror helpers).
- **Pure presentation extraction into WidgetSurface (2026-07-18):** ``displayFlag(for:)`` and pure ``displayLanguageName(for:preferredStreamLanguage:)`` in `WidgetLanguageDisplay.swift`; ``WidgetProviderPresentationAssembly`` owns pure Provider slice assembly. Membership-exception ``WidgetProviderSnapshotResolver`` retains snapshot reads, actor hygiene, stream-catalog station labels, and a thin catalog-aware assemble wrapper. ``WidgetIntentExecution`` remains membership-exception (requires ``SharedPlayerManager`` + ``WidgetRefreshManager``).
- **WidgetSurface + extension-profile tests permanent-doc closeout (2026-07-15):** `CODING_AGENT.md` / `Agents.md` and `README.md` document the two-layer model (`WidgetSurface` + membership-exception SPM sources), default test-plan membership of `LutheranRadioWidgetTests` / `WidgetSurfaceTests`, and widget-only verification commands.
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

- **Event-driven consumer tests:** `WidgetRefreshManagerEventTests.swift` (20), `WidgetEventObserverTests.swift` (6), `RadioLiveActivityManagerTests.swift` attribute-events subset (6), widget-process guards in `SharedPlayerManagerEventTests.swift` / `PlayerEventSubscriberEventTests.swift`.
- **Presentation mapper matrices (2026-07-14):** `PlayerPresentationMapperTests.swift` (9) — `makeStatusPresentation()` and `makeControlPresentation()` for all six `PlayerVisualState` cases; complements `WidgetDisplayModelsTests.swift` metadata resolver coverage.
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
| Visual state (session) | `PersistedWidgetState.visualState` | Main app `savePersistedWidgetState`; widget ``persistOptimisticWidgetSnapshot`` (optimistic) | All Providers, Control widget, `loadSharedState` |
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
| Language chrome (flag + name + alt-stream “current”) | Snapshot `currentLanguage` via Provider assembly / ``preferredWidgetLanguage()`` (home/Control; App Group + session hygiene) | N/A (not shown) | **`ContentState.currentLanguage`** pushed by ``RadioLiveActivityManager`` from main-app stream attach language; views hoist `context.state.currentLanguage` only |

Leaf views (`WidgetMetadataRegion`, play/pause buttons) must not re-derive canonical mapping rules.

### Non-Forcing Refresh Model

`WidgetRefreshManager.refreshIfNeeded` is invoked from **many** imperative call sites (SharedPlayerManager saves, AppDelegate, SceneDelegate, coordinator, ViewController, widget intents) **and** from the internal `PlayerEvent` observer. Duplicate triggers are harmless (debounce/coalesce/regress guards). Future consolidation is Tier 3 (late stage); see Event-Driven Roadmap Tier 4 inventory.

---

## Open Issues (Tracked Outside Tier Backlog)

### Force-quit liveness window (accepted)

**Status:** Documented, no code change planned

After abrupt force-quit, `lastUpdateTime` may remain non-zero for up to **60 seconds**, so widgets can briefly show interactive chrome instead of "tap_to_open". Termination notification paths write sentinel `0` immediately; force-quit cannot. Documented in `LutheranRadioWidget.swift` (via ``WidgetLivenessPresentation``), `Widget-Presentation-Dataflow.md`, and `SharedPlayerManager` resurrection tables.

**SeeAlso:** `forceStaleLivenessTimestampForTermination()`, `isMainAppProcessRecentlyActive()`.

### Widget extension cannot observe `PlayerEvent` (permanent)

**Status:** By design

Emission is guarded to the main app (`isRunningInWidgetProcess`). Extension processes rely on snapshot reads + `refreshVisualStateFromPersistence()` hygiene. Any future "consolidation" must preserve optimistic `persistOptimisticWidgetSnapshot` and provider read-refresh.

**SeeAlso:** Event-Driven Refactor Roadmap "Cross-process and extension reality".

### Widget extension unit test coverage

**Status:** **Closed (2026-07-15)** — `WidgetSurface` framework, extension-profile tests, and permanent-doc closeout ship

Widget contract tests still run in `Lutheran RadioTests` (main-app host) via DEBUG seams. In addition:

| Target | Compile profile | Coverage |
|--------|-----------------|----------|
| `LutheranRadioWidgetTests` | **No** `LUTHERAN_MAIN_APP` (same SPM set as extension) | Coordinators (incl. LA multi-source resolve), factory, liveness, presentation mappers, metadata resolver, Provider assembly, optimistic intent / ``WidgetIntentExecution/perform*`` (home/Control/LA toggle + **LA stream switch**), durable LA toggle mirror, ``displayFlag`` / ``displayLanguageName``, refresh subset |
| `WidgetSurfaceTests` | Pure `WidgetSurface` framework | Swift Testing — coordinators (incl. LA resolve priority), liveness, factory, mappers |

AppIntent `perform()` bodies are thin delegates to ``WidgetIntentExecution/perform*``; those entry points compile and run under the extension profile in `LutheranRadioWidgetTests`. Both targets are in the default `Lutheran Radio.xctestplan`. Permanent agent docs (`CODING_AGENT.md` / `Agents.md`, `README.md`) describe the two-layer model (`WidgetSurface` + membership exceptions).

**SeeAlso:** ``WidgetIntentExecution``, ``WidgetIntentCoordinators``, `LutheranRadioWidgetTests/`, `WidgetSurfaceTests/`, docs/Widget-Presentation-Dataflow.md, CODING_AGENT.md (cross-target widget sources).

### Now Playing + Live Activity stacking (user education / strategy)

**Status:** Documented (2026-07-14); dual-card UX accepted

iOS renders **both** system Now Playing and Live Activity when both are active — expected behavior, not a bug. Program metadata is aligned via `StreamProgramMetadata.nowPlayingDisplayStrings(...)`. Stacking scenarios, LA start policy, metadata push cost, and QA screenshot matrix are canonical in [`docs/Live-Activity-Stacking-and-Media-Surfaces.md`](Live-Activity-Stacking-and-Media-Surfaces.md). Coordinated refresh uses ``SharedPlayerManager/refreshAllMediaSurfaces(liveActivity:widgetRefresh:widgetRefreshImmediate:)``.

**SeeAlso:** `SharedPlayerManager+NowPlaying.swift`, `RadioLiveActivityManager.swift`, `StreamProgramMetadata.swift`.

### Lock-screen Live Activity toggle planning (fixed 2026-07-15; optimistic content 2026-07-18)

**Status:** Fixed

``LiveActivityTogglePlaybackIntent`` must not plan solely from extension-local ``SharedPlayerManager/currentVisualState``. With home-widget write suppression and a memory-only session snapshot, a cold extension defaults to `.prePlay` and inverted the first lock-screen pause into a redundant **play** (audio kept playing). Planning now prefers:

1. ActivityKit ``ContentState/visualState`` (same SSOT as the LA glyph)
2. Durable App Group key ``liveActivityToggleVisualState`` (written on every LA content push; **not** gated by `hasActiveWidgets`)
3. Actor / session-snapshot fallbacks

**SeeAlso:** ``WidgetIntentCoordinators/resolveLiveActivityToggleVisualState(liveActivityContent:durableMirror:actorVisualState:sessionSnapshot:)``, ``WidgetIntentCoordinators/planLiveActivityToggle(resolution:distrustDurableMirrorPlay:)``, ``WidgetIntentExecution/performLiveActivityToggle()``, ``WidgetIntentExecution/pushOptimisticLiveActivityToggleContent(visualState:)``, ``ContentState/replacingVisualState(_:)``, ``RadioLiveActivityManager/recordOptimisticToggleContent(visualState:)``, ``SharedPlayerManager/persistLiveActivityToggleVisualStateMirror(_:)``, ``SharedPlayerManager/shouldDistrustDurableMirrorPlayPlanning()``.

**Hardening (2026-07-15):** Factory reset explicitly clears the durable LA toggle mirror (not only LA-end / termination). After termination sentinel or device reboot (recorded boot identity mismatch), durable mirror alone must not plan **play** — ActivityKit `ContentState` remains trusted for real lock-screen glyphs.

**Optimistic ContentState (2026-07-18):** Toggle intents publish the post-toggle control visual into ActivityKit content (program metadata preserved) and align main-app ``lastPushedContent`` so a rapid second tap resolves from the post-toggle glyph rather than stale pre-tap content. The durable mirror remains the empty-activities fallback.

### Live Activity language chrome SSOT (closed 2026-07-19 — same class as LA toggle visual fix)

**Status:** Closed (2026-07-19)

**Shipped contract**

| Concern | SSOT | Writer | Reader |
|---------|------|--------|--------|
| LA language chrome (flag, name, alt “current”) | `ContentState.currentLanguage` | Main-app ``RadioLiveActivityManager`` on every start/update via ``SharedPlayerManager/liveActivityLanguageCodeForContentPush()`` (stream attach via ``mainAppLiveActivityLanguageCode()`` / ``selectedStream``, or destination language while stream-switch Connecting hold is active — **not** privacy-gated ``preferredWidgetLanguage()`` under no-widgets) | `LockScreenLiveActivityView`, Dynamic Island language chrome — **only** `context.state.currentLanguage` (hoisted once) |
| Durable language mirror | App Group ``liveActivityCurrentLanguage`` | Same push sites as visual mirror; **not** gated by ``hasActiveWidgets``; cleared on LA end, termination, factory reset, privacy clear | ``languageForLiveActivityOrWidgetOptimistic()`` when ActivityKit activities / session snapshot are unavailable |
| Play/pause optimistic language | ContentState language and/or durable mirror | ``performLiveActivityToggle()`` warms language mirror; ``handleWidgetPlay`` / ``handleWidgetStop`` use ``languageForLiveActivityOrWidgetOptimistic()`` | Instant feedback — never bare ``preferredWidgetLanguage()`` alone when mirror/session hold the stream code |

**Why the defect existed (historical):** ContentState carried only visual + metadata; LA views re-derived language via ``preferredWidgetLanguage()``, which hard-defaults to `"en"` under memory-only session + no home widgets while Live Activity remains active.

**Non-goals preserved:** No home-widget write-suppression reopen; no security logic in WidgetSurface; Now Playing artwork policy unchanged.

**SeeAlso:** ``RadioLiveActivityManager/updateCurrentActivity()``, ``SharedPlayerManager/liveActivityLanguageCodeForContentPush()``, ``SharedPlayerManager/mainAppLiveActivityLanguageCode()``, ``SharedPlayerManager/resetToPrePlayForNewStream(preserveActiveSleepTimer:connectingLanguageCode:)``, ``SharedPlayerManager/persistLiveActivityLanguageMirror(_:)``, ``SharedPlayerManager/languageForLiveActivityOrWidgetOptimistic()``, ``WidgetIntentExecution/performLiveActivityToggle()``, ``displayFlag(for:)``, [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md), [`docs/Event-Driven-Refactor-Roadmap.md`](Event-Driven-Refactor-Roadmap.md) (Live Activity language chrome on ContentState shipped).

---

## Remaining Backlog (Prioritized for Slow, Safe Progress)

Ordered by increasing risk and decreasing isolation. Earlier items are safer.

### Tier 1 – Presentation Surface Hygiene (Low Risk, High Value)

**Goal:** Complete the narrow-input presentation migration (see `Widget-Presentation-Dataflow.md`). No behavior change except where an open SSOT gap requires a field on the presentation payload.

- [x] Introduce `PlayerControlPresentation` + `makeControlPresentation()` and migrate all control-glyph sites (2026-06-27).
- [x] Pre-derive `widgetNowPlayingDisplayModel` onto `SimpleEntry` in Provider (widgets).
- [x] Hoist metadata + control derivation to outer `dynamicIsland` closure.
- [x] **Narrow family view inputs (2026-07-13):** `SmallWidgetView` / `MediumWidgetView` / `LargeWidgetView` accept explicit slices (`statusPresentation`, `controlPresentation`, `metadataModel`, `currentStation`, `currentLanguageCode`, `availableStreams`); projected at `LutheranRadioWidgetEntryView`. No `visualState` on family views (semantic policy not required in bodies).
- [x] **LA expanded-region status dedup (2026-07-13):** `statusPres` hoisted in outer `dynamicIsland` closure; expanded `.center`, `.bottom`, and `minimal` close over it (no inline `makeStatusPresentation()` in region builders).
- [x] **Control widget provider pre-derivation (2026-07-13):** `LutheranRadioWidgetControl.Value` stores `statusPresentation` + `controlPresentation`; `Provider` derives once; toggle label reads narrow fields only (symmetric with `SimpleEntry`).
- [x] **Live Activity language on `ContentState` + chrome from `context.state` (2026-07-19):** `currentLanguage` on ``LutheranRadioLiveActivityAttributes.ContentState``; push from ``RadioLiveActivityManager`` via ``mainAppLiveActivityLanguageCode()``; Lock Screen / Dynamic Island language chrome read **only** `context.state.currentLanguage` (hoisted once). Language-only changes force ActivityKit update (`lastPushedContent` equality includes language).
- [x] **LA play/pause optimistic language (2026-07-19):** ``languageForLiveActivityOrWidgetOptimistic()`` prefers session snapshot then durable language mirror before ``preferredWidgetLanguage()``; toggle path warms the language mirror from ContentState.
- [x] **Durable LA language App Group mirror (2026-07-19):** ``liveActivityCurrentLanguage`` — same lifecycle and non-`hasActiveWidgets` gating as ``liveActivityToggleVisualState``.
- [ ] **Optional `WidgetDisplayProjection` bundle:** Single `Equatable` struct bundling the three presentation surfaces for explicit Provider → view handoff. Only if narrow-parameter migration proves noisy.

**Rule:** Presentation SSOT only for the language items; no home-widget privacy regression. No security surface changes.

### Tier 2 – Cross-Process Intent & Snapshot Contracts (Medium Risk)

**Goal:** Protect widget/LA/Control intent round-trips and optimistic snapshot semantics with fast unit tests (main-app host + DEBUG seams).

- [x] **`widgetNowPlayingDisplayModel` resolver matrix (2026-07-13):** `WidgetDisplayModelsTests.swift` — title/speaker/emphasis for every `PlayerVisualState` × metadata presence/absence × language fallback. Pure function; no WidgetCenter IPC.
- [x] **Pending-action dedup contract (2026-07-13):** `WidgetIntentContractTests` — rapid schedule replaces pending; `clearPendingAction(actionId:)` ignores stale IDs; `getPendingActionIfFresh` clears expired `pendingActionTime`.
- [x] **Optimistic `persistOptimisticWidgetSnapshot` contract (2026-07-13):** `WidgetIntentContractTests.testPersistOptimisticWidgetSnapshotWritesSnapshotWithoutPlayerEventYield` + authoritative overwrite + pending preservation; extends `testEmitSuppressesYieldWhenRunningInWidgetProcess`.
- [x] **Rename `forcePersistVisualState` → `persistOptimisticWidgetSnapshot` (2026-07-13; alias retired 2026-07-22):** Public API is ``persistOptimisticWidgetSnapshot(_:language:)`` only; deprecated `forcePersistVisualState` forwarding wrapper removed after zero remaining call sites; canonical docs and SSOT tables use the present-tense name.
- [x] **Widget switch SSOT regression (2026-07-13):** `WidgetIntentContractTests` — paused optimistic snapshot preserved on widget switch; `handleWidgetSwitchToLanguage` paused reconciliation + `processedActionIds` dedup (checklist §6.11 / §6.13).
- [x] **Instant-feedback expiry (2026-07-13):** `WidgetIntentContractTests` — `loadSharedState` prefers instant-feedback within 15 s, falls back after expiry.
- [x] **Play/pause pending-action drain (2026-07-14):** `WidgetIntentContractTests` — optimistic `signalWidgetPendingAction` (play/pause), main-app `checkForPendingWidgetActions` drain (play, pause, double-pause ignore, debounce), Darwin notify + foreground drain, UITestMode drain-only, home-widget and Control-widget toggle mapping matrices + end-to-end signal paths, `handleWidgetPauseAction` coordinator surface (13 tests; method names in Tier 5 play/pause index).
- [x] **Extension-hosted opposite-tap drain + mailbox (2026-07-18):** Same-direction-only 0.65 s debounce (opposite play↔pause always runs); drained play/pause share the media-transport mailbox; pause coordinator path is `async` with no nested Task hop. Unit gates: `testCheckForPendingWidgetActionsAllowsOppositePlayPauseWithinDebounceWindow`, `testCheckForPendingWidgetActionsAllowsOppositePausePlayWithinDebounceWindow` (same-direction debounce retained). Architecture: Live-Activity-Stacking-and-Media-Surfaces (extension-hosted path).
- [x] **Joined optimistic → drain → authoritative state (2026-07-17):** `WidgetIntentContractTests` — multi-phase contracts that join extension-shaped optimistic write + pending signal with main-app drain and authoritative visual/intent postconditions (play and pause); post-drain refresh gate observation without `WidgetCenter` IPC; UITestMode without pending-action bypass clears optimistic play pending without executing. Method names in Tier 5 joined-round-trip index.

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

**Goal:** Complete widget extension test coverage and make widget contracts discoverable alongside the event-driven roadmap.

- [x] [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md) — canonical presentation reference.
- [x] README SSOT widget presentation subsection + Architecture DocC event-driven section (cross-links widgets).
- [x] `WidgetRefreshManager` consumer test suite (20 tests) + teardown/post-stop + liveness + cold-launch factory reset.
- [x] **This roadmap** — living document; update after each micro-step.
- [x] **Cross-link from Event-Driven Refactor Roadmap (2026-07-13):** Tier 3 completion entry + mutation-path dedup inventory cross-link added.
- [x] **README subsection (2026-07-14):** "Widget & Live Activity functionality" table (presentation, stacking doc, wrapper, test index).
- [x] **Presentation mapper test index (2026-07-14):** `PlayerPresentationMapperTests` — `testMakeStatusPresentationMatrixMapsEveryVisualState`, `testMakeStatusPresentationSystemImagePolicyPerVisualState`, `testMakeStatusPresentationProducesNonEmptyLocalizedTextForAllStates`, `testMakeStatusPresentationIsDistinctAcrossAllVisualStates`, `testMakeControlPresentationMatrixMapsEveryVisualState`, `testMakeControlPresentationUsesPauseGlyphOnlyWhenActivelyPlaying`, `testMakeControlPresentationTintMatchesButtonTintColorPolicy`, `testMakeControlPresentationPlayingDiffersFromAllNonPlayingStates`, `testMakeControlPresentationNonPlayingStatesRemainDistinctByTint`.
- [x] **Tier 2 test index (2026-07-13):** `WidgetDisplayModelsTests` (metadata resolver matrix + `WidgetProviderSnapshotResolver`); `WidgetIntentContractTests` (pending-action dedup, instant-feedback expiry, `persistOptimisticWidgetSnapshot`, widget switch SSOT).
- [x] **Tier 2 play/pause drain test index (2026-07-14):** `WidgetIntentContractTests` — `testSignalWidgetPendingActionPlayWritesOptimisticSnapshotAndPending`, `testSignalWidgetPendingActionPauseWritesOptimisticSnapshotAndPending`, `testCheckForPendingWidgetActionsDrainsPlayPending`, `testCheckForPendingWidgetActionsDrainsPausePending`, `testCheckForPendingWidgetActionsIgnoresPauseWhenAlreadyUserPaused`, `testCheckForPendingWidgetActionsDebouncesRapidPlayTaps`, `testNotifyMainAppThenForegroundDrainExecutesPlayPending`, `testUITestModeWithoutBypassDrainsPendingWithoutExecuting`, `testHomeWidgetToggleActionMappingMatrix`, `testControlWidgetToggleActionMappingMatrix`, `testSignalWidgetPendingActionUsesHomeWidgetToggleMapping`, `testSignalWidgetPendingActionUsesControlWidgetToggleMapping`, `testHandleWidgetPauseActionSetsUserPaused`.
- [x] **Joined optimistic→drain round-trip test index (2026-07-17):** `WidgetIntentContractTests` — `testOptimisticPlaySignalThenDrainEstablishesAuthoritativePlayingState`, `testOptimisticPauseSignalThenDrainEstablishesAuthoritativeUserPausedState`, `testOptimisticPlayDrainRequestsWidgetRefreshPassingGuards`, `testOptimisticPlaySignalWithoutPendingBypassClearsWithoutExecuting`.
- [x] **Provider synthesis test index (2026-07-14):** `WidgetDisplayModelsTests` — `resolveWithActorHygiene` hygiene + actor reload; ``WidgetProviderSnapshotResolver/assemblePresentationSlices(from:)`` for `SimpleEntry` / Control-widget `Value` field assembly (`testResolveWithActorHygieneMatchesResolveFromSnapshot`, `testResolveWithActorHygieneReloadsActorVisualStateFromSnapshot`, `testResolveWithActorHygieneDefaultsToPrePlayWhenSnapshotAbsent`, `testAssemblePresentationSlicesMatrixMapsEveryVisualState`, `testAssemblePresentationSlicesUsesConnectionErrorWhenHasError`, `testAssemblePresentationSlicesCarriesStreamMetadataIntoNowPlayingModel`, `testAssemblePresentationSlicesMatchesControlWidgetValueDerivation`, `testAssemblePresentationSlicesFromPersistedSnapshotMatchesProviderContract`). Shared assembly lives in `WidgetDisplayModels.swift`; home-widget and Control-widget Providers consume it.
- [x] **Now Playing formatter + media-surface coordination test index (2026-07-14; ICY dash parse + parse→formatter chain 2026-07-21):** `StreamProgramMetadataTests` — ICY ``from(rawICYMetadata:)`` for ASCII `" - "`, spaced en dash (U+2013), spaced em dash (U+2014), multi-segment re-join, unspaced hyphen non-split, `" by "`, empty/`hasDisplayableContent`; `nowPlayingDisplayStrings` matrix (parsed title/speaker, raw fallback, station fallback, whitespace); raw-ICY → parse → formatter chains `testNowPlayingDisplayStringsFromEnDashRawICYYieldsSpeakerArtistLine`, `testNowPlayingDisplayStringsFromEmDashRawICYYieldsSpeakerArtistLine` (speaker on artist line); widget program-title alignment; `SharedPlayerManagerEventTests` — `testRefreshAllMediaSurfacesOrdersNowPlayingBeforeWidgetRefreshAndWritesDisplayStrings` (coordination order log + `MPNowPlayingInfoCenter` SSOT under DEBUG bypass; LA IPC skipped).
- [x] **Now Playing `playbackState` + remote-command hygiene (2026-07-18):** Live ``updateNowPlayingInfo()`` aligns dictionary rate and `MPNowPlayingInfoCenter.playbackState` (`.playing` / `.paused`); teardown retains `.stopped`. ``configureNowPlayingControlsIfNeeded()`` enables only play/pause/toggle/stop and disables unsupported remote commands. Gates: `testUpdateNowPlayingInfoSetsPausedPlaybackStateWhenNotActivelyPlaying`, `testConfigureNowPlayingControlsDisablesUnsupportedRemoteCommands` (+ extended NP SSOT assertions). Canonical: [`docs/Live-Activity-Stacking-and-Media-Surfaces.md`](Live-Activity-Stacking-and-Media-Surfaces.md).
- [x] **Media-transport command serialization (2026-07-18):** ``MediaTransportCommand`` mailbox on ``SharedPlayerManager`` serializes Now Playing / headset play-pause-toggle-stop and main-app Live Activity engine execution (`submitMediaTransportCommand` / `AndWait`). Pause/stop preempt in-flight play; toggle samples actor state only after prior verbs commit. Gates: `testMediaTransportDoubleToggleWhilePlayingEndsPlaying`, `testMediaTransportDoubleToggleWhilePausedEndsPaused`, `testMediaTransportPausePreemptsInFlightPlayOnMailbox`, `testMediaTransportInterleavesLiveActivityPauseWithRemoteToggle`. Canonical: [`docs/Live-Activity-Stacking-and-Media-Surfaces.md`](Live-Activity-Stacking-and-Media-Surfaces.md).
- [x] **Media toggle planning for Connecting / thermal / security (2026-07-18):** ``isActivelyPlaying`` stays “audio flowing”; toggle planning uses ``plansMediaToggleAsPause`` / ``blocksPlannedPlay`` / ``optimisticVisualAfterPlayPlan`` plus ``isConnectingPlayback`` start pipeline (cancel connect, thermal refuse, security recovery Connecting chrome). Gates: WidgetSurface / extension coordinator matrices; `testMediaTransportToggleWhileConnectingCancelsToUserPaused`, `testUserRequestedPlayWhileConnectingIsIdempotent`. Canonical: Live-Activity-Stacking-and-Media-Surfaces.
- [x] **WidgetSurface coordinator SSOT (2026-07-14):** `WidgetIntentCoordinators`, `WidgetTimelineEntryFactory`, `WidgetLivenessPresentation`, `WidgetNowPlayingDisplay` in `WidgetSurface/`; `WidgetIntentExecution` in `WidgetDisplayModels.swift`; extension thin delegates; `WidgetIntentContractTests` toggle matrices use ``planHomeWidgetToggle(from:)`` / ``planControlWidgetToggle(isPlayingRequested:)``.
- [x] **LiveActivitySwitchStreamIntent contract (2026-07-17):** `WidgetIntentContractExtensionTests` — reject unknown (snapshot unchanged), accept known, preserve `.userPaused` / `.playing` + language update, empty-session success (symmetric to home-widget switch SSOT and LA toggle empty-session path). Methods: `testPerformLiveActivityStreamSwitchRejectsUnknownLanguage`, `testPerformLiveActivityStreamSwitchAcceptsKnownLanguage`, `testPerformLiveActivityStreamSwitchPreservesUserPausedAndUpdatesLanguage`, `testPerformLiveActivityStreamSwitchFromPlayingUpdatesLanguageOnly`, `testPerformLiveActivityStreamSwitchSucceedsWithEmptySessionSnapshot`.
- [x] **displayFlag / displayLanguageName pure helpers (2026-07-17; WidgetSurface home 2026-07-18):** Pure ``displayFlag(for:)`` and ``displayLanguageName(for:preferredStreamLanguage:)`` live in `WidgetSurface/WidgetLanguageDisplay.swift` (`WidgetSurfaceTests` matrix). Stream-catalog preference for ``displayLanguageName(for:)`` remains the membership-exception wrapper (extension-profile `WidgetDisplayModelsExtensionTests`: `testDisplayLanguageNamePrefersAvailableStreams`, stream.flag parity).

**Tier 5 complete when:** Tier 2 checklist is green, `LutheranRadioWidgetTests` ships under the extension compile profile (**done 2026-07-15** — coordinator SSOT + perform SSOT; LA switch + display helpers closed 2026-07-17; **61** extension-profile tests green as of 2026-07-17), and all touched files carry production `///` docs with `SeeAlso:` to this roadmap.

---

## Identified Candidates for Future Consolidation

Authoritative inventory (no behavior change until device-proven). Mirrors Event-Driven Roadmap Tier 4 style.

**1. Optimistic snapshot & lifecycle surfaces (permanent)**

- ``persistOptimisticWidgetSnapshot(_:language:)`` — widget/LA optimistic instant feedback; permanent infrastructure, not a removal target.
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

**Recommended starting order (2026-07-18):**

1. ~~**`LutheranRadioWidgetTests` target**~~ — **Done**: extension-profile target + pure `WidgetSurfaceTests`.
2. ~~**Permanent-doc closeout for WidgetSurface + extension-profile tests**~~ — **Done**: `CODING_AGENT.md` / `Agents.md` two-layer cross-target section; README SSOT + verification for widget unit targets.
3. ~~**LA switch + display helper contracts**~~ — **Done (2026-07-17):** ``LiveActivitySwitchStreamIntent`` perform SSOT + ``displayFlag`` / ``displayLanguageName`` pure tests.
4. ~~**Pure presentation extraction into WidgetSurface**~~ — **Done (2026-07-18):** ``displayFlag(for:)``, pure ``displayLanguageName(for:preferredStreamLanguage:)``, and ``WidgetProviderPresentationAssembly`` live in WidgetSurface; membership-exception ``WidgetDisplayModels.swift`` retains only ``SharedPlayerManager`` / ``WidgetRefreshManager``-coupled snapshot hygiene and ``WidgetIntentExecution``.
5. ~~**Live Activity language chrome SSOT**~~ — **Closed (2026-07-19):** `ContentState.currentLanguage` + durable language mirror + chrome from `context.state`; home-widget write suppression unchanged.
6. Tier 1 optional `WidgetDisplayProjection` bundle (only if future call-site churn warrants it).
7. Optional later: XCUITest widget intents / manual QA matrix (high device cost).
8. Optional later: further membership-exception reduction for ``WidgetRefreshManager`` only if coupling can be broken without a circular WidgetSurface ↔ SharedPlayerManager dependency.

Each micro-step: read target files first, minimal diff, apply the documentation standards above, update this roadmap Completed + Update Log, run build + test gates per `CODING_AGENT.md`.

An item is marked complete only when wired, documented, and the project compiles with zero warnings.

---

## Usage of This Document

This file is the **single source of truth for widget-specific backlog and architecture status**.

Contributors consult it when touching:

- `WidgetSurface/` (presentation types, intent coordinators, timeline factory, liveness policy)
- `LutheranRadioWidget/` (home widgets, Control widget, LA views, intents)
- `WidgetDisplayModels.swift` (provider resolver + `WidgetIntentExecution`)
- `WidgetRefreshManager.swift`
- Widget-related surfaces in `SharedPlayerManager.swift` (persistence, intents, liveness, ``persistOptimisticWidgetSnapshot``)
- Widget-adjacent tests

When a backlog item splits or priorities shift, update this document in the same change.

For player **event** emission and `PlayerEvent` consumers, use [`docs/Event-Driven-Refactor-Roadmap.md`](Event-Driven-Refactor-Roadmap.md).

For presentation mapping rules and termination invariants, use [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md).

---

## Update Log

- **2026-07-23:** **Stream-switch LA language with Connecting hold** — ``resetToPrePlayForNewStream(connectingLanguageCode:)`` + ``liveActivityLanguageCodeForContentPush()`` so Live Activity ContentState never shows prior-language chrome for one push while visual is already `.prePlay` and ``selectedStream`` is still the old stream. Coordinators / Siri intents pass destination language on hold. **DEBUG latency timeline single console sink** — ``MediaTransportLatencyTimeline`` emits via `print` only (no twin `os.Logger` line). Gates: `testStreamSwitchHoldContentLanguageMatchesDestinationBeforeEnginePrep`, extended soft-silence milestone count. Canonical: [`docs/Live-Activity-Stacking-and-Media-Surfaces.md`](Live-Activity-Stacking-and-Media-Surfaces.md). No security surface change; home-widget write suppression unchanged.
- **2026-07-22:** **Retired App Group key purge hygiene** — drop `migrateLegacyIsPlayingIfNeeded` alias; ``clearPersistedVisualStateKeysFromDisk()`` sole purge entry point (includes bare `currentLanguage`); SSOT table marks `isPlaying` / bare `currentLanguage` purged only; ``preferredWidgetLanguage()`` hard-defaults to `"en"` when no home widgets (no bare-key read). Canonical: `SharedPlayerManager.swift` App Group table, [`docs/Event-Driven-Refactor-Roadmap.md`](Event-Driven-Refactor-Roadmap.md) (OI-1). Gates: cold-launch factory reset + `testPreferredWidgetLanguageIgnoresRetiredBareCurrentLanguageKey`. No security surface change.
- **2026-07-22:** **Retire `forcePersistVisualState` alias + optimistic-snapshot SSOT alignment** — public API is ``persistOptimisticWidgetSnapshot(_:language:)`` only (deprecated forwarding wrapper removed; zero call sites). Present-tense SSOT tables and architecture docs use the optimistic-snapshot name; permanent infrastructure language for cross-process optimistic writes. Canonical: `SharedPlayerManager.swift`, [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md), ``<doc:Architecture>``, [`docs/Event-Driven-Refactor-Roadmap.md`](Event-Driven-Refactor-Roadmap.md). No security surface change; no behavior change.
- **2026-07-21:** **ICY StreamTitle typographic dash parse + Now Playing chain gates** — ``StreamProgramMetadata/from(rawICYMetadata:)`` normalizes spaced en/em dashes (U+2013 / U+2014) to ASCII `" - "` and re-joins multi-segment program titles; unit coverage includes separator matrices and raw-ICY → ``nowPlayingDisplayStrings(...)`` chains that keep speaker attribution on the system artist line (`testNowPlayingDisplayStringsFromEnDashRawICYYieldsSpeakerArtistLine`, `testNowPlayingDisplayStringsFromEmDashRawICYYieldsSpeakerArtistLine`). Tier 5 Now Playing formatter index updated. Presentation-only; no security surface change. SeeAlso: `WidgetSurface/StreamProgramMetadata.swift`, [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md).
- **2026-07-20:** **DEBUG media-transport latency timeline** — ``MediaTransportLatencyTimeline`` (membership-exception, DEBUG-only) marks LA toggle, mailbox enqueue/execute, soft silence, authoritative playing, and pending-action drain; console `[MediaTransportLatency]` lines with `t=` / `dt=`; unit gates in `SharedPlayerManagerEventTests`; no transport policy change. Canonical: [`docs/Live-Activity-Stacking-and-Media-Surfaces.md`](Live-Activity-Stacking-and-Media-Surfaces.md).
- **2026-07-19:** **Live Activity language chrome SSOT closed** — `ContentState.currentLanguage` pushed from ``mainAppLiveActivityLanguageCode()`` (stream attach); Lock Screen / Dynamic Island hoist `context.state.currentLanguage` only; durable ``liveActivityCurrentLanguage`` mirror (not gated by ``hasActiveWidgets``); optimistic play/pause uses ``languageForLiveActivityOrWidgetOptimistic()``; language-only changes force ActivityKit update; unit gates in WidgetSurfaceTests, RadioLiveActivityManagerTests, LutheranRadioWidgetTests, SharedPlayerManagerEventTests. Event-Driven roadmap records the same shipped contract (not event Tier 4). Home-widget write suppression unchanged.
- **2026-07-18:** Open issue + Tier 1 backlog for **Live Activity language chrome SSOT** — Lock Screen / Dynamic Island flag and language name re-derive via ``preferredWidgetLanguage()`` while `ContentState` carries only visual + metadata; under memory-only session snapshot + no home widgets (write suppression) resolution hard-defaults to `"en"` even when the engine stream is non-English. Documented required end state (language on `ContentState`, chrome from `context.state`, optimistic toggle language, optional durable mirror), explicit non-goals (no privacy regression), micro-steps, and file list so a later session can implement without external repro notes. Presentation derivation table extended with language-chrome row. Cross-link: Event-Driven Refactor Roadmap (presentation / cross-process; not event emission).
- **2026-07-18:** Pure presentation extraction into WidgetSurface — `WidgetLanguageDisplay.swift` (`displayFlag`, pure `displayLanguageName(for:preferredStreamLanguage:)`), `WidgetProviderPresentationAssembly.swift` (pure Provider slice assembly); membership-exception `WidgetDisplayModels.swift` slimmed to stream-catalog wrappers, ``WidgetProviderSnapshotResolver`` hygiene, and ``WidgetIntentExecution``. Canonical agent docs (`CODING_AGENT.md` / `Agents.md`, `README.md`) document the refined boundary. Pure assembly + language chrome covered in `WidgetSurfaceTests`; stream-catalog contracts remain in main-app / extension-profile suites. `WidgetRefreshManager` stays membership-exception (event observation + WidgetKit).
- **2026-07-17:** Joined optimistic-signal → main-app-drain → authoritative-state contracts indexed — two-phase play/pause round-trips, post-drain `WidgetRefreshManager` refresh gate observation without WidgetCenter IPC, and UITestMode no-bypass safety after the full optimistic signal shape; methods in `WidgetIntentContractTests` (Tier 2 checklist + Tier 5 joined-round-trip index). Complements isolated drain and optimistic-only joints already listed under play/pause drain.
- **2026-07-17:** Close last widget contract holes — ``LiveActivitySwitchStreamIntent`` extension-profile contracts (reject/accept, pause/play language update, empty-session success) symmetric to home switch + LA toggle; pure ``displayFlag`` / ``displayLanguageName`` matrix in `WidgetDisplayModelsExtensionTests`; `docs/widget-test-gaps-analysis.md` aligned (extension target + LA perform + display helpers no longer listed open).
- **2026-07-15:** Permanent-doc closeout for `WidgetSurface` + extension-profile tests — `CODING_AGENT.md` / `Agents.md` cross-target section rewritten for `WidgetSurface` + membership-exception SSOT; README SSOT, widget functionality table, and Agent Verification Commands document `LutheranRadioWidgetTests` / `WidgetSurfaceTests` (default test plan); `WidgetSurface` target sets `SWIFT_STRICT_MEMORY_SAFETY = YES` parity with `Core`.
- **2026-07-15:** LA toggle power-on hygiene — factory reset clears durable mirror + records boot identity; ``shouldDistrustDurableMirrorPlayPlanning()`` (termination sentinel or reboot) blocks durable-mirror-alone **play**; ContentState still trusted; coordinator + extension + factory-reset tests.
- **2026-07-15:** Lock-screen LA toggle multi-source planning — ContentState + durable App Group mirror before extension actor defaults; ``resolveLiveActivityToggleVisualState``; mirror write on every LA push; regression tests for empty-session pause plan.
- **2026-07-15:** `LutheranRadioWidgetTests` extension-profile target (no `LUTHERAN_MAIN_APP`; links WidgetSurface + Core; SPM membershipExceptions); ``WidgetIntentExecution/perform*`` AppIntent SSOT; extension-profile suite + WidgetSurfaceTests green; widget extension unit test coverage closed. Canonical references only (no temporary handoff docs). (Suite size grew with LA toggle/switch + display helpers; see 2026-07-17 log.)
- **2026-07-14:** Documentation standards — removed temporary handoff-doc cross-links; renamed widget extension test gap from internal tracking label to **Widget extension unit test coverage**; production `SeeAlso:` cites canonical roadmap and presentation dataflow only.
- **2026-07-14:** WidgetSurface coordinator layer — `WidgetIntentCoordinators`, `WidgetTimelineEntryFactory`, `WidgetLivenessPresentation`, `WidgetNowPlayingDisplay`; `WidgetIntentExecution` in `WidgetDisplayModels.swift`; extension `perform()`/Provider thin delegates; toggle mirror helpers removed; widget extension test coverage partially complete (coordinator SSOT in main-app host).
- **2026-07-14:** Now Playing formatter tests — `StreamProgramMetadataTests` adds `nowPlayingDisplayStrings` matrix + widget title alignment; `SharedPlayerManagerEventTests` adds `testRefreshAllMediaSurfacesOrdersNowPlayingBeforeWidgetRefreshAndWritesDisplayStrings` (DEBUG coordination-order log + NP bypass seam); Tier 2 play/pause drain method names indexed.
- **2026-07-14:** Provider synthesis — ``WidgetProviderSnapshotResolver/assemblePresentationSlices(from:)`` + `WidgetProviderPresentationSlices`; home-widget `Provider` and Control-widget `Value` use shared assembly; `WidgetDisplayModelsTests` (26 total) adds `resolveWithActorHygiene` + entry/Value synthesis contracts.
- **2026-07-14:** Presentation mapper matrices — `PlayerPresentationMapperTests.swift` (status + control SSOT for all six `PlayerVisualState` cases); Tier 5 test index closed; `WidgetRefreshManager` test count corrected to 20.
- **2026-07-14:** Tier 4 complete — [`docs/Live-Activity-Stacking-and-Media-Surfaces.md`](Live-Activity-Stacking-and-Media-Surfaces.md) (stacking matrix, LA start policy, push-cost validation); ``refreshAllMediaSurfaces`` wrapper + call-site consolidation; dual-card stacking documented as accepted; README functionality table; `testRefreshAllMediaSurfacesCompletesAndOptionalWidgetRefreshPassesGates`.
- **2026-07-13:** Tier 3 complete — ``WidgetProviderSnapshotResolver`` + provider audit table; imperative ``refreshIfNeeded`` dedup in ``performActualSave``, ``didUpdateStreamMetadata``, ``updateUserDefaultsLanguage``; ``refreshUsesImmediateDelivery`` urgency parity on event path; removed `setupWidgetActionPolling`; Control widget Provider aligned with home-widget hygiene; tests in `WidgetRefreshManagerEventTests` + `WidgetDisplayModelsTests`.
- **2026-07-13:** Tier 2 complete — `WidgetDisplayModelsTests.swift` (resolver matrix), `WidgetIntentContractTests.swift` (pending-action dedup, instant-feedback expiry, optimistic persist contract, widget switch SSOT); `forcePersistVisualState` renamed to `persistOptimisticWidgetSnapshot` with deprecated forwarding wrapper.
- **2026-07-13:** Tier 1 — Control widget `Value` pre-derivation (`statusPresentation` + `controlPresentation` in Provider; toggle label consumes narrow fields; symmetric with `SimpleEntry`).
- **2026-07-13:** Core Principles — added **Documentation standards & canonical references** (describe what ships today; link only to committed, tracked docs).
- **2026-07-13:** Tier 1 complete — narrow family view inputs (`LutheranRadioWidgetEntryView` projection) and LA expanded-region `statusPres` dedup (outer `dynamicIsland` closure).
- **2026-07-10:** Tier 2 backlog: rename `forcePersistVisualState` → `persistOptimisticWidgetSnapshot` (permanent widget infrastructure naming); consolidation inventory updated.
- **2026-07-10:** Added **Target Architecture (Ultimate Goal)** section (two-zone hybrid model, permanent snapshot cross-process boundary, definition of “done”) and Tier 3 scope note clarifying consolidation is main-app refresh dedup only.
- **2026-07-10:** Initial roadmap drafted from codebase inventory + canonical docs (`Widget-Presentation-Dataflow.md`, `Event-Driven-Refactor-Roadmap.md`, `cold-launch-streamplay-regression-checklist.md`, `SharedPlayerManager+NowPlaying.swift`, `StreamProgramMetadata.swift`). Completed section consolidates control presentation migration, Provider/LA pre-derivation, memory-only snapshot policy, refresh/teardown/event-consumer tests, and cross-process intent SSOT. Open issues (force-quit liveness, extension event isolation, test coverage, media stacking) recorded. Backlog Tiers 1–5 populated; Tier 2 tests and Tier 1 presentation hygiene are highest priority.

---

This document is consulted at the beginning of any work on widget, Control widget, or Live Activity **functionality** (as distinct from player event emission).