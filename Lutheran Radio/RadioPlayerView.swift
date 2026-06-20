//
//  RadioPlayerView.swift
//  Lutheran Radio
//
//  Main player screen as a pure SwiftUI view.
//  Composition root for the modern player chrome (title, playback controls, metadata,
//  language tuner, and volume/airplay row). The decorative background remains in UIKit
//  ownership (BackgroundImageController) and is visible through a large central spacer.
//
//  This replaced the prior hybrid UIKit layout. All vertical rhythm is now expressed
//  declaratively with VStack + explicit paddings so that future layout experiments are cheap.
//
//  Created by Jari Lammi on 19.6.2026.
//

import SwiftUI
import AVKit

/// The main player interface built in SwiftUI.
///
/// Composes `NowPlayingMetadataView`, `LanguageSelectorView`, `PlaybackControlsView` and
/// `VolumeAndAirPlayRow` under a single composition root (`UIHostingController` in ViewController).
///
/// Current visual order (top to bottom):
/// 1. Localized app title (establishes identity immediately under the status bar).
/// 2. Primary playback controls (play/pause, sleep timer, status pill) — placed high for reachability.
/// 3. Now-playing metadata + conditional speaker photo.
/// 4. Language/flag "tuner" row with animated red needle (`LanguageSelectorView`).
/// 5. Large spacer that leaves the central screen area visually open.
/// 6. Volume slider + AirPlay row anchored near the bottom safe area.
///
/// The decorative map / logo background is deliberately kept in UIKit ownership
/// (`BackgroundImageController`) behind this transparent hosting controller. This preserves
/// parallax, energy-efficiency paths, CI filtering, and deferral logic without risk during
/// the incremental SwiftUI migration.
///
/// Sleep timer: The tap closure is forwarded for compatibility (it still reaches
/// `configureSleepTimerButtonMenu`). The actual presentation is a native
/// `.confirmationDialog` (15/30/45/60 + conditional Cancel) implemented inside
/// `PlaybackControlsView`. Choices are delivered via `PlayerViewModel.selectSleepTimer` /
/// `cancelSleepTimer` closures that the coordinator wires to its authoritative handle methods.
/// This preserves the complete existing timer logic, countdown Task, notifications,
/// `syncSleepTimerToViewModel`, and interaction flags unchanged.
///
/// String revival note: `sleep_timer_sheet_title` is materialized here (and also used directly
/// in the dialog) to keep the localization entry live across all 21 languages.
///
/// - SeeAlso: ``PlayerViewModel``, `PlaybackControlsView`, `LanguageSelectorView`,
///   `NowPlayingMetadataView`, `VolumeAndAirPlayRow`, `ViewController`,
///   `RadioPlayerCoordinator`, `BackgroundImageController`,
///   `configureSleepTimerButtonMenu()`, CODING_AGENT.md (Single Source of Truth Principles + Cross-target shared files),
///   <doc:Architecture>.
struct RadioPlayerView: View {
    @Bindable var viewModel: PlayerViewModel

    /// Called when the user taps the sleep timer button (compatibility / side-effect path).
    /// Primary presentation and choice handling for sleep timer now lives in
    /// `PlaybackControlsView` (`.confirmationDialog`) + `PlayerViewModel` action closures
    /// (wired to coordinator business logic). The closure is still invoked on tap so that
    /// `configureSleepTimerButtonMenu` call sites remain exercised.
    var onSleepTimerTapped: (() -> Void)?

    /// Keeps the previously stale "sleep_timer_sheet_title" string active in the localization
    /// catalog. The value is evaluated once per instance (harmless cost). It is used directly
    /// as the title for the native `.confirmationDialog` sleep timer options (see PlaybackControlsView).
    private let sleepTimerSheetTitle = String(localized: "sleep_timer_sheet_title", table: "Localizable")

    var body: some View {
        ZStack {
            // Background is provided by BackgroundImageController behind this hosted view.
            // We deliberately keep the background layer in UIKit ownership for this phase
            // (parallax, energy efficiency, deferral, CI processing). The SwiftUI layer
            // is intentionally transparent so the processed map/logo artwork shows through
            // the central spacer region.
            Color.clear

            VStack(spacing: 0) {
                // Top title — localized app identity. Horizontal padding prevents the large title
                // from hugging screen edges. Top padding sized for Dynamic Island / status bar clearance.
                Text(String(localized: "lutheran_radio_title", defaultValue: "Lutheran Radio", table: "Localizable"))
                    .font(.largeTitle.weight(.semibold))
                    .padding(.top, 16)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)

                // Playback controls (play/pause + sleep timer moon + status pill).
                // Positioned early in the stack so the most frequent actions sit in a comfortable
                // thumb zone near the top of the content area.
                PlaybackControlsView(
                    viewModel: viewModel,
                    onSleepTimerTapped: onSleepTimerTapped
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

                // Song / program metadata + optional speaker photo.
                // Placed directly above the language selector so current-stream context sits
                // adjacent to the tuner controls.
                NowPlayingMetadataView(viewModel: viewModel)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                // Flags row with red needle indicator.
                // The needle's vertical registration is handled inside LanguageSelectorView
                // via reserved clear space + .offset(y: -11).
                LanguageSelectorView(viewModel: viewModel)
                    .padding(.horizontal)
                    .padding(.bottom, 6)

                // Spacer reserves vertical real-estate in the middle of the screen.
                // This keeps the full-bleed decorative background (map / logo images owned by
                // BackgroundImageController) visible behind the transparent host. The minLength
                // is chosen so the artwork remains prominent even as the top chrome grows.
                Spacer(minLength: 80)

                // Volume + native AirPlay row at the very bottom.
                // Padding values chosen to feel anchored without colliding with the home indicator.
                VolumeAndAirPlayRow()
                    .padding(.horizontal, 32)
                    .padding(.top, 6)
                    .padding(.bottom, 34)
            }
        }
        .background(Color.clear)
    }
}

// MARK: - Volume + AirPlay Row

/// Bottom control row containing speaker icon, volume slider, and AirPlay picker.
///
/// This is a transitional implementation:
/// - The slider drives `DirectStreamingPlayer.shared.setVolume` + the group UserDefaults key
///   used by the rest of the app for persistence across launches / widgets.
/// - A proper binding surface or `MPVolumeView` representable can replace the custom slider later.
///
/// The AirPlay button uses a minimal `UIViewRepresentable` wrapper around `AVRoutePickerView`.
struct VolumeAndAirPlayRow: View {
    @State private var volume: Double = 0.5

    private let sharedDefaultsSuite = "group.radio.lutheran.shared"
    private let volumeKey = "preferredVolume"

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
                .font(.callout)
                .accessibilityHidden(true)

            // Volume control. Value is local @State for this row; changes are immediately
            // forwarded to the streaming engine and persisted (matching prior UIKit behavior).
            Slider(value: $volume, in: 0...1)
                .tint(.accentColor)
                .accessibilityIdentifier("volumeSlider")
                .accessibilityLabel(String(localized: "accessibility_label_volume", table: "Localizable"))
                .accessibilityHint(String(localized: "accessibility_hint_volume", table: "Localizable"))
                .onChange(of: volume) { _, newValue in
                    applyVolume(Float(newValue))
                }

            // AirPlay route picker (native).
            AirPlayButton()
        }
        .frame(height: 44)
        .onAppear {
            loadInitialVolume()
        }
    }

    private func loadInitialVolume() {
        if let shared = UserDefaults(suiteName: sharedDefaultsSuite) {
            let saved = shared.float(forKey: volumeKey)
            let toUse = saved > 0 ? Double(saved) : 0.5
            volume = toUse
            // Make sure the engine matches what we display on first appearance.
            DirectStreamingPlayer.shared.setVolume(Float(toUse))
        } else {
            volume = 0.5
            DirectStreamingPlayer.shared.setVolume(0.5)
        }
    }

    private func applyVolume(_ value: Float) {
        DirectStreamingPlayer.shared.setVolume(value)

        if let shared = UserDefaults(suiteName: sharedDefaultsSuite) {
            shared.set(value, forKey: volumeKey)
            shared.synchronize()
        }
    }
}

/// UIViewRepresentable wrapper for the native AirPlay picker button.
///
/// Prioritizes audio-only routes (video devices disabled) to match historical behavior.
struct AirPlayButton: View {
    var body: some View {
        AirPlayPickerView()
            .frame(width: 44, height: 44)
            .accessibilityLabel(String(localized: "accessibility_label_airplay", table: "Localizable"))
            .accessibilityHint(String(localized: "accessibility_hint_airplay", table: "Localizable"))
    }
}

private struct AirPlayPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = UIColor.secondaryLabel
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        // No dynamic state to push in this simple wrapper.
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Radio Player - Playing") {
    RadioPlayerView(viewModel: .makeMock(visualState: .playing))
        .background(Color(UIColor.systemBackground))
}

#Preview("Radio Player - PrePlay + Sleep") {
    RadioPlayerView(
        viewModel: .makeMock(
            visualState: .prePlay,
            currentMetadata: nil,
            sleepTimerRemaining: 14 * 60
        )
    )
    .background(Color(UIColor.systemBackground))
}
#endif
