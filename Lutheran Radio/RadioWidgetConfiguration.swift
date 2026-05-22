//
//  RadioWidgetConfiguration.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 22.5.2026.
//

import WidgetKit
import AppIntents

/**
 * WIDGET CONFIGURATION INTENT (Main App Copy)
 * ===========================================
 * Tiny duplicate required so the main app process can instantiate
 * the intent during WidgetCenter refreshes / background updates.
 *
 * This file is ONLY in the "Lutheran Radio" target.
 * The original stays untouched in the widget extension.
 */
public struct RadioWidgetConfiguration: WidgetConfigurationIntent {
    public init() {}

    public nonisolated static var title: LocalizedStringResource {
        "Widget Configuration"
    }

    public nonisolated static var description: IntentDescription {
        IntentDescription("Configuration for Lutheran Radio widget.")
    }
}
