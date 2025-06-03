//
//  LutheranRadioWidgetControl.swift
//  LutheranRadioWidget
//
//  Created by Jari Lammi on 3.6.2025.
//

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
                Label(
                    isPlaying ? "Playing" : "Stopped",
                    systemImage: isPlaying ? "pause.fill" : "play.fill"
                )
            }
        }
        .displayName("Lutheran Radio")
        .description("Control Lutheran Radio playback.")
    }
}

extension LutheranRadioWidgetControl {
    struct Value {
        var isPlaying: Bool
        var currentStation: String
    }

    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: ControlConfigurationAppIntent) -> Value {
            LutheranRadioWidgetControl.Value(
                isPlaying: false,
                currentStation: "🇺🇸 English"
            )
        }

        func currentValue(configuration: ControlConfigurationAppIntent) async throws -> Value {
            // Check current playback state from your player
            let isPlaying = DirectStreamingPlayer.shared.player?.rate ?? 0 > 0
            let currentStation = DirectStreamingPlayer.shared.selectedStream.flag + " " + DirectStreamingPlayer.shared.selectedStream.language
            
            return LutheranRadioWidgetControl.Value(
                isPlaying: isPlaying,
                currentStation: currentStation
            )
        }
    }
}

struct ControlConfigurationAppIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Control Configuration"
}

struct ToggleRadioIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Toggle Lutheran Radio"

    @Parameter(title: "Is Playing")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        let player = DirectStreamingPlayer.shared
        
        if value {
            // Start playing
            player.play { success in
                print("Widget play result: \(success)")
            }
        } else {
            // Stop playing
            player.stop()
        }
        
        return .result()
    }
}
