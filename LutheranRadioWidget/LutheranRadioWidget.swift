//
//  LutheranRadioWidget.swift
//  LutheranRadioWidget
//
//  Created by Jari Lammi on 3.6.2025.
//
//  DOCUMENTATION FOR APPLE REVIEW:
//  ================================
//  This file implements Home Screen Widgets for Lutheran Radio - a religious radio streaming app.
//
//  APP PURPOSE:
//  - Provides access to Lutheran religious content (sermons and educational programming)
//  - Educational and spiritual content delivery through audio streaming
//
//  WIDGET FUNCTIONALITY:
//  - Small Widget (2x2): Quick play/pause with current station display
//  - Medium Widget (4x2): Play controls plus quick language switching
//  - Large Widget (4x4): Full control panel with all available language streams
//
//  USER PRIVACY:
//  - No personal data collection or user tracking
//
//  NETWORK USAGE:
//  - Respects iOS background refresh policies
//  - Graceful handling of network connectivity issues
//
//  Enhanced version with stream selection and better state management

import AppIntents
import SwiftUI
import WidgetKit
import Foundation

/**
 * MAIN HOME SCREEN WIDGET
 * ========================
 * Primary widget implementation supporting all iOS Home Screen widget sizes.
 * Provides Lutheran radio control functionality directly from the Home Screen.
 *
 * Supported Sizes:
 * - Small (2x2): Essential controls and status
 * - Medium (4x2): Controls plus quick language switching
 * - Large (4x4): Full control panel with all language options
 */
struct LutheranRadioWidget: Widget {
    /// Unique identifier for this widget type
    let kind: String = "LutheranRadioWidget"

    /// Widget configuration defining supported sizes and functionality
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: RadioWidgetConfiguration.self, provider: Provider()) { entry in
            LutheranRadioWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(String(localized: "lutheran_radio_title"))
        .description(String(localized: "Control playback and switch between language streams."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/**
 * WIDGET DATA PROVIDER
 * =====================
 * Manages data flow and timeline updates for the Home Screen widget.
 * Implements intelligent refresh strategies to balance responsiveness with battery life.
 */
struct Provider: AppIntentTimelineProvider {
    
    /**
     * Provides placeholder content for widget gallery and initial display
     * Shows representative content when actual data isn't available
     */
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
    
    /**
     * Provides snapshot for widget configuration UI
     * Used when user is selecting and configuring widgets
     */
    func snapshot(for configuration: RadioWidgetConfiguration, in context: Context) async -> SimpleEntry {
        await createEntry(with: configuration)
    }
    
    /**
     * Creates widget timeline with intelligent refresh policy
     * 15-minute refresh interval balances responsiveness and battery life
     */
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
        let state = manager.loadSharedState()
        
        // ✅ Safe actor access with await
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
        guard let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            let state = manager.loadSharedState()
            let visualState = await manager.currentVisualState
            return (state.currentLanguage, state.hasError, visualState)
        }
        
        // === CRITICAL: Handle pending play/pause actions for instant widget feedback ===
        if let pendingAction = sharedDefaults.string(forKey: "pendingAction"),
           let pendingTime = sharedDefaults.object(forKey: "pendingActionTime") as? Double {
            
            let actionAge = Date().timeIntervalSince1970 - pendingTime
            if actionAge < 12.0 {   // enough time for widget → main-app roundtrip
                let state = manager.loadSharedState()
                let visualState = await manager.currentVisualState
                
                let effectiveVisualState: PlayerVisualState = {
                    switch pendingAction {
                    case "play":  return .playing
                    case "pause": return .userPaused   // or .paused depending on your enum
                    case "switch":
                        return visualState
                    default:
                        return visualState
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
        
        // instant feedback for language switch
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
        
        // normal path
        let state = manager.loadSharedState()
        let visualState = await manager.currentVisualState
        return (state.currentLanguage, state.hasError, visualState)
    }
}

/**
 * WIDGET TIMELINE ENTRY
 * ======================
 * Data structure representing a single point in the widget's timeline.
 * Contains all information needed to render the widget at a specific time.
 */
struct SimpleEntry: TimelineEntry, Sendable {
    let date: Date
    let visualState: PlayerVisualState
    let currentStation: String
    let statusMessage: String
    let availableStreams: [DirectStreamingPlayer.Stream]
    let configuration: RadioWidgetConfiguration
}

/**
 * WIDGET VIEW ROUTER
 * ==================
 * Routes to appropriate widget view based on widget family size.
 * Ensures optimal layout and functionality for each widget size.
 */
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

/**
 * SMALL WIDGET VIEW
 * =================
 * Compact 2x2 widget providing essential Lutheran radio controls.
 *
 * Features:
 * - Current station display with flag emoji
 * - Playback status indicator
 * - Single-tap play/pause control
 * - App launch prompt when app isn't active
 *
 * Design Philosophy:
 * - Minimal but informative
 * - Large, easily tappable controls
 * - Clear visual state indicators
 */
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
                    Image(systemName: "playpause.fill")
                        .font(.title2)
                        .foregroundColor(entry.visualState.buttonTintColor.swiftUIColor)
                }
                .buttonStyle(.plain)
            }
            .padding(8)
            .background(Color(.systemBackground))
        }
    }
    
    private func isAppRunning() -> Bool {
        if let lastUpdate = UserDefaults(suiteName: "group.radio.lutheran.shared")?
            .object(forKey: "lastUpdateTime") as? Double {
            return Date().timeIntervalSince1970 - lastUpdate < 60
        }
        return false
    }
}

// MARK: - Medium Widget (4x2)

/**
 * MEDIUM WIDGET VIEW
 * ==================
 * Expanded 4x2 widget with additional language switching capabilities.
 *
 * Features:
 * - Detailed station information display
 * - Play/pause control with visual feedback
 * - Quick access to 2 alternative language streams
 * - App launch prompt with additional context
 *
 * Layout:
 * - Left side: Station info and status
 * - Right side: Controls and quick switches
 */
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
                            Image(systemName: "playpause.fill")
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
    
    private func isAppRunning() -> Bool {
        if let lastUpdate = UserDefaults(suiteName: "group.radio.lutheran.shared")?
            .object(forKey: "lastUpdateTime") as? Double {
            return Date().timeIntervalSince1970 - lastUpdate < 60
        }
        return false
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

/**
 * LARGE WIDGET VIEW
 * =================
 * Full-featured 4x4 widget providing complete Lutheran radio control.
 *
 * Features:
 * - Comprehensive station information
 * - All available language streams in grid layout
 * - Visual indicators for currently selected stream
 * - App launch prompt with detailed instructions
 *
 * Design:
 * - Header with title and play control
 * - Current station prominently displayed
 * - Grid of all available language options
 * - Clear visual selection indicators
 */
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
                        Image(systemName: "playpause.fill")
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
    
    private func isAppRunning() -> Bool {
        if let lastUpdate = UserDefaults(suiteName: "group.radio.lutheran.shared")?
            .object(forKey: "lastUpdateTime") as? Double {
            return Date().timeIntervalSince1970 - lastUpdate < 60
        }
        return false
    }
}

// MARK: - App Intents

/**
 * WIDGET TOGGLE INTENT (Home Screen)
 * ==================================
 * Now fully aligned with the PlayerVisualState → WidgetState SSOT refactor.
 * Determines the correct action (play/pause) from the shared actor state,
 * calls the proper manager method, and triggers immediate widget refresh.
 */
struct WidgetToggleRadioIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource {
        "Toggle Lutheran Radio"
    }
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
        let isCurrentlyPlaying = sharedDefaults?.bool(forKey: "playing") ?? false
        let shouldPlay = !isCurrentlyPlaying
        let action = shouldPlay ? "play" : "pause"
        let targetVisualState: PlayerVisualState = shouldPlay ? .playing : .userPaused
        
        #if DEBUG
        print("🔗 Widget wants to \(action) → target state: \(targetVisualState) (isCurrentlyPlaying from UserDefaults = \(isCurrentlyPlaying))")
        #endif
        
        // === OPTIMISTIC UPDATE (critical for instant icon flip) ===
        if let sharedDefaults = sharedDefaults {
            sharedDefaults.set(shouldPlay, forKey: "playing")
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
        
        WidgetCenter.shared.reloadTimelines(ofKind: "LutheranRadioWidget")
        
        #if DEBUG
        print("🔗 WidgetToggleRadioIntent completed. Signaled \(action), refreshed widget to \(targetVisualState)")
        #endif
        
        return .result()
    }
}

/**
 * STREAM SWITCHING INTENT
 * ========================
 * Handles language stream switching from Home Screen widgets.
 * Allows users to quickly change between different Lutheran content languages.
 *
 * FEATURES:
 * - Direct language code targeting
 * - Automatic stream discovery
 * - Safe error handling for missing streams
 */
public struct SwitchStreamIntent: AppIntent {
    public init() {}
    public init(streamLanguageCode: String) {
        self.streamLanguageCode = streamLanguageCode
    }

    public nonisolated static var title: LocalizedStringResource {
        "Switch Stream"
    }
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

/**
* WIDGET CONFIGURATION INTENT
* ============================
* Defines configuration options for the Lutheran Radio widget.
* Currently serves as a placeholder for future configuration features.
*
* Future enhancements could include:
* - Default language selection
* - Auto-start preferences
* - Display customization options
*/
public struct RadioWidgetConfiguration: WidgetConfigurationIntent {
    public init() {}

    public nonisolated static var title: LocalizedStringResource {
        "Widget Configuration"
    }

    public nonisolated static var description: IntentDescription {
        IntentDescription("Configuration for Lutheran Radio widget.")
    }
}

// MARK: - UIColor → Color bridge (SwiftUI)
extension UIColor {
    var swiftUIColor: Color { Color(self) }
}
