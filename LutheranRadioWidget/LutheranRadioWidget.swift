//
//  LutheranRadioWidget.swift
//  LutheranRadioWidget
//
//  Created by Jari Lammi on 3.6.2025.
//
//  Enhanced version with stream selection and better state management

import WidgetKit
import SwiftUI
import AppIntents

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
            availableStreams: DirectStreamingPlayer.availableStreams,
            configuration: RadioWidgetConfiguration()
        )
    }

    func snapshot(for configuration: RadioWidgetConfiguration, in context: Context) async -> SimpleEntry {
        SimpleEntry(
            date: Date(),
            isPlaying: false,
            currentStation: "🇺🇸 " + String(localized: "language_english"),
            statusMessage: String(localized: "Ready to play"),
            availableStreams: DirectStreamingPlayer.availableStreams,
            configuration: configuration
        )
    }
    
    func timeline(for configuration: RadioWidgetConfiguration, in context: Context) async -> Timeline<SimpleEntry> {
        let player = DirectStreamingPlayer.shared
        let isPlaying = player.isPlaying
        let currentStream = player.selectedStream
        let currentStation = currentStream.flag + " " + currentStream.language
        
        // Get status message based on player state
        let statusMessage: String
        switch player.getPlaybackState() {
        case .readyToPlay:
            statusMessage = isPlaying ? String(localized: "status_playing") : String(localized: "Ready")
        case .failed(_):
            if player.isLastErrorPermanent() {
                statusMessage = String(localized: "Service unavailable")
            } else {
                statusMessage = String(localized: "Connection error")
            }
        case .unknown:
            statusMessage = String(localized: "status_buffering") + "..."
        }
        
        let entry = SimpleEntry(
            date: Date(),
            isPlaying: isPlaying,
            currentStation: currentStation,
            statusMessage: statusMessage,
            availableStreams: DirectStreamingPlayer.availableStreams,
            configuration: configuration
        )

        // Update more frequently when playing, less when stopped
        let updateInterval = isPlaying ? 15 : 60
        let nextUpdate = Calendar.current.date(byAdding: .second, value: updateInterval, to: Date())!
        return Timeline(entries: [entry], policy: .after(nextUpdate))
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
            Button(intent: WidgetToggleRadioIntent()) {
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

// MARK: - Medium Widget (4x2)
struct MediumWidgetView: View {
    let entry: SimpleEntry
    
    var body: some View {
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
                Button(intent: WidgetToggleRadioIntent()) {
                    VStack(spacing: 2) {
                        Image(systemName: entry.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title)
                            .foregroundColor(entry.isPlaying ? .orange : .blue)
                        Text(entry.isPlaying ? String(localized: "status_paused") : String(localized: "status_playing"))
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
        VStack(spacing: 12) {
            // Header
            HStack {
                Text(String(localized: "lutheran_radio_title"))
                    .font(.headline)
                    .fontWeight(.bold)
                Spacer()
                Button(intent: WidgetToggleRadioIntent()) {
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

// MARK: - App Intents
struct WidgetToggleRadioIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Lutheran Radio"
    static var description = IntentDescription("Play or pause Lutheran Radio.")

    func perform() async throws -> some IntentResult {
        let player = DirectStreamingPlayer.shared
        let isCurrentlyPlaying = player.isPlaying
        
        if isCurrentlyPlaying {
            player.stop()
        } else {
            await withCheckedContinuation { continuation in
                player.play { success in
                    continuation.resume()
                }
            }
        }
        
        return .result()
    }
}

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
        let player = DirectStreamingPlayer.shared
        
        guard let targetStream = DirectStreamingPlayer.availableStreams.first(where: { $0.languageCode == streamLanguageCode }) else {
            return .result()
        }
        
        // Switch to the new stream
        player.setStream(to: targetStream)
        
        return .result()
    }
}

struct RadioWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Widget Configuration"
    static var description = IntentDescription("Configuration for Lutheran Radio widget.")
}
