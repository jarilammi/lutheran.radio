# Live Activity Stacking & Media Surface Coordination

**Purpose:** Canonical reference for how Lutheran Radio coordinates **system Now Playing** (`MPNowPlayingInfoCenter`), **ActivityKit Live Activities**, and **WidgetKit** surfaces — including the intentional dual-card lock screen UX, Live Activity start policy, metadata push cost, and the ``SharedPlayerManager/refreshAllMediaSurfaces(liveActivity:widgetRefresh:widgetRefreshImmediate:)`` coordination wrapper.

**SeeAlso:** [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md), [`docs/Widget-Functionality-Roadmap.md`](Widget-Functionality-Roadmap.md), `SharedPlayerManager+NowPlaying.swift`, `RadioLiveActivityManager.swift`, `StreamProgramMetadata.swift`, CODING_AGENT.md (Single Source of Truth Principles).

---

## Three Independent System Surfaces (By Design)

Lutheran Radio participates in three first-class iOS presentation layers for background audio:

| Surface | Framework | What the user sees | Authoritative content |
|---------|-----------|-------------------|------------------------|
| System Now Playing | MediaPlayer (`MPNowPlayingInfoCenter`) | Compact lock-screen / Control Center card with transport controls and placeholder artwork | ``StreamProgramMetadata/nowPlayingDisplayStrings(fromParsed:rawFallback:stationName:languageName:)`` via ``updateNowPlayingInfo()`` |
| Live Activity | ActivityKit | Rich branded card: program title, speaker, language flags, App Intent play/pause + switch | In-memory ``currentVisualState`` + ``currentStreamMetadata`` pushed by ``RadioLiveActivityManager`` |
| Home / Control widgets | WidgetKit | Glanceable status + controls from frozen snapshot | ``PersistedWidgetState`` via ``loadPersistedWidgetState()`` |

These are **not** interchangeable. Coexistence is correct architecture. The app's job is **content parity** (same program title rules) and **coordinated refresh** (no surface left stale after a mutation).

---

## Lock Screen Stacking (Expected, Not a Bug)

When playback is active and a Live Activity is running, iOS renders **both**:

1. **Top:** System Now Playing (purple/system chrome, placeholder artwork, LIVE bar, hardware transport keys).
2. **Below:** Lutheran Radio Live Activity (`LockScreenLiveActivityView` — program line, flags, custom pause/play).

This stacking is **platform behavior**. Many streaming apps show both when they use Live Activities alongside `MPNowPlayingInfoCenter`. Lutheran Radio does not suppress either surface while the main process is alive and audio is authorized.

### Stacking Scenarios (Validation Matrix)

| Scenario | Now Playing | Live Activity | User-added lock widget | Expected UX | Policy |
|----------|-------------|---------------|------------------------|-------------|--------|
| Playing, LA started | Visible | Visible (stacked) | None | Two cards + DI | **Accept** — primary surfaces |
| Playing + user lock widget | Visible | Visible | Lutheran home widget on lock screen | Up to three glanceable regions | **Accept** — user chose to add widget |
| Paused (main app alive) | Visible (rate 0) | Visible (subdued program retained) | Any | LA play button remains tappable | **Intentional** — quick resume |
| After termination / force-quit | Cleared (phase 1 teardown) | Ended `.immediate` | Passive `tap_to_open` after liveness window | No interactive LA | **Cleanup Invariant** |
| Background audio, no LA yet | Visible | Started on `setPlaying` or `handleAppWillEnterBackground` | N/A | LA appears when playing | See start policy below |

**Screenshot capture (device / simulator QA):** Verify the matrix above on iPhone 17-class hardware with (a) playing stream + LA only, (b) paused with program title retained on both cards, (c) optional user-added Medium lock widget while playing. Metadata lines should match (e.g. same parsed program title on Now Playing title and LA center region). No automated screenshot gate — manual visual confirmation during release QA.

---

## Live Activity Start Policy (Intentional)

Live Activities are **not** requested at cold launch. They start when playback becomes authoritative:

| Trigger | Entry point | Mode | Rationale |
|---------|-------------|------|-----------|
| First successful `.playing` | ``setPlaying()`` → ``refreshAllMediaSurfaces(liveActivity: .startOrUpdate)`` | Start if `currentActivity == nil`, else update | User has confirmed live audio; LA controls are meaningful |
| Background while playing | ``RadioLiveActivityManager/handleAppWillEnterBackground()`` | ``startActivity()`` when `loadSharedState().isPlaying && currentActivity == nil` | Lock-screen / DI controls while audio continues |
| Foreground correction | ``handleAppDidEnterForeground()`` | ``updateCurrentActivity()`` only | Catch-up after long background without polling |
| User pause / stop | ``stop()``, ``setUserPaused()``, etc. | Update only (LA **not** ended) | Paused LA with working play intent is intentional while process lives |
| Process termination | ``handleAppWillTerminate()`` | ``endActivity(.immediate)`` | No orphaned interactive LA after process exit |

**Never** start LA from widget extension processes. Activity ownership is main-app only.

**UITest / unit test isolation:** ``startActivity()`` and ``updateCurrentActivity()`` no-op under ``SharedPlayerManager/isRunningInUITestMode`` and DEBUG ``isRunningUnderTest`` so `xcodebuild test` stays fast.

---

## Metadata Push Cost (Negligible in Practice)

### Live Activity

``RadioLiveActivityManager/updateCurrentActivity()`` builds a candidate ``ContentState(visualState:streamMetadata:)`` and compares it to in-memory ``lastPushedContent``. **ActivityKit IPC occurs only when the tuple differs** (or on first push). ICY title churn therefore costs one crossing per actual title/speaker/visual change, not per timer tick.

The attribute-events observer (``contentUpdates`` via ``WidgetEventObserver``) keeps ``lastPushedContent`` aligned with the system-accepted state, strengthening suppression of redundant ``Activity.update`` calls.

Protected by ``RadioLiveActivityManagerTests`` (`_test_wouldSuppressLiveActivityUpdate`).

### System Now Playing

``updateNowPlayingInfo()`` writes to ``MPNowPlayingInfoCenter``. Apple documents coalescing of frequent updates; Lutheran Radio does not implement an additional app-side dedup layer.

### Widgets

Mutation-path timeline reloads are driven by the Tier 2 ``PlayerEvent`` observer in ``WidgetRefreshManager`` (debounce + coalesce). Imperative ``refreshIfNeeded`` remains for lifecycle, teardown, extension optimistic intents, and optional ``refreshAllMediaSurfaces(widgetRefresh: true)`` call sites.

---

## `refreshAllMediaSurfaces` Coordination Wrapper

**Location:** `SharedPlayerManager+NowPlaying.swift` (main app only).

**Contract:**

```swift
await refreshAllMediaSurfaces(
    liveActivity: .updateIfActive,   // .none | .updateIfActive | .startOrUpdate
    widgetRefresh: false,            // true only when bypassing PlayerEvent observer
    widgetRefreshImmediate: false
)
```

**Order:** Now Playing → Live Activity (per mode) → optional widget refresh.

**Guards:** Widget extension, session teardown, UITestMode — all no-op (no ActivityKit / WidgetCenter IPC).

**Does not replace** ``didUpdateStreamMetadata(_:)``, which intentionally pushes Live Activity **before** Now Playing and **before** widget snapshot persist for minimum ICY-to-LA latency.

### Canonical call sites (post–Tier 4)

| Mutation | Wrapper mode |
|----------|----------------|
| ``setPlaying()`` | `.startOrUpdate` |
| ``stop()``, ``setUserPaused()``, ``markAsUserPaused()``, ``markPlaybackStoppedByStreamFailure(_:)`` | `.updateIfActive` |
| ``clearSoftPauseMetadataStashForLanguageChange()`` | `.updateIfActive` |
| ``didUpdateStreamMetadata(_:)`` | Custom order (not the wrapper) |
| KVO transient rate-only sync (`DirectStreamingPlayer`) | ``updateNowPlayingInfo()`` only |
| ``performActualSave`` LA bridge | Direct ``updateCurrentActivity()`` (widget-parity catch-up) |

---

## Formatter Parity (OI-W4 Resolution)

Program title and speaker attribution use a single SSOT:

``StreamProgramMetadata.nowPlayingDisplayStrings(fromParsed:rawFallback:stationName:languageName:)``

Consumed by:

- ``updateNowPlayingInfo()`` (Now Playing title + artist)
- ``WidgetDisplayModels.widgetNowPlayingDisplayModel(...)`` (widgets)
- Live Activity views (via ``ContentState.streamMetadata`` + presentation pre-derivation)

The **dual-card layout** remains; **metadata mismatch** between cards is a bug. Stacking itself is not.

---

## Cross-References

- [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md) — presentation surfaces, LA event-driven model, termination invariant
- [`docs/Widget-Functionality-Roadmap.md`](Widget-Functionality-Roadmap.md) — Tier 4 completion status
- [`docs/Event-Driven-Refactor-Roadmap.md`](Event-Driven-Refactor-Roadmap.md) — `PlayerEvent` consumer paths
- `Lutheran RadioTests/RadioLiveActivityManagerTests.swift` — LA diff suppression
- `Lutheran RadioTests/SharedPlayerManagerEventTests.swift` — `refreshAllMediaSurfaces` contract