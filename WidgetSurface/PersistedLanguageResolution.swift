//
//  PersistedLanguageResolution.swift
//  WidgetSurface
//
//  Created by Jari Lammi on 24.7.2026.
//
//  Pure language reconciliation for App Group snapshot writes.
//
//  WidgetSurface framework — presentation/policy vocabulary only (no I/O).
//  SharedPlayerManager.saveCurrentState() gathers preferred/snapshot/model inputs
//  and applies the returned language code to the snapshot write path.
//
//  Why pure: stream-switch holds, paused widget language selection, and no-snapshot
//  cold-launch seeding interact as a race museum if inlined only inside the actor.
//  Exhaustive table tests lock the precedence rules without App Group or engine.
//
//  - SeeAlso: SharedPlayerManager.saveCurrentState(), preferredWidgetLanguage(),
//    holdPrePlayVisualUntilPlayback, CODING_AGENT.md (Single Source of Truth).
//  - AGENT NOTE: Do not reintroduce dual ownership of language writes outside
//    performActualSave / persist paths. This resolver only picks the code string.
//

import Foundation

/// Pure language code resolution for ``SharedPlayerManager/saveCurrentState()``.
public enum PersistedLanguageResolution {

    /// Resolves the language code to persist for the current save.
    ///
    /// Precedence (matches historical `saveCurrentState` behavior):
    /// 1. Start from `preferredLanguage` (typically ``preferredWidgetLanguage()``).
    /// 2. No snapshot: prefer non-empty `modelLanguage` (main-app selected stream).
    /// 3. Snapshot present and preferred is `"en"`: repair from snapshot non-en, else model non-en.
    /// 4. Stream-switch hold active: when model differs from the candidate, prefer model
    ///    (orchestrated switch already updated DirectStreamingPlayer before play).
    ///
    /// - Parameters:
    ///   - preferredLanguage: Baseline from preferredWidgetLanguage / callers.
    ///   - hasSnapshot: Whether a `PersistedWidgetState` snapshot currently exists.
    ///   - snapshotLanguage: Snapshot `currentLanguage` when `hasSnapshot` is true.
    ///   - modelLanguage: `DirectStreamingPlayer.selectedStream.languageCode`.
    ///   - streamSwitchHoldActive: `holdPrePlayVisualUntilPlayback` on the actor.
    /// - Returns: Language code to write into the next snapshot (when privacy allows write).
    /// - Note: Privacy write suppression is enforced by the actor after resolution;
    ///   this function never decides whether to write.
    public static func resolve(
        preferredLanguage: String,
        hasSnapshot: Bool,
        snapshotLanguage: String?,
        modelLanguage: String,
        streamSwitchHoldActive: Bool
    ) -> String {
        var code = preferredLanguage

        if !hasSnapshot {
            if !modelLanguage.isEmpty {
                code = modelLanguage
            }
        } else if code == "en" {
            if let snapshotLanguage, snapshotLanguage != "en" {
                code = snapshotLanguage
            } else if modelLanguage != "en", !modelLanguage.isEmpty {
                code = modelLanguage
            }
        }

        if !modelLanguage.isEmpty,
           modelLanguage != code,
           streamSwitchHoldActive {
            code = modelLanguage
        }

        return code
    }
}
