//
//  SharedPlayerManager+Persistence.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 23.7.2026.
//
//  SHARED: Cross-target membership-exception source (main app + extension +
//  LutheranRadioWidgetTests). Mechanical split of SharedPlayerManager — same actor,
//  no API renames, no behavior change.
//
//  Purpose: In-process PersistedWidgetState session snapshot, retired App Group key purge, and thermal visual sanitization.
//
//  - SeeAlso: SharedPlayerManager.swift, CODING_AGENT.md (cross-target membership exceptions).
//

import Foundation
import Core
import WidgetSurface
#if LUTHERAN_MAIN_APP
import os
import WidgetKit
#endif

extension SharedPlayerManager {
    // MARK: - PlayerVisualState Persistence & Restoration (Private)

    /// Loads the in-process session visual chrome for the current runtime.
    ///
    /// Authoritative **writes** are only via ``saveCurrentState()`` → `performActualSave`
    /// / ``persistWidgetSnapshot`` (privacy-gated). There is no separate visual-save API —
    /// sticky mutations (`applyVisualState`) take effect immediately in-actor; surfaces
    /// observe them after the next real persist path.
    ///
    /// - Returns: Sanitized session visual state, or `.prePlay` when no session snapshot exists.
    /// - Note: Cold launch always yields factory `.prePlay` (memory-only visual policy; OI-1).
    /// - SeeAlso: ``saveCurrentState()``, ``persistWidgetSnapshot``,
    ///   ``clearPersistedVisualStateKeysFromDisk()``, SharedPlayerManager.swift (App Group table),
    ///   docs/Event-Driven-Refactor-Roadmap.md (OI-1), CODING_AGENT.md (SSOT).
    internal func loadVisualState() -> PlayerVisualState {
        // In-session memory snapshot only; cold launch returns .prePlay.
        if let combined = Self.loadPersistedWidgetState() {
            return Self.sanitizedVisualStateForCrossProcessRestore(combined.visualState)
        }
        return .prePlay
    }

    // MARK: - Retired App Group Key Purge

    /// Removes retired on-disk App Group leftovers from pre-memory-only installs and
    /// retired operational keys that no longer have writers or readers.
    ///
    /// **Purge only — not a migration.** Blobs and bools are deleted, never decoded into
    /// session state. Visual chrome is never restored from disk; every cold launch uses
    /// factory `.prePlay` via ``resetToFactoryDefaultsOnLaunch()`` / ``init()``.
    ///
    /// Keys cleared: `persistedWidgetState`, `playerVisualState`, `isPlaying`, `playing`,
    /// `hasError`, bare `currentLanguage`, retired `lastUserPauseTime` (pause barrier is
    /// in-actor only), retired `preferredVolume` (system volume is SSOT).
    ///
    /// Does **not** touch security caches, liveness (`lastUpdateTime`), pending-action keys,
    /// instant-feedback keys, or durable Live Activity mirrors
    /// (`liveActivityToggleVisualState`, `liveActivityCurrentLanguage`).
    ///
    /// Called from ``loadPersistedWidgetState()``, ``ensureVisualStateLoaded()``,
    /// ``resetToFactoryDefaultsOnLaunch()`` / factory-reset teardown,
    /// ``updateInMemorySessionSnapshot``, and ``removeAllLocalPlaybackKeys()``.
    ///
    /// - SeeAlso: ``resetToFactoryDefaultsOnLaunch()``, ``removeAllLocalPlaybackKeys()``,
    ///   ``preferredWidgetLanguage()``, ``wasRecentlyUserPaused(within:)``,
    ///   docs/Event-Driven-Refactor-Roadmap.md (OI-1),
    ///   CODING_AGENT.md (Single Source of Truth Principles).
    nonisolated static func clearPersistedVisualStateKeysFromDisk() {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return }
        defaults.removeObject(forKey: "persistedWidgetState")
        defaults.removeObject(forKey: "playerVisualState")
        defaults.removeObject(forKey: "isPlaying")
        defaults.removeObject(forKey: "playing")
        defaults.removeObject(forKey: "hasError")
        // Retired bare language key (never written by current paths; purge for upgrade hygiene).
        defaults.removeObject(forKey: "currentLanguage")
        // Retired operational keys (no writers/readers; in-actor / system SSOT replaced them).
        defaults.removeObject(forKey: "lastUserPauseTime")
        defaults.removeObject(forKey: "preferredVolume")
    }

    /// Drops the in-process session snapshot. SSOT write helper — sole `nil` assignment site.
    ///
    /// - SeeAlso: ``loadPersistedWidgetState()``, ``updateInMemorySessionSnapshot(visualState:language:streamMetadata:hasError:clearStreamMetadata:)``.
    nonisolated static func clearInMemorySessionSnapshot() {
        unsafe inMemorySessionWidgetSnapshot = nil
    }

    /// Updates the in-process session snapshot (never written to UserDefaults).
    nonisolated static func updateInMemorySessionSnapshot(
        visualState: PlayerVisualState,
        language: String,
        streamMetadata: StreamProgramMetadata? = nil,
        hasError: Bool = false,
        clearStreamMetadata: Bool = false
    ) {
        let visualToStore = visualStateForPersistenceWrite(visualState)
        let resolvedMetadata: StreamProgramMetadata?
        if clearStreamMetadata {
            resolvedMetadata = nil
        } else if let streamMetadata {
            resolvedMetadata = streamMetadata
        } else {
            resolvedMetadata = unsafe inMemorySessionWidgetSnapshot?.streamMetadata
        }
        unsafe inMemorySessionWidgetSnapshot = PersistedWidgetState(
            visualState: visualToStore,
            currentLanguage: language,
            lastLanguageChangeTime: Date(),
            streamMetadata: resolvedMetadata,
            hasError: hasError
        )
        clearPersistedVisualStateKeysFromDisk()
    }

    // MARK: - Thermal visual state (ephemeral — never sticky across launches)

    /// Returns whether `ProcessInfo` reports a thermal state that warrants pausing playback.
    ///
    /// - Note: Simulators report `.nominal` or `.fair`; a persisted `.thermalPaused` snapshot
    ///   on cold launch is therefore always stale unless the device is still overheating.
    ///
    /// - SeeAlso: ``sanitizedVisualStateForCrossProcessRestore(_:)``,
    ///   ``visualStateForPersistenceWrite(_:)``, `DirectStreamingPlayer.setupThermalProtection()`.
    nonisolated static func isDeviceThermallyStressed() -> Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            return true
        case .nominal, .fair:
            return false
        @unknown default:
            return false
        }
    }

    /// Restores a persisted visual state, downgrading stale `.thermalPaused` when the device has cooled.
    ///
    /// `thermalPaused` is an in-session hardware gate only. Unlike `.userPaused` it must not
    /// block cold-launch auto-play after the thermal condition clears (simulator always clears).
    ///
    /// - Parameter state: Raw visual state from a snapshot or legacy JSON key.
    /// - Returns: `state`, or `.prePlay` when `state` was `.thermalPaused` and the device is cool.
    nonisolated static func sanitizedVisualStateForCrossProcessRestore(_ state: PlayerVisualState) -> PlayerVisualState {
        guard state == .thermalPaused, !isDeviceThermallyStressed() else { return state }
        #if DEBUG
        print("[SharedPlayerManager] Sanitized stale persisted .thermalPaused → .prePlay (device no longer overheating)")
        #endif
        return .prePlay
    }

    /// Maps in-memory visual state to a value safe to write into `PersistedWidgetState`.
    ///
    /// Never persist `.thermalPaused`; it is re-derived from `ProcessInfo` when needed.
    nonisolated static func visualStateForPersistenceWrite(_ state: PlayerVisualState) -> PlayerVisualState {
        guard state == .thermalPaused else { return state }
        #if DEBUG
        print("[SharedPlayerManager] Not persisting ephemeral .thermalPaused — writing .prePlay instead")
        #endif
        return .prePlay
    }

    // MARK: - Persisted Widget State (visual + language snapshot)

    /// In-process session snapshot carrying visual intent, language, metadata, and error flag.
    /// Never serialized to UserDefaults (memory-only policy).
    ///
    /// Carries `hasError` so ``loadSharedState()`` can derive both playback chrome and the
    /// permanent-error flag strictly from this in-process snapshot (never from retired
    /// App Group bools — those are purged only via ``clearPersistedVisualStateKeysFromDisk()``).
    struct PersistedWidgetState: Codable {
        let visualState: PlayerVisualState
        let currentLanguage: String
        let lastLanguageChangeTime: Date?
        let streamMetadata: StreamProgramMetadata?
        /// Permanent error flag persisted in the snapshot so widget/LA chrome and
        /// loadSharedState can source it from the single authoritative blob.
        let hasError: Bool

        private enum CodingKeys: String, CodingKey {
            case visualState
            case currentLanguage
            case lastLanguageChangeTime
            case streamMetadata
            case hasError
        }

        init(
            visualState: PlayerVisualState,
            currentLanguage: String,
            lastLanguageChangeTime: Date? = nil,
            streamMetadata: StreamProgramMetadata? = nil,
            hasError: Bool = false
        ) {
            self.visualState = visualState
            self.currentLanguage = currentLanguage
            self.lastLanguageChangeTime = lastLanguageChangeTime
            self.streamMetadata = streamMetadata
            self.hasError = hasError
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            visualState = try container.decode(PlayerVisualState.self, forKey: .visualState)
            currentLanguage = try container.decode(String.self, forKey: .currentLanguage)
            lastLanguageChangeTime = try container.decodeIfPresent(Date.self, forKey: .lastLanguageChangeTime)
            streamMetadata = try container.decodeIfPresent(StreamProgramMetadata.self, forKey: .streamMetadata)
            // Resilient: pre-hasError snapshots decode as no error.
            hasError = try container.decodeIfPresent(Bool.self, forKey: .hasError) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(visualState, forKey: .visualState)
            try container.encode(currentLanguage, forKey: .currentLanguage)
            try container.encodeIfPresent(lastLanguageChangeTime, forKey: .lastLanguageChangeTime)
            try container.encodeIfPresent(streamMetadata, forKey: .streamMetadata)
            try container.encode(hasError, forKey: .hasError)
        }
    }

    /// Updates the in-process session snapshot (visual + language + metadata).
    ///
    /// **Disk no-op:** UserDefaults is never written. On-disk `persistedWidgetState` keys are
    /// actively cleared to enforce the memory-only policy across relaunches.
    internal func savePersistedWidgetState(
        visualState: PlayerVisualState,
        language: String,
        streamMetadata: StreamProgramMetadata? = nil,
        hasError: Bool = false
    ) {
        // Privacy gate (see persistWidgetSnapshot for rationale and hasActiveWidgets docs).
        // Allow widget process bypass (optimistic paths from intents may route here in future).
        guard Self.hasActiveWidgets || Self.isWidgetProcess() else {
            #if DEBUG
            print("[SharedPlayerManager] Suppressing savePersistedWidgetState (no active widgets — write suppression)")
            #endif
            return
        }

        let metadataToPersist = streamMetadata ?? currentStreamMetadata
        Self.updateInMemorySessionSnapshot(
            visualState: visualState,
            language: language,
            streamMetadata: metadataToPersist,
            hasError: hasError
        )

        // Emission after the authoritative in-session snapshot update.
        // Only emitted on main-app actor paths that reach a real write (privacy gate passed).
        emit(.persistedWidgetStateDidUpdate)
    }

    /// Loads the in-process session snapshot (memory-only; never reads UserDefaults).
    ///
    /// Primary reader for widget refresh derivation and in-session SSOT consumers.
    ///
    /// - Returns: The current session snapshot fields, or `nil` after cold launch / before any
    ///   in-session write. Callers must treat `nil` as "default to `.prePlay` + best initial language
    ///   + `hasError == false`".
    ///
    /// - Note: Calls ``clearPersistedVisualStateKeysFromDisk()`` before returning (upgrade hygiene).
    ///   Cross-process widget timelines see `nil` after relaunch (factory "Tap to Play" defaults).
    ///
    /// - SeeAlso: ``resetToFactoryDefaultsOnLaunch()``, ``clearPersistedVisualStateKeysFromDisk()``,
    ///   ``persistWidgetSnapshot(visualState:language:streamMetadata:clearStreamMetadata:hasError:)``,
    ///   ``loadPersistedVisualStateDirect()``, `loadSharedState()`,
    ///   CODING_AGENT.md (Single Source of Truth Principles).
    ///
    /// Thread-safety: nonisolated; safe from any widget/extension context. Sole canonical reader
    /// for ``inMemorySessionWidgetSnapshot`` — do not access that storage elsewhere.
    nonisolated static func loadPersistedWidgetState() -> (
        visualState: PlayerVisualState,
        currentLanguage: String,
        streamMetadata: StreamProgramMetadata?,
        hasError: Bool
    )? {
        clearPersistedVisualStateKeysFromDisk()

        guard let snapshot = unsafe inMemorySessionWidgetSnapshot else { return nil }
        let visual = sanitizedVisualStateForCrossProcessRestore(snapshot.visualState)
        return (visual, snapshot.currentLanguage, snapshot.streamMetadata, snapshot.hasError)
    }

    /// Returns the latest persisted stream program metadata, if any.
    nonisolated static func loadPersistedStreamMetadata() -> StreamProgramMetadata? {
        loadPersistedWidgetState()?.streamMetadata
    }

    /// Nonisolated static writer for the combined `PersistedWidgetState` snapshot.
    ///
    /// Primary writer used by:
    /// - Main-app `performActualSave` / `saveCurrentState` (authoritative path)
    /// - Widget intents (optimistic instant-feedback path)
    /// - `persistOptimisticWidgetSnapshot`
    ///
    /// The snapshot is the **single source of truth** for what widgets and Live
    /// Activities should display.
    ///
    /// - Parameters:
    ///   - visualState: The `PlayerVisualState` to persist (`.playing`, `.userPaused`, etc.).
    ///   - language: Current language code for the widget/LA.
    ///   - streamMetadata: Optional currently playing program metadata.
    ///   - clearStreamMetadata: When true, explicitly clears any prior metadata.
    ///   - hasError: Whether a permanent error condition should be shown.
    ///
    /// - Precondition: Must only be called on paths that have already performed
    ///   privacy gating via `hasActiveWidgets` (the method itself also guards).
    ///
    /// - Postcondition: In-process session snapshot updated (or suppressed if no widgets active).
    ///   UserDefaults visual keys are never written.
    ///
    /// - SeeAlso: ``loadPersistedWidgetState()``, ``savePersistedWidgetState``,
    ///   CODING_AGENT.md (SSOT section), `WidgetRefreshManager`.
    ///
    /// Thread-safety: nonisolated static facade; performs no actor hop.
    nonisolated static func persistWidgetSnapshot(
        visualState: PlayerVisualState,
        language: String,
        streamMetadata: StreamProgramMetadata? = nil,
        clearStreamMetadata: Bool = false,
        hasError: Bool = false
    ) {
        guard Self.hasActiveWidgets || Self.isWidgetProcess() else {
            if !Self.isWidgetProcess() {
                Self.refreshHasActiveWidgetsStatus()
            }
            #if DEBUG
            print("[SharedPlayerManager] Suppressing widget state write (no active widgets configured — write suppression)")
            #endif
            return
        }

        updateInMemorySessionSnapshot(
            visualState: visualState,
            language: language,
            streamMetadata: streamMetadata,
            hasError: hasError,
            clearStreamMetadata: clearStreamMetadata
        )
    }

    /// Convenience alias to the single-source hasActiveLutheranWidgets flag (WidgetRefreshManager).
    /// Used to gate all widget snapshot / optimistic / liveness / pending state writes.
    nonisolated static var hasActiveWidgets: Bool {
        WidgetRefreshManager.hasActiveLutheranWidgets
    }

    /// Fires a non-blocking re-query of WidgetCenter configs to update the privacy write gate.
    /// Safe to call from nonisolated static paths. Primary refresh points remain foreground + explicit clear.
    nonisolated static func refreshHasActiveWidgetsStatus() {
        Task { @MainActor in
            await WidgetRefreshManager.shared.refreshHasActiveWidgets()
        }
    }

    /// Preferred language for home-screen / Control widget chrome and privacy-gated paths.
    ///
    /// Resolution order (canonical):
    /// 1. In-process session snapshot (`PersistedWidgetState.currentLanguage`) when present.
    /// 2. When no snapshot and ``hasActiveWidgets`` is true: `DirectStreamingPlayer.bestInitialLanguageCode()`
    ///    (first supported stream matching `Locale.preferredLanguages`).
    /// 3. When no snapshot and no active widgets (or post-`clearAllLocalState`): hard `"en"`.
    ///
    /// **Privacy invariant:** With no home widgets configured, this path must not surface a
    /// stale App Group language signal. Bare `currentLanguage` is retired, purged by
    /// ``clearPersistedVisualStateKeysFromDisk()``, and is never read here.
    ///
    /// Live Activity language chrome must **not** use this helper — it reads
    /// ``ContentState.currentLanguage`` (main-app stream attach) and, for optimistic extension
    /// paths, ``languageForLiveActivityOrWidgetOptimistic()``.
    ///
    /// - SeeAlso: ``preferredMainAppInitialLanguageCode()``, ``loadPersistedWidgetState()``,
    ///   ``languageForLiveActivityOrWidgetOptimistic()``, ``clearPersistedVisualStateKeysFromDisk()``,
    ///   CODING_AGENT.md (Single Source of Truth Principles).
    nonisolated static func preferredWidgetLanguage() -> String {
        if let combined = loadPersistedWidgetState() {
            return combined.currentLanguage
        }
        if Self.hasActiveWidgets {
            return DirectStreamingPlayer.bestInitialLanguageCode()
        }
        // Privacy: no home widgets / post-clear → hard default; no App Group language read.
        return "en"
    }

    /// Preferred initial language for main-app UI (LanguageSelectorView needle, early cold-launch
    /// seeds, background images, post-clear cold-launch auto-play, etc.).
    ///
    /// Strongly prefers the last language from the PersistedWidgetState snapshot (so "last stream
    /// remembered" is reflected on resurrection / normal cold launch).
    ///
    /// When no snapshot (first-run, post-`clearAllLocalState`, or privacy-no-widgets case) falls back
    /// via `DirectStreamingPlayer.bestInitialLanguageCode()`, which walks `Locale.preferredLanguages`
    /// and picks the first supported radio stream (en/de/fi/sv/et) that matches the user's language
    /// preferences. This is the device locale reseed used for the post-clear / no-snapshot case.
    ///
    /// Distinct from ``preferredWidgetLanguage()``: the widget helper consults `hasActiveWidgets`
    /// for its no-snapshot fallback (`bestInitialLanguageCode` when writes are allowed; hard `"en"`
    /// otherwise). This helper is the main-app path that always prefers `bestInitialLanguageCode`
    /// when no session snapshot exists.
    nonisolated static func preferredMainAppInitialLanguageCode() -> String {
        if let combined = loadPersistedWidgetState() {
            return combined.currentLanguage
        }
        return DirectStreamingPlayer.bestInitialLanguageCode()
    }

    /// Facade over `DirectStreamingPlayer.streamForLanguageCode`.
    /// Returns the Stream for the given code, or the English default (first stream) if not found.
    /// Use this (instead of inline `availableStreams.first(where:...) ?? availableStreams[0]`)
    /// from both main app and widget extension code for a single source of the defaulting rule.
    nonisolated static func streamForLanguageCode(_ languageCode: String) -> DirectStreamingPlayer.Stream {
        DirectStreamingPlayer.streamForLanguageCode(languageCode)
    }

    /// Facade over `DirectStreamingPlayer.indexForLanguageCode`.
    /// Returns the index for the given code (suitable for LanguageSelectorView etc.), or 0 if not found.
    nonisolated static func indexForLanguageCode(_ languageCode: String) -> Int {
        DirectStreamingPlayer.indexForLanguageCode(languageCode)
    }

    #if LUTHERAN_MAIN_APP
    /// Persists the current stream metadata into the combined widget snapshot.
    func persistStreamMetadataForWidgets() {
        guard Self.hasActiveWidgets else {
            #if DEBUG
            print("[SharedPlayerManager] Suppressing persistStreamMetadataForWidgets (no active widgets — privacy mode)")
            #endif
            return
        }
        savePersistedWidgetState(
            visualState: currentVisualState,
            language: Self.preferredWidgetLanguage(),
            streamMetadata: currentStreamMetadata
        )
        Self.bumpWidgetLivenessTimestamp(policy: .immediate)
    }
    #endif

    /// Public entry point for language changes. Persists visual state + language together
    /// in the combined snapshot so widgets receive correct language without extra forcing.
    func saveCombinedWidgetState(language: String) {
        guard Self.hasActiveWidgets else {
            #if DEBUG
            print("[SharedPlayerManager] Suppressing saveCombinedWidgetState (no active widgets — write suppression)")
            #endif
            return
        }
        // Language change path: clear stale program metadata for the snapshot.
        // Uses the same helper as the Now-Playing-oriented clear to keep the nil-ing in one place.
        _clearIcyMetadataStash()
        savePersistedWidgetState(visualState: currentVisualState, language: language, streamMetadata: nil)

        // Bare App Group `currentLanguage` is retired (purged only). Liveness uses the
        // privacy-gated helper so residual heartbeats cannot reappear with the gate closed.
        Self.bumpWidgetLivenessTimestamp(policy: .immediate)
    }
}

