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
/// Actions are forwarded through the viewModel's injected closures (`play()`, `pause()`), which
/// the coordinator wires to the authoritative `handle*` paths.
///
/// - SeeAlso: ``PlayerViewModel``, `PlayerVisualState`, `RadioPlayerCoordinator`.
struct PlaybackControlsView: View {

    @Bindable var viewModel: PlayerViewModel

    // Sleep timer tap is forwarded via closure so that the complex menu / countdown Task
    // logic can remain in the coordinator for now (low-risk incremental migration).
    var onSleepTimerTapped: (() -> Void)?

    private var isActivelyPlaying: Bool {
        viewModel.visualState.isActivelyPlaying
    }

    var body: some View {
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
