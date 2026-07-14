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

// MARK: - MainActor-only MediaPlayer wiring (MPRemoteCommandCenter requires main thread)

@MainActor
private enum NowPlayingRemoteCommands {
    static var installed = false
    
    /// One-time MPRemoteCommandCenter wiring. Must run on the main actor.
    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        
        let center = MPRemoteCommandCenter.shared()
        [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.stopCommand]
            .forEach { $0.removeTarget(nil) }
        
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { _ in
            // Explicit hardware/software remote play must go through designated entry.
            Task { await SharedPlayerManager.shared.userRequestedPlay() }
            return .success
        }
        
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { _ in
            Task { await SharedPlayerManager.shared.stop() }
            return .success
        }
        
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { _ in
            Task {
                let isActivelyPlaying = await SharedPlayerManager.shared.currentVisualState.isActivelyPlaying
                if isActivelyPlaying {
                    await SharedPlayerManager.shared.stop()
                } else {
                    // Toggle play branch from remote also uses designated entry.
                    await SharedPlayerManager.shared.userRequestedPlay()
                }
            }
            return .success
        }
        
        center.stopCommand.isEnabled = true
        center.stopCommand.addTarget { _ in
            Task { await SharedPlayerManager.shared.stop() }
            return .success
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
    /// One-time MPRemoteCommandCenter wiring (main app only).
    func configureNowPlayingControlsIfNeeded() async {
        guard !isRunningInWidget() else { return }
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        await MainActor.run {
            NowPlayingRemoteCommands.installIfNeeded()
        }
    }
    
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
    /// - Precondition: Called only on the main-app `SharedPlayerManager` actor instance.
    /// - Postcondition: `MPNowPlayingInfoCenter.default().nowPlayingInfo` reflects the latest
    ///   title/artist + live rate derived from actor state.
    /// - Note: `MPNowPlayingInfoCenter` coalesces frequent updates.
    /// - SeeAlso: ``didUpdateStreamMetadata(_:)``, ``clearSoftPauseMetadataStashForLanguageChange()``,
    ///   `StreamProgramMetadata.nowPlayingDisplayStrings(fromParsed:rawFallback:stationName:languageName:)`,
    ///   `StreamProgramMetadata.from(rawICYMetadata:)`, `RadioLiveActivityManager`,
    ///   `WidgetDisplayModels.widgetNowPlayingDisplayModel`,
    ///   CODING_AGENT.md (Single Source of Truth Principles).
    ///
    /// AGENT NOTE: The construction of displayTitle / displayArtist was extracted in previous commit
    /// (see StreamProgramMetadata.swift). This method now only supplies context (station, language,
    /// visual playback rate) and writes to the Center. Do not re-introduce inline if/else ladders
    /// for program vs. raw vs. station here. Update the SSOT in StreamProgramMetadata when rules change.
    func updateNowPlayingInfo() async {
        guard !isRunningInWidget() else { return }
        guard !WidgetRefreshManager.isSessionTeardownInProgress else { return }

        let stationName = String(localized: "lutheran_radio_title", table: "Localizable")
        let isActivelyPlaying = currentVisualState.isActivelyPlaying
        let playbackRate = isActivelyPlaying ? 1.0 : 0.0

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

            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
    ///   - widgetRefresh: When `true`, imperatively schedules ``WidgetRefreshManager/refreshIfNeeded(visualState:currentLanguage:hasError:immediate:)``.
    ///     Default `false` because mutation paths already emit ``PlayerEvent``s consumed by the Tier 2 observer.
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
    ///
    /// - SeeAlso: ``updateNowPlayingInfo()``, ``didUpdateStreamMetadata(_:)``, ``setPlaying()``, ``stop()``,
    ///   ``RadioLiveActivityManager/startActivity()``, ``RadioLiveActivityManager/updateCurrentActivity()``,
    ///   ``WidgetRefreshManager/refreshIfNeeded(visualState:currentLanguage:hasError:immediate:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md, docs/Widget-Presentation-Dataflow.md,
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
            let shared = loadSharedState()
            await WidgetRefreshManager.shared.refreshIfNeeded(
                visualState: currentVisualState,
                currentLanguage: shared.currentLanguage,
                hasError: shared.hasError,
                immediate: widgetRefreshImmediate
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