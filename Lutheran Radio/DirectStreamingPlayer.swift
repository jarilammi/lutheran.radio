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
///   - Requires the app security model (`landvetter`) to be in the authorized list.
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
    private let appSecurityModel = "landvetter"
    private var isValidating = false
    #if DEBUG
    /// The last time security validation was performed (exposed for debugging).
    var lastValidationTime: Date?
    #else
    private var lastValidationTime: Date?
    #endif
    private let validationCacheDuration: TimeInterval = 600 // 10 minutes
    
    /// Represents the state of security model validation.
    enum ValidationState {
        case pending
        case success
        case failedTransient
        case failedPermanent
    }
    var validationState: ValidationState = .pending
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
                onMetadataChange?(selectedStream.title)
            }
        }
    }
    #else
    private(set) var selectedStream: Stream {
        didSet {
            if delegate != nil {
                onMetadataChange?(selectedStream.title)
            }
        }
    }
    #endif
    
    #if DEBUG
    var player: AVPlayer?
    var playerItem: AVPlayerItem?
    var metadataOutput: AVPlayerItemMetadataOutput?
    let playbackQueue = DispatchQueue(label: "radio.lutheran.playback", qos: .userInitiated)
    #else
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var metadataOutput: AVPlayerItemMetadataOutput?
    private let playbackQueue = DispatchQueue(label: "radio.lutheran.playback", qos: .userInitiated)
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
        queryTXTRecord(domain: domain) { result in
            #if DEBUG
            switch result {
            case .success(let models):
                print("✅ [Fetch Security Models] Successfully fetched models: \(models)")
            case .failure(let error):
                print("❌ [Fetch Security Models] Failed to fetch models: \(error.localizedDescription)")
            }
            #endif
            DispatchQueue.main.async {
                completion(result)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
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
                    self.onStatusChange?(false, String(localized: "status_connecting"))
                    completion(true)
                }
                return
            case .failedPermanent:
                #if DEBUG
                print("🔒 [Validate Async] Using cached validation: FailedPermanent, time since last: \(Date().timeIntervalSince(lastValidation))s")
                #endif
                hasPermanentError = true
                DispatchQueue.main.async {
                    self.onStatusChange?(false, String(localized: "status_security_failed"))
                    completion(false)
                }
                return
            case .failedTransient, .pending:
                #if DEBUG
                print("🔒 [Validate Async] Cache stale or transient/pending state, proceeding with validation")
                #endif
            }
        }

        performConnectivityCheck { [weak self] isConnected in
            guard let self = self else {
                completion(false)
                return
            }

            if !isConnected {
                #if DEBUG
                print("🔒 [Validate Async] No internet, transient failure")
                #endif
                self.validationState = .failedTransient
                self.hasInternetConnection = false
                DispatchQueue.main.async {
                    self.onStatusChange?(false, String(localized: "status_no_internet"))
                    completion(false)
                }
                return
            }

            self.isValidating = true
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
                    self.onStatusChange?(false, String(localized: "status_no_internet"))
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
                            self.onStatusChange?(false, String(localized: "status_security_failed"))
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
                                self.onStatusChange?(false, String(localized: "status_security_failed"))
                                completion(false)
                            }
                        } else {
                            self.hasPermanentError = false
                            DispatchQueue.main.async {
                                self.onStatusChange?(false, String(localized: "status_connecting"))
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
                        self.onStatusChange?(false, String(localized: "status_no_internet"))
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
                    self.onStatusChange?(false, String(localized: "status_connecting"))
                }
            }
        }
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
                                    self.onStatusChange?(false, String(localized: self.validationState == .failedPermanent ? "status_security_failed" : "status_no_internet"))
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
                    self.onStatusChange?(false, String(localized: "status_no_internet"))
                }
            }
        }
        networkMonitor?.start(queue: DispatchQueue(label: "radio.lutheran.networkmonitor"))
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
                                    self.onStatusChange?(false, String(localized: self.validationState == .failedPermanent ? "status_security_failed" : "status_no_internet"))
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
                    self.onStatusChange?(false, String(localized: "status_no_internet"))
                }
            }
        }
        networkMonitor?.start(queue: DispatchQueue(label: "radio.lutheran.networkmonitor"))
    }
    #endif
    
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
                    self.onStatusChange?(false, String(localized: "status_connecting"))
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
    
    // Helper to construct stream URL with selected baseHostname
    private func getStreamURL(for stream: Stream, with server: Server) -> URL? {
        let languagePrefix = stream.url.host?.components(separatedBy: ".")[0] ?? ""
        let newHostname = "\(languagePrefix)-\(server.subdomain).\(server.baseHostname)"
        var components = URLComponents(url: stream.url, resolvingAgainstBaseURL: false)
        components?.host = newHostname
        return components?.url
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
                        self.onStatusChange?(false, status)
                        completion(false)
                    }
                }
            }
            return
        }
        
        guard validationState == .success else {
            let status = validationState == .failedPermanent ? String(localized: "status_security_failed") : String(localized: "status_no_internet")
            DispatchQueue.main.async {
                self.onStatusChange?(false, status)
                completion(false)
            }
            return
        }
        
        selectOptimalServer { [weak self] server in
            guard let self = self else { completion(false); return }
            self.playWithServer(server, fallbackServers: Self.servers.filter { $0.name != server.name }, completion: completion)
        }
    }
    
    private func playWithServer(_ server: Server, fallbackServers: [Server], completion: @escaping (Bool) -> Void) {
        self.lastServerSelectionTime = Date()
        #if DEBUG
        print("📡 Attempting playback with server: \(server.name)")
        #endif
        
        guard let streamURL = self.getStreamURL(for: self.selectedStream, with: server) else {
            tryNextServer(fallbackServers: fallbackServers, completion: completion)
            return
        }
        
        var urlComponents = URLComponents(url: streamURL, resolvingAgainstBaseURL: false)
        urlComponents?.queryItems = [URLQueryItem(name: "security_model", value: self.appSecurityModel)]
        guard let finalURL = urlComponents?.url else {
            tryNextServer(fallbackServers: fallbackServers, completion: completion)
            return
        }
        
        #if DEBUG
        print("📡 Playing stream with URL: \(finalURL.absoluteString)")
        #endif
        
        self.startPlaybackWithFallback(with: finalURL, server: server, fallbackServers: fallbackServers, completion: completion)
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
            self.onStatusChange?(false, String(localized: "status_stream_unavailable"))
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
        guard !isSwitchingStream else {
            #if DEBUG
            print("📡 Stream switch skipped: already switching")
            #endif
            return
        }
        isSwitchingStream = true
        
        stop { [weak self] in
            guard let self = self else {
                self?.isSwitchingStream = false
                return
            }
            
            self.selectedStream = stream
            #if DEBUG
            print("📡 Stream set to: \(stream.language), URL: \(stream.url)")
            #endif
            
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
                            self.onStatusChange?(false, NSLocalizedString(status, comment: ""))
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
                    self.onStatusChange?(false, NSLocalizedString(status, comment: ""))
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
                        self.onStatusChange?(true, String(localized: "status_playing"))
                    }
                } else {
                    #if DEBUG
                    print("❌ Stream switch failed for: \(self.selectedStream.language)")
                    #endif
                    if self.delegate != nil {
                        self.onStatusChange?(false, String(localized: "status_stream_unavailable"))
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
                self.onStatusChange?(true, String(localized: "status_playing"))
            }
        } else {
            #if DEBUG
            print("❌ Stream switch failed for: \(self.selectedStream.language)")
            #endif
            if self.delegate != nil {
                self.onStatusChange?(false, String(localized: "status_stream_unavailable"))
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
            self.onStatusChange?(false, String(localized: "status_stopped"))
        }
    }

    private func stopBufferingTimer() {
        bufferingTimer?.invalidate()
        bufferingTimer = nil
    }
    
    private func startPlaybackWithFallback(with streamURL: URL, server: Server, fallbackServers: [Server], completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                completion(false)
                return
            }
            
            self.stop()
            
            let asset = AVURLAsset(url: streamURL)
            self.playerItem = AVPlayerItem(asset: asset)
            
            if self.player == nil {
                self.player = AVPlayer(playerItem: self.playerItem)
                #if DEBUG
                print("🎵 Created new AVPlayer")
                #endif
            } else {
                self.player?.replaceCurrentItem(with: self.playerItem)
                #if DEBUG
                print("🎵 Reused existing AVPlayer")
                #endif
            }
            
            self.addObservers()
            
            var tempStatusObserver: NSKeyValueObservation?
            tempStatusObserver = self.playerItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard let self = self else {
                    completion(false)
                    return
                }
                switch item.status {
                case .readyToPlay:
                    self.serverFailureCount[server.name] = 0
                    self.lastFailedServerName = nil
                    self.metadataOutput = AVPlayerItemMetadataOutput(identifiers: nil)
                    self.metadataOutput?.setDelegate(self, queue: .main)
                    if let metadataOutput = self.metadataOutput {
                        self.playerItem?.add(metadataOutput)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.player?.play()
                        self.onStatusChange?(true, String(localized: "status_playing"))
                        completion(true)
                    }
                case .failed:
                    #if DEBUG
                    print("❌ PlayerItem failed with server \(server.name): \(item.error?.localizedDescription ?? "Unknown error")")
                    #endif
                    self.lastError = item.error
                    let errorType = StreamErrorType.from(error: item.error)
                    
                    // Try fallback server instead of retry with same server
                    if !fallbackServers.isEmpty {
                        #if DEBUG
                        print("📡 Trying fallback server...")
                        #endif
                        self.tryNextServer(fallbackServers: fallbackServers, completion: completion)
                    } else {
                        self.hasPermanentError = errorType.isPermanent
                        DispatchQueue.main.async {
                            self.onStatusChange?(false, String(localized: "status_stream_unavailable"))
                            self.stop()
                            completion(false)
                        }
                    }
                case .unknown:
                    #if DEBUG
                    print("⏳ PlayerItem status unknown, waiting...")
                    #endif
                @unknown default:
                    break
                }
                tempStatusObserver?.invalidate()
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 20.0) { [weak self] in
                guard let self = self, self.playerItem?.status != .readyToPlay else { return }
                #if DEBUG
                print("❌ Playback timeout with server \(server.name), trying fallback")
                #endif
                if !fallbackServers.isEmpty {
                    self.tryNextServer(fallbackServers: fallbackServers, completion: completion)
                } else {
                    self.onStatusChange?(false, String(localized: "status_stream_unavailable"))
                    self.stop()
                    completion(false)
                }
            }
        }
    }
    
    func getCurrentMetadataForLiveActivity() -> String? {
        return currentMetadata
    }
    
    func setVolume(_ volume: Float) {
        player?.volume = volume
    }
    
    private func addObservers() {
        playbackQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Remove existing observers for the current playerItem
            if let currentPlayerItem = self.playerItem {
                self.removeObservers(for: currentPlayerItem)
            }
            
            guard let playerItem = self.playerItem else { return }
            
            let playerItemKey = ObjectIdentifier(playerItem)
            var keyPathsSet = self.registeredKeyPaths[playerItemKey] ?? Set<String>()
            
            // Add status observer
            self.statusObserver = playerItem.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    #if DEBUG
                    print("🎵 Player item status: \(item.status.rawValue)")
                    #endif
                    guard self.delegate != nil else { return }
                    switch item.status {
                    case .readyToPlay:
                        self.onStatusChange?(true, String(localized: "status_playing"))
                    case .failed:
                        self.lastError = item.error
                        let errorType = StreamErrorType.from(error: item.error)
                        self.hasPermanentError = errorType.isPermanent
                        self.onStatusChange?(false, errorType.statusString)
                        self.stop()
                    case .unknown:
                        self.onStatusChange?(false, String(localized: "status_buffering"))
                    @unknown default:
                        break
                    }
                }
            }
            #if DEBUG
            print("🧹 Added status observer for playerItem \(playerItemKey)")
            #endif
            
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
            #if DEBUG
            print("🧹 Added buffer observers for playbackBufferEmpty, playbackLikelyToKeepUp, playbackBufferFull")
            #endif
            
            let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            if let player = self.player, self.timeObserver == nil { // Check to avoid duplicate observers
                self.timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
                    guard let self = self, self.delegate != nil else { return }
                    if self.player?.rate ?? 0 > 0 {
                        self.onStatusChange?(true, String(localized: "status_playing"))
                    }
                }
                self.timeObserverPlayer = player // Track the player that added the observer
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
            
            if keyPath == "playbackBufferEmpty" {
                if playerItem.isPlaybackBufferEmpty {
                    self.onStatusChange?(false, String(localized: "status_buffering"))
                    self.startBufferingTimer()
                }
            } else if keyPath == "playbackLikelyToKeepUp" {
                if playerItem.isPlaybackLikelyToKeepUp && playerItem.status == .readyToPlay {
                    self.player?.play()
                    self.onStatusChange?(true, String(localized: "status_playing"))
                    self.stopBufferingTimer()
                }
            } else if keyPath == "playbackBufferFull" {
                if playerItem.isPlaybackBufferFull {
                    self.player?.play()
                    self.onStatusChange?(true, String(localized: "status_playing"))
                    self.stopBufferingTimer()
                }
            }
        }
    }
    
    #if DEBUG
    func removeObservers() {
        removeObserversImplementation()
    }
    #else
    private func removeObservers() {
        removeObserversImplementation()
    }
    #endif
    
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
    
    func stop(completion: (() -> Void)? = nil) {
        // If we're deallocating, perform cleanup synchronously
        if isDeallocating {
            stopSynchronously()
            completion?()
            return
        }
        
        playbackQueue.async { [weak self] in
            guard let self = self, !self.isDeallocating else {
                DispatchQueue.main.async { completion?() }
                return
            }
            #if DEBUG
            print("🛑 Stopping playback")
            #endif
            
            // Only proceed if there's an active player or playerItem
            guard self.player != nil || self.playerItem != nil else {
                DispatchQueue.main.async {
                    self.onStatusChange?(false, String(localized: "status_stopped"))
                    completion?()
                }
                #if DEBUG
                print("🛑 Playback already stopped, skipping cleanup")
                #endif
                return
            }
            
            // Pause and reset player
            self.player?.pause()
            self.player?.rate = 0.0
            
            // Cancel active resource loader sessions
            self.activeResourceLoaders.forEach { _, delegate in
                delegate.cancel()
            }
            self.activeResourceLoaders.removeAll()
            
            // Remove metadata output
            if let metadataOutput = self.metadataOutput, let playerItem = self.playerItem {
                if playerItem.outputs.contains(metadataOutput) {
                    playerItem.remove(metadataOutput)
                    #if DEBUG
                    print("🧹 Removed metadata output from playerItem in stop")
                    #endif
                }
            }
            self.metadataOutput = nil
            
            // Remove observers
            self.removeObserversImplementation()
            
            // Clear playerItem but keep player
            self.playerItem = nil
            self.removedObservers.removeAll()
            
            DispatchQueue.main.async {
                self.onStatusChange?(false, String(localized: "status_stopped"))
                completion?()
            }
            
            self.stopBufferingTimer()
            
            #if DEBUG
            print("🛑 Playback stopped, playerItem and resource loaders cleared")
            #endif
        }
    }
    
    private func stopSynchronously() {
        // Perform all cleanup synchronously without weak references
        player?.pause()
        player?.rate = 0.0
        
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
        stopSynchronously()
        clearCallbacks()
        networkMonitor?.cancel()
        networkMonitor = nil
        metadataOutput = nil
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
        
        onMetadataChange?(streamTitle)
    }
}

extension DirectStreamingPlayer {
    func handleNetworkInterruption() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.delegate != nil else { return }
            self.onStatusChange?(false, String(localized: "alert_retry"))
        }
    }
}

// MARK: - Resource Loader
extension DirectStreamingPlayer: AVAssetResourceLoaderDelegate {
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard var url = loadingRequest.request.url else {
            loadingRequest.finishLoading(with: NSError(domain: "radio.lutheran", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return false
        }
        
        // Convert custom scheme back to HTTPS
        if url.scheme == "lutheranradio" {
            let httpsURLString = url.absoluteString.replacingOccurrences(of: "lutheranradio://", with: "https://")
            guard let httpsURL = URL(string: httpsURLString) else {
                loadingRequest.finishLoading(with: NSError(domain: "radio.lutheran", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTPS URL conversion"]))
                return false
            }
            url = httpsURL
            #if DEBUG
            print("📡 [Resource Loader] Converted custom scheme to HTTPS: \(url)")
            #endif
        }
        
        // Store the original hostname for SSL validation
        let originalHostname = url.host
        
        // Create request with the modified URL (with IP)
        var modifiedRequest = URLRequest(url: url)
        
        // Set the Host header to the original hostname for SSL
        if let originalHost = originalHostname {
            modifiedRequest.setValue(originalHost, forHTTPHeaderField: "Host")
            #if DEBUG
            print("📡 [Resource Loader] Set Host header: \(originalHost)")
            #endif
        }
        
        // Set headers
        modifiedRequest.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        modifiedRequest.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        modifiedRequest.timeoutInterval = 30.0
        
        // Create streaming delegate
        let streamingDelegate = StreamingSessionDelegate(loadingRequest: loadingRequest)
        
        // Store the original hostname for SSL validation
        streamingDelegate.originalHostname = originalHostname
        
        #if DEBUG
        print("📡 StreamingSessionDelegate created with originalHostname: \(originalHostname ?? "nil")")
        #endif
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 30.0
        
        streamingDelegate.session = URLSession(configuration: config, delegate: streamingDelegate, delegateQueue: .main)
        streamingDelegate.dataTask = streamingDelegate.session?.dataTask(with: modifiedRequest)
        
        streamingDelegate.onError = { [weak self] error in
            guard let self = self else { return }
            #if DEBUG
            print("❌ Streaming error: \(error)")
            #endif
            DispatchQueue.main.async {
                self.activeResourceLoaders.removeValue(forKey: loadingRequest)
                self.handleLoadingError(error)
            }
        }
        
        activeResourceLoaders[loadingRequest] = streamingDelegate
        streamingDelegate.dataTask?.resume()
        
        #if DEBUG
        print("📡 Resource loader started for: \(modifiedRequest.url?.absoluteString ?? "nil")")
        print("📡 Request headers: \(modifiedRequest.allHTTPHeaderFields ?? [:])")
        #endif
        
        return true
    }
    
    private func handleLoadingError(_ error: Error) {
        let errorType = StreamErrorType.from(error: error)
        hasPermanentError = errorType.isPermanent
        if let urlError = error as? URLError {
            switch urlError.code {
            case .serverCertificateUntrusted, .secureConnectionFailed:
                onStatusChange?(false, String(localized: "status_security_failed"))
            case .cannotFindHost, .fileDoesNotExist, .badServerResponse:
                onStatusChange?(false, String(localized: "status_stream_unavailable"))
            default:
                onStatusChange?(false, String(localized: "status_buffering"))
            }
        } else {
            onStatusChange?(false, String(localized: "status_buffering"))
        }
        stop()
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        #if DEBUG
        print("📡 Resource loading cancelled")
        #endif
        activeResourceLoaders.removeValue(forKey: loadingRequest)
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
