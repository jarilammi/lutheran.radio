//
//  WidgetInteractiveIntents.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 15.9.2026.
//
//  SHARED: Cross-target membership-exception source (main app + extension +
//  LutheranRadioWidgetTests). Interactive AppIntent **types** for Live Activity,
//  home-widget, and Control Center play/pause/switch. Views stay in
//  `LutheranRadioWidget/` (`ActivityConfiguration`, home family, ControlWidget).
//
//  Why this file is a membership exception:
//  AppIntents that call ``WidgetIntentExecution`` / ``SharedPlayerManager`` cannot live
//  in WidgetSurface (circular: the actor already imports WidgetSurface). They also
//  cannot live only in the widget-extension folder: Archive / lock-screen media
//  interactives must exist in the **app target** so the system can run `perform()`
//  in the app process. File System Synchronized Group membershipExceptions compile
//  this file into the main app, `LutheranRadioWidgetExtension`, and
//  `LutheranRadioWidgetTests` — same set as ``WidgetIntentExecution.swift``.
//
//  Why AudioPlaybackIntent / LiveActivityIntent:
//  A plain `AppIntent` compiled only into the extension runs `perform()` in the
//  extension. Debug/Xcode with an audio-alive main process can still hear Darwin
//  ``radio.lutheran.widget.action``. Archive / lock-screen with main suspended
//  cannot. Apple’s contract: play/pause of media adopts ``AudioPlaybackIntent``;
//  Live Activity interactives adopt ``LiveActivityIntent``. Those protocols make
//  the system launch/wake the **app** in the background. Dual conformance is
//  applied on the main-app compile (`LUTHERAN_MAIN_APP`) so the extension still
//  has the same AppIntent type for `Button(intent:)`.
//
//  Why supportedModes = .background:
//  Lock-screen / home / Control buttons must not foreground the app.
//  ``openAppWhenRun`` stays `false` as a deprecated compatibility alias; do not
//  set it `true`. ``LiveActivityIntent`` must not be used as a way to open the app.
//
//  Execution: thin `perform()` delegates to ``WidgetIntentExecution/perform*``.
//  Main-app play/pause uses the media-transport mailbox
//  (``submitMediaTransportCommandAndWait``). Extension `perform()` keeps pending
//  + Darwin as defense-in-depth if the system still hosts the intent there.
//  Do not also write `pendingAction*` + Darwin for an in-process mailbox tap.
//
//  Privacy: do not open the home-widget ``hasActiveLutheranWidgets`` gate solely
//  because a Live Activity button was tapped. LA mirrors are not home-gate-bound.
//  Never start Live Activities from the widget extension. Never end the only
//  interactive Live Activity while ``isInteractiveLiveActivityRequestEligible``
//  is false. Do not invent `.playing` during stream-switch hold.
//
//  Not Siri: ``PlayRadioIntent`` / ``PauseRadioIntent`` in `RadioPlaybackIntents.swift`
//  remain main-app-only App Shortcuts. Do not conflate with these lock-screen /
//  widget interactives. Do not put Siri utterances in Localizable.
//
//  - SeeAlso: ``WidgetIntentExecution``, ``AudioPlaybackIntent``, ``LiveActivityIntent``,
//    docs/Live-Activity-Stacking-and-Media-Surfaces.md (lock-screen button hosting),
//    docs/Widget-Functionality-Roadmap.md, CODING_AGENT.md (membership exceptions),
//    README.md (cross-target widget sources).
//

import AppIntents
import Foundation
import WidgetSurface

// MARK: - Live Activity play/pause

/// Lock Screen / Dynamic Island play/pause control.
///
/// Thin `perform()` delegates to ``WidgetIntentExecution/performLiveActivityToggle()``.
/// Direction is planned from ActivityKit ContentState / durable App Group mirror first —
/// never from a cold extension’s default `.prePlay` alone.
///
/// - Important: Compiled into the **main app** and the widget extension. On the main-app
///   profile this type adopts ``AudioPlaybackIntent`` and ``LiveActivityIntent`` so the
///   system wakes the app process in the background and runs `perform()` there (Archive /
///   lock-screen media contract). `supportedModes` is ``IntentModes/background``;
///   ``openAppWhenRun`` stays `false` — buttons must not foreground the UI.
///   Main-app execution uses ``WidgetIntentExecution/executeLiveActivityToggle(plan:)``
///   → ``SharedPlayerManager/submitMediaTransportCommandAndWait(_:)``. The extension
///   compile still uses ``stop()`` / ``userRequestedPlay()`` (pending + Darwin
///   ``radio.lutheran.widget.action``) if the system hosts `perform()` there.
/// - Important: Play direction must go through ``SharedPlayerManager/userRequestedPlay()``
///   (explicit-play SSOT). Direct `play()` from this intent is forbidden.
/// - SeeAlso: ``WidgetIntentExecution/performLiveActivityToggle()``,
///   ``LiveActivitySwitchStreamIntent``, ``WidgetPlayRadioIntent``,
///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
///   CODING_AGENT.md (membership exceptions).
struct LiveActivityTogglePlaybackIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Toggle Lutheran Radio Playback" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Toggle play/pause from Live Activity.")
    }
    /// Deprecated alias: keep false so lock-screen buttons never open the host.
    /// Prefer ``supportedModes`` (``.background``).
    nonisolated static var openAppWhenRun: Bool { false }
    nonisolated static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[WidgetInteractiveIntents] LiveActivityTogglePlaybackIntent.perform called")
        #endif

        await WidgetIntentExecution.performLiveActivityToggle()

        #if DEBUG
        print("[WidgetInteractiveIntents] LiveActivityTogglePlaybackIntent completed")
        #endif

        return .result()
    }
}

#if LUTHERAN_MAIN_APP
/// App-target registration: media wake + Live Activity interactive hosting.
///
/// The extension compile keeps the same ``AppIntent`` type for `Button(intent:)` but
/// does not adopt these protocols (unavailable / incorrect in app extensions). The
/// **app** registration is what makes the system choose the app process.
extension LiveActivityTogglePlaybackIntent: AudioPlaybackIntent, LiveActivityIntent {}
#endif

// MARK: - Live Activity language chips

/// Lock Screen / Dynamic Island language-chip stream switch.
///
/// - Important: Adopts ``LiveActivityIntent`` on the main-app profile so chip taps
///   run in the app process without opening the UI (`supportedModes` is background).
///   Never invents `.playing` during stream-switch hold — execution stays on
///   ``WidgetIntentExecution/performLiveActivityStreamSwitch(languageCode:)``.
/// - SeeAlso: ``LiveActivityTogglePlaybackIntent``,
///   ``WidgetIntentExecution/performLiveActivityStreamSwitch(languageCode:)``,
///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
struct LiveActivitySwitchStreamIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Switch Stream" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Switch to a different language stream from Live Activity.")
    }
    nonisolated static var openAppWhenRun: Bool { false }
    nonisolated static var supportedModes: IntentModes { .background }

    @Parameter(title: "Language Code")
    var languageCode: String

    init() {}
    init(languageCode: String) {
        self.languageCode = languageCode
    }

    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[WidgetInteractiveIntents] LiveActivitySwitchStreamIntent.perform called for language: \(languageCode)")
        #endif

        let switched = await WidgetIntentExecution.performLiveActivityStreamSwitch(languageCode: languageCode)

        #if DEBUG
        if !switched {
            print("[WidgetInteractiveIntents] LiveActivitySwitchStreamIntent: Language stream not found")
        } else {
            print("[WidgetInteractiveIntents] LiveActivitySwitchStreamIntent completed for \(languageCode)")
        }
        #endif

        return .result()
    }
}

#if LUTHERAN_MAIN_APP
extension LiveActivitySwitchStreamIntent: LiveActivityIntent {}
#endif

// MARK: - Home widget play/pause

/// Direction-explicit **play** from the home-widget control (play glyph).
///
/// - Important: Main-app profile adopts ``AudioPlaybackIntent`` so media wake runs
///   `perform()` in the app process. `supportedModes` is background; the button must
///   not foreground the app.
/// - SeeAlso: ``WidgetIntentExecution/performHomeWidgetPlay()``, ``WidgetPauseRadioIntent``.
struct WidgetPlayRadioIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Play Lutheran Radio" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Start or resume Lutheran Radio playback.")
    }
    nonisolated static var openAppWhenRun: Bool { false }
    nonisolated static var supportedModes: IntentModes { .background }

    init() {}

    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[WidgetInteractiveIntents] WidgetPlayRadioIntent.perform called")
        #endif
        await WidgetIntentExecution.performHomeWidgetPlay()
        #if DEBUG
        print("[WidgetInteractiveIntents] WidgetPlayRadioIntent completed")
        #endif
        return .result()
    }
}

#if LUTHERAN_MAIN_APP
extension WidgetPlayRadioIntent: AudioPlaybackIntent {}
#endif

/// Direction-explicit **pause** from the home-widget control (pause glyph).
///
/// - SeeAlso: ``WidgetIntentExecution/performHomeWidgetPause()``, ``WidgetPlayRadioIntent``.
struct WidgetPauseRadioIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Pause Lutheran Radio" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Pause Lutheran Radio playback.")
    }
    nonisolated static var openAppWhenRun: Bool { false }
    nonisolated static var supportedModes: IntentModes { .background }

    init() {}

    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[WidgetInteractiveIntents] WidgetPauseRadioIntent.perform called")
        #endif
        await WidgetIntentExecution.performHomeWidgetPause()
        #if DEBUG
        print("[WidgetInteractiveIntents] WidgetPauseRadioIntent completed")
        #endif
        return .result()
    }
}

#if LUTHERAN_MAIN_APP
extension WidgetPauseRadioIntent: AudioPlaybackIntent {}
#endif

/// Legacy single-intent toggle (tests / Shortcuts). Home family views use direction-bound intents.
///
/// - SeeAlso: ``WidgetIntentExecution/performHomeWidgetToggle()``, ``WidgetPlayRadioIntent``.
struct WidgetToggleRadioIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Toggle Lutheran Radio" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Play or pause Lutheran Radio.")
    }
    nonisolated static var openAppWhenRun: Bool { false }
    nonisolated static var supportedModes: IntentModes { .background }

    init() {}

    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[WidgetInteractiveIntents] WidgetToggleRadioIntent.perform called")
        #endif
        await WidgetIntentExecution.performHomeWidgetToggle()
        #if DEBUG
        print("[WidgetInteractiveIntents] WidgetToggleRadioIntent completed")
        #endif
        return .result()
    }
}

#if LUTHERAN_MAIN_APP
extension WidgetToggleRadioIntent: AudioPlaybackIntent {}
#endif

// MARK: - Home widget stream chips

/// Home-widget language-chip stream switch.
///
/// - Important: `supportedModes` is background so chips do not open the app.
///   Engine work stays on ``WidgetIntentExecution/performHomeWidgetStreamSwitch(languageCode:)``.
/// - SeeAlso: ``LiveActivitySwitchStreamIntent``,
///   ``WidgetIntentExecution/performHomeWidgetStreamSwitch(languageCode:)``.
public struct SwitchStreamIntent: AppIntent {
    public init() {}
    public init(streamLanguageCode: String) {
        self.streamLanguageCode = streamLanguageCode
    }

    public nonisolated static var title: LocalizedStringResource { "Switch Stream" }
    public nonisolated static var description: IntentDescription {
        IntentDescription("Switch to a different language stream.")
    }
    public nonisolated static var openAppWhenRun: Bool { false }
    public nonisolated static var supportedModes: IntentModes { .background }

    @Parameter(title: "Language Code")
    var streamLanguageCode: String

    public func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[WidgetInteractiveIntents] SwitchStreamIntent.perform called for language: \(streamLanguageCode)")
        #endif
        await WidgetIntentExecution.performHomeWidgetStreamSwitch(languageCode: streamLanguageCode)
        #if DEBUG
        print("[WidgetInteractiveIntents] SwitchStreamIntent completed for \(streamLanguageCode)")
        #endif
        return .result()
    }
}

#if LUTHERAN_MAIN_APP
extension SwitchStreamIntent: AudioPlaybackIntent {}
#endif

// MARK: - Control Center toggle

/// Control Center ``ControlWidgetToggle`` play/pause.
///
/// Remains a ``SetValueIntent`` so ``ControlWidgetToggle`` can bind `value`
/// (`true` = play, `false` = pause). On the main-app profile also adopts
/// ``AudioPlaybackIntent`` so Control play/pause is the same media-wake class as
/// lock-screen / home play-pause (`supportedModes` is background).
///
/// - Important: If a future SDK rejects ``SetValueIntent`` + ``AudioPlaybackIntent``
///   dual conformance, keep ``SetValueIntent`` (Control Center requirement) and
///   ``supportedModes`` = `.background`. Do not break Control Center.
/// - SeeAlso: ``WidgetIntentExecution/performControlWidgetToggle(isPlayingRequested:)``,
///   ``WidgetPlayRadioIntent``.
struct ToggleRadioIntent: SetValueIntent {
    nonisolated static var title: LocalizedStringResource { "Toggle Lutheran Radio" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Start or stop Lutheran Radio playback.")
    }
    nonisolated static var openAppWhenRun: Bool { false }
    nonisolated static var supportedModes: IntentModes { .background }

    @Parameter(title: "Is Playing")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[WidgetInteractiveIntents] ToggleRadioIntent.perform called with desired value: \(value)")
        #endif
        await WidgetIntentExecution.performControlWidgetToggle(isPlayingRequested: value)
        #if DEBUG
        print("[WidgetInteractiveIntents] ToggleRadioIntent completed successfully")
        #endif
        return .result()
    }
}

#if LUTHERAN_MAIN_APP
extension ToggleRadioIntent: AudioPlaybackIntent {}
#endif
