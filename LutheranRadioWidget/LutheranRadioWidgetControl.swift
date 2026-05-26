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
                LocalizedStringKey("lutheran_radio_title"),
                isOn: value.isPlaying,
                action: ToggleRadioIntent()
            ) { isPlaying in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(value.visualState == .thermalPaused
                            ? String(localized: "status_thermal_paused", defaultValue: "Thermal pause")
                            : (value.visualState == .playing
                                ? String(localized: "status_playing", defaultValue: "Playing")
                                : String(localized: "status_stopped", defaultValue: "Stopped")))
                            .font(.caption2)
                        Text(value.currentStation)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } icon: {
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
    struct Value: Sendable {                    // ← added Sendable for Swift 6
        let visualState: PlayerVisualState      // ← NEW: SSOT
        let currentStation: String
        
        // Backward-compatible properties
        var isPlaying: Bool {
            visualState.isActivelyPlaying
        }
        
        var hasError: Bool {
            visualState == .securityLocked
        }
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
        func previewValue(configuration: NoOpControlConfiguration) -> Value {
            Value(
                visualState: .prePlay,
                currentStation: "🇺🇸 " + String(localized: "language_english")
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
        func currentValue(configuration: NoOpControlConfiguration) async throws -> Value {
            let manager = SharedPlayerManager.shared
            let state = manager.loadSharedState()
            
            // ✅ Safe actor access
            let visualState = await manager.currentVisualState
            
            let currentStream = manager.availableStreams.first(where: { $0.languageCode == state.currentLanguage }) ?? manager.availableStreams[0]
            let currentStation = currentStream.flag + " " + currentStream.language
            
            return Value(
                visualState: visualState,
                currentStation: currentStation
            )
        }
    }
}

/**
 * NO-OP CONTROL CONFIGURATION
 * ============================
 * Minimal type required to satisfy AppIntentControlValueProvider protocol
 * after removal of dead parameterized configuration intent.
 */
struct NoOpControlConfiguration: ControlConfigurationIntent {
    nonisolated static var title: LocalizedStringResource {
        "lutheran_radio_title"
    }
}

/**
 * PLAY/PAUSE TOGGLE INTENT (SSOT-compliant after refactor)
 * =========================================================
 * Handles both play AND pause from widget / Control Center.
 * This was the missing piece after PlayerVisualState → WidgetState refactor.
 */
struct ToggleRadioIntent: SetValueIntent {
    nonisolated static var title: LocalizedStringResource {
        "Toggle Lutheran Radio"
    }
    nonisolated static var description: IntentDescription {
        IntentDescription("Start or stop Lutheran Radio playback.")
    }
    
    @Parameter(title: "Is Playing")
    var value: Bool   // ← true = play, false = pause (this is what ControlWidgetToggle passes)

    init() {}

    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("🔗 ToggleRadioIntent.perform called with desired value: \(value)")
        #endif
        
        let manager = SharedPlayerManager.shared
        
        if value {
            // Play path (already worked)
            print("🔗 Executing widget play action")
            await manager.play()
        } else {
            // ← THIS WAS THE MISSING PIECE
            print("🔗 Executing widget pause action")
            await manager.stop()
        }
        
        // Immediate widget UI feedback — now using modern PlayerVisualState API
        let state = manager.loadSharedState()
        let targetVisualState: PlayerVisualState = value ? .playing : .userPaused
        
        await WidgetRefreshManager.shared.refreshIfNeeded(
            visualState: targetVisualState,
            currentLanguage: state.currentLanguage,
            hasError: state.hasError,
            immediate: true
        )
        
        // Extra safety: force widget timeline refresh
        WidgetCenter.shared.reloadTimelines(ofKind: "LutheranRadioWidget")
        
        #if DEBUG
        print("🔗 ToggleRadioIntent completed successfully")
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
