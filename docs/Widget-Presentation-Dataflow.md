# Widget & Live Activity Presentation Dataflow

This document is the concise, permanent reference for how Lutheran Radio derives and consumes presentation data for WidgetKit home-screen widgets and ActivityKit Live Activities (Dynamic Island + Lock Screen).

It complements (and is cross-referenced by) the source headers in `LutheranRadioWidget.swift`, `LutheranRadioWidgetLiveActivity.swift`, `WidgetSurface/` (`PlayerVisualState.swift`, `WidgetNowPlayingDisplay.swift`, `WidgetTimelineEntryFactory.swift`, `WidgetProviderPresentationAssembly.swift`, `WidgetLanguageDisplay.swift`, `WidgetLivenessPresentation.swift`), membership-exception `WidgetDisplayModels.swift`, and `CODING_AGENT.md`.

## Snapshot-Driven Model

WidgetKit and ActivityKit deliver **frozen value-type snapshots** across process boundaries:

- **Home widgets**: `Provider` (conforming to `AppIntentTimelineProvider`) produces `SimpleEntry` values. The system compares `TimelineEntry` fields to decide re-evaluation.
- **Live Activities**: `RadioLiveActivityManager` pushes `LutheranRadioLiveActivityAttributes.ContentState` (containing `visualState` + `streamMetadata` + `currentLanguage`). The system renders via `ActivityConfiguration` closures and `LockScreenLiveActivityView`. Language chrome (flag, name, alt-stream “current”) reads **only** `context.state.currentLanguage` (hoisted once), never privacy-gated ``preferredWidgetLanguage()``.

There are no live `@Observable` objects inside the widget extension. All display decisions are computed from the snapshot at derivation time or consumption time.

## The Three Narrow Presentation Surfaces

All presentation is organized into three narrow, `Equatable` value types derived from the authoritative `PlayerVisualState` (plus optional `StreamProgramMetadata`):

| Surface                        | Type                              | Mapper / Resolver (`WidgetSurface/`)           | What it carries                          | Consumers |
|--------------------------------|-----------------------------------|------------------------------------------------|------------------------------------------|-----------|
| Status indicator               | `PlayerStatusPresentation`        | `PlayerVisualState.makeStatusPresentation()` (`PlayerVisualState.swift`) | `background`, `foreground`, `text`, `systemImage?` | Status text, pills, indicators in widgets + LA + Control widget |
| Primary play/pause control     | `PlayerControlPresentation`       | `PlayerVisualState.makeControlPresentation()` (`PlayerVisualState.swift`) | `systemImage` ("play.fill"/"pause.fill"), `tint: Color` | Play/pause buttons (Small/Medium/Large, DI trailing/compactTrailing, Lock Screen row, Control widget) |
| Metadata / emphasis (title + speaker) | `WidgetNowPlayingDisplayModel` | `widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)` (`WidgetNowPlayingDisplay.swift`) | `programTitle`, `speakerLine`, `speakerVisible`, `emphasis: WidgetMetadataEmphasis` | `WidgetMetadataRegion`, DI center/compactLeading, Lock Screen metadata blocks |

**Derivation rule (snapshot-driven):**

- **Home widgets**: All three are computed **once per entry** inside the `Provider` (`placeholder`, `snapshot`, `timeline` / `createEntry`). Snapshot fields resolve via ``WidgetProviderSnapshotResolver`` (membership-exception `WidgetDisplayModels.swift`); presentation slices assemble via pure ``WidgetProviderPresentationAssembly`` (stream-catalog wrapper ``WidgetProviderSnapshotResolver/assemblePresentationSlices(from:)``); entry blueprints map through ``WidgetTimelineEntryFactory`` (`WidgetSurface/WidgetTimelineEntryFactory.swift`). Family views read the narrow properties from `SimpleEntry`.
- **Control Center widget**: Status and control surfaces are computed **once per value** inside `LutheranRadioWidgetControl.Provider` (`previewValue`, `currentValue`) using the same resolver + factory path, then stored on `LutheranRadioWidgetControl.Value`. The toggle label closure reads `statusPresentation` and `controlPresentation` only (no inline mapper calls in the view body).
- **Live Activities**: The three are computed **once at the top of `LockScreenLiveActivityView.body`** and **once inside the outer `dynamicIsland` closure**, then closed over by the region builders and subviews. No repeated derivation inside individual `.leading`/`.center`/etc. blocks for the presentation concerns.

`WidgetMetadataRegion` is deliberately narrow: it receives only a `WidgetNowPlayingDisplayModel`.

## Why Pre-Derivation Matters

- **Invalidation cost**: WidgetKit performs structural comparison on the `TimelineEntry`. A change to an unrelated field (e.g. `configuration` or full `availableStreams` ordering) should not force re-work in a leaf that only renders the play glyph. Carrying the already-derived narrow value shrinks the set of mutations that cause body re-evaluation for that leaf.
- **Region work in ActivityKit**: Dynamic Island regions are independent. Re-deriving title/speaker or control glyph inside every region multiplies work on every push. One computation at the outer closure is bounded.
- **View simplicity**: Leaf views and region closures become trivial — they render exactly the four (or two) fields they need. No `switch`, no fallback logic, no `Color(uiColor:)` bridging inside bodies.
- **Consistency**: The same mapping rules apply to main-app UI (via `PlayerViewModel`), home widgets, Live Activities, and Control widgets because status/control mappers live on `PlayerVisualState` (`WidgetSurface/PlayerVisualState.swift`) and the metadata resolver lives in `WidgetSurface/WidgetNowPlayingDisplay.swift`.

## Semantic vs. Presentation Uses of PlayerVisualState

`PlayerVisualState` still exposes:
- `isActivelyPlaying` (purely `self == .playing` — **audio is flowing**)
- `plansMediaToggleAsPause` / `blocksPlannedPlay` / `optimisticVisualAfterPlayPlan` — media-toggle planning (Connecting cancel, thermal refuse, security recovery chrome)
- `buttonTintColor` (and legacy `backgroundColor` / `textColor`)

**Policy**: These remain the source of truth for **semantic** decisions:
- Presence of the red LIVE indicator and animation bars (`isActivelyPlaying`)
- "Local Only" label vs. bars
- Resurrection / intent logic
- Decorative radio glyph tint in certain LA regions (non-control)
- Widget / Live Activity / remote **toggle planning** (not the same as `isActivelyPlaying` alone — see Live Activity stacking doc)

Pure play/pause glyph choice and tint for **controls** must use `makeControlPresentation()` (glyph still follows `isActivelyPlaying` so Connecting keeps a play affordance until audible start).

See the header of `WidgetSurface/PlayerVisualState.swift` for the exact division and AGENT NOTE.

## Adding or Changing a Presentation Axis (Guidance for Contributors)

1. Decide whether the concern belongs on one of the existing surfaces or needs a new narrow type (prefer adding a new `...Presentation` or `...DisplayModel` struct).
2. Implement (or extend) the pure mapper on `PlayerVisualState` (`WidgetSurface/PlayerVisualState.swift`) for status/control axes, or as a free function in `WidgetSurface/WidgetNowPlayingDisplay.swift` for metadata/emphasis. Pure Provider slice assembly stays in ``WidgetProviderPresentationAssembly``; snapshot hygiene wrappers stay in membership-exception `WidgetDisplayModels.swift`; blueprints stay in `WidgetSurface/WidgetTimelineEntryFactory.swift`.
3. Update derivation sites:
   - Add the new field to `SimpleEntry`.
   - Compute it once in `Provider.placeholder`, `createEntry`, and `timeline`.
   - Compute it once at the top of `LockScreenLiveActivityView.body` and inside the outer `dynamicIsland` closure (if applicable).
4. Change consumers (family views, regions, LA region closures, Control widget) to read only the narrow value.
5. Update `SimpleEntry` property documentation and the three main widget/LA files' headers.
6. Add or update an entry in the table above.
7. Update this document, the relevant `///` headers (with `- SeeAlso:`), and the `WidgetSurface/PlayerVisualState.swift` header if the division of concerns changed.
8. Verify with the preview matrix in `LutheranRadioWidget.swift` and on-device widget/LA surfaces.

Never derive presentation inside leaf view `body` for the three canonical surfaces. Never duplicate the mapping rules.

## App Termination & Passive Widget / Live Activity Lifecycle

**Core rule (Cleanup Invariant)**: Widget and Live Activity surfaces are **active / updating only while the main app process is running** (foreground or background audio). Once the main process has quit (normal termination or force-quit), they must transition to a stable passive or last-known state and must not receive further pings, timeline reloads driven from the dead process, or Activity updates.

### How Termination Achieves Passive State
- **Liveness heuristic (SSOT)**: `SharedPlayerManager.isMainAppProcessRecentlyActive()` (backed by the `lastUpdateTime` key + explicit `0` sentinel). Widget family views delegate the passive-branch decision to ``WidgetLivenessPresentation/shouldShowPassiveTapToOpen(isMainAppRecentlyActive:)`` (`WidgetSurface/WidgetLivenessPresentation.swift`) to render either full interactive controls + status + metadata or the "tap_to_open" prompt.
- **On observed termination** (AppDelegate `applicationWillTerminate`, SceneDelegate `sceneDidDisconnect`, `UIApplication.willTerminateNotification`):
  - `SharedPlayerManager.forceStaleLivenessTimestampForTermination()` writes the sentinel `0` (and clears instant-feedback transients). Any subsequent Provider run immediately sees the passive path.
  - `RadioLiveActivityManager.handleAppWillTerminate()` ends the activity with `.immediate` dismissal after a final `.userPaused` push.
  - `WidgetRefreshManager.cancelPendingRefresh()` drops in-flight debounced work.
- **After force-quit** (notification not delivered): no further main-process saves or `reloadTimelines` occur. The 60 s window is the worst-case staleness for the heuristic; after that widgets naturally render passive. The snapshot (`PersistedWidgetState`) is deliberately left behind (last-known visual + language + metadata).
- **Passive presentation**:
  - Widgets show icon + localized "tap_to_open" + `widgetURL(URL(string: "lutheranradio://open"))`. Tapping performs a clean, Apple-approved launch with no side-effect playback.
  - Live Activity is removed from the Dynamic Island / Lock Screen (no lingering interactive surface).
- **Launch paths that remain allowed** (and are the *only* allowed paths):
  - Widget "tap to open" area (`widgetURL`).
  - Standard Live Activity tap-to-launch (while the LA is still present, before termination cleanup).
  - App Intents explicitly marked with `.openAppWhenRun` (if introduced in future).
  - Home screen / app icon / Siri / URL scheme "open".
- **Forbidden after quit**: any code path in widget views, providers, or LA that would implicitly call `reloadTimelines`, start network, schedule timers, or post Darwin notifications whose only purpose is to keep a dead process resident.

### Why This Design Is Conservative
- Prefer explicit shutdown + passive UI over optimistic "keep the surfaces alive".
- No new parallel state; extends the existing `PersistedWidgetState` + `lastUpdateTime` + LA ownership SSOTs.
- The widget extension process may still be invoked by the system (15 min timelines, user adding the widget, etc.); when invoked it safely falls back and renders the passive branch.
- Background audio (`UIBackgroundModes = audio`) intentionally keeps liveness + LA alive while the *process* is still resident for audio. Termination (user force-quit or system kill) is the trigger for passive transition.

## Live Activity Event-Driven Update Model (Decoupled In-Memory Path)

**Goal**: Make Lock Screen and Dynamic Island updates feel immediate while preserving `PersistedWidgetState` as the sole SSOT for widgets and relaunch.

### Separation of Concerns

| Concern                        | Single Source of Truth                  | Write Path                                      | Read for Live Activity                  | Disk I/O on hot path? |
|--------------------------------|-----------------------------------------|-------------------------------------------------|-----------------------------------------|-----------------------|
| Widgets + Control widgets      | `PersistedWidgetState` (snapshot)       | `persistWidgetSnapshot`, `performActualSave`, `saveCombinedWidgetState`, widget intents via `forcePersistVisualState` | `loadPersistedWidgetState()` (providers) | Yes (required) |
| App relaunch / resurrection    | `PersistedWidgetState` + liveness (`lastUpdateTime` + sentinel 0) | Same as above + `bumpWidgetLivenessTimestamp`   | Same + `isMainAppProcessRecentlyActive` | Yes (required) |
| Live Activity (transient UI)   | In-memory `currentVisualState` + `currentStreamMetadata` + stream language (`mainAppLiveActivityLanguageCode` / `selectedStream`) | None for LA itself. Visual/metadata/language mutations + direct notify; durable LA language App Group mirror warmed on push | `await manager.currentVisualState` / `currentStreamMetadata` + language for `ContentState.currentLanguage` | **No** (in-memory compare + conditional `Activity.update`) |

### How Event-Driven Updates Work

1. **Primary drivers** (no timer required):
   - `SharedPlayerManager.setPlaying()`, `stop()`, `setUserPaused()`, `markAsUserPaused()` — after the widget-persisting save they post a `Task { await RadioLiveActivityManager.shared.updateCurrentActivity() }`.
   - `didUpdateStreamMetadata(_:)` — after mutating the in-memory metadata, calls the LA manager directly, **then** persists for widgets. This ordering ensures LA sees the fresh title without waiting for disk.
   - `RadioPlayerCoordinator` toggle / remote / sleep paths — direct calls after state is stable.
   - Lifecycle: `handleAppDidEnterForeground` (correction), `handleAppWillEnterBackground` (auto-start when playing).

2. **Inside `RadioLiveActivityManager`**:
   - `updateCurrentActivity()` computes a candidate `ContentState(visualState:streamMetadata:currentLanguage:)`.
   - It compares against private `lastPushedContent` (purely in-memory, cleared on `endActivity`).
   - Only when different (or first push) does it call `Activity.update` and record the candidate.
   - This is the "Update Invariant": pushes happen **iff** the rendered content would change.

3. **Lock-screen toggle optimistic ContentState** (intent path, main or extension host):
   - ``WidgetIntentExecution/performLiveActivityToggle()`` plans from multi-source resolve, then writes the durable toggle mirror and calls ``pushOptimisticLiveActivityToggleContent(visualState:)``.
   - That helper updates interactive `Activity` instances with ``ContentState/replacingVisualState(_:)`` (program metadata **and** `currentLanguage` preserved) and, on the main app, ``RadioLiveActivityManager/recordOptimisticToggleContent(visualState:)`` so ``lastPushedContent`` matches the optimistic glyph before engine-complete refresh.
   - Resolve still prefers ActivityKit content over the durable mirror; the optimistic content publish is what makes a rapid second tap plan the opposite direction instead of re-reading stale pre-tap content.
   - UITestMode skips ActivityKit IPC; main-app last-pushed alignment still runs for white-box tests.

4. **Timer demotion**:
   - `startLocalUpdateTimer()` / the `updateTimer` are kept as an `internal` testing seam.
   - They are **not** started from `startActivity()`, `observeExistingActivities()`, or normal lifecycle.
   - The timer (now 30 s interval when explicitly started) is only a rare fallback. All user-visible freshness is event-driven.

### Live Activity Attribute Events Observation (contentUpdates / events surface)

`RadioLiveActivityManager` consumes the Live Activity attribute events surface
(`contentUpdates` yielding `ActivityContent<ContentState>`). The observation
loop and task lifetime are implemented by the shared `WidgetEventObserver`
helper (the consolidated extraction of the common pattern also used by
`WidgetRefreshManager` for `PlayerEvent`).

```swift
// Inside the manager (delegated to WidgetEventObserver):
for await content in contentUpdates {
    lastPushedContent = content.state
}
```

(The stream is started in ``beginObservingActivityEvents(_:)`` which delegates
to `WidgetEventObserver.beginObserving(unsafeSequence:onElement:onTermination:)`.)

- The stream (the `events` surface for `LutheranRadioLiveActivityAttributes.ContentState`) is started via ``beginObservingActivityEvents(_:)`` immediately after `Activity.request` and after resuming an existing activity in `observeExistingActivities`.
- On every yield the manager aligns its `lastPushedContent` with the exact `ContentState` the system accepted. Subsequent diff checks in `updateCurrentActivity` therefore suppress pushes that would be no-ops against the rendered surface.
- Terminal states reported by ActivityKit cause immediate local cleanup of `currentActivity` and cancellation of the observer. This provides self-healing lifecycle independent of our explicit termination handlers.
- Observation is strictly additive and non-forcing. All existing push call sites, the `lastPushedContent` dedup logic, privacy gates, and test short-circuits remain unchanged and primary. The net effect is stronger reactivity and fewer wasted `update(using:)` crossings of the ActivityKit boundary.

See `RadioLiveActivityManager.swift` (``beginObservingActivityEvents(_:)``, ``activityObservationTask``, class header), `WidgetSurface/WidgetEventObserver.swift`, and the cross-references below. The Tier 2 Live Activity events item (plus the parallel PlayerEvent consumer in `WidgetRefreshManager`) is complete; the common observation pattern is now in one internal helper for future consumers.

### Invariants (Must Hold After Any Edit)

- **PersistedWidgetState is never bypassed** for widget display, liveness, or relaunch decisions. All providers, `loadSharedState`, and `isMainAppProcessRecentlyActive` continue to read it.
- Live Activity visual state can be (and is) derived from in-memory SPM values without requiring a `UserDefaults` write in the common path.
- An `Activity.update` is sent only when `(visualState, streamMetadata)` differs from the last pushed value.
- Termination cleanup (`handleAppWillTerminate`, `forceStaleLivenessTimestampForTermination`, `endActivity(.immediate)`) is unchanged.
- Widget observable behavior (timeline entries, "tap_to_open" after quit, program title in snapshots) is unchanged.

### Background Playing Considerations

When the app is backgrounded while playing:
- An activity is started (if needed) so the user has controls.
- ICY metadata events and any later visual transitions continue to drive immediate LA pushes (the streaming engine keeps running).
- No periodic 10 s polling occurs. Battery impact is limited to actual content changes (title updates, pause/resume).

The fallback timer is retained for the rare situation where normal event delivery is interrupted while audio continues to play. It is not started by default. Any code that explicitly starts it should do so intentionally, after considering the additional battery and performance cost.

### Call Sites That Must Route Through the Event Path (or the manager's dedup)

- All visual intent changes that reach `.playing` / `.userPaused` / security etc.
- All successful ICY `StreamTitle` deliveries.
- Foreground "catch-up" correction.
- The bridge inside `performActualSave` (intentionally retained so that any visual save also gives LA a chance to converge; the manager suppresses duplicates).

See `RadioLiveActivityManager.swift` (class docs, ``updateCurrentActivity()``, ``lastPushedContent``, ``beginObservingActivityEvents(_:)``, ``activityObservationTask``, `startLocalUpdateTimer`) and the call sites in `SharedPlayerManager` (set* methods + `didUpdateStreamMetadata`) and `RadioPlayerCoordinator`.

## Media Surface Coordination & Lock Screen Stacking

System Now Playing, Live Activities, and widgets are three independent iOS surfaces with intentional coexistence. When both Now Playing and a Live Activity are active, iOS stacks both cards on the Lock Screen — expected platform behavior, not a defect.

- **Formatter parity:** `StreamProgramMetadata.nowPlayingDisplayStrings(...)` (`WidgetSurface/StreamProgramMetadata.swift`) is shared with ``updateNowPlayingInfo()`` and widget/LA title resolution. ICY ``from(rawICYMetadata:)`` recognizes spaced ASCII hyphen-minus, en dash (U+2013), and em dash (U+2014) speaker/title separators so speaker attribution reaches Now Playing, widgets, and Live Activities from the same parse.
- **Coordinated refresh:** ``SharedPlayerManager/refreshAllMediaSurfaces(liveActivity:widgetRefresh:widgetRefreshImmediate:)`` (main app) aligns Now Playing + Live Activity after visual transitions; widget reloads remain on the Tier 2 ``PlayerEvent`` observer unless explicitly requested.
- **LA start policy:** First `.playing` via ``setPlaying()`` (``.startOrUpdate``); background catch-up via ``RadioLiveActivityManager/handleAppWillEnterBackground()``; termination ends LA immediately.

Full stacking matrix, push-cost analysis, and QA scenarios: [`docs/Live-Activity-Stacking-and-Media-Surfaces.md`](Live-Activity-Stacking-and-Media-Surfaces.md).

## Cross-References

### `WidgetSurface/` (presentation-only embedded framework)

- `PlayerVisualState.swift` — `PlayerVisualState`, `PlaybackIntent`, `makeStatusPresentation()` / `makeControlPresentation()` + semantics of `isActivelyPlaying`.
- `WidgetNowPlayingDisplay.swift` — `WidgetMetadataEmphasis`, `WidgetNowPlayingDisplayModel`, `widgetNowPlayingDisplayModel(...)`.
- `WidgetTimelineEntryFactory.swift` — `WidgetProviderSnapshotFields`, `WidgetProviderPresentationSlices`, home/control entry blueprints.
- `WidgetLivenessPresentation.swift` — passive `tap_to_open` vs interactive chrome policy.
- `StreamProgramMetadata.swift` — parsed stream metadata + `nowPlayingDisplayStrings(...)` SSOT.
- `WidgetEventObserver.swift` — shared `contentUpdates` / `PlayerEvent` observation helper.
- `WidgetIntentCoordinators.swift` — toggle/stream-switch **plans** for App Intents (execution in `WidgetIntentExecution`).

### Cross-target + extension shells

- `WidgetSurface/WidgetLanguageDisplay.swift` — pure ``displayFlag(for:)``, ``displayLanguageName(for:preferredStreamLanguage:)``.
- `WidgetSurface/WidgetProviderPresentationAssembly.swift` — pure Provider presentation slice assembly.
- Membership-exception `WidgetDisplayModels.swift` — ``WidgetProviderSnapshotResolver`` (snapshot reads, actor hygiene, stream-catalog labels), catalog-aware ``displayLanguageName(for:)`` wrapper, ``WidgetIntentExecution``; calls `SharedPlayerManager` / `WidgetRefreshManager` for hygiene and optimistic intent side effects.
- `LutheranRadioWidget.swift` — `SimpleEntry`, `Provider`, family views, `WidgetMetadataRegion` (thin delegates to coordinators + factory).
- `LutheranRadioWidgetLiveActivity.swift` — `LutheranRadioLiveActivityWidget`, `LockScreenLiveActivityView`, Dynamic Island regions, intents.
- `LutheranRadioWidgetControl.swift` — Control widget `Value` + toggle (same derivation path as home widgets).
- `SharedPlayerManager.swift` — `PersistedWidgetState`, `isMainAppProcessRecentlyActive`, `forceStaleLivenessTimestampForTermination`, `bumpWidgetLivenessTimestamp`.
- `RadioLiveActivityManager.swift`, `WidgetRefreshManager.swift`, `AppDelegate.swift`, `SceneDelegate.swift`.
- `CODING_AGENT.md` — Documentation & Comment Standards, Single Source of Truth Principles, cross-target shared files.
- [`docs/Widget-Functionality-Roadmap.md`](Widget-Functionality-Roadmap.md) — widget backlog, test coverage, `WidgetSurface` coordinator status.

All user-visible strings use `String(localized: "...", table: "Localizable")`.

## See Also

- `README.md` (Single Sources of Truth section)
- [`docs/Widget-Functionality-Roadmap.md`](Widget-Functionality-Roadmap.md)
- `<doc:Architecture>` (in the Core DocC catalog)
