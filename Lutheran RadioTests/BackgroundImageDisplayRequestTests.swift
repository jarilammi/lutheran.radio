//
//  BackgroundImageDisplayRequestTests.swift
//  Lutheran RadioTests
//
//  Protects the background display request:
//  one publish is current, an older generation must not paint, and a finished
//  bitmap for a superseded request must not change backgroundImageView.
//  Cache fill and deferral timing are not a second paint policy. The controller
//  tests enter the real apply path through the filter-bitmap seam.
//
//  No ActivityKit, WidgetCenter, or network.
//
//  - SeeAlso: ``BackgroundImageDisplayLedger``, ``BackgroundImageController``,
//    docs/Widget-Presentation-Dataflow.md (Main-App Chrome Authority),
//    CODING_AGENT.md (test documentation).
//
//  Created by Jari Lammi on 28.11.2026.
//

import UIKit
import XCTest
@testable import Lutheran_Radio

/// Publish / may-paint identity for the decorative background.
///
/// - SeeAlso: ``BackgroundImageDisplayLedger``, ``BackgroundImageController``
@MainActor
final class BackgroundImageDisplayRequestTests: XCTestCase {

    private var controller: BackgroundImageController?

    override func tearDown() async throws {
        controller?.test_filterOverride = nil
        controller = nil
        try await super.tearDown()
    }

    /// A later publish is the only request that may paint.
    func testPublishSupersedesEarlierRequest() {
        var ledger = BackgroundImageDisplayLedger()
        let finnish = ledger.publish(languageCode: "fi")
        let estonian = ledger.publish(languageCode: "et")

        XCTAssertTrue(ledger.mayPaint(estonian))
        XCTAssertFalse(ledger.mayPaint(finnish))
        XCTAssertLessThan(finnish.generation, estonian.generation)
    }

    /// The same language code with an older generation is not the current request.
    func testOlderGenerationOfSameLanguageMustNotPaint() {
        var ledger = BackgroundImageDisplayLedger()
        let first = ledger.publish(languageCode: "fi")
        let second = ledger.publish(languageCode: "fi")

        XCTAssertEqual(first.languageCode, second.languageCode)
        XCTAssertNotEqual(first.generation, second.generation)
        XCTAssertTrue(ledger.mayPaint(second))
        XCTAssertFalse(ledger.mayPaint(first))
    }

    /// A Finland bitmap that finishes after Estonia is published does not change the view.
    ///
    /// The filter seam has already started, so cancelling the deferred flush is not what
    /// rejects the write. ``applyProcessedImage(_:for:skipCrossDissolve:)`` does.
    func testSupersededFinlandBitmapDoesNotPaintAfterEstoniaPublish() async {
        let finland = solidImage(UIColor.systemBlue)
        let gate = BackgroundImageFilterGate()
        let log = BackgroundImageFilterLog()
        let controller = makeController()
        controller.test_filterOverride = { languageCode in
            log.record(languageCode)
            if languageCode == "fi" {
                await gate.wait()
                return finland
            }
            return nil
        }

        controller.update(for: stream("fi"))
        await waitUntil("Finland filter started") { log.languages.contains("fi") }

        controller.scheduleDeferredForStreamSwitch(stream("et"))
        gate.open()

        await waitUntil("Finland apply reached the view-write gate") {
            controller.test_applyProcessedImageEntries >= 1
        }
        XCTAssertNil(controller.backgroundImageView.image)
        XCTAssertFalse(controller.backgroundImageView.image === finland)
    }

    /// A coalesced waiter whose generation is current paints when the shared fill completes.
    func testCoalescedCurrentGenerationPaintsWhenSharedFillCompletes() async {
        let shared = solidImage(UIColor.systemGreen)
        let gate = BackgroundImageFilterGate()
        let log = BackgroundImageFilterLog()
        let controller = makeController()
        controller.test_filterOverride = { languageCode in
            log.record(languageCode)
            await gate.wait()
            return shared
        }

        controller.update(for: stream("fi"))
        await waitUntil("shared fill started") { log.languages.count == 1 }

        controller.update(for: stream("fi"))
        await waitUntil("second generation joined the fill") {
            controller.test_interestedGenerationCount(for: "fi") >= 2
        }
        XCTAssertEqual(log.languages.count, 1, "The second request must join the fill already running")

        gate.open()
        await waitUntil("shared bitmap painted") {
            controller.backgroundImageView.image === shared
                && controller.test_inFlightImageJobCount == 0
        }
        XCTAssertTrue(controller.backgroundImageView.image === shared)
    }

    /// Modal cancel pauses the flush and leaves the current request paintable.
    func testModalCancelLeavesCurrentRequestPaintable() async {
        let finland = solidImage(UIColor.systemOrange)
        let gate = BackgroundImageFilterGate()
        let log = BackgroundImageFilterLog()
        let controller = makeController()
        controller.test_filterOverride = { languageCode in
            log.record(languageCode)
            await gate.wait()
            return finland
        }

        controller.update(for: stream("fi"))
        await waitUntil("Finland filter started") { log.languages.contains("fi") }

        controller.cancelDeferredForModalInteraction()
        gate.open()

        await waitUntil("current request painted after modal cancel") {
            controller.backgroundImageView.image === finland
        }
        XCTAssertTrue(controller.backgroundImageView.image === finland)
    }

    /// Sticky pause is cancelPendingDeferral() then update(for:), and that update paints.
    func testStickyPauseOrderPaintsDestination() async {
        let estonia = solidImage(UIColor.systemTeal)
        let controller = makeController()
        controller.test_filterOverride = { _ in estonia }

        controller.scheduleDeferredForStreamSwitch(stream("fi"))
        XCTAssertEqual(controller.test_inFlightImageJobCount, 0)

        controller.cancelPendingDeferral()
        controller.update(for: stream("et"))

        await waitUntil("destination bitmap painted") {
            controller.backgroundImageView.image === estonia
        }
        XCTAssertTrue(controller.backgroundImageView.image === estonia)
    }

    /// While deferral is armed, update(for:) does not start Core Image.
    func testUpdateDuringDeferralDoesNotStartProcessing() async {
        let log = BackgroundImageFilterLog()
        let controller = makeController()
        controller.test_filterOverride = { languageCode in
            log.record(languageCode)
            return self.solidImage(UIColor.systemRed)
        }

        controller.scheduleDeferredForStreamSwitch(stream("fi"))
        controller.update(for: stream("et"))

        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(log.languages.isEmpty)
        XCTAssertEqual(controller.test_inFlightImageJobCount, 0)
        XCTAssertNil(controller.backgroundImageView.image)
    }

    private func makeController() -> BackgroundImageController {
        let controller = BackgroundImageController()
        controller.test_usesProcessedImagePath = true
        self.controller = controller
        return controller
    }

    private func stream(_ languageCode: String) -> DirectStreamingPlayer.Stream {
        DirectStreamingPlayer.streamForLanguageCode(languageCode)
    }

    private func solidImage(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    private func waitUntil(
        _ message: String,
        timeoutSeconds: Double = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () -> Bool
    ) async {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeoutSeconds {
                XCTFail(message, file: file, line: line)
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Suspends one filter seam until the test opens it.
@MainActor
private final class BackgroundImageFilterGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

/// Languages that entered the filter seam, in order.
@MainActor
private final class BackgroundImageFilterLog {
    private(set) var languages: [String] = []

    func record(_ languageCode: String) {
        languages.append(languageCode)
    }
}
