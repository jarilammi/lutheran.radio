//
//  LutheranRadioWidgetLiveActivity.swift
//  LutheranRadioWidget
//
//  Created by Jari Lammi on 3.6.2025.
//

import ActivityKit
import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Live Activity Helpers (single source of truth for both Dynamic Island and Lock Screen views)

/// Maps visual state to a status color used in the Live Activity UI.
private func getStatusColor(_ visualState: PlayerVisualState) -> Color {
    switch visualState {
    case .thermalPaused: return .orange
    case .securityLocked: return .red
    case .playing:       return .green
    default:             return .gray
    }
}

/// Derives a localized status string for display in Live Activity (replaces legacy streamStatus).
/// Reads hasError from shared app group for parity with widget providers.
private func getCurrentStreamStatus(visualState: PlayerVisualState) -> String {
    let hasError = UserDefaults(suiteName: "group.radio.lutheran.shared")?.bool(forKey: "hasError") ?? false
    if hasError {
        return String(localized: "Connection error", defaultValue: "Connection error")
    } else if visualState == .thermalPaused {
        return String(localized: "status_thermal_paused", defaultValue: "Thermal pause")
    } else if visualState.isActivelyPlaying {
        return String(localized: "LIVE", defaultValue: "Live")
    } else {
        return String(localized: "Ready", defaultValue: "Ready")
    }
}

/// Returns the localized display name for a language code.
private func getLanguageName(_ code: String) -> String {
    switch code {
    case "en": return String(localized: "language_english")
    case "de": return String(localized: "language_german")
    case "fi": return String(localized: "language_finnish")
    case "sv": return String(localized: "language_swedish")
    case "et": return String(localized: "language_estonian")
    default: return "Unknown"
    }
}

/// Returns the flag emoji for a language code.
private func getStreamFlag(_ code: String) -> String {
    switch code {
    case "en": return "🇺🇸"
    case "de": return "🇩🇪"
    case "fi": return "🇫🇮"
    case "sv": return "🇸🇪"
    case "et": return "🇪🇪"
    default: return "🌍"
    }
}

/// Returns up to 3 alternative language codes (excluding the current one).
private func getAlternativeStreams(current: String) -> [String] {
    let allStreams = ["en", "de", "fi", "sv", "et"]
    return Array(allStreams.filter { $0 != current }.prefix(3))
}

/// Primary program title for Live Activity display, with localized fallback.
private func programDisplayTitle(
    metadata: StreamProgramMetadata?,
    visualState: PlayerVisualState,
    languageCode: String
) -> String {
    if let title = metadata?.programTitle, !title.isEmpty {
        return title
    }
    if visualState.isActivelyPlaying {
        return unsafe String(
            format: String(localized: "live_activity_program_fallback", defaultValue: "%@ · Live Stream"),
            getLanguageName(languageCode)
        )
    }
    return String(localized: "no_track_info", defaultValue: "No track information")
}

/// Secondary speaker line when parsed from ICY metadata.
private func programSpeakerLine(metadata: StreamProgramMetadata?) -> String? {
    guard let speaker = metadata?.speaker, !speaker.isEmpty else { return nil }
    return speaker
}

// MARK: - Live Activity Intents (updated for SSOT + Swift 6)

struct LiveActivityTogglePlaybackIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Toggle Lutheran Radio Playback" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Toggle play/pause from Live Activity.")
    }
    
    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[LutheranRadioWidgetLiveActivity] LiveActivityTogglePlaybackIntent.perform called")
        #endif
        
        let manager = SharedPlayerManager.shared
        let visualState = await manager.currentVisualState   // Safe actor access (SSOT)
        
        if visualState.isActivelyPlaying {
            await manager.stop()
        } else {
            await manager.play()   // ← Fixed: no more 'try'
        }
        
        #if DEBUG
        print("[LutheranRadioWidgetLiveActivity] LiveActivityTogglePlaybackIntent completed – visualState was \(visualState)")
        #endif
        
        return .result()
    }
}

struct LiveActivitySwitchStreamIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Switch Stream" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Switch to a different language stream from Live Activity.")
    }
    
    @Parameter(title: "Language Code")
    var languageCode: String
    
    init() {}
    init(languageCode: String) {
        self.languageCode = languageCode
    }

    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[LutheranRadioWidgetLiveActivity] LiveActivitySwitchStreamIntent.perform called for language: \(languageCode)")
        #endif
        
        let manager = SharedPlayerManager.shared
        
        guard let targetStream = manager.availableStreams.first(where: { $0.languageCode == languageCode }) else {
            #if DEBUG
            print("[LutheranRadioWidgetLiveActivity] LiveActivitySwitchStreamIntent: Language stream not found")
            #endif
            return .result()
        }
        
        await manager.switchToStream(targetStream)
        
        #if DEBUG
        print("[LutheranRadioWidgetLiveActivity] LiveActivitySwitchStreamIntent completed for \(targetStream.language)")
        #endif
        
        return .result()
    }
}

struct LutheranRadioLiveActivityWidget: Widget {
    let kind: String = "LutheranRadioLiveActivity"

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LutheranRadioLiveActivityAttributes.self) { context in
            LockScreenLiveActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(context.state.visualState == .playing ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                                .frame(width: 32, height: 32)
                            
                            Image(systemName: "radio")
                                .foregroundColor(context.state.visualState.buttonTintColor.swiftUIColor)
                                .font(.system(size: 16, weight: .medium))
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LocalizedStringKey("lutheran_radio_title"))
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                            
                            HStack(spacing: 4) {
                                Text(getStreamFlag(SharedPlayerManager.preferredWidgetLanguage()))
                                    .font(.caption2)
                                Text(getLanguageName(SharedPlayerManager.preferredWidgetLanguage()))
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)
                            }
                            
                            if context.state.visualState.isActivelyPlaying {
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
                        Button(intent: LiveActivityTogglePlaybackIntent()) {
                            ZStack {
                                Circle()
                                    .fill(context.state.visualState.buttonTintColor.swiftUIColor.opacity(0.2))
                                    .frame(width: 44, height: 44)
                                
                                Image(systemName: context.state.visualState.isActivelyPlaying ? "pause.fill" : "play.fill")
                                    .font(.title3)
                                    .fontWeight(.semibold)
                                    .foregroundColor(context.state.visualState.buttonTintColor.swiftUIColor)
                            }
                        }
                        .buttonStyle(.plain)
                        
                        if context.state.visualState.isActivelyPlaying {
                            HStack(spacing: 2) {
                                ForEach(0..<3, id: \.self) { index in
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(Color.green)
                                        .frame(width: 2, height: CGFloat.random(in: 4...12))
                                        .animation(.easeInOut(duration: Double.random(in: 0.3...0.7)).repeatForever(autoreverses: true), value: context.state.visualState)
                                }
                            }
                        }
                    }
                }
                
                DynamicIslandExpandedRegion(.center) {
                    let currentLanguage = SharedPlayerManager.preferredWidgetLanguage()
                    VStack(spacing: 6) {
                        VStack(spacing: 2) {
                            Text(getCurrentStreamStatus(visualState: context.state.visualState))
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(context.state.visualState.textColor.swiftUIColor)
                            
                            if context.state.visualState.isActivelyPlaying {
                                Text(programDisplayTitle(
                                    metadata: context.state.streamMetadata,
                                    visualState: context.state.visualState,
                                    languageCode: currentLanguage
                                ))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                
                                if let speaker = programSpeakerLine(metadata: context.state.streamMetadata) {
                                    Text(speaker)
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(getAlternativeStreams(current: SharedPlayerManager.preferredWidgetLanguage()), id: \.self) { langCode in
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
                        HStack(spacing: 4) {
                            Circle()
                                .fill(getStatusColor(context.state.visualState))
                                .frame(width: 6, height: 6)
                            Text(getCurrentStreamStatus(visualState: context.state.visualState))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        if context.state.visualState.isActivelyPlaying {
                            HStack(spacing: 1) {
                                ForEach(0..<5, id: \.self) { index in
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
                                            value: context.state.visualState
                                        )
                                }
                            }
                        } else {
                            HStack(spacing: 2) {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 8))
                                    .foregroundColor(.green)
                                Text(LocalizedStringKey("Local Only"))
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundColor(.green)
                            }
                        }
                    }
                }
            } compactLeading: {
                let currentLanguage = SharedPlayerManager.preferredWidgetLanguage()
                HStack(spacing: 2) {
                    ZStack {
                        Circle()
                            .fill(context.state.visualState.isActivelyPlaying ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                            .frame(width: 20, height: 20)
                        
                        Image(systemName: "radio")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(context.state.visualState.buttonTintColor.swiftUIColor)
                    }
                    
                    if context.state.visualState.isActivelyPlaying {
                        HStack(spacing: 1) {
                            ForEach(0..<2, id: \.self) { index in
                                RoundedRectangle(cornerRadius: 0.5)
                                    .fill(Color.green)
                                    .frame(width: 1, height: CGFloat.random(in: 2...6))
                                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: context.state.visualState)
                            }
                        }
                        
                        if let title = context.state.streamMetadata?.programTitle, !title.isEmpty {
                            Text(title)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        } else {
                            Text(programDisplayTitle(
                                metadata: context.state.streamMetadata,
                                visualState: context.state.visualState,
                                languageCode: currentLanguage
                            ))
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            } compactTrailing: {
                Button(intent: LiveActivityTogglePlaybackIntent()) {
                    ZStack {
                        Circle()
                            .fill(context.state.visualState.buttonTintColor.swiftUIColor.opacity(0.3))
                            .frame(width: 20, height: 20)
                        
                        Image(systemName: context.state.visualState.isActivelyPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(context.state.visualState.buttonTintColor.swiftUIColor)
                    }
                }
                .buttonStyle(.plain)
            } minimal: {
                ZStack {
                    Circle()
                        .fill(getStatusColor(context.state.visualState).opacity(0.3))
                        .frame(width: 18, height: 18)
                    
                    if context.state.visualState.isActivelyPlaying {
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
}

// MARK: - Lock Screen View

struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<LutheranRadioLiveActivityAttributes>
    
    var body: some View {
        let currentLanguage = SharedPlayerManager.preferredWidgetLanguage()
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "radio")
                    .foregroundColor(.white)
                Text(LocalizedStringKey("lutheran_radio_title"))
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(getStreamFlag(currentLanguage)) \(getLanguageName(currentLanguage))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Text(getCurrentStreamStatus(visualState: context.state.visualState))
                .font(.subheadline)
                .foregroundColor(context.state.visualState.textColor.swiftUIColor)
            
            if context.state.visualState.isActivelyPlaying {
                VStack(spacing: 4) {
                    Text(programDisplayTitle(
                        metadata: context.state.streamMetadata,
                        visualState: context.state.visualState,
                        languageCode: currentLanguage
                    ))
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    
                    if let speaker = programSpeakerLine(metadata: context.state.streamMetadata) {
                        Text(speaker)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            
            HStack(spacing: 20) {
                ForEach(getAlternativeStreams(current: currentLanguage), id: \.self) { langCode in
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
                
                Button(intent: LiveActivityTogglePlaybackIntent()) {
                    VStack(spacing: 4) {
                        Image(systemName: context.state.visualState.isActivelyPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.largeTitle)
                            .foregroundColor(context.state.visualState.buttonTintColor.swiftUIColor)
                        Text(context.state.visualState.isActivelyPlaying ? LocalizedStringKey("status_paused") : LocalizedStringKey("Play"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            
            HStack {
                Circle()
                    .fill(getStatusColor(context.state.visualState))
                    .frame(width: 8, height: 8)
                Text(getCurrentStreamStatus(visualState: context.state.visualState))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if context.state.visualState.isActivelyPlaying {
                    HStack(spacing: 1) {
                        ForEach(0..<4, id: \.self) { index in
                            Rectangle()
                                .fill(Color.green)
                                .frame(width: 2, height: 6)
                                .opacity(Double.random(in: 0.3...1.0))
                                .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true), value: context.state.visualState)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.black.opacity(0.8))
        .cornerRadius(12)
    }
}
