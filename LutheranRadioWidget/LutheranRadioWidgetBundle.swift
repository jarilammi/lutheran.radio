//
//  LutheranRadioWidgetBundle.swift
//  LutheranRadioWidget
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
        LutheranRadioWidgetLiveActivity()
    }
}
