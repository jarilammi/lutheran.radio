//
//  PlaybackControlsView.swift
//  Lutheran Radio
//
//  Pure SwiftUI playback controls: play/pause (with symbol bounce), sleep timer button (now
//  using native .confirmationDialog), and colored status pill driven directly by PlayerVisualState.
//
//  Sleep timer: SwiftUI presents the dialog (presets + conditional cancel) and forwards choices
//  via PlayerViewModel. Coordinator retains full ownership of business logic and glue.
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
/// Sleep timer presentation (new):
/// - The moon button tap now triggers a native `.confirmationDialog` offering the four time
///   presets (15/30/45/60 min) plus a destructive "Cancel" only when a timer is active.
/// - Button tap still forwards through the legacy `onSleepTimerTapped` closure (for compatibility).
/// - Actual selection actions call `viewModel.selectSleepTimer(minutes:)` / `cancelSleepTimer()`
///   which are wired (in RadioPlayerCoordinator.wireAndInitialSetup) to the coordinator's
///   `handleSleepTimer*` methods. This keeps *all* business logic (setSleepTimer, cancel,
///   isSleepTimerInteractionActive, settle delays, begin/stopLocalSleepTimerDisplay,
///   syncSleepTimerToViewModel, SPM calls, notifications) exclusively in the coordinator.
/// - The old `configureSleepTimerButtonMenu()` (UIMenu builder) is retained and still called
///   from several internal sleep glue paths; it is a no-op for presentation now.
///
/// Accessibility notes unchanged (see below).
///
/// Actions for play/pause/language are forwarded through the viewModel's injected closures
/// (`play()`, `pause()`, `selectLanguage(at:)`), which the coordinator wires to the authoritative
/// `handle*` paths.
///
/// - SeeAlso: ``PlayerViewModel``, `PlayerVisualState`, `RadioPlayerCoordinator`,
///   `configureSleepTimerButtonMenu()`, CODING_AGENT.md (Documentation & Comment Standards + Single Source of Truth Principles).
struct PlaybackControlsView: View {

    @Bindable var viewModel: PlayerViewModel

    // Legacy tap forwarding (still called on button press for compatibility).
    // The complex menu / countdown Task / preset handling logic remains exclusively
    // in the coordinator; SwiftUI only owns the .confirmationDialog presentation.
    var onSleepTimerTapped: (() -> Void)?

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
            // Tapping shows a .confirmationDialog with the 4 duration presets + conditional Cancel.
            // The legacy onSleepTimerTapped is still invoked (keeps configureSleepTimerButtonMenu
            // call sites exercised for compatibility and any internal side-effects).
            // Dialog actions forward via PlayerViewModel to coordinator-owned timer logic.
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
