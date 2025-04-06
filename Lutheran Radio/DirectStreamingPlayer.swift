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

class DirectStreamingPlayer: NSObject {
    // MARK: - Security Model
    private let appSecurityModel = "turku" // Security model in use
    private var isValidating = false
    private var isSecurityModelValid: Bool?
    
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
    
    // Current selected stream
    private var selectedStream: Stream {
        didSet {
            // Update metadata when stream changes
            if delegate != nil {
                onMetadataChange?(selectedStream.title)
            }
        }
    }
    
    // Player components
    var player: AVPlayer?
    var playerItem: AVPlayerItem?
    var hasPermanentError: Bool = false
    private var statusObserver: NSKeyValueObservation?
    private var timeObserver: Any?
    
    // Keep track of which observers are active
    private var isObservingBuffer = false
    
    // Status callbacks
    var onStatusChange: ((Bool, String) -> Void)?
    var onMetadataChange: ((String?) -> Void)?
    
    // Add a weak delegate to check before invoking callbacks
    private weak var delegate: AnyObject?
    
    func setDelegate(_ delegate: AnyObject?) {
        self.delegate = delegate
    }
    
    // MARK: - Security Model Validation
    
    private func getSystemDNSServers() -> [String] {
        var dnsServers: [String] = []
        
        // Allocate memory for a __res_9_state struct
        let statePtr = UnsafeMutablePointer<__res_9_state>.allocate(capacity: 1)
        
        // Initialize the struct with res_9_ninit
        res_9_ninit(statePtr)
        
        // Access the DNS servers from nsaddr_list (a tuple)
        let nscount = statePtr.pointee.nscount
        if nscount > 0 {
            let addr0 = statePtr.pointee.nsaddr_list.0
            let ip0 = String(cString: inet_ntoa(addr0.sin_addr))
            dnsServers.append(ip0)
        }
        if nscount > 1 {
            let addr1 = statePtr.pointee.nsaddr_list.1
            let ip1 = String(cString: inet_ntoa(addr1.sin_addr))
            dnsServers.append(ip1)
        }
        if nscount > 2 {
            let addr2 = statePtr.pointee.nsaddr_list.2
            let ip2 = String(cString: inet_ntoa(addr2.sin_addr))
            dnsServers.append(ip2)
        }
        
        // Clean up
        res_9_nclose(statePtr)
        statePtr.deallocate()
        
        return dnsServers
    }
    
    private func fetchValidSecurityModels(completion: @escaping (Result<Set<String>, Error>) -> Void) {
        let domain = "securitymodels.lutheran.radio"
        let dnsQueue = DispatchQueue(label: "radio.lutheran.dns", qos: .utility)
        dnsQueue.async {
            let statePtr = UnsafeMutablePointer<__res_9_state>.allocate(capacity: 1)
            defer {
                res_9_nclose(statePtr)
                statePtr.deallocate()
                #if DEBUG
                print("🔒 fetchValidSecurityModels: Resolver state cleaned up")
                #endif
            }
            
            let initResult = res_9_ninit(statePtr)
            if initResult != 0 {
                let error = NSError(domain: "radio.lutheran", code: Int(initResult), userInfo: [NSLocalizedDescriptionKey: "Failed to initialize resolver"])
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }
            
            var response = [UInt8](repeating: 0, count: 4096)
            let queryLength = res_9_nquery(statePtr, domain, 1, 16, &response, Int32(response.count))
            if queryLength < 0 {
                let error = NSError(domain: "radio.lutheran", code: Int(queryLength), userInfo: [NSLocalizedDescriptionKey: "DNS query failed"])
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }
            
            do {
                let models = try self.parseTXTRecord(from: Data(response[0..<Int(queryLength)]))
                DispatchQueue.main.async {
                    completion(.success(models))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    private func buildDNSQuery(for domain: String) -> Data {
        #if DEBUG
        print("🔒 buildDNSQuery: Constructing query for domain: \(domain)")
        #endif
        var query = Data()
        let transactionID = UInt16.random(in: 0...UInt16.max)
        query.append(contentsOf: [UInt8(transactionID >> 8), UInt8(transactionID & 0xFF)])
        query.append(contentsOf: [0x01, 0x00]) // Flags: Standard query
        query.append(contentsOf: [0x00, 0x01]) // Questions: 1
        query.append(contentsOf: [0x00, 0x00]) // Answer RRs: 0
        query.append(contentsOf: [0x00, 0x00]) // Authority RRs: 0
        query.append(contentsOf: [0x00, 0x00]) // Additional RRs: 0
        
        let parts = domain.split(separator: ".")
        for part in parts {
            let length = UInt8(part.count)
            query.append(length)
            query.append(part.data(using: .utf8)!)
            #if DEBUG
            print("🔒 buildDNSQuery: Added domain part: \(part), length: \(length)")
            #endif
        }
        query.append(UInt8(0))
        query.append(contentsOf: [0x00, 0x10]) // QTYPE: TXT (16)
        query.append(contentsOf: [0x00, 0x01]) // QCLASS: IN (1)
        
        #if DEBUG
        print("🔒 buildDNSQuery: Query constructed, total length: \(query.count) bytes")
        #endif
        return query
    }
    
    private func parseTXTRecord(from data: Data) throws -> Set<String> {
        #if DEBUG
        print("🔒 parseTXTRecord: Starting to parse DNS response, data length: \(data.count) bytes")
        #endif
        var models = Set<String>()
        var offset = 12 // Skip header
        
        while offset < data.count && data[offset] != 0 {
            offset += Int(data[offset]) + 1
        }
        offset += 5 // Skip null terminator + QTYPE + QCLASS
        #if DEBUG
        print("🔒 parseTXTRecord: Skipped question section, new offset: \(offset)")
        #endif
        
        guard offset < data.count else {
            throw NSError(domain: "radio.lutheran", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid DNS response"])
        }
        
        while offset < data.count {
            if data[offset] == 0 {
                offset += 1
                #if DEBUG
                print("🔒 parseTXTRecord: Encountered zero byte at offset \(offset), skipping")
                #endif
                continue
            }
            offset += 2 // Skip name pointer
            guard offset + 9 < data.count else { // Ensure enough bytes for type, class, TTL, rdLength
                #if DEBUG
                print("🔒 parseTXTRecord: Insufficient data at offset \(offset), stopping")
                #endif
                break
            }
            let type = (UInt16(data[offset]) << 8) + UInt16(data[offset + 1])
            offset += 8 // Skip type, class, TTL
            guard offset + 1 < data.count else {
                #if DEBUG
                print("🔒 parseTXTRecord: Cannot read rdLength at offset \(offset), stopping")
                #endif
                break
            }
            let rdLength = (UInt16(data[offset]) << 8) + UInt16(data[offset + 1])
            offset += 2
            #if DEBUG
            print("🔒 parseTXTRecord: Record type: \(type), rdLength: \(rdLength), offset: \(offset)")
            #endif
            
            if type == 16 { // TXT record
                guard offset + Int(rdLength) <= data.count else {
                    #if DEBUG
                    print("🔒 parseTXTRecord: rdLength \(rdLength) exceeds remaining data at offset \(offset), skipping")
                    #endif
                    break
                }
                let txtData = data.subdata(in: offset..<offset + Int(rdLength))
                if let txtString = String(data: txtData.dropFirst(), encoding: .utf8) {
                    let modelList = txtString.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
                    models.formUnion(modelList)
                    #if DEBUG
                    print("🔒 parseTXTRecord: Parsed TXT record: \(txtString), extracted models: \(modelList)")
                    #endif
                }
            }
            offset += Int(rdLength)
        }
        
        #if DEBUG
        print("🔒 parseTXTRecord: Parsing complete, models: \(models)")
        #endif
        return models
    }
    
    private func validateSecurityModel(completion: @escaping (Bool) -> Void) {
        guard !isValidating else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { completion(false); return }
                if let isValid = self.isSecurityModelValid {
                    #if DEBUG
                    print("🔒 Validation already completed, returning cached result: isValid=\(isValid)")
                    #endif
                    completion(isValid)
                } else {
                    self.validateSecurityModel(completion: completion)
                }
            }
            return
        }
        
        isValidating = true
        #if DEBUG
        print("🔒 Validating security model: \(appSecurityModel) - Starting validation process")
        #endif
        
        fetchValidSecurityModels { [weak self] result in
            guard let self = self else {
                DispatchQueue.main.async {
                    completion(false)
                }
                return
            }
            
            self.isValidating = false
            switch result {
            case .success(let validModels):
                let isValid = validModels.contains(self.appSecurityModel.lowercased())
                self.isSecurityModelValid = isValid
                #if DEBUG
                print("🔒 Security model validation completed: isValid=\(isValid), validModels=\(validModels)")
                #endif
                if !isValid {
                    self.hasPermanentError = true
                    DispatchQueue.main.async {
                        self.onStatusChange?(false, String(localized: "status_security_failed"))
                        completion(isValid)
                    }
                } else {
                    DispatchQueue.main.async {
                        completion(isValid)
                    }
                }
            case .failure(let error):
                // Fail open on error
                self.isSecurityModelValid = true
                #if DEBUG
                print("🔒 Security model validation failed with error: \(error.localizedDescription), failing open")
                #endif
                DispatchQueue.main.async {
                    completion(true)
                }
            }
        }
    }
    
    override init() {
        let currentLocale = Locale.current
        let languageCode = currentLocale.language.languageCode?.identifier
        if let stream = Self.availableStreams.first(where: { $0.languageCode == languageCode }) {
            selectedStream = stream
        } else {
            selectedStream = Self.availableStreams[0]
        }
        super.init()
        setupAudioSession()
        // Perform validation synchronously during init
        validateSecurityModel { [weak self] isValid in
            self?.isSecurityModelValid = isValid
            if !isValid {
                self?.stop()
                self?.hasPermanentError = true
            }
        }
    }
    
    func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            #if DEBUG
            print("🔊 Audio session successfully configured")
            #endif
        } catch {
            #if DEBUG
            print("🔊 Audio session setup failed: \(error.localizedDescription)")
            #endif
        }
    }
    
    func play(completion: @escaping (Bool) -> Void) {
        if hasPermanentError {
            completion(false)
            return
        }
        
        validateSecurityModel { [weak self] isValid in
            guard let self = self, isValid else {
                completion(false)
                return
            }
            
            self.stop()
            self.hasPermanentError = false
            let asset = AVURLAsset(url: self.selectedStream.url)
            asset.resourceLoader.setDelegate(self, queue: DispatchQueue(label: "radio.lutheran.resourceloader"))
            self.playerItem = AVPlayerItem(asset: asset)
            self.player = AVPlayer(playerItem: self.playerItem)
            self.addObservers()
            self.player?.play()
            
            var tempStatusObserver: NSKeyValueObservation?
            tempStatusObserver = self.playerItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard self != nil else {
                    tempStatusObserver?.invalidate()
                    completion(false)
                    return
                }
                if item.status == .readyToPlay {
                    completion(true)
                } else if item.status == .failed {
                    completion(false)
                }
                tempStatusObserver?.invalidate()
            }
        }
    }
    
    func setStream(to stream: Stream) {
        stop()
        selectedStream = stream
        play { [weak self] success in
            guard let self = self else { return }
            if success {
                #if DEBUG
                print("Stream switched successfully")
                #endif
                if self.delegate != nil {
                    self.onStatusChange?(true, String(localized: "status_playing"))
                }
            } else {
                #if DEBUG
                print("Failed to switch stream")
                #endif
                if self.delegate != nil {
                    self.onStatusChange?(false, String(localized: "status_stream_unavailable"))
                }
            }
        }
    }
    
    func setVolume(_ volume: Float) {
        player?.volume = volume
    }
    
    func addObservers() {
        removeObservers()
        
        statusObserver = playerItem?.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                #if DEBUG
                print("🎵 Player item status: \(item.status.rawValue)")
                #endif
                guard self.delegate != nil else {
                    #if DEBUG
                    print("🎵 Player item status: Delegate is nil, skipping callback")
                    #endif
                    return
                }
                switch item.status {
                case .readyToPlay:
                    self.onStatusChange?(true, String(localized: "status_playing"))
                case .failed:
                    self.lastError = item.error
                    if let error = item.error {
                        let nsError = error as NSError
                        #if DEBUG
                        print("🎵 Player item failed with error: \(error.localizedDescription), code: \(nsError.code), domain: \(nsError.domain)")
                        #endif
                    } else {
                        #if DEBUG
                        print("🎵 Player item failed with no error details")
                        #endif
                    }
                    let errorType = StreamErrorType.from(error: item.error)
                    self.hasPermanentError = errorType.isPermanent
                    self.onStatusChange?(false, errorType.statusString)
                    self.removeObservers()
                case .unknown:
                    self.onStatusChange?(false, String(localized: "status_buffering"))
                @unknown default:
                    break
                }
            }
        }
        
        if let playerItem = playerItem {
            playerItem.addObserver(self, forKeyPath: "playbackBufferEmpty", options: .new, context: nil)
            playerItem.addObserver(self, forKeyPath: "playbackLikelyToKeepUp", options: .new, context: nil)
            playerItem.addObserver(self, forKeyPath: "playbackBufferFull", options: .new, context: nil)
            isObservingBuffer = true
        }
        
        let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            guard let self = self, self.delegate != nil else {
                #if DEBUG
                print("🎵 timeObserver: Delegate is nil, skipping callback")
                #endif
                return
            }
            if self.player?.rate ?? 0 > 0 {
                self.onStatusChange?(true, String(localized: "status_playing"))
            }
        }
        
        let metadataOutput = AVPlayerItemMetadataOutput(identifiers: nil)
        metadataOutput.setDelegate(self, queue: .main)
        playerItem?.add(metadataOutput)
    }
    
    // Handle KVO notifications for buffering state
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard let keyPath = keyPath, let playerItem = object as? AVPlayerItem else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.delegate != nil else {
                #if DEBUG
                print("🎵 observeValue: Delegate is nil, skipping callback")
                #endif
                return
            }
            
            if keyPath == "playbackBufferEmpty" {
                if playerItem.isPlaybackBufferEmpty {
                    #if DEBUG
                    print("⏳ Playback buffer is empty - buffering...")
                    #endif
                    self.onStatusChange?(false, String(localized: "status_buffering"))
                }
            } else if keyPath == "playbackLikelyToKeepUp" {
                if playerItem.isPlaybackLikelyToKeepUp && playerItem.status == .readyToPlay {
                    #if DEBUG
                    print("✅ Playback is likely to keep up - ready to play")
                    #endif
                    self.player?.play()
                    self.onStatusChange?(true, String(localized: "status_playing"))
                }
            } else if keyPath == "playbackBufferFull" {
                if playerItem.isPlaybackBufferFull {
                    #if DEBUG
                    print("✅ Playback buffer is full")
                    #endif
                    self.player?.play()
                    self.onStatusChange?(true, String(localized: "status_playing"))
                }
            }
        }
    }
    
    private func removeObservers() {
        // Remove status observer
        statusObserver?.invalidate()
        statusObserver = nil
        
        // Remove time observer
        if let timeObserver = timeObserver, let player = player {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        
        // Only try to remove KVO observers if we added them
        if isObservingBuffer, let playerItem = playerItem {
            // Remove observers with safety checks
            playerItem.removeObserver(self, forKeyPath: "playbackBufferEmpty")
            playerItem.removeObserver(self, forKeyPath: "playbackLikelyToKeepUp")
            playerItem.removeObserver(self, forKeyPath: "playbackBufferFull")
            isObservingBuffer = false
            #if DEBUG
            print("📊 Removed buffer observers successfully")
            #endif
        }
    }
    
    func isLastErrorPermanent() -> Bool {
        StreamErrorType.from(error: lastError).isPermanent
    }
    
    func stop() {
        removeObservers()
        player?.pause()
        player = nil
        playerItem = nil
        if !hasPermanentError && delegate != nil {
            onStatusChange?(false, String(localized: "status_stopped"))
        }
    }
    
    func clearCallbacks() {
        onStatusChange = nil
        onMetadataChange = nil
        delegate = nil
    }
    
    deinit {
        stop()
    }
}

// MARK: - Metadata Handling
extension DirectStreamingPlayer: AVPlayerItemMetadataOutputPushDelegate {
    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                       didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                       from track: AVPlayerItemTrack?) {
        guard delegate != nil else {
            #if DEBUG
            print("🎵 metadataOutput: Delegate is nil, skipping callback")
            #endif
            return
        }
        
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
        // Reset player and observers in case they're in a bad state
        stop()
        
        // Add a small delay before returning to ready state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.delegate != nil else {
                #if DEBUG
                print("🎵 handleNetworkInterruption: Delegate is nil, skipping callback")
                #endif
                return
            }
            self.onStatusChange?(false, String(localized: "alert_retry"))
        }
    }
}

// MARK: - DirectStreamingPlayer Extension
extension DirectStreamingPlayer: AVAssetResourceLoaderDelegate {
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                       shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url else {
            loadingRequest.finishLoading(with: NSError(domain: "radio.lutheran", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return false
        }

        let streamingDelegate = StreamingSessionDelegate(loadingRequest: loadingRequest)
        let session = URLSession(configuration: .default, delegate: streamingDelegate, delegateQueue: nil)
        let task = session.dataTask(with: url)
        streamingDelegate.onError = { [weak self] error in
            guard let self = self, self.delegate != nil else {
                #if DEBUG
                print("📡 resourceLoader: Delegate is nil, skipping error callback")
                #endif
                return
            }
            DispatchQueue.main.async {
                self.handleLoadingError(error)
            }
        }
        task.resume()
        return true
    }
    
    private func handleLoadingError(_ error: Error) {
        #if DEBUG
        print("📡 Loading error: \(error.localizedDescription)")
        #endif
        let errorType = StreamErrorType.from(error: error)
        hasPermanentError = errorType.isPermanent
        if let urlError = error as? URLError {
            switch urlError.code {
            case .serverCertificateUntrusted, .secureConnectionFailed:
                #if DEBUG
                print("🔒 SSL error: Connection cannot be verified")
                #endif
                onStatusChange?(false, String(localized: "status_security_failed"))
            case .cannotFindHost, .fileDoesNotExist, .badServerResponse: // Include 502
                #if DEBUG
                print("📡 Permanent error: \(urlError.code == .cannotFindHost ? "Host not found" : urlError.code == .fileDoesNotExist ? "File not found" : "Bad server response")")
                #endif
                onStatusChange?(false, String(localized: "status_stream_unavailable"))
            default:
                #if DEBUG
                print("📡 Generic loading error: \(urlError.code)")
                #endif
                onStatusChange?(false, String(localized: "status_buffering"))
            }
        } else {
            #if DEBUG
            print("📡 Non-URL error encountered")
            #endif
            onStatusChange?(false, String(localized: "status_buffering"))
        }
        stop()
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                       didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        // Handle cancellation if needed
        #if DEBUG
        print("Resource loading cancelled")
        #endif
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
            case URLError.Code.secureConnectionFailed.rawValue, // -1200
                 URLError.Code.serverCertificateUntrusted.rawValue: // -1202
                return .securityFailure
            case URLError.Code.cannotFindHost.rawValue, // -1003
                 URLError.Code.resourceUnavailable.rawValue, // -1008
                 URLError.Code.fileDoesNotExist.rawValue, // -1100
                 URLError.Code.cannotConnectToHost.rawValue, // -1004
                 URLError.Code.badServerResponse.rawValue: // -1011 (for 502)
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
