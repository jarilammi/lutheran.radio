//
//  SleepTimerGlassPopoverLayout.swift
//  Lutheran Radio
//
//  One layout correction for the sleep-timer `.confirmationDialog` glass popover.
//
//  UIKit hosts that dialog in `GlassPopoverContentViewRepresentable` at an
//  autoresizing width of 320. The alert content (`_UIAlertControllerPhoneTVMacView`)
//  still installs a required width equality at the phone content width, which is
//  wider than that host (window width minus phone margins). The solver breaks the
//  content width. That recovery rebuilds the glass host, so the first open can
//  install two platform views and stall on the glass color-plane pipeline.
//
//  While ``SleepTimerMenuButton`` is presenting, this type retargets that content
//  width to the host width before the solver runs. It does not set
//  `translatesAutoresizingMaskIntoConstraints` on the glass host, does not dismiss
//  the popover, and does not present a second privacy surface. Following the host
//  stops when `isPresented` becomes false, so the secondary privacy
//  `UIAlertController` (``.alert``, and only after
//  ``SleepTimerPrivacyClearPresentation``) keeps its own width.
//  ``CoordinatorAlertPresentationSettle`` still waits for leftover glass hosts
//  before that alert is presented.
//
//  The setter hook stays installed for the process. ``isFollowingHostWidth`` is
//  the gate: while it is false, the setter writes the proposed constant unchanged.
//
//  - SeeAlso: ``SleepTimerMenuButton``,
//    ``SleepTimerPrivacyClearPresentation``,
//    ``CoordinatorAlertPresentationSettle``,
//    ``ViewController/presentCoordinatorAlertAfterOutgoingPresentationSettles(_:)``,
//    docs/Widget-Presentation-Dataflow.md (Main-App Chrome Authority),
//    CODING_AGENT.md
//
//  Created by Jari Lammi on 11.10.2026.
//

import ObjectiveC
import UIKit

/// Retargets sleep-timer confirmation-dialog content width to the glass popover host.
///
/// - Important: Do not set `translatesAutoresizingMaskIntoConstraints` on the glass
///   host. Do not dismiss SwiftUI’s popover. Call ``stopFollowingHostWidth()`` before
///   the secondary privacy alert is built.
/// - SeeAlso: ``SleepTimerMenuButton``,
///   ``CoordinatorAlertPresentationSettle/isGlassPopoverPlatformHost(_:)``,
///   docs/Widget-Presentation-Dataflow.md (Main-App Chrome Authority),
///   CODING_AGENT.md
enum SleepTimerGlassPopoverLayout {

    /// Autoresizing width of `GlassPopoverContentViewRepresentable` when the host
    /// has not installed that constraint yet. Content wider than the host follows
    /// this until the host’s own autoresizing width can be read.
    static let fallbackHostWidth: CGFloat = 320

    /// Presentation gate for the constraint hooks.
    ///
    /// `true` only while the sleep-timer confirmation dialog is on screen.
    /// The secondary privacy alert is built after ``stopFollowingHostWidth()``.
    ///
    /// - Note: `nonisolated(unsafe)` because the ObjC constraint setter reads it
    ///   and the sleep-timer button writes it on the main actor. A torn read is
    ///   still a Bool gate. Layout that installs the 320-vs-content fight runs
    ///   on the main thread.
    // SAFETY: Main-actor writes from ``beginFollowingHostWidth()`` /
    // ``stopFollowingHostWidth()``. The setter hook only reads the flag, and only
    // mutates a constant after `Thread.isMainThread` plus `MainActor.assumeIsolated`.
    // No shared mutable layout state crosses actors.
    nonisolated(unsafe) static var isFollowingHostWidth = false

    /// Installs the process-wide hooks (once) and starts following the host width.
    ///
    /// Call from the moon-button action before `isPresented` becomes true, so the
    /// dialog’s first constraint assignment is already gated.
    ///
    /// - SeeAlso: ``stopFollowingHostWidth()``, ``SleepTimerMenuButton``
    @MainActor
    static func beginFollowingHostWidth() {
        installHooksIfNeeded()
        // SAFETY: Main-actor write of the presentation gate. The setter hook only reads it.
        unsafe isFollowingHostWidth = true
    }

    /// Stops following the host. Installed hooks stay in place and pass constants through.
    ///
    /// - SeeAlso: ``beginFollowingHostWidth()``
    @MainActor
    static func stopFollowingHostWidth() {
        // SAFETY: Same gate as ``beginFollowingHostWidth()``. Main-actor store.
        unsafe isFollowingHostWidth = false
    }

    /// Width the alert content should use inside the glass host.
    ///
    /// - Parameters:
    ///   - proposed: Required width constant UIKit is assigning.
    ///   - hostWidth: Glass-host autoresizing width, or ``fallbackHostWidth``.
    /// - Returns: `hostWidth` when `proposed` is wider than the host; otherwise
    ///   `proposed`. A content width that already fits is left alone.
    static func contentWidthFollowingHost(proposed: CGFloat, hostWidth: CGFloat) -> CGFloat {
        guard hostWidth > 1, proposed > hostWidth + 0.5 else { return proposed }
        return hostWidth
    }

    /// Constant to store for `constraint`, or `proposed` when this assignment is
    /// not the dialog content width.
    ///
    /// Skips the glass host’s own width (including its autoresizing mask), skips
    /// inequalities and non-required priorities, and skips any view that is not
    /// inside the glass host or an alert view that dialog is installing.
    ///
    /// - Parameters:
    ///   - constraint: Constraint whose constant is about to change or that is
    ///     about to become active.
    ///   - proposed: Value UIKit asked to store.
    /// - Returns: Host width, or `proposed` when the correction does not apply.
    /// - SeeAlso: ``contentWidthFollowingHost(proposed:hostWidth:)``
    @MainActor
    static func replacementWidthConstant(
        _ constraint: NSLayoutConstraint,
        proposed: CGFloat
    ) -> CGFloat {
        // SAFETY: Main-actor read of the presentation gate.
        guard unsafe isFollowingHostWidth else { return proposed }
        guard isRetargetableContentWidth(constraint, proposed: proposed) else { return proposed }
        // SAFETY: `firstItem` is `unowned(unsafe)`. The item is the view that
        // owns this constraint for this main-thread layout call.
        guard let view = unsafe constraint.firstItem as? UIView else { return proposed }
        if CoordinatorAlertPresentationSettle.isGlassPopoverPlatformHost(view) {
            return proposed
        }
        guard viewBelongsToSleepTimerGlassContent(view) else { return proposed }
        return contentWidthFollowingHost(
            proposed: proposed,
            hostWidth: resolvedHostWidth(near: view)
        )
    }

    /// Rewrites already-installed content widths on `view` after it joins a host.
    ///
    /// `superview` is already the new parent when UIKit calls `didMoveToSuperview`.
    /// This runs before UIKit’s own `didMoveToSuperview`, which may layout.
    ///
    /// - Parameter view: View that just moved, or a view whose constraints were
    ///   installed before it joined the glass host.
    /// - SeeAlso: ``replacementWidthConstant(_:proposed:)``
    @MainActor
    static func rewriteContentWidthConstraints(affecting view: UIView) {
        // SAFETY: Main-actor reads of the presentation gate and the rewrite guard.
        guard unsafe isFollowingHostWidth, unsafe !isRewriting else { return }
        guard !CoordinatorAlertPresentationSettle.isGlassPopoverPlatformHost(view) else { return }
        guard viewBelongsToSleepTimerGlassContent(view) else { return }
        // SAFETY: Main-actor store. The setter hook does not read this flag.
        unsafe isRewriting = true
        defer { unsafe isRewriting = false }
        applyReplacementWidths(on: view, limitedToFirstItem: nil)
        if let superview = view.superview {
            applyReplacementWidths(on: superview, limitedToFirstItem: view)
        }
    }

    // MARK: - Host walk

    /// Whether `view` is dialog content whose width must follow the popover.
    ///
    /// True for a descendant of the glass host, and for `_UIAlertController` /
    /// `PhoneTVMac` views that are not in the host yet (the width is assigned
    /// before the popover inserts them). Ordinary player views are false, so a
    /// screen-width constraint outside the dialog is unchanged while content width
    /// is following the host.
    @MainActor
    static func viewBelongsToSleepTimerGlassContent(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let node = current {
            if CoordinatorAlertPresentationSettle.isGlassPopoverPlatformHost(node) {
                return true
            }
            let name = NSStringFromClass(type(of: node))
            if name.contains("PhoneTVMac") || name.contains("UIAlertController") {
                return true
            }
            current = node.superview
        }
        return false
    }

    /// Glass-host autoresizing width, otherwise ``fallbackHostWidth``.
    ///
    /// Bounds are not consulted. The host’s bounds can still be the window width
    /// on the frame the autoresizing constraint becomes the real 320.
    @MainActor
    static func resolvedHostWidth(near view: UIView) -> CGFloat {
        var current: UIView? = view
        while let node = current {
            if CoordinatorAlertPresentationSettle.isGlassPopoverPlatformHost(node) {
                if let width = autoresizingWidth(on: node) {
                    return width
                }
                return fallbackHostWidth
            }
            current = node.superview
        }
        return fallbackHostWidth
    }

    // MARK: - Hooks

    /// Re-entrancy guard for ``rewriteContentWidthConstraints(affecting:)``.
    /// Setting `constant` from that walk re-enters the setter hook, which must
    /// not start another walk.
    // SAFETY: Written only on the main actor inside ``rewriteContentWidthConstraints(affecting:)``.
    // The setter hook does not read it. Paired with ``isFollowingHostWidth``.
    nonisolated(unsafe) private static var isRewriting = false

    private static let installHooks: Void = {
        exchange(
            NSLayoutConstraint.self,
            #selector(setter: NSLayoutConstraint.constant),
            #selector(NSLayoutConstraint.lutheran_sleepTimerSetConstant(_:))
        )
        exchange(
            NSLayoutConstraint.self,
            #selector(setter: NSLayoutConstraint.isActive),
            #selector(NSLayoutConstraint.lutheran_sleepTimerSetActive(_:))
        )
        exchange(
            UIView.self,
            #selector(UIView.didMoveToSuperview),
            #selector(UIView.lutheran_sleepTimerDidMoveToSuperview)
        )
    }()

    @MainActor
    private static func installHooksIfNeeded() {
        _ = installHooks
    }

    private static func exchange(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
        // SAFETY: One-time `method_exchangeImplementations`. `Method` is an
        // opaque C pointer. Each replacement calls the exchanged selector, so
        // the hook does not recurse. Missing selectors fail closed in Debug.
        guard let originalMethod = unsafe class_getInstanceMethod(cls, original),
              let replacementMethod = unsafe class_getInstanceMethod(cls, replacement) else {
            assertionFailure("Sleep-timer glass layout hook missing \(NSStringFromSelector(original))")
            return
        }
        unsafe method_exchangeImplementations(originalMethod, replacementMethod)
    }

    @MainActor
    private static func isRetargetableContentWidth(
        _ constraint: NSLayoutConstraint,
        proposed: CGFloat
    ) -> Bool {
        guard proposed > fallbackHostWidth + 0.5 else { return false }
        guard constraint.firstAttribute == .width else { return false }
        guard constraint.relation == .equal else { return false }
        // SAFETY: `secondItem` is `unowned(unsafe)`. Nil means a constant width.
        guard unsafe constraint.secondItem == nil else { return false }
        guard constraint.priority == .required else { return false }
        guard !isAutoresizingMaskConstraint(constraint) else { return false }
        return true
    }

    /// `NSAutoresizingMaskLayoutConstraint` is not a public type. The dump names
    /// it; skipping that class leaves the glass host’s mask alone.
    private static func isAutoresizingMaskConstraint(_ constraint: NSLayoutConstraint) -> Bool {
        NSStringFromClass(type(of: constraint)).contains("NSAutoresizingMaskLayoutConstraint")
    }

    @MainActor
    private static func autoresizingWidth(on view: UIView) -> CGFloat? {
        for constraint in view.constraints {
            guard isAutoresizingMaskConstraint(constraint),
                  constraint.firstAttribute == .width,
                  constraint.relation == .equal,
                  constraint.constant > 1
            else { continue }
            return constraint.constant
        }
        return nil
    }

    @MainActor
    private static func applyReplacementWidths(
        on owner: UIView,
        limitedToFirstItem item: UIView?
    ) {
        for constraint in owner.constraints {
            // SAFETY: `firstItem` is `unowned(unsafe)`, same as the setter hook.
            if let item, unsafe constraint.firstItem as? UIView !== item {
                continue
            }
            let replacement = replacementWidthConstant(constraint, proposed: constraint.constant)
            if abs(replacement - constraint.constant) > 0.5 {
                constraint.constant = replacement
            }
        }
    }
}

extension NSLayoutConstraint {

    /// Setter hook. While ``SleepTimerGlassPopoverLayout/isFollowingHostWidth`` is
    /// true on the main thread, a dialog content width wider than the glass host
    /// is stored as the host width. Otherwise this is the original setter.
    ///
    /// - Parameter constant: Width or other constant UIKit is assigning.
    @objc nonisolated func lutheran_sleepTimerSetConstant(_ constant: CGFloat) {
        let adjusted = SleepTimerGlassPopoverLayout.adjustedConstantWhileFollowingHost(self, proposed: constant)
        lutheran_sleepTimerSetConstant(adjusted)
    }

    /// Activation hook. Clamps before the engine accepts a required width that was
    /// stored before the view joined the glass host.
    ///
    /// - Parameter active: `true` when the constraint is becoming active.
    @objc nonisolated func lutheran_sleepTimerSetActive(_ active: Bool) {
        if active {
            SleepTimerGlassPopoverLayout.clampBeforeActivationWhileFollowingHost(self)
        }
        lutheran_sleepTimerSetActive(active)
    }
}

extension UIView {

    /// Superview hook. Rewrites content widths before UIKit’s implementation
    /// layouts the new parent.
    @objc func lutheran_sleepTimerDidMoveToSuperview() {
        // SAFETY: Read of the presentation gate from the exchanged UIKit hook.
        if unsafe SleepTimerGlassPopoverLayout.isFollowingHostWidth, Thread.isMainThread {
            MainActor.assumeIsolated {
                SleepTimerGlassPopoverLayout.rewriteContentWidthConstraints(affecting: self)
            }
        }
        lutheran_sleepTimerDidMoveToSuperview()
    }
}

extension SleepTimerGlassPopoverLayout {

    /// Main-thread gate around ``replacementWidthConstant(_:proposed:)``.
    ///
    /// Off the main thread the proposed constant is unchanged. UIKit layout that
    /// installs the dialog width runs on the main thread.
    nonisolated static func adjustedConstantWhileFollowingHost(
        _ constraint: NSLayoutConstraint,
        proposed: CGFloat
    ) -> CGFloat {
        // SAFETY: Read of the presentation gate. Off the main thread this is a pass-through.
        guard unsafe isFollowingHostWidth, Thread.isMainThread else { return proposed }
        return MainActor.assumeIsolated {
            replacementWidthConstant(constraint, proposed: proposed)
        }
    }

    /// Main-thread gate that stores a corrected constant before activation.
    nonisolated static func clampBeforeActivationWhileFollowingHost(_ constraint: NSLayoutConstraint) {
        // SAFETY: Read of the presentation gate. Off the main thread activation is unchanged.
        guard unsafe isFollowingHostWidth, Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            let replacement = replacementWidthConstant(constraint, proposed: constraint.constant)
            if abs(replacement - constraint.constant) > 0.5 {
                constraint.constant = replacement
            }
        }
    }
}
