//
//  RadioLiveActivityManager.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 13.6.2025.
//
//  Privacy-first Live Activities - NO push notifications needed
//

@unsafe @preconcurrency import ActivityKit
import Foundation
import os      // OSAllocatedUnfairLock for termination-path ActivityKit end wait
import UIKit   // For UIApplication.willTerminateNotification (termination observer) and related lifecycle.
import WidgetSurface

/// `RadioLiveActivityManager` owns the lifecycle and push surface for privacy-first
/// local-only Live Activities (Dynamic Island + Lock Screen) using ActivityKit.
/// On Designed-for-iPhone Mac (`isiOSAppOnMac`) ActivityKit is unavailable —
/// ``areActivitiesEnabledOnThisHost`` is false and start/observe/update/ensure no-op.
///
/// ## Purpose and Ownership
/// Manages creation, `ContentState` pushes (via `update(using:)`), and termination
/// of `Activity<LutheranRadioLiveActivityAttributes>`. All pushes are driven from
/// the main-app process only. Widget/App Intent processes mutate state via
/// `SharedPlayerManager` facades; only the main process owns the Activity reference.
///
/// ## Single Source of Truth Contract
/// - Widget and relaunch presentation use `PersistedWidgetState` exclusively
///   (see `loadPersistedWidgetState`, `savePersistedWidgetState`).
/// - Live Activity transient UI is derived from in-memory `SharedPlayerManager`
///   (`currentVisualState` + `currentStreamMetadata`) plus
///   ``SharedPlayerManager/liveActivityLanguageCodeForContentPush()`` (stream attach,
///   or destination language while a stream-switch Connecting hold is active).
/// - `ContentState.currentLanguage` is the language-chrome SSOT on Lock Screen / Dynamic
///   Island; views must not re-derive via privacy-gated ``preferredWidgetLanguage()``.
/// - Durable App Group mirrors (visual + language) warm extension-hosted intent paths
///   and are **not** gated by home-widget ``hasActiveWidgets``.
/// - `PersistedWidgetState` is never bypassed for widgets.
///
/// ## Event-Driven Model (Primary) + Live Activity Attribute Events
/// Updates are reactive to player-domain mutations (visual transitions, ICY
/// `metadataDidUpdate`, lifecycle). The 30 s fallback timer is demoted and not
/// started on normal paths.
///
/// In addition, the manager consumes the Live Activity attribute events
/// stream (`contentUpdates` yielding `ActivityContent<ContentState>`). On
/// yield we align `lastPushedContent` (for stronger diff-driven suppression).
/// Stream termination triggers local self-healing hygiene. Process exit and
/// cold-launch residual reaping are handled by ``handleAppWillTerminate()``
/// and ``observeExistingActivities()`` respectively.
///
/// See the implementation of ``beginObservingActivityEvents(_:)`` and the
/// "Live Activity Attribute Events Observation" section in
/// docs/Widget-Presentation-Dataflow.md. The concrete loop is now the
/// reference implementation inside the shared `WidgetEventObserver`.
///
/// ## Update Invariant
/// `Activity.update(...)` occurs **iff** the candidate is not suppressible under
/// ``shouldSuppressLiveActivityContentPush(lastPushed:candidate:ownedContentLanguage:)``
/// (or force/initial), is not a same-stream ineligible Connecting overwrite of owned
/// paused/playing (``shouldSuppressConnectingContentPushWhileIneligible``), **and** is
/// not coalesced as a second visual mutation while ``inFlightContentPushCandidate`` is
/// unconfirmed. Suppress is an **optimization**, not a source of truth: owned
/// `Activity.content.state.currentLanguage` beats optimistic / aspirational
/// ``lastPushedContent`` — never skip a push when the candidate language is non-empty
/// and differs from the surface the system still holds.
///
/// ## One outstanding visual mutation
/// `Activity.update` apply is asynchronous. Soft-ensure / dual-axis must not issue a
/// second visual-differing IPC while the prior apply is unconfirmed — that burns the
/// lock-stretch apply budget (later glyph changes drop; same-visual language updates
/// can still land). While ``inFlightContentPushCandidate`` is non-nil, a candidate
/// whose visual differs — or a duplicate unconfirmed visual — is remembered as
/// ``pendingCoalescedContentPushCandidate`` (replace, do not queue) and does **not**
/// call `Activity.update`. After delayed re-read, `contentUpdates`, or an immediate
/// post-await match, if the coalesced candidate still differs from observed, push
/// **once**. Pause (``.userPaused``) replacing playing-ensure in-flight is a true
/// visual mutation: latest wins so pause remains the outstanding candidate. Language-only
/// candidates (visual matches in-flight **and** owned visual) still update. Soft-ensure
/// attempt counters still bound the loop; this is IPC coalesce, not a new ensure rail.
/// Does **not** invent `.playing`. Does **not** end while ineligible.
///
/// ## Same-stream ineligible resume must not spend an apply on Connecting
/// While interactive request is ineligible, ``updateCurrentActivity()`` must not
/// `Activity.update` Connecting (``.prePlay``) over owned ``.userPaused`` / ``.playing``.
/// That overwrite is the last visual apply Apple still accepted on same-stream
/// play-after-pause under lock; later `.playing` mutations then dropped. Stream-switch
/// hold still publishes Connecting + destination language. First start (owned already
/// ``.prePlay``) and request-eligible (presentable) still publish Connecting. Does
/// **not** invent `.playing` during attach. Durable mirrors may still warm Connecting
/// for extension planning — owned lock-screen glyph is the thing we must not overwrite.
///
/// Intent-path optimistic toggles publish ContentState and align ``lastPushedContent``
/// so a rapid second tap resolves from the post-toggle glyph; the sequential sticky
/// lock / soft-silence path then converges actor state. Stream-switch optimistic
/// language alignment may advance ``lastPushedContent`` before system acceptance;
/// the owned-language gate + ``ensureAuthoritativeLanguageContentIfNeeded()`` keep
/// lock-screen flag/name on the destination until `content.state` matches.
///
/// ## Interactive recreation after stalled ActivityKit updates
/// Soft retries cannot repair an interactive activity whose system-held
/// `content.state` never advances (language stuck on a prior stream, or visual stuck
/// on `.userPaused` / `.prePlay` after soft resume or audible start while audio is
/// already playing). `Activity.update` apply is **asynchronous**: the immediate
/// `content.state` re-read after `await update` is apply-in-flight, not stall truth.
/// Stall / quiet / recreation bookkeeping wait for ``handleActivityContentUpdate``
/// (`contentUpdates`) or a delayed re-read past ``contentPushApplyConfirmationDelayMilliseconds``.
/// Both observation kinds run ``applySystemContentUpdateHeal`` with prior
/// ``lastSystemHeldContent`` (language-new coarsen). Immediate post-await does not.
/// Pause↔Connecting and Connecting↔playing after hold/connect clear are handshake lag
/// and do **not** consume ``stalledContentPushRecreationThreshold``. After a bounded
/// streak of **committed** stalls that leave system-held ContentState lagging, the
/// manager may end the frozen surface and ``startActivity()`` a replacement seeded from
/// current language chrome + visual — **only when an interactive `Activity.request` is
/// eligible** (Live Activities enabled and the application is active). `Activity.request`
/// visibility is start/recreate only; ``startActivity()`` itself consults
/// ``interactiveLiveActivityStartDisposition`` (owned → ``updateCurrentActivity()`` only,
/// never end+request; eligible + unowned → request after ``.immediate`` residual end;
/// ineligible + unowned → pending ensure, no request, no leading end).
/// When request is ineligible (lock screen / background **visibility** constraints),
/// the existing interactive activity is **kept** and a pending ensure is recorded so
/// the next foreground cycle can start or re-bind. Recreation is capped so thrashing
/// is impossible.
/// **Invariant:** never destroy the only interactive Live Activity unless a replacement
/// can be requested or a recoverable pending ensure is guaranteed. Never invent
/// `.playing` during stream-switch hold.
/// Soft-resume / post-audible **visual** honesty prefers bounded
/// ``ensureAuthoritativePlayingContentIfNeeded()`` retries — not end+request — when the
/// only lag is owned `.prePlay` vs candidate `.playing`.
/// Language chrome prefers bounded ``ensureAuthoritativeLanguageContentIfNeeded()`` retries.
/// After the soft-retry budget is exhausted while interactive request is ineligible, language
/// ensure enters a **quiet pending** state for that destination so status-driven media-surface
/// refreshes do not thrash ActivityKit; re-arm on destination change, eligibility, become-active,
/// or system `contentUpdates`. Language-only status re-pushes defer while quiet; visual mutations
/// still push. **Settled language acceptance:** after stream-switch hold clears (authoritative
/// ``setPlaying`` / soft-resume audible path), ``pushSettledLanguageAcceptanceContentIfNeeded()``
/// clears language quiet and re-runs a **full** soft language-ensure budget for the destination
/// (attach-storm exhaustion must not be the only acceptance window). Consume-once per destination
/// while request stays ineligible prevents soft-resume no-op thrash of the settle entry; re-arm
/// consume on destination change, eligibility, become-active, or `contentUpdates`. When owned
/// language still lags after that post-audible soft cycle while request is ineligible, status-driven
/// thrash re-enters quiet **and** bounded delayed post-settled language ensure retries re-clear quiet
/// on a longer cadence — never end+request while ineligible.
/// **Settled playing acceptance:** peer for owned visual — after hold/connect clear while the
/// actor is authoritative `.playing` and owned visual still lags (``.prePlay`` / ``.userPaused``),
/// ``pushSettledPlayingAcceptanceContentIfNeeded()`` clears playing quiet and re-runs a **full**
/// soft playing-ensure budget (not a single dual-axis push alone) even when quiet was engaged
/// after attach-storm / prior soft-resume exhaustion. Consume-once while ineligible stops
/// soft-resume no-op thrash of the settle entry; re-open consume on optimistic toggle /
/// stream-switch, eligibility, become-active, or `contentUpdates`. When owned visual still lags
/// after that post-audible soft cycle while request is ineligible, status-driven thrash re-enters
/// quiet **and** bounded delayed post-settled playing ensure retries re-clear quiet on a longer
/// cadence — never end+request while ineligible. Does **not** invent `.playing` during hold/connect.
/// Playing ensure has the same quiet-pending shape (``playingEnsureQuietPending``): after
/// ``authoritativePlayingContentEnsureMaxAttempts`` without owned `.playing` while request is
/// ineligible, visual-only status re-pushes that only repair `.playing` defer; pause
/// (``.userPaused``) and language mutations still push. Re-arm playing quiet on authoritative
/// play mutation, optimistic toggle / stream-switch, eligibility, become-active, delayed
/// post-settled playing ensure, or **axis-converged** `contentUpdates` (partial acceptance is
/// not a full heal). On foreground / become-active with an
/// **owned** activity, soft language + playing ensure run via
/// ``ensureAuthoritativeContentOnForegroundIfNeeded()`` (clears both quiet flags and
/// settled-acceptance consume markers first); dual SceneDelegate hooks are debounced for the
/// owned-surface path while still **consuming** language/playing quiet and
/// ``pendingInteractiveLiveActivityEnsure`` on unlock (and allowing a second pass when chrome
/// still lags after a first ineligible pass). Eligible-only recreation is a last resort after
/// soft ensure still fails (never while request is ineligible). ActivityKit may still delay
/// applying language/visual until the process is presentable; the foreground owned-surface rail
/// remains the presentable safety rail, not the only allowed mid-lock path. Some ineligible
/// pushes may still lag; this does **not** claim a lock-screen paint guarantee.
///
/// ## Post-quiet sparse long-horizon ensure (continuous-lock acceptance rail)
/// Soft ensure + post-settled delayed retries (400/1000/2000 ms) correctly stop status thrash
/// after budget exhaustion while request is ineligible — but treating that quiet as **terminal**
/// freezes residual lag for the rest of a continuous-lock stretch even though ActivityKit can
/// still accept later without unlock. After language and/or playing quiet engage (or settled
/// acceptance / partial-axis heal still leaves an axis lagging), ``armPostQuietLongHorizonPlayingEnsureIfNeeded()``
/// / language peer / dual-axis peer schedule **sparse** delayed re-arms on
/// ``postQuietLongHorizonEnsureDelayedIntervalsMilliseconds`` (5 s / 15 s / 45 s, max three fires
/// per freeze generation). Each fire clears quiet once for the lagging axis (or **both** when
/// dual-axis still owns the freeze). Dual-axis settle at ``setPlaying()`` after hold
/// clear remains the first co-push. After freeze soft budget exhausts or playing quiet
/// is pending while request is ineligible, post-quiet language long-horizon stays
/// **language-only** (``ContentState/replacingCurrentLanguage(_:)`` preserves owned
/// visual; do not force `.playing`). Playing long-horizon remains the visual rail
/// (one outstanding visual mutation still coalesces). Unlock-heal remains the
/// presentable visual repair. Before that freeze, when **both** axes lag while the
/// actor is authoritative `.playing` without hold/connect, the dual-axis rail owns
/// recovery: **one** ``ensureAuthoritativeDualAxisContentIfNeeded()`` per fire
/// (destination language **and** playing visual together) — not two independent short
/// single-axis budgets that each re-quiet in the same turn. Single-axis rails arm only
/// when the other axis already matches, or after freeze when dual-axis long-horizon
/// is skipped. Cancelled on ownership end, owned acceptance, actor leaving
/// authoritative play, UITestMode / test sanitization, optimistic mutation / settle restart,
/// destination advance (language/dual re-arm for the new destination), and foreground owned-surface
/// ensure (presentable cycle owns recovery). After dual-axis long-horizon exhausts without
/// acceptance, ``postQuietLongHorizonDualAxisExhausted`` keeps become-active / eligible recreation
/// pending — never end the only interactive LA solely for lag while request ineligible. Does **not**
/// thrash on every status/ICY tick; does **not** invent `.playing` during hold/connect. Short soft
/// ensure + post-settled remain; long-horizon is **additional**, not a replacement.
///
/// ## Settled dual-axis acceptance (prePlay → playing after stream attach)
/// After stream-switch hold clears, owned ContentState can stick on Connecting (``.prePlay``)
/// while the actor is already authoritative `.playing` (and destination language may also lag).
/// Sequential language-only then playing-only soft budgets often re-quiet without co-pushing both
/// axes. ``pushSettledDualAxisAcceptanceContentIfNeeded()`` runs when owned visual is ``.prePlay``,
/// the actor is `.playing`, hold/connect are clear, and destination language is known: clears both
/// quiets once and runs ``ensureAuthoritativeDualAxisContentIfNeeded()`` so one soft path carries
/// destination language **and** playing visual together. Does **not** invent `.playing` during
/// hold/connect. Soft-resume from ``.userPaused`` still uses the single-axis settled playing rail.
///
/// ## Partial-acceptance dual-axis heal
/// System `contentUpdates` **and** delayed re-read after ``contentPushApplyConfirmationDelayMilliseconds``
/// can advance **one** ContentState axis while the other still lags (device: destination language
/// accepted with Connecting visual, or playing visual accepted with prior language). Immediate
/// post-await `content.state` is apply-in-flight and does **not** axis-heal. Treat committed
/// progress as progress, not full heal: clear quiet / cancel post-settled / reset stall streak
/// **only for converged axes**; re-arm the lagging axis (quiet clear + delayed soft ensure) so
/// language acceptance cannot freeze playing repair (and the reverse) even when `contentUpdates`
/// is silent under lock. Soft-ensure inter-attempt spacing is longer while request is
/// ineligible so ActivityKit has an apply window without raising attempt count.
///
/// ## Soft-ensure thrash protection (concurrent collapse + deferred announce-once)
/// Status-driven media-surface refreshes and dual soft-ensure call sites can re-enter
/// ``ensureAuthoritativeLanguageContentIfNeeded()`` / ``ensureAuthoritativePlayingContentIfNeeded()``
/// while a soft-push loop is already in flight. In-flight guards collapse those concurrent
/// entries so parallel attempt counters do not thrash ActivityKit. When stalled-push
/// bookkeeping would recreate but request is ineligible, ``pendingInteractiveLiveActivityEnsure``
/// is recorded **once** for that freeze (announce-once deferred recreation); subsequent
/// identical stalls stay quiet until re-arm. DEBUG stall diagnostics for identical
/// candidate/owned language+visual pairs are rate-limited the same way. Imperative
/// ``updateCurrentActivity()`` on true mutations (setPlaying, stop, metadata, switch) is
/// unchanged.
///
/// ## Continuous-lock ensure thrash smart-loosen (freeze generation + partial coarsen)
/// Soft ensure, post-settled, partial re-arm, and long-horizon rails remain available, but under
/// continuous lock they must not independently clear quiet and re-burn ActivityKit after every
/// failed push. **Freeze-generation soft budget:** after a soft ensure cycle exhausts while
/// request is ineligible, mark the freeze soft budget exhausted and keep quiet as cool-down
/// until mutation, eligibility / become-active, or sparse long-horizon — not every partial
/// re-arm. **Partial re-arm coarsen:** ``shouldRearmPlayingEnsureAfterPartialLanguageAcceptance``
/// requires language **newly** converged this update (``didLanguageNewlyConverge``); same-stream
/// visual stall (language already matched before the push) must not clear quiet, schedule
/// post-settled, or re-arm long-horizon. True language-new wins get **one** delayed post-settled
/// visual follow-through per freeze generation. Nested post-settled after soft-budget exhaust
/// while ineligible is skipped for same-stream stalls (long-horizon owns residual). Eligible
/// presentable cycles still soft-ensure fully; after freeze soft-budget and/or dual-axis
/// long-horizon exhaust, become-active prefers eligible recreation when soft ensure still lags
/// — **never** end only interactive LA solely for lag while request ineligible. Does **not**
/// claim full ActivityKit continuous-lock paint guarantee.
///
/// ## Test Isolation
/// All real Activity creation/update/timer paths are short-circuited under
/// `isRunningUnderTest` (and the UITestMode SSOT) so that `xcodebuild test`
/// remains fast. See guards in `startActivity`, `updateCurrentActivity`,
/// `observeExistingActivities`.
///
/// - SeeAlso: `SharedPlayerManager` (source of visual/metadata + emitter of
///   `PlayerEvent`), `LutheranRadioLiveActivityAttributes.ContentState`,
///   `PlayerVisualState`, `StreamProgramMetadata`,
///   `LutheranRadioWidgetLiveActivity.swift`,
///   `WidgetEventObserver`,
///   docs/Widget-Presentation-Dataflow.md (Live Activity Event-Driven + new
///   events observation section),
///   docs/Event-Driven-Refactor-Roadmap.md (Tier 2 LA events item),
///   CODING_AGENT.md (Single Source of Truth Principles, cross-target shared
///   files, Documentation & Comment Standards),
///   <doc:Architecture>, RadioLiveActivityManagerTests.
@MainActor
class RadioLiveActivityManager: ObservableObject {
    static let shared = RadioLiveActivityManager()

    /// Whether ActivityKit Live Activities are available on this process host.
    ///
    /// On Designed for iPhone / iPad Mac (`ProcessInfo.processInfo.isiOSAppOnMac`),
    /// ActivityKit authorization and output services do not exist. Constructing
    /// `ActivityAuthorizationInfo` or reading `Activity.activities` logs connection
    /// failures. Report disabled without calling ActivityKit.
    ///
    /// This is not a privacy, security, or `PlayerEvent` bypass. It only avoids
    /// unavailable system IPC. Hardware Live Activity chrome is an iPhone / iPad surface.
    ///
    /// - Returns: `false` when ``SharedPlayerManager/isRunningAsIOSAppOnMac``; otherwise
    ///   the system `ActivityAuthorizationInfo` enabled flag.
    /// - SeeAlso: ``startActivity()``, ``observeExistingActivities()``,
    ///   ``SharedPlayerManager/isRunningAsIOSAppOnMac``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    nonisolated static var areActivitiesEnabledOnThisHost: Bool {
        if SharedPlayerManager.isRunningAsIOSAppOnMac {
            return false
        }
        return ActivityAuthorizationInfo().areActivitiesEnabled
    }
    
    @Published var currentActivity: Activity<LutheranRadioLiveActivityAttributes>?

    /// The (now rarely used) repeating local timer.
    ///
    /// - Important: This is intentionally `internal private(set)` as the
    ///   designated testing seam (see `startLocalUpdateTimer` / `stopLocalUpdateTimer`).
    ///   Tests use `@testable` to observe timer creation, validity, and cleanup
    ///   directly. Production code must never read or write this directly.
    ///
    /// - Note: Primary Live Activity updates are event-driven. This timer exists only
    ///   as an explicit fallback and is not started by the normal start/observe paths.
    /// - SeeAlso: ``RadioLiveActivityManager/startLocalUpdateTimer()``,
    ///   ``RadioLiveActivityManager/stopLocalUpdateTimer()``,
    ///   RadioLiveActivityManagerTests
    internal private(set) var updateTimer: Timer?

    /// In-process suppress memory for Live Activity content pushes.
    ///
    /// Purely in-memory (main-app process only). Used to implement the
    /// "push only when rendered content would actually change" rule — an
    /// **optimization**, not proof that the on-screen activity holds this state.
    ///
    /// - Lifecycle: Cleared in `endActivity` and on termination paths.
    /// - Update Invariant: Compared with the freshly derived candidate before
    ///   every `Activity.update`, **subject to** the owned-content language gate
    ///   (``shouldSuppressLiveActivityContentPush``). Equality uses `ContentState`'s
    ///   `Hashable`/`Equatable` (visualState + streamMetadata + currentLanguage).
    /// - After a real `Activity.update`, memory is re-seeded from the activity’s
    ///   `content.state` (system-observed), not from an unverified aspirational candidate.
    /// - Optimistic intent paths may advance this without system acceptance; suppress
    ///   still forces a push when `currentActivity?.content.state.currentLanguage`
    ///   differs from the candidate language.
    /// - Never persisted as a snapshot. Widgets continue to use `PersistedWidgetState`.
    ///   Durable LA visual/language App Group mirrors are separate cross-process signals.
    ///
    /// Exposed as `internal private(set)` for white-box testing of the change-detection
    /// behavior (parallel to `updateTimer`).
    /// - SeeAlso: ``updateCurrentActivity()``, ``ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``handleActivityContentUpdate(_:)``, docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    internal private(set) var lastPushedContent: LutheranRadioLiveActivityAttributes.ContentState?

    /// Consecutive **committed** stalled observations where system-held content still
    /// mismatches the submitted candidate (language and/or stuck pause / Connecting visual).
    ///
    /// Immediate `content.state` after `await Activity.update` is apply-in-flight and does
    /// **not** increment this streak. Commit happens on ``handleActivityContentUpdate``
    /// (`contentUpdates`) or a delayed re-read past ``contentPushApplyConfirmationDelayMilliseconds``.
    /// Both of those observation kinds also run ``applySystemContentUpdateHeal``. Handshake
    /// lag (pause↔Connecting, Connecting↔playing after hold/connect clear) is excluded.
    /// Reset when system-held chrome matches the candidate, on matching `contentUpdates`,
    /// end paths, and when a recreation begins.
    /// - SeeAlso: ``isStalledLiveActivityContentPush(candidate:accepted:)``,
    ///   ``shouldCommitStalledContentPushObservation(kind:isStalled:isHandshakeLag:)``,
    ///   ``shouldRecreateInteractiveLiveActivityAfterStalledPushes(consecutiveStalled:recreationsAttempted:threshold:maxRecreations:isRecreationInProgress:)``.
    private var consecutiveStalledContentPushes = 0

    /// Last **system-held** `content.state` observed from `contentUpdates`, a delayed
    /// re-read, or a post-update snapshot — never aspirational ``lastPushedContent``.
    ///
    /// ``handleActivityContentUpdate`` and delayed re-read capture this as the prior SSOT
    /// for axis-heal coarsen **before** ``commitContentPushObservation`` overwrites it, so
    /// optimistic suppress memory cannot look like a same-stream language match.
    /// - SeeAlso: ``handleActivityContentUpdate(_:)``, ``applySystemContentUpdateHeal(systemContent:priorObservedLanguage:priorObservedVisual:)``,
    ///   ``lastPushedContent``.
    private var lastSystemHeldContent: LutheranRadioLiveActivityAttributes.ContentState?

    /// Candidate submitted to `Activity.update` while apply is still in-flight (immediate
    /// post-await `content.state` still lagged). Compared by delayed re-read / `contentUpdates`.
    /// Also set before `await Activity.update` so MainActor re-entry during the await
    /// coalesces visual-differing candidates instead of issuing a second IPC.
    private var inFlightContentPushCandidate: LutheranRadioLiveActivityAttributes.ContentState?

    /// Latest visual-differing candidate remembered while ``inFlightContentPushCandidate``
    /// is unconfirmed. Replace, do not queue. Flushed once after delayed re-read,
    /// `contentUpdates`, or an immediate post-await match. Language-only same-visual
    /// updates are not stored here — they still issue `Activity.update`.
    /// - SeeAlso: ``shouldCoalesceVisualDifferingContentPushWhileInFlight(inFlightVisual:candidateVisual:ownedVisual:)``.
    private var pendingCoalescedContentPushCandidate: LutheranRadioLiveActivityAttributes.ContentState?

    /// True while ``updateCurrentActivity()`` is inside `await Activity.update` (and the
    /// immediate post-await bookkeeping). Flush of a coalesced candidate waits until this
    /// is false so a language-only / first visual await is not followed by a nested visual IPC.
    private var isAwaitingLiveActivityContentPushApply = false

    /// Delayed apply-confirmation after an in-flight mismatch. Cancelled on a new push,
    /// matching `contentUpdates`, ownership end, or test sanitization.
    private var inFlightContentPushConfirmationTask: Task<Void, Never>?

    /// How many times this process has recreated the interactive Live Activity because
    /// system-held ContentState lagged the candidate. Reset when a push advances chrome.
    private var interactiveContentRecreationsAttempted = 0

    /// Re-entrancy guard while ``recreateInteractiveLiveActivityAfterStalledContent()`` runs
    /// (end + start must not schedule nested recreation from the nested initial push).
    /// While true, non-essential content pushes are skipped so concurrent updates do not
    /// target a dying activity id.
    private var isRecreatingLiveActivityAfterStalledContent = false

    /// When true, the next eligible foreground cycle should request an interactive Live
    /// Activity if session policy still needs one and none is owned.
    ///
    /// Set when:
    /// - Stalled-content recreation is deferred because `Activity.request` is not eligible, or
    /// - An interactive start attempt fails while `currentActivity` remains nil
    ///
    /// Cleared when an interactive activity is successfully owned, or when session teardown
    /// ends Live Activities without an in-flight recreation.
    ///
    /// - SeeAlso: ``ensureInteractiveLiveActivityIfNeeded()``, ``startActivity()``,
    ///   ``recreateInteractiveLiveActivityAfterStalledContent()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    private var pendingInteractiveLiveActivityEnsure = false

    /// Debounce stamp for ``ensureInteractiveLiveActivityIfNeeded()`` **missing-card start**
    /// so SceneDelegate dual foreground hooks do not double-request.
    private var lastInteractiveLiveActivityEnsureAt: Date?

    /// Minimum interval between ensure-start attempts (SceneDelegate dual hooks both fire).
    private static let interactiveLiveActivityEnsureDebounceInterval: TimeInterval = 1.0

    /// Debounce stamp for **owned-surface** foreground soft language/playing ensure
    /// (``ensureAuthoritativeContentOnForegroundIfNeeded()`` via
    /// ``ensureInteractiveLiveActivityIfNeeded()``).
    ///
    /// Independent of the missing-card start stamp so a recent start attempt cannot block
    /// unlock soft-reconcile, and a recent soft ensure cannot block a missing-card start.
    private var lastOwnedSurfaceForegroundEnsureAt: Date?

    /// Minimum interval between owned-surface foreground soft-ensure cycles when there is
    /// nothing pending to consume (dual will-enter-foreground + become-active hooks, rapid
    /// resign/become thrash). Quiet pending, interactive pending ensure, or chrome still
    /// lagging while request-eligible force a re-invoke inside the window.
    ///
    /// - SeeAlso: ``shouldInvokeOwnedSurfaceForegroundEnsure(hasCurrentActivity:lastOwnedSurfaceForegroundEnsureAt:now:debounceInterval:languageEnsureQuietPending:playingEnsureQuietPending:pendingInteractiveLiveActivityEnsure:contentEnsureStillNeeded:isRequestEligible:)``.
    static let ownedSurfaceForegroundEnsureDebounceInterval: TimeInterval = 1.0

    /// Consecutive **committed** stalled observations required before end + ``startActivity()``
    /// recreation.
    ///
    /// Immediate post-await lag and Connecting↔playing handshake do not consume this budget.
    /// Language stick that survives ``contentPushApplyConfirmationDelayMilliseconds`` still may.
    static let stalledContentPushRecreationThreshold = 3

    /// Cap on interactive recreation per healthy match cycle (avoids end/start loops).
    static let maxInteractiveContentRecreations = 2

    /// Maximum soft pushes from ``ensureAuthoritativePlayingContentIfNeeded()`` while owned
    /// visual still lags authoritative `.playing` (ActivityKit acceptance lag after soft-resume
    /// or stream-switch audible start). Prefer this over end+request for visual-only freezes.
    ///
    /// After this budget is exhausted while interactive request is **ineligible**, playing
    /// soft-ensure enters quiet pending (``playingEnsureQuietPending``) so status-driven
    /// media-surface refreshes do not re-burn the soft-retry budget until re-arm
    /// (authoritative play mutation, optimistic toggle / stream-switch, eligibility,
    /// become-active, or system `contentUpdates` acceptance).
    ///
    /// - SeeAlso: ``ensureAuthoritativePlayingContentIfNeeded()``,
    ///   ``shouldRunPlayingContentEnsureSoftPushes(needsPlayingEnsure:quietPending:isRequestEligible:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static let authoritativePlayingContentEnsureMaxAttempts = 3

    /// Maximum soft pushes from ``ensureAuthoritativeLanguageContentIfNeeded()`` while owned
    /// `content.state.currentLanguage` still lags ``liveActivityLanguageCodeForContentPush()``
    /// (ActivityKit acceptance lag after stream-switch / deferred recreation while ineligible).
    /// Prefer this over end+request; eligible-only recreation is a last resort on foreground.
    ///
    /// After this budget is exhausted while interactive request is **ineligible**, language
    /// soft-ensure enters a quiet-pending state for that destination (see
    /// ``languageEnsureQuietPendingDestination``) so status-driven media-surface refreshes
    /// do not re-run the soft-retry budget until re-arm (destination change, eligibility,
    /// become-active, or system `contentUpdates` acceptance).
    ///
    /// - SeeAlso: ``ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``ensureAuthoritativeContentOnForegroundIfNeeded()``,
    ///   ``shouldRunLanguageContentEnsureSoftPushes(needsLanguageEnsure:destinationLanguage:quietPendingDestination:isRequestEligible:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static let authoritativeLanguageContentEnsureMaxAttempts = 3

    /// Destination language for which soft language ensure exhausted while interactive request
    /// was ineligible.
    ///
    /// When non-nil and equal to the current destination, further ensure-driven soft pushes and
    /// **language-only** status re-pushes stay quiet until re-arm:
    /// - Destination language changes (new stream-switch mutation)
    /// - Interactive request becomes eligible
    /// - Foreground / become-active owned-surface soft ensure
    /// - System `contentUpdates` yield that **converges language** to destination (partial
    ///   acceptance does not clear playing-axis state)
    /// - Owned language converges to destination
    ///
    /// Visual mutations (pause / play / Connecting) still push when owned visual differs —
    /// quiet is language-stall thrash protection only, not a full content freeze.
    ///
    /// - SeeAlso: ``ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``shouldRunLanguageContentEnsureSoftPushes(needsLanguageEnsure:destinationLanguage:quietPendingDestination:isRequestEligible:)``,
    ///   ``shouldDeferRedundantLanguagePushWhileQuiet(candidateLanguage:ownedContentLanguage:ownedContentVisual:candidateVisual:quietPendingDestination:isRequestEligible:)``,
    ///   ``pushSettledLanguageAcceptanceContentIfNeeded()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    private var languageEnsureQuietPendingDestination: String?

    /// Destination for which a post-hold **settled** language acceptance cycle already ran while
    /// interactive request was ineligible.
    ///
    /// Soft language ensure often exhausts during the stream-switch attach storm (Connecting),
    /// enters quiet, then would never re-push when audible start finally clears the hold — leaving
    /// system-held `content.state.currentLanguage` on the prior stream until unlock. Settled
    /// acceptance consumes **one** post-hold soft-ensure re-arm per destination after hold clear;
    /// further soft-resume no-ops skip re-entering settle while ineligible until destination change,
    /// eligibility, become-active, or system `contentUpdates`. Bounded delayed post-settled retries
    /// (``schedulePostSettledLanguageEnsureRetriesIfNeeded(destination:)``) continue soft ensure
    /// after that cycle without re-opening the settle entry itself.
    ///
    /// - SeeAlso: ``pushSettledLanguageAcceptanceContentIfNeeded()``,
    ///   ``shouldPushSettledLanguageAcceptance(destinationLanguage:ownedContentLanguage:isStreamSwitchHoldActive:settledAcceptanceConsumedDestination:isRequestEligible:)``,
    ///   ``shouldSchedulePostSettledLanguageEnsureRetries(hasCurrentActivity:destinationLanguage:ownedContentLanguage:isStreamSwitchHoldActive:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    private var languageSettledAcceptanceConsumedDestination: String?

    /// Delayed post-settled language soft-ensure retries after audible destination settle.
    ///
    /// Soft ensure during Connecting + one settle cycle can still leave system-held language on
    /// the prior stream while request is ineligible. Status-driven thrash stays quiet; this task
    /// re-clears quiet on a longer cadence and re-runs soft ensure without end+request.
    /// Cancelled on end paths, destination change, foreground owned-surface ensure, and match.
    ///
    /// - SeeAlso: ``schedulePostSettledLanguageEnsureRetriesIfNeeded(destination:)``,
    ///   ``pushSettledLanguageAcceptanceContentIfNeeded()``.
    private var postSettledLanguageEnsureRetryTask: Task<Void, Never>?

    /// Maximum delayed soft-ensure cycles after a post-hold settled language acceptance still lags.
    ///
    /// - SeeAlso: ``postSettledLanguageEnsureDelayedIntervalsMilliseconds``,
    ///   ``schedulePostSettledLanguageEnsureRetriesIfNeeded(destination:)``.
    static let postSettledLanguageEnsureMaxDelayedAttempts = 3

    /// Sleep intervals (ms) before each delayed post-settled language ensure attempt.
    ///
    /// Longer than attach-storm soft yields so ActivityKit has room to accept language after
    /// audible settle without thrashing status-driven media-surface refreshes.
    ///
    /// - SeeAlso: ``postSettledLanguageEnsureMaxDelayedAttempts``,
    ///   ``schedulePostSettledLanguageEnsureRetriesIfNeeded(destination:)``.
    static let postSettledLanguageEnsureDelayedIntervalsMilliseconds: [UInt64] = [400, 1_000, 2_000]

    /// Whether soft playing ensure exhausted while interactive request was ineligible and
    /// owned visual still lagged authoritative `.playing`.
    ///
    /// When true, further ensure-driven soft pushes and **visual-only** status re-pushes that
    /// only repair candidate `.playing` stay quiet until re-arm:
    /// - Authoritative play mutation (``setPlaying`` / soft-resume ensure re-arm)
    /// - Optimistic toggle or stream-switch ContentState (new control cycle)
    /// - Interactive request becomes eligible
    /// - Foreground / become-active owned-surface soft ensure
    /// - System `contentUpdates` yield that **converges visual** to authoritative `.playing`
    ///   (partial language-only acceptance re-arms playing ensure rather than cancelling it)
    /// - Owned visual converges to `.playing`
    ///
    /// Pause (``.userPaused``) and language mutations still push — quiet is playing-stall
    /// thrash protection only, not a full content freeze. Does **not** invent `.playing`
    /// during stream-switch hold / connecting.
    ///
    /// - SeeAlso: ``ensureAuthoritativePlayingContentIfNeeded()``,
    ///   ``shouldRunPlayingContentEnsureSoftPushes(needsPlayingEnsure:quietPending:isRequestEligible:)``,
    ///   ``shouldDeferRedundantPlayingPushWhileQuiet(candidateVisual:ownedContentVisual:ownedContentLanguage:candidateLanguage:quietPending:isRequestEligible:)``,
    ///   ``pushSettledPlayingAcceptanceContentIfNeeded()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    private var playingEnsureQuietPending = false

    /// Whether a post-hold **settled** playing acceptance soft-ensure re-arm already ran while
    /// interactive request was ineligible and owned visual still lagged authoritative `.playing`.
    ///
    /// Soft playing ensure often exhausts (or never runs usefully) during stream-switch hold /
    /// attach, then quiet defers visual-only `.playing` repair for the rest of a lock stretch —
    /// leaving Connecting or paused chrome while audio is live. Settled acceptance consumes
    /// **one** post-hold full soft playing-ensure re-arm after hold clear; further soft-resume
    /// no-ops skip re-entering settle while ineligible until optimistic toggle / stream-switch,
    /// eligibility, become-active, or system `contentUpdates`. Bounded delayed post-settled
    /// retries (``schedulePostSettledPlayingEnsureRetriesIfNeeded()``) continue soft ensure after
    /// that cycle without re-opening the settle entry itself.
    ///
    /// - SeeAlso: ``pushSettledPlayingAcceptanceContentIfNeeded()``,
    ///   ``shouldPushSettledPlayingAcceptance(actorVisual:ownedContentVisual:isStreamSwitchHoldActive:isConnectingPlayback:settledAcceptanceConsumed:isRequestEligible:)``,
    ///   ``shouldSchedulePostSettledPlayingEnsureRetries(hasCurrentActivity:actorVisual:ownedContentVisual:isStreamSwitchHoldActive:isConnectingPlayback:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    private var playingSettledAcceptanceConsumed = false

    /// Delayed post-settled playing soft-ensure retries after audible settle still lags.
    ///
    /// Soft ensure during attach + one settle cycle can still leave system-held visual on
    /// ``.userPaused`` / ``.prePlay`` while request is ineligible and audio is already live.
    /// Status-driven thrash stays quiet; this task re-clears quiet on a longer cadence and
    /// re-runs soft ensure without end+request. Cancelled on end paths, control mutation,
    /// foreground owned-surface ensure, and owned visual convergence.
    ///
    /// - SeeAlso: ``schedulePostSettledPlayingEnsureRetriesIfNeeded()``,
    ///   ``pushSettledPlayingAcceptanceContentIfNeeded()``.
    private var postSettledPlayingEnsureRetryTask: Task<Void, Never>?

    /// Maximum delayed soft-ensure cycles after a post-hold settled playing acceptance still lags.
    ///
    /// - SeeAlso: ``postSettledPlayingEnsureDelayedIntervalsMilliseconds``,
    ///   ``schedulePostSettledPlayingEnsureRetriesIfNeeded()``.
    static let postSettledPlayingEnsureMaxDelayedAttempts = 3

    /// Sleep intervals (ms) before each delayed post-settled playing ensure attempt.
    ///
    /// Same cadence as language post-settled retries so dual-axis soft acceptance shares one
    /// longer window after soft-resume / audible start without thrashing status-driven wakes.
    ///
    /// - SeeAlso: ``postSettledPlayingEnsureMaxDelayedAttempts``,
    ///   ``schedulePostSettledPlayingEnsureRetriesIfNeeded()``.
    static let postSettledPlayingEnsureDelayedIntervalsMilliseconds: [UInt64] = [400, 1_000, 2_000]

    /// Maximum sparse long-horizon soft-ensure fires after quiet pending while request ineligible.
    ///
    /// Peer to short post-settled retries; longer cadence so residual continuous-lock lag is not
    /// permanently quiet-frozen after the ~2 s post-settled budget without thrashing status ticks.
    ///
    /// - SeeAlso: ``postQuietLongHorizonEnsureDelayedIntervalsMilliseconds``,
    ///   ``armPostQuietLongHorizonPlayingEnsureIfNeeded()``,
    ///   ``armPostQuietLongHorizonLanguageEnsureIfNeeded()``.
    static let postQuietLongHorizonEnsureMaxDelayedAttempts = 3

    /// Sleep intervals (ms) before each post-quiet long-horizon ensure fire (per freeze generation).
    ///
    /// Longer than ``postSettledPlayingEnsureDelayedIntervalsMilliseconds`` / language peer
    /// (400/1000/2000). Sparse by design — not status-driven thrash.
    ///
    /// - SeeAlso: ``postQuietLongHorizonEnsureMaxDelayedAttempts``,
    ///   ``schedulePostQuietLongHorizonPlayingEnsure()``,
    ///   ``schedulePostQuietLongHorizonLanguageEnsure(destination:)``.
    static let postQuietLongHorizonEnsureDelayedIntervalsMilliseconds: [UInt64] = [
        5_000, 15_000, 45_000
    ]

    /// Delayed sparse long-horizon **playing** soft-ensure after quiet / settle still lags.
    ///
    /// - SeeAlso: ``armPostQuietLongHorizonPlayingEnsureIfNeeded()``,
    ///   ``cancelPostQuietLongHorizonPlayingEnsure()``.
    private var postQuietLongHorizonPlayingEnsureTask: Task<Void, Never>?

    /// Freeze generation for the playing long-horizon rail (new quiet freeze starts a fresh horizon).
    private var postQuietLongHorizonPlayingEnsureGeneration: UInt64 = 0

    /// Delayed sparse long-horizon **language** soft-ensure after quiet / settle still lags.
    ///
    /// - SeeAlso: ``armPostQuietLongHorizonLanguageEnsureIfNeeded()``,
    ///   ``cancelPostQuietLongHorizonLanguageEnsure()``.
    private var postQuietLongHorizonLanguageEnsureTask: Task<Void, Never>?

    /// Freeze generation for the language long-horizon rail.
    private var postQuietLongHorizonLanguageEnsureGeneration: UInt64 = 0

    /// Delayed sparse long-horizon **dual-axis** soft-ensure when both language and visual lag.
    ///
    /// Owns recovery when destination language **and** owned visual lag authoritative `.playing`
    /// under continuous lock. One dual-axis ensure per fire — not two single-axis short budgets.
    ///
    /// - SeeAlso: ``armPostQuietLongHorizonDualAxisEnsureIfNeeded()``,
    ///   ``cancelPostQuietLongHorizonDualAxisEnsure()``,
    ///   ``ensureAuthoritativeDualAxisContentIfNeeded()``.
    private var postQuietLongHorizonDualAxisEnsureTask: Task<Void, Never>?

    /// Freeze generation for the dual-axis long-horizon rail.
    private var postQuietLongHorizonDualAxisEnsureGeneration: UInt64 = 0

    /// Whether the dual-axis long-horizon generation exhausted without owned acceptance.
    ///
    /// Become-active / foreground owned-surface ensure treats this like pending ensure so an
    /// eligible presentable cycle can soft-ensure then recreate — never while request ineligible.
    ///
    /// - SeeAlso: ``ensureAuthoritativeContentOnForegroundIfNeeded()``,
    ///   ``shouldInvokeOwnedSurfaceForegroundEnsure(hasCurrentActivity:lastOwnedSurfaceForegroundEnsureAt:now:debounceInterval:languageEnsureQuietPending:playingEnsureQuietPending:pendingInteractiveLiveActivityEnsure:contentEnsureStillNeeded:isRequestEligible:)``.
    private var postQuietLongHorizonDualAxisExhausted = false

    /// Whether a post-hold dual-axis settled acceptance cycle already ran while ineligible
    /// (owned ``.prePlay`` while actor `.playing`).
    ///
    /// - SeeAlso: ``pushSettledDualAxisAcceptanceContentIfNeeded()``,
    ///   ``shouldPushSettledDualAxisAcceptance(actorVisual:ownedContentVisual:destinationLanguage:isStreamSwitchHoldActive:isConnectingPlayback:settledAcceptanceConsumed:isRequestEligible:)``.
    private var dualAxisSettledAcceptanceConsumed = false

    /// Collapse concurrent dual-axis soft-push loops (same thrash shape as single-axis in-flight).
    private var dualAxisEnsureSoftPushesInFlight = false

    /// Whether the continuous-lock ensure freeze soft budget already exhausted while request
    /// was ineligible (quiet cool-down for this freeze generation).
    ///
    /// When true, same-stream partial re-arm must not clear quiet / nest post-settled; true
    /// language-new partial wins still get **one** post-settled follow-through via
    /// ``contentEnsureFreezePartialPostSettledScheduled``. Reset on play/toggle/switch mutation
    /// and presentable foreground ensure. Never ends the interactive surface while ineligible.
    ///
    /// - SeeAlso: ``markContentEnsureFreezeSoftBudgetExhausted()``,
    ///   ``resetContentEnsureFreezeGeneration()``,
    ///   ``shouldSchedulePostSettledPlayingEnsureAfterSoftBudgetExhaust(baseShouldSchedule:isRequestEligible:languageNewlyConvergedThisFreeze:partialPostSettledAlreadyScheduled:)``.
    private var contentEnsureFreezeSoftBudgetExhausted = false

    /// Whether one true-partial delayed post-settled follow-through already scheduled for this
    /// freeze generation (language-new or visual-new win). Prevents nested post-settled storms.
    private var contentEnsureFreezePartialPostSettledScheduled = false

    /// Destination language newly converged during this freeze generation (true partial win).
    ///
    /// Gates one post-settled visual follow-through after soft-budget exhaust while ineligible.
    private var contentEnsureFreezeLanguageNewlyConverged = false

    /// Playing visual newly converged during this freeze generation (true partial visual win).
    ///
    /// Gates one post-settled language follow-through after soft-budget exhaust while ineligible.
    private var contentEnsureFreezeVisualNewlyConverged = false

    /// Inter-attempt sleep (ms) between soft-ensure pushes while interactive request is **eligible**.
    ///
    /// Presentable cycles converge quickly; keep short so unlock heal stays snappy.
    ///
    /// - SeeAlso: ``softEnsureInterAttemptDelayMilliseconds(attempt:maxAttempts:isRequestEligible:)``,
    ///   ``authoritativeContentEnsureIneligibleInterAttemptDelaysMilliseconds``.
    static let authoritativeContentEnsureEligibleInterAttemptDelayMilliseconds: UInt64 = 50

    /// Inter-attempt sleeps (ms) between soft-ensure pushes while interactive request is **ineligible**.
    ///
    /// Device continuous-lock freezes rarely apply within a 50 ms storm; longer spacing gives
    /// ActivityKit an apply window without raising ``authoritativePlayingContentEnsureMaxAttempts``
    /// / language attempt count (no thrash volume increase).
    ///
    /// - SeeAlso: ``softEnsureInterAttemptDelayMilliseconds(attempt:maxAttempts:isRequestEligible:)``,
    ///   ``authoritativeContentEnsureEligibleInterAttemptDelayMilliseconds``.
    static let authoritativeContentEnsureIneligibleInterAttemptDelaysMilliseconds: [UInt64] = [
        200, 400, 800
    ]

    /// Whether a language soft-ensure push loop is already running on the main actor.
    ///
    /// Concurrent re-entry (status callbacks + media-surface ensure + setPlaying) collapses
    /// into a single loop so parallel attempt counters do not thrash ActivityKit.
    ///
    /// - SeeAlso: ``ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``shouldStartAuthoritativeContentEnsureSoftPushLoop(softPushesAlreadyInFlight:)``.
    private var languageEnsureSoftPushesInFlight = false

    /// Whether a playing soft-ensure push loop is already running on the main actor.
    ///
    /// - SeeAlso: ``ensureAuthoritativePlayingContentIfNeeded()``,
    ///   ``shouldStartAuthoritativeContentEnsureSoftPushLoop(softPushesAlreadyInFlight:)``.
    private var playingEnsureSoftPushesInFlight = false

    /// Last DEBUG signature for stalled content diagnostics (candidate/owned language+visual).
    ///
    /// Identical freeze pairs log once until the signature changes or the surface converges.
    ///
    /// - SeeAlso: ``stalledContentDiagnosticsSignature(candidateLanguage:acceptedLanguage:candidateVisual:acceptedVisual:)``,
    ///   ``shouldLogStalledContentDiagnostics(signature:lastLoggedSignature:)``.
    private var lastLoggedStalledContentDiagnosticsSignature: String?

    /// Last DEBUG signature for `contentUpdates` yield diagnostics (system language+visual+id).
    ///
    /// Identical tuples log once until the signature changes or ownership ends. Independent of
    /// stall diagnostics so a stall line cannot suppress a later yield (or the reverse).
    ///
    /// - SeeAlso: ``contentUpdatesYieldDiagnosticsSignature(systemLanguage:systemVisual:activityId:)``,
    ///   ``handleActivityContentUpdate(_:)``.
    private var lastLoggedContentUpdatesYieldDiagnosticsSignature: String?

    /// Whether the "language ensure quiet skip" DEBUG line has already been emitted for the
    /// current quiet engagement (avoids status-callback spam after budget exhaustion).
    private var languageEnsureQuietSkipLogged = false

    /// Whether the "playing ensure quiet skip" DEBUG line has already been emitted for the
    /// current quiet engagement.
    private var playingEnsureQuietSkipLogged = false

    /// Long-lived task observing the Live Activity attribute events stream.
    ///
    /// Consumes `contentUpdates` (the events surface yielding
    /// `ActivityContent<ContentState>` on every attribute update). Started on
    /// acquisition (start or resume); cancelled on end paths. Used to keep
    /// `lastPushedContent` in sync with the system-accepted state for diff-driven
    /// suppression of `update(using:)` calls.
    ///
    /// Responsibilities on yield:
    /// - Synchronize `lastPushedContent` with the yielded activity's `contentState`.
    ///   This aligns the diff check in `updateCurrentActivity` with the exact
    ///   state the system last rendered, strengthening duplicate suppression.
    /// - On `.dismissed` or `.ended`, clear local tracking so that stale
    ///   references do not cause spurious update attempts.
    ///
    /// Why this matters: gives the manager a reactive, system-driven signal
    /// for both content convergence and lifecycle. Combined with the existing
    /// `lastPushedContent` diff and PlayerEvent-driven call sites, it reduces
    /// reliance on the timer fallback and makes forced pushes more robust
    /// without changing any public contract or adding polling.
    ///
    /// - Important: Observation is additive only. All existing push sites
    ///   (`SharedPlayerManager`, `RadioPlayerCoordinator`, lifecycle handlers)
    ///   and the privacy / test guards remain the primary mechanism.
    /// - Note: Runs on main actor via Task + MainActor.run to keep isolation
    ///   clean under strict Swift 6.
    /// - SeeAlso: ``beginObservingActivityEvents(_:)``, ``updateCurrentActivity()``,
    ///   ``endActivity(dismissalPolicy:)``, docs/Widget-Presentation-Dataflow.md,
    ///   docs/Event-Driven-Refactor-Roadmap.md, `WidgetEventObserver`.
    ///
    /// Exposed as `internal private(set)` (parallel to `updateTimer` / `lastPushedContent`)
    /// as the designated white-box testing seam. Production code must never read or
    /// assign this directly.
    internal private(set) var activityObservationTask: Task<Void, Never>?

    #if DEBUG
    /// When true, attribute-events observation termination performs the same local cleanup
    /// as production ``performAttributeObservationTerminationHygiene()`` when
    /// ``currentActivity`` is non-nil, without ActivityKit IPC.
    ///
    /// Used exclusively by ``_test_beginObservingSyntheticContentUpdates(_:)`` and
    /// RadioLiveActivityManagerTests.
    private var _test_harnessSimulatesActiveActivity = false
    #endif

    /// Consolidated observer for the Live Activity attribute events stream
    /// (`contentUpdates`). Delegates to `WidgetEventObserver` (the extracted
    /// common implementation) while continuing to publish the resulting task
    /// into the `activityObservationTask` seam for test isolation.
    private let activityEventObserver = WidgetEventObserver<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>>()

    #if DEBUG
    /// Robust detection of unit / UI test execution under DEBUG.
    ///
    /// Matches the detection used inside `observeExistingActivities()`.
    /// Used to short-circuit Live Activity creation and update paths that would
    /// otherwise perform synchronous calls to ActivityKit's system services or start the 10 s
    /// repeating timer — both of which keep the test runner / LLDB "alive" and
    /// cause extremely slow / hung tests when run via `xcodebuild` from shell.
    ///
    /// The four-way check is required for coverage across:
    /// - `xcodebuild test` (XCTestConfigurationFilePath present)
    /// - Xcode GUI "Product › Test" / test navigator (env var often absent)
    /// - Attached LLDB / process name variants ("xctest", "com.apple...xctest...")
    ///
    /// - SeeAlso: ``observeExistingActivities()``, RadioLiveActivityManagerTests
    private var isRunningUnderTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.processName == "xctest"
            || ProcessInfo.processInfo.processName.contains("xctest")
    }
    #endif
    
    private init() {
        // Defer observation to a Task + yield so that the initial window + first layout
        // (which causes the system launch screen / splash to be dismissed) is never
        // blocked by a potentially slow synchronous ActivityKit query
        // (`Activity<...>.activities.first`) or stream setup.
        //
        // On simulator with stale Live Activities left from prior manual runs or tests,
        // the system service round-trips for `.activities` / contentUpdates can take many minutes
        // and previously kept the splash visible (or caused the 5-10 min "hangs" during
        // `xcodebuild test`).
        // The test setUp explicitly nils + cancels for the same reason.
        //
        // We still observe "early" (next suspension point after the window is visible)
        // so existing LA resumption works for normal cold launches.
        // The internal guards in observeExistingActivities() continue to short-circuit
        // under UITestMode / isRunningUnderTest.
        //
        // AGENT NOTE: If you are tempted to move this call back to synchronous init
        // "for simplicity", you will re-introduce launch stalls and slow test runs
        // on any simulator that has accumulated Live Activities. The pattern here
        // (defer + yield + early nil in observe + cheap sanitization in test setUp)
        // is required for acceptable cold launch and test performance.
        // See CODING_AGENT.md ("Test Execution Patience and Fast, Reliable Test Patterns").
        //
        // - SeeAlso: ``observeExistingActivities()``, scene(willConnectTo:), SceneDelegate,
        //   ``isRunningUnderTest``, CODING_AGENT.md (test isolation patterns + Test Execution Patience),
        //   the sanitization in SharedPlayerManagerEventTests.setUp and RadioLiveActivityManagerTests.setUp.
        Task { @MainActor [weak self] in
            // Cooperative yield lets the current runloop tick, layout, and first commit
            // complete so the launch screen is replaced by app content promptly.
            await Task.yield()
            self?.observeExistingActivities()
        }

        // Defense-in-depth: also listen for willTerminate so we end the LA even if
        // AppDelegate.applicationWillTerminate is not delivered (common on abrupt kills).
        // The observer just forwards to the existing handle/end path.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillTerminateNotification),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }

    @objc private func handleWillTerminateNotification() {
        handleAppWillTerminate()
    }
    
    // MARK: - Privacy-First Live Activity Management

    /// Requests a new privacy-first Live Activity (or replaces an existing one).
    ///
    /// In DEBUG builds this performs an early return (with timer cleanup) when
    /// `isRunningUnderTest` is true. This prevents creation of a real `Activity`
    /// plus the 10 s local `updateTimer` during tests. Without the guard, calls
    /// originating from `SharedPlayerManager.setPlaying()` (via `#if LUTHERAN_MAIN_APP`
    /// paths) during UI tests would start a repeating timer that keeps the test
    /// runner alive, manifesting as "very slow tests" or "hung before establishing
    /// connection" when running `xcodebuild ... test` from the shell.
    ///
    /// **Request eligibility / ownership:** ``interactiveLiveActivityStartDisposition`` is
    /// consulted before any `Activity.request` or leading ``endActivity()``. Visibility-class
    /// failures are start/recreate only. An already-owned interactive surface **always**
    /// updates (never end+request). Eligible + unowned may `Activity.request`; residual
    /// siblings end with ``.immediate`` (same as recreation) — never ``.default``.
    /// Ineligible + unowned records ``pendingInteractiveLiveActivityEnsure`` and returns
    /// (no request, no leading end).
    ///
    /// - Postcondition: If successful (non-test), `currentActivity` is non-nil and initial
    ///   content uses the current `PlayerVisualState` SSOT. On request failure with no owned
    ///   activity, or ineligible start with no owned activity,
    ///   ``pendingInteractiveLiveActivityEnsure`` is set for foreground recovery.
    /// - Important: Only call from main-app code (never widget extension). The caller is
    ///   responsible for ensuring we are allowed to show an activity (usually right after
    ///   a `.playing` transition). Prefer ``ensureInteractiveLiveActivityIfNeeded()`` on
    ///   foreground when recovering after a visibility-class request failure. Never ends
    ///   the only interactive surface while request is ineligible. Never replaces an
    ///   already-owned interactive id (update that surface).
    /// - Note: The test short-circuit here is the companion to the identical guard
    ///   in `observeExistingActivities()`. It is what made the prior partial fix
    ///   (commit 2af37cf) insufficient.
    /// - SeeAlso: `updateCurrentActivity()`, `SharedPlayerManager.setPlaying`,
    ///   ``ensureInteractiveLiveActivityIfNeeded()``,
    ///   ``interactiveLiveActivityStartDisposition(isRequestEligible:hasOwnedActivity:)``,
    ///   ``SharedPlayerManager/refreshAllMediaSurfaces(liveActivity:widgetRefresh:widgetRefreshImmediate:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md (start policy),
    ///   ``isRunningUnderTest``, ``observeExistingActivities()``, <doc:Architecture>
    func startActivity() async {
        // Defense-in-depth UI test isolation using the SSOT.
        // Prevents waking the Chrono widget renderer process (WidgetRenderer_Activities)
        // and avoids any calls to ActivityKit's system services or timer scheduling during UITestMode
        // (explicit "-UITestMode" or XCTest environment under DEBUG).
        if SharedPlayerManager.isRunningInUITestMode {
            stopLocalUpdateTimer()
            activityEventObserver.cancel()
            activityObservationTask = nil
            return
        }

        // Designed-for-iPhone Mac: ActivityKit services are absent. Skip before
        // `ActivityAuthorizationInfo` / `Activity.request` so launch does not log
        // authorization and output-client connection failures.
        if SharedPlayerManager.isRunningAsIOSAppOnMac {
            stopLocalUpdateTimer()
            activityEventObserver.cancel()
            activityObservationTask = nil
            pendingInteractiveLiveActivityEnsure = false
            return
        }

        #if DEBUG
        if isRunningUnderTest {
            // Prevent creating real Live Activities + the repeating local timer
            // during unit/UI tests. This is what was keeping the test runner alive.
            stopLocalUpdateTimer()
            activityEventObserver.cancel()
            activityObservationTask = nil
            return
        }
        #endif

        guard Self.areActivitiesEnabledOnThisHost else {
            #if DEBUG
            print("🔴 Live Activities are not enabled by user")
            #endif
            // User/system disabled: no recoverable request path.
            pendingInteractiveLiveActivityEnsure = false
            return
        }

        let requestEligible = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: true,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        let startDisposition = Self.interactiveLiveActivityStartDisposition(
            isRequestEligible: requestEligible,
            hasOwnedActivity: currentActivity != nil
        )
        switch startDisposition {
        case .deferPendingEnsure:
            pendingInteractiveLiveActivityEnsure = true
            #if DEBUG
            print(
                "🔴 Live Activity start deferred — interactive request not eligible " +
                "(pending ensure recorded; no Activity.request; no end)"
            )
            #endif
            return
        case .updateOwned:
            #if DEBUG
            print(
                "🔴 Live Activity start skipped — already owned; " +
                "updating existing surface only (keeping existing id)"
            )
            #endif
            await updateCurrentActivity()
            return
        case .request:
            break
        }

        // Defense: never Activity.request while this process already owns an interactive
        // surface. Recreation ends first (``.immediate``) so start sees unowned.
        if currentActivity != nil {
            await updateCurrentActivity()
            return
        }

        // Residual siblings (not this-process ownership) must dismiss immediately.
        // ``.default`` leaves lock-screen cards until a distant calendar date.
        endActivity(dismissalPolicy: .immediate)
        
        let manager = SharedPlayerManager.shared
        
        let attributes = LutheranRadioLiveActivityAttributes(
            appName: "Lutheran Radio",
            startTime: Date()
        )
        
        // Safe actor access (now allowed because function is async)
        let visualState = await manager.currentVisualState
        let streamMetadata = await manager.currentStreamMetadata
            ?? SharedPlayerManager.loadPersistedStreamMetadata()
        // Prefer hold-time connecting language when a stream switch is in flight.
        let currentLanguage = await manager.liveActivityLanguageCodeForContentPush()
        
        let initialContentState = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: visualState,
            streamMetadata: streamMetadata,
            currentLanguage: currentLanguage
        )
        
        do {
            let activity = try Activity<LutheranRadioLiveActivityAttributes>.request(
                attributes: attributes,
                content: .init(state: initialContentState, staleDate: nil)
            )
            
            currentActivity = activity
            pendingInteractiveLiveActivityEnsure = false
            beginObservingActivityEvents(activity)

            // Event-driven model: do NOT start the 10 s fallback timer here.
            // Freshness comes from explicit calls at visual/metadata mutation sites
            // (setPlaying / stop / didUpdateStreamMetadata / coordinator) and lifecycle.
            // The timer is only started via the explicit internal testing / fallback API.

            // Initial push captures the starting state into lastPushedContent.
            await updateCurrentActivity()
            
            #if DEBUG
            print("🔴 Privacy-first Live Activity started: \(activity.id)")
            #endif
            
        } catch {
            #if DEBUG
            print("🔴 Failed to start Live Activity: \(error)")
            #endif
            // Request failed after local end: re-bind if the system still holds a surface,
            // otherwise mark pending ensure so the next eligible foreground cycle can recover.
            await recoverAfterFailedInteractiveLiveActivityRequest()
        }
    }

    /// After a failed `Activity.request`, re-bind a system-held activity if present; else mark
    /// pending ensure for the next eligible foreground cycle.
    ///
    /// - Postcondition: Either `currentActivity` is non-nil (re-bound) or
    ///   ``pendingInteractiveLiveActivityEnsure`` is true when no surface is owned.
    /// - SeeAlso: ``startActivity()``, ``ensureInteractiveLiveActivityIfNeeded()``.
    private func recoverAfterFailedInteractiveLiveActivityRequest() async {
        // Prefer re-bind over a permanent blank surface (request may fail while system
        // still holds a residual interactive for this attribute type).
        if let existing = systemHeldLiveActivities().first {
            currentActivity = existing
            pendingInteractiveLiveActivityEnsure = false
            beginObservingActivityEvents(existing)
            await updateCurrentActivity()
            #if DEBUG
            print("🔴 Live Activity re-bound after failed request id=\(existing.id)")
            #endif
            return
        }
        if Self.shouldMarkPendingInteractiveLiveActivityEnsureAfterStartAttempt(
            currentActivityIsNil: currentActivity == nil
        ) {
            pendingInteractiveLiveActivityEnsure = true
            #if DEBUG
            print("🔴 Live Activity pending ensure after failed request (no owned surface)")
            #endif
        }
    }

    /// Pushes the latest `PlayerVisualState` + metadata + stream language into the active
    /// Live Activity, **but only when suppress policy allows**.
    ///
    /// This is the central implementation of the event-driven Live Activity model.
    /// Callers (SPM visual transitions, `didUpdateStreamMetadata`, coordinator, lifecycle,
    /// and the old `performActualSave` bridge) invoke this on meaningful change.
    ///
    /// Derivation uses the **in-memory** actor state (`currentVisualState` +
    /// `currentStreamMetadata`) and ``SharedPlayerManager/liveActivityLanguageCodeForContentPush()``
    /// when the main app is running. The persisted snapshot is used only as a safe fallback for
    /// metadata (e.g. very early after start before the first mutation). This decouples transient
    /// LA presentation from the durable `PersistedWidgetState` writes that widgets and
    /// relaunch require — language chrome must not depend on privacy-gated home-widget writes.
    ///
    /// **Stream-switch hold:** While ``SharedPlayerManager/isStreamSwitchPrePlayHoldActive``
    /// or ``SharedPlayerManager/isConnectingPlayback`` is true, a candidate visual of
    /// `.playing` is clamped to `.prePlay` so lock-screen chrome cannot flash play affordance
    /// during silent engine teardown or first-byte attach. Coordinators establish Connecting
    /// **with the destination language** via ``resetToPrePlayForNewStream`` before `.streamSwitch`
    /// stop so language chrome does not lag one content push behind visual Connecting.
    ///
    /// **Suppress + owned language/visual:** Deduplication uses
    /// ``shouldSuppressLiveActivityContentPush(lastPushed:candidate:ownedContentLanguage:ownedContentVisual:)``.
    /// Owned `content.state.currentLanguage` and `content.state.visualState` beat optimistic
    /// ``lastPushedContent`` so a failed or aspirational push cannot stick the lock-screen
    /// flag or control glyph on prior chrome.
    ///
    /// **Post-update suppress memory:** After `Activity.update`, ``lastPushedContent`` is
    /// re-seeded from the activity’s observed `content.state` (not an unverified aspirational
    /// candidate). Language still mismatched → suppress memory keeps the system-held language
    /// so a further non-suppressed push remains eligible. Visual acceptance lag likewise leaves
    /// suppress memory on system-held visual. Both branches of
    /// ``suppressMemoryAfterActivityUpdate`` return system-held chrome.
    ///
    /// **Stall oracle:** Immediate `content.state` after the await is apply-in-flight.
    /// ``consecutiveStalledContentPushes`` and language/playing quiet do **not** advance
    /// from that single read. Commit waits for ``handleActivityContentUpdate`` or a delayed
    /// re-read past ``contentPushApplyConfirmationDelayMilliseconds``. Handshake lag
    /// (pause↔Connecting, Connecting↔playing after hold/connect clear) is excluded.
    ///
    /// **Same-stream ineligible Connecting skip:** While request is ineligible and
    /// stream-switch hold is inactive, ``shouldSuppressConnectingContentPushWhileIneligible``
    /// skips `Activity.update` when the candidate is Connecting (``.prePlay``) and owned
    /// visual is already ``.userPaused`` or ``.playing``. Keep the committed glyph until
    /// authoritative `.playing` or a later `.userPaused` is the candidate. Stream-switch
    /// hold, first start (owned already Connecting), and request-eligible still publish
    /// Connecting. Durable mirrors still warm. Does **not** invent `.playing`.
    ///
    /// **One outstanding visual mutation:** While ``inFlightContentPushCandidate`` is
    /// unconfirmed, ``shouldCoalesceVisualDifferingContentPushWhileInFlight`` skips a second
    /// visual-differing `Activity.update` and remembers ``pendingCoalescedContentPushCandidate``
    /// (latest wins, including pause replacing playing-ensure). Language-only same-visual
    /// candidates still update. After committed observation, ``flushCoalescedContentPushIfNeeded``
    /// pushes once when the coalesced candidate still differs from observed.
    ///
    /// **Stalled system-held chrome recreation:** When a **committed** stall streak of
    /// language (or non-handshake visual) mismatch remains, recreation is considered.
    /// End + request runs **only when** interactive `Activity.request` is eligible
    /// (activities enabled + application active). When ineligible, the existing activity
    /// is kept and a pending ensure is recorded.
    /// Soft retries (playing ensure) are preferred for pure visual freezes; destroying the only
    /// card under a visibility failure is worse than a stalled glyph.
    ///
    /// - Parameters:
    ///   - preservingOwnedVisual: When `true` (post-quiet language long-horizon after freeze),
    ///     dest language rides ``ContentState/replacingCurrentLanguage(_:)`` so the owned
    ///     glyph is not overwritten with `.playing`. Stream-switch hold still Connecting.
    ///     Durable App Group mirrors still warm actor visual + dest language.
    /// - Precondition: Must be called on the main actor (the method is `@MainActor`).
    /// - Postcondition: If an update is sent, `lastPushedContent` reflects the
    ///   system-observed `content.state` after the await. Durable visual + language App Group
    ///   mirrors are warmed even when ActivityKit IPC is suppressed. After stalled-push recreation threshold,
    ///   interactive activity may be recreated once per healthy match cycle (capped) when eligible.
    /// - Note: Silently no-ops if no activity is active or recreation is in progress.
    /// - Important: Uses `nonisolated(unsafe)` + `unsafe` because `Activity.update` is
    ///   not Sendable in the current SDK; the capture of the Activity is done only after
    ///   we hold a strong local reference on the main actor.
    ///
    /// - SeeAlso: `startActivity()`, ``ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``ensureAuthoritativePlayingContentIfNeeded()``,
    ///   ``recreateInteractiveLiveActivityAfterStalledContent()``,
    ///   `SharedPlayerManager.setPlaying`,
    ///   `SharedPlayerManager.resetToPrePlayForNewStream`,
    ///   `SharedPlayerManager.didUpdateStreamMetadata`,
    ///   `performActualSave` (the bridge call remains for widget parity),
    ///   ``beginObservingActivityEvents(_:)`` (the Live Activity events surface that
    ///   keeps `lastPushedContent` aligned),
    ///   ``shouldSuppressConnectingContentPushWhileIneligible(isRequestEligible:isStreamSwitchHoldActive:ownedVisual:candidateVisual:)``,
    ///   ``shouldCoalesceVisualDifferingContentPushWhileInFlight(inFlightVisual:candidateVisual:ownedVisual:languageOnlyPreservingOwnedVisual:)``,
    ///   ``shouldKeepOwnedVisualOnPostQuietLanguageLongHorizon(freezeSoftBudgetExhausted:playingQuietPending:isRequestEligible:)``,
    ///   ``isRunningUnderTest``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   docs/Widget-Presentation-Dataflow.md,
    ///   docs/Widget-Functionality-Roadmap.md (Live Activity language chrome SSOT),
    ///   docs/cold-launch-streamplay-regression-checklist.md (§6),
    ///   RadioLiveActivityManagerTests
    @MainActor
    func updateCurrentActivity(preservingOwnedVisual: Bool = false) async {
        // Defense-in-depth UI test isolation (SSOT). Even if a stale currentActivity reference
        // existed, we must not call Activity.update during test runs.
        if SharedPlayerManager.isRunningInUITestMode {
            return
        }

        if SharedPlayerManager.isRunningAsIOSAppOnMac {
            return
        }

        #if DEBUG
        if isRunningUnderTest {
            return
        }
        #endif

        // While end+start recreation owns the lifecycle, skip concurrent content pushes so
        // they do not target a dying activity id or race the replacement request.
        if isRecreatingLiveActivityAfterStalledContent {
            return
        }

        guard let activity = currentActivity else { return }
        
        let manager = SharedPlayerManager.shared
        
        // Prefer the live in-memory values (decoupled path). Persisted is only fallback
        // so that an early push before the first mutation still has something reasonable.
        // This is the key separation: LA does not *require* a PersistedWidgetState write.
        //
        // Metadata + language first (await hops). Visual/hold/connecting are sampled **last**
        // so a concurrent ``setPlaying()`` cannot be overwritten by a stale Connecting publish
        // (yellow lock-screen chrome stuck while audio is already playing — stream-switch
        // optimistic prePlay + fire-and-forget performActualSave LA refresh race).
        let streamMetadata = await manager.currentStreamMetadata
            ?? SharedPlayerManager.loadPersistedStreamMetadata()
        // Hold-time target language advances with Connecting so the card never shows the
        // prior stream’s flag/name for one content push while the engine model is still old.
        let currentLanguage = await manager.liveActivityLanguageCodeForContentPush()

        // Authoritative visual at push time — after all prior suspension points.
        // Hold is sampled with visual so same-stream Connecting skip cannot race a
        // stream-switch that established destination-language Connecting honesty.
        let (visualState, streamSwitchHoldActive) = await Self.resolveContentPushVisual(from: manager)

        // Owned surface language + visual beat optimistic suppress memory (flag + glyph SSOT).
        let ownedLanguage = activity.content.state.currentLanguage
        let ownedVisual = activity.content.state.visualState
        let preserveOwnedVisual = Self.shouldPreserveOwnedVisualOnLanguageOnlyContentPush(
            keepOwnedVisualAfterFreeze: preservingOwnedVisual,
            isStreamSwitchHoldActive: streamSwitchHoldActive
        )
        let candidate: LutheranRadioLiveActivityAttributes.ContentState
        if preserveOwnedVisual {
            // Dest language on the owned glyph. Durable mirrors below still warm actor visual.
            candidate = activity.content.state.replacingCurrentLanguage(currentLanguage)
        } else {
            candidate = LutheranRadioLiveActivityAttributes.ContentState(
                visualState: visualState,
                streamMetadata: streamMetadata,
                currentLanguage: currentLanguage
            )
        }

        // Durable App Group mirrors for extension-hosted LA planning / optimistic language.
        // Always keep warm — even when ActivityKit IPC is suppressed — so lock-screen pause
        // and language chrome are not inverted when home-widget write suppression leaves the
        // extension session snapshot empty. Actor visual stays on the mirror when the
        // ActivityKit candidate preserves owned visual after freeze.
        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(visualState)
        SharedPlayerManager.persistLiveActivityLanguageMirror(currentLanguage)
        if Self.shouldSuppressLiveActivityContentPush(
            lastPushed: lastPushedContent,
            candidate: candidate,
            ownedContentLanguage: ownedLanguage,
            ownedContentVisual: ownedVisual
        ) {
            #if DEBUG
            print(
                "🔴 Live Activity update suppressed (content unchanged; owned language=\(ownedLanguage) " +
                "owned visual=\(ownedVisual))"
            )
            #endif
            return
        }

        // After language soft-ensure exhausted while request is ineligible, defer language-only
        // status re-pushes for the same destination. Durable mirrors already warmed above.
        // Visual mutations still push. Re-arm: destination change, eligibility, become-active,
        // or contentUpdates (see languageEnsureQuietPendingDestination).
        let requestEligibleForQuiet = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        if Self.shouldDeferRedundantLanguagePushWhileQuiet(
            candidateLanguage: candidate.currentLanguage,
            ownedContentLanguage: ownedLanguage,
            ownedContentVisual: ownedVisual,
            candidateVisual: candidate.visualState,
            quietPendingDestination: languageEnsureQuietPendingDestination,
            isRequestEligible: requestEligibleForQuiet
        ) {
            // Quiet language-only stall: durable mirrors already warm; no ActivityKit IPC.
            // Rate-limit DEBUG — status callbacks re-hit this every attach frame.
            #if DEBUG
            let deferSig = Self.stalledContentDiagnosticsSignature(
                candidateLanguage: candidate.currentLanguage,
                acceptedLanguage: ownedLanguage,
                candidateVisual: candidate.visualState,
                acceptedVisual: ownedVisual
            )
            if Self.shouldLogStalledContentDiagnostics(
                signature: "lang-defer|" + deferSig,
                lastLoggedSignature: lastLoggedStalledContentDiagnosticsSignature
            ) {
                lastLoggedStalledContentDiagnosticsSignature = "lang-defer|" + deferSig
                print(
                    "🔴 Live Activity language push deferred (quiet pending destination=" +
                    "\(languageEnsureQuietPendingDestination ?? "nil"); owned language=\(ownedLanguage); " +
                    "keeping surface; wait for eligibility, become-active, or language mutation)"
                )
            }
            #endif
            // Quiet defer is thrash protection — arm sparse long-horizon so lag is not terminal.
            await armPostQuietLongHorizonLanguageEnsureIfNeeded()
            return
        }

        // After playing soft-ensure exhausted while request is ineligible, defer visual-only
        // status re-pushes that only repair candidate `.playing`. Durable mirrors already warm.
        // Pause (userPaused) and language mutations still push. Re-arm: authoritative play,
        // optimistic toggle/switch, eligibility, become-active, or contentUpdates.
        if Self.shouldDeferRedundantPlayingPushWhileQuiet(
            candidateVisual: candidate.visualState,
            ownedContentVisual: ownedVisual,
            ownedContentLanguage: ownedLanguage,
            candidateLanguage: candidate.currentLanguage,
            quietPending: playingEnsureQuietPending,
            isRequestEligible: requestEligibleForQuiet
        ) {
            #if DEBUG
            let deferSig = Self.stalledContentDiagnosticsSignature(
                candidateLanguage: candidate.currentLanguage,
                acceptedLanguage: ownedLanguage,
                candidateVisual: candidate.visualState,
                acceptedVisual: ownedVisual
            )
            if Self.shouldLogStalledContentDiagnostics(
                signature: "play-defer|" + deferSig,
                lastLoggedSignature: lastLoggedStalledContentDiagnosticsSignature
            ) {
                lastLoggedStalledContentDiagnosticsSignature = "play-defer|" + deferSig
                print(
                    "🔴 Live Activity playing visual push deferred (quiet pending; owned visual=" +
                    "\(ownedVisual); keeping surface; wait for eligibility, become-active, or play mutation)"
                )
            }
            #endif
            // C4: deferred playing repair while quiet must arm long-horizon if not already armed.
            await armPostQuietLongHorizonPlayingEnsureIfNeeded()
            return
        }

        // Same-stream ineligible resume: do not spend an ActivityKit visual apply on
        // Connecting over committed paused/playing. Stream-switch hold still Connecting.
        // Durable mirrors already warmed above. Must run before visual coalesce so a
        // Connecting candidate cannot become the outstanding flush.
        if Self.shouldSuppressConnectingContentPushWhileIneligible(
            isRequestEligible: requestEligibleForQuiet,
            isStreamSwitchHoldActive: streamSwitchHoldActive,
            ownedVisual: ownedVisual,
            candidateVisual: candidate.visualState
        ) {
            #if DEBUG
            let skipSig = Self.stalledContentDiagnosticsSignature(
                candidateLanguage: candidate.currentLanguage,
                acceptedLanguage: ownedLanguage,
                candidateVisual: candidate.visualState,
                acceptedVisual: ownedVisual
            )
            if Self.shouldLogStalledContentDiagnostics(
                signature: "connecting-skip|" + skipSig,
                lastLoggedSignature: lastLoggedStalledContentDiagnosticsSignature
            ) {
                lastLoggedStalledContentDiagnosticsSignature = "connecting-skip|" + skipSig
                print(
                    "🔴 Live Activity Connecting push skipped (ineligible same-stream resume; " +
                    "owned visual=\(ownedVisual); keeping paused/playing until authoritative " +
                    "playing or a later pause is the candidate)"
                )
            }
            #endif
            return
        }

        // One outstanding visual mutation: while an Activity.update apply is unconfirmed,
        // do not issue a second visual-differing IPC. Remember the latest candidate
        // (pause replaces playing-ensure). Language-only same-visual still updates.
        if Self.shouldCoalesceVisualDifferingContentPushWhileInFlight(
            inFlightVisual: inFlightContentPushCandidate?.visualState,
            candidateVisual: candidate.visualState,
            ownedVisual: ownedVisual,
            languageOnlyPreservingOwnedVisual: preserveOwnedVisual
        ) {
            pendingCoalescedContentPushCandidate = candidate
            #if DEBUG
            let coalesceSig = Self.stalledContentDiagnosticsSignature(
                candidateLanguage: candidate.currentLanguage,
                acceptedLanguage: ownedLanguage,
                candidateVisual: candidate.visualState,
                acceptedVisual: inFlightContentPushCandidate?.visualState ?? ownedVisual
            )
            if Self.shouldLogStalledContentDiagnostics(
                signature: "visual-coalesce|" + coalesceSig,
                lastLoggedSignature: lastLoggedStalledContentDiagnosticsSignature
            ) {
                lastLoggedStalledContentDiagnosticsSignature = "visual-coalesce|" + coalesceSig
                print(
                    "🔴 Live Activity visual push coalesced (in-flight visual=" +
                    "\(String(describing: inFlightContentPushCandidate?.visualState)); " +
                    "candidateVisual=\(candidate.visualState); latest remembered; " +
                    "push once after apply commits)"
                )
            }
            #endif
            return
        }

        // SAFETY: Activity.update / Activity property access are not Sendable in the current
        // SDK; capture a local strong reference on the main actor, then read content/id only
        // under explicit `unsafe` (same capture pattern as end paths).
        nonisolated(unsafe) let safeActivity = activity
        // Mark in-flight before the await so MainActor re-entry (playing ensure / dual-axis
        // during this suspension) coalesces instead of issuing a second visual IPC.
        inFlightContentPushCandidate = candidate
        isAwaitingLiveActivityContentPushApply = true
        unsafe await safeActivity.update(.init(state: candidate, staleDate: nil))

        // Suppress memory from system-observed content, never unverified aspirational candidate.
        // SAFETY: `content.state` / `id` on the nonisolated(unsafe) Activity capture require
        // an `unsafe` expression under SWIFT_STRICT_MEMORY_SAFETY.
        let accepted = unsafe safeActivity.content.state
        lastPushedContent = Self.suppressMemoryAfterActivityUpdate(
            candidate: candidate,
            acceptedSystemContent: accepted
        )

        // Owned language converged → clear language ensure quiet for this destination.
        if Self.shouldClearLanguageEnsureQuietPending(
            quietPendingDestination: languageEnsureQuietPendingDestination,
            destinationLanguage: candidate.currentLanguage,
            ownedOrSystemLanguage: accepted.currentLanguage
        ) {
            languageEnsureQuietPendingDestination = nil
            languageEnsureQuietSkipLogged = false
            cancelPostQuietLongHorizonLanguageEnsure()
        }
        // Owned visual converged to playing → clear playing ensure quiet + settled consume.
        if Self.shouldClearPlayingEnsureQuietPending(
            quietPending: playingEnsureQuietPending,
            ownedOrSystemVisual: accepted.visualState
        ) {
            playingEnsureQuietPending = false
            playingEnsureQuietSkipLogged = false
            cancelPostQuietLongHorizonPlayingEnsure()
        }
        if Self.shouldClearPlayingSettledAcceptanceConsume(
            settledAcceptanceConsumed: playingSettledAcceptanceConsumed,
            ownedOrSystemVisual: accepted.visualState
        ) {
            playingSettledAcceptanceConsumed = false
        }

        // Partial acceptance coarsen: only **true** language-new / visual-new wins re-arm.
        // Same-stream visual stall (language already matched before the push) must not clear
        // quiet, nest post-settled, or re-arm long-horizon — continuous-lock thrash amplifier.
        // Do not call ensure inline (may already be inside a soft-push loop). Never invent
        // .playing; never end while ineligible.
        let partialLanguageRearm = Self.shouldRearmPlayingEnsureAfterPartialLanguageAcceptance(
            candidateLanguage: candidate.currentLanguage,
            acceptedLanguage: accepted.currentLanguage,
            candidateVisual: candidate.visualState,
            acceptedVisual: accepted.visualState,
            preUpdateOwnedLanguage: ownedLanguage
        )
        if partialLanguageRearm {
            contentEnsureFreezeLanguageNewlyConverged = true
        }
        if Self.shouldClearPlayingEnsureQuietForPartialRearm(
            shouldRearmFromPartialPolicy: partialLanguageRearm,
            freezeSoftBudgetExhausted: contentEnsureFreezeSoftBudgetExhausted,
            partialPostSettledAlreadyScheduled: contentEnsureFreezePartialPostSettledScheduled,
            isRequestEligible: requestEligibleForQuiet
        ) {
            playingEnsureQuietPending = false
            playingEnsureQuietSkipLogged = false
            if Self.shouldSchedulePostSettledAfterPartialLanguageWin(
                shouldRearmFromPartialPolicy: partialLanguageRearm,
                softPushesInFlight: playingEnsureSoftPushesInFlight,
                partialPostSettledAlreadyScheduled: contentEnsureFreezePartialPostSettledScheduled,
                isRequestEligible: requestEligibleForQuiet
            ) {
                schedulePostSettledPlayingEnsureRetriesIfNeeded()
                contentEnsureFreezePartialPostSettledScheduled = true
            }
            // True language-new win keeps/re-arms playing long-horizon — do not cancel it.
            await armPostQuietLongHorizonPlayingEnsureIfNeeded()
            #if DEBUG
            print(
                "🔴 Live Activity partial acceptance — language newly converged; " +
                "re-armed playing ensure (owned visual=\(accepted.visualState))"
            )
            #endif
        }
        let partialVisualRearm = Self.shouldRearmLanguageEnsureAfterPartialVisualAcceptance(
            candidateLanguage: candidate.currentLanguage,
            acceptedLanguage: accepted.currentLanguage,
            candidateVisual: candidate.visualState,
            acceptedVisual: accepted.visualState,
            preUpdateOwnedVisual: ownedVisual
        )
        if partialVisualRearm {
            contentEnsureFreezeVisualNewlyConverged = true
        }
        if partialVisualRearm {
            let allowLanguageQuietClear =
                requestEligibleForQuiet
                || !contentEnsureFreezeSoftBudgetExhausted
                || !contentEnsureFreezePartialPostSettledScheduled
            if allowLanguageQuietClear {
                languageEnsureQuietPendingDestination = nil
                languageEnsureQuietSkipLogged = false
                if !languageEnsureSoftPushesInFlight,
                   !candidate.currentLanguage.isEmpty,
                   !contentEnsureFreezePartialPostSettledScheduled || requestEligibleForQuiet {
                    schedulePostSettledLanguageEnsureRetriesIfNeeded(
                        destination: candidate.currentLanguage
                    )
                    contentEnsureFreezePartialPostSettledScheduled = true
                }
                // True visual-new win keeps/re-arms language long-horizon.
                await armPostQuietLongHorizonLanguageEnsureIfNeeded()
                #if DEBUG
                print(
                    "🔴 Live Activity partial acceptance — visual newly converged; " +
                    "re-armed language ensure (owned language=\(accepted.currentLanguage))"
                )
                #endif
            }
        }

        lastSystemHeldContent = accepted
        let streamSwitchHold = await manager.isStreamSwitchPrePlayHoldActive
        let connectingPlayback = await manager.isConnectingPlayback
        let contentStalled = Self.isStalledLiveActivityContentPush(
            candidate: candidate,
            accepted: accepted
        )
        let handshakeLag = Self.isConnectingPlayingHandshakeLag(
            candidateLanguage: candidate.currentLanguage,
            acceptedLanguage: accepted.currentLanguage,
            candidateVisual: candidate.visualState,
            acceptedVisual: accepted.visualState,
            isStreamSwitchHoldActive: streamSwitchHold,
            isConnectingPlayback: connectingPlayback
        )
        // Immediate post-await mismatch is apply-in-flight — do not increment stall or
        // recreate from this read. Handshake lag is also excluded. Full match still resets.
        let shouldCommitStall = Self.shouldCommitStalledContentPushObservation(
            kind: .immediatePostAwait,
            isStalled: contentStalled,
            isHandshakeLag: handshakeLag
        )
        isAwaitingLiveActivityContentPushApply = false
        if shouldCommitStall {
            consecutiveStalledContentPushes += 1
            cancelInFlightContentPushConfirmation()
            Task { @MainActor [weak self] in
                await self?.flushCoalescedContentPushIfNeeded(observed: accepted)
            }
        } else if Self.shouldResetStalledContentStreak(candidate: candidate, accepted: accepted) {
            // Healthy surface — clear recreation budget so a later freeze can recreate again.
            consecutiveStalledContentPushes = 0
            interactiveContentRecreationsAttempted = 0
            clearContentPushDiagnosticsSignatures()
            cancelInFlightContentPushConfirmation()
            // Connecting (or other visual) applied: flush the latest coalesced visual once.
            Task { @MainActor [weak self] in
                await self?.flushCoalescedContentPushIfNeeded(observed: accepted)
            }
        } else if contentStalled {
            scheduleInFlightContentPushConfirmation(candidate: candidate)
        }

        #if DEBUG
        // SAFETY: Activity.id on the nonisolated(unsafe) capture (DEBUG diagnostics only).
        let activityId = unsafe safeActivity.id
        let stallSig = Self.stalledContentDiagnosticsSignature(
            candidateLanguage: candidate.currentLanguage,
            acceptedLanguage: accepted.currentLanguage,
            candidateVisual: candidate.visualState,
            acceptedVisual: accepted.visualState
        )
        // Rate-limit identical candidate/owned freeze pairs (lock-stretch ensure thrash).
        // True mutations that change language or visual re-arm the signature and log again.
        let shouldLogStall = !contentStalled || Self.shouldLogStalledContentDiagnostics(
            signature: stallSig,
            lastLoggedSignature: lastLoggedStalledContentDiagnosticsSignature
        )
        if shouldLogStall {
            if contentStalled {
                lastLoggedStalledContentDiagnosticsSignature = stallSig
            }
            print(
                "🔴 Live Activity update: id=\(activityId) candidateLang=\(candidate.currentLanguage) " +
                "contentStateLang=\(accepted.currentLanguage) visual=\(accepted.visualState) " +
                "candidateVisual=\(candidate.visualState)"
            )
            if !candidate.currentLanguage.isEmpty,
               accepted.currentLanguage != candidate.currentLanguage {
                print(
                    "🔴 Live Activity language not yet on surface (candidate=\(candidate.currentLanguage) " +
                    "content.state=\(accepted.currentLanguage)); suppress memory kept system-held language"
                )
            } else if contentStalled, accepted.visualState != candidate.visualState {
                print(
                    "🔴 Live Activity visual not yet on surface (candidate=\(candidate.visualState) " +
                    "content.state=\(accepted.visualState)); suppress memory kept system-held visual"
                )
            }
        }
        #endif

        // Recreation / deferred-pending only after a **committed** stall. Immediate
        // post-await mismatch is in-flight (see ``scheduleInFlightContentPushConfirmation``).
        if shouldCommitStall {
            await evaluateStalledContentRecreationAfterCommittedObservation()
        }
    }

    /// Cancels an in-flight post-update apply confirmation.
    ///
    /// - Parameter clearCoalesced: When `true`, also drop ``pendingCoalescedContentPushCandidate``
    ///   (ownership end / test sanitization). Default `false` keeps the latest remembered
    ///   visual so a committed observation can still flush it once.
    /// - SeeAlso: ``scheduleInFlightContentPushConfirmation(candidate:)``,
    ///   ``flushCoalescedContentPushIfNeeded(observed:)``.
    private func cancelInFlightContentPushConfirmation(clearCoalesced: Bool = false) {
        inFlightContentPushConfirmationTask?.cancel()
        inFlightContentPushConfirmationTask = nil
        inFlightContentPushCandidate = nil
        isAwaitingLiveActivityContentPushApply = false
        if clearCoalesced {
            pendingCoalescedContentPushCandidate = nil
        }
    }

    /// Issues one ``updateCurrentActivity()`` when a remembered visual-differing candidate
    /// still disagrees with the committed system-held surface.
    ///
    /// Call only after ``inFlightContentPushCandidate`` is cleared (apply committed or
    /// cancelled). Soft-ensure attempt counters still bound later loops; this is the
    /// single post-commit visual IPC, not a new rail. Pause that replaced playing-ensure
    /// in-flight is the outstanding candidate (latest wins via actor SSOT on rebuild).
    ///
    /// - Parameter observed: System-held `content.state` from delayed re-read,
    ///   `contentUpdates`, or immediate post-await match.
    /// - SeeAlso: ``shouldFlushCoalescedContentPushAfterObservation(coalesced:observed:)``,
    ///   ``shouldCoalesceVisualDifferingContentPushWhileInFlight(inFlightVisual:candidateVisual:ownedVisual:)``.
    @MainActor
    private func flushCoalescedContentPushIfNeeded(
        observed: LutheranRadioLiveActivityAttributes.ContentState
    ) async {
        guard inFlightContentPushCandidate == nil else { return }
        guard !isAwaitingLiveActivityContentPushApply else { return }
        guard Self.shouldFlushCoalescedContentPushAfterObservation(
            coalesced: pendingCoalescedContentPushCandidate,
            observed: observed
        ) else {
            pendingCoalescedContentPushCandidate = nil
            return
        }
        pendingCoalescedContentPushCandidate = nil
        await updateCurrentActivity()
    }

    /// End+request or deferred pending ensure after a **committed** stall observation.
    ///
    /// - SeeAlso: ``shouldPerformStalledContentRecreation(consecutiveStalled:recreationsAttempted:isRecreationInProgress:isRequestEligible:threshold:maxRecreations:)``.
    @MainActor
    private func evaluateStalledContentRecreationAfterCommittedObservation() async {
        let requestEligible = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        if Self.shouldPerformStalledContentRecreation(
            consecutiveStalled: consecutiveStalledContentPushes,
            recreationsAttempted: interactiveContentRecreationsAttempted,
            isRecreationInProgress: isRecreatingLiveActivityAfterStalledContent,
            isRequestEligible: requestEligible,
            threshold: Self.stalledContentPushRecreationThreshold,
            maxRecreations: Self.maxInteractiveContentRecreations
        ) {
            await recreateInteractiveLiveActivityAfterStalledContent()
            return
        }
        let wouldRecreateByStreakCap = Self.shouldRecreateInteractiveLiveActivityAfterStalledPushes(
            consecutiveStalled: consecutiveStalledContentPushes,
            recreationsAttempted: interactiveContentRecreationsAttempted,
            threshold: Self.stalledContentPushRecreationThreshold,
            maxRecreations: Self.maxInteractiveContentRecreations,
            isRecreationInProgress: isRecreatingLiveActivityAfterStalledContent
        )
        if Self.shouldMarkPendingEnsureForDeferredRecreation(
            wouldRecreateByStreakCap: wouldRecreateByStreakCap,
            isRequestEligible: requestEligible
        ) {
            let announce = Self.shouldAnnounceDeferredInteractiveRecreationWhileIneligible(
                wouldRecreateByStreakCap: wouldRecreateByStreakCap,
                isRequestEligible: requestEligible,
                pendingEnsureAlreadyRecorded: pendingInteractiveLiveActivityEnsure
            )
            pendingInteractiveLiveActivityEnsure = true
            #if DEBUG
            if announce {
                print(
                    "🔴 Live Activity recreation deferred — interactive request not eligible " +
                    "(keeping existing surface; pending ensure recorded)"
                )
            }
            #endif
        }
    }

    /// Applies a delayed re-read or `contentUpdates` observation to stall bookkeeping.
    ///
    /// Overwrites ``lastSystemHeldContent`` with `observed`. Callers that then
    /// ``applySystemContentUpdateHeal`` **must** capture prior language/visual before this
    /// call — otherwise language-new vs same-stream coarsen is lost.
    ///
    /// - Parameters:
    ///   - candidate: Content submitted (in-flight candidate or actor SSOT).
    ///   - observed: System-held `content.state`.
    ///   - kind: ``.delayedReread`` or ``.contentUpdates`` (not immediate post-await).
    ///   - isStreamSwitchHoldActive: Hold at observation time.
    ///   - isConnectingPlayback: Connect pipeline at observation time.
    /// - SeeAlso: ``shouldCommitStalledContentPushObservation(kind:isStalled:isHandshakeLag:)``,
    ///   ``shouldApplySystemContentUpdateHealAfterObservation(kind:)``,
    ///   ``applySystemContentUpdateHeal(systemContent:priorObservedLanguage:priorObservedVisual:)``.
    @MainActor
    private func commitContentPushObservation(
        candidate: LutheranRadioLiveActivityAttributes.ContentState,
        observed: LutheranRadioLiveActivityAttributes.ContentState,
        kind: LiveActivityContentPushObservationKind,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool
    ) async {
        lastSystemHeldContent = observed
        let stalled = Self.isStalledLiveActivityContentPush(
            candidate: candidate,
            accepted: observed
        )
        let handshakeLag = Self.isConnectingPlayingHandshakeLag(
            candidateLanguage: candidate.currentLanguage,
            acceptedLanguage: observed.currentLanguage,
            candidateVisual: candidate.visualState,
            acceptedVisual: observed.visualState,
            isStreamSwitchHoldActive: isStreamSwitchHoldActive,
            isConnectingPlayback: isConnectingPlayback
        )
        if Self.shouldCommitStalledContentPushObservation(
            kind: kind,
            isStalled: stalled,
            isHandshakeLag: handshakeLag
        ) {
            consecutiveStalledContentPushes += 1
            await evaluateStalledContentRecreationAfterCommittedObservation()
        } else if Self.shouldResetStalledContentStreak(candidate: candidate, accepted: observed) {
            consecutiveStalledContentPushes = 0
            interactiveContentRecreationsAttempted = 0
            clearContentPushDiagnosticsSignatures()
            lastPushedContent = Self.suppressMemoryAfterActivityUpdate(
                candidate: candidate,
                acceptedSystemContent: observed
            )
            if Self.shouldClearPlayingEnsureQuietPending(
                quietPending: playingEnsureQuietPending,
                ownedOrSystemVisual: observed.visualState
            ) {
                playingEnsureQuietPending = false
                playingEnsureQuietSkipLogged = false
                cancelPostQuietLongHorizonPlayingEnsure()
            }
            if Self.shouldClearLanguageEnsureQuietPending(
                quietPendingDestination: languageEnsureQuietPendingDestination,
                destinationLanguage: candidate.currentLanguage,
                ownedOrSystemLanguage: observed.currentLanguage
            ) {
                languageEnsureQuietPendingDestination = nil
                languageEnsureQuietSkipLogged = false
                cancelPostQuietLongHorizonLanguageEnsure()
            }
        }
    }

    /// Schedules a delayed re-read after an immediate post-await mismatch.
    ///
    /// After the apply window, this path is stall truth **and** axis-heal truth (same as
    /// `contentUpdates`). Capture prior ``lastSystemHeldContent`` before commit overwrites it.
    ///
    /// - Parameter candidate: Content submitted to the in-flight `Activity.update`.
    /// - SeeAlso: ``contentPushApplyConfirmationDelayMilliseconds(isRequestEligible:)``,
    ///   ``handleActivityContentUpdate(_:)``,
    ///   ``applySystemContentUpdateHeal(systemContent:priorObservedLanguage:priorObservedVisual:)``.
    @MainActor
    private func scheduleInFlightContentPushConfirmation(
        candidate: LutheranRadioLiveActivityAttributes.ContentState
    ) {
        inFlightContentPushConfirmationTask?.cancel()
        inFlightContentPushConfirmationTask = nil
        guard let activity = currentActivity else { return }
        inFlightContentPushCandidate = candidate
        let eligible = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        let delayMs = Self.contentPushApplyConfirmationDelayMilliseconds(isRequestEligible: eligible)
        // SAFETY: Activity.content is not Sendable; capture on the main actor then
        // re-read under `unsafe` after the apply window (same pattern as updateCurrentActivity).
        nonisolated(unsafe) let safeActivity = activity
        inFlightContentPushConfirmationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if SharedPlayerManager.isRunningInUITestMode { return }
            #if DEBUG
            if self.isRunningUnderTest { return }
            #endif
            guard self.currentActivity != nil else { return }
            // Prior SSOT before commit overwrites lastSystemHeldContent — language-new
            // coarsen is lost if we heal against the just-observed state.
            let priorLanguage = self.lastSystemHeldContent?.currentLanguage
            let priorVisual = self.lastSystemHeldContent?.visualState
            let observed = unsafe safeActivity.content.state
            let manager = SharedPlayerManager.shared
            let hold = await manager.isStreamSwitchPrePlayHoldActive
            let connecting = await manager.isConnectingPlayback
            // contentUpdates may have cancelled this task while we awaited actor SSOT;
            // that path already committed and healed.
            guard !Task.isCancelled else { return }
            await self.commitContentPushObservation(
                candidate: candidate,
                observed: observed,
                kind: .delayedReread,
                isStreamSwitchHoldActive: hold,
                isConnectingPlayback: connecting
            )
            // Apply is committed: clear in-flight, flush the latest coalesced visual once,
            // then axis-heal (heal may re-arm playing ensure; coalesce will hold further IPC).
            self.inFlightContentPushConfirmationTask = nil
            self.inFlightContentPushCandidate = nil
            await self.flushCoalescedContentPushIfNeeded(observed: observed)
            if Self.shouldApplySystemContentUpdateHealAfterObservation(kind: .delayedReread) {
                await self.applySystemContentUpdateHeal(
                    systemContent: observed,
                    priorObservedLanguage: priorLanguage,
                    priorObservedVisual: priorVisual
                )
            }
        }
    }

    /// Observation kind for stall / quiet / recreation bookkeeping after `Activity.update`.
    ///
    /// Immediate post-await `content.state` is apply-in-flight. Stall truth **and**
    /// axis-heal truth are ``contentUpdates`` or a delayed re-read past
    /// ``contentPushApplyConfirmationDelayMilliseconds``.
    ///
    /// - SeeAlso: ``shouldCommitStalledContentPushObservation(kind:isStalled:isHandshakeLag:)``,
    ///   ``shouldApplySystemContentUpdateHealAfterObservation(kind:)``,
    ///   ``updateCurrentActivity()``, docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    enum LiveActivityContentPushObservationKind: Equatable, Sendable {
        /// Immediate `activity.content.state` after `await Activity.update`. Not stall truth.
        case immediatePostAwait
        /// Re-read after ``contentPushApplyConfirmationDelayMilliseconds``.
        case delayedReread
        /// System `contentUpdates` yield — system-held SSOT.
        case contentUpdates
    }

    /// How ``startActivity()`` proceeds given request eligibility and ownership.
    ///
    /// Visibility-class failures are **start/recreate only**. Never end the only interactive
    /// surface while ``isInteractiveLiveActivityRequestEligible`` is false. Never
    /// ``startActivity()`` end+request while this process already owns an interactive id —
    /// ``refreshAllMediaSurfaces`` `.startOrUpdate` and ``startActivity()`` update that id.
    /// Recreation may end+request only after an eligible
    /// ``recreateInteractiveLiveActivityAfterStalledContent()`` that already ended with
    /// ``.immediate``.
    ///
    /// - SeeAlso: ``startActivity()``,
    ///   ``interactiveLiveActivityStartDisposition(isRequestEligible:hasOwnedActivity:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    enum InteractiveLiveActivityStartDisposition: Equatable, Sendable {
        /// Eligible and unowned: end residual siblings with ``.immediate``, then `Activity.request`.
        case request
        /// Already owned (eligible or not): ``updateCurrentActivity()`` only. Never end+request.
        case updateOwned
        /// Ineligible with no owned surface: record pending ensure; do not request; do not end.
        case deferPendingEnsure
    }

    /// Whether a completed `Activity.update` left the system surface on prior chrome.
    ///
    /// Counts as stalled (system-held chrome still lags) when:
    /// - Candidate language is non-empty and differs from system-held language (flag/name stall), or
    /// - System still shows `.userPaused` while the candidate needs `.prePlay` (Connecting) or
    ///   `.playing` (soft-resume / stream-switch attach honesty after pause), or
    /// - System still shows `.prePlay` (Connecting) while the candidate is authoritative
    ///   `.playing` (soft-resume / post-audible visual freeze — pure visual lag without language mismatch), or
    /// - System still shows `.prePlay` while the candidate is intentional `.userPaused`
    ///   (pause push never accepted; soft-resume then inherits a stuck Connecting glyph).
    ///
    /// Intentional Connecting match (candidate `.prePlay` while hold/connect forces Connecting)
    /// is **not** stalled — both sides agree on Connecting.
    ///
    /// Handshake lag (pause↔Connecting, Connecting↔playing after hold/connect clear) is still
    /// reported here so suppress/ensure stay honest; ``shouldCommitStalledContentPushObservation``
    /// excludes it from the recreation streak.
    ///
    /// - Parameters:
    ///   - candidate: Content submitted to ActivityKit.
    ///   - accepted: Re-read `activity.content.state` after the update await, delayed re-read,
    ///     or `contentUpdates`.
    /// - Returns: `true` when system-held chrome still lags the candidate (not yet committed).
    /// - SeeAlso: ``updateCurrentActivity()``, ``ensureAuthoritativePlayingContentIfNeeded()``,
    ///   ``shouldCommitStalledContentPushObservation(kind:isStalled:isHandshakeLag:)``,
    ///   ``shouldRecreateInteractiveLiveActivityAfterStalledPushes(consecutiveStalled:recreationsAttempted:threshold:maxRecreations:isRecreationInProgress:)``.
    static func isStalledLiveActivityContentPush(
        candidate: LutheranRadioLiveActivityAttributes.ContentState,
        accepted: LutheranRadioLiveActivityAttributes.ContentState
    ) -> Bool {
        if !candidate.currentLanguage.isEmpty,
           accepted.currentLanguage != candidate.currentLanguage {
            return true
        }
        // Soft-resume freeze: pause content never leaves the surface while audio plays / Connecting attaches.
        if accepted.visualState == .userPaused,
           candidate.visualState == .playing || candidate.visualState == .prePlay {
            return true
        }
        // Pure visual freeze: system still shows Connecting while candidate is authoritative playing.
        // Prefer soft playing-ensure retries; recreation remains gated by eligibility + streak/cap.
        if accepted.visualState == .prePlay, candidate.visualState == .playing {
            return true
        }
        // Pause honesty: system still Connecting while candidate is intentional user pause.
        if accepted.visualState == .prePlay, candidate.visualState == .userPaused {
            return true
        }
        return false
    }

    /// Whether stalled-push bookkeeping should reset after a system content observation.
    ///
    /// Only when system-held chrome no longer lags the candidate — **partial** acceptance
    /// (language advanced, visual still Connecting / pause) must keep the streak so deferred
    /// recreation bookkeeping is not wiped by one-axis progress.
    ///
    /// - Parameters:
    ///   - candidate: Authoritative candidate ContentState.
    ///   - accepted: System-held `content.state` (post-update or `contentUpdates`).
    /// - Returns: `true` when ``consecutiveStalledContentPushes`` may reset to zero.
    /// - SeeAlso: ``isStalledLiveActivityContentPush(candidate:accepted:)``,
    ///   ``contentUpdateAxisHealPolicy(systemLanguage:systemVisual:destinationLanguage:actorVisual:isStreamSwitchHoldActive:isConnectingPlayback:)``.
    static func shouldResetStalledContentStreak(
        candidate: LutheranRadioLiveActivityAttributes.ContentState,
        accepted: LutheranRadioLiveActivityAttributes.ContentState
    ) -> Bool {
        !isStalledLiveActivityContentPush(candidate: candidate, accepted: accepted)
    }

    /// Delay before a post-update mismatch may be treated as a committed stall.
    ///
    /// Matches the first soft-ensure spacing so ActivityKit has the same apply window
    /// the ensure rails already use (50 ms eligible, 200 ms ineligible). Immediate
    /// post-await `content.state` is not stall truth.
    ///
    /// - Parameter isRequestEligible: Interactive request eligibility (presentable vs lock).
    /// - Returns: Milliseconds to wait before delayed re-read / quiet entry.
    /// - SeeAlso: ``softEnsureInterAttemptDelayMilliseconds(attempt:maxAttempts:isRequestEligible:)``,
    ///   ``shouldCommitStalledContentPushObservation(kind:isStalled:isHandshakeLag:)``.
    static func contentPushApplyConfirmationDelayMilliseconds(isRequestEligible: Bool) -> UInt64 {
        if isRequestEligible {
            return authoritativeContentEnsureEligibleInterAttemptDelayMilliseconds
        }
        return authoritativeContentEnsureIneligibleInterAttemptDelaysMilliseconds.first
            ?? authoritativeContentEnsureEligibleInterAttemptDelayMilliseconds
    }

    /// Whether a visual mismatch is Connecting handshake lag rather than a frozen id.
    ///
    /// Pause↔``.prePlay`` and ``.prePlay``↔``.playing`` after hold/connect have cleared are
    /// the pause→Connecting→playing attach handshake. Eligible 50 ms bursts must not
    /// consume ``stalledContentPushRecreationThreshold``. Language mismatch is never
    /// handshake — true language stick after the apply window still may recreate.
    ///
    /// - Parameters:
    ///   - candidateLanguage: Submitted ContentState language.
    ///   - acceptedLanguage: System-held language.
    ///   - candidateVisual: Submitted visual.
    ///   - acceptedVisual: System-held visual.
    ///   - isStreamSwitchHoldActive: ``isStreamSwitchPrePlayHoldActive``.
    ///   - isConnectingPlayback: ``isConnectingPlayback``.
    /// - Returns: `true` when stall bookkeeping must not increment for this pair.
    /// - SeeAlso: ``shouldCommitStalledContentPushObservation(kind:isStalled:isHandshakeLag:)``,
    ///   ``resolveContentPushVisual(visualState:streamSwitchHold:isConnectingPlayback:)``.
    static func isConnectingPlayingHandshakeLag(
        candidateLanguage: String,
        acceptedLanguage: String,
        candidateVisual: PlayerVisualState,
        acceptedVisual: PlayerVisualState,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool
    ) -> Bool {
        if !candidateLanguage.isEmpty, acceptedLanguage != candidateLanguage {
            return false
        }
        let pauseConnecting =
            (acceptedVisual == .userPaused && candidateVisual == .prePlay)
            || (acceptedVisual == .prePlay && candidateVisual == .userPaused)
        if pauseConnecting {
            return true
        }
        let connectingPlaying =
            (acceptedVisual == .prePlay && candidateVisual == .playing)
            || (acceptedVisual == .playing && candidateVisual == .prePlay)
        if connectingPlaying, !isStreamSwitchHoldActive, !isConnectingPlayback {
            return true
        }
        return false
    }

    /// Whether a stall observation may increment ``consecutiveStalledContentPushes``.
    ///
    /// Immediate post-await mismatch is apply-in-flight. Handshake lag is excluded even
    /// after delayed re-read / `contentUpdates`. Language stick that survives the apply
    /// window still commits.
    ///
    /// - Parameters:
    ///   - kind: When the observation was taken.
    ///   - isStalled: ``isStalledLiveActivityContentPush(candidate:accepted:)``.
    ///   - isHandshakeLag: ``isConnectingPlayingHandshakeLag(candidateLanguage:acceptedLanguage:candidateVisual:acceptedVisual:isStreamSwitchHoldActive:isConnectingPlayback:)``.
    /// - Returns: `true` when the recreation streak may increment.
    /// - SeeAlso: ``updateCurrentActivity()``, ``handleActivityContentUpdate(_:)``.
    static func shouldCommitStalledContentPushObservation(
        kind: LiveActivityContentPushObservationKind,
        isStalled: Bool,
        isHandshakeLag: Bool
    ) -> Bool {
        guard isStalled else { return false }
        guard kind != .immediatePostAwait else { return false }
        if isHandshakeLag { return false }
        return true
    }

    /// Whether a committed observation should run ``applySystemContentUpdateHeal``.
    ///
    /// Stall truth and axis-heal truth share the same observation kinds: ``contentUpdates``
    /// and delayed re-read. Immediate post-await `content.state` is apply-in-flight and must
    /// not coarsen quiet or re-arm playing ensure (handshake lag would look like language-new
    /// or visual-new progress).
    ///
    /// - Parameter kind: Observation kind after `Activity.update`.
    /// - Returns: `true` for ``.delayedReread`` and ``.contentUpdates``.
    /// - SeeAlso: ``applySystemContentUpdateHeal(systemContent:priorObservedLanguage:priorObservedVisual:)``,
    ///   ``scheduleInFlightContentPushConfirmation(candidate:)``,
    ///   ``handleActivityContentUpdate(_:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldApplySystemContentUpdateHealAfterObservation(
        kind: LiveActivityContentPushObservationKind
    ) -> Bool {
        switch kind {
        case .immediatePostAwait:
            return false
        case .delayedReread, .contentUpdates:
            return true
        }
    }

    /// Whether a Connecting (``.prePlay``) ContentState push must skip `Activity.update`
    /// so a same-stream ineligible resume does not spend the lock-stretch visual apply
    /// on yellow chrome the surface already replaced with pause or play.
    ///
    /// Home widgets skip Connecting paint on gapless same-stream soft-resume
    /// (``PlaybackPlayDecision/shouldApplyConnectingPrePlayChrome``). Live Activity is a
    /// different surface: this gate uses owned ContentState + request eligibility +
    /// stream-switch hold, not ``canSoftResumeSameStream``. Home honesty does not heal
    /// the lock-screen glyph.
    ///
    /// - Parameters:
    ///   - isRequestEligible: ``isInteractiveLiveActivityRequestEligible(areActivitiesEnabled:isApplicationActive:)``.
    ///     Presentable apply is cheap; Connecting honesty stands while eligible.
    ///   - isStreamSwitchHoldActive: ``SharedPlayerManager/isStreamSwitchPrePlayHoldActive``.
    ///     Destination-language switch still publishes Connecting; do not skip.
    ///   - ownedVisual: Owned `content.state.visualState`.
    ///   - candidateVisual: Visual from ``resolveContentPushVisual(visualState:streamSwitchHold:isConnectingPlayback:)``.
    /// - Returns: `true` when IPC must skip Connecting (owned paused/playing, ineligible,
    ///   not stream-switch hold, candidate ``.prePlay``).
    /// - Important: Does **not** invent `.playing` during attach. First start (owned
    ///   already ``.prePlay``) still publishes Connecting — nothing better to keep.
    ///   Pause (``.userPaused``) and authoritative `.playing` candidates still push.
    /// - SeeAlso: ``updateCurrentActivity()``,
    ///   ``resolveContentPushVisual(visualState:streamSwitchHold:isConnectingPlayback:)``,
    ///   ``PlaybackPlayDecision/shouldApplyConnectingPrePlayChrome(visualState:isActivePlaybackIntent:canSoftResumeSameStream:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldSuppressConnectingContentPushWhileIneligible(
        isRequestEligible: Bool,
        isStreamSwitchHoldActive: Bool,
        ownedVisual: PlayerVisualState,
        candidateVisual: PlayerVisualState
    ) -> Bool {
        guard !isRequestEligible else { return false }
        guard !isStreamSwitchHoldActive else { return false }
        guard candidateVisual == .prePlay else { return false }
        switch ownedVisual {
        case .userPaused, .playing:
            return true
        case .prePlay, .cleared, .thermalPaused, .securityLocked:
            return false
        }
    }

    /// Whether a candidate must wait for the in-flight `Activity.update` apply instead of
    /// issuing another visual-differing IPC.
    ///
    /// One outstanding visual mutation: while apply is unconfirmed, later visual-differing
    /// candidates (and duplicate unconfirmed visuals such as playing-ensure 2/3) are
    /// remembered and do not call `Activity.update`. Pause (``.userPaused``) replacing
    /// playing-ensure in-flight coalesces — latest wins so pause is the outstanding
    /// candidate after commit. Language-only candidates (candidate visual equals in-flight
    /// visual **and** owned visual) still update — those applies still land under lock.
    /// After freeze, language-only preserving owned visual also still updates even when
    /// in-flight visual differs (playing-ensure in-flight vs owned Connecting): same-visual
    /// language is the apply that still lands; do not bury it behind a visual coalesced flush.
    ///
    /// - Parameters:
    ///   - inFlightVisual: Visual of ``inFlightContentPushCandidate``; `nil` when no apply
    ///     is outstanding.
    ///   - candidateVisual: Visual of the new candidate.
    ///   - ownedVisual: Owned `content.state.visualState`.
    ///   - languageOnlyPreservingOwnedVisual: ``shouldPreserveOwnedVisualOnLanguageOnlyContentPush(keepOwnedVisualAfterFreeze:isStreamSwitchHoldActive:)``
    ///     decided this candidate keeps the owned glyph.
    /// - Returns: `true` when IPC must be skipped and the caller should remember the latest
    ///   candidate.
    /// - SeeAlso: ``updateCurrentActivity()``,
    ///   ``shouldFlushCoalescedContentPushAfterObservation(coalesced:observed:)``,
    ///   ``flushCoalescedContentPushIfNeeded(observed:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldCoalesceVisualDifferingContentPushWhileInFlight(
        inFlightVisual: PlayerVisualState?,
        candidateVisual: PlayerVisualState,
        ownedVisual: PlayerVisualState,
        languageOnlyPreservingOwnedVisual: Bool = false
    ) -> Bool {
        guard let inFlightVisual else { return false }
        if languageOnlyPreservingOwnedVisual, candidateVisual == ownedVisual {
            return false
        }
        // Language-only: same visual as in-flight and already on the owned surface.
        if candidateVisual == inFlightVisual, ownedVisual == candidateVisual {
            return false
        }
        return true
    }

    /// Whether a remembered coalesced candidate should issue one `Activity.update` after
    /// the in-flight apply is committed.
    ///
    /// Compares language and visual only — ICY metadata is not an outstanding visual
    /// mutation. Rebuild on flush uses current actor SSOT (latest pause/play wins).
    ///
    /// - Parameters:
    ///   - coalesced: ``pendingCoalescedContentPushCandidate``.
    ///   - observed: Committed system-held `content.state`.
    /// - Returns: `true` when language or visual still disagrees with observed.
    /// - SeeAlso: ``flushCoalescedContentPushIfNeeded(observed:)``,
    ///   ``shouldCoalesceVisualDifferingContentPushWhileInFlight(inFlightVisual:candidateVisual:ownedVisual:)``.
    static func shouldFlushCoalescedContentPushAfterObservation(
        coalesced: LutheranRadioLiveActivityAttributes.ContentState?,
        observed: LutheranRadioLiveActivityAttributes.ContentState
    ) -> Bool {
        guard let coalesced else { return false }
        return coalesced.visualState != observed.visualState
            || coalesced.currentLanguage != observed.currentLanguage
    }

    /// Start / request disposition for ``startActivity()`` and ``refreshAllMediaSurfaces``
    /// `.startOrUpdate`.
    ///
    /// - Parameters:
    ///   - isRequestEligible: ``isInteractiveLiveActivityRequestEligible(areActivitiesEnabled:isApplicationActive:)``.
    ///   - hasOwnedActivity: Whether this process already owns an interactive activity.
    /// - Returns: ``InteractiveLiveActivityStartDisposition``.
    /// - Important: `hasOwnedActivity == true` is always ``.updateOwned`` (eligible or not).
    ///   Eligible + unowned is ``.request``. Ineligible + unowned is ``.deferPendingEnsure``.
    ///   Recreation ends first so ``startActivity()`` sees unowned.
    /// - SeeAlso: ``startActivity()``, docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func interactiveLiveActivityStartDisposition(
        isRequestEligible: Bool,
        hasOwnedActivity: Bool
    ) -> InteractiveLiveActivityStartDisposition {
        if hasOwnedActivity {
            return .updateOwned
        }
        if isRequestEligible {
            return .request
        }
        return .deferPendingEnsure
    }

    /// Inter-attempt delay between soft-ensure `Activity.update` attempts.
    ///
    /// - Parameters:
    ///   - attempt: 1-based attempt that just completed.
    ///   - maxAttempts: Soft budget for this axis.
    ///   - isRequestEligible: Interactive request eligibility (presentable vs lock-stretch).
    /// - Returns: Milliseconds to sleep before the next attempt, or `nil` when no further attempt.
    /// - SeeAlso: ``authoritativeContentEnsureEligibleInterAttemptDelayMilliseconds``,
    ///   ``authoritativeContentEnsureIneligibleInterAttemptDelaysMilliseconds``,
    ///   ``ensureAuthoritativePlayingContentIfNeeded()``,
    ///   ``ensureAuthoritativeLanguageContentIfNeeded()``.
    static func softEnsureInterAttemptDelayMilliseconds(
        attempt: Int,
        maxAttempts: Int,
        isRequestEligible: Bool
    ) -> UInt64? {
        guard attempt >= 1, attempt < maxAttempts else { return nil }
        if isRequestEligible {
            return authoritativeContentEnsureEligibleInterAttemptDelayMilliseconds
        }
        let delays = authoritativeContentEnsureIneligibleInterAttemptDelaysMilliseconds
        guard !delays.isEmpty else {
            return authoritativeContentEnsureEligibleInterAttemptDelayMilliseconds
        }
        let index = attempt - 1
        if index < delays.count {
            return delays[index]
        }
        return delays[delays.count - 1]
    }

    /// Whether owned language **newly** converged to the candidate destination this update.
    ///
    /// - Parameters:
    ///   - preUpdateOwnedLanguage: System-held language **before** the `Activity.update`.
    ///   - acceptedLanguage: System-held language after the update (or contentUpdates yield).
    ///   - candidateLanguage: Destination language submitted / actor SSOT.
    /// - Returns: `true` when accepted equals non-empty candidate and pre-update owned differed.
    /// - SeeAlso: ``shouldRearmPlayingEnsureAfterPartialLanguageAcceptance(candidateLanguage:acceptedLanguage:candidateVisual:acceptedVisual:preUpdateOwnedLanguage:)``.
    static func didLanguageNewlyConverge(
        preUpdateOwnedLanguage: String,
        acceptedLanguage: String,
        candidateLanguage: String
    ) -> Bool {
        guard !candidateLanguage.isEmpty else { return false }
        guard acceptedLanguage == candidateLanguage else { return false }
        return preUpdateOwnedLanguage != candidateLanguage
    }

    /// Whether owned visual **newly** converged to the candidate visual this update.
    ///
    /// - SeeAlso: ``shouldRearmLanguageEnsureAfterPartialVisualAcceptance(candidateLanguage:acceptedLanguage:candidateVisual:acceptedVisual:preUpdateOwnedVisual:)``.
    static func didVisualNewlyConverge(
        preUpdateOwnedVisual: PlayerVisualState,
        acceptedVisual: PlayerVisualState,
        candidateVisual: PlayerVisualState
    ) -> Bool {
        guard acceptedVisual == candidateVisual else { return false }
        return preUpdateOwnedVisual != candidateVisual
    }

    /// Whether language **newly** converged while visual still needs authoritative `.playing` repair.
    ///
    /// True partial win: system advances destination language with Connecting (``.prePlay``) or
    /// pause chrome while audio is already playing — re-arm playing ensure once without treating
    /// the language win as a full surface heal.
    ///
    /// Same-stream visual stall (language already matched **before** the push) must **not**
    /// re-arm: every failed playing push previously cleared quiet, scheduled post-settled, and
    /// armed long-horizon — continuous-lock thrash without improving ActivityKit acceptance.
    ///
    /// - Parameters:
    ///   - preUpdateOwnedLanguage: System-held language before the update (required for coarsen).
    /// - SeeAlso: ``didLanguageNewlyConverge(preUpdateOwnedLanguage:acceptedLanguage:candidateLanguage:)``,
    ///   ``contentUpdateAxisHealPolicy(systemLanguage:systemVisual:destinationLanguage:actorVisual:isStreamSwitchHoldActive:isConnectingPlayback:priorObservedLanguage:priorObservedVisual:)``,
    ///   ``updateCurrentActivity()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldRearmPlayingEnsureAfterPartialLanguageAcceptance(
        candidateLanguage: String,
        acceptedLanguage: String,
        candidateVisual: PlayerVisualState,
        acceptedVisual: PlayerVisualState,
        preUpdateOwnedLanguage: String
    ) -> Bool {
        guard didLanguageNewlyConverge(
            preUpdateOwnedLanguage: preUpdateOwnedLanguage,
            acceptedLanguage: acceptedLanguage,
            candidateLanguage: candidateLanguage
        ) else { return false }
        guard candidateVisual == .playing else { return false }
        return acceptedVisual != .playing
    }

    /// Whether visual **newly** converged while language still lags destination.
    ///
    /// Same-axis stall (visual already matched before the push) must not re-arm language ensure.
    ///
    /// - SeeAlso: ``shouldRearmPlayingEnsureAfterPartialLanguageAcceptance(candidateLanguage:acceptedLanguage:candidateVisual:acceptedVisual:preUpdateOwnedLanguage:)``,
    ///   ``didVisualNewlyConverge(preUpdateOwnedVisual:acceptedVisual:candidateVisual:)``.
    static func shouldRearmLanguageEnsureAfterPartialVisualAcceptance(
        candidateLanguage: String,
        acceptedLanguage: String,
        candidateVisual: PlayerVisualState,
        acceptedVisual: PlayerVisualState,
        preUpdateOwnedVisual: PlayerVisualState
    ) -> Bool {
        guard didVisualNewlyConverge(
            preUpdateOwnedVisual: preUpdateOwnedVisual,
            acceptedVisual: acceptedVisual,
            candidateVisual: candidateVisual
        ) else { return false }
        guard !candidateLanguage.isEmpty else { return false }
        return acceptedLanguage != candidateLanguage
    }

    /// Whether a true partial re-arm may clear playing quiet for one follow-through.
    ///
    /// - Parameters:
    ///   - shouldRearmFromPartialPolicy: ``shouldRearmPlayingEnsureAfterPartialLanguageAcceptance``.
    ///   - freezeSoftBudgetExhausted: Soft ensure already exhausted this freeze while ineligible.
    ///   - partialPostSettledAlreadyScheduled: One true-partial post-settled already used.
    ///   - isRequestEligible: Presentable / eligible cycles always allow quiet clear.
    /// - Returns: `true` when quiet may clear for partial follow-through.
    /// - SeeAlso: ``shouldSchedulePostSettledAfterPartialLanguageWin(shouldRearmFromPartialPolicy:softPushesInFlight:partialPostSettledAlreadyScheduled:isRequestEligible:)``.
    static func shouldClearPlayingEnsureQuietForPartialRearm(
        shouldRearmFromPartialPolicy: Bool,
        freezeSoftBudgetExhausted: Bool,
        partialPostSettledAlreadyScheduled: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        guard shouldRearmFromPartialPolicy else { return false }
        if isRequestEligible { return true }
        if freezeSoftBudgetExhausted && partialPostSettledAlreadyScheduled {
            return false
        }
        return true
    }

    /// Whether to schedule **one** delayed post-settled playing ensure after a true language-new win.
    ///
    /// - Note: Never schedules mid soft-push loop (``softPushesInFlight``); never nests a second
    ///   post-settled while ineligible after the freeze already used its partial follow-through.
    static func shouldSchedulePostSettledAfterPartialLanguageWin(
        shouldRearmFromPartialPolicy: Bool,
        softPushesInFlight: Bool,
        partialPostSettledAlreadyScheduled: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        guard shouldRearmFromPartialPolicy else { return false }
        guard !softPushesInFlight else { return false }
        if partialPostSettledAlreadyScheduled && !isRequestEligible { return false }
        return true
    }

    /// Whether nested post-settled playing ensure may arm after soft-budget exhaust while locked.
    ///
    /// Eligible cycles keep post-settled for unlock heal. While ineligible, only a **true**
    /// language-new partial win (not yet follow-throughed) may schedule post-settled; same-stream
    /// visual stall skips nested post-settled so sparse long-horizon owns residual.
    ///
    /// - SeeAlso: ``shouldSchedulePostSettledPlayingEnsureRetries(hasCurrentActivity:actorVisual:ownedContentVisual:isStreamSwitchHoldActive:isConnectingPlayback:)``,
    ///   ``armPostQuietLongHorizonPlayingEnsureIfNeeded()``.
    static func shouldSchedulePostSettledPlayingEnsureAfterSoftBudgetExhaust(
        baseShouldSchedule: Bool,
        isRequestEligible: Bool,
        languageNewlyConvergedThisFreeze: Bool,
        partialPostSettledAlreadyScheduled: Bool
    ) -> Bool {
        guard baseShouldSchedule else { return false }
        if isRequestEligible { return true }
        if languageNewlyConvergedThisFreeze && !partialPostSettledAlreadyScheduled {
            return true
        }
        return false
    }

    /// Whether nested post-settled language ensure may arm after soft-budget exhaust while locked.
    ///
    /// Symmetric to playing: true visual-new partial win gets one language follow-through;
    /// pure language stall under continuous lock prefers long-horizon over nested post-settled.
    static func shouldSchedulePostSettledLanguageEnsureAfterSoftBudgetExhaust(
        baseShouldSchedule: Bool,
        isRequestEligible: Bool,
        visualNewlyConvergedThisFreeze: Bool,
        partialPostSettledAlreadyScheduled: Bool
    ) -> Bool {
        guard baseShouldSchedule else { return false }
        if isRequestEligible { return true }
        if visualNewlyConvergedThisFreeze && !partialPostSettledAlreadyScheduled {
            return true
        }
        return false
    }

    /// Whether eligible-only recreation after foreground soft ensure should prefer hard heal
    /// after continuous-lock freeze soft-budget and/or dual-axis long-horizon exhaust.
    ///
    /// Strengthens presentable recovery when mid-lock soft budgets already burned without owned
    /// acceptance — still **never** recreates while request is ineligible.
    ///
    /// - SeeAlso: ``shouldPreferEligibleRecreateAfterDualAxisLongHorizonExhausted(dualAxisExhausted:languageStillLags:visualStillLags:isRequestEligible:recreationsAttempted:maxRecreations:)``,
    ///   ``ensureAuthoritativeContentOnForegroundIfNeeded()``.
    static func shouldPreferEligibleRecreateAfterContentEnsureFreezeExhausted(
        freezeSoftBudgetExhausted: Bool,
        dualAxisExhausted: Bool,
        languageStillLags: Bool,
        visualStillLags: Bool,
        isRequestEligible: Bool,
        recreationsAttempted: Int,
        maxRecreations: Int = RadioLiveActivityManager.maxInteractiveContentRecreations
    ) -> Bool {
        guard freezeSoftBudgetExhausted || dualAxisExhausted else { return false }
        return shouldRecreateAfterForegroundSoftEnsureFailed(
            languageStillMismatches: languageStillLags,
            playingStillStalled: visualStillLags,
            isRequestEligible: isRequestEligible,
            recreationsAttempted: recreationsAttempted,
            maxRecreations: maxRecreations
        )
    }

    /// Axis-scoped heal decisions after a committed `contentUpdates` or delayed re-read observation.
    ///
    /// Partial acceptance clears / cancels only the converged axis and schedules follow-through
    /// for the lagging axis. Full match resets stall bookkeeping. No-progress yields leave
    /// quiet, post-settled tasks, and stall streak intact (no thrash re-arm).
    ///
    /// - SeeAlso: ``handleActivityContentUpdate(_:)``,
    ///   ``shouldResetStalledContentStreak(candidate:accepted:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    struct ContentUpdateAxisHealPolicy: Equatable, Sendable {
        /// System language equals destination (non-empty).
        let languageConverged: Bool
        /// System visual matches effective actor visual (hold/connect → Connecting).
        let visualConverged: Bool
        /// Authoritative playing visual accepted without hold/connect.
        let playingConverged: Bool
        /// Reset ``consecutiveStalledContentPushes`` + recreation budget.
        let resetStalledStreakAndRecreationBudget: Bool
        let clearLanguageQuiet: Bool
        let cancelLanguagePostSettled: Bool
        let clearLanguageSettleConsume: Bool
        let clearPlayingQuiet: Bool
        let cancelPlayingPostSettled: Bool
        let clearPlayingSettleConsume: Bool
        /// Language landed; re-run / schedule playing soft ensure for residual visual lag.
        let shouldFollowThroughPlayingEnsure: Bool
        /// Playing landed; re-run / schedule language soft ensure for residual language lag.
        let shouldFollowThroughLanguageEnsure: Bool
    }

    /// Builds ``ContentUpdateAxisHealPolicy`` from system-held content vs actor SSOT.
    ///
    /// - Parameters:
    ///   - systemLanguage: `content.state.currentLanguage` from ActivityKit.
    ///   - systemVisual: `content.state.visualState` from ActivityKit.
    ///   - destinationLanguage: ``SharedPlayerManager/liveActivityLanguageCodeForContentPush()``.
    ///   - actorVisual: ``SharedPlayerManager/currentVisualState``.
    ///   - isStreamSwitchHoldActive: Stream-switch Connecting hold.
    ///   - isConnectingPlayback: Play-start pipeline Connecting.
    ///   - priorObservedLanguage: Language observed before this yield (``lastPushedContent``
    ///     prior, or pre-update owned). When non-nil, playing follow-through requires language
    ///     **newly** converged (coarsen same-stream contentUpdates thrash).
    ///   - priorObservedVisual: Visual observed before this yield; when non-nil, language
    ///     follow-through requires playing visual **newly** converged.
    /// - Returns: Axis-scoped heal policy (never invents `.playing` during hold/connect).
    /// - SeeAlso: ``ContentUpdateAxisHealPolicy``, ``applySystemContentUpdateHeal(systemContent:priorObservedLanguage:priorObservedVisual:)``,
    ///   ``didLanguageNewlyConverge(preUpdateOwnedLanguage:acceptedLanguage:candidateLanguage:)``.
    static func contentUpdateAxisHealPolicy(
        systemLanguage: String,
        systemVisual: PlayerVisualState,
        destinationLanguage: String,
        actorVisual: PlayerVisualState,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool,
        priorObservedLanguage: String? = nil,
        priorObservedVisual: PlayerVisualState? = nil
    ) -> ContentUpdateAxisHealPolicy {
        let effectiveVisual: PlayerVisualState =
            (isStreamSwitchHoldActive || isConnectingPlayback) ? .prePlay : actorVisual
        let languageConverged =
            !destinationLanguage.isEmpty && systemLanguage == destinationLanguage
        let visualConverged = systemVisual == effectiveVisual
        let playingConverged =
            !isStreamSwitchHoldActive
            && !isConnectingPlayback
            && actorVisual == .playing
            && systemVisual == .playing

        let candidate = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: effectiveVisual,
            streamMetadata: nil,
            currentLanguage: destinationLanguage
        )
        let accepted = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: systemVisual,
            streamMetadata: nil,
            currentLanguage: systemLanguage
        )
        let resetStreak = shouldResetStalledContentStreak(candidate: candidate, accepted: accepted)

        // Coarsen: true partial follow-through only when the axis newly converged this yield.
        // When prior is unknown (nil), keep follow-through so first observation of convergence
        // still heals the lagging axis (cold / missing suppress memory).
        let languageNewlyConverged: Bool = {
            guard languageConverged else { return false }
            guard let prior = priorObservedLanguage else { return true }
            return prior != destinationLanguage
        }()
        let playingNewlyConverged: Bool = {
            guard playingConverged else { return false }
            guard let prior = priorObservedVisual else { return true }
            return prior != .playing
        }()

        let followPlaying =
            languageNewlyConverged
            && !playingConverged
            && !isStreamSwitchHoldActive
            && !isConnectingPlayback
            && actorVisual == .playing
        let followLanguage =
            playingNewlyConverged
            && !languageConverged
            && !destinationLanguage.isEmpty

        return ContentUpdateAxisHealPolicy(
            languageConverged: languageConverged,
            visualConverged: visualConverged,
            playingConverged: playingConverged,
            resetStalledStreakAndRecreationBudget: resetStreak,
            clearLanguageQuiet: languageConverged,
            cancelLanguagePostSettled: languageConverged,
            clearLanguageSettleConsume: languageConverged,
            // Playing quiet clears only on true playing convergence — not on mere visual match
            // to pause/Connecting. Follow-through explicitly re-arms playing quiet separately.
            clearPlayingQuiet: playingConverged,
            cancelPlayingPostSettled: playingConverged,
            clearPlayingSettleConsume: playingConverged,
            shouldFollowThroughPlayingEnsure: followPlaying,
            shouldFollowThroughLanguageEnsure: followLanguage
        )
    }

    /// Whether soft retries should yield to interactive activity recreation (streak/cap only).
    ///
    /// Does **not** encode request eligibility — callers must also consult
    /// ``isInteractiveLiveActivityRequestEligible(areActivitiesEnabled:isApplicationActive:)``
    /// via ``shouldPerformStalledContentRecreation(consecutiveStalled:recreationsAttempted:isRecreationInProgress:isRequestEligible:threshold:maxRecreations:)``
    /// before ending the only interactive surface.
    ///
    /// - Parameters:
    ///   - consecutiveStalled: Streak of stalled pushes since system-held chrome last matched.
    ///   - recreationsAttempted: Recreations already performed this healthy match cycle.
    ///   - threshold: Minimum streak before recreation (production:
    ///     ``stalledContentPushRecreationThreshold``).
    ///   - maxRecreations: Cap per healthy match cycle (production:
    ///     ``maxInteractiveContentRecreations``).
    ///   - isRecreationInProgress: Nested push during end+start must not schedule recreation again.
    /// - Returns: `true` when stalled-push bookkeeping alone would schedule recreation.
    /// - SeeAlso: ``shouldPerformStalledContentRecreation(consecutiveStalled:recreationsAttempted:isRecreationInProgress:isRequestEligible:threshold:maxRecreations:)``,
    ///   ``updateCurrentActivity()``, docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldRecreateInteractiveLiveActivityAfterStalledPushes(
        consecutiveStalled: Int,
        recreationsAttempted: Int,
        threshold: Int = RadioLiveActivityManager.stalledContentPushRecreationThreshold,
        maxRecreations: Int = RadioLiveActivityManager.maxInteractiveContentRecreations,
        isRecreationInProgress: Bool
    ) -> Bool {
        guard !isRecreationInProgress else { return false }
        guard consecutiveStalled >= threshold else { return false }
        guard recreationsAttempted < maxRecreations else { return false }
        return true
    }

    /// Whether an interactive `Activity.request` is eligible for this process right now.
    ///
    /// Visibility is **start/recreate only**. ``startActivity()`` and stalled-content
    /// recreation must not run `Activity.request` (or a leading ``endActivity()``) when
    /// this returns `false`: destroying the only interactive Live Activity under lock-screen
    /// / background **visibility** constraints leaves the user with audio-only chrome until
    /// a later foreground path succeeds. `Activity.update` on an owned id remains allowed.
    ///
    /// - Parameters:
    ///   - areActivitiesEnabled: `Self.areActivitiesEnabledOnThisHost`.
    ///   - isApplicationActive: `UIApplication.shared.applicationState == .active` (presentable
    ///     for a replacement interactive request; inactive/background is not).
    /// - Returns: `true` when both Live Activities are enabled and the app is active.
    /// - SeeAlso: ``startActivity()``,
    ///   ``interactiveLiveActivityStartDisposition(isRequestEligible:hasOwnedActivity:)``,
    ///   ``shouldPerformStalledContentRecreation(consecutiveStalled:recreationsAttempted:isRecreationInProgress:isRequestEligible:threshold:maxRecreations:)``,
    ///   ``recreateInteractiveLiveActivityAfterStalledContent()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func isInteractiveLiveActivityRequestEligible(
        areActivitiesEnabled: Bool,
        isApplicationActive: Bool
    ) -> Bool {
        areActivitiesEnabled && isApplicationActive
    }

    /// Full decision for end + request recreation: streak/cap **and** request eligibility.
    ///
    /// - Parameters:
    ///   - consecutiveStalled: Stalled-push streak.
    ///   - recreationsAttempted: Recreations already performed this healthy match cycle.
    ///   - isRecreationInProgress: Nested push guard.
    ///   - isRequestEligible: ``isInteractiveLiveActivityRequestEligible(areActivitiesEnabled:isApplicationActive:)``.
    ///   - threshold: Production ``stalledContentPushRecreationThreshold``.
    ///   - maxRecreations: Production ``maxInteractiveContentRecreations``.
    /// - Returns: `true` only when bookkeeping would recreate **and** a replacement request
    ///   is eligible (never end the only interactive surface when start cannot succeed).
    /// - SeeAlso: ``recreateInteractiveLiveActivityAfterStalledContent()``,
    ///   ``shouldRecreateInteractiveLiveActivityAfterStalledPushes(consecutiveStalled:recreationsAttempted:threshold:maxRecreations:isRecreationInProgress:)``.
    static func shouldPerformStalledContentRecreation(
        consecutiveStalled: Int,
        recreationsAttempted: Int,
        isRecreationInProgress: Bool,
        isRequestEligible: Bool,
        threshold: Int = RadioLiveActivityManager.stalledContentPushRecreationThreshold,
        maxRecreations: Int = RadioLiveActivityManager.maxInteractiveContentRecreations
    ) -> Bool {
        guard isRequestEligible else { return false }
        return shouldRecreateInteractiveLiveActivityAfterStalledPushes(
            consecutiveStalled: consecutiveStalled,
            recreationsAttempted: recreationsAttempted,
            threshold: threshold,
            maxRecreations: maxRecreations,
            isRecreationInProgress: isRecreationInProgress
        )
    }

    /// Whether a failed interactive start should record a pending foreground ensure.
    ///
    /// - Parameter currentActivityIsNil: Whether ownership is empty after the attempt.
    /// - Returns: `true` when no interactive activity is owned (recoverable absence).
    /// - SeeAlso: ``startActivity()``, ``ensureInteractiveLiveActivityIfNeeded()``.
    static func shouldMarkPendingInteractiveLiveActivityEnsureAfterStartAttempt(
        currentActivityIsNil: Bool
    ) -> Bool {
        currentActivityIsNil
    }

    /// Whether foreground ensure should request an interactive Live Activity.
    ///
    /// - Parameters:
    ///   - pendingEnsure: ``pendingInteractiveLiveActivityEnsure`` after a deferred recreation
    ///     or failed request.
    ///   - hasCurrentActivity: Whether this process already owns an interactive activity.
    ///   - sessionNeedsInteractiveLiveActivity: Playback session still needs LA chrome
    ///     (authoritative playing / Connecting / sticky pause with live session — see
    ///     ``sessionNeedsInteractiveLiveActivity(isPlaying:visualState:)``).
    ///   - areActivitiesEnabled: User/system Live Activities enabled.
    ///   - isRequestEligible: Application is active (presentable for `Activity.request`).
    /// - Returns: `true` when start should run once (no owned activity, enabled, eligible,
    ///   and either pending recovery or session still needs an interactive surface).
    /// - SeeAlso: ``ensureInteractiveLiveActivityIfNeeded()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldEnsureInteractiveLiveActivityStart(
        pendingEnsure: Bool,
        hasCurrentActivity: Bool,
        sessionNeedsInteractiveLiveActivity: Bool,
        areActivitiesEnabled: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        guard areActivitiesEnabled else { return false }
        guard isRequestEligible else { return false }
        guard !hasCurrentActivity else { return false }
        // Session must still need interactive chrome. Pending recovery alone after stop
        // must not invent a Live Activity (call sites clear pending when `sessionNeeds` is false).
        // Dual path once session needs chrome: deferred recovery (`pendingEnsure`) **or**
        // missing surface under active session (foreground correction without a prior flag).
        return sessionNeedsInteractiveLiveActivity
            && (pendingEnsure || !hasCurrentActivity)
    }

    /// Session policy for whether an interactive Live Activity is still meaningful.
    ///
    /// Matches background auto-start intent: authoritative playing, Connecting attach, or
    /// sticky pause while the main process still owns a live session (paused LA is intentional).
    ///
    /// - Parameters:
    ///   - isPlaying: Shared snapshot / App Group `isPlaying` (background auto-start input).
    ///   - visualState: In-memory ``PlayerVisualState``.
    /// - Returns: `true` when start/ensure should be considered for a missing activity.
    /// - SeeAlso: ``handleAppWillEnterBackground()``, ``ensureInteractiveLiveActivityIfNeeded()``.
    static func sessionNeedsInteractiveLiveActivity(
        isPlaying: Bool,
        visualState: PlayerVisualState
    ) -> Bool {
        if isPlaying { return true }
        if visualState.isActivelyPlaying { return true }
        if visualState == .prePlay { return true }
        if visualState == .userPaused { return true }
        return false
    }

    /// Ends the frozen interactive Live Activity and requests a fresh one with current
    /// language chrome + visual (destination stamp / attach language via
    /// ``SharedPlayerManager/liveActivityLanguageCodeForContentPush()``).
    ///
    /// **Why recreation:** After a **committed** stall (``contentUpdates`` or delayed re-read,
    /// not one immediate post-await snapshot) system-held chrome can stay on a prior language
    /// while audio and widgets advance. Handshake lag is excluded. Soft reconcile cannot
    /// change a surface that never advances ContentState; a new `Activity.request` re-seeds
    /// flag/name/control chrome when request is eligible.
    ///
    /// **Eligibility gate:** Must not run when ``isInteractiveLiveActivityRequestEligible`` is
    /// false — callers gate via ``shouldPerformStalledContentRecreation``; this method
    /// re-checks and defers (keeps existing surface + pending ensure) if still ineligible.
    ///
    /// - Precondition: Main actor; not already inside recreation; test isolation short-circuits
    ///   via ``endActivityAsync`` / ``startActivity()`` guards.
    /// - Postcondition: When eligible: recreation attempt counted; stalled streak cleared;
    ///   either a new interactive activity exists or start failure left pending ensure.
    ///   When ineligible: existing activity retained; pending ensure set; recreation budget
    ///   not consumed.
    /// - Important: Does **not** invent `.playing` — initial ContentState comes from actor
    ///   visual + language SSOT (Connecting remains honest during stream-switch hold).
    /// - SeeAlso: ``updateCurrentActivity()``, ``startActivity()``, ``endActivityAsync(dismissalPolicy:)``,
    ///   ``ensureInteractiveLiveActivityIfNeeded()``,
    ///   ``isInteractiveLiveActivityRequestEligible(areActivitiesEnabled:isApplicationActive:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    @MainActor
    func recreateInteractiveLiveActivityAfterStalledContent() async {
        if SharedPlayerManager.isRunningInUITestMode { return }
        #if DEBUG
        if isRunningUnderTest { return }
        #endif
        guard !isRecreatingLiveActivityAfterStalledContent else { return }

        let requestEligible = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        guard requestEligible else {
            // Defense-in-depth: never end the only interactive surface when request cannot
            // succeed (lock / background visibility). Soft retries + pending ensure remain.
            pendingInteractiveLiveActivityEnsure = true
            #if DEBUG
            print(
                "🔴 Live Activity recreation skipped — interactive request not eligible " +
                "(keeping existing surface; pending ensure recorded)"
            )
            #endif
            return
        }

        isRecreatingLiveActivityAfterStalledContent = true
        interactiveContentRecreationsAttempted += 1
        consecutiveStalledContentPushes = 0
        defer { isRecreatingLiveActivityAfterStalledContent = false }

        #if DEBUG
        print(
            "🔴 Live Activity recreating interactive surface after stalled system-held chrome " +
            "(recreation #\(interactiveContentRecreationsAttempted))"
        )
        #endif

        // Immediate dismissal so the frozen prior-language / pause frame does not linger
        // beside the replacement card. Safe only because request eligibility was verified.
        await endActivityAsync(dismissalPolicy: .immediate)
        await startActivity()
        // startActivity sets pending ensure on failure / clears it on success.
    }

    /// Whether ActivityKit IPC should be skipped for this candidate.
    ///
    /// Suppress is an optimization: never skip when the owned surface still disagrees with
    /// the candidate on **language** or **visual**, even if in-process ``lastPushedContent``
    /// already equals the candidate (optimistic stream-switch / toggle alignment or a push
    /// that did not change the visible surface).
    ///
    /// - Parameters:
    ///   - lastPushed: In-process suppress memory (may be optimistically advanced).
    ///   - candidate: Freshly built ContentState for this push.
    ///   - ownedContentLanguage: Owned `Activity.content.state.currentLanguage` when an
    ///     interactive activity is tracked; pass `nil` only when unowned (language gate skipped).
    ///   - ownedContentVisual: Owned `Activity.content.state.visualState` when tracked;
    ///     pass `nil` only when unowned (visual gate skipped).
    /// - Returns: `true` when the push would be a no-op against suppress memory **and**
    ///   owned language + visual chrome.
    /// - SeeAlso: ``updateCurrentActivity()``, ``ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``ensureAuthoritativePlayingContentIfNeeded()``,
    ///   ``_test_wouldSuppressLiveActivityUpdate(visualState:streamMetadata:currentLanguage:ownedContentLanguage:ownedContentVisual:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldSuppressLiveActivityContentPush(
        lastPushed: LutheranRadioLiveActivityAttributes.ContentState?,
        candidate: LutheranRadioLiveActivityAttributes.ContentState,
        ownedContentLanguage: String?,
        ownedContentVisual: PlayerVisualState? = nil
    ) -> Bool {
        // Language is the hard requirement for lock-screen flag/name/alt-current chrome.
        if !candidate.currentLanguage.isEmpty,
           let owned = ownedContentLanguage,
           owned != candidate.currentLanguage {
            return false
        }
        // Control glyph SSOT: optimistic lastPushed must not claim playing/pause while
        // the system-held surface still shows Connecting (or the reverse).
        if let ownedVisual = ownedContentVisual,
           ownedVisual != candidate.visualState {
            return false
        }
        if let last = lastPushed, last == candidate {
            return true
        }
        return false
    }

    /// Chooses suppress-memory ContentState after a real `Activity.update` await.
    ///
    /// Never claims the candidate language when the system-held `content.state` still
    /// reports a different language (failed acceptance, stale handle, silent no-op).
    ///
    /// - Parameters:
    ///   - candidate: Content that was submitted to ActivityKit.
    ///   - acceptedSystemContent: Re-read `activity.content.state` after the update await.
    /// - Returns: Value to store in ``lastPushedContent``.
    /// - SeeAlso: ``updateCurrentActivity()``, ``shouldSuppressLiveActivityContentPush(lastPushed:candidate:ownedContentLanguage:)``.
    static func suppressMemoryAfterActivityUpdate(
        candidate: LutheranRadioLiveActivityAttributes.ContentState,
        acceptedSystemContent: LutheranRadioLiveActivityAttributes.ContentState
    ) -> LutheranRadioLiveActivityAttributes.ContentState {
        // Both language-mismatch and match branches return system-held chrome so suppress
        // memory never claims an unverified candidate. `candidate` remains in the signature
        // so call sites document what was submitted.
        _ = candidate
        return acceptedSystemContent
    }

    /// Whether a language reconcile push is needed for an interactive Live Activity.
    ///
    /// - Parameters:
    ///   - destinationLanguage: ``SharedPlayerManager/liveActivityLanguageCodeForContentPush()``.
    ///   - ownedContentLanguage: Owned `content.state.currentLanguage`, if any.
    ///   - lastPushedLanguage: ``lastPushedContent`` language, if any.
    /// - Returns: `true` when destination is non-empty and either owned or last-pushed
    ///   language does not match (or is missing).
    /// - Note: Does not invent `.playing` — only decides whether language chrome needs a push.
    /// - SeeAlso: ``ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``shouldRunLanguageContentEnsureSoftPushes(needsLanguageEnsure:destinationLanguage:quietPendingDestination:isRequestEligible:)``.
    static func shouldEnsureAuthoritativeLanguageContent(
        destinationLanguage: String,
        ownedContentLanguage: String?,
        lastPushedLanguage: String?
    ) -> Bool {
        guard !destinationLanguage.isEmpty else { return false }
        if ownedContentLanguage != destinationLanguage { return true }
        if lastPushedLanguage != destinationLanguage { return true }
        return false
    }

    /// Whether soft language-ensure pushes should run now, or stay quiet after budget exhaustion.
    ///
    /// After ``authoritativeLanguageContentEnsureMaxAttempts`` while request is ineligible,
    /// the manager records ``languageEnsureQuietPendingDestination``. Further ensure-driven
    /// soft pushes for the **same** destination stay quiet until re-arm so status-driven
    /// media-surface refreshes do not re-burn the soft-retry budget without acceptance.
    ///
    /// **Re-arm (returns true when language ensure is still needed):**
    /// - No quiet pending yet
    /// - Destination language changed (new stream-switch mutation — high-priority push)
    /// - Interactive request became eligible (presentable cycle / unlock)
    ///
    /// - Parameters:
    ///   - needsLanguageEnsure: ``shouldEnsureAuthoritativeLanguageContent(destinationLanguage:ownedContentLanguage:lastPushedLanguage:)``.
    ///   - destinationLanguage: Current ``liveActivityLanguageCodeForContentPush()``.
    ///   - quietPendingDestination: ``languageEnsureQuietPendingDestination`` (nil when not quiet).
    ///   - isRequestEligible: ``isInteractiveLiveActivityRequestEligible(areActivitiesEnabled:isApplicationActive:)``.
    /// - Returns: `true` when soft language pushes should run.
    /// - SeeAlso: ``ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``quietPendingDestinationAfterLanguageEnsureExhaustion(languageStillMismatches:isRequestEligible:destinationLanguage:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldRunLanguageContentEnsureSoftPushes(
        needsLanguageEnsure: Bool,
        destinationLanguage: String,
        quietPendingDestination: String?,
        isRequestEligible: Bool
    ) -> Bool {
        guard needsLanguageEnsure else { return false }
        guard !destinationLanguage.isEmpty else { return false }
        // Re-arm when request is eligible (unlock / presentable cycle).
        if isRequestEligible { return true }
        // Quiet only for the same destination while still ineligible.
        if let quiet = quietPendingDestination, quiet == destinationLanguage {
            return false
        }
        // No quiet yet, or destination changed → high-priority push for the new language.
        return true
    }

    /// Destination to store as quiet-pending after language soft-ensure budget exhaustion.
    ///
    /// - Parameters:
    ///   - languageStillMismatches: Owned / last language still ≠ destination after the last attempt.
    ///   - isRequestEligible: Whether interactive `Activity.request` could succeed now.
    ///   - destinationLanguage: Destination that failed acceptance.
    /// - Returns: `destinationLanguage` when quiet should engage; `nil` when request is eligible
    ///   (keep soft ensure available / let foreground recreation path own recovery) or language matched.
    /// - SeeAlso: ``shouldRunLanguageContentEnsureSoftPushes(needsLanguageEnsure:destinationLanguage:quietPendingDestination:isRequestEligible:)``.
    static func quietPendingDestinationAfterLanguageEnsureExhaustion(
        languageStillMismatches: Bool,
        isRequestEligible: Bool,
        destinationLanguage: String
    ) -> String? {
        guard languageStillMismatches else { return nil }
        guard !isRequestEligible else { return nil }
        guard !destinationLanguage.isEmpty else { return nil }
        return destinationLanguage
    }

    /// Whether a status-driven `Activity.update` that is only repairing language stall should
    /// defer while language ensure is quiet-pending for the same destination.
    ///
    /// Protects lock-stretch thrash: after soft language ensure exhausted while request is
    /// ineligible, every media-surface refresh would otherwise re-submit the same language
    /// candidate (owned-language suppress gate correctly denies suppress). Visual mutations
    /// still push — quiet is language-only.
    ///
    /// - Parameters:
    ///   - candidateLanguage: Candidate ``ContentState.currentLanguage``.
    ///   - ownedContentLanguage: Owned `content.state.currentLanguage`.
    ///   - ownedContentVisual: Owned `content.state.visualState`.
    ///   - candidateVisual: Candidate visual.
    ///   - quietPendingDestination: ``languageEnsureQuietPendingDestination``.
    ///   - isRequestEligible: Interactive request eligibility.
    /// - Returns: `true` when ActivityKit IPC should be skipped for this language-only stall.
    /// - SeeAlso: ``updateCurrentActivity()``, ``shouldRunLanguageContentEnsureSoftPushes(needsLanguageEnsure:destinationLanguage:quietPendingDestination:isRequestEligible:)``.
    static func shouldDeferRedundantLanguagePushWhileQuiet(
        candidateLanguage: String,
        ownedContentLanguage: String,
        ownedContentVisual: PlayerVisualState,
        candidateVisual: PlayerVisualState,
        quietPendingDestination: String?,
        isRequestEligible: Bool
    ) -> Bool {
        guard let quiet = quietPendingDestination else { return false }
        guard !isRequestEligible else { return false }
        guard quiet == candidateLanguage else { return false }
        // Visual still differs → push (pause honesty, playing ensure, Connecting hold).
        if ownedContentVisual != candidateVisual { return false }
        // Language already matches → not a language stall (suppress policy handles no-op).
        if ownedContentLanguage == candidateLanguage { return false }
        return true
    }

    /// Whether quiet-pending language ensure should clear after a system content yield or
    /// owned-language convergence.
    ///
    /// - Parameters:
    ///   - quietPendingDestination: Current quiet destination, if any.
    ///   - destinationLanguage: Current destination language code.
    ///   - ownedOrSystemLanguage: Owned or system-accepted `content.state.currentLanguage`.
    /// - Returns: `true` when quiet should clear (re-arm for a later lag, or destination advanced).
    /// - SeeAlso: ``handleActivityContentUpdate(_:)``, ``ensureAuthoritativeLanguageContentIfNeeded()``.
    static func shouldClearLanguageEnsureQuietPending(
        quietPendingDestination: String?,
        destinationLanguage: String,
        ownedOrSystemLanguage: String?
    ) -> Bool {
        guard quietPendingDestination != nil else { return false }
        // System / owned accepted destination — quiet work is done.
        if let ownedOrSystemLanguage, ownedOrSystemLanguage == destinationLanguage {
            return true
        }
        // Destination moved on — re-arm for the new language (caller also re-arms via
        // shouldRun when quiet != destination).
        if let quiet = quietPendingDestination, quiet != destinationLanguage {
            return true
        }
        return false
    }

    /// Whether a post-hold **settled** language acceptance soft-ensure re-arm should run.
    ///
    /// Soft language ensure often burns its budget during the stream-switch attach storm while
    /// Connecting, then quiet-pending blocks further status-driven pushes for that destination.
    /// When stream-switch hold clears (authoritative audible start / soft-resume), one post-hold
    /// soft language-ensure re-arm is allowed even though quiet would otherwise defer language-only
    /// status re-pushes. Consume-once per destination while request stays ineligible prevents
    /// soft-resume no-op thrash of the settle entry; eligibility re-opens the settle window
    /// (unlock recovery). Bounded delayed post-settled retries continue after the entry without
    /// re-opening this gate.
    ///
    /// - Parameters:
    ///   - destinationLanguage: ``SharedPlayerManager/liveActivityLanguageCodeForContentPush()``.
    ///   - ownedContentLanguage: Owned `content.state.currentLanguage`, if any.
    ///   - isStreamSwitchHoldActive: ``SharedPlayerManager/isStreamSwitchPrePlayHoldActive`` —
    ///     settle waits until hold clears (Connecting honesty preserved).
    ///   - settledAcceptanceConsumedDestination: ``languageSettledAcceptanceConsumedDestination``.
    ///   - isRequestEligible: ``isInteractiveLiveActivityRequestEligible(areActivitiesEnabled:isApplicationActive:)``.
    /// - Returns: `true` when a post-hold language soft-ensure re-arm should run.
    /// - Note: Does **not** invent `.playing` during hold (hold gate). Does **not** end+request.
    /// - SeeAlso: ``pushSettledLanguageAcceptanceContentIfNeeded()``,
    ///   ``shouldSchedulePostSettledLanguageEnsureRetries(hasCurrentActivity:destinationLanguage:ownedContentLanguage:isStreamSwitchHoldActive:)``,
    ///   ``shouldDeferRedundantLanguagePushWhileQuiet(candidateLanguage:ownedContentLanguage:ownedContentVisual:candidateVisual:quietPendingDestination:isRequestEligible:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldPushSettledLanguageAcceptance(
        destinationLanguage: String,
        ownedContentLanguage: String?,
        isStreamSwitchHoldActive: Bool,
        settledAcceptanceConsumedDestination: String?,
        isRequestEligible: Bool
    ) -> Bool {
        guard !destinationLanguage.isEmpty else { return false }
        // Hold still active — Connecting honesty window; wait for authoritative setPlaying.
        guard !isStreamSwitchHoldActive else { return false }
        // Already on destination — no settle work.
        if let ownedContentLanguage, ownedContentLanguage == destinationLanguage {
            return false
        }
        // Consume-once while locked / ineligible: avoid soft-resume no-op re-thrash.
        if let consumed = settledAcceptanceConsumedDestination,
           consumed == destinationLanguage,
           !isRequestEligible {
            return false
        }
        // Eligible (unlock / presentable): always allow settle when language still lags.
        // Ineligible: allow when not yet consumed for this destination.
        return true
    }

    /// Whether bounded delayed post-settled language soft-ensure retries should be scheduled.
    ///
    /// After the post-hold settle soft-ensure re-arm still leaves owned language lagging the
    /// destination, status-driven thrash re-enters quiet. Delayed retries re-clear quiet on a
    /// longer cadence so ActivityKit can accept destination language while request stays
    /// ineligible — without end+request and without re-burning attach-storm status callbacks.
    ///
    /// - Parameters:
    ///   - hasCurrentActivity: Whether this process owns an interactive activity.
    ///   - destinationLanguage: ``SharedPlayerManager/liveActivityLanguageCodeForContentPush()``.
    ///   - ownedContentLanguage: Owned `content.state.currentLanguage`, if any.
    ///   - isStreamSwitchHoldActive: ``SharedPlayerManager/isStreamSwitchPrePlayHoldActive``.
    /// - Returns: `true` when ownership is non-nil, hold is clear, destination is non-empty, and
    ///   owned language is missing or still ≠ destination.
    /// - Note: Does **not** invent `.playing`. Does **not** decide end+request.
    /// - SeeAlso: ``schedulePostSettledLanguageEnsureRetriesIfNeeded(destination:)``,
    ///   ``pushSettledLanguageAcceptanceContentIfNeeded()``,
    ///   ``postSettledLanguageEnsureDelayedIntervalsMilliseconds``.
    static func shouldSchedulePostSettledLanguageEnsureRetries(
        hasCurrentActivity: Bool,
        destinationLanguage: String,
        ownedContentLanguage: String?,
        isStreamSwitchHoldActive: Bool
    ) -> Bool {
        guard hasCurrentActivity else { return false }
        guard !destinationLanguage.isEmpty else { return false }
        guard !isStreamSwitchHoldActive else { return false }
        if let ownedContentLanguage, ownedContentLanguage == destinationLanguage {
            return false
        }
        return true
    }

    /// Whether settled-acceptance consume should clear when destination advances or language converges.
    ///
    /// - Parameters:
    ///   - settledAcceptanceConsumedDestination: Current consume marker, if any.
    ///   - destinationLanguage: Current destination language code.
    ///   - ownedOrSystemLanguage: Owned or system-accepted language, if any.
    /// - Returns: `true` when consume should clear (new destination, or owned matches destination).
    /// - SeeAlso: ``pushSettledLanguageAcceptanceContentIfNeeded()``,
    ///   ``recordOptimisticStreamSwitchContent(language:visualState:)``.
    static func shouldClearLanguageSettledAcceptanceConsume(
        settledAcceptanceConsumedDestination: String?,
        destinationLanguage: String,
        ownedOrSystemLanguage: String?
    ) -> Bool {
        guard settledAcceptanceConsumedDestination != nil else { return false }
        if let ownedOrSystemLanguage, !destinationLanguage.isEmpty,
           ownedOrSystemLanguage == destinationLanguage {
            return true
        }
        if let consumed = settledAcceptanceConsumedDestination,
           !destinationLanguage.isEmpty,
           consumed != destinationLanguage {
            return true
        }
        return false
    }

    /// Whether a post-hold **settled** playing acceptance push should run.
    ///
    /// Soft playing ensure often burns its budget (or never runs usefully while hold is active)
    /// during stream-switch attach, then quiet-pending blocks visual-only `.playing` repair for
    /// the rest of a lock stretch. When hold/connect clear and the actor is authoritative
    /// `.playing`, one post-hold soft playing-ensure re-arm is allowed even though quiet would
    /// otherwise defer playing-only status re-pushes. Consume-once while request stays ineligible
    /// prevents soft-resume no-op thrash of the settle entry; eligibility re-opens the settle
    /// window (unlock recovery). Bounded delayed post-settled retries continue after the entry
    /// without re-opening this gate.
    ///
    /// - Parameters:
    ///   - actorVisual: Actor ``SharedPlayerManager/currentVisualState``.
    ///   - ownedContentVisual: Owned `content.state.visualState`, if any.
    ///   - isStreamSwitchHoldActive: ``SharedPlayerManager/isStreamSwitchPrePlayHoldActive``.
    ///   - isConnectingPlayback: ``SharedPlayerManager/isConnectingPlayback``.
    ///   - settledAcceptanceConsumed: ``playingSettledAcceptanceConsumed``.
    ///   - isRequestEligible: ``isInteractiveLiveActivityRequestEligible(areActivitiesEnabled:isApplicationActive:)``.
    /// - Returns: `true` when a post-hold playing soft-ensure re-arm should run.
    /// - Note: Does **not** invent `.playing` during hold/connect. Does **not** end+request.
    /// - SeeAlso: ``pushSettledPlayingAcceptanceContentIfNeeded()``,
    ///   ``shouldSchedulePostSettledPlayingEnsureRetries(hasCurrentActivity:actorVisual:ownedContentVisual:isStreamSwitchHoldActive:isConnectingPlayback:)``,
    ///   ``shouldDeferRedundantPlayingPushWhileQuiet(candidateVisual:ownedContentVisual:ownedContentLanguage:candidateLanguage:quietPending:isRequestEligible:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldPushSettledPlayingAcceptance(
        actorVisual: PlayerVisualState,
        ownedContentVisual: PlayerVisualState?,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool,
        settledAcceptanceConsumed: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        // Only when actor is authoritative playing (no Connecting honesty window).
        guard actorVisual == .playing else { return false }
        guard !isStreamSwitchHoldActive, !isConnectingPlayback else { return false }
        // Owned already playing — no settle work.
        if ownedContentVisual == .playing { return false }
        // Consume-once while locked / ineligible: avoid soft-resume no-op re-thrash.
        if settledAcceptanceConsumed, !isRequestEligible {
            return false
        }
        // Eligible (unlock / presentable): always allow settle when visual still lags.
        // Ineligible: allow when not yet consumed for this play cycle.
        return true
    }

    /// Whether settled playing-acceptance consume should clear when owned visual converges.
    ///
    /// - Parameters:
    ///   - settledAcceptanceConsumed: Current consume marker.
    ///   - ownedOrSystemVisual: Owned or system-accepted visual, if any.
    /// - Returns: `true` when consume should clear (owned reached `.playing`).
    /// - SeeAlso: ``pushSettledPlayingAcceptanceContentIfNeeded()``,
    ///   ``recordOptimisticToggleContent(visualState:)``,
    ///   ``recordOptimisticStreamSwitchContent(language:visualState:)``.
    static func shouldClearPlayingSettledAcceptanceConsume(
        settledAcceptanceConsumed: Bool,
        ownedOrSystemVisual: PlayerVisualState?
    ) -> Bool {
        guard settledAcceptanceConsumed else { return false }
        if ownedOrSystemVisual == .playing { return true }
        return false
    }

    /// Whether bounded delayed post-settled playing soft-ensure retries should be scheduled.
    ///
    /// After the post-hold settle soft-ensure re-arm still leaves owned visual lagging
    /// authoritative `.playing`, status-driven thrash re-enters quiet. Delayed retries re-clear
    /// quiet on a longer cadence so ActivityKit can accept `.playing` while request stays
    /// ineligible — without end+request and without re-burning attach-storm status callbacks.
    ///
    /// - Parameters:
    ///   - hasCurrentActivity: Whether this process owns an interactive activity.
    ///   - actorVisual: Actor ``SharedPlayerManager/currentVisualState``.
    ///   - ownedContentVisual: Owned `content.state.visualState`, if any.
    ///   - isStreamSwitchHoldActive: ``SharedPlayerManager/isStreamSwitchPrePlayHoldActive``.
    ///   - isConnectingPlayback: ``SharedPlayerManager/isConnectingPlayback``.
    /// - Returns: `true` when ownership is non-nil, hold/connect are clear, actor is
    ///   authoritative `.playing`, and owned visual is missing or still ≠ `.playing`.
    /// - Note: Does **not** invent `.playing` during hold/connect. Does **not** decide end+request.
    /// - SeeAlso: ``schedulePostSettledPlayingEnsureRetriesIfNeeded()``,
    ///   ``pushSettledPlayingAcceptanceContentIfNeeded()``,
    ///   ``postSettledPlayingEnsureDelayedIntervalsMilliseconds``.
    static func shouldSchedulePostSettledPlayingEnsureRetries(
        hasCurrentActivity: Bool,
        actorVisual: PlayerVisualState,
        ownedContentVisual: PlayerVisualState?,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool
    ) -> Bool {
        guard hasCurrentActivity else { return false }
        guard actorVisual == .playing else { return false }
        guard !isStreamSwitchHoldActive, !isConnectingPlayback else { return false }
        if ownedContentVisual == .playing { return false }
        return true
    }

    // MARK: - Post-quiet sparse long-horizon ensure (pure policy)

    /// Whether sparse post-quiet long-horizon **playing** ensure should arm for this freeze.
    ///
    /// Arms only while request is **ineligible** and owned visual still lags authoritative
    /// `.playing`. When already armed, leave the in-flight horizon (do not thrash re-schedule).
    /// When request is eligible, soft ensure / foreground owned-surface ensure own recovery.
    ///
    /// - Parameters:
    ///   - hasCurrentActivity: Whether this process owns an interactive activity.
    ///   - isRequestEligible: Interactive `Activity.request` eligibility.
    ///   - longHorizonAlreadyArmed: Whether ``postQuietLongHorizonPlayingEnsureTask`` is non-nil.
    ///   - actorVisual: Actor ``currentVisualState``.
    ///   - lastPushedVisual: ``lastPushedContent`` visual, if any.
    ///   - ownedContentVisual: Owned `content.state.visualState`, if any.
    ///   - isStreamSwitchHoldActive: Stream-switch Connecting hold.
    ///   - isConnectingPlayback: Play-start pipeline Connecting.
    /// - Returns: `true` when a new long-horizon playing rail should schedule.
    /// - Note: Does **not** invent `.playing` during hold/connect. Does **not** end+request.
    /// - SeeAlso: ``armPostQuietLongHorizonPlayingEnsureIfNeeded()``,
    ///   ``shouldEnsureAuthoritativePlayingContent(actorVisual:streamSwitchHold:isConnectingPlayback:lastPushedVisual:ownedVisual:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldArmPostQuietLongHorizonPlayingEnsure(
        hasCurrentActivity: Bool,
        isRequestEligible: Bool,
        longHorizonAlreadyArmed: Bool,
        actorVisual: PlayerVisualState,
        lastPushedVisual: PlayerVisualState?,
        ownedContentVisual: PlayerVisualState?,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool
    ) -> Bool {
        guard hasCurrentActivity else { return false }
        guard !longHorizonAlreadyArmed else { return false }
        guard !isRequestEligible else { return false }
        return shouldEnsureAuthoritativePlayingContent(
            actorVisual: actorVisual,
            streamSwitchHold: isStreamSwitchHoldActive,
            isConnectingPlayback: isConnectingPlayback,
            lastPushedVisual: lastPushedVisual,
            ownedVisual: ownedContentVisual
        )
    }

    /// Whether sparse post-quiet long-horizon **language** ensure should arm for this freeze.
    ///
    /// - Parameters:
    ///   - hasCurrentActivity: Whether this process owns an interactive activity.
    ///   - isRequestEligible: Interactive `Activity.request` eligibility.
    ///   - longHorizonAlreadyArmed: Whether ``postQuietLongHorizonLanguageEnsureTask`` is non-nil.
    ///   - destinationLanguage: ``liveActivityLanguageCodeForContentPush()``.
    ///   - lastPushedLanguage: ``lastPushedContent`` language, if any.
    ///   - ownedContentLanguage: Owned `content.state.currentLanguage`, if any.
    ///   - isStreamSwitchHoldActive: Stream-switch Connecting hold (settle waits for hold clear).
    /// - Returns: `true` when a new long-horizon language rail should schedule.
    /// - Note: Does **not** invent `.playing`. Does **not** end+request.
    /// - SeeAlso: ``armPostQuietLongHorizonLanguageEnsureIfNeeded()``,
    ///   ``shouldEnsureAuthoritativeLanguageContent(destinationLanguage:ownedContentLanguage:lastPushedLanguage:)``.
    static func shouldArmPostQuietLongHorizonLanguageEnsure(
        hasCurrentActivity: Bool,
        isRequestEligible: Bool,
        longHorizonAlreadyArmed: Bool,
        destinationLanguage: String,
        lastPushedLanguage: String?,
        ownedContentLanguage: String?,
        isStreamSwitchHoldActive: Bool
    ) -> Bool {
        guard hasCurrentActivity else { return false }
        guard !longHorizonAlreadyArmed else { return false }
        guard !isRequestEligible else { return false }
        guard !isStreamSwitchHoldActive else { return false }
        guard !destinationLanguage.isEmpty else { return false }
        return shouldEnsureAuthoritativeLanguageContent(
            destinationLanguage: destinationLanguage,
            ownedContentLanguage: ownedContentLanguage,
            lastPushedLanguage: lastPushedLanguage
        )
    }

    /// Whether an in-flight long-horizon **playing** fire should still run soft ensure.
    ///
    /// - SeeAlso: ``shouldArmPostQuietLongHorizonPlayingEnsure(hasCurrentActivity:isRequestEligible:longHorizonAlreadyArmed:actorVisual:lastPushedVisual:ownedContentVisual:isStreamSwitchHoldActive:isConnectingPlayback:)``.
    static func shouldContinuePostQuietLongHorizonPlayingEnsure(
        hasCurrentActivity: Bool,
        actorVisual: PlayerVisualState,
        lastPushedVisual: PlayerVisualState?,
        ownedContentVisual: PlayerVisualState?,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool
    ) -> Bool {
        guard hasCurrentActivity else { return false }
        return shouldEnsureAuthoritativePlayingContent(
            actorVisual: actorVisual,
            streamSwitchHold: isStreamSwitchHoldActive,
            isConnectingPlayback: isConnectingPlayback,
            lastPushedVisual: lastPushedVisual,
            ownedVisual: ownedContentVisual
        )
    }

    /// Whether an in-flight long-horizon **language** fire should still run soft ensure.
    ///
    /// - SeeAlso: ``shouldArmPostQuietLongHorizonLanguageEnsure(hasCurrentActivity:isRequestEligible:longHorizonAlreadyArmed:destinationLanguage:lastPushedLanguage:ownedContentLanguage:isStreamSwitchHoldActive:)``.
    static func shouldContinuePostQuietLongHorizonLanguageEnsure(
        hasCurrentActivity: Bool,
        destinationLanguage: String,
        lastPushedLanguage: String?,
        ownedContentLanguage: String?,
        isStreamSwitchHoldActive: Bool
    ) -> Bool {
        guard hasCurrentActivity else { return false }
        guard !isStreamSwitchHoldActive else { return false }
        guard !destinationLanguage.isEmpty else { return false }
        return shouldEnsureAuthoritativeLanguageContent(
            destinationLanguage: destinationLanguage,
            ownedContentLanguage: ownedContentLanguage,
            lastPushedLanguage: lastPushedLanguage
        )
    }

    /// Whether the playing long-horizon rail should cancel (ownership gone, accepted, or actor left play).
    ///
    /// - SeeAlso: ``cancelPostQuietLongHorizonPlayingEnsure()``.
    static func shouldCancelPostQuietLongHorizonPlayingEnsure(
        hasCurrentActivity: Bool,
        ownedContentVisual: PlayerVisualState?,
        actorVisual: PlayerVisualState
    ) -> Bool {
        if !hasCurrentActivity { return true }
        if ownedContentVisual == .playing { return true }
        if actorVisual != .playing { return true }
        return false
    }

    /// Whether the language long-horizon rail should cancel (ownership gone, accepted, or empty dest).
    ///
    /// - SeeAlso: ``cancelPostQuietLongHorizonLanguageEnsure()``.
    static func shouldCancelPostQuietLongHorizonLanguageEnsure(
        hasCurrentActivity: Bool,
        destinationLanguage: String,
        ownedContentLanguage: String?
    ) -> Bool {
        if !hasCurrentActivity { return true }
        if destinationLanguage.isEmpty { return true }
        if let ownedContentLanguage, ownedContentLanguage == destinationLanguage {
            return true
        }
        return false
    }

    /// Whether post-quiet language long-horizon must keep the owned glyph after freeze.
    ///
    /// After freeze soft budget exhausts or playing quiet is pending while request is
    /// ineligible, Apple still applies same-visual language updates; dual-axis
    /// playing+language in that sparse slot delays language and still fails the glyph.
    /// Dual-axis settle at ``setPlaying()`` after hold clear is the first co-push and is
    /// not this rail. Request-eligible (presentable) recovery still may co-push.
    ///
    /// - Parameters:
    ///   - freezeSoftBudgetExhausted: ``contentEnsureFreezeSoftBudgetExhausted``.
    ///   - playingQuietPending: ``playingEnsureQuietPending``.
    ///   - isRequestEligible: Interactive `Activity.request` eligibility.
    /// - Returns: `true` when language long-horizon must preserve owned visual.
    /// - Note: Does **not** invent `.playing`. Does **not** end+request.
    /// - SeeAlso: ``languageOnlyLongHorizonCandidateVisual(ownedVisual:actorResolvedVisual:keepOwnedVisual:)``,
    ///   ``shouldArmPostQuietLongHorizonDualAxisEnsure(hasCurrentActivity:isRequestEligible:dualAxisAlreadyArmed:languageStillLags:visualStillLags:actorVisual:isStreamSwitchHoldActive:isConnectingPlayback:freezeSoftBudgetExhausted:playingQuietPending:)``,
    ///   ``ContentState/replacingCurrentLanguage(_:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldKeepOwnedVisualOnPostQuietLanguageLongHorizon(
        freezeSoftBudgetExhausted: Bool,
        playingQuietPending: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        guard !isRequestEligible else { return false }
        return freezeSoftBudgetExhausted || playingQuietPending
    }

    /// Candidate visual for a post-quiet language long-horizon fire.
    ///
    /// After freeze, dest language rides the owned glyph. Before freeze (or when
    /// presentable), actor-resolved visual stands.
    ///
    /// - Parameters:
    ///   - ownedVisual: Owned `content.state.visualState`.
    ///   - actorResolvedVisual: ``resolveContentPushVisual(visualState:streamSwitchHold:isConnectingPlayback:)``.
    ///   - keepOwnedVisual: ``shouldKeepOwnedVisualOnPostQuietLanguageLongHorizon(freezeSoftBudgetExhausted:playingQuietPending:isRequestEligible:)``.
    /// - Returns: Owned visual when keeping the glyph; otherwise the actor-resolved visual.
    /// - SeeAlso: ``shouldPreserveOwnedVisualOnLanguageOnlyContentPush(keepOwnedVisualAfterFreeze:isStreamSwitchHoldActive:)``.
    static func languageOnlyLongHorizonCandidateVisual(
        ownedVisual: PlayerVisualState,
        actorResolvedVisual: PlayerVisualState,
        keepOwnedVisual: Bool
    ) -> PlayerVisualState {
        keepOwnedVisual ? ownedVisual : actorResolvedVisual
    }

    /// Whether ``updateCurrentActivity(preservingOwnedVisual:)`` may keep the owned glyph.
    ///
    /// Stream-switch hold still publishes Connecting + destination language. Same-stream
    /// Connecting after freeze preserves paused/playing (owned glyph is the thing we
    /// must not overwrite).
    ///
    /// - Parameters:
    ///   - keepOwnedVisualAfterFreeze: ``shouldKeepOwnedVisualOnPostQuietLanguageLongHorizon(freezeSoftBudgetExhausted:playingQuietPending:isRequestEligible:)``.
    ///   - isStreamSwitchHoldActive: Stream-switch Connecting hold.
    /// - Returns: `true` when the ActivityKit candidate must use owned visual.
    /// - SeeAlso: ``ContentState/replacingCurrentLanguage(_:)``.
    static func shouldPreserveOwnedVisualOnLanguageOnlyContentPush(
        keepOwnedVisualAfterFreeze: Bool,
        isStreamSwitchHoldActive: Bool
    ) -> Bool {
        guard keepOwnedVisualAfterFreeze else { return false }
        guard !isStreamSwitchHoldActive else { return false }
        return true
    }

    /// Whether both ContentState axes lag while the actor is authoritative `.playing` without hold.
    ///
    /// Long-horizon fires use this to clear **both** quiet flags and run dual soft ensure so
    /// language quiet cannot starve playing repair (and the reverse) under continuous lock
    /// **before** freeze. After freeze / playing quiet while ineligible, dual-axis
    /// long-horizon is skipped — language-only preserves owned visual; playing long-horizon
    /// remains the visual rail.
    /// Status-driven ``shouldDeferRedundantLanguagePushWhileQuiet`` already allows IPC when visual
    /// differs; this policy covers soft-ensure entry after quiet engagement.
    ///
    /// - Note: Does **not** invent `.playing` during hold/connect.
    /// - SeeAlso: ``shouldKeepOwnedVisualOnPostQuietLanguageLongHorizon(freezeSoftBudgetExhausted:playingQuietPending:isRequestEligible:)``,
    ///   ``shouldClearLanguageQuietForDualAxisLongHorizonFire(languageQuietPending:languageStillLags:visualStillLags:actorVisual:isStreamSwitchHoldActive:isConnectingPlayback:freezeSoftBudgetExhausted:playingQuietPending:isRequestEligible:)``,
    ///   ``shouldClearPlayingQuietForDualAxisLongHorizonFire(playingQuietPending:languageStillLags:visualStillLags:actorVisual:isStreamSwitchHoldActive:isConnectingPlayback:freezeSoftBudgetExhausted:isRequestEligible:)``.
    static func shouldRunPostQuietLongHorizonDualAxisEnsure(
        languageStillLags: Bool,
        visualStillLags: Bool,
        actorVisual: PlayerVisualState,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool,
        freezeSoftBudgetExhausted: Bool = false,
        playingQuietPending: Bool = false,
        isRequestEligible: Bool = false
    ) -> Bool {
        if shouldKeepOwnedVisualOnPostQuietLanguageLongHorizon(
            freezeSoftBudgetExhausted: freezeSoftBudgetExhausted,
            playingQuietPending: playingQuietPending,
            isRequestEligible: isRequestEligible
        ) {
            return false
        }
        guard actorVisual == .playing else { return false }
        guard !isStreamSwitchHoldActive, !isConnectingPlayback else { return false }
        return languageStillLags && visualStillLags
    }

    /// Whether a playing long-horizon fire should also clear language quiet for dual-axis soft ensure.
    ///
    /// - SeeAlso: ``shouldRunPostQuietLongHorizonDualAxisEnsure(languageStillLags:visualStillLags:actorVisual:isStreamSwitchHoldActive:isConnectingPlayback:)``.
    static func shouldClearLanguageQuietForDualAxisLongHorizonFire(
        languageQuietPending: Bool,
        languageStillLags: Bool,
        visualStillLags: Bool,
        actorVisual: PlayerVisualState,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool,
        freezeSoftBudgetExhausted: Bool = false,
        playingQuietPending: Bool = false,
        isRequestEligible: Bool = false
    ) -> Bool {
        guard languageQuietPending else { return false }
        return shouldRunPostQuietLongHorizonDualAxisEnsure(
            languageStillLags: languageStillLags,
            visualStillLags: visualStillLags,
            actorVisual: actorVisual,
            isStreamSwitchHoldActive: isStreamSwitchHoldActive,
            isConnectingPlayback: isConnectingPlayback,
            freezeSoftBudgetExhausted: freezeSoftBudgetExhausted,
            playingQuietPending: playingQuietPending,
            isRequestEligible: isRequestEligible
        )
    }

    /// Whether a language long-horizon fire should also clear playing quiet for dual-axis soft ensure.
    ///
    /// - SeeAlso: ``shouldRunPostQuietLongHorizonDualAxisEnsure(languageStillLags:visualStillLags:actorVisual:isStreamSwitchHoldActive:isConnectingPlayback:)``.
    static func shouldClearPlayingQuietForDualAxisLongHorizonFire(
        playingQuietPending: Bool,
        languageStillLags: Bool,
        visualStillLags: Bool,
        actorVisual: PlayerVisualState,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool,
        freezeSoftBudgetExhausted: Bool = false,
        isRequestEligible: Bool = false
    ) -> Bool {
        guard playingQuietPending else { return false }
        return shouldRunPostQuietLongHorizonDualAxisEnsure(
            languageStillLags: languageStillLags,
            visualStillLags: visualStillLags,
            actorVisual: actorVisual,
            isStreamSwitchHoldActive: isStreamSwitchHoldActive,
            isConnectingPlayback: isConnectingPlayback,
            freezeSoftBudgetExhausted: freezeSoftBudgetExhausted,
            playingQuietPending: playingQuietPending,
            isRequestEligible: isRequestEligible
        )
    }

    /// Whether the dual-axis long-horizon **schedule** should arm (both axes lag; single-axis peers step aside).
    ///
    /// When both language and visual lag under continuous lock, arming two single-axis rails yields
    /// near-simultaneous fires that each burn a short soft budget and re-quiet without a co-push.
    /// Prefer one dual-axis horizon generation instead — **until** freeze soft budget exhausts
    /// or playing quiet is pending while ineligible. After that, language-only + playing-only
    /// rails own the sparse slots (same-visual language still lands; dual-axis visual does not).
    ///
    /// - Note: Does **not** invent `.playing` during hold/connect. Does **not** end+request.
    /// - SeeAlso: ``armPostQuietLongHorizonDualAxisEnsureIfNeeded()``,
    ///   ``shouldKeepOwnedVisualOnPostQuietLanguageLongHorizon(freezeSoftBudgetExhausted:playingQuietPending:isRequestEligible:)``,
    ///   ``shouldRunPostQuietLongHorizonDualAxisEnsure(languageStillLags:visualStillLags:actorVisual:isStreamSwitchHoldActive:isConnectingPlayback:freezeSoftBudgetExhausted:playingQuietPending:isRequestEligible:)``.
    static func shouldArmPostQuietLongHorizonDualAxisEnsure(
        hasCurrentActivity: Bool,
        isRequestEligible: Bool,
        dualAxisAlreadyArmed: Bool,
        languageStillLags: Bool,
        visualStillLags: Bool,
        actorVisual: PlayerVisualState,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool,
        freezeSoftBudgetExhausted: Bool = false,
        playingQuietPending: Bool = false
    ) -> Bool {
        guard hasCurrentActivity else { return false }
        guard !dualAxisAlreadyArmed else { return false }
        guard !isRequestEligible else { return false }
        return shouldRunPostQuietLongHorizonDualAxisEnsure(
            languageStillLags: languageStillLags,
            visualStillLags: visualStillLags,
            actorVisual: actorVisual,
            isStreamSwitchHoldActive: isStreamSwitchHoldActive,
            isConnectingPlayback: isConnectingPlayback,
            freezeSoftBudgetExhausted: freezeSoftBudgetExhausted,
            playingQuietPending: playingQuietPending,
            isRequestEligible: isRequestEligible
        )
    }

    /// Whether an in-flight dual-axis long-horizon fire should still run.
    ///
    /// - SeeAlso: ``shouldArmPostQuietLongHorizonDualAxisEnsure(hasCurrentActivity:isRequestEligible:dualAxisAlreadyArmed:languageStillLags:visualStillLags:actorVisual:isStreamSwitchHoldActive:isConnectingPlayback:)``.
    static func shouldContinuePostQuietLongHorizonDualAxisEnsure(
        hasCurrentActivity: Bool,
        languageStillLags: Bool,
        visualStillLags: Bool,
        actorVisual: PlayerVisualState,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool,
        freezeSoftBudgetExhausted: Bool = false,
        playingQuietPending: Bool = false,
        isRequestEligible: Bool = false
    ) -> Bool {
        guard hasCurrentActivity else { return false }
        return shouldRunPostQuietLongHorizonDualAxisEnsure(
            languageStillLags: languageStillLags,
            visualStillLags: visualStillLags,
            actorVisual: actorVisual,
            isStreamSwitchHoldActive: isStreamSwitchHoldActive,
            isConnectingPlayback: isConnectingPlayback,
            freezeSoftBudgetExhausted: freezeSoftBudgetExhausted,
            playingQuietPending: playingQuietPending,
            isRequestEligible: isRequestEligible
        )
    }

    /// Whether dual-axis long-horizon should cancel (ownership gone, both axes accepted, or actor left play).
    ///
    /// - SeeAlso: ``cancelPostQuietLongHorizonDualAxisEnsure()``.
    static func shouldCancelPostQuietLongHorizonDualAxisEnsure(
        hasCurrentActivity: Bool,
        languageStillLags: Bool,
        visualStillLags: Bool,
        actorVisual: PlayerVisualState
    ) -> Bool {
        if !hasCurrentActivity { return true }
        if actorVisual != .playing { return true }
        // Both axes matched — dual work is done (single-axis residual uses single rails).
        if !languageStillLags && !visualStillLags { return true }
        return false
    }

    /// Whether dual-axis long-horizon exhaustion should mark pending presentable recovery.
    ///
    /// - SeeAlso: ``postQuietLongHorizonDualAxisExhausted``,
    ///   ``shouldPreferEligibleRecreateAfterDualAxisLongHorizonExhausted(dualAxisExhausted:languageStillLags:visualStillLags:isRequestEligible:recreationsAttempted:maxRecreations:)``.
    static func shouldMarkDualAxisLongHorizonExhausted(
        languageStillLags: Bool,
        visualStillLags: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        guard !isRequestEligible else { return false }
        return languageStillLags || visualStillLags
    }

    /// Whether eligible-only recreation after foreground soft ensure should prefer hard heal
    /// after dual-axis long-horizon exhausted under continuous lock.
    ///
    /// Strengthens the existing ``shouldRecreateAfterForegroundSoftEnsureFailed`` path when the
    /// dual-axis sparse rail already burned its generation without owned acceptance — still
    /// **never** recreates while request is ineligible.
    ///
    /// - SeeAlso: ``shouldRecreateAfterForegroundSoftEnsureFailed(languageStillMismatches:playingStillStalled:isRequestEligible:recreationsAttempted:maxRecreations:)``,
    ///   ``ensureAuthoritativeContentOnForegroundIfNeeded()``.
    static func shouldPreferEligibleRecreateAfterDualAxisLongHorizonExhausted(
        dualAxisExhausted: Bool,
        languageStillLags: Bool,
        visualStillLags: Bool,
        isRequestEligible: Bool,
        recreationsAttempted: Int,
        maxRecreations: Int = RadioLiveActivityManager.maxInteractiveContentRecreations
    ) -> Bool {
        guard dualAxisExhausted else { return false }
        return shouldRecreateAfterForegroundSoftEnsureFailed(
            languageStillMismatches: languageStillLags,
            playingStillStalled: visualStillLags,
            isRequestEligible: isRequestEligible,
            recreationsAttempted: recreationsAttempted,
            maxRecreations: maxRecreations
        )
    }

    /// Whether a post-hold **dual-axis** settled acceptance should run (prePlay stick after attach).
    ///
    /// When owned visual is still Connecting (``.prePlay``) while the actor is authoritative
    /// `.playing` and hold/connect are clear, push destination language **and** playing together
    /// via dual-axis soft ensure rather than language-only then playing-only budgets that re-quiet.
    /// Consume-once while ineligible prevents soft-resume no-op thrash of the dual settle entry.
    ///
    /// - Note: Does **not** invent `.playing` during hold/connect. Soft-resume from ``.userPaused``
    ///   uses single-axis settled playing acceptance.
    /// - SeeAlso: ``pushSettledDualAxisAcceptanceContentIfNeeded()``,
    ///   ``ensureAuthoritativeDualAxisContentIfNeeded()``.
    static func shouldPushSettledDualAxisAcceptance(
        actorVisual: PlayerVisualState,
        ownedContentVisual: PlayerVisualState?,
        destinationLanguage: String,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool,
        settledAcceptanceConsumed: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        guard actorVisual == .playing else { return false }
        guard !isStreamSwitchHoldActive, !isConnectingPlayback else { return false }
        guard !destinationLanguage.isEmpty else { return false }
        // B1: Connecting stick after stream attach — co-push lang + playing.
        guard ownedContentVisual == .prePlay else { return false }
        if settledAcceptanceConsumed, !isRequestEligible {
            return false
        }
        return true
    }

    /// Whether dual-axis settled-acceptance consume should clear when owned leaves Connecting.
    ///
    /// - SeeAlso: ``pushSettledDualAxisAcceptanceContentIfNeeded()``.
    static func shouldClearDualAxisSettledAcceptanceConsume(
        settledAcceptanceConsumed: Bool,
        ownedOrSystemVisual: PlayerVisualState?
    ) -> Bool {
        guard settledAcceptanceConsumed else { return false }
        // Owned left Connecting (playing or intentional pause) — dual settle for prePlay is done.
        if ownedOrSystemVisual != .prePlay { return true }
        return false
    }

    /// Whether deferred playing-only status push while quiet should arm long-horizon (C4).
    ///
    /// Status thrash correctly defers; permanent freeze does not. When actor is still
    /// authoritative `.playing` and the rail is not already armed, arm sparse recovery.
    ///
    /// - SeeAlso: ``shouldDeferRedundantPlayingPushWhileQuiet(candidateVisual:ownedContentVisual:ownedContentLanguage:candidateLanguage:quietPending:isRequestEligible:)``,
    ///   ``shouldArmPostQuietLongHorizonPlayingEnsure(hasCurrentActivity:isRequestEligible:longHorizonAlreadyArmed:actorVisual:lastPushedVisual:ownedContentVisual:isStreamSwitchHoldActive:isConnectingPlayback:)``.
    static func shouldArmPostQuietLongHorizonPlayingEnsureAfterQuietDefer(
        didDeferPlayingPushWhileQuiet: Bool,
        hasCurrentActivity: Bool,
        isRequestEligible: Bool,
        longHorizonAlreadyArmed: Bool,
        actorVisual: PlayerVisualState,
        lastPushedVisual: PlayerVisualState?,
        ownedContentVisual: PlayerVisualState?,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool
    ) -> Bool {
        guard didDeferPlayingPushWhileQuiet else { return false }
        return shouldArmPostQuietLongHorizonPlayingEnsure(
            hasCurrentActivity: hasCurrentActivity,
            isRequestEligible: isRequestEligible,
            longHorizonAlreadyArmed: longHorizonAlreadyArmed,
            actorVisual: actorVisual,
            lastPushedVisual: lastPushedVisual,
            ownedContentVisual: ownedContentVisual,
            isStreamSwitchHoldActive: isStreamSwitchHoldActive,
            isConnectingPlayback: isConnectingPlayback
        )
    }

    /// Whether deferred language-only status push while quiet should arm long-horizon.
    ///
    /// - SeeAlso: ``shouldArmPostQuietLongHorizonPlayingEnsureAfterQuietDefer(didDeferPlayingPushWhileQuiet:hasCurrentActivity:isRequestEligible:longHorizonAlreadyArmed:actorVisual:lastPushedVisual:ownedContentVisual:isStreamSwitchHoldActive:isConnectingPlayback:)``.
    static func shouldArmPostQuietLongHorizonLanguageEnsureAfterQuietDefer(
        didDeferLanguagePushWhileQuiet: Bool,
        hasCurrentActivity: Bool,
        isRequestEligible: Bool,
        longHorizonAlreadyArmed: Bool,
        destinationLanguage: String,
        lastPushedLanguage: String?,
        ownedContentLanguage: String?,
        isStreamSwitchHoldActive: Bool
    ) -> Bool {
        guard didDeferLanguagePushWhileQuiet else { return false }
        return shouldArmPostQuietLongHorizonLanguageEnsure(
            hasCurrentActivity: hasCurrentActivity,
            isRequestEligible: isRequestEligible,
            longHorizonAlreadyArmed: longHorizonAlreadyArmed,
            destinationLanguage: destinationLanguage,
            lastPushedLanguage: lastPushedLanguage,
            ownedContentLanguage: ownedContentLanguage,
            isStreamSwitchHoldActive: isStreamSwitchHoldActive
        )
    }

    /// Resolves language chrome for visual-only optimistic toggle ``lastPushedContent`` alignment.
    ///
    /// Prefer stream-attach language over lagging suppress memory so pause/play after a stream
    /// switch cannot re-stamp a prior `currentLanguage` into ``lastPushedContent`` while the
    /// engine already plays the destination. Does **not** invent a hard-default privacy `"en"`
    /// when stream attach is empty — falls through to owned / durable mirror / last-pushed.
    ///
    /// - Parameters:
    ///   - lastPushedLanguage: ``lastPushedContent.currentLanguage``, if any.
    ///   - ownedContentLanguage: Owned `content.state.currentLanguage`, if any.
    ///   - selectedStreamLanguage: ``DirectStreamingPlayer/selectedStream`` language (empty when unset).
    ///   - durableLanguageMirror: ``SharedPlayerManager/loadLiveActivityLanguageMirror()``, if any.
    /// - Returns: Non-empty language when any source provides one; otherwise empty (caller may
    ///   fall back to ``mainAppLiveActivityLanguageCode()`` for a non-empty product default).
    /// - SeeAlso: ``recordOptimisticToggleContent(visualState:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func languageForOptimisticToggleContentAlignment(
        lastPushedLanguage: String?,
        ownedContentLanguage: String?,
        selectedStreamLanguage: String,
        durableLanguageMirror: String?
    ) -> String {
        if !selectedStreamLanguage.isEmpty {
            return selectedStreamLanguage
        }
        if let mirror = durableLanguageMirror, !mirror.isEmpty {
            return mirror
        }
        if let owned = ownedContentLanguage, !owned.isEmpty {
            return owned
        }
        if let last = lastPushedLanguage, !last.isEmpty {
            return last
        }
        return ""
    }

    /// Whether soft playing-ensure pushes should run now, or stay quiet after budget exhaustion.
    ///
    /// After ``authoritativePlayingContentEnsureMaxAttempts`` while request is ineligible,
    /// the manager records ``playingEnsureQuietPending``. Further ensure-driven soft pushes
    /// stay quiet until re-arm so status-driven media-surface refreshes do not re-burn the
    /// soft-retry budget without acceptance.
    ///
    /// **Re-arm (returns true when playing ensure is still needed):**
    /// - No quiet pending yet
    /// - Interactive request became eligible (presentable cycle / unlock)
    /// - Caller cleared quiet before ensure (authoritative play mutation, optimistic toggle)
    ///
    /// - Parameters:
    ///   - needsPlayingEnsure: ``shouldEnsureAuthoritativePlayingContent(actorVisual:streamSwitchHold:isConnectingPlayback:lastPushedVisual:ownedVisual:)``.
    ///   - quietPending: ``playingEnsureQuietPending``.
    ///   - isRequestEligible: ``isInteractiveLiveActivityRequestEligible(areActivitiesEnabled:isApplicationActive:)``.
    /// - Returns: `true` when soft playing pushes should run.
    /// - SeeAlso: ``ensureAuthoritativePlayingContentIfNeeded()``,
    ///   ``shouldEnterPlayingEnsureQuietPending(playingStillStalled:isRequestEligible:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldRunPlayingContentEnsureSoftPushes(
        needsPlayingEnsure: Bool,
        quietPending: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        guard needsPlayingEnsure else { return false }
        // Re-arm when request is eligible (unlock / presentable cycle).
        if isRequestEligible { return true }
        // Quiet while still ineligible → stop thrash.
        if quietPending { return false }
        return true
    }

    /// Whether playing soft-ensure should enter quiet pending after budget exhaustion.
    ///
    /// Does **not** enter quiet when owned visual is Connecting (``.prePlay``) that we
    /// published as the hold clamp while the actor is already authoritative `.playing`
    /// without hold/connect — that post-clamp playing mutation still needs to push.
    /// Immediate post-await mismatch is not quiet truth (callers wait the apply window).
    ///
    /// - Parameters:
    ///   - playingStillStalled: Owned / last visual still lags authoritative `.playing`.
    ///   - isRequestEligible: Whether interactive `Activity.request` could succeed now.
    ///   - ownedContentVisual: System-held visual after the apply window, if any.
    ///   - isAuthoritativePlayingWithoutHold: Actor is `.playing` and hold/connect are clear.
    /// - Returns: `true` when quiet should engage (still stalled + request ineligible,
    ///   and not a post-clamp Connecting→playing handshake).
    /// - SeeAlso: ``shouldRunPlayingContentEnsureSoftPushes(needsPlayingEnsure:quietPending:isRequestEligible:)``,
    ///   ``shouldDeferRedundantPlayingPushWhileQuiet(candidateVisual:ownedContentVisual:ownedContentLanguage:candidateLanguage:quietPending:isRequestEligible:)``.
    static func shouldEnterPlayingEnsureQuietPending(
        playingStillStalled: Bool,
        isRequestEligible: Bool,
        ownedContentVisual: PlayerVisualState? = nil,
        isAuthoritativePlayingWithoutHold: Bool = false
    ) -> Bool {
        guard playingStillStalled else { return false }
        guard !isRequestEligible else { return false }
        // Connecting chrome we just published while audio is already playing is handshake,
        // not a freeze that should starve the subsequent `.playing` push.
        if ownedContentVisual == .prePlay, isAuthoritativePlayingWithoutHold {
            return false
        }
        return true
    }

    /// Whether a status-driven `Activity.update` that is only repairing a playing visual stall
    /// should defer while playing ensure is quiet-pending.
    ///
    /// Protects lock-stretch thrash: after soft playing ensure exhausted while request is
    /// ineligible, every media-surface refresh would otherwise re-submit the same `.playing`
    /// candidate against owned **pause** (owned-visual suppress gate correctly denies suppress).
    /// Pause honesty (``.userPaused``) and language mutations still push. Owned Connecting
    /// (``.prePlay``) with candidate `.playing` is the post-clamp mutation and must **not**
    /// defer — quiet must not starve that push.
    ///
    /// - Parameters:
    ///   - candidateVisual: Candidate ``ContentState.visualState``.
    ///   - ownedContentVisual: Owned `content.state.visualState`.
    ///   - ownedContentLanguage: Owned `content.state.currentLanguage`.
    ///   - candidateLanguage: Candidate language.
    ///   - quietPending: ``playingEnsureQuietPending``.
    ///   - isRequestEligible: Interactive request eligibility.
    /// - Returns: `true` when ActivityKit IPC should be skipped for this playing-visual stall.
    /// - SeeAlso: ``updateCurrentActivity()``, ``shouldRunPlayingContentEnsureSoftPushes(needsPlayingEnsure:quietPending:isRequestEligible:)``.
    static func shouldDeferRedundantPlayingPushWhileQuiet(
        candidateVisual: PlayerVisualState,
        ownedContentVisual: PlayerVisualState,
        ownedContentLanguage: String,
        candidateLanguage: String,
        quietPending: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        guard quietPending else { return false }
        guard !isRequestEligible else { return false }
        // Language still differs → push (language honesty + co-push both axes).
        if ownedContentLanguage != candidateLanguage { return false }
        // Visual already matches → not a visual stall (suppress policy handles no-op).
        if ownedContentVisual == candidateVisual { return false }
        // Pause honesty must still push even when owned was stuck Connecting.
        if candidateVisual == .userPaused { return false }
        // Post-clamp playing mutation: we published Connecting; actor is now `.playing`.
        // Quiet must not starve this push (hold is already clear — otherwise resolve
        // would have clamped the candidate back to `.prePlay`).
        if ownedContentVisual == .prePlay, candidateVisual == .playing {
            return false
        }
        // Only defer redundant playing-repair thrash (candidate .playing, owned lagging).
        guard candidateVisual == .playing else { return false }
        return true
    }

    /// Whether playing ensure quiet should clear after system content yield or owned convergence.
    ///
    /// - Parameters:
    ///   - quietPending: Current quiet flag.
    ///   - ownedOrSystemVisual: Owned or system-accepted `content.state.visualState`.
    /// - Returns: `true` when quiet should clear (owned visual reached `.playing`).
    /// - SeeAlso: ``handleActivityContentUpdate(_:)``, ``ensureAuthoritativePlayingContentIfNeeded()``.
    static func shouldClearPlayingEnsureQuietPending(
        quietPending: Bool,
        ownedOrSystemVisual: PlayerVisualState?
    ) -> Bool {
        guard quietPending else { return false }
        if ownedOrSystemVisual == .playing { return true }
        return false
    }

    /// Whether a soft-ensure entry should start a new soft-push loop (collapse concurrent re-entry).
    ///
    /// Status-driven media-surface refreshes and dual call sites can re-enter language or
    /// playing ensure while a loop is already mid-flight. Starting a second loop produces
    /// parallel attempt counters and thrashing `Activity.update` without improving acceptance.
    ///
    /// - Parameter softPushesAlreadyInFlight: Whether this axis already has a soft-push loop running.
    /// - Returns: `true` when this entry may begin the soft-push loop.
    /// - SeeAlso: ``ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``ensureAuthoritativePlayingContentIfNeeded()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldStartAuthoritativeContentEnsureSoftPushLoop(
        softPushesAlreadyInFlight: Bool
    ) -> Bool {
        !softPushesAlreadyInFlight
    }

    /// Whether stalled-push bookkeeping should mark ``pendingInteractiveLiveActivityEnsure``
    /// when recreation is deferred because request is ineligible.
    ///
    /// - Parameters:
    ///   - wouldRecreateByStreakCap: ``shouldRecreateInteractiveLiveActivityAfterStalledPushes``.
    ///   - isRequestEligible: Interactive `Activity.request` eligibility.
    /// - Returns: `true` when pending ensure should be set (idempotent for callers).
    /// - SeeAlso: ``shouldAnnounceDeferredInteractiveRecreationWhileIneligible(wouldRecreateByStreakCap:isRequestEligible:pendingEnsureAlreadyRecorded:)``,
    ///   ``updateCurrentActivity()``.
    static func shouldMarkPendingEnsureForDeferredRecreation(
        wouldRecreateByStreakCap: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        guard !isRequestEligible else { return false }
        return wouldRecreateByStreakCap
    }

    /// Whether to emit the deferred-recreation DEBUG diagnostic for a freeze.
    ///
    /// First deferral for a freeze records pending ensure and may announce once; subsequent
    /// identical stalled evaluations while still ineligible and already pending stay quiet
    /// (battery / log thrash protection). Re-arm of pending (clear then set again after
    /// mutation / eligibility / become-active) re-allows a single announce.
    ///
    /// - Parameters:
    ///   - wouldRecreateByStreakCap: Streak/cap bookkeeping would recreate if eligible.
    ///   - isRequestEligible: Interactive request eligibility.
    ///   - pendingEnsureAlreadyRecorded: ``pendingInteractiveLiveActivityEnsure`` already true.
    /// - Returns: `true` when this is the first deferred-recreation announce for the freeze.
    /// - SeeAlso: ``shouldMarkPendingEnsureForDeferredRecreation(wouldRecreateByStreakCap:isRequestEligible:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldAnnounceDeferredInteractiveRecreationWhileIneligible(
        wouldRecreateByStreakCap: Bool,
        isRequestEligible: Bool,
        pendingEnsureAlreadyRecorded: Bool
    ) -> Bool {
        guard shouldMarkPendingEnsureForDeferredRecreation(
            wouldRecreateByStreakCap: wouldRecreateByStreakCap,
            isRequestEligible: isRequestEligible
        ) else {
            return false
        }
        return !pendingEnsureAlreadyRecorded
    }

    /// Compact signature for rate-limited stall diagnostics (candidate vs system-held chrome).
    ///
    /// - Parameters:
    ///   - candidateLanguage: Submitted ContentState language.
    ///   - acceptedLanguage: System-held / owned language after update.
    ///   - candidateVisual: Submitted visual.
    ///   - acceptedVisual: System-held / owned visual.
    /// - Returns: Stable string for identical freeze pair comparison.
    /// - SeeAlso: ``shouldLogStalledContentDiagnostics(signature:lastLoggedSignature:)``.
    static func stalledContentDiagnosticsSignature(
        candidateLanguage: String,
        acceptedLanguage: String,
        candidateVisual: PlayerVisualState,
        acceptedVisual: PlayerVisualState
    ) -> String {
        "\(candidateLanguage)|\(acceptedLanguage)|\(candidateVisual)|\(acceptedVisual)"
    }

    /// Compact signature for rate-limited `contentUpdates` yield diagnostics.
    ///
    /// - Parameters:
    ///   - systemLanguage: Yielded `content.state.currentLanguage`.
    ///   - systemVisual: Yielded `content.state.visualState`.
    ///   - activityId: Owned ActivityKit id, or `"unowned"` when tracking is empty.
    /// - Returns: Stable string for identical yield-tuple comparison.
    /// - SeeAlso: ``shouldLogStalledContentDiagnostics(signature:lastLoggedSignature:)``,
    ///   ``handleActivityContentUpdate(_:)``.
    static func contentUpdatesYieldDiagnosticsSignature(
        systemLanguage: String,
        systemVisual: PlayerVisualState,
        activityId: String
    ) -> String {
        "\(activityId)|\(systemLanguage)|\(systemVisual)"
    }

    /// Clears rate-limited DEBUG signatures for stall diagnostics and `contentUpdates` yields.
    ///
    /// Call when the freeze pair is no longer current (healthy match, ownership end,
    /// mutation re-arm, test sanitization).
    ///
    /// - SeeAlso: ``lastLoggedStalledContentDiagnosticsSignature``,
    ///   ``lastLoggedContentUpdatesYieldDiagnosticsSignature``.
    private func clearContentPushDiagnosticsSignatures() {
        lastLoggedStalledContentDiagnosticsSignature = nil
        lastLoggedContentUpdatesYieldDiagnosticsSignature = nil
    }

    /// Whether DEBUG stall diagnostics should emit for this signature.
    ///
    /// Identical candidate/owned freeze pairs log once until the signature changes
    /// (true mutation) or the surface converges (caller clears last-logged).
    ///
    /// - Parameters:
    ///   - signature: ``stalledContentDiagnosticsSignature(candidateLanguage:acceptedLanguage:candidateVisual:acceptedVisual:)``.
    ///   - lastLoggedSignature: Last emitted signature, if any.
    /// - Returns: `true` when this signature has not been logged yet.
    /// - SeeAlso: ``updateCurrentActivity()``, docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldLogStalledContentDiagnostics(
        signature: String,
        lastLoggedSignature: String?
    ) -> Bool {
        lastLoggedSignature != signature
    }

    /// Whether a soft-ensure "already quiet" skip should emit a DEBUG line.
    ///
    /// Status callbacks re-enter ensure after budget exhaustion; logging every skip floods
    /// device logs. Emit once per quiet engagement; re-arm when quiet clears or soft pushes run.
    ///
    /// - Parameters:
    ///   - softPushesSuppressedByQuiet: Soft-push gate returned false because quiet while ineligible.
    ///   - alreadyLoggedQuietSkip: Whether this quiet engagement already logged a skip.
    /// - Returns: `true` when this is the first quiet-skip log for the engagement.
    /// - SeeAlso: ``ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``ensureAuthoritativePlayingContentIfNeeded()``.
    static func shouldLogEnsureQuietSkipOnce(
        softPushesSuppressedByQuiet: Bool,
        alreadyLoggedQuietSkip: Bool
    ) -> Bool {
        guard softPushesSuppressedByQuiet else { return false }
        return !alreadyLoggedQuietSkip
    }

    /// Samples actor visual + stream-switch/connect gates into the ContentState visual for a push.
    ///
    /// Stream-switch hold / in-flight connect: never advertise `.playing` while the engine is
    /// tearing down or attaching. When hold is clear and the actor is already `.playing`,
    /// Connecting must not win (stale concurrent sampler safety). Hold is returned with
    /// the visual so ``shouldSuppressConnectingContentPushWhileIneligible`` cannot race a
    /// destination-language switch that must still publish Connecting.
    ///
    /// - Parameter manager: Main-app ``SharedPlayerManager`` instance.
    /// - Returns: Visual to encode in the next ActivityKit candidate, plus the hold sample
    ///   used for same-stream ineligible Connecting skip.
    /// - SeeAlso: ``updateCurrentActivity()``, ``SharedPlayerManager/setPlaying()``,
    ///   ``shouldSuppressConnectingContentPushWhileIneligible(isRequestEligible:isStreamSwitchHoldActive:ownedVisual:candidateVisual:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    private static func resolveContentPushVisual(from manager: SharedPlayerManager) async -> (
        visual: PlayerVisualState,
        isStreamSwitchHoldActive: Bool
    ) {
        let visualState = await manager.currentVisualState
        let streamSwitchHold = await manager.isStreamSwitchPrePlayHoldActive
        let connecting = await manager.isConnectingPlayback
        let visual = resolveContentPushVisual(
            visualState: visualState,
            streamSwitchHold: streamSwitchHold,
            isConnectingPlayback: connecting
        )
        return (visual, streamSwitchHold)
    }

    /// Pure ContentState visual policy for Live Activity pushes (testable without ActivityKit).
    ///
    /// - Parameters:
    ///   - visualState: Actor ``currentVisualState`` sample.
    ///   - streamSwitchHold: ``isStreamSwitchPrePlayHoldActive``.
    ///   - isConnectingPlayback: ``isConnectingPlayback`` (start pipeline without audible play).
    /// - Returns: `.prePlay` when hold/connect would lie about playing; otherwise `visualState`.
    /// - SeeAlso: ``updateCurrentActivity()``, ``_test_resolveContentPushVisual(visualState:streamSwitchHold:isConnectingPlayback:)``.
    static func resolveContentPushVisual(
        visualState: PlayerVisualState,
        streamSwitchHold: Bool,
        isConnectingPlayback: Bool
    ) -> PlayerVisualState {
        if (streamSwitchHold || isConnectingPlayback) && visualState == .playing {
            return .prePlay
        }
        return visualState
    }

    /// If the actor is authoritatively playing (no hold/connect) but suppress memory or owned
    /// content still shows Connecting (``.prePlay``) or sticky pause (``.userPaused``), push
    /// again so lock-screen chrome cannot stick after stream-switch deferred-setPlaying or
    /// soft-resume from pause.
    ///
    /// Performs up to ``authoritativePlayingContentEnsureMaxAttempts`` soft pushes, re-reading
    /// owned `content.state.visualState` after each ``updateCurrentActivity()``. Stops early when
    /// owned visual reaches `.playing`, the ensure gate clears, or the interactive activity
    /// disappears. Does **not** end+recreate — pure visual freezes recover via soft retries
    /// (and stalled-push bookkeeping when ActivityKit still rejects); recreation stays behind
    /// the eligibility gate on the general update path.
    ///
    /// **Quiet pending while request ineligible:** After the soft-retry budget is exhausted
    /// without owned `.playing` acceptance while ``isInteractiveLiveActivityRequestEligible``
    /// is false, records ``playingEnsureQuietPending`` and stops re-running soft pushes on
    /// every status callback. Re-arm when:
    /// - Authoritative play mutation (``rearmPlayingEnsureQuietPending()`` from setPlaying /
    ///   soft-resume)
    /// - Optimistic toggle or stream-switch ContentState
    /// - Interactive request becomes eligible
    /// - Foreground / become-active (``ensureAuthoritativeContentOnForegroundIfNeeded`` clears quiet)
    /// - System `contentUpdates` yield
    ///
    /// **Concurrent collapse:** Re-entry while a soft-push loop is already in flight is a
    /// no-op (``shouldStartAuthoritativeContentEnsureSoftPushLoop``) so parallel attempt
    /// counters do not thrash ActivityKit.
    ///
    /// Called from ``SharedPlayerManager/setPlaying()`` after language ensure (serialize
    /// language then visual so one ContentState push can carry both), and from the soft-resume
    /// publish path when actor visual is already `.playing` (publish no-op) so a stuck
    /// Connecting glyph is still reconciled.
    ///
    /// - SeeAlso: ``updateCurrentActivity()``, ``shouldEnsureAuthoritativePlayingContent(actorVisual:streamSwitchHold:isConnectingPlayback:lastPushedVisual:ownedVisual:)``,
    ///   ``shouldRunPlayingContentEnsureSoftPushes(needsPlayingEnsure:quietPending:isRequestEligible:)``,
    ///   ``shouldStartAuthoritativeContentEnsureSoftPushLoop(softPushesAlreadyInFlight:)``,
    ///   ``authoritativePlayingContentEnsureMaxAttempts``,
    ///   ``ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``recordOptimisticStreamSwitchContent(language:visualState:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    @MainActor
    func ensureAuthoritativePlayingContentIfNeeded() async {
        if SharedPlayerManager.isRunningInUITestMode { return }
        #if DEBUG
        if isRunningUnderTest { return }
        #endif
        guard currentActivity != nil else { return }

        let manager = SharedPlayerManager.shared
        let visual = await manager.currentVisualState
        let hold = await manager.isStreamSwitchPrePlayHoldActive
        let connecting = await manager.isConnectingPlayback
        let lastVisual = lastPushedContent?.visualState
        let ownedVisual = currentActivity?.content.state.visualState
        let needsEnsure = Self.shouldEnsureAuthoritativePlayingContent(
            actorVisual: visual,
            streamSwitchHold: hold,
            isConnectingPlayback: connecting,
            lastPushedVisual: lastVisual,
            ownedVisual: ownedVisual
        )
        // Owned visual converged → drop quiet + long-horizon.
        if Self.shouldClearPlayingEnsureQuietPending(
            quietPending: playingEnsureQuietPending,
            ownedOrSystemVisual: ownedVisual
        ) {
            playingEnsureQuietPending = false
            playingEnsureQuietSkipLogged = false
            cancelPostQuietLongHorizonPlayingEnsure()
        }
        guard needsEnsure else {
            playingEnsureQuietPending = false
            playingEnsureQuietSkipLogged = false
            cancelPostQuietLongHorizonPlayingEnsure()
            return
        }

        let requestEligible = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        guard Self.shouldRunPlayingContentEnsureSoftPushes(
            needsPlayingEnsure: true,
            quietPending: playingEnsureQuietPending,
            isRequestEligible: requestEligible
        ) else {
            #if DEBUG
            if Self.shouldLogEnsureQuietSkipOnce(
                softPushesSuppressedByQuiet: true,
                alreadyLoggedQuietSkip: playingEnsureQuietSkipLogged
            ) {
                playingEnsureQuietSkipLogged = true
                print(
                    "🔴 Live Activity playing ensure quiet (owned=\(String(describing: ownedVisual)); " +
                    "wait for eligibility, become-active, or play mutation)"
                )
            }
            #endif
            // Quiet skip still arms long-horizon if not already (status path may not defer).
            await armPostQuietLongHorizonPlayingEnsureIfNeeded()
            return
        }

        // Collapse concurrent re-entry: only one soft-push loop per axis.
        guard Self.shouldStartAuthoritativeContentEnsureSoftPushLoop(
            softPushesAlreadyInFlight: playingEnsureSoftPushesInFlight
        ) else {
            return
        }
        playingEnsureSoftPushesInFlight = true
        defer { playingEnsureSoftPushesInFlight = false }
        // Soft pushes running → allow a fresh quiet-skip log if this cycle exhausts again.
        playingEnsureQuietSkipLogged = false

        for attempt in 1...Self.authoritativePlayingContentEnsureMaxAttempts {
            guard currentActivity != nil else { return }

            let loopVisual = await manager.currentVisualState
            let loopHold = await manager.isStreamSwitchPrePlayHoldActive
            let loopConnecting = await manager.isConnectingPlayback
            let loopLastVisual = lastPushedContent?.visualState
            let loopOwnedVisual = currentActivity?.content.state.visualState

            guard Self.shouldEnsureAuthoritativePlayingContent(
                actorVisual: loopVisual,
                streamSwitchHold: loopHold,
                isConnectingPlayback: loopConnecting,
                lastPushedVisual: loopLastVisual,
                ownedVisual: loopOwnedVisual
            ) else {
                playingEnsureQuietPending = false
                playingEnsureQuietSkipLogged = false
                return
            }

            #if DEBUG
            print(
                "🔴 Live Activity reconciling authoritative playing → last=\(String(describing: loopLastVisual)) " +
                "owned=\(String(describing: loopOwnedVisual)) attempt=\(attempt)/\(Self.authoritativePlayingContentEnsureMaxAttempts)"
            )
            #endif
            await updateCurrentActivity()

            // Post-update verification: owned visual is the surface honesty SSOT.
            let acceptedVisual = currentActivity?.content.state.visualState
            if acceptedVisual == .playing {
                playingEnsureQuietPending = false
                playingEnsureQuietSkipLogged = false
                cancelPostQuietLongHorizonPlayingEnsure()
                return
            }
            // Yield + eligibility-aware spacing so ActivityKit can apply under lock-stretch
            // without raising attempt count (eligible stays short for unlock heal).
            if let delayMs = Self.softEnsureInterAttemptDelayMilliseconds(
                attempt: attempt,
                maxAttempts: Self.authoritativePlayingContentEnsureMaxAttempts,
                isRequestEligible: requestEligible
            ) {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(delayMs))
            }
        }

        // Soft budget exhausted without acceptance.
        let finalVisual = await manager.currentVisualState
        let finalHold = await manager.isStreamSwitchPrePlayHoldActive
        let finalConnecting = await manager.isConnectingPlayback
        let stillStalled = Self.shouldEnsureAuthoritativePlayingContent(
            actorVisual: finalVisual,
            streamSwitchHold: finalHold,
            isConnectingPlayback: finalConnecting,
            lastPushedVisual: lastPushedContent?.visualState,
            ownedVisual: currentActivity?.content.state.visualState
        )
        let eligibleAfter = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        // Immediate post-await mismatch is not quiet truth — wait one apply window.
        var stalledAfterApplyWindow = stillStalled
        var ownedAfterApplyWindow = currentActivity?.content.state.visualState
        if stillStalled {
            let settleMs = Self.contentPushApplyConfirmationDelayMilliseconds(
                isRequestEligible: eligibleAfter
            )
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(settleMs))
            ownedAfterApplyWindow = currentActivity?.content.state.visualState
            stalledAfterApplyWindow = Self.shouldEnsureAuthoritativePlayingContent(
                actorVisual: finalVisual,
                streamSwitchHold: finalHold,
                isConnectingPlayback: finalConnecting,
                lastPushedVisual: lastPushedContent?.visualState,
                ownedVisual: ownedAfterApplyWindow
            )
        }
        let authoritativePlayingWithoutHold =
            finalVisual == .playing && !finalHold && !finalConnecting
        if Self.shouldEnterPlayingEnsureQuietPending(
            playingStillStalled: stalledAfterApplyWindow,
            isRequestEligible: eligibleAfter,
            ownedContentVisual: ownedAfterApplyWindow,
            isAuthoritativePlayingWithoutHold: authoritativePlayingWithoutHold
        ) {
            playingEnsureQuietPending = true
            playingEnsureQuietSkipLogged = false
            // Keep pending ensure so become-active owned-surface path re-arms recovery.
            markContentEnsureFreezeSoftBudgetExhausted()
            #if DEBUG
            print(
                "🔴 Live Activity playing ensure quiet pending after max attempts " +
                "(recreation remains eligibility-gated; freeze soft budget exhausted)"
            )
            #endif
            // Quiet is thrash protection, not a permanent freeze under continuous lock.
            await armPostQuietLongHorizonPlayingEnsureIfNeeded()
        }
    }

    /// Marks continuous-lock freeze soft budget exhausted and keeps become-active pending ensure.
    ///
    /// - SeeAlso: ``resetContentEnsureFreezeGeneration()``,
    ///   ``contentEnsureFreezeSoftBudgetExhausted``.
    @MainActor
    private func markContentEnsureFreezeSoftBudgetExhausted() {
        contentEnsureFreezeSoftBudgetExhausted = true
        pendingInteractiveLiveActivityEnsure = true
    }

    /// Opens a fresh continuous-lock ensure freeze generation (mutation / presentable cycle).
    ///
    /// - SeeAlso: ``markContentEnsureFreezeSoftBudgetExhausted()``,
    ///   ``rearmPlayingEnsureQuietPending()``.
    @MainActor
    private func resetContentEnsureFreezeGeneration() {
        contentEnsureFreezeSoftBudgetExhausted = false
        contentEnsureFreezePartialPostSettledScheduled = false
        contentEnsureFreezeLanguageNewlyConverged = false
        contentEnsureFreezeVisualNewlyConverged = false
    }

    /// Clears playing ensure quiet so the next soft-ensure cycle gets a full soft budget.
    ///
    /// Call on authoritative play mutations (``setPlaying`` / soft-resume ensure) so a prior
    /// lock-stretch exhaustion cannot block a high-priority visual reconcile after audible
    /// start. Resets freeze-generation bookkeeping so the mutation opens a new soft budget.
    /// Does not invent `.playing` during hold — ensure gates still apply.
    ///
    /// - SeeAlso: ``ensureAuthoritativePlayingContentIfNeeded()``,
    ///   ``resetContentEnsureFreezeGeneration()``,
    ///   ``recordOptimisticToggleContent(visualState:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    @MainActor
    func rearmPlayingEnsureQuietPending() {
        playingEnsureQuietPending = false
        playingEnsureQuietSkipLogged = false
        resetContentEnsureFreezeGeneration()
    }

    /// Post-hold language soft-ensure re-arm after stream-switch hold has cleared.
    ///
    /// Soft language ensure often exhausts during the attach storm (Connecting) and enters
    /// quiet pending for the destination. Status-driven language-only re-pushes then defer,
    /// so system-held language can freeze for the rest of a lock stretch even after audio is
    /// already on the destination stream. Call this from authoritative audible start
    /// (``SharedPlayerManager/setPlaying()``) and soft-resume no-op reconcile so a **full**
    /// soft language-ensure budget re-runs after hold clear (not only a single ActivityKit
    /// update). Consume-once per destination while ineligible keeps soft-resume no-ops from
    /// re-entering this settle entry; bounded delayed retries continue after the entry when
    /// owned language still lags.
    ///
    /// **Quiet re-arm (post-audible):** Clears ``languageEnsureQuietPendingDestination`` so
    /// ``shouldRunLanguageContentEnsureSoftPushes`` and ``shouldDeferRedundantLanguagePushWhileQuiet``
    /// do not drop the post-hold soft cycle, then ``ensureAuthoritativeLanguageContentIfNeeded()``.
    /// Marks ``languageSettledAcceptanceConsumedDestination`` while request is ineligible so
    /// soft-resume no-ops do not re-thrash the settle entry. When owned language still mismatches
    /// after the soft cycle while ineligible, re-enters quiet for status thrash **and** schedules
    /// ``schedulePostSettledLanguageEnsureRetriesIfNeeded(destination:)``.
    ///
    /// - Precondition: Main actor; stream-switch hold should already be cleared by the caller
    ///   (policy also gates on hold). Interactive ``currentActivity`` may be nil (no-op).
    /// - Postcondition: When policy fires, soft language ensure ran up to its budget; optional
    ///   delayed retries may remain in flight while language still lags; no end+request; does
    ///   not invent `.playing` during hold.
    /// - SeeAlso: ``shouldPushSettledLanguageAcceptance(destinationLanguage:ownedContentLanguage:isStreamSwitchHoldActive:settledAcceptanceConsumedDestination:isRequestEligible:)``,
    ///   ``shouldSchedulePostSettledLanguageEnsureRetries(hasCurrentActivity:destinationLanguage:ownedContentLanguage:isStreamSwitchHoldActive:)``,
    ///   ``ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``SharedPlayerManager/setPlaying()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    @MainActor
    func pushSettledLanguageAcceptanceContentIfNeeded() async {
        if SharedPlayerManager.isRunningInUITestMode { return }
        #if DEBUG
        if isRunningUnderTest { return }
        #endif
        guard currentActivity != nil else { return }

        let manager = SharedPlayerManager.shared
        let destination = await manager.liveActivityLanguageCodeForContentPush()
        let hold = await manager.isStreamSwitchPrePlayHoldActive
        let ownedLanguage = currentActivity?.content.state.currentLanguage
        let requestEligible = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )

        // Destination change or owned convergence clears a prior settle consume marker.
        if Self.shouldClearLanguageSettledAcceptanceConsume(
            settledAcceptanceConsumedDestination: languageSettledAcceptanceConsumedDestination,
            destinationLanguage: destination,
            ownedOrSystemLanguage: ownedLanguage
        ) {
            languageSettledAcceptanceConsumedDestination = nil
        }

        guard Self.shouldPushSettledLanguageAcceptance(
            destinationLanguage: destination,
            ownedContentLanguage: ownedLanguage,
            isStreamSwitchHoldActive: hold,
            settledAcceptanceConsumedDestination: languageSettledAcceptanceConsumedDestination,
            isRequestEligible: requestEligible
        ) else {
            return
        }

        // Clear language quiet so post-hold soft ensure gets a full budget (attach-storm quiet
        // must not freeze destination language after audible settle).
        languageEnsureQuietPendingDestination = nil
        languageEnsureQuietSkipLogged = false
        // Consume-once while ineligible — soft-resume no-ops must not re-open the settle entry.
        if !requestEligible {
            languageSettledAcceptanceConsumedDestination = destination
        }
        // Fresh settle cycle owns delayed retries + long-horizon for this destination.
        cancelPostSettledLanguageEnsureRetries()
        cancelPostQuietLongHorizonLanguageEnsure()

        #if DEBUG
        print(
            "🔴 Live Activity settled language acceptance soft-ensure re-arm " +
            "(destination=\(destination) owned=\(ownedLanguage ?? "nil"); " +
            "quiet cleared for full post-hold language budget)"
        )
        #endif

        // Full soft language-ensure budget after hold clear — prefer multi-attempt soft path
        // over a single dual-axis update so ActivityKit has more than one acceptance window.
        await ensureAuthoritativeLanguageContentIfNeeded()

        let acceptedLanguage = currentActivity?.content.state.currentLanguage
        if acceptedLanguage == destination {
            languageEnsureQuietPendingDestination = nil
            languageEnsureQuietSkipLogged = false
            languageSettledAcceptanceConsumedDestination = nil
            return
        }

        // Still lagging while locked — re-enter quiet for status thrash, keep pending ensure
        // for become-active, and schedule longer-cadence soft ensure without end+request.
        let eligibleAfter = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        let holdAfter = await manager.isStreamSwitchPrePlayHoldActive
        if !eligibleAfter, !destination.isEmpty {
            languageEnsureQuietPendingDestination = destination
            languageEnsureQuietSkipLogged = false
            markContentEnsureFreezeSoftBudgetExhausted()
            #if DEBUG
            print(
                "🔴 Live Activity settled language acceptance still lagging " +
                "(destination=\(destination) owned=\(acceptedLanguage ?? "nil"); " +
                "quiet re-armed; freeze soft budget exhausted; recreation remains eligibility-gated)"
            )
            #endif
        }
        // Nested post-settled only for true visual-new partial wins while ineligible.
        let baseLanguagePostSettled = Self.shouldSchedulePostSettledLanguageEnsureRetries(
            hasCurrentActivity: currentActivity != nil,
            destinationLanguage: destination,
            ownedContentLanguage: acceptedLanguage,
            isStreamSwitchHoldActive: holdAfter
        )
        if Self.shouldSchedulePostSettledLanguageEnsureAfterSoftBudgetExhaust(
            baseShouldSchedule: baseLanguagePostSettled,
            isRequestEligible: eligibleAfter,
            visualNewlyConvergedThisFreeze: contentEnsureFreezeVisualNewlyConverged,
            partialPostSettledAlreadyScheduled: contentEnsureFreezePartialPostSettledScheduled
        ) {
            schedulePostSettledLanguageEnsureRetriesIfNeeded(destination: destination)
            contentEnsureFreezePartialPostSettledScheduled = true
        }
        // Settled soft budget must not permanent-freeze under continuous lock — sparse LH.
        if acceptedLanguage != destination {
            await armPostQuietLongHorizonLanguageEnsureIfNeeded()
        }
    }

    /// Cancels any in-flight delayed post-settled language soft-ensure retries.
    ///
    /// - SeeAlso: ``schedulePostSettledLanguageEnsureRetriesIfNeeded(destination:)``,
    ///   ``pushSettledLanguageAcceptanceContentIfNeeded()``.
    @MainActor
    private func cancelPostSettledLanguageEnsureRetries() {
        postSettledLanguageEnsureRetryTask?.cancel()
        postSettledLanguageEnsureRetryTask = nil
    }

    /// Schedules bounded delayed soft language ensure after post-hold settle still lags.
    ///
    /// Status-driven quiet correctly stops attach-storm thrash; these retries re-clear quiet
    /// on ``postSettledLanguageEnsureDelayedIntervalsMilliseconds`` so destination language can
    /// still converge while request is ineligible — without ending the interactive surface.
    /// Cancelled when language matches, destination advances, hold re-arms, ownership ends,
    /// or foreground owned-surface ensure takes over.
    ///
    /// - Parameter destination: Destination language code captured at settle lag time.
    /// - Precondition: Main actor; policy already decided schedule is needed.
    /// - Postcondition: At most one delayed retry task; each attempt may re-run soft ensure.
    /// - SeeAlso: ``shouldSchedulePostSettledLanguageEnsureRetries(hasCurrentActivity:destinationLanguage:ownedContentLanguage:isStreamSwitchHoldActive:)``,
    ///   ``ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``postSettledLanguageEnsureMaxDelayedAttempts``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    @MainActor
    private func schedulePostSettledLanguageEnsureRetriesIfNeeded(destination: String) {
        guard !destination.isEmpty else { return }
        cancelPostSettledLanguageEnsureRetries()
        let intervals = Self.postSettledLanguageEnsureDelayedIntervalsMilliseconds
        let maxAttempts = min(Self.postSettledLanguageEnsureMaxDelayedAttempts, intervals.count)
        guard maxAttempts > 0 else { return }

        postSettledLanguageEnsureRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 1...maxAttempts {
                let delayMs = intervals[attempt - 1]
                try? await Task.sleep(for: .milliseconds(delayMs))
                guard !Task.isCancelled else { return }
                if SharedPlayerManager.isRunningInUITestMode { return }
                #if DEBUG
                if self.isRunningUnderTest { return }
                #endif
                guard self.currentActivity != nil else { return }

                let manager = SharedPlayerManager.shared
                let currentDestination = await manager.liveActivityLanguageCodeForContentPush()
                // Destination advanced — a new settle / mutation owns recovery.
                guard currentDestination == destination else { return }
                let hold = await manager.isStreamSwitchPrePlayHoldActive
                let owned = self.currentActivity?.content.state.currentLanguage
                guard Self.shouldSchedulePostSettledLanguageEnsureRetries(
                    hasCurrentActivity: self.currentActivity != nil,
                    destinationLanguage: currentDestination,
                    ownedContentLanguage: owned,
                    isStreamSwitchHoldActive: hold
                ) else {
                    // Owned converged (or hold re-armed / unowned) — drop quiet for this dest.
                    if owned == destination {
                        self.languageEnsureQuietPendingDestination = nil
                        self.languageEnsureQuietSkipLogged = false
                        self.languageSettledAcceptanceConsumedDestination = nil
                    }
                    return
                }

                // Re-open one soft-ensure cycle without re-opening settle consume.
                self.languageEnsureQuietPendingDestination = nil
                self.languageEnsureQuietSkipLogged = false

                #if DEBUG
                print(
                    "🔴 Live Activity post-settled language ensure retry " +
                    "\(attempt)/\(maxAttempts) destination=\(destination) owned=\(owned ?? "nil")"
                )
                #endif
                await self.ensureAuthoritativeLanguageContentIfNeeded()

                let accepted = self.currentActivity?.content.state.currentLanguage
                if accepted == destination {
                    self.languageEnsureQuietPendingDestination = nil
                    self.languageEnsureQuietSkipLogged = false
                    self.languageSettledAcceptanceConsumedDestination = nil
                    return
                }

                // Still lagging — quiet status thrash until next delayed attempt or FG rail.
                let eligible = Self.isInteractiveLiveActivityRequestEligible(
                    areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
                    isApplicationActive: UIApplication.shared.applicationState == .active
                )
                if !eligible {
                    self.languageEnsureQuietPendingDestination = destination
                    self.languageEnsureQuietSkipLogged = false
                    self.pendingInteractiveLiveActivityEnsure = true
                }
            }
            self.postSettledLanguageEnsureRetryTask = nil
            // Post-settled budget is not terminal under continuous lock — arm sparse long-horizon.
            await self.armPostQuietLongHorizonLanguageEnsureIfNeeded()
        }
    }

    /// Post-hold playing soft-ensure re-arm after stream-switch hold/connect has cleared and the
    /// actor is authoritative `.playing` while owned visual still lags.
    ///
    /// Soft playing ensure often exhausts (or cannot run usefully while hold is active) during
    /// attach, then quiet-pending defers visual-only `.playing` repair for the rest of a lock
    /// stretch — Connecting or paused chrome while audio is live. Call this from authoritative
    /// audible start (``SharedPlayerManager/setPlaying()``) and soft-resume no-op reconcile so a
    /// **full** soft playing-ensure budget re-runs after hold clear (not only a single ActivityKit
    /// update — a lone settle push that immediately re-arms quiet would block the subsequent
    /// ``ensureAuthoritativePlayingContentIfNeeded()`` from ``setPlaying()``).
    ///
    /// **Quiet re-arm (post-audible):** Clears ``playingEnsureQuietPending`` so
    /// ``shouldDeferRedundantPlayingPushWhileQuiet`` / soft-ensure quiet gates do not drop the
    /// post-hold soft cycle, then ``ensureAuthoritativePlayingContentIfNeeded()``. Marks
    /// ``playingSettledAcceptanceConsumed`` while request is ineligible so soft-resume no-ops do
    /// not re-enter the settle entry. When owned visual still lags after that cycle while
    /// ineligible, quiet re-engages for status thrash **and** bounded delayed post-settled soft
    /// ensure retries re-clear quiet on a longer cadence without end+request.
    ///
    /// - Precondition: Main actor; stream-switch hold should already be cleared by the caller
    ///   (policy also gates on hold/connect). Interactive ``currentActivity`` may be nil (no-op).
    /// - Postcondition: When policy fires, soft playing ensure ran up to its budget; optional
    ///   delayed retries may remain in flight while visual still lags; no end+request; does not
    ///   invent `.playing` during hold/connect.
    /// - SeeAlso: ``shouldPushSettledPlayingAcceptance(actorVisual:ownedContentVisual:isStreamSwitchHoldActive:isConnectingPlayback:settledAcceptanceConsumed:isRequestEligible:)``,
    ///   ``shouldSchedulePostSettledPlayingEnsureRetries(hasCurrentActivity:actorVisual:ownedContentVisual:isStreamSwitchHoldActive:isConnectingPlayback:)``,
    ///   ``pushSettledLanguageAcceptanceContentIfNeeded()``,
    ///   ``ensureAuthoritativePlayingContentIfNeeded()``,
    ///   ``SharedPlayerManager/setPlaying()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    @MainActor
    func pushSettledPlayingAcceptanceContentIfNeeded() async {
        if SharedPlayerManager.isRunningInUITestMode { return }
        #if DEBUG
        if isRunningUnderTest { return }
        #endif
        guard currentActivity != nil else { return }

        let manager = SharedPlayerManager.shared
        let actorVisual = await manager.currentVisualState
        let hold = await manager.isStreamSwitchPrePlayHoldActive
        let connecting = await manager.isConnectingPlayback
        let ownedVisual = currentActivity?.content.state.visualState
        let requestEligible = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )

        // Owned convergence clears a prior settle consume marker.
        if Self.shouldClearPlayingSettledAcceptanceConsume(
            settledAcceptanceConsumed: playingSettledAcceptanceConsumed,
            ownedOrSystemVisual: ownedVisual
        ) {
            playingSettledAcceptanceConsumed = false
        }

        guard Self.shouldPushSettledPlayingAcceptance(
            actorVisual: actorVisual,
            ownedContentVisual: ownedVisual,
            isStreamSwitchHoldActive: hold,
            isConnectingPlayback: connecting,
            settledAcceptanceConsumed: playingSettledAcceptanceConsumed,
            isRequestEligible: requestEligible
        ) else {
            return
        }

        // Clear playing quiet so post-hold soft ensure gets a full budget (attach-storm quiet
        // must not freeze soft-resume / post-audible playing after settle).
        playingEnsureQuietPending = false
        playingEnsureQuietSkipLogged = false
        // Consume-once while ineligible — soft-resume no-ops must not re-open the settle entry.
        if !requestEligible {
            playingSettledAcceptanceConsumed = true
        }
        // Fresh settle cycle owns delayed retries + long-horizon for this play cycle.
        cancelPostSettledPlayingEnsureRetries()
        cancelPostQuietLongHorizonPlayingEnsure()

        #if DEBUG
        print(
            "🔴 Live Activity settled playing acceptance soft-ensure re-arm " +
            "(actor=\(actorVisual) owned=\(String(describing: ownedVisual)); " +
            "quiet cleared for full post-hold playing budget)"
        )
        #endif

        // Full soft playing-ensure budget after hold clear — prefer multi-attempt soft path
        // over a single dual-axis update so ActivityKit has more than one acceptance window
        // and setPlaying's trailing ensure is not blocked by an immediate quiet re-arm.
        await ensureAuthoritativePlayingContentIfNeeded()

        let acceptedVisual = currentActivity?.content.state.visualState
        if acceptedVisual == .playing {
            playingEnsureQuietPending = false
            playingEnsureQuietSkipLogged = false
            playingSettledAcceptanceConsumed = false
            return
        }

        // Still lagging while locked — re-enter quiet for status thrash, keep pending ensure
        // for become-active, and schedule longer-cadence soft ensure without end+request.
        let eligibleAfter = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        let holdAfter = await manager.isStreamSwitchPrePlayHoldActive
        let connectingAfter = await manager.isConnectingPlayback
        let actorAfter = await manager.currentVisualState
        if Self.shouldEnterPlayingEnsureQuietPending(
            playingStillStalled: acceptedVisual != .playing,
            isRequestEligible: eligibleAfter,
            ownedContentVisual: acceptedVisual,
            isAuthoritativePlayingWithoutHold: actorAfter == .playing && !holdAfter && !connectingAfter
        ) {
            playingEnsureQuietPending = true
            playingEnsureQuietSkipLogged = false
            markContentEnsureFreezeSoftBudgetExhausted()
            #if DEBUG
            print(
                "🔴 Live Activity settled playing acceptance still lagging " +
                "(owned=\(String(describing: acceptedVisual)); " +
                "quiet re-armed; freeze soft budget exhausted; recreation remains eligibility-gated)"
            )
            #endif
        }
        // Nested post-settled only for true language-new partial wins while ineligible;
        // same-stream visual stall skips post-settled (long-horizon owns residual).
        let basePostSettled = Self.shouldSchedulePostSettledPlayingEnsureRetries(
            hasCurrentActivity: currentActivity != nil,
            actorVisual: actorAfter,
            ownedContentVisual: acceptedVisual,
            isStreamSwitchHoldActive: holdAfter,
            isConnectingPlayback: connectingAfter
        )
        if Self.shouldSchedulePostSettledPlayingEnsureAfterSoftBudgetExhaust(
            baseShouldSchedule: basePostSettled,
            isRequestEligible: eligibleAfter,
            languageNewlyConvergedThisFreeze: contentEnsureFreezeLanguageNewlyConverged,
            partialPostSettledAlreadyScheduled: contentEnsureFreezePartialPostSettledScheduled
        ) {
            schedulePostSettledPlayingEnsureRetriesIfNeeded()
            contentEnsureFreezePartialPostSettledScheduled = true
        }
        // Settled soft budget must not permanent-freeze under continuous lock — sparse LH.
        if acceptedVisual != .playing {
            await armPostQuietLongHorizonPlayingEnsureIfNeeded()
        }
    }

    /// Cancels any in-flight delayed post-settled playing soft-ensure retries.
    ///
    /// - SeeAlso: ``schedulePostSettledPlayingEnsureRetriesIfNeeded()``,
    ///   ``pushSettledPlayingAcceptanceContentIfNeeded()``.
    @MainActor
    private func cancelPostSettledPlayingEnsureRetries() {
        postSettledPlayingEnsureRetryTask?.cancel()
        postSettledPlayingEnsureRetryTask = nil
    }

    /// Schedules bounded delayed soft playing ensure after post-hold settle still lags.
    ///
    /// Status-driven quiet correctly stops attach-storm thrash; these retries re-clear quiet
    /// on ``postSettledPlayingEnsureDelayedIntervalsMilliseconds`` so owned visual can still
    /// converge to `.playing` while request is ineligible — without ending the interactive
    /// surface. Cancelled when visual matches, hold/connect re-arms, ownership ends, control
    /// mutation, or foreground owned-surface ensure takes over.
    ///
    /// - Precondition: Main actor; policy already decided schedule is needed.
    /// - Postcondition: At most one delayed retry task; each attempt may re-run soft ensure.
    /// - SeeAlso: ``shouldSchedulePostSettledPlayingEnsureRetries(hasCurrentActivity:actorVisual:ownedContentVisual:isStreamSwitchHoldActive:isConnectingPlayback:)``,
    ///   ``ensureAuthoritativePlayingContentIfNeeded()``,
    ///   ``postSettledPlayingEnsureMaxDelayedAttempts``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    @MainActor
    private func schedulePostSettledPlayingEnsureRetriesIfNeeded() {
        cancelPostSettledPlayingEnsureRetries()
        let intervals = Self.postSettledPlayingEnsureDelayedIntervalsMilliseconds
        let maxAttempts = min(Self.postSettledPlayingEnsureMaxDelayedAttempts, intervals.count)
        guard maxAttempts > 0 else { return }

        postSettledPlayingEnsureRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 1...maxAttempts {
                let delayMs = intervals[attempt - 1]
                try? await Task.sleep(for: .milliseconds(delayMs))
                guard !Task.isCancelled else { return }
                if SharedPlayerManager.isRunningInUITestMode { return }
                #if DEBUG
                if self.isRunningUnderTest { return }
                #endif
                guard self.currentActivity != nil else { return }

                let manager = SharedPlayerManager.shared
                let actorVisual = await manager.currentVisualState
                let hold = await manager.isStreamSwitchPrePlayHoldActive
                let connecting = await manager.isConnectingPlayback
                let owned = self.currentActivity?.content.state.visualState
                guard Self.shouldSchedulePostSettledPlayingEnsureRetries(
                    hasCurrentActivity: self.currentActivity != nil,
                    actorVisual: actorVisual,
                    ownedContentVisual: owned,
                    isStreamSwitchHoldActive: hold,
                    isConnectingPlayback: connecting
                ) else {
                    // Owned converged (or hold/connect re-armed / actor left playing) — drop quiet.
                    if owned == .playing {
                        self.playingEnsureQuietPending = false
                        self.playingEnsureQuietSkipLogged = false
                        self.playingSettledAcceptanceConsumed = false
                    }
                    return
                }

                // Re-open one soft-ensure cycle without re-opening settle consume.
                self.playingEnsureQuietPending = false
                self.playingEnsureQuietSkipLogged = false

                #if DEBUG
                print(
                    "🔴 Live Activity post-settled playing ensure retry " +
                    "\(attempt)/\(maxAttempts) owned=\(String(describing: owned))"
                )
                #endif
                await self.ensureAuthoritativePlayingContentIfNeeded()

                let accepted = self.currentActivity?.content.state.visualState
                if accepted == .playing {
                    self.playingEnsureQuietPending = false
                    self.playingEnsureQuietSkipLogged = false
                    self.playingSettledAcceptanceConsumed = false
                    return
                }

                // Still lagging — quiet status thrash until next delayed attempt or FG rail.
                let eligible = Self.isInteractiveLiveActivityRequestEligible(
                    areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
                    isApplicationActive: UIApplication.shared.applicationState == .active
                )
                if !eligible {
                    self.playingEnsureQuietPending = true
                    self.playingEnsureQuietSkipLogged = false
                    self.pendingInteractiveLiveActivityEnsure = true
                }
            }
            self.postSettledPlayingEnsureRetryTask = nil
            // Post-settled budget is not terminal under continuous lock — arm sparse long-horizon.
            await self.armPostQuietLongHorizonPlayingEnsureIfNeeded()
        }
    }

    // MARK: - Post-quiet sparse long-horizon ensure (implementation)

    /// Cancels in-flight post-quiet long-horizon **playing** ensure for this freeze generation.
    ///
    /// - SeeAlso: ``armPostQuietLongHorizonPlayingEnsureIfNeeded()``,
    ///   ``schedulePostQuietLongHorizonPlayingEnsure()``.
    @MainActor
    private func cancelPostQuietLongHorizonPlayingEnsure() {
        postQuietLongHorizonPlayingEnsureTask?.cancel()
        postQuietLongHorizonPlayingEnsureTask = nil
    }

    /// Cancels in-flight post-quiet long-horizon **language** ensure for this freeze generation.
    ///
    /// - SeeAlso: ``armPostQuietLongHorizonLanguageEnsureIfNeeded()``,
    ///   ``schedulePostQuietLongHorizonLanguageEnsure(destination:)``.
    @MainActor
    private func cancelPostQuietLongHorizonLanguageEnsure() {
        postQuietLongHorizonLanguageEnsureTask?.cancel()
        postQuietLongHorizonLanguageEnsureTask = nil
    }

    /// Cancels in-flight post-quiet long-horizon **dual-axis** ensure for this freeze generation.
    ///
    /// - SeeAlso: ``armPostQuietLongHorizonDualAxisEnsureIfNeeded()``,
    ///   ``schedulePostQuietLongHorizonDualAxisEnsure()``.
    @MainActor
    private func cancelPostQuietLongHorizonDualAxisEnsure() {
        postQuietLongHorizonDualAxisEnsureTask?.cancel()
        postQuietLongHorizonDualAxisEnsureTask = nil
    }

    /// Cancels all long-horizon rails (teardown, foreground owned-surface, optimistic mutation).
    @MainActor
    private func cancelAllPostQuietLongHorizonEnsure() {
        cancelPostQuietLongHorizonPlayingEnsure()
        cancelPostQuietLongHorizonLanguageEnsure()
        cancelPostQuietLongHorizonDualAxisEnsure()
    }

    /// Arms sparse post-quiet long-horizon **playing** ensure when policy allows.
    ///
    /// Call after quiet entry, settled-still-lagging, partial acceptance re-arm, quiet defer,
    /// or post-settled budget exhaustion while request remains ineligible and owned visual lags.
    /// When language **also** lags **before** freeze, prefers the dual-axis rail (one co-push
    /// per fire) over a single-axis playing horizon that would race a language peer. After
    /// freeze, playing long-horizon stays the visual rail (language-only owns dest language).
    ///
    /// - Precondition: Main actor.
    /// - Postcondition: At most one long-horizon playing task (or dual-axis peer); no end+request;
    ///   does not invent `.playing` during hold/connect.
    /// - SeeAlso: ``shouldArmPostQuietLongHorizonPlayingEnsure(hasCurrentActivity:isRequestEligible:longHorizonAlreadyArmed:actorVisual:lastPushedVisual:ownedContentVisual:isStreamSwitchHoldActive:isConnectingPlayback:)``,
    ///   ``armPostQuietLongHorizonDualAxisEnsureIfNeeded()``,
    ///   ``schedulePostQuietLongHorizonPlayingEnsure()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    @MainActor
    func armPostQuietLongHorizonPlayingEnsureIfNeeded() async {
        if SharedPlayerManager.isRunningInUITestMode { return }
        #if DEBUG
        if isRunningUnderTest { return }
        #endif
        guard currentActivity != nil else { return }

        let manager = SharedPlayerManager.shared
        let actorVisual = await manager.currentVisualState
        let hold = await manager.isStreamSwitchPrePlayHoldActive
        let connecting = await manager.isConnectingPlayback
        let requestEligible = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        let destination = await manager.liveActivityLanguageCodeForContentPush()
        let languageLags = Self.shouldEnsureAuthoritativeLanguageContent(
            destinationLanguage: destination,
            ownedContentLanguage: currentActivity?.content.state.currentLanguage,
            lastPushedLanguage: lastPushedContent?.currentLanguage
        )
        let visualLags = Self.shouldEnsureAuthoritativePlayingContent(
            actorVisual: actorVisual,
            streamSwitchHold: hold,
            isConnectingPlayback: connecting,
            lastPushedVisual: lastPushedContent?.visualState,
            ownedVisual: currentActivity?.content.state.visualState
        )
        // Both axes lag → dual-axis rail owns sparse recovery before freeze.
        // After freeze, language-only + playing-only rails own the slots.
        if Self.shouldArmPostQuietLongHorizonDualAxisEnsure(
            hasCurrentActivity: true,
            isRequestEligible: requestEligible,
            dualAxisAlreadyArmed: postQuietLongHorizonDualAxisEnsureTask != nil,
            languageStillLags: languageLags,
            visualStillLags: visualLags,
            actorVisual: actorVisual,
            isStreamSwitchHoldActive: hold,
            isConnectingPlayback: connecting,
            freezeSoftBudgetExhausted: contentEnsureFreezeSoftBudgetExhausted,
            playingQuietPending: playingEnsureQuietPending
        ) {
            await armPostQuietLongHorizonDualAxisEnsureIfNeeded()
            return
        }
        let keepLanguageOnlyAfterFreeze = Self.shouldKeepOwnedVisualOnPostQuietLanguageLongHorizon(
            freezeSoftBudgetExhausted: contentEnsureFreezeSoftBudgetExhausted,
            playingQuietPending: playingEnsureQuietPending,
            isRequestEligible: requestEligible
        )
        if keepLanguageOnlyAfterFreeze {
            cancelPostQuietLongHorizonDualAxisEnsure()
        } else if postQuietLongHorizonDualAxisEnsureTask != nil, languageLags, visualLags {
            // Dual already armed for both-lag → do not also arm single-axis playing thrash.
            return
        }
        guard Self.shouldArmPostQuietLongHorizonPlayingEnsure(
            hasCurrentActivity: true,
            isRequestEligible: requestEligible,
            longHorizonAlreadyArmed: postQuietLongHorizonPlayingEnsureTask != nil,
            actorVisual: actorVisual,
            lastPushedVisual: lastPushedContent?.visualState,
            ownedContentVisual: currentActivity?.content.state.visualState,
            isStreamSwitchHoldActive: hold,
            isConnectingPlayback: connecting
        ) else {
            return
        }
        // Single-axis playing residual — drop dual if only visual still lags.
        if !languageLags {
            cancelPostQuietLongHorizonDualAxisEnsure()
        }
        schedulePostQuietLongHorizonPlayingEnsure()
    }

    /// Arms sparse post-quiet long-horizon **language** ensure when policy allows.
    ///
    /// When visual **also** lags **before** freeze, prefers the dual-axis rail. After freeze
    /// soft budget / playing quiet while ineligible, stays language-only (owned visual
    /// preserved). New destinations start a fresh freeze (prior language horizon cancelled;
    /// dual/language re-arm for the destination).
    ///
    /// - SeeAlso: ``shouldArmPostQuietLongHorizonLanguageEnsure(hasCurrentActivity:isRequestEligible:longHorizonAlreadyArmed:destinationLanguage:lastPushedLanguage:ownedContentLanguage:isStreamSwitchHoldActive:)``,
    ///   ``armPostQuietLongHorizonDualAxisEnsureIfNeeded()``,
    ///   ``schedulePostQuietLongHorizonLanguageEnsure(destination:)``.
    @MainActor
    func armPostQuietLongHorizonLanguageEnsureIfNeeded() async {
        if SharedPlayerManager.isRunningInUITestMode { return }
        #if DEBUG
        if isRunningUnderTest { return }
        #endif
        guard currentActivity != nil else { return }

        let manager = SharedPlayerManager.shared
        let destination = await manager.liveActivityLanguageCodeForContentPush()
        let hold = await manager.isStreamSwitchPrePlayHoldActive
        let connecting = await manager.isConnectingPlayback
        let actorVisual = await manager.currentVisualState
        let requestEligible = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        let languageLags = Self.shouldEnsureAuthoritativeLanguageContent(
            destinationLanguage: destination,
            ownedContentLanguage: currentActivity?.content.state.currentLanguage,
            lastPushedLanguage: lastPushedContent?.currentLanguage
        )
        let visualLags = Self.shouldEnsureAuthoritativePlayingContent(
            actorVisual: actorVisual,
            streamSwitchHold: hold,
            isConnectingPlayback: connecting,
            lastPushedVisual: lastPushedContent?.visualState,
            ownedVisual: currentActivity?.content.state.visualState
        )
        if Self.shouldArmPostQuietLongHorizonDualAxisEnsure(
            hasCurrentActivity: true,
            isRequestEligible: requestEligible,
            dualAxisAlreadyArmed: postQuietLongHorizonDualAxisEnsureTask != nil,
            languageStillLags: languageLags,
            visualStillLags: visualLags,
            actorVisual: actorVisual,
            isStreamSwitchHoldActive: hold,
            isConnectingPlayback: connecting,
            freezeSoftBudgetExhausted: contentEnsureFreezeSoftBudgetExhausted,
            playingQuietPending: playingEnsureQuietPending
        ) {
            await armPostQuietLongHorizonDualAxisEnsureIfNeeded()
            return
        }
        let keepLanguageOnlyAfterFreeze = Self.shouldKeepOwnedVisualOnPostQuietLanguageLongHorizon(
            freezeSoftBudgetExhausted: contentEnsureFreezeSoftBudgetExhausted,
            playingQuietPending: playingEnsureQuietPending,
            isRequestEligible: requestEligible
        )
        if keepLanguageOnlyAfterFreeze {
            cancelPostQuietLongHorizonDualAxisEnsure()
        } else if postQuietLongHorizonDualAxisEnsureTask != nil, languageLags, visualLags {
            return
        }
        guard Self.shouldArmPostQuietLongHorizonLanguageEnsure(
            hasCurrentActivity: true,
            isRequestEligible: requestEligible,
            longHorizonAlreadyArmed: postQuietLongHorizonLanguageEnsureTask != nil,
            destinationLanguage: destination,
            lastPushedLanguage: lastPushedContent?.currentLanguage,
            ownedContentLanguage: currentActivity?.content.state.currentLanguage,
            isStreamSwitchHoldActive: hold
        ) else {
            return
        }
        if !visualLags {
            cancelPostQuietLongHorizonDualAxisEnsure()
        }
        schedulePostQuietLongHorizonLanguageEnsure(destination: destination)
    }

    /// Arms sparse post-quiet long-horizon **dual-axis** ensure when both axes lag **before**
    /// freeze. After freeze soft budget / playing quiet while ineligible, this no-ops so
    /// language-only and playing-only rails own the sparse slots.
    ///
    /// - SeeAlso: ``shouldArmPostQuietLongHorizonDualAxisEnsure(hasCurrentActivity:isRequestEligible:dualAxisAlreadyArmed:languageStillLags:visualStillLags:actorVisual:isStreamSwitchHoldActive:isConnectingPlayback:)``,
    ///   ``schedulePostQuietLongHorizonDualAxisEnsure()``,
    ///   ``ensureAuthoritativeDualAxisContentIfNeeded()``.
    @MainActor
    func armPostQuietLongHorizonDualAxisEnsureIfNeeded() async {
        if SharedPlayerManager.isRunningInUITestMode { return }
        #if DEBUG
        if isRunningUnderTest { return }
        #endif
        guard currentActivity != nil else { return }

        let manager = SharedPlayerManager.shared
        let destination = await manager.liveActivityLanguageCodeForContentPush()
        let hold = await manager.isStreamSwitchPrePlayHoldActive
        let connecting = await manager.isConnectingPlayback
        let actorVisual = await manager.currentVisualState
        let requestEligible = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        let languageLags = Self.shouldEnsureAuthoritativeLanguageContent(
            destinationLanguage: destination,
            ownedContentLanguage: currentActivity?.content.state.currentLanguage,
            lastPushedLanguage: lastPushedContent?.currentLanguage
        )
        let visualLags = Self.shouldEnsureAuthoritativePlayingContent(
            actorVisual: actorVisual,
            streamSwitchHold: hold,
            isConnectingPlayback: connecting,
            lastPushedVisual: lastPushedContent?.visualState,
            ownedVisual: currentActivity?.content.state.visualState
        )
        guard Self.shouldArmPostQuietLongHorizonDualAxisEnsure(
            hasCurrentActivity: true,
            isRequestEligible: requestEligible,
            dualAxisAlreadyArmed: postQuietLongHorizonDualAxisEnsureTask != nil,
            languageStillLags: languageLags,
            visualStillLags: visualLags,
            actorVisual: actorVisual,
            isStreamSwitchHoldActive: hold,
            isConnectingPlayback: connecting,
            freezeSoftBudgetExhausted: contentEnsureFreezeSoftBudgetExhausted,
            playingQuietPending: playingEnsureQuietPending
        ) else {
            return
        }
        // Dual-axis owns this freeze — drop single-axis peers that would double-fire.
        cancelPostQuietLongHorizonPlayingEnsure()
        cancelPostQuietLongHorizonLanguageEnsure()
        postQuietLongHorizonDualAxisExhausted = false
        schedulePostQuietLongHorizonDualAxisEnsure()
    }

    /// Schedules sparse delayed playing soft-ensure fires after quiet / settle still lags.
    ///
    /// Each fire clears playing quiet once, optionally dual-axis language quiet when both lag,
    /// runs soft ensure, then re-engages quiet between fires while ineligible.
    ///
    /// - SeeAlso: ``postQuietLongHorizonEnsureDelayedIntervalsMilliseconds``,
    ///   ``armPostQuietLongHorizonPlayingEnsureIfNeeded()``.
    @MainActor
    private func schedulePostQuietLongHorizonPlayingEnsure() {
        cancelPostQuietLongHorizonPlayingEnsure()
        postQuietLongHorizonPlayingEnsureGeneration &+= 1
        let generation = postQuietLongHorizonPlayingEnsureGeneration
        let intervals = Self.postQuietLongHorizonEnsureDelayedIntervalsMilliseconds
        let maxAttempts = min(Self.postQuietLongHorizonEnsureMaxDelayedAttempts, intervals.count)
        guard maxAttempts > 0 else { return }

        postQuietLongHorizonPlayingEnsureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 1...maxAttempts {
                let delayMs = intervals[attempt - 1]
                try? await Task.sleep(for: .milliseconds(delayMs))
                guard !Task.isCancelled else { return }
                guard generation == self.postQuietLongHorizonPlayingEnsureGeneration else { return }
                if SharedPlayerManager.isRunningInUITestMode { return }
                #if DEBUG
                if self.isRunningUnderTest { return }
                #endif
                guard self.currentActivity != nil else {
                    self.postQuietLongHorizonPlayingEnsureTask = nil
                    return
                }

                let manager = SharedPlayerManager.shared
                let actorVisual = await manager.currentVisualState
                let hold = await manager.isStreamSwitchPrePlayHoldActive
                let connecting = await manager.isConnectingPlayback
                let ownedVisual = self.currentActivity?.content.state.visualState
                let lastVisual = self.lastPushedContent?.visualState

                if Self.shouldCancelPostQuietLongHorizonPlayingEnsure(
                    hasCurrentActivity: self.currentActivity != nil,
                    ownedContentVisual: ownedVisual,
                    actorVisual: actorVisual
                ) {
                    if ownedVisual == .playing {
                        self.playingEnsureQuietPending = false
                        self.playingEnsureQuietSkipLogged = false
                        self.playingSettledAcceptanceConsumed = false
                    }
                    self.postQuietLongHorizonPlayingEnsureTask = nil
                    return
                }

                guard Self.shouldContinuePostQuietLongHorizonPlayingEnsure(
                    hasCurrentActivity: true,
                    actorVisual: actorVisual,
                    lastPushedVisual: lastVisual,
                    ownedContentVisual: ownedVisual,
                    isStreamSwitchHoldActive: hold,
                    isConnectingPlayback: connecting
                ) else {
                    self.postQuietLongHorizonPlayingEnsureTask = nil
                    return
                }

                // One quiet clear per fire — status thrash stays protected between fires.
                self.playingEnsureQuietPending = false
                self.playingEnsureQuietSkipLogged = false

                let destination = await manager.liveActivityLanguageCodeForContentPush()
                let ownedLanguage = self.currentActivity?.content.state.currentLanguage
                let languageLags = Self.shouldEnsureAuthoritativeLanguageContent(
                    destinationLanguage: destination,
                    ownedContentLanguage: ownedLanguage,
                    lastPushedLanguage: self.lastPushedContent?.currentLanguage
                )
                let visualLags = true
                let fireEligible = Self.isInteractiveLiveActivityRequestEligible(
                    areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
                    isApplicationActive: UIApplication.shared.applicationState == .active
                )
                // Both axes lag → one dual-axis co-push before freeze (not language then playing).
                // After freeze, playing long-horizon stays the visual rail.
                if Self.shouldRunPostQuietLongHorizonDualAxisEnsure(
                    languageStillLags: languageLags,
                    visualStillLags: visualLags,
                    actorVisual: actorVisual,
                    isStreamSwitchHoldActive: hold,
                    isConnectingPlayback: connecting,
                    freezeSoftBudgetExhausted: self.contentEnsureFreezeSoftBudgetExhausted,
                    playingQuietPending: self.playingEnsureQuietPending,
                    isRequestEligible: fireEligible
                ) {
                    self.languageEnsureQuietPendingDestination = nil
                    self.languageEnsureQuietSkipLogged = false
                    #if DEBUG
                    print(
                        "🔴 Live Activity post-quiet long-horizon dual-axis ensure retry " +
                        "\(attempt)/\(maxAttempts) (via playing rail) owned=\(String(describing: ownedVisual))"
                    )
                    #endif
                    await self.ensureAuthoritativeDualAxisContentIfNeeded()
                    let acceptedAfterDual = self.currentActivity?.content.state.visualState
                    if acceptedAfterDual == .playing {
                        self.playingEnsureQuietPending = false
                        self.playingEnsureQuietSkipLogged = false
                        self.playingSettledAcceptanceConsumed = false
                        self.dualAxisSettledAcceptanceConsumed = false
                        self.postQuietLongHorizonDualAxisExhausted = false
                        self.postQuietLongHorizonPlayingEnsureTask = nil
                        return
                    }
                    let eligibleAfterDual = Self.isInteractiveLiveActivityRequestEligible(
                        areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
                        isApplicationActive: UIApplication.shared.applicationState == .active
                    )
                    if !eligibleAfterDual {
                        self.playingEnsureQuietPending = true
                        self.playingEnsureQuietSkipLogged = false
                        self.pendingInteractiveLiveActivityEnsure = true
                    }
                    continue
                }

                #if DEBUG
                print(
                    "🔴 Live Activity post-quiet long-horizon playing ensure retry " +
                    "\(attempt)/\(maxAttempts) owned=\(String(describing: ownedVisual))"
                )
                #endif

                await self.ensureAuthoritativePlayingContentIfNeeded()

                let accepted = self.currentActivity?.content.state.visualState
                if accepted == .playing {
                    self.playingEnsureQuietPending = false
                    self.playingEnsureQuietSkipLogged = false
                    self.playingSettledAcceptanceConsumed = false
                    self.dualAxisSettledAcceptanceConsumed = false
                    self.postQuietLongHorizonDualAxisExhausted = false
                    self.postQuietLongHorizonPlayingEnsureTask = nil
                    return
                }

                let eligible = Self.isInteractiveLiveActivityRequestEligible(
                    areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
                    isApplicationActive: UIApplication.shared.applicationState == .active
                )
                if !eligible {
                    self.playingEnsureQuietPending = true
                    self.playingEnsureQuietSkipLogged = false
                    self.pendingInteractiveLiveActivityEnsure = true
                }
            }
            self.postQuietLongHorizonPlayingEnsureTask = nil
        }
    }

    /// Schedules sparse delayed language soft-ensure fires after quiet / settle still lags.
    ///
    /// - Parameter destination: Destination language code captured at arm time (re-checked each fire).
    /// - SeeAlso: ``postQuietLongHorizonEnsureDelayedIntervalsMilliseconds``,
    ///   ``armPostQuietLongHorizonLanguageEnsureIfNeeded()``.
    @MainActor
    private func schedulePostQuietLongHorizonLanguageEnsure(destination: String) {
        guard !destination.isEmpty else { return }
        cancelPostQuietLongHorizonLanguageEnsure()
        postQuietLongHorizonLanguageEnsureGeneration &+= 1
        let generation = postQuietLongHorizonLanguageEnsureGeneration
        let intervals = Self.postQuietLongHorizonEnsureDelayedIntervalsMilliseconds
        let maxAttempts = min(Self.postQuietLongHorizonEnsureMaxDelayedAttempts, intervals.count)
        guard maxAttempts > 0 else { return }

        postQuietLongHorizonLanguageEnsureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 1...maxAttempts {
                let delayMs = intervals[attempt - 1]
                try? await Task.sleep(for: .milliseconds(delayMs))
                guard !Task.isCancelled else { return }
                guard generation == self.postQuietLongHorizonLanguageEnsureGeneration else { return }
                if SharedPlayerManager.isRunningInUITestMode { return }
                #if DEBUG
                if self.isRunningUnderTest { return }
                #endif
                guard self.currentActivity != nil else {
                    self.postQuietLongHorizonLanguageEnsureTask = nil
                    return
                }

                let manager = SharedPlayerManager.shared
                let currentDestination = await manager.liveActivityLanguageCodeForContentPush()
                // Destination advanced — cancel this freeze and re-arm for the new destination (B2).
                guard currentDestination == destination else {
                    self.postQuietLongHorizonLanguageEnsureTask = nil
                    await self.armPostQuietLongHorizonLanguageEnsureIfNeeded()
                    return
                }
                let hold = await manager.isStreamSwitchPrePlayHoldActive
                let connecting = await manager.isConnectingPlayback
                let actorVisual = await manager.currentVisualState
                let ownedLanguage = self.currentActivity?.content.state.currentLanguage
                let lastLanguage = self.lastPushedContent?.currentLanguage

                if Self.shouldCancelPostQuietLongHorizonLanguageEnsure(
                    hasCurrentActivity: self.currentActivity != nil,
                    destinationLanguage: currentDestination,
                    ownedContentLanguage: ownedLanguage
                ) {
                    if ownedLanguage == destination {
                        self.languageEnsureQuietPendingDestination = nil
                        self.languageEnsureQuietSkipLogged = false
                        self.languageSettledAcceptanceConsumedDestination = nil
                    }
                    self.postQuietLongHorizonLanguageEnsureTask = nil
                    return
                }

                guard Self.shouldContinuePostQuietLongHorizonLanguageEnsure(
                    hasCurrentActivity: true,
                    destinationLanguage: currentDestination,
                    lastPushedLanguage: lastLanguage,
                    ownedContentLanguage: ownedLanguage,
                    isStreamSwitchHoldActive: hold
                ) else {
                    self.postQuietLongHorizonLanguageEnsureTask = nil
                    return
                }

                self.languageEnsureQuietPendingDestination = nil
                self.languageEnsureQuietSkipLogged = false

                let ownedVisual = self.currentActivity?.content.state.visualState
                let languageLags = true
                let visualLags = Self.shouldEnsureAuthoritativePlayingContent(
                    actorVisual: actorVisual,
                    streamSwitchHold: hold,
                    isConnectingPlayback: connecting,
                    lastPushedVisual: self.lastPushedContent?.visualState,
                    ownedVisual: ownedVisual
                )
                let fireEligible = Self.isInteractiveLiveActivityRequestEligible(
                    areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
                    isApplicationActive: UIApplication.shared.applicationState == .active
                )
                let keepOwnedVisual = Self.shouldKeepOwnedVisualOnPostQuietLanguageLongHorizon(
                    freezeSoftBudgetExhausted: self.contentEnsureFreezeSoftBudgetExhausted,
                    playingQuietPending: self.playingEnsureQuietPending,
                    isRequestEligible: fireEligible
                )
                // Both axes lag → one dual-axis co-push before freeze.
                // After freeze, language-only preserves owned visual.
                if Self.shouldRunPostQuietLongHorizonDualAxisEnsure(
                    languageStillLags: languageLags,
                    visualStillLags: visualLags,
                    actorVisual: actorVisual,
                    isStreamSwitchHoldActive: hold,
                    isConnectingPlayback: connecting,
                    freezeSoftBudgetExhausted: self.contentEnsureFreezeSoftBudgetExhausted,
                    playingQuietPending: self.playingEnsureQuietPending,
                    isRequestEligible: fireEligible
                ) {
                    self.playingEnsureQuietPending = false
                    self.playingEnsureQuietSkipLogged = false
                    #if DEBUG
                    print(
                        "🔴 Live Activity post-quiet long-horizon dual-axis ensure retry " +
                        "\(attempt)/\(maxAttempts) (via language rail) destination=\(destination) " +
                        "ownedLang=\(ownedLanguage ?? "nil") ownedVisual=\(String(describing: ownedVisual))"
                    )
                    #endif
                    await self.ensureAuthoritativeDualAxisContentIfNeeded()
                    let acceptedLangAfterDual = self.currentActivity?.content.state.currentLanguage
                    if acceptedLangAfterDual == destination {
                        self.languageEnsureQuietPendingDestination = nil
                        self.languageEnsureQuietSkipLogged = false
                        self.languageSettledAcceptanceConsumedDestination = nil
                        self.postQuietLongHorizonLanguageEnsureTask = nil
                        return
                    }
                    let eligibleAfterDual = Self.isInteractiveLiveActivityRequestEligible(
                        areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
                        isApplicationActive: UIApplication.shared.applicationState == .active
                    )
                    if !eligibleAfterDual {
                        self.languageEnsureQuietPendingDestination = destination
                        self.languageEnsureQuietSkipLogged = false
                        self.pendingInteractiveLiveActivityEnsure = true
                    }
                    continue
                }

                #if DEBUG
                print(
                    "🔴 Live Activity post-quiet long-horizon language ensure retry " +
                    "\(attempt)/\(maxAttempts) destination=\(destination) owned=\(ownedLanguage ?? "nil")"
                )
                #endif

                await self.ensureAuthoritativeLanguageContentIfNeeded(
                    preservingOwnedVisual: keepOwnedVisual
                )

                let accepted = self.currentActivity?.content.state.currentLanguage
                if accepted == destination {
                    self.languageEnsureQuietPendingDestination = nil
                    self.languageEnsureQuietSkipLogged = false
                    self.languageSettledAcceptanceConsumedDestination = nil
                    self.postQuietLongHorizonLanguageEnsureTask = nil
                    return
                }

                let eligible = Self.isInteractiveLiveActivityRequestEligible(
                    areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
                    isApplicationActive: UIApplication.shared.applicationState == .active
                )
                if !eligible {
                    self.languageEnsureQuietPendingDestination = destination
                    self.languageEnsureQuietSkipLogged = false
                    self.pendingInteractiveLiveActivityEnsure = true
                }
            }
            self.postQuietLongHorizonLanguageEnsureTask = nil
        }
    }

    /// Schedules sparse delayed **dual-axis** soft-ensure fires after quiet / settle still lags on both axes.
    ///
    /// Each fire clears both quiet flags once, runs one ``ensureAuthoritativeDualAxisContentIfNeeded()``,
    /// then re-engages quiet between fires while ineligible. Logs dual-axis retries distinctly.
    ///
    /// - SeeAlso: ``postQuietLongHorizonEnsureDelayedIntervalsMilliseconds``,
    ///   ``armPostQuietLongHorizonDualAxisEnsureIfNeeded()``,
    ///   ``ensureAuthoritativeDualAxisContentIfNeeded()``.
    @MainActor
    private func schedulePostQuietLongHorizonDualAxisEnsure() {
        cancelPostQuietLongHorizonDualAxisEnsure()
        postQuietLongHorizonDualAxisEnsureGeneration &+= 1
        let generation = postQuietLongHorizonDualAxisEnsureGeneration
        let intervals = Self.postQuietLongHorizonEnsureDelayedIntervalsMilliseconds
        let maxAttempts = min(Self.postQuietLongHorizonEnsureMaxDelayedAttempts, intervals.count)
        guard maxAttempts > 0 else { return }

        postQuietLongHorizonDualAxisEnsureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 1...maxAttempts {
                let delayMs = intervals[attempt - 1]
                try? await Task.sleep(for: .milliseconds(delayMs))
                guard !Task.isCancelled else { return }
                guard generation == self.postQuietLongHorizonDualAxisEnsureGeneration else { return }
                if SharedPlayerManager.isRunningInUITestMode { return }
                #if DEBUG
                if self.isRunningUnderTest { return }
                #endif
                guard self.currentActivity != nil else {
                    self.postQuietLongHorizonDualAxisEnsureTask = nil
                    return
                }

                let manager = SharedPlayerManager.shared
                let destination = await manager.liveActivityLanguageCodeForContentPush()
                let hold = await manager.isStreamSwitchPrePlayHoldActive
                let connecting = await manager.isConnectingPlayback
                let actorVisual = await manager.currentVisualState
                let ownedLanguage = self.currentActivity?.content.state.currentLanguage
                let ownedVisual = self.currentActivity?.content.state.visualState
                let languageLags = Self.shouldEnsureAuthoritativeLanguageContent(
                    destinationLanguage: destination,
                    ownedContentLanguage: ownedLanguage,
                    lastPushedLanguage: self.lastPushedContent?.currentLanguage
                )
                let visualLags = Self.shouldEnsureAuthoritativePlayingContent(
                    actorVisual: actorVisual,
                    streamSwitchHold: hold,
                    isConnectingPlayback: connecting,
                    lastPushedVisual: self.lastPushedContent?.visualState,
                    ownedVisual: ownedVisual
                )

                if Self.shouldCancelPostQuietLongHorizonDualAxisEnsure(
                    hasCurrentActivity: self.currentActivity != nil,
                    languageStillLags: languageLags,
                    visualStillLags: visualLags,
                    actorVisual: actorVisual
                ) {
                    if !languageLags {
                        self.languageEnsureQuietPendingDestination = nil
                        self.languageEnsureQuietSkipLogged = false
                        self.languageSettledAcceptanceConsumedDestination = nil
                    }
                    if !visualLags {
                        self.playingEnsureQuietPending = false
                        self.playingEnsureQuietSkipLogged = false
                        self.playingSettledAcceptanceConsumed = false
                        self.dualAxisSettledAcceptanceConsumed = false
                    }
                    self.postQuietLongHorizonDualAxisExhausted = false
                    self.postQuietLongHorizonDualAxisEnsureTask = nil
                    // Residual single-axis lag — hand off to single-axis rail.
                    if languageLags {
                        await self.armPostQuietLongHorizonLanguageEnsureIfNeeded()
                    }
                    if visualLags {
                        await self.armPostQuietLongHorizonPlayingEnsureIfNeeded()
                    }
                    return
                }

                let fireEligible = Self.isInteractiveLiveActivityRequestEligible(
                    areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
                    isApplicationActive: UIApplication.shared.applicationState == .active
                )
                guard Self.shouldContinuePostQuietLongHorizonDualAxisEnsure(
                    hasCurrentActivity: true,
                    languageStillLags: languageLags,
                    visualStillLags: visualLags,
                    actorVisual: actorVisual,
                    isStreamSwitchHoldActive: hold,
                    isConnectingPlayback: connecting,
                    freezeSoftBudgetExhausted: self.contentEnsureFreezeSoftBudgetExhausted,
                    playingQuietPending: self.playingEnsureQuietPending,
                    isRequestEligible: fireEligible
                ) else {
                    // Only one axis still lags (or hold re-armed) — hand off single-axis rails.
                    self.postQuietLongHorizonDualAxisEnsureTask = nil
                    if languageLags {
                        await self.armPostQuietLongHorizonLanguageEnsureIfNeeded()
                    }
                    if visualLags {
                        await self.armPostQuietLongHorizonPlayingEnsureIfNeeded()
                    }
                    return
                }

                // One dual quiet clear per fire.
                self.playingEnsureQuietPending = false
                self.playingEnsureQuietSkipLogged = false
                self.languageEnsureQuietPendingDestination = nil
                self.languageEnsureQuietSkipLogged = false

                #if DEBUG
                print(
                    "🔴 Live Activity post-quiet long-horizon dual-axis ensure retry " +
                    "\(attempt)/\(maxAttempts) destination=\(destination) " +
                    "ownedLang=\(ownedLanguage ?? "nil") ownedVisual=\(String(describing: ownedVisual))"
                )
                #endif

                await self.ensureAuthoritativeDualAxisContentIfNeeded()

                let acceptedLang = self.currentActivity?.content.state.currentLanguage
                let acceptedVisual = self.currentActivity?.content.state.visualState
                let stillLanguageLags = Self.shouldEnsureAuthoritativeLanguageContent(
                    destinationLanguage: destination,
                    ownedContentLanguage: acceptedLang,
                    lastPushedLanguage: self.lastPushedContent?.currentLanguage
                )
                let stillVisualLags = Self.shouldEnsureAuthoritativePlayingContent(
                    actorVisual: await manager.currentVisualState,
                    streamSwitchHold: await manager.isStreamSwitchPrePlayHoldActive,
                    isConnectingPlayback: await manager.isConnectingPlayback,
                    lastPushedVisual: self.lastPushedContent?.visualState,
                    ownedVisual: acceptedVisual
                )
                if !stillLanguageLags && !stillVisualLags {
                    self.languageEnsureQuietPendingDestination = nil
                    self.playingEnsureQuietPending = false
                    self.languageSettledAcceptanceConsumedDestination = nil
                    self.playingSettledAcceptanceConsumed = false
                    self.dualAxisSettledAcceptanceConsumed = false
                    self.postQuietLongHorizonDualAxisExhausted = false
                    self.postQuietLongHorizonDualAxisEnsureTask = nil
                    return
                }

                let eligible = Self.isInteractiveLiveActivityRequestEligible(
                    areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
                    isApplicationActive: UIApplication.shared.applicationState == .active
                )
                if !eligible {
                    if stillLanguageLags {
                        self.languageEnsureQuietPendingDestination = destination
                        self.languageEnsureQuietSkipLogged = false
                    }
                    if stillVisualLags {
                        self.playingEnsureQuietPending = true
                        self.playingEnsureQuietSkipLogged = false
                    }
                    self.pendingInteractiveLiveActivityEnsure = true
                }
                // Last fire without acceptance → mark dual-axis exhaust for presentable recovery.
                if attempt == maxAttempts,
                   Self.shouldMarkDualAxisLongHorizonExhausted(
                    languageStillLags: stillLanguageLags,
                    visualStillLags: stillVisualLags,
                    isRequestEligible: eligible
                   ) {
                    self.postQuietLongHorizonDualAxisExhausted = true
                    self.pendingInteractiveLiveActivityEnsure = true
                    #if DEBUG
                    print(
                        "🔴 Live Activity dual-axis long-horizon exhausted " +
                        "(languageLags=\(stillLanguageLags) visualLags=\(stillVisualLags); " +
                        "pending presentable ensure; recreation remains eligibility-gated)"
                    )
                    #endif
                }
            }
            self.postQuietLongHorizonDualAxisEnsureTask = nil
        }
    }

    /// Soft dual-axis ContentState ensure: destination language **and** authoritative playing visual
    /// in one soft-push loop (not sequential single-axis budgets that each re-quiet).
    ///
    /// Clears both quiet flags, runs up to ``authoritativePlayingContentEnsureMaxAttempts``
    /// ``updateCurrentActivity()`` pushes (candidate always carries both axes), and re-engages
    /// quiet only for still-lagging axes after the budget. Does **not** invent `.playing` during
    /// hold/connect. Does **not** end+request.
    ///
    /// - SeeAlso: ``pushSettledDualAxisAcceptanceContentIfNeeded()``,
    ///   ``schedulePostQuietLongHorizonDualAxisEnsure()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    @MainActor
    func ensureAuthoritativeDualAxisContentIfNeeded() async {
        if SharedPlayerManager.isRunningInUITestMode { return }
        #if DEBUG
        if isRunningUnderTest { return }
        #endif
        guard currentActivity != nil else { return }

        let manager = SharedPlayerManager.shared
        let hold = await manager.isStreamSwitchPrePlayHoldActive
        let connecting = await manager.isConnectingPlayback
        let actorVisual = await manager.currentVisualState
        // Never invent playing during Connecting honesty window.
        guard actorVisual == .playing, !hold, !connecting else { return }

        let destination = await manager.liveActivityLanguageCodeForContentPush()
        let languageLags = Self.shouldEnsureAuthoritativeLanguageContent(
            destinationLanguage: destination,
            ownedContentLanguage: currentActivity?.content.state.currentLanguage,
            lastPushedLanguage: lastPushedContent?.currentLanguage
        )
        let visualLags = Self.shouldEnsureAuthoritativePlayingContent(
            actorVisual: actorVisual,
            streamSwitchHold: hold,
            isConnectingPlayback: connecting,
            lastPushedVisual: lastPushedContent?.visualState,
            ownedVisual: currentActivity?.content.state.visualState
        )
        guard languageLags || visualLags else {
            languageEnsureQuietPendingDestination = nil
            playingEnsureQuietPending = false
            postQuietLongHorizonDualAxisExhausted = false
            cancelPostQuietLongHorizonDualAxisEnsure()
            return
        }

        // Clear both quiets so updateCurrentActivity is not deferred on either axis.
        languageEnsureQuietPendingDestination = nil
        languageEnsureQuietSkipLogged = false
        playingEnsureQuietPending = false
        playingEnsureQuietSkipLogged = false

        guard Self.shouldStartAuthoritativeContentEnsureSoftPushLoop(
            softPushesAlreadyInFlight: dualAxisEnsureSoftPushesInFlight
        ) else {
            return
        }
        dualAxisEnsureSoftPushesInFlight = true
        defer { dualAxisEnsureSoftPushesInFlight = false }

        let requestEligible = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )

        for attempt in 1...Self.authoritativePlayingContentEnsureMaxAttempts {
            guard currentActivity != nil else { return }

            let loopHold = await manager.isStreamSwitchPrePlayHoldActive
            let loopConnecting = await manager.isConnectingPlayback
            let loopActor = await manager.currentVisualState
            guard loopActor == .playing, !loopHold, !loopConnecting else { return }

            #if DEBUG
            print(
                "🔴 Live Activity dual-axis ensure " +
                "attempt=\(attempt)/\(Self.authoritativePlayingContentEnsureMaxAttempts) " +
                "ownedLang=\(currentActivity?.content.state.currentLanguage ?? "nil") " +
                "ownedVisual=\(String(describing: currentActivity?.content.state.visualState))"
            )
            #endif
            await updateCurrentActivity()

            let acceptedLang = currentActivity?.content.state.currentLanguage
            let acceptedVisual = currentActivity?.content.state.visualState
            let dest = await manager.liveActivityLanguageCodeForContentPush()
            let stillLang = Self.shouldEnsureAuthoritativeLanguageContent(
                destinationLanguage: dest,
                ownedContentLanguage: acceptedLang,
                lastPushedLanguage: lastPushedContent?.currentLanguage
            )
            let stillVisual = Self.shouldEnsureAuthoritativePlayingContent(
                actorVisual: await manager.currentVisualState,
                streamSwitchHold: await manager.isStreamSwitchPrePlayHoldActive,
                isConnectingPlayback: await manager.isConnectingPlayback,
                lastPushedVisual: lastPushedContent?.visualState,
                ownedVisual: acceptedVisual
            )
            if !stillLang && !stillVisual {
                languageEnsureQuietPendingDestination = nil
                playingEnsureQuietPending = false
                languageSettledAcceptanceConsumedDestination = nil
                playingSettledAcceptanceConsumed = false
                dualAxisSettledAcceptanceConsumed = false
                postQuietLongHorizonDualAxisExhausted = false
                cancelAllPostQuietLongHorizonEnsure()
                return
            }
            if let delayMs = Self.softEnsureInterAttemptDelayMilliseconds(
                attempt: attempt,
                maxAttempts: Self.authoritativePlayingContentEnsureMaxAttempts,
                isRequestEligible: requestEligible
            ) {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(delayMs))
            }
        }

        // Soft dual budget exhausted — re-quiet only lagging axes while ineligible.
        let finalDest = await manager.liveActivityLanguageCodeForContentPush()
        let finalLangLags = Self.shouldEnsureAuthoritativeLanguageContent(
            destinationLanguage: finalDest,
            ownedContentLanguage: currentActivity?.content.state.currentLanguage,
            lastPushedLanguage: lastPushedContent?.currentLanguage
        )
        let finalVisualLags = Self.shouldEnsureAuthoritativePlayingContent(
            actorVisual: await manager.currentVisualState,
            streamSwitchHold: await manager.isStreamSwitchPrePlayHoldActive,
            isConnectingPlayback: await manager.isConnectingPlayback,
            lastPushedVisual: lastPushedContent?.visualState,
            ownedVisual: currentActivity?.content.state.visualState
        )
        let eligibleAfter = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        if !eligibleAfter {
            if finalLangLags {
                languageEnsureQuietPendingDestination = finalDest
                languageEnsureQuietSkipLogged = false
            }
            let finalHold = await manager.isStreamSwitchPrePlayHoldActive
            let finalConnecting = await manager.isConnectingPlayback
            let finalActor = await manager.currentVisualState
            if Self.shouldEnterPlayingEnsureQuietPending(
                playingStillStalled: finalVisualLags,
                isRequestEligible: eligibleAfter,
                ownedContentVisual: currentActivity?.content.state.visualState,
                isAuthoritativePlayingWithoutHold: finalActor == .playing && !finalHold && !finalConnecting
            ) {
                playingEnsureQuietPending = true
                playingEnsureQuietSkipLogged = false
            }
            if finalLangLags || playingEnsureQuietPending {
                markContentEnsureFreezeSoftBudgetExhausted()
            }
        }
    }

    /// Post-hold dual-axis soft-ensure re-arm when owned visual is still Connecting (``.prePlay``)
    /// while the actor is authoritative `.playing` (stream-attach prePlay stick).
    ///
    /// Co-pushes destination language and playing visual via ``ensureAuthoritativeDualAxisContentIfNeeded()``
    /// so language-only then playing-only short budgets cannot re-quiet without a dual payload.
    /// Consume-once while ineligible; arms dual-axis long-horizon when still lagging.
    ///
    /// - SeeAlso: ``shouldPushSettledDualAxisAcceptance(actorVisual:ownedContentVisual:destinationLanguage:isStreamSwitchHoldActive:isConnectingPlayback:settledAcceptanceConsumed:isRequestEligible:)``,
    ///   ``ensureAuthoritativeDualAxisContentIfNeeded()``,
    ///   ``pushSettledPlayingAcceptanceContentIfNeeded()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    @MainActor
    func pushSettledDualAxisAcceptanceContentIfNeeded() async {
        if SharedPlayerManager.isRunningInUITestMode { return }
        #if DEBUG
        if isRunningUnderTest { return }
        #endif
        guard currentActivity != nil else { return }

        let manager = SharedPlayerManager.shared
        let actorVisual = await manager.currentVisualState
        let hold = await manager.isStreamSwitchPrePlayHoldActive
        let connecting = await manager.isConnectingPlayback
        let ownedVisual = currentActivity?.content.state.visualState
        let destination = await manager.liveActivityLanguageCodeForContentPush()
        let requestEligible = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )

        if Self.shouldClearDualAxisSettledAcceptanceConsume(
            settledAcceptanceConsumed: dualAxisSettledAcceptanceConsumed,
            ownedOrSystemVisual: ownedVisual
        ) {
            dualAxisSettledAcceptanceConsumed = false
        }

        guard Self.shouldPushSettledDualAxisAcceptance(
            actorVisual: actorVisual,
            ownedContentVisual: ownedVisual,
            destinationLanguage: destination,
            isStreamSwitchHoldActive: hold,
            isConnectingPlayback: connecting,
            settledAcceptanceConsumed: dualAxisSettledAcceptanceConsumed,
            isRequestEligible: requestEligible
        ) else {
            return
        }

        // Dual settle owns this prePlay cycle — cancel single-axis post-settled peers that
        // would thrash after sequential settle, then run one dual-axis soft budget. Fresh
        // freeze soft budget for this attach settle so thrash smart-loosen does not starve it.
        cancelPostSettledLanguageEnsureRetries()
        cancelPostSettledPlayingEnsureRetries()
        cancelAllPostQuietLongHorizonEnsure()
        languageEnsureQuietPendingDestination = nil
        languageEnsureQuietSkipLogged = false
        playingEnsureQuietPending = false
        playingEnsureQuietSkipLogged = false
        resetContentEnsureFreezeGeneration()
        if !requestEligible {
            dualAxisSettledAcceptanceConsumed = true
            // Peer consume markers so single-axis settle does not re-enter for the same freeze.
            playingSettledAcceptanceConsumed = true
            if !destination.isEmpty {
                languageSettledAcceptanceConsumedDestination = destination
            }
        }

        #if DEBUG
        print(
            "🔴 Live Activity settled dual-axis acceptance soft-ensure re-arm " +
            "(actor=\(actorVisual) owned=\(String(describing: ownedVisual)) dest=\(destination); " +
            "prePlay stick — co-push language + playing)"
        )
        #endif

        await ensureAuthoritativeDualAxisContentIfNeeded()

        let acceptedVisual = currentActivity?.content.state.visualState
        let acceptedLang = currentActivity?.content.state.currentLanguage
        let stillVisualLags = acceptedVisual == .prePlay || acceptedVisual == .userPaused
            || (acceptedVisual != nil && acceptedVisual != .playing)
        let stillLanguageLags = Self.shouldEnsureAuthoritativeLanguageContent(
            destinationLanguage: destination,
            ownedContentLanguage: acceptedLang,
            lastPushedLanguage: lastPushedContent?.currentLanguage
        )

        if acceptedVisual == .playing && !stillLanguageLags {
            dualAxisSettledAcceptanceConsumed = false
            playingSettledAcceptanceConsumed = false
            languageSettledAcceptanceConsumedDestination = nil
            postQuietLongHorizonDualAxisExhausted = false
            return
        }

        let eligibleAfter = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        if !eligibleAfter {
            pendingInteractiveLiveActivityEnsure = true
            #if DEBUG
            print(
                "🔴 Live Activity settled dual-axis acceptance still lagging " +
                "(ownedVisual=\(String(describing: acceptedVisual)) ownedLang=\(acceptedLang ?? "nil"); " +
                "dual-axis long-horizon armed; recreation remains eligibility-gated)"
            )
            #endif
        }
        // Dual-axis LH before freeze; after freeze the dual arm no-ops and
        // single-axis rails still need to arm (language-only + playing visual).
        if stillLanguageLags && stillVisualLags {
            await armPostQuietLongHorizonDualAxisEnsureIfNeeded()
        }
        if stillLanguageLags {
            await armPostQuietLongHorizonLanguageEnsureIfNeeded()
        }
        if stillVisualLags {
            await armPostQuietLongHorizonPlayingEnsureIfNeeded()
        }
    }

    /// Whether playing reconcile should force a content push.
    ///
    /// - Parameters:
    ///   - actorVisual: Actor ``currentVisualState``.
    ///   - streamSwitchHold: ``isStreamSwitchPrePlayHoldActive``.
    ///   - isConnectingPlayback: ``isConnectingPlayback``.
    ///   - lastPushedVisual: ``lastPushedContent`` visual, if any.
    ///   - ownedVisual: Owned `content.state.visualState`, if any.
    /// - Returns: `true` when the actor is authoritative playing without hold/connect and
    ///   last-pushed or owned visual is still Connecting or paused.
    /// - Note: Does not invent play during hold/connect — those remain Connecting honesty.
    /// - SeeAlso: ``ensureAuthoritativePlayingContentIfNeeded()``.
    static func shouldEnsureAuthoritativePlayingContent(
        actorVisual: PlayerVisualState,
        streamSwitchHold: Bool,
        isConnectingPlayback: Bool,
        lastPushedVisual: PlayerVisualState?,
        ownedVisual: PlayerVisualState?
    ) -> Bool {
        guard actorVisual == .playing else { return false }
        guard !streamSwitchHold, !isConnectingPlayback else { return false }
        if lastPushedVisual == .prePlay || lastPushedVisual == .userPaused {
            return true
        }
        if ownedVisual == .prePlay || ownedVisual == .userPaused {
            return true
        }
        // Owned still not playing while suppress memory already claims playing (extension /
        // optimistic path advanced lastPushed without system acceptance).
        if let ownedVisual, ownedVisual != .playing {
            return true
        }
        return false
    }

    /// Ensures interactive Live Activity `ContentState.currentLanguage` matches
    /// ``SharedPlayerManager/liveActivityLanguageCodeForContentPush()`` when they diverge.
    ///
    /// Peer to ``ensureAuthoritativePlayingContentIfNeeded()`` for **language chrome**
    /// (flag / name / alt-stream “current”). Does **not** invent `.playing` — Connecting
    /// (``.prePlay``) remains honest during stream-switch hold; only the language field is
    /// forced to the destination stamp / stream attach.
    ///
    /// - Parameters:
    ///   - preservingOwnedVisual: When `true`, ``updateCurrentActivity(preservingOwnedVisual:)``
    ///     keeps the owned glyph (``ContentState/replacingCurrentLanguage(_:)``). Post-quiet
    ///     language long-horizon after freeze passes this so dest language does not spend
    ///     the sparse slot on `.playing`. Stream-switch hold still Connecting.
    ///
    /// Performs up to ``authoritativeLanguageContentEnsureMaxAttempts`` soft pushes, re-reading
    /// owned `content.state.currentLanguage` after each ``updateCurrentActivity()``. Stops early
    /// when owned language matches destination, the ensure gate clears, or the interactive
    /// activity disappears. Does **not** end+recreate — language freezes recover via soft
    /// retries first; eligible-only recreation is owned by
    /// ``ensureAuthoritativeContentOnForegroundIfNeeded()`` / the stalled-push path.
    ///
    /// **Quiet pending while request ineligible:** After the soft-retry budget is exhausted
    /// without owned language acceptance while ``isInteractiveLiveActivityRequestEligible``
    /// is false, records ``languageEnsureQuietPendingDestination`` and stops re-running soft
    /// pushes on every status callback for that destination. Re-arm when:
    /// - Destination language changes (new mutation — one high-priority ensure cycle)
    /// - Interactive request becomes eligible
    /// - Foreground / become-active (``ensureAuthoritativeContentOnForegroundIfNeeded`` clears quiet)
    /// - System `contentUpdates` yield
    ///
    /// **Concurrent collapse:** Re-entry while a soft-push loop is already in flight is a
    /// no-op so parallel language-ensure attempt counters do not thrash ActivityKit.
    ///
    /// Wire points (main app):
    /// - After media-surface Live Activity update/start (``refreshAllMediaSurfaces``)
    /// - After ``setPlaying()``’s playing reconcile
    /// - After optimistic stream-switch ContentState when this process owns the activity
    /// - Foreground / become-active owned-surface path via
    ///   ``ensureAuthoritativeContentOnForegroundIfNeeded()``
    ///
    /// Relies on ``shouldSuppressLiveActivityContentPush`` so optimistic ``lastPushedContent``
    /// that already claims destination language cannot block a push when owned
    /// `content.state.currentLanguage` is still the prior stream.
    ///
    /// - Precondition: Main actor; interactive ``currentActivity`` may be nil (no-op).
    /// - Postcondition: When a push was needed and not quiet-deferred, ``updateCurrentActivity()``
    ///   ran up to the soft-retry budget (subject to test isolation and ActivityKit acceptance).
    ///   Cheap no-op when owned + last language already match destination, or when quiet for
    ///   the same destination while request remains ineligible, or when a soft-push loop is
    ///   already in flight for this axis.
    /// - SeeAlso: ``updateCurrentActivity(preservingOwnedVisual:)``, ``shouldEnsureAuthoritativeLanguageContent(destinationLanguage:ownedContentLanguage:lastPushedLanguage:)``,
    ///   ``shouldKeepOwnedVisualOnPostQuietLanguageLongHorizon(freezeSoftBudgetExhausted:playingQuietPending:isRequestEligible:)``,
    ///   ``shouldRunLanguageContentEnsureSoftPushes(needsLanguageEnsure:destinationLanguage:quietPendingDestination:isRequestEligible:)``,
    ///   ``shouldStartAuthoritativeContentEnsureSoftPushLoop(softPushesAlreadyInFlight:)``,
    ///   ``authoritativeLanguageContentEnsureMaxAttempts``,
    ///   ``ensureAuthoritativeContentOnForegroundIfNeeded()``,
    ///   ``recordOptimisticStreamSwitchContent(language:visualState:)``,
    ///   ``SharedPlayerManager/liveActivityLanguageCodeForContentPush()``,
    ///   ``ContentState/replacingCurrentLanguage(_:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   docs/Widget-Functionality-Roadmap.md (Live Activity language chrome SSOT).
    @MainActor
    func ensureAuthoritativeLanguageContentIfNeeded(preservingOwnedVisual: Bool = false) async {
        if SharedPlayerManager.isRunningInUITestMode { return }
        #if DEBUG
        if isRunningUnderTest { return }
        #endif
        guard currentActivity != nil else { return }

        let destination = await SharedPlayerManager.shared.liveActivityLanguageCodeForContentPush()
        let ownedLanguage = currentActivity?.content.state.currentLanguage
        let lastLanguage = lastPushedContent?.currentLanguage
        let needsEnsure = Self.shouldEnsureAuthoritativeLanguageContent(
            destinationLanguage: destination,
            ownedContentLanguage: ownedLanguage,
            lastPushedLanguage: lastLanguage
        )
        // Destination moved on or owned converged → drop quiet + long-horizon for the prior destination.
        if Self.shouldClearLanguageEnsureQuietPending(
            quietPendingDestination: languageEnsureQuietPendingDestination,
            destinationLanguage: destination,
            ownedOrSystemLanguage: ownedLanguage
        ) {
            languageEnsureQuietPendingDestination = nil
            languageEnsureQuietSkipLogged = false
            cancelPostQuietLongHorizonLanguageEnsure()
        }
        guard needsEnsure else {
            languageEnsureQuietPendingDestination = nil
            languageEnsureQuietSkipLogged = false
            cancelPostQuietLongHorizonLanguageEnsure()
            return
        }

        let requestEligible = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        guard Self.shouldRunLanguageContentEnsureSoftPushes(
            needsLanguageEnsure: true,
            destinationLanguage: destination,
            quietPendingDestination: languageEnsureQuietPendingDestination,
            isRequestEligible: requestEligible
        ) else {
            #if DEBUG
            if Self.shouldLogEnsureQuietSkipOnce(
                softPushesSuppressedByQuiet: true,
                alreadyLoggedQuietSkip: languageEnsureQuietSkipLogged
            ) {
                languageEnsureQuietSkipLogged = true
                print(
                    "🔴 Live Activity language ensure quiet (destination=\(destination) " +
                    "owned=\(ownedLanguage ?? "nil"); wait for eligibility, become-active, or language mutation)"
                )
            }
            #endif
            await armPostQuietLongHorizonLanguageEnsureIfNeeded()
            return
        }

        // Collapse concurrent re-entry: only one soft-push loop per axis.
        guard Self.shouldStartAuthoritativeContentEnsureSoftPushLoop(
            softPushesAlreadyInFlight: languageEnsureSoftPushesInFlight
        ) else {
            return
        }
        languageEnsureSoftPushesInFlight = true
        defer { languageEnsureSoftPushesInFlight = false }
        languageEnsureQuietSkipLogged = false

        // Destination change re-arms: clear any prior quiet so this cycle can enter quiet
        // for the *new* destination if it also exhausts while ineligible.
        if let quiet = languageEnsureQuietPendingDestination, quiet != destination {
            languageEnsureQuietPendingDestination = nil
        }

        for attempt in 1...Self.authoritativeLanguageContentEnsureMaxAttempts {
            guard currentActivity != nil else { return }

            let loopDestination = await SharedPlayerManager.shared.liveActivityLanguageCodeForContentPush()
            let loopOwned = currentActivity?.content.state.currentLanguage
            let loopLast = lastPushedContent?.currentLanguage

            guard Self.shouldEnsureAuthoritativeLanguageContent(
                destinationLanguage: loopDestination,
                ownedContentLanguage: loopOwned,
                lastPushedLanguage: loopLast
            ) else {
                languageEnsureQuietPendingDestination = nil
                languageEnsureQuietSkipLogged = false
                return
            }

            #if DEBUG
            print(
                "🔴 Live Activity reconciling language chrome → destination=\(loopDestination) " +
                "owned=\(loopOwned ?? "nil") lastPushed=\(loopLast ?? "nil") " +
                "attempt=\(attempt)/\(Self.authoritativeLanguageContentEnsureMaxAttempts)"
            )
            #endif
            await updateCurrentActivity(preservingOwnedVisual: preservingOwnedVisual)

            // Post-update verification: owned language is the surface honesty SSOT.
            let acceptedLanguage = currentActivity?.content.state.currentLanguage
            if acceptedLanguage == loopDestination {
                languageEnsureQuietPendingDestination = nil
                languageEnsureQuietSkipLogged = false
                cancelPostQuietLongHorizonLanguageEnsure()
                return
            }
            // Eligibility-aware inter-attempt spacing (longer under continuous lock).
            let loopEligible = Self.isInteractiveLiveActivityRequestEligible(
                areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
                isApplicationActive: UIApplication.shared.applicationState == .active
            )
            if let delayMs = Self.softEnsureInterAttemptDelayMilliseconds(
                attempt: attempt,
                maxAttempts: Self.authoritativeLanguageContentEnsureMaxAttempts,
                isRequestEligible: loopEligible
            ) {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(delayMs))
            }
        }

        // Soft budget exhausted without acceptance.
        let eligibleAfter = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        // Immediate post-await mismatch is not quiet truth — wait one apply window.
        let settleMs = Self.contentPushApplyConfirmationDelayMilliseconds(
            isRequestEligible: eligibleAfter
        )
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(settleMs))
        let finalDestination = await SharedPlayerManager.shared.liveActivityLanguageCodeForContentPush()
        let finalOwned = currentActivity?.content.state.currentLanguage
        let stillMismatches = Self.shouldEnsureAuthoritativeLanguageContent(
            destinationLanguage: finalDestination,
            ownedContentLanguage: finalOwned,
            lastPushedLanguage: lastPushedContent?.currentLanguage
        )
        if let quietDestination = Self.quietPendingDestinationAfterLanguageEnsureExhaustion(
            languageStillMismatches: stillMismatches,
            isRequestEligible: eligibleAfter,
            destinationLanguage: finalDestination
        ) {
            languageEnsureQuietPendingDestination = quietDestination
            languageEnsureQuietSkipLogged = false
            // Keep pending ensure so become-active owned-surface path re-arms recovery.
            markContentEnsureFreezeSoftBudgetExhausted()
            #if DEBUG
            print(
                "🔴 Live Activity language ensure quiet pending after max attempts " +
                "(destination=\(quietDestination); freeze soft budget exhausted; " +
                "recreation remains eligibility-gated)"
            )
            #endif
            // Quiet is thrash protection, not a permanent freeze under continuous lock.
            await armPostQuietLongHorizonLanguageEnsureIfNeeded()
        }
    }

    /// Whether an owned interactive Live Activity needs soft language and/or playing ensure
    /// on foreground / become-active (ownership non-nil; missing-card start is separate).
    ///
    /// - Parameters:
    ///   - hasCurrentActivity: Whether this process owns an interactive activity.
    ///   - destinationLanguage: ``SharedPlayerManager/liveActivityLanguageCodeForContentPush()``.
    ///   - ownedContentLanguage: Owned `content.state.currentLanguage`, if any.
    ///   - lastPushedLanguage: ``lastPushedContent`` language, if any.
    ///   - actorVisual: Actor ``currentVisualState``.
    ///   - streamSwitchHold: ``isStreamSwitchPrePlayHoldActive``.
    ///   - isConnectingPlayback: ``isConnectingPlayback``.
    ///   - lastPushedVisual: ``lastPushedContent`` visual, if any.
    ///   - ownedVisual: Owned `content.state.visualState`, if any.
    /// - Returns: `true` when ownership is non-nil and language and/or playing ensure gates fire.
    /// - Note: Does not invent `.playing` or decide end+request — soft ensure only.
    /// - SeeAlso: ``ensureAuthoritativeContentOnForegroundIfNeeded()``,
    ///   ``shouldInvokeOwnedSurfaceForegroundEnsure(hasCurrentActivity:lastOwnedSurfaceForegroundEnsureAt:now:debounceInterval:languageEnsureQuietPending:playingEnsureQuietPending:pendingInteractiveLiveActivityEnsure:contentEnsureStillNeeded:isRequestEligible:)``,
    ///   ``shouldEnsureAuthoritativeLanguageContent(destinationLanguage:ownedContentLanguage:lastPushedLanguage:)``,
    ///   ``shouldEnsureAuthoritativePlayingContent(actorVisual:streamSwitchHold:isConnectingPlayback:lastPushedVisual:ownedVisual:)``.
    static func shouldEnsureAuthoritativeContentOnForeground(
        hasCurrentActivity: Bool,
        destinationLanguage: String,
        ownedContentLanguage: String?,
        lastPushedLanguage: String?,
        actorVisual: PlayerVisualState,
        streamSwitchHold: Bool,
        isConnectingPlayback: Bool,
        lastPushedVisual: PlayerVisualState?,
        ownedVisual: PlayerVisualState?
    ) -> Bool {
        guard hasCurrentActivity else { return false }
        if shouldEnsureAuthoritativeLanguageContent(
            destinationLanguage: destinationLanguage,
            ownedContentLanguage: ownedContentLanguage,
            lastPushedLanguage: lastPushedLanguage
        ) {
            return true
        }
        if shouldEnsureAuthoritativePlayingContent(
            actorVisual: actorVisual,
            streamSwitchHold: streamSwitchHold,
            isConnectingPlayback: isConnectingPlayback,
            lastPushedVisual: lastPushedVisual,
            ownedVisual: ownedVisual
        ) {
            return true
        }
        return false
    }

    /// Whether the owned-surface foreground soft-ensure cycle should run now.
    ///
    /// ``SceneDelegate`` calls ``ensureInteractiveLiveActivityIfNeeded()`` from both
    /// ``sceneWillEnterForeground`` (via ``handleAppDidEnterForeground()``) and
    /// ``sceneDidBecomeActive``. Missing-card start already has its own debounce; this gate
    /// is the **owned-surface** peer so unlock recovery stays intentional without dual-hook
    /// soft-budget thrash.
    ///
    /// **Always invoke (consume pending) when:**
    /// - Language ensure quiet is set (lock-stretch thrash after max attempts while ineligible)
    /// - Playing ensure quiet is set
    /// - ``pendingInteractiveLiveActivityEnsure`` is set (deferred recreation / soft-exhaust)
    ///
    /// **Debounce skip when** none of the above and a cycle ran within ``debounceInterval``,
    /// **unless** content still needs soft ensure **and** request is now eligible — so a first
    /// pass that ran while application was not yet `.active` does not permanently skip the
    /// presentable become-active pass.
    ///
    /// - Parameters:
    ///   - hasCurrentActivity: Whether this process owns an interactive activity.
    ///   - lastOwnedSurfaceForegroundEnsureAt: Stamp of the last owned-surface soft cycle.
    ///   - now: Current time (injectable for tests).
    ///   - debounceInterval: Production ``ownedSurfaceForegroundEnsureDebounceInterval``.
    ///   - languageEnsureQuietPending: Whether ``languageEnsureQuietPendingDestination`` is set.
    ///   - playingEnsureQuietPending: ``playingEnsureQuietPending``.
    ///   - pendingInteractiveLiveActivityEnsure: Deferred ensure / soft-exhaust pending flag.
    ///   - contentEnsureStillNeeded: ``shouldEnsureAuthoritativeContentOnForeground`` result.
    ///   - isRequestEligible: ``isInteractiveLiveActivityRequestEligible``.
    /// - Returns: `true` when ``ensureAuthoritativeContentOnForegroundIfNeeded()`` should run.
    /// - Important: Does not decide end+request; never invents `.playing`. Unowned → `false`
    ///   (missing-card start path is separate).
    /// - SeeAlso: ``ensureInteractiveLiveActivityIfNeeded()``,
    ///   ``ensureAuthoritativeContentOnForegroundIfNeeded()``,
    ///   ``ownedSurfaceForegroundEnsureDebounceInterval``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldInvokeOwnedSurfaceForegroundEnsure(
        hasCurrentActivity: Bool,
        lastOwnedSurfaceForegroundEnsureAt: Date?,
        now: Date,
        debounceInterval: TimeInterval = RadioLiveActivityManager.ownedSurfaceForegroundEnsureDebounceInterval,
        languageEnsureQuietPending: Bool,
        playingEnsureQuietPending: Bool,
        pendingInteractiveLiveActivityEnsure: Bool,
        contentEnsureStillNeeded: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        guard hasCurrentActivity else { return false }

        // Consume lock-stretch quiet / deferred pending on a presentable cycle.
        // Quiet is for thrash while request was ineligible — not a freeze across unlock.
        if languageEnsureQuietPending
            || playingEnsureQuietPending
            || pendingInteractiveLiveActivityEnsure
        {
            return true
        }

        if let last = lastOwnedSurfaceForegroundEnsureAt,
           now.timeIntervalSince(last) < debounceInterval {
            // willEnterForeground may run before application is `.active`. become-active must
            // still soft-ensure when chrome lags and request is now eligible.
            if contentEnsureStillNeeded && isRequestEligible {
                return true
            }
            return false
        }

        // First owned-surface pass this debounce window (or never). Soft ensure is a cheap
        // no-op when language + visual already match destination / actor.
        return true
    }

    /// Whether eligible-only end+request may run after foreground soft ensure still leaves
    /// owned chrome lagging the destination language and/or authoritative playing visual.
    ///
    /// **Invariant:** Never true when request is ineligible — keep the only interactive
    /// surface while `Activity.request` cannot succeed (lock / background visibility).
    ///
    /// - Parameters:
    ///   - languageStillMismatches: Soft language ensure gate still true after retries.
    ///   - playingStillStalled: Soft playing ensure gate still true after retries.
    ///   - isRequestEligible: ``isInteractiveLiveActivityRequestEligible(areActivitiesEnabled:isApplicationActive:)``.
    ///   - recreationsAttempted: ``interactiveContentRecreationsAttempted`` this healthy cycle.
    ///   - maxRecreations: Production ``maxInteractiveContentRecreations``.
    /// - Returns: `true` only when soft path still fails **and** request is eligible **and**
    ///   recreation budget remains.
    /// - SeeAlso: ``ensureAuthoritativeContentOnForegroundIfNeeded()``,
    ///   ``recreateInteractiveLiveActivityAfterStalledContent()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func shouldRecreateAfterForegroundSoftEnsureFailed(
        languageStillMismatches: Bool,
        playingStillStalled: Bool,
        isRequestEligible: Bool,
        recreationsAttempted: Int,
        maxRecreations: Int = RadioLiveActivityManager.maxInteractiveContentRecreations
    ) -> Bool {
        guard isRequestEligible else { return false }
        guard languageStillMismatches || playingStillStalled else { return false }
        guard recreationsAttempted < maxRecreations else { return false }
        return true
    }

    /// Soft language + playing ensure for an **owned** interactive Live Activity on
    /// foreground / become-active, then eligible-only recreation if soft ensure still fails.
    ///
    /// **Why:** Deferred recreation keeps the interactive card while request is ineligible;
    /// system-held `content.state` may still trail destination language/visual after unlock.
    /// Real-device unlock heal (system `contentUpdates` after become-active without an in-app
    /// stream switch) is the intentional recovery rail: clear lock-stretch quiet, soft-push
    /// both axes, then optionally recreate only when request-eligible.
    /// ``ensureInteractiveLiveActivityIfNeeded()`` restores a **missing** card only
    /// (`currentActivity == nil`); this is the owned-surface peer so become-active does not
    /// leave a present card on prior-stream chrome. Callers gate dual SceneDelegate hooks via
    /// ``shouldInvokeOwnedSurfaceForegroundEnsure`` so quiet/pending are still **consumed**
    /// while redundant soft cycles are debounced.
    ///
    /// **Order:**
    /// 1. Clear ``languageEnsureQuietPendingDestination`` + ``playingEnsureQuietPending``
    ///    (lock-stretch thrash protection must not freeze chrome across presentable cycles)
    /// 2. Bounded ``ensureAuthoritativeLanguageContentIfNeeded()``
    /// 3. Bounded ``ensureAuthoritativePlayingContentIfNeeded()``
    /// 4. If owned language/visual still lag **and** request is eligible → single
    ///    ``recreateInteractiveLiveActivityAfterStalledContent()`` (re-checks eligibility;
    ///    never ends while ineligible)
    ///
    /// - Precondition: Main actor; no-op under UITestMode / under-test; no-op when unowned.
    ///   Caller should have already decided invoke via
    ///   ``shouldInvokeOwnedSurfaceForegroundEnsure`` (or equivalent ownership check).
    /// - Postcondition: Quiet flags cleared; soft pushes attempted when needed; recreation
    ///   only when eligible and soft path still failed with budget remaining.
    /// - Important: Does not invent `.playing` during stream-switch hold; does not bypass
    ///   privacy write suppression or home-widget write gating. Does not end the only
    ///   activity while request is ineligible.
    /// - SeeAlso: ``ensureInteractiveLiveActivityIfNeeded()``, ``handleAppDidEnterForeground()``,
    ///   ``shouldInvokeOwnedSurfaceForegroundEnsure(hasCurrentActivity:lastOwnedSurfaceForegroundEnsureAt:now:debounceInterval:languageEnsureQuietPending:playingEnsureQuietPending:pendingInteractiveLiveActivityEnsure:contentEnsureStillNeeded:isRequestEligible:)``,
    ///   ``shouldEnsureAuthoritativeContentOnForeground(hasCurrentActivity:destinationLanguage:ownedContentLanguage:lastPushedLanguage:actorVisual:streamSwitchHold:isConnectingPlayback:lastPushedVisual:ownedVisual:)``,
    ///   ``shouldRecreateAfterForegroundSoftEnsureFailed(languageStillMismatches:playingStillStalled:isRequestEligible:recreationsAttempted:maxRecreations:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   docs/Widget-Functionality-Roadmap.md.
    @MainActor
    func ensureAuthoritativeContentOnForegroundIfNeeded() async {
        if SharedPlayerManager.isRunningInUITestMode { return }
        #if DEBUG
        if isRunningUnderTest { return }
        #endif
        guard currentActivity != nil else { return }

        // Re-arm language + playing ensure quiet so unlock / become-active always gets a soft cycle.
        // Quiet is for lock-stretch thrash only — not a permanent freeze across presentable cycles.
        // AGENT NOTE: Both axes clear together — language-only unlock must not leave playing
        // quiet blocking visual recovery (and the reverse). Also clear settled language/playing
        // consume so presentable cycles can re-attempt high-signal acceptance if soft ensure
        // still lags after unlock. Cancel delayed post-settled + post-quiet long-horizon rails —
        // foreground soft ensure owns this presentable cycle. Capture dual-axis LH exhaust +
        // freeze soft-budget exhaust so eligible recreation preference remains after soft ensure
        // still fails.
        let dualAxisExhaustedBeforePresentable = postQuietLongHorizonDualAxisExhausted
        let freezeSoftBudgetExhaustedBeforePresentable = contentEnsureFreezeSoftBudgetExhausted
        cancelPostSettledLanguageEnsureRetries()
        cancelPostSettledPlayingEnsureRetries()
        cancelAllPostQuietLongHorizonEnsure()
        languageEnsureQuietPendingDestination = nil
        languageSettledAcceptanceConsumedDestination = nil
        playingEnsureQuietPending = false
        playingSettledAcceptanceConsumed = false
        dualAxisSettledAcceptanceConsumed = false
        languageEnsureQuietSkipLogged = false
        playingEnsureQuietSkipLogged = false
        postQuietLongHorizonDualAxisExhausted = false
        resetContentEnsureFreezeGeneration()
        // New presentable cycle may re-announce deferred recreation if soft ensure still fails.
        clearContentPushDiagnosticsSignatures()

        // Soft path first — dual-axis when both lag, else language then visual.
        // Never end the only card while ActivityKit may still accept updates.
        await ensureAuthoritativeDualAxisContentIfNeeded()
        await ensureAuthoritativeLanguageContentIfNeeded()
        await ensureAuthoritativePlayingContentIfNeeded()

        guard currentActivity != nil else { return }

        let manager = SharedPlayerManager.shared
        let destination = await manager.liveActivityLanguageCodeForContentPush()
        let ownedLanguage = currentActivity?.content.state.currentLanguage
        let lastLanguage = lastPushedContent?.currentLanguage
        let languageStillMismatches = Self.shouldEnsureAuthoritativeLanguageContent(
            destinationLanguage: destination,
            ownedContentLanguage: ownedLanguage,
            lastPushedLanguage: lastLanguage
        )

        let visual = await manager.currentVisualState
        let hold = await manager.isStreamSwitchPrePlayHoldActive
        let connecting = await manager.isConnectingPlayback
        let lastVisual = lastPushedContent?.visualState
        let ownedVisual = currentActivity?.content.state.visualState
        let playingStillStalled = Self.shouldEnsureAuthoritativePlayingContent(
            actorVisual: visual,
            streamSwitchHold: hold,
            isConnectingPlayback: connecting,
            lastPushedVisual: lastVisual,
            ownedVisual: ownedVisual
        )

        let requestEligible = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )

        let shouldRecreate =
            Self.shouldPreferEligibleRecreateAfterContentEnsureFreezeExhausted(
                freezeSoftBudgetExhausted: freezeSoftBudgetExhaustedBeforePresentable,
                dualAxisExhausted: dualAxisExhaustedBeforePresentable,
                languageStillLags: languageStillMismatches,
                visualStillLags: playingStillStalled,
                isRequestEligible: requestEligible,
                recreationsAttempted: interactiveContentRecreationsAttempted
            )
            || Self.shouldRecreateAfterForegroundSoftEnsureFailed(
                languageStillMismatches: languageStillMismatches,
                playingStillStalled: playingStillStalled,
                isRequestEligible: requestEligible,
                recreationsAttempted: interactiveContentRecreationsAttempted
            )
        guard shouldRecreate else {
            return
        }

        #if DEBUG
        print(
            "🔴 Live Activity foreground soft ensure still lagged " +
            "(language=\(languageStillMismatches) playing=\(playingStillStalled)" +
            (dualAxisExhaustedBeforePresentable ? "; dual-axis long-horizon was exhausted" : "") +
            (freezeSoftBudgetExhaustedBeforePresentable ? "; freeze soft budget was exhausted" : "") +
            "); eligible recreation"
        )
        #endif
        // recreateInteractiveLiveActivityAfterStalledContent re-checks eligibility and never
        // ends the only surface while request is ineligible.
        await recreateInteractiveLiveActivityAfterStalledContent()
    }

    /// Aligns in-memory ``lastPushedContent`` with an intent-path optimistic Live Activity visual.
    ///
    /// Called from ``WidgetIntentExecution`` after ActivityKit content is published (or when
    /// no activity is visible in this process), including main-app ``SharedPlayerManager/stop()``
    /// sticky-lock pause honesty. Matching the optimistic visual here means the subsequent
    /// engine-complete ``updateCurrentActivity()`` typically sees an equal candidate and
    /// suppresses redundant IPC once the actor sticky-locks or setPlaying — **provided** owned
    /// system-held visual also matches (owned-visual suppress gate). Pause from stale Connecting
    /// does **not** require prior owned ``.playing``; language and program metadata are preserved.
    ///
    /// - Parameter visualState: Optimistic control visual (`.userPaused` or `.playing`).
    /// - Postcondition: ``lastPushedContent`` reflects `visualState` with preserved metadata
    ///   and language when any source is available; durable toggle mirrors stay the caller's
    ///   job (already written before this alignment); ``playingEnsureQuietPending`` cleared.
    /// - Note: Does not call `Activity.update` — the intent path owns that IPC via
    ///   `Activity.activities` so extension-hosted and main-hosted toggles share one push site.
    /// - SeeAlso: ``updateCurrentActivity()``, ``recordOptimisticStreamSwitchContent(language:visualState:)``,
    ///   ``WidgetIntentExecution/performLiveActivityToggle()``,
    ///   ``WidgetIntentExecution/executeOptimisticToggle(plan:language:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    @MainActor
    func recordOptimisticToggleContent(visualState: PlayerVisualState) {
        // Control mutation re-arms playing ensure quiet and re-opens settled playing acceptance
        // so pause honesty and later soft-resume get a full post-hold settle window even after
        // prior lock-stretch playing thrash. Cancel delayed post-settled playing retries for the
        // prior play cycle — a new pause/play mutation owns recovery. Fresh freeze generation
        // soft budget so continuous-lock thrash smart-loosen does not starve a real mutation.
        playingEnsureQuietPending = false
        playingEnsureQuietSkipLogged = false
        playingSettledAcceptanceConsumed = false
        dualAxisSettledAcceptanceConsumed = false
        postQuietLongHorizonDualAxisExhausted = false
        resetContentEnsureFreezeGeneration()
        cancelPostSettledPlayingEnsureRetries()
        // New pause/play mutation owns recovery — drop prior freeze long-horizon.
        cancelPostQuietLongHorizonPlayingEnsure()
        cancelPostQuietLongHorizonDualAxisEnsure()
        clearContentPushDiagnosticsSignatures()
        let metadata =
            lastPushedContent?.streamMetadata
            ?? currentActivity?.content.state.streamMetadata
            ?? SharedPlayerManager.loadPersistedStreamMetadata()
        // Prefer stream-attach / durable mirror over lagging lastPushed language so pause after
        // a stream switch cannot freeze prior-language suppress memory while the engine already
        // plays the destination (device residual: lastPushed stayed prior across switch).
        let resolved = Self.languageForOptimisticToggleContentAlignment(
            lastPushedLanguage: lastPushedContent?.currentLanguage,
            ownedContentLanguage: currentActivity?.content.state.currentLanguage,
            selectedStreamLanguage: DirectStreamingPlayer.shared.selectedStream.languageCode,
            durableLanguageMirror: SharedPlayerManager.loadLiveActivityLanguageMirror()
        )
        let language = resolved.isEmpty
            ? SharedPlayerManager.mainAppLiveActivityLanguageCode()
            : resolved
        lastPushedContent = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: visualState,
            streamMetadata: metadata,
            currentLanguage: language
        )
        #if DEBUG
        print("🔴 Live Activity lastPushedContent aligned to optimistic visual=\(visualState) language=\(language)")
        #endif
    }

    /// Aligns in-memory ``lastPushedContent`` with an intent-path optimistic stream-language switch.
    ///
    /// Called from ``WidgetIntentExecution/pushOptimisticLiveActivityStreamSwitchContent(languageCode:visualState:)``
    /// after ActivityKit content is published (or when no activity is visible). Destination
    /// language + Connecting / preserved-pause visual match the optimistic ContentState so
    /// main-app ``updateCurrentActivity()`` can suppress when the actor stamp **and** the
    /// owned surface language converge to the same tuple.
    ///
    /// **Owned language still wins for suppress:** Aligning ``lastPushedContent`` to the
    /// destination does **not** block a needed push when
    /// `currentActivity?.content.state.currentLanguage` still differs — see
    /// ``shouldSuppressLiveActivityContentPush(lastPushed:candidate:ownedContentLanguage:)``.
    /// Callers should also invoke ``ensureAuthoritativeLanguageContentIfNeeded()`` after the
    /// optimistic ActivityKit path when this process owns an interactive activity.
    ///
    /// **Language ensure re-arm:** A new destination clears ``languageEnsureQuietPendingDestination``
    /// when it differs so the next ensure cycle gets one high-priority soft budget for the
    /// new language (home-widget and Live Activity stream chips share this path). Also clears
    /// ``languageSettledAcceptanceConsumedDestination`` when the destination advances so the
    /// next post-hold settle push is available for the new language.
    ///
    /// **Playing ensure re-arm:** Any stream-switch optimistic stamp clears
    /// ``playingEnsureQuietPending`` and ``playingSettledAcceptanceConsumed`` so post-attach
    /// audible start / soft-resume get a full soft budget and one settled playing acceptance
    /// window (Connecting honesty still gated by hold/connect).
    ///
    /// Program metadata is cleared (same as the ActivityKit push) so a prior-stream title
    /// cannot suppress a language-only destination push.
    ///
    /// - Parameters:
    ///   - language: Destination stream language code for language chrome.
    ///   - visualState: Optimistic control visual (typically `.prePlay` or `.userPaused`).
    /// - Postcondition: ``lastPushedContent`` holds `visualState`, `nil` stream metadata, and
    ///   `language` (in-process only — not proof of system acceptance). Quiet language ensure
    ///   is cleared when the destination differs from the prior quiet destination; playing
    ///   ensure quiet and settled playing consume are always cleared for the new switch cycle;
    ///   settled language consume clears when destination advances.
    /// - Note: Does not call `Activity.update` — the intent path owns ActivityKit IPC.
    /// - SeeAlso: ``recordOptimisticToggleContent(visualState:)``, ``updateCurrentActivity()``,
    ///   ``ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``pushSettledLanguageAcceptanceContentIfNeeded()``,
    ///   ``pushSettledPlayingAcceptanceContentIfNeeded()``,
    ///   ``ensureAuthoritativePlayingContentIfNeeded()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   docs/Widget-Functionality-Roadmap.md (Live Activity language chrome SSOT).
    @MainActor
    func recordOptimisticStreamSwitchContent(language: String, visualState: PlayerVisualState) {
        guard !language.isEmpty else { return }
        // New language mutation re-arms soft language ensure for one high-priority cycle.
        if languageEnsureQuietPendingDestination != language {
            languageEnsureQuietPendingDestination = nil
            languageEnsureQuietSkipLogged = false
        }
        // New destination re-opens the post-hold settled language acceptance window and drops
        // delayed retries scheduled for a prior destination.
        if languageSettledAcceptanceConsumedDestination != language {
            languageSettledAcceptanceConsumedDestination = nil
            cancelPostSettledLanguageEnsureRetries()
            cancelPostQuietLongHorizonLanguageEnsure()
        }
        // New stream-switch cycle re-arms playing ensure + settled playing/dual-axis acceptance
        // and drops delayed playing retries + single/dual long-horizon for a prior play cycle.
        // Fresh freeze generation for the new destination (multi-destination language stick).
        playingEnsureQuietPending = false
        playingEnsureQuietSkipLogged = false
        playingSettledAcceptanceConsumed = false
        dualAxisSettledAcceptanceConsumed = false
        postQuietLongHorizonDualAxisExhausted = false
        resetContentEnsureFreezeGeneration()
        cancelPostSettledPlayingEnsureRetries()
        cancelPostQuietLongHorizonPlayingEnsure()
        cancelPostQuietLongHorizonDualAxisEnsure()
        // New mutation may re-log stall diagnostics and re-announce deferred recreation once.
        clearContentPushDiagnosticsSignatures()
        lastPushedContent = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: visualState,
            streamMetadata: nil,
            currentLanguage: language
        )
        #if DEBUG
        let owned = currentActivity?.content.state.currentLanguage
        if let owned, owned != language {
            print(
                "🔴 Live Activity lastPushedContent aligned to optimistic stream switch " +
                "visual=\(visualState) language=\(language) (owned content.state still \(owned); " +
                "suppress will not skip language reconcile)"
            )
        } else {
            print("🔴 Live Activity lastPushedContent aligned to optimistic stream switch visual=\(visualState) language=\(language)")
        }
        #endif
    }

    /// Ends every owned / system-held Live Activity and stops any fallback timer.
    ///
    /// ## Termination correctness (why this is not a fire-and-forget Task alone)
    /// Historically `endActivity` cleared local refs then launched an unstructured
    /// `Task { await activity.end(...) }`. On process exit (`applicationWillTerminate`,
    /// `sceneDidDisconnect`, `willTerminateNotification`) that Task frequently never
    /// ran before the process died, leaving Dynamic Island / Lock Screen with a stale
    /// interactive `ContentState` (often still `.playing`). The cleanup path therefore:
    /// 1. Sweeps **all** `Activity.activities` (not only `currentActivity`) so a nil local
    ///    reference cannot leave system-held surfaces orphaned.
    /// 2. Pushes a final coherent `.userPaused` ContentState that preserves last-known
    ///    language chrome (and program metadata when available).
    /// 3. On termination, **waits** for ActivityKit `update` + `end` via detached work
    ///    + run-loop pumping so the system accepts dismissal before process exit.
    ///
    /// While the main process remains alive (privacy clear, cold-launch hygiene), prefer
    /// ``endActivityAsync(dismissalPolicy:)`` so callers can `await` completion. The
    /// synchronous entry point remains for termination and call sites that cannot hop async.
    ///
    /// `dismissalPolicy`:
    /// - `.default` (privacy clear while process lives): system may keep the ended
    ///   activity visible briefly so the user sees the final paused frame.
    /// - `.immediate` (termination / cold-launch reap): removes the surface right away.
    ///
    /// **Why `.immediate` on termination (Cleanup Invariant)**:
    /// Once the main app process has exited there is no longer an in-process actor that can
    /// service `AppIntent` taps from the Live Activity or push fresh `ContentState` updates.
    /// Leaving the LA visible would allow ActivityKit / Chrono to treat the surface as
    /// active with no live backing process. Immediate dismissal after the final
    /// `.userPaused` push stops that.
    ///
    /// The user can still launch the app via home-screen widget "tap to open", Control
    /// widget, app icon, or (while the LA is still present before termination completes)
    /// the standard Live Activity tap-to-launch ("open") URL.
    ///
    /// - Parameters:
    ///   - dismissalPolicy: ActivityKit dismissal policy (default `.default`).
    ///   - waitForSystemCompletion: When `true` (termination only), block the calling
    ///     context briefly until ActivityKit end finishes or a short timeout elapses.
    ///     Must not be used from paths that cannot afford run-loop pumping.
    /// - Lifecycle: Clears `lastPushedContent`, durable LA mirrors, and observation so a
    ///   future `startActivity` begins clean.
    /// - Note: Does **not** end on user pause — a paused LA with a working play control
    ///   is intentional while the main process is alive.
    /// - Precondition: Main-app process only (widget processes never own the Activity).
    /// - Important: Under `isRunningInUITestMode` / DEBUG `isRunningUnderTest` performs
    ///   only cheap local cleanup; real ActivityKit IPC is skipped (test isolation).
    /// - SeeAlso: ``endActivityAsync(dismissalPolicy:)``, ``handleAppWillTerminate()``,
    ///   ``observeExistingActivities()``, AppDelegate.applicationWillTerminate,
    ///   SharedPlayerManager.forceStaleLivenessTimestampForTermination,
    ///   SharedPlayerManager.performSessionTeardownSynchronouslyForTermination,
    ///   RadioLiveActivityManagerTests, docs/Widget-Presentation-Dataflow.md,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    func endActivity(
        dismissalPolicy: ActivityUIDismissalPolicy = .default,
        waitForSystemCompletion: Bool = false
    ) {
        let prepared = prepareLocalLiveActivityEndState()
        guard let prepared else { return }

        if waitForSystemCompletion {
            endActivitiesWaitingForSystem(
                prepared.activities,
                finalContentState: prepared.finalContentState,
                dismissalPolicy: dismissalPolicy
            )
        } else {
            endActivitiesInBackground(
                prepared.activities,
                finalContentState: prepared.finalContentState,
                dismissalPolicy: dismissalPolicy
            )
        }
    }

    /// Awaitable Live Activity end for session teardown while the process remains alive.
    ///
    /// Prefer this from ``SharedPlayerManager/performSessionAndWidgetTeardown`` (privacy
    /// clear, cold-launch factory reset) so ActivityKit dismissal completes before later
    /// work races with ``observeExistingActivities()`` re-query.
    ///
    /// - Parameter dismissalPolicy: ActivityKit dismissal policy.
    /// - Postcondition: Local tracking cleared; every interactive system activity for this
    ///   attribute type has been asked to end with a final coherent ContentState.
    /// - SeeAlso: ``endActivity(dismissalPolicy:waitForSystemCompletion:)``,
    ///   ``handleAppWillTerminate()``.
    func endActivityAsync(dismissalPolicy: ActivityUIDismissalPolicy = .default) async {
        let prepared = prepareLocalLiveActivityEndState()
        guard let prepared else { return }

        await endActivitiesAwaitingSystem(
            prepared.activities,
            finalContentState: prepared.finalContentState,
            dismissalPolicy: dismissalPolicy
        )
    }

    /// Local prep shared by sync/async end paths: cancel observation, build final
    /// ContentState, clear mirrors, and collect system activities to dismiss.
    ///
    /// Final language/metadata priority (chrome must not invent a live stream, but should
    /// not flash the wrong language on cold-launch reaping either):
    /// 1. ``lastPushedContent`` (this-process last accepted push)
    /// 2. `currentActivity?.content.state` (owned Activity)
    /// 3. Residual system activities' `content.state` (prior-process force-quit leftovers when
    ///    local tracking is empty on cold launch)
    /// 4. ``SharedPlayerManager/mainAppLiveActivityLanguageCode()`` (language only)
    ///
    /// Visual is always forced to `.userPaused` regardless of residual visual.
    ///
    /// - Returns: Activities + final state when ActivityKit work must run; `nil` when
    ///   test isolation short-circuits or there is nothing for the system to end.
    /// - SeeAlso: ``_test_finalEndContentState(lastPushed:activityState:residualState:fallbackLanguage:)``,
    ///   ``observeExistingActivities()``.
    private func prepareLocalLiveActivityEndState() -> (
        activities: [Activity<LutheranRadioLiveActivityAttributes>],
        finalContentState: LutheranRadioLiveActivityAttributes.ContentState
    )? {
        stopLocalUpdateTimer()
        activityEventObserver.cancel()
        activityObservationTask = nil

        // Snapshot local chrome *before* clearing tracking so an in-process end cannot
        // invent language or drop the stream the user was just watching.
        let languageFromLocal =
            lastPushedContent?.currentLanguage
            ?? currentActivity?.content.state.currentLanguage
        let metadataFromLocal =
            lastPushedContent?.streamMetadata
            ?? currentActivity?.content.state.streamMetadata

        // Defense-in-depth UI test isolation — no ActivityKit IPC under test hosts.
        if SharedPlayerManager.isRunningInUITestMode {
            cancelPostSettledLanguageEnsureRetries()
            cancelPostSettledPlayingEnsureRetries()
            cancelAllPostQuietLongHorizonEnsure()
            currentActivity = nil
            cancelInFlightContentPushConfirmation(clearCoalesced: true)
            lastPushedContent = nil
            lastSystemHeldContent = nil
            consecutiveStalledContentPushes = 0
            interactiveContentRecreationsAttempted = 0
            languageEnsureQuietPendingDestination = nil
            languageSettledAcceptanceConsumedDestination = nil
            playingEnsureQuietPending = false
            playingSettledAcceptanceConsumed = false
            languageEnsureQuietSkipLogged = false
            playingEnsureQuietSkipLogged = false
            clearContentPushDiagnosticsSignatures()
            if !isRecreatingLiveActivityAfterStalledContent {
                pendingInteractiveLiveActivityEnsure = false
            }
            SharedPlayerManager.clearLiveActivityToggleVisualStateMirror()
            SharedPlayerManager.clearLiveActivityLanguageMirror()
            return nil
        }

        #if DEBUG
        if isRunningUnderTest {
            cancelPostSettledLanguageEnsureRetries()
            cancelPostSettledPlayingEnsureRetries()
            cancelAllPostQuietLongHorizonEnsure()
            currentActivity = nil
            cancelInFlightContentPushConfirmation(clearCoalesced: true)
            lastPushedContent = nil
            lastSystemHeldContent = nil
            consecutiveStalledContentPushes = 0
            interactiveContentRecreationsAttempted = 0
            languageEnsureQuietPendingDestination = nil
            languageSettledAcceptanceConsumedDestination = nil
            playingEnsureQuietPending = false
            playingSettledAcceptanceConsumed = false
            languageEnsureQuietSkipLogged = false
            playingEnsureQuietSkipLogged = false
            clearContentPushDiagnosticsSignatures()
            if !isRecreatingLiveActivityAfterStalledContent {
                pendingInteractiveLiveActivityEnsure = false
            }
            SharedPlayerManager.clearLiveActivityToggleVisualStateMirror()
            SharedPlayerManager.clearLiveActivityLanguageMirror()
            return nil
        }
        #endif

        // Sweep system-held activities even when `currentActivity` is already nil
        // (observe race, prior partial end, force-quit residual reaped on next launch).
        let activities = collectActivitiesToEnd()

        cancelPostSettledLanguageEnsureRetries()
        cancelPostSettledPlayingEnsureRetries()
        cancelAllPostQuietLongHorizonEnsure()
        currentActivity = nil
        cancelInFlightContentPushConfirmation(clearCoalesced: true)
        lastPushedContent = nil
        lastSystemHeldContent = nil
        consecutiveStalledContentPushes = 0
        languageEnsureQuietPendingDestination = nil
        languageSettledAcceptanceConsumedDestination = nil
        playingEnsureQuietPending = false
        playingSettledAcceptanceConsumed = false
        languageEnsureQuietSkipLogged = false
        playingEnsureQuietSkipLogged = false
        clearContentPushDiagnosticsSignatures()
        // Do not reset interactiveContentRecreationsAttempted here when recreation is mid-flight
        // (end clears tracking before start). Recreation counter is owned by the recreation cycle.
        // Pending ensure survives an in-flight recreation end so a failed replacement start
        // can still recover on foreground; session teardown clears it.
        if !isRecreatingLiveActivityAfterStalledContent {
            interactiveContentRecreationsAttempted = 0
            pendingInteractiveLiveActivityEnsure = false
        }
        SharedPlayerManager.clearLiveActivityToggleVisualStateMirror()
        SharedPlayerManager.clearLiveActivityLanguageMirror()

        guard !activities.isEmpty else { return nil }

        // Cold-launch reaping: local tracking is empty after process exit. Seed final
        // language/metadata from residual system ContentState so the dismiss frame keeps
        // the stream chrome the user last saw (visual still forced to .userPaused).
        let residualChrome = Self.seedFinalEndChromeFromResidualActivities(activities)
        let finalLanguage =
            languageFromLocal
            ?? residualChrome.language
            ?? SharedPlayerManager.mainAppLiveActivityLanguageCode()
        let finalMetadata = metadataFromLocal ?? residualChrome.metadata

        // Final frame: never claim live audio after the owning process is leaving or
        // the session is torn down. Language chrome stays consistent with the last stream.
        let finalContentState = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .userPaused,
            streamMetadata: finalMetadata,
            currentLanguage: finalLanguage
        )
        return (activities, finalContentState)
    }

    /// Seeds language/metadata from residual system activities when this-process local
    /// tracking is empty (typical cold-launch reaping after force-quit).
    ///
    /// - Parameter activities: System-held activities collected for end.
    /// - Returns: First non-empty language and first non-nil program metadata found.
    private static func seedFinalEndChromeFromResidualActivities(
        _ activities: [Activity<LutheranRadioLiveActivityAttributes>]
    ) -> (language: String?, metadata: StreamProgramMetadata?) {
        var language: String?
        var metadata: StreamProgramMetadata?
        for activity in activities {
            let state = activity.content.state
            if language == nil, !state.currentLanguage.isEmpty {
                language = state.currentLanguage
            }
            if metadata == nil, let meta = state.streamMetadata {
                metadata = meta
            }
            if language != nil, metadata != nil { break }
        }
        return (language, metadata)
    }

    /// System-held Live Activities for this attribute type, or empty when ActivityKit is absent.
    ///
    /// Designed-for-iPhone Mac has no ActivityKit output service. Reading
    /// `Activity.activities` logs `OutputClientError`. Return empty without querying.
    ///
    /// - Returns: `Activity.activities` on iPhone / iPad; `[]` when
    ///   ``SharedPlayerManager/isRunningAsIOSAppOnMac``.
    /// - SeeAlso: ``areActivitiesEnabledOnThisHost``, ``observeExistingActivities()``,
    ///   ``collectActivitiesToEnd()``
    private func systemHeldLiveActivities() -> [Activity<LutheranRadioLiveActivityAttributes>] {
        if SharedPlayerManager.isRunningAsIOSAppOnMac {
            return []
        }
        return Activity<LutheranRadioLiveActivityAttributes>.activities
    }

    /// Collects unique Live Activities to dismiss: the local `currentActivity` plus every
    /// system-held activity for this attribute type.
    ///
    /// - Important: Relying solely on `currentActivity` leaves orphans when the local
    ///   reference was cleared (or never set after process exit) while ActivityKit still
    ///   shows Dynamic Island / Lock Screen chrome.
    private func collectActivitiesToEnd() -> [Activity<LutheranRadioLiveActivityAttributes>] {
        var byId: [String: Activity<LutheranRadioLiveActivityAttributes>] = [:]
        if let current = currentActivity {
            byId[current.id] = current
        }
        for activity in systemHeldLiveActivities() {
            byId[activity.id] = activity
        }
        return Array(byId.values)
    }

    /// Fire-and-forget ActivityKit end while the process remains alive (privacy clear).
    private func endActivitiesInBackground(
        _ activities: [Activity<LutheranRadioLiveActivityAttributes>],
        finalContentState: LutheranRadioLiveActivityAttributes.ContentState,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) {
        let content = ActivityContent(state: finalContentState, staleDate: nil)
        for activity in activities {
            // Hoist Sendable identity before the ActivityKit hop so DEBUG logs never
            // touch the nonisolated(unsafe) binding (SE-0458 / SWIFT_STRICT_MEMORY_SAFETY).
            let activityId = activity.id
            // SAFETY: Activity is not Sendable in the current SDK; local strong reference
            // for update/end only (same capture pattern as updateCurrentActivity).
            nonisolated(unsafe) let safeActivity = activity
            Task {
                unsafe await safeActivity.update(content)
                unsafe await safeActivity.end(content, dismissalPolicy: dismissalPolicy)
                #if DEBUG
                print("🔴 Live Activity ended (policy: \(dismissalPolicy)) id=\(activityId)")
                #endif
            }
        }
    }

    /// Awaits ActivityKit final push + end for each activity (session teardown while alive).
    private func endActivitiesAwaitingSystem(
        _ activities: [Activity<LutheranRadioLiveActivityAttributes>],
        finalContentState: LutheranRadioLiveActivityAttributes.ContentState,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) async {
        let content = ActivityContent(state: finalContentState, staleDate: nil)
        for activity in activities {
            // Hoist Sendable identity before the ActivityKit hop so DEBUG logs never
            // touch the nonisolated(unsafe) binding (SE-0458 / SWIFT_STRICT_MEMORY_SAFETY).
            let activityId = activity.id
            // SAFETY: Activity is not Sendable in the current SDK; local strong reference
            // for update/end only (same capture pattern as updateCurrentActivity).
            nonisolated(unsafe) let safeActivity = activity
            unsafe await safeActivity.update(content)
            unsafe await safeActivity.end(content, dismissalPolicy: dismissalPolicy)
            #if DEBUG
            print("🔴 Live Activity ended (awaited, policy: \(dismissalPolicy)) id=\(activityId)")
            #endif
        }
    }

    /// Termination-path end: ActivityKit work runs off the main actor and the caller
    /// pumps the run loop until completion or a short timeout.
    ///
    /// - Why not a plain MainActor `Task`: `applicationWillTerminate` returns and the
    ///   process may exit before a main-actor-scheduled Task runs. `Task.detached`
    ///   plus run-loop pumping keeps the process alive long enough for `end` to land.
    /// - Timeout: best-effort; if the system is wedged we still exit rather than hang.
    /// - SeeAlso: ``handleAppWillTerminate()``, ``endActivity(dismissalPolicy:waitForSystemCompletion:)``.
    private func endActivitiesWaitingForSystem(
        _ activities: [Activity<LutheranRadioLiveActivityAttributes>],
        finalContentState: LutheranRadioLiveActivityAttributes.ContentState,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) {
        let content = ActivityContent(state: finalContentState, staleDate: nil)
        let remaining = OSAllocatedUnfairLock(initialState: activities.count)

        for activity in activities {
            // Hoist Sendable identity before the detached hop so DEBUG logs never
            // touch the nonisolated(unsafe) binding (SE-0458 / SWIFT_STRICT_MEMORY_SAFETY).
            let activityId = activity.id
            // SAFETY: Activity is not Sendable in the current SDK; local strong reference
            // for Task.detached update/end only (same capture pattern as updateCurrentActivity).
            nonisolated(unsafe) let safeActivity = activity
            Task.detached {
                unsafe await safeActivity.update(content)
                unsafe await safeActivity.end(content, dismissalPolicy: dismissalPolicy)
                remaining.withLock { $0 = max(0, $0 - 1) }
                #if DEBUG
                print("🔴 Live Activity ended (termination wait, policy: \(dismissalPolicy)) id=\(activityId)")
                #endif
            }
        }

        // Bound wait so a stuck ActivityKit service cannot hang process exit forever.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let done = remaining.withLock { $0 == 0 }
            if done { break }
            // Pump the current run loop so detached work and any main hops can complete
            // while we still hold the termination callback stack.
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }

        #if DEBUG
        let leftover = remaining.withLock { $0 }
        if leftover > 0 {
            print("🔴 Live Activity termination wait timed out with \(leftover) activity end(s) outstanding")
        }
        #endif
    }
    
    // MARK: - Local-Only Update Timer (demoted fallback only)
    
    /// Starts (or restarts) the repeating fallback timer.
    ///
    /// **This timer is no longer the primary mechanism.** The Live Activity system
    /// is event-driven: visual state changes and ICY metadata arrivals push
    /// immediately via `updateCurrentActivity()` (which applies its own change
    /// detection).
    ///
    /// The timer is retained **only** as:
    /// - An explicit testing seam (`internal`).
    /// - A rare manual fallback for pathological cases where events stop arriving
    ///   while audio continues (e.g. certain background metadata starvation).
    ///
    /// Normal code paths (setPlaying, stop, didUpdateStreamMetadata, foreground,
    /// background auto-start) must **not** start this timer.
    ///
    /// - Important: Exposed as `internal` (together with `updateTimer` and
    ///   `stopLocalUpdateTimer`) as the designated white-box testing seam.
    ///   See ``RadioLiveActivityManager/updateTimer`` and RadioLiveActivityManagerTests.
    internal func startLocalUpdateTimer() {
        stopLocalUpdateTimer()
        
        // Fallback interval only. Not used for normal freshness.
        updateTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            Task { @MainActor in
                await self.updateCurrentActivity()
            }
        }
        
        #if DEBUG
        print("🔴 Started local *fallback* update timer for Live Activity (rarely used)")
        #endif
    }
    
    /// Stops and clears the local update timer (if any).
    ///
    /// Called from `endActivity()`, lifecycle handlers, and tests.
    /// Must be paired with every `startLocalUpdateTimer()` to avoid leaking
    /// repeating timers into the test host or the app.
    internal func stopLocalUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
        
        #if DEBUG
        print("🔴 Stopped local update timer")
        #endif
    }
    
    // MARK: - Privacy-Safe Helper Methods
    
    /// Runs once after singleton init to handle Live Activities that survived process exit.
    ///
    /// ## Process-exit residual reaping (not adoption)
    /// Earlier behavior re-attached `Activity.activities.first` as `currentActivity` and
    /// resumed attribute-events observation. That left Dynamic Island / Lock Screen showing
    /// a stale interactive ContentState (often `.playing`) after force-quit or a missed
    /// termination `end`, with no live audio engine behind it.
    ///
    /// Ownership rule: only this process lifetime may present an interactive LA. A fresh
    /// process must **reap** residuals (final `.userPaused` + `.immediate` end) rather than
    /// adopt them. New activities are created exclusively via ``startActivity()`` when
    /// playback becomes authoritative (or background auto-start while playing).
    ///
    /// **This-process ownership + sibling residual reaping:** if ``currentActivity`` is already
    /// non-nil when the deferred observe runs (``startActivity()`` raced ahead of the post-init
    /// yield), full ``endActivity`` is **not** used — that would dismiss the legitimate owned
    /// Activity and clear mirrors. Instead ``reapUnownedSystemResiduals(preservingOwnedActivityId:)``
    /// ends every system-held activity whose id differs from the owned one, preserving local
    /// tracking. This closes the hole where ownership skip alone could leave a second prior-
    /// process residual interactive while this process owns a new surface. Happy path:
    /// unowned ``startActivity()`` ends residual siblings with ``.immediate`` first, so the
    /// sibling set is empty. Owned start updates only and never leads with end.
    ///
    /// Background audio with a living process never re-enters this path — the singleton
    /// is already initialized and `currentActivity` is managed by start/update/end.
    ///
    /// - Important: In DEBUG builds this performs a **robust test-environment short-circuit**
    ///   using the shared ``isRunningUnderTest`` helper. A real `Activity.activities` lookup
    ///   is a synchronous call into ActivityKit's system services that becomes extremely
    ///   slow under LLDB when any Live Activity is present in the simulator. The guard
    ///   prevents that cost during unit tests and guarantees `currentActivity` starts as `nil`.
    ///
    /// - Note: The four-condition detection (env var + class + two processName checks)
    ///   is required because `XCTestConfigurationFilePath` is reliable under `xcodebuild`
    ///   but often absent from Xcode GUI test runs (Product → Test / test navigator).
    ///
    /// - SeeAlso: ``RadioLiveActivityManager/init()``, ``endActivity(dismissalPolicy:waitForSystemCompletion:)``,
    ///   ``startActivity()``, ``isRunningUnderTest``, RadioLiveActivityManagerTests.setUp,
    ///   docs/Widget-Presentation-Dataflow.md (termination + residual reaping),
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md, <doc:Architecture>
    private func observeExistingActivities() {
        // Defense-in-depth using the SSOT: short-circuit before any ActivityKit query
        // or timer scheduling when launched under -UITestMode. This is critical because
        // the manager is instantiated early (statics, coordinators) and its init calls this.
        if SharedPlayerManager.isRunningInUITestMode {
            currentActivity = nil
            activityEventObserver.cancel()
            activityObservationTask = nil
            return
        }

        // Designed-for-iPhone Mac: `Activity.activities` fails with OutputClientError.
        // Same cheap local nil as UITestMode — do not query or end surfaces that
        // cannot exist on this host.
        if SharedPlayerManager.isRunningAsIOSAppOnMac {
            currentActivity = nil
            activityEventObserver.cancel()
            activityObservationTask = nil
            return
        }

        #if DEBUG
        // Robust test detection (works in Xcode GUI + xcodebuild + attached LLDB).
        // We short-circuit *before* the synchronous call to ActivityKit's system services
        // using the shared `isRunningUnderTest` computed property (DRY).
        if isRunningUnderTest {
            currentActivity = nil
            activityEventObserver.cancel()
            activityObservationTask = nil
            return
        }
        #endif

        // This-process ownership: never full-end the owned Activity, but still reap any
        // sibling system residuals (ids other than currentActivity). Pure id policy lives
        // in ``systemResidualIdsToReap(systemActivityIds:ownedActivityId:)``.
        if let owned = currentActivity {
            reapUnownedSystemResiduals(preservingOwnedActivityId: owned.id)
            return
        }

        // No local ownership: never adopt a prior-process residual as interactive. Full
        // ``endActivity`` sweeps all system activities, pushes paused + residual language
        // chrome, and dismisses immediately. Local `currentActivity` stays nil until
        // ``startActivity()`` runs for this process lifetime.
        let residualCount = systemHeldLiveActivities().count
        if residualCount > 0 {
            #if DEBUG
            print("🔴 Reaping \(residualCount) residual Live Activity surface(s) from prior process lifetime")
            #endif
            endActivity(dismissalPolicy: .immediate, waitForSystemCompletion: false)
        } else {
            currentActivity = nil
        }
    }

    /// Ends system-held Live Activities that are **not** this process's owned surface.
    ///
    /// Used when deferred ``observeExistingActivities()`` finds ``currentActivity`` already
    /// set (start raced ahead of post-init yield, or any future assignment site that did not
    /// go through unowned ``startActivity()``'s leading ``endActivity(dismissalPolicy: .immediate)``).
    /// Full ``endActivity`` would
    /// clear ownership and mirrors; this path must not.
    ///
    /// - Parameter ownedActivityId: ``currentActivity`` id to preserve.
    /// - Postcondition: Owned tracking, observation, and durable mirrors are unchanged.
    ///   Sibling residuals receive final `.userPaused` ContentState and `.immediate` end.
    /// - SeeAlso: ``systemResidualIdsToReap(systemActivityIds:ownedActivityId:)``,
    ///   ``seedFinalEndChromeFromResidualActivities(_:)``, ``observeExistingActivities()``.
    private func reapUnownedSystemResiduals(preservingOwnedActivityId ownedActivityId: String) {
        let systemActivities = systemHeldLiveActivities()
        let siblingIds = Self.systemResidualIdsToReap(
            systemActivityIds: systemActivities.map(\.id),
            ownedActivityId: ownedActivityId
        )
        guard !siblingIds.isEmpty else {
            #if DEBUG
            print("🔴 No unowned system residuals — preserving owned currentActivity id=\(ownedActivityId)")
            #endif
            return
        }

        let siblingSet = Set(siblingIds)
        let siblings = systemActivities.filter { siblingSet.contains($0.id) }
        #if DEBUG
        print("🔴 Reaping \(siblings.count) unowned residual Live Activity surface(s); preserving owned id=\(ownedActivityId)")
        #endif

        // Residual-only chrome: do not read owned lastPushedContent into the dismiss frame
        // (owned surface keeps its live chrome). Visual still forced to .userPaused.
        let residualChrome = Self.seedFinalEndChromeFromResidualActivities(siblings)
        let finalLanguage =
            residualChrome.language
            ?? SharedPlayerManager.mainAppLiveActivityLanguageCode()
        let finalContentState = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .userPaused,
            streamMetadata: residualChrome.metadata,
            currentLanguage: finalLanguage
        )
        endActivitiesInBackground(
            siblings,
            finalContentState: finalContentState,
            dismissalPolicy: .immediate
        )
    }

    /// Pure residual-id policy for cold-launch / deferred observe reaping.
    ///
    /// - Parameters:
    ///   - systemActivityIds: Ids from `Activity.activities` (system-held surfaces).
    ///   - ownedActivityId: This-process ``currentActivity`` id, or `nil` when unowned.
    /// - Returns: Ids that must be ended. When unowned, every system id. When owned, every
    ///   system id **except** the owned one (sibling residuals only).
    /// - Important: Never returns the owned id when `ownedActivityId` is non-nil — that
    ///   would reintroduce the "end our new Activity as a residual" race.
    /// - SeeAlso: ``observeExistingActivities()``, ``reapUnownedSystemResiduals(preservingOwnedActivityId:)``.
    private static func systemResidualIdsToReap(
        systemActivityIds: [String],
        ownedActivityId: String?
    ) -> [String] {
        guard let ownedActivityId else {
            return systemActivityIds
        }
        return systemActivityIds.filter { $0 != ownedActivityId }
    }

    // MARK: - Live Activity Attribute Events Observation

    /// Records a system-accepted ``ContentState`` from the attribute-events stream.
    ///
    /// Keeps ``lastPushedContent`` aligned with the Live Activity surface so
    /// ``updateCurrentActivity()`` can suppress redundant `Activity.update` IPC.
    /// Axis-scoped heal (async): partial acceptance clears only the converged axis and
    /// follow-through soft-ensures the lagging one — does **not** treat every yield as full heal.
    /// Delayed re-read runs the same heal when this observer is silent under lock.
    ///
    /// - SeeAlso: ``applySystemContentUpdateHeal(systemContent:priorObservedLanguage:priorObservedVisual:)``,
    ///   ``shouldApplySystemContentUpdateHealAfterObservation(kind:)``,
    ///   ``contentUpdateAxisHealPolicy(systemLanguage:systemVisual:destinationLanguage:actorVisual:isStreamSwitchHoldActive:isConnectingPlayback:priorObservedLanguage:priorObservedVisual:)``,
    ///   ``scheduleInFlightContentPushConfirmation(candidate:)``.
    private func handleActivityContentUpdate(
        _ content: ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>
    ) {
        // Prior SSOT is last **system-held** chrome, never aspirational ``lastPushedContent``.
        let priorLanguage = lastSystemHeldContent?.currentLanguage
        let priorVisual = lastSystemHeldContent?.visualState
        lastSystemHeldContent = content.state
        lastPushedContent = content.state
        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(content.state.visualState)
        SharedPlayerManager.persistLiveActivityLanguageMirror(content.state.currentLanguage)
        #if DEBUG
        // Rate-limited yield line: proves observer silence vs heal-miss on device without
        // citing local capture filenames. Identical (id, language, visual) stay quiet.
        let activityId = currentActivity?.id ?? "unowned"
        let yieldSig = Self.contentUpdatesYieldDiagnosticsSignature(
            systemLanguage: content.state.currentLanguage,
            systemVisual: content.state.visualState,
            activityId: activityId
        )
        if Self.shouldLogStalledContentDiagnostics(
            signature: yieldSig,
            lastLoggedSignature: lastLoggedContentUpdatesYieldDiagnosticsSignature
        ) {
            lastLoggedContentUpdatesYieldDiagnosticsSignature = yieldSig
            print(
                "🔴 Live Activity contentUpdates yield: id=\(activityId) " +
                "systemLang=\(content.state.currentLanguage) systemVisual=\(content.state.visualState)"
            )
        }
        #endif
        // Axis-aware heal needs actor SSOT (await hops) — schedule without blocking the
        // contentUpdates consumer. Suppress memory already seeded above.
        let inFlightCandidate = inFlightContentPushCandidate
        cancelInFlightContentPushConfirmation()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let inFlightCandidate {
                let manager = SharedPlayerManager.shared
                let hold = await manager.isStreamSwitchPrePlayHoldActive
                let connecting = await manager.isConnectingPlayback
                await self.commitContentPushObservation(
                    candidate: inFlightCandidate,
                    observed: content.state,
                    kind: .contentUpdates,
                    isStreamSwitchHoldActive: hold,
                    isConnectingPlayback: connecting
                )
            }
            // Apply committed via contentUpdates: flush coalesced visual once, then axis-heal.
            await self.flushCoalescedContentPushIfNeeded(observed: content.state)
            if Self.shouldApplySystemContentUpdateHealAfterObservation(kind: .contentUpdates) {
                await self.applySystemContentUpdateHeal(
                    systemContent: content.state,
                    priorObservedLanguage: priorLanguage,
                    priorObservedVisual: priorVisual
                )
            }
        }
    }

    /// Applies axis-scoped quiet / post-settled / stall-streak heal after a committed observation.
    ///
    /// Runs after `contentUpdates` **or** delayed re-read (not immediate post-await).
    ///
    /// - Parameters:
    ///   - systemContent: Latest `content.state` from ActivityKit.
    ///   - priorObservedLanguage: Language before this observation (coarsen same-stream thrash).
    ///   - priorObservedVisual: Visual before this observation.
    /// - Postcondition: Converged axes clear quiet and cancel their post-settled tasks; lagging
    ///   axes retain post-settled work or get **true-new** follow-through soft ensure; stall
    ///   streak resets only when the full candidate is no longer stalled. Never ends the
    ///   interactive surface. Never invents `.playing`.
    /// - SeeAlso: ``contentUpdateAxisHealPolicy(systemLanguage:systemVisual:destinationLanguage:actorVisual:isStreamSwitchHoldActive:isConnectingPlayback:priorObservedLanguage:priorObservedVisual:)``,
    ///   ``ensureAuthoritativePlayingContentIfNeeded()``,
    ///   ``ensureAuthoritativeLanguageContentIfNeeded()``.
    @MainActor
    private func applySystemContentUpdateHeal(
        systemContent: LutheranRadioLiveActivityAttributes.ContentState,
        priorObservedLanguage: String?,
        priorObservedVisual: PlayerVisualState?
    ) async {
        if SharedPlayerManager.isRunningInUITestMode { return }
        #if DEBUG
        if isRunningUnderTest { return }
        #endif
        // Ownership may have ended between the yield and this task.
        guard currentActivity != nil else { return }

        let manager = SharedPlayerManager.shared
        let destination = await manager.liveActivityLanguageCodeForContentPush()
        let actorVisual = await manager.currentVisualState
        let hold = await manager.isStreamSwitchPrePlayHoldActive
        let connecting = await manager.isConnectingPlayback
        let requestEligible = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )

        let policy = Self.contentUpdateAxisHealPolicy(
            systemLanguage: systemContent.currentLanguage,
            systemVisual: systemContent.visualState,
            destinationLanguage: destination,
            actorVisual: actorVisual,
            isStreamSwitchHoldActive: hold,
            isConnectingPlayback: connecting,
            priorObservedLanguage: priorObservedLanguage,
            priorObservedVisual: priorObservedVisual
        )

        if policy.resetStalledStreakAndRecreationBudget {
            consecutiveStalledContentPushes = 0
            interactiveContentRecreationsAttempted = 0
            clearContentPushDiagnosticsSignatures()
        }

        if policy.clearLanguageQuiet {
            languageEnsureQuietPendingDestination = nil
            languageEnsureQuietSkipLogged = false
        }
        if policy.clearLanguageSettleConsume {
            languageSettledAcceptanceConsumedDestination = nil
        }
        if policy.cancelLanguagePostSettled {
            cancelPostSettledLanguageEnsureRetries()
        }

        if policy.clearPlayingQuiet {
            playingEnsureQuietPending = false
            playingEnsureQuietSkipLogged = false
        }
        if policy.clearPlayingSettleConsume {
            playingSettledAcceptanceConsumed = false
        }
        if policy.cancelPlayingPostSettled {
            cancelPostSettledPlayingEnsureRetries()
        }

        #if DEBUG
        if policy.shouldFollowThroughPlayingEnsure || policy.shouldFollowThroughLanguageEnsure {
            print(
                "🔴 Live Activity axis heal " +
                "(langConverged=\(policy.languageConverged) playConverged=\(policy.playingConverged) " +
                "followPlay=\(policy.shouldFollowThroughPlayingEnsure) " +
                "followLang=\(policy.shouldFollowThroughLanguageEnsure) " +
                "resetStreak=\(policy.resetStalledStreakAndRecreationBudget))"
            )
        }
        #endif

        // True language-new win with residual visual lag (device: de flag + prePlay glyph).
        // Same-stream contentUpdates (language already matched) skip follow-through thrash.
        if policy.shouldFollowThroughPlayingEnsure {
            contentEnsureFreezeLanguageNewlyConverged = true
            let allowFollowThrough = Self.shouldClearPlayingEnsureQuietForPartialRearm(
                shouldRearmFromPartialPolicy: true,
                freezeSoftBudgetExhausted: contentEnsureFreezeSoftBudgetExhausted,
                partialPostSettledAlreadyScheduled: contentEnsureFreezePartialPostSettledScheduled,
                isRequestEligible: requestEligible
            )
            if allowFollowThrough {
                playingEnsureQuietPending = false
                playingEnsureQuietSkipLogged = false
                await ensureAuthoritativePlayingContentIfNeeded()
                let ownedVisual = currentActivity?.content.state.visualState
                let actorAfter = await manager.currentVisualState
                let holdAfter = await manager.isStreamSwitchPrePlayHoldActive
                let connectingAfter = await manager.isConnectingPlayback
                let baseSchedule = Self.shouldSchedulePostSettledPlayingEnsureRetries(
                    hasCurrentActivity: currentActivity != nil,
                    actorVisual: actorAfter,
                    ownedContentVisual: ownedVisual,
                    isStreamSwitchHoldActive: holdAfter,
                    isConnectingPlayback: connectingAfter
                )
                if Self.shouldSchedulePostSettledPlayingEnsureAfterSoftBudgetExhaust(
                    baseShouldSchedule: baseSchedule,
                    isRequestEligible: requestEligible,
                    languageNewlyConvergedThisFreeze: true,
                    partialPostSettledAlreadyScheduled: contentEnsureFreezePartialPostSettledScheduled
                ) {
                    schedulePostSettledPlayingEnsureRetriesIfNeeded()
                    contentEnsureFreezePartialPostSettledScheduled = true
                }
                // Keep playing long-horizon armed when visual still lags after axis follow-through.
                if ownedVisual != .playing {
                    await armPostQuietLongHorizonPlayingEnsureIfNeeded()
                }
            } else if systemContent.visualState != .playing {
                // Quiet cool-down — residual visual lag waits for mutation / eligibility / LH.
                await armPostQuietLongHorizonPlayingEnsureIfNeeded()
            }
        }

        // True visual-new win with residual language lag.
        if policy.shouldFollowThroughLanguageEnsure {
            contentEnsureFreezeVisualNewlyConverged = true
            let allowLanguageFollowThrough =
                requestEligible
                || !contentEnsureFreezeSoftBudgetExhausted
                || !contentEnsureFreezePartialPostSettledScheduled
            if allowLanguageFollowThrough {
                languageEnsureQuietPendingDestination = nil
                languageEnsureQuietSkipLogged = false
                await ensureAuthoritativeLanguageContentIfNeeded()
                let ownedLanguage = currentActivity?.content.state.currentLanguage
                let destAfter = await manager.liveActivityLanguageCodeForContentPush()
                let holdAfter = await manager.isStreamSwitchPrePlayHoldActive
                let baseLangSchedule = Self.shouldSchedulePostSettledLanguageEnsureRetries(
                    hasCurrentActivity: currentActivity != nil,
                    destinationLanguage: destAfter,
                    ownedContentLanguage: ownedLanguage,
                    isStreamSwitchHoldActive: holdAfter
                )
                if Self.shouldSchedulePostSettledLanguageEnsureAfterSoftBudgetExhaust(
                    baseShouldSchedule: baseLangSchedule,
                    isRequestEligible: requestEligible,
                    visualNewlyConvergedThisFreeze: true,
                    partialPostSettledAlreadyScheduled: contentEnsureFreezePartialPostSettledScheduled
                ) {
                    schedulePostSettledLanguageEnsureRetriesIfNeeded(destination: destAfter)
                    contentEnsureFreezePartialPostSettledScheduled = true
                }
                if ownedLanguage != destAfter {
                    await armPostQuietLongHorizonLanguageEnsureIfNeeded()
                }
            } else if systemContent.currentLanguage != destination {
                await armPostQuietLongHorizonLanguageEnsureIfNeeded()
            }
        }
    }

    /// Clears local activity tracking when attribute-events observation ends.
    ///
    /// Self-healing hygiene runs when ``currentActivity`` is still non-nil (for example
    /// after system dismissal) so stale references do not drive spurious update attempts.
    private func performAttributeObservationTerminationHygiene() {
        #if DEBUG
        if _test_harnessSimulatesActiveActivity {
            _test_harnessSimulatesActiveActivity = false
            cancelPostSettledLanguageEnsureRetries()
            cancelPostSettledPlayingEnsureRetries()
            cancelAllPostQuietLongHorizonEnsure()
            currentActivity = nil
            cancelInFlightContentPushConfirmation(clearCoalesced: true)
            lastPushedContent = nil
            lastSystemHeldContent = nil
            consecutiveStalledContentPushes = 0
            languageEnsureQuietPendingDestination = nil
            languageSettledAcceptanceConsumedDestination = nil
            playingEnsureQuietPending = false
            playingSettledAcceptanceConsumed = false
            languageEnsureQuietSkipLogged = false
            playingEnsureQuietSkipLogged = false
            clearContentPushDiagnosticsSignatures()
            if !isRecreatingLiveActivityAfterStalledContent {
                interactiveContentRecreationsAttempted = 0
            }
            SharedPlayerManager.clearLiveActivityToggleVisualStateMirror()
            SharedPlayerManager.clearLiveActivityLanguageMirror()
            return
        }
        #endif
        guard currentActivity != nil else { return }
        cancelPostSettledLanguageEnsureRetries()
        cancelPostSettledPlayingEnsureRetries()
        cancelAllPostQuietLongHorizonEnsure()
        currentActivity = nil
        cancelInFlightContentPushConfirmation(clearCoalesced: true)
        lastPushedContent = nil
        lastSystemHeldContent = nil
        consecutiveStalledContentPushes = 0
        languageEnsureQuietPendingDestination = nil
        languageSettledAcceptanceConsumedDestination = nil
        playingEnsureQuietPending = false
        playingSettledAcceptanceConsumed = false
        languageEnsureQuietSkipLogged = false
        playingEnsureQuietSkipLogged = false
        clearContentPushDiagnosticsSignatures()
        if !isRecreatingLiveActivityAfterStalledContent {
            interactiveContentRecreationsAttempted = 0
        }
        SharedPlayerManager.clearLiveActivityToggleVisualStateMirror()
        SharedPlayerManager.clearLiveActivityLanguageMirror()
    }

    /// Publishes the consolidated observer task into ``activityObservationTask``.
    private func publishActivityObservationTask() {
        activityObservationTask = activityEventObserver.task
    }

    #if DEBUG
    /// White-box seam: wires production-identical attribute-events handlers against a
    /// synthetic ``AsyncStream`` fixture instead of ActivityKit ``contentUpdates`` IPC.
    ///
    /// - Parameter stream: In-memory ``ActivityContent`` sequence for unit tests.
    /// - Postcondition: ``activityObservationTask`` holds the observer task published by
    ///   ``WidgetEventObserver``.
    /// - SeeAlso: ``beginObservingActivityEvents(_:)``, RadioLiveActivityManagerTests,
    ///   ``_test_wouldSuppressLiveActivityUpdate(visualState:streamMetadata:)``,
    ///   ``_test_setHarnessSimulatesActiveActivity(_:)``.
    func _test_beginObservingSyntheticContentUpdates(
        _ stream: AsyncStream<ActivityContent<LutheranRadioLiveActivityAttributes.ContentState>>
    ) {
        activityEventObserver.beginObserving(
            stream,
            onElement: { [weak self] content in
                self?.handleActivityContentUpdate(content)
            },
            onTermination: { [weak self] in
                self?.performAttributeObservationTerminationHygiene()
            }
        )
        publishActivityObservationTask()
    }

    /// Returns whether ``updateCurrentActivity()`` would suppress an ActivityKit push under
    /// the production suppress policy (``lastPushedContent`` + owned language/visual gates).
    /// Performs no IPC.
    ///
    /// - Parameters:
    ///   - visualState: Candidate visual state from the player SSOT.
    ///   - streamMetadata: Candidate ICY metadata (nil when absent).
    ///   - currentLanguage: Candidate stream language code (defaults to last-pushed language,
    ///     or ``SharedPlayerManager/mainAppLiveActivityLanguageCode()`` when unset).
    ///   - ownedContentLanguage: Simulated `currentActivity?.content.state.currentLanguage`.
    ///     Defaults to `nil` (owned-language gate skipped).
    ///   - ownedContentVisual: Simulated `currentActivity?.content.state.visualState`.
    ///     Defaults to `nil` (owned-visual gate skipped).
    /// - Returns: `true` when production would skip ActivityKit IPC for this candidate.
    /// - SeeAlso: ``shouldSuppressLiveActivityContentPush(lastPushed:candidate:ownedContentLanguage:ownedContentVisual:)``,
    ///   ``shouldEnsureAuthoritativeLanguageContent(destinationLanguage:ownedContentLanguage:lastPushedLanguage:)``.
    func _test_wouldSuppressLiveActivityUpdate(
        visualState: PlayerVisualState,
        streamMetadata: StreamProgramMetadata?,
        currentLanguage: String? = nil,
        ownedContentLanguage: String? = nil,
        ownedContentVisual: PlayerVisualState? = nil
    ) -> Bool {
        let language = currentLanguage
            ?? lastPushedContent?.currentLanguage
            ?? SharedPlayerManager.mainAppLiveActivityLanguageCode()
        let candidate = LutheranRadioLiveActivityAttributes.ContentState(
            visualState: visualState,
            streamMetadata: streamMetadata,
            currentLanguage: language
        )
        return Self.shouldSuppressLiveActivityContentPush(
            lastPushed: lastPushedContent,
            candidate: candidate,
            ownedContentLanguage: ownedContentLanguage,
            ownedContentVisual: ownedContentVisual
        )
    }

    /// White-box seam for language-reconcile decision (no ActivityKit / no actor hop).
    ///
    /// - SeeAlso: ``shouldEnsureAuthoritativeLanguageContent(destinationLanguage:ownedContentLanguage:lastPushedLanguage:)``,
    ///   ``ensureAuthoritativeLanguageContentIfNeeded()``.
    func _test_shouldEnsureAuthoritativeLanguageContent(
        destinationLanguage: String,
        ownedContentLanguage: String?,
        lastPushedLanguage: String?
    ) -> Bool {
        Self.shouldEnsureAuthoritativeLanguageContent(
            destinationLanguage: destinationLanguage,
            ownedContentLanguage: ownedContentLanguage,
            lastPushedLanguage: lastPushedLanguage
        )
    }

    /// White-box seam: whether soft language ensure should run or stay quiet (no ActivityKit).
    func _test_shouldRunLanguageContentEnsureSoftPushes(
        needsLanguageEnsure: Bool,
        destinationLanguage: String,
        quietPendingDestination: String?,
        isRequestEligible: Bool
    ) -> Bool {
        Self.shouldRunLanguageContentEnsureSoftPushes(
            needsLanguageEnsure: needsLanguageEnsure,
            destinationLanguage: destinationLanguage,
            quietPendingDestination: quietPendingDestination,
            isRequestEligible: isRequestEligible
        )
    }

    /// White-box seam: quiet destination after soft budget exhaustion while ineligible.
    func _test_quietPendingDestinationAfterLanguageEnsureExhaustion(
        languageStillMismatches: Bool,
        isRequestEligible: Bool,
        destinationLanguage: String
    ) -> String? {
        Self.quietPendingDestinationAfterLanguageEnsureExhaustion(
            languageStillMismatches: languageStillMismatches,
            isRequestEligible: isRequestEligible,
            destinationLanguage: destinationLanguage
        )
    }

    /// White-box seam: language-only status push defer while quiet (no ActivityKit).
    func _test_shouldDeferRedundantLanguagePushWhileQuiet(
        candidateLanguage: String,
        ownedContentLanguage: String,
        ownedContentVisual: PlayerVisualState,
        candidateVisual: PlayerVisualState,
        quietPendingDestination: String?,
        isRequestEligible: Bool
    ) -> Bool {
        Self.shouldDeferRedundantLanguagePushWhileQuiet(
            candidateLanguage: candidateLanguage,
            ownedContentLanguage: ownedContentLanguage,
            ownedContentVisual: ownedContentVisual,
            candidateVisual: candidateVisual,
            quietPendingDestination: quietPendingDestination,
            isRequestEligible: isRequestEligible
        )
    }

    /// White-box seam: clear quiet after ownership / system acceptance / destination change.
    func _test_shouldClearLanguageEnsureQuietPending(
        quietPendingDestination: String?,
        destinationLanguage: String,
        ownedOrSystemLanguage: String?
    ) -> Bool {
        Self.shouldClearLanguageEnsureQuietPending(
            quietPendingDestination: quietPendingDestination,
            destinationLanguage: destinationLanguage,
            ownedOrSystemLanguage: ownedOrSystemLanguage
        )
    }

    /// White-box seam: read language ensure quiet destination (no ActivityKit).
    func _test_languageEnsureQuietPendingDestinationValue() -> String? {
        languageEnsureQuietPendingDestination
    }

    /// White-box seam: set language ensure quiet destination (no ActivityKit).
    func _test_setLanguageEnsureQuietPendingDestination(_ value: String?) {
        languageEnsureQuietPendingDestination = value
    }

    /// White-box seam: settled language acceptance policy (no ActivityKit).
    func _test_shouldPushSettledLanguageAcceptance(
        destinationLanguage: String,
        ownedContentLanguage: String?,
        isStreamSwitchHoldActive: Bool,
        settledAcceptanceConsumedDestination: String?,
        isRequestEligible: Bool
    ) -> Bool {
        Self.shouldPushSettledLanguageAcceptance(
            destinationLanguage: destinationLanguage,
            ownedContentLanguage: ownedContentLanguage,
            isStreamSwitchHoldActive: isStreamSwitchHoldActive,
            settledAcceptanceConsumedDestination: settledAcceptanceConsumedDestination,
            isRequestEligible: isRequestEligible
        )
    }

    /// White-box seam: whether delayed post-settled language soft-ensure retries should schedule.
    func _test_shouldSchedulePostSettledLanguageEnsureRetries(
        hasCurrentActivity: Bool,
        destinationLanguage: String,
        ownedContentLanguage: String?,
        isStreamSwitchHoldActive: Bool
    ) -> Bool {
        Self.shouldSchedulePostSettledLanguageEnsureRetries(
            hasCurrentActivity: hasCurrentActivity,
            destinationLanguage: destinationLanguage,
            ownedContentLanguage: ownedContentLanguage,
            isStreamSwitchHoldActive: isStreamSwitchHoldActive
        )
    }

    /// White-box seam: clear settled language consume on destination change / convergence.
    func _test_shouldClearLanguageSettledAcceptanceConsume(
        settledAcceptanceConsumedDestination: String?,
        destinationLanguage: String,
        ownedOrSystemLanguage: String?
    ) -> Bool {
        Self.shouldClearLanguageSettledAcceptanceConsume(
            settledAcceptanceConsumedDestination: settledAcceptanceConsumedDestination,
            destinationLanguage: destinationLanguage,
            ownedOrSystemLanguage: ownedOrSystemLanguage
        )
    }

    /// White-box seam: read settled language acceptance consume marker (no ActivityKit).
    func _test_languageSettledAcceptanceConsumedDestinationValue() -> String? {
        languageSettledAcceptanceConsumedDestination
    }

    /// White-box seam: set settled language acceptance consume marker (no ActivityKit).
    func _test_setLanguageSettledAcceptanceConsumedDestination(_ value: String?) {
        languageSettledAcceptanceConsumedDestination = value
    }

    /// White-box seam: settled playing acceptance policy (no ActivityKit).
    func _test_shouldPushSettledPlayingAcceptance(
        actorVisual: PlayerVisualState,
        ownedContentVisual: PlayerVisualState?,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool,
        settledAcceptanceConsumed: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        Self.shouldPushSettledPlayingAcceptance(
            actorVisual: actorVisual,
            ownedContentVisual: ownedContentVisual,
            isStreamSwitchHoldActive: isStreamSwitchHoldActive,
            isConnectingPlayback: isConnectingPlayback,
            settledAcceptanceConsumed: settledAcceptanceConsumed,
            isRequestEligible: isRequestEligible
        )
    }

    /// White-box seam: clear settled playing consume on owned visual convergence.
    func _test_shouldClearPlayingSettledAcceptanceConsume(
        settledAcceptanceConsumed: Bool,
        ownedOrSystemVisual: PlayerVisualState?
    ) -> Bool {
        Self.shouldClearPlayingSettledAcceptanceConsume(
            settledAcceptanceConsumed: settledAcceptanceConsumed,
            ownedOrSystemVisual: ownedOrSystemVisual
        )
    }

    /// White-box seam: whether delayed post-settled playing soft-ensure retries should schedule.
    func _test_shouldSchedulePostSettledPlayingEnsureRetries(
        hasCurrentActivity: Bool,
        actorVisual: PlayerVisualState,
        ownedContentVisual: PlayerVisualState?,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool
    ) -> Bool {
        Self.shouldSchedulePostSettledPlayingEnsureRetries(
            hasCurrentActivity: hasCurrentActivity,
            actorVisual: actorVisual,
            ownedContentVisual: ownedContentVisual,
            isStreamSwitchHoldActive: isStreamSwitchHoldActive,
            isConnectingPlayback: isConnectingPlayback
        )
    }

    /// White-box seam: post-quiet long-horizon playing arm policy (no ActivityKit).
    func _test_shouldArmPostQuietLongHorizonPlayingEnsure(
        hasCurrentActivity: Bool,
        isRequestEligible: Bool,
        longHorizonAlreadyArmed: Bool,
        actorVisual: PlayerVisualState,
        lastPushedVisual: PlayerVisualState?,
        ownedContentVisual: PlayerVisualState?,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool
    ) -> Bool {
        Self.shouldArmPostQuietLongHorizonPlayingEnsure(
            hasCurrentActivity: hasCurrentActivity,
            isRequestEligible: isRequestEligible,
            longHorizonAlreadyArmed: longHorizonAlreadyArmed,
            actorVisual: actorVisual,
            lastPushedVisual: lastPushedVisual,
            ownedContentVisual: ownedContentVisual,
            isStreamSwitchHoldActive: isStreamSwitchHoldActive,
            isConnectingPlayback: isConnectingPlayback
        )
    }

    /// White-box seam: post-quiet long-horizon language arm policy (no ActivityKit).
    func _test_shouldArmPostQuietLongHorizonLanguageEnsure(
        hasCurrentActivity: Bool,
        isRequestEligible: Bool,
        longHorizonAlreadyArmed: Bool,
        destinationLanguage: String,
        lastPushedLanguage: String?,
        ownedContentLanguage: String?,
        isStreamSwitchHoldActive: Bool
    ) -> Bool {
        Self.shouldArmPostQuietLongHorizonLanguageEnsure(
            hasCurrentActivity: hasCurrentActivity,
            isRequestEligible: isRequestEligible,
            longHorizonAlreadyArmed: longHorizonAlreadyArmed,
            destinationLanguage: destinationLanguage,
            lastPushedLanguage: lastPushedLanguage,
            ownedContentLanguage: ownedContentLanguage,
            isStreamSwitchHoldActive: isStreamSwitchHoldActive
        )
    }

    /// White-box seam: cancel long-horizon playing policy.
    func _test_shouldCancelPostQuietLongHorizonPlayingEnsure(
        hasCurrentActivity: Bool,
        ownedContentVisual: PlayerVisualState?,
        actorVisual: PlayerVisualState
    ) -> Bool {
        Self.shouldCancelPostQuietLongHorizonPlayingEnsure(
            hasCurrentActivity: hasCurrentActivity,
            ownedContentVisual: ownedContentVisual,
            actorVisual: actorVisual
        )
    }

    /// White-box seam: cancel long-horizon language policy.
    func _test_shouldCancelPostQuietLongHorizonLanguageEnsure(
        hasCurrentActivity: Bool,
        destinationLanguage: String,
        ownedContentLanguage: String?
    ) -> Bool {
        Self.shouldCancelPostQuietLongHorizonLanguageEnsure(
            hasCurrentActivity: hasCurrentActivity,
            destinationLanguage: destinationLanguage,
            ownedContentLanguage: ownedContentLanguage
        )
    }

    /// White-box seam: dual-axis long-horizon fire policy.
    func _test_shouldRunPostQuietLongHorizonDualAxisEnsure(
        languageStillLags: Bool,
        visualStillLags: Bool,
        actorVisual: PlayerVisualState,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool,
        freezeSoftBudgetExhausted: Bool = false,
        playingQuietPending: Bool = false,
        isRequestEligible: Bool = false
    ) -> Bool {
        Self.shouldRunPostQuietLongHorizonDualAxisEnsure(
            languageStillLags: languageStillLags,
            visualStillLags: visualStillLags,
            actorVisual: actorVisual,
            isStreamSwitchHoldActive: isStreamSwitchHoldActive,
            isConnectingPlayback: isConnectingPlayback,
            freezeSoftBudgetExhausted: freezeSoftBudgetExhausted,
            playingQuietPending: playingQuietPending,
            isRequestEligible: isRequestEligible
        )
    }

    /// White-box seam: clear language quiet on dual-axis long-horizon playing fire.
    func _test_shouldClearLanguageQuietForDualAxisLongHorizonFire(
        languageQuietPending: Bool,
        languageStillLags: Bool,
        visualStillLags: Bool,
        actorVisual: PlayerVisualState,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool
    ) -> Bool {
        Self.shouldClearLanguageQuietForDualAxisLongHorizonFire(
            languageQuietPending: languageQuietPending,
            languageStillLags: languageStillLags,
            visualStillLags: visualStillLags,
            actorVisual: actorVisual,
            isStreamSwitchHoldActive: isStreamSwitchHoldActive,
            isConnectingPlayback: isConnectingPlayback
        )
    }

    /// White-box seam: clear playing quiet on dual-axis long-horizon language fire.
    func _test_shouldClearPlayingQuietForDualAxisLongHorizonFire(
        playingQuietPending: Bool,
        languageStillLags: Bool,
        visualStillLags: Bool,
        actorVisual: PlayerVisualState,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool
    ) -> Bool {
        Self.shouldClearPlayingQuietForDualAxisLongHorizonFire(
            playingQuietPending: playingQuietPending,
            languageStillLags: languageStillLags,
            visualStillLags: visualStillLags,
            actorVisual: actorVisual,
            isStreamSwitchHoldActive: isStreamSwitchHoldActive,
            isConnectingPlayback: isConnectingPlayback
        )
    }

    /// White-box seam: arm playing long-horizon after quiet defer (C4).
    func _test_shouldArmPostQuietLongHorizonPlayingEnsureAfterQuietDefer(
        didDeferPlayingPushWhileQuiet: Bool,
        hasCurrentActivity: Bool,
        isRequestEligible: Bool,
        longHorizonAlreadyArmed: Bool,
        actorVisual: PlayerVisualState,
        lastPushedVisual: PlayerVisualState?,
        ownedContentVisual: PlayerVisualState?,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool
    ) -> Bool {
        Self.shouldArmPostQuietLongHorizonPlayingEnsureAfterQuietDefer(
            didDeferPlayingPushWhileQuiet: didDeferPlayingPushWhileQuiet,
            hasCurrentActivity: hasCurrentActivity,
            isRequestEligible: isRequestEligible,
            longHorizonAlreadyArmed: longHorizonAlreadyArmed,
            actorVisual: actorVisual,
            lastPushedVisual: lastPushedVisual,
            ownedContentVisual: ownedContentVisual,
            isStreamSwitchHoldActive: isStreamSwitchHoldActive,
            isConnectingPlayback: isConnectingPlayback
        )
    }

    /// White-box seam: whether playing long-horizon task is armed (task non-nil).
    func _test_postQuietLongHorizonPlayingEnsureArmed() -> Bool {
        postQuietLongHorizonPlayingEnsureTask != nil
    }

    /// White-box seam: whether language long-horizon task is armed (task non-nil).
    func _test_postQuietLongHorizonLanguageEnsureArmed() -> Bool {
        postQuietLongHorizonLanguageEnsureTask != nil
    }

    /// White-box seam: whether dual-axis long-horizon task is armed (task non-nil).
    func _test_postQuietLongHorizonDualAxisEnsureArmed() -> Bool {
        postQuietLongHorizonDualAxisEnsureTask != nil
    }

    /// White-box seam: post-quiet language long-horizon keeps owned visual after freeze.
    func _test_shouldKeepOwnedVisualOnPostQuietLanguageLongHorizon(
        freezeSoftBudgetExhausted: Bool,
        playingQuietPending: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        Self.shouldKeepOwnedVisualOnPostQuietLanguageLongHorizon(
            freezeSoftBudgetExhausted: freezeSoftBudgetExhausted,
            playingQuietPending: playingQuietPending,
            isRequestEligible: isRequestEligible
        )
    }

    /// White-box seam: language-only long-horizon candidate visual after freeze.
    func _test_languageOnlyLongHorizonCandidateVisual(
        ownedVisual: PlayerVisualState,
        actorResolvedVisual: PlayerVisualState,
        keepOwnedVisual: Bool
    ) -> PlayerVisualState {
        Self.languageOnlyLongHorizonCandidateVisual(
            ownedVisual: ownedVisual,
            actorResolvedVisual: actorResolvedVisual,
            keepOwnedVisual: keepOwnedVisual
        )
    }

    /// White-box seam: preserve owned visual on language-only ActivityKit candidate.
    func _test_shouldPreserveOwnedVisualOnLanguageOnlyContentPush(
        keepOwnedVisualAfterFreeze: Bool,
        isStreamSwitchHoldActive: Bool
    ) -> Bool {
        Self.shouldPreserveOwnedVisualOnLanguageOnlyContentPush(
            keepOwnedVisualAfterFreeze: keepOwnedVisualAfterFreeze,
            isStreamSwitchHoldActive: isStreamSwitchHoldActive
        )
    }

    /// White-box seam: dual-axis long-horizon arm policy.
    func _test_shouldArmPostQuietLongHorizonDualAxisEnsure(
        hasCurrentActivity: Bool,
        isRequestEligible: Bool,
        dualAxisAlreadyArmed: Bool,
        languageStillLags: Bool,
        visualStillLags: Bool,
        actorVisual: PlayerVisualState,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool,
        freezeSoftBudgetExhausted: Bool = false,
        playingQuietPending: Bool = false
    ) -> Bool {
        Self.shouldArmPostQuietLongHorizonDualAxisEnsure(
            hasCurrentActivity: hasCurrentActivity,
            isRequestEligible: isRequestEligible,
            dualAxisAlreadyArmed: dualAxisAlreadyArmed,
            languageStillLags: languageStillLags,
            visualStillLags: visualStillLags,
            actorVisual: actorVisual,
            isStreamSwitchHoldActive: isStreamSwitchHoldActive,
            isConnectingPlayback: isConnectingPlayback,
            freezeSoftBudgetExhausted: freezeSoftBudgetExhausted,
            playingQuietPending: playingQuietPending
        )
    }

    /// White-box seam: dual-axis long-horizon cancel policy.
    func _test_shouldCancelPostQuietLongHorizonDualAxisEnsure(
        hasCurrentActivity: Bool,
        languageStillLags: Bool,
        visualStillLags: Bool,
        actorVisual: PlayerVisualState
    ) -> Bool {
        Self.shouldCancelPostQuietLongHorizonDualAxisEnsure(
            hasCurrentActivity: hasCurrentActivity,
            languageStillLags: languageStillLags,
            visualStillLags: visualStillLags,
            actorVisual: actorVisual
        )
    }

    /// White-box seam: dual-axis long-horizon exhaust mark policy.
    func _test_shouldMarkDualAxisLongHorizonExhausted(
        languageStillLags: Bool,
        visualStillLags: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        Self.shouldMarkDualAxisLongHorizonExhausted(
            languageStillLags: languageStillLags,
            visualStillLags: visualStillLags,
            isRequestEligible: isRequestEligible
        )
    }

    /// White-box seam: eligible recreate after dual-axis long-horizon exhaust.
    func _test_shouldPreferEligibleRecreateAfterDualAxisLongHorizonExhausted(
        dualAxisExhausted: Bool,
        languageStillLags: Bool,
        visualStillLags: Bool,
        isRequestEligible: Bool,
        recreationsAttempted: Int
    ) -> Bool {
        Self.shouldPreferEligibleRecreateAfterDualAxisLongHorizonExhausted(
            dualAxisExhausted: dualAxisExhausted,
            languageStillLags: languageStillLags,
            visualStillLags: visualStillLags,
            isRequestEligible: isRequestEligible,
            recreationsAttempted: recreationsAttempted
        )
    }

    /// White-box seam: settled dual-axis acceptance (prePlay stick) policy.
    func _test_shouldPushSettledDualAxisAcceptance(
        actorVisual: PlayerVisualState,
        ownedContentVisual: PlayerVisualState?,
        destinationLanguage: String,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool,
        settledAcceptanceConsumed: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        Self.shouldPushSettledDualAxisAcceptance(
            actorVisual: actorVisual,
            ownedContentVisual: ownedContentVisual,
            destinationLanguage: destinationLanguage,
            isStreamSwitchHoldActive: isStreamSwitchHoldActive,
            isConnectingPlayback: isConnectingPlayback,
            settledAcceptanceConsumed: settledAcceptanceConsumed,
            isRequestEligible: isRequestEligible
        )
    }

    /// White-box seam: dual-axis settled consume clear policy.
    func _test_shouldClearDualAxisSettledAcceptanceConsume(
        settledAcceptanceConsumed: Bool,
        ownedOrSystemVisual: PlayerVisualState?
    ) -> Bool {
        Self.shouldClearDualAxisSettledAcceptanceConsume(
            settledAcceptanceConsumed: settledAcceptanceConsumed,
            ownedOrSystemVisual: ownedOrSystemVisual
        )
    }

    /// White-box seam: cancel all long-horizon rails (test sanitization).
    func _test_cancelAllPostQuietLongHorizonEnsure() {
        cancelAllPostQuietLongHorizonEnsure()
        postQuietLongHorizonDualAxisExhausted = false
        dualAxisSettledAcceptanceConsumed = false
    }

    /// White-box seam: optimistic toggle language alignment (no ActivityKit).
    func _test_languageForOptimisticToggleContentAlignment(
        lastPushedLanguage: String?,
        ownedContentLanguage: String?,
        selectedStreamLanguage: String,
        durableLanguageMirror: String?
    ) -> String {
        Self.languageForOptimisticToggleContentAlignment(
            lastPushedLanguage: lastPushedLanguage,
            ownedContentLanguage: ownedContentLanguage,
            selectedStreamLanguage: selectedStreamLanguage,
            durableLanguageMirror: durableLanguageMirror
        )
    }

    /// White-box seam: read settled playing acceptance consume marker (no ActivityKit).
    func _test_playingSettledAcceptanceConsumedValue() -> Bool {
        playingSettledAcceptanceConsumed
    }

    /// White-box seam: set settled playing acceptance consume marker (no ActivityKit).
    func _test_setPlayingSettledAcceptanceConsumed(_ value: Bool) {
        playingSettledAcceptanceConsumed = value
    }

    /// White-box seam: whether soft playing ensure should run (quiet / eligibility).
    func _test_shouldRunPlayingContentEnsureSoftPushes(
        needsPlayingEnsure: Bool,
        quietPending: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        Self.shouldRunPlayingContentEnsureSoftPushes(
            needsPlayingEnsure: needsPlayingEnsure,
            quietPending: quietPending,
            isRequestEligible: isRequestEligible
        )
    }

    /// White-box seam: enter playing quiet after soft budget exhaustion while ineligible.
    func _test_shouldEnterPlayingEnsureQuietPending(
        playingStillStalled: Bool,
        isRequestEligible: Bool,
        ownedContentVisual: PlayerVisualState? = nil,
        isAuthoritativePlayingWithoutHold: Bool = false
    ) -> Bool {
        Self.shouldEnterPlayingEnsureQuietPending(
            playingStillStalled: playingStillStalled,
            isRequestEligible: isRequestEligible,
            ownedContentVisual: ownedContentVisual,
            isAuthoritativePlayingWithoutHold: isAuthoritativePlayingWithoutHold
        )
    }

    /// White-box seam: visual-only playing push defer while quiet (no ActivityKit).
    func _test_shouldDeferRedundantPlayingPushWhileQuiet(
        candidateVisual: PlayerVisualState,
        ownedContentVisual: PlayerVisualState,
        ownedContentLanguage: String,
        candidateLanguage: String,
        quietPending: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        Self.shouldDeferRedundantPlayingPushWhileQuiet(
            candidateVisual: candidateVisual,
            ownedContentVisual: ownedContentVisual,
            ownedContentLanguage: ownedContentLanguage,
            candidateLanguage: candidateLanguage,
            quietPending: quietPending,
            isRequestEligible: isRequestEligible
        )
    }

    /// White-box seam: clear playing quiet after owned visual reaches `.playing`.
    func _test_shouldClearPlayingEnsureQuietPending(
        quietPending: Bool,
        ownedOrSystemVisual: PlayerVisualState?
    ) -> Bool {
        Self.shouldClearPlayingEnsureQuietPending(
            quietPending: quietPending,
            ownedOrSystemVisual: ownedOrSystemVisual
        )
    }

    /// White-box seam: read playing ensure quiet flag (no ActivityKit).
    func _test_playingEnsureQuietPendingValue() -> Bool {
        playingEnsureQuietPending
    }

    /// White-box seam: set playing ensure quiet flag (no ActivityKit).
    func _test_setPlayingEnsureQuietPending(_ value: Bool) {
        playingEnsureQuietPending = value
    }

    /// White-box seam: concurrent soft-ensure collapse (no ActivityKit).
    func _test_shouldStartAuthoritativeContentEnsureSoftPushLoop(
        softPushesAlreadyInFlight: Bool
    ) -> Bool {
        Self.shouldStartAuthoritativeContentEnsureSoftPushLoop(
            softPushesAlreadyInFlight: softPushesAlreadyInFlight
        )
    }

    /// White-box seam: deferred recreation pending mark while request ineligible.
    func _test_shouldMarkPendingEnsureForDeferredRecreation(
        wouldRecreateByStreakCap: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        Self.shouldMarkPendingEnsureForDeferredRecreation(
            wouldRecreateByStreakCap: wouldRecreateByStreakCap,
            isRequestEligible: isRequestEligible
        )
    }

    /// White-box seam: deferred recreation announce-once while request ineligible.
    func _test_shouldAnnounceDeferredInteractiveRecreationWhileIneligible(
        wouldRecreateByStreakCap: Bool,
        isRequestEligible: Bool,
        pendingEnsureAlreadyRecorded: Bool
    ) -> Bool {
        Self.shouldAnnounceDeferredInteractiveRecreationWhileIneligible(
            wouldRecreateByStreakCap: wouldRecreateByStreakCap,
            isRequestEligible: isRequestEligible,
            pendingEnsureAlreadyRecorded: pendingEnsureAlreadyRecorded
        )
    }

    /// White-box seam: stalled content diagnostics signature (rate-limit key).
    func _test_stalledContentDiagnosticsSignature(
        candidateLanguage: String,
        acceptedLanguage: String,
        candidateVisual: PlayerVisualState,
        acceptedVisual: PlayerVisualState
    ) -> String {
        Self.stalledContentDiagnosticsSignature(
            candidateLanguage: candidateLanguage,
            acceptedLanguage: acceptedLanguage,
            candidateVisual: candidateVisual,
            acceptedVisual: acceptedVisual
        )
    }

    /// White-box seam: rate-limit identical stall diagnostics.
    func _test_shouldLogStalledContentDiagnostics(
        signature: String,
        lastLoggedSignature: String?
    ) -> Bool {
        Self.shouldLogStalledContentDiagnostics(
            signature: signature,
            lastLoggedSignature: lastLoggedSignature
        )
    }

    /// White-box seam: quiet-skip DEBUG log once per quiet engagement.
    func _test_shouldLogEnsureQuietSkipOnce(
        softPushesSuppressedByQuiet: Bool,
        alreadyLoggedQuietSkip: Bool
    ) -> Bool {
        Self.shouldLogEnsureQuietSkipOnce(
            softPushesSuppressedByQuiet: softPushesSuppressedByQuiet,
            alreadyLoggedQuietSkip: alreadyLoggedQuietSkip
        )
    }

    /// White-box seam: clear suppress memory between tests (singleton isolation).
    func _test_clearLastPushedContent() {
        cancelInFlightContentPushConfirmation(clearCoalesced: true)
        lastPushedContent = nil
        lastSystemHeldContent = nil
    }

    /// White-box seam for post-update suppress-memory policy (no ActivityKit).
    func _test_suppressMemoryAfterActivityUpdate(
        candidate: LutheranRadioLiveActivityAttributes.ContentState,
        acceptedSystemContent: LutheranRadioLiveActivityAttributes.ContentState
    ) -> LutheranRadioLiveActivityAttributes.ContentState {
        Self.suppressMemoryAfterActivityUpdate(
            candidate: candidate,
            acceptedSystemContent: acceptedSystemContent
        )
    }

    /// White-box seam: whether system-held content still lags the submitted candidate.
    func _test_isStalledLiveActivityContentPush(
        candidate: LutheranRadioLiveActivityAttributes.ContentState,
        accepted: LutheranRadioLiveActivityAttributes.ContentState
    ) -> Bool {
        Self.isStalledLiveActivityContentPush(candidate: candidate, accepted: accepted)
    }

    /// White-box seam: stall streak reset only on non-stalled acceptance.
    func _test_shouldResetStalledContentStreak(
        candidate: LutheranRadioLiveActivityAttributes.ContentState,
        accepted: LutheranRadioLiveActivityAttributes.ContentState
    ) -> Bool {
        Self.shouldResetStalledContentStreak(candidate: candidate, accepted: accepted)
    }

    /// White-box seam: apply-window delay before stall/quiet commit.
    func _test_contentPushApplyConfirmationDelayMilliseconds(isRequestEligible: Bool) -> UInt64 {
        Self.contentPushApplyConfirmationDelayMilliseconds(isRequestEligible: isRequestEligible)
    }

    /// White-box seam: Connecting handshake lag (pause↔prePlay / prePlay↔playing).
    func _test_isConnectingPlayingHandshakeLag(
        candidateLanguage: String,
        acceptedLanguage: String,
        candidateVisual: PlayerVisualState,
        acceptedVisual: PlayerVisualState,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool
    ) -> Bool {
        Self.isConnectingPlayingHandshakeLag(
            candidateLanguage: candidateLanguage,
            acceptedLanguage: acceptedLanguage,
            candidateVisual: candidateVisual,
            acceptedVisual: acceptedVisual,
            isStreamSwitchHoldActive: isStreamSwitchHoldActive,
            isConnectingPlayback: isConnectingPlayback
        )
    }

    /// White-box seam: committed stall observation (not immediate post-await / handshake).
    func _test_shouldCommitStalledContentPushObservation(
        kind: LiveActivityContentPushObservationKind,
        isStalled: Bool,
        isHandshakeLag: Bool
    ) -> Bool {
        Self.shouldCommitStalledContentPushObservation(
            kind: kind,
            isStalled: isStalled,
            isHandshakeLag: isHandshakeLag
        )
    }

    /// White-box seam: start/request disposition (no ActivityKit).
    func _test_interactiveLiveActivityStartDisposition(
        isRequestEligible: Bool,
        hasOwnedActivity: Bool
    ) -> InteractiveLiveActivityStartDisposition {
        Self.interactiveLiveActivityStartDisposition(
            isRequestEligible: isRequestEligible,
            hasOwnedActivity: hasOwnedActivity
        )
    }

    /// White-box seam: soft-ensure inter-attempt delay policy.
    func _test_softEnsureInterAttemptDelayMilliseconds(
        attempt: Int,
        maxAttempts: Int,
        isRequestEligible: Bool
    ) -> UInt64? {
        Self.softEnsureInterAttemptDelayMilliseconds(
            attempt: attempt,
            maxAttempts: maxAttempts,
            isRequestEligible: isRequestEligible
        )
    }

    /// White-box seam: true language-new partial acceptance re-arms playing ensure.
    func _test_shouldRearmPlayingEnsureAfterPartialLanguageAcceptance(
        candidateLanguage: String,
        acceptedLanguage: String,
        candidateVisual: PlayerVisualState,
        acceptedVisual: PlayerVisualState,
        preUpdateOwnedLanguage: String
    ) -> Bool {
        Self.shouldRearmPlayingEnsureAfterPartialLanguageAcceptance(
            candidateLanguage: candidateLanguage,
            acceptedLanguage: acceptedLanguage,
            candidateVisual: candidateVisual,
            acceptedVisual: acceptedVisual,
            preUpdateOwnedLanguage: preUpdateOwnedLanguage
        )
    }

    /// White-box seam: true visual-new partial acceptance re-arms language ensure.
    func _test_shouldRearmLanguageEnsureAfterPartialVisualAcceptance(
        candidateLanguage: String,
        acceptedLanguage: String,
        candidateVisual: PlayerVisualState,
        acceptedVisual: PlayerVisualState,
        preUpdateOwnedVisual: PlayerVisualState
    ) -> Bool {
        Self.shouldRearmLanguageEnsureAfterPartialVisualAcceptance(
            candidateLanguage: candidateLanguage,
            acceptedLanguage: acceptedLanguage,
            candidateVisual: candidateVisual,
            acceptedVisual: acceptedVisual,
            preUpdateOwnedVisual: preUpdateOwnedVisual
        )
    }

    /// White-box seam: language newly converged this update.
    func _test_didLanguageNewlyConverge(
        preUpdateOwnedLanguage: String,
        acceptedLanguage: String,
        candidateLanguage: String
    ) -> Bool {
        Self.didLanguageNewlyConverge(
            preUpdateOwnedLanguage: preUpdateOwnedLanguage,
            acceptedLanguage: acceptedLanguage,
            candidateLanguage: candidateLanguage
        )
    }

    /// White-box seam: partial quiet-clear gate under freeze soft-budget exhaust.
    func _test_shouldClearPlayingEnsureQuietForPartialRearm(
        shouldRearmFromPartialPolicy: Bool,
        freezeSoftBudgetExhausted: Bool,
        partialPostSettledAlreadyScheduled: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        Self.shouldClearPlayingEnsureQuietForPartialRearm(
            shouldRearmFromPartialPolicy: shouldRearmFromPartialPolicy,
            freezeSoftBudgetExhausted: freezeSoftBudgetExhausted,
            partialPostSettledAlreadyScheduled: partialPostSettledAlreadyScheduled,
            isRequestEligible: isRequestEligible
        )
    }

    /// White-box seam: post-settled after soft-budget exhaust (playing).
    func _test_shouldSchedulePostSettledPlayingEnsureAfterSoftBudgetExhaust(
        baseShouldSchedule: Bool,
        isRequestEligible: Bool,
        languageNewlyConvergedThisFreeze: Bool,
        partialPostSettledAlreadyScheduled: Bool
    ) -> Bool {
        Self.shouldSchedulePostSettledPlayingEnsureAfterSoftBudgetExhaust(
            baseShouldSchedule: baseShouldSchedule,
            isRequestEligible: isRequestEligible,
            languageNewlyConvergedThisFreeze: languageNewlyConvergedThisFreeze,
            partialPostSettledAlreadyScheduled: partialPostSettledAlreadyScheduled
        )
    }

    /// White-box seam: eligible recreate after freeze soft-budget / dual-axis exhaust.
    func _test_shouldPreferEligibleRecreateAfterContentEnsureFreezeExhausted(
        freezeSoftBudgetExhausted: Bool,
        dualAxisExhausted: Bool,
        languageStillLags: Bool,
        visualStillLags: Bool,
        isRequestEligible: Bool,
        recreationsAttempted: Int = 0
    ) -> Bool {
        Self.shouldPreferEligibleRecreateAfterContentEnsureFreezeExhausted(
            freezeSoftBudgetExhausted: freezeSoftBudgetExhausted,
            dualAxisExhausted: dualAxisExhausted,
            languageStillLags: languageStillLags,
            visualStillLags: visualStillLags,
            isRequestEligible: isRequestEligible,
            recreationsAttempted: recreationsAttempted
        )
    }

    /// White-box seam: whether delayed re-read / `contentUpdates` run axis-heal.
    func _test_shouldApplySystemContentUpdateHealAfterObservation(
        kind: LiveActivityContentPushObservationKind
    ) -> Bool {
        Self.shouldApplySystemContentUpdateHealAfterObservation(kind: kind)
    }

    /// White-box seam: same-stream ineligible resume must not push Connecting over
    /// committed paused/playing. Stream-switch hold still Connecting.
    func _test_shouldSuppressConnectingContentPushWhileIneligible(
        isRequestEligible: Bool,
        isStreamSwitchHoldActive: Bool,
        ownedVisual: PlayerVisualState,
        candidateVisual: PlayerVisualState
    ) -> Bool {
        Self.shouldSuppressConnectingContentPushWhileIneligible(
            isRequestEligible: isRequestEligible,
            isStreamSwitchHoldActive: isStreamSwitchHoldActive,
            ownedVisual: ownedVisual,
            candidateVisual: candidateVisual
        )
    }

    /// White-box seam: one outstanding visual mutation while apply is in-flight.
    func _test_shouldCoalesceVisualDifferingContentPushWhileInFlight(
        inFlightVisual: PlayerVisualState?,
        candidateVisual: PlayerVisualState,
        ownedVisual: PlayerVisualState,
        languageOnlyPreservingOwnedVisual: Bool = false
    ) -> Bool {
        Self.shouldCoalesceVisualDifferingContentPushWhileInFlight(
            inFlightVisual: inFlightVisual,
            candidateVisual: candidateVisual,
            ownedVisual: ownedVisual,
            languageOnlyPreservingOwnedVisual: languageOnlyPreservingOwnedVisual
        )
    }

    /// White-box seam: flush coalesced candidate after committed observation.
    func _test_shouldFlushCoalescedContentPushAfterObservation(
        coalesced: LutheranRadioLiveActivityAttributes.ContentState?,
        observed: LutheranRadioLiveActivityAttributes.ContentState
    ) -> Bool {
        Self.shouldFlushCoalescedContentPushAfterObservation(
            coalesced: coalesced,
            observed: observed
        )
    }

    /// White-box seam: `contentUpdates` yield diagnostics signature (rate-limit key).
    func _test_contentUpdatesYieldDiagnosticsSignature(
        systemLanguage: String,
        systemVisual: PlayerVisualState,
        activityId: String
    ) -> String {
        Self.contentUpdatesYieldDiagnosticsSignature(
            systemLanguage: systemLanguage,
            systemVisual: systemVisual,
            activityId: activityId
        )
    }

    /// White-box seam: axis-scoped contentUpdates / delayed re-read heal policy.
    func _test_contentUpdateAxisHealPolicy(
        systemLanguage: String,
        systemVisual: PlayerVisualState,
        destinationLanguage: String,
        actorVisual: PlayerVisualState,
        isStreamSwitchHoldActive: Bool,
        isConnectingPlayback: Bool,
        priorObservedLanguage: String? = nil,
        priorObservedVisual: PlayerVisualState? = nil
    ) -> ContentUpdateAxisHealPolicy {
        Self.contentUpdateAxisHealPolicy(
            systemLanguage: systemLanguage,
            systemVisual: systemVisual,
            destinationLanguage: destinationLanguage,
            actorVisual: actorVisual,
            isStreamSwitchHoldActive: isStreamSwitchHoldActive,
            isConnectingPlayback: isConnectingPlayback,
            priorObservedLanguage: priorObservedLanguage,
            priorObservedVisual: priorObservedVisual
        )
    }

    /// White-box seam: recreate decision after a stalled content-push streak (streak/cap only).
    func _test_shouldRecreateInteractiveLiveActivityAfterStalledPushes(
        consecutiveStalled: Int,
        recreationsAttempted: Int,
        threshold: Int = RadioLiveActivityManager.stalledContentPushRecreationThreshold,
        maxRecreations: Int = RadioLiveActivityManager.maxInteractiveContentRecreations,
        isRecreationInProgress: Bool
    ) -> Bool {
        Self.shouldRecreateInteractiveLiveActivityAfterStalledPushes(
            consecutiveStalled: consecutiveStalled,
            recreationsAttempted: recreationsAttempted,
            threshold: threshold,
            maxRecreations: maxRecreations,
            isRecreationInProgress: isRecreationInProgress
        )
    }

    /// White-box seam: end+request only when request is eligible (never end under visibility failure).
    func _test_shouldPerformStalledContentRecreation(
        consecutiveStalled: Int,
        recreationsAttempted: Int,
        isRecreationInProgress: Bool,
        isRequestEligible: Bool,
        threshold: Int = RadioLiveActivityManager.stalledContentPushRecreationThreshold,
        maxRecreations: Int = RadioLiveActivityManager.maxInteractiveContentRecreations
    ) -> Bool {
        Self.shouldPerformStalledContentRecreation(
            consecutiveStalled: consecutiveStalled,
            recreationsAttempted: recreationsAttempted,
            isRecreationInProgress: isRecreationInProgress,
            isRequestEligible: isRequestEligible,
            threshold: threshold,
            maxRecreations: maxRecreations
        )
    }

    /// White-box seam: interactive `Activity.request` eligibility (enabled + application active).
    func _test_isInteractiveLiveActivityRequestEligible(
        areActivitiesEnabled: Bool,
        isApplicationActive: Bool
    ) -> Bool {
        Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: areActivitiesEnabled,
            isApplicationActive: isApplicationActive
        )
    }

    /// White-box seam: pending ensure after a failed start when ownership is empty.
    func _test_shouldMarkPendingInteractiveLiveActivityEnsureAfterStartAttempt(
        currentActivityIsNil: Bool
    ) -> Bool {
        Self.shouldMarkPendingInteractiveLiveActivityEnsureAfterStartAttempt(
            currentActivityIsNil: currentActivityIsNil
        )
    }

    /// White-box seam: foreground ensure-start policy (no ActivityKit).
    func _test_shouldEnsureInteractiveLiveActivityStart(
        pendingEnsure: Bool,
        hasCurrentActivity: Bool,
        sessionNeedsInteractiveLiveActivity: Bool,
        areActivitiesEnabled: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        Self.shouldEnsureInteractiveLiveActivityStart(
            pendingEnsure: pendingEnsure,
            hasCurrentActivity: hasCurrentActivity,
            sessionNeedsInteractiveLiveActivity: sessionNeedsInteractiveLiveActivity,
            areActivitiesEnabled: areActivitiesEnabled,
            isRequestEligible: isRequestEligible
        )
    }

    /// White-box seam: session-needs policy for interactive LA ensure/start.
    func _test_sessionNeedsInteractiveLiveActivity(
        isPlaying: Bool,
        visualState: PlayerVisualState
    ) -> Bool {
        Self.sessionNeedsInteractiveLiveActivity(
            isPlaying: isPlaying,
            visualState: visualState
        )
    }

    /// White-box seam: read pending ensure flag (no ActivityKit).
    func _test_pendingInteractiveLiveActivityEnsure() -> Bool {
        pendingInteractiveLiveActivityEnsure
    }

    /// White-box seam: set pending ensure flag (no ActivityKit).
    func _test_setPendingInteractiveLiveActivityEnsure(_ value: Bool) {
        pendingInteractiveLiveActivityEnsure = value
    }

    /// White-box seam: owned-surface foreground soft-ensure decision (no ActivityKit).
    func _test_shouldEnsureAuthoritativeContentOnForeground(
        hasCurrentActivity: Bool,
        destinationLanguage: String,
        ownedContentLanguage: String?,
        lastPushedLanguage: String?,
        actorVisual: PlayerVisualState,
        streamSwitchHold: Bool,
        isConnectingPlayback: Bool,
        lastPushedVisual: PlayerVisualState?,
        ownedVisual: PlayerVisualState?
    ) -> Bool {
        Self.shouldEnsureAuthoritativeContentOnForeground(
            hasCurrentActivity: hasCurrentActivity,
            destinationLanguage: destinationLanguage,
            ownedContentLanguage: ownedContentLanguage,
            lastPushedLanguage: lastPushedLanguage,
            actorVisual: actorVisual,
            streamSwitchHold: streamSwitchHold,
            isConnectingPlayback: isConnectingPlayback,
            lastPushedVisual: lastPushedVisual,
            ownedVisual: ownedVisual
        )
    }

    /// White-box seam: owned-surface foreground invoke / debounce policy (no ActivityKit).
    func _test_shouldInvokeOwnedSurfaceForegroundEnsure(
        hasCurrentActivity: Bool,
        lastOwnedSurfaceForegroundEnsureAt: Date?,
        now: Date,
        debounceInterval: TimeInterval = RadioLiveActivityManager.ownedSurfaceForegroundEnsureDebounceInterval,
        languageEnsureQuietPending: Bool,
        playingEnsureQuietPending: Bool,
        pendingInteractiveLiveActivityEnsure: Bool,
        contentEnsureStillNeeded: Bool,
        isRequestEligible: Bool
    ) -> Bool {
        Self.shouldInvokeOwnedSurfaceForegroundEnsure(
            hasCurrentActivity: hasCurrentActivity,
            lastOwnedSurfaceForegroundEnsureAt: lastOwnedSurfaceForegroundEnsureAt,
            now: now,
            debounceInterval: debounceInterval,
            languageEnsureQuietPending: languageEnsureQuietPending,
            playingEnsureQuietPending: playingEnsureQuietPending,
            pendingInteractiveLiveActivityEnsure: pendingInteractiveLiveActivityEnsure,
            contentEnsureStillNeeded: contentEnsureStillNeeded,
            isRequestEligible: isRequestEligible
        )
    }

    /// White-box seam: eligible-only recreation after foreground soft ensure still fails.
    func _test_shouldRecreateAfterForegroundSoftEnsureFailed(
        languageStillMismatches: Bool,
        playingStillStalled: Bool,
        isRequestEligible: Bool,
        recreationsAttempted: Int,
        maxRecreations: Int = RadioLiveActivityManager.maxInteractiveContentRecreations
    ) -> Bool {
        Self.shouldRecreateAfterForegroundSoftEnsureFailed(
            languageStillMismatches: languageStillMismatches,
            playingStillStalled: playingStillStalled,
            isRequestEligible: isRequestEligible,
            recreationsAttempted: recreationsAttempted,
            maxRecreations: maxRecreations
        )
    }

    /// White-box seam: playing reconcile decision (Connecting / pause stuck → playing).
    func _test_shouldEnsureAuthoritativePlayingContent(
        actorVisual: PlayerVisualState,
        streamSwitchHold: Bool,
        isConnectingPlayback: Bool,
        lastPushedVisual: PlayerVisualState?,
        ownedVisual: PlayerVisualState?
    ) -> Bool {
        Self.shouldEnsureAuthoritativePlayingContent(
            actorVisual: actorVisual,
            streamSwitchHold: streamSwitchHold,
            isConnectingPlayback: isConnectingPlayback,
            lastPushedVisual: lastPushedVisual,
            ownedVisual: ownedVisual
        )
    }

    /// Enables termination self-healing coverage in RadioLiveActivityManagerTests without
    /// creating a real ``Activity``.
    func _test_setHarnessSimulatesActiveActivity(_ simulates: Bool) {
        _test_harnessSimulatesActiveActivity = simulates
    }

    /// Cancels synthetic attribute-events observation through the consolidated observer.
    ///
    /// Mirrors the cancellation path in ``endActivity(dismissalPolicy:waitForSystemCompletion:)``
    /// without clearing ``currentActivity`` / ``lastPushedContent`` upfront so termination
    /// hygiene can be asserted in isolation.
    func _test_cancelAttributeEventObservation() {
        activityEventObserver.cancel()
        activityObservationTask = nil
    }

    /// Pure final-end ContentState assembly for white-box tests (no ActivityKit IPC).
    ///
    /// Mirrors production language/metadata priority in ``prepareLocalLiveActivityEndState()``:
    /// last-pushed → owned activity content → residual system content (cold-launch reaping) →
    /// fallback language. Visual is always `.userPaused` so the final frame never claims live
    /// audio after the owning process leaves.
    ///
    /// - Parameters:
    ///   - lastPushed: Simulated ``lastPushedContent``.
    ///   - activityState: Simulated `currentActivity?.content.state`.
    ///   - residualState: Simulated residual system `Activity.content.state` (force-quit leftover
    ///     when local tracking is empty). Defaults to `nil`.
    ///   - fallbackLanguage: Stand-in for ``SharedPlayerManager/mainAppLiveActivityLanguageCode()``.
    /// - Returns: The ContentState that would be pushed immediately before `Activity.end`.
    /// - SeeAlso: ``endActivity(dismissalPolicy:waitForSystemCompletion:)``,
    ///   ``handleAppWillTerminate()``, ``observeExistingActivities()``,
    ///   RadioLiveActivityManagerTests.
    func _test_finalEndContentState(
        lastPushed: LutheranRadioLiveActivityAttributes.ContentState?,
        activityState: LutheranRadioLiveActivityAttributes.ContentState?,
        residualState: LutheranRadioLiveActivityAttributes.ContentState? = nil,
        fallbackLanguage: String
    ) -> LutheranRadioLiveActivityAttributes.ContentState {
        let language =
            lastPushed?.currentLanguage
            ?? activityState?.currentLanguage
            ?? residualState?.currentLanguage
            ?? fallbackLanguage
        let metadata =
            lastPushed?.streamMetadata
            ?? activityState?.streamMetadata
            ?? residualState?.streamMetadata
        return LutheranRadioLiveActivityAttributes.ContentState(
            visualState: .userPaused,
            streamMetadata: metadata,
            currentLanguage: language
        )
    }

    /// Cold-launch residual reaping policy seam (no ActivityKit IPC).
    ///
    /// - Parameters:
    ///   - systemActivityIds: Simulated `Activity.activities` ids.
    ///   - ownedActivityId: Simulated ``currentActivity`` id, or `nil` when unowned.
    /// - Returns: Ids production would end (all when unowned; siblings only when owned).
    /// - SeeAlso: ``systemResidualIdsToReap(systemActivityIds:ownedActivityId:)``,
    ///   ``observeExistingActivities()``, ``reapUnownedSystemResiduals(preservingOwnedActivityId:)``,
    ///   RadioLiveActivityManagerTests.
    func _test_systemResidualIdsToReap(
        systemActivityIds: [String],
        ownedActivityId: String?
    ) -> [String] {
        Self.systemResidualIdsToReap(
            systemActivityIds: systemActivityIds,
            ownedActivityId: ownedActivityId
        )
    }

    /// Whether deferred observe uses full ``endActivity`` (clears ownership) vs sibling-only reaping.
    ///
    /// - Parameter hasOwnedCurrentActivity: Whether this process already holds ``currentActivity``.
    /// - Returns: `true` when full residual end runs (no ownership); `false` when only unowned
    ///   siblings are reaped while ownership is preserved.
    /// - SeeAlso: ``observeExistingActivities()``, RadioLiveActivityManagerTests.
    func _test_shouldUseFullResidualEnd(hasOwnedCurrentActivity: Bool) -> Bool {
        !hasOwnedCurrentActivity
    }
    #endif

    /// Begins observation of the supplied activity's attribute events stream
    /// (`contentUpdates`).
    ///
    /// This is ActivityKit's events surface for `LutheranRadioLiveActivityAttributes.ContentState`.
    /// On each yielded `ActivityContent` we record `.state` into `lastPushedContent`
    /// so the manager's diff check in `updateCurrentActivity` uses the exact
    /// value the Live Activity surface last rendered.
    ///
    /// - Parameters:
    ///   - activity: The live `Activity<LutheranRadioLiveActivityAttributes>`
    ///     instance whose attribute updates we will consume.
    /// - Precondition: Must be invoked on the main actor.
    /// - Postcondition: `activityObservationTask` holds a live task that will
    ///   run until cancelled. Any prior observation task is cancelled first.
    /// - Important: The yielded `contentState` is used to keep
    ///   `lastPushedContent` authoritative. Terminal states trigger local
    ///   cleanup so that `currentActivity` never points at a surface the system
    ///   has already dismissed.
    /// - Note: This is the concrete implementation of the "events stream
    ///   optimization" for Live Activities. It is additive; the existing
    ///   diff-driven `updateCurrentActivity` contract and all call sites from
    ///   `SharedPlayerManager` and coordinators are unchanged.
    /// - SeeAlso: ``activityObservationTask``, ``updateCurrentActivity()``,
    ///   ``lastPushedContent``, `endActivity(dismissalPolicy:)`,
    ///   docs/Widget-Presentation-Dataflow.md (Live Activity Attribute Events
    ///   Observation), docs/Event-Driven-Refactor-Roadmap.md,
    ///   ``observeExistingActivities()``, ``startActivity()``,
    ///   `WidgetEventObserver`.
    private func beginObservingActivityEvents(_ activity: Activity<LutheranRadioLiveActivityAttributes>) {
        // SAFETY: ActivityKit's contentUpdates is the attribute events surface
        // yielding ActivityContent<ContentState>. The sequence is not Sendable;
        // we extract under nonisolated(unsafe) on the main-actor call site
        // (see established patterns for framework interop in this project:
        // DNS C callbacks, AVFoundation delegates). The helper performs the
        // iteration; terminal handling is supplied via onTermination so that
        // opportunistic cleanup occurs exactly as before.
        nonisolated(unsafe) let contentUpdates = activity.contentUpdates

        // Delegate to the consolidated `WidgetEventObserver`. The per-element
        // work and terminal hygiene are identical to the prior direct Task.
        // The resulting task is published back into the seam property.
        // The concrete Activity contentUpdates sequence is not Sendable; the
        // unsafe overload + unsafe expression + nonisolated(unsafe) let at
        // materialization satisfy the bridge (consistent with prior direct code).
        activityEventObserver.beginObserving(
            unsafeSequence: unsafe contentUpdates,
            onElement: { [weak self] content in
                self?.handleActivityContentUpdate(content)
            },
            onTermination: { [weak self] in
                self?.performAttributeObservationTerminationHygiene()
            }
        )
        publishActivityObservationTask()
    }
}

// MARK: - App Lifecycle Integration (Privacy-Safe)

extension RadioLiveActivityManager {
    /// Called by SceneDelegate / AppDelegate when the scene enters background.
    ///
    /// Starts a Live Activity (if we are actively playing and none exists) so that
    /// the user has lock-screen / Dynamic Island controls while audio continues in
    /// the background.
    ///
    /// The started activity receives its initial content via the normal event-driven
    /// path inside `startActivity` → `updateCurrentActivity`. No fallback timer is
    /// started.
    ///
    /// Under DEBUG test runs we early-return before inspecting state or scheduling
    /// the async start, for defense-in-depth alongside the guards in startActivity.
    ///
    /// - SeeAlso: SceneDelegate.sceneDidEnterBackground, ``isRunningUnderTest``
    func handleAppWillEnterBackground() {
        // Defense-in-depth: never start Live Activities from background transitions under test.
        if SharedPlayerManager.isRunningInUITestMode { return }
        if SharedPlayerManager.isRunningAsIOSAppOnMac { return }

        #if DEBUG
        if isRunningUnderTest { return }
        #endif

        // Auto-start Live Activity when backgrounding with audio.
        // Subsequent ICY metadata or visual changes will push via the decoupled path.
        let manager = SharedPlayerManager.shared
        let state = manager.loadSharedState()
        
        if state.isPlaying && currentActivity == nil {
            Task {   // ← wrap in Task because startActivity is now async
                await startActivity()
            }
        }
    }
    
    /// Called on foreground transitions.
    ///
    /// 1. Ensures an interactive Live Activity when pending after a deferred recreation /
    ///    failed request, or when the session still needs chrome and none is owned.
    /// 2. When ownership is already non-nil, runs soft language + playing ensure (and
    ///    eligible-only recreation if soft ensure still fails) via
    ///    ``ensureAuthoritativeContentOnForegroundIfNeeded()`` inside
    ///    ``ensureInteractiveLiveActivityIfNeeded()``.
    /// 3. Pushes the current SSOT visual state so that any remaining stale LA content
    ///    (e.g. after a long background period) is corrected before the user sees it.
    ///
    /// Under DEBUG test runs we early-return to avoid even scheduling the no-op
    /// `updateCurrentActivity` Task.
    ///
    /// - SeeAlso: ``isRunningUnderTest``, ``ensureInteractiveLiveActivityIfNeeded()``,
    ///   ``ensureAuthoritativeContentOnForegroundIfNeeded()``,
    ///   ``handleAppWillEnterBackground()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    func handleAppDidEnterForeground() {
        // Defense-in-depth: suppress foreground LA pushes under UITestMode.
        if SharedPlayerManager.isRunningInUITestMode { return }
        if SharedPlayerManager.isRunningAsIOSAppOnMac { return }

        #if DEBUG
        if isRunningUnderTest { return }
        #endif

        Task { @MainActor in
            await ensureInteractiveLiveActivityIfNeeded()
            await updateCurrentActivity()
        }
    }

    /// Debounced foreground ensure: start an interactive Live Activity when session policy
    /// needs one and none is owned (including after a deferred recreation or failed request);
    /// when ownership is already non-nil, soft-reconcile language/visual chrome and optionally
    /// recreate when request-eligible after soft ensure still fails.
    ///
    /// **Why:** `Activity.request` can fail with a visibility-class error while the process
    /// remains lock-screen / background driven. Ending the only interactive surface then leaves
    /// permanent absence until a later start succeeds. Recording
    /// ``pendingInteractiveLiveActivityEnsure`` and retrying on become-active restores the card
    /// without inventing playback. Separately, an **owned** surface may still hold prior-stream
    /// language/visual after deferred recreation while ineligible — soft
    /// ``ensureAuthoritativeContentOnForegroundIfNeeded()`` repairs that without a second SSOT.
    /// Dual SceneDelegate hooks (will-enter-foreground + become-active) are debounced for the
    /// owned-surface path via ``shouldInvokeOwnedSurfaceForegroundEnsure`` while still
    /// consuming language/playing quiet and pending ensure on unlock.
    ///
    /// - Precondition: Main actor; not UITestMode / under-test (callers and this method guard).
    /// - Postcondition: At most one start attempt per debounce window when unowned; when owned,
    ///   at most one soft language/playing ensure cycle per owned-surface debounce window
    ///   unless quiet/pending force consume or chrome still lags while request-eligible;
    ///   pending cleared when ownership is restored, owned soft ensure runs, or the session
    ///   no longer needs interactive chrome.
    /// - Important: Does not stack multiple interactive activities — owned surfaces update
    ///   only; residual siblings before a true new request end with ``.immediate``. Does not
    ///   end the only interactive surface while request is ineligible. Does not bypass
    ///   privacy write suppression.
    /// - SeeAlso: ``startActivity()``, ``handleAppDidEnterForeground()``,
    ///   ``ensureAuthoritativeContentOnForegroundIfNeeded()``,
    ///   ``shouldInvokeOwnedSurfaceForegroundEnsure(hasCurrentActivity:lastOwnedSurfaceForegroundEnsureAt:now:debounceInterval:languageEnsureQuietPending:playingEnsureQuietPending:pendingInteractiveLiveActivityEnsure:contentEnsureStillNeeded:isRequestEligible:)``,
    ///   ``shouldEnsureInteractiveLiveActivityStart(pendingEnsure:hasCurrentActivity:sessionNeedsInteractiveLiveActivity:areActivitiesEnabled:isRequestEligible:)``,
    ///   ``sessionNeedsInteractiveLiveActivity(isPlaying:visualState:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    @MainActor
    func ensureInteractiveLiveActivityIfNeeded() async {
        if SharedPlayerManager.isRunningInUITestMode { return }
        if SharedPlayerManager.isRunningAsIOSAppOnMac { return }
        #if DEBUG
        if isRunningUnderTest { return }
        #endif

        // Owned surface: independent of missing-card start debounce. Dual SceneDelegate hooks
        // still reconcile chrome after unlock, but ``shouldInvokeOwnedSurfaceForegroundEnsure``
        // consumes quiet/pending without re-burning soft budgets on every resign/become thrash.
        if currentActivity != nil {
            let manager = SharedPlayerManager.shared
            let destination = await manager.liveActivityLanguageCodeForContentPush()
            let ownedLanguage = currentActivity?.content.state.currentLanguage
            let lastLanguage = lastPushedContent?.currentLanguage
            let visual = await manager.currentVisualState
            let hold = await manager.isStreamSwitchPrePlayHoldActive
            let connecting = await manager.isConnectingPlayback
            let lastVisual = lastPushedContent?.visualState
            let ownedVisual = currentActivity?.content.state.visualState
            let contentStillNeeded = Self.shouldEnsureAuthoritativeContentOnForeground(
                hasCurrentActivity: true,
                destinationLanguage: destination,
                ownedContentLanguage: ownedLanguage,
                lastPushedLanguage: lastLanguage,
                actorVisual: visual,
                streamSwitchHold: hold,
                isConnectingPlayback: connecting,
                lastPushedVisual: lastVisual,
                ownedVisual: ownedVisual
            )
            let requestEligible = Self.isInteractiveLiveActivityRequestEligible(
                areActivitiesEnabled: Self.areActivitiesEnabledOnThisHost,
                isApplicationActive: UIApplication.shared.applicationState == .active
            )
            let shouldInvoke = Self.shouldInvokeOwnedSurfaceForegroundEnsure(
                hasCurrentActivity: true,
                lastOwnedSurfaceForegroundEnsureAt: lastOwnedSurfaceForegroundEnsureAt,
                now: Date(),
                debounceInterval: Self.ownedSurfaceForegroundEnsureDebounceInterval,
                languageEnsureQuietPending: languageEnsureQuietPendingDestination != nil,
                playingEnsureQuietPending: playingEnsureQuietPending,
                pendingInteractiveLiveActivityEnsure: pendingInteractiveLiveActivityEnsure,
                contentEnsureStillNeeded: contentStillNeeded,
                isRequestEligible: requestEligible
            )
            guard shouldInvoke else {
                #if DEBUG
                print(
                    "🔴 Live Activity owned-surface foreground ensure debounced " +
                    "(quietLang=\(languageEnsureQuietPendingDestination ?? "nil") " +
                    "quietPlay=\(playingEnsureQuietPending) pending=\(pendingInteractiveLiveActivityEnsure) " +
                    "contentNeeded=\(contentStillNeeded) eligible=\(requestEligible))"
                )
                #endif
                return
            }
            lastOwnedSurfaceForegroundEnsureAt = Date()
            // Consume missing-card / soft-exhaust pending; owned soft ensure is the recovery rail.
            pendingInteractiveLiveActivityEnsure = false
            await ensureAuthoritativeContentOnForegroundIfNeeded()
            return
        }

        if let last = lastInteractiveLiveActivityEnsureAt,
           Date().timeIntervalSince(last) < Self.interactiveLiveActivityEnsureDebounceInterval {
            return
        }

        let activitiesEnabled = Self.areActivitiesEnabledOnThisHost
        let requestEligible = Self.isInteractiveLiveActivityRequestEligible(
            areActivitiesEnabled: activitiesEnabled,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )

        let manager = SharedPlayerManager.shared
        let isPlaying = manager.loadSharedState().isPlaying
        let visualState = await manager.currentVisualState
        let sessionNeeds = Self.sessionNeedsInteractiveLiveActivity(
            isPlaying: isPlaying,
            visualState: visualState
        )

        if !sessionNeeds {
            // Stop / teardown while pending: drop the recovery flag without requesting.
            pendingInteractiveLiveActivityEnsure = false
            return
        }

        guard Self.shouldEnsureInteractiveLiveActivityStart(
            pendingEnsure: pendingInteractiveLiveActivityEnsure,
            hasCurrentActivity: currentActivity != nil,
            sessionNeedsInteractiveLiveActivity: sessionNeeds,
            areActivitiesEnabled: activitiesEnabled,
            isRequestEligible: requestEligible
        ) else {
            return
        }

        lastInteractiveLiveActivityEnsureAt = Date()
        #if DEBUG
        print(
            "🔴 Live Activity ensure-start (pending=\(pendingInteractiveLiveActivityEnsure) " +
            "sessionNeeds=\(sessionNeeds))"
        )
        #endif
        await startActivity()
    }
    
    /// Called on process termination paths (AppDelegate, SceneDelegate disconnect,
    /// and `willTerminateNotification`).
    ///
    /// Ends every system-held Live Activity with `.immediate` dismissal and **waits**
    /// (bounded) for ActivityKit to accept the final `.userPaused` ContentState + end.
    /// Without the wait, process exit races the unstructured end Task and Dynamic Island
    /// / Lock Screen keep a stale interactive frame (often still `.playing`).
    ///
    /// Force-quit and OOM still bypass this callback; residual surfaces are reaped on the
    /// next cold launch via ``observeExistingActivities()``.
    ///
    /// - Cleanup Invariant: After a delivered termination callback returns, no interactive
    ///   Live Activity for this app should remain that ActivityKit can treat as live.
    ///   Widgets fall back to passive "tap to open" via the staled liveness sentinel.
    /// - SeeAlso: ``endActivity(dismissalPolicy:waitForSystemCompletion:)``,
    ///   ``observeExistingActivities()``, AppDelegate.applicationWillTerminate,
    ///   SceneDelegate.sceneDidDisconnect,
    ///   SharedPlayerManager.performSessionTeardownSynchronouslyForTermination,
    ///   docs/Widget-Presentation-Dataflow.md.
    func handleAppWillTerminate() {
        endActivity(dismissalPolicy: .immediate, waitForSystemCompletion: true)
    }
}
