//
//  PersistedLanguageResolutionTests.swift
//  WidgetSurfaceTests
//
//  Created by Jari Lammi on 24.7.2026.
//
//  Exhaustive pure language reconciliation for saveCurrentState snapshot writes.
//  Protects: no-snapshot model seed, stale "en" repair, stream-switch hold preference,
//  and paused widget language (hold inactive → do not clobber preferred).
//
//  - SeeAlso: ``PersistedLanguageResolution``, SharedPlayerManager.saveCurrentState().
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

    @Test func repairsStaleEnglishFromSnapshot() {
        let code = PersistedLanguageResolution.resolve(
            preferredLanguage: "en",
            hasSnapshot: true,
            snapshotLanguage: "de",
            modelLanguage: "en",
            streamSwitchHoldActive: false
        )
        #expect(code == "de")
    }

    @Test func repairsStaleEnglishFromModelWhenSnapshotAlsoEnglish() {
        let code = PersistedLanguageResolution.resolve(
            preferredLanguage: "en",
            hasSnapshot: true,
            snapshotLanguage: "en",
            modelLanguage: "et",
            streamSwitchHoldActive: false
        )
        #expect(code == "et")
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

    @Test func streamSwitchHoldPrefersModelOverPreferred() {
        let code = PersistedLanguageResolution.resolve(
            preferredLanguage: "sv",
            hasSnapshot: true,
            snapshotLanguage: "sv",
            modelLanguage: "et",
            streamSwitchHoldActive: true
        )
        #expect(code == "et")
    }

    @Test func nonEnglishPreferredSurvivesLaggingModelWithoutHold() {
        // Paused widget language (non-en): preferred/snapshot must not be overwritten by a
        // lagging Direct model unless stream-switch hold is active. (English is special-cased
        // by the historical stale-"en" repair — see repairsStaleEnglishFromModelWhenSnapshotAlsoEnglish.)
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
