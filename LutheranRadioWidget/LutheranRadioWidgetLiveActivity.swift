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
/// Reads hasError via `loadSharedState()` for parity with widget providers.
private func getCurrentStreamStatus(visualState: PlayerVisualState) -> String {
    let hasError = SharedPlayerManager.shared.loadSharedState().hasError
    if hasError {
        return String(localized: "Connection error", defaultValue: "Connection error", table: "Localizable")
    } else if visualState == .thermalPaused {
        return String(localized: "status_thermal_paused", defaultValue: "Thermal pause", table: "Localizable")
    } else if visualState.isActivelyPlaying {
        return String(localized: "LIVE", defaultValue: "Live", table: "Localizable")
    } else {
        return String(localized: "Ready", defaultValue: "Ready", table: "Localizable")
    }
}

/// Returns the localized display name for a language code.
/// Now forwards to the shared general implementation in WidgetDisplayModels (prefers
/// real availableStreams when present + established localized fallback mapping).
private func getLanguageName(_ code: String) -> String {
    displayLanguageName(for: code)
}

/// Returns the flag emoji for a language code.
/// Now forwards to the shared general implementation.
private func getStreamFlag(_ code: String) -> String {
    displayFlag(for: code)
}

/// Returns up to 3 alternative language codes (excluding the current one).
private func getAlternativeStreams(current: String) -> [String] {
    let allStreams = ["en", "de", "fi", "sv", "et"]
    return Array(allStreams.filter { $0 != current }.prefix(3))
}

// Unified program title + speaker resolver now lives in WidgetDisplayModels.swift
// (along with WidgetMetadataEmphasis). Live Activity computes languageName locally
// for the fallback string and passes the resolved model into the fixed metadata region.

// MARK: - Live Activity Intents (updated for SSOT + Swift 6)

// Privacy note: Live Activities observe state via the PersistedWidgetState snapshot (write suppression / clear local state support)
// (or loadSharedState fallbacks). When absent after clearAllLocalState() or because
// SharedPlayerManager.hasActiveWidgets == false (no Lutheran widgets/Control installed),
// the LA ends on clear and subsequent presentations fall back to neutral prePlay-like UI.
// See WidgetRefreshManager.hasActiveLutheranWidgets (the single source) and the write guards
// in SharedPlayerManager (persist/save/writeInstantFeedback/bump/schedule/performActualSave etc.).

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
                    // Use the shared display model so the title is always present and the speaker line
                    // reserves vertical space (via \u{00A0} + opacity) for layout stability.
                    let languageName = SharedPlayerManager.streamForLanguageCode(currentLanguage).language
                    let metadataModel = widgetNowPlayingDisplayModel(
                        visualState: context.state.visualState,
                        streamMetadata: context.state.streamMetadata,
                        languageName: languageName
                    )
                    VStack(spacing: 6) {
                        VStack(spacing: 2) {
                            Text(getCurrentStreamStatus(visualState: context.state.visualState))
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(context.state.visualState.textColor.swiftUIColor)
                            
                            // Fixed metadata region (no conditional insertion) using shared model + emphasis.
                            Text(metadataModel.programTitle)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.primary)
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                                .truncationMode(.tail)
                                .multilineTextAlignment(.center)
                                .opacity(metadataModel.emphasis.opacity)
                                .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 22, alignment: .center)
                            
                            Text(metadataModel.speakerLine)
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .opacity(metadataModel.speakerVisible ? metadataModel.emphasis.opacity : 0)
                                .frame(maxWidth: .infinity, minHeight: 12, maxHeight: 14, alignment: .center)
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
                        
                        // Use shared model for title (compact leading shows only while actively; model yields metadata or live fallback).
                        let languageName = SharedPlayerManager.streamForLanguageCode(currentLanguage).language
                        let compactModel = widgetNowPlayingDisplayModel(
                            visualState: context.state.visualState,
                            streamMetadata: context.state.streamMetadata,
                            languageName: languageName
                        )
                        Text(compactModel.programTitle)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
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
        // Compute language display name from authoritative streams (full set) for consistent live fallback.
        let languageName = SharedPlayerManager.streamForLanguageCode(currentLanguage).language
        let metadataModel = widgetNowPlayingDisplayModel(
            visualState: context.state.visualState,
            streamMetadata: context.state.streamMetadata,
            languageName: languageName
        )
        
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "radio")
                    .foregroundColor(.white)
                Text(String(localized: "lutheran_radio_title", table: "Localizable"))
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
            
            // Fixed metadata region using the shared display model + emphasis.
            // Both title and speaker lines are always laid out (speaker uses \u{00A0} when absent
            // and opacity 0) so the region does not jump when playback state or ICY metadata changes.
            VStack(spacing: 4) {
                Text(metadataModel.programTitle)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .truncationMode(.tail)
                    .opacity(metadataModel.emphasis.opacity)
                    .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 48, alignment: .center)
                
                Text(metadataModel.speakerLine)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(metadataModel.speakerVisible ? metadataModel.emphasis.opacity : 0)
                    .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 22, alignment: .center)
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
                        Text(context.state.visualState.isActivelyPlaying
                             ? String(localized: "status_paused", defaultValue: "Paused", table: "Localizable")
                             : String(localized: "Play", defaultValue: "Play", table: "Localizable"))
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
