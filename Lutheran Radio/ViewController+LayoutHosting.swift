//
//  ViewController+LayoutHosting.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.7.2026.
//
//  Layout hosting domain for the thin UIKit host (mechanical split).
//
//  Owns: single `UIHostingController` hierarchy install for `RadioPlayerView`
//  (``setupUI``), layout-pass forwarding to the coordinator
//  (``viewDidLayoutSubviews`` → ``RadioPlayerCoordinator/notifyLayoutChange()``),
//  and coordinator `UIAlertController` present settle
//  (``presentCoordinatorAlertAfterOutgoingPresentationSettles(_:)`` — wait until the
//  sleep-timer `.confirmationDialog` container has disappeared, then `layoutIfNeeded`).
//
//  Layering invariants (background visibility):
//  1. Add the hosting controller first (safe-area content surface).
//  2. Clear the hosting view background so the decorative layer shows through.
//  3. Insert `BackgroundImageController.backgroundImageView` at subview index 0
//     with full-bleed constraints + `zPosition = -1`.
//
//  Does **not** own:
//  - SwiftUI composition of chrome leaves (`RadioPlayerView` / `PlayerViewModel`)
//  - AirPlay / volume UIKit bridges (SwiftUI `AirPlayButton` / `VolumeAndAirPlayRow` only —
//    never reintroduce eager `AVRoutePickerView` on the host)
//  - Background image processing / energy / stream-switch deferral (``BackgroundImageController``)
//  - Needle / language layout math (coordinator ``notifyLayoutChange`` is a thin forwarder;
//    SwiftUI `LanguageSelectorView` uses matchedGeometryEffect)
//  - Visual/intent SSOT, engine attach, security
//
//  Stored hosting controller (``playerHostingController``) and shared
//  ``backgroundImageController`` remain on the primary type body; this file owns the
//  install, layout-pass, and coordinator-alert present-settle behavior that uses them.
//
//  - SeeAlso: ``RadioPlayerView``, ``BackgroundImageController``,
//    ``RadioPlayerCoordinator/notifyLayoutChange()``,
//    ``presentCoordinatorAlertAfterOutgoingPresentationSettles(_:)``,
//    ViewController.swift (isolation map),
//    docs/Widget-Presentation-Dataflow.md (Main-App Chrome Authority),
//    CODING_AGENT.md (Single Source of Truth Principles).
//

import UIKit
import SwiftUI

extension ViewController {

    // MARK: - Layout hosting (UIHostingController + background layer)

    /// Installs the single SwiftUI player tree and the full-bleed background image layer.
    ///
    /// Call once from ``viewDidLoad`` after Darwin listener setup and before coordinator
    /// ``RadioPlayerCoordinator/wireAndInitialSetup()``. Layering order is load-bearing for
    /// background visibility (hosting view first, then insert background at index 0).
    ///
    /// - Important: Do not reintroduce multiple hosting controllers or eager UIKit
    ///   `AVRoutePickerView` construction on this host (launch-watchdog history).
    /// - SeeAlso: ``playerHostingController``, ``BackgroundImageController``,
    ///   ``RadioPlayerView``, `AirPlayButton`
    func setupUI() {
        view.backgroundColor = .systemBackground

        // Single SwiftUI player view (composes NowPlayingMetadataView + LanguageSelectorView
        // + PlaybackControlsView + VolumeAndAirPlayRow). This replaces the previous three
        // separate UIHostingControllers + manual interleaving of UIKit chrome.
        //
        // IMPORTANT LAYERING ORDER (background visibility fix):
        // 1. Add the playerHostingController (and its view) FIRST. At this moment it becomes
        //    the only (or top) subview and owns the safe-area content area.
        // 2. Explicitly clear its background so the decorative layer can show through.
        // 3. THEN insert the backgroundImageView at index 0. This places the full-bleed
        //    background BEHIND the hosting view in the subview list. zPosition = -1 is
        //    retained as a CALayer stacking belt-and-suspenders.
        // Why insert *after* adding the host but *at 0*? Adding host first gives it a stable
        // position in the hierarchy; insert(at:0) reliably pushes it above the background
        // without relying on later addSubview order or zPosition alone. RadioPlayerView
        // already uses Color.clear; the hosting view's opaque default was the obscurer.
        addChild(playerHostingController)
        view.addSubview(playerHostingController.view)
        playerHostingController.view.backgroundColor = .clear
        playerHostingController.view.translatesAutoresizingMaskIntoConstraints = false
        playerHostingController.didMove(toParent: self)

        NSLayoutConstraint.activate([
            playerHostingController.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            playerHostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerHostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerHostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Background image layer (full-bleed with parallax insets). Remains UIKit-owned
        // for the duration of the incremental SwiftUI migration (energy efficiency, CI pipeline,
        // deferral, etc. live in BackgroundImageController).
        //
        // Inserted at 0 (bottom) after the hosting controller so the SwiftUI content
        // renders in front. Constraints use view anchors (not safeArea) for true full-bleed.
        // updateForEnergyEfficiency(), scheduleDeferredForStreamSwitch(), and memory warning
        // handling are untouched; this is only the add/insert sequence.
        let bgView = backgroundImageController.backgroundImageView
        view.insertSubview(bgView, at: 0)
        bgView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bgView.topAnchor.constraint(equalTo: view.topAnchor),
            bgView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bgView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bgView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        bgView.layer.zPosition = -1
    }

    /// Forwards layout passes to the coordinator for any residual width-sensitive chrome.
    ///
    /// Height-only shifts (e.g. long metadata pushing content taller) must not retrigger
    /// needle positioning; SwiftUI `LanguageSelectorView` uses `matchedGeometryEffect` and
    /// does not need manual notify for ordinary layout. Coordinator
    /// ``RadioPlayerCoordinator/notifyLayoutChange()`` remains the thin hop.
    ///
    /// - SeeAlso: ``RadioPlayerCoordinator/notifyLayoutChange()``
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Only react to *width* changes. Height-only shifts (e.g. long metadata pushing
        // the contentStackView taller) must not retrigger needle positioning.
        // SwiftUI LanguageSelectorView uses matchedGeometryEffect; no manual notify needed.
        radioPlayerCoordinator.notifyLayoutChange()
    }

    // MARK: - Coordinator alert present settle

    /// Presents a coordinator-owned `UIAlertController` after any outgoing SwiftUI
    /// `.confirmationDialog` container has finished disappearing, then
    /// `layoutIfNeeded` on this host and the player hosting view.
    ///
    /// The sleep-timer dialog in `PlaybackControlsView` is a UIKit glass popover
    /// presented from ``playerHostingController``. Privacy-clear confirmation (and
    /// other coordinator alerts) present from this host. Presenting the UIKit alert
    /// while `GlassPopoverContentViewRepresentable` is still in the hierarchy fights
    /// `_UIAlertControllerPhoneTVMacView` content width (~357) against the popover’s
    /// autoresizing width 320. UIKit recovers by breaking the alert constraint; the
    /// dump is layout noise, not a policy to fight on the glass host.
    ///
    /// One extra `DispatchQueue.main.async` is not enough when a widget refresh and
    /// background-image CI share the main thread with popover teardown. This path
    /// waits for the hosting controller’s presented container to finish its dismiss
    /// transition (or leave the presented chain), yields one more run-loop turn, then
    /// lays out before `present(_:animated:)`.
    ///
    /// - Parameter alert: Coordinator-built alert (privacy confirm, security, SSL).
    /// - Important: Do not disable `PlaybackControlsView`’s `.confirmationDialog`.
    ///   Do not set `translatesAutoresizingMaskIntoConstraints` on UIKit’s glass host.
    ///   Do not call `dismiss` on SwiftUI’s popover — SwiftUI owns that teardown.
    /// - Note: A bounded display-frame poll waits for UIKit to *start* the dismiss
    ///   transition when the presented controller is still up and
    ///   `transitionCoordinator` is still nil. That poll is presentation settle, not
    ///   a playback clock.
    /// - SeeAlso: ``RadioPlayerCoordinator/confirmAndClearLocalState()``,
    ///   `PlaybackControlsView`, ``RadioPlayerCoordinator/presentAlert``,
    ///   docs/Widget-Presentation-Dataflow.md (Main-App Chrome Authority),
    ///   CODING_AGENT.md (thin UIKit host).
    func presentCoordinatorAlertAfterOutgoingPresentationSettles(_ alert: UIAlertController) {
        Task { @MainActor [weak self] in
            await self?.presentCoordinatorAlertAfterOutgoingPresentationSettlesAsync(alert)
        }
    }

    /// Waits for the outgoing confirmationDialog presentation to finish, then presents.
    ///
    /// - Parameter alert: Same alert passed to ``presentCoordinatorAlertAfterOutgoingPresentationSettles(_:)``.
    /// - SeeAlso: ``presentCoordinatorAlertAfterOutgoingPresentationSettles(_:)``
    private func presentCoordinatorAlertAfterOutgoingPresentationSettlesAsync(
        _ alert: UIAlertController
    ) async {
        guard !isDeallocating else { return }
        await waitForOutgoingCoordinatorAlertPresentationToFinish()
        guard !isDeallocating else { return }
        await yieldMainRunLoop()
        guard !isDeallocating else { return }
        view.layoutIfNeeded()
        playerHostingController.view.layoutIfNeeded()
        present(alert, animated: true)
    }

    /// Returns the presented controller that must disappear before a coordinator alert.
    ///
    /// SwiftUI `.confirmationDialog` presents from ``playerHostingController``, not
    /// from this host. A coordinator alert already on this host is also treated as
    /// outgoing so a second alert does not present mid-transition.
    ///
    /// - Returns: The top presented controller on the hosting controller or this host,
    ///   excluding the hosting controller itself (it is a child, not a presented card).
    /// - SeeAlso: ``presentCoordinatorAlertAfterOutgoingPresentationSettles(_:)``
    private func outgoingCoordinatorAlertPresentedViewController() -> UIViewController? {
        if let presented = topPresentedViewController(from: playerHostingController) {
            return presented
        }
        if let presented = topPresentedViewController(from: self),
           presented !== playerHostingController {
            return presented
        }
        return nil
    }

    /// Walks `presentedViewController` from `root` to the top of that chain.
    ///
    /// - Parameter root: Host or ``playerHostingController``.
    /// - Returns: The last presented controller, or `nil` when nothing is presented.
    private func topPresentedViewController(from root: UIViewController) -> UIViewController? {
        var current = root.presentedViewController
        var last: UIViewController?
        while let presented = current {
            last = presented
            current = presented.presentedViewController
        }
        return last
    }

    /// Suspends until the confirmationDialog container has disappeared, or the settle cap elapses.
    ///
    /// When a dismiss transition is already running, waits on its
    /// `transitionCoordinator` completion (the UIKit equivalent of the popover’s
    /// `viewDidDisappear`). When the presented controller is still up but the
    /// transition has not started, polls one display frame at a time so SwiftUI can
    /// begin teardown. After the cap, presents anyway so the user is not stuck.
    ///
    /// - SeeAlso: ``presentCoordinatorAlertAfterOutgoingPresentationSettles(_:)``
    private func waitForOutgoingCoordinatorAlertPresentationToFinish() async {
        var didLogWait = false
        for _ in 0..<CoordinatorAlertPresentationSettle.maxPolls {
            guard !isDeallocating else { return }
            guard let outgoing = outgoingCoordinatorAlertPresentedViewController() else {
                return
            }
            if !didLogWait {
                didLogWait = true
                #if DEBUG
                print("[ViewController] waiting for outgoing confirmationDialog container to finish before presenting coordinator alert")
                #endif
            }
            if let coordinator = outgoing.transitionCoordinator {
                await waitForTransitionCoordinatorToFinish(coordinator)
                continue
            }
            try? await Task.sleep(for: CoordinatorAlertPresentationSettle.pollFrame)
        }
        #if DEBUG
        if outgoingCoordinatorAlertPresentedViewController() != nil {
            print("[ViewController] presenting coordinator alert after outgoing-presentation settle timeout")
        }
        #endif
    }

    /// Resumes when `coordinator`’s transition completes (or immediately if UIKit refuses the alongside).
    ///
    /// - Parameter coordinator: The outgoing presented controller’s `transitionCoordinator`.
    /// - SeeAlso: ``waitForOutgoingCoordinatorAlertPresentationToFinish()``
    private func waitForTransitionCoordinatorToFinish(
        _ coordinator: any UIViewControllerTransitionCoordinator
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let started = coordinator.animate(alongsideTransition: nil, completion: { _ in
                continuation.resume()
            })
            if !started {
                continuation.resume()
            }
        }
    }

    /// One main-run-loop hop so constraint teardown after `presentedViewController == nil` can commit.
    ///
    /// - SeeAlso: ``presentCoordinatorAlertAfterOutgoingPresentationSettles(_:)``
    private func yieldMainRunLoop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}

/// Bounded wait for ``ViewController/presentCoordinatorAlertAfterOutgoingPresentationSettles(_:)``.
///
/// `pollFrame` is a display-frame poll until UIKit starts the confirmationDialog
/// dismiss transition — presentation settle, not a playback clock.
private enum CoordinatorAlertPresentationSettle {
    static let pollFrame: Duration = .milliseconds(16)
    /// ~0.75 s at 60 fps. ConfirmationDialog dismiss is typically 0.25–0.4 s;
    /// remaining frames cover CI / widget layout still holding the glass container.
    static let maxPolls = 45
}
