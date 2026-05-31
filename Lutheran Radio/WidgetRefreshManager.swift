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
    private var lastKnownState: WidgetState?
    
    private var refreshCount = 0
    private var adaptiveInterval: TimeInterval = 0.5
    
    private init() {}
    
    // MARK: - Modern API (only public entry point)
    
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
        
        // ALWAYS refresh on language changes, regardless of throttling
        if let lastState = lastKnownState,
           lastState.currentLanguage != newState.currentLanguage {
            Task { @MainActor in
                await performRefresh(for: newState)
            }
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
            await performRefresh(for: newState)
        }
    }
    
    // MARK: - Private helpers
    
    private func scheduleDelayedRefresh(for state: WidgetState, delay: TimeInterval) {
        pendingRefresh?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.performRefresh(for: state)
                self.adaptiveInterval = max(self.adaptiveInterval * 0.8, 0.5)
            }
        }
        
        pendingRefresh = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
    
    private func performRefresh(for state: WidgetState) async {
        pendingRefresh?.cancel()
        lastRefreshTime = Date()
        lastKnownState = state
        
        do {
            let configs = try await WidgetCenter.shared.currentConfigurations()
            
            if !configs.isEmpty {
                WidgetCenter.shared.reloadTimelines(ofKind: "LutheranRadioWidget")
                WidgetCenter.shared.reloadTimelines(ofKind: "radio.lutheran.LutheranRadio.LutheranRadioWidget")
                
                #if DEBUG
                // Use real visual state for logging (no more fake ".paused" string)
                let vs = state.isThermalPaused ? ".thermalPaused" : (state.isPlaying ? ".playing" : ".userPaused")
                print("🔗 Widget refresh executed (widgets active: \(configs.count)) — visualState: \(vs), lang: \(state.currentLanguage)")
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
        self.isPlaying       = visualState.isActivelyPlaying
        self.currentLanguage = currentLanguage
        self.hasError        = hasError
        self.isTransitioning = isTransitioning
        self.isThermalPaused = (visualState == .thermalPaused)
        self.timestamp       = Date()
    }
}
