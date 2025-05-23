//
//  DirectStreamingPlayer.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 25.2.2025.
//

/// - Article: Direct Streaming Player Guide
///
/// Manages audio streaming, security validation, and network monitoring for the Lutheran Radio app.
import Foundation
import Security
import CommonCrypto
import AVFoundation
import dnssd
import Network

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
    private let appSecurityModel = "mariehamn"
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
               url: URL(string: "https://liveenglish.lutheran.radio:8443/lutheranradio.mp3")!,
               language: NSLocalizedString("language_english", comment: "English language option"),
               languageCode: "en",
               flag: "🇺🇸"),
        Stream(title: NSLocalizedString("lutheran_radio_title", comment: "Title for Lutheran Radio") + " - " +
               NSLocalizedString("language_german", comment: "German language option"),
               url: URL(string: "https://livedeutsch.lutheran.radio:8443/lutheranradio.mp3")!,
               language: NSLocalizedString("language_german", comment: "German language option"),
               languageCode: "de",
               flag: "🇩🇪"),
        Stream(title: NSLocalizedString("lutheran_radio_title", comment: "Title for Lutheran Radio") + " - " +
               NSLocalizedString("language_finnish", comment: "Finnish language option"),
               url: URL(string: "https://livefinnish.lutheran.radio:8443/lutheranradio.mp3")!,
               language: NSLocalizedString("language_finnish", comment: "Finnish language option"),
               languageCode: "fi",
               flag: "🇫🇮"),
        Stream(title: NSLocalizedString("lutheran_radio_title", comment: "Title for Lutheran Radio") + " - " +
               NSLocalizedString("language_swedish", comment: "Swedish language option"),
               url: URL(string: "https://liveswedish.lutheran.radio:8443/lutheranradio.mp3")!,
               language: NSLocalizedString("language_swedish", comment: "Swedish language option"),
               languageCode: "sv",
               flag: "🇸🇪"),
        Stream(title: NSLocalizedString("lutheran_radio_title", comment: "Title for Lutheran Radio") + " - " +
               NSLocalizedString("language_estonian", comment: "Estonian language option"),
               url: URL(string: "https://liveestonian.lutheran.radio:8443/lutheranradio.mp3")!,
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
    private var hostnameToIP: [String: String] = [:]
    
    #if DEBUG
    var retryWorkItem: DispatchWorkItem? // Added to resolve undefined property
    #else
    private var retryWorkItem: DispatchWorkItem? // Added to resolve undefined property
    #endif
    
    func selectOptimalServer(completion: @escaping (Server) -> Void) {
        guard lastServerSelectionTime == nil || Date().timeIntervalSince(lastServerSelectionTime!) > 10.0 else {
            #if DEBUG
            print("📡 selectOptimalServer: Throttling server selection, using cached server: \(selectedServer.name)")
            #endif
            completion(selectedServer)
            return
        }
        serverSelectionWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else {
                completion(Self.servers[0])
                return
            }
            self.fetchServerIPsAndLatencies { results in
                let validResults = results.filter { $0.latency != .infinity && $0.server.ipAddress != nil }
                if let bestResult = validResults.min(by: { $0.latency < $1.latency }) {
                    self.selectedServer = bestResult.server
                    #if DEBUG
                    print("📡 [Server Selection] Selected \(bestResult.server.name) with latency \(bestResult.latency)s, IP=\(bestResult.server.ipAddress ?? "None")")
                    #endif
                } else {
                    self.selectedServer = Self.servers[0]
                    #if DEBUG
                    print("📡 [Server Selection] No valid ping results, falling back to \(self.selectedServer.name)")
                    #endif
                }
                
                if let ipAddress = self.selectedServer.ipAddress {
                    let hostnames = Self.availableStreams.map { $0.url.host ?? "" }.uniqued()
                    self.hostnameToIP = Dictionary(uniqueKeysWithValues: hostnames.map { ($0, ipAddress) })
                    #if DEBUG
                    print("📡 [Server Selection] Hostname to IP mapping: \(self.hostnameToIP)")
                    #endif
                } else {
                    self.hostnameToIP = [:]
                }
                
                completion(self.selectedServer)
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
                self.hostnameToIP = [:]
                self.lastServerSelectionTime = nil
                self.selectedServer = Self.servers[0] // Reset to default
                print("🌐 [Network] Cleared DNS overrides for fresh server selection")
                
                self.lastValidationTime = nil
                self.validationState = .pending
                print("🔒 [Network] Invalidated security model validation cache")
                self.selectOptimalServer { server in
                    print("🌐 [Network] New server selected: \(server.name), hostnameToIP: \(self.hostnameToIP)")
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
                // Clear DNS overrides to force new server selection
                self.hostnameToIP = [:]
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
    
    func play(completion: @escaping (Bool) -> Void) {
        // Audio session is already configured in setupAudioSession() and maintained active for background audio
        // Removed redundant reset to prevent audio system overload
        
        if validationState == .pending {
            #if DEBUG
            print("📡 Play: Validation pending, triggering validation")
            #endif
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
            #if DEBUG
            print("📡 Play aborted: Validation state=\(validationState)")
            #endif
            let status = validationState == .failedPermanent ? String(localized: "status_security_failed") : String(localized: "status_no_internet")
            DispatchQueue.main.async {
                self.onStatusChange?(false, status)
                completion(false)
            }
            return
        }
        
        var urlComponents = URLComponents(url: selectedStream.url, resolvingAgainstBaseURL: false)
        urlComponents?.queryItems = [URLQueryItem(name: "security_model", value: appSecurityModel)]
        guard let streamURL = urlComponents?.url else {
            #if DEBUG
            print("❌ Failed to construct stream URL with security model")
            #endif
            self.onStatusChange?(false, String(localized: "status_stream_unavailable"))
            completion(false)
            return
        }
        
        #if DEBUG
        print("📡 Playing stream with URL: \(streamURL.absoluteString)")
        #endif
        
        let now = Date()
        if let lastSelection = lastServerSelectionTime, now.timeIntervalSince(lastSelection) < serverSelectionCacheDuration, !hostnameToIP.isEmpty {
            #if DEBUG
            print("📡 Using cached server selection: \(selectedServer.name)")
            #endif
            startPlayback(with: streamURL, completion: completion)
        } else {
            selectOptimalServer { [weak self] server in
                guard let self = self else { completion(false); return }
                self.lastServerSelectionTime = Date()
                #if DEBUG
                print("📡 Selected server: \(server.name)")
                #endif
                self.startPlayback(with: streamURL, completion: completion)
            }
        }
    }
    
    func setStream(to stream: Stream) {
        guard !isSwitchingStream else {
            #if DEBUG
            print("📡 Stream switch skipped: already switching")
            #endif
            return
        }
        isSwitchingStream = true
        
        // Stop any ongoing playback and clear state
        stop { [weak self] in
            guard let self = self else {
                self?.isSwitchingStream = false
                return
            }
            
            // Update selectedStream immediately
            self.selectedStream = stream
            #if DEBUG
            print("📡 Stream set to: \(stream.language), URL: \(stream.url)")
            #endif
            
            // Reset validation state if needed
            if self.validationState == .pending {
                self.validateSecurityModelAsync { [weak self] isValid in
                    guard let self = self else {
                        self?.isSwitchingStream = false
                        return
                    }
                    defer { self.isSwitchingStream = false } // Ensure flag is reset
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
                defer { self.isSwitchingStream = false } // Ensure flag is reset
                self.playAfterStreamSwitch()
            } else {
                defer { self.isSwitchingStream = false } // Ensure flag is reset
                let status = self.validationState == .failedPermanent ? "status_security_failed" : "status_no_internet"
                DispatchQueue.main.async {
                    self.onStatusChange?(false, NSLocalizedString(status, comment: ""))
                }
            }
        }
    }

    // Helper method to handle playback after stream switch
    private func playAfterStreamSwitch() {
        let now = Date()
        if let lastSelection = self.lastServerSelectionTime, now.timeIntervalSince(lastSelection) < self.serverSelectionCacheDuration, !self.hostnameToIP.isEmpty {
            #if DEBUG
            print("📡 Using cached server selection for stream switch: \(self.selectedServer.name)")
            #endif
            self.play { [weak self] success in
                guard let self = self else { return }
                self.handleStreamSwitchCompletion(success)
            }
        } else {
            self.selectOptimalServer { [weak self] server in
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
                    self.handleStreamSwitchCompletion(success)
                }
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
    
    private func startPlayback(with streamURL: URL, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                completion(false)
                return
            }

            if !streamURL.absoluteString.contains(self.selectedStream.url.absoluteString) {
                #if DEBUG
                print("❌ URL mismatch: requested=\(streamURL), selectedStream=\(self.selectedStream.url)")
                #endif
                self.onStatusChange?(false, String(localized: "status_stream_unavailable"))
                completion(false)
                return
            }

            self.stop()

            // Use custom scheme to force resource loader when we have DNS overrides
            var assetURL = streamURL
            if !self.hostnameToIP.isEmpty, let host = streamURL.host, self.hostnameToIP[host] != nil {
                // Replace https with custom scheme to force resource loader
                let customURLString = streamURL.absoluteString.replacingOccurrences(of: "https://", with: "lutheranradio://")
                if let customURL = URL(string: customURLString) {
                    assetURL = customURL
                    #if DEBUG
                    print("📡 Using custom scheme to force resource loader: \(assetURL)")
                    #endif
                }
            }

            let asset = AVURLAsset(url: assetURL)
            asset.resourceLoader.setDelegate(self, queue: DispatchQueue.main)
            self.playerItem = AVPlayerItem(asset: asset)

            // Check for invalid playerItem status
            if self.playerItem?.status.rawValue ?? -1 < 0 {
                #if DEBUG
                print("❌ Invalid playerItem status on initialization, possible Core Audio component issue")
                #endif
                self.onStatusChange?(false, String(localized: "status_stream_unavailable"))
                completion(false)
                return
            }

            // Ensure metadataOutput is not attached to another playerItem
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

            #if DEBUG
            print("⏳ Initial playerItem status: \(self.playerItem?.status.rawValue ?? -1)")
            if let error = self.playerItem?.error {
                print("❌ Initial playerItem error: \(error.localizedDescription)")
            }
            #endif

            self.addObservers()

            var tempStatusObserver: NSKeyValueObservation?
            tempStatusObserver = self.playerItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard let self = self else {
                    completion(false)
                    return
                }
                switch item.status {
                case .readyToPlay:
                    #if DEBUG
                    print("✅ PlayerItem readyToPlay, starting playback for: \(self.selectedStream.language)")
                    #endif
                    // Initialize and add metadataOutput
                    self.metadataOutput = AVPlayerItemMetadataOutput(identifiers: nil)
                    self.metadataOutput?.setDelegate(self, queue: .main)
                    if let metadataOutput = self.metadataOutput {
                        self.playerItem?.add(metadataOutput)
                        #if DEBUG
                        print("🧹 Added metadata output in readyToPlay")
                        #endif
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.player?.play()
                        self.onStatusChange?(true, String(localized: "status_playing"))
                        completion(true)
                    }
                case .failed:
                    #if DEBUG
                    print("❌ PlayerItem failed: \(item.error?.localizedDescription ?? "Unknown error")")
                    if let error = item.error as NSError? {
                        print("❌ Error details: domain=\(error.domain), code=\(error.code), userInfo=\(error.userInfo)")
                    }
                    #endif
                    self.lastError = item.error
                    let errorType = StreamErrorType.from(error: item.error)
                    self.hasPermanentError = errorType.isPermanent
                    if errorType == .transientFailure {
                        #if DEBUG
                        print("🔄 Transient error detected, scheduling retry")
                        #endif
                        let workItem = DispatchWorkItem { [weak self] in
                            self?.startPlayback(with: streamURL, completion: completion)
                        }
                        self.retryWorkItem = workItem
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
                    } else {
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
                    #if DEBUG
                    print("⚠️ Unknown player item status")
                    #endif
                    break
                }
                tempStatusObserver?.invalidate()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 20.0) { [weak self, weak tempStatusObserver] in
                guard let self = self, tempStatusObserver != nil else { return }
                if self.playerItem?.status != .readyToPlay {
                    #if DEBUG
                    print("❌ Playback timeout, playerItem not ready")
                    if let error = self.playerItem?.error {
                        print("❌ PlayerItem error on timeout: \(error.localizedDescription)")
                    }
                    #endif
                    self.onStatusChange?(false, String(localized: "status_stream_unavailable"))
                    self.stop()
                    completion(false)
                }
            }
        }
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
        // Perform observer removal on the main thread to avoid race conditions
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                #if DEBUG
                print("🧹 removeObserversImplementation: self is nil, skipping")
                #endif
                return
            }

            // Invalidate status observer
            if let statusObserver = self.statusObserver {
                statusObserver.invalidate()
                self.statusObserver = nil
                #if DEBUG
                print("🧹 Removed status observer")
                #endif
            }

            // Remove time observer
            if let timeObserver = self.timeObserver, let player = self.timeObserverPlayer {
                player.removeTimeObserver(timeObserver)
                #if DEBUG
                print("🧹 Removed time observer")
                #endif
            }
            self.timeObserver = nil
            self.timeObserverPlayer = nil

            // Remove buffer observers
            if self.isObservingBuffer, let playerItem = self.playerItem {
                let playerItemKey = ObjectIdentifier(playerItem)
                if self.removedObservers.contains(playerItemKey) {
                    #if DEBUG
                    print("🧹 Skipping observer removal: already removed for playerItem \(playerItemKey)")
                    #endif
                    self.isObservingBuffer = false
                    return
                }
                
                let keyPaths = [
                    "playbackBufferEmpty",
                    "playbackLikelyToKeepUp",
                    "playbackBufferFull"
                ]
                
                if var keyPathsSet = self.registeredKeyPaths[playerItemKey] {
                    for keyPath in keyPaths where keyPathsSet.contains(keyPath) {
                        playerItem.removeObserver(self, forKeyPath: keyPath)
                        keyPathsSet.remove(keyPath)
                        #if DEBUG
                        print("🧹 Removed observer for \(keyPath)")
                        #endif
                    }
                    
                    self.registeredKeyPaths[playerItemKey] = keyPathsSet.isEmpty ? nil : keyPathsSet
                    self.isObservingBuffer = false
                    self.removedObservers.insert(playerItemKey)
                }
            }

            // Clear registered key paths
            self.registeredKeyPaths.removeAll()
        }
    }
    
    func stop(completion: (() -> Void)? = nil) {
        playbackQueue.async { [weak self] in
            guard let self = self else {
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
    
    func clearCallbacks() {
        onStatusChange = nil
        onMetadataChange = nil
        delegate = nil
    }
    
    deinit {
        stop()
        removeObserversImplementation()
        clearCallbacks()
        networkMonitor?.cancel()
        networkMonitor = nil
        metadataOutput = nil
        #if DEBUG
        print("🧹 Player deinit")
        #endif
    }
}

// MARK: - Server Configuration
extension DirectStreamingPlayer {
    struct Server {
        let name: String
        let pingURL: URL
        var ipAddress: String?
    }
    
    static var servers = [
        Server(
            name: "European",
            pingURL: URL(string: "https://european.lutheran.radio/ping")!,
            ipAddress: nil
        ),
        Server(
            name: "US",
            pingURL: URL(string: "https://livestream.lutheran.radio/ping")!,
            ipAddress: nil
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
        
        for (index, server) in Self.servers.enumerated() {
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
                var updatedServer = server
                
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let ipAddress = json["address"] as? String,
                   let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    updatedServer.ipAddress = ipAddress
                    Self.servers[index] = updatedServer
                    results.append(PingResult(server: updatedServer, latency: latency))
                    #if DEBUG
                    print("📡 [Ping] Success for \(server.name), IP=\(ipAddress), latency=\(latency)s")
                    #endif
                } else {
                    results.append(PingResult(server: server, latency: .infinity))
                    #if DEBUG
                    print("📡 [Ping] Failed for \(server.name): error=\(error?.localizedDescription ?? "None"), status=\((response as? HTTPURLResponse)?.statusCode ?? -1), latency=\(latency)s")
                    #endif
                }
                group.leave()
            }
            task.resume()
        }
        
        group.notify(queue: .main) {
            #if DEBUG
            print("📡 [Ping] All pings completed: \(results.map { "\($0.server.name): \($0.latency)s, IP=\($0.server.ipAddress ?? "None")" })")
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
        
        let songTitle = (item.identifier == AVMetadataIdentifier("icy/StreamTitle") ||
                       (item.key as? String) == "StreamTitle") ? value : nil
        
        onMetadataChange?(songTitle)
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
            #if DEBUG
            print("❌ Resource loader: Invalid URL")
            #endif
            loadingRequest.finishLoading(with: NSError(domain: "radio.lutheran", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return false
        }
        
        // Store the original hostname before any modifications
        var originalHostname: String? = nil
        
        // Convert custom scheme back to https
        if url.scheme == "lutheranradio" {
            let httpsString = url.absoluteString.replacingOccurrences(of: "lutheranradio://", with: "https://")
            guard let httpsURL = URL(string: httpsString) else {
                loadingRequest.finishLoading(with: NSError(domain: "radio.lutheran", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL conversion"]))
                return false
            }
            originalHostname = httpsURL.host  // Store original hostname
            url = httpsURL
            #if DEBUG
            print("📡 Converted custom scheme to HTTPS: \(url)")
            print("📡 Original hostname: \(originalHostname ?? "nil")")
            #endif
        } else {
            originalHostname = url.host
        }
        
        // Create the request with DNS override
        var modifiedRequest = URLRequest(url: url)
        
        // CRITICAL: Set all headers before DNS override
        modifiedRequest.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        modifiedRequest.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        modifiedRequest.timeoutInterval = 30.0
        
        // Apply DNS override if needed
        if let host = originalHostname, let ipAddress = hostnameToIP[host] {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.host = ipAddress
            if let ipURL = components?.url {
                modifiedRequest.url = ipURL
                // CRITICAL: Set the Host header to the original hostname
                modifiedRequest.setValue(host, forHTTPHeaderField: "Host")
                #if DEBUG
                print("📡 Applied DNS override: \(host) -> \(ipAddress)")
                print("📡 Host header set to: \(host)")
                print("📡 Final URL: \(ipURL)")
                #endif
            }
        } else if let host = originalHostname {
            // Even without DNS override, ensure Host header is set
            modifiedRequest.setValue(host, forHTTPHeaderField: "Host")
        }
        
        // Copy any additional headers from the original request
        if let headers = loadingRequest.request.allHTTPHeaderFields {
            for (key, value) in headers where !["Host", "Accept", "Icy-MetaData"].contains(key) {
                modifiedRequest.setValue(value, forHTTPHeaderField: key)
            }
        }
        
        // Create streaming delegate with the original hostname for SSL validation
        let streamingDelegate = StreamingSessionDelegate(loadingRequest: loadingRequest, hostnameToIP: hostnameToIP)
        
        // CRITICAL: Store the original hostname in the delegate for SSL validation
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
