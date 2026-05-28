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
// All widget/extension processes (Home Screen, Control Center, Live Activity) run in
// separate processes with a fresh actor instance (currentVisualState starts at .prePlay).
//
// We therefore never trust the actor's in-memory state for UI decisions.
//
// Instead we use a hardened three-layer approach:
//   1. Always call refreshVisualStateFromPersistence() first.
//   2. For play/pause buttons: check short-lived pendingAction / instantFeedback in
//      the app group UserDefaults (optimistic feedback + 12-15s window).
//   3. Fall back to decoding "playerVisualState" JSON directly via
//      SharedPlayerManager.loadPersistedVisualStateDirect().
//
// This combination guarantees correct button visuals even on first launch of a
// widget process after a forcePersistVisualState from an intent or the main app.

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
        
        let entry = SimpleEntry(
            date: Date(),
            visualState: visualState,
            currentStation: currentStation,
            statusMessage: statusMessage,
            availableStreams: manager.availableStreams,
            configuration: configuration
        )
        
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }
    
    // MARK: - Async helpers (required for actor isolation)
    
    private func getValidatedStreamState() async -> (currentStation: String, statusMessage: String, visualState: PlayerVisualState) {
        let manager = SharedPlayerManager.shared
        // CRITICAL: Widget process starts with a fresh actor (currentVisualState = .prePlay).
        // Use the robust fresh-load path so we always see the latest persisted value
        // written by forcePersistVisualState (from this process) or the main app.
        await manager.refreshVisualStateFromPersistence()
        
        let state = manager.loadSharedState()
        
        // ✅ Safe actor access with await — now authoritative because we synced above
        let visualState = await manager.currentVisualState
        
        let currentStream = manager.availableStreams.first(where: { $0.languageCode == state.currentLanguage }) ?? manager.availableStreams[0]
        let currentStation = currentStream.flag + " " + currentStream.language
        
        let statusMessage: String = {
            if state.hasError {
                return String(localized: "Connection error")
            } else if visualState == .playing {
                return String(localized: "status_playing")
            } else {
                return String(localized: "Ready")
            }
        }()
        
        return (currentStation: currentStation, statusMessage: statusMessage, visualState: visualState)
    }
    
    private func createEntry(with configuration: RadioWidgetConfiguration) async -> SimpleEntry {
        let manager = SharedPlayerManager.shared
        // Layer 1: Always refresh from persistence first (see architectural note above).
        await manager.refreshVisualStateFromPersistence()
        
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
        // Layer 1: Always refresh from persistence first (fresh actor starts at .prePlay).
        await manager.refreshVisualStateFromPersistence()

        guard let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            let state = manager.loadSharedState()
            let visualState = await manager.currentVisualState
            return (state.currentLanguage, state.hasError, visualState)
        }

        // Layer 2: Short-lived pendingAction / instantFeedback for instant UI feedback
        // (written by intents, consumed here before the main app processes the Darwin notification).
        if let pendingAction = sharedDefaults.string(forKey: "pendingAction"),
           let pendingTime = sharedDefaults.object(forKey: "pendingActionTime") as? Double {

            let actionAge = Date().timeIntervalSince1970 - pendingTime
            if actionAge < 12.0 {
                let state = manager.loadSharedState()
                let visualState = await manager.currentVisualState

                let effectiveVisualState: PlayerVisualState = {
                    switch pendingAction {
                    case "play":  return .playing
                    case "pause": return .userPaused
                    case "switch": return visualState
                    default:      return visualState
                    }
                }()

                #if DEBUG
                print("🔗 [WIDGET PROVIDER] pendingAction=\(pendingAction) → forcing visualState=\(effectiveVisualState)")
                #endif

                let language = (pendingAction == "switch")
                    ? (sharedDefaults.string(forKey: "pendingLanguage") ?? state.currentLanguage)
                    : state.currentLanguage

                return (language, state.hasError, effectiveVisualState)
            }
        }

        if let instantFeedbackTime = sharedDefaults.object(forKey: "instantFeedbackTime") as? Double,
           let instantFeedbackLanguage = sharedDefaults.string(forKey: "instantFeedbackLanguage"),
           sharedDefaults.bool(forKey: "isInstantFeedback") == true {

            let age = Date().timeIntervalSince1970 - instantFeedbackTime
            if age < 15.0 {
                let state = manager.loadSharedState()
                let visualState = await manager.currentVisualState
                return (instantFeedbackLanguage, state.hasError, visualState)
            }
        }

        // Layer 3: Final fallback — decode the JSON directly (bypasses actor memory entirely).
        let state = manager.loadSharedState()
        let visualState = SharedPlayerManager.loadPersistedVisualStateDirect()
        return (state.currentLanguage, state.hasError, visualState)
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
        
        // === OPTIMISTIC UPDATE (critical for instant icon flip) ===
        if let sharedDefaults = sharedDefaults {
            sharedDefaults.set(shouldPlay, forKey: "playing")
            
            // Brave: also write the full PlayerVisualState JSON so that any subsequent Provider run
            // (even before the main app processes the Darwin notification) will see the correct sticky state.
            let targetState: PlayerVisualState = shouldPlay ? .playing : .userPaused
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(targetState) {
                sharedDefaults.set(data, forKey: "playerVisualState")
            }
            
            sharedDefaults.synchronize()
            
            let actionId = UUID().uuidString
            let now = Date().timeIntervalSince1970
            
            sharedDefaults.set(action, forKey: "pendingAction")
            sharedDefaults.set(actionId, forKey: "pendingActionId")
            sharedDefaults.set(now, forKey: "pendingActionTime")
            
            #if DEBUG
            print("🔗 Widget set pendingAction = \(action) + playing = \(shouldPlay) (ID: \(actionId))")
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

        // Post Darwin notification
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("radio.lutheran.widget.action" as CFString),
            nil, nil, true
        )

        // Immediate feedback — modern SSOT path (no more legacy WidgetState init)
        let manager = SharedPlayerManager.shared
        let state = manager.loadSharedState()

        // Stream switch keeps the current play/pause state (only language changes)
        let visualState: PlayerVisualState = state.isPlaying ? .playing : .userPaused

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
