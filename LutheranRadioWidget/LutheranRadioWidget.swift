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
// WidgetMetadataEmphasis, WidgetNowPlayingDisplayModel, and the core resolver
// now live in WidgetDisplayModels.swift (shared with Live Activity code).
// The thin adapter below preserves the existing call sites for medium/large widgets.
//
// Presentation surfaces in this file:
// - statusPresentation (via makeStatusPresentation) is already carried on SimpleEntry
//   and consumed for the status caption.
// - controlPresentation (via makeControlPresentation) is the new parallel narrow type
//   for the play/pause buttons. All three family views now use only the narrow value
//   for glyph + tint decisions (see P0 recommendation in the 2026-06-24 presentation
//   dataflow analysis).

// Adapter: computes language name from the entry's streams (full 21-lang list)
// then delegates to the shared resolver.
private func widgetNowPlayingDisplayModel(from entry: SimpleEntry) -> WidgetNowPlayingDisplayModel {
    let languageName = entry.availableStreams
        .first { $0.languageCode == entry.currentLanguageCode }?
        .language ?? entry.currentStation
    return widgetNowPlayingDisplayModel(
        visualState: entry.visualState,
        streamMetadata: entry.streamMetadata,
        languageName: languageName
    )
}

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

/// Returns whether the main app has recently updated shared state.
/// Used by all three widget sizes to decide whether to show controls or the "tap to open" prompt.
private func isAppRunning() -> Bool {
    if let lastUpdate = UserDefaults(suiteName: "group.radio.lutheran.shared")?
        .object(forKey: "lastUpdateTime") as? Double {
        return Date().timeIntervalSince1970 - lastUpdate < 60
    }
    return false
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
// 1. Always call refreshVisualStateFromPersistence() first (actor isolation hygiene).
// 2. Check loadPersistedWidgetState() early — this is the normal hot path.
// 3. Only remaining fallback: very old installs that have never written a snapshot
//    (safe .prePlay + preferred language default).

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
        return SimpleEntry(
            date: Date(),
            visualState: vs,
            currentStation: "🇺🇸 " + String(localized: "language_english", table: "Localizable"),
            currentLanguageCode: "en",
            statusMessage: pres.text,
            statusPresentation: pres,
            controlPresentation: controlPres,
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
        let (currentLanguage, hasError, visualState, streamMetadata) = await getPendingOrCurrentState(manager: SharedPlayerManager.shared)
        
        let manager = SharedPlayerManager.shared
        
        // Use the centralized facade (delegates to DirectStreamingPlayer.streamForLanguageCode
        // with its documented English default). Removes duplicated first/??/ [0] logic.
        let currentStream = SharedPlayerManager.streamForLanguageCode(currentLanguage)
        
        let currentStation = currentStream.flag + " " + currentStream.language

        // Derive from the single source of truth (makeStatusPresentation) instead of
        // duplicating case-by-case text mapping. hasError path kept for compatibility
        // (though getPendingOrCurrentState currently forces false; visual.securityLocked
        // will produce the canonical security text via the mapper).
        let pres = visualState.makeStatusPresentation()
        let controlPres = visualState.makeControlPresentation()
        let statusMessage: String = hasError
            ? String(localized: "Connection error", defaultValue: "Connection error", table: "Localizable")
            : pres.text

        let entry = SimpleEntry(
            date: Date(),
            visualState: visualState,
            currentStation: currentStation,
            currentLanguageCode: currentLanguage,
            statusMessage: statusMessage,
            statusPresentation: pres,
            controlPresentation: controlPres,
            streamMetadata: streamMetadata,
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
        let (currentLanguage, hasError, visualState, streamMetadata) = await getPendingOrCurrentState(manager: manager)

        // Use the centralized facade (see SharedPlayerManager.streamForLanguageCode).
        let currentStream = SharedPlayerManager.streamForLanguageCode(currentLanguage)
        let currentStation = currentStream.flag + " " + currentStream.language

        // Derive from the single sources of truth (makeStatusPresentation + makeControlPresentation)
        // instead of duplicating case-by-case text/glyph mapping. Both narrow values are
        // stored on the TimelineEntry snapshot so that family views receive only the slices
        // they render. Mirrors the timeline path and Live Activity "derive once at top" rule.
        let pres = visualState.makeStatusPresentation()
        let controlPres = visualState.makeControlPresentation()
        let statusMessage: String = hasError
            ? String(localized: "Connection error", defaultValue: "Connection error", table: "Localizable")
            : pres.text

        #if DEBUG
        print("[LutheranRadioWidget] Widget creating entry: visualState=\(visualState), station=\(currentStation)")
        #endif

        return SimpleEntry(
            date: Date(),
            visualState: visualState,
            currentStation: currentStation,
            currentLanguageCode: currentLanguage,
            statusMessage: statusMessage,
            statusPresentation: pres,
            controlPresentation: controlPres,
            streamMetadata: streamMetadata,
            availableStreams: manager.availableStreams,
            configuration: configuration
        )
    }
    
    private func getPendingOrCurrentState(manager: SharedPlayerManager) async -> (
        currentLanguage: String,
        hasError: Bool,
        visualState: PlayerVisualState,
        streamMetadata: StreamProgramMetadata?
    ) {
        // Always refresh from persistence first (fresh actor starts at .prePlay).
        await manager.refreshVisualStateFromPersistence()

        // Snapshot-first (modern path for all current installs). Single simple fallback for
        // first-launch or installs that have never persisted a snapshot.
        //
        // Privacy (write suppression when no widgets configured / clear local state):
        // loadPersistedWidgetState() returns nil (we fall back to safe .prePlay + preferredWidgetLanguage(),
        // which is "en" + suppressed writes for post-clear/no-widgets, or bestInitial when hasActiveWidgets).
        // after the "Clear local playback state" action (sleep timer menu) or when the
        // main app has suppressed all writes because no LutheranRadioWidget / LutheranRadioWidgetControl
        // is currently installed (WidgetRefreshManager.hasActiveLutheranWidgets + SharedPlayerManager guards
        // on persist/save/writeInstant/bump/schedule/pending/liveness paths). The App Group then carries
        // no recent language/visual/metadata/liveness signal.
        if let combined = SharedPlayerManager.loadPersistedWidgetState() {
            return (combined.currentLanguage, false, combined.visualState, combined.streamMetadata)
        }

        return (SharedPlayerManager.preferredWidgetLanguage(), false, .prePlay, nil)
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

    let streamMetadata: StreamProgramMetadata?
    let availableStreams: [DirectStreamingPlayer.Stream]
    let configuration: RadioWidgetConfiguration
}

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
                SmallWidgetView(entry: entry)
            case .systemMedium:
                MediumWidgetView(entry: entry)
            case .systemLarge:
                LargeWidgetView(entry: entry)
            default:
                SmallWidgetView(entry: entry)
            }
        }
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }
}

// MARK: - Small Widget (2x2)

struct SmallWidgetView: View {
    let entry: SimpleEntry
    
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
                Text(entry.statusPresentation.text)
                    .font(.caption2)
                    .foregroundStyle(entry.statusPresentation.foreground)
                    .lineLimit(1)

                if entry.availableStreams.count > 1 {
                    let topRow = Array(entry.availableStreams.prefix(3))
                    let bottomRow = Array(entry.availableStreams.dropFirst(3).prefix(2))

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
                    Image(systemName: entry.controlPresentation.systemImage)
                        .font(.title2)
                        .foregroundColor(entry.controlPresentation.tint)
                }
                .buttonStyle(.plain)
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func smallWidgetStreamFlagButton(for stream: DirectStreamingPlayer.Stream) -> some View {
        let isSelected = stream.languageCode == entry.currentLanguageCode

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

struct MediumWidgetView: View {
    let entry: SimpleEntry
    
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
            let metadata = widgetNowPlayingDisplayModel(from: entry)

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
                        Image(systemName: entry.controlPresentation.systemImage)
                            .font(.title3)
                            .foregroundColor(entry.controlPresentation.tint)
                    }
                    .buttonStyle(.plain)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.currentStation)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text(entry.statusPresentation.text)
                        .font(.caption2)
                        .foregroundStyle(entry.statusPresentation.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                WidgetMetadataRegion(model: metadata, layout: .medium)

                Spacer(minLength: 4)

                if entry.availableStreams.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(entry.availableStreams, id: \.languageCode) { stream in
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
        let isSelected = stream.languageCode == entry.currentLanguageCode

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

struct LargeWidgetView: View {
    let entry: SimpleEntry
    
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
            let metadata = widgetNowPlayingDisplayModel(from: entry)

            VStack(spacing: 12) {
                HStack {
                    Text(String(localized: "lutheran_radio_title", table: "Localizable"))
                        .font(.headline)
                        .fontWeight(.bold)
                    Spacer()
                    // Control affordance from narrow PlayerControlPresentation (SSOT derivation).
                    Button(intent: WidgetToggleRadioIntent()) {
                        Image(systemName: entry.controlPresentation.systemImage)
                            .font(.title2)
                            .foregroundColor(entry.controlPresentation.tint)
                    }
                    .buttonStyle(.plain)
                }

                VStack(spacing: 4) {
                    Text(entry.currentStation)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)

                    Text(entry.statusPresentation.text)
                        .font(.subheadline)
                        .foregroundStyle(entry.statusPresentation.foreground)
                }

                WidgetMetadataRegion(model: metadata, layout: .large)

                Spacer(minLength: 4)

                Divider()

                // 3-column grid on large. With the current 5 streams this yields a balanced
                // 3 + 2 layout; scales cleanly to larger sets (e.g. 21).
                // isSelected now uses the same robust languageCode check as small/medium.
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                    spacing: 8
                ) {
                    ForEach(entry.availableStreams, id: \.languageCode) { stream in
                        let isSelected = stream.languageCode == entry.currentLanguageCode

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
// Exhaustive previews for the shared WidgetNowPlayingDisplayModel + emphasis
// across PlayerVisualState values and metadata presence (nil / title only / title + speaker).
// The same model is used by Live Activity.
//
// Every preview entry is built with both `statusPresentation` (makeStatusPresentation)
// and `controlPresentation` (makeControlPresentation) so the matrix exercises the
// full narrow presentation contract used by providers and Live Activity views.
//
// Use the Xcode canvas to inspect emphasis levels (active / subdued / placeholder)
// and confirm the title + speaker slots remain stable (no conditional insertion).

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

    // Always derive status + control presentation from the visualState (single sources of truth).
    // This removes any need for overrides in preview construction and ensures the
    // exhaustive preview matrix exercises both mappers (status + control) used at runtime
    // by providers and Live Activity views.
    let pres = visualState.makeStatusPresentation()
    let controlPres = visualState.makeControlPresentation()

    return SimpleEntry(
        date: Date(),
        visualState: visualState,
        currentStation: station,
        currentLanguageCode: currentLanguageCode,
        statusMessage: pres.text,
        statusPresentation: pres,
        controlPresentation: controlPres,
        streamMetadata: metadata,
        availableStreams: streams,
        configuration: RadioWidgetConfiguration()
    )
}

// userPaused + nil metadata (shows placeholder)
#Preview("1. userPaused + nil metadata", traits: .sizeThatFitsLayout) {
    MediumWidgetView(entry: makePreviewEntry(
        visualState: .userPaused,
        programTitle: nil,
        speaker: nil
    ))
}

// userPaused + title only (subdued last-known, no speaker)
#Preview("2. userPaused + title only", traits: .sizeThatFitsLayout) {
    LargeWidgetView(entry: makePreviewEntry(
        visualState: .userPaused,
        programTitle: "Evening Prayer",
        speaker: nil
    ))
}

// userPaused + title + speaker (subdued)
#Preview("3. userPaused + title + speaker", traits: .sizeThatFitsLayout) {
    MediumWidgetView(entry: makePreviewEntry(
        visualState: .userPaused,
        programTitle: "Sermon Title Here",
        speaker: "Rev. Martin Luther"
    ))
}

// prePlay + nil metadata (stream switch during connect)
#Preview("4. prePlay + nil (stream switch)", traits: .sizeThatFitsLayout) {
    LargeWidgetView(entry: makePreviewEntry(
        visualState: .prePlay,
        programTitle: nil,
        speaker: nil
    ))
}

// playing + nil metadata (ICY pending / live fallback active)
#Preview("5. playing + nil (ICY pending)", traits: .sizeThatFitsLayout) {
    MediumWidgetView(entry: makePreviewEntry(
        visualState: .playing,
        programTitle: nil,
        speaker: nil
    ))
}

// playing + title (active, no speaker)
#Preview("6. playing + title", traits: .sizeThatFitsLayout) {
    LargeWidgetView(entry: makePreviewEntry(
        visualState: .playing,
        programTitle: "The Means of Grace",
        speaker: nil
    ))
}

// playing + title + speaker (active)
#Preview("7. playing + title + speaker", traits: .sizeThatFitsLayout) {
    MediumWidgetView(entry: makePreviewEntry(
        visualState: .playing,
        programTitle: "Daily Chapel",
        speaker: "Dr. John T. Pless"
    ))
}

// thermalPaused with metadata (subdued)
#Preview("8. thermalPaused + metadata", traits: .sizeThatFitsLayout) {
    LargeWidgetView(entry: makePreviewEntry(
        visualState: .thermalPaused,
        programTitle: "Last Known Program",
        speaker: "Speaker Name"
    ))
}

// securityLocked with metadata (subdued, red tint on other elements)
#Preview("9. securityLocked + metadata", traits: .sizeThatFitsLayout) {
    MediumWidgetView(entry: makePreviewEntry(
        visualState: .securityLocked,
        currentStation: "🇩🇪 Deutsch",
        currentLanguageCode: "de",
        programTitle: "Protected Content",
        speaker: nil
    ))
}

// securityLocked without metadata (placeholder)
#Preview("10. securityLocked + nil (placeholder)", traits: .sizeThatFitsLayout) {
    LargeWidgetView(entry: makePreviewEntry(
        visualState: .securityLocked,
        programTitle: nil,
        speaker: nil
    ))
}

#endif

