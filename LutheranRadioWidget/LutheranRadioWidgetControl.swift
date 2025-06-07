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

struct LutheranRadioWidgetControl: ControlWidget {
    static let kind: String = "radio.lutheran.Lutheran-Radio.LutheranRadioWidget"

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
            let player = DirectStreamingPlayer.shared
            let isPlaying = player.player?.rate ?? 0 > 0
            let currentStream = player.selectedStream
            let currentStation = currentStream.flag + " " + currentStream.language
            
            // Check for errors
            let hasError = player.hasPermanentError || player.isLastErrorPermanent()
            
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

// Enhanced toggle intent with better error handling
struct ToggleRadioIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Toggle Lutheran Radio"
    static let description = IntentDescription("Start or stop Lutheran Radio playback.")

    @Parameter(title: "Is Playing")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        let player = DirectStreamingPlayer.shared
        
        if value {
            // Start playing - use async/await pattern for better reliability
            let success = await withCheckedContinuation { continuation in
                player.play { success in
                    continuation.resume(returning: success)
                }
            }
            
            if !success {
                // Provide feedback about the failure
                if player.isLastErrorPermanent() {
                    throw AppIntentError.general("Service temporarily unavailable")
                } else {
                    throw AppIntentError.general("Connection error - please try again")
                }
            }
        } else {
            // Stop playing
            await withCheckedContinuation { continuation in
                player.stop {
                    continuation.resume()
                }
            }
        }
        
        return .result()
    }
}

// Quick stream switching intent for Shortcuts
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
        let player = DirectStreamingPlayer.shared
        
        guard let targetStream = DirectStreamingPlayer.availableStreams.first(where: { $0.languageCode == language.rawValue }) else {
            throw AppIntentError.general("Language stream not available")
        }
        
        // Switch stream
        player.setStream(to: targetStream)
        
        // Start playing if requested
        if startPlaying {
            let success = await withCheckedContinuation { continuation in
                player.play { success in
                    continuation.resume(returning: success)
                }
            }
            
            if !success {
                throw AppIntentError.general("Failed to start playback")
            }
        }
        
        return .result(value: "Switched to \(targetStream.language)")
    }
}

// Enhanced error handling
extension AppIntentError {
    static func general(_ message: String) -> Error {
        return NSError(domain: "LutheranRadioWidget", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
