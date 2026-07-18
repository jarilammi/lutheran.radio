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
| Paused (main app alive) | Visible (rate 0, `playbackState` `.paused`) | Visible (subdued program retained) | Any | LA play button remains tappable | **Intentional** — quick resume |
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

**Lock-screen toggle optimistic ContentState:** ``WidgetIntentExecution/performLiveActivityToggle()`` publishes the post-toggle control visual via ``pushOptimisticLiveActivityToggleContent(visualState:)`` (ActivityKit `Activity.update` on interactive activities, preserving ``streamMetadata`` through ``ContentState/replacingVisualState(_:)``) and writes the durable App Group toggle mirror. On the main app it also calls ``RadioLiveActivityManager/recordOptimisticToggleContent(visualState:)`` so ``lastPushedContent`` matches the optimistic glyph; when sticky lock / soft silence later produces the same visual, ``updateCurrentActivity()`` suppresses as a no-op. A rapid second tap therefore resolves from post-toggle content (preferred over a lagging mirror or actor), not stale pre-tap content.

Protected by ``RadioLiveActivityManagerTests`` (`_test_wouldSuppressLiveActivityUpdate`, optimistic alignment), ``WidgetIntentContractExtensionTests``, ``WidgetSurfaceTests`` (content replace + second-tap plan).

### System Now Playing

``updateNowPlayingInfo()`` writes to ``MPNowPlayingInfoCenter``. On every live update it sets:

| Field | Source | Values |
|-------|--------|--------|
| Dictionary `MPNowPlayingInfoPropertyPlaybackRate` | ``currentVisualState.isActivelyPlaying`` | `1.0` playing / `0.0` otherwise |
| Center `playbackState` | Same visual | `.playing` / `.paused` while the session is live |

Session teardown and privacy clear (``teardownNowPlayingSession()``, ``clearSystemNowPlayingMetadataSynchronously()``) set `nowPlayingInfo = nil` and `playbackState = .stopped` — not the live-update path.

Apple documents coalescing of frequent updates; Lutheran Radio does not implement an additional app-side dedup layer.

### Remote command surface

``configureNowPlayingControlsIfNeeded()`` installs play / pause / toggle play-pause / stop on ``MPRemoteCommandCenter`` and **disables** unsupported commands (next/previous track, seek, skip, change position/rate, repeat/shuffle, rating/like/dislike/bookmark, language-option enable/disable). Continuous live radio has no track list or seekable timeline; leaving those commands enabled would surface dead affordances on lock screen, Control Center, and hardware remotes.

**Serial media-transport mailbox:** Remote handlers return `.success` immediately and enqueue ``MediaTransportCommand`` values via ``SharedPlayerManager/submitMediaTransportCommand(_:)``. Play and toggle wait for the prior verb; pause/stop preempt (cancel + ``stop()`` without waiting for an in-flight play) and record a pause epoch so a late `userRequestedPlay` re-asserts sticky `.userPaused`. Toggle direction is decided only inside ``performMediaTransportCommand(_:generation:)`` after prior verbs commit state — never as a split `isActivelyPlaying` read in the remote-command callback. Main-app ``WidgetIntentExecution/executeLiveActivityToggle(plan:)`` uses ``submitMediaTransportCommandAndWait(_:)`` so Live Activity engine execution shares the same ordering as headset / Control Center.

**Extension-hosted Live Activity / home-widget play-pause:** The extension process still uses direct ``stop()`` / ``userRequestedPlay()`` (optimistic snapshot + `pendingAction*` + Darwin `notifyMainApp`). Real audio changes only after the main app drains via ``ViewController/checkForPendingWidgetActions()``. Drain rules that keep chrome trustworthy:

- **Same-direction debounce (0.65 s):** A second `"play"` or second `"pause"` within the window is dropped after clearing the pending key (AVFoundation thrash guard). **Opposite** verbs always execute so a rapid flip is not lost after optimistic ContentState already showed the second glyph.
- **Mailbox on drain:** Drained play and pause enqueue ``submitMediaTransportCommandAndWait`` (play) / coordinator pause (pause → mailbox), so an opposite pause can preempt an in-flight extension-originated play the same way system remotes do. Pause drain uses a single MainActor Task (no nested coordinator Task hop).
- **Delivery path:** Darwin `deliverImmediately` + main-queue drain remains primary; SceneDelegate become-active / launch 1…5 s burst are defense-in-depth. No long-period poll timer (unreliable while suspended). UITestMode still clears pendings without executing unless the DEBUG bypass is set.

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

## Formatter Parity

Program title and speaker attribution use a single SSOT:

``StreamProgramMetadata.nowPlayingDisplayStrings(fromParsed:rawFallback:stationName:languageName:)``

Consumed by:

- ``updateNowPlayingInfo()`` (Now Playing title + artist)
- ``WidgetDisplayModels.widgetNowPlayingDisplayModel(...)`` (widgets)
- Live Activity views (via ``ContentState.streamMetadata`` + presentation pre-derivation)

The **dual-card layout** remains; **metadata mismatch** between cards is a bug. Stacking itself is not.

---

## User Pause During Connect / First-Play Attach

When the user pauses (system Now Playing, Live Activity, headset, or in-app) while security validation or secured item attach is still in flight:

1. **``SharedPlayerManager/stop()``** locks sticky `.userPaused` and intent **before** calling the engine, and emits `streamDidStop`.
2. **``DirectStreamingPlayer/stopAndWait(reason:silent:applyUserPauseVisualLock:)``** advances a monotonic attach generation and runs soft pause (rate 0, secured item retained when present). There is no early return that leaves attach free to start audio. SPM passes `applyUserPauseVisualLock: false` so the engine does not re-enter sticky visual lock / surface refresh.
3. **Engine-complete barrier:** Soft pause applies `player.pause()` + `rate == 0` and sets soft-pause **before** `stopAndWait` returns. Only then does SPM run the single ``refreshAllMediaSurfaces`` (Now Playing rate + `playbackState` / Live Activity glyph). Chrome must not lead audible audio.
4. **Start paths** (`play()`, `setStreamAndPlay`, `createAndStartPlayer`, `startPlayback`) re-check generation + ``canProceedWithPlayback()`` after every significant `await` and discard without audible start.
5. **Audible kicks** (readyToPlay `playImmediately`, ICY head-start, recreate restart) go through a shared gate that also blocks soft-paused and teardown-active state.

Required convergence: paused chrome and silent engine — never durable “paused UI + audible stream” from this race. Single ownership for “user pause complete”: SPM sticky lock + one surface refresh after soft silence.

**SeeAlso:** `DirectStreamingPlayer` in-flight attach helpers and `stopAndWait`, `SharedPlayerManager.play()` post-validation sticky re-checks, `Lutheran RadioTests` attach-generation and soft-silence completion coverage.

---

## Cross-References

- [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md) — presentation surfaces, LA event-driven model, termination invariant
- [`docs/Widget-Functionality-Roadmap.md`](Widget-Functionality-Roadmap.md) — Tier 4 completion status
- [`docs/Event-Driven-Refactor-Roadmap.md`](Event-Driven-Refactor-Roadmap.md) — `PlayerEvent` consumer paths
- `Lutheran RadioTests/RadioLiveActivityManagerTests.swift` — LA diff suppression
- `Lutheran RadioTests/SharedPlayerManagerEventTests.swift` — `refreshAllMediaSurfaces` contract; Now Playing rate/`playbackState` alignment; unsupported remote-command disable; media-transport mailbox (double-toggle, pause preemption, LA + remote interleave)