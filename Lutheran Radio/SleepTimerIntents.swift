//
//  SleepTimerIntents.swift
//  Lutheran Radio
//
//  Siri, Shortcuts, Spotlight, and Action Button entry points for the sleep
//  timer. They call ``SharedPlayerManager/setSleepTimer(duration:)`` and
//  ``cancelSleepTimer()`` — the same actor methods the in-app moon menu uses.
//  No second countdown.
//
//  Runs in the background. ``supportedModes`` is ``.background`` and
//  ``openAppWhenRun`` stays false, matching the other playback intents that
//  must not foreground the UI. `perform()` is not `@MainActor`; it awaits
//  ``SharedPlayerManager`` like ``PlayRadioIntent``.
//
//  Phrases are registered on ``LutheranRadioShortcuts`` (one App Shortcuts
//  provider per app). Spoken forms for German, Finnish, Swedish, and Estonian
//  live in `AppShortcuts.xcstrings`. Siri may not speak Estonian yet; those
//  phrases are there for when it does. Shortcuts runs the intents either way.
//
//  Titles, the duration name, the type name, and dialogs reuse existing
//  `Localizable` keys (`sleep_timer_sheet_title`, `sleep_timer_cancel_timer`,
//  and the preset `sleep_timer_preset_*_min` keys). A string literal passed to
//  `LocalizedStringResource`, `IntentDialog`, `IntentDescription`, or `Summary`
//  would be a new catalog key and a translation for every UI language. There
//  is no intent description, parameter summary, or disambiguation dialog.
//
//  - SeeAlso: ``SleepTimerPreset``, ``SleepTimerPresetAppEnum``,
//    ``LutheranRadioShortcuts``, ``SharedPlayerManager/setSleepTimer(duration:)``,
//    ``SharedPlayerManager/cancelSleepTimer(restorePlaybackIntent:notifyStateChange:)``,
//    ``SleepTimerNotification``, CODING_AGENT.md (Localization).
//
//  Created by Jari Lammi on 10.11.2026.
//

import AppIntents
import Foundation

// MARK: - Preset parameter

/// Shortcuts value for one ``SleepTimerPreset``.
///
/// Raw values are the minute counts as strings (`"15"`, `"30"`, `"45"`, `"60"`).
/// Saved shortcuts persist that string. Do not renumber or reuse a raw value.
///
/// Display names are the in-app preset catalog keys (`"15 minutes"` and its
/// translations), not a second set of strings.
///
/// - SeeAlso: ``SleepTimerPreset``, ``SetSleepTimerIntent``,
///   CODING_AGENT.md (Localization).
enum SleepTimerPresetAppEnum: String, AppEnum, CaseIterable, Sendable {
    case fifteenMinutes = "15"
    case thirtyMinutes = "30"
    case fortyFiveMinutes = "45"
    case sixtyMinutes = "60"

    /// The in-app preset this case arms. One-to-one with ``SleepTimerPreset/allCases``.
    var preset: SleepTimerPreset {
        switch self {
        case .fifteenMinutes: .fifteen
        case .thirtyMinutes: .thirty
        case .fortyFiveMinutes: .fortyFive
        case .sixtyMinutes: .sixty
        }
    }

    /// Whole minutes. Comes from ``SleepTimerPreset/rawValue``, not a second literal.
    var minutes: Int { preset.rawValue }

    /// Same catalog key as the in-app sheet title. A literal `"Duration"` would
    /// be a new `Localizable` key. The metadata extractor only accepts this
    /// initializer or a string literal here, so the call is inlined.
    nonisolated static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: LocalizedStringResource(
                "sleep_timer_sheet_title",
                defaultValue: "Sleep timer",
                table: "Localizable"
            )
        )
    }

    /// Every case needs an entry. A missing one traps when Shortcuts draws the picker.
    ///
    /// The metadata extractor only accepts a `LocalizedStringResource` initializer
    /// or a string literal here. A property indirection (`menuTitleResource`) is
    /// extracted as nil. These are the same catalog keys and English defaults as
    /// ``SleepTimerPreset/menuTitleResource``. ``SleepTimerIntentTests`` asserts
    /// the two resources stay equal.
    nonisolated static var caseDisplayRepresentations: [SleepTimerPresetAppEnum: DisplayRepresentation] {
        [
            .fifteenMinutes: DisplayRepresentation(
                title: LocalizedStringResource(
                    "sleep_timer_preset_15_min",
                    defaultValue: "15 minutes",
                    table: "Localizable"
                )
            ),
            .thirtyMinutes: DisplayRepresentation(
                title: LocalizedStringResource(
                    "sleep_timer_preset_30_min",
                    defaultValue: "30 minutes",
                    table: "Localizable"
                )
            ),
            .fortyFiveMinutes: DisplayRepresentation(
                title: LocalizedStringResource(
                    "sleep_timer_preset_45_min",
                    defaultValue: "45 minutes",
                    table: "Localizable"
                )
            ),
            .sixtyMinutes: DisplayRepresentation(
                title: LocalizedStringResource(
                    "sleep_timer_preset_60_min",
                    defaultValue: "60 minutes",
                    table: "Localizable"
                )
            ),
        ]
    }
}

// MARK: - Dialogs

/// Spoken result for ``SetSleepTimerIntent``.
///
/// `full` is the sheet title (`sleep_timer_sheet_title`, English "Sleep timer").
/// `supporting` is that preset's ``SleepTimerPreset/menuTitleResource``.
/// A sentence such as "Sleep timer set for 15 minutes." would be a new
/// `Localizable` key, and so would the 30, 45, and 60 siblings.
///
/// - SeeAlso: ``SleepTimerPreset/menuTitleResource``, ``SetSleepTimerIntent``,
///   CODING_AGENT.md (Localization).
enum SleepTimerSetDialog {
    /// Sheet-title resource used as the spoken line.
    ///
    /// The intent title, shortcut short title, parameter title, and type name
    /// repeat this initializer. The metadata extractor does not follow a property.
    static var fullResource: LocalizedStringResource {
        LocalizedStringResource(
            "sleep_timer_sheet_title",
            defaultValue: "Sleep timer",
            table: "Localizable"
        )
    }

    /// Snippet beside the spoken line. Already translated with the in-app menu.
    static func supportingResource(for preset: SleepTimerPresetAppEnum) -> LocalizedStringResource {
        preset.preset.menuTitleResource
    }

    static func intentDialog(for preset: SleepTimerPresetAppEnum) -> IntentDialog {
        IntentDialog(
            full: fullResource,
            supporting: supportingResource(for: preset)
        )
    }
}

/// Spoken result for ``CancelSleepTimerIntent`` when a countdown is armed.
///
/// The dialog is `sleep_timer_cancel_timer` (English "Cancel timer"). An unarmed
/// timer returns the same result container with `dialog` cleared. `.result()`
/// (`Dialog == Never`) and `.result(dialog:)` (`Dialog == IntentDialog`) are
/// different concrete types, so one `perform()` cannot return both. Clearing
/// `dialog` is the no-dialog result. It does not add a catalog key.
///
/// - SeeAlso: ``CancelSleepTimerIntent``, ``SharedPlayerManager/isSleepTimerArmed``,
///   CODING_AGENT.md (Localization).
enum SleepTimerCancelDialog {
    static var cancelledResource: LocalizedStringResource {
        LocalizedStringResource(
            "sleep_timer_cancel_timer",
            defaultValue: "Cancel timer",
            table: "Localizable"
        )
    }

    static var cancelled: IntentDialog {
        IntentDialog(cancelledResource)
    }

    /// - Parameter isArmed: ``SharedPlayerManager/isSleepTimerArmed``.
    /// - Returns: The cancel-timer dialog when a countdown is armed, and the
    ///   same container with `dialog == nil` when nothing is armed.
    static func result(isArmed: Bool) -> IntentResultContainer<Never, Never, Never, IntentDialog> {
        if isArmed {
            return .result(dialog: cancelled)
        }
        var silent = IntentResultContainer<Never, Never, Never, IntentDialog>.result(dialog: cancelled)
        silent.dialog = nil
        return silent
    }
}

// MARK: - Set

/// Arms a 15, 30, 45, or 60 minute sleep timer from Siri or Shortcuts.
///
/// Calls ``SharedPlayerManager/setSleepTimer(duration:)`` and does not start
/// playback. Stopped or paused audio still gets a countdown: that method moves
/// ``playbackIntent`` to ``.sleepTimer`` only when the visual state is
/// ``.playing`` or the intent is already an active playback intent
/// (``shouldBePlaying`` or ``.sleepTimer``). A ``.userPaused`` session keeps
/// ``.userPaused``. The deadline still runs ``applySleepTimerElapsedPause()``.
/// The in-app preset button uses the same call with no play/pause gate.
///
/// The schedule posts ``SleepTimerNotification/stateDidChange`` so the moon
/// and the local countdown update while the app is in memory. A later
/// foreground pass reads ``sleepTimerRemainingSeconds`` from the actor.
///
/// Replacing an armed timer is the actor's existing behavior: `setSleepTimer`
/// cancels the previous countdown, then arms the new length.
///
/// - SeeAlso: ``SleepTimerPreset``, ``CancelSleepTimerIntent``,
///   ``SharedPlayerManager/setSleepTimer(duration:)``,
///   ``SharedPlayerManager/isSleepTimerArmed``,
///   ``LutheranRadioShortcuts``.
struct SetSleepTimerIntent: AppIntent {
    /// Inlined. The metadata extractor does not follow ``SleepTimerSetDialog/fullResource``.
    nonisolated static var title: LocalizedStringResource {
        LocalizedStringResource(
            "sleep_timer_sheet_title",
            defaultValue: "Sleep timer",
            table: "Localizable"
        )
    }

    /// Deprecated alias. ``supportedModes`` is background so the shortcut does not open the app.
    nonisolated static var openAppWhenRun: Bool { false }
    nonisolated static var supportedModes: IntentModes { .background }

    /// Preset length. Defaults to 30 minutes when the phrase does not name one.
    ///
    /// A phrase that includes `\(\.$duration)` fills this in one sentence.
    /// There is no disambiguation dialog and no parameter summary. Those
    /// literals would be new `Localizable` keys.
    @Parameter(
        title: LocalizedStringResource(
            "sleep_timer_sheet_title",
            defaultValue: "Sleep timer",
            table: "Localizable"
        ),
        default: SleepTimerPresetAppEnum.thirtyMinutes
    )
    var duration: SleepTimerPresetAppEnum

    init() {
        self.duration = .thirtyMinutes
    }

    init(duration: SleepTimerPresetAppEnum) {
        self.duration = duration
    }

    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[SleepTimerIntents] SetSleepTimerIntent.perform minutes=\(duration.minutes)")
        #endif

        // Presets are positive. `setSleepTimer` returns nil only for `<= 0`.
        _ = await SharedPlayerManager.shared.setSleepTimer(duration: duration.preset.duration)

        #if DEBUG
        print("[SleepTimerIntents] SetSleepTimerIntent completed minutes=\(duration.minutes)")
        #endif
        return .result(dialog: SleepTimerSetDialog.intentDialog(for: duration))
    }
}

// MARK: - Cancel

/// Cancels the armed sleep timer.
///
/// Calls ``SharedPlayerManager/cancelSleepTimer()`` only when
/// ``isSleepTimerArmed`` is true (the same flag that posts the inactive
/// countdown notification). An unarmed timer returns
/// ``SleepTimerCancelDialog/result(isArmed:)`` with `dialog == nil` and does
/// not throw.
///
/// - SeeAlso: ``SetSleepTimerIntent``,
///   ``SharedPlayerManager/cancelSleepTimer(restorePlaybackIntent:notifyStateChange:)``,
///   ``SleepTimerCancelDialog``, ``LutheranRadioShortcuts``.
struct CancelSleepTimerIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource {
        LocalizedStringResource(
            "sleep_timer_cancel_timer",
            defaultValue: "Cancel timer",
            table: "Localizable"
        )
    }

    /// Deprecated alias. ``supportedModes`` is background so the shortcut does not open the app.
    nonisolated static var openAppWhenRun: Bool { false }
    nonisolated static var supportedModes: IntentModes { .background }

    init() {}

    func perform() async throws -> some IntentResult {
        let manager = SharedPlayerManager.shared
        let isArmed = await manager.isSleepTimerArmed

        #if DEBUG
        print("[SleepTimerIntents] CancelSleepTimerIntent.perform armed=\(isArmed)")
        #endif

        if isArmed {
            await manager.cancelSleepTimer()
        }

        // Unarmed: `dialog` is nil (no "No sleep timer is running." key).
        // Armed: the cancel-timer title. See ``SleepTimerCancelDialog``.
        return SleepTimerCancelDialog.result(isArmed: isArmed)
    }
}
