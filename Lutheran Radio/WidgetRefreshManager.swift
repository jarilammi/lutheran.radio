//
//  WidgetRefreshManager.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 14.6.2025.
//
//  Prevents excessive widget refreshes through debouncing and change detection.
//  Now fully aligned with PlayerVisualState as the Single Source of Truth (SSOT).
//

// SHARED: Cross-target source (main app + LutheranRadioWidgetExtension)
//
// Single physical file on disk, compiled into both targets via Xcode
// File System Synchronized Group + membershipExceptions (see project.pbxproj).
//
// Purpose:
// @MainActor coordinator for debounced, coalesced `WidgetCenter.reloadTimelines`
// calls. Prevents spam while ensuring widgets and Live Activities reflect the
// latest `PlayerVisualState` promptly.
//
// Key invariants:
// - 100% driven by `PlayerVisualState` (the SSOT).
// - Respects the privacy gate `hasActiveLutheranWidgets` (via
//   `WidgetRefreshManager` + `SharedPlayerManager`) to suppress writes when no
//   Lutheran widgets are installed.
// - Coalesces `.prePlay` → `.playing` and dedupes sticky states.
// - This file contains *no* security logic. Security decisions live only in
//   `Core/` (see CODING_AGENT.md "Core Framework Surface Area").
//
// - SeeAlso: `SharedPlayerManager` (calls `refreshIfNeeded`), `PlayerVisualState`,
//   `PersistedWidgetState`, CODING_AGENT.md (Single Source of Truth Principles
//   + "Cross-target shared source files (non-Core)"), README.md.

import Foundation
import WidgetKit

/// WidgetRefreshManager prevents excessive WidgetKit reloads through debouncing,
/// change detection, and adaptive intervals. It is now 100% driven by PlayerVisualState.
@MainActor
final class WidgetRefreshManager: @unchecked Sendable {
    static let shared = WidgetRefreshManager()
    
    private var lastRefreshTime: Date?
    private var pendingRefresh: DispatchWorkItem?
    /// Latest debounced target; read when the debounce timer runs so superseded visuals never reload timelines.
    private var pendingRefreshState: WidgetState?
    private var lastKnownState: WidgetState?
    /// Deferred `.prePlay` refresh; superseded by `.playing` on the same language within the coalesce window.
    private var coalescedPrePlayWorkItem: DispatchWorkItem?
    private var coalescedPrePlayState: WidgetState?
    
    private var refreshCount = 0
    private var adaptiveInterval: TimeInterval = 0.5
    private static let prePlayToPlayingCoalesceWindow: TimeInterval = 0.3

    // MARK: - Privacy support (widget presence gating for write suppression)
    // Single source of truth for active Lutheran Radio widgets (home widget + Control Center kind).
    // Used by SharedPlayerManager write paths to suppress re-population of persistedWidgetState,
    // instantFeedback*, pendingAction*, lastUpdateTime, etc. when no Lutheran widgets are configured.
    // After an explicit clearAllLocalState the flag is forced false even
    // if configs still list the widget (prevents immediate re-write of a fresh snapshot on next play
    // until explicit re-detect on foreground or subsequent detection).
    // Widget providers (LutheranRadioWidget.swift, Control, LiveActivity) already early-return
    // to safe .prePlay + preferred language defaults when loadPersistedWidgetState() == nil.
    // The canonical list of our widget kinds lives in `ourWidgetKinds`.
    //
    // Concurrency: nonisolated(unsafe) justified because:
    // - Updates are serialized exclusively through @MainActor entry points (refreshHasActiveWidgets, setHasActiveLutheranWidgets, performRefresh).
    // - The containing class is already @unchecked Sendable (existing pattern in this file for WidgetKit/refresh state).
    // - Reads are best-effort cache for a privacy optimization gate (occasional stale true -> one extra write is harmless; false when should be true just delays a write until next foreground detect).
    // - Matches the risk profile of other timestamp/liveness mutable state already managed here.
    nonisolated(unsafe) static private var _hasActiveLutheranWidgets: Bool = false
    // Nonisolated getter so it can be read from nonisolated static write-guard paths in SharedPlayerManager
    // (and widget extension code) while updates remain serialized on @MainActor.
    nonisolated static var hasActiveLutheranWidgets: Bool { unsafe _hasActiveLutheranWidgets }

    @MainActor
    static func setHasActiveLutheranWidgets(_ value: Bool) {
        unsafe _hasActiveLutheranWidgets = value
    }

    /// Re-queries WidgetCenter.currentConfigurations() and updates the hasActiveLutheranWidgets flag.
    /// Primary call sites: sceneDidBecomeActive / foreground (SceneDelegate), after clear (forced false
    /// first, then re-detect allowed on next foreground), and opportunistic on write attempts when suppressed.
    @MainActor
    func refreshHasActiveWidgets() async {
        do {
            let configs = try await WidgetCenter.shared.currentConfigurations()
            let hasActive = configs.contains { Self.ourWidgetKinds.contains($0.kind) }
            Self.setHasActiveLutheranWidgets(hasActive)
            #if DEBUG
            print("[WidgetRefreshManager] Active Lutheran widgets re-detected for privacy gate: \(hasActive) (configs: \(configs.count))")
            #endif
        } catch {
            #if DEBUG
            print("[WidgetRefreshManager] refreshHasActiveWidgets failed: \(error.localizedDescription)")
            #endif
        }
    }
    
    private init() {}

    // Single source for the widget kind identifiers we own (home widget + Control Center widget).
    // Used by the privacy hasActiveLutheranWidgets gate in refresh paths. Centralizing here means
    // adding a new widget kind in the future only requires one edit.
    private static let ourWidgetKinds = ["LutheranRadioWidget", "radio.lutheran.LutheranRadio.LutheranRadioWidget"]
    
    // MARK: - Modern API (only public entry point)
    
    /// Drops any scheduled debounced refresh (e.g. before a visual SSOT transition).
    func cancelPendingRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        pendingRefreshState = nil
        cancelCoalescedPrePlayRefresh()
    }
    
    /// Recommended call site: pass the real visual state directly.
    /// All widget intents, SharedPlayerManager, and Live Activities now use this.
    func refreshIfNeeded(
        visualState: PlayerVisualState,
        currentLanguage: String,
        hasError: Bool,
        immediate: Bool = false
    ) {
        let newState = WidgetState(
            from: visualState,
            currentLanguage: currentLanguage,
            hasError: hasError,
            isTransitioning: false
        )
        
        if shouldCancelPendingDebounce(for: newState.visualState) {
            cancelPendingRefresh()
        }
        
        // ALWAYS refresh on language changes, regardless of throttling
        if let lastState = lastKnownState,
           lastState.currentLanguage != newState.currentLanguage {
            cancelCoalescedPrePlayRefresh()
            Task { @MainActor in
                await performRefreshIfNotStale(for: newState)
            }
            return
        }
        
        // Errors and non-playing visual transitions supersede a deferred .prePlay refresh.
        if hasError {
            cancelCoalescedPrePlayRefresh()
        } else if coalescedPrePlayState != nil,
                  newState.visualState != .prePlay,
                  newState.visualState != .cleared,
                  newState.visualState != .playing {
            cancelCoalescedPrePlayRefresh()
        }
        
        // Coalesce back-to-back .prePlay/.cleared → .playing refreshes on the same language.
        if !hasError,
           newState.visualState == .playing,
           let prePlaySource = coalescedPrePlayState ?? lastKnownState,
           prePlaySource.currentLanguage == newState.currentLanguage,
           prePlaySource.visualState == .prePlay || prePlaySource.visualState == .cleared,
           prePlaySource.hasError == newState.hasError {
            let withinCoalesceWindow = coalescedPrePlayState != nil
                || (lastRefreshTime.map { Date().timeIntervalSince($0) < Self.prePlayToPlayingCoalesceWindow } ?? false)
            if withinCoalesceWindow {
                cancelCoalescedPrePlayRefresh()
                #if DEBUG
                print("[WidgetRefreshManager] Widget refresh coalesced: .prePlay → .playing, lang: \(newState.currentLanguage)")
                #endif
                Task { @MainActor in
                    await performRefreshIfNotStale(for: newState)
                }
                return
            }
        }
        
        // Defer lone .prePlay / .cleared refreshes briefly so a fast .playing follow-up can supersede them.
        // (.cleared is rare for widgets because clear wipes snapshot + forces hasActive false, but
        // keep symmetric so in-process main-app driven paths behave consistently.)
        if !hasError, newState.visualState == .prePlay || newState.visualState == .cleared {
            #if DEBUG
            print("[WidgetRefreshManager] Widget refresh deferred: awaiting possible .playing follow-up — lang: \(newState.currentLanguage)")
            #endif
            scheduleCoalescedPrePlayRefresh(for: newState)
            return
        }
        
        // Coalesce duplicate immediate sticky-pause refreshes (KVO bursts, widget + app paths).
        if immediate,
           !hasError,
           newState.visualState.mustSuppressResurrection,
           let lastState = lastKnownState,
           lastState.visualState == newState.visualState,
           lastState.currentLanguage == newState.currentLanguage,
           lastState.hasError == newState.hasError {
            #if DEBUG
            print("[WidgetRefreshManager] Widget refresh coalesced: sticky \(newState.debugVisualStateLabel) unchanged")
            #endif
            return
        }
        
        // Adaptive debouncing - increase interval with frequency
        if !immediate {
            let now = Date()
            if let lastRefresh = lastRefreshTime {
                let timeSinceLastRefresh = now.timeIntervalSince(lastRefresh)
                
                if timeSinceLastRefresh < adaptiveInterval {
                    refreshCount += 1
                    adaptiveInterval = min(adaptiveInterval * 1.5, 3.0)
                    scheduleDelayedRefresh(for: newState, delay: adaptiveInterval)
                    return
                } else if timeSinceLastRefresh > 5.0 {
                    refreshCount = 0
                    adaptiveInterval = 0.5
                }
            }
        }
        
        Task { @MainActor in
            await performRefreshIfNotStale(for: newState)
        }
    }
    
    // MARK: - Private helpers
    
    /// True when a new visual SSOT should invalidate an in-flight debounced refresh.
    private func shouldCancelPendingDebounce(for newVisual: PlayerVisualState) -> Bool {
        guard pendingRefresh != nil else { return false }
        if let pendingVisual = pendingRefreshState?.visualState {
            return visualTransitionSupersedesPending(from: pendingVisual, to: newVisual)
        }
        if let lastVisual = lastKnownState?.visualState {
            return visualTransitionSupersedesPending(from: lastVisual, to: newVisual)
        }
        return true
    }
    
    private func visualTransitionSupersedesPending(
        from prior: PlayerVisualState,
        to new: PlayerVisualState
    ) -> Bool {
        if prior == new { return false }
        switch new {
        case .playing:
            return prior == .prePlay || prior == .cleared || prior == .userPaused
        case .userPaused, .thermalPaused, .securityLocked:
            return true
        case .prePlay, .cleared:
            return false
        }
    }
    
    /// Returns true if executing `requested` would regress the persisted widget snapshot.
    private func refreshWouldRegress(
        executing requested: PlayerVisualState,
        persisted: PlayerVisualState
    ) -> Bool {
        if requested == persisted { return false }
        switch persisted {
        case .playing:
            return requested == .prePlay || requested == .cleared || requested == .userPaused
        case .userPaused, .thermalPaused:
            return requested == .prePlay || requested == .cleared || requested == .playing
        case .securityLocked:
            return requested != .securityLocked
        case .prePlay, .cleared:
            return false
        }
    }
    
    private func cancelCoalescedPrePlayRefresh() {
        coalescedPrePlayWorkItem?.cancel()
        coalescedPrePlayWorkItem = nil
        coalescedPrePlayState = nil
    }
    
    private func scheduleCoalescedPrePlayRefresh(for state: WidgetState) {
        coalescedPrePlayState = state
        coalescedPrePlayWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, let pendingState = self.coalescedPrePlayState else { return }
                self.coalescedPrePlayWorkItem = nil
                self.coalescedPrePlayState = nil
                await self.performRefreshIfNotStale(for: pendingState)
            }
        }
        
        coalescedPrePlayWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.prePlayToPlayingCoalesceWindow,
            execute: workItem
        )
    }
    
    private func scheduleDelayedRefresh(for state: WidgetState, delay: TimeInterval) {
        pendingRefresh?.cancel()
        pendingRefreshState = state
        
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, let pendingState = self.pendingRefreshState else { return }
                self.pendingRefresh = nil
                self.pendingRefreshState = nil
                await self.performRefreshIfNotStale(for: pendingState)
                self.adaptiveInterval = max(self.adaptiveInterval * 0.8, 0.5)
            }
        }
        
        pendingRefresh = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
    
    private func performRefreshIfNotStale(for state: WidgetState) async {
        if let combined = SharedPlayerManager.loadPersistedWidgetState(),
           refreshWouldRegress(executing: state.visualState, persisted: combined.visualState) {
            #if DEBUG
            print("[WidgetRefreshManager] Widget refresh discarded: stale debounced \(state.debugVisualStateLabel) vs persisted \(debugLabel(for: combined.visualState))")
            #endif
            return
        }
        await performRefresh(for: state)
    }
    
    #if DEBUG
    private func debugLabel(for visualState: PlayerVisualState) -> String {
        WidgetState(
            from: visualState,
            currentLanguage: "",
            hasError: false
        ).debugVisualStateLabel
    }
    #endif
    
    private func performRefresh(for state: WidgetState) async {
        cancelPendingRefresh()
        lastRefreshTime = Date()
        lastKnownState = state
        
        do {
            let configs = try await WidgetCenter.shared.currentConfigurations()

            let hasActive = configs.contains { Self.ourWidgetKinds.contains($0.kind) }
            Self.setHasActiveLutheranWidgets(hasActive)

            if hasActive {
                WidgetCenter.shared.reloadTimelines(ofKind: "LutheranRadioWidget")
                WidgetCenter.shared.reloadTimelines(ofKind: "radio.lutheran.LutheranRadio.LutheranRadioWidget")
                
                #if DEBUG
                print("[WidgetRefreshManager] Widget refresh executed (our widgets active) — visualState: \(state.debugVisualStateLabel), lang: \(state.currentLanguage)")
                #endif
            } else {
                #if DEBUG
                print("[WidgetRefreshManager] Skipped widget refresh: No active Lutheran widgets configured (write suppression active)")
                #endif
            }
        } catch {
            #if DEBUG
            print("[WidgetRefreshManager] Widget refresh failed: \(error.localizedDescription)")
            #endif
        }
    }
}

// MARK: - WidgetState (lightweight projection of PlayerVisualState)

struct WidgetState {
    let visualState: PlayerVisualState
    let isPlaying: Bool
    let currentLanguage: String
    let hasError: Bool
    let isTransitioning: Bool
    let isThermalPaused: Bool
    let timestamp: Date
    
    /// Modern initializer — this is the only path now
    init(from visualState: PlayerVisualState,
         currentLanguage: String,
         hasError: Bool,
         isTransitioning: Bool = false) {
        self.visualState     = visualState
        self.isPlaying       = visualState.isActivelyPlaying
        self.currentLanguage = currentLanguage
        self.hasError        = hasError
        self.isTransitioning = isTransitioning
        self.isThermalPaused = (visualState == .thermalPaused)
        self.timestamp       = Date()
    }
    
    #if DEBUG
    var debugVisualStateLabel: String {
        switch visualState {
        case .prePlay: return ".prePlay"
        case .cleared: return ".cleared"
        case .playing: return ".playing"
        case .userPaused: return ".userPaused"
        case .thermalPaused: return ".thermalPaused"
        case .securityLocked: return ".securityLocked"
        }
    }
    #endif
}
