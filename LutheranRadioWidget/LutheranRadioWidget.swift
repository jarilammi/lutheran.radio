//
//  LutheranRadioWidget.swift
//  LutheranRadioWidget
//
//  Created by Jari Lammi on 3.6.2025.
//

import WidgetKit
import SwiftUI
import AppIntents

struct LutheranRadioWidget: Widget {
    let kind: String = "LutheranRadioWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: RadioWidgetConfiguration.self, provider: Provider()) { entry in
            LutheranRadioWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Lutheran Radio")
        .description("Control and monitor Lutheran Radio playback.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(
            date: Date(),
            isPlaying: false,
            currentStation: "🇺🇸 English",
            configuration: RadioWidgetConfiguration()
        )
    }

    func snapshot(for configuration: RadioWidgetConfiguration, in context: Context) async -> SimpleEntry {
        SimpleEntry(
            date: Date(),
            isPlaying: false,
            currentStation: "🇺🇸 English",
            configuration: configuration
        )
    }
    
    func timeline(for configuration: RadioWidgetConfiguration, in context: Context) async -> Timeline<SimpleEntry> {
        var entries: [SimpleEntry] = []
        
        // Get current state from DirectStreamingPlayer
        let isPlaying = DirectStreamingPlayer.shared.player?.rate ?? 0 > 0
        let currentStation = DirectStreamingPlayer.shared.selectedStream.flag + " " + DirectStreamingPlayer.shared.selectedStream.language
        
        let currentDate = Date()
        let entry = SimpleEntry(
            date: currentDate,
            isPlaying: isPlaying,
            currentStation: currentStation,
            configuration: configuration
        )
        entries.append(entry)

        // Update every 30 seconds
        let nextUpdate = Calendar.current.date(byAdding: .second, value: 30, to: currentDate)!
        return Timeline(entries: entries, policy: .after(nextUpdate))
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let isPlaying: Bool
    let currentStation: String
    let configuration: RadioWidgetConfiguration
}

struct LutheranRadioWidgetEntryView: View {
    var entry: Provider.Entry

    var body: some View {
        VStack(spacing: 8) {
            // Station info
            HStack {
                Text(entry.currentStation)
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }
            
            // Status
            HStack {
                Image(systemName: entry.isPlaying ? "play.fill" : "pause.fill")
                    .foregroundColor(entry.isPlaying ? .green : .gray)
                Text(entry.isPlaying ? "Playing" : "Stopped")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            
            Spacer()
            
            // Play/Pause button
            Button(intent: ToggleRadioIntent()) {
                HStack {
                    Image(systemName: entry.isPlaying ? "pause.fill" : "play.fill")
                    Text(entry.isPlaying ? "Pause" : "Play")
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.blue)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color(.systemBackground))
    }
}

struct RadioWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Widget Configuration"
    static var description = IntentDescription("Configuration for Lutheran Radio widget.")
}
