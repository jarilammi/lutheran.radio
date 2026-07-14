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

/// Returns whether the main app process is considered recently active.
///
/// Delegates to the Single Source of Truth `SharedPlayerManager.isMainAppProcessRecentlyActive()`.
/// The 60 s heuristic (plus explicit 0 sentinel on termination) decides whether widget family
/// views render full interactive chrome (status, controls via `controlPresentation`,
/// metadata, flags) or the stable passive "tap to open" surface.
///
/// **Post-quit contract (Cleanup Invariant)**:
/// - Main app termination paths call `forceStaleLivenessTimestampForTermination()` which writes
///   the sentinel 0 → this immediately returns false.
/// - Subsequent Provider executions (system 15 min timelines or any lingering reloads) render
///   the "tap_to_open" + `widgetURL("lutheranradio://open")` path only.
/// - That path performs a clean app launch via the widget's URL handler (Apple-approved,
///   no playback side-effect, no implicit reload, no resurrection).
/// - No code in these views or the passive branch may trigger `WidgetCenter.reloadTimelines`,
///   network, timers, or Darwin that would wake the (now-dead) main process.
/// - Force-quit may leave a <60 s window of "active" presentation until the timestamp ages;
///   this is documented and accepted (no write possible after abrupt kill).
///
/// - SeeAlso: ``SharedPlayerManager/isMainAppProcessRecentlyActive()``,
///   ``SharedPlayerManager/forceStaleLivenessTimestampForTermination()``,
///   `LutheranRadioWidgetEntryView`, the three *WidgetView bodies (the `if !isAppRunning()`
///   branches), CODING_AGENT.md (SSOT + cross-target), docs/Widget-Presentation-Dataflow.md.
private func isAppRunning() -> Bool {
    SharedPlayerManager.isMainAppProcessRecentlyActive()
}

// MARK: - UIKit → SwiftUI Bridge

extension UIColor {
    var swiftUIColor: Color { Color(self) }
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
        let vs = PlayerVisualState.prePlay
        let pres = vs.makeStatusPresentation()
        let controlPres = vs.makeControlPresentation()

        // Derive the metadata/emphasis model once for the placeholder snapshot.
        // Use the canonical English name for the live-stream fallback (mirrors currentStation).
        // See WidgetDisplayModels.swift for the resolver contract and snapshot-driven rationale.
        let placeholderLanguageName = String(localized: "language_english", table: "Localizable")
        let metaModel = widgetNowPlayingDisplayModel(
            visualState: vs,
            streamMetadata: nil,
            languageName: placeholderLanguageName
        )

        return SimpleEntry(
            date: Date(),
            visualState: vs,
            currentStation: "🇺🇸 " + String(localized: "language_english", table: "Localizable"),
            currentLanguageCode: "en",
            statusMessage: pres.text,
            statusPresentation: pres,
            controlPresentation: controlPres,
            widgetNowPlayingDisplayModel: metaModel,
            streamMetadata: nil,
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
        let fields = await WidgetProviderSnapshotResolver.resolveWithActorHygiene(
            manager: SharedPlayerManager.shared
        )
        let slices = WidgetProviderSnapshotResolver.assemblePresentationSlices(from: fields)
        let manager = SharedPlayerManager.shared

        let entry = SimpleEntry(
            date: Date(),
            visualState: fields.visualState,
            currentStation: slices.currentStation,
            currentLanguageCode: slices.currentLanguageCode,
            statusMessage: slices.statusMessage,
            statusPresentation: slices.statusPresentation,
            controlPresentation: slices.controlPresentation,
            widgetNowPlayingDisplayModel: slices.widgetNowPlayingDisplayModel,
            streamMetadata: fields.streamMetadata,
            availableStreams: manager.availableStreams,
            configuration: configuration
        )
        
        // Safe date calculation
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())
            ?? Date().addingTimeInterval(15 * 60)
        
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }
    
    // MARK: - Async helpers (required for actor isolation)
    
    private func createEntry(with configuration: RadioWidgetConfiguration) async -> SimpleEntry {
        Task { @MainActor in WidgetRefreshManager.setHasActiveLutheranWidgets(true) }
        let manager = SharedPlayerManager.shared
        let fields = await WidgetProviderSnapshotResolver.resolveWithActorHygiene(manager: manager)
        let slices = WidgetProviderSnapshotResolver.assemblePresentationSlices(from: fields)

        #if DEBUG
        print("[LutheranRadioWidget] Widget creating entry: visualState=\(fields.visualState), station=\(slices.currentStation)")
        #endif

        return SimpleEntry(
            date: Date(),
            visualState: fields.visualState,
            currentStation: slices.currentStation,
            currentLanguageCode: slices.currentLanguageCode,
            statusMessage: slices.statusMessage,
            statusPresentation: slices.statusPresentation,
            controlPresentation: slices.controlPresentation,
            widgetNowPlayingDisplayModel: slices.widgetNowPlayingDisplayModel,
            streamMetadata: fields.streamMetadata,
            availableStreams: manager.availableStreams,
            configuration: configuration
        )
    }
}

struct SimpleEntry: TimelineEntry, Sendable {
    let date: Date
    let visualState: PlayerVisualState
    let currentStation: String
    let currentLanguageCode: String
    let statusMessage: String

    /// Narrow presentation for the status indicator (text + associated colors).
    /// Populated from `visualState.makeStatusPresentation()` (the single canonical mapper)
    /// inside the provider paths. Widget family views consume this directly rather than
    /// re-reading `visualState` for status concerns. Reduces invalidation surface.
    ///
    /// - SeeAlso: `PlayerStatusPresentation`, ``PlayerVisualState/makeStatusPresentation()``,
    ///   `controlPresentation` (the parallel narrow type for play/pause controls).
    let statusPresentation: PlayerStatusPresentation

    /// Narrow presentation for the primary play/pause control affordance.
    ///
    /// Populated from `visualState.makeControlPresentation()` (SSOT) in the provider.
    /// Contains only the `systemImage` ("play.fill" / "pause.fill") and `tint` Color
    /// needed by the control button. This is the control-axis counterpart to
    /// `statusPresentation`.
    ///
    /// All three family views (Small/Medium/Large) now read the play/pause
    /// `Image(systemName:)` and foreground tint exclusively from this value.
    ///
    /// Why: WidgetKit snapshots are value types compared field-by-field. Handing
    /// only the slices a leaf needs (instead of the whole visualState) shrinks
    /// the set of changes that cause body re-evaluation for the button.
    ///
    /// - SeeAlso: `PlayerControlPresentation`, ``PlayerVisualState/makeControlPresentation()``,
    ///   `statusPresentation`, LutheranRadioWidgetLiveActivity (same derivation pattern
    ///   performed once at the top of LockScreen / outer DynamicIsland closure).
    let controlPresentation: PlayerControlPresentation

    /// Pre-derived display model for program title, speaker line, visibility and emphasis (metadata axis).
    ///
    /// Populated once per snapshot from `widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)`
    /// inside the Provider (`placeholder`, `snapshot`, `timeline` / `createEntry`). This is the
    /// metadata/emphasis counterpart to `statusPresentation` and `controlPresentation`.
    ///
    /// `MediumWidgetView`, `LargeWidgetView`, and `WidgetMetadataRegion` read this value directly
    /// instead of invoking the resolver inside their `body`. The four fields are the only data
    /// the metadata region needs; everything else (station, status text, controls, language grid)
    /// comes from sibling properties on the entry.
    ///
    /// Why pre-derive here (see WidgetDisplayModels.swift header for full rationale):
    /// - Reduces repeated derivation work on every view body evaluation.
    /// - Narrows the invalidation surface for WidgetKit: only a change to the concrete title/speaker/emphasis
    ///   affects the metadata region without a full visualState-driven re-comparison in the view.
    /// - Makes the data dependency of `WidgetMetadataRegion` explicit and minimal.
    ///
    /// - SeeAlso: `widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)`,
    ///   `WidgetNowPlayingDisplayModel`, `WidgetMetadataRegion`,
    ///   ``PlayerVisualState`` (the source), `SimpleEntry.statusPresentation`,
    ///   `SimpleEntry.controlPresentation`,
    ///   `LutheranRadioWidgetLiveActivity.swift` (parallel top-level derivation for ActivityKit),
    ///   `WidgetDisplayModels.swift` (SSOT + snapshot-driven usage pattern),
    ///   CODING_AGENT.md (narrow inputs, Single Source of Truth Principles).
    let widgetNowPlayingDisplayModel: WidgetNowPlayingDisplayModel

    let streamMetadata: StreamProgramMetadata?
    let availableStreams: [DirectStreamingPlayer.Stream]
    let configuration: RadioWidgetConfiguration
}

/// Routes a timeline snapshot to the correct family view using narrow presentation slices.
///
/// Projects only the fields each family view reads from `SimpleEntry`, so unrelated
/// entry fields (for example `configuration` or `streamMetadata`) do not participate
/// in the family view's stored property dependency set.
///
/// - SeeAlso: `SmallWidgetView`, `MediumWidgetView`, `LargeWidgetView`,
///   docs/Widget-Presentation-Dataflow.md, docs/Widget-Functionality-Roadmap.md.
struct LutheranRadioWidgetEntryView: View {
    var entry: Provider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        // SECURITY / RENDERING NOTE: WidgetKit (iOS 17+) requires .containerBackground(for: .widget)
        // on the timeline entry view (or an ancestor). Plain .background(...) on the widget content
        // root causes the system to render the diagnostic text "Please adopt containerBackground API"
        // on physical devices (and some simulator configurations).
        //
        // Single application point here ensures all three families (small/medium/large) and both
        // the "tap to open" (!isAppRunning) and active playback states receive a proper container fill.
        // We use Color(.systemBackground) to match the previous explicit intent while satisfying the API.
        //
        // See also: LutheranRadioWidget.swift (the three size views no longer apply root .background),
        // WidgetKit documentation on container backgrounds, and CODING_AGENT.md "Single Source of Truth".
        Group {
            switch family {
            case .systemSmall:
                SmallWidgetView(
                    statusPresentation: entry.statusPresentation,
                    controlPresentation: entry.controlPresentation,
                    currentLanguageCode: entry.currentLanguageCode,
                    availableStreams: entry.availableStreams
                )
            case .systemMedium:
                MediumWidgetView(
                    statusPresentation: entry.statusPresentation,
                    controlPresentation: entry.controlPresentation,
                    metadataModel: entry.widgetNowPlayingDisplayModel,
                    currentStation: entry.currentStation,
                    currentLanguageCode: entry.currentLanguageCode,
                    availableStreams: entry.availableStreams
                )
            case .systemLarge:
                LargeWidgetView(
                    statusPresentation: entry.statusPresentation,
                    controlPresentation: entry.controlPresentation,
                    metadataModel: entry.widgetNowPlayingDisplayModel,
                    currentStation: entry.currentStation,
                    currentLanguageCode: entry.currentLanguageCode,
                    availableStreams: entry.availableStreams
                )
            default:
                SmallWidgetView(
                    statusPresentation: entry.statusPresentation,
                    controlPresentation: entry.controlPresentation,
                    currentLanguageCode: entry.currentLanguageCode,
                    availableStreams: entry.availableStreams
                )
            }
        }
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
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
        if !isAppRunning() {
            VStack(spacing: 8) {
                Image(systemName: "radio")
                    .font(.title2)
                    .foregroundColor(.secondary)
                
                Text(String(localized: "tap_to_open", table: "Localizable"))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .padding()
            .widgetURL(URL(string: "lutheranradio://open"))
        } else {
            VStack(spacing: 4) {
                Text(statusPresentation.text)
                    .font(.caption2)
                    .foregroundStyle(statusPresentation.foreground)
                    .lineLimit(1)

                if availableStreams.count > 1 {
                    let topRow = Array(availableStreams.prefix(3))
                    let bottomRow = Array(availableStreams.dropFirst(3).prefix(2))

                    VStack(spacing: 3) {
                        HStack(spacing: 4) {
                            ForEach(topRow, id: \.languageCode) { stream in
                                smallWidgetStreamFlagButton(for: stream)
                            }
                        }
                        HStack(spacing: 4) {
                            ForEach(bottomRow, id: \.languageCode) { stream in
                                smallWidgetStreamFlagButton(for: stream)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)

                // Control affordance sourced exclusively from the narrow pre-derived
                // PlayerControlPresentation (populated via makeControlPresentation in the Provider).
                // This removes the last direct read of visualState for glyph/tint inside SmallWidgetView.
                Button(intent: WidgetToggleRadioIntent()) {
                    Image(systemName: controlPresentation.systemImage)
                        .font(.title2)
                        .foregroundColor(controlPresentation.tint)
                }
                .buttonStyle(.plain)
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func smallWidgetStreamFlagButton(for stream: DirectStreamingPlayer.Stream) -> some View {
        let isSelected = stream.languageCode == currentLanguageCode

        Button(intent: SwitchStreamIntent(streamLanguageCode: stream.languageCode)) {
            Text(stream.flag)
                .font(.subheadline)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(isSelected ? Color.blue.opacity(0.2) : Color.gray.opacity(0.08))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1)
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
        if !isAppRunning() {
            HStack {
                VStack(spacing: 8) {
                    Image(systemName: "radio")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(String(localized: "tap_to_open", table: "Localizable"))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Text(String(localized: "open_app_first", table: "Localizable"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
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
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    // Control affordance from narrow PlayerControlPresentation (SSOT derivation).
                    Button(intent: WidgetToggleRadioIntent()) {
                        Image(systemName: controlPresentation.systemImage)
                            .font(.title3)
                            .foregroundColor(controlPresentation.tint)
                    }
                    .buttonStyle(.plain)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(currentStation)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text(statusPresentation.text)
                        .font(.caption2)
                        .foregroundStyle(statusPresentation.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                WidgetMetadataRegion(model: metadataModel, layout: .medium)

                Spacer(minLength: 4)

                if availableStreams.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(availableStreams, id: \.languageCode) { stream in
                            mediumWidgetStreamFlagButton(for: stream)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(10)
        }
    }

    @ViewBuilder
    private func mediumWidgetStreamFlagButton(for stream: DirectStreamingPlayer.Stream) -> some View {
        let isSelected = stream.languageCode == currentLanguageCode

        Button(intent: SwitchStreamIntent(streamLanguageCode: stream.languageCode)) {
            Text(stream.flag)
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(isSelected ? Color.blue.opacity(0.2) : Color.gray.opacity(0.08))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
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
        if !isAppRunning() {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "radio")
                    .font(.system(size: 60))
                    .foregroundColor(.secondary)
                Text(String(localized: "tap_to_open", table: "Localizable"))
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                Text(String(localized: "open_app_first", table: "Localizable"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
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
                    // Control affordance from narrow PlayerControlPresentation (SSOT derivation).
                    Button(intent: WidgetToggleRadioIntent()) {
                        Image(systemName: controlPresentation.systemImage)
                            .font(.title2)
                            .foregroundColor(controlPresentation.tint)
                    }
                    .buttonStyle(.plain)
                }

                VStack(spacing: 4) {
                    Text(currentStation)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)

                    Text(statusPresentation.text)
                        .font(.subheadline)
                        .foregroundStyle(statusPresentation.foreground)
                }

                WidgetMetadataRegion(model: metadataModel, layout: .large)

                Spacer(minLength: 4)

                Divider()

                // 3-column grid on large. With the current 5 streams this yields a balanced
                // 3 + 2 layout; scales cleanly to larger sets (e.g. 21).
                // isSelected now uses the same robust languageCode check as small/medium.
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                    spacing: 8
                ) {
                    ForEach(availableStreams, id: \.languageCode) { stream in
                        let isSelected = stream.languageCode == currentLanguageCode

                        Button(intent: SwitchStreamIntent(streamLanguageCode: stream.languageCode)) {
                            HStack(spacing: 4) {
                                Text(stream.flag)
                                    .font(.caption)
                                Text(stream.language)
                                    .font(.caption)
                                    .fontWeight(isSelected ? .semibold : .regular)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6) // slightly more generous for labeled buttons on large
                            .background(isSelected ? Color.blue.opacity(0.2) : Color.gray.opacity(0.1))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1)
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

// MARK: - App Intents

struct WidgetToggleRadioIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Toggle Lutheran Radio" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Play or pause Lutheran Radio.")
    }
    
    init() {}
    
    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[LutheranRadioWidget] WidgetToggleRadioIntent.perform called")
        #endif
        
        // Reliable SSOT read for widget extension process
        let visualState = SharedPlayerManager.loadPersistedVisualStateDirect()
        let shouldPlay = !visualState.isActivelyPlaying
        let action = shouldPlay ? "play" : "pause"
        let targetVisualState: PlayerVisualState = shouldPlay ? .playing : .userPaused
        
        #if DEBUG
        print("[LutheranRadioWidget] Widget wants to \(action) → target state: \(targetVisualState) (visualState.isActivelyPlaying = \(visualState.isActivelyPlaying))")
        #endif
        
        // === OPTIMISTIC UPDATE (needed for instant icon flip) ===
        // Read language from the persisted snapshot first (the value the widget timeline/provider
        // just used for this entry). This avoids re-computing preferredWidgetLanguage() which can
        // fall back to "en" when hasActiveWidgets cache is still false on first interaction.
        // The main app will later authoritatively save the actually-selected stream language.
        let persisted = SharedPlayerManager.loadPersistedWidgetState()
        let langForOptimistic = persisted?.currentLanguage ?? SharedPlayerManager.preferredWidgetLanguage()

        if let actionId = SharedPlayerManager.shared.signalWidgetPendingAction(
            visualState: targetVisualState,
            action: action,
            language: langForOptimistic
        ) {
            #if DEBUG
            print("[LutheranRadioWidget] Widget set pendingAction = \(action) (ID: \(actionId))")
            #endif
        }
        
        // Immediate widget UI update — use the same lang we just persisted for the snapshot.
        let state = SharedPlayerManager.shared.loadSharedState()
        await WidgetRefreshManager.shared.refreshIfNeeded(
            visualState: targetVisualState,
            currentLanguage: langForOptimistic,
            hasError: state.hasError,
            immediate: true
        )
        
        #if DEBUG
        print("[LutheranRadioWidget] WidgetToggleRadioIntent completed. Signaled \(action), refreshed widget to \(targetVisualState)")
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

    @Parameter(title: "Language Code")
    var streamLanguageCode: String

    public func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[LutheranRadioWidget] SwitchStreamIntent.perform called for language: \(streamLanguageCode)")
        #endif

        Task { @MainActor in WidgetRefreshManager.setHasActiveLutheranWidgets(true) }

        let manager = SharedPlayerManager.shared

        guard let targetStream = manager.availableStreams.first(where: { $0.languageCode == streamLanguageCode }) else {
            #if DEBUG
            print("[LutheranRadioWidget] SwitchStreamIntent: Language stream not found")
            #endif
            return .result()
        }

        // Route through switchToStream → handleWidgetSwitch → signalWidgetSwitchAction
        // (same path as LiveActivitySwitchStreamIntent).
        await manager.switchToStream(targetStream)

        let state = manager.loadSharedState()
        let visualState = SharedPlayerManager.loadPersistedVisualStateDirect()
        await WidgetRefreshManager.shared.refreshIfNeeded(
            visualState: visualState,
            currentLanguage: streamLanguageCode,
            hasError: state.hasError,
            immediate: true
        )

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
        visualState: visualState,
        currentStation: station,
        currentLanguageCode: currentLanguageCode,
        statusMessage: pres.text,
        statusPresentation: pres,
        controlPresentation: controlPres,
        widgetNowPlayingDisplayModel: metaModel,
        streamMetadata: metadata,
        availableStreams: streams,
        configuration: RadioWidgetConfiguration()
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

#endif

