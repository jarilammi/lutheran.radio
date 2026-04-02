//
//  DirectStreamingPlayer.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 25.2.2025.
//

import Foundation
import Security
import CommonCrypto
import AVFoundation
import dnssd
import Network
import Core

// MARK: - Sendable Completion Helpers (Swift 6)
typealias BoolCompletion   = @Sendable (Bool) -> Void
typealias VoidCompletion   = () -> Void
typealias ResultCompletion<T> = @Sendable (Result<T, Error>) -> Void

// MARK: - Delegate Protocol and Status Enum
/// Protocol for delegate callbacks (e.g., UI updates from ViewController).
protocol StreamingPlayerDelegate: AnyObject {
    func onStatusChange(_ status: PlayerStatus, _ reason: String?)
}

/// Player status enum for callbacks
enum PlayerStatus {
    case playing
    case paused
    case stopped
    case connecting
    case security
}

/// - Article: Core Streaming and Privacy Architecture
///
/// `DirectStreamingPlayer` is the heart of audio streaming, using AVFoundation for direct HTTPS playback with runtime SSL validation. It integrates with `CertificateValidator.swift` for certificate pinning and supports a transition period for rotations (July-August 2026).
///
/// **Single source of truth for state**: `DirectStreamingPlayer` now owns ALL mutations to `isPlaying`, `selectedStream`, `hasPermanentError`, `validationState`, etc. It calls `SharedPlayerManager.shared.saveCurrentState()` immediately after EVERY mutation (play, stop, setStream, status observers, server fallback, validation callbacks). This eliminates widget/Live Activity desync.
///
/// Workflow:
/// 1. **Initialization/Setup**: Queries DNS for access authorization; sets up AVPlayer with custom resource loading (`StreamingSessionDelegate.swift`).
/// 2. **Playback Control**: `play()`/`stop()` manage state; adaptive retries handle network issues (cellular-aware timeouts via `NetworkPathMonitoring`).
/// 3. **Error Handling**: Tracks transient/permanent errors; now guarantees persistence via `saveCurrentState()`.
/// 4. **Privacy Safeguards**: No metadata tracking; minimal network footprint; excludes features like push notifications (see excluded features list above).
///
/// iOS 26 Optimizations: Low-power mode reduces retry aggressiveness. For UI callbacks, see `ViewController.swift`'s `onStatusChange` and `onMetadataChange`. Shared via `SharedPlayerManager.shared` for widgets.
/// `DirectStreamingPlayer` manages audio streaming, security validation, and network monitoring for the Lutheran Radio app.
///
/// The Lutheran Radio app prioritizes user privacy and security to protect individuals, particularly in regions where religious content consumption may be monitored or restricted. This design ensures safe, anonymous access to Lutheran content without compromising personal data.
///
/// ## Intentionally Excluded Features
/// To safeguard user privacy, the following features are deliberately excluded:
/// - **Microphone Access**:
///   - Never requests microphone permissions.
///   - Prevents potential audio surveillance.
///   - Ensures conversations remain private.
/// - **Camera Access**:
///   - Never requests camera permissions.
///   - Protects visual environment privacy.
///   - Prevents facial recognition or environment scanning.
/// - **Push Notifications**:
///   - No remote notifications sent to devices.
///   - Prevents tracking of user engagement patterns.
///   - Eliminates visibility into listening habits.
/// - **Location Services**:
///   - Never requests location permissions.
///   - Prevents tracking of listening locations.
///   - Protects geographical privacy.
/// - **User Accounts/Profiles**:
///   - No registration required.
///   - No personal information collected.
///   - Enables fully anonymous usage.
/// - **Analytics/Tracking**:
///   - No usage statistics collected.
///   - No behavioral analysis performed.
///   - No data shared with third parties.
/// - **User Tracking Data Storage**:
///   - No user-identifiable data stored.
///   - No listening history maintained.
///   - No behavioral tracking or usage patterns recorded.
///
/// ## Security Features Implemented
/// - **Encrypted Connections**:
///   - All streaming uses HTTPS/TLS encryption.
///   - App Transport Security (ATS) enforces pinned public keys via `Info.plist` (`NSAppTransportSecurity`).
///   - Runtime SSL certificate validation with hostname verification is handled in `StreamingSessionDelegate`.
/// - **Dynamic Access Control**:
///   - Queries `securitymodels.lutheran.radio` TXT record to validate app authorization.
///   - Supports remote access control without requiring app updates.
///   - Requires the app security model (`starbase`) to be in the authorized list.
/// - **Privacy-Safe Data Management**:
///   - Streaming state stored only in memory during use.
///   - No persistent traces of listening activity.
///   - Only stores an anonymous preference (mobile data notification dismissed).
/// - **Minimal Network Footprint**:
///   - Connects only to streaming servers.
///   - No telemetry or reporting endpoints.
///   - No unnecessary background network activity.
/// - **Minimal Anonymous Preferences**:
///   - Stores only a boolean for mobile data usage notification preference.
///   - Cannot be used for user identification or tracking.
///   - Enhances user experience without compromising privacy.
///   - Fully deleted when the app is removed.
///
/// ## Why This Matters
/// Religious freedom includes the right to private worship and study. This design ensures users worldwide can access Lutheran content safely, especially in regions where:
/// - Religious content consumption is monitored.
/// - Government surveillance targets faith communities.
/// - Internet activity is logged and analyzed.
/// - Device permissions may be exploited for tracking.
///
/// > **Important:** This is not just about compliance—it’s about protecting user safety and religious freedom globally.
///
/// ## Developer Notes
/// To maintain the app's privacy-first principles, adhere to the following guidelines:
/// - Never implement push notification capabilities.
/// - Never request microphone or camera permissions.
/// - Never integrate analytics or tracking SDKs.
/// - Always use `HTTPS` for network communication.
/// - Never store user-identifiable information.
/// - Evaluate the privacy implications of any new features.
///
/// > **Note:** These restrictions are critical to ensuring user trust and safety in sensitive regions.

/// Share functionality to the LutheranRadioWidget
extension DirectStreamingPlayer {
    static let shared = DirectStreamingPlayer()
}

// MARK: - Network and Path Enums/Protocols
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

/// Protocol for monitoring network path changes.
/// - Note: Abstracts NWPathMonitor for testability; use `NWPathMonitorAdapter` in production.
protocol NetworkPathMonitoring: AnyObject, Sendable {
    /// Handler for network path updates.
    /// - Parameter status: The updated status (e.g., .satisfied).
    var pathUpdateHandler: (@Sendable (NetworkPathStatus) -> Void)? { get set }
    /// Starts monitoring on a specified queue.
    func start(queue: DispatchQueue)
    /// Cancels monitoring.
    func cancel()
    /// Current network path for checks like isExpensive (metered).
    var currentPath: NWPath? { get }
}

/// Adapts `NWPathMonitor` to the `NetworkPathMonitoring` protocol.
final class NWPathMonitorAdapter: NetworkPathMonitoring, @unchecked Sendable {
    private let monitor: NWPathMonitor
    
    var pathUpdateHandler: (@Sendable (NetworkPathStatus) -> Void)? {
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
                self.pathUpdateHandler?(status)
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

private let securityValidator = SecurityModelValidator.shared

/// Manages direct audio streaming, security validation, network monitoring, and privacy protections for the Lutheran Radio app.
final class DirectStreamingPlayer: NSObject, @unchecked Sendable {
    private var isSSLHandshakeComplete = false
    private var certificateValidationTimer: Timer?
    private var hasStartedPlaying = false
    
    // MARK: - Audio Session Properties
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var wasPlayingBeforeInterruption = false
    private var isHandlingInterruption = false
        
    /// Injectable closure for the current date, used for testing time-dependent logic.
    internal var currentDate: @Sendable () -> Date = { Date() }
    
    #if DEBUG
    var networkMonitor: NetworkPathMonitoring?
    var hasInternetConnection = true
    #else
    private var networkMonitor: NetworkPathMonitoring?
    private var hasInternetConnection = true
    #endif
    private var serverFailureCount: [String: Int] = [:]
    private var lastFailedServerName: String?
    private var currentSelectedServer: Server = servers[0]
    
    /// Track initialization and defer callbacks.
    private var isInitializing: Bool = true
    private var pendingStatusChanges: [(isPlaying: Bool, status: String)] = []
    
    /// Protects the playback startup path from aggressive `stop()` calls during async validation + server selection.
    /// Set to `true` at the beginning of `play()` and reset in `defer`.
    private var isCurrentlyAttemptingPlayback = false
    
    // MARK: - Energy Efficiency (Battery Optimization)
    /// Detects if the device is in Low Power Mode to throttle non-essential tasks (e.g., retry intervals) and extend battery life during streaming.
    /// Builds on thermal state handling; queried dynamically in retry/fallback logic.
    /// Reference: iOS ProcessInfo.isLowPowerModeEnabled (available since iOS 9).
    private var isLowEfficiencyMode: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    private var thermalObserver: NSObjectProtocol?
    private var wasPlayingBeforeThermal = false
    
    // Public accessors for ViewController
    var lastFailedServer: String? { return lastFailedServerName }
    var selectedServerInfo: Server { return currentSelectedServer }
    
    // MARK: - Stream URL Construction Rules
    //
    // All stream URLs follow this exact pattern:
    //
    //   https://<language-slug>-<region>.lutheran.radio/lutheranradio.mp3?security_model=<model>
    //
    // Breakdown:
    // • <language-slug>  → hardcoded mapping from language code:
    //     "en" → "english"   | "de" → "german"   | "fi" → "finnish"
    //     "sv" → "swedish"   | "et" → "estonian" | others → fallback to "english"
    //
    // • <region> → determined at runtime via TimeZone.current:
    //     - Europe/, GMT/UTC/WET/CET/EET/Atlantic/Reykjavik/Faroe → "eu"
    //     - America/, US/, Canada/, EST/CST/MST/PST → "us"
    //     - Everything else → "us" (US cluster has higher capacity)
    //
    // • Port is always 443 (TLS on standard port)
    // • Path is always "/lutheranradio.mp3"
    // • Query parameter "security_model" = current appSecurityModel ("starbase" as of version 26.3.1)
    //
    // This design achieves:
    // 1. Geographic load distribution (lower latency)
    // 2. Simple automatic failover (if one cluster is down, the other is used next launch)
    // 3. Future-proof version gating via DNS TXT record
    //
    // ⚠️  WHEN RELEASING A NEW SECURITY MODEL (certificate rotation, etc.):
    // 1. Change the constant below to the new codename (e.g. "brenham")
    // 2. Add the new codename to securitymodels.lutheran.radio TXT record
    // 3. Update README.md Security Model History table
    // 4. Ship app update → all users automatically switch on next launch
    //
    // DO NOT reuse old codenames — see history table to avoid collisions.
    private enum RegionDetector {
        static var currentRegion: Region {
            let tz = TimeZone.current.identifier
            
            if tz.hasPrefix("Europe/") ||
                ["GMT", "UTC", "WET", "CET", "EET", "Atlantic/Reykjavik", "Atlantic/Faroe"].contains(where: tz.hasPrefix) {
                return .eu
            }
            
            if tz.hasPrefix("America/") || tz.hasPrefix("US/") || tz.hasPrefix("Canada/") ||
                ["EST", "CST", "MST", "PST"].contains(where: tz.hasPrefix) {
                return .us
            }
            
            return .us // safe default – US cluster has higher capacity
        }
        
        enum Region: String {
            case eu = "eu"
            case us = "us"
        }
    }
    
    private struct LanguageSlugMapper {
        static func slug(for code: String) -> String {
            switch code {
            case "en": return "english"
            case "de": return "german"
            case "fi": return "finnish"
            case "sv": return "swedish"
            case "et": return "estonian"
            default: return "english"
            }
        }
    }
    
    private struct StreamURLBuilder {
        static func url(for languageCode: String,
                        region: String = DirectStreamingPlayer.shared.currentSelectedServer.subdomain) -> URL {
            
            let languageSlug = LanguageSlugMapper.slug(for: languageCode)
            
            var components = URLComponents()
            components.scheme = "https"
            components.host = "\(languageSlug)-\(region).lutheran.radio"
            components.path = "/lutheranradio.mp3"
            components.queryItems = [
                URLQueryItem(name: "security_model", value: SecurityConfiguration.current.expectedSecurityModel)
            ]
            
            // In production this can never fail, but to silence the compiler nicely:
            return components.url ?? URL(string: "https://livestream.lutheran.radio")!
        }
    }
    
    // MARK: - Server and Stream Structs
    /// A radio stream configuration.
    /// - Example: `Stream(title: "English", language: "English", languageCode: "en", flag: "🇺🇸")
    struct Stream {
        /// Display title (localized).
        let title: String
        /// Streaming URL (HTTPS required).
        var url: URL {
            StreamURLBuilder.url(for: languageCode)
        }
        /// Language name (localized).
        let language: String
        /// ISO language code (e.g., "en").
        let languageCode: String
        /// Emoji flag for UI.
        let flag: String
    }
    
    /// Available streams by language.
    /// - Note: Static array; URLs must be HTTPS for security.
    static let availableStreams = [
        Stream(title: NSLocalizedString("lutheran_radio_title", comment: "Title for Lutheran Radio") + " - " +
               NSLocalizedString("language_english", comment: "English language option"),
               language: NSLocalizedString("language_english", comment: "English language option"),
               languageCode: "en",
               flag: "🇺🇸"),
        Stream(title: NSLocalizedString("lutheran_radio_title", comment: "Title for Lutheran Radio") + " - " +
               NSLocalizedString("language_german", comment: "German language option"),
               language: NSLocalizedString("language_german", comment: "German language option"),
               languageCode: "de",
               flag: "🇩🇪"),
        Stream(title: NSLocalizedString("lutheran_radio_title", comment: "Title for Lutheran Radio") + " - " +
               NSLocalizedString("language_finnish", comment: "Finnish language option"),
               language: NSLocalizedString("language_finnish", comment: "Finnish language option"),
               languageCode: "fi",
               flag: "🇫🇮"),
        Stream(title: NSLocalizedString("lutheran_radio_title", comment: "Title for Lutheran Radio") + " - " +
               NSLocalizedString("language_swedish", comment: "Swedish language option"),
               language: NSLocalizedString("language_swedish", comment: "Swedish language option"),
               languageCode: "sv",
               flag: "🇸🇪"),
        Stream(title: NSLocalizedString("lutheran_radio_title", comment: "Title for Lutheran Radio") + " - " +
               NSLocalizedString("language_estonian", comment: "Estonian language option"),
               language: NSLocalizedString("language_estonian", comment: "Estonian language option"),
               languageCode: "et",
               flag: "🇪🇪"),
    ]
    
    private let audioSession: AVAudioSession
    private let pathMonitor: NetworkPathMonitoring
    
    // MARK: - Enhanced SSL Protection with Connection Tracking
    /// Per-connection info for SSL handshake protection.
    /// - Note: Migrated from `Timer` to `Task<Void, Never>` for Swift 6 Sendable compliance and better cancellation.
    ///   Invariant: `task` fires once after delay, marks `isHandshakeComplete = true` unless cancelled.
    private struct ConnectionInfo: Sendable {
        let id: UUID
        let startTime: Date
        let task: Task<Void, Never>
        var isHandshakeComplete: Bool = false
    }
    
    // Dictionary to track multiple connections
    private var activeConnections: [UUID: ConnectionInfo] = [:]
    private let connectionQueue = DispatchQueue(label: "ssl.connections", qos: .userInitiated)
    
    #if DEBUG
    var isTesting: Bool = false
    #else
    private var isTesting: Bool = false
    #endif
    
    private var lastServerSelectionTime: Date?
    private let serverSelectionCacheDuration: TimeInterval = 7200 // two hours
    #if DEBUG
    var serverSelectionWorkItem: DispatchWorkItem?
    #else
    private var serverSelectionWorkItem: DispatchWorkItem?
    #endif
    
    // MARK: - Playback and Retry Management
    #if DEBUG
    var retryWorkItem: DispatchWorkItem?
    #else
    private var retryWorkItem: DispatchWorkItem?
    #endif
    private var fallbackWorkItem: DispatchWorkItem?
    /// Work item for pending playback operations that can be cancelled
    private var pendingPlaybackWorkItem: DispatchWorkItem?
    
    /// Track deallocation state
    private var isDeallocating = false
    
    /// Selects the optimal streaming server based on latency and failures.
    /// - Parameter completion: Handler with selected server.
    /// - Note: Throttles calls; prefers servers with fewer failures; delays in low-power mode.
    /// - Example: `selectOptimalServer { server in print(server.name) }`
    /// - SeeAlso: `fetchServerIPsAndLatencies(completion:)`
    func selectOptimalServer(completion: @escaping (Server) -> Void) {
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
                
                completion(betterServer)
                return
            }
        }
        
        guard lastServerSelectionTime == nil || Date().timeIntervalSince(lastServerSelectionTime!) > 10.0 else {
            #if DEBUG
            print("📡 selectOptimalServer: Throttling server selection, using cached server: \(currentSelectedServer.name)")
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
                    
                    #if DEBUG
                    print("📡 [Server Selection] Selected \(bestResult.server.name) with latency \(bestResult.latency)s")
                    #endif
                } else {
                    self.currentSelectedServer = Self.servers[0]
                    
                    // Fire-and-forget save
                    Task {
                        await SharedPlayerManager.shared.saveCurrentState()
                    }
                    
                    #if DEBUG
                    print("📡 [Server Selection] No valid ping results, falling back to \(self.currentSelectedServer.name)")
                    #endif
                }
                
                completion(self.currentSelectedServer)
            }
        }
        
        serverSelectionWorkItem = workItem
        let selectionDelay: TimeInterval = isLowEfficiencyMode ? 1.0 : 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + selectionDelay, execute: workItem)
    }
    
    public enum PlaybackState {
        case unknown
        case readyToPlay
        case failed(Error?)
    }
    
    private var lastError: Error?
        
    public func getPlaybackState() -> PlaybackState {
        switch player?.currentItem?.status {
        case .unknown:
            return .unknown
        case .readyToPlay:
            return .readyToPlay
        case .failed:
            return .failed(player?.currentItem?.error)
        default:
            return .unknown
        }
    }
    
    var isPlaying: Bool {
        return (player?.rate ?? 0) > 0 && player?.currentItem?.status == .readyToPlay
    }
    
    #if DEBUG
    var selectedStream: Stream {
        didSet {
            if delegate != nil {
                safeOnMetadataChange(metadata: selectedStream.title)
            }
        }
    }
    #else
    private(set) var selectedStream: Stream {
        didSet {
            if delegate != nil {
                safeOnMetadataChange(metadata: selectedStream.title)
            }
        }
    }
    #endif
    
    // MARK: - Public State Accessors
    var currentPlayerRate: Float {
        return player?.rate ?? 0.0
    }

    var currentItemStatus: AVPlayerItem.Status {
        return player?.currentItem?.status ?? .unknown
    }

    var hasPlayerItem: Bool {
        return player?.currentItem != nil
    }

    var actualPlaybackState: Bool {
        return currentPlayerRate > 0.1 &&
               currentItemStatus == .readyToPlay &&
               hasPlayerItem &&
               !hasPermanentError
    }
    
    #if DEBUG
    var player: AVPlayer?
    var playerItem: AVPlayerItem?
    var metadataOutput: AVPlayerItemMetadataOutput?
    // Audio processing at highest priority
    private let audioQueue = DispatchQueue(label: "radio.lutheran.audio", qos: .userInteractive)
    // SSL operations at supporting priority
    private let sslValidationQueue = DispatchQueue(label: "radio.lutheran.ssl", qos: .userInitiated)
    //*********private let dnsQueue = DispatchQueue(label: "radio.lutheran.dns", qos: .userInitiated)
    // Network operations at background priority
    private let networkQueue = DispatchQueue(label: "radio.lutheran.network", qos: .utility)
    // Keep playbackQueue for compatibility, but redirect to audioQueue
    let playbackQueue = DispatchQueue(label: "radio.lutheran.playback", qos: .userInteractive)
    #else
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var metadataOutput: AVPlayerItemMetadataOutput?
    // Audio processing at highest priority
    private let audioQueue = DispatchQueue(label: "radio.lutheran.audio", qos: .userInteractive)
    // SSL operations at supporting priority
    private let sslValidationQueue = DispatchQueue(label: "radio.lutheran.ssl", qos: .userInitiated)
    // Network operations at background priority
    private let networkQueue = DispatchQueue(label: "radio.lutheran.network", qos: .utility)
    // Keep playbackQueue for compatibility, but redirect to audioQueue
    private let playbackQueue = DispatchQueue(label: "radio.lutheran.playback", qos: .userInteractive)
    #endif
    
    // MARK: - Queue Priority Management
    
    /// Escalates queue priority when audio operations are blocked
    private func executeWithAudioPriority<T>(
        _ operation: @escaping @Sendable () -> T,
        completion: @escaping @Sendable (T) -> Void
    ) {
        if player?.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            // Audio is waiting - escalate to highest priority
            DispatchQueue.global(qos: .userInteractive).async {
                let result = operation()
                DispatchQueue.main.async {
                    completion(result)
                }
            }
        } else {
            // Normal priority
            sslValidationQueue.async {
                let result = operation()
                DispatchQueue.main.async {
                    completion(result)
                }
            }
        }
    }
    
    // CRITICAL: All AVPlayer operations must be on main thread
    private func executeAudioOperation<T>(
        _ operation: @escaping @Sendable () -> T,
        completion: @escaping @Sendable (T) -> Void
    ) {
        // Always execute AVPlayer operations on main thread
        DispatchQueue.main.async {
            let result = operation()
            completion(result)
        }
    }
    
    #if DEBUG
    private func logQueueHierarchy() {
        print("🔧 [QoS] Audio Queue: .userInteractive")
        print("🔧 [QoS] SSL Queue: .userInitiated")
        print("🔧 [QoS] Network Queue: .utility")
        print("🔧 [QoS] Playback Queue: .userInteractive (redirected to audio)")
    }
    #endif
    
    var hasPermanentError: Bool = false
    private var rateObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    /// Tracks whether a stream switch is in progress to suppress unnecessary "stopped" status updates.
    /// - Note: Set to `true` by `ViewController` before stopping playback during a stream switch and reset to `false` after playback resumes. Used in `stop` to determine if status updates should be suppressed.
    /// - Access: `internal` to allow coordination with `ViewController` within the module; not intended for external use.
    var isSwitchingStream = false // Track ongoing stream switches
    private var timeObserver: Any?
    private var timeObserverPlayer: AVPlayer? // Track the player that added the time observer
    private var playerItemObservations: [NSKeyValueObservation] = []  // Store all playerItem observations
    private var bufferingTimer: Timer?
    private var activeResourceLoaders: [AVAssetResourceLoadingRequest: StreamingSessionDelegate] = [:] // Track resource loaders
    
    private weak var currentLoadingDelegate: StreamingSessionDelegate?   // weak to avoid retain cycles
    private var loadingTimeoutWorkItem: DispatchWorkItem?
    
    var onStatusChange: ((Bool, String) -> Void)?
    var onMetadataChange: ((String?) -> Void)?
    internal var currentMetadata: String?
    
    // MARK: - Safe callbacks to MainActor (Swift 6 fix)
    func safeOnStatusChange(isPlaying: Bool, status: String) {
        DispatchQueue.main.async {  // Ensure main-thread safety for UI/delegate calls
            if self.isInitializing {
                self.pendingStatusChanges.append((isPlaying, status))
            } else {
                self.invokeStatusCallbacks(isPlaying: isPlaying, status: status)
                
                // Fire-and-forget async save (does not block UI/delegate callbacks)
                Task {
                    await SharedPlayerManager.shared.saveCurrentState()
                }
            }
        }
    }
    
    private func invokeStatusCallbacks(isPlaying: Bool, status: String) {
        onStatusChange?(isPlaying, status)
        delegate?.onStatusChange(isPlaying ? .playing : .stopped, status)  // Map to enum, pass status as reason
    }
    
    private func safeOnMetadataChange(metadata: String?) {
        Task { @MainActor [weak self] in
            self?.onMetadataChange?(metadata)
        }
    }
    
    weak var delegate: StreamingPlayerDelegate?
    
    /// Sets the delegate for callbacks (e.g., status updates).
    func setDelegate(_ delegate: StreamingPlayerDelegate?) {
        self.delegate = delegate
    }
    
    private func performConnectivityCheck(completion: @escaping BoolCompletion) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3.0
        let session = URLSession(configuration: config)
        let url = URL(string: "https://www.apple.com/library/test/success.html")!
        let task = session.dataTask(with: url) { data, response, error in
            let isConnected = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
            #if DEBUG
            print("🔒 [Connectivity Check] Result: \(isConnected ? "Connected" : "Disconnected"), error: \(error?.localizedDescription ?? "None")")
            #endif
            DispatchQueue.main.async {
                completion(isConnected)
            }
        }
        task.resume()
    }
    
    public func resetTransientErrors() {
        // Reset transient state in the shared validator
        // (Permanent failures stay permanent until app restart or model rotation)
        Task {
            await SecurityModelValidator.shared.resetTransientState()
        }
        
        // Also clear any local permanent error flag if your UI/playback uses it
        hasPermanentError = false
        
        #if DEBUG
        print("🔄 Requested reset of transient security validation state")
        #endif
    }

    func isLastErrorPermanent() async -> Bool {
        await SecurityModelValidator.shared.isPermanentlyInvalid
    }
    
    private override init() {
        self.audioSession = .sharedInstance()
        self.pathMonitor = NWPathMonitorAdapter()
        
        let currentLocale = Locale.current
        let languageCode = currentLocale.language.languageCode?.identifier
        
        if let stream = Self.availableStreams.first(where: { $0.languageCode == languageCode }) {
            selectedStream = stream
        } else {
            selectedStream = Self.availableStreams[0]
        }
        
        #if DEBUG
        isTesting = NSClassFromString("XCTestCase") != nil
        #endif
        
        super.init()
        
        setupAudioSession()
        setupNetworkMonitoring()
        
        #if DEBUG
        print("🎵 Player initialized, starting validation")
        #endif
        
        if hasInternetConnection {
            Task { @MainActor in
                let isValid = await SecurityModelValidator.shared.validateSecurityModel()
                
                #if DEBUG
                print("🔒 Initial validation completed: \(isValid)")
                #endif
                
                if isValid {
                    self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_connecting"))
                } else {
                    let isPermanent = await SecurityModelValidator.shared.isPermanentlyInvalid
                    let statusKey = isPermanent ? "status_security_failed" : "status_no_internet"
                    let localizedStatus = String(localized: String.LocalizationValue(statusKey))
                    self.safeOnStatusChange(isPlaying: false, status: localizedStatus)
                    
                    #if DEBUG
                    print("🔒 Validation failed — permanent? \(isPermanent)")
                    #endif
                }
            }
        } else {
            // No internet at init → transient failure state
            safeOnStatusChange(isPlaying: false, status: String(localized: "status_no_internet"))
        }
        
        #if DEBUG
        logQueueHierarchy()
        #endif
        
        setupThermalProtection()
        
        isInitializing = false
        
        DispatchQueue.main.async {  // Defer to after init returns
            for change in self.pendingStatusChanges {
                self.invokeStatusCallbacks(isPlaying: change.isPlaying, status: change.status)
            }
            self.pendingStatusChanges = []
            
            // Fire-and-forget the final state save (post-init, no blocking needed)
            Task {
                await SharedPlayerManager.shared.saveCurrentState()
            }
        }
    }
    
    #if DEBUG
    private func setupNetworkMonitoring() {
        networkMonitor = pathMonitor
        networkMonitor?.pathUpdateHandler = { [weak self] status in
            guard let self else {
                print("🧹 [Network] Skipped path update: self is nil")
                return
            }
            
            let wasConnected = self.hasInternetConnection
            self.hasInternetConnection = status == .satisfied
            
            print("🌐 [Network] Status: \(self.hasInternetConnection ? "Connected" : "Disconnected")")
            
            if self.hasInternetConnection && !wasConnected {
                // ── Reconnect case ──
                print("🌐 [Network] Connection restored, previous server: \(self.currentSelectedServer.name)")
                
                // Clear server selection cache
                self.lastServerSelectionTime = nil
                self.serverFailureCount.removeAll()
                print("🌐 [Network] Cleared server selection cache + failure counts")
                
                // Reset transient security state + revalidate
                Task {
                    await SecurityModelValidator.shared.resetTransientState()
                    print("🔒 [Network] Invalidated security model validation cache (transient reset)")
                    
                    let isValid = await SecurityModelValidator.shared.validateSecurityModel()
                    print("🔒 [Network] Revalidation result on reconnect: \(isValid)")
                    
                    if !isValid {
                        let isPermanent = await SecurityModelValidator.shared.isPermanentlyInvalid
                        
                        let statusKey = isPermanent ? "status_security_failed" : "status_no_internet"
                        
                        DispatchQueue.main.async {
                            self.safeOnStatusChange(
                                isPlaying: false,
                                status: String(localized: String.LocalizationValue(statusKey))
                            )
                        }
                    } else if self.player?.rate ?? 0 == 0, !self.hasPermanentError {
                        // Auto-replay if previously playing / ready
                    } else if self.player?.rate ?? 0 == 0, !self.hasPermanentError {
                        // Auto-replay if previously playing / ready
                        
                        Task { @MainActor in   // ← important: ensure we run on the right actor
                            do {
                                try await self.play()   // ← now async throws, no completion
                                
                                let playStatusKey = "status_playing"
                                await MainActor.run {   // or just self.safeOnStatusChange since we're already @MainActor
                                    self.safeOnStatusChange(
                                        isPlaying: true,
                                        status: String(localized: String.LocalizationValue(playStatusKey))
                                    )
                                }
                            } catch {
                                let playStatusKey = "status_stream_unavailable"
                                await MainActor.run {
                                    self.safeOnStatusChange(
                                        isPlaying: false,
                                        status: String(localized: String.LocalizationValue(playStatusKey))
                                    )
                                }
                                // Optionally log the error
                                print("Auto-replay failed: \(error)")
                            }
                        }
                    }
                }
                
                // Select optimal server after reconnect
                self.selectOptimalServer { server in
                    print("🌐 [Network] New server selected: \(server.name)")
                    // Any additional post-selection logic here if needed
                }
            }
            else if !self.hasInternetConnection && wasConnected {
                // ── Disconnect case ──
                print("🌐 [Network] Connection lost")
                
                DispatchQueue.main.async {
                    self.safeOnStatusChange(
                        isPlaying: false,
                        status: String(localized: String.LocalizationValue("status_no_internet"))
                    )
                }
            }
        }
        networkMonitor?.start(queue: networkQueue)
    }
    #else
    // MARK: - Network and Monitoring
    public func setupNetworkMonitoring() {
        networkMonitor = pathMonitor
        networkMonitor?.pathUpdateHandler = { [weak self] status in
            guard let self else {
                print("🧹 [Network] Skipped path update: self is nil")
                return
            }
            
            let wasConnected = self.hasInternetConnection
            self.hasInternetConnection = status == .satisfied
            
            print("🌐 [Network] Status: \(self.hasInternetConnection ? "Connected" : "Disconnected")")
            
            if self.hasInternetConnection && !wasConnected {
                // ── Reconnect case ──
                print("🌐 [Network] Connection restored, previous server: \(self.currentSelectedServer.name)")
                
                // Clear server selection cache
                self.lastServerSelectionTime = nil
                self.serverFailureCount.removeAll()
                print("🌐 [Network] Cleared server selection cache + failure counts")
                
                // Reset transient security state + revalidate
                Task {
                    await SecurityModelValidator.shared.resetTransientState()
                    print("🔒 [Network] Invalidated security model validation cache (transient reset)")
                    
                    let isValid = await SecurityModelValidator.shared.validateSecurityModel()
                    print("🔒 [Network] Revalidation result on reconnect: \(isValid)")
                    
                    if !isValid {
                        let isPermanent = await SecurityModelValidator.shared.isPermanentlyInvalid
                        
                        let statusKey = isPermanent ? "status_security_failed" : "status_no_internet"
                        
                        DispatchQueue.main.async {
                            self.safeOnStatusChange(
                                isPlaying: false,
                                status: String(localized: String.LocalizationValue(statusKey))
                            )
                        }
                    } else if self.player?.rate ?? 0 == 0, !self.hasPermanentError {
                        // Auto-replay if previously playing / ready
                    } else if self.player?.rate ?? 0 == 0, !self.hasPermanentError {
                        // Auto-replay if previously playing / ready
                        
                        Task { @MainActor in   // ← important: ensure we run on the right actor
                            do {
                                try await self.play()   // ← now async throws, no completion
                                
                                let playStatusKey = "status_playing"
                                await MainActor.run {   // or just self.safeOnStatusChange since we're already @MainActor
                                    self.safeOnStatusChange(
                                        isPlaying: true,
                                        status: String(localized: String.LocalizationValue(playStatusKey))
                                    )
                                }
                            } catch {
                                let playStatusKey = "status_stream_unavailable"
                                await MainActor.run {
                                    self.safeOnStatusChange(
                                        isPlaying: false,
                                        status: String(localized: String.LocalizationValue(playStatusKey))
                                    )
                                }
                                // Optionally log the error
                                print("Auto-replay failed: \(error)")
                            }
                        }
                    }
                }
                
                // Select optimal server after reconnect
                self.selectOptimalServer { server in
                    print("🌐 [Network] New server selected: \(server.name)")
                    // Any additional post-selection logic here if needed
                }
            }
            else if !self.hasInternetConnection && wasConnected {
                // ── Disconnect case ──
                print("🌐 [Network] Connection lost")
                
                DispatchQueue.main.async {
                    self.safeOnStatusChange(
                        isPlaying: false,
                        status: String(localized: String.LocalizationValue("status_no_internet"))
                    )
                }
            }
        }
        networkMonitor?.start(queue: networkQueue)
    }
    #endif
    
    private func setupThermalProtection() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            
            let currentState = ProcessInfo.processInfo.thermalState
            
            if currentState == .critical || currentState == .serious {
                // Pause if device temperature critical or serious
                if self.isPlaying {
                    self.wasPlayingBeforeThermal = true
                    
                    Task { @MainActor in
                        await self.stop()
                        self.safeOnStatusChange(
                            isPlaying: false,
                            status: String(localized: String.LocalizationValue(stringLiteral: "status_thermal_paused"))
                        )
                    }
                }
            } else if self.wasPlayingBeforeThermal &&
                      (currentState == .nominal || currentState == .fair) {
                // Resume when the device has actually cooled down to a safe temperature
                self.wasPlayingBeforeThermal = false
                
                Task { @MainActor in
                    do {
                        try await self.play()
                        // If play() returns success Bool, you can use it:
                        // let success = try await self.play()
                        // then conditionally update status
                        
                        self.safeOnStatusChange(
                            isPlaying: true,
                            status: String(localized: String.LocalizationValue(stringLiteral: "status_playing"))
                        )
                    } catch {
                        self.safeOnStatusChange(
                            isPlaying: false,
                            status: String(localized: String.LocalizationValue(stringLiteral: "status_stream_unavailable"))
                        )
                        print("Thermal resume play failed: \(error)")
                    }
                }
            }
        }
    }
    
    init(audioSession: AVAudioSession = .sharedInstance(), pathMonitor: NetworkPathMonitoring = NWPathMonitorAdapter()) {
        self.audioSession = audioSession
        self.pathMonitor = pathMonitor
        
        let currentLocale = Locale.current
        let languageCode = currentLocale.language.languageCode?.identifier
        
        if let stream = Self.availableStreams.first(where: { $0.languageCode == languageCode }) {
            selectedStream = stream
        } else {
            selectedStream = Self.availableStreams[0]
        }
        
        #if DEBUG
        isTesting = NSClassFromString("XCTestCase") != nil
        #endif
        
        super.init()
        
        setupAudioSession()
        setupNetworkMonitoring()
        
        // Observe Low Power Mode changes to dynamically adjust optimizations
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(energyEfficiencyChanged),
            name: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"),
            object: nil
        )
        
        #if DEBUG
        print("🎵 Player initialized, starting validation")
        #endif
        
        if hasInternetConnection {
            Task { @MainActor in
                let isValid = await SecurityModelValidator.shared.validateSecurityModel()
                
                #if DEBUG
                print("🔒 Initial validation completed: \(isValid)")
                #endif
                
                if isValid {
                    self.safeOnStatusChange(isPlaying: false, status: String(localized: String.LocalizationValue("status_connecting")))
                } else {
                    // Optional: show appropriate failure state
                    let isPermanent = await SecurityModelValidator.shared.isPermanentlyInvalid
                    let statusKey = isPermanent ? "status_security_failed" : "status_no_internet"
                    self.safeOnStatusChange(
                        isPlaying: false,
                        status: String(localized: String.LocalizationValue(statusKey))
                    )
                }
            }
        }
    }
    
    /// Handles changes to Low Power Mode state.
    /// No immediate actions here; optimizations (e.g., longer retry intervals) are applied dynamically via isLowEfficiencyMode checks.
    /// This reduces unnecessary work in low-battery scenarios without interrupting core streaming.
    @objc private func energyEfficiencyChanged() {
        // No immediate action needed; the isLowEfficiencyMode property will be queried dynamically in retry/fallback spots
        #if DEBUG
        print("🔋 Low Power Mode changed to: \(isLowEfficiencyMode ? "Enabled" : "Disabled")")
        #endif
    }
    
    func setupAudioSession() {
        guard !isTesting else {
            #if DEBUG
            print("🔊 Skipped audio session setup for tests")
            #endif
            return
        }
        
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback {
            do {
                try audioSession.setCategory(.playback, mode: .default, options: [])
                try audioSession.setActive(true)
                #if DEBUG
                print("🔊 Audio session configured")
                #endif
            } catch {
                #if DEBUG
                print("🔊 Failed to configure audio session: \(error.localizedDescription)")
                #endif
            }
        }
    }
    
    /// Starts periodic certificate validation against the *currently preferred* URL
    /// (automatically follows server selection changes – if the app switches to a better cluster,
    /// the next validation will check the new cluster’s cert. Since both clusters use the same cert,
    /// this is safe and gives us early detection if one cluster ever diverges).
    private func startPeriodicValidation() {
        certificateValidationTimer?.invalidate()
        certificateValidationTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            guard let self else { return }
            
            let urlToValidate = self.selectedStream.url   // always valid, includes current server + security_model
            
            // 2026 concurrency model: fire-and-forget background validation
            // Playback continues optimistically; we only stop if validation later fails.
            Task {
                let isValid = await CertificateValidator.shared.validateServerCertificate(for: urlToValidate)
                
                guard !isValid else { return }
                
                await MainActor.run {
                    self.stop()
                    self.safeOnStatusChange(isPlaying: false, status: String(localized: String.LocalizationValue("status_security_failed")))
                }
                
                #if DEBUG
                print("🔒 [Periodic Validation] Certificate validation failed → stopping stream for URL: \(urlToValidate)")
                #endif
            }
        }
    }
    
    // MARK: - Playback Control Methods

    /// Starts or resumes playback after validation and server selection.
    /// - Returns: `true` if playback was successfully *initiated* (item replaced + play() called).
    ///            Note: Actual audio may start slightly later when the item becomes readyToPlay.
    /// - Throws: Only critical unrecoverable errors (rare).
    @MainActor
    func play() async -> Bool {
        // === CRITICAL GUARD: Respect PlayerVisualState user intent ===
        // This prevents "play-on-pause resurrection" after user explicitly pauses
        guard await shouldAutoPlayOrResume else {
            #if DEBUG
            print("🚫 [Play Guard] Blocked resurrection — currentVisualState is .userPaused")
            #endif
            safeOnStatusChange(isPlaying: false, status: "UserPaused")
            return false
        }

        guard !isCurrentlyAttemptingPlayback else {
            #if DEBUG
            print("⚠️ [Playback Guard] Already attempting playback — ignoring duplicate call")
            #endif
            return false
        }

        isCurrentlyAttemptingPlayback = true
        defer { isCurrentlyAttemptingPlayback = false }

        safeOnStatusChange(isPlaying: true, status: String(localized: "status_connecting"))
        SharedPlayerManager.shared.saveFireAndForget()

        let isValid = await SecurityModelValidator.shared.isCurrentlyValid()
        guard isValid else {
            let isPermanent = await SecurityModelValidator.shared.isPermanentlyInvalid
            let statusKey = isPermanent ? "status_security_failed" : "status_no_internet"
            safeOnStatusChange(isPlaying: false, status: String(localized: String.LocalizationValue(statusKey)))
            SharedPlayerManager.shared.saveFireAndForget()
            return false
        }
        
        #if DEBUG
        print("✅ Security validation passed — creating player for \(selectedStream.languageCode)")
        #endif
        
        let streamURL = selectedStream.url
        await createAndStartPlayer(for: streamURL)

        await SharedPlayerManager.shared.saveCurrentState()
        return true
    }
    
    // MARK: - Main-Actor-Bound Player Creation (Swift 6 safe)

    @MainActor
    private func createAndStartPlayer(for url: URL) async {
        // === DEEP CRITICAL GUARD: Respect PlayerVisualState user intent ===
        // This catches all internal/resume paths that bypass the public play() method
        // (stream switches, tuning sound completion, audio session reactivation, etc.)
        guard await shouldAutoPlayOrResume else {
            #if DEBUG
            print("🚫 [Deep Play Guard] Blocked AVPlayer creation/resume — currentVisualState is .userPaused")
            #endif
            safeOnStatusChange(isPlaying: false, status: "UserPaused")
            return
        }

        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: .main)

        let playerItem = AVPlayerItem(asset: asset)
        self.playerItem = playerItem

        if self.player == nil {
            self.player = AVPlayer(playerItem: playerItem)
        } else {
            self.player?.replaceCurrentItem(with: playerItem)
        }

        // === CRITICAL: Activate the audio session before playback ===
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback,
                                    mode: .default,
                                    options: [.allowAirPlay, .defaultToSpeaker])
            
            try session.setActive(true)
            
            #if DEBUG
            print("🔊 [MainActor] AVAudioSession activated successfully (.playback)")
            #endif
        } catch {
            #if DEBUG
            print("❌ [MainActor] Failed to activate AVAudioSession: \(error.localizedDescription)")
            #endif
        }
        // ========================================================
        
        self.player?.play()

        #if DEBUG
        print("▶️ [MainActor] AVPlayer created + play() called for \(url.lastPathComponent ?? url.absoluteString)")
        #endif

        // Do NOT call notifyMainApp here — let SharedPlayerManager do it
    }
    
    @MainActor
    private func preparePlayerItem(for url: URL) async {
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: .main)
        
        let playerItem = AVPlayerItem(asset: asset)
        
        if self.player == nil {
            self.player = AVPlayer(playerItem: playerItem)
        } else {
            self.player?.replaceCurrentItem(with: playerItem)
        }
        self.playerItem = playerItem
        
        setupPlaybackObservers()
        
        #if DEBUG
        print("🔄 [MainActor] Player item prepared (no auto-play) for \(url.lastPathComponent ?? url.absoluteString)")
        #endif
    }

    // MARK: - Playback Setup (MainActor preferred path)

    @MainActor
    private func performOptimalServerSelectionAndFullPlaybackSetup() async -> Bool {
        #if DEBUG
        print("🔊 [Playback Setup] Starting server selection + asset creation")
        #endif

        return await withCheckedContinuation { continuation in
            selectOptimalServer { [weak self] _ in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }

                let streamURL = self.selectedStream.url

                #if DEBUG
                print("🔊 [Playback Setup] Selected URL: \(streamURL)")
                #endif

                // Everything that touches AVPlayer must run on MainActor
                Task { @MainActor [weak self] in
                    guard let self else {
                        continuation.resume(returning: false)
                        return
                    }

                    // 1. Audio Session (critical!)
                    do {
                        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                        try AVAudioSession.sharedInstance().setActive(true)
                    } catch {
                        #if DEBUG
                        print("❌ AudioSession failed: \(error)")
                        #endif
                        continuation.resume(returning: false)
                        return
                    }

                    // 2. Asset + Resource Loader
                    let asset = AVURLAsset(url: streamURL)
                    asset.resourceLoader.setDelegate(self, queue: .main)

                    let playerItem = AVPlayerItem(asset: asset)

                    if self.player == nil {
                        self.player = AVPlayer()
                    }

                    self.player?.replaceCurrentItem(with: playerItem)
                    self.playerItem = playerItem

                    // 3. Setup observers — BEFORE play()
                    self.setupPlaybackObservers()

                    // 4. Explicit play() — guaranteed on MainActor
                    self.player?.play()

                    #if DEBUG
                    print("▶️ [Playback Setup] replaceCurrentItem + play() called on main actor")
                    #endif

                    // We consider initiation successful here.
                    continuation.resume(returning: true)
                }
            }
        }
    }

    // MARK: - Observers

    @MainActor
    private func setupPlaybackObservers() {
        // Invalidate old ones first to avoid leaks/duplicates
        rateObserver?.invalidate()
        statusObserver?.invalidate()

        rateObserver = player?.observe(\.rate, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            #if DEBUG
            print("🔊 [KVO] Rate changed to \(player.rate)")
            #endif
            if player.rate > 0 {
                self.safeOnStatusChange(isPlaying: true, status: String(localized: "status_playing"))
            } else {
                self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_stopped"))
            }
            Task { await SharedPlayerManager.shared.saveCurrentState() }
        }

        statusObserver = player?.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            #if DEBUG
            print("🔊 [KVO] Item status → \(item.status.rawValue)")
            #endif
            switch item.status {
            case .readyToPlay:
                self.safeOnStatusChange(isPlaying: true, status: String(localized: "status_playing"))
            case .failed:
                self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_stream_unavailable"))
                if let error = item.error {
                    self.handlePlaybackError(error)
                }
            default: break
            }
            Task { await SharedPlayerManager.shared.saveCurrentState() }
        }
    }

    // MARK: - Legacy Playback Path (kept for compatibility)

    /// Legacy / fallback playback setup path.
    /// Prefer `performOptimalServerSelectionAndFullPlaybackSetup()` when possible.
    private func performOptimalServerSelectionAndCertificateCheck() {
        #if DEBUG
        print("🔊 [Playback Start] performOptimalServerSelectionAndCertificateCheck entered")
        #endif

        selectOptimalServer { [weak self] _ in
            guard let self else { return }

            #if DEBUG
            print("🔊 [Playback Start] selectOptimalServer closure entered — building asset")
            #endif

            let streamURL = self.selectedStream.url

            // All AVPlayer work must happen on the main actor
            Task { @MainActor [weak self] in
                guard let self else { return }

                #if DEBUG
                print("🔊 [Playback Start] Running on @MainActor — setting up player")
                #endif

                // 1. Ensure player exists
                if self.player == nil {
                    self.player = AVPlayer()
                    #if DEBUG
                    print("🔊 [Playback Start] Created new AVPlayer()")
                    #endif
                }

                // 2. Create asset + set resource loader delegate
                let asset = AVURLAsset(url: streamURL)
                asset.resourceLoader.setDelegate(self, queue: .main)

                let newItem = AVPlayerItem(asset: asset)

                // 3. Replace current item and start playback (on MainActor)
                self.player?.replaceCurrentItem(with: newItem)
                self.playerItem = newItem

                #if DEBUG
                print("🔊 [Playback Start] replaceCurrentItem called")
                #endif

                self.player?.play()

                #if DEBUG
                print("▶️ AVPlayer.play() called directly on @MainActor")
                #endif

                // 4. Setup observers (idempotent)
                self.setupPlaybackObservers()

                // 5. Immediate feedback
                if self.isPlaying {
                    self.delegate?.onStatusChange(.playing, nil)
                } else {
                    #if DEBUG
                    print("🔊 [Playback Start] Playback initiated — waiting for readyToPlay via KVO")
                    #endif
                }
            }

            // Background certificate validation – does NOT block playback
            Task { [weak self] in
                guard let self else { return }
                let isValid = await CertificateValidator.shared.validateServerCertificate(for: streamURL)

                if !isValid {
                    await MainActor.run {
                        self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_security_failed"))
                        self.stop()
                    }
                } else {
                    #if DEBUG
                    print("🔒 [Playback Start] Certificate validation passed in background")
                    #endif
                }
            }
        }
    }

    // MARK: - Stream Switching (the simpler fallback)

    func switchToStream(_ stream: Stream) async {
        let wasPlaying = isPlaying
        
        await stop()
        resetTransientErrors()
        selectedStream = stream
        
        let url = selectedStream.url
        await preparePlayerItem(for: url)
        
        // Force playback with explicit rate on main actor
        await MainActor.run {
            let newItem = AVPlayerItem(url: url)
            self.player?.replaceCurrentItem(with: newItem)
            self.player?.rate = 1.0
            
            #if DEBUG
            print("▶️ AVPlayer rate set to 1.0 from switchToStream on main thread")
            #endif
        }
        
        await SharedPlayerManager.shared.saveCurrentState()
    }
    
    private func playWithServer(fallbackServers: [Server], completion: @escaping BoolCompletion) {
        lastServerSelectionTime = Date()
        #if DEBUG
        print("📡 Attempting playback with server: \(currentSelectedServer.name)")
        #endif
        
        let streamURL = selectedStream.url
        
        // 2026 concurrency model: fire-and-forget background validation
        // (validation no longer blocks; completion is still called exactly as before)
        Task { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            
            let isValid = await CertificateValidator.shared.validateServerCertificate(for: streamURL)
            
            guard isValid else {
                self.safeOnStatusChange(isPlaying: false, status: String(localized: String.LocalizationValue("status_security_failed")))
                self.tryNextServer(fallbackServers: fallbackServers, completion: completion)
                return
            }
            
            self.startPlaybackWithFallback(fallbackServers: fallbackServers, completion: completion)
        }
    }

    private func tryNextServer(fallbackServers: [Server], completion: @escaping BoolCompletion) {
        guard let nextServer = fallbackServers.first else {
            self.safeOnStatusChange(isPlaying: false, status: String(localized: String.LocalizationValue("status_stream_unavailable")))
            completion(false)
            return
        }
        
        // Switch to next server → this automatically makes selectedStream.url point to the new cluster
        self.currentSelectedServer = nextServer
        self.serverFailureCount[nextServer.name, default: 0] += 1
        
        #if DEBUG
        print("📡 Falling back to server: \(nextServer.name)")
        #endif
        
        playWithServer(fallbackServers: Array(fallbackServers.dropFirst()), completion: completion)
    }
    
    // MARK: - Stream Switching (now the single source of truth)
    func setStream(to stream: Stream) async {
        let previousLanguage = selectedStream.languageCode ?? "nil"
        let newLanguage = stream.languageCode ?? "??"

        #if DEBUG
        print("ATOMIC STREAM SWITCH: \(previousLanguage) → \(newLanguage)")
        #endif

        // === FIXED: Only stop if it's a REAL different-stream switch ===
        if previousLanguage != newLanguage {
            #if DEBUG
            print("🔄 Real stream switch detected (\(previousLanguage) → \(newLanguage)) – performing clean stop")
            #endif

            isSwitchingStream = true
            defer { isSwitchingStream = false }

            await stop()

            // Update model + save
            selectedStream = stream
            await SharedPlayerManager.shared.saveCurrentState()
        } else {
            #if DEBUG
            print("🔄 Same stream or initial playback (\(newLanguage)) – skipping stop()")
            #endif

            // Still update/save in case this is the very first playback
            selectedStream = stream
            await SharedPlayerManager.shared.saveCurrentState()
        }

        // Security validation (left completely untouched)
        guard await SecurityModelValidator.shared.validateSecurityModel() else {
            #if DEBUG
            print("❌ Security validation failed after stream switch")
            #endif
            safeOnStatusChange(
                isPlaying: false,
                status: NSLocalizedString("status_stream_unavailable", comment: "")
            )
            return
        }

        // Success path – reliable AVFoundation sequence
        await MainActor.run {
            let newItem = AVPlayerItem(url: stream.url)
            
            self.player?.replaceCurrentItem(with: newItem)
            self.playerItem = newItem   // critical
            
            // Do NOT call addObservers() here anymore — let createAndStartPlayer or a single setup handle it
            
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setActive(true)
            } catch {
                #if DEBUG
                print("⚠️ Could not reactivate AVAudioSession: \(error)")
                #endif
            }

            self.player?.play()
            self.player?.rate = 1.0

            #if DEBUG
            print("▶️ AVPlayer started via .play() + rate=1.0")
            #endif
        }

        try? await Task.sleep(for: .milliseconds(200))

        #if DEBUG
        print("Stream switch succeeded → playback resumed for \(stream.language)")
        #endif

        // Notify UI (this is now mostly redundant because the observer will do it,
        // but it doesn't hurt as a fallback)
        safeOnStatusChange(isPlaying: true, status: "")

        // Final save
        Task {
            await SharedPlayerManager.shared.saveCurrentState()
        }
    }
    
    private func startBufferingTimer() {
        stopBufferingTimer()
        bufferingTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.stop()
            #if DEBUG
            print("⏰ Buffering timeout triggered")
            #endif
            self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_stopped"))
        }
    }

    private func stopBufferingTimer() {
        bufferingTimer?.invalidate()
        bufferingTimer = nil
    }
    
    private func startPlaybackWithFallback(fallbackServers: [Server], completion: @escaping BoolCompletion) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            
            // Stop previous playback
            self.stop(completion: nil, silent: true)
            
            let connectionStartTime = Date()
            let connectionId = UUID()
            
            Task.detached(priority: .userInitiated) {
                await self.setupSSLProtectionTimer(id: connectionId, for: connectionStartTime)
            }
            
            self.isSSLHandshakeComplete = false
            self.hasStartedPlaying = false
            
            let finalURL = self.selectedStream.url
            
            let asset = AVURLAsset(url: finalURL)
            asset.resourceLoader.setDelegate(self, queue: DispatchQueue(label: "radio.lutheran.resourceloader"))
            self.playerItem = AVPlayerItem(asset: asset)
            
            if self.player == nil {
                self.player = AVPlayer(playerItem: self.playerItem)
            } else {
                self.player?.replaceCurrentItem(with: self.playerItem)
            }
            
            self.addObservers()
            
            var tempStatusObserver: NSKeyValueObservation?
            tempStatusObserver = self.playerItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard let self else { return }
                let age = Date().timeIntervalSince(connectionStartTime)
                
                switch item.status {
                case .readyToPlay:
                    tempStatusObserver?.invalidate()
                    self.clearSSLProtectionTimer(for: connectionId)
                    self.fallbackWorkItem?.cancel()
                    self.fallbackWorkItem = nil
                    
                    self.markSSLHandshakeComplete(for: connectionId)
                    self.isSSLHandshakeComplete = true
                    
                    self.serverFailureCount[self.currentSelectedServer.name] = 0
                    self.lastFailedServerName = nil
                    
                    self.metadataOutput = AVPlayerItemMetadataOutput(identifiers: nil)
                    self.metadataOutput?.setDelegate(self, queue: DispatchQueue.main)
                    self.playerItem?.add(self.metadataOutput!)
                    
                    // FIXED: Use Task { @MainActor in } + explicit play() on main + small delay for resource loader
                    Task { @MainActor in
                        self.player?.play()
                        // Tiny safe delay helps when resourceLoader is involved
                        try? await Task.sleep(for: .milliseconds(100))
                        self.player?.play()   // second call is harmless and often needed
                    }
                    
                    self.hasStartedPlaying = true
                    
                    #if DEBUG
                    print("✅ PlayerItem readyToPlay – calling play() on MainActor")
                    #endif
                    
                case .failed:
                    tempStatusObserver?.invalidate()
                    self.clearSSLProtectionTimer(for: connectionId)
                    self.fallbackWorkItem?.cancel()
                    self.fallbackWorkItem = nil
                    
                    #if DEBUG
                    print("❌ PlayerItem failed with server \(self.currentSelectedServer.name) after \(age)s")
                    if let error = item.error {
                        print("   Error: \(error)")
                    }
                    #endif
                    
                    if !fallbackServers.isEmpty {
                        self.tryNextServer(fallbackServers: fallbackServers, completion: completion)
                    } else {
                        self.safeOnStatusChange(isPlaying: false, status: String(localized: String.LocalizationValue("status_stream_unavailable")))
                        completion(false)
                    }
                    
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
            
            // Schedule the fallback timeout (unchanged)
            let timeout: TimeInterval = isLowEfficiencyMode ? 15 : 10
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.playerItem?.status != .readyToPlay else { return }
                tempStatusObserver?.invalidate()
                let age = Date().timeIntervalSince(connectionStartTime)
                #if DEBUG
                print("❌ Fallback timeout reached after \(age)s with server \(self.currentSelectedServer.name)")
                #endif
                self.clearSSLProtectionTimer(for: connectionId)
                self.fallbackWorkItem = nil
                if !fallbackServers.isEmpty {
                    self.tryNextServer(fallbackServers: fallbackServers, completion: completion)
                } else {
                    self.safeOnStatusChange(isPlaying: false, status: String(localized: String.LocalizationValue("status_stream_unavailable")))
                    completion(false)
                }
            }
            
            self.fallbackWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
        }
    }
    
    // FIXED: Remove the cancelPendingSSLProtection method that relied on shared connectionStartTime
    func cancelPendingSSLProtection() {
        clearSSLProtectionTimer()
        #if DEBUG
        print("🔒 [Manual Cancel] Cancelled pending SSL protection")
        #endif
    }
    
    // FIXED: Update clearSSLProtectionTimer to remove debug reference
    private func clearSSLProtectionTimer() {
        clearAllSSLProtectionTimers()
        isSSLHandshakeComplete = true
        
        #if DEBUG
        print("🔒 [SSL Protection] Legacy timer cleared")
        #endif
    }
    
    func getCurrentMetadataForLiveActivity() -> String? {
        return currentMetadata
    }
    
    func setVolume(_ volume: Float) {
        executeAudioOperation({
            self.player?.volume = volume
            return ()
        }, completion: { _ in })
    }
    
    // FIXED: Simplified + robust status observer (works with security isolation + MainActor)
    private func addObservers() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            #if DEBUG
            print("🧹 addObservers() called — clearing old ones")
            #endif
            
            // Clear existing first (safe even if called multiple times)
            self.playerItemObservations.forEach { $0.invalidate() }
            self.playerItemObservations.removeAll()
            
            guard let playerItem = self.playerItem else {
                #if DEBUG
                print("⚠️ addObservers: No playerItem yet")
                #endif
                return
            }
            
            // Status observer — now actively handles .readyToPlay (critical for initial playback)
            let statusObs = playerItem.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    #if DEBUG
                    print("🎵 Player item status changed: \(item.status.rawValue) (readyToPlay=1, failed=2)")
                    #endif
                    
                    guard self.delegate != nil else { return }
                    
                    switch item.status {
                    case .readyToPlay:
                        #if DEBUG
                        print("✅ Item readyToPlay → starting playback")
                        #endif
                        self.player?.play()
                        self.player?.rate = 1.0
                        self.safeOnStatusChange(isPlaying: true, status: String(localized: "status_playing"))
                        self.stopBufferingTimer()
                        self.hasStartedPlaying = true
                        
                    case .failed:
                        self.lastError = item.error
                        let errorType = StreamErrorType.from(error: item.error)
                        self.hasPermanentError = errorType.isPermanent
                        self.safeOnStatusChange(isPlaying: false, status: errorType.statusString)
                        self.stop()
                        
                    case .unknown:
                        if self.hasStartedPlaying {
                            self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_buffering"))
                        }
                    @unknown default:
                        break
                    }
                }
            }
            self.playerItemObservations.append(statusObs)
            #if DEBUG
            print("🧹 Added robust status observer")
            #endif
            
            // Keep the existing buffer observers (they are still useful)
            let bufferEmptyObs = playerItem.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, change in
                guard let self = self, let newValue = change.newValue, newValue else { return }
                DispatchQueue.main.async {
                    if let error = item.error as NSError?, error.domain == "AVFoundationErrorDomain" {
                        #if DEBUG
                        print("🎵 Buffer empty with error — attempting recovery")
                        #endif
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.recreatePlayerItem()
                        }
                        return
                    }
                    self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_buffering"))
                    self.startBufferingTimer()
                }
            }
            self.playerItemObservations.append(bufferEmptyObs)
            
            let likelyToKeepUpObs = playerItem.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, change in
                guard let self = self, let newValue = change.newValue else { return }
                DispatchQueue.main.async {
                    if newValue && item.status == .readyToPlay {
                        self.player?.play()
                        self.safeOnStatusChange(isPlaying: true, status: String(localized: "status_playing"))
                        self.stopBufferingTimer()
                    } else if !newValue && (self.player?.rate ?? 0) == 0 {
                        let stalledDelay: TimeInterval = self.isLowEfficiencyMode ? 20.0 : 10.0
                        DispatchQueue.main.asyncAfter(deadline: .now() + stalledDelay) { [weak self] in
                            guard let self = self,
                                  let currentItem = self.playerItem,
                                  currentItem == item,
                                  !currentItem.isPlaybackLikelyToKeepUp,
                                  (self.player?.rate ?? 0) == 0 else { return }
                            #if DEBUG
                            print("🔄 Stalled — attempting recovery")
                            #endif
                            self.recreatePlayerItem()
                        }
                    }
                }
            }
            self.playerItemObservations.append(likelyToKeepUpObs)
            
            let bufferFullObs = playerItem.observe(\.isPlaybackBufferFull, options: [.new]) { [weak self] item, change in
                guard let self = self, let newValue = change.newValue, newValue else { return }
                DispatchQueue.main.async {
                    self.player?.play()
                    self.safeOnStatusChange(isPlaying: true, status: String(localized: "status_playing"))
                    self.stopBufferingTimer()
                }
            }
            self.playerItemObservations.append(bufferFullObs)
            
            #if DEBUG
            print("🧹 Added buffer observers")
            #endif
            
            // Time observer (kept as-is)
            let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            if let player = self.player, self.timeObserver == nil {
                self.timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
                    guard let self = self, self.delegate != nil else { return }
                    if (self.player?.rate ?? 0) > 0 {
                        self.safeOnStatusChange(isPlaying: true, status: String(localized: "status_playing"))
                    }
                }
                self.timeObserverPlayer = player
                #if DEBUG
                print("🧹 Added time observer")
                #endif
            }
        }
    }
    
    // Methods for observer removal
    func removeObservers(for playerItem: AVPlayerItem?) {
        self.playerItemObservations.forEach { $0.invalidate() }
        self.playerItemObservations.removeAll()
    }

    private func removeObserversFrom(_ playerItem: AVPlayerItem) {
        self.playerItemObservations.forEach { $0.invalidate() }
        self.playerItemObservations.removeAll()
    }
    
    private func recreatePlayerItem() {
        #if DEBUG
        print("🔄 Recreating player item due to decoder error")
        #endif
        
        guard let urlAsset = playerItem?.asset as? AVURLAsset else {
            #if DEBUG
            print("❌ Cannot recreate: no valid URL asset")
            #endif
            return
        }
        
        let currentURL = urlAsset.url
        
        // Clear observations
        playerItemObservations.forEach { $0.invalidate() }
        playerItemObservations.removeAll()
        
        // Create new asset and player item
        let newAsset = AVURLAsset(url: currentURL)
        let newItem = AVPlayerItem(asset: newAsset)
        
        // Replace the item
        player?.replaceCurrentItem(with: newItem)
        
        // Update playerItem reference to the new item
        playerItem = newItem
        
        // Re-add observers to the new item
        addObservers()
        
        // Restart playback
        player?.play()
        
        #if DEBUG
        print("✅ Player item recreated and playback resumed")
        #endif
    }
    
    private func removeObserversImplementation() {
        if isDeallocating {
            removeObserversSynchronously()
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isDeallocating else {
                return
            }
            self.removeObserversSynchronously()
        }
    }
    
    /// Stops playback and cleans up resources.
    /// - Parameters:
    ///   - completion: Optional completion handler called after stopping.
    ///   - isSwitchingStream: If `true`, treats this as a stream switch, suppressing "stopped" status updates.
    ///   - silent: If `true`, skips all status updates to avoid UI flicker.
    func stop(completion: (@MainActor @Sendable () -> Void)? = nil,
              isSwitchingStream: Bool? = nil,
              silent: Bool = false) {
        
        #if DEBUG
        print("🛑 FORCE STOPPING ALL PLAYBACK - isSwitchingStream: \(String(describing: isSwitchingStream)), attemptingPlayback: \(isCurrentlyAttemptingPlayback)")
        #endif
        
        // Existing guards (keep all of them)
        if isCurrentlyAttemptingPlayback {
            #if DEBUG
            print("⚠️ [Stop Guard] Skipping aggressive stop during playback startup attempt (even switch)")
            #endif
            loadingTimeoutWorkItem?.cancel()
            fallbackWorkItem?.cancel()
            pendingPlaybackWorkItem?.cancel()
            retryWorkItem?.cancel()
            return
        }
        
        if isCurrentlyAttemptingPlayback && (isSwitchingStream == nil || isSwitchingStream == false) {
            #if DEBUG
            print("⚠️ [Stop Guard] Skipping aggressive stop during playback startup attempt")
            #endif
            loadingTimeoutWorkItem?.cancel()
            fallbackWorkItem?.cancel()
            pendingPlaybackWorkItem?.cancel()
            retryWorkItem?.cancel()
            return
        }

        loadingTimeoutWorkItem?.cancel()
        currentLoadingDelegate?.loadingRequest.finishLoading(with: URLError(.cancelled))
        currentLoadingDelegate = nil
        
        removeAudioSessionObservers()
        clearAllSSLProtectionTimers()
        retryWorkItem?.cancel()
        fallbackWorkItem?.cancel()
        fallbackWorkItem = nil
        pendingPlaybackWorkItem?.cancel()
        pendingPlaybackWorkItem = nil

        let effectiveSwitching = isSwitchingStream ?? self.isSwitchingStream
        let isUserInitiatedPause = !silent && !effectiveSwitching
        
        // === CRITICAL PlayerVisualState handling ===
        Task { @MainActor in
            if isUserInitiatedPause {
                await self.markAsUserPaused()          // ← Clean call via extension
            }
            // For silent switches / internal stops we leave the previous visual state untouched
            
            // Perform the actual AVPlayer stop
            performActualStop(
                completion: completion,
                silent: silent || effectiveSwitching,
                effectiveSwitching: effectiveSwitching
            )
            
            // Persist everything
            await SharedPlayerManager.shared.saveCurrentState()
        }
    }

    /// Performs the actual stop operation.
    /// - Parameters:
    ///   - completion: Optional completion handler called after stopping.
    ///   - silent: If `true`, skips all status updates to avoid UI flicker.
    ///   - effectiveSwitching: If `true`, suppresses "status_stopped" updates during stream switches.
    /// - Note: Combines `silent` and `effectiveSwitching` into `effectiveSilent`. All main-thread work is now explicitly isolated.
    private func performActualStop(completion: (@MainActor () -> Void)? = nil,
                                   silent: Bool = false,
                                   effectiveSwitching: Bool) {
        clearSSLProtectionTimer()
        isSSLHandshakeComplete = true
        hasStartedPlaying = false
        
        // Security validation is now handled on-demand via SecurityModelValidator.shared (unchanged)
        
        let effectiveSilent = silent || effectiveSwitching
        
        if isDeallocating {
            stopSynchronously()
            if let completion = completion {
                MainActor.assumeIsolated {
                    completion()
                }
            }
            return
        }
        
        audioQueue.async { [weak self] in
            guard let self, !self.isDeallocating else {
                if let completion = completion {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            completion()
                        }
                    }
                }
                return
            }
            
            #if DEBUG
            print("🛑 Stopping playback")
            #endif
            
            guard self.player != nil || self.playerItem != nil else {
                if !silent {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if !effectiveSilent {
                                self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_stopped"))
                            }
                            completion?()
                        }
                    }
                } else if let completion = completion {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            completion()
                        }
                    }
                }
                #if DEBUG
                print("🛑 Playback already stopped, skipping cleanup (silent/effectiveSilent: \(effectiveSilent))")
                #endif
                return
            }
            
            // Pause operations
            self.executeAudioOperation({
                self.player?.pause()
                self.player?.rate = 0.0
                return ""
            }, completion: { _ in })
            
            // Cleanup (unchanged)
            self.activeResourceLoaders.forEach { (_, delegate) in
                delegate.cancel()
            }
            self.activeResourceLoaders.removeAll()
            
            if let metadataOutput = self.metadataOutput, let playerItem = self.playerItem {
                if playerItem.outputs.contains(metadataOutput) {
                    playerItem.remove(metadataOutput)
                    #if DEBUG
                    print("🧹 Removed metadata output from playerItem in stop")
                    #endif
                }
            }
            self.metadataOutput = nil
            
            self.playerItemObservations.forEach { $0.invalidate() }
            self.playerItemObservations.removeAll()
            self.removeObserversImplementation()
            self.playerItem = nil
            
            if !silent {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if !effectiveSilent {
                            self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_stopped"))
                        }
                        completion?()
                    }
                }
            } else if let completion = completion {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        completion()
                    }
                }
            }
            
            self.stopBufferingTimer()
            
            #if DEBUG
            print("🛑 Playback stopped, playerItem and resource loaders cleared")
            #endif
        }
    }
    
    private func stopSynchronously() {
        // Perform all cleanup on main thread
        if Thread.isMainThread {
            player?.pause()
            player?.rate = 0.0
        } else {
            DispatchQueue.main.sync {
                player?.pause()
                player?.rate = 0.0
            }
        }
        
        // Cancel active resource loaders
        activeResourceLoaders.forEach { (_: AVAssetResourceLoadingRequest, delegate: StreamingSessionDelegate) in
            delegate.cancel()
        }
        activeResourceLoaders.removeAll()
        
        // Remove metadata output
        if let metadataOutput = self.metadataOutput, let playerItem = self.playerItem {
            if playerItem.outputs.contains(metadataOutput) {
                playerItem.remove(metadataOutput)
            }
        }
        self.metadataOutput = nil
        
        // Remove observers synchronously
        removeObserversSynchronously()
        
        // Clear playerItem
        playerItem = nil
        
        // Stop buffering timer
        bufferingTimer?.invalidate()
        bufferingTimer = nil
    }
    
    private func performStopCleanup() {
        // Original stop logic without weak references
        guard player != nil || playerItem != nil else {
            return
        }
        
        player?.pause()
        player?.rate = 0.0
        
        activeResourceLoaders.forEach { (_: AVAssetResourceLoadingRequest, delegate: StreamingSessionDelegate) in
            delegate.cancel()
        }
        activeResourceLoaders.removeAll()
        
        if let metadataOutput = self.metadataOutput, let playerItem = self.playerItem {
            if playerItem.outputs.contains(metadataOutput) {
                playerItem.remove(metadataOutput)
            }
        }
        self.metadataOutput = nil
        
        removeObserversImplementation()
        playerItem = nil
        stopBufferingTimer()
    }
    
    private func removeObserversSynchronously() {
        self.playerItemObservations.forEach { $0.invalidate() }
        self.playerItemObservations.removeAll()
        
        if let timeObserver = self.timeObserver, let player = self.timeObserverPlayer {
            player.removeTimeObserver(timeObserver)
        }
        self.timeObserver = nil
        self.timeObserverPlayer = nil
    }
    
    func clearCallbacks() {
        onStatusChange = nil
        onMetadataChange = nil
        delegate = nil
    }
    
    deinit {
        isDeallocating = true
        
        // Cancel pending work items that exist
        serverSelectionWorkItem?.cancel()
        retryWorkItem?.cancel()
        
        #if DEBUG
        print("🧹 [Deinit] Cancelled pending work items")
        #endif
        
        // Stop synchronously to avoid async cleanup during deallocation
        stopSynchronously()
        
        playerItemObservations.forEach { $0.invalidate() }
        playerItemObservations.removeAll()
        
        // Clear all callbacks to prevent retention cycles
        clearCallbacks()
        
        // Cancel network monitoring
        networkMonitor?.cancel()
        networkMonitor = nil
        
        // Clear metadata output
        metadataOutput = nil
        
        // Clear server failure tracking
        serverFailureCount.removeAll()
        lastFailedServerName = nil
        
        // Cleanup thermal observer
        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        // Clean up Low Power Mode observer to prevent memory leaks.
        NotificationCenter.default.removeObserver(self, name: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"), object: nil)
        
        // MARK: - Additional Deinit Cleanup
        removeAudioSessionObservers()
        clearAllSSLProtectionTimers()  // Ensure existing SSL cleanup runs
        
        #if DEBUG
        print("🧹 DirectStreamingPlayer deinit completed")
        #endif
    }
    
    private func handleLoadingError(_ error: Error) {
        let errorType = StreamErrorType.from(error: error)
        hasPermanentError = errorType.isPermanent
        
        #if DEBUG
        print("🔒 [Loading Error] Type: \(errorType), isPermanent: \(errorType.isPermanent)")
        print("🔒 [Loading Error] Error: \(error.localizedDescription)")
        #endif
        
        if let urlError = error as? URLError {
            switch urlError.code {
            case .serverCertificateUntrusted, .secureConnectionFailed:
                #if DEBUG
                print("🔒 [Loading Error] SSL/Certificate error detected")
                #endif
                safeOnStatusChange(isPlaying: false, status: String(localized: "status_security_failed"))
            case .cannotFindHost, .fileDoesNotExist, .badServerResponse:
                #if DEBUG
                print("🔒 [Loading Error] Permanent network/server error detected")
                #endif
                onStatusChange?(false, String(localized: "status_stream_unavailable"))
            default:
                #if DEBUG
                print("🔒 [Loading Error] Transient error detected")
                #endif
                safeOnStatusChange(isPlaying: false, status: String(localized: "status_buffering"))
            }
        } else {
            #if DEBUG
            print("🔒 [Loading Error] Non-URLError detected")
            #endif
            safeOnStatusChange(isPlaying: false, status: String(localized: "status_buffering"))
        }
        
        stop()
    }
}

// MARK: - Server Configuration
extension DirectStreamingPlayer {
    struct Server {
        let name: String
        let pingURL: URL
        let baseHostname: String
        let subdomain: String
    }
    
    static let servers = [
        Server(
            name: "EU",
            pingURL: URL(string: "https://european.lutheran.radio/ping")!,
            baseHostname: "lutheran.radio",
            subdomain: "eu"
        ),
        Server(
            name: "US",
            pingURL: URL(string: "https://livestream.lutheran.radio/ping")!,
            baseHostname: "lutheran.radio",
            subdomain: "us"
        )
    ]
}

// MARK: - Latency Measurement
extension DirectStreamingPlayer {
    struct PingResult {
        let server: Server
        let latency: TimeInterval
    }
    
    func fetchServerIPsAndLatencies(completion: @escaping ([PingResult]) -> Void) {
        let group = DispatchGroup()
        var results: [PingResult] = []
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.0
        let session = URLSession(configuration: config)
        
        networkQueue.async {
            for server in Self.servers {
                group.enter()
                let startTime = Date()
                #if DEBUG
                print("📡 [Ping] Pinging \(server.name) at \(server.pingURL)")
                #endif
                
                let task = session.dataTask(with: server.pingURL) { [weak self] data, response, error in
                    guard self != nil else {
                        group.leave()
                        return
                    }
                    let latency = Date().timeIntervalSince(startTime)
                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200, error == nil {
                        results.append(PingResult(server: server, latency: latency))
                        #if DEBUG
                        print("📡 [Ping] Success for \(server.name), latency=\(latency)s")
                        #endif
                    } else {
                        results.append(PingResult(server: server, latency: .infinity))
                        #if DEBUG
                        print("📡 [Ping] Failed for \(server.name): error=\(error?.localizedDescription ?? "None"), status=\((response as? HTTPURLResponse)?.statusCode ?? -1)")
                        #endif
                    }
                    group.leave()
                }
                task.resume()
            }
        }
        
        group.notify(queue: .main) {
            #if DEBUG
            print("📡 [Ping] All pings completed: \(results.map { "\($0.server.name): \($0.latency)s" })")
            #endif
            completion(results)
        }
    }
}

// Extension to get unique elements from a sequence
extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - Metadata Handling
extension DirectStreamingPlayer: AVPlayerItemMetadataOutputPushDelegate {
    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                       didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                       from track: AVPlayerItemTrack?) {
        guard delegate != nil else { return }
        
        guard let item = groups.first?.items.first,
              let value = item.value(forKeyPath: "stringValue") as? String,
              !value.isEmpty else { return }
        
        let streamTitle = (item.identifier == AVMetadataIdentifier("icy/StreamTitle") ||
                       (item.key as? String) == "StreamTitle") ? value : nil
        
        // Store metadata locally for Live Activities
        self.currentMetadata = streamTitle
        
        safeOnMetadataChange(metadata: streamTitle)
    }
}

extension DirectStreamingPlayer {
    func handleNetworkInterruption() {
        stop()
        let interruptionDelay: TimeInterval = isLowEfficiencyMode ? 1.0 : 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + interruptionDelay) { [weak self] in
            guard let self = self, self.delegate != nil else { return }
            self.safeOnStatusChange(isPlaying: false, status: String(localized: "alert_retry"))
        }
    }
    
    private func handlePlaybackError(_ error: Error?) {
        guard let avError = error as? AVError else { return }
        #if DEBUG
        print("❌ Playback error: code=\(avError.code.rawValue), desc=\(avError.localizedDescription)")
        #endif
        self.hasPermanentError = true  // Flag for reset in stop
        self.stop(completion: nil, silent: true)  // Silent stop to reset
        if avError.localizedDescription.contains("unmatched audio object type") || avError.localizedDescription.contains("SBR decoder") {
            #if DEBUG
            print("⚠️ HE-AAC/SBR format issue detected—recommend server-side LC-AAC fallback")
            #endif
            // Optional: Trigger fallback stream if available (e.g., switchToStream(fallbackStream))
        }
    }
}

// MARK: - Audio Session Interruption Handling
extension DirectStreamingPlayer {
    /// Sets up AVAudioSession observers for interruptions and route changes.
    /// - Note: Called in play() to avoid overhead when idle. Uses NotificationCenter for loose coupling.
    nonisolated private func setupAudioSessionObservers() {
        guard interruptionObserver == nil else { return }  // Idempotent
        
        let session = AVAudioSession.sharedInstance()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            // NEW — only Sendable values cross the boundary
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            
            Task { @MainActor [weak self, typeValue, optionsValue] in
                let type = AVAudioSession.InterruptionType(rawValue: typeValue ?? 0)
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
                guard let self else { return }
                
                switch type {
                case .began:
                    #if DEBUG
                    print("🔇 [AudioSession] Interruption began")
                    #endif
                    self.isHandlingInterruption = true
                    self.wasPlayingBeforeInterruption = self.isPlaying  // Use refined check
                    
                    if self.wasPlayingBeforeInterruption {
                        self.player?.pause()  // Graceful pause
                        self.delegate?.onStatusChange(.paused, "Interruption")  // Notify UI
                        
                        // Persist paused state for widget — non-blocking
                        Task {
                            await SharedPlayerManager.shared.saveCurrentState()
                        }
                    }
                    
                case .ended:
                    #if DEBUG
                    print("🔊 [AudioSession] Interruption ended")
                    #endif
                    if options.contains(.shouldResume) && self.wasPlayingBeforeInterruption && !self.isSwitchingStream {
                        Task.detached(priority: .userInitiated) {
                            try? await Task.sleep(for: .milliseconds(100))
                            await MainActor.run { [weak self] in
                                guard let self else { return }
                                self.player?.play()
                                if self.isPlaying {  // Guard delegate
                                    self.delegate?.onStatusChange(.playing, nil)
                                }
                                
                                // Persist resumed state — non-blocking
                                Task {
                                    await SharedPlayerManager.shared.saveCurrentState()
                                }
                            }
                        }
                    }
                    self.isHandlingInterruption = false
                    self.wasPlayingBeforeInterruption = false
                    
                default:
                    // Fallback for unknown cases (exhaustive without @unknown)
                    #if DEBUG
                    print("⚠️ [AudioSession] Unknown interruption type: \(String(describing: type))")
                    #endif
                    break
                }
            }
        }
        
        // Optional: Handle route changes (e.g., AirPlay disconnect) for completeness
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                #if DEBUG
                print("🔄 [AudioSession] Route changed")
                #endif
                // If disconnected during play, pause and notify
                if self.player?.rate ?? 0 > 0 {
                    self.player?.pause()
                    self.delegate?.onStatusChange(.paused, "Route Change")
                    
                    // Optional: persist paused state after route change
                    Task {
                        await SharedPlayerManager.shared.saveCurrentState()
                    }
                }
            }
        }
    }

    /// Cleans up observers.
    nonisolated private func removeAudioSessionObservers() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
    }
}

// MARK: - Extensions for Delegates and Helpers
/// Handles custom resource loading for secure streaming.
extension DirectStreamingPlayer: AVAssetResourceLoaderDelegate {
    /// Determines if the loader should handle the request.
    /// - Parameters:
    ///   - resourceLoader: The requesting loader.
    ///   - loadingRequest: The resource request.
    /// - Returns: `true` if handling (for lutheran.radio HTTPS URLs).
    /// - Note: Enforces HTTPS and domain checks; sets up pinned sessions.
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url else {
            #if DEBUG
            print("❌ [Resource Loader] No URL in loading request")
            #endif
            loadingRequest.finishLoading(with: NSError(domain: "radio.lutheran", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return false
        }
        
        #if DEBUG
        print("📡 [Resource Loader] ===== NEW REQUEST =====")
        print("📡 [Resource Loader] Received URL: \(url)")
        print("📡 [Resource Loader] URL scheme: \(url.scheme ?? "nil")")
        print("📡 [Resource Loader] URL host: \(url.host ?? "nil")")
        #endif
        
        // FIXED: Only handle HTTPS URLs for lutheran.radio domains
        guard url.scheme == "https",
              let host = url.host,
              host.hasSuffix("lutheran.radio") else {
            #if DEBUG
            print("📡 [Resource Loader] ❌ Not a lutheran.radio HTTPS URL, letting system handle it")
            #endif
            return false  // Let the system handle non-lutheran.radio URLs
        }
        
        // Store the original hostname for SSL validation
        let originalHostname = host
        #if DEBUG
        print("📡 [Resource Loader] ✅ Handling lutheran.radio HTTPS URL: \(url)")
        print("📡 [Resource Loader] Original hostname for SSL: \(originalHostname)")
        #endif
        
        // Create clean request with the HTTPS URL (no conversion needed)
        var modifiedRequest = URLRequest(url: url)
        modifiedRequest.timeoutInterval = 60.0
        
        // Apply Icecast/Liquidsoap compatibility headers (centralised & future-proof)
        modifiedRequest = self.requestWithIcecastHeaders(from: modifiedRequest)
        
        #if DEBUG
        print("📡 [Resource Loader] Final request headers: \(modifiedRequest.allHTTPHeaderFields ?? [:])")
        #endif
        
        // Create streaming delegate
        let streamingDelegate = StreamingSessionDelegate(loadingRequest: loadingRequest)
        streamingDelegate.originalHostname = originalHostname
        
        #if DEBUG
        print("🔒 [Resource Loader] StreamingSessionDelegate created for hostname: \(originalHostname)")
        #endif
        
        // Enhanced configuration for SSL pinning
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60.0
        config.timeoutIntervalForResource = 120.0
        
        // Force fresh SSL connections for proper pinning validation
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCredentialStorage = nil
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 1
        
        let operationQueue = OperationQueue()
        operationQueue.qualityOfService = .userInitiated
        operationQueue.maxConcurrentOperationCount = 1
        
        #if DEBUG
        print("🔒 [Resource Loader] Creating URLSession with SSL-forcing config")
        #endif
        
        streamingDelegate.session = URLSession(configuration: config,
                                               delegate: streamingDelegate,
                                               delegateQueue: operationQueue)
        
        // Apply Icecast/Liquidsoap headers exactly once (clean & future-proof)
        let finalRequest = self.requestWithIcecastHeaders(from: modifiedRequest)
        streamingDelegate.dataTask = streamingDelegate.session?.dataTask(with: finalRequest)
        
        streamingDelegate.onError = { [weak self, weak streamingDelegate] error in
            guard let self = self, let delegate = streamingDelegate else { return }
            
            #if DEBUG
            print("❌ [Resource Loader] Streaming error occurred: \(error.localizedDescription)")
            #endif
            
            DispatchQueue.main.async {
                self.activeResourceLoaders.removeValue(forKey: delegate.loadingRequest)
                self.loadingTimeoutWorkItem?.cancel()
                if self.currentLoadingDelegate === delegate {
                    self.currentLoadingDelegate = nil
                }
                self.handleLoadingError(error)
            }
        }
        
        activeResourceLoaders[loadingRequest] = streamingDelegate
        
        #if DEBUG
        print("🔒 [Resource Loader] Starting data task with Icecast-compatible headers…")
        #endif
        streamingDelegate.dataTask?.resume()
        self.currentLoadingDelegate = streamingDelegate
        self.startLoadingRequestTimeout(for: streamingDelegate)
        
        #if DEBUG
        print("📡 [Resource Loader] ✅ Resource loader setup complete")
        print("📡 [Resource Loader] ===== END REQUEST SETUP =====")
        #endif
        
        return true
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        #if DEBUG
        print("📡 [SSL Debug] Resource loading cancelled for request")
        #endif
        
        if let delegate = activeResourceLoaders.removeValue(forKey: loadingRequest) {
            delegate.cancel()
            loadingTimeoutWorkItem?.cancel()
            if currentLoadingDelegate === delegate {
                currentLoadingDelegate = nil
            }
        }
    }
}

extension DirectStreamingPlayer {
    enum StreamErrorType {
        case securityFailure
        case permanentFailure
        case transientFailure
        case unknown
        
        static func from(error: Error?) -> StreamErrorType {
            guard let nsError = error as NSError?, nsError.domain == NSURLErrorDomain else {
                return .unknown
            }
            
            switch nsError.code {
            case URLError.Code.secureConnectionFailed.rawValue,
                URLError.Code.serverCertificateUntrusted.rawValue:
                return .securityFailure
            case URLError.Code.cannotFindHost.rawValue,
                URLError.Code.resourceUnavailable.rawValue,
                URLError.Code.fileDoesNotExist.rawValue,
                URLError.Code.cannotConnectToHost.rawValue:
                return .permanentFailure
            case URLError.Code.badServerResponse.rawValue:    // Treat as transient to enable fallback for temporary HTTP 5xx errors (e.g., server reboots)
                return .transientFailure
            default:
                return .transientFailure
            }
        }
        
        var statusString: String {
            switch self {
            case .securityFailure:
                return String(localized: "status_security_failed")
            case .permanentFailure:
                return String(localized: "status_stream_unavailable")
            case .transientFailure:
                return String(localized: "status_buffering")
            case .unknown:
                return String(localized: "status_connecting")
            }
        }
        
        var isPermanent: Bool {
            switch self {
            case .securityFailure, .permanentFailure:
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - Adaptive SSL Timeout Implementation (Swift 6 Fixes)
//
// Refactored for strict concurrency without functional changes:
// • Timers → Tasks: Sendable + cancellable (e.g., SSL protection).
// • Races in isOnCellular: Queue-isolated flag (atomic hasResumed).
// Enhances safety for multi-threaded streaming while preserving minimal footprint.
extension DirectStreamingPlayer {
    
    /// Calculates adaptive SSL timeout based on network conditions and server location
    private func getSSLTimeout() async -> TimeInterval {
        // Base timeout - conservative starting point
        var timeout: TimeInterval = 12.0
        
        // Add extra time for cellular connections
        let isCellular = await isOnCellular()
        if isCellular {
            timeout += 4.0
            #if DEBUG
            print("🔒 [SSL Timeout] Added 4s for cellular connection")
            #endif
        }
        
        // Add extra time for expensive (metered) networks, e.g., cellular or paid hotspots.
        // This uses the exposed currentPath from networkMonitor.
        if let path = networkMonitor?.currentPath, path.isExpensive {
            timeout += 2.0
            #if DEBUG
            print("🔒 [SSL Timeout] Added 2s for expensive/metered network")
            #endif
        }
        
        // Add extra time for cross-continental connections
        if currentSelectedServer.name == "EU" && !isInEurope() {
            timeout += 1.5
            #if DEBUG
            print("🔒 [SSL Timeout] Added 1.5s for EU server from non-Europe location")
            #endif
        } else if currentSelectedServer.name == "US" && !isInNorthAmerica() {
            timeout += 1.5
            #if DEBUG
            print("🔒 [SSL Timeout] Added 1.5s for US server from non-North America location")
            #endif
        }
        
        // Add extra time if we have recent server failures (indicates network issues)
        if hasRecentServerFailures() {
            timeout += 1.0
            #if DEBUG
            print("🔒 [SSL Timeout] Added 1s for recent server failures")
            #endif
        }
        
        // Cap at reasonable maximum
        let finalTimeout = min(timeout, 20.0)
        
        #if DEBUG
        print("🔒 [SSL Timeout] Calculated timeout: \(finalTimeout)s (base: 8.0s)")
        #endif
        
        return finalTimeout
    }
    
    /// Short-lived coordinator for async cellular detection via NWPathMonitor.
    /// - Note: Addresses Swift 6 races in original local-var approach:
    ///   - Uses `DispatchQueue.sync` for atomic `hasResumed` (prevents double-resume).
    ///   - Captures Sendables only in handler; weak `self` avoids cycles.
    ///   - Deallocs post-resume (lifetime ~0.1-0.2s).
    /// Invariant: Exactly one path (timeout or update) resumes the continuation.
    private final class CellularCheckCoordinator: @unchecked Sendable {
        private let syncQueue = DispatchQueue(label: "cellular.hasResumed")
        private var hasResumed = false
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

        private func performFallback(continuation: CheckedContinuation<Bool, Never>) async {
            syncQueue.sync {  // Replace: Scoped sync—no manual lock/unlock
                guard !hasResumed else { return }
                hasResumed = true
                monitor?.cancel()
                continuation.resume(returning: false)  // Fallback: non-cellular
            }
        }

        private func handlePathUpdate(path: NWPath, timeoutTask: Task<Void, Never>, continuation: CheckedContinuation<Bool, Never>) async {
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
    private func isOnCellular() async -> Bool {
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
    private func isInEurope() -> Bool {
        let timezone = TimeZone.current
        let europeanTimezones = [
            "Europe/", "GMT", "UTC", "WET", "CET", "EET",
            "Atlantic/Reykjavik", "Atlantic/Faroe"
        ]
        
        return europeanTimezones.contains { timezone.identifier.hasPrefix($0) }
    }
    
    /// Detects if the device is likely in North America based on timezone
    private func isInNorthAmerica() -> Bool {
        let timezone = TimeZone.current
        let northAmericanTimezones = [
            "America/", "US/", "Canada/", "EST", "CST", "MST", "PST"
        ]
        
        return northAmericanTimezones.contains { timezone.identifier.hasPrefix($0) }
    }
    
    /// Checks if we've had recent server failures indicating network issues
    private func hasRecentServerFailures() -> Bool {
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
    private func setupSSLProtectionTimer(id: UUID, for connectionStartTime: Date) async {
        let adaptiveTimeout = await getSSLTimeout()
        
        #if DEBUG
        print("🔒 [SSL Protection] Starting \(adaptiveTimeout)s adaptive protection task for connection \(id)")
        #endif
        
        // Replace Timer with detached Task (Sendable, cancellable)
        let task = Task.detached { [weak self, id, connectionStartTime] in  // weak self for safety
            guard let self = self else { return }
            
            // Sleep asynchronously (equivalent to Timer fire)
            try? await Task.sleep(for: .seconds(adaptiveTimeout))
            
            let connectionAge = Date().timeIntervalSince(connectionStartTime)
            
            #if DEBUG
            print("🔒 [SSL Protection] Adaptive task completed after \(connectionAge)s for connection \(id)")
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
                print("🔒 [SSL Protection] Still connecting after \(connectionAge)s - allowing normal error handling")
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
    private func markSSLHandshakeComplete(for connectionId: UUID) {
        connectionQueue.async {
            if var connectionInfo = self.activeConnections[connectionId] {
                connectionInfo.isHandshakeComplete = true
                self.activeConnections[connectionId] = connectionInfo
                
                #if DEBUG
                print("🔒 [SSL Protection] Marked handshake complete for connection \(connectionId)")
                #endif
            }
        }
    }
    
    /// Checks if SSL handshake is complete for a specific connection
    private func isSSLHandshakeComplete(for connectionId: UUID) -> Bool {
        var isComplete = false
        connectionQueue.sync {
            isComplete = activeConnections[connectionId]?.isHandshakeComplete ?? true
        }
        return isComplete
    }
    
    /// Clears protection for a specific connection by cancelling its Task and removing from tracking.
    /// - Note: Calls `clearAllSSLProtectionTimers()` for thorough cleanup (replaces legacy single-timer invalidate).
    ///   Safe for concurrent calls via `connectionQueue`.
    private func clearSSLProtectionTimer(for connectionId: UUID) {
        connectionQueue.async {
            if let connectionInfo = self.activeConnections.removeValue(forKey: connectionId) {
                connectionInfo.task.cancel()
                
                #if DEBUG
                print("🔒 [SSL Protection] Cleared timer for connection \(connectionId)")
                #endif
            }
        }
        
        // Clear all SSL protection timers if they exist
        clearAllSSLProtectionTimers()
    }
    
    /// Clears all active connections by cancelling Tasks and emptying the dict.
    /// - Note: Thread-safe via `connectionQueue`; use in `stop()` or `deinit` for full reset.
    private func clearAllSSLProtectionTimers() {
        connectionQueue.async {
            for (connectionId, connectionInfo) in self.activeConnections {
                connectionInfo.task.cancel()
                
                #if DEBUG
                print("🔒 [SSL Protection] Cleared timer for connection \(connectionId)")
                #endif
            }
            self.activeConnections.removeAll()
            
            #if DEBUG
            print("🔒 [SSL Protection] Cleared all SSL protection timers")
            #endif
        }
    }
    
    // MARK: - Loading Request Hard Timeout (prevents eternal .unknown status)

    private func startLoadingRequestTimeout(for delegate: StreamingSessionDelegate) {
        loadingTimeoutWorkItem?.cancel()
        
        let work = DispatchWorkItem { [weak self, weak delegate] in
            guard let self = self,
                  let delegate = delegate,
                  !delegate.loadingRequest.isFinished else { return }
            
            #if DEBUG
            print("⏰ [Hard Timeout] Force-finishing hung loading request after 15s – this should never happen only on dead-silent servers")
            #endif
            
            delegate.loadingRequest.finishLoading(with: URLError(.timedOut))
            // Note: no need to call delegate.onError – finishLoading(with:) already triggers failure path
            self.activeResourceLoaders.removeValue(forKey: delegate.loadingRequest)
            self.currentLoadingDelegate = nil
        }
        
        loadingTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: work)
    }
}

// MARK: - Icecast / Liquidsoap Compatibility
private extension DirectStreamingPlayer {
    /// Adds headers required by Icecast2 and Liquidsoap servers.
    /// Must be called for every AVAssetResourceLoadingRequest before creating the URLSession data task.
    /// - Parameter originalRequest: The request coming from AVFoundation.
    /// - Returns: A new request with the mandatory Icecast headers.
    func requestWithIcecastHeaders(from originalRequest: URLRequest) -> URLRequest {
        var request = originalRequest
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        request.setValue("Lutheran Radio/2.0 (iOS; LutheranRadioApp)", forHTTPHeaderField: "User-Agent")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        return request
    }
}

// MARK: - PlayerVisualState Integration

extension DirectStreamingPlayer {

    /// Returns whether we are allowed to automatically start or resume playback
    /// according to the user's explicit intent stored in SharedPlayerManager.
    var shouldAutoPlayOrResume: Bool {
        get async {
            await SharedPlayerManager.shared.currentVisualState.shouldAutoPlayOrResume
        }
    }

    /// Marks the current intent as user-initiated pause.
    /// This should be called from user-facing pause paths (button, remote command, etc.).
    func markAsUserPaused() async {
        await SharedPlayerManager.shared.stop()   // Uses the public stop() which sets .userPaused internally
    }

    /// Marks the current intent as actively playing.
    /// Call this after a successful manual or auto-resume.
    func markAsPlaying() async {
        await SharedPlayerManager.shared.play()   // Uses the public play() which sets .playing internally
    }
}
