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
            isPlaying: false,
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
        return createEntry(with: configuration)
    }
    
    /**
     * Creates widget timeline with multiple entries for smooth updates
     * Implements aggressive refresh strategy to catch rapid state changes
     *
     * Strategy:
     * - Immediate entry with current state
     * - Future entry to prevent timeline staleness
     * - 15-second refresh interval for responsive updates
     */
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
    
    /**
     * Creates widget entry with current radio state
     * Implements sophisticated state detection for instant user feedback
     *
     * Priority order for state detection:
     * 1. Instant feedback (for immediate user response)
     * 2. Pending actions (for predicted state changes)
     * 3. Recent cached state (for efficiency)
     * 4. Live player state (fallback)
     */
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
    
    /**
     * Intelligent state detection with instant feedback capabilities
     * Provides immediate visual feedback for user actions before network confirmation
     *
     * Implementation Details:
     * - Instant feedback: 15-second window for immediate user response
     * - Pending actions: 3-second window for predicted state changes
     * - Recent cache: 2-second window for efficiency
     * - Live state: Real-time fallback
     *
     * - Parameter manager: The shared player manager instance
     * - Returns: Tuple of (isPlaying, currentLanguage, hasError)
     */
    private func getPendingOrCurrentState(manager: SharedPlayerManager) -> (isPlaying: Bool, currentLanguage: String, hasError: Bool) {
        guard let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
            let state = manager.loadSharedState()
            return (state.isPlaying, state.currentLanguage, state.hasError)
        }
        
        // PRIORITY 1: Check for instant feedback (highest priority)
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
        
        // PRIORITY 2: Check for pending switch action
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
        
        // PRIORITY 3: Check for recent cache update
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
        
        // PRIORITY 4: Fall back to normal state
        let state = manager.loadSharedState()
        return (state.isPlaying, state.currentLanguage, state.hasError)
    }
}

/**
 * WIDGET TIMELINE ENTRY
 * ======================
 * Data structure representing a single point in the widget's timeline.
 * Contains all information needed to render the widget at a specific time.
 */
struct SimpleEntry: TimelineEntry {
    let date: Date                                          // Timeline timestamp
    let isPlaying: Bool                                     // Current playback state
    let currentStation: String                             // Display name of current stream
    let statusMessage: String                              // User-friendly status text
    let availableStreams: [DirectStreamingPlayer.Stream]   // All available language streams
    let configuration: RadioWidgetConfiguration           // User's widget configuration
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
            // ONBOARDING STATE: Show when app isn't actively running
            VStack(spacing: 8) {
                Image(systemName: "radio")
                    .font(.title2) // Optimized size for small widget
                    .foregroundColor(.secondary)
                
                Text(String(localized: "tap_to_open"))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2) // Allow text wrapping for localization
                    .minimumScaleFactor(0.8) // Scale down if needed for long text
            }
            .padding()
            .widgetURL(URL(string: "lutheranradio://open"))
        } else {
            // ACTIVE STATE: Full functionality when app is running
            VStack(spacing: 4) {
                // Current station with flag emoji for visual recognition
                Text(entry.currentStation)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                // Status indicator (Playing, Stopped, Error)
                Text(entry.statusMessage)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                Spacer()
                
                // Large, accessible play/pause button
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
    
    /**
     * Determines if the main app is actively running
     * Based on recent state updates from the shared manager
     *
     * - Returns: True if app has provided state updates within last 60 seconds
     */
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
            // ONBOARDING STATE: Informative app launch prompt
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
            // ACTIVE STATE: Full medium widget functionality
            HStack(spacing: 12) {
                // LEFT SIDE: Station information
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
                
                // RIGHT SIDE: Control panel
                VStack(spacing: 8) {
                    // Primary play/pause button
                    Button(intent: ToggleRadioIntent()) {
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
                    
                    // Quick language switching (first 2 alternatives)
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
    
    /**
     * Determines if the main app is actively running
     * Identical implementation to SmallWidgetView for consistency
     */
    private func isAppRunning() -> Bool {
        if let lastUpdate = UserDefaults(suiteName: "group.radio.lutheran.shared")?
            .object(forKey: "lastUpdateTime") as? Double {
            return Date().timeIntervalSince1970 - lastUpdate < 60
        }
        return false
    }
    
    /**
     * Extracts language code from formatted station name
     * Used to determine which alternative streams to show
     *
     * - Parameter stationName: Formatted station name (e.g., "🇺🇸 English")
     * - Returns: Language code (e.g., "en") or "en" as fallback
     */
    private func getCurrentStreamCode(from stationName: String) -> String {
        for stream in entry.availableStreams {
            if stationName.contains(stream.language) {
                return stream.languageCode
            }
        }
        return "en" // Default fallback to English
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
            // ONBOARDING STATE: Comprehensive app launch guidance
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
            // ACTIVE STATE: Complete large widget interface
            VStack(spacing: 12) {
                // HEADER: Title and main control
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
                
                // CURRENT STATION: Prominent display of active stream
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
                
                // LANGUAGE GRID: All available Lutheran radio streams
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
    
    /**
     * Determines if the main app is actively running
     * Consistent with other widget sizes for uniform behavior
     */
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
 * WIDGET-SPECIFIC TOGGLE INTENT
 * ==============================
 * Handles play/pause functionality specifically from Home Screen widgets.
 * Identical to Control Widget toggle but optimized for Home Screen interaction.
 *
 * SAFETY FEATURES:
 * - Connection-safe implementation
 * - Graceful error handling
 * - Immediate user feedback
 */
struct WidgetToggleRadioIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Lutheran Radio"
    static var description = IntentDescription("Play or pause Lutheran Radio.")

    /**
     * Executes play/pause toggle from Home Screen widget
     * Provides immediate feedback to user through debug logging
     */
    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("🔗 WidgetToggleRadioIntent.perform called")
        #endif
        
        let manager = SharedPlayerManager.shared
        let isCurrentlyPlaying = manager.isPlaying
        
        // Toggle between playing and stopped states
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
struct SwitchStreamIntent: AppIntent {
    static var title: LocalizedStringResource = "Switch Stream"
    static var description = IntentDescription("Switch to a different language stream.")
    
    /// Target language code for the switch
    @Parameter(title: "Language Code")
    var streamLanguageCode: String
    
    init() {}
    
    init(streamLanguageCode: String) {
        self.streamLanguageCode = streamLanguageCode
    }

    /**
     * Executes language stream change
     *
     * Process:
     * 1. Validate target language exists in available streams
     * 2. Execute stream switch through player manager
     * 3. Provide debug feedback for development
     *
     * - Throws: No errors thrown - gracefully handles missing streams
     */
    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("🔗 SwitchStreamIntent.perform called for language: \(streamLanguageCode)")
        #endif
        
        let manager = SharedPlayerManager.shared
        
        // Find target stream in available options
        guard let targetStream = manager.availableStreams.first(where: { $0.languageCode == streamLanguageCode }) else {
            #if DEBUG
            print("🔗 SwitchStreamIntent: Language stream not found")
            #endif
            return .result()
        }
        
        // Execute the stream switch
        manager.switchToStream(targetStream)
        
        #if DEBUG
        print("🔗 SwitchStreamIntent completed for \(targetStream.language)")
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
struct RadioWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Widget Configuration"
    static var description = IntentDescription("Configuration for Lutheran Radio widget.")
}
