//
//  PersistedLanguageResolutionTests.swift
//  WidgetSurfaceTests
//
//  Created by Jari Lammi on 24.7.2026.
//
//  Exhaustive pure language reconciliation for saveCurrentState snapshot writes.
//  Protects: no-snapshot model seed, intentional English vs hard-default "en" repair,
//  stream-switch hold preference, hold-time destination outranking lagging
//  preferred/snapshot/model, and paused widget language (hold inactive → do not
//  clobber preferred).
//
//  - SeeAlso: ``PersistedLanguageResolution``, SharedPlayerManager.saveCurrentState(),
//    SharedPlayerManager.streamSwitchConnectingLanguageCode,
//    SharedPlayerManager.liveActivityLanguageCodeForContentPush().
//

import Foundation
import Testing
import WidgetSurface

struct PersistedLanguageResolutionTests {

    @Test func prefersModelWhenNoSnapshot() {
        let code = PersistedLanguageResolution.resolve(
            preferredLanguage: "en",
            hasSnapshot: false,
            snapshotLanguage: nil,
            modelLanguage: "fi",
            streamSwitchHoldActive: false
        )
        #expect(code == "fi")
    }

    @Test func keepsPreferredWhenNoSnapshotAndEmptyModel() {
        let code = PersistedLanguageResolution.resolve(
            preferredLanguage: "sv",
            hasSnapshot: false,
            snapshotLanguage: nil,
            modelLanguage: "",
            streamSwitchHoldActive: false
        )
        #expect(code == "sv")
    }

    /// Intentional English: engine model is already `"en"`. A lagging non-en snapshot
    /// must not clobber preferred `"en"` (historical repair treated every preferred `"en"`
    /// as hard-default pollution and reverted to the prior snapshot language).
    @Test func keepsIntentionalEnglishWhenModelIsEnglishDespiteLaggingSnapshot() {
        let code = PersistedLanguageResolution.resolve(
            preferredLanguage: "en",
            hasSnapshot: true,
            snapshotLanguage: "de",
            modelLanguage: "en",
            streamSwitchHoldActive: false
        )
        #expect(code == "en")
    }

    /// Hard-default preferred `"en"` while the engine is on a non-English stream:
    /// repair from the non-en snapshot (privacy / no-widgets pollution path).
    @Test func repairsHardDefaultEnglishFromSnapshotWhenModelIsNonEnglish() {
        let code = PersistedLanguageResolution.resolve(
            preferredLanguage: "en",
            hasSnapshot: true,
            snapshotLanguage: "de",
            modelLanguage: "et",
            streamSwitchHoldActive: false
        )
        #expect(code == "de")
    }

    /// Preferred and snapshot both `"en"` but engine is non-en: preferred `"en"` is
    /// hard-default pollution — prefer the model stream language.
    @Test func repairsHardDefaultEnglishFromModelWhenSnapshotAlsoEnglish() {
        let code = PersistedLanguageResolution.resolve(
            preferredLanguage: "en",
            hasSnapshot: true,
            snapshotLanguage: "en",
            modelLanguage: "et",
            streamSwitchHoldActive: false
        )
        #expect(code == "et")
    }

    /// Empty model + preferred hard-default `"en"` + non-en snapshot → repair from snapshot.
    @Test func repairsHardDefaultEnglishFromSnapshotWhenModelEmpty() {
        let code = PersistedLanguageResolution.resolve(
            preferredLanguage: "en",
            hasSnapshot: true,
            snapshotLanguage: "fi",
            modelLanguage: "",
            streamSwitchHoldActive: false
        )
        #expect(code == "fi")
    }

    /// Consistent intentional English (preferred, snapshot, and model all `"en"`).
    @Test func keepsIntentionalEnglishWhenAllInputsAgree() {
        let code = PersistedLanguageResolution.resolve(
            preferredLanguage: "en",
            hasSnapshot: true,
            snapshotLanguage: "en",
            modelLanguage: "en",
            streamSwitchHoldActive: false
        )
        #expect(code == "en")
    }

    @Test func keepsNonEnglishPreferredWithoutHold() {
        let code = PersistedLanguageResolution.resolve(
            preferredLanguage: "sv",
            hasSnapshot: true,
            snapshotLanguage: "sv",
            modelLanguage: "fi",
            streamSwitchHoldActive: false
        )
        #expect(code == "sv")
    }

    /// When hold is active but no connecting destination was recorded, prefer engine model
    /// once it has advanced (orchestrated switch already updated DirectStreamingPlayer).
    @Test func streamSwitchHoldPrefersModelOverPreferredWhenConnectingUnknown() {
        let code = PersistedLanguageResolution.resolve(
            preferredLanguage: "sv",
            hasSnapshot: true,
            snapshotLanguage: "sv",
            modelLanguage: "et",
            streamSwitchHoldActive: true,
            connectingLanguageCode: nil
        )
        #expect(code == "et")
    }

    /// Hold-time destination outranks lagging preferred, snapshot, and model so the
    /// App Group snapshot agrees with Live Activity ContentState during Connecting
    /// before ``DirectStreamingPlayer/selectedStream`` settles on the new language.
    @Test func streamSwitchHoldConnectingDestinationOutranksLaggingPreferredSnapshotAndModel() {
        let code = PersistedLanguageResolution.resolve(
            preferredLanguage: "et",
            hasSnapshot: true,
            snapshotLanguage: "et",
            modelLanguage: "et",
            streamSwitchHoldActive: true,
            connectingLanguageCode: "de"
        )
        #expect(code == "de")
    }

    /// Destination also wins when preferred is hard-default `"en"` and snapshot/model still lag —
    /// Connecting chrome must not re-run stale-English repair over the switch target.
    @Test func streamSwitchHoldConnectingDestinationOutranksStaleEnglishRepair() {
        let code = PersistedLanguageResolution.resolve(
            preferredLanguage: "en",
            hasSnapshot: true,
            snapshotLanguage: "sv",
            modelLanguage: "sv",
            streamSwitchHoldActive: true,
            connectingLanguageCode: "et"
        )
        #expect(code == "et")
    }

    /// Hold-time destination `"en"` must not be repaired away — intentional English switch
    /// during Connecting before the engine model settles.
    @Test func streamSwitchHoldConnectingEnglishOutranksLaggingNonEnglishTriad() {
        let code = PersistedLanguageResolution.resolve(
            preferredLanguage: "de",
            hasSnapshot: true,
            snapshotLanguage: "de",
            modelLanguage: "de",
            streamSwitchHoldActive: true,
            connectingLanguageCode: "en"
        )
        #expect(code == "en")
    }

    /// Connecting language is only meaningful while hold is active; ignore a stray value
    /// after hold ends so normal preferred/snapshot/model rules apply.
    @Test func connectingLanguageIgnoredWhenHoldInactive() {
        let code = PersistedLanguageResolution.resolve(
            preferredLanguage: "et",
            hasSnapshot: true,
            snapshotLanguage: "et",
            modelLanguage: "et",
            streamSwitchHoldActive: false,
            connectingLanguageCode: "de"
        )
        #expect(code == "et")
    }

    /// Empty connecting string falls through to model preference on hold.
    @Test func emptyConnectingFallsThroughToModelOnHold() {
        let code = PersistedLanguageResolution.resolve(
            preferredLanguage: "sv",
            hasSnapshot: true,
            snapshotLanguage: "sv",
            modelLanguage: "et",
            streamSwitchHoldActive: true,
            connectingLanguageCode: ""
        )
        #expect(code == "et")
    }

    @Test func nonEnglishPreferredSurvivesLaggingModelWithoutHold() {
        // Paused widget language (non-en): preferred/snapshot must not be overwritten by a
        // lagging Direct model unless stream-switch hold is active. (English is special-cased
        // by the intentional-vs-hard-default rules — see keepsIntentionalEnglishWhenModelIsEnglishDespiteLaggingSnapshot.)
        let code = PersistedLanguageResolution.resolve(
            preferredLanguage: "et",
            hasSnapshot: true,
            snapshotLanguage: "et",
            modelLanguage: "sv",
            streamSwitchHoldActive: false
        )
        #expect(code == "et")
    }

    @Test func holdDoesNotChangeWhenModelMatches() {
        let code = PersistedLanguageResolution.resolve(
            preferredLanguage: "fi",
            hasSnapshot: true,
            snapshotLanguage: "fi",
            modelLanguage: "fi",
            streamSwitchHoldActive: true
        )
        #expect(code == "fi")
    }

    @Test func emptyModelDoesNotOverrideOnHold() {
        let code = PersistedLanguageResolution.resolve(
            preferredLanguage: "nb",
            hasSnapshot: true,
            snapshotLanguage: "nb",
            modelLanguage: "",
            streamSwitchHoldActive: true
        )
        #expect(code == "nb")
    }
}
