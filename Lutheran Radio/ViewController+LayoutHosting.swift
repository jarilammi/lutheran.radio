//
//  ViewController+LayoutHosting.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.7.2026.
//
//  Layout hosting domain for the thin UIKit host (mechanical split).
//
//  Owns: single `UIHostingController` hierarchy install for `RadioPlayerView`
//  (``setupUI``) and layout-pass forwarding to the coordinator
//  (``viewDidLayoutSubviews`` → ``RadioPlayerCoordinator/notifyLayoutChange()``).
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
//  install + layout-pass behavior that uses them.
//
//  - SeeAlso: ``RadioPlayerView``, ``BackgroundImageController``,
//    ``RadioPlayerCoordinator/notifyLayoutChange()``,
//    ViewController.swift (isolation map),
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
}
