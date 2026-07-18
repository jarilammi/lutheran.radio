//
//  WidgetDisplayModels.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 12.6.2026.
//

// SHARED: Cross-target source (main app + LutheranRadioWidgetExtension)
//
// Single physical file compiled into both targets via membershipExceptions.
//
// Purpose (this file only — execution and snapshot hygiene that require
// ``SharedPlayerManager`` / ``WidgetRefreshManager``):
// - Stream-catalog-aware ``displayLanguageName(for:)`` (wraps pure WidgetSurface helpers).
// - ``WidgetProviderSnapshotResolver`` — Provider snapshot reads, actor hygiene, and
//   stream-catalog station labels; pure presentation assembly is delegated to
//   ``WidgetProviderPresentationAssembly`` in WidgetSurface.
// - ``WidgetIntentExecution`` — AppIntent perform SSOT and side effects via
//   ``SharedPlayerManager`` + ``WidgetRefreshManager``.
//
// AGENT NOTE: Pure presentation types and mapping live in **WidgetSurface**, not here:
// - Status/control: ``PlayerVisualState/makeStatusPresentation()``,
//   ``PlayerVisualState/makeControlPresentation()`` (`WidgetSurface/PlayerVisualState.swift`)
// - Metadata/emphasis SSOT: ``WidgetMetadataEmphasis``, ``WidgetNowPlayingDisplayModel``,
//   ``widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)``
//   (`WidgetSurface/WidgetNowPlayingDisplay.swift`)
// - Language chrome: ``displayFlag(for:)``, pure
//   ``displayLanguageName(for:preferredStreamLanguage:)`` (`WidgetSurface/WidgetLanguageDisplay.swift`)
// - Pure Provider slice assembly: ``WidgetProviderPresentationAssembly``
// - Intent *plans*: ``WidgetIntentCoordinators``; *blueprints*: ``WidgetTimelineEntryFactory``
//
// This file stays cross-target because snapshot hygiene and intent execution must call
// ``SharedPlayerManager`` (and refresh coordination must call ``WidgetRefreshManager``).
// Moving those call sites into WidgetSurface would create a circular module dependency
// (`SharedPlayerManager` already imports WidgetSurface).
//
// No security logic and no AVPlayer/streaming ownership.
//
// - SeeAlso: docs/Widget-Presentation-Dataflow.md, docs/Widget-Functionality-Roadmap.md,
//   ``WidgetProviderPresentationAssembly``, ``WidgetIntentCoordinators``,
//   ``WidgetTimelineEntryFactory``, CODING_AGENT.md (cross-target widget sources).

// SAFETY: ActivityKit's `Activity` is not Sendable; optimistic ContentState pushes from
// lock-screen intents use `nonisolated(unsafe)` + `unsafe await activity.update` with a
// local strong capture (same boundary as RadioLiveActivityManager). Prefer
// `@unsafe @preconcurrency` over bare `@preconcurrency` under SWIFT_STRICT_MEMORY_SAFETY.
@unsafe @preconcurrency import ActivityKit
import Foundation
import WidgetSurface

// MARK: - Stream-catalog language name (membership-exception wrapper)
//
// ``displayFlag(for:)`` and pure ``displayLanguageName(for:preferredStreamLanguage:)``
// live in WidgetSurface. This wrapper prefers ``SharedPlayerManager/availableStreams``
// so Live Activity alt buttons and previews match the app stream catalog.
//
// Contracts: `WidgetDisplayModelsExtensionTests` (stream-list preference, unknown capitalize).
// - SeeAlso: docs/Widget-Functionality-Roadmap.md (Tier 5 display helper index).

/// Localized display name for a stream language code (LA alt buttons + previews).
///
/// Prefers ``SharedPlayerManager/availableStreams``; otherwise uses pure WidgetSurface
/// curated `Localizable` keys for en/de/fi/sv/et, then `code.capitalized`.
///
/// - Parameter code: BCP-47-style language code (e.g. `"fi"`).
/// - Returns: Non-empty display name suitable for UI.
/// - SeeAlso: ``displayFlag(for:)``, ``displayLanguageName(for:preferredStreamLanguage:)``,
///   docs/Widget-Functionality-Roadmap.md.
internal func displayLanguageName(for code: String) -> String {
    let preferred = SharedPlayerManager.shared.availableStreams
        .first(where: { $0.languageCode == code })?
        .language
    return displayLanguageName(for: code, preferredStreamLanguage: preferred)
}

// MARK: - Provider snapshot resolution (hygiene + catalog labels)

/// Canonical resolver for home-widget and Control-widget Provider entry points.
///
/// Documents which paths require an actor hop versus safe direct snapshot reads.
/// Cross-process freshness still depends on main-app ``WidgetRefreshManager`` timeline reloads;
/// the resolver only governs in-process read hygiene inside the extension.
///
/// Pure presentation assembly is ``WidgetProviderPresentationAssembly``; this type owns
/// ``SharedPlayerManager`` snapshot reads, actor hygiene, and stream-catalog labels.
///
/// - SeeAlso: ``SharedPlayerManager/refreshVisualStateFromPersistence()``,
///   ``SharedPlayerManager/loadPersistedWidgetState()``,
///   ``WidgetProviderPresentationAssembly``, docs/Widget-Functionality-Roadmap.md.
enum WidgetProviderSnapshotResolver {

    /// Resolves snapshot fields without an actor hop.
    ///
    /// Safe when the Provider consumes only static snapshot readers (`loadPersistedWidgetState`,
    /// `preferredWidgetLanguage`, `streamForLanguageCode`) and never consults
    /// ``SharedPlayerManager/currentVisualState``. Home-widget timeline rendering uses this
    /// after optional hygiene because `getPendingOrCurrentState` never falls back to actor state.
    ///
    /// - Returns: Authoritative session snapshot fields, or factory `.prePlay` defaults when absent.
    nonisolated static func resolveFromSnapshot() -> WidgetProviderSnapshotFields {
        if let combined = SharedPlayerManager.loadPersistedWidgetState() {
            return WidgetProviderSnapshotFields(
                currentLanguage: combined.currentLanguage,
                hasError: combined.hasError,
                visualState: combined.visualState,
                streamMetadata: combined.streamMetadata
            )
        }
        return WidgetProviderSnapshotFields(
            currentLanguage: SharedPlayerManager.preferredWidgetLanguage(),
            hasError: false,
            visualState: .prePlay,
            streamMetadata: nil
        )
    }

    /// Full provider hygiene: resets the actor loaded-guard, then resolves snapshot fields.
    ///
    /// Required when a Provider may consult ``SharedPlayerManager/currentVisualState`` (Control Center
    /// App Group-unavailable fallback) and recommended for every timeline `snapshot` / `timeline`
    /// request in long-lived extension processes after optimistic ``persistOptimisticWidgetSnapshot``
    /// writes. The hop synchronizes the actor guard; snapshot reads remain static.
    ///
    /// - Parameter manager: The shared actor instance for the executing process.
    /// - Returns: Fields from ``resolveFromSnapshot()`` after hygiene.
    static func resolveWithActorHygiene(
        manager: SharedPlayerManager = .shared
    ) async -> WidgetProviderSnapshotFields {
        await manager.refreshVisualStateFromPersistence()
        return resolveFromSnapshot()
    }

    /// Localized station label (`flag + language name`) for a language code.
    ///
    /// - Parameter languageCode: BCP-47-style stream code from the snapshot.
    /// - Returns: Display string used by home-widget `currentStation` and Control-widget `Value`.
    nonisolated static func stationLabel(for languageCode: String) -> String {
        let stream = SharedPlayerManager.streamForLanguageCode(languageCode)
        return stream.flag + " " + stream.language
    }

    /// Assembles the three narrow presentation surfaces plus station label from snapshot fields.
    ///
    /// Resolves stream-catalog language labels, then delegates pure presentation synthesis to
    /// ``WidgetProviderPresentationAssembly``. Home-widget ``SimpleEntry`` and Control-widget
    /// ``Value`` must consume these slices rather than re-invoking presentation mappers in
    /// timeline or value-provider paths.
    ///
    /// - Parameter fields: Authoritative snapshot fields from ``resolveFromSnapshot()`` or
    ///   ``resolveWithActorHygiene(manager:)``.
    /// - Returns: Pre-derived slices ready to populate ``SimpleEntry`` / Control-widget ``Value``.
    /// - SeeAlso: ``WidgetProviderPresentationAssembly/assemblePresentationSlices(from:languageName:stationLabel:)``,
    ///   ``WidgetProviderPresentationSlices``, ``WidgetProviderSnapshotFields``,
    ///   docs/Widget-Presentation-Dataflow.md, docs/Widget-Functionality-Roadmap.md.
    nonisolated static func assemblePresentationSlices(
        from fields: WidgetProviderSnapshotFields
    ) -> WidgetProviderPresentationSlices {
        let stream = SharedPlayerManager.streamForLanguageCode(fields.currentLanguage)
        return WidgetProviderPresentationAssembly.assemblePresentationSlices(
            from: fields,
            languageName: stream.language,
            stationLabel: stationLabel(for: fields.currentLanguage)
        )
    }
}

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
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    static func performLiveActivityToggle() async {
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
        print(
            "[WidgetIntentExecution] LA toggle plan=\(plan) source=\(resolution.source.rawValue) state=\(resolution.visualState) distrustMirrorPlay=\(distrustDurableMirrorPlay) connecting=\(isConnectingPlayback)"
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
        await pushOptimisticLiveActivityToggleContent(visualState: optimisticTarget)

        await executeLiveActivityToggle(plan: plan)
    }

    /// Reads `ContentState.visualState` from the first active/stale Lutheran Radio Live Activity.
    ///
    /// - Returns: Visual state when ActivityKit exposes a live activity in this process; otherwise `nil`.
    /// - Note: App Intent hosts sometimes report an empty activities list; the durable App Group
    ///   mirror is the required fallback in that case.
    nonisolated static func currentLiveActivityContentVisualState() -> PlayerVisualState? {
        firstInteractiveLiveActivity()?.content.state.visualState
    }

    /// Publishes an optimistic Live Activity control visual for lock-screen toggle intents.
    ///
    /// Updates every active/stale `Activity` whose content visual differs from `visualState`,
    /// preserving each activity's existing ``streamMetadata`` (no title/speaker invent or clear).
    /// On the main app, aligns ``RadioLiveActivityManager/lastPushedContent`` so subsequent
    /// ``updateCurrentActivity()`` calls do not regress the glyph while the actor catches up.
    ///
    /// - Parameter visualState: Target control visual (`.userPaused` after pause plan, `.playing` after play).
    /// - Note: Skips ActivityKit IPC under ``SharedPlayerManager/isRunningInUITestMode`` so
    ///   unit tests stay free of system-service round-trips; main-app last-pushed alignment
    ///   still runs so white-box suppression tests can exercise the thrash guard.
    /// - SeeAlso: ``performLiveActivityToggle()``,
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
    /// return `false` without mutating the optimistic snapshot; known codes invoke
    /// ``SharedPlayerManager/switchToStream(_:)`` and preserve paused/playing visual while
    /// updating language (home-widget switch SSOT parity). Does not re-plan play/pause —
    /// multi-source visual resolution is exclusive to ``performLiveActivityToggle()``.
    ///
    /// - Parameter languageCode: Target stream code.
    /// - Returns: `true` when a matching stream was found and the switch was invoked.
    /// - SeeAlso: ``executeLiveActivityStreamSwitch(languageCode:)``,
    ///   ``performHomeWidgetStreamSwitch(languageCode:)``, docs/Widget-Functionality-Roadmap.md.
    @discardableResult
    static func performLiveActivityStreamSwitch(languageCode: String) async -> Bool {
        await executeLiveActivityStreamSwitch(languageCode: languageCode)
    }

    // MARK: - Primitive side effects

    /// Optimistic snapshot + pending action + immediate widget refresh for play/pause toggles.
    ///
    /// - Parameters:
    ///   - plan: Home-widget or Control-widget toggle plan.
    ///   - language: Language code from ``WidgetIntentCoordinators/languageForOptimisticUpdate(persistedLanguage:preferredLanguage:)``.
    static func executeOptimisticToggle(plan: WidgetToggleActionPlan, language: String) async {
        guard plan.shouldExecutePendingAction else { return }
        let manager = SharedPlayerManager.shared
        _ = manager.signalWidgetPendingAction(
            visualState: plan.targetVisualState,
            action: plan.action,
            language: language
        )
        let state = manager.loadSharedState()
        await WidgetRefreshManager.shared.refreshIfNeeded(
            visualState: plan.targetVisualState,
            currentLanguage: language,
            hasError: state.hasError,
            immediate: true
        )
    }

    /// Home-widget stream switch: optimistic path through ``SharedPlayerManager/switchToStream(_:)`` + refresh.
    ///
    /// - Parameter languageCode: Target stream BCP-47-style code from ``SwitchStreamIntent``.
    static func executeHomeWidgetStreamSwitch(languageCode: String) async {
        Task { @MainActor in WidgetRefreshManager.setHasActiveLutheranWidgets(true) }

        let manager = SharedPlayerManager.shared
        guard let targetStream = manager.availableStreams.first(where: { $0.languageCode == languageCode }) else {
            return
        }

        await manager.switchToStream(targetStream)

        let state = manager.loadSharedState()
        let visualState = SharedPlayerManager.loadPersistedVisualStateDirect()
        await WidgetRefreshManager.shared.refreshIfNeeded(
            visualState: visualState,
            currentLanguage: languageCode,
            hasError: state.hasError,
            immediate: true
        )
    }

    /// Live Activity stream switch via canonical ``SharedPlayerManager/switchToStream(_:)``.
    ///
    /// - Parameter languageCode: Target stream code from ``LiveActivitySwitchStreamIntent``.
    /// - Returns: `true` when a matching stream was found and the switch was invoked.
    @discardableResult
    static func executeLiveActivityStreamSwitch(languageCode: String) async -> Bool {
        let manager = SharedPlayerManager.shared
        guard let targetStream = manager.availableStreams.first(where: { $0.languageCode == languageCode }) else {
            return false
        }
        await manager.switchToStream(targetStream)
        return true
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
    /// audio still requires main-app ``checkForPendingWidgetActions`` after Darwin notify;
    /// the main app debounces only same-direction play/pause so a rapid opposite flip is
    /// not dropped, and drained play/pause share the media-transport mailbox for preemption.
    ///
    /// - Parameter plan: Direction from ``WidgetIntentCoordinators/planLiveActivityToggle(from:)``.
    /// - SeeAlso: ``MediaTransportCommand``, ``SharedPlayerManager/submitMediaTransportCommandAndWait(_:)``,
    ///   ``ViewController/checkForPendingWidgetActions()``,
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
