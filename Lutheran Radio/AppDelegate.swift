//
//  AppDelegate.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.10.2024.
//

/// - Article: App Delegate Lifecycle Management
///
/// Handles application lifecycle and scene session configuration for the Lutheran Radio app.
import UIKit

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
}
