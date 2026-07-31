//
//  SceneDelegate.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.10.2024.
//
//  Purpose: UIScene lifecycle host — window ownership, `lutheranradio://` deep links,
//  foreground/background handoff to SharedPlayerManager + RadioLiveActivityManager, and
//  thin scheduling of pending-action drain (coordinator owns execute).
//
//  - SeeAlso: ``RadioPlayerCoordinator/checkForPendingWidgetActions()``,
//    ``SharedPlayerManager/getPendingActionIfFresh(maxAge:)``,
//    ``SharedPlayerManager/discardResidualPendingActionsAndArmMailboxForThisProcess()``,
//    ``SharedPlayerManager/performSessionTeardownSynchronouslyForTermination()``,
//    ViewController cold-launch Task, docs/Widget-Presentation-Dataflow.md, CODING_AGENT.md.
//

import UIKit

/// Scene lifecycle, window setup, and `lutheranradio://` deep-link entry for widget / Live Activity handoff.
///
/// **Responsibilities:**
/// - Foreground/background: liveness heartbeat, state save, Live Activity ensure/update paths
/// - Pending-action **scheduling** only: calls ``ViewController/checkForPendingWidgetActions()``
///   (thin shim → ``RadioPlayerCoordinator/checkForPendingWidgetActions()``). Execution honesty
///   lives in ``SharedPlayerManager/getPendingActionIfFresh(maxAge:)`` (unarmed cold start,
///   pre-boot residual, termination sentinel, max age).
/// - Deep links: `widget-action` URLs (actionId dedup) first; other hosts via ``handleURLScheme(_:from:)``
/// - Termination-adjacent cleanup: ``sceneDidDisconnect`` mirrors
///   ``SharedPlayerManager/performSessionTeardownSynchronouslyForTermination()``
///
/// **`lutheranradio://open` honesty:** ``ViewController/handleOpenFromLiveActivity()`` only runs
/// the resurrection / state-sync check and does **not** invent a new play intent. Cold-launch
/// auto-play (special tuning + ``play()`` when sticky intent is absent) is owned by the
/// ``ViewController`` viewDidLoad Task — orthogonal to this open handler.
///
/// **Privacy:** Scheme payloads are local action tokens only (no external personal data).
///
/// - SeeAlso: ``ViewController/handleOpenFromLiveActivity()``, ``ViewController/handleWidgetAction(action:parameter:actionId:)``,
///   ``RadioPlayerCoordinator/checkForPendingWidgetActions()``,
///   ``RadioLiveActivityManager/ensureInteractiveLiveActivityIfNeeded()``,
///   ``RadioLiveActivityManager/handleAppDidEnterForeground()``,
///   ``SharedPlayerManager/getPendingActionIfFresh(maxAge:)``,
///   docs/Widget-Presentation-Dataflow.md
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    /// The main window for the app's user interface.
    var window: UIWindow?

    /// Configures the window and root ``ViewController`` programmatically (no Main storyboard).
    ///
    /// - Parameters:
    ///   - scene: The scene connecting to the session.
    ///   - session: The session the scene is connecting to.
    ///   - connectionOptions: May include launch URL contexts handled after the root is attached.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        let viewController = ViewController()
        window.rootViewController = viewController
        self.window = window
        window.makeKeyAndVisible()

        // Launch URLs after root is attached so ``rootViewController(in:)`` resolves.
        if let urlContext = connectionOptions.urlContexts.first {
            handleURLScheme(urlContext.url, from: scene)
        }
    }

    /// Observable termination-adjacent surface: same synchronous session teardown as
    /// `applicationWillTerminate` (liveness sentinel, LA end, widget refresh cancel, Now Playing clear).
    ///
    /// - Important: Force-quit and reboot often **do not** deliver this callback. Dirty-exit
    ///   honesty relies on residual aging, reboot distrust, and cold-launch factory hygiene —
    ///   not disconnect alone.
    /// - Note: Not every disconnect is a full process quit (multi-window / temporary). Writing
    ///   the termination liveness sentinel is still safe: the next live foreground bumps
    ///   ``SharedPlayerManager/recordWidgetLiveness()`` again.
    /// - SeeAlso: ``SharedPlayerManager/performSessionTeardownSynchronouslyForTermination()``,
    ///   AppDelegate.applicationWillTerminate
    func sceneDidDisconnect(_ scene: UIScene) {
        SharedPlayerManager.performSessionTeardownSynchronouslyForTermination()

        window?.rootViewController = nil
        window = nil
    }

    /// Becomes active: drain pending widget commands (when honest), then refresh privacy gate,
    /// liveness, snapshot, and Live Activity ensure.
    ///
    /// Pending drain is intentional **before** the async liveness Task so in-session widget
    /// taps are processed promptly. Residual pre-process / pre-boot commands are refused by
    /// ``SharedPlayerManager/getPendingActionIfFresh(maxAge:)`` until cold-launch factory arms
    /// the mailbox (before special tuning).
    ///
    /// - Parameter scene: The scene that became active.
    /// - SeeAlso: ``RadioPlayerCoordinator/checkForPendingWidgetActions()``,
    ///   ``SharedPlayerManager/discardResidualPendingActionsAndArmMailboxForThisProcess()``
    func sceneDidBecomeActive(_ scene: UIScene) {
        #if DEBUG
        print("[SceneDelegate] sceneDidBecomeActive — unlock/active cycle")
        #endif

        // Coordinator drain via VC shim. Honesty gates: unarmed mailbox, pre-boot time,
        // termination sentinel, maxAge — not SceneDelegate policy.
        if let viewController = window?.rootViewController as? ViewController {
            viewController.checkForPendingWidgetActions()
        }

        // Privacy gate refresh before liveness/save so a widget re-added while backgrounded
        // can receive writes again. Fire-and-forget; save paths consult the refreshed flag.
        // LA ensure restores a missing card after deferred recreation / failed request, or
        // soft-reconciles language/visual when ownership is already non-nil.
        Task { @MainActor in
            await WidgetRefreshManager.shared.refreshHasActiveWidgets()
            await SharedPlayerManager.shared.recordWidgetLiveness()
            await SharedPlayerManager.shared.saveCurrentState()
            await RadioLiveActivityManager.shared.ensureInteractiveLiveActivityIfNeeded()
        }
    }

    /// Resign active (lock, interruption, etc.): session/widget hygiene only when **not**
    /// actively playing so background audio + lock-screen LA controls stay intact.
    ///
    /// - Parameter scene: The scene that will resign active.
    /// - SeeAlso: ``SharedPlayerManager/performSessionAndWidgetTeardown(includeFactoryReset:liveActivityTeardown:refreshWidgets:widgetVisualState:staleLiveness:)``
    func sceneWillResignActive(_ scene: UIScene) {
        #if DEBUG
        print("[SceneDelegate] sceneWillResignActive — lock/inactive cycle begin")
        #endif

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

    /// Entering foreground: second pending-drain opportunity + Live Activity foreground push.
    ///
    /// - Parameter scene: The scene entering the foreground.
    /// - SeeAlso: ``RadioLiveActivityManager/handleAppDidEnterForeground()``
    func sceneWillEnterForeground(_ scene: UIScene) {
        if let viewController = window?.rootViewController as? ViewController {
            viewController.checkForPendingWidgetActions()
        }

        // Push latest visual + metadata so Dynamic Island / Lock Screen controls match
        // current PlayerVisualState immediately.
        RadioLiveActivityManager.shared.handleAppDidEnterForeground()
    }

    /// Entering background: keep widget liveness/snapshot fresh; auto-start LA when playing.
    ///
    /// - Parameter scene: The scene entering the background.
    /// - SeeAlso: ``RadioLiveActivityManager/handleAppWillEnterBackground()``
    func sceneDidEnterBackground(_ scene: UIScene) {
        Task {
            await SharedPlayerManager.shared.recordWidgetLiveness()
            await SharedPlayerManager.shared.saveCurrentState()
        }

        // Documented auto-start path when audio is playing. Manager owns the Activity request.
        RadioLiveActivityManager.shared.handleAppWillEnterBackground()

        #if DEBUG
        print("[SceneDelegate] Saved state for widget on background + forwarded LA background handling")
        #endif
    }

    /// Opened via `lutheranradio://` from widgets, Control Center, or Live Activities.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url,
              url.scheme == "lutheranradio" else {
            return
        }

        // `widget-action` URLs carry actionId for deduplication and are dispatched first
        // (not via the general host switch).
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

        // Simple deep links (`play` / `pause` / `toggle` / `open` / `switch`).
        // `open` → resurrection check only on the handler; cold auto-play may still run
        // from ViewController's launch Task when sticky intent is absent.
        handleURLScheme(url, from: scene)
    }

    /// Dispatches `lutheranradio://` hosts for playback control and foregrounding.
    ///
    /// Common path after `widget-action` special cases. Prefer the originating `scene` for
    /// root VC lookup during early lifecycle or open events.
    ///
    /// - Parameters:
    ///   - url: The deep link URL.
    ///   - scene: Optional `UIScene` from the calling context (preferred for VC lookup).
    /// - SeeAlso: ``ParsedWidgetAction``, ``rootViewController(in:)``,
    ///   ``ViewController/handleOpenFromLiveActivity()``
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
            // VC + coordinator shim → ``SharedPlayerManager/userRequestedPlay()``.
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
            // Surfaces the app + resurrection check; does not itself request play.
            viewController.handleOpenFromLiveActivity()

        case "switch":
            // Expected: lutheranradio://switch?language=en (or ?param=...)
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

    /// Parsed `lutheranradio://widget-action` URL (action, actionId, optional parameter).
    ///
    /// Handled with priority in ``scene(_:openURLContexts:)`` because extension signaling
    /// needs actionId deduplication before the simple host switch.
    ///
    /// - SeeAlso: ``scene(_:openURLContexts:)``, ``ViewController/handleWidgetAction(action:parameter:actionId:)``
    private struct ParsedWidgetAction {
        let action: String
        let actionId: String
        let parameter: String?

        /// Parses required fields from a widget-action URL.
        /// - Returns: `nil` if host or mandatory query items are missing.
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

    /// Resolves the root ``ViewController`` that receives widget/URL scheme commands.
    ///
    /// Prefers the supplied scene's window (avoids races when `self.window` is stale during
    /// early open events). Falls back to ``window``.
    ///
    /// - Parameter scene: Scene associated with the current URL or lifecycle event.
    /// - Returns: Root ViewController when it is the expected type.
    /// - SeeAlso: ``handleURLScheme(_:from:)``
    private func rootViewController(in scene: UIScene? = nil) -> ViewController? {
        if let windowScene = scene as? UIWindowScene,
           let vc = windowScene.windows.first?.rootViewController as? ViewController {
            return vc
        }
        return window?.rootViewController as? ViewController
    }
}

