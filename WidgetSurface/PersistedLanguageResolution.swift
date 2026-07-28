//
//  PersistedLanguageResolution.swift
//  WidgetSurface
//
//  Created by Jari Lammi on 24.7.2026.
//
//  Pure language reconciliation for App Group snapshot writes.
//
//  WidgetSurface framework — presentation/policy vocabulary only (no I/O).
//  SharedPlayerManager.saveCurrentState() gathers preferred/snapshot/model/
//  connecting inputs and applies the returned language code to the snapshot write path.
//
//  Why pure: stream-switch holds, paused widget language selection, and no-snapshot
//  cold-launch seeding interact as a race museum if inlined only inside the actor.
//  Exhaustive table tests lock the precedence rules without App Group or engine.
//
//  - SeeAlso: SharedPlayerManager.saveCurrentState(), preferredWidgetLanguage(),
//    streamSwitchConnectingLanguageCode, holdPrePlayVisualUntilPlayback,
//    stampStreamSwitchDestinationLanguage(_:), liveActivityLanguageCodeForContentPush(),
//    CODING_AGENT.md (Single Source of Truth).
//  - AGENT NOTE: Do not reintroduce dual ownership of language writes outside
//    performActualSave / persist paths. This resolver only picks the code string.
//  - AGENT NOTE: Live Activity already prefers destination via
//    liveActivityLanguageCodeForContentPush() during Connecting hold *and* when a
//    paused-path destination stamp is set without visual hold. Snapshot resolution
//    must use the same non-empty destination stamp so widget timelines do not lag
//    on the prior language while LA chrome is already correct.
//  - AGENT NOTE: Preferred `"en"` is ambiguous — privacy hard-default vs intentional
//    English selection. Repair hard-default pollution only when the engine model is
//    *not* English; when model is already `"en"`, keep English even if the snapshot
//    still holds a prior non-en code.
//

import Foundation

/// Pure language code resolution for ``SharedPlayerManager/saveCurrentState()``.
public enum PersistedLanguageResolution {

    /// Resolves the language code to persist for the current save.
    ///
    /// Precedence:
    /// 1. Non-empty `connectingLanguageCode` (**destination stamp**): **outranks**
    ///    preferred, snapshot, and model whether or not Connecting hold is active.
    ///    Used for active-intent hold **and** sticky-paused language switches so
    ///    mid-switch `saveCurrentState` cannot re-persist the prior code while the
    ///    engine model still lags (or after the model advanced but preferred lags).
    /// 2. Otherwise start from `preferredLanguage` (typically ``preferredWidgetLanguage()``).
    /// 3. No snapshot: prefer non-empty `modelLanguage` (main-app selected stream).
    /// 4. Snapshot present and preferred is `"en"`:
    ///    - If `modelLanguage == "en"`: **keep `"en"`** (intentional English confirmed
    ///      by the engine — never clobber with a lagging non-en snapshot).
    ///    - Else if model is a non-empty non-en code: treat preferred `"en"` as
    ///      hard-default pollution; prefer non-en snapshot, else model.
    ///    - Else (empty model): repair from non-en snapshot when present.
    /// 5. Stream-switch hold active without a connecting destination: when model
    ///    differs from the candidate, prefer model (orchestrated switch already
    ///    updated DirectStreamingPlayer before play).
    ///
    /// - Parameters:
    ///   - preferredLanguage: Baseline from preferredWidgetLanguage / callers.
    ///   - hasSnapshot: Whether a `PersistedWidgetState` snapshot currently exists.
    ///   - snapshotLanguage: Snapshot `currentLanguage` when `hasSnapshot` is true.
    ///   - modelLanguage: `DirectStreamingPlayer.selectedStream.languageCode`.
    ///   - streamSwitchHoldActive: `holdPrePlayVisualUntilPlayback` on the actor.
    ///   - connectingLanguageCode: Destination language stamp
    ///     (`streamSwitchConnectingLanguageCode`) for an in-flight stream switch —
    ///     Connecting hold **or** paused-path stamp without visual hold. Non-empty
    ///     always outranks; callers clear when destination is fully stamped (paused)
    ///     or when hold ends (active intent).
    /// - Returns: Language code to write into the next snapshot (when privacy allows write).
    /// - Note: Privacy write suppression is enforced by the actor after resolution;
    ///   this function never decides whether to write.
    /// - SeeAlso: ``SharedPlayerManager/liveActivityLanguageCodeForContentPush()``,
    ///   ``SharedPlayerManager/streamSwitchConnectingLanguageCode``,
    ///   ``SharedPlayerManager/stampStreamSwitchDestinationLanguage(_:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md (Connecting + destination language).
    public static func resolve(
        preferredLanguage: String,
        hasSnapshot: Bool,
        snapshotLanguage: String?,
        modelLanguage: String,
        streamSwitchHoldActive: Bool,
        connectingLanguageCode: String? = nil
    ) -> String {
        // Destination stamp outranks lagging preferred/snapshot/model so the session
        // snapshot agrees with Live Activity ContentState language during any in-flight
        // stream switch (Connecting hold *or* sticky-paused language change without hold).
        if let connecting = connectingLanguageCode, !connecting.isEmpty {
            return connecting
        }

        var code = preferredLanguage

        if !hasSnapshot {
            if !modelLanguage.isEmpty {
                code = modelLanguage
            }
        } else if code == "en" {
            // Preferred `"en"` is ambiguous: privacy hard-default vs intentional English.
            // Engine model already on English → intentional / consistent — keep `"en"`
            // even when the snapshot still holds a prior non-en code.
            if modelLanguage == "en" {
                // Keep preferred `"en"`.
            } else if !modelLanguage.isEmpty {
                // Engine on a non-English stream: preferred `"en"` is hard-default pollution.
                if let snapshotLanguage, snapshotLanguage != "en" {
                    code = snapshotLanguage
                } else {
                    code = modelLanguage
                }
            } else if let snapshotLanguage, snapshotLanguage != "en" {
                // Empty model: repair from non-en snapshot when available.
                code = snapshotLanguage
            }
        }

        // Fallback when hold is active but no connecting destination was recorded
        // (legacy/partial switch paths): prefer engine model once it has advanced.
        if !modelLanguage.isEmpty,
           modelLanguage != code,
           streamSwitchHoldActive {
            code = modelLanguage
        }

        return code
    }
}
