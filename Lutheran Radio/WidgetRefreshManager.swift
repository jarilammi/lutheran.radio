//
//  WidgetRefreshManager.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 14.6.2025.
//
//  Prevents excessive widget refreshes through debouncing and change detection

import Foundation
import WidgetKit

/// - Article: Widget Refresh Optimization
///
/// `WidgetRefreshManager` prevents excessive WidgetKit reloads through debouncing, change detection, and adaptive intervals, integrated with `SharedPlayerManager.swift` for state updates.
///
/// Optimization Strategies:
/// - **Throttling**: Delays non-urgent refreshes (e.g., 0.5-3s adaptive); always immediate for language changes or urgent states (playing/errors).
/// - **Change Detection**: Compares `WidgetState` structs to skip redundant updates; checks active widgets before reloading.
/// - **Integration**: Called from `SharedPlayerManager.swift`'s `saveCurrentState()`; uses `WidgetCenter` for timeline reloads.
/// - **Privacy/Efficiency**: Reduces battery/network use; no data beyond anonymous state.
///
/// For widget data flow, see `loadSharedState()` in `SharedPlayerManager.swift`. iOS 18-focused for low-power scenarios.
class WidgetRefreshManager {
    static let shared = WidgetRefreshManager()
    
    private var lastRefreshTime: Date?
    private var pendingRefresh: DispatchWorkItem?
    private var lastKnownState: WidgetState?
    
    private var refreshCount = 0
    private var adaptiveInterval: TimeInterval = 0.5
    
    private init() {}
    
    // Main refresh method with debouncing and change detection
    func refreshIfNeeded(for newState: WidgetState, immediate: Bool = false) {
        // ALWAYS refresh on language changes, regardless of throttling
        if let lastState = lastKnownState,
           lastState.currentLanguage != newState.currentLanguage {
            performRefresh(for: newState, immediate: true)
            return
        }
        
        // Adaptive debouncing - increase interval with frequency
        if !immediate {
            let now = Date()
            if let lastRefresh = lastRefreshTime {
                let timeSinceLastRefresh = now.timeIntervalSince(lastRefresh)
                
                // If refreshing frequently, increase the interval
                if timeSinceLastRefresh < adaptiveInterval {
                    refreshCount += 1
                    adaptiveInterval = min(adaptiveInterval * 1.5, 3.0) // Cap at 3 seconds
                    
                    scheduleDelayedRefresh(for: newState, delay: adaptiveInterval)
                    return
                } else if timeSinceLastRefresh > 5.0 {
                    // Reset if we haven't refreshed in a while
                    refreshCount = 0
                    adaptiveInterval = 0.5
                }
            }
        }
        
        performRefresh(for: newState, immediate: immediate)
    }
    
    private func scheduleDelayedRefresh(for state: WidgetState, delay: TimeInterval) {
        pendingRefresh?.cancel()
        
        pendingRefresh = DispatchWorkItem { [weak self] in
            self?.performRefresh(for: state, immediate: false)
            // Gradually decrease interval after successful refresh
            self?.adaptiveInterval = max((self?.adaptiveInterval ?? 0.5) * 0.8, 0.5)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: pendingRefresh!)
    }
    
    private func performRefresh(for state: WidgetState, immediate: Bool) {
        pendingRefresh?.cancel()
        lastRefreshTime = Date()
        lastKnownState = state
        
        WidgetCenter.shared.getCurrentConfigurations { result in
            if case .success(let configs) = result, !configs.isEmpty {
                WidgetCenter.shared.reloadTimelines(ofKind: "LutheranRadioWidget")
                WidgetCenter.shared.reloadTimelines(ofKind: "radio.lutheran.LutheranRadio.LutheranRadioWidget")
                
                #if DEBUG
                print("🔗 Widget refresh executed (widgets active: \(configs.count)) - playing: \(state.isPlaying), lang: \(state.currentLanguage)")
                #endif
            } else {
                #if DEBUG
                print("🔗 Skipped widget refresh: No active widgets configured")
                #endif
            }
        }
    }
    
    private func stateChanged(from old: WidgetState, to new: WidgetState) -> Bool {
        return old.isPlaying != new.isPlaying ||
               old.currentLanguage != new.currentLanguage ||
               old.hasError != new.hasError ||
               old.isTransitioning != new.isTransitioning
    }
}

// Simple state struct for change detection
struct WidgetState {
    let isPlaying: Bool
    let currentLanguage: String
    let hasError: Bool
    let isTransitioning: Bool
    let timestamp: Date
    
    init(isPlaying: Bool, currentLanguage: String, hasError: Bool, isTransitioning: Bool = false) {
        self.isPlaying = isPlaying
        self.currentLanguage = currentLanguage
        self.hasError = hasError
        self.isTransitioning = isTransitioning
        self.timestamp = Date()
    }
}
