//
//  ViewController+NetworkPathObservation.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.7.2026.
//
//  Engine path observation domain for the thin UIKit host (mechanical split).
//
//  Owns: host observation of the engine-owned path monitor for cellular expensive-path
//  prompt **presentation**, reconnect technical recovery (SPM.play), and disconnect
//  stop + no-internet chrome (``observeEngineNetworkPath``, sample handler, cellular alert,
//  ``handleNetworkReconnection``).
//
//  Ownership split (do not collapse casually):
//  - **Engine** (``DirectStreamingPlayer/setupNetworkMonitoring()``): sole free-running
//    `NWPathMonitor`, ``hasInternetConnection``, publish via ``onNetworkPathChange``.
//  - **Host (this domain):** UI chrome + cellular alert presentation only — never a second
//    monitor or HTTP connectivity probe timer.
//  - **CellularPermissionManager:** ternary preference decision + persistence (migration-only
//    legacy bool). Host presents the alert; manager owns the durable ask/always/session SSOT.
//  - **SharedPlayerManager:** sticky intent / technical recovery via ``play()`` (never
//    ``userRequestedPlay()`` on reconnect — resurrection hazard).
//
//  Does **not** own:
//  - Path monitor lifecycle or streaming retries (engine)
//  - Security model validation policy (Core via ``SecurityValidationFacade`` call sites only)
//  - Visual/intent SSOT, widget snapshots
//  - Host-local `isPlaying` or parallel connectivity bool (never reintroduce)
//
//  Stored stamps (``cellularPermissionManager``, ``isDeallocating``, ``streamingPlayer``)
//  remain on the primary type body; this file owns the behavior that uses them for path chrome.
//
//  - SeeAlso: ``DirectStreamingPlayer/onNetworkPathChange``,
//    ``DirectStreamingPlayer/setupNetworkMonitoring()``,
//    ``CellularPermissionManager``,
//    ``SharedPlayerManager/play()``, ``SharedPlayerManager/canProceedWithPlayback()``,
//    ``SecurityValidationFacade``,
//    ViewController.swift (isolation map),
//    CODING_AGENT.md (Single Source of Truth Principles).
//

import UIKit

extension ViewController {

    // MARK: - Engine path observation (cellular prompt + reconnect/stop chrome)

    /// Observes the engine-owned path monitor for host chrome only.
    ///
    /// **Ownership:** ``DirectStreamingPlayer/setupNetworkMonitoring()`` owns the sole
    /// free-running `NWPathMonitor` and ``DirectStreamingPlayer/hasInternetConnection``.
    /// This host must not start a second monitor or a periodic HTTP connectivity probe.
    ///
    /// On each published sample (main queue):
    /// 1. Cellular expensive-path prompt via ``CellularPermissionManager`` (presentation only).
    /// 2. Reconnect edge → technical recovery via ``handleNetworkReconnection()`` (SPM.play).
    /// 3. Disconnect edge → SPM stop + no-internet chrome (intent preserved on actor).
    ///
    /// - Precondition: Not called under UITestMode (caller guards).
    /// - SeeAlso: ``DirectStreamingPlayer/onNetworkPathChange``, ``handleNetworkReconnection()``,
    ///   ``CellularPermissionManager``, CODING_AGENT.md (SSOT)
    func observeEngineNetworkPath() {
        if SharedPlayerManager.isRunningInUITestMode {
            #if DEBUG
            print("[ViewController] UITestMode — skipping engine path observation")
            #endif
            return
        }
        #if DEBUG
        print("[ViewController] Observing engine network path (no host NWPathMonitor)")
        #endif
        streamingPlayer.onNetworkPathChange = { [weak self] isConnected, isExpensive, wasConnected in
            // Engine publishes on the main queue; hop to @MainActor for host state / alerts.
            Task { @MainActor [weak self] in
                self?.handleEngineNetworkPathUpdate(
                    isConnected: isConnected,
                    isExpensive: isExpensive,
                    wasConnected: wasConnected
                )
            }
        }

        // Engine monitor starts at façade init (before this host exists). Deliver one
        // non-edge snapshot so the cellular expensive-path prompt can still fire when
        // launch is already on a metered path without waiting for a path flap.
        let isConnected = streamingPlayer.hasInternetConnection
        let isExpensive = streamingPlayer.networkMonitor?.currentPath?.isExpensive
            ?? streamingPlayer.pathMonitor.currentPath?.isExpensive
            ?? false
        handleEngineNetworkPathUpdate(
            isConnected: isConnected,
            isExpensive: isExpensive,
            wasConnected: isConnected
        )
    }

    /// Applies one path sample for cellular prompt + reconnect/disconnect host chrome.
    ///
    /// - Parameters:
    ///   - isConnected: Current engine reachability (`status == .satisfied`).
    ///   - isExpensive: Metered/cellular path for ``CellularPermissionManager`` gates.
    ///   - wasConnected: Prior connected flag; equal to `isConnected` for non-edge snapshots
    ///     (initial attach) so reconnect/stop edges do not fire spuriously.
    /// - SeeAlso: ``observeEngineNetworkPath()``, ``DirectStreamingPlayer/onNetworkPathChange``
    func handleEngineNetworkPathUpdate(isConnected: Bool, isExpensive: Bool, wasConnected: Bool) {
        guard !isDeallocating else { return }

        // Cellular / metered data permission prompt (ternary prefs in CellularPermissionManager).
        if cellularPermissionManager.shouldShowPrompt(isConnected: isConnected, isExpensive: isExpensive) {
            showCellularDataAlert()
            cellularPermissionManager.markPromptedThisLaunch()
        }

        #if DEBUG
        print("[ViewController] Engine path update: connected=\(isConnected) expensive=\(isExpensive) wasConnected=\(wasConnected)")
        #endif

        if isConnected && !wasConnected {
            #if DEBUG
            print("[ViewController] Engine path reconnection — SPM technical recovery")
            #endif
            radioPlayerCoordinator.stopTuningSound()
            handleNetworkReconnection()
        } else if !isConnected && wasConnected {
            #if DEBUG
            print("[ViewController] Engine path disconnect — stop playback + no-internet chrome")
            #endif
            radioPlayerCoordinator.stopTuningSound()
            // Sticky stop via coordinator → SPM.stop() so intent becomes .userPaused surfaces
            // correctly; path loss is not a technical soft-pause (user must re-play after offline).
            radioPlayerCoordinator.stopPlayback()
            radioPlayerCoordinator.updateUIForNoInternet()
        }
    }

    /// Presents the cellular / metered data usage permission alert (presentation only).
    ///
    /// Ternary preference writes and per-launch prompt bookkeeping stay in
    /// ``CellularPermissionManager``. "Not Now" sticky-stops via coordinator so intent
    /// becomes `.userPaused` and widgets/LA update; the prompt reappears next launch for `.ask`.
    ///
    /// - SeeAlso: ``CellularPermissionManager``, ``observeEngineNetworkPath()``
    func showCellularDataAlert() {
        let alert = UIAlertController(
            title: String(localized: "mobile_data_usage_title", table: "Localizable"),
            message: String(localized: "mobile_data_usage_message", table: "Localizable"),
            preferredStyle: .alert
        )

        // "Always Allow" — persist .alwaysAllow and allow playback on cellular.
        alert.addAction(UIAlertAction(title: String(localized: "cellular_always_allow", table: "Localizable"), style: .default) { [weak self] _ in
            guard let self else { return }
            self.cellularPermissionManager.setAlwaysAllow()
            self.cellularPermissionManager.markPromptedThisLaunch()
        })

        // "Allow for This Session" — in-memory only until next launch; no permanent write beyond the session flag.
        alert.addAction(UIAlertAction(title: String(localized: "cellular_allow_this_session", table: "Localizable"), style: .default) { [weak self] _ in
            guard let self else { return }
            self.cellularPermissionManager.setSessionAllow()
            self.cellularPermissionManager.markPromptedThisLaunch()
        })

        // "Not Now" — treat as explicit user pause for this launch on cellular; stop via SSOT so intent becomes .userPaused,
        // widgets/Live Activities update, and no auto-resurrection until next explicit user play. Prompt will re-appear on next launch for .ask.
        alert.addAction(UIAlertAction(title: String(localized: "cellular_not_now", table: "Localizable"), style: .cancel) { [weak self] _ in
            guard let self else { return }
            self.cellularPermissionManager.setAsk()
            self.cellularPermissionManager.markPromptedThisLaunch()
            self.radioPlayerCoordinator.stopPlayback()
        })

        present(alert, animated: true, completion: nil)
    }

    /// Handles network reconnection by re-validating the security model and conditionally resuming playback.
    ///
    /// Invoked from ``observeEngineNetworkPath()`` when the engine publishes
    /// `isConnected && !wasConnected` (sole free-running path monitor on
    /// ``DirectStreamingPlayer``). There is no host-side HTTP probe fallback.
    ///
    /// Flow:
    /// 1. Align engine ``hasInternetConnection`` to true (edge already set by path handler).
    /// 2. Reset transient streaming errors on the engine.
    /// 3. Perform explicit security re-validation via named reconnect intent (Core policy).
    /// 4. On success **and** only if `currentPlaybackIntent` permits (`canProceedWithPlayback`),
    ///    call `SharedPlayerManager.play()` (technical recovery path for full visual/widget surfaces).
    /// 5. On validation failure, present a one-time security alert (if none is already shown).
    ///
    /// - Important: Reconnection is a **technical recovery**, not an explicit user play/resume.
    ///   It must never call `userRequestedPlay()`. Doing so would invoke `setUserIntentToPlay()`,
    ///   clearing any `.userPaused`, `.cleared`, or similar sticky lock and violating the
    ///   resurrection protection contract.
    /// - Precondition: Called only on the main actor (engine path publish + host observer).
    /// - Postcondition: If playback resumes, it does so through the authoritative SPM path
    ///   (visual state, persistence, Now Playing, and widget/LA snapshots are updated by `play()`).
    ///   If intent is `.userPaused` / `.securityLocked` / `.cleared`, no playback is started.
    /// - Note: The explicit validation success check is the preserved reconnection trigger.
    ///   `SPM.play()` will validate again internally (safe). Engine-side reconnect may also
    ///   call `DirectStreamingPlayer.play()` when rate is zero; both paths honor `canProceed`.
    /// - SeeAlso: ``SharedPlayerManager/play()``, ``SharedPlayerManager/userRequestedPlay()``,
    ///   ``SharedPlayerManager/canProceedWithPlayback()``, ``SharedPlayerManager/currentPlaybackIntent``,
    ///   `DirectStreamingPlayer.resetTransientErrors()`, ``DirectStreamingPlayer/onNetworkPathChange``,
    ///   ``observeEngineNetworkPath()``, RadioPlayerCoordinator recovery patterns,
    ///   <doc:Architecture>, CODING_AGENT.md (Single Source of Truth Principles + permitted `play()` cases).
    ///
    /// AGENT NOTE: Prior to the intent model, this method performed the direct low-level call
    /// `_ = await self.streamingPlayer.play()` inside the `if isValid` block. That bypassed
    /// `currentPlaybackIntent`, `canProceedWithPlayback`, `setPlaying` / visual updates,
    /// `saveCurrentState` (widgets, Live Activities, Now Playing), and the single source of truth
    /// for resurrection. The current pattern (`canProceed ? SPM.play() : nothing`) is the correct
    /// technical-recovery usage of the permitted direct `play()` case. `userRequestedPlay()`
    /// is deliberately reserved for button taps, widget play actions, remote commands, Siri, etc.
    func handleNetworkReconnection() {
        if SharedPlayerManager.isRunningInUITestMode {
            return
        }
        // Path handler already set the flag; keep explicit align for defensive consistency.
        streamingPlayer.hasInternetConnection = true

        #if DEBUG
        print("[ViewController] Network reconnected - checking validation state")
        #endif

        Task { @MainActor in
            // 1. Reset transient failures
            self.streamingPlayer.resetTransientErrors()

            // 2. Re-validate via named reconnect intent (Core policy unchanged).
            //    Success remains the preserved trigger for reconnection playback.
            let isValid = await SecurityValidationFacade.validate(.onReconnect)

            if isValid {
                #if DEBUG
                print("[ViewController] Validation succeeded after reconnection - attempting playback (via SPM.play for intent consistency)")
                #endif

                // Recovery after network: call through SPM.play() (permitted technical recovery path)
                // rather than raw engine play(). The canProceed guard ensures we only proceed for
                // active intents (.shouldBePlaying); sticky states (.userPaused, .securityLocked,
                // .cleared) cause an early return here and we never reach clearUserPausedLockIfNeeded
                // inside play().
                //
                // Contrast with userRequestedPlay(), which always does setUserIntentToPlay() first.
                // Using that here would incorrectly resurrect after an explicit user pause.
                if await SharedPlayerManager.shared.canProceedWithPlayback() {
                    await SharedPlayerManager.shared.play()
                }

            } else {
                #if DEBUG
                print("[ViewController] Security model validation failed after reconnection")
                #endif

                // Show alert only if not already presenting one (security error path unchanged)
                if presentedViewController == nil {
                    let alert = UIAlertController(
                        title: String(localized: "security_model_error_title", table: "Localizable"),
                        message: String(localized: "security_model_error_message", table: "Localizable"),
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: String(localized: "ok", table: "Localizable"), style: .default))
                    present(alert, animated: true)
                }
            }
        }
    }

    /// Clears the host path-change callback so a recreated scene does not leave a dangling
    /// observer on the shared engine. Monitor lifecycle itself stays engine-owned.
    ///
    /// Called from `deinit` on the primary type body. `nonisolated` so Swift `deinit` can
    /// invoke it; body only nulls the optional callback — no MainActor state.
    ///
    /// - SeeAlso: ``observeEngineNetworkPath()``, ``DirectStreamingPlayer/onNetworkPathChange``
    nonisolated func clearEngineNetworkPathObservation() {
        streamingPlayer.onNetworkPathChange = nil
    }
}
