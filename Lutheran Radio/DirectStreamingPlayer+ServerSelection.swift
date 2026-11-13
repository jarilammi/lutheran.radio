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
//  only the EU/US RTT probe. First attach is not blocked on that probe: default/last-good
//  (EU / ``servers[0]``) is used immediately while pings run in the background.
//
//  Same-stream hard-resume (user pause already tore Icecast down) may reuse
//  ``currentSelectedServer`` while ``lastServerSelectionTime`` is inside
//  ``sameStreamWarmServerReuseInterval``. Stream switch, cold launch, and recovery
//  ``play()`` do not. Network-path reconnect nils the stamp. Never set
//  ``isSoftPaused`` on user pause to avoid this probe.
//
//  A stream HTTP 403 whose query already carries ``expectedSecurityModel`` excludes
//  that production cluster (`eu` / `us`) for the rest of this process
//  (``noteEmbeddedSecurityModelRejection(url:statusCode:)``). The other cluster may
//  be opened once. When none remain, attach stops and playback locks. The set is not
//  a ping failure and is not cleared when the path returns. Do not send a previous
//  model name.
//
//  - SeeAlso: DirectStreamingPlayer.swift, ``shouldReuseCachedServerSelection(lastSelectionAge:allowSameStreamWarmReuse:)``,
//    SecurityConfiguration.makeSecureEphemeralConfiguration(),
//    SecurityConfiguration.streamingHostCandidates(leadingLabel:), DirectStreamingPlayer+StreamCatalog.swift,
//    PlaybackAttachContext.resume, CODING_AGENT.md (Single Source of Truth Principles).
//

import Foundation
import Network
import Synchronization
import Core

/// Process-local record of production clusters that refused the embedded security model.
///
/// `rejectedSubdomains` holds `eu` / `us` after HTTP 403 on a stream URL that already
/// carried ``SecurityConfiguration/expectedSecurityModel``. `failoverInFlight` stays
/// true after the one move onto a cluster that has not refused yet, so a second 403
/// on the refused cluster does not open another stream. Cleared when no cluster
/// remains, and by the test reset. Not persisted.
///
/// - SeeAlso: ``DirectStreamingPlayer/noteEmbeddedSecurityModelRejection(url:statusCode:)``,
///   ``DirectStreamingPlayer/embeddedSecurityModelClusterRejections``
struct EmbeddedSecurityModelClusterRejectionState: Sendable {
    var rejectedSubdomains: Set<String> = []
    var failoverInFlight: Bool = false
}

/// What one stream HTTP 403 means for the rest of this process.
///
/// - SeeAlso: ``DirectStreamingPlayer/noteEmbeddedSecurityModelRejection(url:statusCode:)``
enum EmbeddedSecurityModelRejectionDisposition: Equatable, Sendable {
    /// Not a refusal of the embedded model (wrong status, ping host, or a query that
    /// does not carry ``SecurityConfiguration/expectedSecurityModel``).
    case notThisFailure
    /// One attach onto this still-eligible production subdomain. The refused cluster
    /// is not opened again.
    case failoverOnce(String)
    /// A failover attach is already scheduled. Do not open the refused cluster again.
    case waitForInFlightFailover
    /// Every production cluster has refused the embedded model. Do not open a stream URL.
    case terminalLock
}

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

    /// `User-Agent` the `/ping` origin requires before it answers HTTP 200.
    ///
    /// Curl and browser agents receive 403. The value is a server allow-list
    /// token, not UI copy, so it is not localized. Icecast media requests keep
    /// their own agent in `requestWithIcecastHeaders(from:)`.
    ///
    /// - SeeAlso: ``latencyProbeRequest(url:)``
    static let latencyProbeUserAgent = "Lutheran Radio"

    /// Builds the EU/US `/ping` request with ``latencyProbeUserAgent``.
    ///
    /// DNSSEC stays on the session (`makeSecureEphemeralConfiguration()`).
    /// This header does not change certificate pinning or the TXT allow-list.
    ///
    /// - Parameter url: Cluster probe URL (`https://european.<apex>/ping` or the US twin).
    /// - Returns: A GET request whose `User-Agent` is ``latencyProbeUserAgent``.
    /// - SeeAlso: ``ping(server:)``, ``<doc:Security-Invariants>``
    static func latencyProbeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(latencyProbeUserAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Repeat probes within this window reuse ``currentSelectedServer`` for every attach context
    /// (cold launch, stream switch, resume, recovery). Only a **valid ping RTT** stamps
    /// ``lastServerSelectionTime``; dual timeout must not, or this window would skip the next
    /// real probe after “we learned nothing.”
    ///
    /// - SeeAlso: ``sameStreamWarmServerReuseInterval``, ``shouldReuseCachedServerSelection(lastSelectionAge:allowSameStreamWarmReuse:)``,
    ///   ``shouldStampLastServerSelection(hasValidPingResult:)``
    static let serverSelectionThrottleInterval: TimeInterval = 10.0

    /// Whether a completed ping pair may stamp ``lastServerSelectionTime``.
    ///
    /// Dual timeout (`hasValidPingResult == false`) must not stamp: the 10 s throttle would
    /// otherwise treat a no-result as a real selection and skip the next probe. A valid RTT
    /// stamps so the next attach can reuse the measured cluster.
    ///
    /// - Parameter hasValidPingResult: At least one ping returned a finite latency.
    /// - Returns: `true` only when a measured cluster exists.
    /// - Important: Ping is latency optimization, not a security gate. DNS TXT / Core pins
    ///   still run on the stream URL via ``makeSecuredPlayerItem(for:)``.
    /// - SeeAlso: ``selectOptimalServer(completion:)``, ``lastServerSelectionTime``
    static func shouldStampLastServerSelection(hasValidPingResult: Bool) -> Bool {
        hasValidPingResult
    }

    /// Same-stream hard-resume (``PlaybackAttachContext/resume``) may reuse the last measured
    /// cluster without a new EU/US ping pair while the last success is this young.
    ///
    /// Longer than ``serverSelectionThrottleInterval`` so a retained ``.resume`` attach does
    /// not wait on RTT after the 10 s throttle expires. Shorter than a routing epoch;
    /// ``lastServerSelectionTime`` is still niled on network-path reconnect. Cold launch,
    /// stream switch, recovery ``play()``, and
    /// ``PlaybackAttachContext/freshAttachAfterHardTeardown`` do not use this window.
    /// User pause still hard-tears Icecast (``isSoftPaused`` stays false); Play with no
    /// retained item is that fresh attach, not warm ``.resume``.
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
    ///     (``PlaybackAttachContext/resume``). `false` for cold launch, stream switch,
    ///     ``PlaybackAttachContext/freshAttachAfterHardTeardown``, and recovery ``play()``.
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

    /// One measured cluster sample used when a rejected cluster must not win on RTT.
    struct ClusterLatencySample: Equatable, Sendable {
        var subdomain: String
        var latency: TimeInterval
    }

    /// Whether `host` is a production stream host (`<slug>-eu.<apex>` / `<slug>-us.<apex>`).
    ///
    /// Ping hosts (`european.<apex>`, `livestream.<apex>`) return nil. The match is the
    /// trailing `-<subdomain>` label, not a substring of the apex.
    ///
    /// - Parameters:
    ///   - host: URL host, without a port.
    ///   - apex: ``SecurityConfiguration/preferredStreamingDomainSuffix``.
    ///   - productionSubdomains: ``servers`` subdomains, preferred order.
    /// - Returns: `eu` / `us` when the host is a language stream on that cluster.
    /// - SeeAlso: ``isEmbeddedSecurityModelRejection(statusCode:url:expectedModel:apex:productionSubdomains:)``
    static func productionClusterSubdomain(
        host: String,
        apex: String,
        productionSubdomains: [String]
    ) -> String? {
        let normalizedHost = host.lowercased()
        let suffix = ".\(apex.lowercased())"
        guard normalizedHost.hasSuffix(suffix) else { return nil }
        let label = String(normalizedHost.dropLast(suffix.count))
        guard !label.contains(".") else { return nil }
        return productionSubdomains.first { subdomain in
            let token = subdomain.lowercased()
            return label.hasSuffix("-\(token)") && label.count > token.count + 1
        }
    }

    /// HTTP 403 from a production stream host whose query already carries the embedded model.
    ///
    /// This is the deploy-lag window: the origin has not loaded the name yet. It is not a
    /// certificate failure and not a `/ping` User-Agent refusal. The app must keep sending
    /// ``SecurityConfiguration/expectedSecurityModel`` and must not substitute an older name.
    ///
    /// - Parameters:
    ///   - statusCode: HTTP status from the stream response.
    ///   - url: Stream URL the origin answered.
    ///   - expectedModel: ``SecurityConfiguration/expectedSecurityModel``.
    ///   - apex: ``SecurityConfiguration/preferredStreamingDomainSuffix``.
    ///   - productionSubdomains: ``servers`` subdomains.
    /// - Returns: `true` only for status 403, a language stream host, and an exact
    ///   `security_model` query match.
    /// - SeeAlso: ``productionClusterSubdomain(host:apex:productionSubdomains:)``,
    ///   ``noteEmbeddedSecurityModelRejection(url:statusCode:)``
    static func isEmbeddedSecurityModelRejection(
        statusCode: Int,
        url: URL,
        expectedModel: String,
        apex: String,
        productionSubdomains: [String]
    ) -> Bool {
        guard statusCode == 403, let host = url.host else { return false }
        guard productionClusterSubdomain(
            host: host,
            apex: apex,
            productionSubdomains: productionSubdomains
        ) != nil else {
            return false
        }
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return false
        }
        return items.contains { $0.name == "security_model" && $0.value == expectedModel }
    }

    /// Whether `subdomain` may still be opened this process.
    ///
    /// - Parameters:
    ///   - subdomain: Production cluster subdomain (`eu` / `us`).
    ///   - rejectedSubdomains: Clusters that already returned HTTP 403 for the embedded model.
    /// - Returns: `false` when `subdomain` is in the set.
    static func clusterEligibleAfterSecurityModelRejections(
        subdomain: String,
        rejectedSubdomains: Set<String>
    ) -> Bool {
        !rejectedSubdomains.contains(subdomain)
    }

    /// The other production cluster, when it has not refused the embedded model.
    ///
    /// - Parameters:
    ///   - currentSubdomain: Cluster that just failed or is selected now.
    ///   - rejectedSubdomains: Clusters already refused this process.
    ///   - servers: ``servers``, preferred order.
    /// - Returns: The first server whose subdomain differs and is not rejected.
    /// - SeeAlso: ``alternateProductionClusterSubdomain(currentSubdomain:productionSubdomains:)``
    static func alternateEligibleCluster(
        currentSubdomain: String,
        rejectedSubdomains: Set<String>,
        servers: [Server]
    ) -> Server? {
        servers.first { server in
            server.subdomain != currentSubdomain && !rejectedSubdomains.contains(server.subdomain)
        }
    }

    /// Cached-cluster reuse, plus the embedded-model refusal set.
    ///
    /// A rejected cluster is never reused, including inside the 10 s throttle and the
    /// same-stream warm window. A missing stamp still does not reuse.
    ///
    /// - Parameters:
    ///   - subdomain: Cluster the cache would keep.
    ///   - rejectedSubdomains: Clusters refused this process.
    ///   - lastSelectionAge: Seconds since ``lastServerSelectionTime``, or nil.
    ///   - allowSameStreamWarmReuse: Forwarded to ``shouldReuseCachedServerSelection(lastSelectionAge:allowSameStreamWarmReuse:)``.
    /// - Returns: `true` only when the cluster is eligible and the age window says reuse.
    /// - SeeAlso: ``shouldReuseCachedServerSelection(lastSelectionAge:allowSameStreamWarmReuse:)``
    static func mayReuseCachedCluster(
        subdomain: String,
        rejectedSubdomains: Set<String>,
        lastSelectionAge: TimeInterval?,
        allowSameStreamWarmReuse: Bool
    ) -> Bool {
        guard clusterEligibleAfterSecurityModelRejections(
            subdomain: subdomain,
            rejectedSubdomains: rejectedSubdomains
        ) else {
            return false
        }
        return shouldReuseCachedServerSelection(
            lastSelectionAge: lastSelectionAge,
            allowSameStreamWarmReuse: allowSameStreamWarmReuse
        )
    }

    /// Lowest finite RTT among clusters that have not refused the embedded model.
    ///
    /// A rejected sample cannot win, even when its latency is lower. When every sample
    /// is unusable, `fallbackSubdomain` is returned only if it is still eligible.
    ///
    /// - Parameters:
    ///   - samples: Ping results. Non-finite latency is a failed probe.
    ///   - rejectedSubdomains: Clusters refused this process.
    ///   - fallbackSubdomain: Current cluster when no eligible sample exists.
    /// - Returns: The subdomain to select, or nil when none remain eligible.
    /// - SeeAlso: ``mayReuseCachedCluster(subdomain:rejectedSubdomains:lastSelectionAge:allowSameStreamWarmReuse:)``
    static func winningClusterSubdomain(
        samples: [ClusterLatencySample],
        rejectedSubdomains: Set<String>,
        fallbackSubdomain: String
    ) -> String? {
        let eligible = samples.filter { sample in
            sample.latency.isFinite && !rejectedSubdomains.contains(sample.subdomain)
        }
        if let best = eligible.min(by: { $0.latency < $1.latency }) {
            return best.subdomain
        }
        if clusterEligibleAfterSecurityModelRejections(
            subdomain: fallbackSubdomain,
            rejectedSubdomains: rejectedSubdomains
        ) {
            return fallbackSubdomain
        }
        return nil
    }

    /// Records an HTTP 403 that refused the embedded security model, if this URL is one.
    ///
    /// Safe to call from the URLSession delegate queue. The insert is visible to the
    /// resource loader before the caller finishes the loading request.
    ///
    /// - Parameters:
    ///   - url: Stream URL that returned `statusCode`.
    ///   - statusCode: HTTP status.
    /// - Returns: ``EmbeddedSecurityModelRejectionDisposition``. `.notThisFailure` leaves
    ///   the existing 403 path in place. `.failoverOnce` is the one move onto the other
    ///   cluster. `.terminalLock` means every production cluster has refused.
    /// - Important: Does not change ``SecurityConfiguration/expectedSecurityModel`` and
    ///   does not persist the set.
    /// - SeeAlso: ``performEmbeddedSecurityModelClusterFailover()``,
    ///   ``isEmbeddedSecurityModelRejection(statusCode:url:expectedModel:apex:productionSubdomains:)``
    func noteEmbeddedSecurityModelRejection(
        url: URL,
        statusCode: Int
    ) -> EmbeddedSecurityModelRejectionDisposition {
        let apex = SecurityConfiguration.current.preferredStreamingDomainSuffix
        let expectedModel = SecurityConfiguration.current.expectedSecurityModel
        let productionSubdomains = Self.servers.map(\.subdomain)
        guard Self.isEmbeddedSecurityModelRejection(
            statusCode: statusCode,
            url: url,
            expectedModel: expectedModel,
            apex: apex,
            productionSubdomains: productionSubdomains
        ), let host = url.host,
              let failed = Self.productionClusterSubdomain(
                host: host,
                apex: apex,
                productionSubdomains: productionSubdomains
              ) else {
            return .notThisFailure
        }
        return embeddedSecurityModelClusterRejections.withLock { state in
            state.rejectedSubdomains.insert(failed)
            let eligible = Self.servers.filter { !state.rejectedSubdomains.contains($0.subdomain) }
            guard let next = eligible.first else {
                state.failoverInFlight = false
                return .terminalLock
            }
            if state.failoverInFlight {
                return .waitForInFlightFailover
            }
            state.failoverInFlight = true
            return .failoverOnce(next.subdomain)
        }
    }

    /// Subdomains refused this process. Empty until a matching HTTP 403 is recorded.
    func embeddedSecurityModelRejectedSubdomains() -> Set<String> {
        embeddedSecurityModelClusterRejections.withLock { $0.rejectedSubdomains }
    }

    /// `true` when at least one production cluster has not refused the embedded model.
    func hasEligibleProductionCluster() -> Bool {
        let rejected = embeddedSecurityModelRejectedSubdomains()
        return Self.servers.contains { !rejected.contains($0.subdomain) }
    }

    /// `true` when `subdomain` may still be opened this process.
    func isProductionClusterEligible(_ subdomain: String) -> Bool {
        Self.clusterEligibleAfterSecurityModelRejections(
            subdomain: subdomain,
            rejectedSubdomains: embeddedSecurityModelRejectedSubdomains()
        )
    }

    /// `true` when `url` is a language stream on a cluster refused this process.
    func streamRequestTargetsRejectedEmbeddedSecurityModelCluster(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        let apex = SecurityConfiguration.current.preferredStreamingDomainSuffix
        guard let subdomain = Self.productionClusterSubdomain(
            host: host,
            apex: apex,
            productionSubdomains: Self.servers.map(\.subdomain)
        ) else {
            return false
        }
        return !isProductionClusterEligible(subdomain)
    }

    /// Points ``currentSelectedServer`` at a cluster that has not refused, without stamping.
    ///
    /// - Returns: `false` when every production cluster has refused. The caller must not ping
    ///   or attach.
    @discardableResult
    func redirectCurrentServerOffRejectedCluster() -> Bool {
        let rejected = embeddedSecurityModelRejectedSubdomains()
        guard Self.servers.contains(where: { !rejected.contains($0.subdomain) }) else {
            return false
        }
        if !rejected.contains(currentSelectedServer.subdomain) {
            return true
        }
        guard let alternate = Self.alternateEligibleCluster(
            currentSubdomain: currentSelectedServer.subdomain,
            rejectedSubdomains: rejected,
            servers: Self.servers
        ) else {
            return false
        }
        currentSelectedServer = alternate
        return true
    }

    /// One move onto a cluster that has not refused the embedded model.
    ///
    /// Does not stamp ``lastServerSelectionTime``. Under UITestMode the URL is recorded
    /// and no item is built. When no cluster remains, locks playback and stops without
    /// a user-pause visual.
    ///
    /// - SeeAlso: ``noteEmbeddedSecurityModelRejection(url:statusCode:)``,
    ///   ``finishBecauseEveryProductionClusterRejectedEmbeddedSecurityModel()``
    @MainActor
    func performEmbeddedSecurityModelClusterFailover() async {
        cancelStartupSafetyNet()
        cancelEarlyICYDropRecreate()
        let server = embeddedSecurityModelClusterRejections.withLock { state -> Server? in
            Self.servers.first { !state.rejectedSubdomains.contains($0.subdomain) }
        }
        guard let server, isProductionClusterEligible(server.subdomain) else {
            await finishBecauseEveryProductionClusterRejectedEmbeddedSecurityModel()
            return
        }
        currentSelectedServer = server
        let url = StreamCatalog.streamURL(
            languageCode: selectedStream.languageCode,
            region: server.subdomain
        )
        test_lastEmbeddedSecurityModelFailoverURL = url
        guard !isTesting else { return }
        recreatePlayerItem(securedURL: url)
    }

    /// Locks visual and intent, then stops the engine, when no production cluster remains.
    ///
    /// Stop uses ``StopReason/error`` so the teardown does not paint sticky user pause
    /// over ``.securityLocked``. No stream URL is opened.
    ///
    /// - SeeAlso: ``SharedPlayerManager/lockPlaybackBecauseEveryProductionClusterRejectedEmbeddedSecurityModel()``,
    ///   ``stop(reason:completion:silent:applyUserPauseVisualLock:)``
    @MainActor
    func finishBecauseEveryProductionClusterRejectedEmbeddedSecurityModel() async {
        cancelStartupSafetyNet()
        cancelEarlyICYDropRecreate()
        await SharedPlayerManager.shared.lockPlaybackBecauseEveryProductionClusterRejectedEmbeddedSecurityModel()
        stop(reason: .error, silent: true, applyUserPauseVisualLock: false)
    }

    /// Clears the process refusal set. Unit tests call this so a case cannot leak into the next one.
    func test_resetEmbeddedSecurityModelClusterRejections() {
        embeddedSecurityModelClusterRejections.withLock { state in
            state.rejectedSubdomains.removeAll()
            state.failoverInFlight = false
        }
        test_lastEmbeddedSecurityModelFailoverURL = nil
        test_recreatePlayerItemEntryCount = 0
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
    ///   latency-only among clusters that have not refused the embedded security model this
    ///   process. A rejected cluster is not a ping sample and is not kept by the throttle.
    ///   Same-stream warm reuse is decided in ``ensureOptimalServerSelected(allowSameStreamWarmReuse:)``
    ///   before this method runs; once this method is entered past the 10 s throttle it pings.
    /// - Example: `selectOptimalServer { server in print(server.name) }`
    /// - SeeAlso: `fetchServerIPsAndLatencies(completion:)`, ``urlWithOptimalServer(for:allowSameStreamWarmReuse:)``,
    ///   ``shouldReuseCachedServerSelection(lastSelectionAge:allowSameStreamWarmReuse:)``
    func selectOptimalServer(completion: @escaping @Sendable (Server) -> Void) {
        guard redirectCurrentServerOffRejectedCluster() else {
            #if DEBUG
            print("[DirectStreamingPlayer] selectOptimalServer: no eligible cluster after embedded-model rejection")
            #endif
            completion(currentSelectedServer)
            return
        }
        let rejected = embeddedSecurityModelRejectedSubdomains()
        if let last = lastServerSelectionTime,
           Self.mayReuseCachedCluster(
            subdomain: currentSelectedServer.subdomain,
            rejectedSubdomains: rejected,
            lastSelectionAge: Date().timeIntervalSince(last),
            allowSameStreamWarmReuse: false
           ) {
            #if DEBUG
            print("[DirectStreamingPlayer] selectOptimalServer: Throttling server selection, using cached server: \(currentSelectedServer.name)")
            #endif
            completion(currentSelectedServer)
            return
        }

        serverSelectionInFlight = true
        serverSelectionWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                completion(Self.servers[0])
                return
            }
            
            self.fetchServerIPsAndLatencies { results in
                let rejectedNow = self.embeddedSecurityModelRejectedSubdomains()
                let samples = results.map {
                    ClusterLatencySample(subdomain: $0.server.subdomain, latency: $0.latency)
                }
                if let winner = Self.winningClusterSubdomain(
                    samples: samples,
                    rejectedSubdomains: rejectedNow,
                    fallbackSubdomain: self.currentSelectedServer.subdomain
                ), let server = Self.servers.first(where: { $0.subdomain == winner }) {
                    let measured = samples.contains { sample in
                        sample.subdomain == winner
                            && sample.latency.isFinite
                            && !rejectedNow.contains(sample.subdomain)
                    }
                    self.currentSelectedServer = server
                    if measured {
                        // Fire-and-forget save of a measured cluster. A refused cluster
                        // cannot be this winner. Dual timeout does not save or stamp.
                        Task {
                            await SharedPlayerManager.shared.saveCurrentState()
                        }
                    }
                    if Self.shouldStampLastServerSelection(hasValidPingResult: measured) {
                        self.lastServerSelectionTime = Date()
                    }
                    #if DEBUG
                    print("[DirectStreamingPlayer] [Server Selection] Selected \(server.name) measured=\(measured)")
                    #endif
                } else {
                    // No eligible cluster, or dual timeout with a rejected fallback.
                    // Do not stamp. Do not open a refused cluster from this result.
                    #if DEBUG
                    print("[DirectStreamingPlayer] [Server Selection] No eligible ping result, keeping \(self.currentSelectedServer.name) (not stamping)")
                    #endif
                }

                self.serverSelectionInFlight = false
                completion(self.currentSelectedServer)
            }
        }
        
        serverSelectionWorkItem = workItem
        let selectionDelay: TimeInterval = isLowEfficiencyMode ? 1.0 : 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + selectionDelay, execute: workItem)
    }

    /// Starts the EU/US RTT probe without waiting. First attach uses default/last-good
    /// (``servers[0]`` / EU, or a previously measured cluster) immediately.
    ///
    /// Isolation: no-op under UITestMode. Coalesces while ``serverSelectionInFlight``.
    /// Does not skip DNS TXT / Core pins on the stream URL.
    ///
    /// - SeeAlso: ``ensureOptimalServerSelected(allowSameStreamWarmReuse:)``,
    ///   ``urlWithOptimalServer(for:allowSameStreamWarmReuse:)``
    func beginBackgroundServerSelectionIfNeeded() {
        guard !isTesting else { return }
        guard hasEligibleProductionCluster() else { return }
        guard redirectCurrentServerOffRejectedCluster() else { return }
        guard !serverSelectionInFlight else { return }
        let age = lastServerSelectionTime.map { Date().timeIntervalSince($0) }
        if Self.mayReuseCachedCluster(
            subdomain: currentSelectedServer.subdomain,
            rejectedSubdomains: embeddedSecurityModelRejectedSubdomains(),
            lastSelectionAge: age,
            allowSameStreamWarmReuse: false
        ) {
            return
        }
        selectOptimalServer { _ in }
    }
    
    /// Ensures a cluster is available for URL construction without blocking first audible attach.
    ///
    /// Fast-path: ``shouldReuseCachedServerSelection(lastSelectionAge:allowSameStreamWarmReuse:)``
    /// returns immediately with zero allocation and no suspension (10 s throttle for every
    /// context; longer warm window only when `allowSameStreamWarmReuse` is true).
    ///
    /// Otherwise starts the EU/US ping pair in the **background** and returns immediately on
    /// default/last-good (``servers[0]`` / EU). Ping is latency optimization, not a security
    /// gate — DNS TXT / Core pins still run on the stream URL. Dual timeout does not stamp
    /// ``lastServerSelectionTime``.
    ///
    /// This is the internal implementation detail behind
    /// ``urlWithOptimalServer(for:allowSameStreamWarmReuse:)``.
    ///
    /// - Parameter allowSameStreamWarmReuse: Pass `true` only from ``PlaybackAttachContext/resume``
    ///   attach (retained same-stream path). Default `false` keeps the 10 s throttle only —
    ///   required for stream switch, cold launch, fresh attach after hard teardown, and
    ///   recovery ``play()``.
    /// - SeeAlso: ``shouldReuseCachedServerSelection(lastSelectionAge:allowSameStreamWarmReuse:)``,
    ///   ``beginBackgroundServerSelectionIfNeeded()``
    func ensureOptimalServerSelected(allowSameStreamWarmReuse: Bool = false) async {
        guard redirectCurrentServerOffRejectedCluster() else {
            #if DEBUG
            print("[DirectStreamingPlayer] ensureOptimalServerSelected: no eligible cluster after embedded-model rejection")
            #endif
            return
        }
        let age = lastServerSelectionTime.map { Date().timeIntervalSince($0) }
        if Self.mayReuseCachedCluster(
            subdomain: currentSelectedServer.subdomain,
            rejectedSubdomains: embeddedSecurityModelRejectedSubdomains(),
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

        #if DEBUG
        print("[DirectStreamingPlayer] ensureOptimalServerSelected: attaching on \(currentSelectedServer.name) without waiting for ping pair")
        #endif
        beginBackgroundServerSelectionIfNeeded()
    }

    /// Returns a playback URL for `stream` on the current cluster (default/last-good, or a
    /// just-measured winner if a background ping already completed).
    ///
    /// This is the **single source of truth** for all URL construction that feeds AVURLAsset
    /// or AVPlayerItem on cold launch, stream switch, same-stream resume, or direct start paths.
    ///
    /// Internally calls ``ensureOptimalServerSelected(allowSameStreamWarmReuse:)`` then
    /// reads the computed `stream.url` (which consults `currentSelectedServer` at read time).
    /// First attach is **not** serialized behind the ping pair: default/last-good is used
    /// immediately and pings run in parallel (typically during the tuning clip). A later
    /// successful ping updates ``currentSelectedServer`` for the next stream switch; it does
    /// not recreate an in-flight first-byte item (that would abort DNS/TLS).
    ///
    /// Adding new playback entry points? Route their first `.url` access through this helper
    /// and the original race becomes structurally impossible.
    ///
    /// - Parameters:
    ///   - stream: Catalog stream whose host is rewritten from ``currentSelectedServer``.
    ///   - allowSameStreamWarmReuse: `true` only for ``PlaybackAttachContext/resume``. `false`
    ///     (default) for cold launch, stream switch, fresh attach after hard teardown, and
    ///     recovery ``play()`` — those still start a background ping when the 10 s throttle
    ///     has expired. Does not skip Core pins on the stream URL.
    /// - Returns: HTTPS stream URL on the currently selected cluster.
    /// - Note: A stamp older than the 10 s throttle is a valid last-good attach when warm
    ///   reuse is false. ``ensureOptimalServerSelected(allowSameStreamWarmReuse:)`` returns
    ///   immediately and kicks a background ping; it does not re-stamp until that pair
    ///   completes. Debug checks that a *reused* stamp is inside the window this call asked
    ///   for. It does not require a deliberate last-good stamp to be fresh.
    /// - SeeAlso: ``shouldReuseCachedServerSelection(lastSelectionAge:allowSameStreamWarmReuse:)``,
    ///   ``beginBackgroundServerSelectionIfNeeded()``,
    ///   ``PlaybackAttachContext``, DirectStreamingPlayer+PlaybackAttach.swift
    func urlWithOptimalServer(for stream: Stream, allowSameStreamWarmReuse: Bool = false) async -> URL {
        // A refused cluster is not probed. Callers that attach must check
        // ``hasEligibleProductionCluster()`` first; the resource loader also refuses
        // the URL so a late caller still opens no stream HTTP.
        guard hasEligibleProductionCluster() else {
            return stream.url
        }
        await ensureOptimalServerSelected(allowSameStreamWarmReuse: allowSameStreamWarmReuse)

        #if DEBUG
        // Stamp is optional (first attach, or dual timeout that must not stamp).
        // When this call reused the stamp, the age must actually sit inside the window
        // ``shouldReuseCachedServerSelection`` claimed — that catches a reuse predicate
        // that returns true for a stamp outside 10 s / the warm window.
        // A stale stamp on the last-good path (warm reuse false, age past the throttle)
        // is expected: attach already returned on the previous cluster and the background
        // ping owns the next stamp. Do not treat that age as a failed reuse.
        if let t = lastServerSelectionTime {
            let age = Date().timeIntervalSince(t)
            if Self.shouldReuseCachedServerSelection(
                lastSelectionAge: age,
                allowSameStreamWarmReuse: allowSameStreamWarmReuse
            ) {
                let insideThrottle = age >= 0 && age <= Self.serverSelectionThrottleInterval
                let insideWarmWindow = allowSameStreamWarmReuse
                    && age <= Self.sameStreamWarmServerReuseInterval
                assert(
                    insideThrottle || insideWarmWindow,
                    "urlWithOptimalServer: reused selection stamp is \(age)s old outside the requested window (same-stream warm reuse=\(allowSameStreamWarmReuse))"
                )
            } else {
                let ageText = age.formatted(
                    .number
                        .precision(.fractionLength(1))
                        .locale(Locale(identifier: "en_US_POSIX"))
                )
                print("[DirectStreamingPlayer] urlWithOptimalServer: last-good attach with selection stamp age \(ageText)s (same-stream warm reuse=\(allowSameStreamWarmReuse)); background ping owns the next stamp")
            }
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
        let rejected = embeddedSecurityModelRejectedSubdomains()
        let targets = Self.servers.filter { !rejected.contains($0.subdomain) }
        guard !targets.isEmpty else { return [] }
        return await withTaskGroup(of: PingResult.self) { group in
            for server in targets {
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
        
        // DNSSEC stays on (same secure session as streaming). The `/ping` origin
        // answers HTTP 200 only for `User-Agent: Lutheran Radio`; other agents
        // get 403, which this method records as a failed sample.
        // - SeeAlso: latencyProbeRequest(url:), SecurityConfiguration.makeSecureEphemeralConfiguration()
        let request = Self.latencyProbeRequest(url: server.pingURL)
        
        do {
            // First attempt stays at 2 s with DNSSEC required. The User-Agent on `request`
            // is unchanged. A DNSSEC-not-completed error may retry once at a longer timeout.
            let (_, response) = try await ProtectedHostHTTPS.data(
                for: request,
                host: server.pingURL.host,
                configureFirst: { configuration in
                    configuration.timeoutIntervalForRequest = 2.0
                },
                delegate: nil,
                delegateQueue: nil
            )
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
