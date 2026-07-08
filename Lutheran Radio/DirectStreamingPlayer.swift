//
//  DirectStreamingPlayer.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 25.2.2025.
//

import Foundation
import Security
import CommonCrypto
@unsafe @preconcurrency import AVFoundation
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
    /// status = semantic state (playing / paused / etc.)
    /// reasonKey = the exact key from Localizable.xcstrings (e.g. "status_playing", "status_paused")
    func onStatusChange(_ status: PlayerStatus, reasonKey: String?)
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
/// **Single source of truth for state**: `DirectStreamingPlayer` now owns all mutations to `isPlaying`, `selectedStream`, `hasPermanentError`, `validationState`, etc. It calls `SharedPlayerManager.shared.saveCurrentState()` immediately after every mutation (play, stop, setStream, status observers, server fallback, validation callbacks). This keeps widget and Live Activity state aligned.
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
///   - Does not expose listening habits to a remote service.
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
///   - Requires the app security model (`dallas`) to be in the authorized list.
/// - **DNSSEC-authenticated name resolution** (iOS 16+ / always on this deployment target):
///   - Streaming, validation HEAD, and server-ping sessions are created with
///     `URLSessionConfiguration.requiresDNSSECValidation = true` (via
///     ``SecurityConfiguration/makeSecureEphemeralConfiguration()``).
///   - Provides authenticated DNS before TLS + runtime certificate pinning.
///   - Lookup failures (including "DNSSEC unavailable from resolver") are transient.
/// - **Privacy-Safe Data Management**:
///   - Streaming state stored only in memory during use.
///   - No persistent traces of listening activity.
///   - Only stores an anonymous preference (mobile data notification dismissed).
/// - **Minimal Network Footprint**:
///   - Connects only to streaming servers.
///   - No telemetry or reporting endpoints.
///   - No unnecessary background network activity.
/// - **Minimal Anonymous Preferences**:
///   - Stores the user's cellular data permission preference (ternary: ask/alwaysAllow/sessionAllow) + legacy compat flag (migration only from prior boolean).
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


/// Manages direct audio streaming, security validation, network monitoring, and privacy protections for the Lutheran Radio app.
final class DirectStreamingPlayer: NSObject, @unchecked Sendable {
    private var isSSLHandshakeComplete = false
    private var certificateValidationTimer: Timer?
    private var hasStartedPlaying = false
    /// True while cold launch / stream-switch attach waits for `.readyToPlay` before the first audible kick.
    private var isDeferringFirstPlayKick = false
    /// True after the first non-empty ICY StreamTitle on the current attach (cold launch / stream switch).
    private(set) var hasReceivedLiveStreamMetadata = false
    
    // MARK: - Audio Session Properties
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var wasPlayingBeforeInterruption = false
    private var isHandlingInterruption = false
        
    /// Injectable closure for the current date, used for testing time-dependent logic.
    internal var currentDate: @Sendable () -> Date = { Date() }
    
    // Single declaration (no DEBUG/release duplication) for the few members that historically
    // needed relaxed visibility for test/diagnostic inspection. All other state is now declared once.
    internal var networkMonitor: NetworkPathMonitoring?
    internal var hasInternetConnection = true
    private var serverFailureCount: [String: Int] = [:]
    private var lastFailedServerName: String?
    private var currentSelectedServer: Server = servers[0]
    
    /// Track initialization and defer callbacks.
    private var isInitializing: Bool = true
    private var pendingStatusChanges: [(isPlaying: Bool, reasonKey: String?)] = []
    
    /// Simple last-value dedup for status emissions.
    /// Prevents identical consecutive (isPlaying, reasonKey) tuples from re-driving
    /// the delegate + UI + widget pipeline on every KVO jitter or repeated callback.
    private var lastEmittedStatus: (isPlaying: Bool, reasonKey: String?)?
    
    // Lightweight raw KVO dedup trackers (used inside the observer closures)
    private var lastObservedTimeControl: AVPlayer.TimeControlStatus?
    private var lastObservedItemStatus: AVPlayerItem.Status?
    
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
    
    // Public accessors for ViewController
    var lastFailedServer: String? { return lastFailedServerName }
    var selectedServerInfo: Server { return currentSelectedServer }

    // MARK: - Injected Dependencies (construction roots)
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

    // MARK: - Nested Configuration Types
    //
    // Stream URL construction, language/region mapping, Stream model, Server definitions,
    // and latency result type. All declared early (right after injected dependencies) for:
    // • Maximum locality with the code that consumes them
    // • Clean Xcode // MARK outline navigation
    // • Single place for the documented URL pattern + security_model injection rules
    //
    // All production URLs are built with the current `expectedSecurityModel` from
    // `SecurityConfiguration` (never hard-coded or duplicated elsewhere in this file).
    // See `Core/Configuration/SecurityConfiguration.swift`.

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
    // • Query parameter "security_model" = current expected security model (from SecurityConfiguration)
    //
    // This design achieves:
    // 1. Geographic load distribution (lower latency)
    // 2. Simple automatic failover (if one cluster is down, the other is used next launch)
    // 3. Future-proof version gating via DNS TXT record
    //
    // WHEN RELEASING A NEW SECURITY MODEL (certificate rotation, etc.):
    // 1. Update `expectedSecurityModel` in `Core/Configuration/SecurityConfiguration.swift`
    // 2. Add the new codename to the TXT record on securitymodels.lutheran.radio
    // 3. Append a row to the Security Model History table in README.md
    // 4. Ship the app update → users on the new version will validate against the new model
    //
    // DO NOT reuse old codenames — see the history table in README.md to avoid collisions.
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
            
            // This construction is guaranteed to succeed with valid inputs.
            // We use a helper so we have a single place for all hardcoded URL fallbacks.
            return components.url ?? makeURL("https://livestream.lutheran.radio")
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
        Stream(title: String(localized: "lutheran_radio_title", defaultValue: "Lutheran Radio", table: "Localizable", comment: "Title for Lutheran Radio") + " - " +
               String(localized: "language_english", defaultValue: "English", table: "Localizable", comment: "English language option"),
               language: String(localized: "language_english", defaultValue: "English", table: "Localizable", comment: "English language option"),
               languageCode: "en",
               flag: "🇺🇸"),
        Stream(title: String(localized: "lutheran_radio_title", defaultValue: "Lutheran Radio", table: "Localizable", comment: "Title for Lutheran Radio") + " - " +
               String(localized: "language_german", defaultValue: "German", table: "Localizable", comment: "German language option"),
               language: String(localized: "language_german", defaultValue: "German", table: "Localizable", comment: "German language option"),
               languageCode: "de",
               flag: "🇩🇪"),
        Stream(title: String(localized: "lutheran_radio_title", defaultValue: "Lutheran Radio", table: "Localizable", comment: "Title for Lutheran Radio") + " - " +
               String(localized: "language_finnish", defaultValue: "Finnish", table: "Localizable", comment: "Finnish language option"),
               language: String(localized: "language_finnish", defaultValue: "Finnish", table: "Localizable", comment: "Finnish language option"),
               languageCode: "fi",
               flag: "🇫🇮"),
        Stream(title: String(localized: "lutheran_radio_title", defaultValue: "Lutheran Radio", table: "Localizable", comment: "Title for Lutheran Radio") + " - " +
               String(localized: "language_swedish", defaultValue: "Swedish", table: "Localizable", comment: "Swedish language option"),
               language: String(localized: "language_swedish", defaultValue: "Swedish", table: "Localizable", comment: "Swedish language option"),
               languageCode: "sv",
               flag: "🇸🇪"),
        Stream(title: String(localized: "lutheran_radio_title", defaultValue: "Lutheran Radio", table: "Localizable", comment: "Title for Lutheran Radio") + " - " +
               String(localized: "language_estonian", defaultValue: "Estonian", table: "Localizable", comment: "Estonian language option"),
               language: String(localized: "language_estonian", defaultValue: "Estonian", table: "Localizable", comment: "Estonian language option"),
               languageCode: "et",
               flag: "🇪🇪"),
    ]

    // MARK: - Initial language helpers (centralized for main-app reseed + cold launch)

    /// Best initial radio stream languageCode for the main app UI (LanguageSelectorView needle position,
    /// early cold-launch seeds, background images, and the post-clear cold-launch auto-play choice).
    ///
    /// Prefers the localizations that the *main bundle actually resolved* for the current run
    /// (Bundle.main.preferredLocalizations, in user preference order). This captures the effective
    /// app language the UI is presenting ("Finnish on a fi device", simulator Application Language
    /// overrides via -AppleLanguages, etc.). We walk the full ordered list and return the first
    /// subtag that matches one of our five supported radio streams (en, de, fi, sv, et). This ensures
    /// the initial needle and auto-play stream match the localized experience when the presented
    /// language is a supported radio language.
    ///
    /// Falls back to walking the user's `Locale.preferredLanguages` (the list that also drives
    /// Localizable.xcstrings), then Locale.current. Ultimate fallback "en".
    ///
    /// This produces a user-friendly starting selection on first-run or after privacy clear,
    /// while still being a non-identifying default.
    ///
    /// Distinct from widget privacy paths: `SharedPlayerManager.preferredWidgetLanguage()` (and all
    /// widget/Live Activity providers) intentionally hard-fallback to "en" with *no* device locale
    /// probing when `loadPersistedWidgetState()` is absent (or hasActiveWidgets is false post-clear).
    /// This prevents writing any language signal into the App Group when no widgets are configured
    /// (writes suppressed). The main-app path (preferredMainAppInitialLanguageCode) always uses
    /// bestInitial on no-snapshot so post-clear reseed + launch play get the right lang.
    static func bestInitialLanguageCode() -> String {
        let supported = Set(Self.availableStreams.map { $0.languageCode })

        // 1. Bundle's resolved preferredLocalizations first (the localizations the app actually
        //    selected for strings/UI this run). Walking the full list (not just .first) gives the
        //    highest user-preference radio lang that the bundle accepted, which reliably reflects
        //    simulator scheme overrides and device UI language even when Locale.preferredLanguages
        //    leads with the dev language or another entry.
        for raw in Bundle.main.preferredLocalizations {
            let candidate = raw.split(separator: "-").first.map(String.init) ?? raw
            if supported.contains(candidate) {
                return candidate
            }
        }

        // 2. User's ordered preferredLanguages (drives strings + explicit user ordering).
        for raw in Locale.preferredLanguages {
            // preferredLanguages values are BCP-47-like: "fi", "fi-FI", "en-US", "zh-Hans-CN" etc.
            let candidate = raw.split(separator: "-").first.map(String.init) ?? raw
            if supported.contains(candidate) {
                return candidate
            }
        }

        // 3. Last-chance current locale subtag.
        if let current = Locale.current.language.languageCode?.identifier,
           supported.contains(current) {
            return current
        }

        return "en"
    }

    /// Returns the index of the stream for the given languageCode (suitable for LanguageSelectorView
    /// and selectedStreamIndex). Returns 0 (English) if the code is not one of the supported streams.
    /// Replaces all the previous repeated `firstIndex(where: ...) ?? 0` for initial selection paths.
    static func indexForLanguageCode(_ languageCode: String) -> Int {
        availableStreams.firstIndex(where: { $0.languageCode == languageCode }) ?? 0
    }

    /// Returns the Stream matching the languageCode, or the English default (index 0) if not found.
    /// Used for safe lookup from a code we believe is valid (initial choice, model-only set, etc.).
    static func streamForLanguageCode(_ languageCode: String) -> Stream {
        availableStreams.first(where: { $0.languageCode == languageCode }) ?? availableStreams[0]
    }

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
    
    private var lastServerSelectionTime: Date?
    private let serverSelectionCacheDuration: TimeInterval = 7200 // two hours
    internal var serverSelectionWorkItem: DispatchWorkItem?
    internal var retryWorkItem: DispatchWorkItem?
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
    private func ensureOptimalServerSelected() async {
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
    private func urlWithOptimalServer(for stream: Stream) async -> URL {
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
    
    private func fetchAllServerLatencies() async -> [PingResult] {
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
    
    private func ping(server: Server) async -> PingResult {
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

    // MARK: - Error & Retry State (simple scalars)
    private var lastError: Error?
    
    private var initialPlaybackRetryCount = 0
    private let maxInitialRetries = 2

    /// Whether the current attach is still within its initial per-stream recovery budget.
    ///
    /// True after `resetInitialPlaybackCountersForNewStream()` (called by `switchToStream`
    /// for language changes and cold-launch paths) until either:
    /// - `hasStartedPlaying` becomes true after stable playback, or
    /// - the retry budget is exhausted.
    ///
    /// Used by `RadioPlayerCoordinator` (and internal recovery paths) as a cheap predicate
    /// to suppress user-visible transient failure surfaces ("unavailable", grey pause, alert)
    /// for normal ICY/Fig/AAC decoder noise on fresh items. This is the defensive complement
    /// to the centralized `handleItemStatusFailure` logic.
    ///
    /// - Important: This is **not** a general "is playing" flag. It specifically protects the
    ///   early window documented in `switchToStream` and `resetInitialPlaybackCountersForNewStream`.
    ///
    /// - SeeAlso: `switchToStream(_:)`, `resetInitialPlaybackCountersForNewStream()`,
    ///   `handleItemStatusFailure(_:)`, `RadioPlayerCoordinator.handleStatusChange`,
    ///   CODING_AGENT.md (Single Source of Truth + explicit transient modeling)
    var isInInitialRecoveryWindow: Bool {
        !hasStartedPlaying && initialPlaybackRetryCount < maxInitialRetries
    }

    /// At most one `recreatePlayerItem()` body may run at a time (MainActor only).
    private var recreateInFlight = false
    /// Coalesces rapid early `timeControlStatus` drops on a fresh ICY item into one recovery action.
    private var earlyICYDropRecreateTask: Task<Void, Never>?
    /// Set synchronously at intentional stop; cleared when a new secured `playerItem` is attached.
    /// Prevents stale `timeControlStatus` KVO and debounced recreate tasks from running after teardown.
    @MainActor private var isPlaybackTeardownActive = false
    /// User-initiated pause kept the secured `AVPlayerItem` alive for gapless same-stream resume.
    @MainActor private var isSoftPaused = false
    /// Language of the secured `AVPlayerItem` currently attached (`nil` after hard teardown).
    @MainActor private var attachedItemLanguageCode: String?
    /// Cancellable startup safety-net work (cold launch / stream-switch first attach only).
    private var startupSafetyNetWorkItem: DispatchWorkItem?
    
    var isPlaying: Bool {
        return (player?.rate ?? 0) > 0 && player?.currentItem?.status == .readyToPlay
    }
    
    // Relaxed visibility in Debug builds only — for test / diagnostic inspection.
    // (See the playerItem/metadataOutput block below for the complete list of intentional visibility differences.)
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
    
    var player: AVPlayer?

    // Concurrency queues — declared once to avoid duplicated queue declarations between DEBUG and release builds.
    // These three are always private; they are never exposed for testing or external use.
    private let audioQueue = DispatchQueue(label: "radio.lutheran.audio", qos: .userInteractive)
    private let sslValidationQueue = DispatchQueue(label: "radio.lutheran.ssl", qos: .userInitiated)
    private let networkQueue = DispatchQueue(label: "radio.lutheran.network", qos: .utility)

    // Retained only for the historical "compatibility" comment. All real audio/SSL work uses the queues above.
    // Made private in all configurations (no external usage observed in the codebase).
    private let playbackQueue = DispatchQueue(label: "radio.lutheran.playback", qos: .userInteractive)

    // MARK: - Playback Engine (player, queues, observers, resource loaders)
    #if DEBUG
    // Relaxed visibility in Debug builds only — for test / diagnostic inspection of the streaming engine.
    // playerItem and metadataOutput (together with selectedStream above) are the only stored properties
    // that intentionally differ in visibility between DEBUG and release.
    var playerItem: AVPlayerItem?
    var metadataOutput: AVPlayerItemMetadataOutput?
    #else
    private var playerItem: AVPlayerItem?
    private var metadataOutput: AVPlayerItemMetadataOutput?
    #endif
    private var needsImmediateMetadataPush = false   // replaces time heuristic
    
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
    
    // Important: All AVPlayer operations must be on main thread
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

    /// AVPlayer KVO (`timeControlStatus`, buffer empty, etc.) can emit `status_stopped` /
    /// `status_buffering` for sub-second ICY/Fig glitches while `PlayerVisualState` is still `.playing`.
    /// Suppresses the full delegate → UI → widget pipeline and re-asserts Now Playing playback rate
    /// so Control Center / lock screen do not flash an extra pause.
    @MainActor
    private func shouldSuppressTransientKVOStatus(isPlaying: Bool, reasonKey: String?) async -> Bool {
        guard !isPlaying, let reasonKey else { return false }
        switch reasonKey {
        case "status_stopped", "status_buffering":
            break
        default:
            return false
        }
        return await SharedPlayerManager.shared.currentVisualState.isActivelyPlaying
    }

    /// Returns true when a stable connect/buffer status should not trigger widget persistence:
    /// `isPlaying` is false but `currentVisualState` is already `.prePlay` or `.playing`.
    @MainActor
    private func shouldSkipWidgetSaveForTransientConnectOrBuffer(
        isPlaying: Bool,
        reasonKey: String?
    ) async -> Bool {
        guard !isPlaying, let reasonKey else { return false }
        switch reasonKey {
        case "status_connecting", "status_buffering":
            break
        default:
            return false
        }
        let visual = await SharedPlayerManager.shared.currentVisualState
        return visual == .prePlay || visual == .playing
    }

    @MainActor
    private func deliverStatusChange(isPlaying: Bool, reasonKey: String?) {
        let didEmit = invokeStatusCallbacks(isPlaying: isPlaying, reasonKey: reasonKey)

        // Uses exact keys from Localizable.xcstrings. Only force a widget save on real emissions.
        if didEmit {
            let isStableState = isPlaying ||
            reasonKey == "status_playing" ||
            reasonKey == "status_paused" ||
            reasonKey == "status_stopped" ||
            reasonKey == "status_paused_call" ||
            reasonKey == "status_thermal_paused" ||
            reasonKey == "status_no_internet" ||
            reasonKey == "status_security_failed" ||
            reasonKey == "status_stream_unavailable" ||
            reasonKey == "status_connecting" ||
            reasonKey == "status_ssl_transition" ||
            reasonKey == "status_buffering" ||
            reasonKey == "status_failed"

            if isStableState {
                Task {
                    if await self.shouldSkipWidgetSaveForTransientConnectOrBuffer(
                        isPlaying: isPlaying,
                        reasonKey: reasonKey
                    ) {
                        #if DEBUG
                        print("[DirectStreamingPlayer] safeOnStatusChange: transient \(reasonKey ?? "nil") — skipping widget save (visual SSOT prePlay/playing)")
                        #endif
                        return
                    }
                    let vis = await SharedPlayerManager.shared.currentVisualState
                    if vis.mustSuppressResurrection {
                        #if DEBUG
                        print("[DirectStreamingPlayer] safeOnStatusChange: stable stopped (isPlaying=\(isPlaying), key='\(reasonKey ?? "nil")') while sticky pause — skipping force save (explicit stop path already persisted correct visual+lang)")
                        #endif
                    } else {
                        #if DEBUG
                        print("[DirectStreamingPlayer] safeOnStatusChange: STABLE final state (isPlaying=\(isPlaying), key='\(reasonKey ?? "nil")') → forcing widget save")
                        #endif
                        await SharedPlayerManager.shared.saveCurrentState()
                    }
                }
            } else {
                #if DEBUG
                print("[DirectStreamingPlayer] safeOnStatusChange: transient state (isPlaying=\(isPlaying), key='\(reasonKey ?? "nil")') → skipping widget save")
                #endif
            }
        }
    }

    func safeOnStatusChange(isPlaying: Bool, reasonKey: String?) {
        // SAFETY: Never feed status into the delegate → UI → widget / Live Activity / Now Playing pipeline
        // when running under UI test mode. This is the root cause of:
        //   • audible radio stream before tests execute
        //   • WidgetRenderer_Activities 0x8BADF00D watchdog crash (Chrono renderer woken at launch)
        //
        // Why both checks:
        //   • `isTesting` delegates to SharedPlayerManager.isRunningInUITestMode (the SSOT)
        //   • Direct check on the SSOT is defense-in-depth in case isTesting is read before
        //     the first access or during early static/coordinator construction.
        // The SSOT itself prefers the explicit "-UITestMode" launch argument.
        //
        // See: SharedPlayerManager.isRunningInUITestMode, ViewController cold-launch guard,
        // CODING_AGENT.md (test isolation requirements).
        if isTesting || SharedPlayerManager.isRunningInUITestMode {
            return
        }

        DispatchQueue.main.async {
            if self.isInitializing {
                self.pendingStatusChanges.append((isPlaying, reasonKey))
            } else {
                Task { @MainActor in
                    if await self.shouldSuppressTransientKVOStatus(isPlaying: isPlaying, reasonKey: reasonKey) {
                        #if DEBUG
                        print("[DirectStreamingPlayer] safeOnStatusChange: transient \(reasonKey ?? "nil") while visualState .playing → suppress pipeline")
                        #endif
                        #if LUTHERAN_MAIN_APP
                        await SharedPlayerManager.shared.updateNowPlayingInfo()
                        #endif
                        return
                    }
                    self.deliverStatusChange(isPlaying: isPlaying, reasonKey: reasonKey)
                }
            }
        }
    }
    
    /// Returns true if the status was actually emitted (not a duplicate).
    @discardableResult
    private func invokeStatusCallbacks(isPlaying: Bool, reasonKey: String?) -> Bool {
        // Simple last-value dedup: identical consecutive tuples are a no-op.
        // This prevents KVO jitter and duplicate callback storms from re-driving
        // the entire delegate → UI → widget pipeline.
        let incoming = (isPlaying, reasonKey)
        if lastEmittedStatus?.isPlaying == isPlaying && lastEmittedStatus?.reasonKey == reasonKey {
            return false
        }
        lastEmittedStatus = incoming
        
        // Compute localized string once for UI / logs / delegate (backward compatible)
        let localizedStatus = reasonKey.map { String(localized: String.LocalizationValue($0), table: "Localizable") } ?? ""
        
        onStatusChange?(isPlaying, localizedStatus)
        
        // Pass the raw key to the delegate (ViewController expects the key, not the translated text)
        delegate?.onStatusChange(isPlaying ? .playing : .stopped, reasonKey: reasonKey)
        
        #if DEBUG
        print("[DirectStreamingPlayer] invokeStatusCallbacks → isPlaying=\(isPlaying), reasonKey='\(reasonKey ?? "nil")', localized='\(localizedStatus)'")
        #endif
        return true
    }
    
    private func safeOnMetadataChange(metadata: String?) {
        #if LUTHERAN_MAIN_APP
        Task {
            await SharedPlayerManager.shared.didUpdateStreamMetadata(metadata)
        }
        #endif
        Task { @MainActor [weak self] in
            self?.onMetadataChange?(metadata)
        }
    }
    
    weak var delegate: StreamingPlayerDelegate?
    
    /// Sets the delegate for callbacks (e.g., status updates).
    func setDelegate(_ delegate: StreamingPlayerDelegate?) {
        self.delegate = delegate
    }
    
    public func resetTransientErrors() {
        // Reset transient state in the shared validator
        // (Permanent failures stay permanent until app restart or model rotation)
        Task {
            await SecurityModelValidator.shared.resetTransientState()
        }
        
        // Also clear any local permanent error flag if your UI/playback uses it
        hasPermanentError = false
        
        // Clear dedup state so post-reset status changes are not incorrectly suppressed.
        lastEmittedStatus = nil
        lastObservedTimeControl = nil
        lastObservedItemStatus = nil
        
        #if DEBUG
        print("[DirectStreamingPlayer] [Playback] Requested reset of transient security validation state (NOTE: initialPlaybackRetryCount and hasStartedPlaying are deliberately NOT reset here — use resetInitialPlaybackCountersForNewStream() for user stream switches)")
        #endif
    }

    /// Called on every user-initiated language/stream switch (flag-tap via completeStreamSwitch,
    /// widget via handleWidgetSwitchToLanguage, Siri/shortcut, or any path that ends up
    /// calling `switchToStream`).
    ///
    /// Gives the *new* stream a clean startup attempt budget (retryCount = 0) so that
    /// transient ICY noise or safety-net exhaustion from the *previous* stream cannot
    /// trigger a false-positive status_stream_unavailable (red banner + popup).
    ///
    /// Resets cold-launch recovery counters so each stream switch gets a fresh attempt budget.
    /// The budget is observable via `isInInitialRecoveryWindow`, which the coordinator
    /// uses to suppress transient failure UI during the window.
    ///
    /// AGENT NOTE: Prefer calling `switchToStream(_:)` (or the higher-level coordinator paths)
    /// rather than manually calling the individual reset + stop steps.
    func resetInitialPlaybackCountersForNewStream() {
        initialPlaybackRetryCount = 0
        hasStartedPlaying = false   // defensive; the preceding stop() already does this for most paths
        isDeferringFirstPlayKick = false
        hasReceivedLiveStreamMetadata = false
        Task { @MainActor [weak self] in
            self?.cancelEarlyICYDropRecreate()
        }

        #if DEBUG
        print("[DirectStreamingPlayer] [Playback] resetInitialPlaybackCountersForNewStream — fresh startup budget for stream switch (retryCount reset to 0)")
        #endif
    }

    func isLastErrorPermanent() async -> Bool {
        await SecurityModelValidator.shared.isPermanentlyInvalid
    }
    
    private override init() {
        self.audioSession = .sharedInstance()
        self.pathMonitor = NWPathMonitorAdapter()
        
        // Use the centralized preference-respecting helper (bestInitialLanguageCode).
        // Previously duplicated fragile Locale.current + ?? [0] logic here and in the other init.
        selectedStream = Self.streamForLanguageCode(Self.bestInitialLanguageCode())
        
        // isTesting is now a computed property that delegates live to
        // SharedPlayerManager.isRunningInUITestMode (the SSOT). No assignment needed.
        
        super.init()
        
        // Now async (uses configureAudioSessionAsync under the hood). Fire-and-forget is safe here:
        // activation is non-blocking and any playback paths re-ensure / await as needed.
        Task { @MainActor in
            await setupAudioSession()
        }
        setupNetworkMonitoring()
        
        #if DEBUG
        print("[DirectStreamingPlayer] Player initialized, starting validation")
        #endif
        
        if hasInternetConnection && !isTesting {
            // Eager initial validation is skipped entirely under test (isTesting is sourced from
            // SharedPlayerManager.isRunningInUITestMode, which prefers "-UITestMode").
            // This avoids DNS TXT + security network I/O on every UITest launch before any test code runs.
            // Real validation still occurs for normal app cold launches (via SPM.play and other paths).
            Task { @MainActor in
                let isValid = await SecurityModelValidator.shared.validateSecurityModel()
                
                #if DEBUG
                print("[DirectStreamingPlayer] Initial validation completed: \(isValid)")
                #endif
                
                if isValid {
                    self.safeOnStatusChange(isPlaying: false, reasonKey: "status_connecting")
                } else {
                    let isPermanent = await SecurityModelValidator.shared.isPermanentlyInvalid
                    let statusKey = isPermanent ? "status_security_failed" : "status_no_internet"
                    self.safeOnStatusChange(isPlaying: false, reasonKey: statusKey)
                    
                    #if DEBUG
                    print("[DirectStreamingPlayer] Validation failed — permanent? \(isPermanent)")
                    #endif
                }
            }
        }
        // IMPORTANT: Emit *zero* status at init time under test (for the main shared instance
        // created via static let / designated init, used by coordinator/VC/VM).
        // Previous else-if/else here called safeOnStatusChange synchronously, feeding the
        // delegate → widget / Live Activity pipeline and contributing to renderer wake + audio side effects.
        // The hard guard in safeOnStatusChange + this structure ensures no init-time emissions.
        
        setupThermalProtection()
        
        // Clear dedup state so the first real post-init status always emits.
        lastEmittedStatus = nil
        lastObservedTimeControl = nil
        lastObservedItemStatus = nil
        
        isInitializing = false
        
        DispatchQueue.main.async {  // Defer to after init returns
            for change in self.pendingStatusChanges {
                // Updated to pass reasonKey (see property change below)
                self.invokeStatusCallbacks(isPlaying: change.isPlaying, reasonKey: change.reasonKey)
            }
            self.pendingStatusChanges = []
            
            // Fire-and-forget the final state save (post-init, no blocking needed)
            Task {
                await SharedPlayerManager.shared.saveCurrentState()
            }
        }
    }
    
    /// Sets up NWPathMonitor for network reachability changes.
    /// Single implementation (no DEBUG/release duplication).
    /// Uses `internal` visibility so `@testable` test targets can reach it when needed,
    /// while keeping the production surface minimal. All `#if DEBUG` is confined to logging.
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
        networkMonitor?.pathUpdateHandler = { [weak self] status in
            guard let self else {
                #if DEBUG
                print("[DirectStreamingPlayer] [Network] Skipped path update: self is nil")
                #endif
                return
            }

            let wasConnected = self.hasInternetConnection
            self.hasInternetConnection = status == .satisfied

            #if DEBUG
            print("[DirectStreamingPlayer] [Network] Status: \(self.hasInternetConnection ? "Connected" : "Disconnected")")
            #endif

            if self.hasInternetConnection && !wasConnected {
                // ── Reconnect case ──
                #if DEBUG
                print("[DirectStreamingPlayer] [Network] Connection restored, previous server: \(self.currentSelectedServer.name)")
                print("[DirectStreamingPlayer] [Network] Cleared server selection cache + failure counts")
                #endif

                self.lastServerSelectionTime = nil
                self.serverFailureCount.removeAll()

                // Reset transient security state + revalidate
                Task {
                    await SecurityModelValidator.shared.resetTransientState()

                    #if DEBUG
                    print("[DirectStreamingPlayer] [Network] Invalidated security model validation cache (transient reset)")
                    #endif

                    let isValid = await SecurityModelValidator.shared.validateSecurityModel()

                    #if DEBUG
                    print("[DirectStreamingPlayer] [Network] Revalidation result on reconnect: \(isValid)")
                    #endif

                    if !isValid {
                        let isPermanent = await SecurityModelValidator.shared.isPermanentlyInvalid

                        let statusKey = isPermanent ? "status_security_failed" : "status_no_internet"

                        DispatchQueue.main.async {
                            self.safeOnStatusChange(
                                isPlaying: false,
                                reasonKey: statusKey
                            )
                        }
                    } else if self.player?.rate ?? 0 == 0, !self.hasPermanentError {
                        // Auto-replay if previously playing / ready
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
            else if !self.hasInternetConnection && wasConnected {
                // ── Disconnect case ──
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
    
    private func setupThermalProtection() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            
            let thermalState = ProcessInfo.processInfo.thermalState
            
            // ── Device overheating ─────────────────────────────────────
            if thermalState == .serious || thermalState == .critical {
                if self.isPlaying {
                    Task { @MainActor in
                        self.stop()                                 // sync
                        await SharedPlayerManager.shared.setVisualState(.thermalPaused)
                    }
                }
                return
            }
            
            // ── Device cooled down again ───────────────────────────────
            if thermalState == .nominal || thermalState == .fair {
                Task { @MainActor in
                    // Must await actor-isolated property (Swift 6 rule)
                    if await SharedPlayerManager.shared.currentVisualState.shouldAutoResumeOnThermalRecovery {
                        // Set visual state *before* play() so UI turns green immediately
                        await SharedPlayerManager.shared.setVisualState(.playing)
                        
                        let success = await self.play()
                        
                        if !success {
                            await SharedPlayerManager.shared.setVisualState(.userPaused)
                        }
                    }
                }
            }
        }
    }
    
    init(audioSession: AVAudioSession = .sharedInstance(), pathMonitor: NetworkPathMonitoring = NWPathMonitorAdapter()) {
        self.audioSession = audioSession
        self.pathMonitor = pathMonitor
        
        // Use the centralized preference-respecting helper (bestInitialLanguageCode).
        // Previously duplicated fragile Locale.current + ?? [0] logic here and in the designated init.
        selectedStream = Self.streamForLanguageCode(Self.bestInitialLanguageCode())
        
        // isTesting is now a computed property that delegates live to
        // SharedPlayerManager.isRunningInUITestMode (the SSOT). No assignment needed.
        
        super.init()
        
        // Now async (uses configureAudioSessionAsync under the hood). Fire-and-forget is safe here:
        // activation is non-blocking and any playback paths re-ensure / await as needed.
        Task { @MainActor in
            await setupAudioSession()
        }
        setupNetworkMonitoring()
        
        // Observe Low Power Mode changes to dynamically adjust optimizations
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(energyEfficiencyChanged),
            name: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"),
            object: nil
        )
        
        #if DEBUG
        print("[DirectStreamingPlayer] Player initialized, starting validation")
        #endif
        
        if hasInternetConnection && !isTesting {
            // Eager initial validation is skipped entirely under test (isTesting via SharedPlayerManager.isRunningInUITestMode).
            // Matches the designated init() and prevents real DNS/security I/O + status callbacks
            // during unit tests (MockDirectStreamingPlayer path) and UI tests.
            Task { @MainActor in
                let isValid = await SecurityModelValidator.shared.validateSecurityModel()
                
                #if DEBUG
                print("[DirectStreamingPlayer] Initial validation completed: \(isValid)")
                #endif
                
                if isValid {
                    self.safeOnStatusChange(isPlaying: false, reasonKey: "status_connecting")
                } else {
                    // Optional: show appropriate failure state
                    let isPermanent = await SecurityModelValidator.shared.isPermanentlyInvalid
                    let statusKey = isPermanent ? "status_security_failed" : "status_no_internet"
                    self.safeOnStatusChange(
                        isPlaying: false,
                        reasonKey: statusKey
                    )
                }
            }
        }
        // IMPORTANT: No status emission at init time under test mode.
        // Previously an `else if isTesting` / `else` branch called safeOnStatusChange here,
        // which fed the delegate → UI → widget / Live Activity pipeline before any test code ran.
        // We must emit *zero* status from init when isTesting (sourced from the SSOT).
        // The hard guard inside safeOnStatusChange provides defense-in-depth for any other call sites.
    }
    
    /// Handles changes to Low Power Mode state.
    /// No immediate actions here; optimizations (e.g., longer retry intervals) are applied dynamically via isLowEfficiencyMode checks.
    /// This reduces unnecessary work in low-battery scenarios without interrupting core streaming.
    @objc private func energyEfficiencyChanged() {
        // No immediate action needed; the isLowEfficiencyMode property will be queried dynamically in retry/fallback spots
        #if DEBUG
        print("[DirectStreamingPlayer] Low Power Mode changed to: \(isLowEfficiencyMode ? "Enabled" : "Disabled")")
        #endif
    }
    
    /// Reusable @MainActor async helper for AVAudioSession configuration.
    ///
    /// This is the **single source of truth** for audio session category configuration
    /// and activation (and the planned deactivation surface).
    ///
    /// - Sets the `.playback` category (via the synchronous `setCategory`) **only** when
    ///   it is not already `.playback`. This follows Apple guidance for the initial
    ///   configuration while avoiding "called on the main thread while the audio session
    ///   is active" warnings from SessionCore during re-entrancy (route changes,
    ///   interruptions, stream switches, tuning sound setup, etc.).
    /// - On iOS 27.0 and later: activates via the non-blocking
    ///   `activateWithOptions:completionHandler:` (the async spelling) using a dynamic
    ///   runtime dispatch (see ``activateAsyncDynamic(session:wasAlreadyPlayback:)``).
    /// - On iOS 26.2 (deployment target): the activation is performed on a background
    ///   queue via `DispatchQueue.global` + continuation. This ensures the actual
    ///   `setActive` call is never executed while the main thread is blocked, eliminating
    ///   the runtime warning:
    ///   "This method can lead to UI unresponsiveness if called on the main thread.
    ///    Consider using the asynchronous activate/deactivate API instead."
    ///
    /// All audio activation paths (init setup, `play()`, `startPlayback`, stream switches,
    /// tuning sound, interruption recovery, route changes, category changes) must flow through
    /// this method, the thin `setupAudioSession()` wrapper, or (from ViewController) via
    /// `reconfigureAudioSession()`.
    ///
    /// Call sites are already structured as `Task { @MainActor in await ... }` or direct
    /// `await` from @MainActor contexts. The main thread remains responsive during activation.
    ///
    /// **Xcode / SDK compatibility (important for contributors):**
    /// This file is required to compile on both the minimum supported Xcode (26) and
    /// newer Xcode versions. The dynamic IMP dispatch is used so that a direct reference
    /// to the iOS 27 API never appears in source when built against the Xcode 26 SDK.
    /// When built with Xcode 27+, the `#available(iOS 27.0, *)` branch executes, but we
    /// deliberately continue using the runtime lookup instead of the typed API. This
    /// preserves the ability for the same source to build on Xcode 26.
    ///
    /// Runtime behavior:
    /// - On iOS 27.0+: real asynchronous activation via the framework completion handler.
    /// - On iOS 26.x: synchronous `setActive` is executed off the main thread (no main-thread warning).
    /// Local `AVAudioPlayer` usage (tuning clips) can still emit implicit diagnostics
    /// on 26.x even after explicit configuration.
    ///
    /// - Returns: `true` on successful category + activate; `false` on error or under `isTesting`.
    ///
    /// - Precondition: Must be called from a `@MainActor` context.
    /// - Important: Never call `setCategory` or `setActive` directly outside this helper.
    ///   Never replace the dynamic dispatch with a direct `activate(options:completionHandler:)`
    ///   call unless the minimum supported Xcode version is raised above 26.
    /// - Note: Respects `isTesting` (SSOT via `SharedPlayerManager.isRunningInUITestMode`) exactly.
    ///   Under test mode this is a no-op (returns `false`).
    /// - SeeAlso: ``setupAudioSession()``, ``deactivateAudioSessionAsync()``,
    ///   `ViewController.reconfigureAudioSession()`,
    ///   `ViewController.handleInterruption(_:)`, `ViewController.handleRouteChange(_:)`,
    ///   CODING_AGENT.md (AV session + documentation rules).
    @MainActor
    func configureAudioSessionAsync() async -> Bool {
        // Widget / extension safety (lightweight no-op path).
        // Primary protection: this file is excluded from LutheranRadioWidgetExtension target
        // via membershipExceptions (see project.pbxproj and CODING_AGENT.md cross-target rules).
        // If the file is ever accidentally compiled for an extension, this guard + the
        // early returns in init paths prevent AVAudioSession configuration in the wrong process.
        if Bundle.main.bundleURL.pathExtension == "appex" {
            return false
        }

        guard !isTesting else {
            #if DEBUG
            print("[DirectStreamingPlayer] Skipped audio session setup for tests...")
            #endif
            return false
        }
        
        let session = audioSession
        let wasAlreadyPlayback = session.category == .playback
        
        do {
            if !wasAlreadyPlayback {
                // Conditional to avoid SessionCore "while audio session is active" warnings
                // when reconfiguring an already-active playback session.
                try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
            }
            
            let activated: Bool
            if #available(iOS 27.0, *) {
                // iOS 27.0+: use the non-blocking async activation path.
                // We always resolve via dynamic dispatch (selector + IMP) rather than the
                // typed API. This is required so the identical source compiles on Xcode 26
                // (where the declaration does not exist in the SDK).
                // See the availability and compatibility notes on `configureAudioSessionAsync`.
                activated = await Self.activateAsyncDynamic(session: session, wasAlreadyPlayback: wasAlreadyPlayback)
            } else {
                // iOS 26.2 deployment fallback:
                // Perform setActive off the main thread. This eliminates the AVAudioSession
                // runtime diagnostic that is emitted when the synchronous API is invoked
                // directly from a main-thread / @MainActor context.
                activated = await Self.activateSynchronouslyOffMainThread(session: session)
            }
            return activated
        } catch {
            #if DEBUG
            print("[DirectStreamingPlayer] Failed to configure audio session: \(error.localizedDescription)")
            #endif
            return false
        }
    }

    /// Dynamic dispatch for `activateWithOptions:completionHandler:` using the raw IMP.
    ///
    /// This wrapper lets the project compile from a single source on both the minimum
    /// supported Xcode (26, against the iOS 26 SDK) *and* Xcode 27+ (against the iOS 27 SDK).
    ///
    /// - When built with Xcode 26 the iOS 27 API symbol does not exist, so any direct
    ///   call would fail to compile.
    /// - When built with Xcode 27+ the API is visible, but we intentionally keep using
    ///   the runtime `NSSelectorFromString` + `method(for:)` + `unsafeBitCast` path.
    ///   This guarantees the source remains buildable on Xcode 26 without `#if` / compiler
    ///   version conditionals.
    ///
    /// At runtime on iOS 27.0+, `responds(to:)` succeeds and the real asynchronous
    /// implementation is invoked.
    ///
    /// We use `method(for:)` + `unsafeBitCast` to the precise `@convention(c)` signature because
    /// the method takes a scalar `NSUInteger` (AVAudioSessionActivationOptions) as the first
    /// argument after SEL, followed by a block. The NSObject `perform(_:with:with:)` API always
    /// passes `id` arguments and has the wrong ABI, which produced crashes inside the handler
    /// closure on Xcode 27 beta + iOS 27 simulator.
    @available(iOS 27.0, *)
    private static func activateAsyncDynamic(session: AVAudioSession, wasAlreadyPlayback: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            let selector = NSSelectorFromString("activateWithOptions:completionHandler:")

            guard session.responds(to: selector),
                  let imp = unsafe session.method(for: selector) else {
                continuation.resume(returning: false)
                return
            }

            // SAFETY: unsafeBitCast of the IMP is required to obtain a callable function pointer
            // with the exact C ABI of the ObjC method (scalar UInt options + escaping block).
            //
            // This is the only technique that lets us invoke the iOS 27+ async activation API
            // while keeping the identical source compilable on both Xcode 26 (where the
            // declaration is absent from the SDK) and Xcode 27+. The cast is isolated to this
            // helper; the completion block is invoked exactly once by the framework.
            //
            // We deliberately pass the raw integer 0 instead of constructing the OptionSet type
            // (which would require the new SDK symbol).
            //
            // Do not replace this with a direct typed call to the public API. Doing so would
            // make the file unbuildable on the project's minimum supported Xcode (26).
            // See the full compatibility notes on `configureAudioSessionAsync`.
            typealias ActivateFn = @convention(c) (
                AnyObject,
                Selector,
                UInt, // AVAudioSessionActivationOptions raw value (.none == 0)
                @escaping @convention(block) (Bool, Error?) -> Void
            ) -> Void

            let activateWithOptions = unsafe unsafeBitCast(imp, to: ActivateFn.self)

            let handler: @convention(block) (Bool, Error?) -> Void = { success, error in
                if let error {
                    #if DEBUG
                    print("[DirectStreamingPlayer] Async activate failed: \(error.localizedDescription)")
                    #endif
                    continuation.resume(returning: false)
                } else {
                    #if DEBUG
                    if !wasAlreadyPlayback {
                        print("[DirectStreamingPlayer] Audio session configured + activated asynchronously")
                    }
                    #endif
                    continuation.resume(returning: success)
                }
            }

            // Invoke with explicit scalar 0 for options.
            activateWithOptions(session, selector, 0, handler)
        }
    }

    /// Off-main-thread wrapper for the synchronous `setActive(true)` on iOS 26.x.
    ///
    /// Executes `setActive` on a global concurrent queue (userInitiated QoS) and bridges
    /// the result back via continuation. This keeps the `@MainActor` caller responsive
    /// and prevents the AVAudioSession runtime warning that is emitted when the blocking
    /// API is invoked directly from the main thread.
    ///
    /// - Note: Only used in the `< iOS 27` fallback path inside ``configureAudioSessionAsync()``.
    /// - Returns: `true` if activation succeeded.
    private static func activateSynchronouslyOffMainThread(session: AVAudioSession) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try session.setActive(true, options: [])
                    continuation.resume(returning: true)
                } catch {
                    #if DEBUG
                    print("[DirectStreamingPlayer] setActive (off-main) failed: \(error.localizedDescription)")
                    #endif
                    continuation.resume(returning: false)
                }
            }
        }
    }

    // MARK: - System media session teardown (Now Playing hygiene)

    /// Hard-detaches the secured `AVPlayerItem` for privacy / cold-launch factory reset.
    ///
    /// Complements ``SharedPlayerManager/teardownNowPlayingSession()`` which clears
    /// `MPNowPlayingInfoCenter`. Safe when playback is already stopped or during privacy clear.
    ///
    /// - Postcondition: Player paused, current item nil, soft-pause stash cleared.
    /// - SeeAlso: ``teardownSystemMediaSession()``, ``deactivateAudioSessionAsync()``.
    @MainActor
    func teardownSystemMediaSessionSynchronously() {
        guard !isTesting else { return }

        player?.pause()
        player?.rate = 0.0
        player?.replaceCurrentItem(with: nil)
        playerItem = nil
        clearAttachedItemBinding()
        isSoftPaused = false
    }

    /// Full async teardown: synchronous player detach plus audio session deactivation.
    ///
    /// - SeeAlso: ``SharedPlayerManager/teardownNowPlayingSession()``.
    @MainActor
    func teardownSystemMediaSession() async {
        teardownSystemMediaSessionSynchronously()
        _ = await deactivateAudioSessionAsync()
    }

    // MARK: - Deactivation (symmetric to activation)

    /// Deactivates the audio session using the appropriate API for the runtime.
    ///
    /// - On iOS 27.0+: uses the non-blocking `deactivateWithOptions:completionHandler:` via dynamic dispatch.
    /// - On iOS 26.x: performs the synchronous `setActive(false)` off the main thread.
    ///
    /// All future explicit deactivation (e.g. on full stop, backgrounding with no active
    /// playback, or explicit teardown) must go through this method.
    ///
    /// - Returns: `true` on success (or no-op success under test/widget conditions).
    /// - SeeAlso: ``configureAudioSessionAsync()``
    @MainActor
    func deactivateAudioSessionAsync() async -> Bool {
        if Bundle.main.bundleURL.pathExtension == "appex" {
            return true
        }
        guard !isTesting else {
            #if DEBUG
            print("[DirectStreamingPlayer] Skipped audio session deactivation for tests...")
            #endif
            return true
        }

        let session = audioSession
        if #available(iOS 27.0, *) {
            return await Self.deactivateAsyncDynamic(session: session)
        } else {
            return await Self.deactivateSynchronouslyOffMainThread(session: session)
        }
    }

    @available(iOS 27.0, *)
    private static func deactivateAsyncDynamic(session: AVAudioSession) async -> Bool {
        await withCheckedContinuation { continuation in
            let selector = NSSelectorFromString("deactivateWithOptions:completionHandler:")

            guard session.responds(to: selector),
                  let imp = unsafe session.method(for: selector) else {
                continuation.resume(returning: false)
                return
            }

            // SAFETY: unsafeBitCast mirrors the pattern used for activation.
            // Required for exact C ABI (options + escaping completion block) and
            // dual Xcode 26/27+ source compatibility.
            typealias DeactivateFn = @convention(c) (
                AnyObject,
                Selector,
                UInt, // AVAudioSessionDeactivationOptions
                @escaping @convention(block) (Bool, Error?) -> Void
            ) -> Void

            let deactivateWithOptions = unsafe unsafeBitCast(imp, to: DeactivateFn.self)

            let handler: @convention(block) (Bool, Error?) -> Void = { success, error in
                if let error {
                    #if DEBUG
                    print("[DirectStreamingPlayer] Async deactivate failed: \(error.localizedDescription)")
                    #endif
                    continuation.resume(returning: false)
                } else {
                    #if DEBUG
                    print("[DirectStreamingPlayer] Audio session deactivated asynchronously")
                    #endif
                    continuation.resume(returning: success)
                }
            }

            deactivateWithOptions(session, selector, 0, handler)
        }
    }

    private static func deactivateSynchronouslyOffMainThread(session: AVAudioSession) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try session.setActive(false, options: [])
                    continuation.resume(returning: true)
                } catch {
                    #if DEBUG
                    print("[DirectStreamingPlayer] setActive(false) (off-main) failed: \(error.localizedDescription)")
                    #endif
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Thin async wrapper around ``configureAudioSessionAsync()``.
    ///
    /// Single owner for playback AVAudioSession category+activation for cold launch,
    /// stream switches, and tuning sound paths.
    ///
    /// Under `isTesting` (SSOT `SharedPlayerManager.isRunningInUITestMode`) this is a no-op.
    /// Prevents background audio side effects during tests / launch performance tests.
    ///
    /// - SeeAlso: ``configureAudioSessionAsync()``, `play()`, `startPlayback(context:)`.
    @MainActor
    func setupAudioSession() async {
        // Widget / extension safety: no-op when running in appex (see configureAudioSessionAsync).
        // The #available(iOS 27.0, *) + dynamic dispatch logic lives only inside the
        // configure implementation. It is never reached from widget extension compilations
        // (file excluded from that target) and is carefully written for dual Xcode 26 / 27+
        // source compatibility.
        if Bundle.main.bundleURL.pathExtension == "appex" {
            return
        }
        _ = await configureAudioSessionAsync()
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
                    self.safeOnStatusChange(isPlaying: false, reasonKey: "status_security_failed")  // ← fixed
                }
                
                #if DEBUG
                print("[DirectStreamingPlayer] [Periodic Validation] Certificate validation failed → stopping stream for URL: \(urlToValidate)")
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
        // UI Test isolation (defense-in-depth).
        // Even if a recovery or network-restore path reaches here, never start real playback.
        // Visual state for assertions is driven exclusively through SharedPlayerManager.
        guard !isTesting else {
            #if DEBUG
            print("[DirectStreamingPlayer] play() — isTesting, early return (no AVPlayer, no audio session, no network)")
            #endif
            return false
        }

        // === Important guard : Driven by authoritative playback intent ===
        // This is the first execution-engine site wired to `currentPlaybackIntent` via
        // the new `canProceedWithPlayback()` helper. It replaces the prior ad-hoc visualState
        // derivation for this narrow top-level path.
        //
        // Sticky `.userPaused` / `.securityLocked` behavior is preserved exactly (the helper
        // returns false for those states, matching the old `shouldAutoPlayOrResume` rules).
        // This prevents "play-on-pause resurrection" after explicit user pause.
        guard await SharedPlayerManager.shared.canProceedWithPlayback() else {
            #if DEBUG
            print("🚫 [Play Guard] Blocked by playbackIntent = \(await SharedPlayerManager.shared.currentPlaybackIntent)")
            #endif
            safeOnStatusChange(isPlaying: false, reasonKey: "status_paused")   // ← changed
            return false
        }
        
        guard !isCurrentlyAttemptingPlayback else {
            #if DEBUG
            print("[DirectStreamingPlayer] [Playback Guard] Already attempting playback — ignoring duplicate call")
            #endif
            return false
        }
        
        isCurrentlyAttemptingPlayback = true
        defer { isCurrentlyAttemptingPlayback = false }
        
        safeOnStatusChange(isPlaying: true, reasonKey: "status_connecting")   // ← changed
        SharedPlayerManager.shared.saveFireAndForget()
        
        let isValid = await SecurityModelValidator.shared.isCurrentlyValid()
        guard isValid else {
            let isPermanent = await SecurityModelValidator.shared.isPermanentlyInvalid
            let statusKey = isPermanent ? "status_security_failed" : "status_no_internet"
            safeOnStatusChange(isPlaying: false, reasonKey: statusKey)       // ← changed
            SharedPlayerManager.shared.saveFireAndForget()
            return false
        }
        
        #if DEBUG
        print("[DirectStreamingPlayer] Security validation passed — creating player for \(selectedStream.languageCode)")
        #endif
        
        let streamURL = await urlWithOptimalServer(for: selectedStream)
        await createAndStartPlayer(for: streamURL)

        await SharedPlayerManager.shared.saveCurrentState()
        return true
    }
    
    // MARK: - Main-Actor-Bound Player Creation (Swift 6 safe)

    @MainActor
    private func createAndStartPlayer(for url: URL) async {
        // UI Test isolation (defense-in-depth). play() already guards, but this protects
        // any future direct caller of the private helper.
        guard !isTesting else {
            #if DEBUG
            print("[DirectStreamingPlayer] createAndStartPlayer — isTesting, no-op")
            #endif
            return
        }

        // === Playback intent guard : Driven by authoritative playback intent ===
        // This catches all internal/resume paths that bypass the public play() method
        // (stream switches, tuning sound completion, audio session reactivation, etc.).
        // Now uses the intent helper (second execution-engine site wired to currentPlaybackIntent).
        // Sticky .userPaused / .securityLocked / .cleared (privacy clear) behavior preserved exactly.
        guard await SharedPlayerManager.shared.canProceedWithPlayback() else {
            #if DEBUG
            print("🚫 [Deep Play Guard] Blocked by playbackIntent = \(await SharedPlayerManager.shared.currentPlaybackIntent)")
            #endif
            safeOnStatusChange(isPlaying: false, reasonKey: "status_paused")  // ← fixed
            return
        }
        
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: .main)
        
        let playerItem = AVPlayerItem(asset: asset)
        self.playerItem = playerItem
        bindAttachedItemToSelectedStream()
        clearPlaybackTeardownGuard()
        
        if self.player == nil {
            self.player = AVPlayer(playerItem: playerItem)
        } else {
            self.player?.replaceCurrentItem(with: playerItem)
        }
        // === Important: Activate the audio session before playback (async, main-thread safe) ===
        let audioSessionOK = await configureAudioSessionAsync()
        #if DEBUG
        if audioSessionOK {
            print("[DirectStreamingPlayer] [MainActor] AVAudioSession activated successfully (.playback)")
        } else {
            print("[DirectStreamingPlayer] [MainActor] Failed to activate AVAudioSession")
        }
        #endif
        // ========================================================
        
        self.player?.play()

        #if DEBUG
        print("[DirectStreamingPlayer] ▶ [MainActor] AVPlayer created + play() called for \(url.lastPathComponent)")
        #endif

        // Do NOT call notifyMainApp here — let SharedPlayerManager do it
    }
    
    @MainActor
    private func preparePlayerItem(for url: URL) async {
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: .main)
        
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 15.0
        
        if self.player == nil {
            self.player = AVPlayer(playerItem: playerItem)
        } else {
            self.player?.replaceCurrentItem(with: playerItem)
        }
        self.playerItem = playerItem
        bindAttachedItemToSelectedStream()
        clearPlaybackTeardownGuard()
        
        setupPlaybackObservers()
        
        #if DEBUG
        print("[DirectStreamingPlayer] [MainActor] Player item prepared (no auto-play) for \(url.lastPathComponent)")
        #endif
    }

    // MARK: - Playback Setup (MainActor preferred path)

    @MainActor
    private func performOptimalServerSelectionAndFullPlaybackSetup() async -> Bool {
        guard !isTesting else {
            #if DEBUG
            print("[DirectStreamingPlayer] performOptimalServerSelectionAndFullPlaybackSetup — isTesting, no-op")
            #endif
            return false
        }

        #if DEBUG
        print("[DirectStreamingPlayer] [Playback Setup] Starting server selection + asset creation")
        #endif

        return await withCheckedContinuation { continuation in
            selectOptimalServer { [weak self] _ in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }

                let streamURL = self.selectedStream.url

                #if DEBUG
                print("[DirectStreamingPlayer] [Playback Setup] Selected URL: \(streamURL)")
                #endif

                // Everything that touches AVPlayer must run on MainActor
                Task { @MainActor [weak self] in
                    guard let self else {
                        continuation.resume(returning: false)
                        return
                    }

                    // 1. Audio Session (critical!) — now async to avoid main thread warnings
                    let audioOK = await configureAudioSessionAsync()
                    if !audioOK {
                        #if DEBUG
                        print("[DirectStreamingPlayer] AudioSession failed")
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
                    self.bindAttachedItemToSelectedStream()
                    self.clearPlaybackTeardownGuard()

                    // 3. Setup observers — BEFORE play()
                    self.setupPlaybackObservers()

                    // 4. Explicit play() — guaranteed on MainActor
                    self.player?.play()

                    #if DEBUG
                    print("[DirectStreamingPlayer] ▶ [Playback Setup] replaceCurrentItem + play() called on main actor")
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
        // Invalidate old ones first
        rateObserver?.invalidate()
        statusObserver?.invalidate()

        // Reset raw KVO trackers for the fresh observers (lastEmittedStatus is intentionally
        // left alone here — stream switches and stop/play handle the higher-level reset).
        lastObservedTimeControl = nil
        lastObservedItemStatus = nil

        #if DEBUG
        print("[DirectStreamingPlayer] 🛠 [DirectStreamingPlayer] setupPlaybackObservers() — setting up Swift-6-safe observers")
        #endif

        // === timeControlStatus observer (rateObserver) ===
        rateObserver = player?.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] observedPlayer, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }

                // Lightweight raw-value dedup in the KVO handler itself.
                let newTC = observedPlayer.timeControlStatus
                guard self.lastObservedTimeControl != newTC else { return }
                self.lastObservedTimeControl = newTC

                #if DEBUG
                print("[DirectStreamingPlayer] [KVO] timeControlStatus → \(newTC.rawValue) | rate: \(observedPlayer.rate)")
                #endif

                switch newTC {
                case .playing:
                    self.cancelEarlyICYDropRecreate()
                    // Important : KVO resurrection protection now driven by
                    // authoritative playback intent.
                    guard await SharedPlayerManager.shared.canProceedWithPlayback() else {
                        #if DEBUG
                        print("[DirectStreamingPlayer] [KVO] timeControlStatus.playing: resurrection suppressed by playbackIntent — enforcing pause")
                        #endif
                        if observedPlayer.rate > 0 {
                            observedPlayer.pause()
                            observedPlayer.rate = 0.0
                        }
                        return
                    }
                    guard observedPlayer.currentItem?.status == .readyToPlay else {
                        #if DEBUG
                        print("[DirectStreamingPlayer] [KVO] timeControlStatus.playing: ignoring until item ready (status=\(observedPlayer.currentItem?.status.rawValue ?? -1))")
                        #endif
                        return
                    }
                    self.safeOnStatusChange(isPlaying: true, reasonKey: "status_playing")   // ← fixed
                    self.hasStartedPlaying = true
                    self.stopBufferingTimer()
                    
                case .paused:
                    if !self.isPlaybackTeardownActive && observedPlayer.rate == 0.0 {
                        self.safeOnStatusChange(isPlaying: false, reasonKey: "status_stopped")   // ← fixed
                    }
                    
                    // observer hardening (event-driven, no new timers):
                    // React to early timeControlStatus drops on a fresh ICY item *before* any
                    // stable playing period has been achieved. This catches the exact transient
                    // ICY PUMP / FigStreamPlayer noise clusters (-12640, -12785, -12860, -12783,
                    // -15514 etc.) from manual-testing-works.txt that rarely set playerItem.error
                    // and therefore bypassed the existing bufferEmpty + stalled recreate paths.
                    // Reuses the same initialPlaybackRetryCount bound + canProceedWithPlayback()
                    // guard as the (now minimal) safety net. Purely reactive to the KVO symptom.
                    if !self.isPlaybackTeardownActive
                        && !self.hasStartedPlaying
                        && !self.isDeferringFirstPlayKick
                        && self.initialPlaybackRetryCount < self.maxInitialRetries {
                        self.scheduleEarlyICYDropRecreate(rate: observedPlayer.rate)
                    }
                    
                case .waitingToPlayAtSpecifiedRate:
                    self.safeOnStatusChange(isPlaying: false, reasonKey: "status_buffering")   // ← fixed
                    
                @unknown default:
                    break
                }
            }
        }
        
        // === item status observer (statusObserver) ===
        statusObserver = player?.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }

                // Lightweight raw-value dedup in the KVO handler itself.
                let newItemStatus = item.status
                if self.lastObservedItemStatus == newItemStatus {
                    // Raw status unchanged — the downstream tuple dedup in invokeStatusCallbacks
                    // will still catch any derived (isPlaying, reasonKey) duplicates.
                } else {
                    self.lastObservedItemStatus = newItemStatus
                }

                #if DEBUG
                print("[DirectStreamingPlayer] [KVO] Item status → \(newItemStatus.rawValue)")
                #endif

                switch newItemStatus {
                case .readyToPlay:
                    // First-play kick and status_playing emission are handled by addObservers'
                    // readyToPlay branch (single canonical path after startPlayback deferral).
                    break

                case .failed:
                    // Route through the canonical decision point.
                    //
                    // This is the first concrete step in the modest architectural consolidation.
                    // Previously this path unconditionally emitted "status_stream_unavailable"
                    // (bypassing the retry budget established by resetInitialPlaybackCountersForNewStream).
                    //
                    // The new handler applies the same early-window transient logic used by
                    // addObservers + the improved StreamErrorType classification.
                    // Real permanent failures still surface; normal fresh-item ICY noise
                    // triggers recreatePlayerItem() silently.
                    await self.handleItemStatusFailure(item)
                default:
                    break
                }
                
                await SharedPlayerManager.shared.saveCurrentState()
            }
        }
        
        // Ensure ICY metadata delegate is wired on the fresh player item.
        // This is the single canonical attachment point (tracked in `metadataOutput` for
        // proper cleanup in stop paths and idempotent re-attach on item replacement).
        ensureICYAttached()
    }

    // MARK: - Stream Switching (Single Source of Truth for engine prep)

    /// Prepares the engine for a user-initiated stream/language change (the canonical
    /// preparation step for all stream choice paths).
    ///
    /// This method is the **single place** that performs the common engine-side work
    /// required when the user (via flags, widget, Siri, shortcuts, etc.) selects a
    /// different Lutheran Radio stream:
    ///
    /// - Records the new selected stream via the model-only path (no AVPlayerItem is
    ///   created or attached yet — that happens later in `setStreamAndPlay` or `play()`).
    /// - Clears transient error state.
    /// - If the language actually changes, performs a silent `.streamSwitch` stop and
    ///   waits for completion.
    /// - Resets the per-stream playback attempt counters (`resetInitialPlaybackCountersForNewStream`)
    ///   so the new stream receives a fresh budget.
    ///
    /// - Parameter stream: The target stream.
    ///
    /// - Important: This performs **only engine preparation**. It does **not**:
    ///   - Start or attach playback.
    ///   - Play any tuning sound (that is main-app delight, owned by `RadioPlayerCoordinator`).
    ///   - Mutate `SharedPlayerManager` visual state, `currentPlaybackIntent`, or persisted snapshot.
    ///   - Update the language selector, background images, or any UI.
    ///   - Decide whether to call `resetToPrePlayForNewStream` or `play()`.
    ///
    /// Callers must `await` this when they need teardown to be complete before the next step
    /// (tuning, resetToPrePlay, or `play()`).
    ///
    /// Typical main-app usage (from `RadioPlayerCoordinator.completeStreamSwitch` — the
    /// canonical flag-tap orchestration):
    /// ```
    /// // (optimistic prePlay + hold may already be set by handleLanguageSelection)
    /// await streamingPlayer.switchToStream(stream)
    /// await playTuningSound(animateNeedleTo: index)
    /// if !holdActive {
    ///     await SharedPlayerManager.shared.resetToPrePlayForNewStream(...)
    /// }
    /// await SharedPlayerManager.shared.play()
    /// ```
    ///
    /// Widget / reconciliation path uses the engine method directly (no tuning):
    /// ```
    /// await streamingPlayer.switchToStream(targetStream)
    /// // ... index/background/UI ...
    /// if shouldResume { await resetToPrePlay...; await play() }
    /// ```
    ///
    /// - SeeAlso: `setSelectedStreamModelOnly(to:)`, `resetInitialPlaybackCountersForNewStream()`,
    ///   `SharedPlayerManager.resetToPrePlayForNewStream(preserveActiveSleepTimer:)`,
    ///   `SharedPlayerManager.play()`, `SharedPlayerManager.userRequestedPlay()`,
    ///   `SharedPlayerManager.switchToStream`,
    ///   `RadioPlayerCoordinator.completeStreamSwitch`,
    ///   `RadioPlayerCoordinator.switchToStreamFromWidget(to:index:actionId:)`,
    ///   `RadioPlayerCoordinator.handleWidgetSwitchToLanguage`,
    ///   `RadioPlayerCoordinator.handleLanguageSelection`,
    ///   <doc:Architecture>, CODING_AGENT.md (Single Source of Truth Principles).
    ///
    /// AGENT NOTE: This is the *only* place the four engine prep steps are allowed.
    /// All call sites (coordinator canonicals, SPM forwarding, Siri intents, Live Activity signals,
    /// cold-launch model seeding) must go through here. Never duplicate setModel + reset + stop + counterReset.
    /// The two RadioPlayerCoordinator canonicals (completeStreamSwitch for main-app flag taps,
    /// switchToStreamFromWidget for widget reconciliation) are the preferred callers for user-driven changes.
    /// Note: after `switchToStream` on an active-intent path, the subsequent direct `play()`
    /// is the internal continuation case (already-active playback intent); explicit starts
    /// use `userRequestedPlay()`. See the Precondition on `userRequestedPlay()`.
    @MainActor
    func switchToStream(_ stream: Stream) async {
        let previousLanguage = selectedStream.languageCode
        let newLanguage = stream.languageCode
        let isLanguageChange = previousLanguage != newLanguage

        // Set model first (matches the pattern used by the current coordinator switch paths).
        await setSelectedStreamModelOnly(to: stream)
        resetTransientErrors()

        if isLanguageChange {
            #if DEBUG
            print("[DirectStreamingPlayer] switchToStream — awaiting silent .streamSwitch stop (\(previousLanguage) → \(newLanguage))")
            #endif
            await withCheckedContinuation { continuation in
                stop(
                    reason: .streamSwitch,
                    completion: { continuation.resume() },
                    silent: true
                )
            }
        }

        resetInitialPlaybackCountersForNewStream()

        #if DEBUG
        print("[DirectStreamingPlayer] switchToStream engine prep complete for \(newLanguage)")
        #endif
    }
    
    // MARK: - Stream Switching (Single Source of Truth)

    /// Updates the selected stream model without creating or replacing an `AVPlayerItem`.
    /// Used on cold launch before tuning so the secured item is created once in `setStreamAndPlay`.
    func setSelectedStreamModelOnly(to stream: Stream) async {
        // Under test we still allow the pure model update (no network, no AV work).
        // ViewController already short-circuits before calling this in UITestMode, but
        // keeping the engine tolerant is useful for direct test injection.
        lastEmittedStatus = nil
        lastObservedTimeControl = nil
        lastObservedItemStatus = nil
        selectedStream = stream

        #if DEBUG
        print("[DirectStreamingPlayer] Stream model updated (no player item) for \(stream.language)")
        #endif
    }

    /// Updates the selected stream model and prepares the player.
    /// Does NOT start playback — call `play()` afterwards if needed.
    @MainActor
    func setStream(to stream: Stream) async {
        // UI Test isolation: prevent even model-only prepares from triggering
        // urlWithOptimalServer (which may ping) or AVURLAsset/resourceLoader work.
        guard !isTesting else {
            // Still update the model so that visual / language queries in tests see the intended value
            // if a test directly manipulates the player (rare). Most UI tests go through the coordinator/VM.
            selectedStream = stream
            #if DEBUG
            print("[DirectStreamingPlayer] setStream — isTesting, model updated but no network/asset work")
            #endif
            return
        }

        let modelLanguage = selectedStream.languageCode
        let attachedLanguage = attachedItemLanguageCode
        let newLanguage = stream.languageCode
        let attachedMismatch = attachedLanguage.map { $0 != newLanguage } ?? false
        let modelChanged = modelLanguage != newLanguage
        let needsCleanStop = attachedMismatch || modelChanged

        #if DEBUG
        let fromLanguage = attachedLanguage ?? modelLanguage
        print("ATOMIC STREAM SWITCH: \(fromLanguage) → \(newLanguage)")
        #endif

        if needsCleanStop {
            #if DEBUG
            if attachedMismatch {
                print("[DirectStreamingPlayer] Attached item language mismatch — performing clean stop")
            } else {
                print("[DirectStreamingPlayer] Real stream switch detected – performing clean stop")
            }
            #endif

            isSwitchingStream = true
            defer { isSwitchingStream = false }

            isSoftPaused = false

            if playerItem != nil || attachedLanguage != nil {
                stop(reason: .streamSwitch, silent: true)   // ← removed `await`
            }
        } else {
            #if DEBUG
            print("[DirectStreamingPlayer] Same stream or initial playback (\(newLanguage)) – skipping stop()")
            #endif
        }
        
        // Clear dedup state for the new stream context so the first status after the switch emits.
        lastEmittedStatus = nil
        lastObservedTimeControl = nil
        lastObservedItemStatus = nil

        // Update model
        selectedStream = stream

        // Secured AVURLAsset + resourceLoader path (same as cold-launch startPlayback and createAndStartPlayer).
        let url = await urlWithOptimalServer(for: stream)
        await preparePlayerItem(for: url)

        #if DEBUG
        print("[DirectStreamingPlayer] Stream model updated and secured AVPlayerItem prepared for \(stream.language)")
        #endif
    }

    /// Full atomic "switch stream + start playing" — this is what SharedPlayerManager should call
    @MainActor
    func setStreamAndPlay(to stream: Stream, context: PlaybackAttachContext = .coldLaunch) async {
        // UI Test isolation: never attach real items or start playback from the engine.
        // SharedPlayerManager.play() already short-circuits before reaching here for
        // explicit test taps; this guard protects any direct callers or future paths.
        guard !isTesting else {
            #if DEBUG
            print("[DirectStreamingPlayer] setStreamAndPlay — isTesting, no-op (no network, no AVPlayer work)")
            #endif
            return
        }

        await setStream(to: stream)

        // Now safely start playback
        await startPlayback(context: context)
    }

    /// Cancels any pending startup safety-net recreate (e.g. before sleep-timer scheduling).
    func cancelPendingStartupRecovery() {
        Task { @MainActor [weak self] in
            self?.cancelStartupSafetyNet()
        }
    }

    /// True when a soft-paused or attached item targets a different language than `selectedStream`.
    @MainActor
    func softPauseResumeRequiresStreamReattach() -> Bool {
        guard let attached = attachedItemLanguageCode else { return false }
        return attached != selectedStream.languageCode
    }

    @MainActor
    private func bindAttachedItemToSelectedStream() {
        attachedItemLanguageCode = selectedStream.languageCode
    }

    @MainActor
    private func clearAttachedItemBinding() {
        attachedItemLanguageCode = nil
    }

    /// Resumes a same-stream pause without recreating the secured `AVPlayerItem`.
    @MainActor
    func resumeFromSoftPauseIfAvailable() async -> Bool {
        // UI Test isolation: never resume real audio from soft-pause under test.
        guard !isTesting else { return false }

        guard isSoftPaused, playerItem != nil, player?.currentItem != nil else { return false }
        guard !softPauseResumeRequiresStreamReattach() else {
            isSoftPaused = false
            #if DEBUG
            print("[DirectStreamingPlayer] Soft-pause resume declined — attached item language (\(attachedItemLanguageCode ?? "nil")) != selected stream (\(selectedStream.languageCode))")
            #endif
            return false
        }
        guard await SharedPlayerManager.shared.canProceedWithPlayback() else { return false }

        isSoftPaused = false
        cancelStartupSafetyNet()

        guard let player else { return false }
        player.play()
        player.rate = 1.0
        player.playImmediately(atRate: 1.0)
        safeOnStatusChange(isPlaying: true, reasonKey: "status_playing")
        hasStartedPlaying = true
        await SharedPlayerManager.shared.setPlaying()

        #if DEBUG
        print("[DirectStreamingPlayer] Resumed from soft pause — skipped item recreation")
        #endif
        return true
    }
    
    #if DEBUG
    private func debugAttachContextLabel(_ context: PlaybackAttachContext) -> String {
        switch context {
        case .coldLaunch: return "cold launch"
        case .streamSwitch: return "stream switch"
        case .resume: return "resume"
        }
    }
    #endif

    private func ensurePlayerExists() {
        if self.player == nil {
            #if DEBUG
            print("[DirectStreamingPlayer] Creating new AVPlayer instance")
            #endif
            
            let newPlayer = AVPlayer()
            newPlayer.automaticallyWaitsToMinimizeStalling = true
            self.player = newPlayer
            
            // Optional: Set volume from your slider
            // newPlayer.volume = Float(currentVolume)
        }
    }

    /// Private: Actually starts the player + handles session
    private func startPlayback(context: PlaybackAttachContext = .coldLaunch) async {
        // UI Test isolation (defense-in-depth).
        guard !isTesting else {
            #if DEBUG
            print("[DirectStreamingPlayer] startPlayback — isTesting, early return (no audio session activation, no player.play)")
            #endif
            return
        }

        // ──────────────────────────────────────────────────────────────
        // Important : Top-level resurrection protection now driven by
        // authoritative playback intent via canProceedWithPlayback().
        // (Previously visualState.shouldAutoPlayOrResume; now consistent with public play()
        // and deep createAndStartPlayer paths.)
        // Sticky .userPaused / .securityLocked / .cleared (privacy clear) behavior preserved exactly.
        guard await SharedPlayerManager.shared.canProceedWithPlayback() else {
            #if DEBUG
            print("[DirectStreamingPlayer] startPlayback: resurrection suppressed by playbackIntent = \(await SharedPlayerManager.shared.currentPlaybackIntent)")
            #endif
            return
        }
        // ──────────────────────────────────────────────────────────────

        // Fresh playback attempt — clear dedup state so the first status we emit
        // (e.g. "status_connecting" or "status_playing") is never incorrectly suppressed.
        lastEmittedStatus = nil
        lastObservedTimeControl = nil
        lastObservedItemStatus = nil

        // Pre-compute the optimal URL (ensures server, bakes the host into the URL value).
        // We do this here (outside MainActor.run) so the run closure stays synchronous,
        // matching every other MainActor.run site in the file and avoiding overload resolution
        // issues under the widget extension's compilation context.
        let coldLaunchURL = await urlWithOptimalServer(for: selectedStream)

        // Configure session using the reusable async helper (SSOT) before AVPlayer work.
        // (Eliminates prior direct top-level synchronous setActive calls from hot paths.)
        _ = await configureAudioSessionAsync()

        await MainActor.run {
            ensurePlayerExists()
            
            guard let player = self.player else {
                #if DEBUG
                print("[DirectStreamingPlayer] No AVPlayer instance available")
                #endif
                return
            }
            
            // Item should already exist from setStream (secured preparePlayerItem). Attach only as fallback.
            if player.currentItem == nil {
                #if DEBUG
                print("[DirectStreamingPlayer] \(debugAttachContextLabel(context)): no currentItem after AVPlayer init → attaching fresh item")
                #endif
                
                let url = coldLaunchURL
                let asset = AVURLAsset(url: url)
                asset.resourceLoader.setDelegate(self, queue: .main)
                let newItem = AVPlayerItem(asset: asset)
                newItem.preferredForwardBufferDuration = 15.0
                player.replaceCurrentItem(with: newItem)
                self.playerItem = newItem
                self.bindAttachedItemToSelectedStream()
                self.clearPlaybackTeardownGuard()
                self.setupPlaybackObservers()
                self.addObservers()
                
                #if DEBUG
                print("[DirectStreamingPlayer] attached fresh AVPlayerItem (\(debugAttachContextLabel(context)))")
                #endif
            } else {
                #if DEBUG
                print("[DirectStreamingPlayer] reusing secured AVPlayerItem from setStream")
                #endif
                // preparePlayerItem already ran setupPlaybackObservers; only attach item-level observers.
                self.addObservers()
            }
            
            player.automaticallyWaitsToMinimizeStalling = false
            // Defer the first audible kick until AVPlayerItem.status == .readyToPlay.
            // Do not call play() here — AVPlayer begins loading the attached item automatically;
            // playImmediately in addObservers' readyToPlay handler is the single audible kick.
            self.isDeferringFirstPlayKick = true
            self.hasReceivedLiveStreamMetadata = false
            self.cancelEarlyICYDropRecreate()
            self.safeOnStatusChange(isPlaying: false, reasonKey: "status_connecting")
            
            #if DEBUG
            print("[DirectStreamingPlayer] startPlayback: awaiting readyToPlay before first play kick (item.status: \(player.currentItem?.status.rawValue ?? -1))")
            #endif
        }
        
        // Optional ICY head-start retry — only when the first kick has not achieved playback.
        if context != .resume {
            try? await Task.sleep(for: .milliseconds(400))
            
            Task { @MainActor in
                guard let player = self.player else { return }
                
                guard await SharedPlayerManager.shared.canProceedWithPlayback() else {
                    #if DEBUG
                    print("[DirectStreamingPlayer] post-head-start: resurrection suppressed by playbackIntent")
                    #endif
                    return
                }

                let itemReady = player.currentItem?.status == .readyToPlay
                let alreadyPlaying = self.hasStartedPlaying || player.rate > 0.1
                guard !alreadyPlaying else {
                    #if DEBUG
                    print("[DirectStreamingPlayer] post-head-start: skipped — playback already active (hasStartedPlaying=\(self.hasStartedPlaying), rate=\(player.rate))")
                    #endif
                    return
                }
                
                guard itemReady else {
                    #if DEBUG
                    print("[DirectStreamingPlayer] post-head-start: skipped — item not ready yet, deferring to readyToPlay observer")
                    #endif
                    return
                }
                
                player.playImmediately(atRate: 1.0)
                #if DEBUG
                print("[DirectStreamingPlayer] post-head-start playImmediately called (ready fallback, item.status: \(player.currentItem?.status.rawValue ?? -1))")
                #endif
            }
        }
        
        // Only the single lightweight safety net (below) remains as true last resort.
        
        // Startup safety net: first-play attach only (cold launch or stream switch).
        // Same-stream resume uses soft pause and must not schedule a stale recreate.
        if (context == .coldLaunch || context == .streamSwitch) && initialPlaybackRetryCount == 0 {
            Task { @MainActor in
                #if DEBUG
                print("[DirectStreamingPlayer] scheduling startup safety net (single last resort)")
                #endif
                self.scheduleStartupSafetyNet()
            }
        }
        
        // Persist the playing state
        await SharedPlayerManager.shared.setPlaying()
        
        #if DEBUG
        print("[DirectStreamingPlayer] Requested playing state update via SharedPlayerManager (initial auto-play)")
        #endif
    }
    
    func isActuallyPlaying() -> Bool {
        guard let player = self.player else { return false }
        return player.timeControlStatus == .playing && player.rate > 0.0
    }

    /// True after the canonical readyToPlay play kick has started stable audible output.
    @MainActor
    func isPlaybackAttachStable() -> Bool {
        guard let player, let item = player.currentItem else { return false }
        return hasStartedPlaying
            && !isDeferringFirstPlayKick
            && item.status == .readyToPlay
            && player.rate > 0.1
    }
    
    private func startBufferingTimer() {
        stopBufferingTimer()
        bufferingTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.stop()
            #if DEBUG
            print("⏰ Buffering timeout triggered")
            #endif
            self.safeOnStatusChange(isPlaying: false, reasonKey: "status_stopped")   // ← fixed
        }
    }
    
    private func stopBufferingTimer() {
        bufferingTimer?.invalidate()
        bufferingTimer = nil
    }
    
    // FIXED: Remove the cancelPendingSSLProtection method that relied on shared connectionStartTime
    func cancelPendingSSLProtection() {
        clearSSLProtectionTimer()
        #if DEBUG
        print("[DirectStreamingPlayer] [Manual Cancel] Cancelled pending SSL protection")
        #endif
    }
    
    // FIXED: Update clearSSLProtectionTimer to remove debug reference
    private func clearSSLProtectionTimer() {
        clearAllSSLProtectionTimers()
        isSSLHandshakeComplete = true
        
        #if DEBUG
        print("[DirectStreamingPlayer] SSL protection timer cleared")
        #endif
    }
    
    // NOTE: getCurrentMetadataForLiveActivity was removed (2026-06).
    // Live Activity now sources metadata exclusively via SharedPlayerManager
    // (currentStreamMetadata + loadPersistedStreamMetadata) + PlayerVisualState SSOT.
    // The old direct accessor was no longer called after the LA/SSOT consolidation.
    
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
            print("[DirectStreamingPlayer] addObservers() called — clearing old ones")
            #endif
            
            // Clear existing first (safe even if called multiple times)
            self.playerItemObservations.forEach { $0.invalidate() }
            self.playerItemObservations.removeAll()
            
            guard let playerItem = self.playerItem else {
                #if DEBUG
                print("[DirectStreamingPlayer] addObservers: No playerItem yet")
                #endif
                return
            }
            
            // Status observer — now actively handles .readyToPlay (critical for initial playback)
            let statusObs = playerItem.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                guard let self = self else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    #if DEBUG
                    print("[DirectStreamingPlayer] Player item status changed: \(item.status.rawValue) (readyToPlay=1, failed=2)")
                    #endif
                    
                    guard self.delegate != nil else { return }
                    
                    switch item.status {
                    case .readyToPlay:
                        // Canonical first-play kick: cold launch and stream-switch attach defer
                        // playImmediately from startPlayback until the secured item is ready.
                        #if DEBUG
                        print("[DirectStreamingPlayer] Item readyToPlay → starting playback")
                        #endif
                        
                        self.initialPlaybackRetryCount = 0
                        
                        self.isDeferringFirstPlayKick = false
                        self.cancelEarlyICYDropRecreate()
                        if (self.player?.rate ?? 0) < 0.1 {
                            self.player?.playImmediately(atRate: 1.0)
                            #if DEBUG
                            print("[DirectStreamingPlayer] playImmediately called — timeControlStatus: \(self.player?.timeControlStatus.rawValue ?? -1), rate: \(self.player?.rate ?? -1), item.status: \(item.status.rawValue)")
                            #endif
                        }
                        self.safeOnStatusChange(isPlaying: true, reasonKey: "status_playing")   // ← fixed
                        self.stopBufferingTimer()
                        self.hasStartedPlaying = true
                        
                    case .failed:
                        break
                        
                    case .unknown:
                        if self.hasStartedPlaying {
                            self.safeOnStatusChange(isPlaying: false, reasonKey: "status_buffering")   // ← fixed
                        }
                    @unknown default:
                        break
                    }
                }
                
                // Failed status uses direct MainActor Task hop from KVO (no double Dispatch+Task).
                // This path routes to the canonical handleItemStatusFailure for classification + early retry budget.
                if item.status == .failed {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.lastError = item.error
                        await self.handleItemStatusFailure(item)
                    }
                }
            }
            self.playerItemObservations.append(statusObs)
            #if DEBUG
            print("[DirectStreamingPlayer] Added robust status observer")
            #endif
            
            // Keep the existing buffer observers (they are still useful)
            let bufferEmptyObs = playerItem.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, change in
                guard let self = self, let newValue = change.newValue, newValue else { return }
                DispatchQueue.main.async {
                    if let error = item.error as NSError?, error.domain == "AVFoundationErrorDomain" {
                        #if DEBUG
                        print("[DirectStreamingPlayer] Buffer empty with error — attempting recovery")
                        #endif
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.recreatePlayerItem()
                        }
                        return
                    }
                    self.safeOnStatusChange(isPlaying: false, reasonKey: "status_buffering")   // ← fixed
                    self.startBufferingTimer()
                }
            }
            self.playerItemObservations.append(bufferEmptyObs)
            
            let likelyToKeepUpObs = playerItem.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, change in
                guard let self = self, let newValue = change.newValue else { return }
                if newValue && item.status == .readyToPlay {
                    guard !self.isDeferringFirstPlayKick else { return }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard await SharedPlayerManager.shared.canProceedWithPlayback() else { return }
                        if (self.player?.rate ?? 0) < 0.1 {
                            self.player?.play()
                        }
                        if self.hasStartedPlaying {
                            self.safeOnStatusChange(isPlaying: true, reasonKey: "status_playing")   // ← fixed
                            self.stopBufferingTimer()
                        }
                    }
                } else if !newValue && (self.player?.rate ?? 0) == 0 {
                    let stalledDelay: TimeInterval = self.isLowEfficiencyMode ? 20.0 : 10.0
                    DispatchQueue.main.asyncAfter(deadline: .now() + stalledDelay) { [weak self] in
                        guard let self = self,
                              let currentItem = self.playerItem,
                              currentItem == item,
                              !currentItem.isPlaybackLikelyToKeepUp,
                              (self.player?.rate ?? 0) == 0 else { return }
                        #if DEBUG
                        print("[DirectStreamingPlayer] Stalled — attempting recovery")
                        #endif
                        self.recreatePlayerItem()
                    }
                }
            }
            self.playerItemObservations.append(likelyToKeepUpObs)
            
            let bufferFullObs = playerItem.observe(\.isPlaybackBufferFull, options: [.new]) { [weak self] item, change in
                guard let self = self, let newValue = change.newValue, newValue else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard await SharedPlayerManager.shared.canProceedWithPlayback() else { return }
                    self.player?.play()
                    self.safeOnStatusChange(isPlaying: true, reasonKey: "status_playing")   // ← fixed
                    self.stopBufferingTimer()
                }
            }
            self.playerItemObservations.append(bufferFullObs)
            
            #if DEBUG
            print("[DirectStreamingPlayer] Added buffer observers")
            #endif
            
            // Time observer (kept as-is)
            let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            if let player = self.player, self.timeObserver == nil {
                self.timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
                    guard let self = self, self.delegate != nil else { return }
                    if (self.player?.rate ?? 0) > 0 {
                        self.safeOnStatusChange(isPlaying: true, reasonKey: "status_playing")   // ← fixed
                    }
                }
                self.timeObserverPlayer = player
                #if DEBUG
                print("[DirectStreamingPlayer] Added time observer")
                #endif
            }
        }
    }
    
    @MainActor
    private func cancelStartupSafetyNet() {
        startupSafetyNetWorkItem?.cancel()
        startupSafetyNetWorkItem = nil
    }

    // MARK: - Startup Safety Net (cold launch / stream-switch first attach)
    @MainActor
    private func scheduleStartupSafetyNet() {
        guard initialPlaybackRetryCount < maxInitialRetries else { return }

        cancelStartupSafetyNet()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            Task { @MainActor in
                // ──────────────────────────────────────────────────────────────
                // intent-driven startup safety net.
                // The .prePlay visual-state heuristic has been removed (last remaining
                // currentVisualState decision point for control flow in DirectStreamingPlayer).
                // Activation now relies solely on: intent check + actual playback facts.
                guard await SharedPlayerManager.shared.canProceedWithPlayback() else {
                    #if DEBUG
                    print("[DirectStreamingPlayer] startup safety net: resurrection suppressed by playbackIntent")
                    #endif
                    return
                }
                // ──────────────────────────────────────────────────────────────
                
                let isActuallyPlaying = (self.player?.rate ?? 0) > 0.1 &&
                                        self.currentItemStatus == .readyToPlay
                
                if !isActuallyPlaying {
                    self.initialPlaybackRetryCount += 1
                    #if DEBUG
                    print("[DirectStreamingPlayer] [Playback] Startup safety net: no playback detected after 5s – retry \(self.initialPlaybackRetryCount)/\(self.maxInitialRetries) | hasStartedPlaying=\(self.hasStartedPlaying) | currentItemStatus=\(self.currentItemStatus.rawValue) | hasPlayerItem=\(self.playerItem != nil) | rate=\(self.player?.rate ?? -1)")
                    #endif

                    if self.initialPlaybackRetryCount >= self.maxInitialRetries {
                        #if DEBUG
                        let tc = self.player?.timeControlStatus.rawValue ?? -1
                        print("[DirectStreamingPlayer] [Playback] Max attempts (\(self.maxInitialRetries)) reached - giving up")
                        print("[DirectStreamingPlayer] [Playback] Safety net terminal: hasPermanentError=\(self.hasPermanentError) | timeControlStatus=\(tc) | rate=\(self.player?.rate ?? -1) | currentItemStatus=\(self.currentItemStatus.rawValue)")
                        #endif

                        if self.hasPermanentError {
                            // Real permanent failure (via handleLoadingError or item.failed permanent).
                            // Emit the modern hard-failure key so red banner + popup use the
                            // correct localized "Failed" / reason text (post-unification).
                            self.safeOnStatusChange(isPlaying: false, reasonKey: "status_failed")
                        } else {
                            // Pure transient ICY/Fig/decoder noise on noisy streams (Viro etc.).
                            // Give one final recreatePlayerItem() (unified resource-loader item)
                            // and suppress the severe status entirely. No red UX for recoverable cases.
                            #if DEBUG
                            print("[DirectStreamingPlayer] [Playback] Transient give-up: performing FINAL recreatePlayerItem() then suppressing severe status. No red popup.")
                            #endif
                            self.recreatePlayerItem()
                        }
                        return
                    }

                    self.recreatePlayerItem()
                }
            }
        }
        startupSafetyNetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
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
    
    @MainActor
    private func activatePlaybackTeardownGuard() {
        isPlaybackTeardownActive = true
        cancelEarlyICYDropRecreate()
        cancelStartupSafetyNet()
    }

    @MainActor
    private func clearPlaybackTeardownGuard() {
        isPlaybackTeardownActive = false
    }

    /// Activates the teardown guard on the main actor without requiring the caller to be MainActor-isolated.
    private func activatePlaybackTeardownGuardFromStop() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { activatePlaybackTeardownGuard() }
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated { self.activatePlaybackTeardownGuard() } }
        }
    }

    @MainActor
    private func scheduleEarlyICYDropRecreate(rate: Float) {
        guard !isPlaybackTeardownActive else { return }
        earlyICYDropRecreateTask?.cancel()
        earlyICYDropRecreateTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard let self else { return }
            guard !self.isPlaybackTeardownActive else { return }
            guard !self.hasStartedPlaying else { return }
            guard !self.isDeferringFirstPlayKick else {
                #if DEBUG
                print("[DirectStreamingPlayer] [KVO] early ICY drop: skipped — awaiting readyToPlay first-play kick")
                #endif
                return
            }
            guard self.initialPlaybackRetryCount < self.maxInitialRetries else { return }
            guard await SharedPlayerManager.shared.canProceedWithPlayback() else {
                #if DEBUG
                print("[DirectStreamingPlayer] [KVO] early ICY drop: suppressed by playbackIntent")
                #endif
                return
            }
            if self.initialPlaybackRetryCount == 0 {
                self.initialPlaybackRetryCount = 1
            }
            #if DEBUG
            print("[DirectStreamingPlayer] [Playback] Early timeControl drop on fresh ICY item — proactive recreatePlayerItem | hasStartedPlaying=\(self.hasStartedPlaying) | retryCount now=\(self.initialPlaybackRetryCount) | rate=\(rate)")
            #endif
            self.recreatePlayerItem()
        }
    }
    
    @MainActor
    private func cancelEarlyICYDropRecreate() {
        earlyICYDropRecreateTask?.cancel()
        earlyICYDropRecreateTask = nil
    }
    
    private func recreatePlayerItem() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard !self.isPlaybackTeardownActive else {
                #if DEBUG
                print("[DirectStreamingPlayer] [Playback] recreatePlayerItem: suppressed — playback teardown active")
                #endif
                return
            }
            guard !self.recreateInFlight else {
                #if DEBUG
                print("[DirectStreamingPlayer] [Playback] recreatePlayerItem: coalesced — already in flight")
                #endif
                return
            }
            self.recreateInFlight = true
            defer { self.recreateInFlight = false }
            
            #if DEBUG
            print("[DirectStreamingPlayer] Recreating player item due to decoder error")
            #endif
            
            guard let urlAsset = self.playerItem?.asset as? AVURLAsset else {
                #if DEBUG
                print("[DirectStreamingPlayer] [Playback] Cannot recreate: no valid URL asset | hasStartedPlaying=\(self.hasStartedPlaying) | initialPlaybackRetryCount=\(self.initialPlaybackRetryCount) | playerItem=\(self.playerItem != nil) | this often happens during stream switch races")
                #endif
                return
            }
            
            let currentURL = urlAsset.url
            
            // Clear observations
            self.playerItemObservations.forEach { $0.invalidate() }
            self.playerItemObservations.removeAll()
            
            // Create new asset and player item
            let newAsset = AVURLAsset(url: currentURL)
            let newItem = AVPlayerItem(asset: newAsset)
            
            // Replace the item
            self.player?.replaceCurrentItem(with: newItem)
            
            // Update playerItem reference to the new item
            self.playerItem = newItem
            self.bindAttachedItemToSelectedStream()
            self.clearPlaybackTeardownGuard()
            
            // Re-add observers to the new item
            self.addObservers()
            
            // Intent guard — actor state is kept trustworthy by the centralized pause timestamp
            // and intent wiring.
            guard await SharedPlayerManager.shared.canProceedWithPlayback() else {
                #if DEBUG
                print("[DirectStreamingPlayer] recreatePlayerItem: resurrection suppressed by playbackIntent")
                #endif
                return
            }
            
            // Restart playback only if still allowed — defer audible kick when item not ready.
            if newItem.status == .readyToPlay {
                self.isDeferringFirstPlayKick = false
                self.player?.playImmediately(atRate: 1.0)
            } else {
                self.isDeferringFirstPlayKick = true
            }
            
            #if DEBUG
            print("[DirectStreamingPlayer] Player item recreated and playback resumed (item.status: \(newItem.status.rawValue))")
            #endif
            
            // NEW (per minimal ICY resume fix): ensure delegate wired on the fresh item created by recreate
            self.ensureICYAttached()
        }
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
    ///
    /// - Parameters:
    ///   - reason: Why we are stopping. This is now the single source of truth for user intent.
    ///             `.userAction` → sticky `.userPaused`
    ///             `.streamSwitch`, `.interruption`, `.error` → preserve play intent
    ///   - completion: Optional completion handler called after stopping.
    ///   - silent: If `true`, skips status updates / UI flicker (exactly as it behaved in recent commits).
    func stop(
        reason: StopReason = .userAction,
        completion: (@MainActor @Sendable () -> Void)? = nil,
        silent: Bool = false
    ) {
        
        #if DEBUG
        print("[DirectStreamingPlayer] FORCE STOPPING ALL PLAYBACK - reason: \(reason), silent: \(silent), attemptingPlayback: \(isCurrentlyAttemptingPlayback)")
        #endif

        // === EXISTING GUARDS - DO NOT REMOVE OR MERGE THESE ===
        if isCurrentlyAttemptingPlayback {
            #if DEBUG
            print("[DirectStreamingPlayer] [Stop Guard] Skipping aggressive stop during playback startup attempt")
            #endif
            loadingTimeoutWorkItem?.cancel()
            fallbackWorkItem?.cancel()
            pendingPlaybackWorkItem?.cancel()
            retryWorkItem?.cancel()
            return
        }

        let usesSoftPause = reason == .userAction && !silent
        if usesSoftPause {
            Task { @MainActor [weak self] in
                self?.cancelStartupSafetyNet()
                self?.cancelEarlyICYDropRecreate()
            }
        } else {
            // Activate before any async work so stale KVO / debounced recreate cannot race teardown.
            activatePlaybackTeardownGuardFromStop()
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
        
        // === Important: Set visual state based on reason + silent (respects recent commit semantics) ===
        Task {
            if reason == .userAction && !silent {
                await self.markAsUserPaused()
                #if DEBUG
                print("[DirectStreamingPlayer] markAsUserPaused() called – visualState set to .userPaused")
                #endif
            }
            // .streamSwitch / .interruption / .error intentionally skip markAsUserPaused()
            // → this replaces the markAsPlaying() workaround
            
            // Perform the actual stop on the main actor
            await MainActor.run {
                performActualStop(
                    reason: reason,
                    completion: completion,
                    silent: silent
                )
            }
            
            // Persist after everything (unchanged)
            await SharedPlayerManager.shared.saveCurrentState()
        }
    }

    /// Performs the actual stop operation.
    /// - Parameters:
    ///   - completion: Optional completion handler called after stopping.
    ///   - silent: If `true`, skips all status updates to avoid UI flicker.
    ///   - effectiveSwitching: If `true`, suppresses "status_stopped" updates during stream switches.
    /// - Note: Combines `silent` and `effectiveSwitching` into `effectiveSilent`. All main-thread work is now explicitly isolated.
    private func performActualStop(
        reason: StopReason,
        completion: (@MainActor () -> Void)? = nil,
        silent: Bool = false
    ) {
        // Derive effectiveSilent exactly as before, but now driven by reason
        // (preserves all recent-commit behaviour for silent + stream switches)
        let effectiveSilent = silent || (reason != .userAction)
        let usesSoftPause = reason == .userAction && !effectiveSilent

        if !usesSoftPause {
            activatePlaybackTeardownGuardFromStop()
        }
        clearSSLProtectionTimer()
        isSSLHandshakeComplete = true
        hasStartedPlaying = false
        isDeferringFirstPlayKick = false
        
        if isDeallocating {
            stopSynchronously()
            if let completion = completion {
                MainActor.assumeIsolated { completion() }
            }
            return
        }
        
        audioQueue.async { [weak self] in
            guard let self, !self.isDeallocating else {
                if let completion = completion {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { completion() }
                    }
                }
                return
            }
            
            #if DEBUG
            print("[DirectStreamingPlayer] Stopping playback (reason: \(reason), effectiveSilent: \(effectiveSilent))")
            #endif

            if usesSoftPause {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.player?.pause()
                        self.player?.rate = 0.0
                        self.isSoftPaused = true
                        self.lastEmittedStatus = nil
                        self.lastObservedTimeControl = nil
                        self.lastObservedItemStatus = nil
                        self.safeOnStatusChange(isPlaying: false, reasonKey: "status_stopped")
                        completion?()
                    }
                }
                #if DEBUG
                print("[DirectStreamingPlayer] Soft pause — kept secured AVPlayerItem for same-stream resume")
                #endif
                return
            }

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isSoftPaused = false
                }
            }
            
            guard self.player != nil || self.playerItem != nil else {
                if !effectiveSilent {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.safeOnStatusChange(isPlaying: false, reasonKey: "status_stopped")  // ← fixed
                            completion?()
                        }
                    }
                } else if let completion = completion {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { completion() }
                    }
                }
                #if DEBUG
                print("[DirectStreamingPlayer] Playback already stopped, skipping cleanup (reason: \(reason))")
                #endif
                return
            }
            
            // Pause + cleanup
            self.executeAudioOperation({
                self.player?.pause()
                self.player?.rate = 0.0
                return ""
            }, completion: { _ in })
            
            self.activeResourceLoaders.forEach { (_, delegate) in
                delegate.cancel()
            }
            self.activeResourceLoaders.removeAll()
            
            if let metadataOutput = self.metadataOutput, let playerItem = self.playerItem {
                if playerItem.outputs.contains(metadataOutput) {
                    playerItem.remove(metadataOutput)
                    #if DEBUG
                    print("[DirectStreamingPlayer] Removed metadata output from playerItem in stop")
                    #endif
                }
            }
            self.metadataOutput = nil
            
            self.playerItemObservations.forEach { $0.invalidate() }
            self.playerItemObservations.removeAll()
            self.removeObserversImplementation()
            self.playerItem = nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.clearAttachedItemBinding()
                }
            }
            
            if !effectiveSilent {
                // A real terminal stop is a context change — clear dedup so the
                // "status_stopped" we are about to emit (and any subsequent play) is not suppressed.
                lastEmittedStatus = nil
                lastObservedTimeControl = nil
                lastObservedItemStatus = nil
                
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.safeOnStatusChange(isPlaying: false, reasonKey: "status_stopped")  // ← fixed
                        completion?()
                    }
                }
            } else if let completion = completion {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { completion() }
                }
            }
            
            self.stopBufferingTimer()
            
            #if DEBUG
            print("[DirectStreamingPlayer] Playback stopped, playerItem and resource loaders cleared (reason: \(reason))")
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
        if Thread.isMainThread {
            MainActor.assumeIsolated { clearAttachedItemBinding() }
        }
        
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
        if Thread.isMainThread {
            MainActor.assumeIsolated { clearAttachedItemBinding() }
        }
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
        
        // Clear raw KVO trackers when observers are torn down.
        lastObservedTimeControl = nil
        lastObservedItemStatus = nil
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
        print("[DirectStreamingPlayer] [Deinit] Cancelled pending work items")
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
        print("[DirectStreamingPlayer] deinit completed")
        #endif
    }
    
    private func handleLoadingError(_ error: Error) async {
        let errorType = StreamErrorType.from(error: error)
        hasPermanentError = errorType.isPermanent
        
        #if DEBUG
        print("[DirectStreamingPlayer] [Loading Error] Type: \(errorType), isPermanent: \(errorType.isPermanent)")
        print("[DirectStreamingPlayer] [Loading Error] Error: \(error.localizedDescription)")
        #endif
        
        if let urlError = error as? URLError {
            switch urlError.code {
            case .serverCertificateUntrusted, .secureConnectionFailed:
                #if DEBUG
                print("[DirectStreamingPlayer] [Loading Error] SSL/Certificate error detected")
                #endif
                safeOnStatusChange(isPlaying: false, reasonKey: "status_security_failed")   // ← fixed
                
            case .fileDoesNotExist, .badServerResponse:
                #if DEBUG
                print("[DirectStreamingPlayer] [Loading Error] Hard server error (resource / response)")
                #endif
                // Permanent non-security failure → emit status_failed (now the canonical
                // key for hard connection errors that trigger red banner + popup).
                safeOnStatusChange(isPlaying: false, reasonKey: "status_failed")
                
            case .cannotFindHost, .dnsLookupFailed:
                #if DEBUG
                print("[DirectStreamingPlayer] [Loading Error] DNS lookup error (may be DNSSEC-unvalidated when policy active) — treating as transient")
                #endif
                // DNS lookup (including potential DNSSEC validation failure when
                // requiresDNSSECValidationForStreaming is active) → recoverable path.
                fallthrough
                
            default:
                #if DEBUG
                print("[DirectStreamingPlayer] [Loading Error] Transient error detected")
                #endif
                safeOnStatusChange(isPlaying: false, reasonKey: "status_buffering")   // ← fixed
                
                // : Make recreatePlayerItem the canonical "reset this live ICY item
                // after startup noise" for transient cases in the early window (before stable play).
                // This is the primary path from resource loader onError for ICY pump/Fig transients.
                if !hasStartedPlaying && initialPlaybackRetryCount < maxInitialRetries {
                    guard await SharedPlayerManager.shared.canProceedWithPlayback() else {
                        #if DEBUG
                        print("[DirectStreamingPlayer] [Loading Error] transient early: suppressed by playbackIntent")
                        #endif
                        return
                    }
                    if initialPlaybackRetryCount == 0 { initialPlaybackRetryCount = 1 }
                    #if DEBUG
                    print("[DirectStreamingPlayer] Transient loading error on fresh ICY item — canonical recreatePlayerItem")
                    #endif
                    recreatePlayerItem()
                    return   // do not fall through to stop()
                }
            }
        } else {
            #if DEBUG
            print("[DirectStreamingPlayer] [Loading Error] Non-URLError detected")
            #endif
            safeOnStatusChange(isPlaying: false, reasonKey: "status_buffering")   // ← fixed
        }
        
        // Pass classified errorType (owned here) to the *existing* Shared method.
        // `streamDidFail` emission happens inside markPlaybackStoppedByStreamFailure
        // after its state mutation. No emission code or Task-await-Shared lives in Direct.
        await SharedPlayerManager.shared.markPlaybackStoppedByStreamFailure(errorType)
        stop()
    }
}

// (No more top-level Latency Measurement extension — the methods now live
// inside the class under a dedicated MARK, co-located with selectOptimalServer.)

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
        guard delegate != nil,
              let group = groups.last else { return }

        // A group can contain multiple metadata items; only StreamTitle candidates trigger async work.
        for item in group.items {
            processPotentialStreamTitle(item)
        }
    }

    /// Modern iOS 16+ implementation for ICY/StreamTitle metadata extraction.
    ///
    /// Uses the non-deprecated `load(_:)` / `status(of:)` async properties on `AVMetadataItem`
    /// (replaces the deprecated `loadValuesAsynchronously(forKeys:)` + `statusOfValue(forKey:)`).
    /// Performs cheap synchronous filtering on identifier/key before any loading work.
    /// All UI / delegate side effects are dispatched back to the main queue.
    private func processPotentialStreamTitle(_ item: AVMetadataItem) {
        // Capture Sendable filter criteria synchronously (cheap, no Sendable issues)
        let identifier = item.identifier?.rawValue
        let key = item.key as? String

        let isStreamTitle = (identifier?.localizedCaseInsensitiveContains("streamtitle") == true) ||
                            (identifier == "icy/StreamTitle") ||
                            (key == "StreamTitle")

        guard isStreamTitle else { return }

        // Modern async API (iOS 16+). The Task closure capture of non-Sendable AVMetadataItem
        // is tolerated thanks to @preconcurrency import AVFoundation.
        Task { [weak self] in
            if let title = try? await item.load(.stringValue) {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                await MainActor.run { [weak self] in
                    guard let self else { return }

                    self.currentMetadata = trimmed
                    self.hasReceivedLiveStreamMetadata = true
                    
                    self.safeOnMetadataChange(metadata: trimmed)
                    if self.needsImmediateMetadataPush {
                        self.needsImmediateMetadataPush = false
                        #if DEBUG
                        print("[DirectStreamingPlayer] LIVE ICY [ensured after re-attach]: \(trimmed)")
                        #endif
                    } else {
                        #if DEBUG
                        print("[DirectStreamingPlayer] Using LIVE ICY metadata: \(trimmed)")
                        #endif
                    }
                }
            }
        }
    }

    /// Guarantees metadata delegate is attached to every new AVPlayerItem (critical on same-stream resume).
    /// Sets the explicit flag so the very next ICY StreamTitle triggers an immediate Now Playing / widget update.
    @MainActor
    private func ensureICYAttached() {
        guard let item = player?.currentItem else { return }
        
        // Defensive clean + re-attach (idempotent)
        if let old = metadataOutput {
            item.remove(old)
        }
        
        let newOutput = AVPlayerItemMetadataOutput(identifiers: nil)
        newOutput.setDelegate(self, queue: .main)
        item.add(newOutput)
        metadataOutput = newOutput
        
        needsImmediateMetadataPush = true
        
        #if DEBUG
        print("[DirectStreamingPlayer] ICY metadata output re-attached to fresh player item")
        #endif
    }
}

extension DirectStreamingPlayer {
    func handleNetworkInterruption() {
        stop()
        let interruptionDelay: TimeInterval = isLowEfficiencyMode ? 1.0 : 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + interruptionDelay) { [weak self] in
            guard let self = self, self.delegate != nil else { return }
            // Emit a proper status_* key (never button titles or popup titles as reasonKey).
            self.safeOnStatusChange(isPlaying: false, reasonKey: "status_paused")
        }
    }
    
    private func handlePlaybackError(_ error: Error?) {
        guard let avError = error as? AVError else { return }
        #if DEBUG
        print("[DirectStreamingPlayer] Playback error: code=\(avError.code.rawValue), desc=\(avError.localizedDescription)")
        #endif

        // Historical behavior: any AVError set the permanent flag.
        // Under the modest architectural consolidation we are moving toward a single
        // decision point (`handleItemStatusFailure`) that respects the early-window
        // transient budget. Direct callers of handlePlaybackError (currently only the
        // unconditional statusObserver path) will be routed through the canonical
        // handler in a follow-up slice.
        self.hasPermanentError = true
        self.stop(completion: nil, silent: true)

        if avError.localizedDescription.contains("unmatched audio object type") || avError.localizedDescription.contains("SBR decoder") {
            #if DEBUG
            print("[DirectStreamingPlayer] HE-AAC/SBR format issue detected—recommend server-side LC-AAC fallback")
            #endif
        }
    }

    /// Central decision point for `.failed` status on an `AVPlayerItem`.
    ///
    /// This method is the emerging **single source of truth** for the question:
    /// "Is this a self-healing transient (normal ICY/Fig/AAC framing noise on a fresh item)
    /// that should be recovered with `recreatePlayerItem`, or a real permanent failure?"
    ///
    /// It combines:
    /// - Improved `StreamErrorType` classification (non-URL decoder errors → transient)
    /// - The fresh-item budget (`!hasStartedPlaying` + `initialPlaybackRetryCount`)
    /// - Intent check via `SharedPlayerManager.canProceedWithPlayback()`
    ///
    /// - Important: After a user stream switch, `switchToStream` + `resetInitialPlaybackCountersForNewStream`
    ///   must have been called so that the new item starts with a clean budget. This is what
    ///   prevents prior-stream noise from poisoning the new stream's first attempt.
    ///
    /// - Precondition: Called on a `.failed` KVO delivery for the current `playerItem`.
    /// - Postcondition: Either `recreatePlayerItem()` was scheduled (transient case) or a
    ///   terminal status was emitted and the player was stopped (permanent case).
    ///
    /// - SeeAlso: `StreamErrorType.from(error:)`, `switchToStream(_:)`, `resetInitialPlaybackCountersForNewStream()`,
    ///   `setupPlaybackObservers()`, `addObservers()`, `recreatePlayerItem()`,
    ///   RadioPlayerCoordinator.handleStatusChange, CODING_AGENT.md
    @MainActor
    private func handleItemStatusFailure(_ item: AVPlayerItem) async {
        let error = item.error
        let errorType = StreamErrorType.from(error: error)

        // Always record the classification for observers and UI.
        hasPermanentError = errorType.isPermanent

        // Early window on a fresh (or post-switch) item with remaining retry budget
        // and a non-permanent error → canonical silent recovery via recreate.
        // This is the behavior the unconditional observer path was missing.
        if !hasStartedPlaying
            && initialPlaybackRetryCount < maxInitialRetries
            && !errorType.isPermanent {

            guard await SharedPlayerManager.shared.canProceedWithPlayback() else {
                #if DEBUG
                print("[DirectStreamingPlayer] [Item status failure] early transient suppressed by intent")
                #endif
                return
            }

            if initialPlaybackRetryCount == 0 {
                initialPlaybackRetryCount = 1
            }

            #if DEBUG
            print("[DirectStreamingPlayer] Item status .failed on fresh ICY item (post-pause/switch) — canonical recreatePlayerItem")
            #endif
            recreatePlayerItem()
            return
        }

        // Real permanent (or late) failure path.
        // Pass the player-owned classified errorType to the existing Shared surface.
        // .streamDidFail emission (and visual) happens inside mark... after mutation.
        // No emission logic, no new APIs, no Task { await record... } in Direct.
        safeOnStatusChange(isPlaying: false, reasonKey: errorType.statusString)
        await SharedPlayerManager.shared.markPlaybackStoppedByStreamFailure(errorType)
        stop()
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
                    print("[DirectStreamingPlayer] [AudioSession] Interruption began")
                    #endif
                    self.isHandlingInterruption = true
                    self.wasPlayingBeforeInterruption = self.isPlaying  // Use refined check
                    
                    if self.wasPlayingBeforeInterruption {
                        self.player?.pause()  // Graceful pause
                        self.delegate?.onStatusChange(.paused, reasonKey: "Interruption")  // ← fixed
                        
                        // Persist paused state for widget — non-blocking
                        Task {
                            await SharedPlayerManager.shared.saveCurrentState()
                        }
                    }
                    
                case .ended:
                    #if DEBUG
                    print("[DirectStreamingPlayer] [AudioSession] Interruption ended — options.contains(.shouldResume): \(options.contains(.shouldResume))")
                    #endif
                    
                    // Reset flags immediately
                    self.isHandlingInterruption = false
                    self.wasPlayingBeforeInterruption = false
                    
                    guard options.contains(.shouldResume) else {
                        #if DEBUG
                        print("[DirectStreamingPlayer] [AudioSession] No .shouldResume — doing nothing")
                        #endif
                        return
                    }
                    
                    // Respect PlayerVisualState resurrection suppression before resuming.
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        
                        await SharedPlayerManager.shared.restoreVisualStateRespectingUserIntent()
                        
                        if case .playing = await SharedPlayerManager.shared.currentVisualState {
                            #if DEBUG
                            print("[DirectStreamingPlayer] ▶ [AudioSession] Resurrection allowed — resuming playback")
                            #endif
                            
                            // Small delay helps AVPlayer settle after interruption
                            try? await Task.sleep(for: .milliseconds(100))
                            
                            self.player?.play()
                            
                            if self.isPlaying {
                                self.delegate?.onStatusChange(.playing, reasonKey: nil)  // ← fixed
                            }
                            
                            await self.markAsPlaying()
                            
                            // Persist resumed state — non-blocking
                            Task {
                                await SharedPlayerManager.shared.saveCurrentState()
                            }
                        } else {
                            #if DEBUG
                            print("🚫 [AudioSession] Resurrection suppressed — user intent remains .userPaused")
                            #endif
                            self.safeOnStatusChange(isPlaying: false, reasonKey: "status_paused")
                        }
                    }
                    
                default:
                    // Fallback for unknown cases (exhaustive without @unknown)
                    #if DEBUG
                    print("[DirectStreamingPlayer] [AudioSession] Unknown interruption type: \(String(describing: type))")
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
                print("[DirectStreamingPlayer] [AudioSession] Route changed")
                #endif
                // If disconnected during play, pause and notify
                if self.player?.rate ?? 0 > 0 {
                    self.player?.pause()
                    self.delegate?.onStatusChange(.paused, reasonKey: "Route Change")  // ← fixed
                    
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
///
/// All actual data transport for lutheran.radio hosts goes through URLSessions
/// configured via ``SecurityConfiguration/makeSecureEphemeralConfiguration()`` (DNSSEC
/// + cache hardening). The resource loader exists to let us supply our own
/// `URLSession` + `StreamingSessionDelegate` (which in turn uses `CertificateValidator`
/// for the TLS challenge). This gives us full control over both DNSSEC resolution
/// and certificate pinning for the media bytes.
///
/// - Note: We do **not** use a custom URL scheme for the AVURLAsset itself
///   (previous attempts were removed for simplicity). The DNS resolution that
///   matters (the one that actually carries audio) is the one performed by the
///   controlled `URLSession` inside `shouldWaitForLoadingOfRequestedResource`.
extension DirectStreamingPlayer: AVAssetResourceLoaderDelegate {
    /// Determines if the loader should handle the request.
    /// - Parameters:
    ///   - resourceLoader: The requesting loader.
    ///   - loadingRequest: The resource request.
    /// - Returns: `true` if handling (for lutheran.radio HTTPS URLs).
    /// - Note: Enforces HTTPS and domain checks; sets up pinned + DNSSEC-protected sessions.
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url else {
            #if DEBUG
            print("[DirectStreamingPlayer] [Resource Loader] No URL in loading request")
            #endif
            loadingRequest.finishLoading(with: NSError(domain: "radio.lutheran", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return false
        }
        
        #if DEBUG
        print("[DirectStreamingPlayer] [Resource Loader] ===== NEW REQUEST =====")
        print("[DirectStreamingPlayer] [Resource Loader] Received URL: \(url)")
        print("[DirectStreamingPlayer] [Resource Loader] URL scheme: \(url.scheme ?? "nil")")
        print("[DirectStreamingPlayer] [Resource Loader] URL host: \(url.host ?? "nil")")
        #endif
        
        // FIXED: Only handle HTTPS URLs for lutheran.radio domains
        guard url.scheme == "https",
              let host = url.host,
              host.hasSuffix("lutheran.radio") else {
            #if DEBUG
            print("[DirectStreamingPlayer] [Resource Loader] Not a lutheran.radio HTTPS URL, letting system handle it")
            #endif
            return false  // Let the system handle non-lutheran.radio URLs
        }
        
        // Store the original hostname for SSL validation
        let originalHostname = host
        #if DEBUG
        print("[DirectStreamingPlayer] [Resource Loader] Handling lutheran.radio HTTPS URL: \(url)")
        print("[DirectStreamingPlayer] [Resource Loader] Original hostname for SSL: \(originalHostname)")
        #endif
        
        // Create clean request with the HTTPS URL (no conversion needed)
        var modifiedRequest = URLRequest(url: url)
        modifiedRequest.timeoutInterval = 60.0
        
        // Apply Icecast/Liquidsoap compatibility headers (centralised & future-proof)
        modifiedRequest = self.requestWithIcecastHeaders(from: modifiedRequest)
        
        #if DEBUG
        print("[DirectStreamingPlayer] [Resource Loader] Final request headers: \(modifiedRequest.allHTTPHeaderFields ?? [:])")
        #endif
        
        // Create streaming delegate
        let streamingDelegate = StreamingSessionDelegate(loadingRequest: loadingRequest)
        streamingDelegate.originalHostname = originalHostname
        
        #if DEBUG
        print("[DirectStreamingPlayer] [Resource Loader] StreamingSessionDelegate created for hostname: \(originalHostname)")
        #endif
        
        // Enhanced configuration for SSL pinning + DNSSEC-protected name resolution.
        // All policy for secure networking flows through SecurityConfiguration (Core/ single source of truth).
        let config = SecurityConfiguration.makeSecureEphemeralConfiguration()
        config.timeoutIntervalForRequest = 60.0
        config.timeoutIntervalForResource = 120.0
        
        // Additional streaming-specific tunables (DNSSEC + cache hardening already applied by factory).
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 1
        
        let operationQueue = OperationQueue()
        operationQueue.qualityOfService = .userInitiated
        operationQueue.maxConcurrentOperationCount = 1
        
        #if DEBUG
        print("[DirectStreamingPlayer] [Resource Loader] Creating URLSession with SSL-forcing config")
        #endif
        
        streamingDelegate.session = URLSession(configuration: config,
                                               delegate: streamingDelegate,
                                               delegateQueue: operationQueue)
        
        streamingDelegate.dataTask = streamingDelegate.session?.dataTask(with: modifiedRequest)
        
        streamingDelegate.onError = { [weak self, weak streamingDelegate] error in
            guard let self = self, let delegate = streamingDelegate else { return }
            
            #if DEBUG
            print("[DirectStreamingPlayer] [Resource Loader] Streaming error occurred: \(error.localizedDescription)")
            #endif
            
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.activeResourceLoaders.removeValue(forKey: delegate.loadingRequest)
                self.loadingTimeoutWorkItem?.cancel()
                if self.currentLoadingDelegate === delegate {
                    self.currentLoadingDelegate = nil
                }
                
                // : For transient ICY startup noise on fresh items, go straight to
                // recreatePlayerItem (now the canonical reset tool) instead of the full
                // handleLoadingError + stop path. handleLoadingError is still called for
                // permanent cases and late transients.
                let errType = StreamErrorType.from(error: error)
                if !self.hasStartedPlaying && self.initialPlaybackRetryCount < self.maxInitialRetries
                    && !errType.isPermanent {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard await SharedPlayerManager.shared.canProceedWithPlayback() else { return }
                        if self.initialPlaybackRetryCount == 0 { self.initialPlaybackRetryCount = 1 }
                        #if DEBUG
                        print("[DirectStreamingPlayer] Resource loader transient error on fresh ICY item — canonical recreatePlayerItem")
                        #endif
                        self.recreatePlayerItem()
                    }
                    return
                }
                
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.handleLoadingError(error)
                }
            }
        }
        
        activeResourceLoaders[loadingRequest] = streamingDelegate
        
        #if DEBUG
        print("[DirectStreamingPlayer] [Resource Loader] Starting data task with Icecast-compatible headers…")
        #endif
        streamingDelegate.dataTask?.resume()
        self.currentLoadingDelegate = streamingDelegate
        self.startLoadingRequestTimeout(for: streamingDelegate)
        
        #if DEBUG
        print("[DirectStreamingPlayer] [Resource Loader] Resource loader setup complete")
        print("[DirectStreamingPlayer] [Resource Loader] ===== END REQUEST SETUP =====")
        #endif
        
        return true
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        #if DEBUG
        print("[DirectStreamingPlayer] [SSL Debug] Resource loading cancelled for request")
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
    /// Classification of errors reported by `AVPlayerItem` or the resource loader.
    ///
    /// This is the authoritative model for **permanent vs transient** errors in the streaming engine.
    /// It directly supports the contract that normal live ICY framing / decoder noise on a fresh
    /// item (after `switchToStream` + `resetInitialPlaybackCountersForNewStream`) must be recovered
    /// silently via `recreatePlayerItem` rather than surfacing `status_stream_unavailable`.
    ///
    /// - Important: Many ICY pump, Fig, and AAC decoder errors (e.g. err=-12785, -16042,
    ///   "Error deserializing SCE", AudioFormatDescription failures) arrive **outside**
    ///   `NSURLErrorDomain`. These are expected transient noise on the first packets of a live
    ///   HE-AAC stream and must be classified as `.transientFailure` (or handled as such) when
    ///   `!hasStartedPlaying`.
    ///
    /// - SeeAlso: `handleItemStatusFailure(_:)`, `switchToStream(_:)`, `resetInitialPlaybackCountersForNewStream()`,
    ///   `addObservers()`, `preparePlayerItem(for:)`, CODING_AGENT.md (explicit permanent/transient modeling)
    enum StreamErrorType {
        /// Hard security failure (certificate, model validation). Never auto-retried.
        case securityFailure

        /// Genuine permanent failure (resource gone, TCP connect after DNS success, etc.).
        ///
        /// DNS lookup failures are intentionally **not** included here; see ``from(error:)``.
        case permanentFailure

        /// Recoverable condition: network blip, temporary server response, or the normal
        /// decoder / framing noise that occurs on fresh ICY items after a switch or cold launch.
        case transientFailure

        /// Unclassified. Treated conservatively as transient in early-window recovery paths.
        case unknown

        /// Classifies the given error.
        ///
        /// - Parameter error: The `item.error` or equivalent from AVFoundation / resource loading.
        /// - Returns: The appropriate `StreamErrorType`.
        ///
        /// - Note: DNS lookup failures (cannotFindHost / dnsLookupFailed) are deliberately
        ///   classified transient. This keeps streaming available on networks where
        ///   ``SecurityConfiguration/requiresDNSSECValidationForStreaming`` cannot be satisfied
        ///   by the local resolver (the requirement is therefore "opt-in safe").
        ///   Any error that is not a clear security or hard post-DNS host/resource failure
        ///   is treated as transient. This is the key change that lets the canonical recreate
        ///   path handle the exact symptoms seen during language switches (see stream switch glitch analysis).
        static func from(error: Error?) -> StreamErrorType {
            guard let nsError = error as NSError? else {
                return .unknown
            }

            if nsError.domain == NSURLErrorDomain {
                switch nsError.code {
                case URLError.Code.secureConnectionFailed.rawValue,
                     URLError.Code.serverCertificateUntrusted.rawValue:
                    return .securityFailure

                case URLError.Code.fileDoesNotExist.rawValue,
                     URLError.Code.cannotConnectToHost.rawValue,
                     URLError.Code.resourceUnavailable.rawValue:
                    // Hard resource or TCP-level failures after successful name resolution.
                    return .permanentFailure

                case URLError.Code.cannotFindHost.rawValue,
                     URLError.Code.dnsLookupFailed.rawValue:
                    // DNS-level lookup failures are treated as transient.
                    //
                    // Reasons this is intentional and safe:
                    // - Mobile networks frequently produce transient DNS flakes.
                    // - When ``SecurityConfiguration/requiresDNSSECValidationForStreaming`` is true,
                    //   a resolver that cannot return a validated answer for a signed zone will
                    //   cause the URLSession task to surface as a lookup failure. Treating it
                    //   transient ensures we do not permanently brick streaming on networks where
                    //   DNSSEC validation is "unavailable" from the client's perspective (the
                    //   requirement is opt-in safe).
                    // - Server selection / recreatePlayerItem paths provide fallback recovery.
                    //
                    // (cannotConnectToHost stays permanent: it means DNS succeeded but TCP failed.)
                    return .transientFailure

                case URLError.Code.badServerResponse.rawValue:
                    // Temporary 5xx or similar — allow recreate / fallback.
                    return .transientFailure

                default:
                    return .transientFailure
                }
            }

            // AVFoundationErrorDomain, Fig* internals, OSStatus decoder issues, and other
            // non-URL errors are the common manifestation of live ICY "first packets" noise.
            // We deliberately classify them as transient so the early-window guard in
            // `handleItemStatusFailure` (and the equivalent logic in addObservers) can
            // trigger `recreatePlayerItem()` instead of a user-visible failure.
            return .transientFailure
        }

        /// The localized status reason key to emit for this classification.
        var statusString: String {
            switch self {
            case .securityFailure:
                return String(localized: "status_security_failed", table: "Localizable")
            case .permanentFailure:
                return String(localized: "status_failed", table: "Localizable")
            case .transientFailure:
                return String(localized: "status_buffering", table: "Localizable")
            case .unknown:
                return String(localized: "status_connecting", table: "Localizable")
            }
        }

        /// True only for errors that should never be auto-recovered.
        ///
        /// Transient and unknown errors remain eligible for the per-stream retry budget
        /// and `recreatePlayerItem` when the item is still fresh (`!hasStartedPlaying`).
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
    private func markSSLHandshakeComplete(for connectionId: UUID) {
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
                print("[DirectStreamingPlayer] [SSL Protection] Cleared timer for connection \(connectionId)")
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
                print("[DirectStreamingPlayer] [SSL Protection] Cleared timer for connection \(connectionId)")
                #endif
            }
            self.activeConnections.removeAll()
            
            #if DEBUG
            print("[DirectStreamingPlayer] [SSL Protection] Cleared all SSL protection timers")
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
            print("⏰ [Hard Timeout] Completing hung loading request after 15s – this should never happen only on unresponsive servers")
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
    ///
    /// Now delegates to the authoritative playback intent helper
    /// instead of deriving from visualState. This makes Direct consistent with its
    /// internal guards.
    var shouldAutoPlayOrResume: Bool {
        get async {
            await SharedPlayerManager.shared.canProceedWithPlayback()
        }
    }

    /// Marks the current intent as user-initiated pause.
    /// This should be called from all user-facing pause paths (button, widget, remote commands, Darwin notifications, etc.).
    func markAsUserPaused() async {
        await SharedPlayerManager.shared.setUserPaused()
        
        #if DEBUG
        print("[DirectStreamingPlayer] markAsUserPaused() called – currentVisualState = .userPaused")
        #endif
    }

    /// Marks the current intent as actively playing.
    /// Call this after a successful manual play or auto-resume (e.g. after AVPlayer starts with rate == 1.0).
    func markAsPlaying() async {
        await SharedPlayerManager.shared.setPlaying()
        
        #if DEBUG
        print("[DirectStreamingPlayer] ▶ markAsPlaying() called – currentVisualState = .playing")
        #endif
    }
}
