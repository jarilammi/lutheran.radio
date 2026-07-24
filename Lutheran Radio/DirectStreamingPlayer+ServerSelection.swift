//
//  DirectStreamingPlayer+ServerSelection.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 24.7.2026.
//
//  Stream server value types (Server, PingResult), cluster list, latency pings, and optimal-server URL selection.
//
//  Behavior-preserving domain split from DirectStreamingPlayer.swift.
//  DirectStreamingPlayer remains the public façade; this file owns one domain.
//
//  AGENT NOTE: Members used across files are `internal` (Swift `private` is
//  file-scoped). Prefer this domain file over re-implementing attach / recovery
//  / catalog logic in call sites.
//
//  - SeeAlso: DirectStreamingPlayer.swift, SecurityConfiguration.makeSecureEphemeralConfiguration(), DirectStreamingPlayer+StreamCatalog.swift,
//    CODING_AGENT.md (Single Source of Truth Principles).
//

import Foundation
import Network
import Core

extension DirectStreamingPlayer {
    /// A radio stream server endpoint (EU or US cluster).
    struct Server {
        let name: String
        let pingURL: URL
        let baseHostname: String
        let subdomain: String
    }
    
    /// Static list of known streaming clusters.
    /// The first entry is the default/fallback.
    static let servers: [Server] = [
        Server(
            name: "EU",
            pingURL: makeURL("https://european.lutheran.radio/ping"),
            baseHostname: "lutheran.radio",
            subdomain: "eu"
        ),
        Server(
            name: "US",
            pingURL: makeURL("https://livestream.lutheran.radio/ping"),
            baseHostname: "lutheran.radio",
            subdomain: "us"
        )
    ]

    internal static func makeURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            fatalError("Invalid hardcoded URL: \(string)")
        }
        return url
    }
    
    /// Result of a latency ping against one server.
    struct PingResult {
        let server: Server
        let latency: TimeInterval
    }

    // MARK: - Network & Server Selection
    /// When true, real audio session configuration, eager security validation, and
    /// all playback engine entry points are no-ops. This keeps XCUITest and unit test
    /// launches completely silent (no background audio, no DNS TXT, no certificate work,
    /// no network I/O).
    ///
    /// Delegates live to the single source of truth `SharedPlayerManager.isRunningInUITestMode`.
    /// That property prefers the explicit "-UITestMode" launch argument (set by
    /// Lutheran_RadioUITests) and only falls back to XCTest environment indicators under
    /// DEBUG builds.
    ///
    /// Defense-in-depth: even if a recovery or network path inside DirectStreamingPlayer
    /// were to call `play()` under test, the early returns here ensure no real work occurs.
    ///
    /// - Important: Do not duplicate detection logic. `isTesting` always reflects the SSOT.
    ///   If a new playback entry point is added, guard it with `if isTesting { return … }`.
    ///
    /// - SeeAlso: ``SharedPlayerManager/isRunningInUITestMode``, ViewController.viewDidLoad,
    ///   ``setupAudioSession()``, `play()`, `setStreamAndPlay(to:context:)`, `startPlayback(context:)`,
    ///   CODING_AGENT.md (test isolation requirements).
    internal var isTesting: Bool {
        SharedPlayerManager.isRunningInUITestMode
    }

    // AGENT NOTE (UI Test Isolation):
    // All new playback-related entry points added to DirectStreamingPlayer (including
    // recovery, soft-pause resume, network reconnect auto-play, or any new public
    // "start" method) must be guarded by `if isTesting { return … }` (or equivalent)
    // so that `xcodebuild test` and XCUITest launches with "-UITestMode" never produce
    // background audio or perform DNS / cert / stream work.
    // The authoritative check is `SharedPlayerManager.isRunningInUITestMode`.
    // Keep this note in sync with any new auto-play surfaces.
    //
    // Stored server-selection / deallocation flags live on the façade class body
    // (extensions cannot declare stored properties).

    /// Selects the optimal streaming server based on latency and failures.
    /// - Parameter completion: Handler with selected server.
    /// - Note: Throttles calls; prefers servers with fewer failures; delays in low-power mode.
    /// - Example: `selectOptimalServer { server in print(server.name) }`
    /// - SeeAlso: `fetchServerIPsAndLatencies(completion:)`
    func selectOptimalServer(completion: @escaping @Sendable (Server) -> Void) {
        // If we have a server that failed recently, try the other one first
        if let lastFailed = lastFailedServerName,
           let failureCount = serverFailureCount[lastFailed],
           failureCount > 0 {
            
            let workingServers = Self.servers.filter { server in
                let failCount = serverFailureCount[server.name, default: 0]
                return failCount == 0 || failCount < failureCount
            }
            
            if let betterServer = workingServers.first {
                #if DEBUG
                print("Avoiding recently failed server \(lastFailed), using \(betterServer.name)")
                #endif
                currentSelectedServer = betterServer
                
                // Fire-and-forget save (no need to block selection)
                Task {
                    await SharedPlayerManager.shared.saveCurrentState()
                }
                
                lastServerSelectionTime = Date()
                completion(betterServer)
                return
            }
        }
        
        if let last = lastServerSelectionTime,
           Date().timeIntervalSince(last) <= 10.0 {
            #if DEBUG
            print("[DirectStreamingPlayer] selectOptimalServer: Throttling server selection, using cached server: \(currentSelectedServer.name)")
            #endif
            completion(currentSelectedServer)
            return
        }
        
        serverSelectionWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                completion(Self.servers[0])
                return
            }
            
            self.fetchServerIPsAndLatencies { results in
                let validResults = results.filter { $0.latency != .infinity }
                
                if let bestResult = validResults.min(by: { $0.latency < $1.latency }) {
                    self.currentSelectedServer = bestResult.server
                    
                    // Fire-and-forget save
                    Task {
                        await SharedPlayerManager.shared.saveCurrentState()
                    }
                    
                    self.lastServerSelectionTime = Date()
                    
                    #if DEBUG
                    print("[DirectStreamingPlayer] [Server Selection] Selected \(bestResult.server.name) with latency \(bestResult.latency)s")
                    #endif
                } else {
                    self.currentSelectedServer = Self.servers[0]
                    
                    // Fire-and-forget save
                    Task {
                        await SharedPlayerManager.shared.saveCurrentState()
                    }
                    
                    self.lastServerSelectionTime = Date()
                    
                    #if DEBUG
                    print("[DirectStreamingPlayer] [Server Selection] No valid ping results, falling back to \(self.currentSelectedServer.name)")
                    #endif
                }
                
                completion(self.currentSelectedServer)
            }
        }
        
        serverSelectionWorkItem = workItem
        let selectionDelay: TimeInterval = isLowEfficiencyMode ? 1.0 : 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + selectionDelay, execute: workItem)
    }
    
    /// Ensures the optimal server — the one with the lowest measured latency — has been
    /// confidently selected before any playback path constructs a `selectedStream.url`.
    ///
    /// Fast-path: if the 10 s throttle window is active we return immediately with zero
    /// allocation and no suspension (fixes the "continuation always suspends" review item).
    ///
    /// This is the internal implementation detail behind `urlWithOptimalServer(for:)`.
    func ensureOptimalServerSelected() async {
        if let last = lastServerSelectionTime,
           Date().timeIntervalSince(last) <= 10.0 {
            #if DEBUG
            print("[DirectStreamingPlayer] ensureOptimalServerSelected: throttled (≤10s), using cached \(currentSelectedServer.name)")
            #endif
            return
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            selectOptimalServer { _ in cont.resume() }
        }
    }

    /// Returns a playback URL for `stream` whose host is guaranteed to be the current
    /// optimal server (lowest latency, or the best non-failed server if one has recently failed).
    ///
    /// This is the **single source of truth** for all URL construction that feeds AVURLAsset
    /// or AVPlayerItem on cold launch, stream switch, or direct start paths.
    ///
    /// Internally calls `ensureOptimalServerSelected()` (now cheap after first use) then
    /// reads the computed `stream.url` (which consults `currentSelectedServer` at read time).
    ///
    /// Adding new playback entry points? Route their first `.url` access through this helper
    /// and the original race becomes structurally impossible.
    func urlWithOptimalServer(for stream: Stream) async -> URL {
        await ensureOptimalServerSelected()

        #if DEBUG
        // Catches regressions of the "forgot to update lastServerSelectionTime on a completion path"
        // or any mutation that clears the stamp without going through selectOptimalServer.
        if let t = lastServerSelectionTime {
            let age = Date().timeIntervalSince(t)
            assert(age < 60.0, "urlWithOptimalServer: ensure returned but selection stamp is \(age)s old")
        } else {
            assertionFailure("urlWithOptimalServer: ensure returned without a lastServerSelectionTime stamp")
        }
        #endif

        return stream.url
    }

    // MARK: - Latency Measurement
    //
    // Implementation co-located with selectOptimalServer (its only public caller)
    // and the rest of the server-selection / failover logic. Types (Server, PingResult)
    // live in the Nested Configuration Types section earlier in the class.

    func fetchServerIPsAndLatencies(completion: @escaping @Sendable ([PingResult]) -> Void) {
        Task { @MainActor in
            let results = await self.fetchAllServerLatencies()
            
            #if DEBUG
            print("[DirectStreamingPlayer] [Ping] All pings completed: \(results.map { "\($0.server.name): \($0.latency)s" })")
            #endif
            completion(results)
        }
    }
    
    func fetchAllServerLatencies() async -> [PingResult] {
        await withTaskGroup(of: PingResult.self) { group in
            for server in Self.servers {
                group.addTask {
                    await self.ping(server: server)
                }
            }
            
            var results: [PingResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }
    
    func ping(server: Server) async -> PingResult {
        let startTime = Date()
        
        // Use the centralized secure configuration from Core so that DNSSEC validation
        // is uniformly required for server-selection pings (same policy as streaming data).
        let config = SecurityConfiguration.makeSecureEphemeralConfiguration()
        config.timeoutIntervalForRequest = 2.0
        let session = URLSession(configuration: config)
        
        do {
            let (_, response) = try await session.data(from: server.pingURL)
            let latency = Date().timeIntervalSince(startTime)
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                #if DEBUG
                print("[DirectStreamingPlayer] [Ping] Success for \(server.name), latency=\(latency)s")
                #endif
                return PingResult(server: server, latency: latency)
            } else {
                #if DEBUG
                print("[DirectStreamingPlayer] [Ping] Failed for \(server.name): bad status")
                #endif
                return PingResult(server: server, latency: .infinity)
            }
        } catch {
            #if DEBUG
            print("[DirectStreamingPlayer] [Ping] Failed for \(server.name): \(error.localizedDescription)")
            #endif
            return PingResult(server: server, latency: .infinity)
        }
    }
}
