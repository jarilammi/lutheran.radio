//
//  ViewController+DarwinWidgetNotify.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.7.2026.
//
//  Darwin widget-notify domain for the thin UIKit host (mechanical split).
//
//  Owns: CF Darwin observer install/teardown for `radio.lutheran.widget.action`,
//  and the launch 1…5 s pending-action drain burst (``setupFastWidgetActionChecking``).
//
//  Delivery paths this domain wires:
//  - Primary: Darwin notify → main hop → ``checkForPendingWidgetActions()`` (coordinator drain)
//  - Defense-in-depth launch burst: 1…5 s `asyncAfter` drains after cold start
//  - Pause self-echo suppression via ``DarwinSelfEchoGuard`` (main app only)
//
//  Does **not** own:
//  - Pending-action drain / debounce / mailbox keys (``RadioPlayerCoordinator/checkForPendingWidgetActions()``)
//  - SceneDelegate become-active / foreground drain scheduling (calls the public host shim only)
//  - Posting Darwin notifies from the main app (``SharedPlayerManager`` media-transport surfaces)
//  - Visual/intent SSOT or engine attach
//
//  Stored teardown flag (``isDeallocating``) remains on the primary type body. Public drain
//  shim ``checkForPendingWidgetActions()`` stays on the primary file so SceneDelegate/tests
//  keep a stable one-line entry.
//
//  - SeeAlso: ``ViewController/checkForPendingWidgetActions()``,
//    ``RadioPlayerCoordinator/checkForPendingWidgetActions()``,
//    ``DarwinSelfEchoGuard``,
//    ViewController.swift (isolation map),
//    CODING_AGENT.md (Single Source of Truth Principles).
//

import UIKit

extension ViewController {

    // MARK: - Darwin widget notify + launch drain burst

    /// Installs the CF Darwin observer for cross-process widget pending-action wakeups.
    ///
    /// The callback hops to the main queue and calls the public drain shim
    /// ``checkForPendingWidgetActions()`` (coordinator owns drain + debounce + mailbox).
    /// Pause self-echoes posted by the main app are suppressed via ``DarwinSelfEchoGuard``.
    ///
    /// - Important: Pair with ``removeDarwinNotificationObserver()`` from `deinit` so a
    ///   recreated scene does not leave a dangling CF observer on `Unmanaged` of `self`.
    /// - SeeAlso: ``setupFastWidgetActionChecking()``, ``DarwinSelfEchoGuard``,
    ///   ``RadioPlayerCoordinator/checkForPendingWidgetActions()``
    func setupDarwinNotificationListener() {
        let notificationName = "radio.lutheran.widget.action"
        let center = CFNotificationCenterGetDarwinNotifyCenter()

        // SAFETY: CF Darwin notify requires an opaque observer pointer and a C callback.
        // `Unmanaged.passUnretained(self)` matches the remove path in
        // ``removeDarwinNotificationObserver()`` (same opaque identity). The callback only
        // hops to main and reads the host weakly via takeUnretainedValue — no retain cycle
        // with CF. A safer high-level API is not available for Darwin notify centers.
        unsafe CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (_, observer, _, _, _) in
                // SAFETY: Opaque pointer is the same Unmanaged passUnretained identity installed
                // above; CF only invokes while the observer is registered (removed in deinit).
                guard let observer = unsafe observer else { return }
                let vc = unsafe Unmanaged<ViewController>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    #if LUTHERAN_MAIN_APP
                    let hasPendingAction = SharedPlayerManager.shared.hasPendingWidgetAction()
                    if DarwinSelfEchoGuard.shouldSuppressPauseEcho(hasPendingAction: hasPendingAction) {
                        #if DEBUG
                        print("[ViewController] Ignoring self-posted Darwin pause notification echo")
                        #endif
                        return
                    }
                    #endif

                    #if DEBUG
                    print("[ViewController] Received Darwin notification for widget action")
                    #endif
                    // Thin lifecycle shim → coordinator owns drain + debounce + mailbox enqueue.
                    vc.checkForPendingWidgetActions()
                }
            },
            notificationName as CFString,
            nil,
            .deliverImmediately
        )

        #if DEBUG
        print("[ViewController] Darwin notification listener setup complete")
        #endif
    }

    /// Removes every Darwin observer registered with this host instance as the opaque context.
    ///
    /// Called from `deinit` only. Must use the same `Unmanaged.passUnretained(self)` identity
    /// as ``setupDarwinNotificationListener()``.
    ///
    /// - Important: `nonisolated` so Swift `deinit` (nonisolated) can call it. Body only
    ///   performs CF remove with the install opaque identity — no MainActor state.
    /// - SeeAlso: ``setupDarwinNotificationListener()``
    nonisolated func removeDarwinNotificationObserver() {
        // SAFETY: CF + Unmanaged is the only permitted remove path for the Darwin observer
        // installed in ``setupDarwinNotificationListener()``. Matches install opaque identity.
        // nonisolated: deinit cannot hop to MainActor; this is pure CF teardown.
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        unsafe CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Schedules a 1…5 s post-launch pending-action drain burst (defense-in-depth).
    ///
    /// Widget-action delivery does not use a repeating foreground poll timer. Primary path is
    /// Darwin notify → coordinator drain. This burst covers the cold-start window when a
    /// pending may already be in the App Group before the Darwin observer is live.
    ///
    /// SceneDelegate `sceneDidBecomeActive` / `sceneWillEnterForeground` also call the public
    /// drain shim; they are not owned by this domain.
    ///
    /// UITestMode: skip entirely so stale pendings from prior sessions cannot become "user input"
    /// and so unit-test hosts avoid scheduler noise. Coordinator drain still has a UITestMode
    /// drain-without-execute guard as defense-in-depth.
    ///
    /// - SeeAlso: ``setupDarwinNotificationListener()``, ``checkForPendingWidgetActions()``,
    ///   ``SharedPlayerManager/isRunningInUITestMode``
    func setupFastWidgetActionChecking() {
        if SharedPlayerManager.isRunningInUITestMode {
            #if DEBUG
            print("[ViewController] UITestMode — skipping fast widget action checking schedule")
            #endif
            return
        }

        // Check for widget actions every second for the first 5 seconds after app starts.
        // Uses repeated asyncAfter (no Timer, no mutable counter, no Sendable data-race issues).
        for i in 1...5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i)) { [weak self] in
                self?.checkForPendingWidgetActions()
                if i == 5 {
                    #if DEBUG
                    print("[ViewController] Fast widget action checking completed")
                    #endif
                }
            }
        }
    }
}
