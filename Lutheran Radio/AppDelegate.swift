//
//  AppDelegate.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.10.2024.
//

/// - Article: Lutheran Radio App Overview
///
/// Lutheran Radio is a privacy-first iOS 18+ app for streaming Lutheran content in multiple languages (English, German, Finnish, Swedish, Estonian). It emphasizes secure, anonymous access without tracking, analytics, or permissions for microphone/camera/location/push notifications.
///
/// Key Components:
/// - **Streaming Core**: `DirectStreamingPlayer.swift` handles audio playback with SSL pinning and adaptive retries (see `CertificateValidator.swift` for validation logic).
/// - **UI and Controls**: `ViewController.swift` manages the main interface, language selection (`LanguageCell.swift`), and iOS 18 features like low-power mode optimization.
/// - **Background/Widget Integration**: Uses `SharedPlayerManager.swift` for state sharing with widgets; `RadioLiveActivityManager.swift` for local-only Live Activities; `WidgetRefreshManager.swift` for throttled updates.
/// - **Lifecycle Handling**: `SceneDelegate.swift` processes URL schemes from widgets and manages background/foreground transitions.
///
/// Privacy Focus: No user data collection; encrypted streams only (see `StreamingSessionDelegate.swift` for session management). For widget interactions, see `handleURLScheme` in `SceneDelegate.swift`.
import UIKit
import WidgetKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    /// Called when the application finishes launching.
    /// - Parameters:
    ///   - application: The application instance.
    ///   - launchOptions: Launch options provided to the app.
    /// - Returns: A Boolean indicating whether the app launched successfully.
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }

    // MARK: - UISceneSession Lifecycle
    /// Provides configuration for a connecting scene session.
    /// - Parameters:
    ///   - application: The application instance.
    ///   - connectingSceneSession: The scene session being connected.
    ///   - options: Connection options for the scene.
    /// - Returns: The scene configuration to use.
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    /// Called when scene sessions are discarded.
    /// - Parameters:
    ///   - application: The application instance.
    ///   - sceneSessions: The set of discarded scene sessions.
    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {}
    
    // NEW: Add foreground refresh
    func applicationWillEnterForeground(_ application: UIApplication) {
        WidgetCenter.shared.reloadAllTimelines()
        
        #if DEBUG
        print("🔗 [AppDelegate] Force widget refresh on foreground")
        #endif
    }
}
