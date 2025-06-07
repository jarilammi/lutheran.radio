//
//  SharedPlayerManager.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 7.6.2025.
//

import Foundation
import AVFoundation

class SharedPlayerManager {
    static let shared = SharedPlayerManager()
    private let player = DirectStreamingPlayer.shared
    
    private init() {}
    
    // Widget-safe methods that won't crash
    var isPlaying: Bool {
        return player.isPlaying
    }
    
    var currentStream: DirectStreamingPlayer.Stream {
        return player.selectedStream
    }
    
    var availableStreams: [DirectStreamingPlayer.Stream] {
        return DirectStreamingPlayer.availableStreams
    }
    
    var hasError: Bool {
        return player.hasPermanentError || player.isLastErrorPermanent()
    }
    
    // Widget-safe play method
    func play(completion: @escaping (Bool) -> Void) {
        // Ensure we're not in a widget context for complex operations
        guard !isRunningInWidget() else {
            // For widgets, use URL scheme to communicate with main app
            openMainApp(action: "play")
            completion(true)
            return
        }
        
        player.play(completion: completion)
    }
    
    // Widget-safe stop method
    func stop(completion: @escaping () -> Void = {}) {
        guard !isRunningInWidget() else {
            openMainApp(action: "pause")
            completion()
            return
        }
        
        player.stop(completion: completion)
    }
    
    // Switch stream method
    func switchToStream(_ stream: DirectStreamingPlayer.Stream) {
        guard !isRunningInWidget() else {
            openMainApp(action: "switch", parameter: stream.languageCode)
            return
        }
        
        player.setStream(to: stream)
    }
    
    // Check if running in widget context
    private func isRunningInWidget() -> Bool {
        return Bundle.main.bundlePath.contains("PlugIns")
    }
    
    // Open main app with action - Fixed for iOS
    private func openMainApp(action: String, parameter: String? = nil) {
        var urlString = "lutheranradio://\(action)"
        if let param = parameter {
            urlString += "?param=\(param)"
        }
        
        if let url = URL(string: urlString) {
            // For iOS widgets, we need to use the extensionContext
            // This will be handled in the actual widget implementation
            #if DEBUG
            print("Widget would open URL: \(url)")
            #endif
            // Note: Actual URL opening should be handled in the widget's perform() method
            // using extensionContext?.open(url, completionHandler: nil)
        }
    }
}

// Use UserDefaults for simple state sharing:
extension SharedPlayerManager {
    private var sharedDefaults: UserDefaults? {
        return UserDefaults(suiteName: "group.radio.lutheran.shared")
    }
    
    func saveCurrentState() {
        sharedDefaults?.set(isPlaying, forKey: "isPlaying")
        sharedDefaults?.set(currentStream.languageCode, forKey: "currentLanguage")
        sharedDefaults?.set(hasError, forKey: "hasError")
    }
    
    func loadSharedState() -> (isPlaying: Bool, currentLanguage: String, hasError: Bool) {
        let isPlaying = sharedDefaults?.bool(forKey: "isPlaying") ?? false
        let currentLanguage = sharedDefaults?.string(forKey: "currentLanguage") ?? "en"
        let hasError = sharedDefaults?.bool(forKey: "hasError") ?? false
        return (isPlaying, currentLanguage, hasError)
    }
}
