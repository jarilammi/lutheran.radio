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
import WidgetSurface

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

        // AGENT NOTE: Full path is ``WidgetIntentExecution/performControlWidgetToggle(isPlayingRequested:)``
        // so extension-profile unit tests exercise the same body as this AppIntent.
        await WidgetIntentExecution.performControlWidgetToggle(isPlayingRequested: value)

        #if DEBUG
        print("[LutheranRadioWidgetControl] ToggleRadioIntent completed successfully")
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

        /// Builds a synthetic control-widget snapshot for previews.
        ///
        /// - Parameters:
        ///   - visualState: Preview visual state (typically `.prePlay`).
        ///   - currentStation: Localized station label (flag + language name).
        init(visualState: PlayerVisualState, currentStation: String) {
            self.visualState = visualState
            self.currentStation = currentStation
            self.statusPresentation = visualState.makeStatusPresentation()
            self.controlPresentation = visualState.makeControlPresentation()
        }

        /// Builds a control-widget snapshot from pre-derived presentation slices.
        ///
        /// - Parameters:
        ///   - fields: Authoritative snapshot fields from ``WidgetProviderSnapshotResolver``.
        ///   - slices: Presentation assembly from ``WidgetProviderSnapshotResolver/assemblePresentationSlices(from:)``.
        init(fields: WidgetProviderSnapshotFields, slices: WidgetProviderPresentationSlices) {
            self.visualState = fields.visualState
            self.currentStation = slices.currentStation
            self.statusPresentation = slices.statusPresentation
            self.controlPresentation = slices.controlPresentation
        }

        /// Builds a control-widget snapshot from ``WidgetTimelineEntryFactory`` output.
        init(blueprint: WidgetControlValueBlueprint) {
            self.visualState = blueprint.visualState
            self.currentStation = blueprint.currentStation
            self.statusPresentation = blueprint.statusPresentation
            self.controlPresentation = blueprint.controlPresentation
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
            await resolveControlWidgetValue()
        }

        // MARK: - State resolution (snapshot is the sole SSOT)

        private func resolveControlWidgetValue() async -> Value {
            let manager = SharedPlayerManager.shared
            let fields = await WidgetProviderSnapshotResolver.resolveWithActorHygiene(manager: manager)
            let slices = WidgetProviderSnapshotResolver.assemblePresentationSlices(from: fields)

            // App Group unavailable (extremely rare): actor fallback after hygiene.
            if UserDefaults(suiteName: "group.radio.lutheran.shared") == nil {
                let vs = await manager.currentVisualState
                let fallbackFields = WidgetProviderSnapshotFields(
                    currentLanguage: fields.currentLanguage,
                    hasError: fields.hasError,
                    visualState: vs,
                    streamMetadata: fields.streamMetadata
                )
                let fallbackSlices = WidgetProviderSnapshotResolver.assemblePresentationSlices(from: fallbackFields)
                return Value(blueprint: WidgetTimelineEntryFactory.makeControlWidgetBlueprint(fields: fallbackFields, slices: fallbackSlices))
            }

            // Snapshot present — SSOT path (symmetric with home-widget Provider).
            if SharedPlayerManager.loadPersistedWidgetState() != nil {
                return Value(blueprint: WidgetTimelineEntryFactory.makeControlWidgetBlueprint(fields: fields, slices: slices))
            }

            // No snapshot yet: actor visual + preferred language (installs that never wrote).
            let vs = await manager.currentVisualState
            let fallbackFields = WidgetProviderSnapshotFields(
                currentLanguage: fields.currentLanguage,
                hasError: fields.hasError,
                visualState: vs,
                streamMetadata: fields.streamMetadata
            )
            let fallbackSlices = WidgetProviderSnapshotResolver.assemblePresentationSlices(from: fallbackFields)
            return Value(blueprint: WidgetTimelineEntryFactory.makeControlWidgetBlueprint(fields: fallbackFields, slices: fallbackSlices))
        }
    }
}
