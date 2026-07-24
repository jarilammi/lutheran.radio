//
//  DirectStreamingPlayer+Metadata.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 24.7.2026.
//
//  ICY / StreamTitle metadata push delegate and ensureICYAttached for live items.
//
//  Behavior-preserving domain split from DirectStreamingPlayer.swift.
//  DirectStreamingPlayer remains the public façade; this file owns one domain.
//
//  AGENT NOTE: Members used across files are `internal` (Swift `private` is
//  file-scoped). Prefer this domain file over re-implementing attach / recovery
//  / catalog logic in call sites.
//
//  - SeeAlso: DirectStreamingPlayer.swift,
//    CODING_AGENT.md (Single Source of Truth Principles).
//

import Foundation
@unsafe @preconcurrency import AVFoundation

// MARK: - Metadata Handling
extension DirectStreamingPlayer: AVPlayerItemMetadataOutputPushDelegate {
    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                        from track: AVPlayerItemTrack?) {
        guard delegate != nil,
              let group = groups.last else { return }

        // A group can contain multiple metadata items; only StreamTitle candidates trigger async work.
        for item in group.items {
            processPotentialStreamTitle(item)
        }
    }

    /// Modern iOS 16+ implementation for ICY/StreamTitle metadata extraction.
    ///
    /// Uses the non-deprecated `load(_:)` / `status(of:)` async properties on `AVMetadataItem`
    /// (replaces the deprecated `loadValuesAsynchronously(forKeys:)` + `statusOfValue(forKey:)`).
    /// Performs cheap synchronous filtering on identifier/key before any loading work.
    /// All UI / delegate side effects are dispatched back to the main queue.
    func processPotentialStreamTitle(_ item: AVMetadataItem) {
        // Capture Sendable filter criteria synchronously (cheap, no Sendable issues)
        let identifier = item.identifier?.rawValue
        let key = item.key as? String

        let isStreamTitle = (identifier?.localizedCaseInsensitiveContains("streamtitle") == true) ||
                            (identifier == "icy/StreamTitle") ||
                            (key == "StreamTitle")

        guard isStreamTitle else { return }

        // Modern async API (iOS 16+). The Task closure capture of non-Sendable AVMetadataItem
        // is tolerated thanks to @preconcurrency import AVFoundation.
        Task { [weak self] in
            if let title = try? await item.load(.stringValue) {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                await MainActor.run { [weak self] in
                    guard let self else { return }

                    self.currentMetadata = trimmed
                    self.hasReceivedLiveStreamMetadata = true
                    
                    self.safeOnMetadataChange(metadata: trimmed)
                    if self.needsImmediateMetadataPush {
                        self.needsImmediateMetadataPush = false
                        #if DEBUG
                        print("[DirectStreamingPlayer] LIVE ICY [ensured after re-attach]: \(trimmed)")
                        #endif
                    } else {
                        #if DEBUG
                        print("[DirectStreamingPlayer] Using LIVE ICY metadata: \(trimmed)")
                        #endif
                    }
                }
            }
        }
    }

    /// Guarantees metadata delegate is attached to every new AVPlayerItem (critical on same-stream resume).
    /// Sets the explicit flag so the very next ICY StreamTitle triggers an immediate Now Playing / widget update.
    @MainActor
    func ensureICYAttached() {
        guard let item = player?.currentItem else { return }
        
        // Defensive clean + re-attach (idempotent)
        if let old = metadataOutput {
            item.remove(old)
        }
        
        let newOutput = AVPlayerItemMetadataOutput(identifiers: nil)
        newOutput.setDelegate(self, queue: .main)
        item.add(newOutput)
        metadataOutput = newOutput
        
        needsImmediateMetadataPush = true
        
        #if DEBUG
        print("[DirectStreamingPlayer] ICY metadata output re-attached to fresh player item")
        #endif
    }
}
