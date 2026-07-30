//
//  WidgetIntentExecution.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 23.7.2026.
//
//  SHARED: Cross-target membership-exception source (main app + extension +
//  LutheranRadioWidgetTests). AppIntent perform SSOT and side effects via
//  SharedPlayerManager + WidgetRefreshManager.
//
//  Planning (pure mapping) lives in WidgetIntentCoordinators (WidgetSurface).
//  Snapshot hygiene / Provider assembly live in WidgetDisplayModels.swift.
//
//  Mechanical split from WidgetDisplayModels.swift — no API renames, no behavior change.
//
//  - SeeAlso: WidgetDisplayModels.swift, WidgetIntentCoordinators,
//    docs/Widget-Functionality-Roadmap.md, CODING_AGENT.md (cross-target membership exceptions).
//

// SAFETY: ActivityKit's `Activity` is not Sendable; optimistic ContentState pushes from
// lock-screen intents use `nonisolated(unsafe)` + `unsafe await activity.update` with a
// local strong capture (same boundary as RadioLiveActivityManager). Prefer
// `@unsafe @preconcurrency` over bare `@preconcurrency` under SWIFT_STRICT_MEMORY_SAFETY.
@unsafe @preconcurrency import ActivityKit
import Foundation
import WidgetSurface

// MARK: - Intent execution (cross-target SSOT)

/// Executes widget intent plans that require ``SharedPlayerManager`` and ``WidgetRefreshManager``.
///
/// Planning (pure mapping) lives in ``WidgetIntentCoordinators`` (WidgetSurface).
/// Extension `perform()` bodies and extension-profile unit tests both call the
/// ``perform*`` entry points so AppIntent side effects have a single compile-time SSOT
/// under the extension compile profile (no `LUTHERAN_MAIN_APP`).
///
/// - SeeAlso: ``WidgetIntentCoordinators``, docs/Widget-Functionality-Roadmap.md,
///   docs/Widget-Presentation-Dataflow.md.
enum WidgetIntentExecution {

    // MARK: - AppIntent perform entry points (extension `perform()` + tests)

    /// Full home-widget toggle path used by ``WidgetToggleRadioIntent/perform()``.
    ///
    /// Resolves the optimistic plan from the persisted visual snapshot, picks language
    /// for the optimistic write, then runs ``executeOptimisticToggle(plan:language:)``.
    ///
    /// - SeeAlso: ``WidgetIntentCoordinators/planHomeWidgetToggle(from:)``,
    ///   ``WidgetIntentCoordinators/languageForOptimisticUpdate(persistedLanguage:preferredLanguage:)``.
    static func performHomeWidgetToggle() async {
        let visualState = SharedPlayerManager.loadPersistedVisualStateDirect()
        let plan = WidgetIntentCoordinators.planHomeWidgetToggle(from: visualState)
        // Thermal refuse keeps chrome authoritative — no optimistic flip, no pending drain.
        guard plan.shouldExecutePendingAction else { return }
        let language = WidgetIntentCoordinators.languageForOptimisticUpdate(
            persistedLanguage: SharedPlayerManager.loadPersistedWidgetState()?.currentLanguage,
            preferredLanguage: SharedPlayerManager.preferredWidgetLanguage()
        )
        await executeOptimisticToggle(plan: plan, language: language)
    }

    /// Full Control Center toggle path used by ``ToggleRadioIntent/perform()``.
    ///
    /// - Parameter isPlayingRequested: `true` = play, `false` = pause (ControlWidgetToggle value).
    /// - SeeAlso: ``WidgetIntentCoordinators/planControlWidgetToggle(isPlayingRequested:)``.
    static func performControlWidgetToggle(isPlayingRequested: Bool) async {
        Task { @MainActor in WidgetRefreshManager.setHasActiveLutheranWidgets(true) }

        let plan = WidgetIntentCoordinators.planControlWidgetToggle(isPlayingRequested: isPlayingRequested)
        let language = WidgetIntentCoordinators.languageForOptimisticUpdate(
            persistedLanguage: SharedPlayerManager.loadPersistedWidgetState()?.currentLanguage,
            preferredLanguage: SharedPlayerManager.preferredWidgetLanguage()
        )
        await executeOptimisticToggle(plan: plan, language: language)
    }

    /// Full home-widget stream switch path used by ``SwitchStreamIntent/perform()``.
    ///
    /// - Parameter languageCode: Target stream BCP-47-style code.
    static func performHomeWidgetStreamSwitch(languageCode: String) async {
        await executeHomeWidgetStreamSwitch(languageCode: languageCode)
    }

    /// Full Live Activity toggle path used by ``LiveActivityTogglePlaybackIntent/perform()``.
    ///
    /// Resolves visual state with multi-source priority so lock-screen pause matches the
    /// control glyph the user saw:
    /// 1. Active ActivityKit ``ContentState/visualState`` (same SSOT as the LA UI)
    /// 2. Durable App Group mirror (last LA push; not gated by home-widget write suppression)
    /// 3. Actor / in-process session snapshot fallbacks
    ///
    /// Extension processes often start with an empty memory-only session snapshot and
    /// default actor `.prePlay`; planning from actor alone inverted the first pause while
    /// audio was already playing.
    ///
    /// **Optimistic ContentState:** after planning, the path publishes the target visual into
    /// ActivityKit content (preserving program metadata) and the durable mirror so a rapid
    /// second tap resolves from the post-toggle glyph rather than stale pre-tap content.
    /// Main-app ``RadioLiveActivityManager/lastPushedContent`` is aligned so actor-driven
    /// pushes do not thrash the optimistic glyph before sticky lock / soft silence converge.
    ///
    /// **Post-term / reboot:** when ``SharedPlayerManager/shouldDistrustDurableMirrorPlayPlanning()``
    /// is true, durable mirror alone must not plan `.play` (stale App Group after dirty
    /// power-off). ContentState remains trusted for explicit lock-screen glyphs.
    ///
    /// **Connecting / thermal / security:** when the main-app start pipeline is active
    /// (``SharedPlayerManager/isConnectingPlayback``), plan pause to cancel connect.
    /// Thermal refuses play while the hardware gate is authoritative. Security recovery
    /// may plan play but optimistic chrome uses connecting (``.prePlay``), not `.playing`.
    ///
    /// - SeeAlso: ``WidgetIntentCoordinators/resolveLiveActivityToggleVisualState(liveActivityContent:durableMirror:actorVisualState:sessionSnapshot:)``,
    ///   ``WidgetIntentCoordinators/planLiveActivityToggle(resolution:distrustDurableMirrorPlay:isConnectingPlayback:)``,
    ///   ``pushOptimisticLiveActivityToggleContent(visualState:)``,
    ///   ``SharedPlayerManager/persistLiveActivityToggleVisualStateMirror(_:)``,
    ///   ``SharedPlayerManager/shouldDistrustDurableMirrorPlayPlanning()``,
    ///   ``SharedPlayerManager/isConnectingPlayback``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   ``MediaTransportLatencyTimeline`` (DEBUG latency milestones).
    static func performLiveActivityToggle() async {
        #if DEBUG
        MediaTransportLatencyTimeline.mark(.liveActivityToggleStarted)
        #endif

        let liveActivityContent = currentLiveActivityContentVisualState()
        let durableMirror = SharedPlayerManager.loadLiveActivityToggleVisualStateMirror()
        let actorVisualState = await SharedPlayerManager.shared.currentVisualState
        let sessionSnapshot = SharedPlayerManager.loadPersistedWidgetState()?.visualState
        let distrustDurableMirrorPlay = SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning()
        let isConnectingPlayback = await SharedPlayerManager.shared.isConnectingPlayback

        let resolution = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: liveActivityContent,
            durableMirror: durableMirror,
            actorVisualState: actorVisualState,
            sessionSnapshot: sessionSnapshot
        )
        let plan = WidgetIntentCoordinators.planLiveActivityToggle(
            resolution: resolution,
            distrustDurableMirrorPlay: distrustDurableMirrorPlay,
            isConnectingPlayback: isConnectingPlayback
        )

        #if DEBUG
        MediaTransportLatencyTimeline.mark(
            .liveActivityTogglePlanResolved,
            detail: "plan=\(plan) source=\(resolution.source.rawValue) state=\(resolution.visualState) distrustMirrorPlay=\(distrustDurableMirrorPlay) connecting=\(isConnectingPlayback)"
        )
        #endif

        // Thermal refuse: keep policy chrome; do not optimistic-flip or drain engine work.
        guard plan != .refuse else { return }

        // Optimistic mirror + ActivityKit ContentState so a second rapid tap plans against
        // the intended post-toggle visual (content wins resolve when activities are visible).
        // Under distrust, forced-pause plans also pin the mirror to `.userPaused` (never
        // re-warm a play-biased token from a stale non-playing mirror alone).
        // Security recovery play plans use connecting chrome (not green/playing) until engine-complete.
        let optimisticTarget: PlayerVisualState
        switch plan {
        case .pause:
            optimisticTarget = .userPaused
        case .play:
            optimisticTarget = resolution.visualState.optimisticVisualAfterPlayPlan
        case .refuse:
            return
        @unknown default:
            return
        }
        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(optimisticTarget)
        // Keep language mirror warm from ContentState (or existing durable code) so extension
        // play/pause instant-feedback does not fall through to privacy-gated "en".
        if let contentLanguage = currentLiveActivityContentLanguage(), !contentLanguage.isEmpty {
            SharedPlayerManager.persistLiveActivityLanguageMirror(contentLanguage)
        }
        await pushOptimisticLiveActivityToggleContent(visualState: optimisticTarget)
        #if DEBUG
        MediaTransportLatencyTimeline.mark(
            .liveActivityToggleOptimisticPublished,
            detail: "visual=\(optimisticTarget)"
        )
        #endif

        #if DEBUG
        MediaTransportLatencyTimeline.mark(.liveActivityToggleExecuteStarted, detail: "plan=\(plan)")
        #endif
        await executeLiveActivityToggle(plan: plan)
        #if DEBUG
        MediaTransportLatencyTimeline.mark(.liveActivityToggleExecuteFinished, detail: "plan=\(plan)")
        #endif
    }

    /// Reads `ContentState.visualState` from the first active/stale Lutheran Radio Live Activity.
    ///
    /// - Returns: Visual state when ActivityKit exposes a live activity in this process; otherwise `nil`.
    /// - Note: App Intent hosts sometimes report an empty activities list; the durable App Group
    ///   mirror is the required fallback in that case.
    nonisolated static func currentLiveActivityContentVisualState() -> PlayerVisualState? {
        firstInteractiveLiveActivity()?.content.state.visualState
    }

    /// Reads `ContentState.currentLanguage` from the first interactive Live Activity.
    ///
    /// - Returns: Stream language code when ActivityKit exposes content; otherwise `nil`.
    /// - SeeAlso: ``currentLiveActivityContentVisualState()``,
    ///   ``SharedPlayerManager/languageForLiveActivityOrWidgetOptimistic()``.
    nonisolated static func currentLiveActivityContentLanguage() -> String? {
        guard let code = firstInteractiveLiveActivity()?.content.state.currentLanguage, !code.isEmpty else {
            return nil
        }
        return code
    }

    /// Publishes an optimistic Live Activity control visual for lock-screen toggle intents.
    ///
    /// Updates every active/stale `Activity` whose content visual differs from `visualState`,
    /// preserving each activity's existing ``streamMetadata`` and ``currentLanguage`` (no
    /// title/speaker/language invent or clear). On the main app, aligns
    /// ``RadioLiveActivityManager/lastPushedContent`` so subsequent ``updateCurrentActivity()``
    /// calls do not regress the glyph while the actor catches up.
    ///
    /// - Parameter visualState: Target control visual (`.userPaused` after pause plan, `.playing` after play).
    /// - Note: Skips ActivityKit IPC under ``SharedPlayerManager/isRunningInUITestMode`` so
    ///   unit tests stay free of system-service round-trips; main-app last-pushed alignment
    ///   still runs so white-box suppression tests can exercise the thrash guard.
    /// - SeeAlso: ``performLiveActivityToggle()``,
    ///   ``pushOptimisticLiveActivityStreamSwitchContent(languageCode:visualState:)``,
    ///   ``LutheranRadioLiveActivityAttributes/ContentState/replacingVisualState(_:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func pushOptimisticLiveActivityToggleContent(visualState: PlayerVisualState) async {
        let skipActivityKitIPC = SharedPlayerManager.isRunningInUITestMode

        if !skipActivityKitIPC {
            for activity in interactiveLiveActivities() {
                let current = activity.content.state
                let candidate = current.replacingVisualState(visualState)
                guard candidate != current else { continue }

                nonisolated(unsafe) let safeActivity = activity
                // SAFETY: Activity.update is not Sendable in the current SDK; capture is a
                // local strong reference from Activity.activities (same pattern as
                // RadioLiveActivityManager.updateCurrentActivity).
                unsafe await safeActivity.update(.init(state: candidate, staleDate: nil))
            }
        }

        #if LUTHERAN_MAIN_APP
        await MainActor.run {
            RadioLiveActivityManager.shared.recordOptimisticToggleContent(visualState: visualState)
        }
        #endif
    }

    /// Publishes optimistic Live Activity language chrome for lock-screen stream-language chips.
    ///
    /// Updates every interactive activity whose content would change under destination
    /// language + switch visual (Connecting when leaving play, preserved pause when sticky).
    /// Clears prior-stream program metadata by default so an old title does not ride under
    /// the new flag. Warms the durable language mirror and, on the main app, aligns
    /// ``RadioLiveActivityManager/lastPushedContent`` so engine-complete pushes can suppress
    /// when they match the optimistic destination **and** owned `content.state` language.
    ///
    /// After each ActivityKit update, re-reads `content.state.currentLanguage`. DEBUG logs do
    /// not claim success when the surface still holds the prior language. On the main app,
    /// ``ensureAuthoritativeLanguageContentIfNeeded()`` forces a non-suppressed reconcile
    /// when owned content language still differs from the destination (owned language beats
    /// optimistic suppress memory).
    ///
    /// - Parameters:
    ///   - languageCode: Destination stream language code (flag / name / alt-current).
    ///   - visualState: Optimistic control visual from
    ///     ``WidgetIntentCoordinators/optimisticLiveActivityVisualForStreamSwitch(from:)``.
    /// - Note: Skips ActivityKit IPC under ``SharedPlayerManager/isRunningInUITestMode``;
    ///   mirror + main-app last-pushed alignment still run for white-box contracts.
    /// - SeeAlso: ``executeLiveActivityStreamSwitch(languageCode:)``,
    ///   ``RadioLiveActivityManager/ensureAuthoritativeLanguageContentIfNeeded()``,
    ///   ``RadioLiveActivityManager/shouldSuppressLiveActivityContentPush(lastPushed:candidate:ownedContentLanguage:)``,
    ///   ``LutheranRadioLiveActivityAttributes/ContentState/replacingStreamSwitchDestination(language:visualState:clearStreamMetadata:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   docs/Widget-Functionality-Roadmap.md (Live Activity language chrome SSOT).
    static func pushOptimisticLiveActivityStreamSwitchContent(
        languageCode: String,
        visualState: PlayerVisualState
    ) async {
        guard !languageCode.isEmpty else { return }

        SharedPlayerManager.persistLiveActivityLanguageMirror(languageCode)
        // When leaving play for Connecting, keep durable toggle mirror coherent with ContentState.
        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(visualState)

        let skipActivityKitIPC = SharedPlayerManager.isRunningInUITestMode
        var anySurfaceAcceptedDestination = false

        if !skipActivityKitIPC {
            for activity in interactiveLiveActivities() {
                let current = activity.content.state
                let candidate = current.replacingStreamSwitchDestination(
                    language: languageCode,
                    visualState: visualState,
                    clearStreamMetadata: true
                )
                if candidate == current {
                    if current.currentLanguage == languageCode {
                        anySurfaceAcceptedDestination = true
                    }
                    continue
                }

                nonisolated(unsafe) let safeActivity = activity
                // SAFETY: Activity.update / content.state / id are not Sendable in the current
                // SDK; capture is a local strong reference from Activity.activities, and
                // post-update reads use explicit `unsafe` under SWIFT_STRICT_MEMORY_SAFETY
                // (same pattern as RadioLiveActivityManager.updateCurrentActivity).
                unsafe await safeActivity.update(.init(state: candidate, staleDate: nil))

                let acceptedLanguage = unsafe safeActivity.content.state.currentLanguage
                if acceptedLanguage == languageCode {
                    anySurfaceAcceptedDestination = true
                }
                #if DEBUG
                // SAFETY: Activity.id on the nonisolated(unsafe) capture (DEBUG diagnostics only).
                let activityId = unsafe safeActivity.id
                if acceptedLanguage != languageCode {
                    print(
                        "🔴 Optimistic LA stream-switch: content.state language still " +
                        "\(acceptedLanguage.isEmpty ? "empty" : acceptedLanguage) " +
                        "after update (destination=\(languageCode) id=\(activityId)); " +
                        "not treating as accepted"
                    )
                } else {
                    print(
                        "🔴 Optimistic LA stream-switch accepted: language=\(languageCode) " +
                        "visual=\(visualState) id=\(activityId)"
                    )
                }
                #endif
            }
        }

        #if LUTHERAN_MAIN_APP
        await MainActor.run {
            RadioLiveActivityManager.shared.recordOptimisticStreamSwitchContent(
                language: languageCode,
                visualState: visualState
            )
        }
        // Owned content language beats optimistic lastPushedContent for suppress; reconcile
        // when the surface still holds the prior stream after the intent-path push.
        if !skipActivityKitIPC, !anySurfaceAcceptedDestination {
            await RadioLiveActivityManager.shared.ensureAuthoritativeLanguageContentIfNeeded()
        } else if !skipActivityKitIPC {
            // Even when one surface accepted, owned main-app activity may still lag — cheap no-op.
            await RadioLiveActivityManager.shared.ensureAuthoritativeLanguageContentIfNeeded()
        }
        #endif
    }

    /// Active or stale Lutheran Radio Live Activities visible to this process.
    ///
    /// - Returns: Activities whose content may drive lock-screen toggle resolve and optimistic push.
    nonisolated private static func interactiveLiveActivities()
        -> [Activity<LutheranRadioLiveActivityAttributes>]
    {
        Activity<LutheranRadioLiveActivityAttributes>.activities.filter {
            switch $0.activityState {
            case .active, .stale:
                return true
            default:
                return false
            }
        }
    }

    /// First interactive Live Activity, if any.
    nonisolated private static func firstInteractiveLiveActivity()
        -> Activity<LutheranRadioLiveActivityAttributes>?
    {
        interactiveLiveActivities().first
    }

    /// Full Live Activity stream switch path used by ``LiveActivitySwitchStreamIntent/perform()``.
    ///
    /// Extension-profile contracts (`WidgetIntentContractExtensionTests`): unknown codes
    /// return `false` without mutating the optimistic snapshot; known codes:
    /// 1. Push optimistic ActivityKit ``ContentState`` with destination language (flag/name
    ///    chrome) and Connecting or preserved pause visual
    /// 2. Warm durable language mirror
    /// 3. Invoke ``SharedPlayerManager/switchToStream(_:)`` (pending + Darwin)
    ///
    /// Home-widget snapshot visual may still preserve `.playing` across the optimistic
    /// App Group write; Live Activity ContentState uses Connecting when leaving active play
    /// so language chrome never claims audible playback on the destination stream.
    ///
    /// - Parameter languageCode: Target stream code.
    /// - Returns: `true` when a matching stream was found and the switch was invoked.
    /// - SeeAlso: ``executeLiveActivityStreamSwitch(languageCode:)``,
    ///   ``pushOptimisticLiveActivityStreamSwitchContent(languageCode:visualState:)``,
    ///   ``performHomeWidgetStreamSwitch(languageCode:)``, docs/Widget-Functionality-Roadmap.md,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    @discardableResult
    static func performLiveActivityStreamSwitch(languageCode: String) async -> Bool {
        await executeLiveActivityStreamSwitch(languageCode: languageCode)
    }

    // MARK: - Primitive side effects

    /// Optimistic snapshot + pending action + immediate widget refresh for play/pause toggles.
    ///
    /// Imperative **extensionOptimistic** path: the extension process cannot emit
    /// ``PlayerEvent``; immediate ``refreshIfNeeded`` is the only cross-process reload lever
    /// until the main app drains the pending action.
    ///
    /// **Home live chrome:** ``signalWidgetPendingAction`` → ``persistOptimisticWidgetSnapshot``
    /// stamps privacy-gated ``homeWidgetLiveChrome`` with the plan’s ``targetVisualState``
    /// (reason `"optimisticToggle"`). Pause → ``.userPaused``; play → plan optimistic visual
    /// (``optimisticVisualAfterPlayPlan`` / Control ``.playing``) — never invent beyond the pure
    /// planner. Main-app settle overwrites when the gate is open.
    ///
    /// **Live Activity pause honesty:** When the plan targets a control visual (``.userPaused``
    /// or ``.playing``), also warms the durable LA toggle mirror (not gated by home widgets)
    /// and publishes optimistic ActivityKit ContentState via ``pushOptimisticLiveActivityToggleContent(visualState:)``.
    /// That path preserves language chrome and replaces a stale system-held Connecting
    /// (``.prePlay``) glyph so lock-screen controls track home/Control pause without waiting
    /// for main-app soft silence + ``updateCurrentActivity()`` acceptance.
    ///
    /// - Parameters:
    ///   - plan: Home-widget or Control-widget toggle plan.
    ///   - language: Language code from ``WidgetIntentCoordinators/languageForOptimisticUpdate(persistedLanguage:preferredLanguage:)``.
    /// - SeeAlso: ``WidgetRefreshTrigger/extensionOptimistic``,
    ///   ``pushOptimisticLiveActivityToggleContent(visualState:)``,
    ///   ``SharedPlayerManager/persistLiveActivityToggleVisualStateMirror(_:)``,
    ///   ``SharedPlayerManager/stampHomeWidgetLiveChromeFromSession(visualState:language:hasError:reason:)``,
    ///   ``WidgetProviderSnapshotResolver/resolveFromSnapshot()``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§5.3),
    ///   docs/Event-Driven-Refactor-Roadmap.md,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func executeOptimisticToggle(plan: WidgetToggleActionPlan, language: String) async {
        guard plan.shouldExecutePendingAction else { return }
        let manager = SharedPlayerManager.shared
        _ = manager.signalWidgetPendingAction(
            visualState: plan.targetVisualState,
            action: plan.action.wireValue,
            language: language
        )
        // Home/Control pause must not leave LA ContentState stuck on Connecting while the
        // home snapshot already shows userPaused — same optimistic ContentState path as LA toggle.
        if plan.targetVisualState.isDefinitiveMediaToggleVisual {
            SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(plan.targetVisualState)
            if let contentLanguage = currentLiveActivityContentLanguage(), !contentLanguage.isEmpty {
                SharedPlayerManager.persistLiveActivityLanguageMirror(contentLanguage)
            } else if !language.isEmpty {
                SharedPlayerManager.persistLiveActivityLanguageMirror(language)
            }
            await pushOptimisticLiveActivityToggleContent(visualState: plan.targetVisualState)
        }
        let state = manager.loadSharedState()
        await WidgetRefreshManager.shared.refreshIfNeeded(
            visualState: plan.targetVisualState,
            currentLanguage: language,
            hasError: state.hasError,
            immediate: true,
            trigger: .extensionOptimistic
        )
    }

    /// Home-widget stream switch: optimistic path through ``SharedPlayerManager/switchToStream(_:)`` + refresh.
    ///
    /// Imperative **extensionOptimistic** path (no PlayerEvent emission in the extension process).
    /// When a Live Activity is visible in this process, also pushes destination language into
    /// ActivityKit ContentState so lock-screen flag chrome does not lag a home-widget chip tap.
    ///
    /// **First home paint honesty:** The optimistic refresh visual uses the same pure stream-switch
    /// rule as Live Activity ContentState — actively playing → Connecting (``.prePlay``); sticky
    /// pause preserved. ``switchToStream`` → ``handleWidgetSwitch`` → ``signalWidgetSwitchAction``
    /// writes that visual + destination language into session RAM **and** privacy-gated
    /// ``homeWidgetLiveChrome`` (reason `"optimisticSwitch"`) before the immediate reload, so
    /// destination language does not flash mid-switch "playing" chrome during silent attach hold.
    /// Authoritative ``.playing`` arrives later via main-app attach / ``setPlaying()``.
    ///
    /// - Parameter languageCode: Target stream BCP-47-style code from ``SwitchStreamIntent``.
    /// - SeeAlso: ``WidgetRefreshTrigger/extensionOptimistic``,
    ///   ``WidgetIntentCoordinators/optimisticLiveActivityVisualForStreamSwitch(from:)``,
    ///   ``pushOptimisticLiveActivityStreamSwitchContent(languageCode:visualState:)``,
    ///   ``SharedPlayerManager/signalWidgetSwitchAction(visualState:language:)``,
    ///   ``WidgetProviderSnapshotResolver/resolveFromSnapshot()``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§5.3, §9),
    ///   docs/Widget-Presentation-Dataflow.md.
    static func executeHomeWidgetStreamSwitch(languageCode: String) async {
        Task { @MainActor in WidgetRefreshManager.setHasActiveLutheranWidgets(true) }

        let manager = SharedPlayerManager.shared
        guard let targetStream = manager.availableStreams.first(where: { $0.languageCode == languageCode }) else {
            return
        }

        // Snapshot visual before switch (playing / paused) drives optimistic chrome for both
        // LA ContentState and the home timeline reload. Do not re-read after switch alone —
        // prefer the pure rule explicitly so a lagging disk playing cannot force a dishonest
        // first paint if the snapshot write and refresh ever race.
        let preSwitchVisual = SharedPlayerManager.loadPersistedVisualStateDirect()
        let optimisticHomeVisual = WidgetIntentCoordinators.optimisticLiveActivityVisualForStreamSwitch(
            from: preSwitchVisual
        )

        // Lock-screen LA may coexist with the home widget — advance flag chrome before drain.
        await publishOptimisticStreamSwitchLanguageChrome(languageCode: languageCode)

        await manager.switchToStream(targetStream)

        let state = manager.loadSharedState()
        await WidgetRefreshManager.shared.refreshIfNeeded(
            visualState: optimisticHomeVisual,
            currentLanguage: languageCode,
            hasError: state.hasError,
            immediate: true,
            trigger: .extensionOptimistic
        )
    }

    /// Live Activity stream switch: optimistic language ContentState, then pending + Darwin.
    ///
    /// Publishes destination ``ContentState/currentLanguage`` (and Connecting / preserved
    /// pause visual) **before** ``switchToStream`` so lock-screen flag/name track the chip
    /// tap immediately. Engine attach remains main-app drain ownership.
    ///
    /// - Parameter languageCode: Target stream code from ``LiveActivitySwitchStreamIntent``.
    /// - Returns: `true` when a matching stream was found and the switch was invoked.
    /// - SeeAlso: ``pushOptimisticLiveActivityStreamSwitchContent(languageCode:visualState:)``,
    ///   ``WidgetIntentCoordinators/optimisticLiveActivityVisualForStreamSwitch(from:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    @discardableResult
    static func executeLiveActivityStreamSwitch(languageCode: String) async -> Bool {
        let manager = SharedPlayerManager.shared
        guard let targetStream = manager.availableStreams.first(where: { $0.languageCode == languageCode }) else {
            return false
        }

        await publishOptimisticStreamSwitchLanguageChrome(languageCode: languageCode)

        await manager.switchToStream(targetStream)
        return true
    }

    /// Resolves optimistic switch visual and pushes Live Activity language chrome.
    ///
    /// Prefer ActivityKit ContentState visual (matches the glyph the user sees), then the
    /// session snapshot. Destination language always warms the durable mirror even when no
    /// activity is visible in this process.
    ///
    /// - Parameter languageCode: Destination stream language code.
    private static func publishOptimisticStreamSwitchLanguageChrome(languageCode: String) async {
        let contentVisual = currentLiveActivityContentVisualState()
        let snapshotVisual = SharedPlayerManager.loadPersistedVisualStateDirect()
        let baseVisual = contentVisual ?? snapshotVisual
        let optimisticVisual = WidgetIntentCoordinators.optimisticLiveActivityVisualForStreamSwitch(
            from: baseVisual
        )
        await pushOptimisticLiveActivityStreamSwitchContent(
            languageCode: languageCode,
            visualState: optimisticVisual
        )
    }

    /// Live Activity play/pause toggle via actor-isolated manager APIs.
    ///
    /// On the main app, engine work is enqueued on the same serial media-transport mailbox
    /// as system Now Playing / headset remotes (``SharedPlayerManager/submitMediaTransportCommandAndWait(_:)``)
    /// so interleaved lock-screen taps cannot invert direction. The extension process keeps
    /// direct ``stop()`` / ``userRequestedPlay()`` so pending-action + Darwin drain remains
    /// the cross-process path (no main-app mailbox in the extension binary).
    ///
    /// **Extension host latency:** optimistic ContentState + durable mirror are published
    /// before this method runs (``performLiveActivityToggle()``). Engine silence / first
    /// audio still requires main-app ``RadioPlayerCoordinator/checkForPendingWidgetActions()``
    /// after Darwin notify; the main app debounces only same-direction play/pause so a rapid
    /// opposite flip is not dropped, and drained play/pause share the media-transport mailbox
    /// for preemption.
    ///
    /// - Parameter plan: Direction from ``WidgetIntentCoordinators/planLiveActivityToggle(from:)``.
    /// - SeeAlso: ``MediaTransportCommand``, ``SharedPlayerManager/submitMediaTransportCommandAndWait(_:)``,
    ///   ``RadioPlayerCoordinator/checkForPendingWidgetActions()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    static func executeLiveActivityToggle(plan: WidgetLiveActivityTogglePlan) async {
        let manager = SharedPlayerManager.shared
        #if LUTHERAN_MAIN_APP
        switch plan {
        case .pause:
            await manager.submitMediaTransportCommandAndWait(.pause)
        case .play:
            await manager.submitMediaTransportCommandAndWait(.play)
        case .refuse:
            break
        @unknown default:
            break
        }
        #else
        switch plan {
        case .pause:
            await manager.stop()
        case .play:
            await manager.userRequestedPlay()
        case .refuse:
            break
        @unknown default:
            break
        }
        #endif
    }
}

