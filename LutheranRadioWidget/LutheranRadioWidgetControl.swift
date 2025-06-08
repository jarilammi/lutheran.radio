//
//  LutheranRadioWidgetControl.swift
//  LutheranRadioWidget
//
//  Created by Jari Lammi on 3.6.2025.
//
//  Enhanced Control Widget with stream selection capability

import AppIntents
import SwiftUI
import WidgetKit
import Foundation

struct LutheranRadioWidgetControl: ControlWidget {
    static let kind: String = "radio.lutheran.LutheranRadio.LutheranRadioWidget"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: Self.kind,
            provider: Provider()
        ) { value in
            ControlWidgetToggle(
                "Lutheran Radio",
                isOn: value.isPlaying,
                action: ToggleRadioIntent()
            ) { isPlaying in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(isPlaying ? String(localized: "status_playing") : String(localized: "status_stopped"))
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
    struct Value {
        var isPlaying: Bool
        var currentStation: String
        var hasError: Bool
    }

    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: ControlConfigurationAppIntent) -> Value {
            LutheranRadioWidgetControl.Value(
                isPlaying: false,
                currentStation: "🇺🇸 " + String(localized: "language_english"),
                hasError: false
            )
        }

        func currentValue(configuration: ControlConfigurationAppIntent) async throws -> Value {
            let manager = SharedPlayerManager.shared
            let isPlaying = manager.isPlaying
            let currentStream = manager.currentStream
            let currentStation = currentStream.flag + " " + currentStream.language
            
            // Check for errors
            let hasError = manager.hasError
            
            return LutheranRadioWidgetControl.Value(
                isPlaying: isPlaying,
                currentStation: currentStation,
                hasError: hasError
            )
        }
    }
}

// Enhanced control configuration with stream selection options
struct ControlConfigurationAppIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Control Configuration"
    static let description = IntentDescription("Configure Lutheran Radio control widget.")
    
    @Parameter(title: "Preferred Language", description: "Default language stream to use")
    var preferredLanguage: StreamLanguageOption?
    
    static var parameterSummary: some ParameterSummary {
        Summary("Configure Lutheran Radio for \(\.$preferredLanguage)")
    }
}

// Stream language options for configuration
enum StreamLanguageOption: String, AppEnum {
    case english = "en"
    case german = "de"
    case finnish = "fi"
    case swedish = "sv"
    case estonian = "ee"
    
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Language")
    static var caseDisplayRepresentations: [StreamLanguageOption: DisplayRepresentation] = [
        .english: DisplayRepresentation(title: LocalizedStringResource("🇺🇸 English")),
        .german: DisplayRepresentation(title: LocalizedStringResource("🇩🇪 German")),
        .finnish: DisplayRepresentation(title: LocalizedStringResource("🇫🇮 Finnish")),
        .swedish: DisplayRepresentation(title: LocalizedStringResource("🇸🇪 Swedish")),
        .estonian: DisplayRepresentation(title: LocalizedStringResource("🇪🇪 Estonian"))
    ]
}

// Enhanced toggle intent - CONNECTION SAFE
struct ToggleRadioIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Toggle Lutheran Radio"
    static let description = IntentDescription("Start or stop Lutheran Radio playback.")

    @Parameter(title: "Is Playing")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("🔗 ToggleRadioIntent.perform called with value: \(value)")
        #endif
        
        let manager = SharedPlayerManager.shared
        
        if value {
            // Use simple synchronous method call
            manager.play { _ in
                // Empty completion handler - widget doesn't wait for result
            }
        } else {
            // Use simple synchronous method call
            manager.stop()
        }
        
        #if DEBUG
        print("🔗 ToggleRadioIntent completed successfully")
        #endif
        
        return .result()
    }
}

// Quick stream switching intent - CONNECTION SAFE
struct QuickSwitchStreamIntent: AppIntent {
    static var title: LocalizedStringResource = "Switch Lutheran Radio Language"
    static var description = IntentDescription("Quickly switch to a different language stream.")
    
    @Parameter(title: "Language", description: "Language stream to switch to")
    var language: StreamLanguageOption
    
    @Parameter(title: "Start Playing", description: "Start playing after switching", default: true)
    var startPlaying: Bool
    
    static var parameterSummary: some ParameterSummary {
        When(\.$startPlaying, .equalTo, true) {
            Summary("Switch to \(\.$language) and start playing")
        } otherwise: {
            Summary("Switch to \(\.$language)")
        }
    }

    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("🔗 QuickSwitchStreamIntent.perform called for language: \(language.rawValue)")
        #endif
        
        let manager = SharedPlayerManager.shared
        
        guard let targetStream = manager.availableStreams.first(where: { $0.languageCode == language.rawValue }) else {
            #if DEBUG
            print("🔗 QuickSwitchStreamIntent: Language stream not available")
            #endif
            return .result()
        }
        
        // Use simple synchronous call to avoid connection issues
        manager.switchToStream(targetStream)
        
        if startPlaying {
            // Use simple synchronous method call
            manager.play { _ in
                // Empty completion handler - widget doesn't wait for result
            }
        }
        
        #if DEBUG
        print("🔗 QuickSwitchStreamIntent completed")
        #endif
        
        return .result()
    }
}

// MARK: - Configuration Intent - CONNECTION SAFE




// MARK: - Enhanced Error Handling
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
