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
    
    // Imperative **lifecycle** path: foreground re-entry has no PlayerEvent.
    // Mutation-path reloads stay on the Tier 2 observer; this only re-syncs
    // timelines after suspension (see WidgetRefreshTrigger.lifecycle).
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
                immediate: true,
                trigger: .lifecycle
            )
        }

        // Also refresh Live Activity state (in case scene delegate path wasn't the active one).
        RadioLiveActivityManager.shared.handleAppDidEnterForeground()
        
        #if DEBUG
        print("[AppDelegate] Foreground widget refresh via WidgetRefreshManager + LA update")
        #endif
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // === App Termination Cleanup (Conservative Widget + Live Activity Lifecycle) ===
        //
        // Primary objective: once the main app process is no longer running, widget and Live
        // Activity surfaces must stop receiving active updates/pings and must render stable
        // passive / last-known states. They may only launch the app via Apple-approved paths.
        //
        // This method is the canonical documented termination entry (UIApplicationDelegate).
        // iOS does not guarantee delivery (force-quit, OOM, crash all bypass it), which is why
        // we also observe willTerminateNotification inside RadioLiveActivityManager and call
        // the liveness-stale marker from every observable termination surface.
        //
        // Cleanup performed here (order matters):
        // 1. Force-stale the liveness timestamp (SSOT) → widgets immediately see
        //    `isMainAppProcessRecentlyActive() == false` and render the "tap_to_open" prompt
        //    (widgetURL launch only). This is the key signal that kills the "still pinging"
        //    appearance after quit.
        // 2. End any Live Activity (final .userPaused pushed + immediate dismissal).
        // 3. Cancel pending widget refreshes so no in-flight debounced reload can execute
        //    after the process is dead.
        //
        // Cleanup Invariant: After this returns (when delivered), no path originating from the
        // (now-exiting) main process may cause WidgetCenter.reloadTimelines, Activity.update,
        // or liveness bumps. The persisted snapshot (if present) is left as last-known for
        // providers; the liveness sentinel makes presentation passive.
        //
        // See also: SharedPlayerManager.forceStaleLivenessTimestampForTermination,
        // RadioLiveActivityManager.handleAppWillTerminate, SceneDelegate.sceneDidDisconnect,
        // WidgetRefreshManager.cancelPendingRefresh, docs/Widget-Presentation-Dataflow.md.
        //
        // SAFETY: All calls here are best-effort and non-throwing; they only touch in-process
        // state and UserDefaults. No force-unwraps.

        // Canonical synchronous session + widget teardown (liveness, LA, widgets, Now Playing).
        SharedPlayerManager.performSessionTeardownSynchronouslyForTermination()

        #if DEBUG
        print("[AppDelegate] applicationWillTerminate — performSessionTeardownSynchronouslyForTermination complete")
        #endif
    }
}
