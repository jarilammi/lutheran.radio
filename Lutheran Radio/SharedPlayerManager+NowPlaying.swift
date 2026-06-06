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
    
    /// Called when ICY metadata changes (DirectStreamingPlayer → SharedPlayerManager).
    func didUpdateStreamMetadata(_ metadata: String?) async {
        guard !isRunningInWidget() else { return }
        nowPlayingStreamMetadata = metadata
        currentStreamMetadata = StreamProgramMetadata.from(rawICYMetadata: metadata)

        persistStreamMetadataForWidgets()

        await updateNowPlayingInfo()
        await RadioLiveActivityManager.shared.updateCurrentActivity()
    }
    
    /// Refreshes MPNowPlayingInfoCenter from current visual state and metadata.
    func updateNowPlayingInfo() async {
        guard !isRunningInWidget() else { return }
        
        let stationName = String(localized: "lutheran_radio_title", table: "Localizable")
        let cachedMetadata = nowPlayingStreamMetadata
        let isActivelyPlaying = currentVisualState.isActivelyPlaying
        let playbackRate = isActivelyPlaying ? 1.0 : 0.0
        
        let playerMetadata = await MainActor.run {
            DirectStreamingPlayer.shared.currentMetadata
        }
        let displayTitle = cachedMetadata ?? playerMetadata ?? stationName
        
        await MainActor.run {
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: displayTitle,
                MPMediaItemPropertyArtist: stationName,
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