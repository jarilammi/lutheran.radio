//
//  WidgetRefreshManager.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 14.6.2025.
//
//  Prevents excessive widget refreshes through debouncing and change detection.
//  Now fully aligned with PlayerVisualState as the Single Source of Truth (SSOT).
//

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
    
    private var refreshCount = 0
    private var adaptiveInterval: TimeInterval = 0.5
    
    private init() {}
    
    // MARK: - Modern API (only public entry point)
    
    /// Drops any scheduled debounced refresh (e.g. before a visual SSOT transition).
    func cancelPendingRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        pendingRefreshState = nil
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
            Task { @MainActor in
                await performRefreshIfNotStale(for: newState)
            }
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
            print("🔇 Widget refresh coalesced: sticky \(newState.debugVisualStateLabel) unchanged")
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
            return prior == .prePlay || prior == .userPaused
        case .userPaused, .thermalPaused, .securityLocked:
            return true
        case .prePlay:
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
            return requested == .prePlay || requested == .userPaused
        case .userPaused, .thermalPaused:
            return requested == .prePlay || requested == .playing
        case .securityLocked:
            return requested != .securityLocked
        case .prePlay:
            return false
        }
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
            print("🔇 Widget refresh discarded: stale debounced \(state.debugVisualStateLabel) vs persisted \(debugLabel(for: combined.visualState))")
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
            
            if !configs.isEmpty {
                WidgetCenter.shared.reloadTimelines(ofKind: "LutheranRadioWidget")
                WidgetCenter.shared.reloadTimelines(ofKind: "radio.lutheran.LutheranRadio.LutheranRadioWidget")
                
                #if DEBUG
                print("🔗 Widget refresh executed (widgets active: \(configs.count)) — visualState: \(state.debugVisualStateLabel), lang: \(state.currentLanguage)")
                #endif
            } else {
                #if DEBUG
                print("🔗 Skipped widget refresh: No active widgets configured")
                #endif
            }
        } catch {
            #if DEBUG
            print("🔗 Widget refresh failed: \(error.localizedDescription)")
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
        case .playing: return ".playing"
        case .userPaused: return ".userPaused"
        case .thermalPaused: return ".thermalPaused"
        case .securityLocked: return ".securityLocked"
        }
    }
    #endif
}
