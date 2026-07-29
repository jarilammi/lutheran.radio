//
//  RadioPlayerCoordinator+StatusDistribution.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.7.2026.
//
//  Status / chrome distribution domain for RadioPlayerCoordinator (mechanical split).
//
//  Owns: applying `PlayerVisualState` to in-app chrome (`updateUI`), engine status
//  choke point (`handleStatusChange`), pure chrome resolver
//  (`RadioPlayerChromeVisualResolver`), VM metadata/switch-flag sync, no-internet
//  chrome, Now Playing / widget save thin forwarders, legacy status-label allowlist
//  announcements, and thermal enter/exit VoiceOver on the modern chrome path.
//
//  Does not own: play/pause toggle shims (primary coordinator file), stream-switch
//  orchestration (`+StreamSwitch` calls into this domain for chrome), pending-action
//  drain (`+PendingActions`), sleep-timer glue (`+SleepTimer`), tuning clips
//  (`+Tuning`), privacy clear dialog (primary file — nulls `lastAppliedVisualState`
//  then calls `updateUI`), engine rate pause / attach (DirectStreamingPlayer), or
//  visual/intent SSOT (SharedPlayerManager).
//
//  Stored chrome stamps (`lastAppliedVisualState`, `hasShownSecurityAlert`,
//  `hasEverPlayed`) remain on the primary type body (extensions cannot declare
//  stored properties); this file owns the behavior that mutates them.
//
//  Public/entry surfaces on the same type:
//  - ``updateUI(for:)`` — paint chrome from a resolved visual
//  - ``handleStatusChange(_:reasonKey:)`` — StreamingPlayerDelegate hop (via host)
//  - ``updateUIForNoInternet()`` — airplane / path-loss chrome
//  - ``updateNowPlayingInfo(title:)`` / ``saveStateForWidget()`` — thin SPM forwarders
//    (`title:` re-enters ICY SSOT; prefer engine ``safeOnMetadataChange`` for live StreamTitle)
//  - ``setIsSwitchingStream(_:)`` / ``syncMetadataToViewModel(_:)`` — VM bridge
//  - ``safeUpdateStatusLabel(text:backgroundColor:textColor:isPermanentError:)``
//
//  Pure resolver (same module, free type):
//  - ``RadioPlayerChromeVisualResolver`` — engine status → chrome visual (unit-tested)
//
//  - SeeAlso: ``DirectStreamingPlayer/safeOnStatusChange``,
//    ``DirectStreamingPlayer/safeOnMetadataChange(metadata:)``,
//    ``SharedPlayerManager/setPlaying()``, ``SharedPlayerManager/currentVisualState``,
//    ``SharedPlayerManager/didUpdateStreamMetadata(_:)``,
//    RadioPlayerCoordinator.swift (isolation map),
//    docs/Live-Activity-Stacking-and-Media-Surfaces.md (ICY single-owner path),
//    CODING_AGENT.md (Single Source of Truth Principles).
//

import UIKit
import Core
import WidgetSurface

extension RadioPlayerCoordinator {

    // MARK: - Update distribution (single place for visual state application to all subviews)

    /// Applies a `PlayerVisualState` to in-app chrome (SwiftUI `PlayerViewModel` + security alert).
    ///
    /// Dedupes consecutive identical states via `lastAppliedVisualState` so connecting/buffering
    /// chatter does not thrash the pill. Authoritative promotion to `.playing` after deferred
    /// Connecting is decided in ``handleStatusChange(_:reasonKey:)`` /
    /// ``RadioPlayerChromeVisualResolver`` — this method only paints what it is given.
    ///
    /// VoiceOver: thermal enter/exit is announced here (modern chrome SSOT) via
    /// ``announceThermalVisualTransition(from:to:)`` so `status_thermal_paused` is spoken
    /// without requiring focus on the status pill. Other status strings continue to use the
    /// legacy `safeUpdateStatusLabel` allowlist where that path still runs.
    ///
    /// - Parameter visualState: Chrome visual to apply (not necessarily equal to SPM yet during
    ///   the deferred ``setPlaying()`` window).
    /// - SeeAlso: ``handleStatusChange(_:reasonKey:)``, ``RadioPlayerChromeVisualResolver``,
    ///   ``announceThermalVisualTransition(from:to:)``, `PlayerViewModel`,
    ///   CODING_AGENT.md (Single Source of Truth Principles).
    @MainActor
    func updateUI(for visualState: PlayerVisualState) {
        if lastAppliedVisualState == visualState {
            #if DEBUG
            print("[RadioPlayerCoordinator] updateUI → skipped (already applied \(visualState))")
            #endif
            return
        }
        let previousVisualState = lastAppliedVisualState
        lastAppliedVisualState = visualState

        // Pure SwiftUI views are driven via viewModel (pushed below).
        // // playbackControlsView.applyVisualState was UIKit path.

        // Drive the SwiftUI observable model (if wired).
        // This is the primary hand-off point so that SwiftUI reacts with the same
        // visual state the UIKit chrome just received. Coordinator owns timing.
        if let vm = viewModel {
            vm.visualState = visualState
            vm.selectedStreamIndex = selectedStreamIndex
            if visualState == .securityLocked {
                vm.isShowingSecurityError = true
                vm.lastErrorMessage = String(localized: "security_model_error_message", table: "Localizable")
            } else if vm.isShowingSecurityError {
                // Clear transient error surface on recovery to non-locked state
                vm.isShowingSecurityError = false
            }
        }

        if visualState == .securityLocked {
            if !hasShownSecurityAlert {
                hasShownSecurityAlert = true
                // Route alert presentation through injected hook (keeps security alert presentation site in host if desired;
                // the decision to show on this state transition lives here with the visual update).
                let alert = UIAlertController(
                    title: String(localized: "security_model_error_title", table: "Localizable"),
                    message: String(localized: "security_model_error_message", table: "Localizable"),
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "alert_retry", table: "Localizable"), style: .default, handler: { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in
                        self.streamingPlayer.resetTransientErrors()
                        let isValid = await SecurityValidationFacade.validate(.securityRetry)
                        if isValid {
                            await SharedPlayerManager.shared.userRequestedPlay()
                        } else {
                            let isPermanent = await SecurityValidationFacade.isPermanentlyInvalid()
                            #if DEBUG
                            print("[RadioPlayerCoordinator] Retry failed — permanent? \(isPermanent)")
                            #endif
                        }
                    }
                }))
                alert.addAction(UIAlertAction(title: String(localized: "ok", table: "Localizable"), style: .cancel, handler: nil))
                presentAlert?(alert)
            }
        }

        // Thermal pause is involuntary hardware chrome — announce enter/exit so VoiceOver
        // users hear `status_thermal_paused` / recovery without focusing the status pill.
        // Dedupe above ensures we only announce real transitions.
        announceThermalVisualTransition(from: previousVisualState, to: visualState)

        #if DEBUG
        print("[RadioPlayerCoordinator] updateUI → applied \(visualState) (bg=\(visualState.backgroundColor), tint=\(visualState.buttonTintColor))")
        #endif
    }

    // MARK: - VM sync helpers (coordinator remains driver)

    /// Pushes the stream-switching flag to both the legacy DirectStreamingPlayer and (if present) the SwiftUI VM.
    /// Call sites that set `streamingPlayer.isSwitchingStream` should prefer or also call this when a VM is active.
    @MainActor
    func setIsSwitchingStream(_ value: Bool) {
        streamingPlayer.isSwitchingStream = value
        viewModel?.isSwitchingStream = value
    }

    /// Pushes parsed metadata into the observable model (coordinator or VC call sites can use this).
    @MainActor
    func syncMetadataToViewModel(_ raw: String?) {
        if let raw {
            viewModel?.currentMetadata = StreamProgramMetadata.from(rawICYMetadata: raw)
        } else {
            viewModel?.currentMetadata = nil
        }
    }

    func updateUIForNoInternet() {
        safeUpdateStatusLabel(
            text: String(localized: "status_no_internet", table: "Localizable"),
            backgroundColor: .systemGray,
            textColor: .white,
            isPermanentError: false
        )
        // Metadata + play/pause glyph now driven by VM for SwiftUI views.
        viewModel?.currentMetadata = nil
        // visualState update will cause the controls to show correct glyph.
    }

    /// Thin Now Playing refresh (and optional ICY SSOT write) for host call sites.
    ///
    /// - Parameter title: When non-`nil`, re-enters ``SharedPlayerManager/didUpdateStreamMetadata(_:)``.
    ///   **Live ICY must not use this** — the engine already owns that path via
    ///   ``DirectStreamingPlayer/safeOnMetadataChange(metadata:)``. Prefer `title: nil` (or omit)
    ///   to refresh system Now Playing from the existing stash after language/visual mutations.
    /// - SeeAlso: ``SharedPlayerManager/updateNowPlayingInfo()``,
    ///   ``SharedPlayerManager/didUpdateStreamMetadata(_:)``,
    ///   ``DirectStreamingPlayer/safeOnMetadataChange(metadata:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
    func updateNowPlayingInfo(title: String? = nil) {
        #if LUTHERAN_MAIN_APP
        Task {
            if let title {
                // Escape hatch only — not the live StreamTitle path (engine SSOT).
                await SharedPlayerManager.shared.didUpdateStreamMetadata(title)
            } else {
                await SharedPlayerManager.shared.updateNowPlayingInfo()
            }
        }
        #endif
    }

    func saveStateForWidget() {
        Task {
            await SharedPlayerManager.shared.saveCurrentState()
        }
    }

    func safeUpdateStatusLabel(text: String, backgroundColor: UIColor, textColor: UIColor, isPermanentError: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // VM drives SwiftUI status pill
            viewModel?.visualState = .prePlay // placeholder; real state comes from caller

            if text != String(localized: "status_playing", table: "Localizable") {
                self.saveStateForWidget()
            }

            let importantStatuses: Set<String> = [
                String(localized: "status_connecting", table: "Localizable"),
                String(localized: "status_playing", table: "Localizable"),
                String(localized: "status_paused", table: "Localizable"),
                String(localized: "status_paused_call", table: "Localizable"),
                String(localized: "status_no_internet", table: "Localizable"),
                String(localized: "status_stream_unavailable", table: "Localizable"),
                String(localized: "status_failed", table: "Localizable"),
                String(localized: "status_security_failed", table: "Localizable"),
                String(localized: "status_stopped", table: "Localizable"),
                String(localized: "status_ssl_transition", table: "Localizable")
            ]

            if importantStatuses.contains(text) {
                unsafe UIAccessibility.post(notification: .announcement, argument: text)
            }
        }
    }

    // MARK: - Accessibility announcements (status chrome)

    // Language-switch VoiceOver announce lives in RadioPlayerCoordinator+StreamSwitch.swift.

    /// Announces thermal pause enter/exit on the modern ``updateUI(for:)`` chrome path.
    ///
    /// Keeps `status_thermal_paused` active for VoiceOver without requiring focus on the
    /// status pill. Sighted users already see the orange "Device hot" pill via
    /// ``PlayerVisualState/makeStatusPresentation()``; this only adds a proactive
    /// announcement for non-sighted users when the hardware gate flips.
    ///
    /// - Parameters:
    ///   - previous: Visual applied before this transition (`nil` on first paint).
    ///   - next: Visual being applied now (already deduped by ``updateUI(for:)``).
    /// - Note: Enter posts the catalog thermal string. Leave posts the destination
    ///   status-pill text (Play / Pause / …) so recovery is spoken once from this SSOT.
    /// - SeeAlso: ``updateUI(for:)``, ``PlayerVisualState/thermalPaused``,
    ///   `status_thermal_paused` in `Localizable.xcstrings`, CODING_AGENT.md.
    private func announceThermalVisualTransition(from previous: PlayerVisualState?, to next: PlayerVisualState) {
        let message: String?
        if next == .thermalPaused {
            // Enter thermal: speak the same short status string the pill shows.
            message = String(localized: "status_thermal_paused", table: "Localizable")
        } else if previous == .thermalPaused {
            // Leave thermal: speak the destination chrome status (e.g. Play after auto-resume).
            message = next.makeStatusPresentation().text
        } else {
            message = nil
        }
        guard let message, !message.isEmpty else { return }
        // SAFETY: UIAccessibility.post is the established VoiceOver announcement API
        // (same pattern as `announceSwitchedToLanguage` and post-clear `clear_local_state_done`).
        unsafe UIAccessibility.post(notification: .announcement, argument: message)
    }

    // MARK: - Streaming status distribution entry (called from VC's StreamingPlayerDelegate hop)

    /// Receives every status update from the streaming engine and decides UI, visual state,
    /// alerts, and widget/Live Activity side effects.
    ///
    /// This is the central choke point for mapping low-level `PlayerStatus` + `reasonKey`
    /// (from `DirectStreamingPlayer.safeOnStatusChange`) into high-level `PlayerVisualState`
    /// and user-visible surfaces via ``RadioPlayerChromeVisualResolver``.
    ///
    /// **Connecting-until-audible chrome:** While the start pipeline is active, SPM holds
    /// `.prePlay` until engine ``setPlaying()`` / `publishAuthoritativePlayingIfNeeded`.
    /// Engine `status_playing` can arrive on MainActor **before** that actor mutation is
    /// visible. Chrome must still promote to `.playing` promptly — freezing `.prePlay` here
    /// leaves the in-app pill yellow while audio and Live Activity already show playing.
    /// Sticky `.userPaused` / `.cleared` / policy chrome remain protected.
    ///
    /// Special handling exists for transient states (connecting/buffering preserve optimistic
    /// prePlay/playing, with an engine-audible race guard) and for explicit user pauses. The
    /// unavailable/failed reaction includes an `isInInitialRecoveryWindow` guard so that normal
    /// self-healing ICY decoder noise immediately after a language switch (or cold launch)
    /// does not force `.userPaused` + alert.
    ///
    /// - Parameters:
    ///   - status: Coarse player status.
    ///   - reasonKey: Exact Localizable key (e.g. "status_playing", "status_stream_unavailable").
    ///     Used both for localization and for precise branching.
    ///
    /// - SeeAlso: ``RadioPlayerChromeVisualResolver/resolve(status:reasonKey:visualState:playbackIntent:engineIsActuallyPlaying:)``,
    ///   `DirectStreamingPlayer.safeOnStatusChange`, `handleItemStatusFailure(_:)`,
    ///   `streamingPlayer.isInInitialRecoveryWindow`, `SharedPlayerManager.markPlaybackStoppedByStreamFailure`,
    ///   `SharedPlayerManager.setPlaying()`, `updateUI(for:)`, CODING_AGENT.md (transient vs permanent modeling)
    func handleStatusChange(_ status: PlayerStatus, reasonKey: String?) async {
        let visualState = await SharedPlayerManager.shared.currentVisualState
        let playbackIntent = await SharedPlayerManager.shared.currentPlaybackIntent
        // Engine-truth for the deferred-setPlaying race: status_playing / brief buffer while
        // rate is already 1 must not re-stick Connecting chrome before SPM flips to `.playing`.
        let engineIsActuallyPlaying = streamingPlayer.isActuallyPlaying()

        #if DEBUG
        print("[RadioPlayerCoordinator] onStatusChange → \(status) (reasonKey: \(reasonKey ?? "nil")) → visualState \(visualState) enginePlaying=\(engineIsActuallyPlaying)")
        #endif

        let effectiveVisualState = RadioPlayerChromeVisualResolver.resolve(
            status: status,
            reasonKey: reasonKey,
            visualState: visualState,
            playbackIntent: playbackIntent,
            engineIsActuallyPlaying: engineIsActuallyPlaying
        )

        #if DEBUG
        if effectiveVisualState == .playing
            && visualState == .prePlay
            && (reasonKey == "status_playing" || engineIsActuallyPlaying) {
            print("[RadioPlayerCoordinator] in-app chrome → .playing while SPM still .prePlay (deferred setPlaying race; engine audible)")
            MediaTransportLatencyTimeline.mark(
                .inAppChromeAppliedPlaying,
                detail: "spmVisual=prePlay reasonKey=\(reasonKey ?? "nil")"
            )
        }
        #endif

        self.updateUI(for: effectiveVisualState)

        // If we had to correct the UI to .userPaused for a real sticky user pause (despite the
        // actor having loaded a stale .prePlay), repair the in-memory SSOT immediately so that
        // any follow-on save uses the correct visual.
        // Never do this repair for .cleared (the post-reset visual).
        if effectiveVisualState == .userPaused && visualState == .prePlay && playbackIntent == .userPaused {
            Task {
                await SharedPlayerManager.shared.setVisualState(.userPaused)
            }
        }

        if let reasonKey = reasonKey {
            if reasonKey == "status_ssl_transition" {
                // Status pill color updated via VM / SwiftUI in updateUI.

                // Present via hook (alert creation kept close to original site for mechanical fidelity)
                let alert = UIAlertController(
                    title: String(localized: "ssl_transition_title", table: "Localizable"),
                    message: String(localized: "ssl_transition_message", table: "Localizable"),
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "alert_continue", table: "Localizable"), style: .default, handler: { [weak self] _ in
                    guard self != nil else { return }
                    Task { @MainActor in
                        await SharedPlayerManager.shared.userRequestedPlay()
                    }
                }))
                alert.addAction(UIAlertAction(title: String(localized: "ok", table: "Localizable"), style: .cancel, handler: nil))
                presentAlert?(alert)

            } else if reasonKey == "status_no_internet" {
                // Status handled in updateUIForNoInternet via VM.
                self.updateUIForNoInternet()

            } else if reasonKey == "status_stream_unavailable" || reasonKey == "status_failed" {
                // After `switchToStream` + `resetInitialPlaybackCountersForNewStream`, the player
                // gives the new item a fresh retry budget. Live ICY framing/decoder noise on the
                // first packets is recovered silently by secured `recreatePlayerItem()`
                // (`handleItemStatusFailure`, buffer/timeControl observers, resource loader).
                //
                // While `isInInitialRecoveryWindow` is true, suppress grey-pause mutation and the
                // stream-unavailable alert. A later `status_playing` advances the UI without a flash.
                //
                // Defensive: engine paths already avoid severe keys for early transients; the
                // window check keeps the contract at the UI layer if a fallback still emits them.
                if streamingPlayer.isInInitialRecoveryWindow {
                    #if DEBUG
                    print("[RadioPlayerCoordinator] Suppressing unavailable/failed reaction — streamingPlayer.isInInitialRecoveryWindow (transient ICY noise on fresh post-switch/cold item)")
                    #endif
                } else {
                    let vsForCheck = await SharedPlayerManager.shared.currentVisualState
                    if vsForCheck.isActivelyPlaying || vsForCheck == .prePlay {
                        // Preserves playback intent (`.shouldBePlaying` / `.sleepTimer`) so a
                        // subsequent language switch auto-resumes without an extra play tap.
                        await SharedPlayerManager.shared.markPlaybackStoppedByStreamFailure()
                    }
                    let correctedVisualState = await SharedPlayerManager.shared.currentVisualState
                    self.updateUI(for: correctedVisualState)

                    if let vc = viewController, vc.presentedViewController == nil {
                        let alert = UIAlertController(
                            title: String(localized: "stream_unavailable_title", table: "Localizable"),
                            message: String(localized: "stream_unavailable_message", table: "Localizable"),
                            preferredStyle: .alert
                        )
                        alert.addAction(UIAlertAction(title: String(localized: "alert_retry", table: "Localizable"), style: .default) { _ in
                            Task { @MainActor in
                                await SharedPlayerManager.shared.userRequestedPlay()
                            }
                        })
                        alert.addAction(UIAlertAction(title: String(localized: "ok", table: "Localizable"), style: .cancel, handler: nil))
                        presentAlert?(alert)
                    }
                }
            }
        }

        if status == .playing {
            hasEverPlayed = true

            if reasonKey == nil {
                playHapticFeedback(style: .light)
            }

            if reasonKey == "status_playing" {
                self.backgroundImageController.scheduleDeferredFlushIfNeeded()
            }
        }

        saveStateForWidget()
    }
}

// MARK: - In-app chrome visual resolver (engine status → pill / glyph)

/// Pure mapping from streaming-engine status callbacks into the in-app chrome `PlayerVisualState`.
///
/// ``RadioPlayerCoordinator/handleStatusChange(_:reasonKey:)`` is the sole production call site.
/// Logic lives here so unit tests can assert Connecting-until-audible, sticky pause, and privacy
/// clear contracts without constructing a full UIKit host or driving `AVPlayer`.
///
/// ## Why this is not a dumb pass-through of SPM visual
///
/// SharedPlayerManager defers authoritative ``setPlaying()`` until soft-resume rate kick or
/// readyToPlay first-play kick (`publishAuthoritativePlayingIfNeeded`). Engine
/// `status_playing` is delivered via `DispatchQueue.main.async` and can interleave **before**
/// the SPM actor mutation is visible. Freezing chrome on SPM `.prePlay` in that window leaves
/// the main-app pill yellow (Connecting) while audio is live and Live Activity / Now Playing
/// already show playing.
///
/// Holding `.prePlay` during **true** Connecting (`status_connecting` / buffering while the
/// engine is not audibly playing) remains correct.
///
/// ## Sticky / policy protection (must not regress)
///
/// - `.userPaused` visual or intent on terminal stop/pause keys → grey pause chrome.
/// - `.cleared` intent (privacy clear) → blue cleared chrome for any residual engine chatter.
/// - `.securityLocked` / `.thermalPaused` while those visuals are authoritative → keep policy chrome
///   even if a late `status_playing` races in (engine kick should already be suppressed).
///
/// - SeeAlso: ``RadioPlayerCoordinator/handleStatusChange(_:reasonKey:)``,
///   ``SharedPlayerManager/setPlaying()``, `DirectStreamingPlayer.publishAuthoritativePlayingIfNeeded`,
///   `PlayerVisualState`, CODING_AGENT.md (Single Source of Truth Principles).
enum RadioPlayerChromeVisualResolver: Sendable {

    /// Resolves the chrome visual that ``RadioPlayerCoordinator/updateUI(for:)`` should apply.
    ///
    /// - Parameters:
    ///   - status: Coarse `PlayerStatus` from the streaming delegate (note: `status_connecting` is
    ///     often delivered with `isPlaying: true` → `.playing` status; always prefer `reasonKey`).
    ///   - reasonKey: Exact Localizable key from `safeOnStatusChange` (e.g. `"status_playing"`).
    ///   - visualState: Current SPM `currentVisualState` (may still be `.prePlay` after audible start).
    ///   - playbackIntent: Current SPM `currentPlaybackIntent`.
    ///   - engineIsActuallyPlaying: ``DirectStreamingPlayer/isActuallyPlaying()`` — rate + timeControl
    ///     truth used to avoid re-sticking Connecting chrome during the deferred-`setPlaying` race
    ///     when buffering/connecting keys arrive while audio is already flowing.
    /// - Returns: Chrome visual to apply. Does **not** mutate SPM; the actor remains SSOT for
    ///   persistence / widgets / LA. In-app chrome may lead SPM by one frame during deferred setPlaying.
    /// - SeeAlso: ``RadioPlayerCoordinator/handleStatusChange(_:reasonKey:)``,
    ///   ``SharedPlayerManager/setPlaying()``, CODING_AGENT.md.
    static func resolve(
        status: PlayerStatus,
        reasonKey: String?,
        visualState: PlayerVisualState,
        playbackIntent: PlaybackIntent,
        engineIsActuallyPlaying: Bool = false
    ) -> PlayerVisualState {
        // Privacy clear: intent alone blocks resurrection; chrome must stay blue `.cleared`
        // through residual connecting/stopped callbacks from the silent teardown.
        if playbackIntent == .cleared {
            return .cleared
        }

        // Authoritative audible-start report from the engine.
        // Prefer reasonKey: `status_connecting` is also delivered with PlayerStatus.playing
        // because safeOnStatusChange uses isPlaying:true for connecting feedback.
        let isAuthoritativePlayingReport =
            reasonKey == "status_playing"
            || (status == .playing && reasonKey == nil)

        if isAuthoritativePlayingReport {
            if visualState == .userPaused || playbackIntent == .userPaused {
                return .userPaused
            }
            if visualState == .cleared {
                return .cleared
            }
            if visualState == .securityLocked || playbackIntent == .securityLocked {
                return .securityLocked
            }
            if visualState == .thermalPaused {
                return .thermalPaused
            }
            // Deferred Connecting (.prePlay), already-playing SPM, or any other non-sticky
            // surface: promote chrome to green promptly when the engine reports audible play.
            return .playing
        }

        // Connecting / buffering: preserve optimistic chrome.
        // Key off reasonKey only — do not require `status != .playing`, because connecting is
        // emitted with isPlaying:true → PlayerStatus.playing.
        if let reasonKey,
           reasonKey == "status_connecting" || reasonKey == "status_buffering" {
            // Deferred setPlaying race: engine already audible, SPM still .prePlay, and a
            // buffer/connect key arrives after we (or status_playing) painted green — do not
            // re-stick yellow Connecting while rate is 1 and intent still wants play.
            if engineIsActuallyPlaying,
               playbackIntent.isActivePlaybackIntent,
               visualState == .prePlay || visualState == .playing {
                return .playing
            }
            if visualState == .prePlay || visualState == .playing || visualState == .cleared {
                return visualState
            }
            if playbackIntent.isActivePlaybackIntent {
                return .prePlay
            }
        }

        // Explicit user pause: terminal stop/pause keys must not regress grey → yellow Connecting.
        if status == .stopped || status == .paused
            || reasonKey == "status_stopped" || reasonKey == "status_paused" {
            if visualState == .userPaused || playbackIntent == .userPaused {
                return .userPaused
            }
        }

        // Protect sticky chrome from other engine chatter (SSL keys, unavailable noise, etc.).
        // Authoritative playing is handled above so this no longer freezes Connecting after audible start.
        if visualState == .userPaused || visualState == .prePlay || visualState == .cleared {
            return visualState
        }
        return visualState
    }
}
