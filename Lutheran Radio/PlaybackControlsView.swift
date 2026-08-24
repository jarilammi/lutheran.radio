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
//  - Sole presentation is a native `.confirmationDialog` with duration presets,
//    conditional "Cancel timer", and the destructive "Clear local state" privacy action.
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
/// - The moon button tap triggers a native `.confirmationDialog` offering the presets,
///   conditional Cancel, and the "Clear local state" privacy action.
/// - All complex orchestration, countdown, and privacy logic remains in `RadioPlayerCoordinator`.
///
/// - Precondition: The values must be driven by the coordinator (or mock for previews/tests).
/// - Note: The privacy clear path does a secondary confirmation via UIAlert before acting.
/// - SeeAlso: ``PlayerViewModel``, ``PlayerControlPresentation``, ``PlayerStatusPresentation``,
///   `StatusPill`, `NowPlayingDisplayModel`, `RadioPlayerCoordinator`, `VolumeAndAirPlayRow`,
///   ``HapticPlaybackPolicy``, ``HapticsController``,
///   ``RadioPlayerCoordinator/handleStatusChange(_:reasonKey:)``,
///   ``PlaybackPausePressFeedback``,
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
    /// When provided (wired from RadioPlayerView / ViewController), tapping the button
    /// inside the dialog invokes this, which reaches `RadioPlayerCoordinator.confirmAndClearLocalState()`.
    /// Always shown after the presets (regardless of active timer state).
    ///
    /// - Note: The action builds a secondary confirmation `UIAlertController`. The host
    ///   presents it only after this `.confirmationDialog` container has disappeared
    ///   (``ViewController/presentCoordinatorAlertAfterOutgoingPresentationSettles(_:)``).
    ///   The clear performs `SharedPlayerManager.clearAllLocalState()` and related resets.
    /// - SeeAlso: `RadioPlayerCoordinator.confirmAndClearLocalState`, `SharedPlayerManager.clearAllLocalState`,
    ///   ``ViewController/presentCoordinatorAlertAfterOutgoingPresentationSettles(_:)``,
    ///   CODING_AGENT.md (Single Source of Truth Principles).
    var onClearLocalStateTapped: (() -> Void)? = nil

    // Local presentation state for the SwiftUI-native sleep timer options dialog.
    // This is the primary user-facing path after the SwiftUI migration of the player UI.
    @State private var isShowingSleepTimerDialog = false

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

            // Sleep timer: moon button opens sole presentation surface — `.confirmationDialog`
            // with 15/30/45/60 presets, conditional Cancel, and always-visible Clear local state.
            // Preset/cancel closures reach coordinator handlers via PlayerViewModel; clear uses
            // onClearLocalStateTapped → confirmAndClearLocalState (secondary UIAlert).
            Button {
                isShowingSleepTimerDialog = true
            } label: {
                let active = (sleepTimerRemaining ?? 0) > 0
                Image(systemName: active ? "moon.zzz.fill" : "moon.zzz")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(active ? Color.indigo : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "accessibility_label_sleep_timer", table: "Localizable"))
            .accessibilityHint(String(localized: "accessibility_hint_sleep_timer", table: "Localizable"))
            // Sleep timer a11y value is supplied pre-derived from the caller.
            // When a timer is active the value surfaces remaining minutes to VoiceOver
            // (e.g. "12 minutes remaining"); otherwise empty string.
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

                // Cancel only when a timer is currently active.
                if let remaining = sleepTimerRemaining, remaining > 0 {
                    Button(
                        String(localized: "sleep_timer_cancel_timer", table: "Localizable"),
                        role: .destructive
                    ) {
                        onCancelSleepTimer?()
                    }
                }

                // Privacy: clear recent playback/widget/Live Activity App Group state (not Core security data).
                // Secondary UIAlert is built in confirmAndClearLocalState; the host presents
                // it after this confirmationDialog container has disappeared.
                // - SeeAlso: SharedPlayerManager.clearAllLocalState,
                //   ViewController.presentCoordinatorAlertAfterOutgoingPresentationSettles,
                //   <doc:Architecture>, CODING_AGENT.md.
                Button(
                    String(localized: "clear_local_state_title", table: "Localizable"),
                    role: .destructive
                ) {
                    onClearLocalStateTapped?()
                }
            }

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
