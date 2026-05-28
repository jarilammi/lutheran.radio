//
//  LutheranRadioWidgetControl.swift
//  LutheranRadioWidget
//
//  Created by Jari Lammi on 3.6.2025.
//

import AppIntents
import SwiftUI
import WidgetKit
import Foundation

// MARK: - Error Helpers

extension AppIntentError {
    static func widgetSafe(_ message: String) -> Error {
        #if DEBUG
        print("🔗 Widget-safe error: \(message)")
        #endif
        return NSError(domain: "LutheranRadioWidget", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func general(_ message: String) -> Error {
        return NSError(domain: "LutheranRadioWidget", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

struct NoOpControlConfiguration: ControlConfigurationIntent {
    nonisolated static var title: LocalizedStringResource {
        "lutheran_radio_title"
    }
}

struct ToggleRadioIntent: SetValueIntent {
    nonisolated static var title: LocalizedStringResource { "Toggle Lutheran Radio" }
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

struct LutheranRadioWidgetControl: ControlWidget {
    static let kind: String = "radio.lutheran.LutheranRadio.LutheranRadioWidget"

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
    struct Value: Sendable {
        let visualState: PlayerVisualState
        let currentStation: String

        var isPlaying: Bool {
            visualState.isActivelyPlaying
        }

        var hasError: Bool {
            visualState == .securityLocked
        }
    }

    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: NoOpControlConfiguration) -> Value {
            Value(
                visualState: .prePlay,
                currentStation: "🇺🇸 " + String(localized: "language_english")
            )
        }

        func currentValue(configuration: NoOpControlConfiguration) async throws -> Value {
            let (visualState, currentStation) = await effectiveVisualStateAndStation()
            return Value(visualState: visualState, currentStation: currentStation)
        }

        // MARK: - State resolution (uses the same three-layer hardening as the Home Screen widget)

        private func effectiveVisualStateAndStation() async -> (visualState: PlayerVisualState, currentStation: String) {
            let manager = SharedPlayerManager.shared

            // Layer 1: Always refresh from persistence first (fresh actor).
            await manager.refreshVisualStateFromPersistence()
            
            guard let sharedDefaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else {
                let state = manager.loadSharedState()
                let vs = await manager.currentVisualState
                let stream = manager.availableStreams.first(where: { $0.languageCode == state.currentLanguage }) ?? manager.availableStreams[0]
                return (vs, stream.flag + " " + stream.language)
            }
            
            // Layer 2: Short-lived pendingAction / instantFeedback (same pattern as Home Screen widget).
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

            // Layer 3: Final fallback — direct JSON decode (bypasses actor memory).
            let state = manager.loadSharedState()
            let vs = SharedPlayerManager.loadPersistedVisualStateDirect()
            let stream = manager.availableStreams.first(where: { $0.languageCode == state.currentLanguage }) ?? manager.availableStreams[0]
            let station = stream.flag + " " + stream.language
            return (vs, station)
        }
    }
}
