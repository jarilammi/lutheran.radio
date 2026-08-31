# Cold-launch streamplay regression checklist

Regression guard for Lutheran Radio playback startup, resume, stream switching, and widget behavior.

**Purpose:** Standalone checklist for LLM sessions and refactors. It captures the regression surface from shipped cold-launch/streamplay work so `docs/cold-launch-streamplay-improvements.md` can be retired without losing verification coverage.

**Canonical agent rules:** [`CODING_AGENT.md`](../CODING_AGENT.md) — read first.

**Last updated:** 2026-07-30

---

## LLM session prompt (copy when verifying or refactoring)

```
Read CODING_AGENT.md and docs/cold-launch-streamplay-regression-checklist.md.

Scope: [describe your change — files, behavior].

Walk every numbered check in sections that apply. Run xcodebuild clean build + test
(sequential, iPhone 17 / iOS 26.5).

Confirm happy-path log markers (Section 12) still appear. Flag any regression by
mechanism name (e.g. recreateInFlight, attachedItemLanguageCode), not backlog IDs.

End with security impact, build status, localization needed.
```

---

## How to use

1. Read `CODING_AGENT.md`.
2. Run build and test gates (Section 2).
3. Walk numbered checks in every section your change might affect.
4. Re-capture console logs when behavior is uncertain (Section 12).
5. Name failures by mechanism — not internal task IDs.

**Key files**

| File | Role |
|------|------|
| `Lutheran Radio/DirectStreamingPlayer.swift` | AVPlayer, KVO, `recreatePlayerItem`, soft pause, ICY |
| `Lutheran Radio/SharedPlayerManager.swift` | `play()`, `stop()`, intent, widget persistence |
| `Lutheran Radio/SharedPlayerManager+SleepTimer.swift` | Sleep timer + MainActor notifications |
| `Lutheran Radio/ViewController.swift` | Stream switch, tuning, UI, widget handlers |
| `Lutheran Radio/WidgetRefreshManager.swift` | Debounced widget timeline reloads |
| `LutheranRadioWidget/LutheranRadioWidget.swift` | `SwitchStreamIntent`, `WidgetToggleRadioIntent`, timeline providers |
| `Core/Actors/SecurityModelValidator.swift` | DNS TXT validation (only place) |
| `Core/Security/CertificateValidator.swift` | Runtime cert digest pinning |
| `Core/Configuration/SecurityConfiguration.swift` | Security policy constants |

**Observer layout (recreate / teardown)**

1. `setupPlaybackObservers()` — `timeControlStatus` KVO on `AVPlayer`; early `.paused` on fresh ICY item schedules debounced recreate (150 ms) via `attemptEarlyWindowTransientRecovery`; skipped while `isPlaybackTeardownActive`.
2. `recreatePlayerItem()` — single-flight via `recreateInFlight` on MainActor; always rebuilds via `makeSecuredPlayerItem` (resource loader + DNSSEC/cert path); rebinds `setupPlaybackObservers` + `addObservers`; bails during teardown; discards when `playbackAttachGeneration` advanced; restarts loading-grace clock on success.
3. `addObservers()` — item `status` / buffer KVO; buffer-empty with `AVFoundationErrorDomain` and early-window stalls call secured recreate under intent + budget + loading-grace guards (grace + debounce for pre-stable stalls; longer post-stable stall delay).
4. `attemptEarlyWindowTransientRecovery` — single gate for pre-stable-play silent recovery (budget increments per admission, intent, teardown). Stall-class callers also use `shouldAttemptEarlyAttachStallRecovery`.
5. `stop()` / `performActualStop` — `activatePlaybackTeardownGuardFromStop()` runs synchronously on main thread before async cleanup; item observers invalidated and `playerItem = nil`; guard cleared when new secured item attaches.

---

## 1. Security

1. **DNS TXT validation** — `SecurityModelValidator` queries ordered `securityModelDomains` (`securitymodels.siikkari.net` → `securitymodels.lutheranradio.eu` → `securitymodels.lutheranradio.sk`); playback blocked on permanent failure. One `validateSecurityModel() started` per session. No duplicate validation outside `Core/Actors/`.
2. **Certificate pinning** — Full DER SHA-256 digest pinning in `CertificateValidator` against `pinnedFingerprintDigests` (sole live `*.siikkari.net` leaf; retired pre-cutover digests are not accepted); SPKI pinning in `Info.plist` for apex `siikkari.net`. Runtime never compares colon-hex strings. Streaming hosts use sole media apex `preferredStreamingDomainSuffixes` (`siikkari.net`).
3. **Time skew** — Device vs server skew > 5 minutes denies transition-window leniency.
4. **Security model** — `expectedSecurityModel` is `"dallas"` in `SecurityConfiguration.swift`; stream URLs include the security model query parameter.
5. **MIE/EMTE** — Hardened runtime entitlements present; minimum deployment target iOS 26.2+.
6. **Core isolation** — No security logic duplicated in app or widget; cert/DNS/policy flow through `Core/` only.

---

## 2. Build, test, and toolchain

1. **Clean build** — `xcodebuild -scheme "Lutheran Radio" -sdk iphonesimulator26.5 -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17' clean build` succeeds.
2. **Clean test** — Same destination with `clean test` succeeds. Run build then test sequentially.
3. **Swift 6 strictness** — All targets: `SWIFT_VERSION = 6`, `SWIFT_STRICT_CONCURRENCY = complete`, `SWIFT_APPROACHABLE_CONCURRENCY = NO`, `SWIFT_STRICT_MEMORY_SAFETY = YES`.
4. **Localization** — User-visible strings use `String(localized:)` / `NSLocalizedString`, table `"Localizable"`; all 37 languages if keys added.
5. **Mechanical-refactor exception** — Warning-only work may use `CODE_SIGNING_ALLOWED=NO` build + mandatory full test per `CODING_AGENT.md`; behavior-touching PRs require full signed build.

---

## 3. Architecture (single sources of truth)

1. **Server selection** — `urlWithOptimalServer(for:)` in `DirectStreamingPlayer`; no ad-hoc host selection.
2. **Playback intent** — `currentPlaybackIntent` / `PlaybackIntent` is authoritative for “user wants audio.” Includes `.cleared` (from privacy clear) as a sticky blocker (isStickyPauseOrLock) alongside `.userPaused` / `.securityLocked`. Do not conflate with grey `.userPaused` visual after stream failure.
3. **Visual state** — `currentVisualState` / `PlayerVisualState` drives UI only; switch auto-resume gates on `playbackIntent.isActivePlaybackIntent`.
4. **Widget snapshot** — `PersistedWidgetState` via `loadPersistedWidgetState` / `savePersistedWidgetState` only.
5. **Cold-launch model** — `setSelectedStreamModelOnly` without `AVPlayerItem`; secured attach in `attachAndPlay` → `prepareSecuredPlayerItem`.
6. **Widget pause/play** — Extension signals Darwin; main app uses `SharedPlayerManager.stop()` / `play()` — no duplicated player logic in widget.
7. **Widget language switch** — Extension: `SwitchStreamIntent` → `signalWidgetSwitchAction` (App Group + Darwin only; never main-app `DirectStreamingPlayer.switchToStream` in extension). Main app: `handleWidgetSwitchToLanguage` mirrors `completeStreamSwitch`: model-only → single `stop(.streamSwitch)` → `play()`.

---

## 4. Cold launch and first play

1. **Model before item** — `Stream model updated (no player item)` before secured `AVPlayerItem` attach.
2. **Single secured item** — One item per cold launch; reuse via `prepareSecuredPlayerItem` / `startPlayback`.
3. **Playing visual timing** — `.playing` is applied via deferred ``setPlaying()`` after soft-resume success or engine ready-to-play (not an early pre-`setStreamAndPlay` optimistic paint).
4. **Play-path label** — DEBUG: `cold-launch first play, proceeding` (not resume/switch mislabels). First automatic play is gated by factory reset + sticky intent + prePlay one-shot only (no wall-clock “resurrection relaxed” window).
5. **Startup safety net** — At most once on cold-launch first attach (`initialPlaybackRetryCount == 0`); not on resume or soft-pause resume.
6. **Tuning coordination** — `Tuning sound finished playing, success: true` then `Tuning sound wait completed` before attach. Factory-reset Now Playing phase 2 may still be enqueueing deactivate when presentable cold launch starts; first special-tuning clip / ``play()`` ``configureAudioSessionAsync()`` waits on ``audioSessionMutationTail``. Overlapping `setCategory` with an in-flight SessionCore deactivate returns OSStatus -50. SessionCore deactivate of a never-configured session is skipped (``shouldSkipSessionCoreDeactivate``) so the first presentable `setCategory` is not poisoned after a completed factory deactivate. That skip is instant; first presentable configure still settles SessionCore before `setCategory` (``shouldSettleSessionCoreBeforeFirstPlaybackCategory``). Engine construction does not activate the session.
7. **DNS on launch** — Security model validation completes; failure blocks playback.
8. **ICY arrival** — `LIVE ICY [ensured after re-attach]:` for launched language.
9. **Background image** — One `Processing image for {lang}` per cold launch; duplicate cache-key races coalesce.
10. **Post-clear cold launch (first play after privacy clear)** — After `clearAllLocalState`, next launch lands on `.prePlay` visual + non-sticky intent (no leaked `.userPaused`); early `status_connecting` does not produce grey paused or yellow flash; the post-tuning guard passes with "post-clear cold launch — allowing..." label; identifying writes (snapshot, lastUpdateTime, etc.) occur only after the guard as part of the successful post-clear play (not in pre-guard setup). In-session privacy clear uses ``resetStateToClearedForPrivacy`` (`.cleared` visual + sticky `.cleared` intent); the following cold launch is factory `.prePlay`. The privacy-clear unit test asserts cleared visual + blocker intent.
    The language reseed (selector needle + initialStream for the post-clear auto-play) now uses the centralized `DirectStreamingPlayer.bestInitialLanguageCode()` (walks `Locale.preferredLanguages` for a supported stream) + `indexForLanguageCode` / `streamForLanguageCode` helpers. This replaces the previous duplicated fragile `Locale.current.language.languageCode ?? "en"` paths (which often produced English even on fi/sv/etc. devices). Post-clear reseed in `resetLanguageSelectorToInitialLocale` and the VC/coordinator initial calc now respect the user's actual preferences while preserving the no-snapshot privacy guarantee and the "writes only after successful post-clear play" rule. `preferredWidgetLanguage` now uses `bestInitialLanguageCode` for its no-snapshot fallback when `hasActiveWidgets` is true (widget configured, writes allowed); it still hard-defaults to "en" (with write suppression) when the flag is false (no widgets or post-clear forced-false). This prevents "en" poisoning of the snapshot for normal widget users while keeping the privacy no-signal property for cleared/high-risk cases.

---

## 5. Pause, resume, and Icecast teardown

1. **Explicit pause intent** — User/widget/remote pause sets `playbackIntent = .userPaused` and sticky `.userPaused` visual.
2. **Resume path label** — DEBUG: `resume play, proceeding`; zero `first cold-launch play call` on resume.
3. **User pause tears down Icecast** — ``stop()`` awaits hard `stopAndWait` (resource loaders cancelled, item niled, `isSoftPaused == false`) then ``deactivateAudioSessionAsync()``. A paused keep-alive `URLSession` must not keep receiving the live body. Play after pause is full `attachAndPlay` (Connecting chrome). Same-stream resume (``PlaybackAttachContext/resume``) may reuse the last selected cluster inside ``sameStreamWarmServerReuseInterval`` without a new ping pair; language switch still pings after the 10 s throttle.
4. **No buffer auto-resume** — After sticky `.userPaused`: zero `timeControlStatus → 2 | rate: 1.0`; no audible restart.
5. **Buffer observers gated** — `isPlaybackLikelyToKeepUp` / `isPlaybackBufferFull` call `play()` only when `canProceedWithPlayback()` is true.
6. **Playing KVO enforcement** — `.playing` `timeControlStatus` while intent blocks → `pause()` + `rate = 0`.
7. **Hard-teardown guard** — User-action stop activates the playback teardown guard synchronously (same as stream-switch / interruption).
8. **In-flight discard only** — ``enforceSilenceAfterDiscardedAttach`` may still rate-pause a discarded attach; it is not the unattended user-pause path.
9. **Stash cleared on language change** — `nowPlayingStreamMetadata` cleared on language switch.
10. **Pause → switch → play** — Paused on A, model B: no retained item; switch updates model; Play reattaches B.
11. **Attached item language** — `attachedItemLanguageCode` matches secured item; mismatch → clean reattach.

---

## 6. Stream switch (in-app and widget)

1. **Chrome before teardown** — Active-intent switch establishes `resetToPrePlayForNewStream(connectingLanguageCode:)` (Connecting / `.prePlay` hold, ICY stash cleared, **destination** language on LA ContentState / durable language mirror, media surfaces refreshed) **before** silent `.streamSwitch` stop. Live Activity must not advertise `.playing` mid teardown and must not show prior-language chrome for one content push while already Connecting.
2. **Switch order** — Connecting hold + destination language → `Stream model updated (no player item)` + silent stop → session language snapshot → tuning (in-app) → single `play()`. A switch that lands while the previous attach is still Connecting must print `stream-switch play, proceeding` (and `resetToPrePlayForNewStream — clearing superseded start pipeline` when the latch was set) — **not** `start pipeline already active, skipping duplicate entry`.
3. **Single streamSwitch stop** — One `FORCE STOPPING … reason: streamSwitch` per switch; zero `userAction` stop during widget switch.
4. **One observer attach** — One `setupPlaybackObservers` per final attach; early-window recreates are budget-capped (see §8).
5. **No userPaused lock workaround** — Zero `[Widget] Cleared userPaused lock` during widget switch.
6. **PrePlay hold dedup** — One `resetToPrePlayForNewStream` on tap / entry; completeStreamSwitch skips a second reset when hold active.
7. **Play-path label** — DEBUG: `stream-switch play, proceeding`.
8. **Startup safety net** — Shares the early-window recreate budget; cancelled on teardown; no multi-recreate storm with stall recovery.
9. **Teardown during switch** — Stale post-stop `timeControlStatus → 0` does not trigger recreate or `status_stopped` flash; in-flight recreate aborts when `playbackAttachGeneration` advances.
10. **ICY per language** — Fresh `LIVE ICY` for each switched language; prior-language program title cleared at prePlay hold.
11. **Widget playing-path switch** — `▶ [Widget Switch] Starting new stream using SharedPlayerManager.play()`; no extra play tap.
12. **Explicit-pause switch block** — Widget pause then switch: `[Widget Switch] Blocked — userPaused, no auto-resume`.
13. **Stream-failure switch** — After decode/network failure (not user pause): `markPlaybackStoppedByStreamFailure()` with intent unchanged (`.shouldBePlaying`); widget switch auto-resumes without extra play tap. See Section 12.3.
14. **Widget switch delivery** — `SwitchStreamIntent` must reach the main app via App Group + Darwin before §6.10 handler lines: `Found pending action: switch` with non-nil `Pending language: {code}`; then `Executing widget switch action to language:`. If pause/play Darwin works but switch produces zero pending-action logs, treat as extension routing regression (`isRunningInWidget`, `signalWidgetSwitchAction`), not ICY or stream failure.
15. **Home language vs LA language under lock** — After widget playing-path switch while lock/inactive: home refresh / snapshot language matches destination; soft language ensure may log `language ensure quiet pending` / post-settled retries with `destination≠owned` without ending the activity (`recreation deferred` while request ineligible is correct). Do **not** require owned `contentState` language to match destination for the entire inactive stretch.
16. **Presentable-window LA language heal** — After a lock-stretch language stall (destination audio + home correct; system-held language prior), unlock into main app **without** changing language: owned LA language (flag/name) must converge to destination (often with playing visual) on the same interactive activity; no `Failed to start Live Activity: visibility` solely from language lag. Re-lock should show destination chrome. Mechanism: ``ensureInteractiveLiveActivityIfNeeded`` → ``ensureAuthoritativeContentOnForegroundIfNeeded`` (soft ensure; eligible recreation only if soft still fails).

---

## 7. Widget persistence and refresh

1. **Snapshot skip dominance** — `performActualSave: snapshot unchanged — skipping persist`; zero paired `State saved` on same no-op.
2. **Genuine mutations only** — `State saved` on real changes; single-digit count per extended session, not per KVO tick.
3. **No TC-tick persistence** — `timeControlStatus` KVO does not save every tick; ICY bursts: `suppress pipeline` without trailing `State saved`.
4. **Sticky-pause urgent refresh** — First `.playing` → `.userPaused` gets one urgent reload; subsequent pause KVO hits snapshot skip.
5. **Widget pause metadata** — `State saved: playing=false` + `Widget refresh executed — visualState: .userPaused`; program lines hidden while paused.
6. **PrePlay/playing coalesce** — Fast `.prePlay` then `.playing` within ~300 ms → ≤1 `Widget refresh executed` per switch phase.
7. **Language-change urgency** — Language changes still trigger immediate refresh.
8. **Widget liveness** — `lastUpdateTime` fresh during background playback; widget stays interactive, not offline “tap to open”.
9. **Transient connect skip** — `transient status_connecting — skipping widget save`.
10. **Darwin self-echo** — `Ignoring self-posted Darwin pause notification echo`; genuine widget actions still execute once.

---

## 8. Player item, ICY, and KVO observers

1. **Single-flight recreate** — `recreatePlayerItem()` coalesces concurrent callers.
2. **Secured recreate** — Every recreate uses `makeSecuredPlayerItem` (resource loader delegate); never a bare `AVURLAsset` without the streaming security path.
3. **Early-window recovery gate** — `attemptEarlyWindowTransientRecovery` is the single pre-stable-play gate (budget + intent + teardown) for timeControl, buffer-empty, item `.failed`, resource-loader, and loading-error paths. **Each admission increments** `initialPlaybackRetryCount` up to `maxInitialRetries` (hard cap shared with the startup safety net).
4. **Loading grace** — Progressive ICY items often stay at `status == .unknown` with no error for several seconds. Stall-class recovery uses `shouldAttemptEarlyAttachStallRecovery` + `earlyAttachLoadingGraceSeconds` (~4 s from attach / recreate) so normal first-byte loading is not treated as an immediate recreate. Hard failures (item `.failed`, buffer-empty with `AVFoundationErrorDomain`) bypass grace.
5. **Early-ICY debounce** — 150 ms on early `.paused` KVO; cancelled on `.playing`, stop, counter reset.
6. **Early stall delay** — Pre-stable stall waits remaining loading grace + ~1.5 s debounce (longer under Low Power Mode); post-stable stalls keep the longer debounce.
7. **Generation-aware recreate** — `recreatePlayerItem` captures `playbackAttachGeneration` and aborts if stop / stream-switch advanced it mid-flight.
8. **Teardown guard** — `isPlaybackTeardownActive` at `stop()` start; suppresses recreate and early-ICY until new item attached.
9. **Guard cleared on attach** — `clearPlaybackTeardownGuard()` in `preparePlayerItem`, `createAndStartPlayer`, `startPlayback`, successful recreate; successful recreate restarts the loading-grace clock.
10. **No recreate during switch stop** — Zero `Cannot recreate` and zero duplicate secured-item recreate during switch teardown.
11. **Transient status_stopped** — `transient status_stopped while visualState .playing → suppress pipeline` during ICY bursts.
12. **Item failure handling** — `status_stream_unavailable` / `status_failed` → `markPlaybackStoppedByStreamFailure()`, not `setUserPaused()`; intent stays `.shouldBePlaying` (or `.sleepTimer`) unless user explicitly paused.
13. **Observer invalidation** — Stop invalidates item observers and sets `playerItem = nil`.

---

## 9. UI and visual state

1. **updateUI dedup** — ≤1 `updateUI → applied userPaused` per pause; duplicates log `skipped (already applied …)`.
2. **Distinct transitions** — `prePlay` → `playing` → `userPaused` still update when enum changes.
3. **Stream switch visuals** — Yellow `.prePlay` on tap; after tuning; green `.playing` after attach.
4. **Needle during tuning** — Needle sweeps during tuning clip on playing path.
5. **Background image coalesce** — One pass per cache key; alpha and dimensions unchanged.
6. **Error UI on failure** — Red banner / alert on stream failure; grey pause chrome without sticky pause intent.
7. **Clear local state visual** — Destructive clear action uses `.prePlay` visual (via direct engine stop + reset) + transient confirmation status; never leaves SSOT in `.userPaused`. Post-clear launches and status callbacks never mix `.userPaused` grey with the clear path. "Cleared" confirmation (or equivalent) appears without yellow connecting.

---

## 10. Sleep timer

1. **MainActor notification** — `SleepTimerNotification.postStateChange` is `@MainActor`; cancel/elapse paths `await` it.
2. **No lldb trap on pause** — Pause with active sleep timer: zero `EXC_BREAKPOINT` at notification post.
3. **SSOT stop path** — Sleep-timer cancel routes through `SharedPlayerManager.stop()`.
4. **Preserve across switch** — Active-intent stream switches (`completeStreamSwitch`, `switchToStreamFromWidget`, external/Siri switch helpers) pass `preserveActiveSleepTimer: true` when intent is `.sleepTimer`.
5. **Elapsed engine-complete cleanup** — ``applySleepTimerElapsedPause()`` awaits ``stopAndWait(reason: .interruption)`` then ``deactivateAudioSessionAsync()``. Does not run ``performSessionAndWidgetTeardown``. Grey `.userPaused` + `.sleepTimer` intent; resume via ``setPlaying()``.

---

## 11. Performance and churn (must not regress)

1. Zero duplicate early-ICY/recreate pairs on manual resume.
2. Zero `first cold-launch play call` on resume or stream-switch paths.
3. Zero startup safety-net scheduling on resume or soft-pause resume.
4. Zero `cold-launch:` hyphen-prefix in attach DEBUG strings.
5. Zero adaptive connect-time handshake-budget DEBUG (`SSL Protection`, `SSL Timeout`, `Cancelled pending SSL protection`) — domain removed; connect readiness is AVPlayer item status + resource-loader timeouts; TLS trust is Core pin + ATS SPKI only.
6. Widget reload spam absent on manual pause (snapshot skip dominates).
7. No duplicate `Processing image for {lang}` for same cache key in one phase.

---

## 12. Log capture and verification

Console capture helper (Debug Simulator `print()` only — not UI automation):

```bash
./Scripts/capture-debug-console.sh --short              # cold launch → initial-streamplay-start.txt
./Scripts/capture-debug-console.sh --manual             # you drive the sim → manual-streamplay-session.log
./Scripts/capture-debug-console.sh --analyze [logfile]  # acceptance greps on an existing capture
```

### 12.1 Commands

```bash
xcodebuild -scheme "Lutheran Radio" -sdk iphonesimulator26.5 \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17' clean build

xcodebuild -scheme "Lutheran Radio" -sdk iphonesimulator26.5 \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17' clean test
```

### 12.2 Happy-path log markers (must still appear)

```
[DirectStreamingPlayer] Stream model updated and secured AVPlayerItem prepared for …
[ViewController] Tuning sound finished playing, success: true
[TuningSoundCoordinator] Tuning sound wait completed
[DirectStreamingPlayer] LIVE ICY [ensured after re-attach]: …
[SharedPlayerManager] Rehydrating stream metadata from soft-pause stash
[ViewController] Executing widget switch action to language: …
[ViewController] ▶ [Widget Switch] Starting new stream using SharedPlayerManager.play()
[ViewController] [Widget Switch] Blocked — userPaused, no auto-resume
[DirectStreamingPlayer] Soft-pause resume declined — attached item language (…) != selected stream (…)
[DirectStreamingPlayer] Attached item language mismatch — performing clean stop
[SharedPlayerManager] performActualSave: snapshot unchanged — skipping persist
[ViewController] post-clear cold launch — allowing initial playback and state creation
[RadioPlayerCoordinator] post-clear cold launch — allowing initial playback (intent will be cleared by play())
[SharedPlayerManager] resetStateToClearedForPrivacy — in-memory SSOT reset to .cleared (blue) + .cleared intent (no persist; .cleared blocks recovery until explicit play)
```

### 12.3 Stream-failure switch verification (manual `manual-streamplay-session.log`)

Capture with `./Scripts/capture-debug-console.sh --manual` while driving the Simulator (the script records console only; it does not inject widget actions).

Session: cold launch → play sv → wait for item failed / `status_stream_unavailable` → widget switch de **without** play tap.

| Check | Expected |
|-------|----------|
| Failure intent | `markPlaybackStoppedByStreamFailure()` — intent unchanged (`.shouldBePlaying`); **no** `playbackIntent: shouldBePlaying → userPaused` from failure alone |
| Switch gate | Zero `[Widget Switch] Blocked — userPaused` between failure and de switch |
| Auto-resume | One `▶ [Widget Switch] Starting… play()` for de |
| Recovery | `LIVE ICY` for de without manual widget play tap |
| Regression | Explicit widget pause → switch still blocked (`[Widget Switch] Blocked — userPaused, no auto-resume`) |

### 12.4 Reference logs

| File | Purpose |
|------|---------|
| `initial-streamplay-start.txt` | Cold-launch happy path (`./Scripts/capture-debug-console.sh --short`) |
| `manual-streamplay-session.log` | Widget pause/play churn and switch delivery (`./Scripts/capture-debug-console.sh --manual`) |
| `long-test-txt.log` | Legacy manual captures (still accepted by `--analyze` if present) |

### 12.5 Play-path DEBUG labels

```
SharedPlayerManager.play() – cold-launch first play, proceeding
SharedPlayerManager.play() – resume play, proceeding
SharedPlayerManager.play() – stream-switch play, proceeding
[DirectStreamingPlayer] Resumed from soft pause — skipped item recreation
[ViewController] [completeStreamSwitch] Skipping redundant resetToPrePlayForNewStream — tap already set .prePlay hold
```

---

## 13. Unit tests

1. **`SharedPlayerManagerPlaybackIntentTests`** — Stream failure preserves `.shouldBePlaying`; explicit `stop()` sets `.userPaused`.
2. **All test targets** — Pass under `clean test` with strict concurrency.

---

## 14. Simulator console noise (not regressions)

These messages commonly appear during stream attach on Simulator and recover without user impact. Do not treat as app bugs if playback and ICY follow.

| Message | Likely source | Action |
|---------|---------------|--------|
| `AddInstanceForFactory: No factory registered for id …` | CoreAudio / system | Ignore on Simulator |
| `AudioConverterOOP.cpp … Failed to prepare AudioConverterService: -302` | Simulator audio converter | Ignore unless reproducible on device |
| `HALC_ProxyIOContext … skipping cycle due to overload` | Audio HAL overload | Ignore on Simulator |
| `LoudnessManager.mm … no plist loaded` | Simulator loudness path | Ignore on Simulator |
| `HTTPRequest signalled err=-12939` | AVFoundation stream HTTP teardown | Ignore during item replace; investigate if persistent on device |
| `<<< timebase >>> signalled err=-12753` | AVFoundation timebase reset | Ignore during recreate |
| `<<<< FigStreamPlayer >>>> signalled err=-12860 / -12783` | Internal stream player reset | Ignore during ICY attach/recreate |
| `<<<< ICY PUMP >>>> signalled err=-12640 / -12785` | ICY metadata pump during item swap | Ignore; metadata still arrives |
| `<<HLS-FASB>> signalled err=-15514` | Fragment assembler | Ignore on Simulator |
| `<<<< FIM >>>> signalled err=-16042` | Fig item teardown | Ignore during `stop()` or stream switch |
| `metricevent_subscriber signalled err=-19772` | Media analytics | Ignore |
| `ICSInfo.cpp / AACDecoder.cpp … Error deserializing` | Occasional AAC frame glitch | Ignore if playback recovers |
| `AACDecoder.cpp:52 Error: unmatched audio object type` | HE-AAC/SBR init on Simulator | Ignore if `readyToPlay` + ICY follow |
| `HEAACDecoder.cpp:331 Failed to initialize SBR decoder` | Simulator HE-AAC path | Ignore if playback recovers |
| `HALC_ProxyIOContext::_StartIO(): Start failed … error 35` | Audio HAL race during rapid switch | Ignore on Simulator during switch churn |

**Log format note:** App and widget targets use `[ComponentName]` DEBUG prefixes. `Core/Actors/` and `Core/Security/` retain legacy emoji prefixes (`🔒`, `📜`).

---

## Quick regression matrix (by change area)

| If you changed… | Re-read sections |
|-----------------|------------------|
| `Core/Security/*`, `SecurityModelValidator`, `Info.plist` | 1, 2 |
| `DirectStreamingPlayer` KVO, recreate, soft pause | 5, 8, 11 |
| `SharedPlayerManager` play/stop/intent/save + clear paths | 3, 4 (post-clear), 5, 6, 7 |
| `ViewController` switch, tuning, UI + initial Task defer | 4, 6, 9 |
| `WidgetRefreshManager`, `LutheranRadioWidget`, `SwitchStreamIntent`, `isRunningInWidget` | 6, 7 |
| `SharedPlayerManager+SleepTimer` + clear menu | 10 |
| Background images | 4.10, 9.5, 11.7 |
| Privacy clear / post-clear cold launch (visual + no re-creation of deleted data) | 4 (new), 9 (new), 12.2 (new markers), 13 |
| Localization only | 2.4 |
| Mechanical refactor / rename | 2, 3, 11, 12 |

---

*Update this checklist when new playback or widget behavior ships. `CODING_AGENT.md` remains the canonical security and build gate document.*
