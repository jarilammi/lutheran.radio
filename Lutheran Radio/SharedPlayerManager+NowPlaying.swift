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
        // This keeps widget observable behavior unchanged while giving LA the fast path.
        persistStreamMetadataForWidgets()

        let state = loadSharedState()
        await WidgetRefreshManager.shared.refreshIfNeeded(
            visualState: currentVisualState,
            currentLanguage: Self.preferredWidgetLanguage(),
            hasError: state.hasError
        )
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

    /// Aggressively clears the system Now Playing session (Lock Screen, Control Center,
    /// Dynamic Island media card) and detaches the AVPlayer item.
    ///
    /// `MPNowPlayingInfoCenter` persists at the OS level across relaunch and reboot unless
    /// explicitly cleared — independent of the memory-only widget/visual policy.
    ///
    /// - Precondition: Main-app target only. Call during cold-launch factory reset, privacy
    ///   clear, or process termination — **not** while intentionally backgrounding live playback.
    /// - Postcondition: `nowPlayingInfo == nil`, `playbackState == .stopped`; secured item detached.
    /// - SeeAlso: ``resetToFactoryDefaultsOnLaunch()``, ``SharedPlayerManager/clearAllLocalState()``,
    ///   ``DirectStreamingPlayer/teardownSystemMediaSession()``, CODING_AGENT.md.
    func teardownNowPlayingSession() async {
        guard !isRunningInWidget() else { return }

        #if DEBUG
        print("[SessionTeardown] Clearing MPNowPlayingInfoCenter + AVPlayer item")
        #endif

        await MainActor.run {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }

        await DirectStreamingPlayer.shared.teardownSystemMediaSession()
    }

    /// Best-effort synchronous clear of system Now Playing metadata.
    ///
    /// Used on `applicationWillTerminate` / `sceneDidDisconnect` where async deactivation
    /// may not complete before the process exits. The metadata clear is the critical privacy step.
    ///
    /// - SeeAlso: ``teardownNowPlayingSession()``, AppDelegate.applicationWillTerminate,
    ///   SceneDelegate.sceneDidDisconnect.
    nonisolated static func clearSystemNowPlayingMetadataSynchronously() {
        MainActor.assumeIsolated {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            DirectStreamingPlayer.shared.teardownSystemMediaSessionSynchronously()
        }
    }
}
#endif
