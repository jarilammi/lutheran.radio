//
//  SharedPlayerManager+NowPlaying.swift
//  Lutheran Radio
//
//  Lock screen and Control Center integration using the MediaPlayer framework.
//  Main app target only (no CarPlay entitlement required).
//
//  Created by Jari Lammi on 3.6.2026.
//

#if LUTHERAN_MAIN_APP
import Foundation
import MediaPlayer
import UIKit
import WidgetSurface

// MARK: - Media surface coordination (Now Playing + Live Activity + optional widgets)

/// Selects how ``SharedPlayerManager/refreshAllMediaSurfaces(liveActivity:widgetRefresh:widgetRefreshImmediate:)``
/// refreshes the Live Activity surface.
///
/// - SeeAlso: ``SharedPlayerManager/refreshAllMediaSurfaces(liveActivity:widgetRefresh:widgetRefreshImmediate:)``,
///   ``RadioLiveActivityManager/startActivity()``, ``RadioLiveActivityManager/updateCurrentActivity()``,
///   docs/Live-Activity-Stacking-and-Media-Surfaces.md.
enum MediaSurfaceLiveActivityMode: Sendable {
    /// Skip Live Activity IPC (Now Playing and optional widget refresh only).
    case none
    /// Push when an activity is already active; no-op when `currentActivity == nil`.
    case updateIfActive
    /// Start on first `.playing` transition, otherwise update (``setPlaying()`` policy).
    case startOrUpdate
}

// MARK: - Media transport command mailbox (Now Playing + Live Activity engine path)

/// Transport verbs that share ``SharedPlayerManager``'s serial media-transport mailbox.
///
/// System Now Playing / Control Center / headset remotes and main-process Live Activity
/// toggle execution enqueue through this type so rapid clicks cannot invert direction by
/// sampling `isActivelyPlaying` before a prior verb commits sticky intent / visual state.
///
/// - SeeAlso: ``SharedPlayerManager/submitMediaTransportCommand(_:)``,
///   ``SharedPlayerManager/submitMediaTransportCommandAndWait(_:)``,
///   ``WidgetIntentExecution/executeLiveActivityToggle(plan:)``,
///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
enum MediaTransportCommand: Sendable, Equatable {
    /// Explicit play / resume (``SharedPlayerManager/userRequestedPlay()``).
    case play
    /// User pause (``SharedPlayerManager/stop()`` sticky `.userPaused` + soft silence).
    case pause
    /// System stop command (same engine path as pause for this live stream).
    case stop
    /// Headset / lock-screen toggle: pause when actively playing, otherwise play.
    case togglePlayPause
}

// MARK: - MainActor-only MediaPlayer wiring (MPRemoteCommandCenter requires main thread)

@MainActor
private enum NowPlayingRemoteCommands {
    static var installed = false

    /// One-time ``MPRemoteCommandCenter`` wiring. Must run on the main actor.
    ///
    /// Enables only the transport verbs this live stream supports (play, pause,
    /// toggle play/pause, stop). All other system remote commands are disabled so
    /// Control Center / lock screen / headset chrome does not offer next/previous,
    /// seek, skip, rating, or other affordances that have no engine implementation.
    ///
    /// - Postcondition: Supported commands are enabled with targets that route to
    ///   ``SharedPlayerManager/submitMediaTransportCommand(_:)`` (serial mailbox →
    ///   ``userRequestedPlay()`` / ``stop()``). Unsupported commands are disabled.
    /// - Note: Handlers return `.success` immediately and only hop onto the actor to
    ///   enqueue work — they never block the remote-command callback thread on network
    ///   or engine completion. Ordering and toggle direction decisions run inside the
    ///   media-transport mailbox.
    /// - SeeAlso: ``SharedPlayerManager/configureNowPlayingControlsIfNeeded()``,
    ///   ``SharedPlayerManager/submitMediaTransportCommand(_:)``,
    ///   ``SharedPlayerManager/updateNowPlayingInfo()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    static func installIfNeeded() {
        guard !installed else { return }
        installed = true

        let center = MPRemoteCommandCenter.shared()

        // Detach any prior targets on the verbs we own, then re-bind.
        [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.stopCommand]
            .forEach { $0.removeTarget(nil) }

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { _ in
            // Enqueue only — mailbox serializes with pause/toggle/LA engine execution.
            Task { await SharedPlayerManager.shared.submitMediaTransportCommand(.play) }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { _ in
            Task { await SharedPlayerManager.shared.submitMediaTransportCommand(.pause) }
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { _ in
            // Direction is decided inside the mailbox after prior verbs commit state —
            // never sample `isActivelyPlaying` in this handler (split read/action race).
            Task { await SharedPlayerManager.shared.submitMediaTransportCommand(.togglePlayPause) }
            return .success
        }

        center.stopCommand.isEnabled = true
        center.stopCommand.addTarget { _ in
            Task { await SharedPlayerManager.shared.submitMediaTransportCommand(.stop) }
            return .success
        }

        // Live radio has no track list, seekable timeline, ratings, or language-option
        // remote surface. Disable every unsupported command so system chrome does not
        // present dead next/previous/seek/skip/like controls on lock screen, Control
        // Center, or hardware remotes.
        disableUnsupportedRemoteCommands(on: center)
    }

    /// Disables every ``MPRemoteCommandCenter`` command that Lutheran Radio does not
    /// implement for a continuous live stream.
    ///
    /// - Parameter center: The shared remote-command center (main actor only).
    /// - Postcondition: Supported transport remains enabled; all other listed commands
    ///   have `isEnabled == false`.
    private static func disableUnsupportedRemoteCommands(on center: MPRemoteCommandCenter) {
        let unsupported: [MPRemoteCommand] = [
            center.nextTrackCommand,
            center.previousTrackCommand,
            center.skipForwardCommand,
            center.skipBackwardCommand,
            center.seekForwardCommand,
            center.seekBackwardCommand,
            center.changePlaybackPositionCommand,
            center.changePlaybackRateCommand,
            center.changeRepeatModeCommand,
            center.changeShuffleModeCommand,
            center.ratingCommand,
            center.likeCommand,
            center.dislikeCommand,
            center.bookmarkCommand,
            center.enableLanguageOptionCommand,
            center.disableLanguageOptionCommand
        ]
        for command in unsupported {
            command.removeTarget(nil)
            command.isEnabled = false
        }
    }
}

@MainActor
private enum NowPlayingArtwork {
    static let placeholder: MPMediaItemArtwork? = {
        guard let image = UIImage(named: "radio-placeholder") else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }()
}

extension SharedPlayerManager {
    /// One-time ``MPRemoteCommandCenter`` wiring for Lock Screen, Control Center, and
    /// hardware remotes (main app only).
    ///
    /// Installs play / pause / toggle / stop handlers and disables every unsupported
    /// remote command (next/previous, seek, skip, rating, language options, etc.) so
    /// system chrome never offers dead transport affordances for a live stream.
    ///
    /// Handlers enqueue ``MediaTransportCommand`` values on the serial media-transport
    /// mailbox rather than spawning unordered play/stop tasks.
    ///
    /// - Precondition: Main-app ``SharedPlayerManager``; no-op in the widget extension.
    /// - Postcondition: Supported commands enabled; unsupported commands disabled.
    ///   Idempotent after the first successful install for this process.
    /// - SeeAlso: ``submitMediaTransportCommand(_:)``, ``updateNowPlayingInfo()``,
    ///   ``userRequestedPlay()``, ``stop()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    func configureNowPlayingControlsIfNeeded() async {
        guard !isRunningInWidget() else { return }
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        await MainActor.run {
            NowPlayingRemoteCommands.installIfNeeded()
        }
    }

    /// Enqueues a media transport verb on the serial mailbox and returns after scheduling.
    ///
    /// Now Playing remotes, headset clicks, and main-process Live Activity toggle execution
    /// share this mailbox so interleaved taps cannot invert play/pause direction.
    ///
    /// **Ordering rules**
    /// - **Play / toggle:** wait for the previous enqueued verb to finish, then run only if
    ///   this submission’s epoch is still current (not superseded by a newer submit).
    /// - **Pause / stop:** preempt — cancel the previous chain task and run ``stop()``
    ///   without waiting for an in-flight play to complete. Records
    ///   ``mediaTransportPauseEpoch`` so a play already inside `userRequestedPlay` re-asserts
    ///   sticky pause after it returns (cooperative `Task` cancel alone is not enough).
    /// - **Toggle direction** is sampled only inside ``performMediaTransportCommand(_:generation:)``
    ///   after prior verbs have committed visual/intent (no split read/action across tasks).
    ///
    /// - Parameter command: The transport verb to schedule.
    /// - Important: Does **not** await engine completion — safe for `MPRemoteCommandCenter`
    ///   callbacks that must return `.success` immediately. Use
    ///   ``submitMediaTransportCommandAndWait(_:)`` when the caller must observe completion
    ///   (Live Activity intent execution on the main app).
    /// - SeeAlso: ``MediaTransportCommand``, ``performMediaTransportCommand(_:generation:)``,
    ///   ``WidgetIntentExecution/executeLiveActivityToggle(plan:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md
    ///
    /// AGENT NOTE: Keep remote handlers and LA engine execution on this mailbox. Do not
    /// re-introduce unstructured `Task { isActivelyPlaying; stop/play }` in remote targets.
    ///
    /// DEBUG: ``MediaTransportLatencyTimeline`` marks enqueue + execute start/finish so
    /// device QA can measure remote / LA mailbox latency without changing policy.
    func submitMediaTransportCommand(_ command: MediaTransportCommand) {
        mediaTransportEpoch &+= 1
        let epoch = mediaTransportEpoch
        let previous = mediaTransportChain

        if command == .pause || command == .stop {
            mediaTransportPauseEpoch = epoch
        }

        #if DEBUG
        MediaTransportLatencyTimeline.mark(
            .mediaTransportEnqueued,
            detail: "command=\(command) epoch=\(epoch)"
        )
        #endif

        let task: Task<Void, Never>
        switch command {
        case .pause, .stop:
            // Preempt in-flight play/toggle so user pause is not stuck behind security
            // validation or attach. Cancellation is cooperative; pause-epoch repair after
            // a late userRequestedPlay is the hard guarantee that sticky pause wins.
            // After stop, drain the cancelled predecessor so repair (and any late play)
            // finish before this chain task reports idle.
            task = Task {
                previous?.cancel()
                await self.performMediaTransportCommand(command, generation: epoch)
                await previous?.value
            }
        case .play, .togglePlayPause:
            task = Task {
                await previous?.value
                guard epoch == self.mediaTransportEpoch else { return }
                guard !Task.isCancelled else { return }
                await self.performMediaTransportCommand(command, generation: epoch)
            }
        }
        mediaTransportChain = task
    }

    /// Enqueues a media transport verb and awaits mailbox drain through that verb.
    ///
    /// Used by main-app Live Activity toggle execution so App Intent `perform()` still
    /// observes engine-complete stop / play while sharing remote-command ordering.
    ///
    /// - Parameter command: The transport verb to run.
    /// - SeeAlso: ``submitMediaTransportCommand(_:)``,
    ///   ``WidgetIntentExecution/executeLiveActivityToggle(plan:)``
    func submitMediaTransportCommandAndWait(_ command: MediaTransportCommand) async {
        submitMediaTransportCommand(command)
        await mediaTransportChain?.value
    }

    /// Awaits the current media-transport chain until idle (unit tests and diagnostics).
    ///
    /// - Note: Orphaned play tasks cancelled by pause preemption may still be finishing
    ///   engine work; call sites that need sticky-pause repair should allow a short yield
    ///   or re-read visual state after this returns when testing preemption.
    /// - SeeAlso: ``submitMediaTransportCommand(_:)``
    func waitForMediaTransportIdle() async {
        await mediaTransportChain?.value
    }

    /// Executes one transport verb after mailbox ordering has been applied.
    ///
    /// Toggle samples authoritative actor state only here so a rapid second remote click
    /// cannot pair with a stale pre-mutation read:
    /// - ``isActivelyPlaying`` or ``isConnectingPlayback`` → ``stop()`` (silence or cancel connect)
    /// - ``blocksPlannedPlay`` while thermally stressed → no-op (keep thermal chrome)
    /// - otherwise → ``userRequestedPlay()``
    ///
    /// - Parameters:
    ///   - command: Verb to apply to the engine / sticky intent path.
    ///   - generation: Submission epoch captured at enqueue time.
    /// - SeeAlso: ``userRequestedPlay()``, ``stop()``, ``isConnectingPlayback``,
    ///   ``MediaTransportCommand``, ``PlayerVisualState/blocksPlannedPlay``,
    ///   ``MediaTransportLatencyTimeline`` (DEBUG latency milestones)
    func performMediaTransportCommand(
        _ command: MediaTransportCommand,
        generation: UInt64
    ) async {
        #if DEBUG
        MediaTransportLatencyTimeline.mark(
            .mediaTransportExecuteStarted,
            detail: "command=\(command) epoch=\(generation)"
        )
        #endif

        switch command {
        case .play:
            // Idempotent while Connecting; thermal refuse lives inside userRequestedPlay.
            await userRequestedPlay()
            await reassertStickyPauseIfSupersededByPause(generation: generation)
        case .pause, .stop:
            await stop()
        case .togglePlayPause:
            if currentVisualState.isActivelyPlaying || isConnectingPlayback {
                await stop()
            } else if currentVisualState.blocksPlannedPlay && Self.isDeviceThermallyStressed() {
                #if DEBUG
                print("[SharedPlayerManager] media-transport toggle refused — thermal gate still active")
                MediaTransportLatencyTimeline.mark(
                    .mediaTransportExecuteFinished,
                    detail: "command=\(command) epoch=\(generation) result=thermalRefuse"
                )
                #endif
                return
            } else {
                await userRequestedPlay()
                await reassertStickyPauseIfSupersededByPause(generation: generation)
            }
        }

        #if DEBUG
        MediaTransportLatencyTimeline.mark(
            .mediaTransportExecuteFinished,
            detail: "command=\(command) epoch=\(generation)"
        )
        #endif
    }

    /// If a pause/stop was submitted after `generation` and remains the latest transport
    /// verb, re-run ``stop()`` so a late `userRequestedPlay` cannot clear sticky pause.
    ///
    /// - Parameter generation: Epoch of the play/toggle submission that just finished play.
    /// - Note: Does nothing when a newer play/toggle already advanced ``mediaTransportEpoch``
    ///   past ``mediaTransportPauseEpoch`` (pause was not the latest user intent).
    private func reassertStickyPauseIfSupersededByPause(generation: UInt64) async {
        guard mediaTransportPauseEpoch > generation else { return }
        guard mediaTransportEpoch == mediaTransportPauseEpoch else { return }
        await stop()
    }

    #if DEBUG
    /// Current media-transport submission epoch (unit tests).
    func _test_mediaTransportEpoch() -> UInt64 {
        mediaTransportEpoch
    }

    /// Epoch of the last pause/stop submit (unit tests).
    func _test_mediaTransportPauseEpoch() -> UInt64 {
        mediaTransportPauseEpoch
    }
    #endif
    
    /// Restores parsed widget metadata from the raw ICY stash after soft-pause resume.
    /// ICY servers typically do not resend StreamTitle when the same secured item resumes.
    func rehydrateStreamMetadataFromStashIfNeeded() async {
        guard currentStreamMetadata == nil,
              let raw = nowPlayingStreamMetadata else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        #if DEBUG
        print("[SharedPlayerManager] Rehydrating stream metadata from soft-pause stash")
        #endif

        await didUpdateStreamMetadata(raw)
    }

    /// Called when ICY metadata changes (DirectStreamingPlayer → SharedPlayerManager).
    ///
    /// This is a primary **event-driven** source for Live Activity updates.
    /// The Live Activity push reads the just-mutated in-memory `currentStreamMetadata`
    /// and does not require (or wait for) the widget snapshot write.
    ///
    /// Widget snapshot + liveness writes are preserved (program title is useful in
    /// home widgets) but are a separate concern from the transient LA surface.
    /// Called when ICY metadata (StreamTitle) changes or is rehydrated.
    ///
    /// This is the canonical mutation site for `currentStreamMetadata`.
    /// After the assignment, emits `.metadataDidUpdate` so that any future
    /// observers receive the authoritative parsed program metadata.
    ///
    /// - Parameter metadata: Raw ICY StreamTitle (or nil to clear).
    ///
    /// - Postcondition: `nowPlayingStreamMetadata` and `currentStreamMetadata` reflect
    ///   the (parsed) value. Live Activity, Now Playing, widget snapshot, and refresh
    ///   notified. `.metadataDidUpdate` emitted via the authoritative emitter.
    ///
    /// - SeeAlso: ``emit(_:)``, `PlayerEvent.metadataDidUpdate`,
    ///   `StreamProgramMetadata.from(rawICYMetadata:)`, ``persistStreamMetadataForWidgets()``,
    ///   CODING_AGENT.md, docs/Event-Driven-Refactor-Roadmap.md (Tier 1 metadata emission).
    ///
    /// AGENT NOTE: Emission after mutation. This is the SSOT update path for program
    /// metadata. Clears that bypass this (e.g. language switch stash) should consider
    /// emitting nil explicitly if observers require it.
    func didUpdateStreamMetadata(_ metadata: String?) async {
        guard !isRunningInWidget() else { return }
        guard !WidgetRefreshManager.isSessionTeardownInProgress else { return }

        nowPlayingStreamMetadata = metadata
        currentStreamMetadata = StreamProgramMetadata.from(rawICYMetadata: metadata)

        // Emission *after* the state mutation. Authoritative site for metadata updates.
        // Additive: all existing LA/NowPlaying/widget paths continue unchanged.
        emit(.metadataDidUpdate(currentStreamMetadata))

        // Event-driven LA update (decoupled in-memory path).
        // The comparison inside RadioLiveActivityManager ensures we only cross the
        // ActivityKit boundary when title/speaker actually changed.
        await RadioLiveActivityManager.shared.updateCurrentActivity()

        await updateNowPlayingInfo()

        // Persist for widgets (program title in snapshot) — intentionally after the
        // LA push so that LA responsiveness is not gated on disk I/O.
        // Widget timeline reload is driven by ``.metadataDidUpdate`` and
        // ``.persistedWidgetStateDidUpdate`` on the Tier 2 observer path (Tier 3 dedup).
        persistStreamMetadataForWidgets()
    }
    
    /// Refreshes the system Now Playing info (MPNowPlayingInfoCenter) for Lock Screen,
    /// Control Center, Siri, and hardware remote controls.
    ///
    /// Delegates title/artist construction to `StreamProgramMetadata.nowPlayingDisplayStrings`
    /// (the single source of truth for this formatting) to guarantee parity of program
    /// titles and speaker attribution with Live Activities and widgets.
    ///
    /// Playback rate and ``MPNowPlayingInfoCenter/playbackState`` are derived from the same
    /// authoritative visual (`currentVisualState.isActivelyPlaying`) so Control Center /
    /// lock transport chrome cannot disagree with Live Activity or dictionary rate while a
    /// session is live. Session teardown and privacy clear set `.stopped` separately via
    /// ``teardownNowPlayingSession()`` / ``clearSystemNowPlayingMetadataSynchronously()``.
    ///
    /// - Precondition: Called only on the main-app `SharedPlayerManager` actor instance.
    /// - Postcondition: `MPNowPlayingInfoCenter.default().nowPlayingInfo` reflects the latest
    ///   title/artist + live rate derived from actor state; `playbackState` is `.playing`
    ///   when actively playing and `.paused` otherwise (not `.stopped` — that is reserved
    ///   for session teardown / privacy clear).
    /// - Note: `MPNowPlayingInfoCenter` coalesces frequent updates.
    /// - SeeAlso: ``didUpdateStreamMetadata(_:)``, ``clearSoftPauseMetadataStashForLanguageChange()``,
    ///   ``teardownNowPlayingSession()``, ``refreshAllMediaSurfaces(liveActivity:widgetRefresh:widgetRefreshImmediate:)``,
    ///   `StreamProgramMetadata.nowPlayingDisplayStrings(fromParsed:rawFallback:stationName:languageName:)`,
    ///   `StreamProgramMetadata.from(rawICYMetadata:)`, `RadioLiveActivityManager`,
    ///   `WidgetDisplayModels.widgetNowPlayingDisplayModel`,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   CODING_AGENT.md (Single Source of Truth Principles).
    ///
    /// AGENT NOTE: The construction of displayTitle / displayArtist was extracted in previous commit
    /// (see StreamProgramMetadata.swift). This method now only supplies context (station, language,
    /// visual playback rate / playbackState) and writes to the Center. Do not re-introduce inline
    /// if/else ladders for program vs. raw vs. station here. Update the SSOT in StreamProgramMetadata
    /// when rules change. Keep `MPNowPlayingInfoPropertyPlaybackRate` and `playbackState` aligned
    /// on every live write; do not leave `playbackState` only on teardown paths.
    func updateNowPlayingInfo() async {
        guard !isRunningInWidget() else { return }
        guard !WidgetRefreshManager.isSessionTeardownInProgress else { return }

        let stationName = String(localized: "lutheran_radio_title", table: "Localizable")
        let isActivelyPlaying = currentVisualState.isActivelyPlaying
        let playbackRate = isActivelyPlaying ? 1.0 : 0.0
        // Align MediaRemote transport state with dictionary rate: `.playing` only when
        // visual is actively playing; otherwise `.paused` while the session remains live.
        // Teardown/privacy clear set `.stopped` + nil info (separate ownership).
        let playbackState: MPNowPlayingPlaybackState = isActivelyPlaying ? .playing : .paused

        let languageCode = Self.preferredWidgetLanguage()
        let languageName = Self.streamForLanguageCode(languageCode).language

        // Use the extracted SSOT so Now Playing, widgets, and Live Activities stay in sync
        // on program titles (e.g. "Psaltaren 34") and speaker attribution.
        let display = StreamProgramMetadata.nowPlayingDisplayStrings(
            fromParsed: currentStreamMetadata,
            rawFallback: nowPlayingStreamMetadata,
            stationName: stationName,
            languageName: languageName
        )

        await MainActor.run {
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: display.title,
                MPMediaItemPropertyArtist: display.artist,
                MPNowPlayingInfoPropertyIsLiveStream: true,
                MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
                MPMediaItemPropertyMediaType: MPMediaType.anyAudio.rawValue
            ]

            if let artwork = NowPlayingArtwork.placeholder {
                info[MPMediaItemPropertyArtwork] = artwork
            }

            let center = MPNowPlayingInfoCenter.default()
            center.nowPlayingInfo = info
            center.playbackState = playbackState
        }
    }

    /// Synchronizes system Now Playing, Live Activity, and optionally home-screen widget
    /// timelines from the current in-memory actor state.
    ///
    /// This is the canonical coordination surface for visual/metadata transitions that
    /// must stay aligned across MPNowPlayingInfoCenter, ActivityKit, and WidgetKit without
    /// duplicating formatter rules or LA start policy at each call site.
    ///
    /// - Parameters:
    ///   - liveActivity: How to refresh the Live Activity. Default ``MediaSurfaceLiveActivityMode/updateIfActive``.
    ///   - widgetRefresh: When `true`, imperatively schedules
    ///     ``WidgetRefreshManager/refreshIfNeeded(visualState:currentLanguage:hasError:immediate:trigger:)``
    ///     with ``WidgetRefreshTrigger/mediaSurface``. Default `false` because mutation paths
    ///     already emit ``PlayerEvent``s consumed by the Tier 2 observer.
    ///   - widgetRefreshImmediate: Urgency when `widgetRefresh` is `true`.
    ///
    /// - Precondition: Main-app ``SharedPlayerManager`` actor only. No-op in the widget extension
    ///   and during session teardown. Under ``SharedPlayerManager/isRunningInUITestMode``, Now Playing
    ///   and Live Activity IPC are skipped; ``widgetRefresh`` may still run (subject to ``WidgetRefreshManager`` gates).
    /// - Postcondition: Requested surfaces reflect ``currentVisualState``, ``currentStreamMetadata``,
    ///   and live playback rate via ``StreamProgramMetadata/nowPlayingDisplayStrings(fromParsed:rawFallback:stationName:languageName:)``.
    ///
    /// - Important: Does **not** replace ``didUpdateStreamMetadata(_:)`` ordering (Live Activity before
    ///   widget persist). Use there only for the shared formatter via ``updateNowPlayingInfo()``.
    /// - Note: Live Activity pushes are diff-suppressed by ``RadioLiveActivityManager/lastPushedContent``;
    ///   redundant calls are cheap. Now Playing coalesces frequent updates at the system layer.
    ///   Prefer `widgetRefresh: false` so home-widget reloads stay on the event path; enable only
    ///   when an explicit imperative widget reload is required alongside NP/LA coordination.
    ///
    /// - SeeAlso: ``updateNowPlayingInfo()``, ``didUpdateStreamMetadata(_:)``, ``setPlaying()``, ``stop()``,
    ///   ``RadioLiveActivityManager/startActivity()``, ``RadioLiveActivityManager/updateCurrentActivity()``,
    ///   ``WidgetRefreshManager/refreshIfNeeded(visualState:currentLanguage:hasError:immediate:trigger:)``,
    ///   ``WidgetRefreshTrigger/mediaSurface``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md, docs/Widget-Presentation-Dataflow.md,
    ///   docs/Event-Driven-Refactor-Roadmap.md (dual-path inventory),
    ///   CODING_AGENT.md (Single Source of Truth Principles).
    ///
    /// AGENT NOTE: Prefer this wrapper over ad-hoc ``updateNowPlayingInfo()`` + detached
    /// `Task { @MainActor in … updateCurrentActivity() }` pairs at new call sites.
    func refreshAllMediaSurfaces(
        liveActivity: MediaSurfaceLiveActivityMode = .updateIfActive,
        widgetRefresh: Bool = false,
        widgetRefreshImmediate: Bool = false
    ) async {
        guard !isRunningInWidget() else { return }
        guard !WidgetRefreshManager.isSessionTeardownInProgress else { return }

        // Now Playing + Live Activity IPC are skipped under UITestMode (matches ``setPlaying()``
        // isolation). Optional imperative widget refresh remains available for tests that enable
        // the WidgetRefreshManager gate-observation bypass seam.
        #if DEBUG
        let bypassNowPlayingUnderUITest = unsafe Self._test_bypassUITestModeForNowPlayingUpdates
        let allowsNowPlaying = !Self.isRunningInUITestMode || bypassNowPlayingUnderUITest
        #else
        let allowsNowPlaying = !Self.isRunningInUITestMode
        #endif

        if allowsNowPlaying {
            await updateNowPlayingInfo()
            #if DEBUG
            Self._test_recordMediaSurfaceCoordinationStep(.nowPlayingUpdate)
            #endif
        }

        if !Self.isRunningInUITestMode {
            switch liveActivity {
            case .none:
                break
            case .updateIfActive:
                await RadioLiveActivityManager.shared.updateCurrentActivity()
                #if DEBUG
                Self._test_recordMediaSurfaceCoordinationStep(.liveActivityUpdate)
                #endif
            case .startOrUpdate:
                // SAFETY: `currentActivity` is MainActor-isolated; read it on the main actor
                // before choosing start vs. update from the SharedPlayerManager actor.
                let needsStart = await MainActor.run {
                    RadioLiveActivityManager.shared.currentActivity == nil
                }
                if needsStart {
                    await RadioLiveActivityManager.shared.startActivity()
                    #if DEBUG
                    Self._test_recordMediaSurfaceCoordinationStep(.liveActivityStart)
                    #endif
                } else {
                    await RadioLiveActivityManager.shared.updateCurrentActivity()
                    #if DEBUG
                    Self._test_recordMediaSurfaceCoordinationStep(.liveActivityUpdate)
                    #endif
                }
            }
        } else if liveActivity != .none {
            #if DEBUG
            Self._test_recordMediaSurfaceCoordinationStep(.liveActivitySkippedUnderTest)
            #endif
        }

        if widgetRefresh {
            // Imperative **mediaSurface** path (opt-in). Default production call sites leave
            // widgetRefresh false so mutation-path reloads stay on the Tier 2 observer.
            let shared = loadSharedState()
            await WidgetRefreshManager.shared.refreshIfNeeded(
                visualState: currentVisualState,
                currentLanguage: shared.currentLanguage,
                hasError: shared.hasError,
                immediate: widgetRefreshImmediate,
                trigger: .mediaSurface
            )
            #if DEBUG
            Self._test_recordMediaSurfaceCoordinationStep(.widgetRefresh)
            #endif
        }
    }

    #if DEBUG
    /// Recorded coordination steps from ``refreshAllMediaSurfaces(liveActivity:widgetRefresh:widgetRefreshImmediate:)``.
    ///
    /// Used by unit tests to assert Now Playing → Live Activity → widget refresh ordering
    /// without ActivityKit IPC under the XCTest host.
    enum MediaSurfaceCoordinationStep: Sendable, Equatable {
        case nowPlayingUpdate
        case liveActivitySkippedUnderTest
        case liveActivityUpdate
        case liveActivityStart
        case widgetRefresh
    }

    /// When `true`, ``refreshAllMediaSurfaces(liveActivity:widgetRefresh:widgetRefreshImmediate:)``
    /// writes to `MPNowPlayingInfoCenter` even under ``isRunningInUITestMode``.
    nonisolated(unsafe) private static var _test_bypassUITestModeForNowPlayingUpdates = false

    nonisolated(unsafe) private static var _test_recordMediaSurfaceCoordinationOrder = false

    nonisolated(unsafe) private static var _test_mediaSurfaceCoordinationStepLog: [MediaSurfaceCoordinationStep] = []

    /// Enables Now Playing updates during XCTest runs (no Live Activity IPC).
    nonisolated static func _test_setBypassUITestModeForNowPlayingUpdates(_ bypass: Bool) {
        unsafe _test_bypassUITestModeForNowPlayingUpdates = bypass
    }

    /// Enables append-only recording of media-surface coordination steps.
    nonisolated static func _test_setRecordMediaSurfaceCoordinationOrder(_ record: Bool) {
        unsafe _test_recordMediaSurfaceCoordinationOrder = record
    }

    nonisolated static func _test_clearMediaSurfaceCoordinationOrderLog() {
        unsafe _test_mediaSurfaceCoordinationStepLog = []
    }

    nonisolated static func _test_mediaSurfaceCoordinationOrderLog() -> [MediaSurfaceCoordinationStep] {
        unsafe _test_mediaSurfaceCoordinationStepLog
    }

    private static func _test_recordMediaSurfaceCoordinationStep(_ step: MediaSurfaceCoordinationStep) {
        guard unsafe _test_recordMediaSurfaceCoordinationOrder else { return }
        unsafe _test_mediaSurfaceCoordinationStepLog.append(step)
    }
    #endif

    /// Clears the system Now Playing session (Lock Screen, Control Center, Dynamic Island
    /// media card) and detaches the secured AVPlayer item without blocking cold launch.
    ///
    /// `MPNowPlayingInfoCenter` persists at the OS level across relaunch and reboot unless
    /// explicitly cleared — independent of the memory-only widget/visual policy.
    ///
    /// Phase 1 (awaited, lightweight): nil `nowPlayingInfo`, stop playback state, cancel
    /// pending widget reloads, and set the cross-process teardown gate.
    ///
    /// Phase 2 (detached): pause + item detach (+ optional audio-session deactivation on
    /// device only). Returns before phase 2 completes so MediaRemoteUI's launch watchdog
    /// is not tripped by synchronous main-thread AVFoundation work during factory reset.
    ///
    /// - Precondition: Main-app target only. Call during cold-launch factory reset, privacy
    ///   clear, or process termination — **not** while intentionally backgrounding live playback.
    /// - Postcondition: `nowPlayingInfo == nil`, `playbackState == .stopped`; player detach
    ///   scheduled (or skipped when debounced / re-entrant).
    /// - SeeAlso: ``resetToFactoryDefaultsOnLaunch()``, ``SharedPlayerManager/clearAllLocalState()``,
    ///   ``DirectStreamingPlayer/teardownSystemMediaSession()``, `WidgetRefreshManager.isSessionTeardownInProgress`,
    ///   docs/Event-Driven-Refactor-Roadmap.md, CODING_AGENT.md.
    func teardownNowPlayingSession() async {
        guard !isRunningInWidget() else { return }

        if isTeardownInProgress {
            #if DEBUG
            print("[SessionTeardown] LOCK held — skipped re-entrant teardownNowPlayingSession")
            #endif
            return
        }

        isTeardownInProgress = true
        WidgetRefreshManager.setSessionTeardownInProgress(true)

        #if DEBUG
        print("[SessionTeardown] LOCK — teardownNowPlayingSession phase 1 (MPNowPlayingInfoCenter clear)")
        #endif

        await MainActor.run {
            WidgetRefreshManager.shared.cancelPendingRefresh()
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }

        // Release the launch-window gate once metadata is cleared; phase 2 must not block
        // subsequent explicit teardowns (e.g. privacy clear after factory reset in tests).
        isTeardownInProgress = false
        WidgetRefreshManager.setSessionTeardownInProgress(false)

        #if DEBUG
        print("[SessionTeardown] UNLOCK — teardownNowPlayingSession phase 1 complete; phase 2 detached")
        #endif

        // SAFETY: Phase 2 runs in a detached utility task so cold-launch factory reset and
        // privacy clear return immediately after the metadata clear. Awaiting synchronous
        // AVPlayer.replaceCurrentItem + audio-session deactivation on the main actor during
        // launch previously provoked MediaRemoteUI's 0x8BADF00D watchdog (excessive CPU while
        // the system process handles Now Playing teardown). AVPlayer APIs require MainActor;
        // the detached task only hops to MainActor for the minimal pause/nil-item work.
        // Audio-session deactivation is skipped on simulator (shorter watchdog budget).
        let detachPlayerItem = true
        #if targetEnvironment(simulator)
        let deactivateAudioSession = false
        #else
        let deactivateAudioSession = true
        #endif

        Task.detached(priority: .utility) {
            await Self.performDeferredSystemMediaTeardown(
                detachPlayerItem: detachPlayerItem,
                deactivateAudioSession: deactivateAudioSession
            )
        }
    }

    /// Phase 2 of session teardown: minimal AVPlayer detach off the hot launch path.
    ///
    /// - Parameters:
    ///   - detachPlayerItem: When `true`, pauses and nils the current item (no full player replace).
    ///   - deactivateAudioSession: When `true`, deactivates `AVAudioSession` after detach.
    private static func performDeferredSystemMediaTeardown(
        detachPlayerItem: Bool,
        deactivateAudioSession: Bool
    ) async {
        guard detachPlayerItem else { return }

        await MainActor.run {
            DirectStreamingPlayer.shared.teardownSystemMediaSessionSynchronously()
        }

        guard deactivateAudioSession else { return }

        // Audio-session deactivation is skipped on simulator (shorter watchdog budget); see
        // ``teardownNowPlayingSession()`` where `deactivateAudioSession` is already `false`.
        #if !targetEnvironment(simulator)
        let timeoutNanoseconds: UInt64 = 500_000_000
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = await DirectStreamingPlayer.shared.deactivateAudioSessionAsync()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            }
            _ = await group.next()
            group.cancelAll()
        }
        #endif

        #if DEBUG
        print("[SessionTeardown] Phase 2 complete — deferred media detach finished")
        #endif
    }

    /// Best-effort synchronous clear of system Now Playing metadata.
    ///
    /// Used on `applicationWillTerminate` / `sceneDidDisconnect` where async deactivation
    /// may not complete before the process exits. The metadata clear is the critical privacy step;
    /// AVPlayer detach is intentionally omitted here to avoid main-thread MediaRemoteUI watchdog
    /// pressure during process exit.
    ///
    /// - SeeAlso: ``teardownNowPlayingSession()``, AppDelegate.applicationWillTerminate,
    ///   SceneDelegate.sceneDidDisconnect, docs/Event-Driven-Refactor-Roadmap.md.
    nonisolated static func clearSystemNowPlayingMetadataSynchronously() {
        MainActor.assumeIsolated {
            WidgetRefreshManager.shared.cancelPendingRefresh()
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
    }
}
#endif
