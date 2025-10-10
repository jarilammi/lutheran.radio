//
//  SceneDelegate.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.10.2024.
//

import UIKit

/// - Article: Scene Lifecycle and Widget Integration
///
/// `SceneDelegate` manages iOS scene transitions, window setup, and URL scheme handling for widget actions in the Lutheran Radio app.
///
/// Core Responsibilities:
/// - **Lifecycle Events**: Handles foreground/background transitions with state saves via `SharedPlayerManager.swift`; checks pending widget actions on active.
/// - **Widget Communication**: Processes `lutheranradio://` schemes (e.g., play/pause/switch) from widgets, delegating to public methods in `ViewController.swift`.
/// - **URL Handling**: Supports deep links for playback control; integrates with `AppDelegate.swift` for app-wide lifecycle.
/// - **Privacy Note**: No external data in schemes; all actions local to app state.
///
/// For related background features, see `RadioLiveActivityManager.swift`. Ensures seamless widget-to-app handoff without tracking.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    /// The main window for the app's user interface.
    var window: UIWindow?

    /// Called when the scene connects to the session.
    /// - Parameters:
    ///   - scene: The scene connecting to the session.
    ///   - session: The session the scene is connecting to.
    ///   - connectionOptions: Options for the connection.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // Use this method to optionally configure and attach the UIWindow `window` to the provided UIWindowScene `scene`.
        // If using a storyboard, the `window` property will automatically be initialized and attached to the scene.
        // This delegate does not imply the connecting scene or session are new (see `application:configurationForConnectingSceneSession` instead).
        guard let _ = (scene as? UIWindowScene) else { return }
        
        // Handle any URLs that were used to launch the app
        if let urlContext = connectionOptions.urlContexts.first {
            handleURLScheme(urlContext.url)
        }
    }

    /// Called when the scene disconnects.
    /// - Parameter scene: The scene that disconnected.
    func sceneDidDisconnect(_ scene: UIScene) {
        window?.rootViewController = nil
        window = nil
    }

    /// Called when the scene becomes active.
    /// - Parameter scene: The scene that became active.
    func sceneDidBecomeActive(_ scene: UIScene) {
        // Called when the scene has moved from an inactive state to an active state.
        // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
        
        // Check for pending widget actions when app becomes active
        if let viewController = window?.rootViewController as? ViewController {
            viewController.checkForPendingWidgetActions()
        }
        
        // Save current state when becoming active (in case widget needs fresh data)
        SharedPlayerManager.shared.saveCurrentState()
    }

    /// Called when the scene will resign active state.
    /// - Parameter scene: The scene that will resign active.
    func sceneWillResignActive(_ scene: UIScene) {
        // Called when the scene will move from an active state to an inactive state.
        // This may occur due to temporary interruptions (ex. an incoming phone call).
    }

    /// Called when the scene enters the foreground.
    /// - Parameter scene: The scene entering the foreground.
    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
    }

    /// Called when the scene enters the background.
    /// - Parameter scene: The scene entering the background.
    func sceneDidEnterBackground(_ scene: UIScene) {
        // Called as the scene transitions from the foreground to the background.
        // Use this method to save data, release shared resources, and store enough scene-specific state information
        // to restore the scene back to its current state.
        
        // Save current state for widget sharing
        SharedPlayerManager.shared.saveCurrentState()
        
        #if DEBUG
        print("🔗 Saved state for widget on background")
        #endif
    }

    /// Called when the app is opened via URL scheme
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url,
              url.scheme == "lutheranradio",
              url.host == "widget-action",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let action = components.queryItems?.first(where: { $0.name == "action" })?.value,
              let actionId = components.queryItems?.first(where: { $0.name == "actionId" })?.value else {
            return
        }
        
        let parameter = components.queryItems?.first(where: { $0.name == "parameter" })?.value
        
        // Get the ViewController instance
        if let windowScene = scene as? UIWindowScene,
           let window = windowScene.windows.first,
           let viewController = window.rootViewController as? ViewController {
            viewController.handleWidgetAction(action: action, parameter: parameter, actionId: actionId)
        }
    }

    /// Handles incoming URL schemes from widgets or external sources
    private func handleURLScheme(_ url: URL) {
        guard url.scheme == "lutheranradio" else {
            #if DEBUG
            print("🔗 Invalid URL scheme: \(url.scheme ?? "nil"), expected 'lutheranradio'")
            #endif
            return
        }
        
        #if DEBUG
        print("🔗 Handling URL scheme: \(url.absoluteString)")
        #endif
        
        // Ensure we have access to the view controller
        guard let viewController = window?.rootViewController as? ViewController else {
            #if DEBUG
            print("🔗 Unable to get ViewController from window")
            #endif
            return
        }
        
        switch url.host {
        case "play":
            #if DEBUG
            print("🔗 Handling play action from widget")
            #endif
            viewController.handlePlayAction() // ✅ Use public method
            
        case "pause":
            #if DEBUG
            print("🔗 Handling pause action from widget")
            #endif
            viewController.handlePauseAction() // ✅ Use public method
            
        case "toggle":
            #if DEBUG
            print("🔗 Handling toggle action from widget")
            #endif
            viewController.handleTogglePlayback() // ✅ Use public method
            
        case "switch":
            // Handle stream switch from widget
            // Expected format: lutheranradio://switch?language=en
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let queryItems = components.queryItems,
               let languageItem = queryItems.first(where: { $0.name == "language" || $0.name == "param" }),
               let languageCode = languageItem.value {
                #if DEBUG
                print("🔗 Handling switch to language: \(languageCode)")
                #endif
                viewController.handleSwitchToLanguage(languageCode) // ✅ Use public method
            } else {
                #if DEBUG
                print("🔗 Invalid switch URL format: \(url.absoluteString)")
                #endif
            }
            
        default:
            #if DEBUG
            print("🔗 Unknown URL host: \(url.host ?? "nil")")
            #endif
            break
        }
    }
}
