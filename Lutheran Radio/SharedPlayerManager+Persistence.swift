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
//  Purpose: In-process PersistedWidgetState session snapshot, privacy-gated home-widget
//  program-metadata App Group mirror, privacy-gated home live-chrome App Group mirror
//  (visual + language + hasError), retired App Group key purge, and thermal visual sanitization.
//
//  - SeeAlso: SharedPlayerManager.swift, docs/Home-Live-Chrome-App-Group-Mirror-Design.md,
//    CODING_AGENT.md (cross-target membership exceptions).
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
    /// `hasError`, bare `currentLanguage`, retired `lastUserPauseTime` (pause recovery is
    /// sticky ``PlaybackIntent`` only), retired `preferredVolume` (system volume is SSOT).
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
    ///   ``preferredWidgetLanguage()``, ``canProceedWithPlayback()``,
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
        let visualForWrite = Self.visualStateForPersistenceWrite(visualState)
        Self.updateInMemorySessionSnapshot(
            visualState: visualState,
            language: language,
            streamMetadata: metadataToPersist,
            hasError: hasError
        )
        // Cross-process program chrome: extension Providers read the privacy-gated mirror
        // because the session snapshot is process-local (OI-1 memory-only visual policy).
        Self.persistHomeWidgetStreamMetadataMirror(metadataToPersist)
        // Cross-process live chrome (visual + language + hasError): same privacy class as
        // program-metadata mirror. Projects session settle for extension Providers; identity
        // skip avoids App Group spam on attach-path identical Connecting storms.
        // Soft-resume honesty: product never mutates sticky `.userPaused` → `.prePlay` when
        // soft-resume eligible, so this projection holds pause chrome until setPlaying.
        Self.stampHomeWidgetLiveChromeFromSession(
            visualState: visualForWrite,
            language: language,
            hasError: hasError,
            reason: "sessionSave"
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
    ///
    /// ``updatedAt`` is the session last-write epoch (`lastLanguageChangeTime`) used by
    /// ``resolveHomeWidgetChromeFields`` when comparing session vs ``homeWidgetLiveChrome``
    /// freshness. `nil` when the snapshot has no timestamp.
    ///
    /// - SeeAlso: ``WidgetProviderSnapshotResolver/resolveFromSnapshot()``,
    ///   ``resolveHomeWidgetChromeFields(sessionVisual:sessionLanguage:sessionHasError:sessionUpdatedAt:liveChrome:)``.
    nonisolated static func loadPersistedWidgetState() -> (
        visualState: PlayerVisualState,
        currentLanguage: String,
        streamMetadata: StreamProgramMetadata?,
        hasError: Bool,
        updatedAt: TimeInterval?
    )? {
        clearPersistedVisualStateKeysFromDisk()

        guard let snapshot = unsafe inMemorySessionWidgetSnapshot else { return nil }
        let visual = sanitizedVisualStateForCrossProcessRestore(snapshot.visualState)
        return (
            visual,
            snapshot.currentLanguage,
            snapshot.streamMetadata,
            snapshot.hasError,
            snapshot.lastLanguageChangeTime?.timeIntervalSince1970
        )
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
    /// - `persistOptimisticWidgetSnapshot` / ``signalWidgetSwitchAction``
    ///
    /// The in-process session snapshot is the **process-local** SSOT for visual/language.
    /// Cross-process home/Control Providers also receive the privacy-gated
    /// ``homeWidgetLiveChrome`` projection stamped here (identity skip when unchanged).
    ///
    /// - Parameters:
    ///   - visualState: The `PlayerVisualState` to persist (`.playing`, `.userPaused`, etc.).
    ///   - language: Current language code for the widget/LA.
    ///   - streamMetadata: Optional currently playing program metadata.
    ///   - clearStreamMetadata: When true, explicitly clears any prior metadata.
    ///   - hasError: Whether a permanent error condition should be shown.
    ///   - liveChromeStampReason: Optional reason token for the live-chrome App Group stamp
    ///     (e.g. `"optimisticToggle"`, `"optimisticSwitch"`, `"persistSnapshot"`). Identity skip
    ///     ignores reason; main-app settle overwrites optimistic stamps when the gate is open.
    ///
    /// - Precondition: Must only be called on paths that have already performed
    ///   privacy gating via `hasActiveWidgets` (the method itself also guards; widget-process
    ///   bypass allows extension intent proof when the main gate is closed).
    ///
    /// - Postcondition: In-process session snapshot updated (or suppressed if no widgets active
    ///   on main). UserDefaults visual keys are never written. When the write is allowed,
    ///   ``stampHomeWidgetLiveChromeFromSession`` projects visual + language + hasError.
    ///
    /// - SeeAlso: ``loadPersistedWidgetState()``, ``savePersistedWidgetState``,
    ///   ``stampHomeWidgetLiveChromeFromSession(visualState:language:hasError:reason:)``,
    ///   ``WidgetProviderSnapshotResolver/resolveFromSnapshot()``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§5.3 extension optimistic),
    ///   CODING_AGENT.md (SSOT section), `WidgetRefreshManager`.
    ///
    /// Thread-safety: nonisolated static facade; performs no actor hop.
    nonisolated static func persistWidgetSnapshot(
        visualState: PlayerVisualState,
        language: String,
        streamMetadata: StreamProgramMetadata? = nil,
        clearStreamMetadata: Bool = false,
        hasError: Bool = false,
        liveChromeStampReason: String? = "persistSnapshot"
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

        let visualForWrite = visualStateForPersistenceWrite(visualState)
        updateInMemorySessionSnapshot(
            visualState: visualState,
            language: language,
            streamMetadata: streamMetadata,
            hasError: hasError,
            clearStreamMetadata: clearStreamMetadata
        )
        // Keep App Group program-metadata mirror aligned for extension Provider reads.
        if clearStreamMetadata {
            clearHomeWidgetStreamMetadataMirror()
        } else if let streamMetadata {
            persistHomeWidgetStreamMetadataMirror(streamMetadata)
        }
        // Project live chrome for home/Control Providers (privacy gate already passed above).
        // Extension optimistic intents use this path with reason optimisticToggle / optimisticSwitch;
        // main-app settle overwrites later. Identity skip avoids App Group spam.
        stampHomeWidgetLiveChromeFromSession(
            visualState: visualForWrite,
            language: language,
            hasError: hasError,
            reason: liveChromeStampReason
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

    // MARK: - Home-widget program metadata App Group mirror (privacy-gated)

    /// App Group key for the latest privacy-allowed program metadata used by home/Control Providers.
    ///
    /// Visual / playback chrome stay **memory-only** (OI-1). Program title and speaker are pure
    /// presentation strings from live ICY; the widget extension cannot observe main-app
    /// `PlayerEvent` or main-app RAM, so a privacy-gated App Group blob is required for
    /// honest medium/large program chrome after ICY parse.
    ///
    /// **Privacy:** Written only when ``hasActiveWidgets`` is true (or the call runs in a
    /// widget/extension process). Cleared when the gate closes, on privacy clear, language
    /// hygiene, and when ICY is cleared.
    ///
    /// - SeeAlso: ``persistHomeWidgetStreamMetadataMirror(_:)``, ``loadHomeWidgetStreamMetadataMirror()``,
    ///   ``clearHomeWidgetStreamMetadataMirror()``, ``persistStreamMetadataForWidgets()``,
    ///   ``WidgetProviderSnapshotResolver/resolveFromSnapshot()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md, docs/Widget-Presentation-Dataflow.md.
    nonisolated static let homeWidgetStreamMetadataAppGroupKey = "homeWidgetStreamMetadata"

    /// Writes the privacy-gated home-widget program-metadata mirror for cross-process Providers.
    ///
    /// - Parameter metadata: Parsed ICY program fields, or `nil` to clear the mirror.
    /// - Precondition: Home-widget privacy gate open **or** widget-process bypass (intent proof).
    /// - Postcondition: When allowed, App Group holds JSON for `metadata` (or key removed when `nil`).
    /// - SeeAlso: ``loadHomeWidgetStreamMetadataMirror()``, ``clearHomeWidgetStreamMetadataMirror()``,
    ///   ``persistStreamMetadataForWidgets()``, ``hasActiveWidgets``.
    nonisolated static func persistHomeWidgetStreamMetadataMirror(_ metadata: StreamProgramMetadata?) {
        guard Self.hasActiveWidgets || Self.isWidgetProcess() else {
            #if DEBUG
            print("[SharedPlayerManager] Suppressing home-widget stream-metadata mirror write (no active widgets — privacy mode)")
            #endif
            return
        }
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return }
        guard let metadata, metadata.hasDisplayableContent else {
            defaults.removeObject(forKey: homeWidgetStreamMetadataAppGroupKey)
            return
        }
        do {
            let data = try JSONEncoder().encode(metadata)
            defaults.set(data, forKey: homeWidgetStreamMetadataAppGroupKey)
        } catch {
            #if DEBUG
            print("[SharedPlayerManager] Failed to encode home-widget stream-metadata mirror: \(error.localizedDescription)")
            #endif
            defaults.removeObject(forKey: homeWidgetStreamMetadataAppGroupKey)
        }
    }

    /// Reads the privacy-gated home-widget program-metadata mirror, if present and well-formed.
    ///
    /// - Returns: Parsed ``StreamProgramMetadata``, or `nil` when missing/invalid (treat as no program chrome).
    /// - SeeAlso: ``persistHomeWidgetStreamMetadataMirror(_:)``,
    ///   ``WidgetProviderSnapshotResolver/resolveFromSnapshot()``.
    nonisolated static func loadHomeWidgetStreamMetadataMirror() -> StreamProgramMetadata? {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared"),
              let data = defaults.data(forKey: homeWidgetStreamMetadataAppGroupKey)
        else {
            return nil
        }
        return try? JSONDecoder().decode(StreamProgramMetadata.self, from: data)
    }

    /// Removes the home-widget program-metadata mirror (privacy gate close, privacy clear, ICY clear).
    ///
    /// - SeeAlso: ``persistHomeWidgetStreamMetadataMirror(_:)``,
    ///   ``WidgetRefreshManager/setHasActiveLutheranWidgets(_:)``,
    ///   ``removeAllLocalPlaybackKeys()``.
    nonisolated static func clearHomeWidgetStreamMetadataMirror() {
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return }
        defaults.removeObject(forKey: homeWidgetStreamMetadataAppGroupKey)
        #if DEBUG
        print("[SharedPlayerManager] Cleared home-widget stream-metadata mirror")
        #endif
    }

    // MARK: - Home live chrome App Group mirror (privacy-gated)

    /// App Group key for privacy-gated live home/Control chrome (visual + language + hasError).
    ///
    /// Parallel privacy class to ``homeWidgetStreamMetadataAppGroupKey``: written only while
    /// ``hasActiveWidgets`` (or widget-process bypass). Session-scoped projection for extension
    /// Providers — never cold-launch play resurrection (OI-1).
    ///
    /// - SeeAlso: ``persistHomeWidgetLiveChromeMirror(_:)``, ``loadHomeWidgetLiveChromeMirror()``,
    ///   ``clearHomeWidgetLiveChromeMirror()``, ``HomeWidgetLiveChrome``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md,
    ///   CODING_AGENT.md (Single Source of Truth Principles).
    ///
    /// AGENT NOTE: Single source of truth key name — any rename must update the App Group
    /// table in SharedPlayerManager.swift and the permanent design doc.
    nonisolated static let homeWidgetLiveChromeAppGroupKey = "homeWidgetLiveChrome"

    /// App Group integer epoch that forces home-widget **interactive LIVE** to re-evaluate paint.
    ///
    /// WidgetKit can keep a system-held TimelineEntry showing residual ``.playing`` (Toistaa /
    /// green pause) after App Group ``homeWidgetLiveChrome`` already holds ``.userPaused`` —
    /// same honesty class as Live Activity ContentState lag. ``LutheranRadioWidgetEntryView``
    /// observes this key via ``@AppStorage`` so body re-runs ``resolveFromSnapshot()`` after
    /// optimistic toggle / settle stamps, even when live-chrome **identity skip** would not
    /// rewrite the JSON blob (main-app sticky pause after extension already stamped).
    ///
    /// Not a paint SSOT — only a wake token. Chrome fields remain session + ``homeWidgetLiveChrome``.
    ///
    /// - SeeAlso: ``bumpHomeWidgetInteractivePaintEpoch()``, ``loadHomeWidgetInteractivePaintEpoch()``,
    ///   ``persistHomeWidgetLiveChromeMirror(_:)``,
    ///   ``WidgetIntentExecution/executeOptimisticToggle(plan:language:)``,
    ///   ``LutheranRadioWidgetEntryView``, docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§6).
    ///
    /// AGENT NOTE: Single source of truth key name — any rename must update the App Group table
    /// in SharedPlayerManager.swift and the entry-view ``@AppStorage`` binding.
    nonisolated static let homeWidgetInteractivePaintEpochAppGroupKey = "homeWidgetInteractivePaintEpoch"

    /// App Group string wake token combining epoch + visual + language for interactive LIVE paint.
    ///
    /// ``@AppStorage`` on an Int epoch alone is unreliable when WidgetKit holds an archived view
    /// or when the render process suite cache lags. A string signature changes on every chrome
    /// flip so SwiftUI dependencies re-fire when the suite is visible in-process, and Providers
    /// embed the same token into ``SimpleEntry/paintSignature`` for structural TimelineEntry identity.
    ///
    /// Wake only — never invent visual from this string alone.
    ///
    /// - SeeAlso: ``homeWidgetInteractivePaintEpochAppGroupKey``,
    ///   ``publishHomeWidgetInteractivePaintSignature(visualState:language:epoch:)``,
    ///   ``loadHomeWidgetInteractivePaintSignature()``,
    ///   ``LutheranRadioWidgetEntryView``.
    ///
    /// AGENT NOTE: Single source of truth key name — update App Group table + EntryView binding.
    nonisolated static let homeWidgetInteractivePaintSignatureAppGroupKey =
        "homeWidgetInteractivePaintSignature"

    /// Local ``NotificationCenter`` name posted when interactive paint wake tokens advance.
    ///
    /// Same-process companion to the Darwin paint-advanced name: ``@AppStorage`` does not
    /// always re-fire when the intent handler and LIVE render share a process but suite KVO
    /// is skipped. ``LutheranRadioWidgetEntryView`` listens and re-resolves from snapshot SSOT.
    ///
    /// - SeeAlso: ``homeWidgetInteractivePaintAdvancedDarwinName``,
    ///   ``postHomeWidgetInteractivePaintAdvancedWake()``,
    ///   ``LutheranRadioWidgetEntryView``.
    nonisolated static let homeWidgetInteractivePaintAdvancedNotification =
        Notification.Name("radio.lutheran.homeWidgetInteractivePaintAdvanced")

    /// Darwin notify name for cross-process interactive home paint wake.
    ///
    /// Posted from ``bumpHomeWidgetInteractivePaintEpoch(reason:)`` so a main-app settle
    /// (soft-resume ``.playing`` stamp) can re-evaluate extension LIVE without relying on
    /// suite ``@AppStorage`` KVO across processes. Peer to ``radio.lutheran.widget.action``.
    ///
    /// - SeeAlso: ``homeWidgetInteractivePaintAdvancedNotification``,
    ///   ``postHomeWidgetInteractivePaintAdvancedWake()``,
    ///   ``registerHomeWidgetInteractivePaintWakeObserverIfNeeded()``.
    nonisolated static let homeWidgetInteractivePaintAdvancedDarwinName =
        "radio.lutheran.homeWidget.interactivePaintAdvanced"

    /// Increments the interactive paint epoch so LIVE home entry views re-resolve from snapshot SSOT.
    ///
    /// - Parameter reason: Optional DEBUG label (e.g. `"optimisticToggle"`, `"liveChromeWrite"`).
    /// - Postcondition: App Group epoch is strictly greater than before (wrapping at `Int.max`);
    ///   suite is flushed for cross-process ``@AppStorage`` visibility; paint signature is
    ///   republished from current live chrome when present; local + Darwin paint-advanced wakes fire.
    /// - SeeAlso: ``homeWidgetInteractivePaintEpochAppGroupKey``,
    ///   ``loadHomeWidgetInteractivePaintEpoch()``,
    ///   ``publishHomeWidgetInteractivePaintSignature(visualState:language:epoch:)``,
    ///   ``postHomeWidgetInteractivePaintAdvancedWake()``,
    ///   ``WidgetIntentExecution/executeOptimisticToggle(plan:language:)``.
    nonisolated static func bumpHomeWidgetInteractivePaintEpoch(reason: String? = nil) {
        let suite = "group.radio.lutheran.shared"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        // Re-sync before read so concurrent extension/main writers do not lose increments.
        CFPreferencesAppSynchronize(suite as CFString)
        defaults.synchronize()
        let next = defaults.integer(forKey: homeWidgetInteractivePaintEpochAppGroupKey) &+ 1
        defaults.set(next, forKey: homeWidgetInteractivePaintEpochAppGroupKey)
        // Publish signature with best-known chrome so @AppStorage String observers always flip.
        if let chrome = loadHomeWidgetLiveChromeMirrorWithoutResync() {
            publishHomeWidgetInteractivePaintSignature(
                visualState: chrome.visualState,
                language: chrome.currentLanguage,
                epoch: next,
                postPaintWake: false
            )
        } else {
            defaults.set("\(next)|unknown|", forKey: homeWidgetInteractivePaintSignatureAppGroupKey)
        }
        defaults.synchronize()
        CFPreferencesAppSynchronize(suite as CFString)
        // Suite tokens alone do not re-run LIVE in another process instance; post wake after flush.
        postHomeWidgetInteractivePaintAdvancedWake()
        #if DEBUG
        if let reason {
            print("[SharedPlayerManager] Bumped home-widget interactive paint epoch → \(next) (\(reason))")
        }
        #endif
    }

    /// Current interactive paint epoch from the App Group suite (0 when absent).
    ///
    /// - Returns: Integer observed by ``LutheranRadioWidgetEntryView`` / tests.
    /// - SeeAlso: ``bumpHomeWidgetInteractivePaintEpoch(reason:)``.
    nonisolated static func loadHomeWidgetInteractivePaintEpoch() -> Int {
        let suite = "group.radio.lutheran.shared"
        CFPreferencesAppSynchronize(suite as CFString)
        guard let defaults = UserDefaults(suiteName: suite) else { return 0 }
        defaults.synchronize()
        if let cfValue = CFPreferencesCopyAppValue(
            homeWidgetInteractivePaintEpochAppGroupKey as CFString,
            suite as CFString
        ) as? NSNumber {
            return cfValue.intValue
        }
        return defaults.integer(forKey: homeWidgetInteractivePaintEpochAppGroupKey)
    }

    /// Current interactive paint signature from the App Group suite (empty when absent).
    ///
    /// - Returns: Wake string embedded in ``SimpleEntry/paintSignature`` / observed via ``@AppStorage``.
    /// - SeeAlso: ``publishHomeWidgetInteractivePaintSignature(visualState:language:epoch:)``,
    ///   ``loadHomeWidgetInteractivePaintEpoch()``.
    nonisolated static func loadHomeWidgetInteractivePaintSignature() -> String {
        let suite = "group.radio.lutheran.shared"
        CFPreferencesAppSynchronize(suite as CFString)
        guard let defaults = UserDefaults(suiteName: suite) else { return "" }
        defaults.synchronize()
        if let cfValue = CFPreferencesCopyAppValue(
            homeWidgetInteractivePaintSignatureAppGroupKey as CFString,
            suite as CFString
        ) as? String {
            return cfValue
        }
        return defaults.string(forKey: homeWidgetInteractivePaintSignatureAppGroupKey) ?? ""
    }

    /// Builds the stable paint-signature string (epoch + visual token + language).
    ///
    /// - Parameters:
    ///   - visualState: Chrome visual projected into the signature (wake identity only).
    ///   - language: Stream language code.
    ///   - epoch: Current paint epoch integer.
    /// - Returns: Signature string for App Group / ``SimpleEntry`` identity (not a paint SSOT).
    /// - SeeAlso: ``HomeWidgetLiveChrome/stableToken(for:)``.
    nonisolated static func makeHomeWidgetInteractivePaintSignature(
        visualState: PlayerVisualState,
        language: String,
        epoch: Int
    ) -> String {
        "\(epoch)|\(HomeWidgetLiveChrome.stableToken(for: visualState))|\(language)"
    }

    /// Writes the interactive paint signature string for LIVE ``@AppStorage`` / entry identity.
    ///
    /// - Parameters:
    ///   - visualState: Chrome visual projected into the signature (wake identity only).
    ///   - language: Stream language code.
    ///   - epoch: Current paint epoch integer.
    ///   - postPaintWake: When `true` (default), posts local + Darwin paint-advanced wake after flush.
    ///     Pass `false` when the caller already posts via ``bumpHomeWidgetInteractivePaintEpoch``.
    /// - SeeAlso: ``homeWidgetInteractivePaintSignatureAppGroupKey``,
    ///   ``bumpHomeWidgetInteractivePaintEpoch(reason:)``,
    ///   ``postHomeWidgetInteractivePaintAdvancedWake()``.
    nonisolated static func publishHomeWidgetInteractivePaintSignature(
        visualState: PlayerVisualState,
        language: String,
        epoch: Int,
        postPaintWake: Bool = true
    ) {
        let suite = "group.radio.lutheran.shared"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        let signature = makeHomeWidgetInteractivePaintSignature(
            visualState: visualState,
            language: language,
            epoch: epoch
        )
        defaults.set(signature, forKey: homeWidgetInteractivePaintSignatureAppGroupKey)
        defaults.synchronize()
        CFPreferencesAppSynchronize(suite as CFString)
        if postPaintWake {
            postHomeWidgetInteractivePaintAdvancedWake()
        }
    }

    /// Posts local ``NotificationCenter`` + Darwin paint-advanced wake for interactive LIVE re-eval.
    ///
    /// **Why both:** Same-process optimistic intent may not flip suite ``@AppStorage`` KVO; local
    /// NC re-runs the LIVE body immediately. Main-app settle stamps run in another process —
    /// Darwin is the cross-process peer to ``radio.lutheran.widget.action``. Not a WidgetCenter
    /// thrash path (no extra ``reloadAllTimelines``).
    ///
    /// - SeeAlso: ``homeWidgetInteractivePaintAdvancedNotification``,
    ///   ``homeWidgetInteractivePaintAdvancedDarwinName``,
    ///   ``registerHomeWidgetInteractivePaintWakeObserverIfNeeded()``,
    ///   ``bumpHomeWidgetInteractivePaintEpoch(reason:)``.
    nonisolated static func postHomeWidgetInteractivePaintAdvancedWake() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(homeWidgetInteractivePaintAdvancedDarwinName as CFString),
            nil,
            nil,
            true
        )
        NotificationCenter.default.post(
            name: homeWidgetInteractivePaintAdvancedNotification,
            object: nil
        )
    }

    /// Registers a process-lifetime Darwin observer that forwards paint-advanced wakes to local NC.
    ///
    /// Safe to call repeatedly (idempotent). ``LutheranRadioWidgetEntryView`` registers once so
    /// main-app suite stamps can re-evaluate extension LIVE without suite KVO.
    ///
    /// - SeeAlso: ``postHomeWidgetInteractivePaintAdvancedWake()``,
    ///   ``homeWidgetInteractivePaintAdvancedDarwinName``.
    nonisolated static func registerHomeWidgetInteractivePaintWakeObserverIfNeeded() {
        paintWakeObserverRegistrationLock.lock()
        defer { paintWakeObserverRegistrationLock.unlock() }
        // SAFETY: `nonisolated(unsafe)` flag is mutated only under
        // ``paintWakeObserverRegistrationLock``; SE-0458 requires `unsafe` on each access.
        guard unsafe !paintWakeObserverRegistered else { return }
        unsafe paintWakeObserverRegistered = true

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        // SAFETY: Process-lifetime Darwin observer with a stable static NSObject as the opaque
        // context (``paintWakeObserverToken``). Callback is a non-capturing C function
        // (``homeWidgetInteractivePaintAdvancedDarwinCallback``) that only hops to main and posts
        // NotificationCenter — no retain of widget views or actors. High-level Darwin API is
        // not available for this wake path. Matches the CF Darwin pattern used for
        // ``radio.lutheran.widget.action``.
        let observer = unsafe Unmanaged.passUnretained(paintWakeObserverToken).toOpaque()
        unsafe CFNotificationCenterAddObserver(
            center,
            observer,
            homeWidgetInteractivePaintAdvancedDarwinCallback,
            homeWidgetInteractivePaintAdvancedDarwinName as CFString,
            nil,
            .deliverImmediately
        )
    }

    /// Opaque CF Darwin observer identity for paint-advanced wakes (process lifetime).
    ///
    /// `@unchecked Sendable` so the process-lifetime static can be `nonisolated` (not
    /// `nonisolated(unsafe)`) and still reachable from nonisolated CF registration. CF holds
    /// an unretained pointer only.
    private final class HomeWidgetPaintWakeObserverToken: NSObject, @unchecked Sendable {}
    // SAFETY: Immutable process-lifetime registration identity; never mutated after init; CF
    // holds an unretained opaque pointer only (no ownership transfer). `nonisolated` (not
    // `nonisolated(unsafe)`) because the type is Sendable — SE-0458 flags unnecessary unsafe
    // on Sendable constants.
    nonisolated private static let paintWakeObserverToken = HomeWidgetPaintWakeObserverToken()
    // SAFETY: Boolean guarded by ``paintWakeObserverRegistrationLock``; no other concurrent readers.
    nonisolated(unsafe) private static var paintWakeObserverRegistered = false
    nonisolated private static let paintWakeObserverRegistrationLock = NSLock()

    /// Loads live chrome without an extra suite re-sync (caller already synchronized).
    ///
    /// Used by epoch bump to attach visual/language to the paint signature without recursion.
    nonisolated private static func loadHomeWidgetLiveChromeMirrorWithoutResync() -> HomeWidgetLiveChrome? {
        let suite = "group.radio.lutheran.shared"
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        let data: Data?
        if let cfValue = CFPreferencesCopyAppValue(
            homeWidgetLiveChromeAppGroupKey as CFString,
            suite as CFString
        ) as? Data {
            data = cfValue
        } else {
            data = defaults.data(forKey: homeWidgetLiveChromeAppGroupKey)
        }
        guard let data,
              let chrome = try? JSONDecoder().decode(HomeWidgetLiveChrome.self, from: data),
              !chrome.currentLanguage.isEmpty
        else {
            return nil
        }
        return chrome
    }

    /// Writes the privacy-gated home live-chrome mirror for cross-process Providers.
    ///
    /// - Parameter chrome: Live visual + language + hasError payload, or `nil` to clear.
    /// - Precondition: Home-widget privacy gate open **or** widget-process bypass (intent proof).
    /// - Postcondition: When allowed, App Group holds JSON for `chrome` (or key removed when `nil`
    ///   / empty language). When the gate is closed on the main app, **no** key is written.
    ///   Extension process under ``shouldDistrustDurableMirrorPlayPlanning()`` refuses to stamp
    ///   ``.playing`` (must not re-project residual “still playing” chrome after terminate/reboot).
    ///   Successful write/clear also bumps ``homeWidgetInteractivePaintEpochAppGroupKey``.
    /// - SeeAlso: ``loadHomeWidgetLiveChromeMirror()``, ``clearHomeWidgetLiveChromeMirror()``,
    ///   ``bumpHomeWidgetInteractivePaintEpoch(reason:)``,
    ///   ``shouldDistrustDurableMirrorPlayPlanning()``,
    ///   ``persistHomeWidgetStreamMetadataMirror(_:)`` (privacy-class peer),
    ///   ``HomeWidgetLiveChrome``, docs/Home-Live-Chrome-App-Group-Mirror-Design.md.
    nonisolated static func persistHomeWidgetLiveChromeMirror(_ chrome: HomeWidgetLiveChrome?) {
        guard Self.hasActiveWidgets || Self.isWidgetProcess() else {
            #if DEBUG
            print("[SharedPlayerManager] Suppressing home-widget live-chrome mirror write (no active widgets — privacy mode)")
            #endif
            return
        }
        // Extension must not re-stamp residual “playing” chrome after terminate/reboot while
        // Provider paint already treats the mirror as absent. Main-app stamps remain allowed
        // (live process on this boot after factory / recorded boot identity).
        if let chrome,
           chrome.visualState == .playing,
           Self.isWidgetProcess(),
           Self.shouldDistrustDurableMirrorPlayPlanning() {
            #if DEBUG
            print("[SharedPlayerManager] Suppressing extension home-widget live-chrome .playing stamp under terminate/reboot distrust")
            #endif
            return
        }
        guard let defaults = UserDefaults(suiteName: "group.radio.lutheran.shared") else { return }
        guard let chrome, !chrome.currentLanguage.isEmpty else {
            defaults.removeObject(forKey: homeWidgetLiveChromeAppGroupKey)
            // Flush clear so Provider / interactive paint heal in another extension process
            // cannot re-read residual chrome after privacy / factory wipe.
            defaults.synchronize()
            bumpHomeWidgetInteractivePaintEpoch(reason: "liveChromeClear")
            return
        }
        do {
            let data = try JSONEncoder().encode(chrome)
            defaults.set(data, forKey: homeWidgetLiveChromeAppGroupKey)
            // Flush optimistic / settle stamps before WidgetCenter reload. Intent perform and
            // Provider/timeline render may run in different extension process instances; without
            // a suite flush, interactive LIVE can re-resolve a lagging ``.playing`` residual while
            // this process already holds ``.userPaused`` (interactive LIVE residual-playing class).
            defaults.synchronize()
            CFPreferencesAppSynchronize("group.radio.lutheran.shared" as CFString)
            bumpHomeWidgetInteractivePaintEpoch(reason: "liveChromeWrite")
            // Authoritative signature from the chrome just written; bump already posted wake.
            publishHomeWidgetInteractivePaintSignature(
                visualState: chrome.visualState,
                language: chrome.currentLanguage,
                epoch: loadHomeWidgetInteractivePaintEpoch(),
                postPaintWake: false
            )
        } catch {
            #if DEBUG
            print("[SharedPlayerManager] Failed to encode home-widget live-chrome mirror: \(error.localizedDescription)")
            #endif
            defaults.removeObject(forKey: homeWidgetLiveChromeAppGroupKey)
            defaults.synchronize()
            bumpHomeWidgetInteractivePaintEpoch(reason: "liveChromeEncodeFailure")
        }
    }

    /// Reads the privacy-gated home live-chrome mirror, if present and well-formed.
    ///
    /// Forces a cross-process preference-domain re-sync (``CFPreferencesAppSynchronize`` + suite
    /// ``synchronize()``) and prefers ``CFPreferencesCopyAppValue`` so a Provider / interactive
    /// entry heal does not paint residual ``.playing`` from a stale per-process UserDefaults
    /// cache after another process stamped ``.userPaused`` (interactive LIVE residual-playing class).
    ///
    /// - Returns: Parsed ``HomeWidgetLiveChrome``, or `nil` when missing, decode fails
    ///   (including unknown visual token), or language is empty (treat as absent → factory path).
    /// - SeeAlso: ``persistHomeWidgetLiveChromeMirror(_:)``, ``clearHomeWidgetLiveChromeMirror()``,
    ///   ``HomeWidgetLiveChrome``, docs/Home-Live-Chrome-App-Group-Mirror-Design.md.
    nonisolated static func loadHomeWidgetLiveChromeMirror() -> HomeWidgetLiveChrome? {
        let suite = "group.radio.lutheran.shared"
        // Cross-process re-sync: interactive heal and Provider resolve must not paint residual
        // ``.playing`` from a stale suite RAM cache after another process stamped ``.userPaused``.
        CFPreferencesAppSynchronize(suite as CFString)
        guard let defaults = UserDefaults(suiteName: suite) else {
            return nil
        }
        defaults.synchronize()
        let data: Data?
        if let cfValue = CFPreferencesCopyAppValue(
            homeWidgetLiveChromeAppGroupKey as CFString,
            suite as CFString
        ) as? Data {
            data = cfValue
        } else {
            data = defaults.data(forKey: homeWidgetLiveChromeAppGroupKey)
        }
        guard let data else { return nil }
        guard let chrome = try? JSONDecoder().decode(HomeWidgetLiveChrome.self, from: data),
              !chrome.currentLanguage.isEmpty
        else {
            return nil
        }
        return chrome
    }

    /// Removes the home live-chrome mirror (privacy gate close, privacy clear, factory residual, terminate).
    ///
    /// - SeeAlso: ``persistHomeWidgetLiveChromeMirror(_:)``,
    ///   ``bumpHomeWidgetInteractivePaintEpoch(reason:)``,
    ///   ``WidgetRefreshManager/setHasActiveLutheranWidgets(_:)``,
    ///   ``removeAllLocalPlaybackKeys()``, ``forceStaleLivenessTimestampForTermination()``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§7 privacy clear matrix).
    nonisolated static func clearHomeWidgetLiveChromeMirror() {
        let suite = "group.radio.lutheran.shared"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defaults.removeObject(forKey: homeWidgetLiveChromeAppGroupKey)
        defaults.removeObject(forKey: homeWidgetInteractivePaintEpochAppGroupKey)
        defaults.removeObject(forKey: homeWidgetInteractivePaintSignatureAppGroupKey)
        defaults.synchronize()
        CFPreferencesAppSynchronize(suite as CFString)
        #if DEBUG
        print("[SharedPlayerManager] Cleared home-widget live-chrome mirror")
        #endif
    }

    /// Builds and persists live chrome from session fields when the privacy gate allows.
    ///
    /// Convenience writer for main-app stamp sites (sticky pause, setPlaying, switch hold,
    /// session save projection) **and** extension optimistic intent projection (via
    /// ``persistWidgetSnapshot`` / ``persistOptimisticWidgetSnapshot`` /
    /// ``signalWidgetSwitchAction``). Sets `updatedAt` to now. No-ops when the main-app gate is
    /// closed (same suppression as ``persistHomeWidgetLiveChromeMirror(_:)``); widget-process
    /// bypass remains for intent proof.
    ///
    /// **Identity skip:** When visual + language + hasError already match the App Group mirror,
    /// the write is skipped (``shouldSkipIdenticalHomeWidgetLiveChromeWrite``) so attach-path
    /// Connecting storms, identical session saves, and repeated optimistic stamps do not spam
    /// UserDefaults. Definitive control visuals (``.userPaused`` **and** ``.playing``) still bump
    /// paint epoch + signature (``liveChromeIdentitySkipWake``) so interactive LIVE can re-resolve
    /// after main settle when extension already stamped the same chrome — without force-rewriting
    /// the JSON blob (sticky rewrite + dual WidgetCenter wakes thrashed residual LIVE without
    /// healing it). Connecting identity skips stay quiet.
    ///
    /// **Soft-resume honesty (main app):** Callers must pass the **actual** session visual.
    /// Product soft-resume retains sticky ``.userPaused`` until ``setPlaying()``; do not invent
    /// intermediate ``.prePlay`` on the main settle path. Extension optimistic **home** play
    /// stamps ``optimisticHomeWidgetVisualAfterPlayPlan`` (sticky pause or Connecting — never
    /// invent home ``.playing``). ``optimisticVisualAfterPlayPlan`` is the LA / media dual-tap
    /// helper and is not this home-chrome writer’s play plan.
    ///
    /// - Parameters:
    ///   - visualState: Presentation visual to project (never invent mid-hold ``.playing`` beyond
    ///     pure planners).
    ///   - language: Stream language code (empty language clears the mirror when gate open).
    ///   - hasError: Permanent-error chrome flag.
    ///   - reason: Optional stamp reason for DEBUG / future coalesce (e.g. `"stickyPause"`,
    ///     `"setPlaying"`, `"switchHold"`, `"sessionSave"`, `"privacyGateOpen"`,
    ///     `"optimisticToggle"`, `"optimisticSwitch"`, `"persistSnapshot"`).
    /// - SeeAlso: ``persistHomeWidgetLiveChromeMirror(_:)``,
    ///   ``shouldSkipIdenticalHomeWidgetLiveChromeWrite(existing:candidate:)``,
    ///   ``restampHomeWidgetLiveChromeAfterPrivacyGateOpenIfNeeded()``,
    ///   ``WidgetProviderSnapshotResolver/resolveFromSnapshot()``,
    ///   ``persistHomeWidgetStreamMetadataMirror(_:)`` (privacy-class peer),
    ///   ``PlayerVisualState/optimisticHomeWidgetVisualAfterPlayPlan``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§4, §5.2–§5.3, §6, §9).
    nonisolated static func stampHomeWidgetLiveChromeFromSession(
        visualState: PlayerVisualState,
        language: String,
        hasError: Bool,
        reason: String? = nil
    ) {
        let chrome = HomeWidgetLiveChrome(
            visualState: visualState,
            currentLanguage: language,
            hasError: hasError,
            updatedAt: Date().timeIntervalSince1970,
            stampReason: reason
        )
        if shouldSkipIdenticalHomeWidgetLiveChromeWrite(
            existing: loadHomeWidgetLiveChromeMirror(),
            candidate: chrome
        ) {
            #if DEBUG
            print("[SharedPlayerManager] Skipping identical home-widget live-chrome stamp (visual=\(visualState), lang=\(language))")
            #endif
            // Identity skip omits a second JSON write (and its liveChromeWrite epoch bump).
            // Main sticky pause after extension optimistic ``.userPaused``, and main soft-resume
            // ``.playing`` after an earlier identical stamp, both hit this path. Wake interactive
            // LIVE via epoch + signature + Darwin/local NC only — do **not** force rewrite the
            // chrome blob or call ``reloadAllTimelines`` (WidgetCenter thrash without healing
            // residual LIVE). Connecting identity skips stay quiet (attach storms).
            if visualState.isDefinitiveMediaToggleVisual {
                // ``bumpHomeWidgetInteractivePaintEpoch`` republishes signature from chrome and
                // posts paint-advanced wake — no second publish needed.
                bumpHomeWidgetInteractivePaintEpoch(reason: "liveChromeIdentitySkipWake")
            }
            return
        }
        persistHomeWidgetLiveChromeMirror(chrome)
    }

    #if LUTHERAN_MAIN_APP
    /// Persists the current stream metadata into the combined widget snapshot **and** the
    /// privacy-gated App Group program-metadata mirror for extension Providers.
    ///
    /// - Precondition: ``hasActiveWidgets`` is true (method returns early otherwise).
    /// - Postcondition: In-process session snapshot carries ``currentStreamMetadata``; App Group
    ///   mirror matches when the gate remains open.
    /// - SeeAlso: ``didUpdateStreamMetadata(_:)``,
    ///   ``restampHomeWidgetProgramMetadataAfterPrivacyGateOpenIfNeeded()``,
    ///   ``persistHomeWidgetStreamMetadataMirror(_:)``.
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
        // Explicit mirror stamp (save path also syncs) so ICY→home stays one call site.
        Self.persistHomeWidgetStreamMetadataMirror(currentStreamMetadata)
        Self.bumpWidgetLivenessTimestamp(policy: .immediate)
    }

    /// Re-stamps in-memory ICY program metadata into the session snapshot + App Group mirror
    /// after the home-widget privacy write gate opens (false → true).
    ///
    /// **Why:** ICY often arrives while `hasActiveWidgets == false` (persist suppressed). Live
    /// Activity still receives in-memory ``updateCurrentActivity``. Identical subsequent ICY is a
    /// no-op in ``didUpdateStreamMetadata(_:)``, so home widgets never receive program fields
    /// unless this handoff re-stamps once when widgets appear.
    ///
    /// - Precondition: Caller has already opened the privacy gate (``hasActiveWidgets`` true).
    /// - Postcondition: When ``currentStreamMetadata`` is displayable, session + mirror carry it
    ///   and ``PlayerEvent/persistedWidgetStateDidUpdate`` is emitted; otherwise no-op.
    /// - Important: Does **not** invent catalog titles; does **not** write when the gate is closed.
    /// - SeeAlso: ``persistStreamMetadataForWidgets()``,
    ///   ``restampHomeWidgetLiveChromeAfterPrivacyGateOpenIfNeeded()``,
    ///   ``WidgetRefreshManager/setHasActiveLutheranWidgets(_:)``,
    ///   ``didUpdateStreamMetadata(_:)``, docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    ///
    /// AGENT NOTE: Sole handoff for privacy→write program-metadata honesty. Keep gated on
    /// ``hasActiveWidgets`` and non-nil in-memory ICY only.
    func restampHomeWidgetProgramMetadataAfterPrivacyGateOpenIfNeeded() {
        guard Self.hasActiveWidgets else { return }
        guard let metadata = currentStreamMetadata, metadata.hasDisplayableContent else {
            #if DEBUG
            print("[SharedPlayerManager] Privacy gate open — no in-memory program metadata to re-stamp")
            #endif
            return
        }
        #if DEBUG
        print("[SharedPlayerManager] Privacy gate open — re-stamping in-memory program metadata for home widgets")
        #endif
        persistStreamMetadataForWidgets()
    }

    /// Re-stamps main-app session visual + language + hasError into the privacy-gated live-chrome
    /// App Group mirror after the home-widget write gate opens (false → true).
    ///
    /// **Why:** While ``hasActiveWidgets`` is false, main-app sticky pause / setPlaying / switch
    /// saves suppress App Group writes. Actor memory still holds honest chrome. When the user
    /// installs a home widget mid-session, Providers need one projection of that chrome without
    /// waiting for the next settle mutation.
    ///
    /// - Precondition: Caller has already opened the privacy gate (``hasActiveWidgets`` true).
    /// - Postcondition: When session has non-factory displayable chrome, ``homeWidgetLiveChrome``
    ///   carries actor visual + resolved language + hasError (identity skip OK if already aligned).
    /// - Important: Projects **actor** ``currentVisualState`` — never invents ``.playing`` during
    ///   stream-switch Connecting hold (``.prePlay`` + destination language). Soft-resume residual
    ///   sticky ``.userPaused`` is preserved until a later ``setPlaying()`` save.
    /// - Important: Pure factory cold-launch (``.prePlay``, no session, no hold, no active/paused
    ///   intent) is a no-op so gate open does not seed residual chrome.
    /// - SeeAlso: ``stampHomeWidgetLiveChromeFromSession(visualState:language:hasError:reason:)``,
    ///   ``restampHomeWidgetProgramMetadataAfterPrivacyGateOpenIfNeeded()`` (privacy-class peer),
    ///   ``WidgetRefreshManager/setHasActiveLutheranWidgets(_:)``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§5.5, §7).
    ///
    /// AGENT NOTE: Sole handoff for privacy→write live-chrome honesty. Keep gated on
    /// ``hasActiveWidgets`` and non-factory session chrome only.
    func restampHomeWidgetLiveChromeAfterPrivacyGateOpenIfNeeded() {
        guard Self.hasActiveWidgets else { return }

        let visual = Self.visualStateForPersistenceWrite(currentVisualState)
        let session = Self.loadPersistedWidgetState()
        let language: String = {
            if let pending = streamSwitchConnectingLanguageCode, !pending.isEmpty {
                return pending
            }
            if let sessionLanguage = session?.currentLanguage, !sessionLanguage.isEmpty {
                return sessionLanguage
            }
            let model = DirectStreamingPlayer.shared.selectedStream.languageCode
            if !model.isEmpty {
                return model
            }
            return Self.preferredWidgetLanguage()
        }()
        guard !language.isEmpty else {
            #if DEBUG
            print("[SharedPlayerManager] Privacy gate open — empty language; skipping live-chrome re-stamp")
            #endif
            return
        }

        let hasError = session?.hasError ?? false
        let isNonFactory =
            visual != .prePlay
            || holdPrePlayVisualUntilPlayback
            || hasError
            || session != nil
            || currentPlaybackIntent.isActivePlaybackIntent
            || currentPlaybackIntent == .userPaused
            || currentVisualState == .userPaused

        guard isNonFactory else {
            #if DEBUG
            print("[SharedPlayerManager] Privacy gate open — no non-factory live chrome to re-stamp")
            #endif
            return
        }

        #if DEBUG
        print("[SharedPlayerManager] Privacy gate open — re-stamping live chrome (visual=\(visual), lang=\(language))")
        #endif
        Self.stampHomeWidgetLiveChromeFromSession(
            visualState: visual,
            language: language,
            hasError: hasError,
            reason: "privacyGateOpen"
        )
    }
    #endif

    /// Explicit destination-language snapshot write for stream/language switch paths.
    ///
    /// Persists **current** visual state together with the given language code so widgets and
    /// session readers see the destination language without inventing `.prePlay` (paused switches
    /// keep sticky `.userPaused` chrome). Also projects privacy-gated ``homeWidgetLiveChrome``
    /// (visual + destination language) via ``savePersistedWidgetState``. Privacy-gated: no write
    /// when `!hasActiveWidgets`.
    ///
    /// **Ordering:** Stream-switch orchestrators await this via
    /// ``RadioPlayerCoordinator/updateUserDefaultsLanguage(_:)`` **before** media-surface refresh
    /// or other ``saveCurrentState()`` work. Do not wrap this call in a fire-and-forget `Task` as
    /// the sole destination-language writer — concurrent ``saveCurrentState()`` can re-resolve from
    /// a lagging preferred/snapshot and persist the prior code last.
    ///
    /// - Parameter language: Destination stream language code (e.g. after `switchToStream`).
    /// - Postcondition: When the privacy gate allows, in-process session snapshot language equals
    ///   `language`, live-chrome mirror projects current visual + destination language (identity
    ///   skip OK), and ``PlayerEvent/persistedWidgetStateDidUpdate`` has been emitted.
    /// - SeeAlso: ``saveCurrentState()``, ``savePersistedWidgetState(visualState:language:streamMetadata:hasError:)``,
    ///   ``stampHomeWidgetLiveChromeFromSession(visualState:language:hasError:reason:)``,
    ///   ``RadioPlayerCoordinator/updateUserDefaultsLanguage(_:)``,
    ///   ``PersistedLanguageResolution``,
    ///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§5.2 switch, §5.4),
    ///   CODING_AGENT.md (Single Source of Truth Principles).
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

        // Destination already stamped with matching visual + cleared metadata → no second write.
        // First switch still writes when language differs or prior metadata remains.
        // Still project live chrome (identity skip when mirror already matches) so a residual
        // clear of `homeWidgetLiveChrome` alone cannot leave session language without paint payload.
        if let previous = Self.loadPersistedWidgetState(),
           previous.currentLanguage == language,
           previous.visualState == currentVisualState,
           previous.streamMetadata == nil,
           previous.hasError == false {
            Self.stampHomeWidgetLiveChromeFromSession(
                visualState: Self.visualStateForPersistenceWrite(currentVisualState),
                language: language,
                hasError: false,
                reason: "saveCombinedAlreadyStamped"
            )
            Self.bumpWidgetLivenessTimestamp(policy: .immediate)
            #if DEBUG
            print("[SharedPlayerManager] saveCombinedWidgetState: destination already stamped — skipping persist")
            #endif
            return
        }

        savePersistedWidgetState(visualState: currentVisualState, language: language, streamMetadata: nil)

        // Bare App Group `currentLanguage` is retired (purged only). Liveness uses the
        // privacy-gated helper so residual heartbeats cannot reappear with the gate closed.
        Self.bumpWidgetLivenessTimestamp(policy: .immediate)
    }
}

/// C-compatible Darwin callback for interactive home paint wake (must not capture context).
///
/// Forwards to local ``NotificationCenter`` on the main queue so
/// ``LutheranRadioWidgetEntryView`` can re-resolve snapshot SSOT after a main-app settle stamp.
///
/// - SeeAlso: ``SharedPlayerManager/registerHomeWidgetInteractivePaintWakeObserverIfNeeded()``,
///   ``SharedPlayerManager/homeWidgetInteractivePaintAdvancedNotification``.
// SAFETY: CF Darwin requires a C function pointer. This free function captures nothing; it only
// hops to main and posts the SSOT ``homeWidgetInteractivePaintAdvancedNotification`` name.
private func homeWidgetInteractivePaintAdvancedDarwinCallback(
    _ center: CFNotificationCenter?,
    _ observer: UnsafeMutableRawPointer?,
    _ name: CFNotificationName?,
    _ object: UnsafeRawPointer?,
    _ userInfo: CFDictionary?
) {
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: SharedPlayerManager.homeWidgetInteractivePaintAdvancedNotification,
            object: nil
        )
    }
}

