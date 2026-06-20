//
//  AppDelegate.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.10.2024.
//

/// - Article: Lutheran Radio App Overview
///
/// Lutheran Radio is a privacy-first iOS 26+ app for streaming Lutheran content in multiple languages (English, German, Finnish, Swedish, Estonian). It emphasizes secure, anonymous access without tracking, analytics, or permissions for microphone/camera/location/push notifications.
///
/// Key Components:
/// - **Streaming Core**: `DirectStreamingPlayer.swift` handles audio playback with SSL pinning and adaptive retries (see `CertificateValidator.swift` for validation logic).
/// - **UI and Controls**: `ViewController.swift` manages the main interface, language selection (`LanguageCell.swift`), and iOS 26 features like low-power mode optimization.
/// - **Background/Widget Integration**: Uses `SharedPlayerManager.swift` for state sharing with widgets; `RadioLiveActivityManager.swift` for local-only Live Activities; `WidgetRefreshManager.swift` for throttled updates.
/// - **Lifecycle Handling**: `SceneDelegate.swift` processes URL schemes from widgets and manages background/foreground transitions.
///
/// Privacy Focus: No user data collection; encrypted streams only (see `StreamingSessionDelegate.swift` for session management). For widget interactions, see `handleURLScheme` in `SceneDelegate.swift`.
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

    // MARK: - Menu Building (Storyboard Removal Guard)
    //
    // After fully removing Main.storyboard, UIKit's UIMenuSystem (used for
    // the main menu bar on iPad / Mac, and for discovering keyboard shortcuts /
    // key commands) can still attempt to load a storyboard named "Main" via
    // the private _storyboardInitialMenu path inside buildMenuWithBuilder.
    //
    // This produces the exact crash:
    //   'Could not find a storyboard named 'Main' in bundle ...'
    //
    // Implementing buildMenu(with:) here makes the app participate in menu
    // construction explicitly (as a UIResponder), short-circuiting the
    // storyboard fallback. We call super so that standard system menus
    // (Edit, Format, View, Window, Help, etc.) and automatic key command
    // discovery from the responder chain continue to work.
    //
    // - Important: This must live on AppDelegate (or another early responder)
    //   because the menu rebuild can be triggered very early (during
    //   _immediatelyUpdateSerializableKeyCommands / after CA commit).
    // - SeeAlso: SceneDelegate (window setup), UIApplication.buildMenuWithBuilder
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
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
    
    // Foreground refresh — use the centralized manager (respects debouncing + SSOT)
    func applicationWillEnterForeground(_ application: UIApplication) {
        Task { @MainActor in
            let manager = SharedPlayerManager.shared
            await manager.recordWidgetLiveness()
            let vs = await manager.currentVisualState
            let st = manager.loadSharedState()
            WidgetRefreshManager.shared.refreshIfNeeded(
                visualState: vs,
                currentLanguage: st.currentLanguage,
                hasError: st.hasError,
                immediate: true
            )
        }
        
        #if DEBUG
        print("[AppDelegate] Foreground widget refresh via WidgetRefreshManager")
        #endif
    }
}
