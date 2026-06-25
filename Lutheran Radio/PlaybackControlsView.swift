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
//    `isActivelyPlaying` for action routing, `.symbolEffect`, and accessibility.
//
//  Sleep timer:
//  - Uses a native `.confirmationDialog` with duration presets, conditional "Cancel timer",
//    and the destructive "Clear local state" privacy action.
//  - Accessibility value (when active) comes from the pre-derived
//    `sleepTimerAccessibilityValue` (derived on the model, not inside the view body).
//
//  The view receives only narrow value types (`controlPresentation`, timer values,
//  `statusPresentation`) + action closures. No `PlayerViewModel`.
//  All complex timing, orchestration, and privacy confirmation logic remains in
//  `RadioPlayerCoordinator`.
//
//  Note: `configureSleepTimerButtonMenu()` is still called from several glue paths for
//  compatibility, even though the primary UI now uses `.confirmationDialog`.
//
//  Created by Jari Lammi on 13.6.2026.
//

import SwiftUI

/// Pure SwiftUI row for the main player controls.
///
/// Receives narrow value inputs for everything it renders:
/// - `controlPresentation`: glyph and tint for the play/pause button (from `PlayerControlPresentation`).
/// - `isActivelyPlaying`: semantic flag used for action routing, `.symbolEffect` key, and accessibility.
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
/// Sleep timer presentation:
/// - Timer countdown and accessibility value come in pre-computed.
/// - The moon button tap triggers a native `.confirmationDialog` offering the presets,
///   conditional Cancel, and the "Clear local state" privacy action.
/// - All complex orchestration, countdown, and privacy logic remains in `RadioPlayerCoordinator`.
///
/// - Precondition: The values must be driven by the coordinator (or mock for previews/tests).
/// - Note: The privacy clear path does a secondary confirmation via UIAlert before acting.
/// - SeeAlso: ``PlayerViewModel``, ``PlayerControlPresentation``, ``PlayerStatusPresentation``,
///   `StatusPill`, `NowPlayingDisplayModel`, `RadioPlayerCoordinator`,
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

    // Legacy tap forwarding (still called on button press for compatibility).
    // The complex menu / countdown Task / preset handling logic remains exclusively
    // in the coordinator; SwiftUI only owns the .confirmationDialog presentation.
    var onSleepTimerTapped: (() -> Void)? = nil

    /// Optional closure for the privacy "Clear local state" destructive action.
    /// When provided (wired from RadioPlayerView / ViewController), tapping the button
    /// inside the dialog invokes this, which reaches `RadioPlayerCoordinator.confirmAndClearLocalState()`.
    /// This restores the privacy feature that was present in the legacy UIMenu (always shown,
    /// after the presets, regardless of active timer state).
    ///
    /// - Note: The action itself shows a secondary confirmation UIAlertController (title + message + destructive confirm).
    ///   The clear performs `SharedPlayerManager.clearAllLocalState()` and related resets.
    /// - SeeAlso: RadioPlayerCoordinator.confirmAndClearLocalState, SharedPlayerManager.clearAllLocalState,
    ///   PlaybackControlsView (the .confirmationDialog), CODING_AGENT.md (Single Source of Truth Principles).
    var onClearLocalStateTapped: (() -> Void)? = nil

    // Local presentation state for the SwiftUI-native sleep timer options dialog.
    // This is the primary user-facing path after the SwiftUI migration of the player UI.
    @State private var isShowingSleepTimerDialog = false

    var body: some View {
        HStack(spacing: 20) {
            // Play / Pause button
            // Glyph and tint come from the narrow controlPresentation input.
            // Action routing, symbolEffect value, and accessibility labels use the
            // explicit semantic `isActivelyPlaying` flag.
            Button {
                if isActivelyPlaying {
                    onPause()
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
            .accessibilityIdentifier("playPauseButton")
            .accessibilityHint(String(localized: "accessibility_hint_play_pause", table: "Localizable"))
            .accessibilityLabel(
                isActivelyPlaying
                    ? String(localized: "accessibility_label_play_pause", table: "Localizable")
                    : String(localized: "accessibility_label_play", table: "Localizable")
            )
            // Revives the stale "toggle_playback" string as an explicit accessibility action name.
            // The button's default tap behavior already works; this named action provides a clear
            // discoverable action for VoiceOver / Switch Control users. Matches the old UIKit
            // custom action intent without changing observable behavior.
            .accessibilityAction(named: String(localized: "toggle_playback", table: "Localizable")) {
                if isActivelyPlaying {
                    onPause()
                } else {
                    onPlay()
                }
            }

            // Sleep timer button (native SwiftUI).
            // Tapping shows a .confirmationDialog with the 4 duration presets + conditional Cancel
            // + (always) the destructive "Clear local state" privacy action.
            // The legacy onSleepTimerTapped is still invoked (keeps configureSleepTimerButtonMenu
            // call sites exercised for compatibility and any internal side-effects).
            // Dialog actions for presets/cancel use the injected closures; clear uses its direct closure.
            Button {
                onSleepTimerTapped?()
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
                // 15 / 30 / 45 / 60 minute presets (identical to prior UIMenu).
                // These call the narrow closure supplied by the composition root.
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

                // Cancel only when a timer is currently active (matches the old UIMenu conditional).
                if let remaining = sleepTimerRemaining, remaining > 0 {
                    Button(
                        String(localized: "sleep_timer_cancel_timer", table: "Localizable"),
                        role: .destructive
                    ) {
                        onCancelSleepTimer?()
                    }
                }

                // "Clear local state" privacy / destructive action.
                // Restored from the legacy UIMenu built in configureSleepTimerButtonMenu()
                // (which unconditionally appended it after the presets, even when a timer was active).
                // Always visible here to match original behavior.
                // Label uses the existing localized key (no new localization strings added).
                // Tapping this calls the injected closure (wired to coordinator.confirmAndClearLocalState),
                // which presents its own UIAlertController for confirmation before calling
                // SharedPlayerManager.clearAllLocalState(). This is the privacy feature for clearing
                // recent playback/widget/Live Activity state from the App Group (does not affect
                // security/Core data).
                //
                // - SeeAlso: RadioPlayerCoordinator.configureSleepTimerButtonMenu, confirmAndClearLocalState,
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
