//
//  WidgetHomeAndLiveActivityChromeTests.swift
//  WidgetSurfaceTests
//
//  Created by Jari Lammi on 24.7.2026.
//
//  Pure presentation contracts for alternative stream codes, equalizer geometry,
//  and Lock Screen control glyph mapping. No SharedPlayerManager / AppIntents.
//
//  - SeeAlso: ``alternativeStreamCodes(current:availableLanguageCodes:maxCount:fallbackCodes:)``,
//    ``LiveActivityEqualizerStyle``, ``liveActivityLockScreenControlSystemImage(from:)``,
//    docs/Widget-Presentation-Dataflow.md.
//

import CoreFoundation
import Testing
import WidgetSurface

// MARK: - alternativeStreamCodes

struct AlternativeStreamCodesTests {

    /// Catalog codes exclude current and respect maxCount.
    @Test func prefersCatalogCodesExcludingCurrent() {
        let codes = alternativeStreamCodes(
            current: "fi",
            availableLanguageCodes: ["en", "de", "fi", "sv", "et", "nb"],
            maxCount: 4
        )
        #expect(codes == ["en", "de", "sv", "et"])
        #expect(!codes.contains("fi"))
        #expect(codes.count == 4)
    }

    /// Empty catalog falls back to curated en/de/fi/sv/et (excluding current).
    @Test func emptyCatalogUsesFallbackCodes() {
        let codes = alternativeStreamCodes(
            current: "en",
            availableLanguageCodes: [],
            maxCount: 4
        )
        #expect(codes == ["de", "fi", "sv", "et"])
    }

    /// maxCount smaller than available list truncates in source order.
    @Test func respectsMaxCount() {
        let codes = alternativeStreamCodes(
            current: "xx",
            availableLanguageCodes: ["a", "b", "c", "d", "e"],
            maxCount: 2
        )
        #expect(codes == ["a", "b"])
    }

    /// When current is the only catalog entry, result is empty.
    @Test func onlyCurrentInCatalogYieldsEmpty() {
        let codes = alternativeStreamCodes(
            current: "fi",
            availableLanguageCodes: ["fi"],
            maxCount: 4
        )
        #expect(codes.isEmpty)
    }
}

// MARK: - Equalizer deterministic geometry

struct LiveActivityEqualizerStyleTests {

    @Test func expandedTrailingHasThreeDeterministicBars() {
        let style = LiveActivityEqualizerStyle.expandedTrailing
        #expect(style.barCount == 3)
        #expect(style.height(at: 0) == 6)
        #expect(style.height(at: 1) == 12)
        #expect(style.height(at: 2) == 8)
        #expect(style.duration(at: 0) == 0.45)
        #expect(style.duration(at: 1) == 0.55)
        #expect(style.duration(at: 2) == 0.40)
    }

    @Test func expandedBottomHasFiveGradientBarsWithStagger() {
        let style = LiveActivityEqualizerStyle.expandedBottom
        #expect(style.barCount == 5)
        #expect(style.usesGradient)
        #expect(style.staggeredDelay == 0.1)
        #expect(style.height(at: 0) == 4)
        #expect(style.height(at: 4) == 9)
    }

    @Test func compactLeadingHasTwoBars() {
        let style = LiveActivityEqualizerStyle.compactLeading
        #expect(style.barCount == 2)
        #expect(style.height(at: 0) == 3)
        #expect(style.height(at: 1) == 5)
        #expect(style.duration(at: 0) == 0.5)
        #expect(!style.usesGradient)
    }

    /// Heights wrap by index so out-of-range calls stay defined.
    @Test func heightWrapsByBarCount() {
        let style = LiveActivityEqualizerStyle.expandedTrailing
        #expect(style.height(at: 3) == style.height(at: 0))
    }
}

// MARK: - Lock Screen control glyph

struct LiveActivityLockScreenControlImageTests {

    @Test func mapsPlayAndPauseToCircleVariants() {
        #expect(liveActivityLockScreenControlSystemImage(from: "pause.fill") == "pause.circle.fill")
        #expect(liveActivityLockScreenControlSystemImage(from: "play.fill") == "play.circle.fill")
        #expect(liveActivityLockScreenControlSystemImage(from: "other") == "play.circle.fill")
    }
}
