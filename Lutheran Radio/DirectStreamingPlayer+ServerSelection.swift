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
//  Security Invariant: Cluster ping hosts and `baseHostname` come from
//  ``SecurityConfiguration/preferredStreamingDomainSuffix`` (today `siikkari.net`).
//  Do not hard-code apex strings here — keep EU = european.<apex>, US = livestream.<apex>.
//  Skipping a warm same-stream ping does **not** skip stream TLS / Core pin / DNS TXT —
//  only the EU/US RTT probe before ``urlWithOptimalServer(for:)`` builds the host.
//
//  Same-stream hard-resume (user pause already tore Icecast down) may reuse
//  ``currentSelectedServer`` while ``lastServerSelectionTime`` is inside
//  ``sameStreamWarmServerReuseInterval``. Stream switch, cold launch, and recovery
//  ``play()`` do not. Network-path reconnect nils the stamp. Never set
//  ``isSoftPaused`` on user pause to avoid this probe.
//
//  - SeeAlso: DirectStreamingPlayer.swift, ``shouldReuseCachedServerSelection(lastSelectionAge:allowSameStreamWarmReuse:)``,
//    SecurityConfiguration.makeSecureEphemeralConfiguration(),
//    SecurityConfiguration.streamingHostCandidates(leadingLabel:), DirectStreamingPlayer+StreamCatalog.swift,
//    PlaybackAttachContext.resume, CODING_AGENT.md (Single Source of Truth Principles).
//

import Foundation
import Network
import Core

extension DirectStreamingPlayer {
    /// A radio stream server endpoint (EU or US cluster).
    ///
    /// - Important: `baseHostname` is the preferred streaming apex from Core policy
    ///   (``SecurityConfiguration/preferredStreamingDomainSuffix``), not a hard-coded
    ///   legacy domain. Stream language hosts are built as
    ///   `<languageSlug>-<subdomain>.<baseHostname>` in ``StreamCatalog``.
    /// - SeeAlso: ``StreamCatalog/streamURL(languageCode:region:securityModel:)``,
    ///   ``SecurityConfiguration/preferredStreamingDomainSuffixes``
    struct Server {
        let name: String
        let pingURL: URL
        let baseHostname: String
        let subdomain: String
    }
    
    /// Static list of known streaming clusters under the preferred streaming apex.
    ///
    /// The first entry is the default/fallback. Hosts are derived from
    /// ``SecurityConfiguration/preferredStreamingDomainSuffix`` so media preference
    /// stays a single source of truth in Core (today: `european.siikkari.net` and
    /// `livestream.siikkari.net`).
    ///
    /// - SeeAlso: ``SecurityConfiguration/streamingHostCandidates(leadingLabel:)``,
    ///   ``SecurityConfiguration/preferredStreamingDomainSuffixes``,
    ///   ``<doc:Security-Invariants>``
    static let servers: [Server] = {
        let apex = SecurityConfiguration.current.preferredStreamingDomainSuffix
        // Prefer the first candidate for each leading label (preferred apex).
        let euHost = SecurityConfiguration.current.streamingHostCandidates(leadingLabel: "european").first
            ?? "european.\(apex)"
        let usHost = SecurityConfiguration.current.streamingHostCandidates(leadingLabel: "livestream").first
            ?? "livestream.\(apex)"
        return [
            Server(
                name: "EU",
                pingURL: makeURL("https://\(euHost)/ping"),
                baseHostname: apex,
                subdomain: "eu"
            ),
            Server(
                name: "US",
                pingURL: makeURL("https://\(usHost)/ping"),
                baseHostname: apex,
                subdomain: "us"
            )
        ]
    }()

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

    /// Repeat probes within this window reuse ``currentSelectedServer`` for every attach context
    /// (cold launch, stream switch, resume, recovery).
    ///
    /// - SeeAlso: ``sameStreamWarmServerReuseInterval``, ``shouldReuseCachedServerSelection(lastSelectionAge:allowSameStreamWarmReuse:)``
    static let serverSelectionThrottleInterval: TimeInterval = 10.0

    /// Same-stream hard-resume (``PlaybackAttachContext/resume``) may reuse the last measured
    /// cluster without a new EU/US ping pair while the last success is this young.
    ///
    /// Longer than ``serverSelectionThrottleInterval`` so pause-then-play does not wait on RTT
    /// after the 10 s throttle expires. Shorter than a routing epoch; ``lastServerSelectionTime``
    /// is still niled on network-path reconnect. Cold launch, stream switch, and recovery
    /// ``play()`` do not use this window. User pause still hard-tears Icecast
    /// (``isSoftPaused`` stays false).
    ///
    /// - SeeAlso: ``shouldReuseCachedServerSelection(lastSelectionAge:allowSameStreamWarmReuse:)``,
    ///   ``urlWithOptimalServer(for:allowSameStreamWarmReuse:)``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md (user pause / play-after-pause attach)
    static let sameStreamWarmServerReuseInterval: TimeInterval = 600.0

    /// Whether ``ensureOptimalServerSelected(allowSameStreamWarmReuse:)`` may skip the EU/US ping
    /// pair and keep ``currentSelectedServer``.
    ///
    /// - Parameters:
    ///   - lastSelectionAge: Seconds since ``lastServerSelectionTime``, or `nil` if never selected
    ///     (or niled on reconnect). Negative ages do not reuse.
    ///   - allowSameStreamWarmReuse: `true` only for same-stream hard-resume
    ///     (``PlaybackAttachContext/resume``). `false` for cold launch, stream switch, and
    ///     recovery ``play()``.
    /// - Returns: `true` when a new ping pair must not run.
    /// - Important: Missing stamp never reuses. The 10 s throttle applies to every context.
    ///   The longer warm window applies only when `allowSameStreamWarmReuse` is true.
    ///   Does not skip Core certificate pinning or DNS TXT validation on the stream URL.
    /// - SeeAlso: ``serverSelectionThrottleInterval``, ``sameStreamWarmServerReuseInterval``,
    ///   ``urlWithOptimalServer(for:allowSameStreamWarmReuse:)``
    static func shouldReuseCachedServerSelection(
        lastSelectionAge: TimeInterval?,
        allowSameStreamWarmReuse: Bool
    ) -> Bool {
        guard let age = lastSelectionAge, age >= 0 else { return false }
        if age <= serverSelectionThrottleInterval { return true }
        if allowSameStreamWarmReuse, age <= sameStreamWarmServerReuseInterval { return true }
        return false
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
    ///   ``setupAudioSession()``, `play()`, ``attachAndPlay(to:context:)``, `startPlayback(context:)`,
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

    /// Selects the optimal streaming server by measured latency (lowest RTT wins).
    ///
    /// - Parameter completion: Handler with selected server.
    /// - Note: Throttles repeat calls within ``serverSelectionThrottleInterval`` (reuses
    ///   ``currentSelectedServer``); delays the latency probe in Low Power Mode. Selection is
    ///   latency-only — there is no failure-count map driving prefer/avoid logic. Same-stream
    ///   warm reuse is decided in ``ensureOptimalServerSelected(allowSameStreamWarmReuse:)``
    ///   before this method runs; once this method is entered past the 10 s throttle it pings.
    /// - Example: `selectOptimalServer { server in print(server.name) }`
    /// - SeeAlso: `fetchServerIPsAndLatencies(completion:)`, ``urlWithOptimalServer(for:allowSameStreamWarmReuse:)``,
    ///   ``shouldReuseCachedServerSelection(lastSelectionAge:allowSameStreamWarmReuse:)``
    func selectOptimalServer(completion: @escaping @Sendable (Server) -> Void) {
        if let last = lastServerSelectionTime,
           Date().timeIntervalSince(last) <= Self.serverSelectionThrottleInterval {
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
    /// Fast-path: ``shouldReuseCachedServerSelection(lastSelectionAge:allowSameStreamWarmReuse:)``
    /// returns immediately with zero allocation and no suspension (10 s throttle for every
    /// context; longer warm window only when `allowSameStreamWarmReuse` is true).
    ///
    /// This is the internal implementation detail behind
    /// ``urlWithOptimalServer(for:allowSameStreamWarmReuse:)``.
    ///
    /// - Parameter allowSameStreamWarmReuse: Pass `true` only from ``PlaybackAttachContext/resume``
    ///   attach (same-stream hard-resume after user pause). Default `false` keeps the 10 s
    ///   throttle only — required for stream switch, cold launch, and recovery ``play()``.
    /// - SeeAlso: ``shouldReuseCachedServerSelection(lastSelectionAge:allowSameStreamWarmReuse:)``
    func ensureOptimalServerSelected(allowSameStreamWarmReuse: Bool = false) async {
        let age = lastServerSelectionTime.map { Date().timeIntervalSince($0) }
        if Self.shouldReuseCachedServerSelection(
            lastSelectionAge: age,
            allowSameStreamWarmReuse: allowSameStreamWarmReuse
        ) {
            #if DEBUG
            if let age {
                if age <= Self.serverSelectionThrottleInterval {
                    print("[DirectStreamingPlayer] ensureOptimalServerSelected: throttled (≤\(Int(Self.serverSelectionThrottleInterval))s), using cached \(currentSelectedServer.name)")
                } else {
                    // FloatingPointFormatStyle — not `String(format:)` — so DEBUG stays free of
                    // C-varargs `unsafe` under SWIFT_STRICT_MEMORY_SAFETY.
                    let ageText = age.formatted(
                        .number
                            .precision(.fractionLength(1))
                            .locale(Locale(identifier: "en_US_POSIX"))
                    )
                    print("[DirectStreamingPlayer] ensureOptimalServerSelected: same-stream warm reuse (age=\(ageText)s ≤ \(Int(Self.sameStreamWarmServerReuseInterval))s), using cached \(currentSelectedServer.name)")
                }
            }
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
    /// or AVPlayerItem on cold launch, stream switch, same-stream resume, or direct start paths.
    ///
    /// Internally calls ``ensureOptimalServerSelected(allowSameStreamWarmReuse:)`` then
    /// reads the computed `stream.url` (which consults `currentSelectedServer` at read time).
    ///
    /// Adding new playback entry points? Route their first `.url` access through this helper
    /// and the original race becomes structurally impossible.
    ///
    /// - Parameters:
    ///   - stream: Catalog stream whose host is rewritten from ``currentSelectedServer``.
    ///   - allowSameStreamWarmReuse: `true` only for ``PlaybackAttachContext/resume``. `false`
    ///     (default) for cold launch, stream switch, and recovery ``play()`` — those still ping
    ///     when the 10 s throttle has expired. Does not skip Core pins on the stream URL.
    /// - Returns: HTTPS stream URL on the currently selected cluster.
    /// - SeeAlso: ``shouldReuseCachedServerSelection(lastSelectionAge:allowSameStreamWarmReuse:)``,
    ///   ``PlaybackAttachContext``, DirectStreamingPlayer+PlaybackAttach.swift
    func urlWithOptimalServer(for stream: Stream, allowSameStreamWarmReuse: Bool = false) async -> URL {
        await ensureOptimalServerSelected(allowSameStreamWarmReuse: allowSameStreamWarmReuse)

        #if DEBUG
        // Catches regressions of the "forgot to update lastServerSelectionTime on a completion path"
        // or any mutation that clears the stamp without going through selectOptimalServer.
        if let t = lastServerSelectionTime {
            let age = Date().timeIntervalSince(t)
            assert(
                Self.shouldReuseCachedServerSelection(
                    lastSelectionAge: age,
                    allowSameStreamWarmReuse: allowSameStreamWarmReuse
                ),
                "urlWithOptimalServer: ensure returned but selection stamp is \(age)s old (same-stream warm reuse=\(allowSameStreamWarmReuse))"
            )
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
