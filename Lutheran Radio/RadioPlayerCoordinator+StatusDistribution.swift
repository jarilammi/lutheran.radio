//
//  RadioPlayerCoordinator+StatusDistribution.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.7.2026.
//
//  Status / chrome distribution domain for RadioPlayerCoordinator (mechanical split).
//
//  Owns: applying `PlayerVisualState` to in-app chrome (`updateUI`), engine status
//  choke point (`handleStatusChange` — **adapter only**: race lead + error/unavailable
//  side effects; **not** long-term visual SSOT), pure in-app chrome visual policy
//  (`RadioPlayerChromeVisualResolver` — soft-resume hold promote, Connecting race,
//  sticky pause, switch hold, status-path supersession gate), **primary SSOT visual
//  chrome observation** (`beginObservingVisualStateForChrome` — paints from
//  `visualStateDidChange` without requiring a second status emission), VM
//  metadata/switch-flag sync, no-internet chrome, Now Playing / widget save thin
//  forwarders, legacy status-label allowlist announcements, and thermal enter/exit
//  VoiceOver on the modern chrome path.
//
//  Dual-path discipline (main chrome):
//  1. **Primary paint:** ``beginObservingVisualStateForChrome()`` on
//     ``PlayerEvent/visualStateDidChange`` after SPM mutations (`setPlaying`, pause,
//     stop, policy). Durable visual transitions must not depend on engine status.
//  2. **Status adapter:** ``handleStatusChange`` may lead by one frame when the engine
//     reports audible before the actor visual is visible (Connecting race / soft-resume
//     hold promote via pure policy). It must not overwrite settled SSOT chrome with a
//     superseded pure-policy result (``shouldApplyStatusPathChromePaint``).
//  3. Both paths share ``updateUI(for:)`` dedupe (`lastAppliedVisualState`).
//
//  Does not own: play/pause toggle shims (primary coordinator file), stream-switch
//  orchestration (`+StreamSwitch` calls into this domain for chrome), pending-action
//  drain (`+PendingActions`), sleep-timer glue (`+SleepTimer`), tuning clips
//  (`+Tuning`), privacy clear dialog (primary file — nulls `lastAppliedVisualState`
//  then calls `updateUI`), engine rate pause / attach (DirectStreamingPlayer), or
//  visual/intent SSOT (SharedPlayerManager).
//
//  Stored chrome stamps (`lastAppliedVisualState`, `hasShownSecurityAlert`,
//  `hasEverPlayed`, `hasPlayedHapticForCurrentAudibleStart`,
//  `visualChromeEventObserver`, `visualChromeObservationTask`) remain
//  on the primary type body (extensions cannot declare stored properties); this file
//  owns the behavior that mutates them.
//
//  Public/entry surfaces on the same type:
//  - ``updateUI(for:)`` — paint chrome from a resolved visual (deduped)
//  - ``beginObservingVisualStateForChrome()`` — **primary** paint from visual SSOT transitions
//  - ``handleStatusChange(_:reasonKey:)`` — status-path adapter (race lead + errors only)
//  - ``updateUIForNoInternet()`` — airplane / path-loss chrome
//  - ``saveStateForWidget()`` — thin SPM forwarder for host persist
//  - ``setIsSwitchingStream(_:)`` / ``syncMetadataToViewModel(_:)`` — VM bridge
//  - ``safeUpdateStatusLabel(text:backgroundColor:textColor:isPermanentError:)``
//
//  Pure resolver (same module, free type):
//  - ``RadioPlayerChromeVisualResolver`` — engine status → chrome visual + status paint gate
//
//  - SeeAlso: ``DirectStreamingPlayer/safeOnStatusChange``,
//    ``DirectStreamingPlayer/safeOnMetadataChange(metadata:)``,
//    ``SharedPlayerManager/setPlaying()``, ``SharedPlayerManager/currentVisualState``,
//    ``SharedPlayerManager/makeEventsStreamWithReplay()``,
//    ``SharedPlayerManager/didUpdateStreamMetadata(_:)``,
//    RadioPlayerCoordinator.swift (isolation map),
//    docs/Widget-Presentation-Dataflow.md (Main-App Chrome Authority — dual path + soft-resume hold),
//    docs/Live-Activity-Stacking-and-Media-Surfaces.md (Connecting vs audible start; soft-resume surfaces;
//    ICY single-owner path — LA ensure remains orthogonal to main status adapter),
//    docs/Event-Driven-Refactor-Roadmap.md (non-forcing main chrome consumer; multi-cast replay),
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
    /// chatter and dual-path status + SSOT observation cannot thrash the pill. Callers:
    /// - **Primary (visual SSOT):** ``beginObservingVisualStateForChrome()`` on
    ///   ``PlayerEvent/visualStateDidChange`` after ``setPlaying()`` / pause / stop / policy.
    ///   This is the long-term paint authority for durable visual transitions.
    /// - **Status race lead (adapter only):** ``handleStatusChange(_:reasonKey:)`` via pure
    ///   ``RadioPlayerChromeVisualResolver`` — may lead SPM by one frame on soft-resume /
    ///   deferred Connecting promote; must not regress settled SSOT chrome (supersession gate).
    /// - **Explicit coordinator paths:** pause/stop shims, privacy clear, stream switch.
    ///
    /// VoiceOver: thermal enter/exit is announced here (modern chrome SSOT) via
    /// ``announceThermalVisualTransition(from:to:)`` so `status_thermal_paused` is spoken
    /// without requiring focus on the status pill. Other status strings continue to use the
    /// legacy `safeUpdateStatusLabel` allowlist where that path still runs.
    ///
    /// - Parameter visualState: Chrome visual to apply (not necessarily equal to SPM yet during
    ///   the deferred ``setPlaying()`` window when status path promotes early).
    /// - SeeAlso: ``beginObservingVisualStateForChrome()``, ``handleStatusChange(_:reasonKey:)``,
    ///   ``RadioPlayerChromeVisualResolver``, ``announceThermalVisualTransition(from:to:)``,
    ///   `PlayerViewModel`, docs/Widget-Presentation-Dataflow.md,
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

    /// Thin persist forwarder: writes the authoritative `PersistedWidgetState` snapshot
    /// through ``SharedPlayerManager/saveCurrentState()`` for widgets and Live Activities.
    ///
    /// Debouncing lives in ``WidgetRefreshManager``; this path does not apply its own throttle.
    /// Host `ViewController` widget-action completion calls this method (no second copy).
    ///
    /// - SeeAlso: ``SharedPlayerManager/saveCurrentState()``,
    ///   ``WidgetRefreshManager/refreshIfNeeded(visualState:currentLanguage:hasError:immediate:)``
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

    // MARK: - Visual SSOT chrome observation (primary paint for visual transitions)

    /// Begins (or restarts) coordinator-owned observation of SPM visual transitions for in-app chrome.
    ///
    /// Consumes ``SharedPlayerManager/makeEventsStreamWithReplay()`` so late attach receives the
    /// current visual as a prefix event, then live ``PlayerEvent/visualStateDidChange`` values
    /// paint via ``updateUI(for:)`` **without requiring a second engine status emission**.
    ///
    /// **Why required:** Soft-resume holds residual `.userPaused` visual until
    /// ``SharedPlayerManager/setPlaying()``. That mutation emits `visualStateDidChange(.playing)`
    /// and refreshes widgets / Live Activity, but status delivery can race, last-value-dedupe,
    /// or never re-deliver after a prior `status_playing`. Painting from the visual SSOT event
    /// closes stuck grey pause chrome while audio is live.
    ///
    /// **Non-forcing:** Observation never mutates SPM, never calls `play()` / `stop()`, never
    /// bypasses privacy write suppression, and never forces WidgetCenter. Multi-cast live
    /// delivery coexists with ``WidgetRefreshManager`` (primary ``events`` iterator untouched).
    ///
    /// **Dual-path discipline:** This observer is **primary** for durable visual transitions.
    /// Status path (``handleStatusChange``) is demoted to optional one-frame race lead +
    /// error/unavailable/SSL side effects — never a second visual SSOT. Both paths share
    /// ``updateUI(for:)`` dedupe via `lastAppliedVisualState`; status additionally uses
    /// ``RadioPlayerChromeVisualResolver/shouldApplyStatusPathChromePaint`` so a late
    /// pure-policy result cannot regress chrome already settled to SPM SSOT.
    ///
    /// - Postcondition: ``visualChromeObservationTask`` holds the live observation task.
    ///   Subsequent ``setPlaying()`` / ``setUserPaused()`` / stop visual mutations paint
    ///   ``PlayerViewModel`` when the event arrives on MainActor. Replay prefix may paint
    ///   the current SPM visual once on attach (deduped if chrome already matches).
    /// - Precondition: Call from ``wireAndInitialSetup()`` (fire-and-forget Task) or `await`
    ///   from tests. Idempotent restart cancels the prior task first.
    /// - SeeAlso: ``updateUI(for:)``, ``handleStatusChange(_:reasonKey:)``,
    ///   ``SharedPlayerManager/makeEventsStreamWithReplay()``, ``SharedPlayerManager/setPlaying()``,
    ///   `PlayerEvent.visualStateDidChange`, `WidgetEventObserver`,
    ///   docs/Widget-Presentation-Dataflow.md, docs/Event-Driven-Refactor-Roadmap.md,
    ///   CODING_AGENT.md (Single Source of Truth Principles).
    @MainActor
    func beginObservingVisualStateForChrome() async {
        guard !SharedPlayerManager.isWidgetProcess() else { return }

        visualChromeEventObserver.cancel()
        visualChromeObservationTask?.cancel()
        visualChromeObservationTask = nil

        let stream = await SharedPlayerManager.shared.makeEventsStreamWithReplay()
        visualChromeEventObserver.beginObserving(stream) { [weak self] event in
            await self?.handleVisualChromePlayerEvent(event)
        }
        visualChromeObservationTask = visualChromeEventObserver.task
        // Let the for-await reach its first suspension and drain the replay prefix so
        // subsequent setPlaying / setUserPaused mutations are live-forwarded reliably.
        await Task.yield()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        #if DEBUG
        print("[RadioPlayerCoordinator] began SSOT visual chrome observation (multi-cast replay)")
        #endif
    }

    /// Stops SSOT visual chrome observation (test teardown / explicit restart helper).
    ///
    /// Idempotent. Production deinit cancels ``visualChromeObservationTask`` only (nonisolated);
    /// this MainActor entry also clears the observer task reference.
    ///
    /// - SeeAlso: ``beginObservingVisualStateForChrome()``.
    @MainActor
    func stopObservingVisualStateForChrome() {
        visualChromeEventObserver.cancel()
        visualChromeObservationTask?.cancel()
        visualChromeObservationTask = nil
    }

    /// Applies a single ``PlayerEvent`` to in-app chrome when it carries a visual SSOT transition.
    ///
    /// Only ``PlayerEvent/visualStateDidChange`` paints — the event payload **is** the mutation.
    /// Other cases are ignored (intent / metadata / stream verbs / persist signals do not own
    /// main chrome glyphs). Never mutates SPM or starts playback.
    ///
    /// - Parameter event: Domain event from the multi-cast replay stream.
    /// - SeeAlso: ``beginObservingVisualStateForChrome()``, ``updateUI(for:)``.
    @MainActor
    func handleVisualChromePlayerEvent(_ event: PlayerEvent) async {
        guard case .visualStateDidChange(let visual) = event else { return }
        #if DEBUG
        if lastAppliedVisualState != visual {
            print("[RadioPlayerCoordinator] SSOT visual chrome → \(visual)")
            if visual == .playing {
                MediaTransportLatencyTimeline.mark(
                    .inAppChromeAppliedPlaying,
                    detail: "source=visualStateDidChange"
                )
            }
        }
        #endif
        updateUI(for: visual)
    }

    #if DEBUG
    /// White-box seam: delivers one event through the production SSOT chrome handler.
    ///
    /// - Parameter event: Domain event to apply (typically ``visualStateDidChange``).
    /// - SeeAlso: ``handleVisualChromePlayerEvent(_:)``, chrome visual resolver tests.
    @MainActor
    func _test_applyVisualChromePlayerEvent(_ event: PlayerEvent) async {
        await handleVisualChromePlayerEvent(event)
    }
    #endif

    // MARK: - Streaming status distribution entry (called from VC's StreamingPlayerDelegate hop)

    /// Receives every status update from the streaming engine: optional chrome **race lead**
    /// via pure policy, then error / unavailable / SSL / no-internet **side effects**.
    ///
    /// **Demoted role (adapter, not visual SSOT):** Durable main-app chrome for visual
    /// transitions is owned by ``beginObservingVisualStateForChrome()`` on
    /// ``PlayerEvent/visualStateDidChange``. This status path is **not** the long-term paint
    /// authority. It remains for:
    /// 1. **Optional one-frame race lead** — engine `status_playing` / audible truth can
    ///    arrive on MainActor before SPM ``setPlaying()`` is visible; pure policy may promote
    ///    Connecting or soft-resume hold chrome early (defense in depth after SSOT paint).
    /// 2. **Error / unavailable / SSL / no-internet side effects** — alerts, recovery windows,
    ///    ``markPlaybackStoppedByStreamFailure``, became-playing haptic
    ///    (``HapticPlaybackPolicy`` on `status_playing` / `nil`), background flush, widget save.
    ///
    /// Chrome mapping for the race-lead branch is solely
    /// ``RadioPlayerChromeVisualResolver/resolve(status:reasonKey:visualState:playbackIntent:engineIsActuallyPlaying:)``.
    /// Before paint, SPM visual/intent are re-sampled and pure policy re-resolved so a concurrent
    /// ``setPlaying()`` / ``setUserPaused()`` cannot leave a stale snapshot in charge. Paint is
    /// gated by ``RadioPlayerChromeVisualResolver/shouldApplyStatusPathChromePaint`` so settled
    /// SSOT chrome is never overwritten by a superseded pure-policy result.
    ///
    /// **Connecting-until-audible chrome:** While the start pipeline is active, SPM holds
    /// `.prePlay` until engine ``setPlaying()`` / `publishAuthoritativePlayingIfNeeded`.
    /// Engine `status_playing` can arrive on MainActor **before** that actor mutation is
    /// visible. Race-lead promote to `.playing` remains allowed — freezing `.prePlay` here
    /// leaves the in-app pill yellow while audio and Live Activity already show playing.
    ///
    /// **Soft-resume hold promote (intent-gated):** Soft-resume retains residual `.userPaused`
    /// **visual** until ``setPlaying()`` while intent is already active. Pure policy promotes
    /// chrome to `.playing` when the engine reports audible play (or is already audible) —
    /// freezing on residual visual alone would leave grey pause chrome while audio is live.
    /// True sticky pause still freezes when **intent** is `.userPaused` (late `status_playing`
    /// must not resurrect green). Privacy `.cleared` / security / thermal policy chrome remain
    /// protected.
    ///
    /// Special handling exists for transient states (connecting/buffering preserve optimistic
    /// prePlay/playing/soft-resume residual grey, with an engine-audible race guard) and for
    /// explicit user pauses. The unavailable/failed reaction includes an
    /// `isInInitialRecoveryWindow` guard so that normal self-healing ICY decoder noise
    /// immediately after a language switch (or cold launch) does not force `.userPaused` + alert.
    ///
    /// - Parameters:
    ///   - status: Coarse player status.
    ///   - reasonKey: Exact Localizable key (e.g. "status_playing", "status_stream_unavailable").
    ///     Used both for localization and for precise branching.
    /// - Postcondition: When race lead or hold/sticky correction is still valid against latest
    ///   SPM SSOT, ``PlayerViewModel`` chrome matches the pure-policy result (deduped by
    ///   ``updateUI(for:)``). When SSOT chrome is already settled and policy would diverge
    ///   without race-lead authority, chrome is left unchanged (side effects still run).
    ///   Soft-resume hold with active intent + audible report may still paint `.playing` one
    ///   frame early; sticky pause intent keeps `.userPaused`.
    ///
    /// - SeeAlso: ``beginObservingVisualStateForChrome()``,
    ///   ``RadioPlayerChromeVisualResolver/resolve(status:reasonKey:visualState:playbackIntent:engineIsActuallyPlaying:)``,
    ///   ``RadioPlayerChromeVisualResolver/shouldApplyStatusPathChromePaint(policyResult:latestVisual:latestIntent:lastApplied:)``,
    ///   `DirectStreamingPlayer.safeOnStatusChange`, `handleItemStatusFailure(_:)`,
    ///   `streamingPlayer.isInInitialRecoveryWindow`, `SharedPlayerManager.markPlaybackStoppedByStreamFailure`,
    ///   `SharedPlayerManager.setPlaying()`, `updateUI(for:)`, ``HapticPlaybackPolicy``,
    ///   docs/Widget-Presentation-Dataflow.md, docs/Event-Driven-Refactor-Roadmap.md,
    ///   CODING_AGENT.md (transient vs permanent modeling, Single Source of Truth Principles)
    func handleStatusChange(_ status: PlayerStatus, reasonKey: String?) async {
        // Engine-truth for deferred-setPlaying and soft-resume hold races: status_playing /
        // brief buffer while rate is already 1 must promote chrome before SPM flips to `.playing`.
        let engineIsActuallyPlaying = streamingPlayer.isActuallyPlaying()

        // Sample SPM once for logging, then re-sample immediately before chrome paint so a
        // concurrent setPlaying / setUserPaused cannot leave a stale snapshot in charge of
        // the race-lead branch (status is adapter; SSOT may advance while we await).
        var visualState = await SharedPlayerManager.shared.currentVisualState
        var playbackIntent = await SharedPlayerManager.shared.currentPlaybackIntent

        #if DEBUG
        print("[RadioPlayerCoordinator] onStatusChange → \(status) (reasonKey: \(reasonKey ?? "nil")) → visualState \(visualState) intent=\(playbackIntent) enginePlaying=\(engineIsActuallyPlaying)")
        #endif

        // Sole chrome mapping for this path — pure table (sticky intent freeze vs soft-resume promote).
        var effectiveVisualState = RadioPlayerChromeVisualResolver.resolve(
            status: status,
            reasonKey: reasonKey,
            visualState: visualState,
            playbackIntent: playbackIntent,
            engineIsActuallyPlaying: engineIsActuallyPlaying
        )

        // Supersession: re-read SSOT and re-resolve so race-lead paint uses latest actor truth.
        let latestVisual = await SharedPlayerManager.shared.currentVisualState
        let latestIntent = await SharedPlayerManager.shared.currentPlaybackIntent
        if latestVisual != visualState || latestIntent != playbackIntent {
            #if DEBUG
            print("[RadioPlayerCoordinator] status path re-resolved after SSOT advanced (snapshot \(visualState)/\(playbackIntent) → \(latestVisual)/\(latestIntent))")
            #endif
            visualState = latestVisual
            playbackIntent = latestIntent
            effectiveVisualState = RadioPlayerChromeVisualResolver.resolve(
                status: status,
                reasonKey: reasonKey,
                visualState: visualState,
                playbackIntent: playbackIntent,
                engineIsActuallyPlaying: engineIsActuallyPlaying
            )
        }

        #if DEBUG
        if effectiveVisualState == .playing
            && (reasonKey == "status_playing" || engineIsActuallyPlaying) {
            if visualState == .prePlay {
                print("[RadioPlayerCoordinator] in-app chrome → .playing while SPM still .prePlay (status race lead; deferred setPlaying; engine audible)")
                MediaTransportLatencyTimeline.mark(
                    .inAppChromeAppliedPlaying,
                    detail: "source=statusRaceLead spmVisual=prePlay reasonKey=\(reasonKey ?? "nil")"
                )
            } else if visualState == .userPaused, playbackIntent.isActivePlaybackIntent {
                // Soft-resume hold: residual sticky visual with active play intent must promote.
                print("[RadioPlayerCoordinator] in-app chrome → .playing while SPM still .userPaused (status race lead; soft-resume hold promote; active intent)")
                MediaTransportLatencyTimeline.mark(
                    .inAppChromeAppliedPlaying,
                    detail: "source=statusRaceLead spmVisual=userPaused softResumeHold reasonKey=\(reasonKey ?? "nil")"
                )
            }
        } else if effectiveVisualState == .userPaused, reasonKey == "status_playing", playbackIntent == .userPaused {
            // True sticky pause: late audible report must not resurrect green.
            print("[RadioPlayerCoordinator] in-app chrome stays .userPaused on status_playing (sticky pause intent freeze)")
        }
        #endif

        // Status is not sole visual SSOT: skip chrome paint when settled SSOT already matches
        // SPM and pure policy would diverge without race-lead authority.
        let shouldPaintChrome = RadioPlayerChromeVisualResolver.shouldApplyStatusPathChromePaint(
            policyResult: effectiveVisualState,
            latestVisual: visualState,
            latestIntent: playbackIntent,
            lastApplied: lastAppliedVisualState
        )
        if shouldPaintChrome {
            self.updateUI(for: effectiveVisualState)
        } else {
            #if DEBUG
            print("[RadioPlayerCoordinator] status path skipped chrome paint (superseded by settled SSOT lastApplied=\(String(describing: lastAppliedVisualState)) spm=\(visualState) policy=\(effectiveVisualState))")
            #endif
        }

        // If we had to correct the UI to .userPaused for a real sticky user pause (despite the
        // actor having loaded a stale .prePlay), repair the in-memory SSOT immediately so that
        // any follow-on save uses the correct visual.
        // Never do this repair for .cleared (the post-reset visual).
        // Only when status chrome paint was allowed (or chrome already sticky) — do not drive
        // SPM mutations from a superseded race-lead branch.
        if shouldPaintChrome,
           effectiveVisualState == .userPaused,
           visualState == .prePlay,
           playbackIntent == .userPaused {
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

        if HapticPlaybackPolicy.shouldClearAudibleStartHapticLatch(status: status) {
            hasPlayedHapticForCurrentAudibleStart = false
        }

        if status == .playing {
            hasEverPlayed = true

            // Production audible start is `status_playing` (device log). `nil` is
            // interruption resume. The previous `reasonKey == nil` gate never fired
            // on the normal play / resume / switch path.
            if HapticPlaybackPolicy.shouldPlayPlayingConfirmation(
                status: status,
                reasonKey: reasonKey,
                alreadyPlayedForCurrentAudibleStart: hasPlayedHapticForCurrentAudibleStart
            ) {
                hasPlayedHapticForCurrentAudibleStart = true
                playHapticFeedback(style: .light)
            }

            if reasonKey == "status_playing" {
                self.backgroundImageController.scheduleDeferredFlushIfNeeded()
            }
        }

        saveStateForWidget()
    }
}

// MARK: - In-app chrome visual policy (engine status + SSOT → pill / glyph)

/// Pure, side-effect-free policy mapping engine status + SPM visual/intent into in-app chrome.
///
/// ## Dual-path ownership (main chrome)
///
/// | Path | Role | Entry |
/// |------|------|--------|
/// | **Visual SSOT (primary)** | Durable paint after SPM mutations | ``RadioPlayerCoordinator/beginObservingVisualStateForChrome()`` on ``PlayerEvent/visualStateDidChange`` |
/// | **Status adapter (demoted)** | Optional one-frame race lead + error side effects | ``RadioPlayerCoordinator/handleStatusChange(_:reasonKey:)`` |
///
/// This pure table is the sole **status-path** mapping when engine status arrives before / without
/// a matching actor visual hop. Durable transitions must not depend on status alone — SSOT paint
/// is primary. Status paint is further gated by ``shouldApplyStatusPathChromePaint`` so a
/// superseded pure-policy result cannot regress chrome already settled to SPM SSOT.
///
/// Logic lives here so unit tests can assert soft-resume hold promote, Connecting-until-audible,
/// sticky pause, switch hold, privacy clear, and status supersession without a UIKit host or
/// `AVPlayer`.
///
/// ## Policy table (authoritative)
///
/// | Situation | Inputs (conceptual) | Chrome output |
/// |-----------|---------------------|---------------|
/// | Privacy clear | intent `.cleared` | `.cleared` |
/// | True sticky pause | sticky pause **intent** + late audible report | `.userPaused` |
/// | Soft-resume hold promote | residual `.userPaused` **visual**, **active** play intent, audible report or engine audible | `.playing` |
/// | Connecting race | `.prePlay` visual, active intent, audible | `.playing` |
/// | True Connecting / switch hold | `.prePlay`, active intent, not audible | `.prePlay` (never invent green) |
/// | Soft-resume intermediate | residual `.userPaused` visual, active intent, not yet audible | `.userPaused` (never invent Connecting) |
/// | Policy chrome | security / thermal authoritative | keep policy visual |
/// | Terminal stop while sticky | stop/pause keys + sticky pause | `.userPaused` |
///
/// ## Why residual `.userPaused` visual alone must not freeze
///
/// Soft-resume intentionally retains sticky **visual** until engine ``setPlaying()`` while
/// intent is already active (``.shouldBePlaying`` / ``.sleepTimer``). Freezing chrome on
/// residual visual alone leaves the main-app pill grey while audio is live. Sticky freeze
/// requires sticky **intent** (user still wants pause), not residual visual under active play.
///
/// ## Why this is not a dumb pass-through of SPM visual
///
/// SharedPlayerManager defers authoritative ``setPlaying()`` until soft-resume rate kick or
/// readyToPlay first-play kick (`publishAuthoritativePlayingIfNeeded`). Engine
/// `status_playing` is delivered via `DispatchQueue.main.async` and can interleave **before**
/// the SPM actor mutation is visible. Status path may lead SPM by one frame on pure policy promote;
/// SPM remains SSOT for persistence / widgets / Live Activity and for durable main chrome via
/// ``visualStateDidChange``.
///
/// - SeeAlso: ``RadioPlayerCoordinator/handleStatusChange(_:reasonKey:)``,
///   ``RadioPlayerCoordinator/beginObservingVisualStateForChrome()``,
///   ``shouldApplyStatusPathChromePaint(policyResult:latestVisual:latestIntent:lastApplied:)``,
///   ``SharedPlayerManager/setPlaying()``, `DirectStreamingPlayer.publishAuthoritativePlayingIfNeeded`,
///   `PlayerVisualState`, `PlaybackIntent`,
///   docs/Widget-Presentation-Dataflow.md (Main-App Chrome Authority),
///   docs/Live-Activity-Stacking-and-Media-Surfaces.md (Connecting vs audible start),
///   docs/Event-Driven-Refactor-Roadmap.md (main chrome consumer),
///   CODING_AGENT.md (Single Source of Truth Principles).
enum RadioPlayerChromeVisualResolver: Sendable {

    /// Resolves the in-app chrome visual from engine status + current SPM visual/intent.
    ///
    /// Pure and side-effect free: does **not** mutate SPM, start Live Activities, or paint UI.
    /// Status-path callers apply the result only when
    /// ``shouldApplyStatusPathChromePaint(policyResult:latestVisual:latestIntent:lastApplied:)``
    /// allows, via ``RadioPlayerCoordinator/updateUI(for:)``.
    ///
    /// - Parameters:
    ///   - status: Coarse `PlayerStatus` from the streaming delegate (note: `status_connecting` is
    ///     often delivered with `isPlaying: true` → `.playing` status; always prefer `reasonKey`).
    ///   - reasonKey: Exact Localizable key from `safeOnStatusChange` (e.g. `"status_playing"`).
    ///   - visualState: Current SPM `currentVisualState` (may still be `.prePlay` or residual
    ///     `.userPaused` soft-resume hold after audible start). Prefer the **latest** sample
    ///     immediately before paint (status adapter re-samples after concurrent SPM mutations).
    ///   - playbackIntent: Current SPM `currentPlaybackIntent` — sticky vs active distinguishes
    ///     true pause freeze from soft-resume hold promote.
    ///   - engineIsActuallyPlaying: ``DirectStreamingPlayer/isActuallyPlaying()`` — rate + timeControl
    ///     truth used for soft-resume / deferred-`setPlaying` promote when status keys race or chatter.
    /// - Returns: Chrome visual the status path *proposes*. In-app chrome may lead SPM by one frame
    ///   during deferred setPlaying / soft-resume hold; actor remains SSOT for persistence /
    ///   widgets / LA and for durable main chrome via visual SSOT observation.
    /// - Important: Never invent `.playing` during silent attach or stream-switch hold (not audible).
    ///   Never invent Connecting (`.prePlay`) during soft-resume hold (residual `.userPaused` + active intent).
    /// - SeeAlso: ``shouldApplyStatusPathChromePaint(policyResult:latestVisual:latestIntent:lastApplied:)``,
    ///   ``RadioPlayerCoordinator/handleStatusChange(_:reasonKey:)``,
    ///   ``SharedPlayerManager/setPlaying()``, ``PlaybackIntent/isActivePlaybackIntent``, CODING_AGENT.md.
    static func resolve(
        status: PlayerStatus,
        reasonKey: String?,
        visualState: PlayerVisualState,
        playbackIntent: PlaybackIntent,
        engineIsActuallyPlaying: Bool = false
    ) -> PlayerVisualState {
        // 1. Privacy clear: intent alone blocks resurrection; chrome stays blue `.cleared`
        // through residual connecting/stopped callbacks from silent teardown.
        if playbackIntent == .cleared {
            return .cleared
        }

        // Authoritative audible-start report from the engine.
        // Prefer reasonKey: `status_connecting` is also delivered with PlayerStatus.playing
        // because safeOnStatusChange uses isPlaying:true for connecting feedback.
        let isAuthoritativePlayingReport =
            reasonKey == "status_playing"
            || (status == .playing && reasonKey == nil)

        // Promote window: engine reports audible play, or rate/timeControl already proves
        // audio while intent still wants play (soft-resume / deferred setPlaying races).
        let shouldConsiderPlayingPromote =
            isAuthoritativePlayingReport
            || (engineIsActuallyPlaying && playbackIntent.isActivePlaybackIntent)

        if shouldConsiderPlayingPromote {
            // 2. True sticky pause: freeze only when intent still wants pause — not residual
            // `.userPaused` visual under active play intent (soft-resume hold).
            if playbackIntent == .userPaused {
                return .userPaused
            }
            // Residual cleared visual without cleared intent (defensive).
            if visualState == .cleared {
                return .cleared
            }
            // 7. Policy chrome: security / thermal stay authoritative against late audible reports.
            if visualState == .securityLocked || playbackIntent == .securityLocked {
                return .securityLocked
            }
            if visualState == .thermalPaused {
                return .thermalPaused
            }
            // 3–4. Soft-resume hold promote (residual .userPaused + active intent), deferred
            // Connecting race (.prePlay), already-playing SPM, or any other non-policy surface:
            // promote chrome to green when the engine is (or reports) audible.
            return .playing
        }

        // Connecting / buffering without promote window: preserve optimistic / hold chrome.
        // Key off reasonKey only — do not require `status != .playing`, because connecting is
        // emitted with isPlaying:true → PlayerStatus.playing.
        if let reasonKey,
           reasonKey == "status_connecting" || reasonKey == "status_buffering" {
            // 5–6. True Connecting / switch hold: keep yellow while silent attach or hold.
            // Soft-resume intermediate: residual grey pause must not become Connecting.
            // Already-playing / cleared: preserve optimistic surface through buffer chatter.
            if visualState == .prePlay
                || visualState == .playing
                || visualState == .cleared
                || visualState == .userPaused {
                return visualState
            }
            // Active intent with non-hold visual (e.g. unexpected) → Connecting.
            if playbackIntent.isActivePlaybackIntent {
                return .prePlay
            }
        }

        // 8. Explicit user pause: terminal stop/pause keys must not regress grey → yellow Connecting.
        if status == .stopped || status == .paused
            || reasonKey == "status_stopped" || reasonKey == "status_paused" {
            if visualState == .userPaused || playbackIntent == .userPaused {
                return .userPaused
            }
        }

        // Protect sticky / hold / cleared chrome from other engine chatter (SSL keys,
        // unavailable noise, etc.). Promote window above already handled audible start.
        if visualState == .userPaused || visualState == .prePlay || visualState == .cleared {
            return visualState
        }
        return visualState
    }

    /// Whether the status adapter may call ``RadioPlayerCoordinator/updateUI(for:)`` with
    /// `policyResult`, or must skip because settled visual SSOT already owns chrome.
    ///
    /// Status path is demoted: optional **one-frame race lead** when pure policy promotes
    /// `.playing` while SPM still holds Connecting (`.prePlay`) or soft-resume residual
    /// (`.userPaused` + active intent), plus hold/sticky corrections when chrome lags.
    /// It must **not** overwrite chrome that already matches latest SPM visual with a
    /// divergent pure-policy result (superseded race-lead / stale status).
    ///
    /// Pure and side-effect free — unit-tested without a coordinator host.
    ///
    /// - Parameters:
    ///   - policyResult: Output of ``resolve(status:reasonKey:visualState:playbackIntent:engineIsActuallyPlaying:)``
    ///     against **latest** SPM visual/intent.
    ///   - latestVisual: Latest ``SharedPlayerManager/currentVisualState`` used for resolve.
    ///   - latestIntent: Latest ``SharedPlayerManager/currentPlaybackIntent`` used for resolve.
    ///   - lastApplied: Coordinator `lastAppliedVisualState` (chrome already shown), if any.
    /// - Returns: `true` when status may paint; `false` when paint would regress settled SSOT.
    /// - SeeAlso: ``resolve(status:reasonKey:visualState:playbackIntent:engineIsActuallyPlaying:)``,
    ///   ``RadioPlayerCoordinator/handleStatusChange(_:reasonKey:)``,
    ///   ``RadioPlayerCoordinator/beginObservingVisualStateForChrome()``,
    ///   docs/Widget-Presentation-Dataflow.md, CODING_AGENT.md (Single Source of Truth Principles).
    static func shouldApplyStatusPathChromePaint(
        policyResult: PlayerVisualState,
        latestVisual: PlayerVisualState,
        latestIntent: PlaybackIntent,
        lastApplied: PlayerVisualState?
    ) -> Bool {
        // Race lead still valid against latest SSOT: promote playing while actor holds
        // Connecting or soft-resume residual under active play intent.
        if policyResult == .playing,
           latestIntent.isActivePlaybackIntent,
           latestVisual == .prePlay || latestVisual == .userPaused {
            return true
        }

        // Chrome already matches settled SPM visual — status must not diverge away from SSOT.
        // (Identical policy is allowed; updateUI dedupes the no-op.)
        if let lastApplied, lastApplied == latestVisual {
            return policyResult == latestVisual
        }

        // Chrome lags SSOT or is unset — allow pure-policy paint (including sticky freeze /
        // hold preservation / catch-up toward latest when policy agrees).
        return true
    }
}
