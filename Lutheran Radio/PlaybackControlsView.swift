//
//  PlaybackControlsView.swift
//  Lutheran Radio
//
//  Pure SwiftUI playback controls row with play/pause button and sleep timer.
//
//  Play / Pause button:
//  - Visual appearance (system image + tint) is driven by the narrow `controlPresentation`
//    value received from the caller.
//  - Semantic state (whether audio is actively playing) is supplied explicitly as
//    `isActivelyPlaying` for action routing, `.symbolEffect`, accessibility, and
//    whether an in-app pause press may bump the local sensory-feedback token.
//  - VoiceOver label is short and state-dependent (`accessibility_label_play` /
//    `accessibility_label_pause`); the longer toggle instruction stays on the hint
//    and the named `toggle_playback` custom action.
//  - Pause-only press chrome: `.sensoryFeedback(.selection)` on a local incrementing
//    token. Play tap has no haptic here. Audible-start confirmation is an
//    orchestration event on `HapticPlaybackPolicy` + `HapticsController` via
//    `RadioPlayerCoordinator.handleStatusChange` (one `.light` UIImpact per
//    audible start, latched; shipped 987ebd5). Privacy-clear stays `.heavy`.
//  - The token is *not* `isActivelyPlaying`. Language switch (playing → Connecting
//    → playing), stream failure, thermal, and security lock also leave `.playing`;
//    binding SwiftUI feedback to that flag would double-buzz with confirmation.
//    `PlayerVisualState.isActivelyPlaying` is `self == .playing` only — Connecting
//    keeps a play affordance and is not “user paused”.
//  - This is press chrome, not a second haptic owner. Do not call
//    `HapticsController` from this view. Do not add play-tap / optimistic-play
//    feedback. Widget, Live Activity, Control Center, keyboard, and remote
//    commands are not this surface.
//
//  Sleep timer:
//  - Sole presentation is a native `.confirmationDialog` on ``SleepTimerMenuButton``
//    with duration presets, conditional "Cancel timer", and the destructive
//    "Clear local state" privacy action.
//  - The menu button is equatable on cancel-timer availability and the minute
//    accessibility string. Action closures are left out of that comparison: the
//    parent reallocates them on every status paint, and comparing them rebuilds
//    the glass popover (a second `GlassPopoverContentViewRepresentable`).
//  - While the dialog is presented, ``SleepTimerGlassPopoverLayout`` retargets
//    alert content that requires a width wider than the glass host so the content
//    follows the popover. It does not set `translatesAutoresizingMaskIntoConstraints`
//    on the host.
//  - Accessibility value (when active) comes from the pre-derived
//    `sleepTimerAccessibilityValue` (derived on the model, not inside the view body).
//
//  The view receives only narrow value types (`controlPresentation`, timer values,
//  `statusPresentation`) + action closures. No `PlayerViewModel`, no
//  `HapticsController`, no coordinator call. All complex timing, orchestration,
//  audible-start / privacy-clear impacts, and privacy confirmation logic remain
//  in `RadioPlayerCoordinator` / `HapticPlaybackPolicy`.
//
//  Created by Jari Lammi on 13.6.2026.
//

import SwiftUI
import WidgetSurface

/// Pure SwiftUI row for the main player controls.
///
/// Receives narrow value inputs for everything it renders:
/// - `controlPresentation`: glyph and tint for the play/pause button (from `PlayerControlPresentation`).
/// - `isActivelyPlaying`: semantic flag used for action routing, `.symbolEffect` key,
///   accessibility, and whether a pause press may bump the local sensory-feedback token.
/// - `sleepTimerRemaining` + `sleepTimerAccessibilityValue`: timer state and pre-derived a11y string.
///
/// Actions are supplied as closures so the view has no knowledge of `PlayerViewModel`.
/// Status is rendered via the already-narrow `StatusPill`.
///
/// This completes the narrow-input contract for the control axis (parallel to
/// how `StatusPill` receives only `PlayerStatusPresentation` and `NowPlayingMetadataView`
/// receives only `NowPlayingDisplayModel`).
///
/// The pattern (leaf views receive narrow value types + closures, never the full
/// model) is now consistent across the main player and the widget / Live Activity
/// leaf views (`WidgetMetadataRegion`, button builders in Dynamic Island, etc.).
///
/// Pause press chrome (this view only):
/// - `.sensoryFeedback(.selection)` on a local incrementing token, shared by the
///   `Button` action and the VoiceOver / Switch Control `toggle_playback` action.
/// - Pause-only because `HapticPlaybackPolicy` already confirms audible start
///   (987ebd5). A play-tap haptic would double-buzz on fast resume.
/// - Local token, not `isActivelyPlaying`: leaving `.playing` is not “user paused”
///   (`PlayerVisualState.isActivelyPlaying` is `self == .playing` only).
/// - Not a replacement for `HapticPlaybackPolicy` / `HapticsController`.
///
/// Accessibility (play / pause):
/// - Label is short and state-dependent: `accessibility_label_play` when idle,
///   `accessibility_label_pause` when actively playing (revives the catalog key that
///   was orphaned when SwiftUI used the longer `accessibility_label_play_pause` as the label).
/// - Hint remains `accessibility_hint_play_pause` (toggle instruction).
/// - Named custom action `toggle_playback` keeps the discoverable rotor action for
///   VoiceOver / Switch Control (same revival pattern as the volume cluster on
///   `VolumeAndAirPlayRow`).
///
/// Sleep timer presentation:
/// - Timer countdown and accessibility value come in pre-computed.
/// - The moon button tap triggers a native `.confirmationDialog` on
///   ``SleepTimerMenuButton`` offering the presets, conditional Cancel, and the
///   "Clear local state" privacy action. Equatable inputs omit action closures so
///   a status paint does not build a second glass host.
/// - While that dialog is presented, ``SleepTimerGlassPopoverLayout`` makes alert
///   content follow the glass host width.
/// - The destructive privacy row only arms ``SleepTimerPrivacyClearPresentation``;
///   `onClearLocalStateTapped` runs after the dialog’s `isPresented` binding is false
///   so the secondary `UIAlertController` is not built while glass is still up.
///   The width correction stops on that same transition.
/// - All complex orchestration, countdown, and privacy logic remains in `RadioPlayerCoordinator`.
///
/// - Precondition: The values must be driven by the coordinator (or mock for previews/tests).
/// - Note: The privacy clear path does a secondary confirmation via UIAlert before acting.
///   That alert is invoked only after this `.confirmationDialog` `isPresented` is false
///   (``SleepTimerPrivacyClearPresentation``) and after leftover glass popover hosts
///   have left the window scene
///   (``ViewController/presentCoordinatorAlertAfterOutgoingPresentationSettles(_:)``).
/// - SeeAlso: ``PlayerViewModel``, ``PlayerControlPresentation``, ``PlayerStatusPresentation``,
///   `StatusPill`, `NowPlayingDisplayModel`, `RadioPlayerCoordinator`, `VolumeAndAirPlayRow`,
///   ``HapticPlaybackPolicy``, ``HapticsController``,
///   ``RadioPlayerCoordinator/handleStatusChange(_:reasonKey:)``,
///   ``PlaybackPausePressFeedback``,
///   ``SleepTimerMenuButton``,
///   ``SleepTimerPrivacyClearPresentation``,
///   ``SleepTimerGlassPopoverLayout``,
///   ``CoordinatorAlertPresentationSettle``,
///   ``PlayerVisualState/isActivelyPlaying``,
///   CODING_AGENT.md (narrow inputs for separate View types + cached derived values),
///   <doc:Architecture>.
struct PlaybackControlsView: View {

    let controlPresentation: PlayerControlPresentation
    let isActivelyPlaying: Bool
    let sleepTimerRemaining: TimeInterval?
    let sleepTimerAccessibilityValue: String?
    let statusPresentation: PlayerStatusPresentation

    // Action closures supplied by the composition root (RadioPlayerView).
    // The view never reaches back into a model for behavior.
    var onPlay: () -> Void = {}
    var onPause: () -> Void = {}
    var onSelectSleepTimer: ((Int) -> Void)? = nil
    var onCancelSleepTimer: (() -> Void)? = nil

    /// Optional closure for the privacy "Clear local state" destructive action.
    /// When provided (wired from RadioPlayerView / ViewController), the destructive
    /// row arms a pending flag; this closure runs after the dialog `isPresented`
    /// binding is false and reaches `RadioPlayerCoordinator.confirmAndClearLocalState()`.
    /// Always shown after the presets (regardless of active timer state).
    ///
    /// - Note: The action builds a secondary confirmation `UIAlertController`. This
    ///   view does **not** invoke the closure from the destructive-row action.
    ///   ``SleepTimerPrivacyClearPresentation`` arms a pending flag; the closure
    ///   runs only after this `.confirmationDialog` `isPresented` is false. The host
    ///   then waits for leftover `GlassPopoverContentViewRepresentable` hosts to
    ///   leave the scene
    ///   (``ViewController/presentCoordinatorAlertAfterOutgoingPresentationSettles(_:)``).
    ///   The clear performs `SharedPlayerManager.clearAllLocalState()` and related resets.
    /// - SeeAlso: `RadioPlayerCoordinator.confirmAndClearLocalState`, `SharedPlayerManager.clearAllLocalState`,
    ///   ``SleepTimerPrivacyClearPresentation``,
    ///   ``ViewController/presentCoordinatorAlertAfterOutgoingPresentationSettles(_:)``,
    ///   CODING_AGENT.md (Single Source of Truth Principles).
    var onClearLocalStateTapped: (() -> Void)? = nil

    /// Equatable trigger for pause-only `.sensoryFeedback`. Incremented only by
    /// ``requestPauseFromControl()`` when ``PlaybackPausePressFeedback`` allows.
    /// Never bound to `isActivelyPlaying` — that flag also falls on language
    /// switch, failure, thermal, and security lock (then confirmation would fire again).
    @State private var pausePressFeedbackToken = 0

    var body: some View {
        HStack(spacing: 20) {
            // Play / Pause button
            // Glyph and tint come from the narrow controlPresentation input.
            // Action routing, symbolEffect value, and accessibility labels use the
            // explicit semantic `isActivelyPlaying` flag.
            // Pause haptic: local token + `.selection` (different feel from the
            // coordinator's `.light` audible-start UIImpact). Play tap has no
            // sensoryFeedback — confirmation already owns audible start.
            Button {
                if isActivelyPlaying {
                    requestPauseFromControl()
                } else {
                    onPlay()
                }
            } label: {
                Image(systemName: controlPresentation.systemImage)
                    .font(.system(size: 24, weight: .bold))
                    .frame(width: 50, height: 50)
                    .foregroundStyle(controlPresentation.tint)
                    .symbolEffect(.bounce, value: isActivelyPlaying)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.selection, trigger: pausePressFeedbackToken)
            .accessibilityIdentifier("playPauseButton")
            .accessibilityHint(String(localized: "accessibility_hint_play_pause", table: "Localizable"))
            // State-dependent short labels: "Play" when idle, "Pause" when actively playing.
            // Revives `accessibility_label_pause` (orphaned when the SwiftUI migration used the
            // longer `accessibility_label_play_pause` string as the label). The long toggle
            // instruction remains on the hint; the named `toggle_playback` action below is
            // the discoverable rotor entry for VoiceOver / Switch Control.
            .accessibilityLabel(
                isActivelyPlaying
                    ? String(localized: "accessibility_label_pause", table: "Localizable")
                    : String(localized: "accessibility_label_play", table: "Localizable")
            )
            // Revives the stale "toggle_playback" string as an explicit accessibility action name.
            // The button's default tap behavior already works; this named action provides a clear
            // discoverable action for VoiceOver / Switch Control users. Matches the old UIKit
            // custom action intent without changing observable behavior.
            // Pause branch shares ``requestPauseFromControl()`` with the Button so
            // VoiceOver / Switch Control cannot drift from the press-chrome path.
            .accessibilityAction(named: String(localized: "toggle_playback", table: "Localizable")) {
                if isActivelyPlaying {
                    requestPauseFromControl()
                } else {
                    onPlay()
                }
            }

            // Sleep timer: ``SleepTimerMenuButton`` is the sole `.confirmationDialog`.
            // Equatable so a status / metadata paint does not build a second glass host.
            // Width correction: ``SleepTimerGlassPopoverLayout`` while the dialog is up.
            SleepTimerMenuButton(
                sleepTimerRemaining: sleepTimerRemaining,
                sleepTimerAccessibilityValue: sleepTimerAccessibilityValue,
                onSelectSleepTimer: onSelectSleepTimer,
                onCancelSleepTimer: onCancelSleepTimer,
                onClearLocalStateTapped: onClearLocalStateTapped
            )
            .equatable()

            // Status pill consumes the narrow cached presentation passed in.
            // Invalidation boundary is limited to statusPresentation changes only.
            StatusPill(presentation: statusPresentation)
        }
        .frame(height: 50)
    }

    /// Shared pause request from the `Button` action and the `toggle_playback`
    /// accessibility action.
    ///
    /// Increments ``pausePressFeedbackToken`` only when
    /// ``PlaybackPausePressFeedback/shouldBumpPausePressToken(isActivelyPlaying:isUITestMode:isLowPowerModeEnabled:)``
    /// is true, then calls `onPause()`. Play never enters this path.
    ///
    /// - SeeAlso: ``HapticPlaybackPolicy``, ``HapticsController``,
    ///   ``RadioPlayerCoordinator/handleStatusChange(_:reasonKey:)``,
    ///   CODING_AGENT.md
    private func requestPauseFromControl() {
        guard isActivelyPlaying else { return }
        if PlaybackPausePressFeedback.shouldBumpPausePressToken(
            isActivelyPlaying: isActivelyPlaying,
            isUITestMode: SharedPlayerManager.isRunningInUITestMode,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        ) {
            pausePressFeedbackToken += 1
        }
        onPause()
    }
}

// MARK: - Sleep-timer menu (sole confirmationDialog)

/// Moon button and the only sleep-timer `.confirmationDialog`.
///
/// Equatable inputs are cancel-timer availability and the minute accessibility
/// string. ``PlaybackControlsView`` reallocates action closures on every status
/// paint. Putting those closures in `==` would treat the button as changed and
/// SwiftUI would build a second `GlassPopoverContentViewRepresentable` while the
/// dialog is up. The closures capture the stable view model and host for the
/// life of the screen; the first body that runs keeps calling them.
///
/// The moon-button action starts ``SleepTimerGlassPopoverLayout`` following the
/// host width before `isPresented` becomes true. ``stopFollowingHostWidth()``
/// runs when the binding goes false, before ``onClearLocalStateTapped`` builds
/// the secondary privacy alert.
///
/// - SeeAlso: ``PlaybackControlsView``,
///   ``SleepTimerGlassPopoverLayout``,
///   ``SleepTimerPrivacyClearPresentation``,
///   docs/Widget-Presentation-Dataflow.md (Main-App Chrome Authority),
///   CODING_AGENT.md
struct SleepTimerMenuButton: View, Equatable {

    /// Countdown input for ``==``. Nonisolated so equality stays off the main
    /// actor: ``View`` isolation would otherwise make the `Equatable` witness
    /// cross actors. Minute ticks of this value do not participate in ``==``.
    nonisolated let sleepTimerRemaining: TimeInterval?
    /// Minute-bucketed VoiceOver string. Same isolation reason as
    /// ``sleepTimerRemaining``.
    nonisolated let sleepTimerAccessibilityValue: String?
    var onSelectSleepTimer: ((Int) -> Void)?
    var onCancelSleepTimer: (() -> Void)?
    var onClearLocalStateTapped: (() -> Void)?

    /// Cancel-timer row is present only while a countdown is active.
    /// Minute ticks inside the same spoken accessibility string do not flip this.
    nonisolated var cancelTimerIsAvailable: Bool {
        (sleepTimerRemaining ?? 0) > 0
    }

    /// Ignores action closures. Those are reallocated on every status paint.
    nonisolated static func == (lhs: SleepTimerMenuButton, rhs: SleepTimerMenuButton) -> Bool {
        lhs.cancelTimerIsAvailable == rhs.cancelTimerIsAvailable
            && lhs.sleepTimerAccessibilityValue == rhs.sleepTimerAccessibilityValue
    }

    @State private var isShowingSleepTimerDialog = false
    @State private var pendingPrivacyClearConfirm = false

    var body: some View {
        Button {
            // Arm before SwiftUI presents, so the first content-width assignment
            // is already gated. ``SleepTimerGlassPopoverLayout``.
            SleepTimerGlassPopoverLayout.beginFollowingHostWidth()
            isShowingSleepTimerDialog = true
        } label: {
            Image(systemName: cancelTimerIsAvailable ? "moon.zzz.fill" : "moon.zzz")
                .font(.system(size: 22, weight: .medium))
                .frame(width: 44, height: 44)
                .foregroundStyle(cancelTimerIsAvailable ? Color.indigo : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "accessibility_label_sleep_timer", table: "Localizable"))
        .accessibilityHint(String(localized: "accessibility_hint_sleep_timer", table: "Localizable"))
        // Pre-derived minute string. Empty when no timer is active.
        .accessibilityValue(sleepTimerAccessibilityValue ?? "")
        .confirmationDialog(
            String(localized: "sleep_timer_sheet_title", table: "Localizable"),
            isPresented: $isShowingSleepTimerDialog,
            titleVisibility: .visible
        ) {
            Button(String(localized: "sleep_timer_preset_15_min", table: "Localizable")) {
                onSelectSleepTimer?(15)
            }
            Button(String(localized: "sleep_timer_preset_30_min", table: "Localizable")) {
                onSelectSleepTimer?(30)
            }
            Button(String(localized: "sleep_timer_preset_45_min", table: "Localizable")) {
                onSelectSleepTimer?(45)
            }
            Button(String(localized: "sleep_timer_preset_60_min", table: "Localizable")) {
                onSelectSleepTimer?(60)
            }

            if cancelTimerIsAvailable {
                Button(
                    String(localized: "sleep_timer_cancel_timer", table: "Localizable"),
                    role: .destructive
                ) {
                    onCancelSleepTimer?()
                }
            }

            // Pending confirm only. Invoke onClearLocalStateTapped after isPresented
            // is false (SleepTimerPrivacyClearPresentation). The width correction
            // stops on that transition. The host then waits for leftover glass hosts.
            // - SeeAlso: SleepTimerPrivacyClearPresentation,
            //   SleepTimerGlassPopoverLayout,
            //   ViewController.presentCoordinatorAlertAfterOutgoingPresentationSettles,
            //   CODING_AGENT.md.
            Button(
                String(localized: "clear_local_state_title", table: "Localizable"),
                role: .destructive
            ) {
                armPrivacyClearConfirmAfterDialogDismisses()
            }
        }
        .onChange(of: isShowingSleepTimerDialog) { _, isShowing in
            if !isShowing {
                SleepTimerGlassPopoverLayout.stopFollowingHostWidth()
            }
            presentPendingPrivacyClearConfirmIfReady(dialogIsPresented: isShowing)
        }
    }

    /// Arms the privacy-clear confirm and invokes it immediately only if SwiftUI
    /// has already flipped the confirmationDialog `isPresented` binding to false.
    ///
    /// Otherwise ``presentPendingPrivacyClearConfirmIfReady(dialogIsPresented:)``
    /// runs from `.onChange` when the dialog finishes dismissing.
    ///
    /// - SeeAlso: ``SleepTimerPrivacyClearPresentation``
    private func armPrivacyClearConfirmAfterDialogDismisses() {
        pendingPrivacyClearConfirm = true
        presentPendingPrivacyClearConfirmIfReady(dialogIsPresented: isShowingSleepTimerDialog)
    }

    /// Invokes `onClearLocalStateTapped` when a privacy confirm is pending and the
    /// sleep-timer confirmationDialog is no longer presented.
    ///
    /// Stops ``SleepTimerGlassPopoverLayout`` following the host before the closure
    /// so the secondary alert’s own width is not retargeted to the glass host.
    ///
    /// - Parameter dialogIsPresented: Current `isShowingSleepTimerDialog` value.
    /// - SeeAlso: ``SleepTimerPrivacyClearPresentation/shouldInvokePrivacyClearConfirm(dialogIsPresented:pendingPrivacyConfirm:)``,
    ///   ``SleepTimerGlassPopoverLayout/stopFollowingHostWidth()``
    private func presentPendingPrivacyClearConfirmIfReady(dialogIsPresented: Bool) {
        guard SleepTimerPrivacyClearPresentation.shouldInvokePrivacyClearConfirm(
            dialogIsPresented: dialogIsPresented,
            pendingPrivacyConfirm: pendingPrivacyClearConfirm
        ) else {
            return
        }
        pendingPrivacyClearConfirm = false
        SleepTimerGlassPopoverLayout.stopFollowingHostWidth()
        onClearLocalStateTapped?()
    }
}

// MARK: - Pause press feedback policy (in-app control only)

/// Whether an explicit in-app pause press should increment the SwiftUI
/// `.sensoryFeedback` trigger token.
///
/// Pause-only: audible-start confirmation already lives on
/// ``HapticPlaybackPolicy`` + ``HapticsController`` via
/// ``RadioPlayerCoordinator/handleStatusChange(_:reasonKey:)`` (one `.light`
/// `UIImpactFeedbackGenerator` per audible start, latched). Binding
/// `.sensoryFeedback` to `isActivelyPlaying` would also fire on language
/// switch, stream failure, thermal, and security lock — then confirmation
/// would fire again. `PlayerVisualState.isActivelyPlaying` is
/// `self == .playing` only; Connecting keeps a play affordance and is not
/// “user paused”.
///
/// This is not a replacement for ``HapticPlaybackPolicy``. The view stays a
/// narrow-input leaf: it reads UITestMode / Low Power Mode the same way
/// ``HapticsController/playHapticFeedback(style:)`` does, and never calls
/// the controller.
///
/// - SeeAlso: ``PlaybackControlsView``, ``HapticPlaybackPolicy``,
///   ``HapticsController``,
///   ``RadioPlayerCoordinator/handleStatusChange(_:reasonKey:)``,
///   ``PlayerVisualState/isActivelyPlaying``,
///   ``SharedPlayerManager/isRunningInUITestMode``,
///   CODING_AGENT.md
enum PlaybackPausePressFeedback {

    /// Whether the local pause-press token should increment.
    ///
    /// - Parameters:
    ///   - isActivelyPlaying: `PlayerVisualState.isActivelyPlaying` immediately
    ///     before `onPause()`. Must be `true` (audio flowing); Connecting is false.
    ///   - isUITestMode: ``SharedPlayerManager/isRunningInUITestMode``.
    ///   - isLowPowerModeEnabled: `ProcessInfo.processInfo.isLowPowerModeEnabled`.
    /// - Returns: `true` only for an explicit pause while audio is flowing and
    ///   neither UITestMode nor Low Power Mode is on.
    /// - Note: SwiftUI `.sensoryFeedback` still respects system haptic settings.
    ///   The Low Power skip matches ``HapticsController`` so pause cannot
    ///   out-buzz play confirmation when the coordinator is also silent.
    /// - SeeAlso: ``HapticPlaybackPolicy``, ``HapticsController``,
    ///   ``RadioPlayerCoordinator/handleStatusChange(_:reasonKey:)``,
    ///   CODING_AGENT.md
    static func shouldBumpPausePressToken(
        isActivelyPlaying: Bool,
        isUITestMode: Bool,
        isLowPowerModeEnabled: Bool
    ) -> Bool {
        isActivelyPlaying && !isUITestMode && !isLowPowerModeEnabled
    }
}

// MARK: - Sleep-timer privacy-clear present sequencing

/// When the sleep-timer `.confirmationDialog` may invoke the privacy-clear coordinator.
///
/// The destructive "Clear local state" row must not call `onClearLocalStateTapped`
/// while the dialog is still `isPresented`. That action builds a secondary
/// `UIAlertController`; presenting it during the dialog action races iOS 26+
/// `GlassPopoverContentViewRepresentable` (autoresizing width 320) against
/// `_UIAlertControllerPhoneTVMacView` content that is wider than that host.
/// The row only arms a pending flag; the coordinator runs after `isPresented`
/// is false. ``SleepTimerGlassPopoverLayout`` has already stopped following the
/// host by then.
/// The host then waits for leftover glass hosts to leave the window scene
/// before `present`.
///
/// This is present-timing only. Do not disable the confirmationDialog. Do not
/// invent a second privacy surface.
///
/// - SeeAlso: ``PlaybackControlsView``,
///   ``SleepTimerMenuButton``,
///   ``SleepTimerGlassPopoverLayout``,
///   ``CoordinatorAlertPresentationSettle``,
///   ``ViewController/presentCoordinatorAlertAfterOutgoingPresentationSettles(_:)``,
///   ``RadioPlayerCoordinator/confirmAndClearLocalState()``,
///   docs/Widget-Presentation-Dataflow.md (Main-App Chrome Authority),
///   CODING_AGENT.md
enum SleepTimerPrivacyClearPresentation {

    /// Whether `onClearLocalStateTapped` may run now.
    ///
    /// - Parameters:
    ///   - dialogIsPresented: `PlaybackControlsView` sleep-timer confirmationDialog
    ///     `isPresented` binding.
    ///   - pendingPrivacyConfirm: Armed by the destructive row; not yet consumed.
    /// - Returns: `true` only when a confirm is pending **and** the dialog has
    ///   already dismissed. Presenting while `dialogIsPresented` is true overlaps
    ///   the glass host (autoresizing width 320) with a wider alert content width.
    /// - SeeAlso: ``CoordinatorAlertPresentationSettle/canPresentCoordinatorAlert(outgoingPresentedViewController:sceneContainsGlassPopoverHost:)``
    static func shouldInvokePrivacyClearConfirm(
        dialogIsPresented: Bool,
        pendingPrivacyConfirm: Bool
    ) -> Bool {
        pendingPrivacyConfirm && !dialogIsPresented
    }
}

// MARK: - StatusPill (narrow-input leaf)

/// Dedicated pill view that renders player status using the minimal `PlayerStatusPresentation`.
///
/// Takes only the presentation value type (Equatable). This creates an explicit
/// invalidation boundary: the pill only re-renders when the presented colors/text change,
/// independent of other view model properties (metadata, timer, stream index, etc.).
///
/// Example consumption (in a parent that still needs broader state for controls):
/// ```swift
/// StatusPill(presentation: viewModel.statusPresentation)
/// ```
///
/// - SeeAlso: ``PlayerStatusPresentation``, ``PlayerViewModel/statusPresentation``,
///   ``PlayerVisualState/makeStatusPresentation()``, CODING_AGENT.md (value types + narrow inputs).
struct StatusPill: View {
    let presentation: PlayerStatusPresentation

    var body: some View {
        Text(presentation.text)
            .font(.body)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minWidth: 120, maxWidth: 0.4 * 360)
            .background(presentation.background)
            .foregroundStyle(presentation.foreground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .accessibilityLabel(presentation.text)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Controls - Playing") {
    let vm = PlayerViewModel.makeMock(visualState: .playing)
    PlaybackControlsView(
        controlPresentation: vm.controlPresentation,
        isActivelyPlaying: vm.isActivelyPlaying,
        sleepTimerRemaining: vm.sleepTimerRemaining,
        sleepTimerAccessibilityValue: vm.sleepTimerAccessibilityValue,
        statusPresentation: vm.statusPresentation,
        onPlay: vm.play,
        onPause: vm.pause,
        onSelectSleepTimer: { _ in },
        onCancelSleepTimer: {}
    )
    .padding()
}

#Preview("Controls - Connecting") {
    let vm = PlayerViewModel.makeMock(visualState: .prePlay)
    PlaybackControlsView(
        controlPresentation: vm.controlPresentation,
        isActivelyPlaying: vm.isActivelyPlaying,
        sleepTimerRemaining: vm.sleepTimerRemaining,
        sleepTimerAccessibilityValue: vm.sleepTimerAccessibilityValue,
        statusPresentation: vm.statusPresentation,
        onPlay: vm.play,
        onPause: vm.pause,
        onSelectSleepTimer: { _ in },
        onCancelSleepTimer: {}
    )
    .padding()
}
#endif
