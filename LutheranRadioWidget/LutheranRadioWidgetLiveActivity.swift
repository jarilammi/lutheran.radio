//
//  LutheranRadioWidgetLiveActivity.swift
//  LutheranRadioWidget
//
//  Created by Jari Lammi on 3.6.2025.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct LutheranRadioLiveActivityWidget: Widget {
    let kind: String = "LutheranRadioLiveActivity"

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RadioActivityAttributes.self) { context in
            // Lock Screen view
            LockScreenLiveActivityView(context: context)
        } dynamicIsland: { context in
            // Enhanced Dynamic Island - Local updates only, maximum privacy
            DynamicIsland {
                // Expanded view - Rich controls and info
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        // Animated radio icon
                        ZStack {
                            Circle()
                                .fill(context.state.isPlaying ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                                .frame(width: 32, height: 32)
                            
                            Image(systemName: "radio")
                                .foregroundColor(context.state.isPlaying ? .green : .white)
                                .font(.system(size: 16, weight: .medium))
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Lutheran Radio")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                            
                            HStack(spacing: 4) {
                                Text(context.state.currentStreamFlag)
                                    .font(.caption2)
                                Text(getLanguageName(context.state.currentStreamLanguage))
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)
                            }
                            
                            // Live indicator when playing
                            if context.state.isPlaying {
                                HStack(spacing: 2) {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 4, height: 4)
                                        .opacity(0.8)
                                    Text("LIVE")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(spacing: 8) {
                        // Main play/pause with enhanced visual feedback
                        Button(intent: LiveActivityTogglePlaybackIntent()) {
                            ZStack {
                                Circle()
                                    .fill(context.state.isPlaying ? Color.orange.opacity(0.2) : Color.blue.opacity(0.2))
                                    .frame(width: 44, height: 44)
                                
                                Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title3)
                                    .fontWeight(.semibold)
                                    .foregroundColor(context.state.isPlaying ? .orange : .blue)
                            }
                        }
                        .buttonStyle(.plain)
                        
                        // Audio visualization when playing
                        if context.state.isPlaying {
                            HStack(spacing: 2) {
                                ForEach(0..<3) { index in
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(Color.green)
                                        .frame(width: 2, height: CGFloat.random(in: 4...12))
                                        .animation(.easeInOut(duration: Double.random(in: 0.3...0.7)).repeatForever(autoreverses: true), value: context.state.lastUpdated)
                                }
                            }
                        }
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 6) {
                        // Current content display
                        if let metadata = context.state.currentMetadata, !metadata.isEmpty {
                            VStack(spacing: 2) {
                                Text("Now Playing")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .textCase(.uppercase)
                                
                                Text(metadata)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .foregroundColor(.primary)
                            }
                        } else {
                            VStack(spacing: 2) {
                                Text(context.state.streamStatus)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(context.state.isPlaying ? .green : .secondary)
                                
                                if context.state.isPlaying {
                                    Text("Lutheran Radio Live Stream")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        
                        // Enhanced language switcher with visual feedback
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(getAlternativeStreams(current: context.state.currentStreamLanguage), id: \.self) { langCode in
                                    Button(intent: LiveActivitySwitchStreamIntent(languageCode: langCode)) {
                                        VStack(spacing: 2) {
                                            Text(getStreamFlag(langCode))
                                                .font(.system(size: 16))
                                            Text(getLanguageName(langCode))
                                                .font(.system(size: 8, weight: .medium))
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.gray.opacity(0.1))
                                        .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        // Connection status indicator
                        HStack(spacing: 4) {
                            Circle()
                                .fill(getStatusColor(context.state))
                                .frame(width: 6, height: 6)
                            Text(context.state.streamStatus)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        // Enhanced audio visualization
                        if context.state.isPlaying {
                            HStack(spacing: 1) {
                                ForEach(0..<5) { index in
                                    RoundedRectangle(cornerRadius: 0.5)
                                        .fill(LinearGradient(
                                            gradient: Gradient(colors: [.green, .blue]),
                                            startPoint: .bottom,
                                            endPoint: .top
                                        ))
                                        .frame(width: 2, height: CGFloat.random(in: 3...10))
                                        .animation(
                                            .easeInOut(duration: Double.random(in: 0.3...0.8))
                                            .repeatForever(autoreverses: true)
                                            .delay(Double(index) * 0.1),
                                            value: context.state.lastUpdated
                                        )
                                }
                            }
                        } else {
                            // Privacy indicator when not playing
                            HStack(spacing: 2) {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 8))
                                    .foregroundColor(.green)
                                Text("Local Only")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundColor(.green)
                            }
                        }
                    }
                }
            } compactLeading: {
                // Enhanced compact leading view
                HStack(spacing: 2) {
                    ZStack {
                        Circle()
                            .fill(context.state.isPlaying ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                            .frame(width: 20, height: 20)
                        
                        Image(systemName: "radio")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(context.state.isPlaying ? .green : .white)
                    }
                    
                    if context.state.isPlaying {
                        // Mini audio bars
                        HStack(spacing: 1) {
                            ForEach(0..<2) { index in
                                RoundedRectangle(cornerRadius: 0.5)
                                    .fill(Color.green)
                                    .frame(width: 1, height: CGFloat.random(in: 2...6))
                                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: context.state.lastUpdated)
                            }
                        }
                    }
                }
            } compactTrailing: {
                // Enhanced compact trailing view
                Button(intent: LiveActivityTogglePlaybackIntent()) {
                    ZStack {
                        Circle()
                            .fill(context.state.isPlaying ? Color.orange.opacity(0.3) : Color.blue.opacity(0.3))
                            .frame(width: 20, height: 20)
                        
                        Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(context.state.isPlaying ? .orange : .blue)
                    }
                }
                .buttonStyle(.plain)
            } minimal: {
                // Enhanced minimal view with status indication
                ZStack {
                    Circle()
                        .fill(getStatusColor(context.state).opacity(0.3))
                        .frame(width: 18, height: 18)
                    
                    if context.state.isPlaying {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.green)
                    } else {
                        Image(systemName: "radio")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.gray)
                    }
                }
            }
        }
    }
    
    // Enhanced helper functions for privacy-first Live Activity
    private func getLanguageName(_ code: String) -> String {
        switch code {
        case "en": return "English"
        case "de": return "German"
        case "fi": return "Finnish"
        case "sv": return "Swedish"
        case "ee": return "Estonian"
        default: return "Unknown"
        }
    }
    
    private func getStreamFlag(_ code: String) -> String {
        switch code {
        case "en": return "🇺🇸"
        case "de": return "🇩🇪"
        case "fi": return "🇫🇮"
        case "sv": return "🇸🇪"
        case "ee": return "🇪🇪"
        default: return "🌍"
        }
    }
    
    private func getAlternativeStreams(current: String) -> [String] {
        let allStreams = ["en", "de", "fi", "sv", "ee"]
        return Array(allStreams.filter { $0 != current }.prefix(3))
    }
    
    private func getStatusColor(_ state: RadioActivityAttributes.ContentState) -> Color {
        if state.streamStatus.contains("Error") {
            return .red
        } else if state.isPlaying {
            return .green
        } else {
            return .gray
        }
    }
}

// MARK: - Lock Screen View
struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<RadioActivityAttributes>
    
    var body: some View {
        VStack(spacing: 12) {
            // Header with app name and current stream
            HStack {
                Image(systemName: "radio")
                    .foregroundColor(.white)
                Text("Lutheran Radio")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(context.state.currentStreamFlag) \(getLanguageName(context.state.currentStreamLanguage))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            // Current metadata or status
            if let metadata = context.state.currentMetadata, !metadata.isEmpty {
                Text(metadata)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            } else {
                Text(context.state.streamStatus)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            // Controls section
            HStack(spacing: 20) {
                // Language quick switches (first 3 alternatives)
                ForEach(getAlternativeStreams(current: context.state.currentStreamLanguage).prefix(3), id: \.self) { langCode in
                    Button(intent: LiveActivitySwitchStreamIntent(languageCode: langCode)) {
                        VStack(spacing: 2) {
                            Text(getStreamFlag(langCode))
                                .font(.title3)
                            Text(getLanguageName(langCode))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                
                Spacer()
                
                // Main play/pause button
                Button(intent: LiveActivityTogglePlaybackIntent()) {
                    VStack(spacing: 4) {
                        Image(systemName: context.state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.largeTitle)
                            .foregroundColor(context.state.isPlaying ? .orange : .green)
                        Text(context.state.isPlaying ? "Pause" : "Play")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            
            // Status indicator
            HStack {
                Circle()
                    .fill(context.state.isPlaying ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(context.state.streamStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if context.state.isPlaying {
                    HStack(spacing: 1) {
                        ForEach(0..<4) { index in
                            Rectangle()
                                .fill(Color.green)
                                .frame(width: 2, height: 6)
                                .opacity(Double.random(in: 0.3...1.0))
                                .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true), value: context.state.lastUpdated)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.black.opacity(0.8))
        .cornerRadius(12)
    }
    
    private func getLanguageName(_ code: String) -> String {
        switch code {
        case "en": return "English"
        case "de": return "German"
        case "fi": return "Finnish"
        case "sv": return "Swedish"
        case "ee": return "Estonian"
        default: return "Unknown"
        }
    }
    
    private func getAlternativeStreams(current: String) -> [String] {
        let allStreams = ["en", "de", "fi", "sv", "ee"]
        return allStreams.filter { $0 != current }
    }
    
    private func getStreamFlag(_ code: String) -> String {
        switch code {
        case "en": return "🇺🇸"
        case "de": return "🇩🇪"
        case "fi": return "🇫🇮"
        case "sv": return "🇸🇪"
        case "ee": return "🇪🇪"
        default: return "🌍"
        }
    }
}
