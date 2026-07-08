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
/// - **Widget Communication**: Processes `lutheranradio://` schemes (e.g., play/pause/switch, "open") from widgets and Live Activities, delegating to public methods in `ViewController.swift`.
/// - **URL Handling**: Single entry point for deep links. Widget-action URLs are parsed and dispatched first for actionId deduplication; everything else flows through `handleURLScheme`. Uses `rootViewController(in:)` + `ParsedWidgetAction` (the extracted helpers) to avoid duplication and respect scene window context.
/// - **Privacy Note**: No external data in schemes; all actions local to app state.
///
/// The extraction of `ParsedWidgetAction` and `rootViewController(in:)` centralizes the previously repeated VC lookup and query parsing. All "open" handling for Live Activity taps correctly surfaces the app without forcing playback (see resurrection check).
///
/// For related background features, see `RadioLiveActivityManager.swift`. Ensures seamless widget-to-app handoff without tracking.
/// - SeeAlso: `ViewController.handleOpenFromLiveActivity`, `ViewController.handleWidgetAction`, `SharedPlayerManager` (pending actions)
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    /// The main window for the app's user interface.
    var window: UIWindow?

    /// Called when the scene connects to the session.
    /// - Parameters:
    ///   - scene: The scene connecting to the session.
    ///   - session: The session the scene is connecting to.
    ///   - connectionOptions: Options for the connection.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // Use this method to configure and attach the UIWindow `window` to the provided UIWindowScene `scene`.
        // Since we have removed Main.storyboard, we must create the window and root ViewController
        // programmatically. (The old storyboard-based automatic setup no longer applies.)
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        let viewController = ViewController()
        window.rootViewController = viewController
        self.window = window
        window.makeKeyAndVisible()

        // Handle any URLs that were used to launch the app (after root is attached)
        if let urlContext = connectionOptions.urlContexts.first {
            handleURLScheme(urlContext.url, from: scene)
        }
    }

    /// Called when the scene disconnects.
    ///
    /// This is one of the observable termination surfaces. We treat disconnect as a signal
    /// that this scene (and potentially the process) is going away, so we perform the same
    /// conservative widget/LA cleanup as applicationWillTerminate.
    ///
    /// - Cleanup Invariant: stale liveness + cancel pending + (LA end is also driven via the
    ///   shared notification observer, but we call the marker here for belt-and-suspenders).
    /// - Note: Not every disconnect is a full quit (multi-window, temporary), but forcing stale
    ///   liveness is harmless: the next foreground will bump it again via recordWidgetLiveness.
    func sceneDidDisconnect(_ scene: UIScene) {
        // Conservative quit cleanup for widget + LA surfaces (see AppDelegate.applicationWillTerminate
        // for the full rationale and invariant).
        SharedPlayerManager.performSessionTeardownSynchronouslyForTermination()

        window?.rootViewController = nil
        window = nil
    }

    /// Called when the scene becomes active.
    /// - Parameter scene: The scene that became active.
    func sceneDidBecomeActive(_ scene: UIScene) {
        // Called when the scene has moved from an inactive state to an active state.
        // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.

        #if DEBUG
        print("[SceneDelegate] sceneDidBecomeActive — unlock/active cycle")
        #endif
        
        // Check for pending widget actions when app becomes active
        if let viewController = window?.rootViewController as? ViewController {
            viewController.checkForPendingWidgetActions()
        }
        
        // Privacy: refresh the hasActiveLutheranWidgets flag (single source for write gating)
        // *before* the liveness/save so that if a widget was (re)added while backgrounded, writes resume.
        // Save current state when becoming active (in case widget needs fresh data)
        // → non-blocking / fire-and-forget. The save paths now consult the refreshed flag.
        Task { @MainActor in
            await WidgetRefreshManager.shared.refreshHasActiveWidgets()
            await SharedPlayerManager.shared.recordWidgetLiveness()
            await SharedPlayerManager.shared.saveCurrentState()
        }
    }

    /// Called when the scene will resign active state.
    /// - Parameter scene: The scene that will resign active.
    func sceneWillResignActive(_ scene: UIScene) {
        // Called when the scene will move from an active state to an inactive state.
        // This may occur due to temporary interruptions (ex. an incoming phone call) or device lock.

        #if DEBUG
        print("[SceneDelegate] sceneWillResignActive — lock/inactive cycle begin")
        #endif

        // Session hygiene when not actively playing: end stale LA surfaces and push passive widget state.
        // Skipped during background audio so lock-screen playback and LA controls remain intact.
        Task {
            let manager = SharedPlayerManager.shared
            let isActivelyPlaying = await manager.currentVisualState.isActivelyPlaying
            guard !isActivelyPlaying else {
                #if DEBUG
                print("[SceneDelegate] sceneWillResignActive — skipping session teardown (active playback)")
                #endif
                return
            }
            await manager.performSessionAndWidgetTeardown(
                includeFactoryReset: false,
                liveActivityTeardown: .immediate,
                refreshWidgets: true,
                widgetVisualState: nil,
                staleLiveness: false
            )
        }
    }

    /// Called when the scene enters the foreground.
    /// - Parameter scene: The scene entering the foreground.
    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
        if let viewController = window?.rootViewController as? ViewController {
            viewController.checkForPendingWidgetActions()
        }

        // Live Activity lifecycle (parallel to widget state): push latest visual + metadata
        // on return to foreground so Dynamic Island / Lock Screen buttons reflect current
        // PlayerVisualState immediately. See RadioLiveActivityManager.
        RadioLiveActivityManager.shared.handleAppDidEnterForeground()
    }

    /// Called when the scene enters the background.
    /// - Parameter scene: The scene entering the background.
    func sceneDidEnterBackground(_ scene: UIScene) {
        // Called as the scene transitions from the foreground to the background.
        // Use this method to save data, release shared resources, and store enough scene-specific state information
        // to restore the scene back to its current state.
        
        // Save current state for widget sharing — non-blocking / fire-and-forget
        Task {
            await SharedPlayerManager.shared.recordWidgetLiveness()
            await SharedPlayerManager.shared.saveCurrentState()
        }

        // Live Activity: give manager chance to start (if audio playing) when entering background.
        // This is the documented auto-start path. Manager owns the Activity request.
        RadioLiveActivityManager.shared.handleAppWillEnterBackground()
        
        #if DEBUG
        print("[SceneDelegate] Saved state for widget on background + forwarded LA background handling")
        #endif
    }

    /// Called when the app is opened via URL scheme from widgets or Live Activities.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url,
              url.scheme == "lutheranradio" else {
            return
        }

        // Widget-action URLs are special: they carry an `actionId` for deduplication
        // and are processed immediately (bypassing the general handler). This path
        // is used by certain widget-to-app signaling flows.
        if let action = ParsedWidgetAction.from(url) {
            if let viewController = rootViewController(in: scene) {
                if action.action == "switch", let languageCode = action.parameter {
                    viewController.handleWidgetSwitchToLanguage(languageCode, actionId: action.actionId)
                    Task {
                        SharedPlayerManager.shared.clearPendingAction(actionId: action.actionId)
                    }
                } else {
                    viewController.handleWidgetAction(action: action.action, parameter: action.parameter, actionId: action.actionId)
                }
            }
            return
        }

        // Simple deep links (including "open" from tapping Live Activities or widgets)
        // go through the unified handler, which will surface the app and/or perform
        // the requested playback control. See handleOpenFromLiveActivity for the
        // "open" resurrection path that respects .userPaused / .securityLocked.
        handleURLScheme(url, from: scene)
    }

    /// Handles `lutheranradio://` deep links for playback control and foregrounding.
    ///
    /// This is the common path after any `widget-action` special cases. Callers
    /// may pass the originating `scene` so that the root ViewController can be
    /// resolved reliably even during early lifecycle or open events.
    ///
    /// - Parameters:
    ///   - url: The deep link URL.
    ///   - scene: Optional `UIScene` from the calling context (preferred for VC lookup).
    /// - SeeAlso: `ParsedWidgetAction`, `rootViewController(in:)`, `ViewController.handleOpenFromLiveActivity`
    private func handleURLScheme(_ url: URL, from scene: UIScene? = nil) {
        guard url.scheme == "lutheranradio" else {
            #if DEBUG
            print("[SceneDelegate] Invalid URL scheme: \(url.scheme ?? "nil"), expected 'lutheranradio'")
            #endif
            return
        }

        #if DEBUG
        print("[SceneDelegate] Handling URL scheme: \(url.absoluteString)")
        #endif

        guard let viewController = rootViewController(in: scene) else {
            #if DEBUG
            print("[SceneDelegate] Unable to get ViewController from window")
            #endif
            return
        }

        switch url.host {
        case "play":
            #if DEBUG
            print("[SceneDelegate] Handling play action from widget")
            #endif
            // Routes (via VC + coordinator shim) to userRequestedPlay() — the designation.
            viewController.handlePlayAction()

        case "pause":
            #if DEBUG
            print("[SceneDelegate] Handling pause action from widget")
            #endif
            viewController.handlePauseAction()

        case "toggle":
            #if DEBUG
            print("[SceneDelegate] Handling toggle action from widget")
            #endif
            viewController.handleTogglePlayback()

        case "open":
            #if DEBUG
            print("[SceneDelegate] Handling open from Live Activity or widget tap")
            #endif
            viewController.handleOpenFromLiveActivity()

        case "switch":
            // Expected format: lutheranradio://switch?language=en (or ?param=...)
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let queryItems = components.queryItems,
               let languageItem = queryItems.first(where: { $0.name == "language" || $0.name == "param" }),
               let languageCode = languageItem.value {
                #if DEBUG
                print("[SceneDelegate] Handling switch to language: \(languageCode)")
                #endif
                viewController.handleSwitchToLanguage(languageCode)
            } else {
                #if DEBUG
                print("[SceneDelegate] Invalid switch URL format: \(url.absoluteString)")
                #endif
            }

        default:
            #if DEBUG
            print("[SceneDelegate] Unknown URL host: \(url.host ?? "nil")")
            #endif
            break
        }
    }

    // MARK: - Extracted URL Helpers

    /// Parsed representation of a `lutheranradio://widget-action` URL.
    ///
    /// These carry the action name, a unique `actionId` (for dedup), and an optional
    /// parameter (e.g. language code for switches). They are handled with priority
    /// in `openURLContexts` because they come from the widget extension process.
    ///
    /// - SeeAlso: `SceneDelegate.scene(_:openURLContexts:)`, `ViewController.handleWidgetAction`
    private struct ParsedWidgetAction {
        let action: String
        let actionId: String
        let parameter: String?

        /// Parses the required fields from a widget-action URL.
        /// Returns nil if host or mandatory query items are missing.
        static func from(_ url: URL) -> ParsedWidgetAction? {
            guard url.host == "widget-action",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let action = components.queryItems?.first(where: { $0.name == "action" })?.value,
                  let actionId = components.queryItems?.first(where: { $0.name == "actionId" })?.value
            else { return nil }

            let parameter = components.queryItems?.first(where: { $0.name == "parameter" })?.value
            return ParsedWidgetAction(action: action, actionId: actionId, parameter: parameter)
        }
    }

    /// Resolves the root `ViewController` that receives widget/URL scheme commands.
    ///
    /// When a `UIScene` is supplied (typical during `openURLContexts` and launch),
    /// its window is preferred. This avoids races where the delegate's stored
    /// `window` has not yet been updated for the active scene.
    ///
    /// Falls back to `self.window`.
    ///
    /// - Parameter scene: The scene associated with the current URL or lifecycle event.
    /// - Returns: The root ViewController if it is the expected type.
    /// - Note: Single extraction point for all VC lookups in this delegate.
    /// - SeeAlso: `handleURLScheme(_:from:)`
    private func rootViewController(in scene: UIScene? = nil) -> ViewController? {
        if let windowScene = scene as? UIWindowScene,
           let vc = windowScene.windows.first?.rootViewController as? ViewController {
            return vc
        }
        return window?.rootViewController as? ViewController
    }
}
