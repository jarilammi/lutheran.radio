//
//  PrivacyClearConfirmationPresentationTests.swift
//  Lutheran RadioTests
//
//  Created by Jari Lammi on 28.8.2026.
//
//  Protects the privacy-clear confirm present-timing contract:
//  the sleep-timer SwiftUI `.confirmationDialog` must dismiss, and leftover
//  iOS 26+ `GlassPopoverContentViewRepresentable` hosts must leave the window
//  scene, before the secondary `UIAlertController` is presented.
//
//  Invariant: presenting `_UIAlertControllerPhoneTVMacView` (~357pt content)
//  into leftover confirmationDialog glass (autoresizing width 320) is
//  unsatisfiable. UIKit recovers by breaking the alert constraint. The
//  confirmationDialog stays; this is present-timing only.
//
//  Why this shape:
//  - `presentedViewController == nil` is not sufficient on iOS 26+ — glass
//    can remain in a scene window after the presented chain is empty.
//  - Hosting a real confirmationDialog + UIAlert in XCTest is ActivityKit /
//    UIKit-present expensive and not this suite. The testable policies are
//    ``SleepTimerPrivacyClearPresentation`` and
//    ``CoordinatorAlertPresentationSettle``.
//  - No ActivityKit, WidgetCenter, live AsyncStream, or Core security.
//
//  - SeeAlso: `SleepTimerPrivacyClearPresentation`,
//    `CoordinatorAlertPresentationSettle`,
//    `PlaybackControlsView`,
//    `ViewController.presentCoordinatorAlertAfterOutgoingPresentationSettles`,
//    docs/Widget-Presentation-Dataflow.md (Main-App Chrome Authority),
//    CODING_AGENT.md (test documentation + fast patterns).
//

import XCTest
import UIKit
@testable import Lutheran_Radio

/// Present-timing policy for the privacy-clear confirm after the sleep-timer dialog.
///
/// Invariant: do not present the secondary UIAlert while the confirmationDialog
/// is still `isPresented` or while a glass popover host remains in the scene.
///
/// - SeeAlso: ``SleepTimerPrivacyClearPresentation/shouldInvokePrivacyClearConfirm(dialogIsPresented:pendingPrivacyConfirm:)``,
///   ``CoordinatorAlertPresentationSettle/canPresentCoordinatorAlert(outgoingPresentedViewController:sceneContainsGlassPopoverHost:)``
@MainActor
final class PrivacyClearConfirmationPresentationTests: XCTestCase {

    /// Destructive row arms pending; coordinator runs only after `isPresented` is false.
    func testPrivacyClearConfirmWaitsUntilSleepTimerDialogDismissed() {
        XCTAssertFalse(
            SleepTimerPrivacyClearPresentation.shouldInvokePrivacyClearConfirm(
                dialogIsPresented: true,
                pendingPrivacyConfirm: true
            ),
            "Must not invoke privacy confirm while the sleep-timer confirmationDialog is still presented"
        )
        XCTAssertTrue(
            SleepTimerPrivacyClearPresentation.shouldInvokePrivacyClearConfirm(
                dialogIsPresented: false,
                pendingPrivacyConfirm: true
            ),
            "Pending privacy confirm must run after the confirmationDialog isPresented is false"
        )
    }

    /// No pending flag means no confirm, whether the dialog is up or not.
    func testPrivacyClearConfirmDoesNotInvokeWithoutPendingFlag() {
        XCTAssertFalse(
            SleepTimerPrivacyClearPresentation.shouldInvokePrivacyClearConfirm(
                dialogIsPresented: true,
                pendingPrivacyConfirm: false
            )
        )
        XCTAssertFalse(
            SleepTimerPrivacyClearPresentation.shouldInvokePrivacyClearConfirm(
                dialogIsPresented: false,
                pendingPrivacyConfirm: false
            ),
            "Dismissing the dialog without the destructive row must not invoke privacy confirm"
        )
    }

    /// Presented-chain empty is not enough while glass remains in the scene.
    func testCoordinatorAlertMustWaitForGlassPopoverHost() {
        XCTAssertFalse(
            CoordinatorAlertPresentationSettle.canPresentCoordinatorAlert(
                outgoingPresentedViewController: nil,
                sceneContainsGlassPopoverHost: true
            ),
            "presentedViewController == nil is not sufficient while GlassPopoverContentViewRepresentable remains"
        )
        XCTAssertTrue(
            CoordinatorAlertPresentationSettle.canPresentCoordinatorAlert(
                outgoingPresentedViewController: nil,
                sceneContainsGlassPopoverHost: false
            ),
            "Empty presented chain and no glass host is the present-timing SSOT"
        )
    }

    /// A still-presented confirmationDialog container blocks the coordinator alert.
    func testCoordinatorAlertMustWaitForOutgoingPresentedController() {
        let outgoing = UIViewController()
        XCTAssertFalse(
            CoordinatorAlertPresentationSettle.canPresentCoordinatorAlert(
                outgoingPresentedViewController: outgoing,
                sceneContainsGlassPopoverHost: false
            ),
            "Outgoing presented controller must finish disappearing before the coordinator alert"
        )
        XCTAssertFalse(
            CoordinatorAlertPresentationSettle.canPresentCoordinatorAlert(
                outgoingPresentedViewController: outgoing,
                sceneContainsGlassPopoverHost: true
            ),
            "Either leftover (presented chain or glass) is a 320-vs-357 layout fight"
        )
    }

    /// Type-name matcher must catch the iOS 26+ mangled glass host from constraint dumps.
    func testGlassPopoverHostTypeNameMatchesMangledPlatformViewHost() {
        let dumped =
            "_TtGC5UIKit22UICorePlatformViewHostGVS_32PlatformViewRepresentableAdaptorVS_P10$19b9139c436GlassPopoverContentViewRepresentable__"
        XCTAssertTrue(
            CoordinatorAlertPresentationSettle.isGlassPopoverPlatformHostTypeName(dumped),
            "Constraint-dump mangled GlassPopoverContentViewRepresentable must match"
        )
        XCTAssertTrue(
            CoordinatorAlertPresentationSettle.isGlassPopoverPlatformHostTypeName(
                CoordinatorAlertPresentationSettle.glassPopoverHostTypeNameToken
            )
        )
        XCTAssertFalse(
            CoordinatorAlertPresentationSettle.isGlassPopoverPlatformHostTypeName(
                "_UIAlertControllerPhoneTVMacView"
            ),
            "The privacy UIAlert itself must not be treated as leftover confirmationDialog glass"
        )
        XCTAssertFalse(
            CoordinatorAlertPresentationSettle.isGlassPopoverPlatformHostTypeName("UIView")
        )
    }

    /// Ordinary UIView trees are not glass hosts; nil is not a host.
    func testOrdinaryViewTreeIsNotGlassPopoverHost() {
        XCTAssertFalse(
            CoordinatorAlertPresentationSettle.viewTreeContainsGlassPopoverHost(nil)
        )
        let view = UIView()
        view.addSubview(UIView())
        XCTAssertFalse(
            CoordinatorAlertPresentationSettle.viewTreeContainsGlassPopoverHost(view),
            "A generic UIView tree must not be treated as confirmationDialog glass"
        )
        XCTAssertFalse(
            CoordinatorAlertPresentationSettle.isGlassPopoverPlatformHost(view)
        )
        XCTAssertFalse(
            CoordinatorAlertPresentationSettle.sceneContainsGlassPopoverHost(window: nil),
            "A nil player window cannot contain leftover glass"
        )
    }
}
