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
///   - Requires the app security model (`nuuk`) to be in the authorized list.
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

/// Represents the network path status for connectivity monitoring.
enum NetworkPathStatus: Sendable {
    case satisfied
    case unsatisfied
    case requiresConnection
}

/// Protocol for monitoring network path changes.
protocol NetworkPathMonitoring: AnyObject {
    /// Handler for network path updates.
    var pathUpdateHandler: (@Sendable (NetworkPathStatus) -> Void)? { get set }
    /// Starts monitoring on a specified queue.
    func start(queue: DispatchQueue)
    /// Cancels monitoring.
    func cancel()
}

/// Adapts `NWPathMonitor` to the `NetworkPathMonitoring` protocol.
class NWPathMonitorAdapter: NetworkPathMonitoring {
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

/// Manages direct streaming playback, including network monitoring and security validation.
class DirectStreamingPlayer: NSObject {
    // MARK: - Security Model
    private let appSecurityModel = "stjohns"
    private var isValidating = false
    #if DEBUG
    /// The last time security validation was performed (exposed for debugging).
    var validationTimer: Timer?
    #else
    private var validationTimer: Timer?
    #endif
    private let validationCacheDuration: TimeInterval = 600 // 10 minutes
    private var sslConnectionTimeout: Timer?
    private var isSSLHandshakeComplete = false
    private var hasStartedPlaying = false
    
    /// Represents the state of security model validation.
    enum ValidationState {
        case pending
        case success
        case failedTransient
        case failedPermanent
    }
    var validationState: ValidationState = .pending
    private var lastValidationTime: Date?
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
    
    private var thermalObserver: NSObjectProtocol?
    private var wasPlayingBeforeThermal = false
    
    // Public accessors for ViewController
    var lastFailedServer: String? { return lastFailedServerName }
    var selectedServerInfo: Server { return currentSelectedServer }
    
    struct Stream {
        let title: String
        let url: URL
        let language: String
        let languageCode: String
        let flag: String
    }
        
    static let availableStreams = [
        Stream(title: NSLocalizedString("lutheran_radio_title", comment: "Title for Lutheran Radio") + " - " +
               NSLocalizedString("language_english", comment: "English language option"),
               url: URL(string: "https://english.lutheran.radio:8443/lutheranradio.mp3")!,
               language: NSLocalizedString("language_english", comment: "English language option"),
               languageCode: "en",
               flag: "🇺🇸"),
        Stream(title: NSLocalizedString("lutheran_radio_title", comment: "Title for Lutheran Radio") + " - " +
               NSLocalizedString("language_german", comment: "German language option"),
               url: URL(string: "https://german.lutheran.radio:8443/lutheranradio.mp3")!,
               language: NSLocalizedString("language_german", comment: "German language option"),
               languageCode: "de",
               flag: "🇩🇪"),
        Stream(title: NSLocalizedString("lutheran_radio_title", comment: "Title for Lutheran Radio") + " - " +
               NSLocalizedString("language_finnish", comment: "Finnish language option"),
               url: URL(string: "https://finnish.lutheran.radio:8443/lutheranradio.mp3")!,
               language: NSLocalizedString("language_finnish", comment: "Finnish language option"),
               languageCode: "fi",
               flag: "🇫🇮"),
        Stream(title: NSLocalizedString("lutheran_radio_title", comment: "Title for Lutheran Radio") + " - " +
               NSLocalizedString("language_swedish", comment: "Swedish language option"),
               url: URL(string: "https://swedish.lutheran.radio:8443/lutheranradio.mp3")!,
               language: NSLocalizedString("language_swedish", comment: "Swedish language option"),
               languageCode: "sv",
               flag: "🇸🇪"),
        Stream(title: NSLocalizedString("lutheran_radio_title", comment: "Title for Lutheran Radio") + " - " +
               NSLocalizedString("language_estonian", comment: "Estonian language option"),
               url: URL(string: "https://estonian.lutheran.radio:8443/lutheranradio.mp3")!,
               language: NSLocalizedString("language_estonian", comment: "Estonian language option"),
               languageCode: "ee",
               flag: "🇪🇪"),
    ]
    
    private let audioSession: AVAudioSession
    private let pathMonitor: NetworkPathMonitoring
    
    // MARK: - Enhanced SSL Protection with Connection Tracking
    private struct ConnectionInfo {
        let id: UUID
        let startTime: Date
        let timer: Timer
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
    
    private var selectedServer: Server = servers[0]
    
    #if DEBUG
    var retryWorkItem: DispatchWorkItem?
    #else
    private var retryWorkItem: DispatchWorkItem?
    #endif
    
    /// Work item for pending playback operations that can be cancelled
    private var pendingPlaybackWorkItem: DispatchWorkItem?
    
    /// Track deallocation state
    private var isDeallocating = false
    
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
                print("📡 Avoiding recently failed server \(lastFailed), using \(betterServer.name)")
                #endif
                currentSelectedServer = betterServer
                completion(betterServer)
                return
            }
        }
        
        // Existing throttling logic
        guard lastServerSelectionTime == nil || Date().timeIntervalSince(lastServerSelectionTime!) > 10.0 else {
            #if DEBUG
            print("📡 selectOptimalServer: Throttling server selection, using cached server: \(currentSelectedServer.name)")
            #endif
            completion(currentSelectedServer)
            return
        }
        
        serverSelectionWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else {
                completion(Self.servers[0])
                return
            }
            self.fetchServerIPsAndLatencies { results in
                let validResults = results.filter { $0.latency != .infinity }
                if let bestResult = validResults.min(by: { $0.latency < $1.latency }) {
                    self.currentSelectedServer = bestResult.server
                    #if DEBUG
                    print("📡 [Server Selection] Selected \(bestResult.server.name) with latency \(bestResult.latency)s")
                    #endif
                } else {
                    self.currentSelectedServer = Self.servers[0]
                    #if DEBUG
                    print("📡 [Server Selection] No valid ping results, falling back to \(self.currentSelectedServer.name)")
                    #endif
                }
                completion(self.currentSelectedServer)
            }
        }
        serverSelectionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }
    
    public enum PlaybackState {
        case unknown
        case readyToPlay
        case failed(Error?)
    }
    
    private var lastError: Error?
        
    public func getPlaybackState() -> PlaybackState {
        switch playerItem?.status {
        case .unknown:
            return .unknown
        case .readyToPlay:
            return .readyToPlay
        case .failed:
            return .failed(playerItem?.error)
        default:
            return .unknown
        }
    }
    
    var isPlaying: Bool {
        return player?.rate ?? 0 > 0
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
        return playerItem != nil && player?.currentItem != nil
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
    private func executeWithAudioPriority<T>(_ operation: @escaping () -> T, completion: @escaping (T) -> Void) {
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
    private func executeAudioOperation<T>(_ operation: @escaping () -> T, completion: @escaping (T) -> Void) {
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
    private var statusObserver: NSKeyValueObservation?
    private var registeredKeyPaths: [ObjectIdentifier: Set<String>] = [:]
    private var removedObservers: Set<ObjectIdentifier> = []
    #if DEBUG
    var isSwitchingStream = false // Track ongoing stream switches (testing)
    #else
    private var isSwitchingStream = false // Track ongoing stream switches (production)
    #endif
    private var timeObserver: Any?
    private var timeObserverPlayer: AVPlayer? // Track the player that added the time observer
    private var isObservingBuffer = false
    private var bufferingTimer: Timer?
    private var activeResourceLoaders: [AVAssetResourceLoadingRequest: StreamingSessionDelegate] = [:] // Track resource loaders
    
    var onStatusChange: ((Bool, String) -> Void)?
    var onMetadataChange: ((String?) -> Void)?
    internal var currentMetadata: String?
    
    // Safe wrappers to ensure callbacks are always on main thread
    private func safeOnStatusChange(isPlaying: Bool, status: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChange?(isPlaying, status)
        }
    }
    
    private func safeOnMetadataChange(metadata: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.onMetadataChange?(metadata)
        }
    }
    
    private weak var delegate: AnyObject?
    
    func setDelegate(_ delegate: AnyObject?) {
        self.delegate = delegate
    }
    
    // MARK: - Security Model Validation
    
    private func fetchValidSecurityModelsImplementation(completion: @escaping (Result<Set<String>, Error>) -> Void) {
        let domain = "securitymodels.lutheran.radio"
        #if DEBUG
        print("🔒 [Fetch Security Models] Fetching valid security models for domain: \(domain)")
        #endif
        
        // Use SSL queue with priority escalation for audio-blocking operations
        sslValidationQueue.async { [weak self] in
            // Escalate to userInteractive if audio is waiting
            if self?.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                DispatchQueue.global(qos: .userInteractive).async {
                    self?.queryTXTRecord(domain: domain) { result in
                        DispatchQueue.main.async {
                            completion(result)
                        }
                    }
                }
            } else {
                self?.queryTXTRecord(domain: domain) { result in
                    DispatchQueue.main.async {
                        completion(result)
                    }
                }
            }
        }
    }
    
    #if DEBUG
    open func fetchValidSecurityModels(completion: @escaping (Result<Set<String>, Error>) -> Void) {
        fetchValidSecurityModelsImplementation(completion: completion)
    }
    #else
    private func fetchValidSecurityModels(completion: @escaping (Result<Set<String>, Error>) -> Void) {
        fetchValidSecurityModelsImplementation(completion: completion)
    }
    #endif
    
    private func queryTXTRecord(domain: String, completion: @escaping (Result<Set<String>, Error>) -> Void) {
        class QueryContext {
            weak var player: DirectStreamingPlayer?
            let completion: (Result<Set<String>, Error>) -> Void
            init(player: DirectStreamingPlayer, completion: @escaping (Result<Set<String>, Error>) -> Void) {
                self.player = player
                self.completion = completion
            }
        }

        var serviceRef: DNSServiceRef?
        let flags: DNSServiceFlags = kDNSServiceFlagsTimeout
        let interfaceIndex: UInt32 = 0
        let type: UInt16 = UInt16(kDNSServiceType_TXT)
        let rrClass: UInt16 = UInt16(kDNSServiceClass_IN)

        #if DEBUG
        print("🔍 [DNS Query] Starting TXT record query for domain: \(domain)")
        #endif

        guard let domainCStr = domain.cString(using: .utf8) else {
            #if DEBUG
            print("❌ [DNS Query] Failed to convert domain to C string")
            #endif
            completion(.failure(NSError(domain: "radio.lutheran", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid domain"])))
            return
        }

        let context = QueryContext(player: self, completion: completion)
        let contextPointer = UnsafeMutablePointer<QueryContext>.allocate(capacity: 1)
        contextPointer.initialize(to: context)
        defer {
            contextPointer.deinitialize(count: 1)
            contextPointer.deallocate()
            #if DEBUG
            print("🧹 [DNS Query] Deallocated QueryContext memory")
            #endif
        }

        let error = DNSServiceQueryRecord(
            &serviceRef,
            flags,
            interfaceIndex,
            domainCStr,
            type,
            rrClass,
            { (ref, flags, interface, errorCode, fullName, rrtype, rrclass, rdlen, rdata, ttl, context) in
                let contextPointer = context?.assumingMemoryBound(to: QueryContext.self)
                guard let queryContext = contextPointer?.pointee else {
                    #if DEBUG
                    print("❌ [DNS Query Callback] QueryContext is nil")
                    #endif
                    return
                }
                let completion = queryContext.completion
                guard let player = queryContext.player else {
                    #if DEBUG
                    print("❌ [DNS Query Callback] Player instance deallocated")
                    #endif
                    completion(.failure(NSError(domain: "radio.lutheran", code: -1, userInfo: [NSLocalizedDescriptionKey: "Player deallocated"])))
                    return
                }

                guard errorCode == kDNSServiceErr_NoError, let rawData = rdata else {
                    #if DEBUG
                    print("❌ [DNS Query Callback] Query failed with errorCode=\(errorCode)")
                    #endif
                    completion(.failure(NSError(domain: "dnssd", code: Int(errorCode), userInfo: [NSLocalizedDescriptionKey: "DNS query failed"])))
                    return
                }

                #if DEBUG
                print("✅ [DNS Query Callback] Retrieved TXT record data: length=\(rdlen)")
                #endif

                let txtData = Data(bytes: rawData, count: Int(rdlen))
                let models = player.parseTXTRecordData(txtData)
                completion(.success(models))
            },
            contextPointer
        )

        if error == kDNSServiceErr_NoError, let serviceRef = serviceRef {
            #if DEBUG
            print("🚀 [DNS Query] DNSServiceQueryRecord initiated successfully")
            #endif
            DNSServiceProcessResult(serviceRef)
            DNSServiceRefDeallocate(serviceRef)
        } else {
            #if DEBUG
            print("❌ [DNS Query] DNSServiceQueryRecord failed with error=\(error)")
            #endif
            completion(.failure(NSError(domain: "dnssd", code: Int(error), userInfo: [NSLocalizedDescriptionKey: "DNS service init failed"])))
        }
    }

    private func parseTXTRecordData(_ data: Data) -> Set<String> {
        var models = Set<String>()
        var index = 0
        while index < data.count {
            let length = Int(data[index])
            guard length > 0 && length <= 255 else { break } // Stop parsing on invalid length
            index += 1
            if index + length <= data.count {
                let strData = data.subdata(in: index..<index + length)
                if let str = String(data: strData, encoding: .utf8) {
                    let modelList = str.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
                    models.formUnion(modelList)
                }
                index += length
            } else {
                break
            }
        }
        #if DEBUG
        print("📜 [Parse TXT Record] Parsed models: \(models)")
        #endif
        return models
    }
    
    private func validateSecurityModelAsyncImplementation(completion: @escaping (Bool) -> Void) {
        guard !isValidating else {
            #if DEBUG
            print("🔒 [Validate Async] Validation in progress, checking state")
            #endif
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self else {
                    completion(false)
                    return
                }
                switch self.validationState {
                case .success:
                    #if DEBUG
                    print("🔒 [Validate Async] Reusing cached success state")
                    #endif
                    completion(true)
                case .failedPermanent:
                    #if DEBUG
                    print("🔒 [Validate Async] Reusing cached failedPermanent state")
                    #endif
                    completion(false)
                default:
                    #if DEBUG
                    print("🔒 [Validate Async] Retrying validation")
                    #endif
                    self.validateSecurityModelAsync(completion: completion)
                }
            }
            return
        }

        if let lastValidation = lastValidationTime,
           Date().timeIntervalSince(lastValidation) < validationCacheDuration {
            switch validationState {
            case .success:
                #if DEBUG
                print("🔒 [Validate Async] Using cached validation: Success, time since last: \(Date().timeIntervalSince(lastValidation))s")
                #endif
                DispatchQueue.main.async {
                    self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_connecting"))
                    completion(true)
                }
                return
            case .failedPermanent:
                #if DEBUG
                print("🔒 [Validate Async] Using cached validation: FailedPermanent, time since last: \(Date().timeIntervalSince(lastValidation))s")
                #endif
                hasPermanentError = true
                DispatchQueue.main.async {
                    self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_security_failed"))
                    completion(false)
                }
                return
            case .failedTransient, .pending:
                #if DEBUG
                print("🔒 [Validate Async] Cache stale or transient/pending state, proceeding with validation")
                #endif
            }
        }
        
        isValidating = true

        performConnectivityCheck { [weak self] isConnected in
            guard let self = self else {
                completion(false)
                return
            }

            if !isConnected {
                #if DEBUG
                print("🔒 [Validate Async] No internet, transient failure")
                #endif
                self.isValidating = false
                self.validationState = .failedTransient
                self.hasInternetConnection = false
                DispatchQueue.main.async {
                    self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_no_internet"))
                    completion(false)
                }
                return
            }

            self.hasInternetConnection = true
            #if DEBUG
            print("🔒 [Validate Async] Starting validation for model: \(self.appSecurityModel)")
            #endif

            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.isValidating else { return }
                self.isValidating = false
                self.validationState = .failedTransient
                #if DEBUG
                print("🔒 [Validate Async] Validation timed out")
                #endif
                DispatchQueue.main.async {
                    self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_no_internet"))
                    completion(false)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: timeoutWorkItem)

            self.fetchValidSecurityModels { [weak self] result in
                guard let self = self else {
                    completion(false)
                    return
                }
                timeoutWorkItem.cancel()
                self.isValidating = false
                self.lastValidationTime = Date()
                #if DEBUG
                print("🔒 [Validate Async] Updated lastValidationTime to \(self.lastValidationTime!)")
                #endif
                switch result {
                case .success(let validModels):
                    #if DEBUG
                    print("🔒 [Validate Async] Fetched models: \(validModels)")
                    #endif
                    if validModels.isEmpty {
                        self.validationState = .failedPermanent
                        self.hasPermanentError = true
                        #if DEBUG
                        print("🔒 [Validate Async] No valid models received")
                        #endif
                        DispatchQueue.main.async {
                            self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_security_failed"))
                            completion(false)
                        }
                    } else {
                        let isValid = validModels.contains(self.appSecurityModel.lowercased())
                        self.validationState = isValid ? .success : .failedPermanent
                        #if DEBUG
                        print("🔒 [Validate Async] Result: isValid=\(isValid), model=\(self.appSecurityModel), validModels=\(validModels)")
                        #endif
                        if !isValid {
                            self.hasPermanentError = true
                            DispatchQueue.main.async {
                                self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_security_failed"))
                                completion(false)
                            }
                        } else {
                            self.hasPermanentError = false
                            DispatchQueue.main.async {
                                self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_connecting"))
                                completion(true)
                            }
                        }
                    }
                case .failure(let error):
                    self.validationState = .failedTransient
                    #if DEBUG
                    print("🔒 [Validate Async] Failed to fetch models: \(error.localizedDescription)")
                    #endif
                    DispatchQueue.main.async {
                        self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_no_internet"))
                        completion(false)
                    }
                }
            }
        }
    }
    
    #if DEBUG
    open func validateSecurityModelAsync(completion: @escaping (Bool) -> Void) {
        validateSecurityModelAsyncImplementation(completion: completion)
    }
    #else
    func validateSecurityModelAsync(completion: @escaping (Bool) -> Void) {
        validateSecurityModelAsyncImplementation(completion: completion)
    }
    #endif
    
    private func performConnectivityCheck(completion: @escaping (Bool) -> Void) {
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
        if validationState == .failedTransient {
            validationState = .pending
            lastValidationTime = nil
            #if DEBUG
            print("🔄 Reset transient errors to pending and invalidated cache")
            #endif
        }
        hasPermanentError = false
    }

    func isLastErrorPermanent() -> Bool {
        return validationState == .failedPermanent
    }
    
    override init() {
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
            validateSecurityModelAsync { [weak self] isValid in
                guard let self = self else { return }
                #if DEBUG
                print("🔒 Initial validation completed: \(isValid)")
                #endif
                if isValid {
                    self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_connecting"))
                }
            }
        }
        #if DEBUG
        logQueueHierarchy()
        #endif
        
        setupThermalProtection()
    }
    
    #if DEBUG
    open func setupNetworkMonitoring() {
        networkMonitor = pathMonitor
        networkMonitor?.pathUpdateHandler = { [weak self] status in
            guard let self = self else {
                print("🧹 [Network] Skipped path update: self is nil")
                return
            }
            let wasConnected = self.hasInternetConnection
            self.hasInternetConnection = status == .satisfied
            print("🌐 [Network] Status: \(self.hasInternetConnection ? "Connected" : "Disconnected")")
            if self.hasInternetConnection && !wasConnected {
                print("🌐 [Network] Connection restored, previous server: \(self.selectedServer.name)")
                
                // Clear DNS overrides to force new server selection
                self.lastServerSelectionTime = nil
                self.selectedServer = Self.servers[0] // Reset to default
                print("🌐 [Network] Cleared DNS overrides for fresh server selection")
                
                self.lastValidationTime = nil
                self.validationState = .pending
                print("🔒 [Network] Invalidated security model validation cache")
                self.selectOptimalServer { server in
                    print("🌐 [Network] New server selected: \(server.name)")
                    if self.validationState == .failedTransient {
                        self.validationState = .pending
                        self.hasPermanentError = false
                        self.validateSecurityModelAsync { isValid in
                            print("🔒 [Network] Revalidation result: \(isValid)")
                            if !isValid {
                                DispatchQueue.main.async {
                                    self.safeOnStatusChange(isPlaying: false, status: String(localized: self.validationState == .failedPermanent ? "status_security_failed" : "status_no_internet"))
                                }
                            } else if self.player?.rate ?? 0 == 0, !self.hasPermanentError {
                                self.play { success in
                                    DispatchQueue.main.async {
                                        self.onStatusChange?(success, String(localized: success ? "status_playing" : "status_stream_unavailable"))
                                    }
                                }
                            }
                        }
                    }
                }
            } else if !self.hasInternetConnection && wasConnected {
                self.validationState = .failedTransient
                DispatchQueue.main.async {
                    self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_no_internet"))
                }
            }
        }
        networkMonitor?.start(queue: networkQueue)
    }
    #else
    private func setupNetworkMonitoring() {
        networkMonitor = pathMonitor
        networkMonitor?.pathUpdateHandler = { [weak self] status in
            guard let self = self else { return }
            let wasConnected = self.hasInternetConnection
            self.hasInternetConnection = status == .satisfied
            if self.hasInternetConnection && !wasConnected {
                // Reset server selection to force new selection
                self.lastServerSelectionTime = nil
                self.selectedServer = Self.servers[0] // Reset to default
                
                self.lastValidationTime = nil
                self.validationState = .pending
                self.selectOptimalServer { server in
                    if self.validationState == .failedTransient {
                        self.validationState = .pending
                        self.hasPermanentError = false
                        self.validateSecurityModelAsync { isValid in
                            if !isValid {
                                DispatchQueue.main.async {
                                    self.safeOnStatusChange(isPlaying: false, status: String(localized: self.validationState == .failedPermanent ? "status_security_failed" : "status_no_internet"))
                                }
                            } else if self.player?.rate ?? 0 == 0, !self.hasPermanentError {
                                self.play { success in
                                    DispatchQueue.main.async {
                                        self.onStatusChange?(success, String(localized: success ? "status_playing" : "status_stream_unavailable"))
                                    }
                                }
                            }
                        }
                    }
                }
            } else if !self.hasInternetConnection && wasConnected {
                self.validationState = .failedTransient
                DispatchQueue.main.async {
                    self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_no_internet"))
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
            guard let self = self else { return }
            
            if ProcessInfo.processInfo.thermalState == .critical ||
               ProcessInfo.processInfo.thermalState == .serious {
                // Pause if device temperature critical or serious
                if self.isPlaying {
                    self.wasPlayingBeforeThermal = true
                    self.stop {
                        self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_thermal_paused"))
                    }
                }
            } else if self.wasPlayingBeforeThermal &&
                        (ProcessInfo.processInfo.thermalState == .nominal ||
                         ProcessInfo.processInfo.thermalState == .fair) {
                // Resume when the device has actually cooled down to a safe temperature
                self.wasPlayingBeforeThermal = false
                self.play { _ in }
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
        #if DEBUG
        print("🎵 Player initialized, starting validation")
        #endif
        if hasInternetConnection {
            validateSecurityModelAsync { [weak self] isValid in
                guard let self = self else { return }
                #if DEBUG
                print("🔒 Initial validation completed: \(isValid)")
                #endif
                if isValid {
                    self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_connecting"))
                }
            }
        }
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
    
    // Helper to construct stream URL with selected baseHostname
    private func getStreamURL(for stream: Stream, with server: Server) -> URL? {
        let languagePrefix = stream.url.host?.components(separatedBy: ".")[0] ?? ""
        let newHostname = "\(languagePrefix)-\(server.subdomain).\(server.baseHostname)"
        var components = URLComponents(url: stream.url, resolvingAgainstBaseURL: false)
        components?.host = newHostname
        return components?.url  // Direct https:// URL
    }
    
    /// Starts periodic certificate validation
    private func startPeriodicValidation() {
        validationTimer?.invalidate()
        validationTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard let streamURL = self.getStreamURL(for: self.selectedStream, with: self.selectedServer) else {
                self.stop()
                DispatchQueue.main.async {
                    self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_stream_unavailable"))
                }
                #if DEBUG
                print("🔒 [Periodic Validation] Invalid stream URL, stopping stream")
                #endif
                return
            }
            CertificateValidator.shared.validateServerCertificate(for: streamURL) { isValid in
                if !isValid {
                    self.stop()
                    DispatchQueue.main.async {
                        self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_security_failed"))
                    }
                    #if DEBUG
                    print("🔒 [Periodic Validation] Failed, stopping stream")
                    #endif
                }
            }
        }
    }

    func play(completion: @escaping (Bool) -> Void) {
        if validationState == .pending {
            validateSecurityModelAsync { [weak self] isValid in
                guard let self = self else { completion(false); return }
                if isValid {
                    self.play(completion: completion)
                } else {
                    let status = self.validationState == .failedPermanent ? String(localized: "status_security_failed") : String(localized: "status_no_internet")
                    DispatchQueue.main.async {
                        self.safeOnStatusChange(isPlaying: false, status: status)
                        completion(false)
                    }
                }
            }
            return
        }
        
        guard validationState == .success else {
            let status = validationState == .failedPermanent ? String(localized: "status_security_failed") : String(localized: "status_no_internet")
            DispatchQueue.main.async {
                self.safeOnStatusChange(isPlaying: false, status: status)
                completion(false)
            }
            return
        }
        
        selectOptimalServer { [weak self] server in
            guard let self = self else { completion(false); return }
            guard let streamURL = self.getStreamURL(for: self.selectedStream, with: server) else {
                self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_stream_unavailable"))
                completion(false)
                return
            }
            CertificateValidator.shared.validateServerCertificate(for: streamURL) { isValid in
                if isValid {
                    self.playWithServer(server, fallbackServers: Self.servers.filter { $0.name != server.name }) { success in
                        if success { self.startPeriodicValidation() }
                        completion(success)
                    }
                } else {
                    self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_security_failed"))
                    completion(false)
                }
            }
        }
    }
    
    private func playWithServer(_ server: Server, fallbackServers: [Server], completion: @escaping (Bool) -> Void) {
        self.lastServerSelectionTime = Date()
        #if DEBUG
        print("📡 Attempting playback with server: \(server.name)")
        #endif
        
        guard let streamURL = self.getStreamURL(for: self.selectedStream, with: server) else {
            #if DEBUG
            print("❌ Failed to construct stream URL for server: \(server.name)")
            #endif
            tryNextServer(fallbackServers: fallbackServers, completion: completion)
            return
        }
        
        CertificateValidator.shared.validateServerCertificate(for: streamURL) { [weak self] isValid in
            guard let self = self else {
                completion(false)
                return
            }
            
            if !isValid {
                #if DEBUG
                print("🔒 Certificate validation failed for server: \(server.name)")
                #endif
                self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_security_failed"))
                self.tryNextServer(fallbackServers: fallbackServers, completion: completion)
                return
            }
            
            var urlComponents = URLComponents(url: streamURL, resolvingAgainstBaseURL: false)
            urlComponents?.queryItems = [URLQueryItem(name: "security_model", value: self.appSecurityModel)]
            
            guard let finalURL = urlComponents?.url else {
                #if DEBUG
                print("❌ Failed to construct final URL with security model for server: \(server.name)")
                #endif
                self.tryNextServer(fallbackServers: fallbackServers, completion: completion)
                return
            }
            
            #if DEBUG
            print("📡 Playing stream with URL: \(finalURL.absoluteString)")
            #endif
            
            self.startPlaybackWithFallback(with: finalURL, server: server, fallbackServers: fallbackServers, completion: completion)
        }
    }

    private func tryNextServer(fallbackServers: [Server], completion: @escaping (Bool) -> Void) {
        // Mark the current server as failed
        lastFailedServerName = currentSelectedServer.name
        serverFailureCount[currentSelectedServer.name, default: 0] += 1
        
        #if DEBUG
        print("📡 Server \(currentSelectedServer.name) failed (count: \(serverFailureCount[currentSelectedServer.name] ?? 0))")
        #endif
        
        guard let nextServer = fallbackServers.first else {
            #if DEBUG
            print("📡 No more servers to try")
            #endif
            self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_stream_unavailable"))
            completion(false)
            return
        }
        
        #if DEBUG
        print("📡 Trying fallback server: \(nextServer.name)")
        #endif
                
        currentSelectedServer = nextServer
        let remainingServers = Array(fallbackServers.dropFirst())
        playWithServer(nextServer, fallbackServers: remainingServers, completion: completion)
    }
    
    func setStream(to stream: Stream) {
        // CRITICAL: Prevent concurrent stream switches
        guard !isSwitchingStream else {
            #if DEBUG
            print("🔗 Stream switch already in progress, ignoring request for \(stream.languageCode)")
            #endif
            return
        }
        isSwitchingStream = true
        
        #if DEBUG
        print("🔗 ATOMIC STREAM SWITCH: \(selectedStream.languageCode) -> \(stream.languageCode)")
        #endif
        
        // CRITICAL: Update selectedStream immediately and atomically
        selectedStream = stream
        
        // Force immediate state save to prevent race conditions
        SharedPlayerManager.shared.saveCurrentState()
        
        stop { [weak self] in
            guard let self = self else {
                self?.isSwitchingStream = false
                return
            }
            
            // Ensure selectedStream is still set after stop
            self.selectedStream = stream
            
            #if DEBUG
            print("📡 Stream set to: \(stream.language), URL: \(stream.url)")
            print("🔍 DEBUG: selectedStream.languageCode = \(self.selectedStream.languageCode)")
            #endif
            
            // Force another state save after stop completes
            SharedPlayerManager.shared.saveCurrentState()
            
            if self.validationState == .pending {
                self.validateSecurityModelAsync { [weak self] isValid in
                    guard let self = self else {
                        self?.isSwitchingStream = false
                        return
                    }
                    defer { self.isSwitchingStream = false }
                    
                    if isValid {
                        self.playAfterStreamSwitch()
                    } else {
                        let status = self.validationState == .failedPermanent ? "status_security_failed" : "status_no_internet"
                        DispatchQueue.main.async {
                            self.safeOnStatusChange(isPlaying: false, status: NSLocalizedString(status, comment: ""))
                        }
                    }
                }
            } else if self.validationState == .success {
                defer { self.isSwitchingStream = false }
                self.playAfterStreamSwitch()
            } else {
                defer { self.isSwitchingStream = false }
                let status = self.validationState == .failedPermanent ? "status_security_failed" : "status_no_internet"
                DispatchQueue.main.async {
                    self.safeOnStatusChange(isPlaying: false, status: NSLocalizedString(status, comment: ""))
                }
            }
        }
    }

    // Helper method to handle playback after stream switch
    private func playAfterStreamSwitch() {
        selectOptimalServer { [weak self] server in
            guard let self = self else {
                self?.isSwitchingStream = false
                return
            }
            self.lastServerSelectionTime = Date()
            #if DEBUG
            print("📡 Selected server for stream switch: \(server.name)")
            #endif
            self.play { [weak self] success in
                guard let self = self else { return }
                if success {
                    #if DEBUG
                    print("✅ Stream switched to: \(self.selectedStream.language)")
                    #endif
                    if self.delegate != nil {
                        self.safeOnStatusChange(isPlaying: true, status: String(localized: "status_playing"))
                    }
                } else {
                    #if DEBUG
                    print("❌ Stream switch failed for: \(self.selectedStream.language)")
                    #endif
                    if self.delegate != nil {
                        self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_stream_unavailable"))
                    }
                }
                self.isSwitchingStream = false
            }
        }
    }

    // Helper method to handle stream switch completion
    private func handleStreamSwitchCompletion(_ success: Bool) {
        if success {
            #if DEBUG
            print("✅ Stream switched to: \(self.selectedStream.language)")
            #endif
            if self.delegate != nil {
                self.safeOnStatusChange(isPlaying: true, status: String(localized: "status_playing"))
            }
        } else {
            #if DEBUG
            print("❌ Stream switch failed for: \(self.selectedStream.language)")
            #endif
            if self.delegate != nil {
                self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_stream_unavailable"))
            }
        }
        self.isSwitchingStream = false
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
    
    // FIXED: Reset SSL tracking when starting new playback
    private func startPlaybackWithFallback(with streamURL: URL, server: Server, fallbackServers: [Server], completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                completion(false)
                return
            }
            
            self.stop()
            
            // Create connection with tracking
            let connectionStartTime = Date()
            let connectionId = self.setupSSLProtectionTimer(for: connectionStartTime)
            
            // Reset SSL tracking for new connection
            self.isSSLHandshakeComplete = false
            self.hasStartedPlaying = false
            
            let finalURL = streamURL
            
            #if DEBUG
            print("📡 [SSL Fix] Starting connection \(connectionId) with URL: \(finalURL)")
            print("🔒 [SSL Timing] Connection started at: \(connectionStartTime)")
            #endif
            
            let asset = AVURLAsset(url: finalURL)
            asset.resourceLoader.setDelegate(self, queue: DispatchQueue(label: "radio.lutheran.resourceloader"))
            self.playerItem = AVPlayerItem(asset: asset)
            
            if self.player == nil {
                self.player = AVPlayer(playerItem: self.playerItem)
                #if DEBUG
                print("🎵 Created new AVPlayer for connection \(connectionId)")
                #endif
            } else {
                self.player?.replaceCurrentItem(with: self.playerItem)
                #if DEBUG
                print("🎵 Reused existing AVPlayer for connection \(connectionId)")
                #endif
            }
            
            self.addObservers()
            
            // FIXED: Single observer that properly handles SSL timer cleanup
            var tempStatusObserver: NSKeyValueObservation?
            tempStatusObserver = self.playerItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard let self = self else {
                    completion(false)
                    return
                }
                
                let connectionAge = Date().timeIntervalSince(connectionStartTime)
                
                switch item.status {
                case .readyToPlay:
                    tempStatusObserver?.invalidate()
                    
                    // CRITICAL FIX: Clear the SSL timer immediately when ready to play
                    self.clearSSLProtectionTimer(for: connectionId)
                    
                    // Mark handshake complete for both systems
                    self.markSSLHandshakeComplete(for: connectionId)
                    self.isSSLHandshakeComplete = true
                    
                    #if DEBUG
                    print("🔒 [SSL Timing] Ready to play after \(connectionAge)s for connection \(connectionId)")
                    print("🔒 [SSL Protection] Timer cleared for successful connection")
                    #endif
                    
                    self.serverFailureCount[server.name] = 0
                    self.lastFailedServerName = nil
                    
                    // Set up metadata
                    self.metadataOutput = AVPlayerItemMetadataOutput(identifiers: nil)
                    self.metadataOutput?.setDelegate(self, queue: .main)
                    if let metadataOutput = self.metadataOutput {
                        self.playerItem?.add(metadataOutput)
                    }
                    
                    // FIXED: Start playback immediately without delay
                    #if DEBUG
                    print("🎵 [Auto Play] Actually calling player.play() for \(self.selectedStream.language)")
                    #endif
                    self.player?.play()
                    self.hasStartedPlaying = true
                    
                    // Check playback status after a brief moment
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if self.player?.rate ?? 0 > 0 {
                            self.safeOnStatusChange(isPlaying: true, status: String(localized: "status_playing"))
                            completion(true)
                        } else {
                            // If still not playing, try again
                            self.player?.play()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                let isPlaying = self.player?.rate ?? 0 > 0
                                self.onStatusChange?(isPlaying, String(localized: isPlaying ? "status_playing" : "status_buffering"))
                                completion(isPlaying)
                            }
                        }
                    }
                    
                case .failed:
                    tempStatusObserver?.invalidate()
                    self.clearSSLProtectionTimer(for: connectionId)
                    
                    #if DEBUG
                    print("❌ PlayerItem failed with server \(server.name) after \(connectionAge)s")
                    #endif
                    
                    if !fallbackServers.isEmpty {
                        self.tryNextServer(fallbackServers: fallbackServers, completion: completion)
                    } else {
                        self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_stream_unavailable"))
                        completion(false)
                    }
                    
                case .unknown:
                    #if DEBUG
                    print("⏳ PlayerItem status unknown after \(connectionAge)s, waiting...")
                    #endif
                @unknown default:
                    break
                }
            }
            
            // FIXED: Reduce timeout fallback since we clear timer on readyToPlay
            let adaptiveTimeout = self.getSSLTimeout()
            DispatchQueue.main.asyncAfter(deadline: .now() + max(adaptiveTimeout + 5.0, 15.0)) { [weak self] in
                guard let self = self, self.playerItem?.status != .readyToPlay else { return }
                tempStatusObserver?.invalidate()
                let connectionAge = Date().timeIntervalSince(connectionStartTime)
                #if DEBUG
                print("❌ Fallback timeout reached after \(connectionAge)s with server \(server.name)")
                #endif
                self.clearSSLProtectionTimer(for: connectionId)
                if !fallbackServers.isEmpty {
                    self.tryNextServer(fallbackServers: fallbackServers, completion: completion)
                } else {
                    self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_stream_unavailable"))
                    completion(false)
                }
            }
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
        sslConnectionTimeout?.invalidate()
        sslConnectionTimeout = nil
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
    
    // FIXED: Simplified status observer that doesn't conflict with SSL protection
    private func addObservers() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Remove existing observers for the current playerItem
            if let currentPlayerItem = self.playerItem {
                self.removeObservers(for: currentPlayerItem)
            }
            
            guard let playerItem = self.playerItem else { return }
            
            let playerItemKey = ObjectIdentifier(playerItem)
            var keyPathsSet = self.registeredKeyPaths[playerItemKey] ?? Set<String>()
            
            // FIXED: Simplified status observer without SSL conflicts
            self.statusObserver = playerItem.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    #if DEBUG
                    print("🎵 Player item status: \(item.status.rawValue)")
                    #endif
                    guard self.delegate != nil else { return }
                    
                    switch item.status {
                    case .readyToPlay:
                        // Don't interfere with SSL protection - let startPlaybackWithFallback handle it
                        break
                        
                    case .failed:
                        // Only handle if this isn't managed by startPlaybackWithFallback
                        if self.hasStartedPlaying {
                            self.lastError = item.error
                            let errorType = StreamErrorType.from(error: item.error)
                            self.hasPermanentError = errorType.isPermanent
                            self.safeOnStatusChange(isPlaying: false, status: errorType.statusString)
                            self.stop()
                        }
                        
                    case .unknown:
                        if self.hasStartedPlaying {
                            self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_buffering"))
                        }
                    @unknown default:
                        break
                    }
                }
            }
            #if DEBUG
            print("🧹 Added status observer for playerItem \(playerItemKey)")
            #endif
            
            // Add buffer observers (unchanged)
            let keyPaths = [
                "playbackBufferEmpty",
                "playbackLikelyToKeepUp",
                "playbackBufferFull"
            ]
            for keyPath in keyPaths {
                playerItem.addObserver(self, forKeyPath: keyPath, options: .new, context: nil)
                keyPathsSet.insert(keyPath)
                #if DEBUG
                print("🧹 Added observer for \(keyPath) to playerItem \(playerItemKey)")
                #endif
            }
            self.registeredKeyPaths[playerItemKey] = keyPathsSet
            self.isObservingBuffer = true
            
            // Add time observer (unchanged)
            let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            if let player = self.player, self.timeObserver == nil {
                self.timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
                    guard let self = self, self.delegate != nil else { return }
                    if self.player?.rate ?? 0 > 0 {
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
    
    // Add new methods for observer removal
    func removeObservers(for playerItem: AVPlayerItem?) {
        guard let playerItem = playerItem else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.removeObserversFrom(playerItem)
        }
    }

    private func removeObserversFrom(_ playerItem: AVPlayerItem) {
        let playerItemKey = ObjectIdentifier(playerItem)
        
        // Remove status observer if it's for this playerItem
        if let statusObserver = self.statusObserver {
            statusObserver.invalidate()
            self.statusObserver = nil
            #if DEBUG
            print("🧹 Removed status observer for playerItem \(playerItemKey)")
            #endif
        }
        
        // Remove buffer observers
        if let keyPathsSet = self.registeredKeyPaths[playerItemKey] {
            for keyPath in keyPathsSet {
                playerItem.removeObserver(self, forKeyPath: keyPath)
                #if DEBUG
                print("🧹 Removed observer for \(keyPath) from playerItem \(playerItemKey)")
                #endif
            }
            self.registeredKeyPaths.removeValue(forKey: playerItemKey)
        }
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard let keyPath = keyPath, let playerItem = object as? AVPlayerItem else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.delegate != nil else { return }
            
            // NEW: Add status monitoring for failed player items
            if keyPath == "status" {
                if playerItem.status == .failed {
                    #if DEBUG
                    print("🎵 Player item failed with error: \(playerItem.error?.localizedDescription ?? "Unknown")")
                    if let error = playerItem.error as NSError? {
                        print("🎵 Error domain: \(error.domain), code: \(error.code)")
                    }
                    #endif
                    
                    // Check for decoder-related failures (expanded error codes)
                    if let error = playerItem.error as NSError? {
                        let isDecoderError = error.domain == "AVFoundationErrorDomain" &&
                                           (error.code == -11819 ||  // Media services reset
                                            error.code == -11839 ||  // Cannot decode
                                            error.code == -12913)    // Decoder busy
                        
                        if isDecoderError {
                            #if DEBUG
                            print("🔄 AVFoundation decoder error detected, initiating recovery")
                            #endif
                            
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                self.recreatePlayerItem()
                            }
                            return
                        }
                    }
                    
                    // Handle other types of failures
                    self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_stream_unavailable"))
                }
                
            } else if keyPath == "playbackBufferEmpty" {
                if playerItem.isPlaybackBufferEmpty {
                    // ENHANCED: Expand your existing decoder error detection
                    if let error = playerItem.error as NSError?,
                       error.domain == "AVFoundationErrorDomain" {
                        #if DEBUG
                        print("🎵 Buffer empty with AVFoundation error detected, attempting recovery")
                        #endif
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.recreatePlayerItem()
                        }
                        return
                    }
                    
                    self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_buffering"))
                    self.startBufferingTimer()
                }
                
            } else if keyPath == "playbackLikelyToKeepUp" {
                if playerItem.isPlaybackLikelyToKeepUp && playerItem.status == .readyToPlay {
                    self.player?.play()
                    self.safeOnStatusChange(isPlaying: true, status: String(localized: "status_playing"))
                    self.stopBufferingTimer()
                } else if !playerItem.isPlaybackLikelyToKeepUp && self.player?.rate == 0 {
                    // NEW: Add stalled playback detection
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                        guard let self = self,
                              let currentItem = self.playerItem,
                              currentItem == playerItem,
                              !currentItem.isPlaybackLikelyToKeepUp,
                              self.player?.rate == 0 else { return }
                        
                        #if DEBUG
                        print("🔄 Stalled playback detected, attempting recovery")
                        #endif
                        
                        self.recreatePlayerItem()
                    }
                }
                
            } else if keyPath == "playbackBufferFull" {
                if playerItem.isPlaybackBufferFull {
                    self.player?.play()
                    self.safeOnStatusChange(isPlaying: true, status: String(localized: "status_playing"))
                    self.stopBufferingTimer()
                }
            }
        }
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
        
        // Remove existing observers first - FIXED: Add the required 'for' parameter
        removeObservers(for: playerItem)
        
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
    
    // FIXED: Update the stop() method to include connection cleanup
    func stop(completion: (() -> Void)? = nil) {
        #if DEBUG
        print("🛑 FORCE STOPPING ALL PLAYBACK - isSwitchingStream: \(isSwitchingStream)")
        #endif
        
        // Clear all active SSL timers
        clearAllSSLProtectionTimers()
        
        // CRITICAL: Cancel any pending audio operations
        pendingPlaybackWorkItem?.cancel()
        pendingPlaybackWorkItem = nil
        
        validationTimer?.invalidate()
        validationTimer = nil
        
        // Continue with existing stop logic
        performActualStop(completion: completion)
    }

    // FIXED: Update performActualStop to remove connectionStartTime references
    private func performActualStop(completion: (() -> Void)? = nil) {
        clearSSLProtectionTimer()
        isSSLHandshakeComplete = true
        hasStartedPlaying = false
        validationTimer?.invalidate()
        validationTimer = nil
        
        // If we're deallocating, perform cleanup synchronously
        if isDeallocating {
            stopSynchronously()
            completion?()
            return
        }
        
        audioQueue.async { [weak self] in
            guard let self = self, !self.isDeallocating else {
                DispatchQueue.main.async { completion?() }
                return
            }
            
            #if DEBUG
            print("🛑 Stopping playback")
            #endif
            
            guard self.player != nil || self.playerItem != nil else {
                DispatchQueue.main.async {
                    self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_stopped"))
                    completion?()
                }
                #if DEBUG
                print("🛑 Playback already stopped, skipping cleanup")
                #endif
                return
            }
            
            // ONLY pause/rate operations use executeAudioOperation
            self.executeAudioOperation({
                self.player?.pause()
                self.player?.rate = 0.0
                return ()
            }, completion: { _ in })
            
            // Cleanup continues immediately, not waiting for audio operation
            self.activeResourceLoaders.forEach { _, delegate in
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
            
            self.removeObserversImplementation()
            self.playerItem = nil
            self.removedObservers.removeAll()
            
            DispatchQueue.main.async {
                self.safeOnStatusChange(isPlaying: false, status: String(localized: "status_stopped"))
                completion?()
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
        activeResourceLoaders.forEach { _, delegate in
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
        removedObservers.removeAll()
        
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
        
        activeResourceLoaders.forEach { _, delegate in
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
        removedObservers.removeAll()
        stopBufferingTimer()
    }
    
    private func removeObserversSynchronously() {
        // Remove observers without async dispatch
        if let statusObserver = self.statusObserver {
            statusObserver.invalidate()
            self.statusObserver = nil
        }
        
        if let timeObserver = self.timeObserver, let player = self.timeObserverPlayer {
            player.removeTimeObserver(timeObserver)
        }
        self.timeObserver = nil
        self.timeObserverPlayer = nil
        
        if isObservingBuffer, let playerItem = self.playerItem {
            let playerItemKey = ObjectIdentifier(playerItem)
            if !removedObservers.contains(playerItemKey) {
                let keyPaths = ["playbackBufferEmpty", "playbackLikelyToKeepUp", "playbackBufferFull"]
                if let keyPathsSet = registeredKeyPaths[playerItemKey] {
                    for keyPath in keyPaths where keyPathsSet.contains(keyPath) {
                        playerItem.removeObserver(self, forKeyPath: keyPath)
                    }
                }
                registeredKeyPaths.removeValue(forKey: playerItemKey)
                removedObservers.insert(playerItemKey)
            }
        }
        isObservingBuffer = false
        registeredKeyPaths.removeAll()
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
                onStatusChange?(false, String(localized: "status_security_failed"))
            case .cannotFindHost, .fileDoesNotExist, .badServerResponse:
                #if DEBUG
                print("🔒 [Loading Error] Permanent network/server error detected")
                #endif
                onStatusChange?(false, String(localized: "status_stream_unavailable"))
            default:
                #if DEBUG
                print("🔒 [Loading Error] Transient error detected")
                #endif
                onStatusChange?(false, String(localized: "status_buffering"))
            }
        } else {
            #if DEBUG
            print("🔒 [Loading Error] Non-URLError detected")
            #endif
            onStatusChange?(false, String(localized: "status_buffering"))
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
    
    static var servers = [
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.delegate != nil else { return }
            self.safeOnStatusChange(isPlaying: false, status: String(localized: "alert_retry"))
        }
    }
}

// MARK: - Enhanced Resource Loader with Transition Support
extension DirectStreamingPlayer: AVAssetResourceLoaderDelegate {
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
        
        // Set standard streaming headers
        modifiedRequest.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        modifiedRequest.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        modifiedRequest.timeoutInterval = 60.0
        
        #if DEBUG
        print("📡 [Resource Loader] Request headers: \(modifiedRequest.allHTTPHeaderFields ?? [:])")
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
        
        // FIXED: Create URLSession with proper QoS for SSL operations
        let operationQueue = OperationQueue()
        operationQueue.qualityOfService = .userInitiated
        operationQueue.maxConcurrentOperationCount = 1
        
        #if DEBUG
        print("🔒 [Resource Loader] Creating URLSession with SSL-forcing config")
        #endif
        
        streamingDelegate.session = URLSession(configuration: config, delegate: streamingDelegate, delegateQueue: operationQueue)
        streamingDelegate.dataTask = streamingDelegate.session?.dataTask(with: modifiedRequest)
        
        streamingDelegate.onError = { [weak self] error in
            guard let self = self else { return }
            #if DEBUG
            print("❌ [Resource Loader] Streaming error occurred")
            print("❌ [Resource Loader] Error: \(error.localizedDescription)")
            #endif
            DispatchQueue.main.async {
                self.activeResourceLoaders.removeValue(forKey: loadingRequest)
                self.handleLoadingError(error)
            }
        }
        
        activeResourceLoaders[loadingRequest] = streamingDelegate
        
        #if DEBUG
        print("🔒 [Resource Loader] Starting data task for SSL validation...")
        #endif
        streamingDelegate.dataTask?.resume()
        
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
                 URLError.Code.cannotConnectToHost.rawValue,
                 URLError.Code.badServerResponse.rawValue:
                return .permanentFailure
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

// MARK: - Adaptive SSL Timeout Implementation
extension DirectStreamingPlayer {
    
    /// Calculates adaptive SSL timeout based on network conditions and server location
    private func getSSLTimeout() -> TimeInterval {
        // Base timeout - conservative starting point
        var timeout: TimeInterval = 8.0
        
        // Add extra time for cellular connections
        if isOnCellular() {
            timeout += 4.0
            #if DEBUG
            print("🔒 [SSL Timeout] Added 2s for cellular connection")
            #endif
        }
        
        // Add extra time for cross-continental connections
        if selectedServer.name == "EU" && !isInEurope() {
            timeout += 1.5
            #if DEBUG
            print("🔒 [SSL Timeout] Added 1.5s for EU server from non-Europe location")
            #endif
        } else if selectedServer.name == "US" && !isInNorthAmerica() {
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
        let finalTimeout = min(timeout, 15.0)
        
        #if DEBUG
        print("🔒 [SSL Timeout] Calculated timeout: \(finalTimeout)s (base: 4.0s)")
        #endif
        
        return finalTimeout
    }
    
    /// Detects if the device is on a cellular connection
    private func isOnCellular() -> Bool {
        let networkMonitor = NWPathMonitor()
        var isCellular = false
        
        let semaphore = DispatchSemaphore(value: 0)
        networkMonitor.pathUpdateHandler = { path in
            isCellular = path.usesInterfaceType(.cellular)
            semaphore.signal()
        }
        
        // FIXED: Use userInitiated QoS instead of utility
        let queue = DispatchQueue(label: "cellularCheck", qos: .userInitiated)
        networkMonitor.start(queue: queue)
        
        // Wait briefly for result
        _ = semaphore.wait(timeout: .now() + 0.1)
        networkMonitor.cancel()
        
        return isCellular
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
    
    /// Sets up SSL protection timer for a specific connection and returns connection ID
    private func setupSSLProtectionTimer(for connectionStartTime: Date) -> UUID {
        let connectionId = UUID()
        let adaptiveTimeout = getSSLTimeout()
        
        #if DEBUG
        print("🔒 [SSL Protection] Starting \(adaptiveTimeout)s adaptive protection timer for connection \(connectionId)")
        #endif
        
        let timer = Timer.scheduledTimer(withTimeInterval: adaptiveTimeout, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            
            let connectionAge = Date().timeIntervalSince(connectionStartTime)
            
            #if DEBUG
            print("🔒 [SSL Protection] Adaptive timer expired after \(connectionAge)s for connection \(connectionId)")
            #endif
            
            // Mark SSL handshake as complete after timeout for this specific connection
            self.connectionQueue.async {
                if var connectionInfo = self.activeConnections[connectionId] {
                    connectionInfo.isHandshakeComplete = true
                    self.activeConnections[connectionId] = connectionInfo
                }
            }
            
            // If still not ready after adaptive timeout, allow normal error handling
            if self.playerItem?.status == .unknown {
                #if DEBUG
                print("🔒 [SSL Protection] Still connecting after \(connectionAge)s - allowing normal error handling")
                #endif
            }
        }
        
        // Store connection info
        let connectionInfo = ConnectionInfo(
            id: connectionId,
            startTime: connectionStartTime,
            timer: timer,
            isHandshakeComplete: false
        )
        
        connectionQueue.async {
            self.activeConnections[connectionId] = connectionInfo
        }
        
        return connectionId
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
    
    /// Clears SSL protection timer for a specific connection
    private func clearSSLProtectionTimer(for connectionId: UUID) {
        connectionQueue.async {
            if let connectionInfo = self.activeConnections.removeValue(forKey: connectionId) {
                connectionInfo.timer.invalidate()
                
                #if DEBUG
                print("🔒 [SSL Protection] Cleared timer for connection \(connectionId)")
                #endif
            }
        }
        
        // Also clear the legacy timer if it exists
        sslConnectionTimeout?.invalidate()
        sslConnectionTimeout = nil
    }
    
    /// Clears all active SSL protection timers
    private func clearAllSSLProtectionTimers() {
        connectionQueue.async {
            for (connectionId, connectionInfo) in self.activeConnections {
                connectionInfo.timer.invalidate()
                
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
}
