//
//  RadioPlaybackIntents.swift
//  Lutheran Radio
//
//  Siri Shortcuts + AppShortcutsProvider implementation for top-level voice / Shortcuts app
//  integration. Reuses the exact SharedPlayerManager SSOT surfaces used by widget intents
//  and the RadioPlayerCoordinator (resetToPrePlayForNewStream + switchToStream + setUserIntentToPlay
//  + play / stop). All playback goes through the documented guarded paths, resurrection protection,
//  security validation, intent clearing, and persistence.
//
//  New code lives only in the main "Lutheran Radio" target (no Core, no widget changes).
//  Matches style, DEBUG logging, init patterns, and error handling from LutheranRadioWidget intents.
//
//  Created by Jari Lammi on 15.6.2026.
//

import AppIntents
import Foundation
import WidgetSurface

// MARK: - Language Entity (for high-quality Siri disambiguation + suggestions)

/// AppEntity representing one of the 5 playable radio streams (en, de, fi, sv, et).
/// Display uses the authoritative flag + localized language name from DirectStreamingPlayer.Stream
/// (which in turn uses the language_* + lutheran_radio_title keys from Localizable).
struct RadioLanguageEntity: AppEntity {
    /// The language code (e.g. "fi", "de"). Used as stable identifier.
    let id: String

    /// Human-readable representation shown in Shortcuts / Siri.
    let displayRepresentation: DisplayRepresentation

    nonisolated static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: LocalizedStringResource("Language"),
            numericFormat: LocalizedStringResource("\(placeholder: .int) languages")
        )
    }

    nonisolated static let defaultQuery = RadioLanguageQuery()

    init(id: String, displayRepresentation: DisplayRepresentation) {
        self.id = id
        self.displayRepresentation = displayRepresentation
    }
}

// MARK: - Entity Query

struct RadioLanguageQuery: EntityQuery {
    /// Returns the 5 supported streams as suggested entities for Siri / Shortcuts parameter pickers.
    /// Uses the SSOT availableStreams (exactly the 5 playable ones; full 21 UI languages are separate).
    func suggestedEntities() async throws -> [RadioLanguageEntity] {
        let streams = SharedPlayerManager.shared.availableStreams
        return streams.map { stream in
            RadioLanguageEntity(
                id: stream.languageCode,
                displayRepresentation: DisplayRepresentation(
                    title: "\(stream.flag) \(stream.language)"
                )
            )
        }
    }

    /// Resolves specific entities by ID (used by the system for persisted shortcuts etc.).
    func entities(for identifiers: [RadioLanguageEntity.ID]) async throws -> [RadioLanguageEntity] {
        let streams = SharedPlayerManager.shared.availableStreams
        return identifiers.compactMap { code in
            guard let stream = streams.first(where: { $0.languageCode == code }) else { return nil }
            return RadioLanguageEntity(
                id: stream.languageCode,
                displayRepresentation: DisplayRepresentation(
                    title: "\(stream.flag) \(stream.language)"
                )
            )
        }
    }
}

// MARK: - Play Intent (generic or parameterized by language)

/// Siri / Shortcuts / App Intent entry for explicit play or "play in language".
///
/// Always terminates via `SharedPlayerManager.userRequestedPlay()` (the designated
/// authoritative explicit-play entry). Parameterized language cases do resetToPrePlay +
/// switchToStream before the play request.
///
/// - SeeAlso: ``SharedPlayerManager/userRequestedPlay()``, ``SharedPlayerManager/setUserIntentToPlay()``,
///   RadioPlayerCoordinator.handleSwitchToLanguage,
///   CODING_AGENT.md (Single Source of Truth Principles), <doc:Architecture>.
struct PlayRadioIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Play Lutheran Radio" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Play or resume Lutheran Radio.")
    }

    /// Optional language parameter. When supplied, switches to that stream before playing.
    /// When nil, performs a generic resume / last-stream play (or default initial language).
    @Parameter(title: LocalizedStringResource("Language"))
    var language: RadioLanguageEntity?

    init() {}

    init(language: RadioLanguageEntity?) {
        self.language = language
    }

    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[RadioPlaybackIntents] PlayRadioIntent.perform called language=\(language?.id ?? "nil (generic/resume)")")
        #endif

        let manager = SharedPlayerManager.shared

        if let entity = language {
            // Parameterized "Play Lutheran Radio in X" path.
            guard let targetStream = manager.availableStreams.first(where: { $0.languageCode == entity.id }) else {
                #if DEBUG
                print("[RadioPlaybackIntents] PlayRadioIntent: requested language not found, falling back to generic play")
                #endif
                // Route through the authoritative explicit entry (designation).
                await manager.userRequestedPlay()
                return .result()
            }

            // Follow the documented switch + play path from the resurrection table and
            // RadioPlayerCoordinator / widget switch paths. Then use userRequestedPlay()
            // (the single designated entry) to guarantee setUserIntentToPlay + play for
            // clearing sticky states and driving the guarded engine.
            let intent = await manager.currentPlaybackIntent
            await manager.resetToPrePlayForNewStream(
                preserveActiveSleepTimer: intent == .sleepTimer
            )
            await manager.switchToStream(targetStream)
        }

        // Generic play / resume (or continuation after a parameterized switch above).
        // `userRequestedPlay()` is the designated explicit-play entry point.
        // It performs configure (main-app) + setUserIntentToPlay() + play().
        await manager.userRequestedPlay()

        #if DEBUG
        print("[RadioPlaybackIntents] PlayRadioIntent completed")
        #endif
        return .result()
    }
}

// MARK: - Pause Intent

struct PauseRadioIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Pause Lutheran Radio" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Pause Lutheran Radio playback.")
    }

    init() {}

    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[RadioPlaybackIntents] PauseRadioIntent.perform called")
        #endif

        let manager = SharedPlayerManager.shared

        // stop() immediately locks .userPaused (sticky resurrection protection) and
        // updates playbackIntent. This is the same path used by in-app pause, widget
        // pause, Control Center, Live Activity, and lock screen.
        await manager.stop()

        #if DEBUG
        print("[RadioPlaybackIntents] PauseRadioIntent completed – visual locked to userPaused")
        #endif
        return .result()
    }
}

// MARK: - Switch Language Intent (explicit language change + play)

/// Siri / Shortcuts intent for language switch + play.
///
/// Uses reset + switchToStream followed by the designated `userRequestedPlay()`
/// (ensures `setUserIntentToPlay()` + execution through `play()`).
///
/// - SeeAlso: ``SharedPlayerManager/userRequestedPlay()``.
struct SwitchToLanguageIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Switch to %@" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Switch Lutheran Radio language stream.")
    }

    @Parameter(title: LocalizedStringResource("Language"))
    var language: RadioLanguageEntity

    init() {}

    init(language: RadioLanguageEntity) {
        self.language = language
    }

    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[RadioPlaybackIntents] SwitchToLanguageIntent.perform called for: \(language.id)")
        #endif

        let manager = SharedPlayerManager.shared

        guard let targetStream = manager.availableStreams.first(where: { $0.languageCode == language.id }) else {
            #if DEBUG
            print("[RadioPlaybackIntents] SwitchToLanguageIntent: language stream not found for \(language.id)")
            #endif
            return .result()
        }

        // Mirror the canonical switch flow used for in-app flag taps (completeStreamSwitch)
        // and widget reconciliation (switchToStreamFromWidget). Uses resetToPrePlayForNewStream
        // + SPM.switchToStream (which for main-app forwards to engine) + then the designated
        // userRequestedPlay() entry (set + play). This ensures the prePlay visual, sticky
        // clear, and guarded execution (see resurrection table).
        // External/Siri paths intentionally bypass main-app tuning/needle UX.
        // Preserve an active sleep timer across the switch (symmetric with completeStreamSwitch).
        let intent = await manager.currentPlaybackIntent
        await manager.resetToPrePlayForNewStream(
            preserveActiveSleepTimer: intent == .sleepTimer
        )
        await manager.switchToStream(targetStream)
        await manager.userRequestedPlay()

        #if DEBUG
        print("[RadioPlaybackIntents] SwitchToLanguageIntent completed for \(language.id)")
        #endif
        return .result()
    }
}

// MARK: - AppShortcutsProvider (zero-config Siri + Shortcuts app discovery)

struct LutheranRadioShortcuts: AppShortcutsProvider {
    /// Provides the top-level shortcuts that appear automatically in the Shortcuts app,
    /// Spotlight, and are trainable by Siri ("Hey Siri, play Lutheran Radio in Finnish").
    static var appShortcuts: [AppShortcut] {
        let play = AppShortcut(
            intent: PlayRadioIntent(),
            phrases: [
                "Play \(.applicationName)",
                "Start \(.applicationName)",
                "Play \(.applicationName) in \(\.$language)"
            ],
            shortTitle: LocalizedStringResource("Play Lutheran Radio"),
            systemImageName: "play.circle.fill"
        )
        let pause = AppShortcut(
            intent: PauseRadioIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Stop \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("Pause Lutheran Radio"),
            systemImageName: "pause.circle.fill"
        )
        let switchLang = AppShortcut(
            intent: SwitchToLanguageIntent(),
            phrases: [
                "Switch \(.applicationName) to \(\.$language)",
                "Play \(.applicationName) in \(\.$language)"
            ],
            shortTitle: LocalizedStringResource("Switch to %@"),
            systemImageName: "globe"
        )
        return [play, pause, switchLang]
    }
}
