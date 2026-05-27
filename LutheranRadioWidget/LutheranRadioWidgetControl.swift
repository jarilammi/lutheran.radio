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
            let (visualState, currentStation) = await effectiveVisualStateAndStation()
            return Value(visualState: visualState, currentStation: currentStation)
        }
        
        // MARK: - Best visual state (exact same pendingAction → instantFeedback → synced logic as home widget Provider)
        
        private func effectiveVisualStateAndStation() async -> (visualState: PlayerVisualState, currentStation: String) {
            let manager = SharedPlayerManager.shared
            
            // CRITICAL: Widget/Control Center extension runs in its own process.
            // The actor's currentVisualState starts at .prePlay every time.
            // We must load the persisted PlayerVisualState (or legacy fallback) before trusting it.
            // Use the robust fresh-load path so we always see the latest value written by
            // forcePersistVisualState (from this process) or the main app (via saveVisualState).
            await manager.refreshVisualStateFromPersistence()
            
            guard let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
                let state = manager.loadSharedState()
                let vs = await manager.currentVisualState
                let stream = manager.availableStreams.first(where: { $0.languageCode == state.currentLanguage }) ?? manager.availableStreams[0]
                return (vs, stream.flag + " " + stream.language)
            }
            
            // === CRITICAL: Handle pending play/pause actions for instant widget feedback ===
            // (Identical 12-second window and mapping used by the home-screen widget Provider.)
            if let pendingAction = sharedDefaults.string(forKey: "pendingAction"),
               let pendingTime = sharedDefaults.object(forKey: "pendingActionTime") as? Double {
                
                let actionAge = Date().timeIntervalSince1970 - pendingTime
                if actionAge < 12.0 {
                    let state = manager.loadSharedState()
                    let vs = await manager.currentVisualState
                    
                    let effective: PlayerVisualState = {
                        switch pendingAction {
                        case "play":  return .playing
                        case "pause": return .userPaused
                        case "switch": return vs
                        default:      return vs
                        }
                    }()
                    
                    #if DEBUG
                    print("🔗 [CONTROL PROVIDER] pendingAction=\(pendingAction) → forcing visualState=\(effective)")
                    #endif
                    
                    let stream = manager.availableStreams.first(where: { $0.languageCode == state.currentLanguage }) ?? manager.availableStreams[0]
                    let station = stream.flag + " " + stream.language
                    return (effective, station)
                }
            }
            
            // instant feedback for language switch (visual from actor, station reflects the instant language)
            if let instantFeedbackTime = sharedDefaults.object(forKey: "instantFeedbackTime") as? Double,
               let instantFeedbackLanguage = sharedDefaults.string(forKey: "instantFeedbackLanguage"),
               sharedDefaults.bool(forKey: "isInstantFeedback") == true {
                
                let age = Date().timeIntervalSince1970 - instantFeedbackTime
                if age < 15.0 {
                    _ = manager.loadSharedState()
                    let vs = await manager.currentVisualState
                    let lang = instantFeedbackLanguage
                    let stream = manager.availableStreams.first(where: { $0.languageCode == lang }) ?? manager.availableStreams[0]
                    let station = stream.flag + " " + stream.language
                    return (vs, station)
                }
            }
            
            // Normal authoritative path.
            // ROBUST HARDENING for the play/pause button visual (the ControlWidgetToggle isOn + icon):
            // When no pendingAction is active, decode the "playerVisualState" JSON *directly*.
            // This bypasses any reliance on the actor's in-memory currentVisualState (which may have
            // been loaded before the intent's forcePersistVisualState write became visible).
            // Combined with refreshVisualStateFromPersistence() above and the 12s pendingAction window,
            // this guarantees the widget toggle shows the correct play/pause icon even on the very
            // first interaction in a fresh widget process.
            let state = manager.loadSharedState()
            let vs = SharedPlayerManager.loadPersistedVisualStateDirect()
            let stream = manager.availableStreams.first(where: { $0.languageCode == state.currentLanguage }) ?? manager.availableStreams[0]
            let station = stream.flag + " " + stream.language
            return (vs, station)
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
        
        // Widget extension cannot own AVPlayer. We only signal intent via shared defaults + Darwin notification.
        // The main app (receiving the Darwin notification via checkForPendingWidgetActions) is the sole executor
        // of actual playback changes. This matches the design used by WidgetToggleRadioIntent (home widget).
        // Direct play()/stop() calls here caused double-execution (widget optimistic path + main app heavy path),
        // producing tuning-sound waits, full stream re-setup, intermediate playing=false saves, and state thrashing.
        
        // Brave: also force-persist the full visual state JSON from the widget process.
        // This makes the next Control Widget timeline / currentValue read the correct icon immediately.
        let targetVisualState: PlayerVisualState = value ? .playing : .userPaused
        manager.forcePersistVisualState(targetVisualState)
        
        // Write the exact same pendingAction signals the home widget uses.
        // The Control Provider's currentValue (above) now consults pendingAction + instantFeedback,
        // so the very next toggle visual resolution (isOn / green-pause icon) flips instantly and correctly.
        if let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared") {
            let action = value ? "play" : "pause"
            let actionId = UUID().uuidString
            let now = Date().timeIntervalSince1970
            sharedDefaults.set(action, forKey: "pendingAction")
            sharedDefaults.set(actionId, forKey: "pendingActionId")
            sharedDefaults.set(now, forKey: "pendingActionTime")
            sharedDefaults.synchronize()
        }
        
        // Wake the main app so it executes the action (exactly like the home widget intent).
        // Without this the Darwin round-trip never starts for pure Control Widget taps.
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("radio.lutheran.widget.action" as CFString),
            nil, nil, true
        )
        
        // Immediate widget UI feedback — now using modern PlayerVisualState API
        let state = manager.loadSharedState()
        
        await WidgetRefreshManager.shared.refreshIfNeeded(
            visualState: targetVisualState,
            currentLanguage: state.currentLanguage,
            hasError: state.hasError,
            immediate: true
        )
        
        #if DEBUG
        print("🔗 ToggleRadioIntent completed successfully (signaled \(value ? "play" : "pause") via pendingAction + Darwin)")
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
