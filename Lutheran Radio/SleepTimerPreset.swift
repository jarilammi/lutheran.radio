//
//  SleepTimerPreset.swift
//  Lutheran Radio
//
//  Minute lengths shared by the in-app sleep-timer confirmation dialog and
//  ``SetSleepTimerIntent``. One list so Shortcuts cannot offer a duration the
//  moon menu does not, or the reverse.
//
//  Display strings reuse the existing `sleep_timer_preset_*_min` catalog keys
//  (already translated for every UI language). The `defaultValue` on each
//  ``LocalizedStringResource`` is the English catalog value. Do not change
//  that default to the key name — string extraction would overwrite "15 minutes".
//
//  - SeeAlso: ``SleepTimerPresetAppEnum``, ``SleepTimerMenuButton``,
//    ``SharedPlayerManager/setSleepTimer(duration:)``,
//    CODING_AGENT.md (Single Source of Truth Principles).
//
//  Created by Jari Lammi on 10.11.2026.
//

import Foundation

/// Minute lengths the sleep-timer menu and ``SetSleepTimerIntent`` both offer.
///
/// AGENT NOTE: Single source of truth for the four presets. ``SleepTimerMenuButton``
/// lists ``allCases``. ``SleepTimerPresetAppEnum`` maps one case per preset.
/// Do not hard-code 15, 30, 45, or 60 beside this type.
///
/// - SeeAlso: ``SleepTimerPresetAppEnum``, ``SleepTimerMenuButton``,
///   ``SharedPlayerManager/setSleepTimer(duration:)``,
///   CODING_AGENT.md (Single Source of Truth Principles).
enum SleepTimerPreset: Int, CaseIterable, Sendable, Hashable {
    case fifteen = 15
    case thirty = 30
    case fortyFive = 45
    case sixty = 60

    /// Menu order. Declaration order of ``allCases`` (15, 30, 45, 60).
    static var pickerMinutes: [Int] {
        allCases.map(\.rawValue)
    }

    /// Armed length passed to ``SharedPlayerManager/setSleepTimer(duration:)``.
    var duration: TimeInterval {
        TimeInterval(rawValue * 60)
    }

    /// Localized menu title. The Shortcuts picker repeats these catalog keys.
    ///
    /// App Enum metadata extraction cannot follow a property, so
    /// ``SleepTimerPresetAppEnum/caseDisplayRepresentations`` writes the same
    /// initializer again. The intent tests assert the two resources stay equal.
    ///
    /// - Important: `defaultValue` must stay the English catalog value for that key.
    var menuTitleResource: LocalizedStringResource {
        switch self {
        case .fifteen:
            LocalizedStringResource(
                "sleep_timer_preset_15_min",
                defaultValue: "15 minutes",
                table: "Localizable"
            )
        case .thirty:
            LocalizedStringResource(
                "sleep_timer_preset_30_min",
                defaultValue: "30 minutes",
                table: "Localizable"
            )
        case .fortyFive:
            LocalizedStringResource(
                "sleep_timer_preset_45_min",
                defaultValue: "45 minutes",
                table: "Localizable"
            )
        case .sixty:
            LocalizedStringResource(
                "sleep_timer_preset_60_min",
                defaultValue: "60 minutes",
                table: "Localizable"
            )
        }
    }

    /// Resolved title for a `Button` label. Looks up ``menuTitleResource``.
    var menuTitle: String {
        String(localized: menuTitleResource)
    }
}
