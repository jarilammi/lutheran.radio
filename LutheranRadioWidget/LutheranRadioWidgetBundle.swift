//
//  LutheranRadioWidgetBundle.swift
//  LutheranRadioWidget
//
//  WidgetKit gallery **section** name is the extension CFBundleDisplayName
//  (`LutheranRadioWidget/InfoPlist.xcstrings`), kept in lockstep with
//  `"lutheran_radio_title"`. Per-widget titles stay on Localizable
//  (`.configurationDisplayName` / Control `.displayName`). The OS does not
//  read CFBundleDisplayName from Localizable.
//
//  - SeeAlso: `LutheranRadioWidget.swift`, docs/Widget-Presentation-Dataflow.md,
//    CODING_AGENT.md (Localization — InfoPlist.xcstrings exception).
//
//  Created by Jari Lammi on 3.6.2025.
//

import WidgetKit
import SwiftUI

@main
struct LutheranRadioWidgetBundle: WidgetBundle {
    var body: some Widget {
        LutheranRadioWidget()
        LutheranRadioWidgetControl()
        LutheranRadioLiveActivityWidget()
    }
}
