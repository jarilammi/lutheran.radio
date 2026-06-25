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
    func didUpdateStreamMetadata(_ metadata: String?) async {
        guard !isRunningInWidget() else { return }
        nowPlayingStreamMetadata = metadata
        currentStreamMetadata = StreamProgramMetadata.from(rawICYMetadata: metadata)

        persistStreamMetadataForWidgets()

        await updateNowPlayingInfo()
        await RadioLiveActivityManager.shared.updateCurrentActivity()

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
    /// Uses the parsed `currentStreamMetadata` (programTitle + speaker) as the primary source
    /// to ensure content parity with Live Activities and widgets. Falls back through raw ICY
    /// metadata then a language-augmented station name.
    ///
    /// - Precondition: Called only on the main-app `SharedPlayerManager` actor instance.
    /// - Postcondition: `MPNowPlayingInfoCenter.default().nowPlayingInfo` reflects the latest
    ///   title/artist + live rate derived from actor state.
    /// - Note: `MPNowPlayingInfoCenter` coalesces frequent updates.
    /// - SeeAlso: ``didUpdateStreamMetadata(_:)``, ``clearSoftPauseMetadataStashForLanguageChange()``,
    ///   `StreamProgramMetadata.from(rawICYMetadata:)`, `RadioLiveActivityManager`,
    ///   CODING_AGENT.md (Single Source of Truth Principles).
    func updateNowPlayingInfo() async {
        guard !isRunningInWidget() else { return }

        let stationName = String(localized: "lutheran_radio_title", table: "Localizable")
        let isActivelyPlaying = currentVisualState.isActivelyPlaying
        let playbackRate = isActivelyPlaying ? 1.0 : 0.0

        let languageCode = Self.preferredWidgetLanguage()
        let languageName = Self.streamForLanguageCode(languageCode).language

        // Prefer the parsed metadata (identical source to LA/widgets) so Now Playing shows
        // the same program title (e.g. "Psaltaren 34") when it becomes available via ICY.
        let meta = currentStreamMetadata
        let displayTitle: String
        let displayArtist: String

        if let program = meta?.programTitle, !program.isEmpty {
            displayTitle = program
            if let speaker = meta?.speaker, !speaker.isEmpty {
                displayArtist = "\(speaker) • \(stationName)"
            } else {
                displayArtist = "\(languageName) • \(stationName)"
            }
        } else if let raw = nowPlayingStreamMetadata, !raw.isEmpty {
            displayTitle = raw
            displayArtist = "\(languageName) • \(stationName)"
        } else {
            displayTitle = stationName
            displayArtist = "\(languageName) • \(stationName)"
        }

        await MainActor.run {
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: displayTitle,
                MPMediaItemPropertyArtist: displayArtist,
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
}
#endif
