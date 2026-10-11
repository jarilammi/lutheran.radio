//
//  SleepTimerGlassPopoverLayoutTests.swift
//  Lutheran RadioTests
//
//  Protects the sleep-timer confirmation-dialog layout correction:
//  alert content that requires a width wider than the glass popover host
//  follows that host, and a player view outside the dialog does not.
//
//  Invariant: do not set `translatesAutoresizingMaskIntoConstraints` on the
//  glass host. Do not retarget the host's own width. Disarm before any
//  unrelated width is assigned so the secondary privacy alert is unchanged.
//
//  ``SleepTimerMenuButton`` equality ignores action closures. Those closures
//  are reallocated on every status paint; comparing them would rebuild the
//  glass popover.
//
//  Decision tests do not present the popover. The moon-button open is eyes-on.
//
//  - SeeAlso: `SleepTimerGlassPopoverLayout`,
//    `SleepTimerMenuButton`,
//    `PrivacyClearConfirmationPresentationTests`,
//    docs/Widget-Presentation-Dataflow.md (Main-App Chrome Authority),
//    CODING_AGENT.md (test documentation).
//
//  Created by Jari Lammi on 11.10.2026.
//

import UIKit
import XCTest
@testable import Lutheran_Radio

/// Stand-in whose class name contains the production glass-host token.
private final class GlassPopoverContentViewRepresentable: UIView {}

/// Stand-in whose class name contains the production alert-view token.
private final class Fixture_UIAlertControllerPhoneTVMacView: UIView {}

/// Content-width policy for the sleep-timer glass popover.
///
/// - SeeAlso: ``SleepTimerGlassPopoverLayout``, ``SleepTimerMenuButton``
@MainActor
final class SleepTimerGlassPopoverLayoutTests: XCTestCase {

    /// Async because `XCTestCase.tearDown()` is nonisolated. The sync override
    /// cannot call ``SleepTimerGlassPopoverLayout/stopFollowingHostWidth()`` without an actor hop.
    override func tearDown() async throws {
        SleepTimerGlassPopoverLayout.stopFollowingHostWidth()
        try await super.tearDown()
    }

    /// A required content width wider than the glass host is stored as the fallback host width.
    ///
    /// The stand-in host has no autoresizing-mask constraint (that class is not public).
    /// The hook then uses ``SleepTimerGlassPopoverLayout/fallbackHostWidth``.
    /// Activating `widthAnchor` on the host would clear its autoresizing mask;
    /// this test leaves that mask set so the hook is shown not to clear it.
    func testFollowingHostClampsContentWiderThanGlassHost() {
        SleepTimerGlassPopoverLayout.beginFollowingHostWidth()
        let host = GlassPopoverContentViewRepresentable()
        let content = UIView()
        host.addSubview(content)
        let contentWidth = content.widthAnchor.constraint(equalToConstant: 366)
        contentWidth.isActive = true

        XCTAssertEqual(contentWidth.constant, 320, accuracy: 0.5)
        XCTAssertTrue(
            host.translatesAutoresizingMaskIntoConstraints,
            "The glass host autoresizing mask stays under UIKit"
        )
    }

    /// Screen-width constraints outside the dialog stay put while content width follows the host.
    func testFollowingHostLeavesUnrelatedWidthAlone() {
        SleepTimerGlassPopoverLayout.beginFollowingHostWidth()
        let playerRow = UIView()
        let rowWidth = playerRow.widthAnchor.constraint(equalToConstant: 366)
        rowWidth.isActive = true
        XCTAssertEqual(rowWidth.constant, 366, accuracy: 0.5)
    }

    /// After following stops, dialog content keeps the width UIKit assigns.
    func testStoppedFollowLeavesAssignedWidth() {
        SleepTimerGlassPopoverLayout.beginFollowingHostWidth()
        SleepTimerGlassPopoverLayout.stopFollowingHostWidth()
        let host = GlassPopoverContentViewRepresentable()
        let content = UIView()
        host.addSubview(content)
        let contentWidth = content.widthAnchor.constraint(equalToConstant: 366)
        contentWidth.isActive = true
        XCTAssertEqual(contentWidth.constant, 366, accuracy: 0.5)
    }

    /// Alert content not yet inserted into the glass host still follows the fallback width.
    func testPhoneAlertContentFollowsFallbackHostWidthWhileFollowing() {
        SleepTimerGlassPopoverLayout.beginFollowingHostWidth()
        let alert = Fixture_UIAlertControllerPhoneTVMacView()
        let content = UIView()
        alert.addSubview(content)
        let contentWidth = content.widthAnchor.constraint(equalToConstant: 366)
        contentWidth.isActive = true
        XCTAssertEqual(
            contentWidth.constant,
            SleepTimerGlassPopoverLayout.fallbackHostWidth,
            accuracy: 0.5
        )
    }

    /// A content width that already fits the host is unchanged. Height is not a width.
    func testFittingWidthAndHeightStayUnchanged() {
        SleepTimerGlassPopoverLayout.beginFollowingHostWidth()
        let host = GlassPopoverContentViewRepresentable()
        let content = UIView()
        host.addSubview(content)
        let contentWidth = content.widthAnchor.constraint(equalToConstant: 300)
        let contentHeight = content.heightAnchor.constraint(equalToConstant: 366)
        contentWidth.isActive = true
        contentHeight.isActive = true
        XCTAssertEqual(contentWidth.constant, 300, accuracy: 0.5)
        XCTAssertEqual(contentHeight.constant, 366, accuracy: 0.5)
    }

    /// A width stored before the view joins the host is retargeted on `didMoveToSuperview`.
    func testRewriteAfterJoiningHostFollowsFallbackWidth() {
        SleepTimerGlassPopoverLayout.beginFollowingHostWidth()
        let host = GlassPopoverContentViewRepresentable()
        let content = UIView()
        let contentWidth = content.widthAnchor.constraint(equalToConstant: 366)
        contentWidth.isActive = true
        XCTAssertEqual(contentWidth.constant, 366, accuracy: 0.5, "Not in a host yet")
        host.addSubview(content)
        XCTAssertEqual(contentWidth.constant, 320, accuracy: 0.5)
    }

    /// Status paints reallocate closures. Equality must not see that as a new menu.
    func testSleepTimerMenuButtonEqualityIgnoresActionClosures() {
        let first = SleepTimerMenuButton(
            sleepTimerRemaining: nil,
            sleepTimerAccessibilityValue: nil,
            onSelectSleepTimer: { _ in },
            onCancelSleepTimer: {},
            onClearLocalStateTapped: {}
        )
        let second = SleepTimerMenuButton(
            sleepTimerRemaining: nil,
            sleepTimerAccessibilityValue: nil,
            onSelectSleepTimer: { _ in },
            onCancelSleepTimer: {},
            onClearLocalStateTapped: {}
        )
        XCTAssertEqual(first, second)

        let timed = SleepTimerMenuButton(
            sleepTimerRemaining: 12 * 60,
            sleepTimerAccessibilityValue: "12 minutes remaining",
            onSelectSleepTimer: nil,
            onCancelSleepTimer: nil,
            onClearLocalStateTapped: nil
        )
        XCTAssertNotEqual(first, timed)
        XCTAssertTrue(timed.cancelTimerIsAvailable)
        XCTAssertFalse(first.cancelTimerIsAvailable)
    }

    /// Pure width policy: wider than the host follows the host; a fit stays.
    func testContentWidthFollowingHost() {
        XCTAssertEqual(
            SleepTimerGlassPopoverLayout.contentWidthFollowingHost(proposed: 366, hostWidth: 320),
            320,
            accuracy: 0.5
        )
        XCTAssertEqual(
            SleepTimerGlassPopoverLayout.contentWidthFollowingHost(proposed: 300, hostWidth: 320),
            300,
            accuracy: 0.5
        )
        XCTAssertEqual(
            SleepTimerGlassPopoverLayout.contentWidthFollowingHost(proposed: 320, hostWidth: 320),
            320,
            accuracy: 0.5
        )
    }
}
