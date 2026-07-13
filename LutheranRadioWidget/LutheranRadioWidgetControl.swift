//
//  LutheranRadioWidgetControl.swift
//  LutheranRadioWidget
//
//  Created by Jari Lammi on 3.6.2025.
//
//  Control Center toggle widget. Snapshot-driven presentation matches home widgets:
//  `Provider` pre-derives `PlayerStatusPresentation` and `PlayerControlPresentation`
//  onto `Value` once per `currentValue` / `previewValue` read; the toggle label closure
//  consumes only those narrow fields (no inline `makeStatusPresentation()` /
//  `makeControlPresentation()` in the view body).
//
//  - SeeAlso: `SimpleEntry` (WidgetKit parallel), `LutheranRadioWidget.swift` (Provider),
//    docs/Widget-Presentation-Dataflow.md, docs/Widget-Functionality-Roadmap.md (Tier 1),
//    CODING_AGENT.md (narrow inputs, cross-target shared sources).

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
                        // Pre-derived in Provider (parallel to SimpleEntry.statusPresentation).
                        Text(value.statusPresentation.text)
                            .font(.caption2)
                        Text(value.currentStation)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    // Pre-derived in Provider (parallel to SimpleEntry.controlPresentation).
                    // `value.isPlaying` remains semantic-only for the ControlWidgetToggle contract.
                    Image(systemName: value.controlPresentation.systemImage)
                        .foregroundStyle(value.controlPresentation.tint)
                }
            }
        }
        .displayName(LocalizedStringResource("lutheran_radio_title"))
        .description(LocalizedStringResource("Control Lutheran Radio playback and see current station."))
    }
}

extension LutheranRadioWidgetControl {
    /// Snapshot value for the Control Widget.
    ///
    /// Carries the authoritative `visualState` (from persisted snapshot) plus the two
    /// narrow presentation surfaces pre-derived once in `Provider` — the Control Center
    /// parallel to `SimpleEntry.statusPresentation` / `SimpleEntry.controlPresentation`.
    ///
    /// `isPlaying` is intentionally kept as a semantic Bool for the `SetValueIntent`
    /// / toggle contract. Presentation glyph and status text read only the narrow fields.
    ///
    /// - SeeAlso: `SimpleEntry`, ``PlayerVisualState/makeStatusPresentation()``,
    ///   ``PlayerVisualState/makeControlPresentation()``, docs/Widget-Presentation-Dataflow.md.
    struct Value: Sendable {
        let visualState: PlayerVisualState
        let currentStation: String
        let statusPresentation: PlayerStatusPresentation
        let controlPresentation: PlayerControlPresentation

        var isPlaying: Bool {
            visualState.isActivelyPlaying
        }

        var hasError: Bool {
            visualState == .securityLocked
        }

        /// Builds a control-widget snapshot with narrow presentations derived once from `visualState`.
        ///
        /// - Parameters:
        ///   - visualState: Authoritative policy state from the persisted snapshot.
        ///   - currentStation: Localized station label (flag + language name).
        init(visualState: PlayerVisualState, currentStation: String) {
            self.visualState = visualState
            self.currentStation = currentStation
            self.statusPresentation = visualState.makeStatusPresentation()
            self.controlPresentation = visualState.makeControlPresentation()
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
