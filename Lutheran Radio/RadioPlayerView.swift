//
//  RadioPlayerView.swift
//  Lutheran Radio
//
//  Main player screen as a pure SwiftUI view.
//  This replaces the complex hybrid UIKit layout of interleaved hosted views
//  and legacy UILabel/UISlider elements.
//
//  Created by Jari Lammi on 19.6.2026.
//

import SwiftUI
import AVKit

/// The main player interface built in SwiftUI.
///
/// Composes the three previously extracted modern SwiftUI subviews
/// (`NowPlayingMetadataView`, `LanguageSelectorView`, `PlaybackControlsView`)
/// plus a volume + AirPlay control row.
///
/// Layout mirrors the intent of the prior UIKit arrangement but is now:
/// - Single composition root (one `UIHostingController` in the host).
/// - Declarative VStack + Spacers for the classic "title area / selector / controls / volume" rhythm.
/// - Background image remains behind the hosting controller (owned by `BackgroundImageController`)
///   for minimal-risk incremental migration.
///
/// The sleep timer button forwards its tap via `onSleepTimerTapped` so that
/// the existing UIMenu / countdown / SharedPlayerManager glue can stay in
/// `RadioPlayerCoordinator` during this phase.
///
/// String revival for stale localizations (user will curate the catalog separately):
/// - `sleep_timer_sheet_title` is referenced below so the entry becomes active.
///   When the sleep timer menu is later converted from the coordinator's UIMenu to a
///   native SwiftUI `confirmationDialog` or `.sheet`, this string will be used as the title.
///
/// - SeeAlso: ``PlayerViewModel``, `PlaybackControlsView`, `LanguageSelectorView`,
///   `NowPlayingMetadataView`, `ViewController.setupUI()`, `RadioPlayerCoordinator`,
///   CODING_AGENT.md (Single Source of Truth Principles + Cross-target shared files),
///   <doc:Architecture>.
struct RadioPlayerView: View {
    @Bindable var viewModel: PlayerViewModel

    /// Called when the user taps the sleep timer button.
    /// The complex menu + countdown logic + SharedPlayerManager integration
    /// remains in `RadioPlayerCoordinator.configureSleepTimerButtonMenu` and friends.
    var onSleepTimerTapped: (() -> Void)?

    /// Keeps the previously stale "sleep_timer_sheet_title" string active in the localization
    /// catalog. The value is evaluated once per instance (harmless cost) and is ready for use
    /// when the sleep timer presentation migrates fully to SwiftUI.
    private let sleepTimerSheetTitle = String(localized: "sleep_timer_sheet_title", table: "Localizable")

    var body: some View {
        ZStack {
            // Background is provided by BackgroundImageController behind this hosted view.
            // We deliberately keep the background layer in UIKit ownership for this phase
            // (parallax, energy efficiency, deferral, CI processing). The SwiftUI layer
            // is intentionally transparent.
            Color.clear

            VStack(spacing: 0) {
                // Now Playing metadata + speaker photo (when relevant).
                // Padding chosen to give breathing room under the status bar / Dynamic Island.
                NowPlayingMetadataView(viewModel: viewModel)
                    .padding(.top, 24)
                    .padding(.horizontal, 20)

                Spacer(minLength: 24)

                // Language / flag selector with animated red needle (matchedGeometryEffect).
                LanguageSelectorView(viewModel: viewModel)
                    .padding(.horizontal)

                Spacer()

                // Playback controls (play/pause + sleep timer + status pill).
                PlaybackControlsView(
                    viewModel: viewModel,
                    onSleepTimerTapped: onSleepTimerTapped
                )
                .padding(.horizontal, 24)

                // Volume + native AirPlay row (replaces the prior UIKit UISlider + AVRoutePickerView).
                VolumeAndAirPlayRow()
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
                    .padding(.bottom, 34)
            }
        }
        // Ensure the hosting view does not paint an opaque background that would hide the image layer.
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
