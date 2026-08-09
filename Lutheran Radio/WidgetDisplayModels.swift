//
//  WidgetDisplayModels.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 12.6.2026.
//

// SHARED: Cross-target source (main app + LutheranRadioWidgetExtension)
//
// Membership-exception file compiled into both targets via project.pbxproj.
// Intent *execution* lives in WidgetIntentExecution.swift (same exception set).
//
// Purpose (this file — Provider snapshot resolution + catalog labels that require
// ``SharedPlayerManager``):
// - Stream-catalog-aware ``displayLanguageName(for:)`` (wraps pure WidgetSurface helpers).
// - ``WidgetProviderSnapshotResolver`` — Provider paint reads from process-local session +
//   privacy-gated App Group mirrors (live chrome, program metadata) and stream-catalog
//   station labels; pure presentation assembly is delegated to
//   ``WidgetProviderPresentationAssembly`` in WidgetSurface.
// - ``WidgetInteractivePaintHeal`` — rebuild interactive home paint from
//   ``resolveFromSnapshot()`` and merge lagging TimelineEntry wake tokens with suite
//   (used by the entry view; testable under the extension compile profile).
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
// This file stays cross-target because snapshot resolution must call ``SharedPlayerManager``.
// Intent execution lives in WidgetIntentExecution.swift (same membershipExceptions set).
// Moving those call sites into WidgetSurface would create a circular module dependency
// (`SharedPlayerManager` already imports WidgetSurface).
//
// No security logic and no AVPlayer/streaming ownership.
//
// - SeeAlso: docs/Widget-Presentation-Dataflow.md, docs/Widget-Functionality-Roadmap.md,
//   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§6),
//   docs/Live-Activity-Stacking-and-Media-Surfaces.md (ContentState lag class — peer),
//   ``WidgetProviderPresentationAssembly``, ``WidgetIntentCoordinators``,
//   ``WidgetTimelineEntryFactory``, ``WidgetInteractivePaintHeal``,
//   CODING_AGENT.md (cross-target widget sources).

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

// MARK: - Provider snapshot resolution (paint SSOT + catalog labels)

/// Canonical resolver for home-widget and Control-widget Provider entry points.
///
/// Providers resolve paint via ``resolveFromSnapshot()`` only — no actor hop on the paint
/// path. Cross-process freshness still depends on main-app ``WidgetRefreshManager`` timeline
/// reloads; this type owns ``SharedPlayerManager`` static snapshot / mirror reads and
/// stream-catalog labels. Pure presentation assembly is ``WidgetProviderPresentationAssembly``.
///
/// **Live chrome resolution (visual / language / hasError):**
/// Uses pure ``resolveHomeWidgetChromeFields`` over process-local session + privacy-gated
/// ``homeWidgetLiveChrome``:
/// - Agreeing chrome fields → prefer session (same-process optimistic continuity)
/// - Disagreeing fields → **fresher** `updatedAt` wins (main settle mirror can heal stale
///   extension-session ``.prePlay`` after switch hold)
/// - Only one source → that source; neither → factory ``.prePlay``
/// - Termination sentinel or device reboot (``shouldDistrustDurableMirrorPlayPlanning()``) →
///   treat residual live chrome as **absent** even if the App Group blob remains (dirty exit
///   / power-off must not paint last play/pause glyphs)
///
/// Interactive vs passive chrome still comes from liveness (`lastUpdateTime` /
/// ``WidgetLivenessPresentation``) — live chrome alone is **not** proof the main app is interactive.
///
/// ``SharedPlayerManager/refreshVisualStateFromPersistence()`` remains for main-app cold-launch
/// / coordination paths that need actor ``currentVisualState`` aligned with session RAM; it is
/// not part of normal Provider paint (Control may call it only on the rare App Group-nil fallback).
///
/// - SeeAlso: ``SharedPlayerManager/loadPersistedWidgetState()``,
///   ``SharedPlayerManager/loadHomeWidgetLiveChromeMirror()``,
///   ``SharedPlayerManager/loadHomeWidgetStreamMetadataMirror()``,
///   ``SharedPlayerManager/shouldDistrustDurableMirrorPlayPlanning()``,
///   ``SharedPlayerManager/refreshVisualStateFromPersistence()``,
///   ``resolveHomeWidgetChromeFields(sessionVisual:sessionLanguage:sessionHasError:sessionUpdatedAt:liveChrome:distrustLiveChrome:)``,
///   ``WidgetProviderPresentationAssembly``,
///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§6 Provider read order),
///   docs/Widget-Functionality-Roadmap.md,
///   docs/Widget-Presentation-Dataflow.md.
enum WidgetProviderSnapshotResolver {

    /// Resolves Provider paint fields from process-local session + privacy-gated App Group mirrors.
    ///
    /// Home and Control Providers use this as the sole happy-path paint SSOT. It never consults
    /// ``SharedPlayerManager/currentVisualState`` and performs no actor hop.
    ///
    /// **Chrome resolution (visual / language / hasError):** pure
    /// ``resolveHomeWidgetChromeFields`` — session vs ``homeWidgetLiveChrome`` by field agreement
    /// and wall-clock freshness (not rigid session-first). When
    /// ``shouldDistrustDurableMirrorPlayPlanning()`` is true, residual live chrome is ignored
    /// (factory when session is also empty). Language falls through to
    /// ``preferredWidgetLanguage()`` when both sources leave language empty.
    ///
    /// **Program metadata:** session `streamMetadata` → ``loadHomeWidgetStreamMetadataMirror()``
    /// (unchanged single-concern peer; not folded into live chrome).
    ///
    /// **Must never:** invent ``.playing`` when the winning source holds ``.prePlay`` (switch hold);
    /// treat live chrome as interactive-app proof (liveness still drives passive `tap_to_open`);
    /// paint residual live chrome after termination sentinel or device reboot;
    /// read LA durable mirrors or retired on-disk visual keys for home chrome.
    ///
    /// - Returns: Snapshot fields for Provider presentation assembly; factory defaults when both
    ///   session and live-chrome mirrors are absent or live chrome is distrusted
    ///   (program-metadata mirror may still populate title).
    /// - SeeAlso: docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§6.1–§6.5),
    ///   ``resolveHomeWidgetChromeFields(sessionVisual:sessionLanguage:sessionHasError:sessionUpdatedAt:liveChrome:distrustLiveChrome:)``,
    ///   ``SharedPlayerManager/shouldDistrustDurableMirrorPlayPlanning()``,
    ///   ``SharedPlayerManager/stampHomeWidgetLiveChromeFromSession(visualState:language:hasError:reason:)``,
    ///   ``persistHomeWidgetStreamMetadataMirror`` (program-title peer),
    ///   docs/Widget-Presentation-Dataflow.md.
    nonisolated static func resolveFromSnapshot() -> WidgetProviderSnapshotFields {
        // Program metadata: prefer in-process session snapshot, then privacy-gated App Group
        // mirror. The mirror is required because the session snapshot is process-local (OI-1)
        // while home Providers run in the widget extension and must still show live ICY titles
        // after main-app parse + timeline reload.
        let mirroredMetadata = SharedPlayerManager.loadHomeWidgetStreamMetadataMirror()
        // Live chrome + session: pure freshness selection so main-app settle on the App Group
        // mirror can heal a stale extension-session Connecting hold without rigid session-first.
        // Post-termination / reboot: ignore residual live chrome so passive factory paint wins.
        let liveChrome = SharedPlayerManager.loadHomeWidgetLiveChromeMirror()
        let session = SharedPlayerManager.loadPersistedWidgetState()
        let distrustLiveChrome = SharedPlayerManager.shouldDistrustDurableMirrorPlayPlanning()

        let chrome = resolveHomeWidgetChromeFields(
            sessionVisual: session?.visualState,
            sessionLanguage: session?.currentLanguage,
            sessionHasError: session?.hasError,
            sessionUpdatedAt: session?.updatedAt,
            liveChrome: liveChrome,
            distrustLiveChrome: distrustLiveChrome
        )

        let language = chrome.currentLanguage ?? SharedPlayerManager.preferredWidgetLanguage()
        let streamMetadata = session?.streamMetadata ?? mirroredMetadata

        return WidgetProviderSnapshotFields(
            currentLanguage: language,
            hasError: chrome.hasError,
            visualState: chrome.visualState,
            streamMetadata: streamMetadata
        )
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
    /// - Parameter fields: Authoritative snapshot fields from ``resolveFromSnapshot()``.
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

// MARK: - Interactive home paint heal

/// Snapshot-driven status/control blueprint plus merged paint wake tokens for interactive home paint.
///
/// Same fields ``LutheranRadioWidgetEntryView`` applies when the entry body re-evaluates:
/// status/control/metadata/station come from ``resolveFromSnapshot()``, never from lagging
/// Provider entry slices. ``paintEpoch`` / ``paintSignature`` are wake/identity only — not paint SSOTs.
///
/// - Note: Exercising this type in unit tests asserts heal output given suite + lagging wake
///   tokens. It does not assert that WidgetKit re-evaluated the on-screen home widget.
/// - SeeAlso: ``WidgetInteractivePaintHeal/projectHomeInteractivePaint(laggingPaintEpoch:laggingPaintSignature:date:)``,
///   ``WidgetProviderSnapshotResolver/resolveFromSnapshot()``,
///   docs/Widget-Presentation-Dataflow.md,
///   docs/Live-Activity-Stacking-and-Media-Surfaces.md (ContentState lag class).
struct WidgetInteractivePaintHealProjection: Sendable, Equatable {
    /// Snapshot fields that drove this projection (visual / language / error / metadata).
    let fields: WidgetProviderSnapshotFields
    /// Home-widget blueprint ready for ``SimpleEntry`` (presentation slices + visual).
    let blueprint: WidgetHomeTimelineEntryBlueprint
    /// ``max(lagging entry epoch, suite epoch)`` — TimelineEntry / body identity token.
    let paintEpoch: Int
    /// Suite signature when non-empty; otherwise the lagging entry signature.
    let paintSignature: String
}

/// Rebuilds interactive home-widget presentation from snapshot SSOT.
///
/// Lives in this membership-exception file so extension-profile unit tests can call the same
/// heal path as ``LutheranRadioWidgetEntryView`` without compiling the widget shell
/// (``SimpleEntry``, entry view).
///
/// **What heal does:**
/// 1. ``resolveFromSnapshot()`` — session + privacy-gated ``homeWidgetLiveChrome`` (+ metadata).
/// 2. Assemble slices + home blueprint (status/control match resolved visual).
/// 3. Merge lagging Provider wake tokens with suite: epoch = max; signature prefers suite.
///
/// **What heal never does:** Prefer lagging entry pause/play chrome over resolve; invent
/// visual from epoch/signature alone; dual ``reloadAllTimelines`` thrash.
///
/// - SeeAlso: ``projectHomeInteractivePaint(laggingPaintEpoch:laggingPaintSignature:date:)``,
///   ``WidgetProviderSnapshotResolver/resolveFromSnapshot()``,
///   ``SharedPlayerManager/loadHomeWidgetInteractivePaintEpoch()``,
///   ``SharedPlayerManager/loadHomeWidgetInteractivePaintSignature()``,
///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§6),
///   docs/Live-Activity-Stacking-and-Media-Surfaces.md (ContentState lag class).
enum WidgetInteractivePaintHeal {

    /// Rebuilds interactive home paint from the current snapshot, ignoring lagging entry chrome.
    ///
    /// WidgetKit may still hold a residual ``SimpleEntry`` (e.g. ``.playing`` status/control)
    /// while App Group live chrome already advanced (e.g. ``.userPaused`` after optimistic home
    /// pause). When the entry body re-runs, presentation must follow ``resolveFromSnapshot()`` —
    /// never the lagging entry slices.
    ///
    /// - Parameters:
    ///   - laggingPaintEpoch: ``SimpleEntry/paintEpoch`` from the system-held archive (wake only).
    ///   - laggingPaintSignature: ``SimpleEntry/paintSignature`` from that archive (wake only).
    ///   - date: Timeline entry date retained on the rebuilt blueprint (typically the lagging
    ///     entry’s `date`, or `Date()` in tests).
    /// - Returns: Snapshot-driven blueprint plus merged paint epoch/signature wake tokens.
    /// - Postcondition: ``blueprint.visualState`` equals ``resolveFromSnapshot().visualState``;
    ///   ``paintEpoch`` is ``max(laggingPaintEpoch, suiteEpoch)``; non-empty suite signature wins.
    /// - Note: Callers that need on-screen home-widget honesty after optimistic toggle still
    ///   depend on body re-evaluation (suite ``@AppStorage``, Darwin/local paint-advanced wake,
    ///   ``reloadTimelines``). This method only defines the paint result once heal runs.
    /// - SeeAlso: ``WidgetInteractivePaintHealProjection``,
    ///   ``WidgetProviderSnapshotResolver/resolveFromSnapshot()``,
    ///   ``WidgetTimelineEntryFactory/makeHomeWidgetBlueprint(date:fields:slices:)``.
    nonisolated static func projectHomeInteractivePaint(
        laggingPaintEpoch: Int,
        laggingPaintSignature: String,
        date: Date = Date()
    ) -> WidgetInteractivePaintHealProjection {
        let fields = WidgetProviderSnapshotResolver.resolveFromSnapshot()
        let slices = WidgetProviderSnapshotResolver.assemblePresentationSlices(from: fields)
        let blueprint = WidgetTimelineEntryFactory.makeHomeWidgetBlueprint(
            date: date,
            fields: fields,
            slices: slices
        )
        let suiteEpoch = SharedPlayerManager.loadHomeWidgetInteractivePaintEpoch()
        let suiteSignature = SharedPlayerManager.loadHomeWidgetInteractivePaintSignature()
        return WidgetInteractivePaintHealProjection(
            fields: fields,
            blueprint: blueprint,
            paintEpoch: max(laggingPaintEpoch, suiteEpoch),
            paintSignature: suiteSignature.isEmpty ? laggingPaintSignature : suiteSignature
        )
    }
}
