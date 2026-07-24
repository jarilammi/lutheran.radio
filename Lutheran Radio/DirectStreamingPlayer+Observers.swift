//
//  DirectStreamingPlayer+Observers.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 24.7.2026.
//
//  AVPlayer / AVPlayerItem KVO observers, buffer timers, and observer teardown for the streaming engine façade.
//
//  Behavior-preserving domain split from DirectStreamingPlayer.swift.
//  DirectStreamingPlayer remains the public façade; this file owns one domain.
//
//  AGENT NOTE: Members used across files are `internal` (Swift `private` is
//  file-scoped). Prefer this domain file over re-implementing attach / recovery
//  / catalog logic in call sites.
//
//  - SeeAlso: DirectStreamingPlayer.swift, DirectStreamingPlayer+PlayerItemRecovery.swift, DirectStreamingPlayer+Metadata.swift,
//    CODING_AGENT.md (Single Source of Truth Principles).
//

import Foundation
import Core
import WidgetSurface
@unsafe @preconcurrency import AVFoundation

extension DirectStreamingPlayer {
    // MARK: - Observers

    @MainActor
    func setupPlaybackObservers() {
        // Invalidate old ones first
        rateObserver?.invalidate()
        statusObserver?.invalidate()

        // Reset raw KVO trackers for the fresh observers (lastEmittedStatus is intentionally
        // left alone here — stream switches and stop/play handle the higher-level reset).
        lastObservedTimeControl = nil
        lastObservedItemStatus = nil

        #if DEBUG
        print("[DirectStreamingPlayer] 🛠 [DirectStreamingPlayer] setupPlaybackObservers() — setting up Swift-6-safe observers")
        #endif

        // === timeControlStatus observer (rateObserver) ===
        rateObserver = player?.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] observedPlayer, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }

                // Lightweight raw-value dedup in the KVO handler itself.
                let newTC = observedPlayer.timeControlStatus
                guard self.lastObservedTimeControl != newTC else { return }
                self.lastObservedTimeControl = newTC

                #if DEBUG
                print("[DirectStreamingPlayer] [KVO] timeControlStatus → \(newTC.rawValue) | rate: \(observedPlayer.rate)")
                #endif

                switch newTC {
                case .playing:
                    self.cancelEarlyICYDropRecreate()
                    // KVO resurrection protection is driven by authoritative playback intent.
                    guard await SharedPlayerManager.shared.canProceedWithPlayback() else {
                        #if DEBUG
                        print("[DirectStreamingPlayer] [KVO] timeControlStatus.playing: resurrection suppressed by playbackIntent — enforcing pause")
                        #endif
                        if observedPlayer.rate > 0 {
                            observedPlayer.pause()
                            observedPlayer.rate = 0.0
                        }
                        return
                    }
                    guard observedPlayer.currentItem?.status == .readyToPlay else {
                        #if DEBUG
                        print("[DirectStreamingPlayer] [KVO] timeControlStatus.playing: ignoring until item ready (status=\(observedPlayer.currentItem?.status.rawValue ?? -1))")
                        #endif
                        return
                    }
                    self.safeOnStatusChange(isPlaying: true, reasonKey: "status_playing")
                    self.hasStartedPlaying = true
                    self.stopBufferingTimer()
                    // Defense-in-depth: if readyToPlay kick already published chrome, this no-ops;
                    // if KVO observed audible play first, surfaces catch up here.
                    await self.publishAuthoritativePlayingIfNeeded()
                    
                case .paused:
                    if !self.isPlaybackTeardownActive && observedPlayer.rate == 0.0 {
                        self.safeOnStatusChange(isPlaying: false, reasonKey: "status_stopped")
                    }
                    
                    // Early `timeControlStatus` drops on a fresh ICY attach (before stable play)
                    // often arrive without `playerItem.error`. Route them through the same
                    // early-window budget and intent guard as buffer-empty / item-failure recovery
                    // so the 5 s startup safety net is a last resort rather than the primary path.
                    if !self.isPlaybackTeardownActive
                        && !self.hasStartedPlaying
                        && !self.isDeferringFirstPlayKick
                        && self.initialPlaybackRetryCount < self.maxInitialRetries {
                        self.scheduleEarlyICYDropRecreate(rate: observedPlayer.rate)
                    }
                    
                case .waitingToPlayAtSpecifiedRate:
                    self.safeOnStatusChange(isPlaying: false, reasonKey: "status_buffering")
                    
                @unknown default:
                    break
                }
            }
        }
        
        // === item status observer (statusObserver) ===
        statusObserver = player?.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }

                // Lightweight raw-value dedup in the KVO handler itself.
                let newItemStatus = item.status
                if self.lastObservedItemStatus == newItemStatus {
                    // Raw status unchanged — the downstream tuple dedup in invokeStatusCallbacks
                    // will still catch any derived (isPlaying, reasonKey) duplicates.
                } else {
                    self.lastObservedItemStatus = newItemStatus
                }

                #if DEBUG
                print("[DirectStreamingPlayer] [KVO] Item status → \(newItemStatus.rawValue)")
                #endif

                switch newItemStatus {
                case .readyToPlay:
                    // First-play kick and status_playing emission are handled by addObservers'
                    // readyToPlay branch (single canonical path after startPlayback deferral).
                    break

                case .failed:
                    // Route through the canonical decision point: early-window transients
                    // recover via secured `recreatePlayerItem()`; permanent failures surface.
                    await self.handleItemStatusFailure(item)
                default:
                    break
                }
                
                await SharedPlayerManager.shared.saveCurrentState()
            }
        }
        
        // Ensure ICY metadata delegate is wired on the fresh player item.
        // This is the single canonical attachment point (tracked in `metadataOutput` for
        // proper cleanup in stop paths and idempotent re-attach on item replacement).
        ensureICYAttached()
    }

    func startBufferingTimer() {
        stopBufferingTimer()
        bufferingTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.stop()
            #if DEBUG
            print("⏰ Buffering timeout triggered")
            #endif
            self.safeOnStatusChange(isPlaying: false, reasonKey: "status_stopped")   // ← fixed
        }
    }
    
    func stopBufferingTimer() {
        bufferingTimer?.invalidate()
        bufferingTimer = nil
    }
    
    // FIXED: Remove the cancelPendingSSLProtection method that relied on shared connectionStartTime
    func cancelPendingSSLProtection() {
        clearSSLProtectionTimer()
        #if DEBUG
        print("[DirectStreamingPlayer] [Manual Cancel] Cancelled pending SSL protection")
        #endif
    }
    
    // FIXED: Update clearSSLProtectionTimer to remove debug reference
    func clearSSLProtectionTimer() {
        clearAllSSLProtectionTimers()
        isSSLHandshakeComplete = true
        
        #if DEBUG
        print("[DirectStreamingPlayer] SSL protection timer cleared")
        #endif
    }
    
    // NOTE: getCurrentMetadataForLiveActivity was removed (2026-06).
    // Live Activity now sources metadata exclusively via SharedPlayerManager
    // (currentStreamMetadata + loadPersistedStreamMetadata) + PlayerVisualState SSOT.
    // The old direct accessor was no longer called after the LA/SSOT consolidation.

    func addObservers() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            #if DEBUG
            print("[DirectStreamingPlayer] addObservers() called — clearing old ones")
            #endif
            
            // Clear existing first (safe even if called multiple times)
            self.playerItemObservations.forEach { $0.invalidate() }
            self.playerItemObservations.removeAll()
            
            guard let playerItem = self.playerItem else {
                #if DEBUG
                print("[DirectStreamingPlayer] addObservers: No playerItem yet")
                #endif
                return
            }
            
            // Status observer — now actively handles .readyToPlay (critical for initial playback)
            let statusObs = playerItem.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                guard let self = self else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    #if DEBUG
                    print("[DirectStreamingPlayer] Player item status changed: \(item.status.rawValue) (readyToPlay=1, failed=2)")
                    #endif
                    
                    guard self.delegate != nil else { return }
                    
                    switch item.status {
                    case .readyToPlay:
                        // Canonical first-play kick: cold launch and stream-switch attach defer
                        // playImmediately from startPlayback until the secured item is ready.
                        // Must re-check sticky pause / soft-pause / teardown — user may have paused
                        // during connect while this item was still loading.
                        // Authoritative `.playing` chrome is published only after the kick so
                        // Now Playing rate / Live Activity glyph never lead audible audio.
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            guard item === self.playerItem else { return }
                            guard await self.shouldAllowAudiblePlaybackKick() else {
                                self.isDeferringFirstPlayKick = false
                                self.player?.pause()
                                self.player?.rate = 0.0
                                #if DEBUG
                                print("[DirectStreamingPlayer] readyToPlay kick suppressed — user pause / soft-pause / teardown")
                                #endif
                                return
                            }
                            #if DEBUG
                            print("[DirectStreamingPlayer] Item readyToPlay → starting playback")
                            #endif
                            
                            self.initialPlaybackRetryCount = 0
                            
                            self.isDeferringFirstPlayKick = false
                            self.cancelEarlyICYDropRecreate()
                            if (self.player?.rate ?? 0) < 0.1 {
                                self.player?.playImmediately(atRate: 1.0)
                                #if DEBUG
                                print("[DirectStreamingPlayer] playImmediately called — timeControlStatus: \(self.player?.timeControlStatus.rawValue ?? -1), rate: \(self.player?.rate ?? -1), item.status: \(item.status.rawValue)")
                                #endif
                            }
                            self.safeOnStatusChange(isPlaying: true, reasonKey: "status_playing")   // ← fixed
                            self.stopBufferingTimer()
                            self.hasStartedPlaying = true
                            await self.publishAuthoritativePlayingIfNeeded()
                        }
                        
                    case .failed:
                        break
                        
                    case .unknown:
                        if self.hasStartedPlaying {
                            self.safeOnStatusChange(isPlaying: false, reasonKey: "status_buffering")   // ← fixed
                        }
                    @unknown default:
                        break
                    }
                }
                
                // Failed status uses direct MainActor Task hop from KVO (no double Dispatch+Task).
                // This path routes to the canonical handleItemStatusFailure for classification + early retry budget.
                if item.status == .failed {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.lastError = item.error
                        await self.handleItemStatusFailure(item)
                    }
                }
            }
            self.playerItemObservations.append(statusObs)
            #if DEBUG
            print("[DirectStreamingPlayer] Added robust status observer")
            #endif
            
            // Buffer observers: early-window AVFoundation errors recover immediately via the
            // secured recreate path; post-stable stalls use a longer debounce.
            let bufferEmptyObs = playerItem.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, change in
                guard let self = self, let newValue = change.newValue, newValue else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard !self.isPlaybackTeardownActive else { return }
                    if let error = item.error as NSError?, error.domain == AVFoundationErrorDomain {
                        #if DEBUG
                        print("[DirectStreamingPlayer] Buffer empty with AVFoundation error — early-window recovery path")
                        #endif
                        // Short debounce coalesces bursty decoder noise into one recreate.
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !self.isPlaybackTeardownActive else { return }
                        guard self.playerItem === item else { return }
                        let recovered = await self.attemptEarlyWindowTransientRecovery(
                            reason: "bufferEmpty+AVFoundationError",
                            allowWhileDeferringFirstPlayKick: true
                        )
                        if !recovered && !StreamErrorType.from(error: error).isPermanent {
                            // Post-stable or budget-exhausted transient: still try one secured recreate
                            // when intent allows (does not mark sticky user pause).
                            guard await SharedPlayerManager.shared.canProceedWithPlayback() else { return }
                            self.recreatePlayerItem()
                        }
                        return
                    }
                    self.safeOnStatusChange(isPlaying: false, reasonKey: "status_buffering")
                    self.startBufferingTimer()
                }
            }
            self.playerItemObservations.append(bufferEmptyObs)
            
            let likelyToKeepUpObs = playerItem.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, change in
                guard let self = self, let newValue = change.newValue else { return }
                if newValue && item.status == .readyToPlay {
                    guard !self.isDeferringFirstPlayKick else { return }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard await SharedPlayerManager.shared.canProceedWithPlayback() else { return }
                        if (self.player?.rate ?? 0) < 0.1 {
                            self.player?.play()
                        }
                        if self.hasStartedPlaying {
                            self.safeOnStatusChange(isPlaying: true, reasonKey: "status_playing")
                            self.stopBufferingTimer()
                        }
                    }
                } else if !newValue && (self.player?.rate ?? 0) == 0 {
                    // KVO is nonisolated — hop to MainActor before reading attach grace /
                    // early-window state (``currentAttachBeganAt`` is MainActor-isolated).
                    // Early attach: wait loading grace + short debounce before treating
                    // "not likely to keep up" as a stall. Post-stable uses a longer debounce.
                    // Startup safety net remains a final fallback only.
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let inEarlyWindow = !self.hasStartedPlaying
                            && self.initialPlaybackRetryCount < self.maxInitialRetries
                        let stalledDelay: TimeInterval = {
                            if inEarlyWindow {
                                let graceRemaining = self.remainingEarlyAttachLoadingGraceSeconds()
                                let debounce = self.isLowEfficiencyMode
                                    ? self.earlyAttachStallDebounceSeconds * 1.5
                                    : self.earlyAttachStallDebounceSeconds
                                return graceRemaining + debounce
                            }
                            return self.isLowEfficiencyMode ? 20.0 : 10.0
                        }()
                        try? await Task.sleep(for: .seconds(stalledDelay))
                        guard !self.isPlaybackTeardownActive else { return }
                        guard let currentItem = self.playerItem,
                              currentItem === item,
                              !currentItem.isPlaybackLikelyToKeepUp,
                              (self.player?.rate ?? 0) == 0 else { return }
                        guard await SharedPlayerManager.shared.canProceedWithPlayback() else { return }
                        if !self.hasStartedPlaying && self.initialPlaybackRetryCount < self.maxInitialRetries {
                            guard self.shouldAttemptEarlyAttachStallRecovery(
                                item: currentItem,
                                rate: self.player?.rate ?? 0
                            ) else {
                                #if DEBUG
                                print("[DirectStreamingPlayer] Early-window stall deferred — item still loading within grace (status=\(currentItem.status.rawValue))")
                                #endif
                                return
                            }
                            #if DEBUG
                            print("[DirectStreamingPlayer] Early-window stall — secured recreatePlayerItem")
                            #endif
                            _ = await self.attemptEarlyWindowTransientRecovery(
                                reason: "stalled-early",
                                allowWhileDeferringFirstPlayKick: true
                            )
                        } else if self.hasStartedPlaying {
                            #if DEBUG
                            print("[DirectStreamingPlayer] Stalled — secured recreatePlayerItem")
                            #endif
                            self.recreatePlayerItem()
                        }
                    }
                }
            }
            self.playerItemObservations.append(likelyToKeepUpObs)
            
            let bufferFullObs = playerItem.observe(\.isPlaybackBufferFull, options: [.new]) { [weak self] item, change in
                guard let self = self, let newValue = change.newValue, newValue else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard await SharedPlayerManager.shared.canProceedWithPlayback() else { return }
                    self.player?.play()
                    self.safeOnStatusChange(isPlaying: true, reasonKey: "status_playing")
                    self.stopBufferingTimer()
                }
            }
            self.playerItemObservations.append(bufferFullObs)
            
            #if DEBUG
            print("[DirectStreamingPlayer] Added buffer observers")
            #endif
            
            // Time observer (kept as-is)
            let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            if let player = self.player, self.timeObserver == nil {
                self.timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
                    guard let self = self, self.delegate != nil else { return }
                    if (self.player?.rate ?? 0) > 0 {
                        self.safeOnStatusChange(isPlaying: true, reasonKey: "status_playing")   // ← fixed
                    }
                }
                self.timeObserverPlayer = player
                #if DEBUG
                print("[DirectStreamingPlayer] Added time observer")
                #endif
            }
        }
    }

    func removeObservers(for playerItem: AVPlayerItem?) {
        self.playerItemObservations.forEach { $0.invalidate() }
        self.playerItemObservations.removeAll()
    }

    func removeObserversFrom(_ playerItem: AVPlayerItem) {
        self.playerItemObservations.forEach { $0.invalidate() }
        self.playerItemObservations.removeAll()
    }

    func removeObserversImplementation() {
        if isDeallocating {
            removeObserversSynchronously()
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isDeallocating else {
                return
            }
            self.removeObserversSynchronously()
        }
    }

    func removeObserversSynchronously() {
        self.playerItemObservations.forEach { $0.invalidate() }
        self.playerItemObservations.removeAll()
        
        if let timeObserver = self.timeObserver, let player = self.timeObserverPlayer {
            player.removeTimeObserver(timeObserver)
        }
        self.timeObserver = nil
        self.timeObserverPlayer = nil
        
        // Clear raw KVO trackers when observers are torn down.
        lastObservedTimeControl = nil
        lastObservedItemStatus = nil
    }
}
