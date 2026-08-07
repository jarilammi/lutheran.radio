# Home Live Chrome App Group Mirror — Design Spec

**Status:** **Implemented** (2026-08-07) · PR1–PR4 shipped · Provider paint via ``resolveHomeWidgetChromeFields`` (agreement → session; disagreement → fresher `updatedAt`) · privacy residual clear true→false edge only · device eyes-on §10.3 / §14 **passed** · PR5 wake-discard unification **shipped** (optional follow-on; not required for Implemented). Details: §6, §7.2, §8, §11.  
**Date:** 2026-07-30 (inventory polish 2026-08-06; eyes-on absorb 2026-08-07; PR5 2026-08-07)  

**Audience:** Implementers and reviewers of home/Control widget cross-process chrome  
**Canonical permanent rules:** [`CODING_AGENT.md`](../CODING_AGENT.md) (always take precedence)  

**How this document advances:** This file is the **committed mechanism SSOT**. Temporary untracked notes and device logs may exist locally for capture; they are never committed or cited from product code. Useful truth is absorbed here (mechanism language only) in the **same change as the code** (or as a docs-only absorb when validation status changes). See §16.

**Related permanent docs (do not regress):**

| Doc | Role |
|-----|------|
| [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md) | Snapshot → Provider → timeline; soft-resume / switch honesty contracts |
| [`docs/Widget-Functionality-Roadmap.md`](Widget-Functionality-Roadmap.md) | Hybrid two-zone model; permanent optimistic + pending infrastructure |
| [`docs/Event-Driven-Refactor-Roadmap.md`](Event-Driven-Refactor-Roadmap.md) | OI-1 memory-only visual; non-forcing dual-path refresh |
| [`docs/Live-Activity-Stacking-and-Media-Surfaces.md`](Live-Activity-Stacking-and-Media-Surfaces.md) | LA ContentState + durable mirrors (orthogonal gate policy); lock-stretch language soft ensure + presentable-window heal residual |
| App Group SSOT table in `Lutheran Radio/SharedPlayerManager.swift` | Authoritative key inventory after ship |

---

## 1. Problem statement

### 1.1 What broke

OI-1 correctly made visual / playback chrome **memory-only** for privacy and cold-launch honesty:

- No durable restore of “was playing” across process exit.
- Retired keys (`persistedWidgetState`, `playerVisualState`, `isPlaying`, bare `currentLanguage`, …) are purge-only.

The incomplete half of that contract is live **cross-process paint**:

| Surface | How it sees chrome today | Works while main is alive? |
|---------|--------------------------|----------------------------|
| Main app UI | Actor `currentVisualState` + session RAM | Yes |
| Live Activity | ActivityKit `ContentState` + LA durable mirrors (not home-gated) | Yes when ActivityKit accepts; some widget playing switches while request-ineligible may lag language until become-active (home paint is independent) |
| Home / Control **Provider** | `loadPersistedWidgetState()` (**process-local RAM**) else factory `.prePlay` | **No** for main-app-driven transitions |
| Program title on home | Session RAM then privacy-gated `homeWidgetStreamMetadata` | Yes (pattern to copy) |

`WidgetRefreshManager.performRefresh` only calls `WidgetCenter.reloadTimelines` — it does **not** pass visual/language into WidgetKit. The extension re-reads App Group + its own process memory. Main-process “refresh executed … visualState: .playing” is a **scheduler label**, not Provider paint proof.

### 1.2 Design goal

Give home and Control **Providers** a **privacy-gated, short-lived, extension-readable** chrome signal that tracks main-app (and extension-optimistic) visual + language **while the main process is alive and home widgets are installed**, without:

- Restoring play state across cold launch (OI-1 must hold)
- Opening write suppression when no home widgets
- Touching Core / DNS / pins
- Inventing `.playing` during stream-switch hold
- Replacing pending-action mailbox or Darwin IPC
- Forcing `PlayerEvent` into the extension

### 1.3 Non-goals

| Non-goal | Why |
|----------|-----|
| Fix LA lock-stretch ContentState acceptance | Separate ActivityKit surface; LA already has ContentState + ungated durable mirrors |
| Collapse dual-path `WidgetRefreshManager` | Non-forcing architecture stays; mirror reduces *need* for complex execute-time authority later |
| Fold instant-feedback triple “for simplicity” as the only fix | Instant feedback is language-only and ~15 s; not authoritative settle chrome |
| Reintroduce full on-disk `PersistedWidgetState` blob | Too large; cold-launch restore temptation; OI-1 regression |
| Use LA mirrors as home chrome SSOT | LA mirrors are **not** gated by `hasActiveWidgets`; home privacy history forbids that |

---

## 2. Design principles

1. **Copy the proven metadata pattern**, not the LA pattern.  
   `homeWidgetStreamMetadata` is privacy-gated, cleared on gate close, and read by `WidgetProviderSnapshotResolver`. Live chrome must match that privacy class.

2. **OI-1 remains for cold launch.**  
   Mirror is **session live chrome**, not cold-launch resurrection. After process exit / terminate sentinel / privacy clear, Providers show factory passive or `.prePlay` defaults.

3. **Main app remains authority; extension may optimistic-stamp.**  
   Extension intent paths may write the mirror early (same as today’s optimistic session snapshot + instant feedback). Main-app sticky pause, setPlaying, switch hold, and soft-resume settle **overwrite** with authoritative values when the privacy gate is open.

4. **`reloadTimelines` stays the wake signal.**  
   The mirror is the **payload** Providers read; refresh scheduling is still required to wake WidgetKit. Scheduler policy may be simplified *after* paint is correct — not instead of the mirror.

5. **Mechanism names only** in product code and permanent docs when shipping (no living-prompt cluster IDs).

---

## 3. Key design

### 3.1 Recommendation: single JSON blob (preferred)

**One App Group key**, one encode/decode path, one clear helper — parallel to `homeWidgetStreamMetadata`.

| Field | Type | Value |
|-------|------|--------|
| **Key name** | `String` | `homeWidgetLiveChrome` |
| **Suite** | App Group | `group.radio.lutheran.shared` |
| **Storage type** | `Data` (JSON) | Codable struct |
| **Gate** | Privacy | Write only when `hasActiveWidgets \|\| isWidgetProcess()` |
| **Cold launch** | None | Key absent or ignored when process is not resident / sentinel passive path |

#### Payload: `HomeWidgetLiveChrome`

```swift
/// Privacy-gated live home/Control chrome for extension Providers.
/// Session-scoped only — never used for cold-launch resurrection (OI-1).
struct HomeWidgetLiveChrome: Codable, Equatable, Sendable {
    /// Presentation visual for status/control derivation (never invent mid-hold playing).
    var visualState: PlayerVisualState  // encode as stable case name String

    /// Stream language code for flag / station label / chips.
    var currentLanguage: String

    /// Permanent-error chrome flag (security / unrecoverable network).
    var hasError: Bool

    /// Wall-clock of last authoritative or optimistic stamp (epoch seconds).
    var updatedAt: TimeInterval

    /// Optional: generation or reason token for DEBUG / future coalesce (not required for v1 paint).
    var stampReason: String?  // e.g. "setPlaying", "stickyPause", "switchHold", "optimisticToggle"
}
```

**Encoding notes:**

- Encode `PlayerVisualState` as a **stable case-name token** (same approach as `liveActivityToggleVisualState` tokens) so extension and main stay binary-compatible across minor refactors.
- Unknown tokens on read → treat mirror as **absent** (safe `.prePlay` path), never crash.
- Do **not** embed `StreamProgramMetadata` here — keep `homeWidgetStreamMetadata` as the sole program-title mirror (single concern).

### 3.2 Rejected alternatives (and why)

| Alternative | Decision |
|-------------|----------|
| Three scalar keys (`homeWidgetLiveVisual`, `homeWidgetLiveLanguage`, `homeWidgetLiveHasError`) | Workable but more residual-clear surface; prefer one blob like metadata |
| Reuse `liveActivityToggleVisualState` + `liveActivityCurrentLanguage` for home | **Reject** — not privacy-gated; would re-open language/visual writes when no home widgets |
| Revive full `persistedWidgetState` JSON | **Reject** — OI-1 regression; cold-launch restore risk; oversized |
| Instant-feedback only (existing triple) | **Reject** as sole chrome SSOT — language-only, 15 s window, not used by Provider visual today |
| Darwin payload / CFNotification userInfo | **Reject** — payload-less notify is proven; UserDefaults mailbox remains the data plane |

### 3.3 Relationship to existing keys

| Existing key | Relationship after ship |
|--------------|-------------------------|
| `inMemorySessionWidgetSnapshot` | Unchanged — main + warm extension RAM SSOT |
| `homeWidgetStreamMetadata` | Unchanged — program title/speaker only |
| `isInstantFeedback` / `instantFeedbackTime` / `instantFeedbackLanguage` | Keep for short-lived optimistic language on `loadSharedState` paths; **not** required for Provider visual once mirror exists. Optional later fold (operational residual), not this design’s scope |
| `lastUpdateTime` | Unchanged — 60 s interactive vs passive; terminate `0` |
| `liveActivityToggleVisualState` / `liveActivityCurrentLanguage` | Unchanged — LA-only; **not** home privacy class |
| Retired visual keys | Stay purge-only; never reintroduce writers |

### 3.4 SSOT table row (for `SharedPlayerManager` when shipping)

| Key | Type | Primary writers | Primary readers | Purpose | Lifetime |
|-----|------|-----------------|-----------------|---------|----------|
| `homeWidgetLiveChrome` | Data (JSON) | `persistHomeWidgetLiveChromeMirror` via session save / sticky / setPlaying / switch / optimistic intent | `loadHomeWidgetLiveChromeMirror` + `WidgetProviderSnapshotResolver.resolveFromSnapshot` | Privacy-gated **visual + language + hasError** for home/Control Providers (extension cannot read main-app session RAM) | Written only while `hasActiveWidgets` (or widget-process bypass); cleared on gate close, privacy clear, factory/privacy reset, terminate residual hygiene |

---

## 4. API surface (shipped)

All names are mechanism-oriented. Placement:

- Payload type + identity skip + pure resolution: `WidgetSurface/HomeWidgetLiveChrome.swift` (presentation-only) — ``HomeWidgetLiveChrome``, ``shouldSkipIdenticalHomeWidgetLiveChromeWrite``, ``resolveHomeWidgetChromeFields``
- Persist / load / clear / stamp convenience: `SharedPlayerManager+Persistence.swift` (membership-exception SPM, next to program-metadata mirror)
- Provider paint: ``WidgetProviderSnapshotResolver/resolveFromSnapshot`` (membership-exception `WidgetDisplayModels.swift`)

```text
homeWidgetLiveChromeAppGroupKey: String  // "homeWidgetLiveChrome"

persistHomeWidgetLiveChromeMirror(_ chrome: HomeWidgetLiveChrome?)
  // Pre: hasActiveWidgets || isWidgetProcess()
  // Post: App Group holds JSON; no-op when gate closed (main app); nil / empty language removes key
  // Extension process refuses .playing stamps when shouldDistrustDurableMirrorPlayPlanning()

loadHomeWidgetLiveChromeMirror() -> HomeWidgetLiveChrome?
  // Returns nil if missing / decode fail / unknown visual token / empty language

clearHomeWidgetLiveChromeMirror()
  // Gate true→false edge, privacy clear, factory residual, terminate hygiene

stampHomeWidgetLiveChromeFromSession(
  visualState: PlayerVisualState,
  language: String,
  hasError: Bool,
  reason: String?
)
  // Builds chrome + updatedAt = now; identity-skip then persist if gate open
  // Wired from sticky pause, setPlaying, switch hold, save projection, extension optimistic paths

shouldSkipIdenticalHomeWidgetLiveChromeWrite(
  existing: HomeWidgetLiveChrome?,
  candidate: HomeWidgetLiveChrome
) -> Bool
  // Skip when visual + language + hasError match (ignore stampReason / updatedAt)

resolveHomeWidgetChromeFields(...) -> HomeWidgetResolvedChrome
  // agreement → session; disagreement → fresher updatedAt; neither → factory
  // distrustLiveChrome ignores residual mirror (terminate sentinel / reboot boot-identity)
```

**Do not** add a second visual SSOT on the actor. Mirror is a **cross-process projection** of session visual + language already decided by SPM.

---

## 5. Writers (who stamps, when)

### 5.1 Authority rules

| Rank | Writer class | May stamp? | Notes |
|------|--------------|------------|--------|
| 1 | Main app authoritative settle | Yes (gate open) | `setPlaying`, sticky pause lock, permanent error, privacy `.cleared` path before clear |
| 2 | Main app intentional non-playing hold | Yes (gate open) | Stream-switch Connecting (`.prePlay` + destination language); soft-resume **does not** stamp intermediate Connecting when `canSoftResumeSameStream` — retain prior sticky chrome until setPlaying |
| 3 | Extension optimistic intent | Yes (widget-process bypass) | Toggle / switch intent before Darwin drain; same visual honesty as `optimisticLiveActivityVisualForStreamSwitch` / toggle plan |
| 4 | Gate closed (no home widgets) | **No** | Suppress; clear residual on transition true→false |
| 5 | Cold launch factory reset | Clear only | Do not seed “playing” from prior process |

### 5.2 Main-app stamp matrix

| Event | visualState to stamp | language | hasError | urgency / notes |
|-------|----------------------|----------|----------|-----------------|
| Sticky user pause lock (`stop` / `setUserPaused` / `markAsUserPaused`) | `.userPaused` | current stream language | false (unless permanent error) | **Early** — same moment as early sticky session snapshot intent; before soft silence |
| Soft-resume eligible play intent | **Do not stamp Connecting** | unchanged | — | Hold residual pause chrome until audible |
| Engine `setPlaying()` / authoritative playing | `.playing` | current / destination language | false | Authoritative settle; always stamp when gate open |
| Stream-switch hold (active play) | `.prePlay` | **destination** language | false | Honesty window; never `.playing` mid-hold |
| Paused stream switch (no auto-resume) | `.userPaused` | destination language | false | Destination language without Connecting hold |
| Permanent error / security lock chrome | policy visual | current language | true as needed | Match session `hasError` |
| Privacy clear / factory reset | clear mirror | — | — | No “cleared” durable home chrome after quit |
| Attach-path identical Connecting storm | skip if identical | — | — | Reuse identity-skip spirit of sticky Connecting snapshot skip |
| ICY metadata only | **no chrome stamp** | — | — | Metadata mirror only |

### 5.3 Extension optimistic stamp matrix

| Intent | visualState | language | Notes |
|--------|-------------|----------|-------|
| Home/Control toggle → pause | `.userPaused` | current | Mirror + session optimistic + pending |
| Home/Control toggle → play (connect) | `.prePlay` (or plan’s optimistic visual) | current | Do not invent playing if plan says Connecting |
| Soft-resume path after pause (same stream) | Prefer plan’s non-lying optimistic; if plan is playing, stamp `.playing` only when product policy already does for optimistic UI | current | Align with `optimisticVisualAfterPlayPlan` — no new invention |
| Stream switch while playing | `.prePlay` | destination | Same as `optimisticLiveActivityVisualForStreamSwitch` |
| Stream switch while paused | `.userPaused` | destination | Preserve sticky pause |

Extension writes must use the **same pure planners** already used for session optimistic snapshots so LA / home / intent stay aligned.

### 5.4 Coupling to existing save paths

| Existing path | Add live-chrome stamp? |
|---------------|------------------------|
| `savePersistedWidgetState` / `persistWidgetSnapshot` (when gate open) | **Yes** — project visual + language + hasError (identity skip OK) |
| `persistEarlyStickyUserPausedSnapshotIfPrivacyAllows` | **Yes** — early pause honesty |
| `performActualSave` when snapshot actually changes | **Yes** |
| `saveCombinedWidgetState` / language destination stamp | **Yes** (language + current visual) |
| Soft-resume Connecting skip | **No intermediate Connecting stamp** (mirror holds prior pause until setPlaying) |
| `persistStreamMetadataForWidgets` | **No** chrome change (metadata only) |
| LA ContentState push | **No** — different gate class |
| `bumpWidgetLivenessTimestamp` alone | **No** — liveness ≠ chrome |

### 5.5 Gate open false → true (handoff)

When `hasActiveLutheranWidgets` opens:

1. If main process has a non-factory session visual/language, **re-stamp once** (same spirit as `restampHomeWidgetProgramMetadataAfterPrivacyGateOpenIfNeeded`).
2. Then schedule a normal `reloadTimelines` (existing refresh path).
3. Do not invent `.playing` if actor is still Connecting hold.

---

## 6. Provider read order

### 6.1 Shipped algorithm (`WidgetProviderSnapshotResolver.resolveFromSnapshot`)

```text
let mirroredMetadata = loadHomeWidgetStreamMetadataMirror()
let liveChrome = loadHomeWidgetLiveChromeMirror()
let session = loadPersistedWidgetState()  // process-local; may be nil in extension
// session.updatedAt = lastLanguageChangeTime epoch (for freshness)

// --- Visual / language / hasError ---
// Pure ``resolveHomeWidgetChromeFields`` (WidgetSurface):
//  1. Neither source → factory (.prePlay, language nil → preferredWidgetLanguage(), hasError false)
//  2. Only one source → that source
//  3. Both agree on chrome fields → prefer session (same-process optimistic continuity)
//  4. Both disagree → greater updatedAt wins; ties prefer session
//  5. Session missing updatedAt treated as older than any stamped mirror

let chrome = resolveHomeWidgetChromeFields(
  sessionVisual: session?.visualState,
  sessionLanguage: session?.currentLanguage,
  sessionHasError: session?.hasError,
  sessionUpdatedAt: session?.updatedAt,
  liveChrome: liveChrome
)
let language = chrome.currentLanguage ?? preferredWidgetLanguage()

// --- Program metadata (unchanged; not in live chrome) ---
let streamMetadata = session?.streamMetadata ?? mirroredMetadata

return WidgetProviderSnapshotFields(
  currentLanguage: language,
  hasError: chrome.hasError,
  visualState: chrome.visualState,
  streamMetadata: streamMetadata
)
```

### 6.2 Why freshness (not rigid session-first)

| Host | Session RAM | Live chrome mirror | Paint when they disagree |
|------|-------------|--------------------|---------------------------|
| Main app (rare Provider host) | Authoritative in-process | Redundant projection | Usually agree after save projection |
| Extension after **own** optimistic intent | Fresh optimistic write | Same tick if intent also stamped mirror | **Agreement → session** |
| Extension after **main-only** transition | Often **nil** | **Authoritative paint source** | Mirror-only |
| Extension **warm** after main settle | Stale optimistic (e.g. switch-hold ``.prePlay``) | Newer main ``.playing`` / sticky pause | **Fresher `updatedAt` wins** |
| Extension cold wake after terminate | nil | Should be **cleared** → factory / passive | Factory / passive |

Rigid session-first left home yellow Connecting when extension session held switch-hold ``.prePlay`` while main had already stamped a newer ``homeWidgetLiveChrome`` ``.playing``. Freshness comparison preserves same-process optimistic continuity (agree → session; fresher session pause still beats staler residual playing mirror) while allowing a fresher main mirror to replace a stale extension session.

### 6.3 Passive / termination / reboot interaction

| Condition | Provider behavior |
|-----------|-------------------|
| `lastUpdateTime == 0` (termination sentinel) or liveness aged out | Existing passive `tap_to_open` via `WidgetLivenessPresentation` — **do not** treat live chrome as interactive proof of a live app |
| `shouldDistrustDurableMirrorPlayPlanning()` (termination sentinel **or** device reboot boot-identity mismatch) | ``resolveHomeWidgetChromeFields(..., distrustLiveChrome: true)`` treats residual ``homeWidgetLiveChrome`` as **absent** even if the App Group blob remains (force-quit and power cycle often never run observed-terminate clear). Empty session → factory paint (``.prePlay`` + ``preferredWidgetLanguage()``). Process-local session still wins when present. |
| Live chrome present but main process not recently active (no reboot, residual 60 s window) | Liveness still wins for **interactive vs passive** chrome; residual mirror may still supply visual fields until aged out or cleared |
| No live chrome, no session | `.prePlay` + `preferredWidgetLanguage()` |
| Extension write under distrust | ``persistHomeWidgetLiveChromeMirror`` refuses stamping ``.playing`` (must not re-project residual “still playing” after terminate/reboot) |

**Recommended terminate hygiene:** `forceStaleLivenessTimestampForTermination` / sync termination teardown also `clearHomeWidgetLiveChromeMirror()` (with metadata residual policy already in place). Prefer explicit clear over “stale mirror + passive overlay”. **Reboot / force-quit residual:** when clear never ran, paint distrust above is the safety net so Providers do not flash last play/pause glyphs.

### 6.4 Control Center Provider

Same `resolveFromSnapshot` / hygiene path as home. No second resolution order.

### 6.5 What Providers must never do

- Read `SharedPlayerManager.currentVisualState` as home SSOT (actor may be empty/wrong isolation in extension).
- Read LA durable mirrors for home chrome.
- Decode retired `persistedWidgetState` disk keys.
- Invent `.playing` when mirror says `.prePlay` during switch hold.

---

## 7. Privacy clear matrix

Legend: **W** = may write · **C** = must clear · **—** = no-op · **R** = may read

### 7.1 Key lifetime matrix

| Event | `homeWidgetLiveChrome` | `homeWidgetStreamMetadata` | Instant-feedback triple | Session RAM | LA mirrors | Pending mailbox | `lastUpdateTime` |
|-------|------------------------|----------------------------|-------------------------|-------------|------------|-----------------|------------------|
| No home widgets (gate closed) | **C** residual; **no W** | **C** residual; **no W** | **C** residual | may exist main-only | **W** allowed | **W** transient OK | **C** residual |
| Gate open (widgets installed) | **W** | **W** | **W** | **W** | **W** | **W** | **W** |
| Gate false → true | **W** re-stamp once | **W** re-stamp once | — | as today | — | — | **W** |
| Gate true → false | **C** | **C** | **C** | keep main RAM optional | keep | keep transient rules | **C** residual helper |
| User privacy clear (`clearAllLocalState`) | **C** | **C** | **C** | **C** | **C** | **C** | **C** |
| Factory reset cold launch | **C** (or already empty) | **C** | **C** | **C** | **C** as today | as today | as today |
| App terminate (delivered path) | **C** (recommended) | as today | as today | process dies | LA end + clear as today | as today | **0** sentinel |
| Force-quit | process dies; next launch factory | next launch purge | next launch | empty | residual reaped as today | as today | ages out / launch purge |
| Soft silence / pause | **W** `.userPaused` | keep title or clear per ICY policy | clear on auth save as today | **W** | LA path separate | — | **W** throttle |
| setPlaying | **W** `.playing` | keep/update via ICY | clear optimistic as today | **W** | LA separate | — | **W** |
| Stream switch hold | **W** `.prePlay` + dest lang | clear title on switch as today | lang flash optional | **W** | LA separate | switch pending | **W** |
| ICY title update | **—** | **W** | — | metadata in session | LA in-memory | — | optional |

### 7.2 Clear helper ownership

Live chrome is **not** folded into the liveness residual helper. Gate close runs **sibling** clears at one edge site.

| Helper / site | Clears live chrome? | Notes |
|---------------|---------------------|--------|
| `clearHomeWidgetLivenessAndInstantFeedbackResiduals()` | **No** | Only `lastUpdateTime` + instant-feedback triple (`isInstantFeedback` / time / language). Name is honest — do not extend this helper to own mirrors. |
| `clearHomeWidgetStreamMetadataMirror()` | **No** (metadata only) | Sibling of live-chrome clear; same privacy class. |
| `clearHomeWidgetLiveChromeMirror()` | **Yes** (this key only) | Dedicated clear for ``homeWidgetLiveChrome``. |
| `WidgetRefreshManager.setHasActiveLutheranWidgets` **true→false edge** | **Yes** (orchestration) | Calls liveness residual clear **+** metadata mirror clear **+** live-chrome clear as three siblings. Re-asserting `false` while already closed is residual-clear **no-op** so WidgetCenter lag (`configs: 0` while widgets still exist) cannot wipe extension-stamped mirrors under widget-process bypass. Main-app write suppression while closed remains in force. |
| `removeAllLocalPlaybackKeys()` / privacy clear | **Yes** | Includes ``clearHomeWidgetLiveChromeMirror()`` with other home residuals. |
| `resetToFactoryDefaultsOnLaunch()` | **Yes** | Belt-and-suspenders residual reap. |
| Termination sync teardown (`forceStaleLivenessTimestampForTermination` path) | **Yes** | Explicit live-chrome clear (prefer clear over stale mirror + passive overlay). |
| Core security cache / DNS keys | **Never** | Untouched by home residual paths. |

**Edge semantics (must hold):**

| Transition | Residual clear (liveness + instant feedback + metadata mirror + live chrome) | Re-stamp |
|------------|-------------------------------------------------------------------------------|----------|
| true → false | **Yes** (once per edge) | — |
| false → false | **No** | — |
| false → true | **No** | **Yes** once (program metadata + live chrome) |
| true → true | **No** | **No** |

Full privacy clear, factory residual, and terminate paths clear independently of the gate edge (unchanged).

### 7.3 Privacy invariants (must hold after ship)

1. With **zero** Lutheran home/Control widgets configured, App Group must **not** retain live visual/language chrome from prior installs (gate **true→false** edge clear; cold-launch / factory / terminate still reap orphans).
2. Privacy clear removes live chrome in the same transaction as metadata, instant feedback, and liveness residuals.
3. Mirror writes never bypass `hasActiveWidgets` on the **main app** (widget-process bypass only when intent execution proves a widget/control is hosting).
4. Security keys (`lastSecurityValidation`, Core) untouched.
5. No PII beyond anonymous stream language code + presentation visual enum + optional program metadata (already separate).
6. Residual clear on ``setHasActiveLutheranWidgets`` is **edge-only** (true→false); write suppression while the gate is closed is continuous.

---

## 8. Interaction with `WidgetRefreshManager`

### 8.1 Current refresh policy (mirror shipped)

- Keep dual-path refresh and coalesce as-is **except** where a bug blocks reloads entirely.
- Every **authoritative mirror stamp** is followed by a refresh schedule path that can wake WidgetKit (event path and/or existing save path). Early sticky pause and ``setPlaying`` already emit / schedule as required.
- Providers paint from session + ``homeWidgetLiveChrome`` (``resolveHomeWidgetChromeFields``).
- `WidgetCenter.reloadTimelines` is **wake only** — it does not carry visual/language into WidgetKit.

### 8.2 PR5 — execute-time home wake discard (shipped)

**Status:** **Shipped** (2026-08-07). Optional follow-on after Implemented eyes-on; **not** required for Status → Implemented. Does **not** change Provider paint SSOT.

**Problem:** Execute-time gates were framed as “paint authority” (main-process candidate must match extension paint). After live chrome, that framing is obsolete for **paint**. Memory-lag and session-lag tables still have unique, product-critical value for **wake scheduling** and ``lastKnownState`` bookkeeping.

**Shipped simplification (smallest slice):**

| Surface | Role |
|---------|------|
| ``refreshWouldDiscardHomeWake(executing:memory:session:isImmediate:)`` | Single pure execute-time SSOT: **memory lag first**, then optional **session lag** |
| ``refreshWouldRegressMemoryAuthority`` | Memory-lag helper (residual sticky, mid-hold premature ``.playing``, post-audible Connecting) |
| ``refreshWouldRegressPersistedSnapshot`` | Session-lag helper (soft-resume reverse-race pause; directional sticky) |
| ``performRefreshIfNotStale`` | Calls the unified function; DEBUG outcomes retain leg-specific cases for triage |

**Memory- and session-lag rules are unchanged:** a home wake is discarded in the same cases as the previous sequential checks; only composition is unified. Soft-resume non-immediate Connecting, identical non-playing coalesce, dual-path ``WidgetRefreshTrigger``, and live chrome stamp/resolve paths are **unchanged**.

**Kept (not dropped in PR5):**

| Gate | Why |
|------|-----|
| Memory leg | Mid-hold premature ``.playing``; residual sticky after intentional Connecting |
| Session leg directional sticky | Soft-resume reverse race (non-immediate pause vs session ``.playing``) — memory does **not** cover this |
| Soft-resume non-immediate Connecting | Single authoritative ``.playing`` wake after gapless resume |
| Identical non-playing coalesce | Battery; attach / dual-path storms |

**Rejected (out of scope for PR5; park for later only with new evidence):**

| Idea | Why rejected as first slice |
|------|-----------------------------|
| Drop memory authority | Unique mid-hold / residual-sticky wake cases regress |
| Soften session regress “because mirror is SSOT” | More useless wakes; soft-resume reverse race returns |
| Read live chrome at execute time | New complexity, not simplification |

**Unit gates:** existing pure + integration authority tests remain green; composition covered by `testRefreshWouldDiscardHomeWakeComposesMemoryThenSession` in `WidgetRefreshManagerEventTests`.

**Eyes-on (device smoke after ship):** same required paint matrix as §10.3 / §14 plus mid-switch no playing flash and soft-resume reverse-race quiet. Trust Provider paint, not main scheduler labels (§8.3).

**Later optional slices (not shipped):** collapse helpers into one table implementation; drop proven-dead branches only with matrix proof; Event Tier 4 call-site deletion is a different roadmap item.

### 8.3 What refresh logs mean

| Log | Means |
|-----|--------|
| `Widget refresh executed … visualState: X` | Main process scheduled a reload (scheduler label) |
| Provider DEBUG `creating entry: visualState=Y` | Extension painted Y (trust this for eyes-on) |
| Success criterion | Y tracks main-app SSOT within one reload after stamp; not that X==Y in the same process |
| `Widget refresh discarded: memory lag …` / `session lag …` | Execute-time home wake discard (PR5); not Provider paint proof |

---

## 9. Soft-resume and switch honesty (must not regress)

These product rules stay **source** of what is stamped; the mirror only **projects** them.

| Scenario | Mirror content | Forbidden |
|----------|----------------|-----------|
| Soft-resume same stream | Hold prior `.userPaused` until `setPlaying` → then `.playing` | Stamping `.prePlay` “to look busy”; inventing early `.playing` before engine publish if product already skips Connecting |
| True attach / first play | `.prePlay` then `.playing` | Skipping Connecting when attach is real |
| Stream switch while playing | Destination language + `.prePlay` until setPlaying | Destination language + `.playing` mid-hold |
| Stream switch while paused | Destination language + `.userPaused` | Auto-resume or Connecting flash unless product already does |
| Sticky pause | `.userPaused` early | Lagging `.playing` left on mirror after lock |

---

## 10. Testing plan (regression + eyes-on)

Unit and integration cases below protect the shipped mirror. Device eyes-on (§10.3 / §14) **passed** 2026-08-07; Status → **Implemented**.

### 10.1 Pure / unit (no WidgetCenter IPC)

| Test | Asserts |
|------|---------|
| Gate closed suppresses main-app stamp | No key written |
| Widget-process bypass stamps | Key present |
| Decode unknown visual token → nil load | Safe absent |
| Identity skip identical chrome | No redundant write / no extra event if wired |
| Provider resolution: freshness + agreement → factory | Pure ``resolveHomeWidgetChromeFields`` table |
| Provider resolution: nil session + mirror playing | paints playing |
| Provider resolution: fresher session pause + staler mirror playing | session wins |
| Provider resolution: stale session prePlay + fresher mirror playing | **mirror wins** (fresher ``updatedAt``) |
| Clear on gate close / privacy clear / factory | Key absent |
| Soft-resume path does not stamp Connecting when skip policy true | Mirror remains userPaused until setPlaying helper |
| Switch hold stamps prePlay + dest language | Pure stamp helper |

### 10.2 Integration (existing UITestMode / seams)

- Early sticky pause → mirror userPaused before soft silence.
- setPlaying → mirror playing.
- Extension optimistic switch → mirror prePlay + dest lang; main setPlaying → mirror playing.
- Privacy clear → Provider fields factory; gate closed until re-detect.
- Gate open re-stamp once when playing with widgets added mid-session (parallel metadata test).

### 10.3 Device eyes-on matrix (manual)

Self-contained manual checklist for §14. **Do not commit device logs**; absorb failures into this design or product source using mechanism names only. Trust **Provider DEBUG** `creating entry: visualState=…` (or on-device paint), not main-process “refresh executed … visualState” scheduler labels.

**Product fact:** on cold launch the main app **auto-plays** when sticky intent allows (special tuning → stream). Validation does **not** require a silent open after install. OI-1 is **widget / App Group residual honesty** (no prior-process play resurrection), not “main stays silent after open.”

**Required sequence (passed 2026-08-07 on physical device):**

1. Install ≥1 home widget; cold-launch a **new** main process under Xcode Debug; wait until audio is playing; background the app.
2. Pause from the **home widget** (app stays backgrounded).
3. Soft-resume play from home; wait until audible (app stays backgrounded).
4. Switch stream language from home **while playing**.
5. Open the app and run **in-app privacy clear**; confirm live chrome residual is gone (home factory/defaults — not residual playing). Next open may auto-play as product.

| Step | Required? | Home chrome expectation |
|------|-----------|-------------------------|
| Cold launch with widgets (new process; product auto-plays) → background | **Required** | Brief Connecting / ``prePlay``, then home settles **playing** for **this** process without reopening the app; not stuck factory while audio is live |
| Pause from home | **Required** | First durable paint ``userPaused`` (no long residual ``playing`` flash) |
| Soft resume from home | **Required** | Settles ``playing``; no long post-audible Connecting while soft-resume same-stream is already audible |
| Switch stream while playing | **Required** | Destination flag + Connecting / ``prePlay``, then ``playing`` after attach settle — never destination + ``playing`` mid-hold |
| Privacy clear | **Required** | ``clearHomeWidgetLiveChromeMirror`` (and siblings); home factory/defaults — not residual playing |
| Residual honesty when session + live chrome absent or distrust applies | Regression | Factory ``prePlay`` / passive ``tap_to_open`` — **not** prior-process playing residual |
| Play from main (true first attach, if exercised separately from cold-launch auto-play) | Regression | Connecting then playing |
| Switch stream while paused | Optional | Destination flag + ``userPaused`` (no false auto-play / Connecting storm) |
| Remove all home/Control widgets, then re-add while main still playing | Optional | Gate true→false residual clear; false→true re-stamp of current visual |
| Force quit while playing | Optional visual residual | Passive / factory — **not** resurrected **prior-process** playing (OI-1); relaunch tracks **new** session if product auto-plays |

---

## 11. Delivery status

| Slice | Scope | Status |
|-------|--------|--------|
| **PR1** | Types + persist/load/clear + App Group SSOT row + privacy/gate clear + pure tests | **Shipped** (2026-07-30) |
| **PR2** | Main-app stamps (sticky pause, ``setPlaying``, switch hold, save projection) + gate-open re-stamp | **Shipped** (2026-07-30) |
| **PR3** | Extension optimistic stamps + Provider paint via ``resolveHomeWidgetChromeFields`` (agreement → session; disagreement → fresher ``updatedAt``) | **Shipped** (2026-07-30) |
| **PR4** | Terminate residual clear + sibling permanent docs (presentation dataflow, widget roadmap, event-driven OI-1 note, README pointer) | **Shipped** (2026-07-30) |
| **PR5 (optional)** | Unify execute-time home **wake** discard (§8.2) | **Shipped** (2026-08-07) — ``refreshWouldDiscardHomeWake``; same discard cases as prior sequential checks; **not** required for Implemented |

Required delivery for this design is **PR1–PR4 + §14 eyes-on**. PR5 is an optional follow-on (now shipped).

Do **not** mix Live Activity lock-stretch acceptance work into home live-chrome paint fixes.

---

## 12. Security impact assessment (design)

| Topic | Impact |
|-------|--------|
| Core / DNS / certificate pins | **None** — no Core touch |
| Privacy write suppression | **Preserved / strengthened** — new key is home-gated like metadata |
| Cold-launch play resurrection | **None** — clear on terminate/factory; OI-1 holds |
| Attack surface | Anonymous language code + visual enum in App Group; no PII listening history; same class as existing mirrors |
| MIE/EMTE / hardened runtime | **None** |

---

## 13. Documentation surfaces (mechanism SSOT)

Authoritative surfaces for the shipped mirror. Keep them aligned when writers, Provider order, privacy clear, or eyes-on status change. Prefer mechanism names only; never cite temporary notes or untracked paths.

| Surface | Role |
|---------|------|
| This design doc | Mechanism SSOT (keys, writers, Provider order, privacy, §10.3 eyes-on checklist, delivery status). Status → **Implemented** (2026-08-07) after §14 / required §10.3 sequence. |
| `SharedPlayerManager` App Group SSOT table | ``homeWidgetLiveChrome`` row + lifetime / clear invariants |
| ``WidgetProviderSnapshotResolver`` / related `///` | Read path via ``resolveHomeWidgetChromeFields``; SeeAlso to this design |
| [`docs/Widget-Presentation-Dataflow.md`](Widget-Presentation-Dataflow.md) | Cross-process live chrome; ``reloadTimelines`` is wake-only |
| [`docs/Widget-Functionality-Roadmap.md`](Widget-Functionality-Roadmap.md) | Freshness stack includes live chrome beside program-metadata mirror |
| [`docs/Event-Driven-Refactor-Roadmap.md`](Event-Driven-Refactor-Roadmap.md) | OI-1: memory-only **session** + privacy-gated **live projection** |
| README SSOT index | One-line pointer to this design |

| Status (2026-08-07) | Note |
|---------------------|------|
| Ship-time inventory (PR4 + polish) | **Done** — product `///` / App Group table / sibling permanent docs describe the shipped mirror |
| Eyes-on absorb | **Done** — this design Implemented; siblings that still claimed eyes-on open updated |
| Ongoing | On paint or privacy behavior change: update this design + the surfaces above **in the same change** as the code |

---

## 14. Success criteria

Design is **successfully implemented** when:

1. With home widgets installed and main app playing in background, home chrome tracks **pause / soft-resume / switch / playing** without requiring the user to open the app for a visual update.
2. Extension process cold-wake after a main-app stamp paints from **mirror**, not factory `.prePlay`, while liveness still says interactive.
3. Removing widgets or privacy clear leaves **no** live visual/language residual in App Group.
4. Force-quit / cold launch does **not** restore **prior-process** playing chrome (OI-1). Product may **auto-play** on open of a **new** process; home must track that session, not resurrect App Group residual from the previous process.
5. Stream-switch hold never shows destination `.playing` before attach settle.
6. Gates green; no Core changes; no localization keys required (visual/lang codes only).

**Eyes-on status (2026-08-07):** **Passed** on physical device using the **required sequence in §10.3** (cold-launch auto-play → background → home pause → soft resume → switch while playing → privacy residual clear). On-device home paint confirmed; main-process mechanism lines consistent (privacy-gate re-stamp, identical live-chrome identity skip, soft-resume hold of ``userPaused`` until authoritative ``playing``, switch hold ``prePlay`` + destination language, ``clearHomeWidgetLiveChromeMirror``). Prefer Provider-side `creating entry` or on-device paint over main-app refresh logs (§8.3). Optional §10.3 rows (paused switch, remove/re-add widgets, force-quit residual) were not required for this pass. PR5 wake-discard unification is separate and shipped (§8.2).

---

## 15. Decision summary

| Decision | Choice |
|----------|--------|
| Key shape | **Single JSON** `homeWidgetLiveChrome` |
| Privacy class | **Same as** `homeWidgetStreamMetadata` (home-gated) |
| Not privacy class | LA durable mirrors (leave alone) |
| Provider order | **``resolveHomeWidgetChromeFields``**: agreement → session; disagreement → fresher `updatedAt`; neither → factory (+ metadata mirror unchanged) |
| Soft-resume | Project hold; no false Connecting stamp |
| Switch | Project Connecting + dest language |
| Refresh policy | Mirror shipped; PR5 execute-time wake-discard unification shipped (optional; not required for Implemented) |
| Instant feedback | Keep for now; not primary visual SSOT |

---

## 16. Work protocol and document advancement

This file is the **committed mechanism SSOT**. Implementers may keep private scratch notes or device captures on disk; those are never committed and never cited from product source, PR bodies, or permanent docs. Useful truth is absorbed here (or into sibling permanent docs / product ``///``) using **mechanism names only**.

| Layer | Role | Git |
|-------|------|-----|
| **This design** | Mechanism SSOT (keys, writers, Provider order, privacy, success criteria, eyes-on checklist) | **Committed** — update when decisions ship or validation status changes |
| **Temporary notes / logs** | Private scratch, device captures | **Never commit**; absorb useful truth upward in mechanism language |

### When to edit this design

| Change type | Update this file? | Same change as code? |
|-------------|-------------------|----------------------|
| Ship a key, API, or Provider order | **Yes** — present tense “what ships” | **Yes** |
| Decision flip (e.g. three keys vs one blob) | **Yes** — record the new decision; drop obsolete rows | **Yes** |
| Mark slice done / validation status | **Yes** — update implementation history below | **Yes** (or docs-only when status-only) |
| All required slices + device eyes-on pass | **Yes** — Status → **Implemented** + date | Prefer dedicated docs change or last product change |
| Temporary log paths or private note filenames | **No** | — |

### Implementation history

| Slice (design §11) | Status | Ship commit / date | Mechanism note |
|--------------------|--------|--------------------|----------------|
| PR1 — types + persist/load/clear + SSOT + pure tests | **Shipped** | 2026-07-30 | ``HomeWidgetLiveChrome`` (stable visual tokens) + ``homeWidgetLiveChrome`` App Group key; ``persistHomeWidgetLiveChromeMirror`` / ``loadHomeWidgetLiveChromeMirror`` / ``clearHomeWidgetLiveChromeMirror`` / ``stampHomeWidgetLiveChromeFromSession`` (privacy gate = ``hasActiveWidgets`` \|\| ``isWidgetProcess()``); clear on gate close, ``removeAllLocalPlaybackKeys``, factory residual, ``forceStaleLivenessTimestampForTermination``; SSOT table row; pure tests. At this slice: **no** Provider read-order change yet — key may exist with no user-visible paint change. |
| PR2 — main-app stamps + gate open re-stamp | **Shipped** | 2026-07-30 | Main-app projection via ``savePersistedWidgetState`` / ``persistWidgetSnapshot`` → ``stampHomeWidgetLiveChromeFromSession`` (identity skip); sticky early pause, ``setPlaying``, switch hold (``resetToPrePlayForNewStream`` / ``saveCurrentState``), paused switch (``saveCombinedWidgetState``), ``performActualSave``; soft-resume holds prior ``.userPaused`` (no intermediate Connecting stamp); ``restampHomeWidgetLiveChromeAfterPrivacyGateOpenIfNeeded`` wired from ``setHasActiveLutheranWidgets`` false→true (peer of program-metadata re-stamp). Unit tests in ``SharedPlayerManagerMediaSurfaceTests``. At this slice: **no** Provider read-order change yet. |
| PR3 — extension optimistic + Provider resolution | **Shipped** | 2026-07-30 | Extension optimistic stamps via ``persistOptimisticWidgetSnapshot`` / ``signalWidgetSwitchAction`` → ``persistWidgetSnapshot`` → ``stampHomeWidgetLiveChromeFromSession`` (reasons ``optimisticToggle`` / ``optimisticSwitch``; widget-process bypass; identity skip). Pure planners unchanged. Provider paint via pure ``resolveHomeWidgetChromeFields``: **agreement → session; disagreement → fresher `updatedAt`** (fresher main mirror replaces stale extension-session switch-hold ``.prePlay``); neither → factory. Program metadata still session → ``homeWidgetStreamMetadata``. Liveness still owns interactive vs passive. Tests: pure WidgetSurface freshness table + extension ``WidgetDisplayModelsExtensionTests`` + main ``SharedPlayerManagerMediaSurfaceTests``. |
| PR4 — terminate clear + permanent sibling docs | **Shipped** | 2026-07-30 | Terminate residual: ``clearHomeWidgetLiveChromeMirror`` already on ``forceStaleLivenessTimestampForTermination`` (PR1; verified vs §6.3 / §7 — no residual gap). Permanent sibling docs (mechanism names only): ``docs/Widget-Presentation-Dataflow.md`` (cross-process live chrome section; Provider order; reload is wake-only; terminate clear note), ``docs/Widget-Functionality-Roadmap.md`` (freshness stack + writers table + update log), ``docs/Event-Driven-Refactor-Roadmap.md`` (OI-1 memory-only session + privacy-gated live projection), README SSOT index pointer. App Group table / resolver ``///`` already accurate after PR3 (no rewrite). No paint behavior change; no Core touch. |
| Privacy-gate residual clear true→false edge only | **Shipped** | 2026-07-30 | ``setHasActiveLutheranWidgets`` residual clear (liveness + instant feedback + ``homeWidgetStreamMetadata`` + ``homeWidgetLiveChrome``) runs only on previous-true → new-false. Re-asserting closed gate is residual no-op (WidgetCenter configs:0 lag must not wipe extension-stamped mirrors). false→true re-stamp edge unchanged. Full privacy / factory / terminate clear paths unchanged. Tests: ``testReassertingPrivacyGateClosedDoesNotClearLiveChromeOrMetadataMirrors``, ``testReassertingPrivacyGateClosedDoesNotClearLivenessOrInstantFeedbackResiduals`` + existing true→false / false→true coverage. |
| Device eyes-on (success criteria §14) | **Passed** | 2026-08-07 | Physical device; required §10.3 sequence: cold-launch auto-play → background → home pause → soft resume → switch while playing → privacy residual clear. On-device paint + main mechanism consistency (gate re-stamp, identity skip, soft-resume hold, switch ``prePlay`` + destination language, ``clearHomeWidgetLiveChromeMirror``). Docs absorb only; Status → **Implemented**. |
| PR5 — execute-time home wake discard unification | **Shipped** | 2026-08-07 | ``refreshWouldDiscardHomeWake`` composes memory lag then session lag (same discard cases as prior sequential checks; only composition unified); ``performRefreshIfNotStale`` single call site; pure helpers retained; wake-only framing in permanent docs; composition test `testRefreshWouldDiscardHomeWakeComposesMemoryThenSession`. Soft-resume Connecting deferral + identical coalesce unchanged. Not required for Implemented; do not mix with paint-blame fixes. |

### Temporary files (explicit allow / deny)

**Allow (local only):** device logs, untracked scratch notes.

**Deny:** `git add` of those paths; `SeeAlso` or README links to untracked paths; product comments that name temporary filenames or private capture labels.

**Rule of thumb:** If a future contributor needs the fact after a clean clone, it must live in **this design**, **product source**, or another **committed** permanent doc — not only in a temporary file. The §10.3 checklist and §14 success criteria are complete without external session notes.

---

**Security impact: none** (privacy-gated like ``homeWidgetStreamMetadata``; no Core touch)  
**Build status: green (PR1–PR4 product gates already green; docs-only status update)**  
**Localization needed: no**
