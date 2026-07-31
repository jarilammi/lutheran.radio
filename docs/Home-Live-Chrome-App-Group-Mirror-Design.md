# Home Live Chrome App Group Mirror — Design Spec

**Status:** Design / partial — **PR1 + PR2 + PR3 + PR4 shipped**; **session-vs-mirror freshness heal** on Provider paint (pure ``resolveHomeWidgetChromeFields``: agreement → session; disagreement → fresher `updatedAt`); **privacy-gate residual clear is true→false edge only** (re-asserting closed gate does not wipe extension-stamped mirrors). Device eyes-on success criteria (§14) remain open before Status → **Implemented**. Optional refresh simplification is PR5 (blocked on eyes-on).  
**Date:** 2026-07-30  
**Audience:** Implementers and reviewers of home/Control widget cross-process chrome  
**Canonical permanent rules:** [`CODING_AGENT.md`](../CODING_AGENT.md) (always take precedence)  

**How this document advances:** This file is the **committed mechanism SSOT**. Implementation sessions may use a **local, gitignored living brief** for cluster sequencing — that brief must never be committed or cited from product code. Temporary untracked notes and device logs are allowed locally; useful truth is absorbed into this design (mechanism language only) in the **same PR as the code** that ships each slice. See §16.

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

- No durable restore of “was playing” across process death.
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
   Mirror is **session live chrome**, not cold-launch resurrection. After process death / terminate sentinel / privacy clear, Providers show factory passive or `.prePlay` defaults.

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
| **Cold launch** | None | Key absent or ignored when process is dead / sentinel passive path |

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

## 4. API surface (proposed)

All names are mechanism-oriented. Placement (as shipped in PR1):

- Payload type + identity skip: `WidgetSurface/HomeWidgetLiveChrome.swift` (presentation-only)
- Persist / load / clear / stamp convenience: `SharedPlayerManager+Persistence.swift` (membership-exception SPM, next to program-metadata mirror)

```text
homeWidgetLiveChromeAppGroupKey: String  // "homeWidgetLiveChrome"

persistHomeWidgetLiveChromeMirror(_ chrome: HomeWidgetLiveChrome?)
  // Pre: hasActiveWidgets || isWidgetProcess()
  // Post: App Group holds JSON; no-op when gate closed (main app); nil / empty language removes key

loadHomeWidgetLiveChromeMirror() -> HomeWidgetLiveChrome?
  // Returns nil if missing / decode fail / unknown visual token / empty language

clearHomeWidgetLiveChromeMirror()
  // Gate close, privacy clear, factory residual, terminate hygiene

// Convenience writers (main app; stamp call sites land in PR2)
stampHomeWidgetLiveChromeFromSession(
  visualState: PlayerVisualState,
  language: String,
  hasError: Bool,
  reason: String?
)
  // Builds chrome + updatedAt = now; calls persist if gate open

// Identity skip (pure; WidgetSurface)
shouldSkipIdenticalHomeWidgetLiveChromeWrite(
  existing: HomeWidgetLiveChrome?,
  candidate: HomeWidgetLiveChrome
) -> Bool
  // Skip when visual + language + hasError match (ignore stampReason / updatedAt)
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

### 6.1 Target algorithm (`WidgetProviderSnapshotResolver.resolveFromSnapshot`)

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
//  5. Session missing updatedAt treated as older than any stamped mirror (heal residual)

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
| Extension **warm** after main settle | Stale optimistic (e.g. switch-hold ``.prePlay``) | Newer main ``.playing`` / sticky pause | **Fresher `updatedAt` wins** (P0 heal) |
| Extension cold wake after terminate | nil | Should be **cleared** → factory / passive | Factory / passive |

Rigid session-first left home yellow Connecting when extension session held switch-hold ``.prePlay`` while main had already stamped a newer ``homeWidgetLiveChrome`` ``.playing``. Freshness comparison preserves same-process optimistic continuity (agree → session; fresher session pause still beats staler residual playing mirror) while allowing main settle to heal stale extension session.

### 6.3 Passive / termination interaction

| Condition | Provider behavior |
|-----------|-------------------|
| `lastUpdateTime == 0` (termination sentinel) or liveness aged out | Existing passive `tap_to_open` via `WidgetLivenessPresentation` — **do not** treat live chrome as interactive proof of a live app |
| Live chrome present but process dead | Liveness still wins for **interactive vs passive** chrome; mirror may be cleared on terminate path (recommended) so passive path does not flash last playing glyph |
| No live chrome, no session | `.prePlay` + `preferredWidgetLanguage()` |

**Recommended terminate hygiene:** `forceStaleLivenessTimestampForTermination` / sync termination teardown also `clearHomeWidgetLiveChromeMirror()` (with metadata residual policy already in place). Prefer explicit clear over “stale mirror + passive overlay” so passive UI cannot briefly show pause/play of a dead process before liveness check.

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

| Helper | Must include live chrome clear? |
|--------|----------------------------------|
| `clearHomeWidgetLivenessAndInstantFeedbackResiduals()` | **Yes** — rename or extend docs to “home residual clear”; include live chrome + metadata (metadata already paired on gate close) |
| `removeAllLocalPlaybackKeys()` / privacy clear | **Yes** |
| `WidgetRefreshManager` gate **true→false edge only** | **Yes** (same site as metadata / liveness residual clear). Re-asserting `false` while already closed is a residual-clear **no-op** so WidgetCenter lag (`configs: 0` while widgets still exist) cannot wipe extension-stamped live chrome / metadata under widget-process bypass. Main-app write suppression while closed remains in force. |
| `resetToFactoryDefaultsOnLaunch()` | **Yes** (belt-and-suspenders) |
| Termination sync teardown | **Yes** (recommended) |
| Core security cache / DNS keys | **Never** |

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

### 8.1 Phase 1 (ship mirror; freeze further authority layers)

- Keep existing refresh dual-path and coalesce as-is **except** where a bug blocks reloads entirely.
- Ensure every **authoritative mirror stamp** is followed by a refresh schedule path that can wake WidgetKit (event path and/or existing save path). Early sticky pause already aims at this; setPlaying already emits.
- **Do not** add more execute-time memory-authority cases until Providers paint from the mirror.

### 8.2 Phase 2 (optional simplification — separate PR)

After device eyes-on proves paint:

| Candidate simplification | Condition |
|--------------------------|-----------|
| Drop or narrow `refreshWouldRegressMemoryAuthority` | Provider no longer depends on main-process candidate visual matching extension paint |
| Soften directional disk regress | “Disk” session lag is less critical if mirror is the extension SSOT |
| Keep soft-resume non-immediate Connecting | Still valuable for **not scheduling** useless Connecting reloads when soft-resume will setPlaying soon |
| Keep identical non-playing coalesce | Battery; still valid |

Phase 2 is optional and must not ship in the same PR as the mirror if it clouds regression blame.

### 8.3 What refresh logs mean after ship

| Log | Means |
|-----|--------|
| `Widget refresh executed … visualState: X` | Main process scheduled a reload (scheduler label) |
| Provider DEBUG `creating entry: visualState=Y` | Extension painted Y (trust this for eyes-on) |
| Success criterion | Y tracks main-app SSOT within one reload after stamp; not that X==Y in the same process |

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

## 10. Testing plan (when implementing)

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
| Provider resolution: stale session prePlay + fresher mirror playing | **mirror wins** (P0 heal) |
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

Manual checklist for §14 success criteria. **Do not commit device logs**; absorb failures into this design or product source using mechanism names only. Trust **Provider DEBUG** `creating entry: visualState=…` (or on-device paint), not main-process “refresh executed … visualState” scheduler labels.

| Step | Home chrome expectation |
|------|-------------------------|
| Cold launch, widgets installed, not playing | prePlay / tap affordance |
| Play from main | Connecting then playing (true attach) |
| Pause from home | First durable paint paused (no long playing flash) |
| Soft resume from home | No long post-audible Connecting; settles playing |
| Switch stream while playing | Dest flag + Connecting, then playing |
| Switch while paused | Dest flag + paused |
| Remove all widgets | Residual clear; re-add shows honest defaults then re-stamp if playing |
| Privacy clear | Factory / en default per product |
| Force quit while playing | Passive / factory — **not** resurrected playing (OI-1) |

---

## 11. Implementation plan (suggested PR stack)

| PR | Scope | Risk |
|----|-------|------|
| **PR1** | Types + persist/load/clear + SSOT table + privacy/gate clear wiring + pure tests | Low — no paint change yet if Provider not switched |
| **PR2** | Main-app stamp call sites (sticky, setPlaying, switch, save projection) + gate open re-stamp | Medium — write volume; identity skip |
| **PR3** | Extension optimistic stamp + Provider resolution order | Medium — user-visible |
| **PR4** | Terminate clear + dataflow/roadmap/README mechanism docs | Low |
| **PR5 (optional later)** | Simplify refresh authority layers | Medium — only after device proof |

Do **not** mix LA lock-stretch acceptance work into PR1–4.

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

## 13. Documentation updates required at ship time

| Surface | Update |
|---------|--------|
| `SharedPlayerManager.swift` App Group table | New row + invariants |
| `WidgetDisplayModels.swift` / resolver `///` | Read order + SeeAlso |
| `docs/Widget-Presentation-Dataflow.md` | Cross-process live chrome section; correct “reload alone carries paint” implication |
| `docs/Widget-Functionality-Roadmap.md` | Freshness stack lists live chrome mirror |
| `docs/Event-Driven-Refactor-Roadmap.md` | OI-1 note: memory-only **session** + privacy-gated **live projection** for extension paint |
| README SSOT index | One-line pointer |
| This design doc | Mark **Implemented** + date + commit when done |

Do **not** cite local living prompts in product comments or permanent docs.

---

## 14. Success criteria

Design is **successfully implemented** when:

1. With home widgets installed and main app playing in background, home chrome tracks **pause / soft-resume / switch / playing** without requiring the user to open the app for “heal.”
2. Extension process cold-wake after a main-app stamp paints from **mirror**, not factory `.prePlay`, while liveness still says interactive.
3. Removing widgets or privacy clear leaves **no** live visual/language residual in App Group.
4. Force-quit / cold launch does **not** restore playing chrome (OI-1).
5. Stream-switch hold never shows destination `.playing` before attach settle.
6. Gates green; no Core changes; no localization keys required (visual/lang codes only).

**Eyes-on status (2026-07-30):** Not started. PR3 paint path + PR4 permanent docs are on disk; run the §10.3 matrix on a physical device (or interactive simulator with real WidgetKit) before flipping Status → **Implemented**. Prefer Provider-side paint evidence over main-app refresh logs (§8.3).

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
| Refresh policy | Ship mirror first; optional later simplify |
| Instant feedback | Keep for now; not primary visual SSOT |

---

## 16. Work protocol and document advancement

Implementation is **not** tracked by cluster IDs in this file. Session sequencing may live in a **local gitignored living brief** on the implementer’s machine. That brief is never committed and never cited from product source, PR bodies, or permanent docs.

| Layer | Role | Git |
|-------|------|-----|
| **This design** | Mechanism SSOT (keys, writers, Provider order, privacy, success criteria) | **Committed** — update when decisions ship |
| **Local living brief** | One-cluster sessions, status board, device-log absorb | **Never commit** |
| **Temporary notes / logs** | Scratch, captures | **Never commit**; absorb useful truth upward |

### When to edit this design

| Change type | Update this file? | Same PR as code? |
|-------------|-------------------|------------------|
| Ship a key, API, or Provider order | **Yes** — present tense “what ships” | **Yes** |
| Decision flip (e.g. three keys vs one blob) | **Yes** — record the new decision; drop obsolete rows | **Yes** |
| Mark slice done | **Yes** — fill implementation progress below | **Yes** |
| All required slices + device eyes-on pass | **Yes** — Status → **Implemented** + date | Prefer dedicated docs commit or last PR |
| Session cluster open/close theater | **No** | — |
| Temporary log paths or living-brief names | **No** | — |

### Implementation progress (fill as PRs land)

| Slice (design §11) | Status | Ship commit / date | Mechanism note |
|--------------------|--------|--------------------|----------------|
| PR1 — types + persist/load/clear + SSOT + pure tests | **Shipped** (partial product) | 2026-07-30 | ``HomeWidgetLiveChrome`` (stable visual tokens) + ``homeWidgetLiveChrome`` App Group key; ``persistHomeWidgetLiveChromeMirror`` / ``loadHomeWidgetLiveChromeMirror`` / ``clearHomeWidgetLiveChromeMirror`` / ``stampHomeWidgetLiveChromeFromSession`` (privacy gate = ``hasActiveWidgets`` \|\| ``isWidgetProcess()``); clear on gate close, ``removeAllLocalPlaybackKeys``, factory residual, ``forceStaleLivenessTimestampForTermination``; SSOT table row; pure tests. **No** Provider read-order change yet — key may exist with no user-visible paint change. |
| PR2 — main-app stamps + gate open re-stamp | **Shipped** (partial product) | 2026-07-30 | Main-app projection via ``savePersistedWidgetState`` / ``persistWidgetSnapshot`` → ``stampHomeWidgetLiveChromeFromSession`` (identity skip); sticky early pause, ``setPlaying``, switch hold (``resetToPrePlayForNewStream`` / ``saveCurrentState``), paused switch (``saveCombinedWidgetState``), ``performActualSave``; soft-resume holds prior ``.userPaused`` (no intermediate Connecting stamp); ``restampHomeWidgetLiveChromeAfterPrivacyGateOpenIfNeeded`` wired from ``setHasActiveLutheranWidgets`` false→true (peer of program-metadata re-stamp). Unit tests in ``SharedPlayerManagerMediaSurfaceTests``. **No** Provider read-order change yet. |
| PR3 — extension optimistic + Provider resolution | **Shipped** (partial product — paint path on; freshness heal added; device eyes-on still open) | 2026-07-30 | Extension optimistic stamps via ``persistOptimisticWidgetSnapshot`` / ``signalWidgetSwitchAction`` → ``persistWidgetSnapshot`` → ``stampHomeWidgetLiveChromeFromSession`` (reasons ``optimisticToggle`` / ``optimisticSwitch``; widget-process bypass; identity skip). Pure planners unchanged. Provider paint via pure ``resolveHomeWidgetChromeFields``: **agreement → session; disagreement → fresher `updatedAt`** (heals stale extension-session switch-hold ``.prePlay`` when main stamped newer ``.playing``); neither → factory. Program metadata still session → ``homeWidgetStreamMetadata``. Liveness still owns interactive vs passive. Tests: pure WidgetSurface freshness table + extension ``WidgetDisplayModelsExtensionTests`` + main ``SharedPlayerManagerMediaSurfaceTests``. Status remains design/partial until §14 device eyes-on. |
| PR4 — terminate clear + permanent sibling docs | **Shipped** | 2026-07-30 | Terminate residual: ``clearHomeWidgetLiveChromeMirror`` already on ``forceStaleLivenessTimestampForTermination`` (PR1; verified vs §6.3 / §7 — no residual gap). Permanent sibling docs (mechanism names only): ``docs/Widget-Presentation-Dataflow.md`` (cross-process live chrome section; Provider order; reload is wake-only; terminate clear note), ``docs/Widget-Functionality-Roadmap.md`` (freshness stack + writers table + update log), ``docs/Event-Driven-Refactor-Roadmap.md`` (OI-1 memory-only session + privacy-gated live projection), README SSOT index pointer. App Group table / resolver ``///`` already accurate after PR3 (no rewrite). No paint behavior change; no Core touch. |
| Privacy-gate residual clear true→false edge only | **Shipped** | 2026-07-30 | ``setHasActiveLutheranWidgets`` residual clear (liveness + instant feedback + ``homeWidgetStreamMetadata`` + ``homeWidgetLiveChrome``) runs only on previous-true → new-false. Re-asserting closed gate is residual no-op (WidgetCenter configs:0 lag must not wipe extension-stamped mirrors). false→true re-stamp edge unchanged. Full privacy / factory / terminate clear paths unchanged. Tests: ``testReassertingPrivacyGateClosedDoesNotClearLiveChromeOrMetadataMirrors``, ``testReassertingPrivacyGateClosedDoesNotClearLivenessOrInstantFeedbackResiduals`` + existing true→false / false→true coverage. |
| Device eyes-on (success criteria §14) | Not started | — | Paint path + permanent docs + edge residual clear shipped; run §10.3 manual matrix before Status → Implemented |
| PR5 — optional refresh simplification | Blocked on eyes-on | — | Only after §14 paint proof; do not mix with mirror blame |

### Temporary files (explicit allow / deny)

**Allow (local only):** device logs, untracked scratch notes, local living brief.

**Deny:** `git add` of those paths; `SeeAlso` or README links to untracked paths; product comments that name living briefs or session filenames.

**Rule of thumb:** If a future contributor needs the fact after a clean clone, it must live in **this design**, **product source**, or another **committed** permanent doc — not only in a temporary file.

---

**Security impact: none** (privacy-gated like ``homeWidgetStreamMetadata``; no Core touch)  
**Build status: green when PR1–PR4 gates pass**  
**Localization needed: no**
