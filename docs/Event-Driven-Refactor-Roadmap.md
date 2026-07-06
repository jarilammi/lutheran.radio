# Event-Driven Refactor Roadmap

**Purpose**  

This document is the authoritative living record of the incremental migration toward a fully event-driven architecture in which **nothing is forced** and **all significant actions and state transitions flow through typed events**.

It serves as both the project backlog for remaining work and a self-contained reference for developers and coding agents. It describes the current state, the governing principles, and the safe next micro-steps.

**Core Principles (Never Violate)**
- Progress must be **slow and piece-by-piece**. Every micro-step must be small, reviewable, and non-breaking.
- **Nothing is forced**: Existing imperative paths, direct calls, and snapshot-based widget/Live Activity logic must continue to work unchanged. Event emission and consumption are always additive.
- All comments and documentation must be written at **production level** (present tense, final architecture language). No "phase", "step", "temporary", "will be", or migration language is allowed.
- Security invariants come first. No changes may touch `Core/`, certificate validation, DNS TXT validation, or `SecurityModelValidator`.
- Every change must follow `CODING_AGENT.md` (structured documentation, `SeeAlso`, AGENT NOTE where appropriate, build gates, etc.).
- After every micro-step, this roadmap document must be updated to reflect completed work and adjust priorities.

**Current State (as of last observed commit)**

**Completed**
- `PlayerEvent` enum introduced in `PlayerVisualState.swift` as the canonical vocabulary for player-domain events (additive only).
- `SharedPlayerManager` established as the **authoritative emitter** of `PlayerEvent`.
- Clean `AsyncStream<PlayerEvent>` implementation added (`events` property created exactly once, continuation lives for actor lifetime).
- `internal emit(_:)` central emission point (with widget-process guard).
- Emission of `.playbackIntentChanged` wired inside `updatePlaybackIntent(to:)`.
- Tier 1 Emission Coverage complete: stream transitions (start/pause/stop/fail via existing surfaces + enhanced `markPlaybackStoppedByStreamFailure`), `metadataDidUpdate` (in `didUpdateStreamMetadata` + clears), `visualStateDidChange` (via `applyVisualState` / `setVisualState`), `persistedWidgetStateDidUpdate` (after authoritative snapshot writes in `savePersistedWidgetState`). Emissions added after state mutations inside `SharedPlayerManager` using existing surfaces only; no new record APIs or emission logic in `DirectStreamingPlayer`.
- Surface cleanup in `SharedPlayerManager.swift` + `PlayerViewModel.swift` (commit d219f8e): event-driven non-forcing architecture promoted in headers and public API docs; legacy forcing shims (e.g. `forcePersistVisualState` and related) explicitly scoped to widget optimistic paths only; stronger SeeAlso/cross-links to ``PlayerEvent``, ``events``, and this roadmap.
- Tier 2 first consumer: lightweight internal observer added inside `WidgetRefreshManager` (main-app only). It reacts to key `PlayerEvent` cases and drives timeline reloads exclusively by calling the pre-existing `refreshIfNeeded(visualState:currentLanguage:hasError:immediate:)` surface with state derived from the same SSOT readers (`loadPersistedWidgetState`, `loadSharedState`). All imperative snapshot paths, debouncing, coalescing, and guards remain 100% unchanged and primary. Full structured documentation and present-tense final-architecture comments added per CODING_AGENT.md. (2026-07-04)
- Tier 2 UI subscriber: lightweight `PlayerEventSubscriber` (Observation/@State/.task/onChange/Task) added in the primary player UI hosting view (`RadioPlayerView`). Reacts to `playbackIntentChanged` + state transition events; updates local observable values for UI-only side effects (animations, refreshes, Widget/LA coordination). Existing direct bindings untouched. Full production docs + file header improvements. (2026-07-05)
- Tier 3 current-state replay implemented: `PlayerCurrentState` type + `SharedPlayerManager.currentState` snapshot and `makeEventsStreamWithReplay()` added. `PlayerEventSubscriber` wired to the replaying stream. All surfaces carry production-level documentation. Late subscribers receive current state on subscription. (2026-07-06)

**Architecture Status**
- `SharedPlayerManager` is the single source of truth for emitting player events.
- All Tier 1 `PlayerEvent` cases are now emitted after their state mutations inside the actor.
- Emissions are strictly additive; direct state access, imperative paths, and widget snapshot writes remain the primary mechanism. Legacy forcing surfaces exist only for compatibility and are documented as such.
- `SharedPlayerManager` supplies `currentState` (snapshot) and `makeEventsStreamWithReplay()` for late-subscriber initialization. The primary `events` stream continues unchanged.
- Consumers exist: `WidgetRefreshManager` maintains a lightweight internal observer of `events` (started only in the main app process) and `RadioLiveActivityManager` consumes Live Activity attribute events. Both delegate to the consolidated `WidgetEventObserver` helper. The main-app player UI layer (`RadioPlayerView`) hosts an additive `PlayerEventSubscriber` that consumes the replaying stream for UI-only effects and seeds from `currentState`. All snapshot + refresh + LA + direct-binding logic, seams, and behavior are unchanged. Event-driven and imperative paths operate in parallel.
- Widget, Live Activity, and UI paths continue to rely on direct state access and snapshot derivation as the primary mechanism. The event path (with replay) is available for decoupled observation. See player SSOT file docs for non-forcing direction and cross-references.

---

## Remaining Backlog (Prioritized for Slow, Safe Progress)

The backlog is ordered by increasing risk and decreasing isolation. Earlier items are safer and more contained.

### Tier 1 – Emission Coverage (Low Risk, High Value)
Goal: Ensure every significant domain transition inside `SharedPlayerManager` and related player logic produces the corresponding `PlayerEvent`.

- [x] Emit `streamDidStart`, `streamDidPause`, `streamDidStop`, and `streamDidFail` (via `setPlaying`, `setUserPaused`/`markAsUserPaused`, `stop`, `markPlaybackStoppedByStreamFailure` using existing surfaces: emissions added after state mutations inside the actor; no new record APIs or emission logic in `DirectStreamingPlayer`).
- [x] Emit `metadataDidUpdate` when `StreamProgramMetadata` changes (and on clears).
- [x] Emit `visualStateDidChange` when `PlayerVisualState` is updated (centralized via `applyVisualState`).
- [x] Emit `persistedWidgetStateDidUpdate` when widget snapshot state is written (after `savePersistedWidgetState` writes).
- [x] (No additional cases required; `visualStateDidChange` case was present and wired.)

**Tier 1 complete.** All core player domain events (`streamDidStart`, `streamDidPause`, `streamDidStop`, `streamDidFail`, `metadataDidUpdate`, `visualStateDidChange`, and `persistedWidgetStateDidUpdate`) are now emitted from `SharedPlayerManager` after their corresponding state mutations. Emissions are strictly additive and use existing canonical surfaces; direct state access and imperative paths remain the primary mechanism.

**Rule for these items**: Emission must be added *after* the state mutation, inside the same actor or controlled boundary. Never remove or bypass existing direct paths.

### Tier 2 – First Consumers (Medium Risk)
Goal: Introduce the first real observers of the `events` stream without forcing any existing code to change.

- [x] Add an internal observer inside `WidgetRefreshManager` that reacts to key `PlayerEvent` cases (`.visualStateDidChange`, `.persistedWidgetStateDidUpdate`, stream transitions, metadata, intent) to trigger timeline reloads by routing through the existing `refreshIfNeeded` surface. All snapshot derivation, debouncing, coalescing, regress guards, privacy gating, and direct call sites remain 100% intact and primary. The observer is strictly additive and non-forcing.
- [x] `RadioLiveActivityManager` consumes the Live Activity attribute updates AsyncStream (`activity.contentUpdates`, the events surface for `LutheranRadioLiveActivityAttributes.ContentState`). On yield the manager aligns `lastPushedContent` (stronger diff suppression of `update(using:)`) and reacts to terminal states for self-healing lifecycle. Observation starts on acquisition and is cancelled on end; all prior push sites, dedup, gates, and tests are unchanged (additive only). Production docs added. (2026-07-04)
- [x] Tier 2 polish complete: common observation pattern for `PlayerEvent` (WidgetRefreshManager) and Live Activity attribute events (RadioLiveActivityManager) extracted to internal `WidgetEventObserver` helper. Both managers delegate to the helper; all task seams (`eventObservationTask`, `activityObservationTask`), property contracts, test isolation, and observable behavior are preserved exactly. No new polling or forcing. `WidgetEventObserver` added to cross-target shared sources with full production documentation and cross-links. (2026-07-04)
- [x] Add a lightweight subscriber (`PlayerEventSubscriber`) in the main app UI layer inside the primary player hosting view (`RadioPlayerView`). Uses `@State` + `@Observable` + `.task` + `.onChange` for value-type driven reactions to `playbackIntentChanged` and all other key `PlayerEvent` cases. Existing direct state bindings, @Bindable viewModel usage, and all subview contracts remain 100% untouched. Observation reuses `WidgetEventObserver` internally; all side effects are UI-only (local state updates for future animations / refreshes / Widget/LA coordination). Full structured production `///` documentation + file header uplift applied. Non-forcing, additive only. (2026-07-05)

**Rule**: Consumers must be additive. The imperative/snapshot paths stay as the primary mechanism. Event-driven paths run in parallel initially.

### Tier 3 – Richer Event Surface & Replay (Higher Value, More Care)
- [x] `PlayerCurrentState` value type introduced alongside `PlayerEvent`. `SharedPlayerManager` now exposes `currentState` (authoritative snapshot) and `makeEventsStreamWithReplay()` (per-subscriber stream that first yields events synthesized from current state then forwards the live stream). `PlayerEventSubscriber` (RadioPlayerView) now consumes the replaying stream. All additions are strictly additive; the original `events` surface and all imperative/snapshot paths remain unchanged and primary. Full production documentation, cross-links, and present-tense final-architecture comments applied in `PlayerVisualState.swift`, `SharedPlayerManager.swift`, `RadioPlayerView.swift`, `WidgetEventObserver.swift`, and `WidgetRefreshManager.swift`. (2026-07-06)
- [ ] Evaluate whether a higher-level typed event bus (wrapping multiple domain actors) is needed, or whether per-actor `AsyncStream`s are sufficient.
- [ ] Add error and recovery events (`securityValidationFailed`, `streamRecoveryAttempted`, etc.) if they provide clear value for observers.

### Tier 4 – Gradual Consolidation (Long-term, High Caution)
- [ ] Identify places where direct "force" calls or polling can be replaced by event observation (very late stage).
- [ ] Clean up any now-redundant direct mutation paths only after multiple consumers prove the event path is reliable.
- [ ] Add comprehensive tests for event emission order, stream behavior under actor isolation, and late-subscriber scenarios.

### Tier 5 – Documentation & Tests
- [ ] Expand `Core/Core.docc/Articles/Architecture.md` (or create a dedicated Event-Driven Architecture article) describing the `PlayerEvent` + `SharedPlayerManager.events` model.
- [ ] Add unit tests in the test target that verify emission of each `PlayerEvent` case and stream behavior.
- [ ] Update `README.md` Single Sources of Truth section to include the event emission responsibility of `SharedPlayerManager`.

---

## Selecting and Implementing Micro-Steps

The next item is always the highest-priority remaining entry in the backlog (Tier 3 onward now that Tier 1 and Tier 2 coverage are complete).

Each micro-step is a tiny, isolated, additive change (for example, adding a single emission site or a small non-forcing consumer) that follows every rule in `CODING_AGENT.md`, including reading target files first, using production-level comments, updating cross-references, and passing build gates.

After a change is complete and reviewed, the "Completed" section of this document is updated, the finished item is moved out of the backlog, and priorities are adjusted if new insights emerged.

An item is marked complete only when the emission (or consumption) is wired and the code compiles cleanly with zero warnings.

## Usage of This Document

This file is the single source of truth for the current state of the event-driven refactor.

Contributors address a specific backlog item when making changes. When a backlog item is split, re-prioritized, or when new `PlayerEvent` cases are required, this document is updated in the same change.

The target architecture is one in which the primary way components learn about player state changes is by observing `PlayerEvent`s, while direct state access remains available for compatibility and simplicity.

## Update Log

This document must be maintained after every significant micro-step so that the backlog, completed items, and priorities remain accurate for developers and future agents.

Keep a short chronological log of major milestones:

- `PlayerEvent` vocabulary introduced + `SharedPlayerManager` became authoritative emitter with clean `AsyncStream` (commit 085311d...).
- Tier 1 Emission Coverage cleaned up and completed (emissions added after state mutations inside `SharedPlayerManager` using existing surfaces only; no new record APIs or emission logic in `DirectStreamingPlayer`). Stream*, metadata, visualStateDidChange, and persistedWidgetStateDidUpdate now emitted. Stale comments/docs cleaned. (2026-07-03)
- Surface cleanup + docs uplift (commit d219f8e): improved docs in `SharedPlayerManager.swift` + `PlayerViewModel.swift` promoting event-driven non-forcing architecture, scoping legacy forcing shims to widget optimistic paths, and strengthening SeeAlso/cross-links to `PlayerEvent` / ``events`` / roadmap. (2026-07-03)
- Tier 2 first consumer complete: `WidgetRefreshManager` now contains a lightweight internal `PlayerEvent` observer (additive only). All changes follow production documentation standards (structured `///`, file headers, AGENT NOTE, present-tense final architecture language, cross-links to `events`, `PlayerEvent`, roadmap, Architecture.md, CODING_AGENT.md). Existing snapshot + refresh paths untouched. Build + test gates passed. (2026-07-04)
- Live Activity attribute events complete: `RadioLiveActivityManager` now observes the `activity.contentUpdates` AsyncStream (events for ContentState + state). Aligns dedup record + self-heals on dismissal. Additive, production docs, cross-links. (2026-07-04)
- Tier 2 polish (consolidation): The common observation pattern used by both `WidgetRefreshManager` (PlayerEvent) and `RadioLiveActivityManager` (Live Activity attribute events) has been extracted into the internal `WidgetEventObserver` helper. Both managers delegate to it while preserving all task seams, property names, contracts, and behavior. `WidgetEventObserver` is now part of the cross-target shared sources, carries full production documentation, and is referenced from the dataflow and roadmap docs. No behavior change, no new polling. (2026-07-04)
- UI subscriber (main app layer): `PlayerEventSubscriber` added to `RadioPlayerView` (the primary player UI hosting view). Uses `@Observable`, `@State`, `.task`, `.onChange`, and `Task` for lightweight reactions to `playbackIntentChanged` + state transition events. Value-type updates; UI-only side effects only; zero impact on existing bindings or Core. Full structured docs and header uplift. Roadmap updated. (2026-07-05)
- Tier 3 current-state replay delivered: `PlayerCurrentState` type added to the canonical vocabulary in `PlayerVisualState.swift`. `SharedPlayerManager` now provides `currentState` (snapshot for initialization) and `makeEventsStreamWithReplay()` (replaying stream). `PlayerEventSubscriber` consumes the replaying stream. All touched files received production-level documentation (structured `///`, present-tense final language, SeeAlso links to new surfaces and this roadmap, AGENT NOTE where appropriate). Changes are strictly additive. No existing `events` contract, imperative paths, or snapshot surfaces were altered. (2026-07-06)

---

This document is the single source of truth for the current state of the event-driven architecture migration. It is consulted at the beginning of any work on this area.
