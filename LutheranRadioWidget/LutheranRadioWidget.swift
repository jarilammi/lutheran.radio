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

// MARK: - Shared Helpers

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
        .configurationDisplayName(String(localized: "lutheran_radio_title"))
        .description(String(localized: "Control playback and switch between language streams."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct Provider: AppIntentTimelineProvider {
    
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(
            date: Date(),
            visualState: .prePlay,
            currentStation: "🇺🇸 " + String(localized: "language_english"),
            statusMessage: String(localized: "Ready to play"),
            availableStreams: SharedPlayerManager.shared.availableStreams,
            configuration: RadioWidgetConfiguration()
        )
    }
    
    func snapshot(for configuration: RadioWidgetConfiguration, in context: Context) async -> SimpleEntry {
        await createEntry(with: configuration)
    }
    
    func timeline(for configuration: RadioWidgetConfiguration, in context: Context) async -> Timeline<SimpleEntry> {
        let (currentLanguage, hasError, visualState) = await getPendingOrCurrentState(manager: SharedPlayerManager.shared)
        
        let manager = SharedPlayerManager.shared
        
        // Safer stream selection
        let currentStream = manager.availableStreams.first { $0.languageCode == currentLanguage }
            ?? manager.availableStreams.first
            ?? manager.availableStreams[0]          // final fallback (should never happen)
        
        let currentStation = currentStream.flag + " " + currentStream.language
        
        let statusMessage: String = {
            if visualState == .thermalPaused {
                return String(localized: "status_thermal_paused", defaultValue: "Thermal pause")
            } else if hasError {
                return String(localized: "Connection error", defaultValue: "Connection error")
            } else if visualState == .playing {
                return String(localized: "status_playing", defaultValue: "Playing")
            } else {
                return String(localized: "Ready", defaultValue: "Ready")
            }
        }()
        
        let entry = SimpleEntry(
            date: Date(),
            visualState: visualState,
            currentStation: currentStation,
            statusMessage: statusMessage,
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
        let manager = SharedPlayerManager.shared
        let (currentLanguage, hasError, visualState) = await getPendingOrCurrentState(manager: manager)

        let currentStream = manager.availableStreams.first { $0.languageCode == currentLanguage } ?? manager.availableStreams[0]
        let currentStation = currentStream.flag + " " + currentStream.language

        let statusMessage: String = {
            if visualState == .thermalPaused {
                return String(localized: "status_thermal_paused", defaultValue: "Thermal pause")
            } else if hasError {
                return String(localized: "Connection error", defaultValue: "Connection error")
            } else if visualState == .playing {
                return String(localized: "status_playing", defaultValue: "Playing")
            } else {
                return String(localized: "Ready", defaultValue: "Ready")
            }
        }()

        #if DEBUG
        print("🔗 Widget creating entry: visualState=\(visualState), station=\(currentStation)")
        #endif

        return SimpleEntry(
            date: Date(),
            visualState: visualState,
            currentStation: currentStation,
            statusMessage: statusMessage,
            availableStreams: manager.availableStreams,
            configuration: configuration
        )
    }
    
    private func getPendingOrCurrentState(manager: SharedPlayerManager) async -> (currentLanguage: String, hasError: Bool, visualState: PlayerVisualState) {
        // Always refresh from persistence first (fresh actor starts at .prePlay).
        await manager.refreshVisualStateFromPersistence()

        // Snapshot-first (modern path for all current installs). Single simple fallback for
        // first-launch or installs that have never persisted a snapshot.
        if let combined = SharedPlayerManager.loadPersistedWidgetState() {
            return (combined.currentLanguage, false, combined.visualState)
        }

        return (SharedPlayerManager.preferredWidgetLanguage(), false, .prePlay)
    }
}

struct SimpleEntry: TimelineEntry, Sendable {
    let date: Date
    let visualState: PlayerVisualState
    let currentStation: String
    let statusMessage: String
    let availableStreams: [DirectStreamingPlayer.Stream]
    let configuration: RadioWidgetConfiguration
}

struct LutheranRadioWidgetEntryView: View {
    var entry: Provider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
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
                
                Text(String(localized: "tap_to_open"))
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
                Text(entry.currentStation)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                Text(entry.statusMessage)
                    .font(.caption2)
                    .foregroundColor(entry.visualState.textColor.swiftUIColor)
                    .lineLimit(1)
                
                Spacer()
                
                Button(intent: WidgetToggleRadioIntent()) {
                    Image(systemName: entry.visualState.isActivelyPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .foregroundColor(entry.visualState.buttonTintColor.swiftUIColor)
                }
                .buttonStyle(.plain)
            }
            .padding(8)
            .background(Color(.systemBackground))
        }
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
                    Text(String(localized: "tap_to_open"))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Text(String(localized: "open_app_first"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .padding()
            .widgetURL(URL(string: "lutheranradio://open"))
        } else {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "lutheran_radio_title"))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    Text(entry.currentStation)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    
                    Text(entry.statusMessage)
                        .font(.caption)
                        .foregroundColor(entry.visualState.textColor.swiftUIColor)
                    
                    Spacer()
                }
                
                Spacer()
                
                VStack(spacing: 8) {
                    Button(intent: WidgetToggleRadioIntent()) {
                        VStack(spacing: 2) {
                            Image(systemName: entry.visualState.isActivelyPlaying ? "pause.fill" : "play.fill")
                                .font(.title)
                                .foregroundColor(entry.visualState.buttonTintColor.swiftUIColor)
                            Text(entry.visualState.isActivelyPlaying ? String(localized: "status_playing") : String(localized: "status_paused"))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    
                    if entry.availableStreams.count > 1 {
                        let currentStreamCode = getCurrentStreamCode(from: entry.currentStation)
                        let alternativeStreams = entry.availableStreams.filter { $0.languageCode != currentStreamCode }.prefix(2)
                        
                        ForEach(Array(alternativeStreams), id: \.languageCode) { stream in
                            Button(intent: SwitchStreamIntent(streamLanguageCode: stream.languageCode)) {
                                Text(stream.flag)
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding()
            .background(Color(.systemBackground))
        }
    }
    
    private func getCurrentStreamCode(from stationName: String) -> String {
        for stream in entry.availableStreams {
            if stationName.contains(stream.language) {
                return stream.languageCode
            }
        }
        return "en"
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
                Text(String(localized: "tap_to_open"))
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                Text(String(localized: "open_app_first"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding()
            .widgetURL(URL(string: "lutheranradio://open"))
        } else {
            VStack(spacing: 12) {
                HStack {
                    Text(String(localized: "lutheran_radio_title"))
                        .font(.headline)
                        .fontWeight(.bold)
                    Spacer()
                    Button(intent: WidgetToggleRadioIntent()) {
                        Image(systemName: entry.visualState.isActivelyPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .foregroundColor(entry.visualState.buttonTintColor.swiftUIColor)
                    }
                    .buttonStyle(.plain)
                }
                
                VStack(spacing: 4) {
                    Text(entry.currentStation)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    Text(entry.statusMessage)
                        .font(.subheadline)
                        .foregroundColor(entry.visualState.textColor.swiftUIColor)
                }
                
                Divider()
                
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 8) {
                    ForEach(entry.availableStreams, id: \.languageCode) { stream in
                        let isSelected = entry.currentStation.contains(stream.language)
                        
                        Button(intent: SwitchStreamIntent(streamLanguageCode: stream.languageCode)) {
                            HStack(spacing: 4) {
                                Text(stream.flag)
                                    .font(.caption)
                                Text(stream.language)
                                    .font(.caption)
                                    .fontWeight(isSelected ? .semibold : .regular)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
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
                
                Spacer()
            }
            .padding()
            .background(Color(.systemBackground))
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
        print("🔗 WidgetToggleRadioIntent.perform called")
        #endif
        
        // ✅ Reliable SSOT read for widget extension process
        let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared")
        let visualState = SharedPlayerManager.loadPersistedVisualStateDirect()
        let shouldPlay = !visualState.isActivelyPlaying
        let action = shouldPlay ? "play" : "pause"
        let targetVisualState: PlayerVisualState = shouldPlay ? .playing : .userPaused
        
        #if DEBUG
        print("🔗 Widget wants to \(action) → target state: \(targetVisualState) (visualState.isActivelyPlaying = \(visualState.isActivelyPlaying))")
        #endif
        
        // === OPTIMISTIC UPDATE (needed for instant icon flip) ===
        let targetState: PlayerVisualState = shouldPlay ? .playing : .userPaused
        
        // Use the unified force path: writes the PersistedWidgetState snapshot (visual + lang)
        // + updates in-memory currentVisualState in this process.
        SharedPlayerManager.shared.forcePersistVisualState(targetState)
        
        if let sharedDefaults = sharedDefaults {
            let actionId = UUID().uuidString
            let now = Date().timeIntervalSince1970
            
            sharedDefaults.set(action, forKey: "pendingAction")
            sharedDefaults.set(actionId, forKey: "pendingActionId")
            sharedDefaults.set(now, forKey: "pendingActionTime")
            
            #if DEBUG
            print("🔗 Widget set pendingAction = \(action) (ID: \(actionId))")
            #endif
        }
        
        // Wake main app
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("radio.lutheran.widget.action" as CFString),
            nil, nil, true
        )
        
        // Immediate widget UI update
        let state = SharedPlayerManager.shared.loadSharedState()
        await WidgetRefreshManager.shared.refreshIfNeeded(
            visualState: targetVisualState,
            currentLanguage: state.currentLanguage,
            hasError: state.hasError,
            immediate: true
        )
        
        #if DEBUG
        print("🔗 WidgetToggleRadioIntent completed. Signaled \(action), refreshed widget to \(targetVisualState)")
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
        print("🔗 SwitchStreamIntent.perform called for language: \(streamLanguageCode)")
        #endif

        guard let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            return .result()
        }

        let actionId = UUID().uuidString
        let now = Date().timeIntervalSince1970

        sharedDefaults.set("switch", forKey: "pendingAction")
        sharedDefaults.set(actionId, forKey: "pendingActionId")
        sharedDefaults.set(now, forKey: "pendingActionTime")
        sharedDefaults.set(streamLanguageCode, forKey: "pendingLanguage")

        sharedDefaults.set(true, forKey: "isInstantFeedback")
        sharedDefaults.set(now, forKey: "instantFeedbackTime")
        sharedDefaults.set(streamLanguageCode, forKey: "instantFeedbackLanguage")

        // Post Darwin notification
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("radio.lutheran.widget.action" as CFString),
            nil, nil, true
        )

        let manager = SharedPlayerManager.shared
        let state = manager.loadSharedState()

        // Stream switch keeps the current play/pause state (only language changes)
        let visualState: PlayerVisualState = state.isPlaying ? .playing : .userPaused

        // Architectural unification: write the snapshot optimistically with the *new* language
        // + preserved visual. This means providers' early loadPersistedWidgetState() return
        // delivers correct optimistic state for *all* widget actions (play/pause/switch).
        SharedPlayerManager.persistWidgetSnapshot(visualState: visualState, language: streamLanguageCode)

        await WidgetRefreshManager.shared.refreshIfNeeded(
            visualState: visualState,          // ← authoritative source
            currentLanguage: streamLanguageCode,
            hasError: state.hasError,
            immediate: true
        )

        #if DEBUG
        print("🔗 SwitchStreamIntent: posted switch to \(streamLanguageCode) (ID: \(actionId))")
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
