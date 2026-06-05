//
//  SecurityModelValidatorTests.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 22.3.2026.
//

import Testing
import Foundation
@testable import Core

/// Mirrors ``SecurityConfiguration/expectedSecurityModel`` for deterministic validator tests.
private let testExpectedSecurityModel = SecurityConfiguration().expectedSecurityModel

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
    // ------------------------------------------------------------------------
    @Test("Validation runs without crashing (real DNS)")
    func validationRuns() async {
        await resetValidator()
        
        let validator = SecurityModelValidator.shared
        
        let isValid = await validator.validateSecurityModel()
        
        #expect(isValid == true || isValid == false)
    }
    
    // ------------------------------------------------------------------------
    // State observation after validation
    // ------------------------------------------------------------------------
    @Test("State transitions after validation call")
    func stateAfterValidation() async {
        await resetValidator()
        
        let validator = SecurityModelValidator.shared
        
        let initialState = await validator.currentState
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
    // Reset behavior
    // ------------------------------------------------------------------------
    @Test("Reset transient state")
    func resetTransient() async {
        await resetValidator()
        
        let validator = SecurityModelValidator.shared
        
        _ = await validator.validateSecurityModel()
        
        let stateBefore = await validator.currentState
        
        await validator.resetTransientState()
        
        let stateAfter = await validator.currentState
        
        if stateBefore == .failedTransient {
            #expect(stateAfter != .failedTransient)
        } else {
            #expect(true, "No transient failure → reset has no effect")
        }
    }
    
    // ------------------------------------------------------------------------
    // Permanent invalid check
    // ------------------------------------------------------------------------
    @Test("Permanent invalid flag")
    func permanentFlag() async {
        await resetValidator()
        
        let validator = SecurityModelValidator.shared
        
        _ = await validator.validateSecurityModel()
        
        let isPermanent = await validator.isPermanentlyInvalid
        
        #expect(isPermanent == true || isPermanent == false)
    }
    
    // ============================================================
    // DETERMINISTIC TESTS (moved inside the serialized suite)
    // ============================================================
    
    private func resetForDeterministicTest() async {
        await SecurityModelValidator.shared.resetTransientState()
        await SecurityModelValidator._test_setTXTFetcher(nil, clearCache: true)
    }
    
    private func forceFutureClock() async {
        let farFuture: @Sendable () -> Date = { Date().addingTimeInterval(7200) }
        await SecurityModelValidator._test_setCurrentDate(farFuture)
    }
    
    private func restoreRealClock() async {
        await SecurityModelValidator._test_setCurrentDate { Date() }
    }
    
    // MARK: - Success Paths
    
    @Test("Success when primary domain returns the expected model")
    func successViaPrimary() async {
        await resetForDeterministicTest()
        
        await SecurityModelValidator._test_setTXTFetcher { domain in
            if domain.contains("lutheran.radio") {
                return [testExpectedSecurityModel, "other-model"]
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
                throw NSError(domain: "test.dns", code: -1001, userInfo: nil)
            }
            if domain.contains("lutheranradio.sk") {
                return [testExpectedSecurityModel]
            }
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
        await forceFutureClock()
        
        await SecurityModelValidator._test_setTXTFetcher { _ in
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
        await forceFutureClock()
        
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
    
    @Test("Concurrent validateSecurityModel coalesces to one fetcher invocation")
    func concurrentValidationCoalesces() async {
        await resetForDeterministicTest()

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var _value = 0
            var value: Int { lock.withLock { _value } }
            func increment() { lock.withLock { _value += 1 } }
        }
        let counter = Counter()

        await SecurityModelValidator._test_setTXTFetcher { _ in
            counter.increment()
            try await Task.sleep(nanoseconds: 200_000_000)
            return [testExpectedSecurityModel]
        }

        async let first = SecurityModelValidator.shared.validateSecurityModel()
        async let second = SecurityModelValidator.shared.validateSecurityModel()
        let results = await (first, second)

        #expect(results.0 == true)
        #expect(results.1 == true)
        #expect(counter.value == 1, "Overlapping validations must share one DNS fetch")
    }

    @Test("Cache hit returns success without calling fetcher again")
    func cacheHitSkipsFetcher() async {
        await resetForDeterministicTest()
        
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var _value = 0
            var value: Int { lock.withLock { _value } }
            func increment() { lock.withLock { _value += 1 } }
        }
        let counter = Counter()
        
        await SecurityModelValidator._test_setTXTFetcher { _ in
            counter.increment()
            return [testExpectedSecurityModel]
        }
        
        let first = await SecurityModelValidator.shared.validateSecurityModel()
        #expect(first == true)
        #expect(counter.value == 1)
        
        await SecurityModelValidator._test_setTXTFetcher({ _ in
            counter.increment()
            return ["completely-different-model"]
        }, clearCache: false)
        
        let second = await SecurityModelValidator.shared.validateSecurityModel()
        #expect(second == true)
        #expect(counter.value == 1, "Fetcher should not have been called again due to cache")
        
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
        await forceFutureClock()
        
        await SecurityModelValidator._test_setTXTFetcher { _ in
            throw NSError(domain: "test.dns", code: -1)
        }
        
        let first = await SecurityModelValidator.shared.validateSecurityModel()
        #expect(first == false)
        let stateAfterFail = await SecurityModelValidator.shared.currentState
        #expect(stateAfterFail == .failedTransient)
        
        await SecurityModelValidator.shared.resetTransientState()
        
        await SecurityModelValidator._test_setTXTFetcher { _ in
            return [testExpectedSecurityModel]
        }
        
        let second = await SecurityModelValidator.shared.validateSecurityModel()
        #expect(second == true)
        let finalState = await SecurityModelValidator.shared.currentState
        #expect(finalState == .success)
        
        await restoreRealClock()
    }
}

// MARK: - Pure Parser Tests (safe to run in parallel)

@Suite("parseInlineTXTRecord (pure DNS TXT parser) Tests")
struct ParseInlineTXTRecordTests {
    
    private func block(_ string: String) -> Data {
        var data = Data()
        let bytes = Data(string.utf8)
        precondition(bytes.count <= 255, "TXT label too long for test")
        data.append(UInt8(bytes.count))
        data.append(bytes)
        return data
    }
    
    private func multiBlock(_ strings: [String]) -> Data {
        strings.reduce(into: Data()) { $0.append(block($1)) }
    }
    
    @Test("Empty or structurally invalid inputs produce empty set", arguments: [
        Data(), Data([0]), Data([3, 0x61, 0x62]), Data([10, 0x61, 0x62, 0x63])
    ])
    func emptyOrInvalidInputs(data: Data) {
        let result = SecurityModelValidator._test_parseInlineTXTRecord(data)
        #expect(result.isEmpty)
    }
    
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
    
    @Test("Non-UTF8 bytes in a block cause that block to be skipped (not crash)")
    func nonUTF8BlockIsSkipped() {
        var data = block("fredericksburg")
        data.append(0x03)
        data.append(0x80)
        data.append(0x81)
        data.append(0x82)
        let result = SecurityModelValidator._test_parseInlineTXTRecord(data)
        #expect(result == Set(["fredericksburg"]))
    }
    
    @Test("Maximum-length (255 byte) label is accepted")
    func maximumLengthLabel() {
        let longModel = String(repeating: "a", count: 255)
        let data = block(longModel)
        let result = SecurityModelValidator._test_parseInlineTXTRecord(data)
        #expect(result == Set([longModel]))
    }
    
    @Test("Label that would exceed 255 bytes is impossible (UInt8 length) but 255 is the effective max")
    func lengthByteMaxIs255() {
        let maxLabel = String(repeating: "x", count: 255)
        let data = block(maxLabel)
        #expect(SecurityModelValidator._test_parseInlineTXTRecord(data).count == 1)
    }
    
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
