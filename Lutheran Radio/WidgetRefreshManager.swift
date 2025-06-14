//
//  WidgetRefreshManager.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 14.6.2025.
//
//  Prevents excessive widget refreshes through debouncing and change detection

import Foundation
import WidgetKit

class WidgetRefreshManager {
    static let shared = WidgetRefreshManager()
    
    private var lastRefreshTime: Date?
    private var pendingRefresh: DispatchWorkItem?
    private var lastKnownState: WidgetState?
    
    private init() {}
    
    // Main refresh method with debouncing and change detection
    func refreshIfNeeded(for newState: WidgetState, immediate: Bool = false) {
        // Skip if state hasn't actually changed
        if let lastState = lastKnownState, !stateChanged(from: lastState, to: newState) {
            #if DEBUG
            print("🔗 Skipping refresh - no state change")
            #endif
            return
        }
        
        // Debouncing - prevent rapid refreshes
        if !immediate, let lastRefresh = lastRefreshTime,
           Date().timeIntervalSince(lastRefresh) < 0.5 {
            scheduleDelayedRefresh(for: newState)
            return
        }
        
        performRefresh(for: newState, immediate: immediate)
    }
    
    private func scheduleDelayedRefresh(for state: WidgetState) {
        pendingRefresh?.cancel()
        
        pendingRefresh = DispatchWorkItem { [weak self] in
            self?.performRefresh(for: state, immediate: false)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: pendingRefresh!)
    }
    
    private func performRefresh(for state: WidgetState, immediate: Bool) {
        pendingRefresh?.cancel()
        lastRefreshTime = Date()
        lastKnownState = state
        
        WidgetCenter.shared.reloadTimelines(ofKind: "LutheranRadioWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "radio.lutheran.LutheranRadio.LutheranRadioWidget")
        
        #if DEBUG
        print("🔗 Widget refresh executed - playing: \(state.isPlaying), lang: \(state.currentLanguage)")
        #endif
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
