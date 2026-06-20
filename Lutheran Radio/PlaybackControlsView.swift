//
//  PlaybackControlsView.swift
//  Lutheran Radio
//
//  Pure SwiftUI playback controls: play/pause (with symbol bounce), sleep timer button (now
//  using native .confirmationDialog), and colored status pill driven directly by PlayerVisualState.
//
//  Sleep timer: SwiftUI presents the dialog (presets + conditional cancel + clear-local-state)
//  and forwards choices via PlayerViewModel (for timer actions) or direct closure (for privacy clear).
//  Coordinator retains full ownership of business logic, glue, and the privacy confirm flow.
//
//  "Clear local state" (privacy): The destructive action was present in the pre-migration UIMenu
//  (always shown, using "clear_local_state_title"). It was lost in the initial .confirmationDialog
//  migration. This file now restores it as a role:.destructive Button inside the same dialog.
//  Tapping forwards to onClearLocalStateTapped → coordinator.confirmAndClearLocalState() which
//  does secondary UIAlert confirmation + SharedPlayerManager.clearAllLocalState().
//
//  IMPORTANT: configureSleepTimerButtonMenu() remains untouched (per requirements) and is still
//  called from glue paths for compatibility side-effects only.
//
//  Created by Jari Lammi on 13.6.2026.
//

import SwiftUI

/// Pure SwiftUI row for the main player controls.
///
/// Binds to `PlayerViewModel.visualState` for status text/color and play/pause glyph.
/// Uses native SwiftUI Button + `.symbolEffect(.bounce)` for delightful play/pause transitions.
/// The sleep timer button uses the moon symbol and indigo tint when active (countdown value can be
/// observed via `viewModel.sleepTimerRemaining` by a parent or the button itself).
///
/// Sleep timer presentation:
/// - The moon button tap triggers a native `.confirmationDialog` offering:
///   - Four time presets (15/30/45/60 min)
///   - Conditional destructive "Cancel timer" (only when `sleepTimerRemaining > 0`)
///   - Destructive "Clear local state" privacy action (always present, matching legacy UIMenu)
/// - Button tap still forwards through the legacy `onSleepTimerTapped` closure (for compatibility).
/// - Timer selections call `viewModel.selectSleepTimer(minutes:)` / `cancelSleepTimer()` which
///   are wired (in `RadioPlayerCoordinator.wireAndInitialSetup`) to the coordinator's
///   `handleSleepTimer*` methods. All business logic stays in the coordinator.
/// - The "Clear local state" button calls the injected `onClearLocalStateTapped` (if any).
/// - The old `configureSleepTimerButtonMenu()` (UIMenu builder) is retained and still called
///   from several internal sleep glue paths; it is a no-op for presentation now.
///
/// - Precondition: The viewModel must be driven by the coordinator (or mock for previews/tests).
/// - Note: The privacy clear path does a secondary confirmation via UIAlert before acting.
/// - SeeAlso: ``PlayerViewModel``, `PlayerVisualState`, `RadioPlayerCoordinator`,
///   `configureSleepTimerButtonMenu()`, `confirmAndClearLocalState()`, `SharedPlayerManager.clearAllLocalState`,
///   CODING_AGENT.md (Documentation & Comment Standards + Single Source of Truth Principles),
///   <doc:Architecture>.
struct PlaybackControlsView: View {

    @Bindable var viewModel: PlayerViewModel

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

    private var isActivelyPlaying: Bool {
        viewModel.visualState.isActivelyPlaying
    }

    var body: some View {
        // Pre-computed for the sleep timer accessibilityValue (revives stale string).
        // Done here (not inside the modifier) to keep the ViewBuilder expression simple and
        // avoid type-checker "failed to produce diagnostic" issues under strict Swift 6.
        let sleepTimerValue: String? = {
            guard let remaining = viewModel.sleepTimerRemaining, remaining > 0 else { return nil }
            let minutes = max(1, Int((remaining + 59) / 60))
            // SAFETY: String(format:) with a catalog-provided format string containing %d
            // is the established pattern in this codebase for placeholder-bearing VoiceOver
            // strings (see announceSwitchedToLanguage in RadioPlayerCoordinator.swift).
            // The format is trusted (our Localizable.xcstrings) and the argument is a simple Int.
            // Required under SWIFT_STRICT_MEMORY_SAFETY=YES; the `unsafe` marker satisfies
            // the compiler while preserving the localized pluralization/positioning across 21 langs.
            return unsafe String(
                format: String(localized: "sleep_timer_accessibility_remaining", table: "Localizable"),
                minutes
            )
        }()

        HStack(spacing: 20) {
            // Play / Pause
            Button {
                if isActivelyPlaying {
                    viewModel.pause()
                } else {
                    viewModel.play()
                }
            } label: {
                Image(systemName: isActivelyPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .bold))
                    .frame(width: 50, height: 50)
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
                    viewModel.pause()
                } else {
                    viewModel.play()
                }
            }

            // Sleep timer button (native SwiftUI).
            // Tapping shows a .confirmationDialog with the 4 duration presets + conditional Cancel
            // + (always) the destructive "Clear local state" privacy action.
            // The legacy onSleepTimerTapped is still invoked (keeps configureSleepTimerButtonMenu
            // call sites exercised for compatibility and any internal side-effects).
            // Dialog actions for presets/cancel forward via PlayerViewModel; clear uses direct closure.
            Button {
                onSleepTimerTapped?()
                isShowingSleepTimerDialog = true
            } label: {
                let remaining = viewModel.sleepTimerRemaining
                let active = (remaining ?? 0) > 0
                Image(systemName: active ? "moon.zzz.fill" : "moon.zzz")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(active ? Color.indigo : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "accessibility_label_sleep_timer", table: "Localizable"))
            .accessibilityHint(String(localized: "accessibility_hint_sleep_timer", table: "Localizable"))
            // This revives the stale "sleep_timer_accessibility_remaining" localization entry.
            // When a timer is active we format the remaining seconds into whole minutes and
            // supply it as the accessibilityValue so VoiceOver reads e.g. "12 minutes remaining".
            // The (remaining + 59)/60 rounding-up matches the original UIKit behavior for a11y.
            // AGENT NOTE: Any future change to sleep timer presentation must keep using this key
            // (or the equivalent via a single-source computed property) so the 21 language
            // translations never go stale again.
            // Pass "" when inactive so the modifier receives a non-optional String (the API
            // requires it). An empty value is a no-op for VoiceOver on this control.
            .accessibilityValue(sleepTimerValue ?? "")
            .confirmationDialog(
                String(localized: "sleep_timer_sheet_title", table: "Localizable"),
                isPresented: $isShowingSleepTimerDialog,
                titleVisibility: .visible
            ) {
                // 15 / 30 / 45 / 60 minute presets (identical to prior UIMenu).
                // Selection routes through VM -> coordinator handle* so that
                // setSleepTimer, countdown, intent, notifications and VM sync are untouched.
                Button(String(localized: "sleep_timer_preset_15_min", table: "Localizable")) {
                    viewModel.selectSleepTimer(minutes: 15)
                }
                Button(String(localized: "sleep_timer_preset_30_min", table: "Localizable")) {
                    viewModel.selectSleepTimer(minutes: 30)
                }
                Button(String(localized: "sleep_timer_preset_45_min", table: "Localizable")) {
                    viewModel.selectSleepTimer(minutes: 45)
                }
                Button(String(localized: "sleep_timer_preset_60_min", table: "Localizable")) {
                    viewModel.selectSleepTimer(minutes: 60)
                }

                // Cancel only when a timer is currently active (matches the old UIMenu conditional).
                if let remaining = viewModel.sleepTimerRemaining, remaining > 0 {
                    Button(
                        String(localized: "sleep_timer_cancel_timer", table: "Localizable"),
                        role: .destructive
                    ) {
                        viewModel.cancelSleepTimer()
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
                // AGENT NOTE: Do not change visibility condition without also updating the legacy
                // configureSleepTimerButtonMenu() and its call sites/comments. This dialog is the
                // SwiftUI presentation surface; business logic and double-confirmation stay in coordinator.
                // - SeeAlso: RadioPlayerCoordinator.configureSleepTimerButtonMenu, confirmAndClearLocalState,
                //   <doc:Architecture>, CODING_AGENT.md.
                Button(
                    String(localized: "clear_local_state_title", table: "Localizable"),
                    role: .destructive
                ) {
                    onClearLocalStateTapped?()
                }
            }

            // Status pill (exact states + colors from PlayerVisualState)
            Text(statusText)
                .font(.body)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(minWidth: 120, maxWidth: 0.4 * 360) // approximate previous relative max
                .background(Color(uiColor: viewModel.visualState.backgroundColor))
                .foregroundStyle(Color(uiColor: viewModel.visualState.textColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .accessibilityLabel(statusText)
        }
        .frame(height: 50)
    }

    private var statusText: String {
        switch viewModel.visualState {
        case .playing:        return String(localized: "status_playing", table: "Localizable")
        case .userPaused:     return String(localized: "status_paused", table: "Localizable")
        case .thermalPaused:  return String(localized: "status_thermal_paused", table: "Localizable")
        case .prePlay:        return String(localized: "status_connecting", table: "Localizable")
        case .cleared:        return String(localized: "clear_local_state_done", table: "Localizable")
        case .securityLocked: return String(localized: "status_security_failed", table: "Localizable")
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Controls - Playing") {
    PlaybackControlsView(viewModel: .makeMock(visualState: .playing))
        .padding()
}

#Preview("Controls - Connecting") {
    PlaybackControlsView(viewModel: .makeMock(visualState: .prePlay))
        .padding()
}
#endif
