//
//  WidgetDisplayModels.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 12.6.2026.
//

// SHARED: Cross-target source (main app + LutheranRadioWidgetExtension)
//
// Single physical file compiled into both targets.
//
// Purpose:
// Owns the metadata/emphasis presentation axis for widgets and Live Activities
// (`WidgetMetadataEmphasis`, `WidgetNowPlayingDisplayModel`, resolver) and
// language/flag helpers. Complements the status and control presentation mappers
// that live on `PlayerVisualState`.
//
// Presentation helpers plus cross-target ``WidgetIntentExecution`` (AppIntent perform
// SSOT). No security logic and no AVPlayer/streaming ownership.
//
// - SeeAlso: docs/Widget-Presentation-Dataflow.md (primary reference for the
//   three-surface snapshot-driven contract), `LutheranRadioWidget.swift`,
//   `LutheranRadioWidgetLiveActivity.swift`, `PlayerVisualState.swift`,
//   ``WidgetIntentCoordinators``, CODING_AGENT.md.

import ActivityKit
import Foundation
import WidgetSurface

// MARK: - Shared Widget / Live Activity Display Models
//
// Three narrow presentation surfaces are consistently derived once at the snapshot /
// provider level and consumed as value types by WidgetKit and ActivityKit surfaces:
//
// - `statusPresentation: PlayerStatusPresentation` (via `makeStatusPresentation()`)
// - `controlPresentation: PlayerControlPresentation` (via `makeControlPresentation()`)
// - `widgetNowPlayingDisplayModel: WidgetNowPlayingDisplayModel` (via `widgetNowPlayingDisplayModel(...)`)
//
// `WidgetMetadataEmphasis` + `WidgetNowPlayingDisplayModel` + the resolver function
// are the Single Source of Truth for the program-title / speaker-line / emphasis axis
// (the metadata/emphasis counterpart to the two presentation types on PlayerVisualState).
//
// ## Snapshot-Driven Derivation Pattern
//
// All three are **pre-derived** at the Provider / top-of-view level:
//
// - In home widgets: `SimpleEntry` is populated inside the `Provider`
//   (`placeholder(in:)`, `snapshot(for:in:)`, `timeline(for:in:)` via `createEntry`).
//   `LutheranRadioWidgetEntryView` projects the pre-derived values into
//   `SmallWidgetView`, `MediumWidgetView`, `LargeWidgetView`, and `WidgetMetadataRegion`;
//   family views receive narrow slices only; no derivation inside `body`.
// - In Live Activities: `LockScreenLiveActivityView.body` and the outer `dynamicIsland`
//   closure each compute the three narrow models once near the top, then close over them
//   for the various regions and sub-layouts.
//
// Why pre-derivation matters for WidgetKit / ActivityKit:
// - WidgetKit performs field-wise comparison on `TimelineEntry` values to decide
//   whether a view needs re-evaluation / invalidation. A narrow derived value means
//   only changes that affect the concrete status text, play glyph/tint, or title/speaker
//   cause body work for the consumers of that slice.
// - ActivityKit Dynamic Island region builders run independently. Hoisting derivation
//   to the outer closure bounds CPU and allocation work to once per push.
// - Leaf views and region closures receive the smallest possible input (e.g. four fields
//   for metadata), making them simpler, cheaper to diff, and easier to reason about.
//
// The resolvers (`makeStatusPresentation`, `makeControlPresentation`, and
// `widgetNowPlayingDisplayModel`) remain the single places that encode the mapping rules
// over `PlayerVisualState` + metadata fallbacks.
//
// ## Terminology (exact project names)
// - `PlayerStatusPresentation` + `makeStatusPresentation()` — status indicator axis.
// - `PlayerControlPresentation` + `makeControlPresentation()` — primary control axis.
// - `widgetNowPlayingDisplayModel(...)` — the core metadata/emphasis resolver.
// - `WidgetNowPlayingDisplayModel` — narrow value type for title/speaker/emphasis.
// - `SimpleEntry` — the `TimelineEntry` snapshot carrying all three for home widgets.
// - `WidgetMetadataRegion` — fixed-height title + speaker slots (medium/large).
// - `Provider` — the `AppIntentTimelineProvider`.
// - `LutheranRadioLiveActivityWidget` / Dynamic Island regions / `LockScreenLiveActivityView`.
//
// - SeeAlso: `PlayerVisualState` (the source; hosts the status/control mappers),
//   ``PlayerVisualState/makeStatusPresentation()``, ``PlayerVisualState/makeControlPresentation()``,
//   `LutheranRadioWidget.swift` (SimpleEntry + Provider + family views),
//   `LutheranRadioWidgetLiveActivity.swift` (top-level derivation + regions),
//   `LutheranRadioLiveActivityAttributes.ContentState`,
//   `WidgetDisplayModels.swift` (this file),
//   CODING_AGENT.md (Documentation & Comment Standards, Single Source of Truth Principles,
//   narrow inputs for WidgetKit/ActivityKit, Cross-target shared source files (non-Core)),
//   docs/Widget-Presentation-Dataflow.md (concise permanent guidance),
//   <doc:Architecture>, README.md (Single Sources of Truth).
//
// All user-visible strings use `String(localized: "key", table: "Localizable")` with explicit table.

// MARK: - Display name / flag helpers (module-internal)
//
// Used by the SwiftUI preview matrix and (via the existing thin get* wrappers)
// by Live Activity for its curated alt-stream buttons.
// Prefer the real availableStreams (full 21 languages + correct localized names from
// the app's static list) and fall back to the established mapping for the common codes.
// This is the general form so we never hard-code "Lutheran Radio - English" or
// "🇺🇸 English" in preview data.

internal func displayLanguageName(for code: String) -> String {
    // Prefer the authoritative streams (best, locale-correct names from the main app)
    if let s = SharedPlayerManager.shared.availableStreams.first(where: { $0.languageCode == code }) {
        return s.language
    }
    // Fallback mapping (covers the languages used in LA alt buttons + common preview cases).
    // Uses the same keys as the previous private getLanguageName in the Live Activity file.
    switch code {
    case "en": return String(localized: "language_english", table: "Localizable")
    case "de": return String(localized: "language_german", table: "Localizable")
    case "fi": return String(localized: "language_finnish", table: "Localizable")
    case "sv": return String(localized: "language_swedish", table: "Localizable")
    case "et": return String(localized: "language_estonian", table: "Localizable")
    default: return code.capitalized
    }
}

internal func displayFlag(for code: String) -> String {
    switch code {
    case "en": return "🇺🇸"
    case "de": return "🇩🇪"
    case "fi": return "🇫🇮"
    case "sv": return "🇸🇪"
    case "et": return "🇪🇪"
    default: return "🌍"
    }
}

// MARK: - Provider snapshot resolution (Tier 3 hygiene)

/// Canonical resolver for home-widget and Control-widget Provider entry points.
///
/// Documents which paths require an actor hop versus safe direct snapshot reads.
/// Cross-process freshness still depends on main-app ``WidgetRefreshManager`` timeline reloads;
/// the resolver only governs in-process read hygiene inside the extension.
///
/// - SeeAlso: ``SharedPlayerManager/refreshVisualStateFromPersistence()``,
///   ``SharedPlayerManager/loadPersistedWidgetState()``, docs/Widget-Functionality-Roadmap.md.
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
    /// Single source of truth for Provider entry synthesis after snapshot resolution.
    /// Home-widget ``SimpleEntry`` and Control-widget ``Value`` must consume these slices
    /// rather than re-invoking ``PlayerVisualState/makeStatusPresentation()``,
    /// ``PlayerVisualState/makeControlPresentation()``, or ``widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)``
    /// in timeline or value-provider paths.
    ///
    /// - Parameter fields: Authoritative snapshot fields from ``resolveFromSnapshot()`` or
    ///   ``resolveWithActorHygiene(manager:)``.
    /// - Returns: Pre-derived slices ready to populate ``SimpleEntry`` / Control-widget ``Value``.
    /// - SeeAlso: ``WidgetProviderPresentationSlices``, ``WidgetProviderSnapshotFields``,
    ///   docs/Widget-Presentation-Dataflow.md, docs/Widget-Functionality-Roadmap.md.
    nonisolated static func assemblePresentationSlices(
        from fields: WidgetProviderSnapshotFields
    ) -> WidgetProviderPresentationSlices {
        let currentStream = SharedPlayerManager.streamForLanguageCode(fields.currentLanguage)
        let statusPresentation = fields.visualState.makeStatusPresentation()
        let controlPresentation = fields.visualState.makeControlPresentation()
        let statusMessage: String = fields.hasError
            ? String(localized: "Connection error", defaultValue: "Connection error", table: "Localizable")
            : statusPresentation.text
        let metadataModel = widgetNowPlayingDisplayModel(
            visualState: fields.visualState,
            streamMetadata: fields.streamMetadata,
            languageName: currentStream.language
        )
        return WidgetProviderPresentationSlices(
            currentLanguageCode: fields.currentLanguage,
            currentStation: stationLabel(for: fields.currentLanguage),
            statusPresentation: statusPresentation,
            controlPresentation: controlPresentation,
            statusMessage: statusMessage,
            widgetNowPlayingDisplayModel: metadataModel
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
    /// audio was already playing (see lockscreen regression).
    ///
    /// - SeeAlso: ``WidgetIntentCoordinators/resolveLiveActivityToggleVisualState(liveActivityContent:durableMirror:actorVisualState:sessionSnapshot:)``,
    ///   ``SharedPlayerManager/persistLiveActivityToggleVisualStateMirror(_:)``.
    static func performLiveActivityToggle() async {
        let liveActivityContent = currentLiveActivityContentVisualState()
        let durableMirror = SharedPlayerManager.loadLiveActivityToggleVisualStateMirror()
        let actorVisualState = await SharedPlayerManager.shared.currentVisualState
        let sessionSnapshot = SharedPlayerManager.loadPersistedWidgetState()?.visualState

        let resolution = WidgetIntentCoordinators.resolveLiveActivityToggleVisualState(
            liveActivityContent: liveActivityContent,
            durableMirror: durableMirror,
            actorVisualState: actorVisualState,
            sessionSnapshot: sessionSnapshot
        )
        let plan = WidgetIntentCoordinators.planLiveActivityToggle(resolution: resolution)

        #if DEBUG
        print(
            "[WidgetIntentExecution] LA toggle plan=\(plan) source=\(resolution.source.rawValue) state=\(resolution.visualState)"
        )
        #endif

        // Optimistic mirror write so a second rapid tap in a cold extension process
        // plans against the intended post-toggle visual before main-app LA push lands.
        let optimisticTarget: PlayerVisualState = (plan == .pause) ? .userPaused : .playing
        SharedPlayerManager.persistLiveActivityToggleVisualStateMirror(optimisticTarget)

        await executeLiveActivityToggle(plan: plan)
    }

    /// Reads `ContentState.visualState` from the first active/stale Lutheran Radio Live Activity.
    ///
    /// - Returns: Visual state when ActivityKit exposes a live activity in this process; otherwise `nil`.
    /// - Note: App Intent hosts sometimes report an empty activities list; the durable App Group
    ///   mirror is the required fallback in that case.
    nonisolated static func currentLiveActivityContentVisualState() -> PlayerVisualState? {
        let activities = Activity<LutheranRadioLiveActivityAttributes>.activities
        guard let activity = activities.first(where: {
            switch $0.activityState {
            case .active, .stale:
                return true
            default:
                return false
            }
        }) else {
            return nil
        }
        return activity.content.state.visualState
    }

    /// Full Live Activity stream switch path used by ``LiveActivitySwitchStreamIntent/perform()``.
    ///
    /// - Parameter languageCode: Target stream code.
    /// - Returns: `true` when a matching stream was found and the switch was invoked.
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
    /// - Parameter plan: Direction from ``WidgetIntentCoordinators/planLiveActivityToggle(from:)``.
    static func executeLiveActivityToggle(plan: WidgetLiveActivityTogglePlan) async {
        let manager = SharedPlayerManager.shared
        switch plan {
        case .pause:
            await manager.stop()
        case .play:
            await manager.userRequestedPlay()
        @unknown default:
            break
        }
    }
}
