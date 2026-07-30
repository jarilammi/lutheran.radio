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
| First successful `.playing` | Engine audible start → ``setPlaying()`` → ``refreshAllMediaSurfaces(liveActivity: .startOrUpdate)`` | Start if `currentActivity == nil`, else update | User has confirmed live audio (soft-resume rate kick or readyToPlay first-play kick); LA controls are meaningful. Connecting (``.prePlay``) does **not** start LA via optimistic ``play()`` chrome. |
| Background while playing | ``RadioLiveActivityManager/handleAppWillEnterBackground()`` | ``startActivity()`` when `loadSharedState().isPlaying && currentActivity == nil` | Lock-screen / DI controls while audio continues |
| Foreground correction | ``handleAppDidEnterForeground()`` / become-active | ``ensureInteractiveLiveActivityIfNeeded()`` then ``updateCurrentActivity()`` | Catch-up after long background; **pending ensure** restores a **missing** interactive LA after deferred recreation or failed `Activity.request` (visibility) when session still needs chrome; when ownership is already non-nil, ``ensureAuthoritativeContentOnForegroundIfNeeded()`` runs bounded soft language/playing ensure (clears language + playing quiet first) and eligible-only recreation if soft ensure still fails; dual SceneDelegate hooks are debounced via ``shouldInvokeOwnedSurfaceForegroundEnsure`` while still consuming quiet / pending on unlock |
| User pause / stop | ``stop()``, ``setUserPaused()``, etc. | Update only (LA **not** ended) | Paused LA with working play intent is intentional while process lives |
| Active-intent stream / language switch | ``resetToPrePlayForNewStream(connectingLanguageCode:)`` then silent engine `.streamSwitch` stop, then **awaited** session language snapshot + ``refreshAllMediaSurfaces`` | Update only | Connecting (``.prePlay``) **and destination language** before teardown; never leave ContentState at `.playing` mid switch; never publish Connecting with the **prior** language for one content push. ``liveActivityLanguageCodeForContentPush()`` prefers the hold-time destination until ``setPlaying()``. ``saveCurrentState()`` feeds the same destination into ``PersistedLanguageResolution/resolve`` (`connectingLanguageCode`) so the App Group snapshot does not lag on preferred/snapshot/model while LA chrome is already correct. Switch paths **await** ``updateUserDefaultsLanguage`` → ``saveCombinedWidgetState(language:)`` before media refresh / further saves so destination is not the sole fire-and-forget writer racing a lagging re-resolve. ``updateCurrentActivity()`` also clamps `.playing` → `.prePlay` while stream-switch hold or connect pipeline is active (defense-in-depth). |
| Sticky-paused stream / language switch | ``stampStreamSwitchDestinationLanguage`` + **awaited** session language snapshot + ``refreshAllMediaSurfaces`` **before** silent engine `.streamSwitch` stop; **no** auto-resume | Update only | Keep sticky ``.userPaused`` chrome (no Connecting hold). Destination language stamp outranks lagging preferred/snapshot/model in ``PersistedLanguageResolution/resolve`` and feeds ``liveActivityLanguageCodeForContentPush()`` so lock-screen flag advances immediately without inventing `.prePlay` or starting audio. After post-switch language write + refresh, ``clearStreamSwitchDestinationLanguageIfNotHolding()`` drops the stamp. |
| Process termination | ``handleAppWillTerminate()`` | Sweep all system activities → final `.userPaused` (language preserved) → ``end(.immediate)`` with **bounded wait** | No orphaned interactive LA after delivered process exit |
| Force-quit / missed terminate | Next cold launch ``observeExistingActivities()`` | Reap residuals (never re-adopt as live). If ``currentActivity`` already set (start raced ahead of deferred observe), full end is skipped for the owned id and **sibling** system residuals are still reaped | No half-dead `.playing` chrome without a live engine; ownership never leaves a second residual interactive |
| Session teardown (alive) | ``performSessionAndWidgetTeardown`` | ``endActivityAsync`` (awaited) | Privacy clear / factory reset complete before later work |

**Never** start LA from widget extension processes. Activity ownership is main-app only.

**UITest / unit test isolation:** ``startActivity()`` and ``updateCurrentActivity()`` no-op under ``SharedPlayerManager/isRunningInUITestMode`` and DEBUG ``isRunningUnderTest`` so `xcodebuild test` stays fast.

---

## Metadata Push Cost (Negligible in Practice)

### Live Activity

``RadioLiveActivityManager/updateCurrentActivity()`` builds a candidate ``ContentState(visualState:streamMetadata:currentLanguage:)`` and applies ``shouldSuppressLiveActivityContentPush(lastPushed:candidate:ownedContentLanguage:ownedContentVisual:)``. **ActivityKit IPC is skipped only when** in-process ``lastPushedContent`` equals the candidate **and** the owned activity’s `content.state.currentLanguage` **and** `content.state.visualState` do not disagree with the candidate. Owned surface language and visual beat optimistic / aspirational suppress memory so a stream-switch destination cannot be “claimed” while the lock-screen flag still shows the prior stream, and soft-resume cannot leave suppress memory claiming `.playing` while the system-held glyph is still Connecting (``.prePlay``). After a real `Activity.update`, suppress memory is re-seeded from the activity’s observed `content.state` (not an unverified aspirational candidate). ICY title churn and language-only stream switches therefore cost one crossing per actual title/speaker/visual/**language** change that the surface still needs, not per timer tick. Language chrome rides `currentLanguage` from ``SharedPlayerManager/liveActivityLanguageCodeForContentPush()`` (stream attach via ``mainAppLiveActivityLanguageCode()``, or destination language while ``streamSwitchConnectingLanguageCode`` is stamped — Connecting hold **or** sticky-paused stamp without hold); durable ``liveActivityCurrentLanguage`` warms extension optimistic paths without reopening home-widget write suppression.

**Stream-switch honesty:** Coordinators establish ``holdPrePlayVisualUntilPlayback`` via ``resetToPrePlayForNewStream(connectingLanguageCode:)`` with the **destination** language code, clear prior-language ICY metadata, and refresh media surfaces **before** silent engine stop. While the hold or play-start pipeline is active, a candidate visual of `.playing` is forced to `.prePlay` so lock-screen glyphs cannot claim audible playback during attach. Destination language on the hold prevents a one-frame prior-language flag/name while visual is already Connecting and ``selectedStream`` is still the old stream. The same non-empty destination stamp is the top precedence input to ``PersistedLanguageResolution/resolve`` (hold **or** paused path) so ``saveCurrentState()`` writes snapshot `currentLanguage` to the switch target even when preferredWidgetLanguage / snapshot / Direct model still report the prior stream.

**Sticky-paused language switch:** When intent is ``.userPaused``, orchestrators must **not** auto-resume and must **not** force Connecting (``.prePlay``). They call ``stampStreamSwitchDestinationLanguage(_:)`` (destination stamp + durable LA language mirror only), await destination snapshot write + media-surface refresh, then run engine ``switchToStream``, re-stamp language after model prep, and ``clearStreamSwitchDestinationLanguageIfNotHolding()``. Lock-screen flag advances to the destination while the paused glyph stays; play starts the new stream only after an explicit play.

**Intentional English vs hard-default `"en"`:** Preferred `"en"` is ambiguous (privacy hard-default from ``preferredWidgetLanguage()`` vs real English selection). ``PersistedLanguageResolution/resolve`` keeps `"en"` when the engine model is already `"en"` — a lagging non-en snapshot must not reintroduce the prior language. Hard-default pollution is still repaired when the model is a non-empty non-en code (prefer non-en snapshot, else model). A non-empty destination stamp of `"en"` (hold or paused path) outranks lagging non-en preferred/snapshot/model the same way as any other destination code.

**Widget refresh derivation language under privacy write suppression:** ``WidgetRefreshManager`` coalesce / deferred-refresh bookkeeping and DEBUG `lang:` labels resolve language via ``SharedPlayerManager/languageForWidgetRefreshDerivation(fallbackLanguage:)`` (session snapshot → stream attach → durable LA language mirror → main-app locale reseed). They do **not** report ``preferredWidgetLanguage()``'s privacy hard-default `"en"` alone while the engine stream or LA language mirror holds a non-English code. Home-widget App Group snapshot writes remain gated by ``hasActiveLutheranWidgets``; this path does not bypass write suppression.

**Widget refresh identical non-playing coalesce (attach / dual-path quiet path):** Event-path ``refreshUsesImmediateDelivery`` forces `immediate: true` for sticky pause/lock and ``.cleared`` (factory-reset / pause urgency). Connecting ``.prePlay`` is **not** immediate so it participates in the ``.prePlay`` → ``.playing`` coalesce window — same-stream soft-resume schedules a single authoritative ``.playing`` home reload instead of painting Connecting after audio is already live. ``shouldCoalesceIdenticalNonPlayingRefresh`` drops further timeline reloads when ``lastKnownState`` already matches the candidate visual **and** language **and** error flags for connecting chrome (``.prePlay`` / ``.cleared``) or sticky pause/lock. Language changes always force a reload first (and mark the candidate immediate for regress gates). Attach-path Connecting deferral **holds one coalesce deadline** across status storms (does not reset the window per callback). Execute-time memory SSOT authority discards residual sticky after intentional Connecting and premature ``.playing`` while memory still holds Connecting. Active ``.playing`` is rate-limited by adaptive debounce, not identity skip. Dual-path architecture (``playerEvent`` + teardown / lifecycle / extension optimistic) is unchanged — only identical chrome is collapsed.

**Home soft-resume connecting chrome skip:** When ``DirectStreamingPlayer/PlaybackAttachState/canSoftResumeSameStream`` is true, ``setUserIntentToPlay`` / ``clearUserPausedLockIfNeeded`` / play post-security connecting chrome skip stamping ``.prePlay`` and retain sticky visual until engine ``setPlaying()``. Gapless soft-resume is audible before Connecting could honestly apply; home widgets therefore do not flash yellow Connecting on that path. True attach, stream-switch hold, and soft-resume-ineligible recovery still use Connecting until audible start.

**Attach-path sticky Connecting snapshot quiet:** Status KVO and coordinator label paths call ``saveCurrentState()`` many times while attach waits for `readyToPlay`. ``DirectStreamingPlayer/shouldSkipForceWidgetSaveOnStableStatus`` skips force save while visual is sticky Connecting (``.prePlay`` / ``.cleared``) — parity with sticky pause/lock skip — and still forces for permanent-error / unavailability keys. ``SharedPlayerManager/shouldSkipIdenticalStickyConnectingSnapshotWrite`` collapses identical Connecting re-persists when language, error flags, and metadata already match the session snapshot; first transition into Connecting, language changes, error repairs, and transitions to ``.playing`` / ``.userPaused`` still write. ``saveCombinedWidgetState(language:)`` also no-ops when destination language + visual are already stamped with cleared metadata. Privacy write suppression when no home widgets remain unchanged.

**Widget refresh stale debounced discard (intentional):** ``refreshWouldRegressPersistedSnapshot(executing:persisted:isImmediate:)`` discards a delayed/debounced target when the persisted snapshot has already advanced past it (e.g. **non-immediate** ``.prePlay`` vs persisted ``.playing``, or **non-immediate** ``.userPaused`` after soft-resume already wrote ``.playing``). **Immediate** sticky-pause urgency against a lagging ``.playing`` snapshot is **not** discarded (forward stop; early sticky session snapshot also aligns disk before non-carried events). **Immediate** language-change / switch Connecting against lagging ``.playing`` is **not** discarded (destination first paint). Connecting against lagging sticky disk is allowed (forward attach); reverse races use ``refreshWouldRegressMemoryAuthority``. Timeline reload cannot invent snapshot fields; the discard avoids a useless `reloadTimelines` that would re-read the newer snapshot. Not a product failure and not a reason to remove dual-path observation.

**Destination language write ordering:** ``RadioPlayerCoordinator/updateUserDefaultsLanguage(_:)`` is `async` and **awaits** ``saveCombinedWidgetState(language:)`` on the actor before returning. Stream-switch orchestrators (`completeStreamSwitch`, `switchToStreamFromWidget`, external switch) await that hop **before** ``refreshAllMediaSurfaces`` or other work that can call ``saveCurrentState()``. ``saveCurrentState()`` itself resolves language **after** its suspension points so a concurrent destination snapshot write is visible before `performActualSave` — never resolve-then-await-then-write a stale prior code as the last writer.

The attribute-events observer (``contentUpdates`` via ``WidgetEventObserver``) keeps ``lastPushedContent`` aligned with the system-accepted state, strengthening suppression of redundant ``Activity.update`` calls.

**Lock-screen toggle optimistic ContentState:** ``WidgetIntentExecution/performLiveActivityToggle()`` publishes the post-toggle control visual via ``pushOptimisticLiveActivityToggleContent(visualState:)`` (ActivityKit `Activity.update` on interactive activities, preserving ``streamMetadata`` and ``currentLanguage`` through ``ContentState/replacingVisualState(_:)``) and writes the durable App Group toggle visual + language mirrors. On the main app it also calls ``RadioLiveActivityManager/recordOptimisticToggleContent(visualState:)`` so ``lastPushedContent`` matches the optimistic glyph; when sticky lock / soft silence later produces the same visual, ``updateCurrentActivity()`` suppresses as a no-op. A rapid second tap therefore resolves from post-toggle content (preferred over a lagging mirror or actor), not stale pre-tap content.

**Pause honesty while system-held visual is still Connecting:** User pause must not require owned `content.state.visualState` to have been ``.playing`` first. Three coordinated mechanisms:

1. **Early durable + optimistic ContentState on every pause entry:** ``SharedPlayerManager/stop()`` warms ``persistLiveActivityToggleVisualStateMirror(.userPaused)`` at sticky lock (not gated by home widgets) and, on the main app, calls ``pushOptimisticLiveActivityToggleContent(visualState: .userPaused)`` **before** soft silence completes. Home/Control optimistic toggles (``executeOptimisticToggle``) use the same durable mirror + optimistic ContentState path when the plan targets ``.userPaused`` or ``.playing``. Language chrome is preserved via ``ContentState/replacingVisualState(_:)``; engine-complete ``refreshAllMediaSurfaces`` after silence remains the reconcile path (suppress when optimistic already matches).
2. **Owned-visual suppress gate still denies no-op** when system-held visual is ``.prePlay`` and the candidate is ``.userPaused`` — ActivityKit IPC is not skipped solely because in-process ``lastPushedContent`` already advanced. Playing-ensure quiet pending never defers ``.userPaused`` candidates.
3. **Multi-source resolve does not trust stale Connecting alone:** ``WidgetIntentCoordinators/resolveLiveActivityToggleVisualState`` prefers definitive peers (``.playing`` / ``.userPaused`` from durable mirror, actor, or session) over system-held ``.prePlay`` so a lock-stretch Connecting freeze cannot invert first pause into play or invert post-pause resume planning. Intentional Connecting without a definitive peer remains content-authoritative; ``isConnectingPlayback`` still plans pause to cancel attach.

**SeeAlso:** ``PlayerVisualState/isDefinitiveMediaToggleVisual``, ``WidgetIntentExecution/executeOptimisticToggle(plan:language:)``, ``SharedPlayerManager/stop()``, ``RadioLiveActivityManager/shouldDeferRedundantPlayingPushWhileQuiet(candidateVisual:ownedContentVisual:ownedContentLanguage:candidateLanguage:quietPending:isRequestEligible:)``.

**Lock-screen stream-language chip optimistic ContentState:** ``WidgetIntentExecution/executeLiveActivityStreamSwitch(languageCode:)`` (and home-widget switch when a Live Activity is visible) publishes destination language chrome **before** pending-action / Darwin drain via ``pushOptimisticLiveActivityStreamSwitchContent(languageCode:visualState:)``. Content uses ``ContentState/replacingStreamSwitchDestination(language:visualState:clearStreamMetadata:)`` with visual from ``WidgetIntentCoordinators/optimisticLiveActivityVisualForStreamSwitch(from:)`` (``.prePlay`` Connecting when leaving active play; preserved ``.userPaused`` when sticky-paused — never invent `.playing` for a destination stream that is not yet audible). Prior-stream program metadata is cleared so an old title does not ride under the new flag. Durable language + toggle mirrors warm at the same moment; main-app ``RadioLiveActivityManager/recordOptimisticStreamSwitchContent(language:visualState:)`` aligns ``lastPushedContent`` so later stamp / ``updateCurrentActivity()`` can suppress when the actor **and** owned `content.state` language converge to the same destination tuple. Optimistic alignment alone never blocks a push when owned content language still differs (ActivityKit suppress uses owned content language). After the optimistic ActivityKit path, ``ensureAuthoritativeLanguageContentIfNeeded()`` reconciles when destination still diverges from owned / last language. Home-widget App Group snapshot may still preserve `.playing` across the optimistic write; Live Activity ContentState uses Connecting honesty for language chrome.

**Connecting must not stick after audible start:** ``updateCurrentActivity()`` samples visual / hold / connect **after** metadata/language awaits so a concurrent ``setPlaying()`` is not overwritten by a stale Connecting candidate (yellow Connecting chrome + destination language while audio already plays). After ``setPlaying()``’s primary media-surface refresh, settled acceptance then soft ensure run so one ContentState push can co-converge both axes: ``pushSettledLanguageAcceptanceContentIfNeeded()`` then ``pushSettledPlayingAcceptanceContentIfNeeded()`` then ``ensureAuthoritativePlayingContentIfNeeded()`` (soft ensure respects quiet when already engaged). Playing ensure re-pushes when last-pushed **or** owned content visual is still `.prePlay` (Connecting) **or** `.userPaused` (soft-resume after pause) while the actor is authoritative `.playing` without hold/connect. Owned pause or Connecting with optimistic last-pushed playing also schedules reconcile. The ensure path performs up to ``authoritativePlayingContentEnsureMaxAttempts`` soft pushes, re-reading owned `content.state.visualState` after each update, and stops when owned visual reaches `.playing`. Soft-resume rate-kick publish that no-ops because the actor is already `.playing` still runs settled language + playing acceptance (consume-once while ineligible) then soft ensure so a stuck Connecting glyph is reconciled without a second `streamDidStart` or soft-resume thrash. Pure visual freezes prefer these soft retries over end+request recreation. Hold / connecting still block inventing `.playing`.

**Language reconcile after stream switch:** ``ensureAuthoritativeLanguageContentIfNeeded()`` is the language peer to the playing ensure. It performs up to ``authoritativeLanguageContentEnsureMaxAttempts`` soft pushes when ``liveActivityLanguageCodeForContentPush()`` differs from owned `content.state.currentLanguage` or suppress memory, re-reading owned language after each update. Wired after media-surface Live Activity update/start (``refreshAllMediaSurfaces``), after ``setPlaying()`` (before playing ensure), after optimistic stream-switch ContentState on the main app, and on foreground / become-active via ``ensureAuthoritativeContentOnForegroundIfNeeded()``. Does not invent `.playing`.

**Language ensure quiet pending (lock-stretch thrash protection):** After the soft language-ensure budget is exhausted without owned language acceptance while interactive request is **ineligible**, the manager records a quiet-pending destination (``languageEnsureQuietPendingDestination``) and stops re-running soft language pushes on every status callback for that destination. Language-only status re-pushes via ``updateCurrentActivity()`` also defer while quiet (owned visual still matches candidate visual). **Visual mutations still push** (pause / play / Connecting honesty). Re-arm (one high-priority ensure cycle) when: destination language changes (stream-switch mutation / optimistic ``recordOptimisticStreamSwitchContent``), interactive request becomes eligible, foreground / become-active clears quiet before soft ensure, or system `contentUpdates` yields. Does **not** end the activity while ineligible. Home-widget and Live Activity stream chips share ``publishOptimisticStreamSwitchLanguageChrome`` → ``pushOptimisticLiveActivityStreamSwitchContent`` so both paths stamp destination language before pending drain.

**Settled language acceptance (post-hold high-signal push):** Soft language ensure often burns its budget during the stream-switch attach storm (Connecting). Quiet pending then correctly stops thrash — but without a further push after hold clears, system-held `content.state.currentLanguage` can remain on the prior stream for the rest of a lock stretch while audio and home widgets already track the destination. ``pushSettledLanguageAcceptanceContentIfNeeded()`` runs after authoritative audible start (``SharedPlayerManager/setPlaying()``) and soft-resume no-op reconcile: when hold is inactive and owned language still ≠ destination, it clears language quiet **once**, submits a dual-axis ``updateCurrentActivity()`` (destination language + current honest visual), and marks ``languageSettledAcceptanceConsumedDestination`` while request is ineligible so soft-resume no-ops do not re-thrash. If owned language still lags after that single push while ineligible, quiet re-engages. Consume clears on destination change, owned convergence, eligibility / become-active, or `contentUpdates`. Does **not** invent `.playing` during hold; does **not** end while ineligible. ActivityKit may still delay applying language until the process is presentable — foreground owned-surface ensure remains the unlock recovery rail.

**Settled playing acceptance (post-hold high-signal push):** Soft playing ensure often burns its budget (or cannot run usefully while hold is active) during stream-switch attach, then quiet-pending defers visual-only `.playing` repair for the rest of a lock stretch — Connecting chrome while audio is live. ``pushSettledPlayingAcceptanceContentIfNeeded()`` runs after authoritative audible start (``SharedPlayerManager/setPlaying()``) and soft-resume no-op reconcile: when hold/connect are inactive, the actor is authoritative `.playing`, and owned visual still lags (``.prePlay`` / ``.userPaused``), it clears playing quiet **once**, submits a dual-axis ``updateCurrentActivity()`` (destination language + `.playing`), and marks ``playingSettledAcceptanceConsumed`` while request is ineligible so soft-resume no-ops do not re-thrash. If owned visual still lags after that single push while ineligible, quiet re-engages. Consume clears on optimistic toggle / stream-switch, owned convergence, eligibility / become-active, or `contentUpdates`. Does **not** invent `.playing` during hold/connect; does **not** end while ineligible. ActivityKit may still delay applying visual until the process is presentable — foreground owned-surface ensure remains the unlock recovery rail.

**Playing ensure quiet pending (lock-stretch thrash protection):** After the soft playing-ensure budget is exhausted without owned `.playing` acceptance while interactive request is **ineligible**, the manager records ``playingEnsureQuietPending`` and stops re-running soft playing pushes on every status callback. Visual-only status re-pushes that only repair candidate `.playing` also defer while quiet (owned language already matches). **Pause (``.userPaused``) and language mutations still push.** Re-arm when: authoritative play mutation (``rearmPlayingEnsureQuietPending()``), optimistic toggle or stream-switch ContentState, interactive request becomes eligible, foreground / become-active clears quiet before soft ensure, or system `contentUpdates` yields. ``setPlaying`` / soft-resume prefer settled playing acceptance (consume-once) then soft ensure without blind re-arm so lock-stretch thrash does not re-burn the soft budget on every soft-resume no-op. Does **not** end the activity while ineligible; does **not** invent `.playing` during stream-switch hold.

**Soft-ensure thrash protection (concurrent collapse + deferred announce-once):** After honesty quiet pending is engaged, residual lock-stretch noise is concurrent soft-ensure re-entry and repeated deferred-recreation / stall diagnostics while request stays ineligible. ``shouldStartAuthoritativeContentEnsureSoftPushLoop`` collapses concurrent language or playing soft-push loops into a single in-flight loop per axis (parallel attempt counters must not thrash ActivityKit). When stalled-push bookkeeping would recreate but request is ineligible, ``shouldMarkPendingEnsureForDeferredRecreation`` sets ``pendingInteractiveLiveActivityEnsure`` and ``shouldAnnounceDeferredInteractiveRecreationWhileIneligible`` announces **once** for that freeze; subsequent identical deferred evaluations stay quiet until re-arm (eligibility, mutation, become-active, or `contentUpdates`). DEBUG stall diagnostics for identical candidate/owned language+visual pairs are rate-limited via ``stalledContentDiagnosticsSignature`` / ``shouldLogStalledContentDiagnostics``; quiet-skip ensure logs emit once per quiet engagement. **Imperative** ``updateCurrentActivity()`` on true mutations (setPlaying, stop, metadata, switch) is unchanged. Does **not** end while ineligible; does **not** invent `.playing`.

**Interactive recreation after stalled ActivityKit updates:** Soft retries and owned-language/visual suppress cannot repair an ActivityKit surface that never applies `Activity.update` (device freezes: system-held language stuck on a prior stream, or visual stuck on `.userPaused` / `.prePlay` after soft resume or audible start while audio/widgets advance). After each real update, ``isStalledLiveActivityContentPush(candidate:accepted:)`` compares the submitted candidate to re-read `content.state` — language mismatch, pause-vs-playing/Connecting, **and** pure Connecting-vs-playing (or Connecting-vs-pause) visual freezes all count as stalled. A bounded streak (``stalledContentPushRecreationThreshold``) with recreation budget remaining (``maxInteractiveContentRecreations``) may recreate — **only when interactive request is eligible** (``isInteractiveLiveActivityRequestEligible``: Live Activities enabled **and** `UIApplication` active). When eligible, ``recreateInteractiveLiveActivityAfterStalledContent()`` runs ``endActivityAsync(dismissalPolicy: .immediate)`` then ``startActivity()`` so the replacement card is seeded from ``liveActivityLanguageCodeForContentPush()`` + current visual (Connecting honesty preserved during stream-switch hold). When **ineligible** (lock screen / background visibility constraints), the existing interactive activity is **kept** and a pending ensure is recorded — never end the only card when `Activity.request` cannot succeed. Concurrent content pushes are skipped while recreation is in progress. Nested recreation during end+start is suppressed; matching chrome or `contentUpdates` clears the streak and recreation count. Soft-resume visual honesty does **not** depend on recreation as the happy path.

**AGENT NOTE — Deferred recreation policy (surface continuity):** When interactive request is ineligible, end+request must **not** run. The interactive card, play/pause, and audio path stay live. Soft ``ensureAuthoritativeLanguageContentIfNeeded()`` / ``ensureAuthoritativePlayingContentIfNeeded()`` submit destination language and visual within their soft budgets; after language or playing ensure exhausts while ineligible, the matching quiet pending stops status-driven thrash until re-arm (destination/play mutation, eligibility, become-active, or `contentUpdates`). Concurrent soft-ensure re-entry collapses into one in-flight loop per axis; deferred recreation records pending ensure **once** per freeze (no deferred-log flood). ActivityKit may still delay applying language/visual to system-held `content.state` for the remainder of a lock/background stretch; convergence often occurs after the process becomes active and further updates are accepted. That ordering preserves a presentable control surface when `Activity.request` would fail (visibility-class). Do **not** reverse deferred recreation by ending the activity while ineligible. Do **not** treat delayed ContentState language or visual alone as proof that eligibility, soft-resume playing ensure, or write-side language stamps are broken. ``ensureInteractiveLiveActivityIfNeeded()`` restores a **missing** card; when ownership is already non-nil, ``ensureAuthoritativeContentOnForegroundIfNeeded()`` clears language + playing quiet then runs bounded soft language/playing ensure on become-active / foreground and may perform eligible-only recreation only if soft ensure still fails (never while ineligible).

**Foreground owned-surface ensure with existing interactive activity:** On ``handleAppDidEnterForeground()`` / ``sceneDidBecomeActive`` (via ``ensureInteractiveLiveActivityIfNeeded()``), when ``currentActivity != nil``, owned-surface recovery is the intentional unlock heal rail (system-held language/visual may lag until the process is presentable; soft ensure then eligible-only recreation without requiring an in-app stream switch).

1. **Invoke gate** — ``shouldInvokeOwnedSurfaceForegroundEnsure`` always runs soft ensure when language quiet, playing quiet, or ``pendingInteractiveLiveActivityEnsure`` is set (consume lock-stretch pending). Debounces dual will-enter-foreground + become-active hooks and rapid resign/become thrash when nothing is pending. Inside the debounce window, still re-invokes when content still needs soft ensure **and** request is now eligible (first pass may have run while application was not yet `.active`).
2. **Soft path** — ``ensureAuthoritativeContentOnForegroundIfNeeded()`` clears language + playing ensure quiet **together**, then bounded ``ensureAuthoritativeLanguageContentIfNeeded()`` then ``ensureAuthoritativePlayingContentIfNeeded()``. Soft-matched chrome is a cheap no-op.
3. **Eligible-only recreation** — If soft ensure still fails **and** ``isInteractiveLiveActivityRequestEligible`` is true with recreation budget remaining, ``recreateInteractiveLiveActivityAfterStalledContent()`` may end+request once (re-checks eligibility). **Never** ends the only card while request is ineligible. Does not invent `.playing` during stream-switch hold.

Missing-card start debounce (``interactiveLiveActivityEnsureDebounceInterval``) is independent of owned-surface debounce (``ownedSurfaceForegroundEnsureDebounceInterval``).

**Pending Live Activity start after request failure:** If ``startActivity()`` fails (including visibility-class errors) with no owned surface, or recreation was deferred while ineligible, ``pendingInteractiveLiveActivityEnsure`` is set. ``ensureInteractiveLiveActivityIfNeeded()`` (foreground / become-active, debounced on the missing-card start path) starts once when activities are enabled, the app is active, ownership is empty, and session policy still needs interactive chrome (playing / Connecting / sticky pause). Failed request also attempts re-bind of a system-held residual before marking pending. When ownership is already non-nil but system-held language/visual lags the destination, the owned-surface soft ensure path above runs (pending is consumed when the owned soft cycle invokes); end+request remains eligibility-gated only after soft ensure still fails (see note above).

Protected by ``RadioLiveActivityManagerTests`` (owned-language + owned-visual suppress gates, language ensure decision, language ensure quiet pending after max attempts while ineligible + re-arm on destination/eligibility + language-only status defer while quiet, settled language acceptance after hold clear while quiet + consume-once while ineligible + re-open on destination/eligibility, settled playing acceptance after hold clear while quiet + consume-once while ineligible + re-open on toggle/stream-switch/eligibility, playing ensure quiet pending after max attempts while ineligible + re-arm on toggle/stream-switch/authoritative play + playing-only status defer while quiet with pause/language still push, soft-ensure thrash collapse + deferred recreation announce-once + rate-limited stall diagnostics + quiet-skip log once, post-update suppress memory, stalled chrome including pure Connecting visual freeze + recreation decision + request eligibility / deferred recreation, pending ensure after failed start, foreground ensure-start policy, foreground owned-surface soft ensure + owned-surface invoke/debounce policy + eligible-only recreation-after-soft-fail policy, playing ensure for pause/Connecting with soft-retry budget, optimistic toggle + stream-switch alignment, optimistic pause from Connecting preserves language + owned-visual suppress deny), ``WidgetIntentContractExtensionTests`` (LA switch language mirror + Connecting toggle mirror, home pause warms durable LA toggle mirror), ``WidgetIntentCoordinatorTests`` / ``WidgetSurfaceTests`` (content replace, stream-switch destination, second-tap plan, stale Connecting defers to definitive userPaused/playing peers).

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

**Serial media-transport mailbox:** Remote handlers return `.success` immediately and enqueue ``MediaTransportCommand`` values via ``SharedPlayerManager/submitMediaTransportCommand(_:)``. Play and toggle wait for the prior verb; pause/stop preempt (cancel + ``stop()`` without waiting for an in-flight play) and record a pause epoch so a late `userRequestedPlay` re-asserts sticky `.userPaused`. Toggle direction is decided only inside ``performMediaTransportCommand(_:generation:)`` after prior verbs commit state — never as a split visual read in the remote-command callback. Toggle pause when ``isActivelyPlaying`` **or** ``isConnectingPlayback`` (cancel connect); thermal refuse while ``blocksPlannedPlay`` and the device is still stressed. Main-app ``WidgetIntentExecution/executeLiveActivityToggle(plan:)`` uses ``submitMediaTransportCommandAndWait(_:)`` so Live Activity engine execution shares the same ordering as headset / Control Center.

**Extension-hosted Live Activity / home-widget play-pause:** The extension process still uses direct ``stop()`` / ``userRequestedPlay()`` (optimistic snapshot + `pendingAction*` + Darwin `notifyMainApp`). Real audio changes only after the main app drains via ``RadioPlayerCoordinator/checkForPendingWidgetActions()`` (single owner of debounce, UITestMode drain-without-execute, and mailbox enqueue). `ViewController` and `SceneDelegate` only call a thin public shim after Darwin notify or lifecycle events.

Drain rules that keep chrome trustworthy:

- **Same-direction debounce (0.65 s):** A second `"play"` or second `"pause"` within the window is dropped after clearing the pending key (AVFoundation thrash guard). **Opposite** verbs always execute so a rapid flip is not lost after optimistic ContentState already showed the second glyph.
- **Mailbox on drain:** Drained play and pause enqueue ``submitMediaTransportCommandAndWait`` (play) / ``handleWidgetPauseAction`` (pause → mailbox), so an opposite pause can preempt an in-flight extension-originated play the same way system remotes do. Pause drain uses a single MainActor Task (no nested Task hop).
- **Delivery path:** Darwin `deliverImmediately` + main-queue drain remains primary; SceneDelegate become-active / launch 1…5 s burst are defense-in-depth. No long-period poll timer (unreliable while suspended). UITestMode still clears pendings without executing unless the DEBUG bypass is set.

### Widgets

Mutation-path timeline reloads are driven by the Tier 2 ``PlayerEvent`` observer in ``WidgetRefreshManager`` (``WidgetRefreshTrigger/playerEvent``; debounce + coalesce). Imperative ``refreshIfNeeded`` remains for lifecycle (``.lifecycle``), teardown/post-stop (``.teardown``), extension optimistic intents (``.extensionOptimistic``), and optional ``refreshAllMediaSurfaces(widgetRefresh: true)`` (``.mediaSurface``). Dual-path inventory and DEBUG dual-fire soft log: `docs/Event-Driven-Refactor-Roadmap.md` Tier 4 §2.

### DEBUG media-transport latency timeline

``MediaTransportLatencyTimeline`` (DEBUG only; stripped from Release) records ordered milestones so device QA can measure intent → soft silence and intent → first audio with numbers rather than anecdotes. **It does not change transport policy**, mailbox ordering, soft-pause, or surface refresh.

| Milestone family | Insertion points |
|------------------|------------------|
| Live Activity toggle | ``WidgetIntentExecution/performLiveActivityToggle()`` — started, plan resolved, optimistic published, execute started/finished |
| Mailbox | ``submitMediaTransportCommand`` enqueue; ``performMediaTransportCommand`` execute start/finish |
| Soft silence | ``DirectStreamingPlayer/stopAndWait`` resume (engine-complete) |
| First audio chrome | ``publishAuthoritativePlayingIfNeeded`` published / skipped |
| Extension drain | ``RadioPlayerCoordinator/checkForPendingWidgetActions()`` — entered, same-direction debounced, play/pause start/finish |

**Console format** (grep `[MediaTransportLatency]`):

```text
[MediaTransportLatency] #n t=+Tms dt=+Dms <milestone> [detail]
```

- `t` — elapsed since last ``MediaTransportLatencyTimeline/reset()`` (or first mark after process start)
- `dt` — delta since the previous mark (per-hop latency)
- **One line per mark:** each milestone is emitted once via `print` only. Do not reintroduce a twin `os.Logger` emit of the same string — Xcode’s console mirrors both sinks and previously showed identical duplicate lines (same `t=` / `dt=`), which polluted field analysis.

**Unit gates:** `SharedPlayerManagerMediaTransportLatencyTests` — `testMediaTransportLatencyTimelineRecordsPauseMailboxAndSoftSilence` (includes single `softSilenceComplete` count), `testMediaTransportLatencyTimelineRecordsLiveActivityTogglePauseChain`.

**Device QA:** Before a lock-screen scenario, optionally call ``MediaTransportLatencyTimeline/reset()`` from a DEBUG hook or rely on process-start origin; then pause/play from Now Playing and Live Activity and read `dt=` on `softSilenceComplete` and `authoritativePlayingPublished`. Each milestone should appear once in the console.

- SeeAlso: ``MediaTransportLatencyTimeline``, docs/Widget-Functionality-Roadmap.md

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
- Live Activity views (via ``ContentState.streamMetadata`` + ``ContentState.currentLanguage`` + presentation pre-derivation)

The **dual-card layout** remains; **metadata mismatch** between cards is a bug. Stacking itself is not.

---

## ICY StreamTitle Single-Owner Path

Live program metadata has **one** mutation owner on the main app:

| Step | Owner | Role |
|------|--------|------|
| Extract `StreamTitle` from `AVPlayerItemMetadataOutput` | ``DirectStreamingPlayer`` (`+Metadata`) | Real ICY only |
| Deliver | ``safeOnMetadataChange(metadata:)`` | Pushes SSOT, then host presentation hook |
| Mutate + emit + surfaces | ``SharedPlayerManager/didUpdateStreamMetadata(_:)`` | Sole write of raw/parsed stash; emits `.metadataDidUpdate`; LA → Now Playing → privacy-gated home persist |
| In-app chrome | `RadioPlayerCoordinator` `onMetadataChange` | **ViewModel only** (sleep-timer may defer VM apply). Must not re-enter ``didUpdateStreamMetadata`` |
| Home / Control program chrome | ``persistStreamMetadataForWidgets()`` + App Group ``homeWidgetStreamMetadata`` mirror | In-process session snapshot is process-local (OI-1). Extension Providers read ``loadHomeWidgetStreamMetadataMirror()`` via ``WidgetProviderSnapshotResolver`` |
| Privacy → write handoff | ``restampHomeWidgetProgramMetadataAfterPrivacyGateOpenIfNeeded()`` | When ``hasActiveWidgets`` opens false→true and in-memory ICY is non-nil, re-stamp session + mirror once (identical subsequent ICY is a no-op) |

**Invariants:**

1. **No dual delivery** — coordinator must not call ``didUpdateStreamMetadata`` / `updateNowPlayingInfo(title:)` for live ICY; that re-emits and re-pushes surfaces.
2. **Idempotent SSOT** — identical raw ICY is a no-op inside ``didUpdateStreamMetadata`` (defense in depth).
3. **No catalog titles as StreamTitle** — ``Stream/title`` / ``Stream/language`` are presentation labels. Feeding catalog `"Station - Language"` into the parser yields `programTitle` = language name. On language-code change, ``selectedStream`` clears prior ICY (`nil`) so surfaces use station/language fallbacks until real ICY arrives.
4. **Clear paths** remain ``_clearIcyMetadataStash()`` / ``clearSoftPauseMetadataStashForLanguageChange()`` for paused switches and language hygiene (also clear the home program-metadata mirror).
5. **Privacy** — home program-metadata mirror writes only while ``hasActiveWidgets`` (or widget-process bypass). Gate close / privacy clear remove the key. Do **not** invent catalog titles to fill empty ICY.
6. **OI-1 intact** — visual / playback chrome stay memory-only; the mirror is program title/speaker only, not play state.

**SeeAlso:** ``DirectStreamingPlayer/selectedStream``, ``DirectStreamingPlayer/safeOnMetadataChange(metadata:)``, ``SharedPlayerManager/didUpdateStreamMetadata(_:)``, ``SharedPlayerManager/persistHomeWidgetStreamMetadataMirror(_:)``, ``SharedPlayerManager/restampHomeWidgetProgramMetadataAfterPrivacyGateOpenIfNeeded()``, `StreamProgramMetadataTests`, `SharedPlayerManagerMediaSurfaceTests`.

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

## Connecting Chrome vs Audible Start

``SharedPlayerManager/play()`` must **not** call ``setPlaying()`` before soft-resume or secured attach completes. Claiming `.playing` (Now Playing rate 1, Live Activity pause glyph, `streamDidStart`) while the engine is still validating, tuning, or waiting on `.readyToPlay` made lock-screen chrome lie about audio.

| Phase | Visual / intent | Surfaces |
|-------|-----------------|----------|
| Explicit play intent (true attach / switch) | ``setUserIntentToPlay()`` → `.prePlay` + active intent | Connecting chrome; `isActivelyPlaying == false` (play affordance, rate 0) |
| Soft-resume eligible (same stream) | Residual sticky visual held (no Connecting stamp) + active intent until ``setPlaying()`` | Gapless intermediate: home skips yellow Connecting; main may briefly show residual pause chrome; LA still settles only after authoritative publish |
| Soft-resume success | Rate kick then ``publishAuthoritativePlayingIfNeeded()`` → ``setPlaying()`` | Rate 1, pause glyph, LA start/update + settled playing acceptance / soft ensure |
| Full attach | `startPlayback` stays on `status_connecting` / stream-switch prePlay hold | Same connecting chrome until readyToPlay |
| readyToPlay first-play kick | `playImmediately` then ``publishAuthoritativePlayingIfNeeded()`` | Authoritative `.playing` |
| User pause during connect | Sticky `.userPaused` + generation discard (see above) | Paused chrome + silent engine |

**Authoritative publish helper:** ``DirectStreamingPlayer`` `publishAuthoritativePlayingIfNeeded()` calls ``setPlaying()`` only when intent still allows play and visual is not already `.playing` (readyToPlay + timeControl KVO cannot double-emit).

**Surface paint after ``setPlaying()`` (shared intermediate, independent consumers):**

| Surface | How `.playing` reaches chrome after audible start |
|---------|---------------------------------------------------|
| Live Activity | Direct ``refreshAllMediaSurfaces`` / ``updateCurrentActivity``; settled playing acceptance + soft ensure when owned ContentState lags (this document) |
| Home widget | Tier 2 ``PlayerEvent`` observer + soft-resume coalesce / Connecting skip ([`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md)) |
| Main-app play/pause + status pill | **Primary:** ``RadioPlayerCoordinator/beginObservingVisualStateForChrome()`` on ``visualStateDidChange``; status path is demoted race lead + errors only via pure ``RadioPlayerChromeVisualResolver`` (soft-resume hold promote is intent-gated). See **Main-App Chrome Authority** in Widget Presentation Dataflow. |

Do **not** re-solve main-app grey residual by inventing `.playing` before the engine kick, reintroducing soft-resume Connecting stamps, or routing main paint through LA ensure loops. Soft-resume Connecting skip for home remains intentional; main chrome must settle from SPM visual SSOT once ``setPlaying()`` emits.

**Extension optimistic paths** (widget `handleWidgetPlay`, Live Activity toggle ContentState) may still flip control chrome immediately for cross-process latency; main-app engine chrome follows the table above. Security recovery optimistic play uses Connecting (``.prePlay``), not green `.playing`, until validation + audible start succeed.

**SeeAlso:** ``SharedPlayerManager/play()``, ``SharedPlayerManager/setPlaying()``, `resumeFromSoftPauseIfAvailable`, readyToPlay kick in `addObservers`, ``RadioPlayerCoordinator/beginObservingVisualStateForChrome()``, ``RadioPlayerChromeVisualResolver``, [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md) (main-app chrome authority; home soft-resume refresh), `Lutheran RadioTests` connecting-chrome and publish-idempotency gates.

---

## Media Toggle Planning (Connecting / Thermal / Security)

``PlayerVisualState/isActivelyPlaying`` remains **audio is flowing** (``.playing`` only). Media-transport and Live Activity **toggle planning** use a richer matrix so intermediate and policy states do not behave like “idle pause → play”:

| Authoritative condition | Toggle plan | Rationale |
|-------------------------|-------------|-----------|
| ``isActivelyPlaying`` | pause | Silence audio |
| ``SharedPlayerManager/isConnectingPlayback`` (start pipeline active, not yet playing) | pause | Cancel connect; do not re-enter validation/attach |
| ``thermalPaused`` (``blocksPlannedPlay``) | refuse | Hardware gate; cool-down auto-resume; keep thermal chrome |
| ``securityLocked`` | play (recovery) | Explicit re-validation; optimistic chrome = Connecting (``.prePlay``) |
| ``userPaused`` / idle ``prePlay`` / ``cleared`` | play | Normal resume / first play |

**Idempotent play:** ``userRequestedPlay()`` is a no-op while ``isConnectingPlayback`` is true. Remote play while connecting does not stack a second pipeline.

**Start pipeline:** ``play()`` sets an in-actor start-pipeline flag after sticky/early guards and clears it in ``setPlaying()``, ``stop()``, security lock, or sticky abort. Live Activity planning reads ``isConnectingPlayback`` on the main app (extension host may still only see ContentState; main-app drain remains idempotent).

**SeeAlso:** ``PlayerVisualState/plansMediaToggleAsPause``, ``PlayerVisualState/blocksPlannedPlay``, ``PlayerVisualState/optimisticVisualAfterPlayPlan``, ``WidgetIntentCoordinators/planLiveActivityToggle(resolution:distrustDurableMirrorPlay:isConnectingPlayback:)``, ``SharedPlayerManager/performMediaTransportCommand(_:generation:)``.

---

## Cross-References

- [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md) — presentation surfaces, LA event-driven model, termination invariant, **main-app chrome authority** (SSOT visual paint + demoted status adapter; soft-resume hold contract)
- [`docs/Widget-Functionality-Roadmap.md`](Widget-Functionality-Roadmap.md) — Tier 4 completion status
- [`docs/Event-Driven-Refactor-Roadmap.md`](Event-Driven-Refactor-Roadmap.md) — `PlayerEvent` consumers (``WidgetRefreshManager``, main-app chrome observation, ``PlayerEventSubscriber``)
- `Lutheran RadioTests/RadioLiveActivityManagerTests.swift` — LA diff suppression
- `Lutheran RadioTests/SharedPlayerManagerMediaSurfaceTests.swift` — `refreshAllMediaSurfaces` contract; Now Playing rate/`playbackState` alignment; unsupported remote-command disable; media-transport mailbox (double-toggle, pause preemption, LA + remote interleave)
- `Lutheran RadioTests/SharedPlayerManagerMediaTransportLatencyTests.swift` — DEBUG ``MediaTransportLatencyTimeline`` pause + LA toggle chains
- `Lutheran Radio/MediaTransportLatencyTimeline.swift` — DEBUG-only structured latency timeline (membership-exception; stripped from Release)
- `Lutheran Radio/RadioPlayerCoordinator+StatusDistribution.swift` — main-app dual-path chrome (orthogonal to LA ContentState ensure; shared soft-resume intermediate language only)