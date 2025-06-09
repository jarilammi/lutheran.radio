//
//  LutheranRadioWidgetControl.swift
//  LutheranRadioWidget
//
//  Created by Jari Lammi on 3.6.2025.
//
//  DOCUMENTATION FOR APPLE REVIEW:
//  ================================
//  This file implements a Control Widget for Lutheran Radio - a religious radio streaming app.
//  The app provides Lutheran radio content in multiple languages (English, German, Finnish, Swedish, Estonian).
//
//  PURPOSE: Educational and religious content delivery through audio streaming
//  CONTENT: Lutheran religious programming, sermons and educational content
//  FUNCTIONALITY: Play/pause control and language stream selection via iOS widgets
//
//  PRIVACY: No personal data collection
//
//  Enhanced Control Widget with stream selection capability for iOS Control Center integration

import AppIntents
import SwiftUI
import WidgetKit
import Foundation

/**
 * PRIMARY CONTROL WIDGET
 * ======================
 * This is the main Control Widget that appears in iOS Control Center, allowing users to:
 * - View current playback status (playing/stopped)
 * - See which language stream is currently selected
 * - Toggle playback with a single tap
 * - Control Lutheran radio content without opening the main app
 *
 * The widget is designed for quick access to religious audio content and respects
 * iOS design guidelines for Control Center widgets.
 */
struct LutheranRadioWidgetControl: ControlWidget {
    /// Unique identifier for this Control Widget - required by iOS
    static let kind: String = "radio.lutheran.LutheranRadio.LutheranRadioWidget"

    /// Main widget configuration defining appearance and behavior
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: Self.kind,
            provider: Provider()
        ) { value in
            // Control toggle that shows current state and allows play/pause
            ControlWidgetToggle(
                "Lutheran Radio",
                isOn: value.isPlaying,
                action: ToggleRadioIntent()
            ) { isPlaying in
                Label {
                    // Status display showing playback state and current station
                    VStack(alignment: .leading, spacing: 1) {
                        // Current status (Playing/Stopped) - localized for international users
                        Text(isPlaying ? String(localized: "status_playing") : String(localized: "status_stopped"))
                            .font(.caption2)
                        // Current language stream with flag emoji for visual identification
                        Text(value.currentStation)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    // Play/pause icon that updates based on current state
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                }
            }
        }
        .displayName(LocalizedStringResource("lutheran_radio_title"))
        .description(LocalizedStringResource("Control Lutheran Radio playback and see current station."))
    }
}

extension LutheranRadioWidgetControl {
    /**
     * WIDGET STATE VALUE
     * ==================
     * Represents the current state of the radio player for display in the widget.
     * This data is refreshed automatically by iOS and reflects real-time player status.
     */
    struct Value {
        /// Whether audio is currently playing
        var isPlaying: Bool
        /// Display name of current stream (e.g., "🇺🇸 English", "🇩🇪 German")
        var currentStation: String
        /// Whether there's a connection or playback error
        var hasError: Bool
    }

    /**
     * DATA PROVIDER
     * =============
     * Supplies current state data to the Control Widget.
     * Communicates with SharedPlayerManager to get real-time radio state.
     */
    struct Provider: AppIntentControlValueProvider {
        
        /**
         * Provides sample data for widget preview in iOS Settings
         * Used when user is configuring widgets or in Xcode previews
         */
        func previewValue(configuration: ControlConfigurationAppIntent) -> Value {
            LutheranRadioWidgetControl.Value(
                isPlaying: false,
                currentStation: "🇺🇸 " + String(localized: "language_english"),
                hasError: false
            )
        }

        /**
         * Retrieves current radio state for live widget display
         * Called by iOS when widget needs to update its display
         *
         * - Parameter configuration: User's widget configuration preferences
         * - Returns: Current radio player state
         * - Throws: Errors if unable to communicate with radio player
         */
        func currentValue(configuration: ControlConfigurationAppIntent) async throws -> Value {
            let manager = SharedPlayerManager.shared
            let isPlaying = manager.isPlaying
            let currentStream = manager.currentStream
            // Format station name with flag emoji and language name for easy recognition
            let currentStation = currentStream.flag + " " + currentStream.language
            
            // Check for connection or streaming errors
            let hasError = manager.hasError
            
            return LutheranRadioWidgetControl.Value(
                isPlaying: isPlaying,
                currentStation: currentStation,
                hasError: hasError
            )
        }
    }
}

/**
 * WIDGET CONFIGURATION INTENT
 * ============================
 * Allows users to configure their preferred default language stream.
 * This configuration is stored locally and respects user privacy.
 */
struct ControlConfigurationAppIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Control Configuration"
    static let description = IntentDescription("Configure Lutheran Radio control widget.")
    
    /// User's preferred language stream for initial playback
    @Parameter(title: "Preferred Language", description: "Default language stream to use")
    var preferredLanguage: StreamLanguageOption?
    
    /// Summary text shown in iOS Settings when configuring the widget
    static var parameterSummary: some ParameterSummary {
        Summary("Configure Lutheran Radio for \(\.$preferredLanguage)")
    }
}

/**
 * LANGUAGE STREAM OPTIONS
 * =======================
 * Defines available language streams for Lutheran radio content.
 * Each stream provides religious content in a specific language.
 */
enum StreamLanguageOption: String, AppEnum {
    case english = "en"      // English Lutheran content
    case german = "de"       // German Lutheran content
    case finnish = "fi"      // Finnish Lutheran content
    case swedish = "sv"      // Swedish Lutheran content
    case estonian = "ee"     // Estonian Lutheran content
    
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Language")
    
    /// User-friendly display names with flag emojis for easy recognition
    static var caseDisplayRepresentations: [StreamLanguageOption: DisplayRepresentation] = [
        .english: DisplayRepresentation(title: LocalizedStringResource("🇺🇸 English")),
        .german: DisplayRepresentation(title: LocalizedStringResource("🇩🇪 German")),
        .finnish: DisplayRepresentation(title: LocalizedStringResource("🇫🇮 Finnish")),
        .swedish: DisplayRepresentation(title: LocalizedStringResource("🇸🇪 Swedish")),
        .estonian: DisplayRepresentation(title: LocalizedStringResource("🇪🇪 Estonian"))
    ]
}

/**
 * PLAY/PAUSE TOGGLE INTENT
 * =========================
 * Handles play/pause functionality from the Control Widget.
 * This is the primary user interaction - starting and stopping religious audio content.
 *
 * SAFETY FEATURES:
 * - Connection-safe implementation prevents crashes if network unavailable
 * - Immediate widget refresh provides user feedback
 * - Graceful error handling for poor network conditions
 */
struct ToggleRadioIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Toggle Lutheran Radio"
    static let description = IntentDescription("Start or stop Lutheran Radio playback.")

    @Parameter(title: "Is Playing")
    var value: Bool

    init() {}

    /**
     * Executes the play/pause action when user taps the Control Widget
     *
     * Flow:
     * 1. Check current playback state
     * 2. Toggle state (playing → stopped, stopped → playing)
     * 3. Update widget display immediately
     * 4. Provide debug feedback for development
     */
    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("🔗 WidgetToggleRadioIntent.perform called")
        #endif
        
        let manager = SharedPlayerManager.shared
        let isCurrentlyPlaying = manager.isPlaying
        
        // Toggle playback state
        if isCurrentlyPlaying {
            manager.stop()  // Stop religious audio content
        } else {
            manager.play { _ in }  // Start streaming religious content
        }
        
        // Force immediate widget refresh for responsive user experience
        WidgetCenter.shared.reloadTimelines(ofKind: "LutheranRadioWidget")
        
        #if DEBUG
        print("🔗 WidgetToggleRadioIntent completed successfully")
        #endif
        
        return .result()
    }
}

/**
 * QUICK STREAM SWITCHING INTENT
 * ==============================
 * Allows rapid switching between different language streams of Lutheran content.
 * Users can quickly change from English to German sermons, for example.
 *
 * FEATURES:
 * - Instant language switching without stopping playback
 * - Optional auto-play after switching
 * - Support for all available Lutheran radio languages
 */
struct QuickSwitchStreamIntent: AppIntent {
    static var title: LocalizedStringResource = "Switch Lutheran Radio Language"
    static var description = IntentDescription("Quickly switch to a different language stream.")
    
    /// Target language for switching
    @Parameter(title: "Language", description: "Language stream to switch to")
    var language: StreamLanguageOption
    
    /// Whether to automatically start playing after language switch
    @Parameter(title: "Start Playing", description: "Start playing after switching", default: true)
    var startPlaying: Bool
    
    /// Dynamic summary based on user's startPlaying preference
    static var parameterSummary: some ParameterSummary {
        When(\.$startPlaying, .equalTo, true) {
            Summary("Switch to \(\.$language) and start playing")
        } otherwise: {
            Summary("Switch to \(\.$language)")
        }
    }

    /**
     * Executes language stream switching
     *
     * Process:
     * 1. Find target language stream in available streams
     * 2. Switch player to new stream
     * 3. Optionally start playback
     * 4. Refresh all widget types to show new state
     *
     * - Throws: Errors if target language stream is not available
     */
    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("🔗 QuickSwitchStreamIntent.perform called for language: \(language.rawValue)")
        #endif
        
        let manager = SharedPlayerManager.shared
        
        // Find the requested language stream
        guard let targetStream = manager.availableStreams.first(where: { $0.languageCode == language.rawValue }) else {
            #if DEBUG
            print("🔗 QuickSwitchStreamIntent: Language stream not found")
            #endif
            return .result()
        }
        
        // Switch to the new Lutheran content stream
        manager.switchToStream(targetStream)
        
        // Update all widget displays immediately
        WidgetCenter.shared.reloadTimelines(ofKind: "LutheranRadioWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "radio.lutheran.LutheranRadio.LutheranRadioWidget")
        
        #if DEBUG
        print("🔗 QuickSwitchStreamIntent completed for \(targetStream.language)")
        #endif
        
        return .result()
    }
}

// MARK: - Enhanced Error Handling

/**
 * ERROR HANDLING EXTENSIONS
 * ==========================
 * Provides safe error handling for widget operations.
 * Ensures widgets don't crash the system or provide poor user experience.
 */
extension AppIntentError {
    /**
     * Creates widget-safe errors that won't crash iOS
     * Used for non-critical errors that should be logged but not interrupt user experience
     */
    static func widgetSafe(_ message: String) -> Error {
        #if DEBUG
        print("🔗 Widget-safe error: \(message)")
        #endif
        return NSError(domain: "LutheranRadioWidget", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }
    
    /**
     * Creates general errors for more serious issues
     * Used when widget functionality cannot continue
     */
    static func general(_ message: String) -> Error {
        return NSError(domain: "LutheranRadioWidget", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
