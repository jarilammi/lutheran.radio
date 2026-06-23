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
        print("[LutheranRadioWidgetControl] Widget-safe error: \(message)")
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
    var value: Bool  // ← true = play, false = pause (this is what ControlWidgetToggle passes)
    
    init() {}
    
    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[LutheranRadioWidgetControl] ToggleRadioIntent.perform called with desired value: \(value)")
        #endif

        Task { @MainActor in WidgetRefreshManager.setHasActiveLutheranWidgets(true) }

        let manager = SharedPlayerManager.shared
        
        // Widget extension cannot own AVPlayer. We only signal intent via shared defaults + Darwin notification.
        // The main app (receiving the Darwin notification via checkForPendingWidgetActions) is the sole executor
        // of actual playback changes. This matches the design used by WidgetToggleRadioIntent (home widget).
        // Direct play()/stop() calls here caused double-execution (widget optimistic path + main app heavy path),
        // producing tuning-sound waits, full stream re-setup, intermediate playing=false saves, and state thrashing.
        
        // Brave: also force-persist the full visual state JSON from the widget process.
        // This makes the next Control Widget timeline / currentValue read the correct icon immediately.
        // (The inner persist / schedule paths are gated by hasActiveWidgets; when the Control widget
        // itself is present the flag is true. After a main-app privacy clear the snapshot will be absent
        // until re-detect, and providers fall back gracefully.)
        let targetVisualState: PlayerVisualState = value ? .playing : .userPaused
        let action = value ? "play" : "pause"

        // Use persisted language for consistency (same as home widget fix).
        let persisted = SharedPlayerManager.loadPersistedWidgetState()
        let langForOptimistic = persisted?.currentLanguage ?? SharedPlayerManager.preferredWidgetLanguage()

        // Same optimistic path as WidgetToggleRadioIntent: snapshot + pendingAction + Darwin notify.
        manager.signalWidgetPendingAction(visualState: targetVisualState, action: action, language: langForOptimistic)
        
        // Immediate widget UI feedback — now using modern PlayerVisualState API
        let state = manager.loadSharedState()
        
        await WidgetRefreshManager.shared.refreshIfNeeded(
            visualState: targetVisualState,
            currentLanguage: langForOptimistic,
            hasError: state.hasError,
            immediate: true
        )
        
        #if DEBUG
        print("[LutheranRadioWidgetControl] ToggleRadioIntent completed successfully (signaled \(value ? "play" : "pause") via pendingAction + Darwin)")
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
                        // Consume PlayerStatusPresentation (via makeStatusPresentation) so the
                        // control widget uses the same text mapping as the home widget / main app.
                        // This eliminates the local thermal/playing/stopped ternary duplication.
                        Text(value.visualState.makeStatusPresentation().text)
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
                currentStation: "🇺🇸 " + String(localized: "language_english", table: "Localizable")
            )
        }
        
        func currentValue(configuration: NoOpControlConfiguration) async throws -> Value {
            let (visualState, currentStation) = await effectiveVisualStateAndStation()
            return Value(visualState: visualState, currentStation: currentStation)
        }
        
        // MARK: - State resolution (snapshot is the sole SSOT)
        
        private func effectiveVisualStateAndStation() async -> (visualState: PlayerVisualState, currentStation: String) {
            let manager = SharedPlayerManager.shared
            
            // Always refresh from persistence first (fresh actor).
            await manager.refreshVisualStateFromPersistence()
            
            // App Group unavailable (extremely rare). Fall back to in-memory state + preferred language helper.
            if UserDefaults(suiteName: "group.radio.lutheran.shared") == nil {
                let vs = await manager.currentVisualState
                let lang = SharedPlayerManager.preferredWidgetLanguage()
                let stream = SharedPlayerManager.streamForLanguageCode(lang)
                return (vs, stream.flag + " " + stream.language)
            }
            
            // The unified snapshot is the single source of truth.
            if let combined = SharedPlayerManager.loadPersistedWidgetState() {
                let stream = SharedPlayerManager.streamForLanguageCode(combined.currentLanguage)
                return (combined.visualState, stream.flag + " " + stream.language)
            }
            
            // Ultimate fallback for installs that never wrote a combined snapshot.
            let vs = await manager.currentVisualState
            let lang = SharedPlayerManager.preferredWidgetLanguage()
            let stream = SharedPlayerManager.streamForLanguageCode(lang)
            let station = stream.flag + " " + stream.language
            return (vs, station)
        }
    }
}
