# Widget & Live Activity Presentation Dataflow

This document is the concise, permanent reference for how Lutheran Radio derives and consumes presentation data for WidgetKit home-screen widgets and ActivityKit Live Activities (Dynamic Island + Lock Screen).

It complements (and is cross-referenced by) the source headers in `LutheranRadioWidget.swift`, `LutheranRadioWidgetLiveActivity.swift`, `WidgetSurface/` (`PlayerVisualState.swift`, `PlayerPresentation.swift`, `PlaybackIntent.swift`, `PlayerEvent.swift`, `WidgetNowPlayingDisplay.swift`, `WidgetTimelineEntryFactory.swift`, `WidgetProviderPresentationAssembly.swift`, `WidgetLanguageDisplay.swift`, `WidgetLivenessPresentation.swift`), membership-exception `WidgetDisplayModels.swift`, and `CODING_AGENT.md`.

## Snapshot-Driven Model

WidgetKit and ActivityKit deliver **frozen value-type snapshots** across process boundaries:

- **Home widgets**: `Provider` (conforming to `AppIntentTimelineProvider`) produces `SimpleEntry` values. The system compares `TimelineEntry` fields to decide re-evaluation.
- **Live Activities**: `RadioLiveActivityManager` pushes `LutheranRadioLiveActivityAttributes.ContentState` (containing `visualState` + `streamMetadata` + `currentLanguage`). The system renders via `ActivityConfiguration` closures and `LockScreenLiveActivityView`. Language chrome (flag, name, alt-stream “current”) reads **only** `context.state.currentLanguage` (hoisted once), never privacy-gated ``preferredWidgetLanguage()``.

There are no live `@Observable` objects inside the widget extension. All display decisions are computed from the snapshot at derivation time or consumption time.

## The Three Narrow Presentation Surfaces

All presentation is organized into three narrow, `Equatable` value types derived from the authoritative `PlayerVisualState` (plus optional `StreamProgramMetadata`):

| Surface                        | Type                              | Mapper / Resolver (`WidgetSurface/`)           | What it carries                          | Consumers |
|--------------------------------|-----------------------------------|------------------------------------------------|------------------------------------------|-----------|
| Status indicator               | `PlayerStatusPresentation`        | `PlayerVisualState.makeStatusPresentation()` (`PlayerPresentation.swift`; colors via `PlayerVisualChromePalette`) | `background`, `foreground`, `text`, `systemImage?` | Status text, pills, indicators in widgets + LA + Control widget |
| Primary play/pause control     | `PlayerControlPresentation`       | `PlayerVisualState.makeControlPresentation()` (`PlayerPresentation.swift`; tint via `PlayerVisualChromePalette`) | `systemImage` ("play.fill"/"pause.fill"), `tint: Color` | Play/pause buttons (Small/Medium/Large, DI trailing/compactTrailing, Lock Screen row, Control widget) |
| Metadata / emphasis (title + speaker) | `WidgetNowPlayingDisplayModel` | `widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)` (`WidgetNowPlayingDisplay.swift`) | `programTitle`, `speakerLine`, `speakerVisible`, `emphasis: WidgetMetadataEmphasis` | `WidgetMetadataRegion`, DI center/compactLeading, Lock Screen metadata blocks |

**Derivation rule (snapshot-driven):**

- **Home widgets**: All three are computed **once per entry** inside the `Provider` (`placeholder`, `snapshot`, `timeline` / `createEntry`). Snapshot fields resolve via ``WidgetProviderSnapshotResolver`` (membership-exception `WidgetDisplayModels.swift`); presentation slices assemble via pure ``WidgetProviderPresentationAssembly`` (stream-catalog wrapper ``WidgetProviderSnapshotResolver/assemblePresentationSlices(from:)``); entry blueprints map through ``WidgetTimelineEntryFactory`` (`WidgetSurface/WidgetTimelineEntryFactory.swift`). Family views read the narrow properties from `SimpleEntry`. `SimpleEntry` stores only narrow presentation slices (status / control / metadata model + station + language + streams) — not full `PlayerVisualState`, raw `streamMetadata`, or a parallel status string. When the snapshot has `hasError`, assembly folds the localized “Connection error” string into `statusPresentation.text`. Passive `tap_to_open` chrome and stream chips are shared via `WidgetSurface/WidgetHomeChrome.swift` (`WidgetPassiveTapToOpenChrome`, `WidgetStreamChipLabel`).
- **Control Center widget**: Status and control surfaces are computed **once per value** inside `LutheranRadioWidgetControl.Provider` (`previewValue`, `currentValue`) using the same resolver + factory path, then stored on `LutheranRadioWidgetControl.Value`. The toggle label closure reads `statusPresentation` and `controlPresentation` only (no inline mapper calls in the view body).
- **Live Activities**: The three are computed **once at the top of `LockScreenLiveActivityView.body`** and **once inside the outer `dynamicIsland` closure**, then closed over by the region builders and subviews. No repeated derivation inside individual `.leading`/`.center`/etc. blocks for the presentation concerns. Shared layout chrome lives in `WidgetSurface/LiveActivityPresentationChrome.swift` (`LiveActivityMetadataBlock`, language labels / stream-switch chip labels, deterministic `LiveActivityEqualizerBars`). Alt-stream codes use pure ``alternativeStreamCodes(current:availableLanguageCodes:maxCount:fallbackCodes:)`` (catalog supplied at the extension boundary). **Dynamic Island expanded layout contract**: no `ScrollView` in any expanded region; language chips live in `.bottom` as a non-scrolling `HStack` of flag-only chips capped by ``liveActivityDynamicIslandAlternativeStreamMaxCount`` (3); center is status + fixed-height metadata only; trailing is a single play/pause control. Violating these size/hierarchy rules produces the system yellow ActivityKit compliance overlay (not an app status colour).

`WidgetMetadataRegion` is deliberately narrow: it receives only a `WidgetNowPlayingDisplayModel`.

## Why Pre-Derivation Matters

- **Invalidation cost**: WidgetKit performs structural comparison on the `TimelineEntry`. A change to an unrelated field (e.g. `configuration` or full `availableStreams` ordering) should not force re-work in a leaf that only renders the play glyph. Carrying the already-derived narrow value shrinks the set of mutations that cause body re-evaluation for that leaf.
- **Region work in ActivityKit**: Dynamic Island regions are independent. Re-deriving title/speaker or control glyph inside every region multiplies work on every push. One computation at the outer closure is bounded.
- **View simplicity**: Leaf views and region closures become trivial — they render exactly the four (or two) fields they need. No `switch`, no fallback logic, no `Color(uiColor:)` bridging inside bodies.
- **Consistency**: The same mapping rules apply to main-app UI (via `PlayerViewModel`), home widgets, Live Activities, and Control widgets because status/control mappers live on `PlayerVisualState` (`WidgetSurface/PlayerPresentation.swift`, palette in `PlayerVisualChromePalette`) and the metadata resolver lives in `WidgetSurface/WidgetNowPlayingDisplay.swift`.

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

See the headers of `WidgetSurface/PlayerVisualState.swift` (policy) and `WidgetSurface/PlayerPresentation.swift` (display derivation + chrome palette) for the exact division and AGENT NOTE.

## Adding or Changing a Presentation Axis (Guidance for Contributors)

1. Decide whether the concern belongs on one of the existing surfaces or needs a new narrow type (prefer adding a new `...Presentation` or `...DisplayModel` struct).
2. Implement (or extend) the pure mapper on `PlayerVisualState` (`WidgetSurface/PlayerPresentation.swift`) for status/control axes, or as a free function in `WidgetSurface/WidgetNowPlayingDisplay.swift` for metadata/emphasis. Color decisions belong in ``PlayerVisualChromePalette``. Pure Provider slice assembly stays in ``WidgetProviderPresentationAssembly``; snapshot hygiene wrappers stay in membership-exception `WidgetDisplayModels.swift`; blueprints stay in `WidgetSurface/WidgetTimelineEntryFactory.swift`.
3. Update derivation sites:
   - Add the new field to `SimpleEntry`.
   - Compute it once in `Provider.placeholder`, `createEntry`, and `timeline`.
   - Compute it once at the top of `LockScreenLiveActivityView.body` and inside the outer `dynamicIsland` closure (if applicable).
4. Change consumers (family views, regions, LA region closures, Control widget) to read only the narrow value.
5. Update `SimpleEntry` property documentation and the three main widget/LA files' headers.
6. Add or update an entry in the table above.
7. Update this document, the relevant `///` headers (with `- SeeAlso:`), and the `WidgetSurface/PlayerVisualState.swift` / `PlayerPresentation.swift` headers if the division of concerns changed.
8. Verify with the preview matrix in `LutheranRadioWidget.swift` and on-device widget/LA surfaces.

Never derive presentation inside leaf view `body` for the three canonical surfaces. Never duplicate the mapping rules.

## App Termination & Passive Widget / Live Activity Lifecycle

**Core rule (Cleanup Invariant)**: Widget and Live Activity surfaces are **active / updating only while the main app process is running** (foreground or background audio). Once the main process has quit (normal termination or force-quit), they must transition to a stable passive or last-known state and must not receive further pings, timeline reloads driven from the dead process, or Activity updates.

### How Termination Achieves Passive State
- **Liveness heuristic (SSOT)**: `SharedPlayerManager.isMainAppProcessRecentlyActive()` (backed by the `lastUpdateTime` key + explicit `0` sentinel). Widget family views delegate the passive-branch decision to ``WidgetLivenessPresentation/shouldShowPassiveTapToOpen(isMainAppRecentlyActive:)`` (`WidgetSurface/WidgetLivenessPresentation.swift`) to render either full interactive controls + status + metadata or the "tap_to_open" prompt. **Liveness owns interactive vs passive** — privacy-gated live chrome (below) is never proof the main app is still interactive.
- **Process isolation**: the termination sentinel is **presentation / extension only**. Main-app cold launch, `play()`, resurrection, and restore use in-process sticky intent after ``resetToFactoryDefaultsOnLaunch()`` — never `lastUpdateTime == 0` as a play gate. Play status does not survive process death (OI-1).
- **On observed termination** (AppDelegate `applicationWillTerminate`, SceneDelegate `sceneDidDisconnect`, `UIApplication.willTerminateNotification`):
  - `SharedPlayerManager.forceStaleLivenessTimestampForTermination()` writes the sentinel `0`, clears instant-feedback transients, clears durable LA mirrors, and **explicitly clears** privacy-gated ``homeWidgetLiveChrome`` (session-scoped only). Prefer explicit clear over “stale mirror + passive overlay” so passive Providers cannot briefly flash last play/pause glyphs from a dead process. Any subsequent Provider run immediately sees the passive path and factory visual defaults when session + live chrome are absent.
  - `RadioLiveActivityManager.handleAppWillTerminate()` **sweeps all** system-held Live Activities (not only the local `currentActivity` ref), pushes a final coherent `.userPaused` ContentState that **preserves last-known language chrome** (and program metadata when available), ends with `.immediate` dismissal, and **waits** (bounded run-loop pump + detached ActivityKit work) so process death cannot race an unfinished unstructured `Task`.
  - `WidgetRefreshManager.cancelPendingRefresh()` drops in-flight debounced work.
  - While the main process is alive, ``WidgetRefreshManager`` also identity-coalesces identical connecting / sticky chrome (`shouldCoalesceIdenticalNonPlayingRefresh`) so attach-path and dual-path storms do not spam `reloadTimelines` for unchanged language/visual. Language changes always reload (and mark the candidate **immediate** for regress gates). Stale debounced targets that regress a newer snapshot are discarded (`refreshWouldRegressPersistedSnapshot(executing:persisted:isImmediate:)`). Execute-time **memory SSOT authority** (`refreshWouldRegressMemoryAuthority(executing:memory:isImmediate:)`) additionally discards targets that reverse ``SharedPlayerManager/currentVisualState`` (residual sticky after intentional Connecting; premature ``.playing`` during switch/connect hold; non-immediate post-audible Connecting after audible play).
  - **Home soft-resume refresh authority:** Event-path Connecting (``.prePlay``) is **not** immediate (`refreshUsesImmediateDelivery`); it defers behind the ``.prePlay`` → ``.playing`` coalesce window so same-stream soft-resume schedules a single authoritative ``.playing`` home reload instead of painting Connecting after audio is already live. Sticky pause/lock and ``.cleared`` remain immediate. Independently, ``setUserIntentToPlay`` / play connecting chrome skip when ``DirectStreamingPlayer/PlaybackAttachState/canSoftResumeSameStream`` is true so gapless resume retains sticky visual until engine ``setPlaying()`` (no intermediate Connecting stamp). True attach / stream-switch still get Connecting until audible start. Dual-path architecture and privacy write suppression are unchanged. **Main-app in-process chrome** follows the same soft-resume intermediate and paints from visual SSOT (see **Main-App Chrome Authority** below) — orthogonal to WidgetKit reload timing.
  - **Home stream-switch first-paint honesty:** On active-play home (and extension LA co-path) stream switch, the optimistic session snapshot and first ``refreshIfNeeded`` target use ``WidgetIntentCoordinators/optimisticLiveActivityVisualForStreamSwitch(from:)`` — actively playing → Connecting (``.prePlay``); sticky pause preserved. Destination language advances immediately without claiming mid-switch ``.playing`` during silent attach hold. Authoritative ``.playing`` arrives later via main-app attach / ``setPlaying()``. At execute time, memory Connecting **discards premature ``.playing``** so a lagging dual-path playing target cannot flash mid-hold. Immediate language-change Connecting may advance a lagging session snapshot still on prior-language ``.playing``. Soft-resume prePlay→playing coalesce, sticky-pause directionality, and privacy write suppression are unchanged. Wired from widget-path ``switchToStream`` snapshot write and ``WidgetIntentExecution/executeHomeWidgetStreamSwitch(languageCode:)``.
  - **Sticky pause home refresh authority:** On ``stop()`` / sticky user-pause lock, when the home-widget privacy gate allows writes, ``SharedPlayerManager`` writes an early sticky ``.userPaused`` session snapshot (`persistEarlyStickyUserPausedSnapshotIfPrivacyAllows`) **before** soft silence and the deferred authoritative ``saveCurrentState()``. That keeps non-carried events (`streamDidStop`, `playbackIntentChanged`, `streamDidPause`) and the regress gate from re-reading lagging ``.playing``. Separately, ``refreshWouldRegressPersistedSnapshot`` is **directional**: non-immediate / adaptive-debounced ``.userPaused`` still discards when the session snapshot has already advanced to ``.playing`` (soft-resume reverse race), but **immediate** sticky-pause / teardown urgency does **not** discard ``.userPaused`` solely because the snapshot still lags on ``.playing`` (forward stop). Privacy write suppression with zero widgets is unchanged (early sticky is a no-op when the gate is closed).
  - **Home multi-surface refresh authority (connecting advance + bounded deferral):** When memory SSOT advances sticky → Connecting (``.prePlay``) on true attach, residual disk-derived sticky refreshes **discard** (memory authority) and Connecting may execute against a lagging sticky session snapshot (disk regress no longer treats Connecting as always stale vs sticky). Attach-path status storms that re-enter non-immediate Connecting **hold a single coalesce deadline** (do not reset the window on every callback) so first honest Connecting paint is not starved by multi-second “awaiting possible .playing follow-up” storms. Never invent home ``.playing`` during switch/connect hold to track main-app race-lead green.
  - Attach-path status / label saves identity-skip sticky Connecting snapshot re-persists (`shouldSkipForceWidgetSaveOnStableStatus`, `shouldSkipIdenticalStickyConnectingSnapshotWrite`) so `readyToPlay` wait storms do not re-emit ``.persistedWidgetStateDidUpdate`` for unchanged language + ``.prePlay``.
- **After force-quit** (notification not delivered): no further main-process saves or `reloadTimelines` occur. The 60 s window is the worst-case staleness for the heuristic; after that widgets naturally render passive. The snapshot (`PersistedWidgetState`) is deliberately left behind (last-known visual + language + metadata). Any Live Activity residual is **reaped on next cold launch** by `RadioLiveActivityManager.observeExistingActivities()` (final paused frame + immediate end — never re-adopted as interactive `.playing` without a live engine). When deferred observe finds this-process ``currentActivity`` already set (start raced ahead of post-init yield), full ``endActivity`` is not used for the owned surface; **sibling** system residuals (other activity ids) are still ended so ownership cannot leave a second residual interactive.
- **Passive presentation**:
  - Widgets show icon + localized "tap_to_open" + `widgetURL(URL(string: "lutheranradio://open"))`. Tapping performs a clean, Apple-approved launch with no side-effect playback.
  - Live Activity is removed from the Dynamic Island / Lock Screen (no lingering interactive surface after a delivered terminate path, or after residual reaping on relaunch).
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

| Concern                        | Single Source of Truth                  | Write Path                                      | Read for Live Activity / Provider       | Disk I/O on hot path? |
|--------------------------------|-----------------------------------------|-------------------------------------------------|-----------------------------------------|-----------------------|
| Widgets + Control widgets (visual / language / hasError) | In-process `PersistedWidgetState` session snapshot + privacy-gated App Group ``homeWidgetLiveChrome`` | `persistWidgetSnapshot` / ``savePersistedWidgetState`` → ``stampHomeWidgetLiveChromeFromSession`` (sticky early pause, ``setPlaying``, switch hold, ``performActualSave``); extension optimistic via ``persistOptimisticWidgetSnapshot`` / ``signalWidgetSwitchAction``; gate-open re-stamp | ``WidgetProviderSnapshotResolver/resolveFromSnapshot()`` via pure ``resolveHomeWidgetChromeFields``: **agreement → session; disagreement → fresher `updatedAt`; neither → factory** | Session is memory-only (OI-1); live chrome is privacy-gated App Group (session-scoped; cleared on terminate / gate close / privacy clear / factory residual). Fresher main mirror heals stale extension-session switch-hold ``.prePlay``. |
| Widgets + Control widgets (program title/speaker) | In-process session `streamMetadata` + privacy-gated App Group ``homeWidgetStreamMetadata`` | ICY via ``persistStreamMetadataForWidgets()`` / privacy-gate open re-stamp; snapshot saves when gate open | Resolver: session metadata → ``loadHomeWidgetStreamMetadataMirror()`` (unchanged single-concern peer) | Program metadata mirror is privacy-gated App Group |
| Widget passive chrome after quit | Liveness (`lastUpdateTime` + sentinel `0`) | `bumpWidgetLivenessTimestamp`, `forceStaleLivenessTimestampForTermination` (also clears live chrome + LA mirrors + instant feedback) | `isMainAppProcessRecentlyActive` / ``WidgetLivenessPresentation`` — **not** live chrome | Yes (providers) |
| App relaunch / main-app play   | In-process visual + `PlaybackIntent` after ``resetToFactoryDefaultsOnLaunch()`` | Factory reset + sticky intent SSOT; **not** termination sentinel | Cold-launch / `play()` / resurrection | No prior-process play gate |
| Live Activity (transient UI)   | In-memory `currentVisualState` + `currentStreamMetadata` + stream language (`liveActivityLanguageCodeForContentPush` — attach via `mainAppLiveActivityLanguageCode` / `selectedStream`, or destination language while `streamSwitchConnectingLanguageCode` is stamped: Connecting hold **or** sticky-paused stamp without hold) | None for LA itself. Visual/metadata/language mutations + direct notify; durable LA language App Group mirror warmed on push | `await manager.currentVisualState` / `currentStreamMetadata` + language for `ContentState.currentLanguage` | **No** (in-memory compare + conditional `Activity.update`) |

### How Event-Driven Updates Work

1. **Primary drivers** (no timer required):
   - `SharedPlayerManager.setPlaying()`, `stop()`, `setUserPaused()`, `markAsUserPaused()` — after the widget-persisting save they post a `Task { await RadioLiveActivityManager.shared.updateCurrentActivity() }`.
   - `didUpdateStreamMetadata(_:)` — after mutating the in-memory metadata, calls the LA manager directly, **then** persists for widgets (session snapshot + privacy-gated ``homeWidgetStreamMetadata`` App Group mirror). This ordering ensures LA sees the fresh title without waiting for disk. When ICY arrived under write suppression, ``restampHomeWidgetProgramMetadataAfterPrivacyGateOpenIfNeeded()`` re-stamps once when ``hasActiveWidgets`` opens. ICY does **not** stamp live chrome (metadata-only path).
   - `RadioPlayerCoordinator` toggle / remote / sleep paths — direct calls after state is stable.
   - Lifecycle: `handleAppDidEnterForeground` (correction), `handleAppWillEnterBackground` (auto-start when playing).

2. **Inside `RadioLiveActivityManager`**:
   - `updateCurrentActivity()` computes a candidate `ContentState(visualState:streamMetadata:currentLanguage:)`.
   - Suppress uses ``shouldSuppressLiveActivityContentPush`` against private `lastPushedContent` **and** owned `content.state.currentLanguage` **and** owned `content.state.visualState` (owned language + visual beat optimistic suppress memory).
   - Only when not suppressed does it call `Activity.update`, then re-seeds `lastPushedContent` from the activity’s observed `content.state` (never an unverified aspirational candidate).
   - ``ensureAuthoritativeLanguageContentIfNeeded()`` re-pushes (up to ``authoritativeLanguageContentEnsureMaxAttempts``, re-reading owned language after each push) when destination language from ``liveActivityLanguageCodeForContentPush()`` still differs from owned / last language (peer to playing ensure). After budget exhaustion while interactive request is ineligible, language ensure quiet pending stops status-driven thrash for that destination until re-arm (destination change, eligibility, become-active, or `contentUpdates`). Language-only ``updateCurrentActivity`` re-pushes defer while quiet; visual mutations still push. Also on foreground / become-active via ``ensureAuthoritativeContentOnForegroundIfNeeded()`` when ownership is non-nil (clears language + playing quiet first; dual SceneDelegate hooks debounced by ``shouldInvokeOwnedSurfaceForegroundEnsure`` while still consuming quiet/pending).
   - ``pushSettledLanguageAcceptanceContentIfNeeded()`` after stream-switch hold clears (``setPlaying`` / soft-resume no-op) when owned language still lags destination: clears language quiet once, re-runs a **full** ``ensureAuthoritativeLanguageContentIfNeeded()`` soft budget, and while still lagging under ineligible request schedules bounded delayed post-settled soft ensure (``postSettledLanguageEnsureDelayedIntervalsMilliseconds``). Consume-once settle entry while ineligible; re-open on destination change, eligibility, become-active, or `contentUpdates`. Soft budgets may still exhaust without owned language acceptance for some lock-stretch playing switches; become-active / ``ensureAuthoritativeContentOnForegroundIfNeeded()`` is the proven presentable-window heal.
   - ``pushSettledPlayingAcceptanceContentIfNeeded()`` fires **one** dual-axis high-signal push after hold/connect clear when the actor is authoritative `.playing` and owned visual still lags (``.prePlay`` / ``.userPaused``) — bypasses playing quiet once while ineligible so attach-storm / soft-resume quiet cannot freeze Connecting chrome for the whole lock stretch. Consume-once; re-open on optimistic toggle / stream-switch, eligibility, become-active, or `contentUpdates`.
   - ``ensureAuthoritativePlayingContentIfNeeded()`` re-pushes (up to ``authoritativePlayingContentEnsureMaxAttempts``, re-reading owned visual after each push) when actor is authoritative `.playing` without hold/connect but last-pushed or owned visual is still `.prePlay` or `.userPaused` (stream-switch Connecting sampler + soft-resume pause / Connecting freeze). After budget exhaustion while request is ineligible, playing ensure quiet pending stops status-driven thrash; visual-only `.playing` repair re-pushes defer while quiet; pause and language mutations still push. Re-arm on ``rearmPlayingEnsureQuietPending()``, optimistic toggle / stream-switch, eligibility, become-active, or `contentUpdates`. Concurrent soft-ensure re-entry collapses into one in-flight loop per axis. Also invoked from soft-resume publish when actor visual is already `.playing` (publish no-op path runs settled language + playing acceptance then soft ensure without blind re-arm) and from foreground owned-surface ensure. ``setPlaying`` sequences settled language acceptance then settled playing acceptance then soft playing ensure so one ContentState can co-converge both axes without soft-resume thrash.
   - After a bounded streak of `Activity.update` results that leave system-held chrome lagging (system `content.state` language still prior, or visual stuck on `.userPaused` / `.prePlay` while candidate needs Connecting/playing/pause), recreation is considered. End + ``startActivity()`` runs **only when** interactive request is eligible (activities enabled + application active); otherwise the existing surface is kept and a pending ensure is recorded **once** per freeze (no deferred-log flood while still ineligible). On become-active with ownership already non-nil, ``shouldInvokeOwnedSurfaceForegroundEnsure`` gates the cycle (consume quiet/pending; debounce dual hooks; second pass when chrome still lags while eligible), then soft language/playing ensure runs first; eligible-only recreation only if soft ensure still fails. Pure visual freezes prefer soft playing-ensure retries. See docs/Live-Activity-Stacking-and-Media-Surfaces.md.

3. **Lock-screen toggle optimistic ContentState** (intent path, main or extension host):
   - ``WidgetIntentExecution/performLiveActivityToggle()`` plans from multi-source resolve, then writes the durable toggle mirror and calls ``pushOptimisticLiveActivityToggleContent(visualState:)``.
   - Home/Control ``executeOptimisticToggle`` uses the same durable mirror + optimistic ContentState path for definitive play/pause targets so a home pause does not leave lock-screen chrome stuck on Connecting.
   - That helper updates interactive `Activity` instances with ``ContentState/replacingVisualState(_:)`` (program metadata **and** `currentLanguage` preserved) and, on the main app, ``RadioLiveActivityManager/recordOptimisticToggleContent(visualState:)`` so ``lastPushedContent`` matches the optimistic glyph before engine-complete refresh.
   - ``SharedPlayerManager/stop()`` also warms the durable mirror at sticky lock and (main app) pushes optimistic ``.userPaused`` ContentState before soft silence — pause honesty does not require owned visual to have been ``.playing`` first.
   - Multi-source resolve trusts non-Connecting ContentState; system-held Connecting defers to a definitive durable/actor/session peer so planning does not invert under lock-stretch freezes.
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
- On every yield the manager aligns its `lastPushedContent` with the exact `ContentState` the system accepted. Subsequent suppress checks in `updateCurrentActivity` therefore skip pushes that would be no-ops against the rendered surface **unless** the candidate language still differs from owned content language.
- Terminal states reported by ActivityKit cause immediate local cleanup of `currentActivity` and cancellation of the observer. This provides self-healing lifecycle independent of our explicit termination handlers.
- Observation is strictly additive and non-forcing. All existing push call sites, suppress policy (owned language gate), privacy gates, and test short-circuits remain primary. The net effect is stronger reactivity and fewer wasted `update(using:)` crossings of the ActivityKit boundary.

See `RadioLiveActivityManager.swift` (``beginObservingActivityEvents(_:)``, ``activityObservationTask``, class header), `WidgetSurface/WidgetEventObserver.swift`, and the cross-references below. The Tier 2 Live Activity events item (plus the parallel PlayerEvent consumer in `WidgetRefreshManager`) is complete; the common observation pattern is now in one internal helper for future consumers.

### Cross-Process Home Live Chrome (Privacy-Gated Projection)

**Problem:** OI-1 correctly made visual/playback chrome **memory-only** for the session (`inMemorySessionWidgetSnapshot`). The incomplete half of that contract was live **cross-process paint**: home/Control Providers run in the widget extension and **cannot** read main-app session RAM. ``WidgetRefreshManager.performRefresh`` only calls `WidgetCenter.reloadTimelines` — it does **not** pass visual/language into WidgetKit. Main-process “refresh executed … visualState: .playing” is a **scheduler label**, not Provider paint proof. Extension paint comes from App Group + process-local session, re-read after each reload wake.

**Solution:** Privacy-gated App Group key ``homeWidgetLiveChrome`` (JSON ``HomeWidgetLiveChrome``: visual + language + hasError + stamp metadata). Same privacy class as ``homeWidgetStreamMetadata`` (write only while ``hasActiveWidgets`` or widget-process bypass; clear on gate close, privacy clear, factory residual, terminate).

| Layer | Role |
|-------|------|
| **Session RAM** (`loadPersistedWidgetState`) | Process-local SSOT after extension optimistic intent or main-app in-process host |
| **Live chrome mirror** (`loadHomeWidgetLiveChromeMirror`) | Extension-readable projection when main-only transitions left no extension session |
| **Factory** | ``.prePlay`` + ``preferredWidgetLanguage()`` + `hasError == false` when both absent |
| **`reloadTimelines`** | Wake signal only — payload is the mirror / session, not the reload call itself |

**Provider read order** (``WidgetProviderSnapshotResolver/resolveFromSnapshot``):

```text
// Visual / language / hasError — pure resolveHomeWidgetChromeFields
// agreement → session; disagreement → greater updatedAt (tie → session); neither → factory
session + homeWidgetLiveChrome → preferredWidgetLanguage() when language empty

// Program metadata (unchanged; separate key)
session.streamMetadata → homeWidgetStreamMetadata → nil
```

When chrome fields agree, session wins (same-process optimistic continuity). When they disagree, the **fresher** wall-clock stamp wins so main-app settle on ``homeWidgetLiveChrome`` can heal a stale extension-session switch-hold ``.prePlay`` without inventing mid-hold ``.playing`` when the mirror still holds Connecting. Main-app settle after drain must stamp the mirror so extension cold wakes and warm extension processes both converge.

**Writers (mechanism names):**

| Path | Stamps live chrome? |
|------|---------------------|
| ``savePersistedWidgetState`` / ``persistWidgetSnapshot`` (gate open) | Yes — ``stampHomeWidgetLiveChromeFromSession`` (identity skip) |
| Sticky early pause, ``setPlaying``, switch hold, paused switch, ``performActualSave`` | Yes (project honesty; soft-resume holds prior ``.userPaused``, no intermediate Connecting) |
| Extension optimistic toggle / switch | Yes (widget-process bypass; same pure planners) |
| ``restampHomeWidgetLiveChromeAfterPrivacyGateOpenIfNeeded`` | Once on gate false→true |
| ICY / ``persistStreamMetadataForWidgets`` | **No** (metadata only) |
| LA ContentState push | **No** (different gate class; not home privacy) |
| ``bumpWidgetLivenessTimestamp`` alone | **No** (liveness ≠ chrome) |

**Must never:** invent ``.playing`` when the mirror holds ``.prePlay`` (switch hold); treat live chrome as interactive-app proof; read LA durable mirrors or retired on-disk visual keys for home chrome; restore play chrome across cold launch (OI-1).

**Canonical mechanism SSOT:** [`docs/Home-Live-Chrome-App-Group-Mirror-Design.md`](Home-Live-Chrome-App-Group-Mirror-Design.md) (§5 writers, §6 Provider order, §6.3 passive/termination, §7 privacy clear). App Group table row in `SharedPlayerManager.swift`.

### Invariants (Must Hold After Any Edit)

- **PersistedWidgetState is never bypassed** for in-process session display or liveness derivation. Providers resolve via ``WidgetProviderSnapshotResolver`` (``resolveHomeWidgetChromeFields`` freshness for visual/language/hasError; session → program-metadata mirror for titles).
- Live Activity visual state can be (and is) derived from in-memory SPM values without requiring a `UserDefaults` write in the common path.
- An `Activity.update` is sent only when `(visualState, streamMetadata)` differs from the last pushed value.
- Termination cleanup (`handleAppWillTerminate` with waited system end, `forceStaleLivenessTimestampForTermination` including ``clearHomeWidgetLiveChromeMirror()``, cold-launch residual reaping in `observeExistingActivities`) must remain correct: no interactive LA after process death on delivered paths; no resurrected home play chrome (OI-1); residuals reaped on relaunch.
- Widget observable behavior (timeline entries, "tap_to_open" after quit, program title in snapshots) remains privacy-gated; live chrome is session-scoped only.

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

## Main-App Chrome Authority (In-Process, Not WidgetKit)

Home widgets and Live Activities derive chrome from snapshots / ContentState. The **main app** play/pause control and status pill are in-process UI owned by ``RadioPlayerCoordinator``. They share the same SPM visual SSOT and soft-resume intermediate as widgets, but paint through a dual-path discipline that must not invent a second visual authority.

### Dual-path ownership

| Path | Role | Entry |
|------|------|--------|
| **Visual SSOT (primary)** | Durable paint after SPM mutations (`setPlaying`, pause, stop, policy) | ``RadioPlayerCoordinator/beginObservingVisualStateForChrome()`` multi-cast-observes ``makeEventsStreamWithReplay()`` and applies ``updateUI(for:)`` on ``PlayerEvent/visualStateDidChange`` — **no** second engine status emission required |
| **Status adapter (demoted)** | Error / unavailable / SSL / no-internet side effects + optional **one-frame race lead** when the engine reports audible before the actor visual is visible | ``handleStatusChange(_:reasonKey:)`` → pure ``RadioPlayerChromeVisualResolver`` → ``updateUI`` only when ``shouldApplyStatusPathChromePaint`` allows |

Both paths share ``updateUI(for:)`` dedupe (`lastAppliedVisualState`). Observation is **non-forcing**: it never mutates SPM, never calls `play()`/`stop()`, and never bypasses privacy write suppression. ``PlayerEventSubscriber`` (``RadioPlayerView``) remains UI-only counters — not a second paint owner.

### Soft-resume hold contract

Same-stream soft-resume (`canSoftResumeSameStream`) intentionally **skips** stamping Connecting (``.prePlay``) and retains residual sticky visual until engine ``setPlaying()``:

| Phase | SPM visual | Intent | Main chrome |
|-------|------------|--------|-------------|
| Sticky pause | `.userPaused` | sticky pause | Grey pause |
| Explicit play, soft-resume eligible | residual `.userPaused` (held) | active play | May briefly remain grey (honest intermediate) |
| Engine rate kick + ``setPlaying()`` | `.playing` | active play | **Must** settle playing (green / pause control) via SSOT observation |
| Status race before actor hop | residual hold | active | Pure policy may promote one frame when audible report / engine is audible |

**Sticky pause freeze is intent-gated:** late `status_playing` cannot resurrect green while intent still wants pause. Residual `.userPaused` **visual** alone under active play intent is soft-resume hold promote, not sticky freeze.

**Must not:** Invent `.playing` during silent attach or stream-switch hold; reintroduce Connecting stamp on soft-resume “to fix grey”; treat status as long-term visual SSOT.

### Pure policy (status-path mapping)

``RadioPlayerChromeVisualResolver`` is the sole pure table for status-path chrome proposals (privacy clear, sticky vs soft-resume promote, Connecting race, switch hold, security/thermal). Full table and supersession gate live on the type in `RadioPlayerCoordinator+StatusDistribution.swift`.

### Relationship to other surfaces

| Surface | Soft-resume / audible-start paint |
|---------|-----------------------------------|
| Home widget | Connecting skip + event-path coalesce (this doc, termination section) |
| Main app | Primary: ``visualStateDidChange`` → ``updateUI``; status race lead only (this section) |
| Live Activity | ``setPlaying`` → settled language acceptance (soft-ensure re-arm + delayed post-settled ensure) then settled playing acceptance + soft ensure; presentable-window heal via foreground owned-surface ensure; **not** main-app status resolver — see [`docs/Live-Activity-Stacking-and-Media-Surfaces.md`](Live-Activity-Stacking-and-Media-Surfaces.md) |

**SeeAlso:** ``RadioPlayerCoordinator/beginObservingVisualStateForChrome()``, ``RadioPlayerCoordinator/handleStatusChange(_:reasonKey:)``, ``RadioPlayerChromeVisualResolver``, ``SharedPlayerManager/setPlaying()``, ``SharedPlayerManager/makeEventsStreamWithReplay()``, [`docs/Event-Driven-Refactor-Roadmap.md`](Event-Driven-Refactor-Roadmap.md) (main-app chrome consumer), [`docs/Live-Activity-Stacking-and-Media-Surfaces.md`](Live-Activity-Stacking-and-Media-Surfaces.md), `Lutheran RadioTests/RadioPlayerChromeVisualResolverTests.swift`.

---

## Media Surface Coordination & Lock Screen Stacking

System Now Playing, Live Activities, and widgets are three independent iOS surfaces with intentional coexistence. When both Now Playing and a Live Activity are active, iOS stacks both cards on the Lock Screen — expected platform behavior, not a defect.

- **Formatter parity:** `StreamProgramMetadata.nowPlayingDisplayStrings(...)` (`WidgetSurface/StreamProgramMetadata.swift`) is shared with ``updateNowPlayingInfo()`` and widget/LA title resolution. ICY ``from(rawICYMetadata:)`` recognizes spaced ASCII hyphen-minus, en dash (U+2013), and em dash (U+2014) speaker/title separators so speaker attribution reaches Now Playing, widgets, and Live Activities from the same parse.
- **Coordinated refresh:** ``SharedPlayerManager/refreshAllMediaSurfaces(liveActivity:widgetRefresh:widgetRefreshImmediate:)`` (main app) aligns Now Playing + Live Activity after visual transitions; widget reloads remain on the Tier 2 ``PlayerEvent`` observer unless explicitly requested.
- **LA start policy:** First `.playing` via ``setPlaying()`` (``.startOrUpdate``); background catch-up via ``RadioLiveActivityManager/handleAppWillEnterBackground()``; termination ends LA immediately.

Full stacking matrix, language/playing ensure, deferred recreation, presentable-window heal residual, push-cost analysis, and QA scenarios: [`docs/Live-Activity-Stacking-and-Media-Surfaces.md`](Live-Activity-Stacking-and-Media-Surfaces.md).

## Cross-References

### `WidgetSurface/` (presentation-only embedded framework)

- `PlayerVisualState.swift` — `PlayerVisualState` policy cases + `isActivelyPlaying` / resurrection helpers.
- `PlayerPresentation.swift` — `PlayerStatusPresentation`, `PlayerControlPresentation`, `PlayerVisualChromePalette`, `makeStatusPresentation()` / `makeControlPresentation()`.
- `PlaybackIntent.swift` — `PlaybackIntent`, `StopReason`, `PlaybackAttachContext`.
- `PlayerEvent.swift` — `PlayerEvent`, `PlayerCurrentState`.
- `WidgetNowPlayingDisplay.swift` — `WidgetMetadataEmphasis`, `WidgetNowPlayingDisplayModel`, `widgetNowPlayingDisplayModel(...)`.
- `WidgetTimelineEntryFactory.swift` — `WidgetProviderSnapshotFields`, `WidgetProviderPresentationSlices`, home/control entry blueprints.
- `WidgetLivenessPresentation.swift` — passive `tap_to_open` vs interactive chrome policy.
- `StreamProgramMetadata.swift` — parsed stream metadata + `nowPlayingDisplayStrings(...)` SSOT.
- `WidgetEventObserver.swift` — shared `contentUpdates` / `PlayerEvent` observation helper.
- `WidgetIntentCoordinators.swift` — toggle/stream-switch **plans** for App Intents (execution in `WidgetIntentExecution`).

### Cross-target + extension shells

- `WidgetSurface/WidgetLanguageDisplay.swift` — pure ``displayFlag(for:)``, ``displayLanguageName(for:preferredStreamLanguage:)``.
- `WidgetSurface/WidgetProviderPresentationAssembly.swift` — pure Provider presentation slice assembly.
- Membership-exception `WidgetDisplayModels.swift` — ``WidgetProviderSnapshotResolver`` (``resolveHomeWidgetChromeFields`` freshness for visual/language/hasError; program metadata peer; actor hygiene; stream-catalog labels), catalog-aware ``displayLanguageName(for:)`` wrapper, ``WidgetIntentExecution``; calls `SharedPlayerManager` / `WidgetRefreshManager` for hygiene and optimistic intent side effects.
- `WidgetSurface/HomeWidgetLiveChrome.swift` — pure ``HomeWidgetLiveChrome`` payload + identity-skip helper (presentation-only).
- `LutheranRadioWidget.swift` — `SimpleEntry`, `Provider`, family views, `WidgetMetadataRegion` (thin delegates to coordinators + factory).
- `LutheranRadioWidgetLiveActivity.swift` — `LutheranRadioLiveActivityWidget`, `LockScreenLiveActivityView`, Dynamic Island regions, intents.
- `LutheranRadioWidgetControl.swift` — Control widget `Value` + toggle (same derivation path as home widgets).
- `SharedPlayerManager.swift` (+ Persistence / AppGroup extensions) — `PersistedWidgetState`, App Group SSOT table (``homeWidgetLiveChrome``, ``homeWidgetStreamMetadata``), `isMainAppProcessRecentlyActive`, `forceStaleLivenessTimestampForTermination`, `bumpWidgetLivenessTimestamp`, live-chrome stamp/clear helpers.
- `RadioLiveActivityManager.swift`, `WidgetRefreshManager.swift`, `AppDelegate.swift`, `SceneDelegate.swift`.
- `RadioPlayerCoordinator+StatusDistribution.swift` — main-app chrome dual path: ``beginObservingVisualStateForChrome()`` (primary SSOT paint), ``handleStatusChange`` (demoted adapter), pure ``RadioPlayerChromeVisualResolver`` (soft-resume hold promote, sticky pause, Connecting race, supersession gate).
- `CODING_AGENT.md` — Documentation & Comment Standards, Single Source of Truth Principles, cross-target shared files.
- [`docs/Home-Live-Chrome-App-Group-Mirror-Design.md`](Home-Live-Chrome-App-Group-Mirror-Design.md) — mechanism SSOT for privacy-gated home live chrome (writers, Provider order, privacy clear, success criteria).
- [`docs/Widget-Functionality-Roadmap.md`](Widget-Functionality-Roadmap.md) — widget backlog, test coverage, `WidgetSurface` coordinator status, freshness stack.
- [`docs/Event-Driven-Refactor-Roadmap.md`](Event-Driven-Refactor-Roadmap.md) — non-forcing `PlayerEvent` consumers including main-app chrome observation; OI-1 + live projection note.
- [`docs/Live-Activity-Stacking-and-Media-Surfaces.md`](Live-Activity-Stacking-and-Media-Surfaces.md) — Connecting-until-audible, soft-resume publish, LA settled acceptance (orthogonal to main chrome status adapter).

All user-visible strings use `String(localized: "...", table: "Localizable")`.

## See Also

- `README.md` (Single Sources of Truth section — event-driven consumers + presentation surfaces + live chrome pointer)
- [`docs/Home-Live-Chrome-App-Group-Mirror-Design.md`](Home-Live-Chrome-App-Group-Mirror-Design.md) (privacy-gated ``homeWidgetLiveChrome`` mechanism SSOT)
- [`docs/Widget-Functionality-Roadmap.md`](Widget-Functionality-Roadmap.md)
- [`docs/Event-Driven-Refactor-Roadmap.md`](Event-Driven-Refactor-Roadmap.md) (main-app chrome consumer; multi-cast replay; OI-1)
- [`docs/Live-Activity-Stacking-and-Media-Surfaces.md`](Live-Activity-Stacking-and-Media-Surfaces.md) (Connecting vs audible start; soft-resume / setPlaying surfaces)
- ``RadioPlayerCoordinator/beginObservingVisualStateForChrome()``, ``RadioPlayerChromeVisualResolver``
- ``WidgetProviderSnapshotResolver/resolveFromSnapshot()``, ``SharedPlayerManager/stampHomeWidgetLiveChromeFromSession(visualState:language:hasError:reason:)``
- `<doc:Architecture>` (in the Core DocC catalog)
