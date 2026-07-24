//
//  DirectStreamingPlayer+SSLProtection.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 24.7.2026.
//
//  Adaptive SSL handshake protection timers and cellular / region timeout heuristics.
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
import Network
@unsafe @preconcurrency import AVFoundation

// MARK: - Adaptive SSL Timeout Implementation (Swift 6 Fixes)
//
// Refactored for strict concurrency without functional changes:
// • Timers → Tasks: Sendable + cancellable (e.g., SSL protection).
// • Races in isOnCellular: Queue-isolated flag (atomic hasResumed).
// Enhances safety for multi-threaded streaming while preserving minimal footprint.
extension DirectStreamingPlayer {
    
    /// Calculates adaptive SSL timeout based on network conditions and server location
    func getSSLTimeout() async -> TimeInterval {
        // Base timeout - conservative starting point
        var timeout: TimeInterval = 12.0
        
        // Add extra time for cellular connections
        let isCellular = await isOnCellular()
        if isCellular {
            timeout += 4.0
            #if DEBUG
            print("[DirectStreamingPlayer] [SSL Timeout] Added 4s for cellular connection")
            #endif
        }
        
        // Add extra time for expensive (metered) networks, e.g., cellular or paid hotspots.
        // This uses the exposed currentPath from networkMonitor.
        if let path = networkMonitor?.currentPath, path.isExpensive {
            timeout += 2.0
            #if DEBUG
            print("[DirectStreamingPlayer] [SSL Timeout] Added 2s for expensive/metered network")
            #endif
        }
        
        // Add extra time for cross-continental connections
        if currentSelectedServer.name == "EU" && !isInEurope() {
            timeout += 1.5
            #if DEBUG
            print("[DirectStreamingPlayer] [SSL Timeout] Added 1.5s for EU server from non-Europe location")
            #endif
        } else if currentSelectedServer.name == "US" && !isInNorthAmerica() {
            timeout += 1.5
            #if DEBUG
            print("[DirectStreamingPlayer] [SSL Timeout] Added 1.5s for US server from non-North America location")
            #endif
        }
        
        // Add extra time if we have recent server failures (indicates network issues)
        if hasRecentServerFailures() {
            timeout += 1.0
            #if DEBUG
            print("[DirectStreamingPlayer] [SSL Timeout] Added 1s for recent server failures")
            #endif
        }
        
        // Cap at reasonable maximum
        let finalTimeout = min(timeout, 20.0)
        
        #if DEBUG
        print("[DirectStreamingPlayer] [SSL Timeout] Calculated timeout: \(finalTimeout)s (base: 8.0s)")
        #endif
        
        return finalTimeout
    }
    
    /// Short-lived coordinator for async cellular detection via NWPathMonitor.
    /// - Note: Addresses Swift 6 races in original local-var approach:
    ///   - Uses `DispatchQueue.sync` for atomic `hasResumed` (prevents double-resume).
    ///   - Captures Sendables only in handler; weak `self` avoids cycles.
    ///   - Deallocs post-resume (lifetime ~0.1-0.2s).
    /// Invariant: Exactly one path (timeout or update) resumes the continuation.
    final class CellularCheckCoordinator: @unchecked Sendable {
        let syncQueue = DispatchQueue(label: "cellular.hasResumed")
        var hasResumed = false
        private weak var monitor: NWPathMonitor?

        func setupCheck(timeoutDuration: Double, continuation: CheckedContinuation<Bool, Never>) {
            let monitor = NWPathMonitor()
            self.monitor = monitor  // Weak to avoid retain cycles

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutDuration * 1_000_000_000))
                await self.performFallback(continuation: continuation)
            }

            monitor.pathUpdateHandler = { [weak self, timeoutTask, continuation] path in  // Capture locals (Sendable); weak self for cycle
                Task {  // No @Sendable needed—Task infers it, but locals are safe
                    await self?.handlePathUpdate(path: path, timeoutTask: timeoutTask, continuation: continuation)
                }
            }

            let queue = DispatchQueue(label: "cellularCheck", qos: .userInitiated)
            monitor.start(queue: queue)
        }

        func performFallback(continuation: CheckedContinuation<Bool, Never>) async {
            syncQueue.sync {  // Replace: Scoped sync—no manual lock/unlock
                guard !hasResumed else { return }
                hasResumed = true
                monitor?.cancel()
                continuation.resume(returning: false)  // Fallback: non-cellular
            }
        }

        func handlePathUpdate(path: NWPath, timeoutTask: Task<Void, Never>, continuation: CheckedContinuation<Bool, Never>) async {
            syncQueue.sync {
                guard !hasResumed else { return }
                hasResumed = true
                monitor?.cancel()
                timeoutTask.cancel()
                continuation.resume(returning: path.usesInterfaceType(.cellular))
            }
        }
    }
    
    /// Detects cellular interface asynchronously with quick timeout.
    /// - Returns: `true` if cellular (via path update), `false` otherwise (fallback).
    /// - Note: Inline low-power check avoids `self` capture in concurrent Task.
    ///   Timeout: 0.1s (normal) / 0.2s (low power) to prevent hangs.
    func isOnCellular() async -> Bool {
        await withCheckedContinuation { continuation in
            // INLINE: Direct ProcessInfo call—no self capture
            let timeoutDuration = ProcessInfo.processInfo.isLowPowerModeEnabled ? 0.2 : 0.1
            let coordinator = CellularCheckCoordinator()
            Task.detached {
                coordinator.setupCheck(timeoutDuration: timeoutDuration, continuation: continuation)
            }
        }
    }
    
    /// Detects if the device is likely in Europe based on timezone
    func isInEurope() -> Bool {
        let timezone = TimeZone.current
        let europeanTimezones = [
            "Europe/", "GMT", "UTC", "WET", "CET", "EET",
            "Atlantic/Reykjavik", "Atlantic/Faroe"
        ]
        
        return europeanTimezones.contains { timezone.identifier.hasPrefix($0) }
    }
    
    /// Detects if the device is likely in North America based on timezone
    func isInNorthAmerica() -> Bool {
        let timezone = TimeZone.current
        let northAmericanTimezones = [
            "America/", "US/", "Canada/", "EST", "CST", "MST", "PST"
        ]
        
        return northAmericanTimezones.contains { timezone.identifier.hasPrefix($0) }
    }
    
    /// Checks if we've had recent server failures indicating network issues
    func hasRecentServerFailures() -> Bool {
        let totalFailures = serverFailureCount.values.reduce(0, +)
        return totalFailures > 0
    }
}

// MARK: - Enhanced SSL Protection Timer Methods
extension DirectStreamingPlayer {
    
    /// Sets up per-connection SSL protection via a detached Task.
    /// - Parameters:
    ///   - id: Pre-generated UUID for the connection (ensures sync compatibility in detached Tasks).
    ///   - connectionStartTime: Timestamp when the connection began.
    /// - Note: Replaces legacy `Timer` with `Task.detached` + `Task.sleep(for:)` for:
    ///   - Swift 6 concurrency safety (Sendable, no implicit captures).
    ///   - Improved cancellation (`.cancel()` propagates to sleep).
    ///   Behavior: After adaptive timeout, marks handshake "complete" and logs if still unknown.
    func setupSSLProtectionTimer(id: UUID, for connectionStartTime: Date) async {
        let adaptiveTimeout = await getSSLTimeout()
        
        #if DEBUG
        print("[DirectStreamingPlayer] [SSL Protection] Starting \(adaptiveTimeout)s adaptive protection task for connection \(id)")
        #endif
        
        // Replace Timer with detached Task (Sendable, cancellable)
        let task = Task.detached { [weak self, id, connectionStartTime] in  // weak self for safety
            guard let self = self else { return }
            
            // Sleep asynchronously (equivalent to Timer fire)
            try? await Task.sleep(for: .seconds(adaptiveTimeout))
            
            let connectionAge = Date().timeIntervalSince(connectionStartTime)
            
            #if DEBUG
            print("[DirectStreamingPlayer] [SSL Protection] Adaptive task completed after \(connectionAge)s for connection \(id)")
            #endif
            
            // Mark SSL handshake as complete after timeout for this specific connection
            self.connectionQueue.async { [id] in
                if var connectionInfo = self.activeConnections[id] {
                    connectionInfo.isHandshakeComplete = true
                    self.activeConnections[id] = connectionInfo
                }
            }
            
            // If still not ready after adaptive timeout, allow normal error handling
            if self.playerItem?.status == .unknown {
                #if DEBUG
                print("[DirectStreamingPlayer] [SSL Protection] Still connecting after \(connectionAge)s - allowing normal error handling")
                #endif
            }
        }
        
        // Store connection info via queue (now captures Task, which is Sendable)
        self.connectionQueue.async { [id, connectionStartTime, task] in
            let connectionInfo = ConnectionInfo(
                id: id,
                startTime: connectionStartTime,
                task: task,  // Store Task instead of Timer
                isHandshakeComplete: false
            )
            self.activeConnections[id] = connectionInfo
        }
    }
    
    /// Marks SSL handshake as complete for a specific connection
    func markSSLHandshakeComplete(for connectionId: UUID) {
        connectionQueue.async {
            if var connectionInfo = self.activeConnections[connectionId] {
                connectionInfo.isHandshakeComplete = true
                self.activeConnections[connectionId] = connectionInfo
                
                #if DEBUG
                print("[DirectStreamingPlayer] [SSL Protection] Marked handshake complete for connection \(connectionId)")
                #endif
            }
        }
    }
    
    /// Checks if SSL handshake is complete for a specific connection
    func isSSLHandshakeComplete(for connectionId: UUID) -> Bool {
        var isComplete = false
        connectionQueue.sync {
            isComplete = activeConnections[connectionId]?.isHandshakeComplete ?? true
        }
        return isComplete
    }
    
    /// Clears protection for a specific connection by cancelling its Task and removing from tracking.
    /// - Note: Calls `clearAllSSLProtectionTimers()` for thorough cleanup (replaces legacy single-timer invalidate).
    ///   Safe for concurrent calls via `connectionQueue`.
    func clearSSLProtectionTimer(for connectionId: UUID) {
        connectionQueue.async {
            if let connectionInfo = self.activeConnections.removeValue(forKey: connectionId) {
                connectionInfo.task.cancel()
                
                #if DEBUG
                print("[DirectStreamingPlayer] [SSL Protection] Cleared timer for connection \(connectionId)")
                #endif
            }
        }
        
        // Clear all SSL protection timers if they exist
        clearAllSSLProtectionTimers()
    }
    
    /// Clears all active connections by cancelling Tasks and emptying the dict.
    /// - Note: Thread-safe via `connectionQueue`; use in `stop()` or `deinit` for full reset.
    func clearAllSSLProtectionTimers() {
        connectionQueue.async {
            for (connectionId, connectionInfo) in self.activeConnections {
                connectionInfo.task.cancel()
                
                #if DEBUG
                print("[DirectStreamingPlayer] [SSL Protection] Cleared timer for connection \(connectionId)")
                #endif
            }
            self.activeConnections.removeAll()
            
            #if DEBUG
            print("[DirectStreamingPlayer] [SSL Protection] Cleared all SSL protection timers")
            #endif
        }
    }

}
