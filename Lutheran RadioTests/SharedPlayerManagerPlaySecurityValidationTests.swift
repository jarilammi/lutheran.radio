//
//  SharedPlayerManagerPlaySecurityValidationTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 27.10.2026.
//
//  ``play()`` security phase: all-host transient DNS failure vs authoritative TXT rejection.
//
//  The XCTest host reports ``SharedPlayerManager/isRunningInUITestMode`` through the
//  DEBUG fallback even when `-UITestMode` is absent. That early-gate outcome skips
//  ``.beforeAttach``. These tests enable
//  ``_test_setBypassUITestModeForPlaySecurityValidation(_:)`` so ``play()`` reaches
//  Core validation. The process flag itself stays true, so engine ``attachAndPlay``
//  still no-ops if a regression falls through.
//
//  Isolation follows ``prepareSharedPlayerManagerEventTestIsolation`` (it does not
//  skip security validation). The fetcher is installed before ``play()`` and cleared
//  in tear-down. Pattern: `CoreTests/SecurityModelValidatorTests.swift`
//  (`transientFailureBothDomainsFail`).
//
//  - SeeAlso: ``SharedPlayerManager/play()``, ``SecurityValidationFacade``,
//    ``SecurityModelValidator/_test_setTXTFetcher(_:clearCache:)``,
//    `PlayerEventTestSupport.swift`,
//    CODING_AGENT.md (Test Execution Patience and Fast, Reliable Test Patterns).
//

import XCTest
import Core
@testable import Lutheran_Radio

/// ``beforeAttach`` false is not always a sticky security lock.
///
/// An all-host transient DNS failure leaves ``isPermanentlyInvalid`` false, paints
/// grey ``.userPaused``, keeps an active intent, and does not attach. An authoritative
/// TXT answer that omits ``SecurityConfiguration/expectedSecurityModel`` locks
/// visual and intent to ``.securityLocked``.
///
/// - SeeAlso: ``SecurityValidationFacade/validate(_:)``,
///   ``SecurityValidationFacade/isPermanentlyInvalid()``,
///   ``PlaybackIntent/securityLocked``,
///   CODING_AGENT.md.
final class SharedPlayerManagerPlaySecurityValidationTests: XCTestCase {

    private let manager = SharedPlayerManager.shared

    /// Sendable hit counter for the injected TXT fetcher.
    ///
    /// A later ``play()`` must call the fetcher again. The prePlay one-shot does not
    /// block that re-entry when visual is grey ``.userPaused`` and intent is active.
    private final class TXTFetchCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var hits = 0

        var count: Int { lock.withLock { hits } }

        func increment() {
            lock.withLock { hits += 1 }
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        await prepareSharedPlayerManagerEventTestIsolation(manager: manager)
        // After isolation. The helper clears this seam so other suites stay on
        // UITest isolation; this suite turns it on only for ``play()``.
        SharedPlayerManager._test_setBypassUITestModeForPlaySecurityValidation(true)
    }

    override func tearDown() async throws {
        await SecurityModelValidator._test_setTXTFetcher(nil, clearCache: true)
        await SecurityModelValidator._test_setCurrentDate { Date() }
        SharedPlayerManager._test_setBypassUITestModeForPlaySecurityValidation(false)
        await tearDownSharedPlayerManagerEventTestIsolation(manager: manager)
        try await super.tearDown()
    }

    /// Installs a deterministic TXT fetcher and forces the success-cache clock forward
    /// so ``play()`` cannot treat a prior timestamp as a validation hit.
    ///
    /// - Parameter fetcher: Per-domain TXT closure. Throw for transient; return a set
    ///   that omits the expected model for authoritative rejection.
    private func installTXTFetcher(
        _ fetcher: @escaping @Sendable (String) async throws -> Set<String>
    ) async {
        await SecurityModelValidator._test_setCurrentDate {
            Date().addingTimeInterval(7200)
        }
        await SecurityModelValidator._test_setTXTFetcher(fetcher, clearCache: true)
    }

    /// All-host transient DNS failure must not take ``.securityLocked`` or attach.
    ///
    /// Protects: ``beforeAttach`` false with ``isPermanentlyInvalid()`` false paints
    /// grey ``.userPaused``, leaves ``.shouldBePlaying``, clears the start pipeline
    /// (so post-security connecting chrome and ``attachAndPlay`` never run), and a
    /// later ``play()`` enters validation again. The security-model alert follows
    /// ``.securityLocked`` only, so this path does not show it.
    ///
    /// - SeeAlso: ``SecurityModelValidator/validateSecurityModel()``,
    ///   ``markPlaybackStoppedByStreamFailure(_:)``,
    ///   ``PlaybackPlayDecision/evaluateEarlyGates(_:)``.
    func testPlayAllHostTransientDNSFailureKeepsActiveIntentAndDoesNotAttach() async {
        let counter = TXTFetchCounter()
        await installTXTFetcher { _ in
            counter.increment()
            throw NSError(
                domain: "test.dns",
                code: -1001,
                userInfo: [NSLocalizedDescriptionKey: "simulated network error"]
            )
        }

        let intentBefore = await manager.currentPlaybackIntent
        let pipelineBefore = await manager.isPlaybackStartPipelineActive
        XCTAssertEqual(intentBefore, .shouldBePlaying)
        XCTAssertTrue(intentBefore.isActivePlaybackIntent)
        XCTAssertFalse(pipelineBefore)

        await manager.play()

        let hitsAfterFirstPlay = counter.count
        XCTAssertGreaterThan(
            hitsAfterFirstPlay,
            0,
            "play() must reach .beforeAttach and invoke the TXT fetcher"
        )
        await assertTransientPauseWithoutAttach()

        // Grey .userPaused with an active intent is outside the prePlay one-shot,
        // so a later play() enters validation again and still does not attach.
        await manager.play()

        XCTAssertGreaterThan(
            counter.count,
            hitsAfterFirstPlay,
            "A later play() must enter validation again after a transient DNS failure"
        )
        await assertTransientPauseWithoutAttach()
    }

    /// Authoritative TXT rejection (expected model absent) still locks.
    ///
    /// Protects: ``isPermanentlyInvalid()`` true after ``beforeAttach`` false applies
    /// ``.securityLocked`` visual and intent and does not continue to attach.
    ///
    /// - SeeAlso: ``SecurityConfiguration/expectedSecurityModel``,
    ///   ``PlaybackIntent/securityLocked``.
    func testPlayAuthoritativeTXTRejectionLocksSecurity() async {
        let expected = SecurityConfiguration.current.expectedSecurityModel
        let omitted: Set<String> = ["some-other-model", "legacy-model"]
        XCTAssertFalse(
            omitted.contains(expected),
            "Fixture must omit the expected security model"
        )

        await installTXTFetcher { _ in
            omitted
        }

        await manager.play()

        let permanent = await SecurityValidationFacade.isPermanentlyInvalid()
        let visual = await manager.currentVisualState
        let intent = await manager.currentPlaybackIntent

        let pipelineActive = await manager.isPlaybackStartPipelineActive
        XCTAssertTrue(permanent)
        XCTAssertEqual(visual, .securityLocked)
        XCTAssertEqual(intent, .securityLocked)
        XCTAssertFalse(
            pipelineActive,
            "Permanent lock returns before post-security chrome and attach"
        )
    }

    /// Grey pause, active intent, pipeline clear: attach did not run.
    ///
    /// Post-security connecting chrome replaces a non-playing visual with ``.prePlay``
    /// and leaves ``isPlaybackStartPipelineActive`` set until ``setPlaying()``.
    /// UITest isolation would paint ``.playing``. Neither is this outcome.
    private func assertTransientPauseWithoutAttach() async {
        let permanent = await SecurityValidationFacade.isPermanentlyInvalid()
        let visual = await manager.currentVisualState
        let intent = await manager.currentPlaybackIntent

        let pipelineActive = await manager.isPlaybackStartPipelineActive
        XCTAssertFalse(permanent)
        XCTAssertEqual(visual, .userPaused)
        XCTAssertEqual(intent, .shouldBePlaying)
        XCTAssertTrue(intent.isActivePlaybackIntent)
        XCTAssertNotEqual(intent, .securityLocked)
        XCTAssertFalse(
            pipelineActive,
            "Transient failure must return before attach and clear the start pipeline"
        )
    }
}
