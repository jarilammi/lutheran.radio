//
//  WidgetSurface.swift
//  WidgetSurface
//
//  Created by Jari Lammi on 14.7.2026.
//
//  Embedded framework for cross-process widget and Live Activity presentation types.
//  Presentation-only — no security logic (see Core/). Linked by the main app (embed),
//  LutheranRadioWidgetExtension (link only), LutheranRadioWidgetTests, and WidgetSurfaceTests.
//
//  Includes pure language chrome (``displayFlag(for:)``,
//  ``displayLanguageName(for:preferredStreamLanguage:)``) and pure Provider slice assembly
//  (``WidgetProviderPresentationAssembly``). Snapshot hygiene, stream-catalog station labels,
//  and intent *execution* remain membership-exception sources under `Lutheran Radio/`
//  (`SharedPlayerManager`, `WidgetDisplayModels`, `WidgetRefreshManager`) because they
//  call into ``SharedPlayerManager`` — see CODING_AGENT.md cross-target section.
//
//  - SeeAlso: docs/Widget-Presentation-Dataflow.md, docs/Widget-Functionality-Roadmap.md,
//    CODING_AGENT.md (Cross-target widget sources and WidgetSurface), README.md SSOT.
//

import Foundation
