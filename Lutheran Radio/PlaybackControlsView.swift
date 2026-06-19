//
//  PlaybackControlsView.swift
//  Lutheran Radio
//
//  Pure SwiftUI playback controls: play/pause (with symbol bounce), sleep timer button, and
//  colored status pill driven directly by PlayerVisualState.
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
/// Accessibility:
/// - Play/pause button carries explicit `toggle_playback` custom action name (revives the string
///   that became stale when the old UIKit custom accessibility action was removed).
/// - Sleep timer button carries dynamic `.accessibilityValue` using `sleep_timer_accessibility_remaining`
///   (e.g. "12 minutes remaining") so VoiceOver users hear remaining time. This revives the
///   previously stale string that lost its UIKit call site during the SwiftUI foundation migration.
///
/// Actions are forwarded through the viewModel's injected closures (`play()`, `pause()`), which
/// the coordinator wires to the authoritative `handle*` paths.
///
/// - SeeAlso: ``PlayerViewModel``, `PlayerVisualState`, `RadioPlayerCoordinator`,
///   CODING_AGENT.md (Documentation & Comment Standards + Single Source of Truth Principles).
struct PlaybackControlsView: View {

    @Bindable var viewModel: PlayerViewModel

    // Sleep timer tap is forwarded via closure so that the complex menu / countdown Task
    // logic can remain in the coordinator for now (low-risk incremental migration).
    var onSleepTimerTapped: (() -> Void)?

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

            // Sleep timer (visual only for now; full menu attached at higher level or via closure)
            Button {
                onSleepTimerTapped?()
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
