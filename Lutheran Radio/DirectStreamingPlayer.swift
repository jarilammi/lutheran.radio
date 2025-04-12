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

class DirectStreamingPlayer: NSObject {
    // MARK: - Security Model
    private let appSecurityModel = "mariehamn" // Security model in use
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
    
    private func fetchValidSecurityModels(completion: @escaping (Result<Set<String>, Error>) -> Void) {
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
    
    private func queryTXTRecord(domain: String, completion: @escaping (Result<Set<String>, Error>) -> Void) {
        // Define a context structure to hold self and the completion handler
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
        print("🔍 [DNS Query] Starting TXT record query for domain: \(domain), flags: \(flags), interface: \(interfaceIndex), type: \(type), class: \(rrClass)")
        #endif

        guard let domainCStr = domain.cString(using: .utf8) else {
            #if DEBUG
            print("❌ [DNS Query] Failed to convert domain to C string: \(domain)")
            #endif
            completion(.failure(NSError(domain: "radio.lutheran", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid domain"])))
            return
        }

        // Create the context and pass it to DNSServiceQueryRecord
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
                #if DEBUG
                print("📩 [DNS Query Callback] Invoked with: errorCode=\(errorCode), fullName=\(String(cString: fullName!)), rrtype=\(rrtype), rrclass=\(rrclass), rdlen=\(rdlen), ttl=\(ttl)")
                #endif

                // Retrieve the context
                let contextPointer = context?.assumingMemoryBound(to: QueryContext.self)
                guard let queryContext = contextPointer?.pointee else {
                    #if DEBUG
                    print("❌ [DNS Query Callback] QueryContext is nil, aborting")
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

                // Process the callback
                guard errorCode == kDNSServiceErr_NoError, let rawData = rdata else {
                    #if DEBUG
                    print("❌ [DNS Query Callback] Query failed with errorCode=\(errorCode)")
                    #endif
                    completion(.failure(NSError(domain: "dnssd", code: Int(errorCode), userInfo: [NSLocalizedDescriptionKey: "DNS query failed"])))
                    return
                }

                #if DEBUG
                print("✅ [DNS Query Callback] Successfully retrieved TXT record data: length=\(rdlen)")
                #endif

                let txtData = Data(bytes: rawData, count: Int(rdlen))
                let models = player.parseTXTRecordData(txtData)
                #if DEBUG
                print("🎉 [DNS Query Callback] Query completed, parsed models: \(models)")
                #endif
                completion(.success(models))
            },
            contextPointer
        )

        if error == kDNSServiceErr_NoError, let serviceRef = serviceRef {
            #if DEBUG
            print("🚀 [DNS Query] DNSServiceQueryRecord initiated successfully, processing result")
            #endif
            DNSServiceProcessResult(serviceRef)
            DNSServiceRefDeallocate(serviceRef)
            #if DEBUG
            print("🧹 [DNS Query] DNSServiceRef deallocated")
            #endif
        } else {
            #if DEBUG
            print("❌ [DNS Query] DNSServiceQueryRecord initiation failed with error=\(error)")
            #endif
            completion(.failure(NSError(domain: "dnssd", code: Int(error), userInfo: [NSLocalizedDescriptionKey: "DNS service init failed"])))
        }
    }

    private func parseTXTRecordData(_ data: Data) -> Set<String> {
        #if DEBUG
        print("📜 [Parse TXT Record] Starting parsing of TXT record data, length: \(data.count) bytes")
        #endif
        var models = Set<String>()
        var index = 0
        while index < data.count {
            let length = Int(data[index])
            #if DEBUG
            print("📜 [Parse TXT Record] Reading segment at index \(index), length: \(length)")
            #endif
            index += 1
            if index + length <= data.count {
                let strData = data.subdata(in: index..<index + length)
                if let str = String(data: strData, encoding: .utf8) {
                    #if DEBUG
                    print("📜 [Parse TXT Record] Parsed string: \(str)")
                    #endif
                    let modelList = str.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
                    models.formUnion(modelList)
                    #if DEBUG
                    print("📜 [Parse TXT Record] Extracted models: \(modelList)")
                    #endif
                } else {
                    #if DEBUG
                    print("❌ [Parse TXT Record] Failed to decode string at index \(index - 1)")
                    #endif
                }
                index += length
            } else {
                #if DEBUG
                print("❌ [Parse TXT Record] Invalid length at index \(index - 1): length=\(length), remaining data=\(data.count - index)")
                #endif
                break
            }
        }
        #if DEBUG
        print("📜 [Parse TXT Record] Parsing complete, final models: \(models)")
        #endif
        return models
    }
    
    private func validateSecurityModel(completion: @escaping (Bool) -> Void) {
        guard !isValidating else {
            #if DEBUG
            print("🔒 [Validate Security Model] Validation already in progress, scheduling retry")
            #endif
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else {
                    #if DEBUG
                    print("❌ [Validate Security Model] Self deallocated during retry")
                    #endif
                    completion(false)
                    return
                }
                if let isValid = self.isSecurityModelValid {
                    #if DEBUG
                    print("🔒 [Validate Security Model] Validation already completed, returning cached result: isValid=\(isValid)")
                    #endif
                    completion(isValid)
                } else {
                    #if DEBUG
                    print("🔒 [Validate Security Model] Retrying validation")
                    #endif
                    self.validateSecurityModel(completion: completion)
                }
            }
            return
        }

        isValidating = true
        #if DEBUG
        print("🔒 [Validate Security Model] Starting validation for security model: \(appSecurityModel)")
        #endif

        fetchValidSecurityModels { [weak self] result in
            guard let self = self else {
                #if DEBUG
                print("❌ [Validate Security Model] Self deallocated during validation")
                #endif
                DispatchQueue.main.async { completion(false) }
                return
            }
            self.isValidating = false
            switch result {
            case .success(let validModels):
                if validModels.isEmpty {
                    #if DEBUG
                    print("❌ [Validate Security Model] No security models returned from DNS, treating as permanent security error")
                    #endif
                    self.isSecurityModelValid = false
                    self.hasPermanentError = true
                    self.lastValidationWasSecurityMismatch = true
                    DispatchQueue.main.async {
                        self.onStatusChange?(false, String(localized: "status_security_failed"))
                        completion(false)
                    }
                } else {
                    let isValid = validModels.contains(self.appSecurityModel.lowercased())
                    self.isSecurityModelValid = isValid
                    #if DEBUG
                    print("🔒 [Validate Security Model] Validation result: model=\(self.appSecurityModel), isValid=\(isValid), validModels=\(validModels)")
                    #endif
                    if !isValid {
                        self.hasPermanentError = true
                        self.lastValidationWasSecurityMismatch = true
                        DispatchQueue.main.async {
                            self.onStatusChange?(false, String(localized: "status_security_failed"))
                            completion(false)
                        }
                    } else {
                        self.hasPermanentError = false // Clear any previous permanent error on success
                        self.lastValidationWasSecurityMismatch = false
                        DispatchQueue.main.async {
                            completion(true)
                        }
                    }
                }
            case .failure(let error):
                let nsError = error as NSError
                if nsError.domain == "radio.lutheran" && nsError.code < 0 { // DNS query failed
                    #if DEBUG
                    print("❌ [Validate Security Model] DNS query failed, likely due to network issue: \(error.localizedDescription)")
                    #endif
                    self.isSecurityModelValid = false
                    // Do not set hasPermanentError for network issues
                    DispatchQueue.main.async {
                        self.onStatusChange?(false, String(localized: "status_no_internet"))
                        completion(false)
                    }
                } else {
                    #if DEBUG
                    print("❌ [Validate Security Model] Security model fetch failed with error: \(error.localizedDescription), treating as permanent security error")
                    #endif
                    self.isSecurityModelValid = false
                    self.hasPermanentError = true
                    self.lastValidationWasSecurityMismatch = true
                    DispatchQueue.main.async {
                        self.onStatusChange?(false, String(localized: "status_security_failed"))
                        completion(false)
                    }
                }
            }
        }
    }
    
    public func resetTransientErrors() {
        if !hasPermanentErrorDueToSecurity() {
            hasPermanentError = false
            isSecurityModelValid = nil // Force revalidation on next play
            #if DEBUG
            print("🔄 Resetting transient error state: hasPermanentError=\(hasPermanentError), forcing security model revalidation")
            #endif
        } else {
            #if DEBUG
            print("🔄 Skipping reset of transient errors due to permanent security error")
            #endif
        }
    }

    private func hasPermanentErrorDueToSecurity() -> Bool {
        return hasPermanentError && lastValidationWasSecurityMismatch
    }
    
    private var lastValidationWasSecurityMismatch: Bool = false

    private func wasLastValidationSecurityMismatch() -> Bool {
        return lastValidationWasSecurityMismatch
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
        if hasPermanentErrorDueToSecurity() {
            #if DEBUG
            print("📡 Play aborted: Permanent security error exists")
            #endif
            DispatchQueue.main.async {
                self.onStatusChange?(false, String(localized: "status_security_failed"))
                completion(false)
            }
            return
        }

        validateSecurityModel { [weak self] isValid in
            guard let self = self else {
                completion(false)
                return
            }

            if !isValid {
                completion(false)
                return
            }

            // Proceed with playback
            self.stop()
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
        if hasPermanentErrorDueToSecurity() {
            #if DEBUG
            print("📡 Stream switch aborted: Permanent security error exists")
            #endif
            DispatchQueue.main.async {
                self.onStatusChange?(false, String(localized: "status_security_failed"))
            }
            return
        }

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
            // Remove observers only if we know they were added
            playerItem.removeObserver(self, forKeyPath: "playbackBufferEmpty")
            playerItem.removeObserver(self, forKeyPath: "playbackLikelyToKeepUp")
            playerItem.removeObserver(self, forKeyPath: "playbackBufferFull")
            isObservingBuffer = false
            #if DEBUG
            print("📊 Removed buffer observers successfully")
            #endif
        } else {
            #if DEBUG
            print("📊 No buffer observers to remove (isObservingBuffer=\(isObservingBuffer), playerItem=\(playerItem != nil ? "exists" : "nil"))")
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
