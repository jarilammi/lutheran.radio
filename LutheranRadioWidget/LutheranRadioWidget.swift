//
//  LutheranRadioWidget.swift
//  LutheranRadioWidget
//
//  Created by Jari Lammi on 3.6.2025.
//
//  Enhanced version with stream selection and better state management

import AppIntents
import SwiftUI
import WidgetKit
import Foundation

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
            isPlaying: false,
            currentStation: "🇺🇸 " + String(localized: "language_english"),
            statusMessage: String(localized: "Ready to play"),
            availableStreams: SharedPlayerManager.shared.availableStreams,
            configuration: RadioWidgetConfiguration()
        )
    }

    func snapshot(for configuration: RadioWidgetConfiguration, in context: Context) async -> SimpleEntry {
        return createEntry(with: configuration)
    }
    
    func timeline(for configuration: RadioWidgetConfiguration, in context: Context) async -> Timeline<SimpleEntry> {
        let entry = createEntry(with: configuration)
        
        // Create multiple entries to ensure regular updates
        let now = Date()
        let entries = [
            entry,
            // Add future entries to ensure timeline doesn't go stale
            SimpleEntry(
                date: now.addingTimeInterval(30),
                isPlaying: entry.isPlaying,
                currentStation: entry.currentStation,
                statusMessage: entry.statusMessage,
                availableStreams: entry.availableStreams,
                configuration: configuration
            )
        ]
        
        // Use shorter refresh policy to catch state changes faster
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(15)))
    }
    
    private func createEntry(with configuration: RadioWidgetConfiguration) -> SimpleEntry {
        let manager = SharedPlayerManager.shared
        
        // Check for pending widget actions first (for instant feedback)
        let (isPlaying, currentLanguage, hasError) = getPendingOrCurrentState(manager: manager)
        
        // Get the stream info based on the resolved language
        let currentStream = manager.availableStreams.first { $0.languageCode == currentLanguage } ?? manager.availableStreams[0]
        let currentStation = currentStream.flag + " " + currentStream.language
        
        // Get status message based on player state
        let statusMessage: String
        if hasError {
            statusMessage = String(localized: "Connection error")
        } else if isPlaying {
            statusMessage = String(localized: "status_playing")
        } else {
            statusMessage = String(localized: "Ready")
        }
        
        #if DEBUG
        print("🔗 Widget creating entry: playing=\(isPlaying), station=\(currentStation), status=\(statusMessage), language=\(currentLanguage)")
        #endif
        
        return SimpleEntry(
            date: Date(),
            isPlaying: isPlaying,
            currentStation: currentStation,
            statusMessage: statusMessage,
            availableStreams: manager.availableStreams,
            configuration: configuration
        )
    }
    
    // Helper method to check for pending actions and provide instant feedback
    private func getPendingOrCurrentState(manager: SharedPlayerManager) -> (isPlaying: Bool, currentLanguage: String, hasError: Bool) {
        guard let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            let state = manager.loadSharedState()
            return (state.isPlaying, state.currentLanguage, state.hasError)
        }
        
        // FIXED: Check for instant feedback first (highest priority)
        if let instantFeedbackTime = sharedDefaults.object(forKey: "instantFeedbackTime") as? Double,
           let instantFeedbackLanguage = sharedDefaults.string(forKey: "instantFeedbackLanguage"),
           sharedDefaults.bool(forKey: "isInstantFeedback") == true {
            
            let age = Date().timeIntervalSince1970 - instantFeedbackTime
            
            // Use instant feedback for 15 seconds
            if age < 15.0 {
                let state = manager.loadSharedState()
                
                #if DEBUG
                print("🔗 Using instant feedback state: \(instantFeedbackLanguage), age: \(age)s")
                #endif
                
                return (state.isPlaying, instantFeedbackLanguage, state.hasError)
            }
        }
        
        // Check for pending switch action (second priority)
        if let pendingAction = sharedDefaults.string(forKey: "pendingAction"),
           pendingAction == "switch",
           let pendingLanguage = sharedDefaults.string(forKey: "pendingLanguage"),
           let pendingTime = sharedDefaults.object(forKey: "pendingActionTime") as? Double {
            
            let actionAge = Date().timeIntervalSince1970 - pendingTime
            
            // If action is fresh (less than 3 seconds), use pending language for instant feedback
            if actionAge < 3.0 {
                #if DEBUG
                print("🔗 Using pending language for instant feedback: \(pendingLanguage), age: \(actionAge)s")
                #endif
                let state = manager.loadSharedState()
                return (state.isPlaying, pendingLanguage, state.hasError)
            }
        }
        
        // Check for recent cache update (third priority)
        let lastUpdateTime = sharedDefaults.double(forKey: "lastUpdateTime")
        let timeSinceUpdate = Date().timeIntervalSince1970 - lastUpdateTime
        
        // If very recent update (less than 2 seconds), prioritize cached state
        if timeSinceUpdate < 2.0 {
            let cachedLanguage = sharedDefaults.string(forKey: "currentLanguage") ?? "en"
            let state = manager.loadSharedState()
            
            #if DEBUG
            print("🔗 Using cached state (recent update): \(cachedLanguage), age: \(timeSinceUpdate)s")
            #endif
            
            return (state.isPlaying, cachedLanguage, state.hasError)
        }
        
        // Fall back to normal state
        let state = manager.loadSharedState()
        return (state.isPlaying, state.currentLanguage, state.hasError)
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let isPlaying: Bool
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
            // Show localized "Open App" UI when app isn't active
            VStack(spacing: 8) {
                Image(systemName: "radio")
                    .font(.title2) // Slightly smaller for more text space
                    .foregroundColor(.secondary)
                
                Text(String(localized: "tap_to_open"))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2) // Allow up to 2 lines
                    .minimumScaleFactor(0.8) // Scale down if needed
            }
            .padding()
            .widgetURL(URL(string: "lutheranradio://open"))
        } else {
            // Your existing widget UI
            VStack(spacing: 4) {
                // Current station
                Text(entry.currentStation)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                // Status
                Text(entry.statusMessage)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                Spacer()
                
                // Play/Pause button
                Button(intent: ToggleRadioIntent()) {
                    Image(systemName: entry.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundColor(entry.isPlaying ? .orange : .blue)
                }
                .buttonStyle(.plain)
            }
            .padding(8)
            .background(Color(.systemBackground))
        }
    }
    
    private func isAppRunning() -> Bool {
        // Check if we have recent state updates (within last 60 seconds)
        if let lastUpdate = UserDefaults(suiteName: "group.radio.lutheran.shared")?
            .object(forKey: "lastUpdateTime") as? Double {
            return Date().timeIntervalSince1970 - lastUpdate < 60
        }
        return false
    }
}

// MARK: - Medium Widget (4x2)
struct MediumWidgetView: View {
    let entry: SimpleEntry
    
    var body: some View {
        if !isAppRunning() {
            // Show localized "Open App" UI when app isn't active
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
            // Your existing medium widget UI
            HStack(spacing: 12) {
                // Left side - Current station info
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
                        .foregroundColor(entry.isPlaying ? .green : .secondary)
                    
                    Spacer()
                }
                
                Spacer()
                
                // Right side - Controls
                VStack(spacing: 8) {
                    // Play/Pause button
                    Button(intent: ToggleRadioIntent()) {
                        VStack(spacing: 2) {
                            Image(systemName: entry.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.title)
                                .foregroundColor(entry.isPlaying ? .orange : .blue)
                            Text(entry.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    
                    // Quick language switch (first 2 alternatives)
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
    
    private func isAppRunning() -> Bool {
        // Check if we have recent state updates (within last 60 seconds)
        if let lastUpdate = UserDefaults(suiteName: "group.radio.lutheran.shared")?
            .object(forKey: "lastUpdateTime") as? Double {
            return Date().timeIntervalSince1970 - lastUpdate < 60
        }
        return false
    }
    
    private func getCurrentStreamCode(from stationName: String) -> String {
        // Extract language code from current station display
        for stream in entry.availableStreams {
            if stationName.contains(stream.language) {
                return stream.languageCode
            }
        }
        return "en" // Default fallback
    }
}

// MARK: - Large Widget (4x4)
struct LargeWidgetView: View {
    let entry: SimpleEntry
    
    var body: some View {
        if !isAppRunning() {
            // Show localized "Open App" UI when app isn't active
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
            // Your existing large widget UI
            VStack(spacing: 12) {
                // Header
                HStack {
                    Text(String(localized: "lutheran_radio_title"))
                        .font(.headline)
                        .fontWeight(.bold)
                    Spacer()
                    Button(intent: ToggleRadioIntent()) {
                        Image(systemName: entry.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2)
                            .foregroundColor(entry.isPlaying ? .orange : .blue)
                    }
                    .buttonStyle(.plain)
                }
                
                // Current station and status
                VStack(spacing: 4) {
                    Text(entry.currentStation)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    Text(entry.statusMessage)
                        .font(.subheadline)
                        .foregroundColor(entry.isPlaying ? .green : .secondary)
                }
                
                Divider()
                
                // All available streams
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
    
    private func isAppRunning() -> Bool {
        // Check if we have recent state updates (within last 60 seconds)
        if let lastUpdate = UserDefaults(suiteName: "group.radio.lutheran.shared")?
            .object(forKey: "lastUpdateTime") as? Double {
            return Date().timeIntervalSince1970 - lastUpdate < 60
        }
        return false
    }
}

// MARK: - App Intents - FIXED

// Widget-specific toggle intent - CONNECTION SAFE
struct WidgetToggleRadioIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Lutheran Radio"
    static var description = IntentDescription("Play or pause Lutheran Radio.")

    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("🔗 WidgetToggleRadioIntent.perform called")
        #endif
        
        let manager = SharedPlayerManager.shared
        let isCurrentlyPlaying = manager.isPlaying
        
        if isCurrentlyPlaying {
            manager.stop()
        } else {
            manager.play { _ in }
        }
        
        #if DEBUG
        print("🔗 WidgetToggleRadioIntent completed successfully")
        #endif
        
        return .result()
    }
}

// Stream switching intent - CONNECTION SAFE
struct SwitchStreamIntent: AppIntent {
    static var title: LocalizedStringResource = "Switch Stream"
    static var description = IntentDescription("Switch to a different language stream.")
    
    @Parameter(title: "Language Code")
    var streamLanguageCode: String
    
    init() {}
    
    init(streamLanguageCode: String) {
        self.streamLanguageCode = streamLanguageCode
    }

    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("🔗 SwitchStreamIntent.perform called for language: \(streamLanguageCode)")
        #endif
        
        let manager = SharedPlayerManager.shared
        
        guard let targetStream = manager.availableStreams.first(where: { $0.languageCode == streamLanguageCode }) else {
            #if DEBUG
            print("🔗 SwitchStreamIntent: Language stream not found")
            #endif
            return .result()
        }
        
        // Use the fixed switchToStream method
        manager.switchToStream(targetStream)
        
        #if DEBUG
        print("🔗 SwitchStreamIntent completed for \(targetStream.language)")
        #endif
        
        return .result()
    }
}

// MARK: - Configuration Intent - FIXED
struct RadioWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Widget Configuration"
    static var description = IntentDescription("Configuration for Lutheran Radio widget.")
}
