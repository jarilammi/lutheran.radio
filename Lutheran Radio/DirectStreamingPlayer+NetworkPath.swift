//
//  DirectStreamingPlayer+NetworkPath.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 25.7.2026.
//
//  Engine-owned network path monitoring: status types, injectable monitor protocol,
//  production NWPathMonitor adapter, and sole free-running setup path.
//
//  Behavior-preserving domain split from DirectStreamingPlayer.swift.
//  DirectStreamingPlayer remains the public engine façade; this file owns one domain.
//
//  Ownership (do not invert):
//  - This domain owns the **sole** production free-running `NWPathMonitor` lifecycle
//    (`setupNetworkMonitoring`) and updates ``hasInternetConnection`` for streaming retries.
//  - Host chrome (cellular expensive-path prompt, SPM stop/reconnect) **observes** via
//    ``DirectStreamingPlayer/onNetworkPathChange`` — never a second free-running monitor
//    or HTTP probe timer on ViewController.
//  - Do not reintroduce short-lived parallel path probes for connect-time heuristics; the
//    free-running sample + ``onNetworkPathChange`` is the only path SSOT.
//  - Stored flags (`hasInternetConnection`, `networkMonitor`, `onNetworkPathChange`,
//    `pathMonitor`) live on the façade class body (extensions cannot declare stored state).
//
//  AGENT NOTE: Members used across files are `internal` (Swift `private` is
//  file-scoped). Prefer this domain file over re-implementing path monitoring in call sites.
//  UITestMode / `isTesting` must continue to skip monitor start so reconnect cannot auto-play.
//
//  - SeeAlso: DirectStreamingPlayer.swift,
//    ViewController path observation, CellularPermissionManager,
//    CODING_AGENT.md (Single Source of Truth Principles).
//

import Foundation
import Network

// MARK: - Network path status types and monitor protocol

/// Represents the network path status for connectivity monitoring.
/// - Note: Maps to NWPath.Status; used for adaptive retries.
enum NetworkPathStatus: Sendable {
    /// Network is available and satisfied.
    case satisfied
    /// Network is unavailable.
    case unsatisfied
    /// Connection is required but not yet established.
    case requiresConnection
}

/// Single published path sample from the engine-owned monitor.
///
/// Carries both reachability status and expensive/metered classification so host chrome
/// (cellular prompt presentation) can observe the engine without a second `NWPathMonitor`.
///
/// - SeeAlso: ``NetworkPathMonitoring``, ``DirectStreamingPlayer/setupNetworkMonitoring()``,
///   `CellularPermissionManager`, ViewController path observation.
struct NetworkPathUpdate: Sendable {
    /// Mapped `NWPath.Status` (satisfied / unsatisfied / requiresConnection).
    let status: NetworkPathStatus
    /// `NWPath.isExpensive` — cellular / personal-hotspot style metered paths.
    let isExpensive: Bool
}

/// Protocol for monitoring network path changes.
///
/// Production uses a single `NWPathMonitor` via ``NWPathMonitorAdapter`` owned by
/// ``DirectStreamingPlayer``. Host UI must **observe** path updates (via
/// ``DirectStreamingPlayer/onNetworkPathChange``) rather than start a second monitor.
///
/// - Note: Abstracts NWPathMonitor for testability; use `NWPathMonitorAdapter` in production.
/// - SeeAlso: ``NetworkPathUpdate``, ``DirectStreamingPlayer/hasInternetConnection``
protocol NetworkPathMonitoring: AnyObject, Sendable {
    /// Handler for network path updates (status + expensive flag in one sample).
    var pathUpdateHandler: (@Sendable (NetworkPathUpdate) -> Void)? { get set }
    /// Starts monitoring on a specified queue.
    func start(queue: DispatchQueue)
    /// Cancels monitoring.
    func cancel()
    /// Current network path for checks like isExpensive (metered) between updates.
    var currentPath: NWPath? { get }
}

/// Adapts `NWPathMonitor` to the `NetworkPathMonitoring` protocol.
///
/// Sole production adapter for the engine path monitor. Delivers ``NetworkPathUpdate`` so
/// expensive-path classification travels with status (no second monitor for cellular UI).
///
/// - Note: `@unchecked Sendable` matches historical engine sharing; path callbacks hop to
///   main for host chrome. Prefer MainActor hops for new cross-boundary work.
final class NWPathMonitorAdapter: NetworkPathMonitoring, @unchecked Sendable {
    let monitor: NWPathMonitor

    var pathUpdateHandler: (@Sendable (NetworkPathUpdate) -> Void)? {
        didSet {
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self = self else { return }
                let status: NetworkPathStatus
                switch path.status {
                case .satisfied:
                    status = .satisfied
                case .unsatisfied:
                    status = .unsatisfied
                case .requiresConnection:
                    status = .requiresConnection
                @unknown default:
                    status = .unsatisfied
                }
                self.pathUpdateHandler?(NetworkPathUpdate(status: status, isExpensive: path.isExpensive))
            }
        }
    }

    // Implement currentPath to expose the underlying monitor's currentPath.
    var currentPath: NWPath? {
        return monitor.currentPath
    }

    init() {
        self.monitor = NWPathMonitor()
    }

    func start(queue: DispatchQueue) {
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }
}

// MARK: - Network path monitoring (engine sole free-running monitor)

extension DirectStreamingPlayer {

    /// Starts the **sole** production `NWPathMonitor` for process reachability.
    ///
    /// Ownership story (do not reintroduce a host-side monitor):
    /// 1. This method is the only free-running path-monitor start in the main app.
    /// 2. ``hasInternetConnection`` is updated here and is the authoritative flag for
    ///    streaming retries, cold-launch guards, and host mirrors.
    /// 3. ``onNetworkPathChange`` publishes the same sample to host chrome (cellular
    ///    expensive-path prompt, SPM stop/reconnect) so UI never needs a second clock
    ///    or HTTP probe timer.
    ///
    /// UI Test isolation: does not start under `isTesting` (sourced from
    /// `SharedPlayerManager.isRunningInUITestMode`) so reconnect cannot auto-play
    /// or fire security work in the test host.
    ///
    /// - SeeAlso: ``onNetworkPathChange``, ``NetworkPathUpdate``, ``hasInternetConnection``,
    ///   ViewController path observation (observer only), CODING_AGENT.md (SSOT)
    /// - Important: Do not add a parallel `NWPathMonitor` on `ViewController` or a 5 s
    ///   `URLSession` connectivity poll — path updates already cover reconnect edges.
    internal func setupNetworkMonitoring() {
        // UI Test isolation: do not start network monitoring under test.
        // This prevents reconnect handlers from calling play() or triggering any
        // network/security work or status callbacks during UITest launches.
        guard !isTesting else {
            #if DEBUG
            print("[DirectStreamingPlayer] setupNetworkMonitoring — isTesting, skipping NWPathMonitor (no auto-replay side effects)")
            #endif
            return
        }

        networkMonitor = pathMonitor
        networkMonitor?.pathUpdateHandler = { [weak self] update in
            guard let self else {
                #if DEBUG
                print("[DirectStreamingPlayer] [Network] Skipped path update: self is nil")
                #endif
                return
            }

            let wasConnected = self.hasInternetConnection
            let isConnected = update.status == .satisfied
            self.hasInternetConnection = isConnected
            let isExpensive = update.isExpensive

            #if DEBUG
            print("[DirectStreamingPlayer] [Network] Status: \(isConnected ? "Connected" : "Disconnected") expensive=\(isExpensive)")
            #endif

            // Publish once for host chrome (cellular + SPM surfaces). Main queue so
            // alert presentation and coordinator calls stay on the UI actor.
            if let onNetworkPathChange = self.onNetworkPathChange {
                DispatchQueue.main.async {
                    onNetworkPathChange(isConnected, isExpensive, wasConnected)
                }
            }

            if isConnected && !wasConnected {
                // ── Reconnect case (engine streaming recovery) ──
                #if DEBUG
                print("[DirectStreamingPlayer] [Network] Connection restored, previous server: \(self.currentSelectedServer.name)")
                print("[DirectStreamingPlayer] [Network] Cleared server selection throttle cache")
                #endif

                self.lastServerSelectionTime = nil

                // Reset transient security state + revalidate (named reconnect intent).
                Task {
                    await SecurityValidationFacade.resetTransientState()

                    #if DEBUG
                    print("[DirectStreamingPlayer] [Network] Invalidated security model validation cache (transient reset)")
                    #endif

                    let isValid = await SecurityValidationFacade.validate(.onReconnect)

                    #if DEBUG
                    print("[DirectStreamingPlayer] [Network] Revalidation result on reconnect: \(isValid)")
                    #endif

                    if !isValid {
                        let isPermanent = await SecurityValidationFacade.isPermanentlyInvalid()

                        let statusKey = isPermanent ? "status_security_failed" : "status_no_internet"

                        DispatchQueue.main.async {
                            self.safeOnStatusChange(
                                isPlaying: false,
                                reasonKey: statusKey
                            )
                        }
                    } else if self.player?.rate ?? 0 == 0, !self.hasPermanentError {
                        // Auto-replay if previously playing / ready (engine.play already
                        // consults canProceedWithPlayback). Host also routes SPM.play via
                        // onNetworkPathChange for full visual/widget surfaces.
                        Task { @MainActor in
                            let success = await self.play()

                            let playStatusKey = success ? "status_playing" : "status_stream_unavailable"
                            self.safeOnStatusChange(
                                isPlaying: success,
                                reasonKey: playStatusKey
                            )

                            #if DEBUG
                            if !success {
                                print("Auto-replay failed or was blocked by guard")
                            }
                            #endif
                        }
                    }
                }

                // Select optimal server after reconnect
                self.selectOptimalServer { server in
                    #if DEBUG
                    print("[DirectStreamingPlayer] [Network] New server selected: \(server.name)")
                    #endif
                    // Any additional post-selection logic here if needed
                }
            }
            else if !isConnected && wasConnected {
                // ── Disconnect case (engine status chrome) ──
                #if DEBUG
                print("[DirectStreamingPlayer] [Network] Connection lost")
                #endif

                DispatchQueue.main.async {
                    self.safeOnStatusChange(
                        isPlaying: false,
                        reasonKey: "status_no_internet"
                    )
                }
            }
        }
        networkMonitor?.start(queue: networkQueue)
    }
}
