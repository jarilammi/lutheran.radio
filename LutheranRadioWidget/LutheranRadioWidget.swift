//
//  LutheranRadioWidget.swift
//  LutheranRadioWidget
//
//  Created by Jari Lammi on 3.6.2025.
//

import AppIntents
import SwiftUI
import WidgetKit
import Foundation
import WidgetSurface

// MARK: - Shared Display Logic
//
// WidgetDisplayModels.swift owns the metadata/emphasis axis
// (`WidgetMetadataEmphasis`, `WidgetNowPlayingDisplayModel`, `widgetNowPlayingDisplayModel(...)`).
//
// `SimpleEntry` (the WidgetKit TimelineEntry snapshot) carries the three narrow
// presentation surfaces, each derived exactly once in the Provider:
// - `statusPresentation: PlayerStatusPresentation` (from `makeStatusPresentation`)
// - `controlPresentation: PlayerControlPresentation` (from `makeControlPresentation`)
// - `widgetNowPlayingDisplayModel: WidgetNowPlayingDisplayModel` (from the resolver)
//
// `LutheranRadioWidgetEntryView` projects narrow slices from `SimpleEntry` into
// `SmallWidgetView` / `MediumWidgetView` / `LargeWidgetView`. `WidgetMetadataRegion`
// receives only `WidgetNowPlayingDisplayModel`.
//
// Interactive LIVE scenes re-resolve paint via ``WidgetProviderSnapshotResolver/resolveFromSnapshot()``
// so optimistic App Group ``homeWidgetLiveChrome`` (e.g. pause → ``.userPaused``) is not left
// behind a system-held TimelineEntry that still shows residual ``.playing`` — same honesty class
// as Live Activity ContentState lag after extension toggle. Body re-evaluation is driven by:
// 1. ``@AppStorage`` on paint signature + paint epoch (suite-visible same-process flips)
// 2. Local + Darwin paint-advanced wake (``homeWidgetInteractivePaintAdvanced``) so main settle
//    and cross-process suite stamps re-run heal without suite KVO (peer to widget-action Darwin)
// 3. ``SimpleEntry/paintEpoch`` + ``paintSignature`` for TimelineEntry structural identity after
//    ``reloadTimelines`` (Provider / archive only — **not** root EntryView `.id`)
// Live-chrome load uses CFPreferences re-sync so heal does not re-paint residual playing from a
// stale suite cache. Heal always prefers snapshot SSOT over a lagging Provider entry (never keep
// residual pause chrome when resolve/live chrome already advanced to ``.playing``).
//
// Play/pause control is **direction-bound** (``WidgetPlayRadioIntent`` / ``WidgetPauseRadioIntent``)
// from the control glyph so residual LIVE cannot schedule the opposite verb of the visible
// affordance. ``openAppWhenRun`` is false; root EntryView must **not** thrash structural `.id`
// on paint wakes (intent miss → WidgetKit host open). Home optimistic play never invents
// ``.playing`` (see ``optimisticHomeWidgetVisualAfterPlayPlan``).
//
// The identical top-level derivation pattern is used by Live Activity views.
//
// See docs/Widget-Presentation-Dataflow.md for rationale and contributor guidance.

private enum WidgetMetadataLayout {
    case medium
    case large

    var titleFont: Font {
        switch self {
        case .medium: .caption.weight(.medium)
        case .large: .subheadline.weight(.semibold)
        }
    }

    var speakerFont: Font { self == .medium ? .caption2 : .caption }

    var titleLineLimit: Int { self == .medium ? 1 : 2 }

    var titleHeight: CGFloat { self == .medium ? 18 : 44 }

    var speakerHeight: CGFloat { self == .medium ? 14 : 18 }

    // Leading alignment on .large for visual consistency with the leading header,
    // station/status block, and the left-to-right flow of the 3-column language grid
    var textAlignment: TextAlignment { self == .medium ? .leading : .leading }
    var stackAlignment: HorizontalAlignment { self == .medium ? .leading : .leading }
    var frameAlignment: Alignment { self == .medium ? .leading : .leading }
}

/// Fixed-height program title and speaker slots for medium and large widgets.
///
/// Receives a pre-derived `WidgetNowPlayingDisplayModel` (populated on `SimpleEntry`
/// by the Provider). Deliberately narrow: renders only the four fields with the
/// appropriate emphasis opacity. No `PlayerVisualState` or raw metadata handling.
///
/// - SeeAlso: `WidgetNowPlayingDisplayModel`, `widgetNowPlayingDisplayModel(...)`,
///   `SimpleEntry.widgetNowPlayingDisplayModel`, `MediumWidgetView`, `LargeWidgetView`,
///   `WidgetDisplayModels.swift`, docs/Widget-Presentation-Dataflow.md.
private struct WidgetMetadataRegion: View {
    let model: WidgetNowPlayingDisplayModel
    let layout: WidgetMetadataLayout

    var body: some View {
        VStack(alignment: layout.stackAlignment, spacing: 2) {
            Text(model.programTitle)
                .font(layout.titleFont)
                .foregroundStyle(.primary)
                .multilineTextAlignment(layout.textAlignment)
                .lineLimit(layout.titleLineLimit)
                .minimumScaleFactor(0.85)
                .truncationMode(.tail)
                .opacity(model.emphasis.opacity)
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity, minHeight: layout.titleHeight, maxHeight: layout.titleHeight, alignment: layout.frameAlignment)

            Text(model.speakerLine)
                .font(layout.speakerFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(layout.textAlignment)
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(model.speakerVisible ? model.emphasis.opacity : 0)
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity, minHeight: layout.speakerHeight, maxHeight: layout.speakerHeight, alignment: layout.frameAlignment)
        }
        .frame(maxWidth: .infinity, alignment: layout.frameAlignment)
    }
}

/// Whether widget family views should render the passive `tap_to_open` launch surface.
private func shouldShowPassiveTapToOpen() -> Bool {
    WidgetLivenessPresentation.shouldShowPassiveTapToOpen(
        isMainAppRecentlyActive: SharedPlayerManager.isMainAppProcessRecentlyActive()
    )
}

// MARK: - UIKit → SwiftUI Bridge

extension UIColor {
    /// Widget-shell `UIColor` → SwiftUI `Color` using the labeled `Color(uiColor:)` initializer.
    ///
    /// Live Activity compact chrome reads ``PlayerVisualState/buttonTintColor`` through this
    /// property. Palette mapping itself lives in ``PlayerPresentation`` (`Color(uiColor:)` there).
    ///
    /// - SeeAlso: ``PlayerVisualState/buttonTintColor``, `PlayerPresentation.swift`
    var swiftUIColor: Color { Color(uiColor: self) }
}

// MARK: - Cross-Process State Model (the core of this widget extension)
//
// All widget/extension processes run with a fresh actor instance (currentVisualState
// starts at .prePlay). We therefore never trust the actor's in-memory state for UI decisions.
//
// The PersistedWidgetState snapshot is the single authoritative + optimistic source of
// truth. It is written from the main app on every authoritative save and from widget
// intents for instant feedback.
//
// Provider snapshot resolution is centralized in ``WidgetProviderSnapshotResolver``.
// See docs/Widget-Functionality-Roadmap.md (Tier 3 provider audit) for which paths
// require an actor hop versus safe direct ``loadPersistedWidgetState()`` reads.

/// Home-screen widget (small / medium / large).
///
/// WidgetKit gallery **section** name is the extension `CFBundleDisplayName`
/// (`LutheranRadioWidget/InfoPlist.xcstrings`), not this configuration title.
/// Keep both in lockstep with `"lutheran_radio_title"`. Never restore the
/// target identifier `LutheranRadioWidget` as the gallery section.
///
/// - SeeAlso: `LutheranRadioWidget/InfoPlist.xcstrings`, `lutheran_radio_title`,
///   docs/Widget-Presentation-Dataflow.md, CODING_AGENT.md (Localization).
struct LutheranRadioWidget: Widget {
    let kind: String = "LutheranRadioWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: RadioWidgetConfiguration.self, provider: Provider()) { entry in
            LutheranRadioWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(String(localized: "lutheran_radio_title", table: "Localizable"))
        .description(String(localized: "Control playback and switch between language streams.", defaultValue: "Control playback and switch between language streams.", table: "Localizable"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct Provider: AppIntentTimelineProvider {
    
    func placeholder(in context: Context) -> SimpleEntry {
        // Placeholder via pure factory/assembly path (same narrow slices as timeline entries).
        let fields = WidgetProviderSnapshotFields(
            currentLanguage: "en",
            hasError: false,
            visualState: .prePlay,
            streamMetadata: nil
        )
        let languageName = String(localized: "language_english", table: "Localizable")
        let slices = WidgetProviderPresentationAssembly.assemblePresentationSlices(
            from: fields,
            languageName: languageName,
            stationLabel: "🇺🇸 " + languageName
        )
        let blueprint = WidgetTimelineEntryFactory.makeHomeWidgetBlueprint(
            date: Date(),
            fields: fields,
            slices: slices
        )
        return SimpleEntry(
            blueprint: blueprint,
            availableStreams: SharedPlayerManager.shared.availableStreams,
            configuration: RadioWidgetConfiguration()
        )
    }
    
    func snapshot(for configuration: RadioWidgetConfiguration, in context: Context) async -> SimpleEntry {
        // Mark active immediately: executing in widget process proves a Lutheran widget
        // is installed. This lets preferredWidgetLanguage() take the hasActive branch
        // (bestInitial) on first-run / no-snapshot instead of hard "en".
        Task { @MainActor in WidgetRefreshManager.setHasActiveLutheranWidgets(true) }
        return await createEntry(with: configuration)
    }
    
    func timeline(for configuration: RadioWidgetConfiguration, in context: Context) async -> Timeline<SimpleEntry> {
        Task { @MainActor in WidgetRefreshManager.setHasActiveLutheranWidgets(true) }
        let manager = SharedPlayerManager.shared
        let entry = await makeTimelineEntry(with: configuration, manager: manager)
        
        // Safe date calculation
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())
            ?? Date().addingTimeInterval(15 * 60)
        
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }
    
    // MARK: - Async helpers (required for actor isolation)
    
    private func createEntry(with configuration: RadioWidgetConfiguration) async -> SimpleEntry {
        Task { @MainActor in WidgetRefreshManager.setHasActiveLutheranWidgets(true) }
        return await makeTimelineEntry(with: configuration, manager: SharedPlayerManager.shared)
    }

    private func makeTimelineEntry(
        with configuration: RadioWidgetConfiguration,
        manager: SharedPlayerManager
    ) async -> SimpleEntry {
        // Paint SSOT: session + privacy-gated live chrome + program-metadata mirror.
        // No actor hop — ``resolveFromSnapshot()`` never consults ``currentVisualState``.
        let fields = WidgetProviderSnapshotResolver.resolveFromSnapshot()
        let slices = WidgetProviderSnapshotResolver.assemblePresentationSlices(from: fields)
        let blueprint = WidgetTimelineEntryFactory.makeHomeWidgetBlueprint(
            date: Date(),
            fields: fields,
            slices: slices
        )

        #if DEBUG
        print("[LutheranRadioWidget] Widget creating entry: visualState=\(blueprint.visualState), station=\(blueprint.currentStation)")
        #endif

        let paintEpoch = SharedPlayerManager.loadHomeWidgetInteractivePaintEpoch()
        let paintSignature = SharedPlayerManager.loadHomeWidgetInteractivePaintSignature()
        return SimpleEntry(
            blueprint: blueprint,
            availableStreams: manager.availableStreams,
            configuration: configuration,
            paintEpoch: paintEpoch,
            paintSignature: paintSignature
        )
    }
}

/// Home-widget timeline entry: narrow presentation slices only.
///
/// Does **not** store full ``PlayerVisualState`` policy, raw ``StreamProgramMetadata``,
/// or a redundant `statusMessage` string. Status/control/metadata are pre-derived once
/// in the Provider (via ``WidgetProviderPresentationAssembly`` + ``WidgetTimelineEntryFactory``);
/// family views read only the fields projected below.
///
/// ``paintEpoch`` / ``paintSignature`` are wake/identity fields only (not paint SSOT) so WidgetKit
/// structural comparison treats post-toggle Provider entries as distinct from residual archives.
///
/// - SeeAlso: ``WidgetHomeTimelineEntryBlueprint``, docs/Widget-Presentation-Dataflow.md.
struct SimpleEntry: TimelineEntry, Sendable {
    let date: Date
    let currentStation: String
    let currentLanguageCode: String
    /// Interactive paint wake token captured at Provider resolve time (not a visual SSOT).
    let paintEpoch: Int
    /// Interactive paint signature captured at Provider resolve time (not a visual SSOT).
    let paintSignature: String

    init(
        blueprint: WidgetHomeTimelineEntryBlueprint,
        availableStreams: [DirectStreamingPlayer.Stream],
        configuration: RadioWidgetConfiguration,
        paintEpoch: Int = 0,
        paintSignature: String = ""
    ) {
        self.date = blueprint.date
        self.currentStation = blueprint.currentStation
        self.currentLanguageCode = blueprint.currentLanguageCode
        self.statusPresentation = blueprint.statusPresentation
        self.controlPresentation = blueprint.controlPresentation
        self.widgetNowPlayingDisplayModel = blueprint.widgetNowPlayingDisplayModel
        self.availableStreams = availableStreams
        self.configuration = configuration
        self.paintEpoch = paintEpoch
        self.paintSignature = paintSignature
    }

    init(
        date: Date,
        currentStation: String,
        currentLanguageCode: String,
        statusPresentation: PlayerStatusPresentation,
        controlPresentation: PlayerControlPresentation,
        widgetNowPlayingDisplayModel: WidgetNowPlayingDisplayModel,
        availableStreams: [DirectStreamingPlayer.Stream],
        configuration: RadioWidgetConfiguration,
        paintEpoch: Int = 0,
        paintSignature: String = ""
    ) {
        self.date = date
        self.currentStation = currentStation
        self.currentLanguageCode = currentLanguageCode
        self.statusPresentation = statusPresentation
        self.controlPresentation = controlPresentation
        self.widgetNowPlayingDisplayModel = widgetNowPlayingDisplayModel
        self.availableStreams = availableStreams
        self.configuration = configuration
        self.paintEpoch = paintEpoch
        self.paintSignature = paintSignature
    }

    /// Narrow presentation for the status indicator (text + associated colors).
    ///
    /// Populated from ``PlayerVisualState/makeStatusPresentation()`` (with `hasError`
    /// folded into `text` at assembly time). Family views never re-read policy state.
    ///
    /// - SeeAlso: `PlayerStatusPresentation`, ``PlayerVisualState/makeStatusPresentation()``,
    ///   `controlPresentation`.
    let statusPresentation: PlayerStatusPresentation

    /// Narrow presentation for the primary play/pause control affordance.
    ///
    /// Populated from ``PlayerVisualState/makeControlPresentation()`` (SSOT) in the provider.
    /// Contains only the `systemImage` and `tint` needed by the control button.
    ///
    /// - SeeAlso: `PlayerControlPresentation`, ``PlayerVisualState/makeControlPresentation()``,
    ///   `statusPresentation`, LutheranRadioWidgetLiveActivity.
    let controlPresentation: PlayerControlPresentation

    /// Pre-derived display model for program title, speaker line, visibility and emphasis.
    ///
    /// Populated once per snapshot from ``widgetNowPlayingDisplayModel`` inside Provider
    /// assembly. Medium/Large and ``WidgetMetadataRegion`` read this value directly.
    ///
    /// - SeeAlso: `WidgetNowPlayingDisplayModel`, `WidgetMetadataRegion`,
    ///   `SimpleEntry.statusPresentation`, `SimpleEntry.controlPresentation`.
    let widgetNowPlayingDisplayModel: WidgetNowPlayingDisplayModel

    let availableStreams: [DirectStreamingPlayer.Stream]
    let configuration: RadioWidgetConfiguration
}

/// Routes a timeline snapshot to the correct family view using narrow presentation slices.
///
/// Projects only the fields each family view reads from `SimpleEntry`, so unrelated
/// entry fields (for example `configuration` or `streamMetadata`) do not participate
/// in the family view's stored property dependency set.
///
/// **Interactive paint heal:** Before projecting, re-resolves status/control/metadata/station
/// from ``WidgetProviderSnapshotResolver/resolveFromSnapshot()`` (session + privacy-gated
/// ``homeWidgetLiveChrome``). Provider-built ``SimpleEntry`` remains the WidgetKit wake payload
/// and archival timeline SSOT; LIVE interactive scenes can lag that archive after
/// optimistic stamps (durable chrome already ``.userPaused`` while the system-held entry still
/// shows residual ``.playing`` / green pause — or residual Tauko after soft-resume settle).
/// Re-resolve is the home-widget peer to Live Activity optimistic ContentState push — paint
/// follows App Group chrome when the body re-evaluates, without trusting
/// ``SharedPlayerManager/currentVisualState``.
///
/// **Why suite tokens + Darwin/local wake:** ``resolveFromSnapshot()`` only helps when body
/// re-runs. WidgetKit often keeps an archived LIVE tree. ``@AppStorage`` on signature + epoch
/// covers same-process suite flips; local NC + Darwin ``homeWidgetInteractivePaintAdvanced``
/// covers intent-handler vs render process splits and main-app settle stamps (without dual
/// ``reloadAllTimelines`` thrash). Heal **always** rebuilds via
/// ``WidgetInteractivePaintHeal/projectHomeInteractivePaint`` (snapshot SSOT) — never preferring
/// a lagging Provider entry pause over resolve ``.playing`` (that blocked soft-resume settle).
///
/// - SeeAlso: `SmallWidgetView`, `MediumWidgetView`, `LargeWidgetView`,
///   ``WidgetInteractivePaintHeal/projectHomeInteractivePaint(laggingPaintEpoch:laggingPaintSignature:date:)``,
///   ``WidgetProviderSnapshotResolver/resolveFromSnapshot()``,
///   ``SharedPlayerManager/bumpHomeWidgetInteractivePaintEpoch(reason:)``,
///   ``SharedPlayerManager/postHomeWidgetInteractivePaintAdvancedWake()``,
///   ``WidgetIntentExecution/executeOptimisticToggle(plan:language:)``,
///   docs/Widget-Presentation-Dataflow.md, docs/Widget-Functionality-Roadmap.md,
///   docs/Live-Activity-Stacking-and-Media-Surfaces.md (ContentState lag class).
struct LutheranRadioWidgetEntryView: View {
    var entry: Provider.Entry
    @Environment(\.widgetFamily) var family

    /// App Group suite for interactive paint observation (same container as live chrome).
    ///
    /// Falls back to `.standard` only if the suite is unavailable (should not happen for a
    /// correctly signed extension); paint heal still re-resolves from snapshot readers.
    private static let appGroupDefaults =
        UserDefaults(suiteName: "group.radio.lutheran.shared") ?? .standard

    /// One-time Darwin → local NC bridge registration for this process.
    private static let paintWakeObserverRegistration: Void = {
        SharedPlayerManager.registerHomeWidgetInteractivePaintWakeObserverIfNeeded()
    }()

    /// Wake token: epoch + visual + language; flips when live chrome or optimistic toggle advances.
    ///
    /// Reading this property creates a SwiftUI dependency so body re-runs after
    /// ``publishHomeWidgetInteractivePaintSignature`` when the suite mutation is visible in-process.
    @AppStorage(
        SharedPlayerManager.homeWidgetInteractivePaintSignatureAppGroupKey,
        store: LutheranRadioWidgetEntryView.appGroupDefaults
    )
    private var interactivePaintSignature: String = ""

    /// Integer epoch companion — dual suite observation when String KVO is skipped.
    @AppStorage(
        SharedPlayerManager.homeWidgetInteractivePaintEpochAppGroupKey,
        store: LutheranRadioWidgetEntryView.appGroupDefaults
    )
    private var interactivePaintEpoch: Int = 0

    /// Local generation advanced by Darwin/local paint-advanced wake (cross-process settle).
    @State private var paintWakeGeneration: UInt = 0

    var body: some View {
        // SECURITY / RENDERING NOTE: WidgetKit (iOS 17+) requires .containerBackground(for: .widget)
        // on the timeline entry view (or an ancestor). Plain .background(...) on the widget content
        // root causes the system to render the diagnostic text "Please adopt containerBackground API"
        // on physical devices (and some simulator configurations).
        //
        // Single application point here ensures all three families (small/medium/large) and both
        // the "tap to open" (!isAppRunning) and active playback states receive a proper container fill.
        // We use Color(uiColor: .systemBackground) to match the previous explicit intent while satisfying the API.
        //
        // See also: LutheranRadioWidget.swift (the three size views no longer apply root .background),
        // WidgetKit documentation on container backgrounds, and CODING_AGENT.md "Single Source of Truth".
        //
        // Paint heal: re-resolve from snapshot SSOT (CFPreferences re-sync on live-chrome load) so
        // interactive LIVE does not keep residual playing/pause chrome after optimistic toggle or
        // main settle. Suite + Darwin/local wake dependencies force body re-eval.
        let _ = Self.paintWakeObserverRegistration
        // @AppStorage + paintWakeGeneration create body dependencies for suite/Darwin wakes so
        // interactive paint heal re-runs. Do **not** put those tokens (or presentation chrome)
        // into a root `.id` — structural identity thrash recreates AppIntent buttons and drops
        // the hit target (intent miss → host open; see AGENT NOTE below).
        let _ = interactivePaintSignature
        let _ = interactivePaintEpoch
        let _ = paintWakeGeneration
        let paint = Self.interactivePaintEntry(from: entry)
        Group {
            switch family {
            case .systemSmall:
                SmallWidgetView(
                    statusPresentation: paint.statusPresentation,
                    controlPresentation: paint.controlPresentation,
                    currentLanguageCode: paint.currentLanguageCode,
                    availableStreams: paint.availableStreams
                )
            case .systemMedium:
                MediumWidgetView(
                    statusPresentation: paint.statusPresentation,
                    controlPresentation: paint.controlPresentation,
                    metadataModel: paint.widgetNowPlayingDisplayModel,
                    currentStation: paint.currentStation,
                    currentLanguageCode: paint.currentLanguageCode,
                    availableStreams: paint.availableStreams
                )
            case .systemLarge:
                LargeWidgetView(
                    statusPresentation: paint.statusPresentation,
                    controlPresentation: paint.controlPresentation,
                    metadataModel: paint.widgetNowPlayingDisplayModel,
                    currentStation: paint.currentStation,
                    currentLanguageCode: paint.currentLanguageCode,
                    availableStreams: paint.availableStreams
                )
            default:
                SmallWidgetView(
                    statusPresentation: paint.statusPresentation,
                    controlPresentation: paint.controlPresentation,
                    currentLanguageCode: paint.currentLanguageCode,
                    availableStreams: paint.availableStreams
                )
            }
        }
        // AGENT NOTE — open-host / intent-miss (home play/pause):
        // When the AppIntent button is not hit, WidgetKit opens the host app: main may show
        // ``sceneDidBecomeActive`` with **no** ``WidgetPauseRadioIntent.perform``, no
        // pending-mailbox/Darwin drain, no ``stop()`` / sticky userPaused — audio keeps playing.
        // That is default host open, not interactive LIVE residual paint (pause never started).
        //
        // Root cause: thrashing structural identity around interactive buttons.
        // ``liveChromeIdentitySkipWake`` after an identical playing stamp advances suite
        // epoch/signature + Darwin paint-advanced wake. Folding any of paintSignature, paint
        // epoch, paintWakeGeneration, or presentation chrome into a root `.id` destroys/recreates
        // the entire interactive tree (and Button intent targets). Body re-eval via the
        // `let _ =` suite/wake deps above is enough for heal to update Text/Image bindings;
        // Button identity is direction-stable (see ``homeWidgetPlayPauseButton``). Never re-add
        // a root `.id` wake token without eyes-on proof that open-host is gone.
        .onReceive(
            NotificationCenter.default.publisher(
                for: SharedPlayerManager.homeWidgetInteractivePaintAdvancedNotification
            )
        ) { _ in
            paintWakeGeneration &+= 1
        }
        .containerBackground(for: .widget) {
            Color(uiColor: .systemBackground)
        }
    }

    /// Rebuilds presentation slices from the current snapshot SSOT for interactive paint honesty.
    ///
    /// Thin shell over ``WidgetInteractivePaintHeal/projectHomeInteractivePaint`` so heal math
    /// is shared with extension-profile unit tests; this view keeps streams and configuration
    /// from the WidgetKit-delivered entry. Always prefers resolve over lagging entry chrome —
    /// never keep residual pause when suite already advanced to ``.playing``.
    ///
    /// - Parameter entry: WidgetKit-delivered timeline entry (streams + configuration retained).
    /// - Returns: Entry whose status/control/metadata/station match snapshot SSOT.
    /// - SeeAlso: ``WidgetInteractivePaintHeal/projectHomeInteractivePaint(laggingPaintEpoch:laggingPaintSignature:date:)``,
    ///   ``WidgetProviderSnapshotResolver/resolveFromSnapshot()``,
    ///   ``SharedPlayerManager/loadHomeWidgetLiveChromeMirror()`` (suite re-sync on read).
    private static func interactivePaintEntry(from entry: SimpleEntry) -> SimpleEntry {
        let projection = WidgetInteractivePaintHeal.projectHomeInteractivePaint(
            laggingPaintEpoch: entry.paintEpoch,
            laggingPaintSignature: entry.paintSignature,
            date: entry.date
        )
        return SimpleEntry(
            blueprint: projection.blueprint,
            availableStreams: entry.availableStreams,
            configuration: entry.configuration,
            paintEpoch: projection.paintEpoch,
            paintSignature: projection.paintSignature
        )
    }
}

// MARK: - Small Widget (2x2)

/// Two-by-two home-screen widget.
///
/// Receives only the narrow slices required for rendering: status and control
/// presentations plus stream-selection data. Does not depend on the full `SimpleEntry`.
///
/// - SeeAlso: `LutheranRadioWidgetEntryView` (projection site), `MediumWidgetView`,
///   docs/Widget-Presentation-Dataflow.md.
struct SmallWidgetView: View {
    let statusPresentation: PlayerStatusPresentation
    let controlPresentation: PlayerControlPresentation
    let currentLanguageCode: String
    let availableStreams: [DirectStreamingPlayer.Stream]

    var body: some View {
        if shouldShowPassiveTapToOpen() {
            WidgetPassiveTapToOpenChrome(style: .small)
                .padding()
                .widgetURL(URL(string: "lutheranradio://open"))
        } else {
            VStack(spacing: 4) {
                Text(statusPresentation.text)
                    .font(.caption2)
                    .foregroundStyle(statusPresentation.foreground)
                    .lineLimit(1)
                    // Marks status for invalidation while App Intent / timeline settle (interactive
                    // residual LIVE class — Toistaa ↔ Tauko after home pause/resume).
                    .invalidatableContent()

                if availableStreams.count > 1 {
                    let topRow = Array(availableStreams.prefix(3))
                    let bottomRow = Array(availableStreams.dropFirst(3).prefix(2))

                    VStack(spacing: 3) {
                        HStack(spacing: 4) {
                            ForEach(topRow, id: \.languageCode) { stream in
                                homeWidgetStreamFlagButton(for: stream, expandsToFill: false)
                            }
                        }
                        HStack(spacing: 4) {
                            ForEach(bottomRow, id: \.languageCode) { stream in
                                homeWidgetStreamFlagButton(for: stream, expandsToFill: false)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)

                // Direction-bound control: pause glyph → pause intent; play glyph → play intent.
                // Residual LIVE lag cannot invert the scheduled verb the way a single toggle can
                // when the visible glyph disagrees with App Group resolve.
                homeWidgetPlayPauseButton(controlPresentation: controlPresentation, font: .title2)
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func homeWidgetStreamFlagButton(
        for stream: DirectStreamingPlayer.Stream,
        expandsToFill: Bool
    ) -> some View {
        Button(intent: SwitchStreamIntent(streamLanguageCode: stream.languageCode)) {
            WidgetStreamChipLabel(
                flag: stream.flag,
                isSelected: stream.languageCode == currentLanguageCode,
                style: .flagOnly,
                expandsToFill: expandsToFill
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Medium Widget (4x2)

/// Four-by-two home-screen widget.
///
/// Receives pre-derived narrow presentation slices plus station and metadata models.
/// Does not depend on the full `SimpleEntry` snapshot.
///
/// - SeeAlso: `LutheranRadioWidgetEntryView`, `WidgetMetadataRegion`,
///   docs/Widget-Presentation-Dataflow.md.
struct MediumWidgetView: View {
    let statusPresentation: PlayerStatusPresentation
    let controlPresentation: PlayerControlPresentation
    let metadataModel: WidgetNowPlayingDisplayModel
    let currentStation: String
    let currentLanguageCode: String
    let availableStreams: [DirectStreamingPlayer.Stream]

    var body: some View {
        if shouldShowPassiveTapToOpen() {
            HStack {
                WidgetPassiveTapToOpenChrome(style: .medium)
            }
            .padding()
            .widgetURL(URL(string: "lutheranradio://open"))
        } else {
            // Consume pre-derived narrow surfaces from the snapshot (SimpleEntry).
            // Derivation happened once in the Provider. No resolver calls inside body.
            VStack(spacing: 6) {
                HStack {
                    Text(String(localized: "lutheran_radio_title", table: "Localizable"))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    // Direction-bound control (pause glyph → pause intent; play glyph → play intent).
                    homeWidgetPlayPauseButton(controlPresentation: controlPresentation, font: .title3)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(currentStation)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text(statusPresentation.text)
                        .font(.caption2)
                        .foregroundStyle(statusPresentation.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .invalidatableContent()
                }

                WidgetMetadataRegion(model: metadataModel, layout: .medium)

                Spacer(minLength: 4)

                if availableStreams.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(availableStreams, id: \.languageCode) { stream in
                            Button(intent: SwitchStreamIntent(streamLanguageCode: stream.languageCode)) {
                                WidgetStreamChipLabel(
                                    flag: stream.flag,
                                    isSelected: stream.languageCode == currentLanguageCode,
                                    style: .flagOnly,
                                    expandsToFill: true
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(10)
        }
    }
}

// MARK: - Large Widget (4x4)

/// Four-by-four home-screen widget.
///
/// Receives the same narrow input contract as `MediumWidgetView` with large-family layout.
/// Does not depend on the full `SimpleEntry` snapshot.
///
/// - SeeAlso: `LutheranRadioWidgetEntryView`, `WidgetMetadataRegion`,
///   docs/Widget-Presentation-Dataflow.md.
struct LargeWidgetView: View {
    let statusPresentation: PlayerStatusPresentation
    let controlPresentation: PlayerControlPresentation
    let metadataModel: WidgetNowPlayingDisplayModel
    let currentStation: String
    let currentLanguageCode: String
    let availableStreams: [DirectStreamingPlayer.Stream]

    var body: some View {
        if shouldShowPassiveTapToOpen() {
            WidgetPassiveTapToOpenChrome(style: .large)
                .padding()
                .widgetURL(URL(string: "lutheranradio://open"))
        } else {
            // Consume pre-derived narrow surfaces from the snapshot (SimpleEntry).
            // Derivation happened once in the Provider. Equivalent to how
            // statusPresentation and controlPresentation are consumed.
            VStack(spacing: 12) {
                HStack {
                    Text(String(localized: "lutheran_radio_title", table: "Localizable"))
                        .font(.headline)
                        .fontWeight(.bold)
                    Spacer()
                    // Direction-bound control (pause glyph → pause intent; play glyph → play intent).
                    homeWidgetPlayPauseButton(controlPresentation: controlPresentation, font: .title2)
                }

                VStack(spacing: 4) {
                    Text(currentStation)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)

                    Text(statusPresentation.text)
                        .font(.subheadline)
                        .foregroundStyle(statusPresentation.foreground)
                        .invalidatableContent()
                }

                WidgetMetadataRegion(model: metadataModel, layout: .large)

                Spacer(minLength: 4)

                Divider()

                // 3-column grid on large. With the current 5 streams this yields a balanced
                // 3 + 2 layout; scales cleanly to larger sets (e.g. 21).
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                    spacing: 8
                ) {
                    ForEach(availableStreams, id: \.languageCode) { stream in
                        Button(intent: SwitchStreamIntent(streamLanguageCode: stream.languageCode)) {
                            WidgetStreamChipLabel(
                                flag: stream.flag,
                                languageName: stream.language,
                                isSelected: stream.languageCode == currentLanguageCode,
                                style: .labeled
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding()
        }
    }
}

// MARK: - Home play/pause control (direction-bound)

/// Builds the home-widget play/pause button from narrow ``PlayerControlPresentation``.
///
/// Pause glyph (`pause.fill`) wires ``WidgetPauseRadioIntent``; every other control glyph
/// (play / connecting) wires ``WidgetPlayRadioIntent``. Direction-bound intents keep residual
/// LIVE paint from scheduling the opposite verb of the visible affordance.
///
/// **Paint honesty:** Callers pass control from ``LutheranRadioWidgetEntryView`` interactive
/// paint heal (``WidgetInteractivePaintHeal`` → ``resolveFromSnapshot()``). This control does
/// **not** re-resolve independently — a second suite read mid-body could disagree with the
/// parent slice and thrash Button identity (intent miss → host open).
///
/// **Hit target:** Expanded tappable area (peer to Live Activity control chrome) so a small
/// SF Symbol glyph is not the only hit region; miss → WidgetKit default host open.
///
/// - Parameters:
///   - controlPresentation: Pre-derived control slice from Provider / interactive paint heal.
///   - font: Family-specific control font.
/// - Important: `@MainActor` is required so ``ButtonStyle/plain`` (main-actor static) is legal
///   from this free function. Call sites are widget `View` bodies (already main-actor).
/// - SeeAlso: ``WidgetPlayRadioIntent``, ``WidgetPauseRadioIntent``,
///   ``PlayerVisualState/makeControlPresentation()``,
///   ``LutheranRadioWidgetEntryView`` (heal SSOT).
@MainActor
@ViewBuilder
private func homeWidgetPlayPauseButton(
    controlPresentation: PlayerControlPresentation,
    font: Font
) -> some View {
    // Control SSOT for the button: parent heal slice only (actively playing → `pause.fill`).
    // Button identity is **direction only** (pause vs play intent). Never include paint
    // epoch/signature/wake generation — those recreate AppIntent buttons and drop hit testing
    // (tap falls through to host-app open). Residual chrome text/glyph is owned by entry-view
    // heal body re-eval, not by thrashing this Button.
    // Do not mark the control with ``invalidatableContent()`` — Apple guidance is judicious use
    // on important data views; annotating the interactive control risks a non-tappable settle
    // window while status text already uses invalidatableContent for residual LIVE honesty.
    let isPause = controlPresentation.systemImage == "pause.fill"
    let label = Image(systemName: controlPresentation.systemImage)
        .font(font)
        .foregroundStyle(controlPresentation.tint)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .contentTransition(.opacity)
    if isPause {
        Button(intent: WidgetPauseRadioIntent()) { label }
            .buttonStyle(.plain)
            .id("home-control-pause")
            .accessibilityLabel(
                String(localized: "accessibility_label_pause", defaultValue: "Pause", table: "Localizable")
            )
    } else {
        Button(intent: WidgetPlayRadioIntent()) { label }
            .buttonStyle(.plain)
            .id("home-control-play")
            .accessibilityLabel(
                String(localized: "Play", defaultValue: "Play", table: "Localizable")
            )
    }
}

// MARK: - App Intents

/// Direction-explicit **play** from the home-widget control (play glyph).
///
/// Runs in the widget extension process. Does **not** open the main app
/// (``openAppWhenRun`` is `false`). Audio work is pending-mailbox + Darwin to a
/// already-running/background main process when present.
///
/// - SeeAlso: ``WidgetIntentExecution/performHomeWidgetPlay()``, ``WidgetPauseRadioIntent``.
struct WidgetPlayRadioIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Play Lutheran Radio" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Start or resume Lutheran Radio playback.")
    }
    /// Interactive home control must stay in-widget; never foreground main for play/pause.
    nonisolated static var openAppWhenRun: Bool { false }

    init() {}

    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[LutheranRadioWidget] WidgetPlayRadioIntent.perform called")
        #endif
        await WidgetIntentExecution.performHomeWidgetPlay()
        #if DEBUG
        print("[LutheranRadioWidget] WidgetPlayRadioIntent completed")
        #endif
        return .result()
    }
}

/// Direction-explicit **pause** from the home-widget control (pause glyph).
///
/// Runs in the widget extension process. Does **not** open the main app
/// (``openAppWhenRun`` is `false`).
///
/// - SeeAlso: ``WidgetIntentExecution/performHomeWidgetPause()``, ``WidgetPlayRadioIntent``.
struct WidgetPauseRadioIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Pause Lutheran Radio" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Pause Lutheran Radio playback.")
    }
    /// Interactive home control must stay in-widget; never foreground main for play/pause.
    nonisolated static var openAppWhenRun: Bool { false }

    init() {}

    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[LutheranRadioWidget] WidgetPauseRadioIntent.perform called")
        #endif
        await WidgetIntentExecution.performHomeWidgetPause()
        #if DEBUG
        print("[LutheranRadioWidget] WidgetPauseRadioIntent completed")
        #endif
        return .result()
    }
}

/// Legacy single-intent toggle (tests / Shortcuts). Home family views use direction-bound intents.
///
/// Does **not** open the main app (``openAppWhenRun`` is `false`) — same in-widget contract as
/// ``WidgetPlayRadioIntent`` / ``WidgetPauseRadioIntent``. Prefer those direction-bound intents
/// for LIVE chrome so residual glyphs cannot invert the scheduled verb.
///
/// - SeeAlso: ``WidgetIntentExecution/performHomeWidgetToggle()``, ``WidgetPlayRadioIntent``.
struct WidgetToggleRadioIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Toggle Lutheran Radio" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Play or pause Lutheran Radio.")
    }
    /// Shortcuts / tests must stay in-widget; never foreground main for a toggle.
    nonisolated static var openAppWhenRun: Bool { false }

    init() {}
    
    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[LutheranRadioWidget] WidgetToggleRadioIntent.perform called")
        #endif

        // AGENT NOTE: Full path is ``WidgetIntentExecution/performHomeWidgetToggle()`` so
        // extension-profile unit tests exercise the same body as this AppIntent.
        await WidgetIntentExecution.performHomeWidgetToggle()

        #if DEBUG
        print("[LutheranRadioWidget] WidgetToggleRadioIntent completed")
        #endif

        return .result()
    }
}

public struct SwitchStreamIntent: AppIntent {
    public init() {}
    public init(streamLanguageCode: String) {
        self.streamLanguageCode = streamLanguageCode
    }

    public nonisolated static var title: LocalizedStringResource { "Switch Stream" }
    public nonisolated static var description: IntentDescription {
        IntentDescription("Switch to a different language stream.")
    }
    /// Stream chips must stay in-widget; never foreground main for language switch.
    public nonisolated static var openAppWhenRun: Bool { false }

    @Parameter(title: "Language Code")
    var streamLanguageCode: String

    public func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[LutheranRadioWidget] SwitchStreamIntent.perform called for language: \(streamLanguageCode)")
        #endif

        // AGENT NOTE: Full path is ``WidgetIntentExecution/performHomeWidgetStreamSwitch(languageCode:)``.
        await WidgetIntentExecution.performHomeWidgetStreamSwitch(languageCode: streamLanguageCode)

        #if DEBUG
        print("[LutheranRadioWidget] SwitchStreamIntent completed for \(streamLanguageCode)")
        #endif

        return .result()
    }
}

public struct RadioWidgetConfiguration: WidgetConfigurationIntent {
    public init() {}

    public nonisolated static var title: LocalizedStringResource { "Widget Configuration" }
    public nonisolated static var description: IntentDescription {
        IntentDescription("Configuration for Lutheran Radio widget.")
    }
}

// MARK: - SwiftUI Preview Matrix
//
// Exhaustive previews exercising the full snapshot-driven contract:
// all three narrow presentations are derived for every entry
// (`statusPresentation`, `controlPresentation`, `widgetNowPlayingDisplayModel`).
//
// Covers `PlayerVisualState` cases + metadata presence/absence combinations.
// WidgetMetadataRegion receives the pre-derived model exactly as runtime views do.
// The same models are used by Live Activity surfaces.
//
// Use the canvas to verify emphasis levels and stable title/speaker layout
// (no conditional insertion).
//
// - SeeAlso: `WidgetDisplayModels.swift`, docs/Widget-Presentation-Dataflow.md,
//   `LutheranRadioWidgetLiveActivity.swift`.

#if DEBUG

private func makePreviewEntry(
    visualState: PlayerVisualState,
    currentStation: String? = nil,
    currentLanguageCode: String = "en",
    programTitle: String? = nil,
    speaker: String? = nil
) -> SimpleEntry {
    // Resolve language name + flag from code in a general way (prefers real streams;
    // falls back to the established localized mapping). This replaces the previous
    // hard-coded "🇺🇸 English" / "Lutheran Radio - English" defaults.
    let languageName = displayLanguageName(for: currentLanguageCode)
    let flag = displayFlag(for: currentLanguageCode)
    let station = currentStation ?? "\(flag) \(languageName)"

    let metadata: StreamProgramMetadata? =
        (programTitle != nil || speaker != nil)
        ? StreamProgramMetadata(programTitle: programTitle, speaker: speaker)
        : nil

    // Prefer real streams (nonisolated accessor from SharedPlayerManager).
    // When synthesizing (isolated preview canvas), build using the general form requested:
    //   String(localized: "lutheran_radio_title", table: "Localizable") + " - " + previewLanguageName(...)
    // plus a small set of additional languages so the medium/large flag grids have content.
    let streams: [DirectStreamingPlayer.Stream] =
        SharedPlayerManager.shared.availableStreams.isEmpty
        ? [
            .init(
                title: String(localized: "lutheran_radio_title", table: "Localizable") + " - " + languageName,
                language: languageName,
                languageCode: currentLanguageCode,
                flag: flag
            ),
            .init(
                title: String(localized: "lutheran_radio_title", table: "Localizable") + " - " + displayLanguageName(for: "de"),
                language: displayLanguageName(for: "de"),
                languageCode: "de",
                flag: displayFlag(for: "de")
            ),
            .init(
                title: String(localized: "lutheran_radio_title", table: "Localizable") + " - " + displayLanguageName(for: "fi"),
                language: displayLanguageName(for: "fi"),
                languageCode: "fi",
                flag: displayFlag(for: "fi")
            )
          ]
        : SharedPlayerManager.shared.availableStreams

    // Always derive status + control + metadata presentations from the visualState (single sources of truth).
    // This removes any need for overrides in preview construction and ensures the
    // exhaustive preview matrix exercises all three mappers (status + control + metadata)
    // used at runtime by the Provider (SimpleEntry) and by Live Activity views.
    //
    // widgetNowPlayingDisplayModel(...) is now the canonical derivation for the
    // title/speaker/emphasis carried on SimpleEntry (no adapter inside view bodies).
    let pres = visualState.makeStatusPresentation()
    let controlPres = visualState.makeControlPresentation()
    let metaModel = widgetNowPlayingDisplayModel(
        visualState: visualState,
        streamMetadata: metadata,
        languageName: languageName
    )

    return SimpleEntry(
        date: Date(),
        currentStation: station,
        currentLanguageCode: currentLanguageCode,
        statusPresentation: pres,
        controlPresentation: controlPres,
        widgetNowPlayingDisplayModel: metaModel,
        availableStreams: streams,
        configuration: RadioWidgetConfiguration()
    )
}

/// Projects a preview `SimpleEntry` into the narrow inputs `SmallWidgetView` consumes at runtime.
private func smallWidgetView(from entry: SimpleEntry) -> SmallWidgetView {
    SmallWidgetView(
        statusPresentation: entry.statusPresentation,
        controlPresentation: entry.controlPresentation,
        currentLanguageCode: entry.currentLanguageCode,
        availableStreams: entry.availableStreams
    )
}

/// Projects a preview `SimpleEntry` into the narrow inputs `MediumWidgetView` consumes at runtime.
private func mediumWidgetView(from entry: SimpleEntry) -> MediumWidgetView {
    MediumWidgetView(
        statusPresentation: entry.statusPresentation,
        controlPresentation: entry.controlPresentation,
        metadataModel: entry.widgetNowPlayingDisplayModel,
        currentStation: entry.currentStation,
        currentLanguageCode: entry.currentLanguageCode,
        availableStreams: entry.availableStreams
    )
}

/// Projects a preview `SimpleEntry` into the narrow inputs `LargeWidgetView` consumes at runtime.
private func largeWidgetView(from entry: SimpleEntry) -> LargeWidgetView {
    LargeWidgetView(
        statusPresentation: entry.statusPresentation,
        controlPresentation: entry.controlPresentation,
        metadataModel: entry.widgetNowPlayingDisplayModel,
        currentStation: entry.currentStation,
        currentLanguageCode: entry.currentLanguageCode,
        availableStreams: entry.availableStreams
    )
}

// userPaused + nil metadata (shows placeholder)
#Preview("1. userPaused + nil metadata", traits: .sizeThatFitsLayout) {
    mediumWidgetView(from: makePreviewEntry(
        visualState: .userPaused,
        programTitle: nil,
        speaker: nil
    ))
}

// userPaused + title only (subdued last-known, no speaker)
#Preview("2. userPaused + title only", traits: .sizeThatFitsLayout) {
    largeWidgetView(from: makePreviewEntry(
        visualState: .userPaused,
        programTitle: "Evening Prayer",
        speaker: nil
    ))
}

// userPaused + title + speaker (subdued)
#Preview("3. userPaused + title + speaker", traits: .sizeThatFitsLayout) {
    mediumWidgetView(from: makePreviewEntry(
        visualState: .userPaused,
        programTitle: "Sermon Title Here",
        speaker: "Rev. Martin Luther"
    ))
}

// prePlay + nil metadata (stream switch during connect)
#Preview("4. prePlay + nil (stream switch)", traits: .sizeThatFitsLayout) {
    largeWidgetView(from: makePreviewEntry(
        visualState: .prePlay,
        programTitle: nil,
        speaker: nil
    ))
}

// playing + nil metadata (ICY pending / live fallback active)
#Preview("5. playing + nil (ICY pending)", traits: .sizeThatFitsLayout) {
    mediumWidgetView(from: makePreviewEntry(
        visualState: .playing,
        programTitle: nil,
        speaker: nil
    ))
}

// playing + title (active, no speaker)
#Preview("6. playing + title", traits: .sizeThatFitsLayout) {
    largeWidgetView(from: makePreviewEntry(
        visualState: .playing,
        programTitle: "The Means of Grace",
        speaker: nil
    ))
}

// playing + title + speaker (active)
#Preview("7. playing + title + speaker", traits: .sizeThatFitsLayout) {
    mediumWidgetView(from: makePreviewEntry(
        visualState: .playing,
        programTitle: "Daily Chapel",
        speaker: "Dr. John T. Pless"
    ))
}

// thermalPaused with metadata (subdued)
#Preview("8. thermalPaused + metadata", traits: .sizeThatFitsLayout) {
    largeWidgetView(from: makePreviewEntry(
        visualState: .thermalPaused,
        programTitle: "Last Known Program",
        speaker: "Speaker Name"
    ))
}

// securityLocked with metadata (subdued, red tint on other elements)
#Preview("9. securityLocked + metadata", traits: .sizeThatFitsLayout) {
    mediumWidgetView(from: makePreviewEntry(
        visualState: .securityLocked,
        currentStation: "🇩🇪 Deutsch",
        currentLanguageCode: "de",
        programTitle: "Protected Content",
        speaker: nil
    ))
}

// securityLocked without metadata (placeholder)
#Preview("10. securityLocked + nil (placeholder)", traits: .sizeThatFitsLayout) {
    largeWidgetView(from: makePreviewEntry(
        visualState: .securityLocked,
        programTitle: nil,
        speaker: nil
    ))
}

// Small family: interactive playing (narrow inputs; flag grid + control)
#Preview("11. small playing (interactive)", traits: .sizeThatFitsLayout) {
    smallWidgetView(from: makePreviewEntry(
        visualState: .playing,
        currentLanguageCode: "en",
        programTitle: "Daily Chapel",
        speaker: nil
    ))
}

// Passive `tap_to_open`: direct chrome when liveness is not recently active
// (``WidgetLivenessPresentation/shouldShowPassiveTapToOpen``). Family views take
// this branch at runtime; canvas previews construct chrome explicitly so App Group
// heartbeat state cannot hide the axis.
#Preview("12. passive tap_to_open small", traits: .sizeThatFitsLayout) {
    WidgetPassiveTapToOpenChrome(style: .small)
        .padding()
}

#Preview("13. passive tap_to_open medium", traits: .sizeThatFitsLayout) {
    WidgetPassiveTapToOpenChrome(style: .medium)
        .padding()
}

// Non-English playing: flag + localized language name on medium
#Preview("14. playing fi + metadata", traits: .sizeThatFitsLayout) {
    mediumWidgetView(from: makePreviewEntry(
        visualState: .playing,
        currentLanguageCode: "fi",
        programTitle: "Aamuhartaus",
        speaker: "Puhuja"
    ))
}

// Non-English paused: subdued chrome with Swedish station identity
#Preview("15. userPaused sv + title", traits: .sizeThatFitsLayout) {
    largeWidgetView(from: makePreviewEntry(
        visualState: .userPaused,
        currentLanguageCode: "sv",
        programTitle: "Kvällsbön",
        speaker: nil
    ))
}

// Small family non-English: selected flag honesty for a non-en stream
#Preview("16. small playing et", traits: .sizeThatFitsLayout) {
    smallWidgetView(from: makePreviewEntry(
        visualState: .playing,
        currentLanguageCode: "et",
        programTitle: nil,
        speaker: nil
    ))
}

// Cleared: post privacy-reset confirmation chrome (distinct blue status)
#Preview("17. cleared + nil (privacy reset)", traits: .sizeThatFitsLayout) {
    mediumWidgetView(from: makePreviewEntry(
        visualState: .cleared,
        programTitle: nil,
        speaker: nil
    ))
}

#endif

