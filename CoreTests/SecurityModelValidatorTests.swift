//
//  SecurityModelValidatorTests.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 22.3.2026.
//

import Testing
import Foundation
@testable import Core

@Suite("SecurityModelValidator Tests", .serialized)
struct SecurityModelValidatorTests {
    
    // MARK: - Helper (runs when you call it)
    private func resetValidator() async {
        // Full clean via the test seam: removes any injected fetcher, clears
        // in-memory + UserDefaults cache, and forces .pending state.
        await SecurityModelValidator._test_setTXTFetcher(nil, clearCache: true)
    }
    
    // ------------------------------------------------------------------------
    // Smoke test: can we even create and call the public validation method?
    // (If initializer is inaccessible → this will fail compilation → needs access fix)
    // ------------------------------------------------------------------------
    @Test("Validation runs without crashing (real DNS)")
    func validationRuns() async {
        await resetValidator()
        
        let validator = SecurityModelValidator.shared
        
        let isValid = await validator.validateSecurityModel()
        
        #expect(isValid == true || isValid == false)  // just prove it returns Bool
    }
    
    // ------------------------------------------------------------------------
    // State observation after validation
    // ------------------------------------------------------------------------
    @Test("State transitions after validation call")
    func stateAfterValidation() async {
        await resetValidator()                    // ensure clean starting point
        
        let validator = SecurityModelValidator.shared
        
        let initialState = await validator.currentState
        // We cannot guarantee .pending because the singleton may already be successful
        #expect(
            initialState == .pending || initialState == .success,
            "Should start as .pending or already be successfully validated (singleton)"
        )
        
        let isValid = await validator.validateSecurityModel()
        
        let finalState = await validator.currentState
        
        #expect(
            finalState == .success ||
            finalState == .failedPermanent ||
            finalState == .failedTransient,
            "After validation we must be in a terminal state"
        )
        
        if isValid {
            #expect(finalState == .success)
        } else {
            #expect(finalState == .failedPermanent || finalState == .failedTransient)
        }
    }
    
    // ------------------------------------------------------------------------
    // Reset behavior (if resetTransientState is public/internal)
    // ------------------------------------------------------------------------
    @Test("Reset transient state")
    func resetTransient() async {
        await resetValidator()
        
        let validator = SecurityModelValidator.shared
        
        // Call validation first (may set transient failure if DNS bad)
        _ = await validator.validateSecurityModel()
        
        let stateBefore = await validator.currentState
        
        await validator.resetTransientState()  // assume this is accessible
        
        let stateAfter = await validator.currentState
        
        if stateBefore == .failedTransient {
            #expect(stateAfter != .failedTransient)
        } else {
            #expect(true, "No transient failure → reset has no effect")
        }
    }
    
    // ------------------------------------------------------------------------
    // Permanent invalid check (if isPermanentlyInvalid is accessible)
    // ------------------------------------------------------------------------
    @Test("Permanent invalid flag")
    func permanentFlag() async {
        await resetValidator()
        
        let validator = SecurityModelValidator.shared
        
        _ = await validator.validateSecurityModel()
        
        let isPermanent = await validator.isPermanentlyInvalid
        
        #expect(isPermanent == true || isPermanent == false)
    }
}

// MARK: - Pure Parser Tests (deterministic, no network, no side effects)

/// Comprehensive table-driven tests for the internal DNS TXT wire-format parser.
///
/// These tests exercise `SecurityModelValidator._test_parseInlineTXTRecord` (DEBUG-only
/// wrapper around the private `parseInlineTXTRecord`). They are fast, deterministic, and
/// cover many edge cases that are difficult or impossible to trigger reliably over live DNS.
@Suite("parseInlineTXTRecord (pure DNS TXT parser) Tests")
struct ParseInlineTXTRecordTests {

    // MARK: - Helpers

    /// Build a single length-prefixed TXT block (DNS wire format).
    private func block(_ string: String) -> Data {
        var data = Data()
        let bytes = Data(string.utf8)
        precondition(bytes.count <= 255, "TXT label too long for test")
        data.append(UInt8(bytes.count))
        data.append(bytes)
        return data
    }

    /// Concatenate multiple length-prefixed blocks (realistic multi-string TXT record).
    private func multiBlock(_ strings: [String]) -> Data {
        strings.reduce(into: Data()) { $0.append(block($1)) }
    }

    // MARK: - Empty / Malformed / Guard Cases

    @Test("Empty or structurally invalid inputs produce empty set", arguments: [
        Data(),                                           // truly empty
        Data([0]),                                        // length=0 guard
        Data([3, 0x61, 0x62]),                            // length=3 but only 2 bytes follow (overrun)
        Data([10, 0x61, 0x62, 0x63])                      // length=10 but only 3 bytes follow
    ])
    func emptyOrInvalidInputs(data: Data) {
        let result = SecurityModelValidator._test_parseInlineTXTRecord(data)
        #expect(result.isEmpty)
    }

    // MARK: - Basic Valid Cases

    @Test("Single model (various casing and whitespace)", arguments: [
        ("fredericksburg", Set(["fredericksburg"])),
        ("FREDERICKSBURG", Set(["fredericksburg"])),
        ("  fredericksburg  ", Set(["fredericksburg"])),
        ("\tfredericksburg\n", Set(["fredericksburg"]))
    ])
    func singleModel(input: String, expected: Set<String>) {
        let data = block(input)
        #expect(SecurityModelValidator._test_parseInlineTXTRecord(data) == expected)
    }

    @Test("Comma-separated models in a single TXT string")
    func commaSeparatedSingleBlock() {
        let data = block("fredericksburg, brenham , landvetter")
        let result = SecurityModelValidator._test_parseInlineTXTRecord(data)
        #expect(result == Set(["fredericksburg", "brenham", "landvetter"]))
    }

    @Test("Multiple separate TXT strings (multi-block)")
    func multipleSeparateBlocks() {
        let data = multiBlock([
            "fredericksburg,brenham",
            "landvetter",
            "  other-model  "
        ])
        let result = SecurityModelValidator._test_parseInlineTXTRecord(data)
        #expect(result == Set(["fredericksburg", "brenham", "landvetter", "other-model"]))
    }

    // MARK: - Trimming, Case, and Empty Segment Handling

    @Test("Whitespace around commas and models is trimmed; empty segments dropped")
    func trimmingAndEmptySegments() {
        let data = block("  fredericksburg  ,  , , brenham ,  , landvetter  ")
        let result = SecurityModelValidator._test_parseInlineTXTRecord(data)
        #expect(result == Set(["fredericksburg", "brenham", "landvetter"]))
    }

    @Test("Only commas and whitespace produces empty set")
    func onlyCommasAndWhitespace() {
        let data = block("  , ,  ,   ")
        let result = SecurityModelValidator._test_parseInlineTXTRecord(data)
        #expect(result.isEmpty)
    }

    @Test("Mixed blocks with some only-whitespace are handled cleanly")
    func mixedValidAndEmptyBlocks() {
        let data = multiBlock([
            "fredericksburg",
            "   , ,  ",
            "brenham, landvetter"
        ])
        let result = SecurityModelValidator._test_parseInlineTXTRecord(data)
        #expect(result == Set(["fredericksburg", "brenham", "landvetter"]))
    }

    // MARK: - Duplicates and Ordering

    @Test("Duplicates across blocks are deduplicated (Set semantics)")
    func duplicateModelsAcrossBlocks() {
        let data = multiBlock([
            "fredericksburg,brenham",
            "fredericksburg",
            "brenham, landvetter"
        ])
        let result = SecurityModelValidator._test_parseInlineTXTRecord(data)
        #expect(result == Set(["fredericksburg", "brenham", "landvetter"]))
    }

    // MARK: - Non-UTF8 and Encoding Robustness

    @Test("Non-UTF8 bytes in a block cause that block to be skipped (not crash)")
    func nonUTF8BlockIsSkipped() {
        // Valid first block, then a block containing an invalid UTF-8 sequence (lone continuation byte)
        var data = block("fredericksburg")
        data.append(0x03)           // length = 3
        data.append(0x80)           // lone continuation byte (invalid start)
        data.append(0x81)
        data.append(0x82)

        let result = SecurityModelValidator._test_parseInlineTXTRecord(data)
        #expect(result == Set(["fredericksburg"]))
    }

    // MARK: - Maximum Length Label (255 bytes)

    @Test("Maximum-length (255 byte) label is accepted")
    func maximumLengthLabel() {
        let longModel = String(repeating: "a", count: 255)
        let data = block(longModel)
        let result = SecurityModelValidator._test_parseInlineTXTRecord(data)
        #expect(result == Set([longModel]))
    }

    @Test("Label that would exceed 255 bytes is impossible (UInt8 length) but 255 is the effective max")
    func lengthByteMaxIs255() {
        // We cannot create a 256-byte label with a single length byte; this documents the limit.
        let maxLabel = String(repeating: "x", count: 255)
        let data = block(maxLabel)
        #expect(SecurityModelValidator._test_parseInlineTXTRecord(data).count == 1)
    }

    // MARK: - Real-World-ish Combinations

    @Test("Realistic multi-domain TXT record with mixed formatting")
    func realisticMixedFormatting() {
        let data = multiBlock([
            "fredericksburg , brenham",
            "landvetter,other",
            "  LEGACY-MODEL  "
        ])
        let result = SecurityModelValidator._test_parseInlineTXTRecord(data)
        #expect(result == Set(["fredericksburg", "brenham", "landvetter", "other", "legacy-model"]))
    }

    @Test("Empty model names after trimming are never emitted")
    func emptyModelNamesNeverEmitted() {
        let data = block(",,,   ,fredericksburg,,,")
        let result = SecurityModelValidator._test_parseInlineTXTRecord(data)
        #expect(result == Set(["fredericksburg"]))
    }
}

// MARK: - Deterministic Full Validator Tests (using injected TXT fetcher)

/// Tests that exercise the entire `validateSecurityModel()` state machine
/// (cache, domain loop, success/permanent/transient decisions) using a deterministic
/// TXT fetcher instead of live DNS.
///
/// These tests are fast, reliable, and do not depend on network or the real
/// `securitymodels.lutheran.radio` zone.
@Suite("Deterministic SecurityModelValidator Tests (injected TXT)", .serialized)
struct DeterministicSecurityModelValidatorTests {

    // MARK: - Helpers

    /// Reset both transient state and any injected fetcher.
    /// Call at the start (and optionally end) of each test that uses the seam.
    private func resetForDeterministicTest() async {
        await SecurityModelValidator.shared.resetTransientState()
        await SecurityModelValidator._test_setTXTFetcher(nil, clearCache: true)
    }

    /// Force the validator's logical clock far into the future.
    /// Any success timestamp previously written (by this process, the running app,
    /// or earlier tests) will now appear >1h old, so the cache guard is bypassed
    /// and the injected TXT fetcher is guaranteed to be consulted.
    private func forceFutureClock() async {
        let farFuture: @Sendable () -> Date = { Date().addingTimeInterval(7200) }
        await SecurityModelValidator._test_setCurrentDate(farFuture)
    }

    /// Restore the real-time clock provider (best-effort cleanup after forceFutureClock).
    private func restoreRealClock() async {
        await SecurityModelValidator._test_setCurrentDate { Date() }
    }

    // MARK: - Success Paths

    @Test("Success when primary domain returns the expected model")
    func successViaPrimary() async {
        await resetForDeterministicTest()

        await SecurityModelValidator._test_setTXTFetcher { domain in
            // Simulate primary domain
            if domain.contains("lutheran.radio") {
                return ["fredericksburg", "other-model"]
            }
            throw NSError(domain: "test.dns", code: -1, userInfo: [NSLocalizedDescriptionKey: "simulated primary failure"])
        }

        let isValid = await SecurityModelValidator.shared.validateSecurityModel()
        #expect(isValid == true, "Should succeed when model is present")

        let state = await SecurityModelValidator.shared.currentState
        #expect(state == .success)
    }

    @Test("Success via backup when primary throws (transient)")
    func successViaBackupAfterPrimaryTransient() async {
        await resetForDeterministicTest()

        await SecurityModelValidator._test_setTXTFetcher { domain in
            if domain.contains("lutheran.radio") {
                // Primary fails transiently
                throw NSError(domain: "test.dns", code: -1001, userInfo: nil)
            }
            if domain.contains("lutheranradio.sk") {
                // Backup succeeds with the model
                return ["fredericksburg"]
            }
            // Unknown domain → transient error (lets domain loop continue instead
            // of immediately triggering the permanent-failure path on empty set).
            throw NSError(domain: "test.dns", code: -1001, userInfo: nil)
        }

        let isValid = await SecurityModelValidator.shared.validateSecurityModel()
        #expect(isValid == true)

        let state = await SecurityModelValidator.shared.currentState
        #expect(state == .success)
    }

    // MARK: - Permanent Failure

    @Test("Permanent failure when model is not in TXT on a responding domain")
    func permanentFailureModelNotAllowed() async {
        await resetForDeterministicTest()
        await forceFutureClock()   // defeat any success timestamp written by the live app or prior tests

        await SecurityModelValidator._test_setTXTFetcher { _ in
            // Authoritative response that does NOT contain our model
            return ["some-other-model", "legacy-model"]
        }

        let isValid = await SecurityModelValidator.shared.validateSecurityModel()
        #expect(isValid == false)

        let state = await SecurityModelValidator.shared.currentState
        #expect(state == .failedPermanent)

        let isPermanent = await SecurityModelValidator.shared.isPermanentlyInvalid
        #expect(isPermanent == true)

        await restoreRealClock()
    }

    // MARK: - Transient Failure

    @Test("Transient failure when both domains throw")
    func transientFailureBothDomainsFail() async {
        await resetForDeterministicTest()
        await forceFutureClock()   // defeat any success timestamp written by the live app or prior tests

        await SecurityModelValidator._test_setTXTFetcher { _ in
            throw NSError(domain: "test.dns", code: -1001, userInfo: [NSLocalizedDescriptionKey: "simulated network error"])
        }

        let isValid = await SecurityModelValidator.shared.validateSecurityModel()
        #expect(isValid == false)

        let state = await SecurityModelValidator.shared.currentState
        #expect(state == .failedTransient)

        let isPermanent = await SecurityModelValidator.shared.isPermanentlyInvalid
        #expect(isPermanent == false)

        await restoreRealClock()
    }

    // MARK: - Cache Behavior (deterministic)

    @Test("Cache hit returns success without calling fetcher again")
    func cacheHitSkipsFetcher() async {
        await resetForDeterministicTest()

        // Use a reference type for the counter so mutations inside @Sendable
        // fetcher closures are safe (avoids "mutation of captured var in
        // concurrently-executing code" under Swift 6 / parallel test execution).
        final class Counter {
            private(set) var value = 0
            func increment() { value += 1 }
        }
        let counter = Counter()

        await SecurityModelValidator._test_setTXTFetcher { _ in
            counter.increment()
            return ["fredericksburg"]
        }

        // First call → should hit fetcher
        let first = await SecurityModelValidator.shared.validateSecurityModel()
        #expect(first == true)
        #expect(counter.value == 1)

        // Change what the fetcher would return (simulating a server change)
        await SecurityModelValidator._test_setTXTFetcher({ _ in
            counter.increment()
            return ["completely-different-model"]
        }, clearCache: false)   // deliberately do NOT clear cache

        // Second call should still be served from cache (old result)
        let second = await SecurityModelValidator.shared.validateSecurityModel()
        #expect(second == true)
        #expect(counter.value == 1, "Fetcher should not have been called again due to cache")

        // Now force a cache bypass via reset + new fetcher
        await SecurityModelValidator.shared.resetTransientState()
        await SecurityModelValidator._test_setTXTFetcher({ _ in
            counter.increment()
            return ["completely-different-model"]
        }, clearCache: true)

        let afterReset = await SecurityModelValidator.shared.validateSecurityModel()
        #expect(afterReset == false, "Should now see the new (wrong) model and fail permanently")
        #expect(counter.value == 2)
    }

    // MARK: - Reset + Seam Interaction

    @Test("Reset transient state clears transient failure and allows fresh validation")
    func resetAfterTransientAllowsRetry() async {
        await resetForDeterministicTest()
        await forceFutureClock()   // guarantee we actually reach the first (transient) fetcher

        // Force transient failure
        await SecurityModelValidator._test_setTXTFetcher { _ in
            throw NSError(domain: "test.dns", code: -1)
        }

        let first = await SecurityModelValidator.shared.validateSecurityModel()
        #expect(first == false)
        let stateAfterFail = await SecurityModelValidator.shared.currentState
        #expect(stateAfterFail == .failedTransient)

        // Reset
        await SecurityModelValidator.shared.resetTransientState()

        // Now provide a successful response
        await SecurityModelValidator._test_setTXTFetcher { _ in
            return ["fredericksburg"]
        }

        let second = await SecurityModelValidator.shared.validateSecurityModel()
        #expect(second == true)
        let finalState = await SecurityModelValidator.shared.currentState
        #expect(finalState == .success)

        await restoreRealClock()
    }
}
