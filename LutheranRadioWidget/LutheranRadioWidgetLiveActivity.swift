//
//  LutheranRadioWidgetLiveActivity.swift
//  LutheranRadioWidget
//
//  Created by Jari Lammi on 3.6.2025.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct LutheranRadioWidgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct LutheranRadioWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LutheranRadioWidgetAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension LutheranRadioWidgetAttributes {
    fileprivate static var preview: LutheranRadioWidgetAttributes {
        LutheranRadioWidgetAttributes(name: "World")
    }
}

extension LutheranRadioWidgetAttributes.ContentState {
    fileprivate static var smiley: LutheranRadioWidgetAttributes.ContentState {
        LutheranRadioWidgetAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: LutheranRadioWidgetAttributes.ContentState {
         LutheranRadioWidgetAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: LutheranRadioWidgetAttributes.preview) {
   LutheranRadioWidgetLiveActivity()
} contentStates: {
    LutheranRadioWidgetAttributes.ContentState.smiley
    LutheranRadioWidgetAttributes.ContentState.starEyes
}
