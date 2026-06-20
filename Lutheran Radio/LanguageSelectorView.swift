//
//  LanguageSelectorView.swift
//  Lutheran Radio
//
//  Pure SwiftUI horizontal language/flag "tuning" selector with an animated red needle indicator.
//  Replaces the prior UIKit UICollectionView + manual Auto Layout needle math.
//
//  The needle sweep is driven by matchedGeometryEffect + an explicit spring animation on the
//  HStack keyed by selectedStreamIndex. This produces a clearly visible, radio-like tuning motion
//  (see body documentation for parameter rationale).
//
//  Created by Jari Lammi on 12.6.2026.
//

import SwiftUI

/// Pure idiomatic SwiftUI view for the horizontal flag selector row ("tuner").
///
/// Renders the available streams as emoji flags using `DirectStreamingPlayer.availableStreams`
/// (the single source of truth for the 21-language set and their visual order).
///
/// Selection drives `PlayerViewModel.selectedStreamIndex`; taps are forwarded via
/// `viewModel.selectLanguage(at:)` and ultimately reach the full stream-switch path in
/// `RadioPlayerCoordinator` (debounce + tuning sound + security + DirectStreamingPlayer swap).
///
/// The row is implemented as a plain `HStack` (no `ScrollView`) because the selector must remain
/// a fixed, non-scrollable, perfectly centered set of five flags. The previous ScrollView +
/// `.scrollDisabled(true)` form worked but carried unnecessary scrolling machinery.
///
/// The animated red "tuning needle" uses `matchedGeometryEffect` on the indicator Rectangle
/// together with an explicit `.animation(.spring(response:dampingFraction:), value:)` modifier
/// applied to the `HStack` container. The animation value is `viewModel.selectedStreamIndex`.
/// When the user taps a flag, `selectLanguage(at:)` eventually mutates the index (via the
/// coordinator's optimistic UI path), causing the `if isSelected` branch in `flagView` to
/// insert the Rectangle at a different position inside the HStack layout. The spring then
/// produces a visible, damped sweep of the geometry from the old position to the new one.
///
/// Spring tuning rationale (response: 0.62, dampingFraction: 0.80):
/// - Slow enough for the travel to be clearly perceptible and to feel like a physical radio
///   tuning needle moving across the dial while the tuning sound plays.
/// - Damped enough to settle elegantly without excessive oscillation or "boing".
/// - Still responsive (no perceptible lag on tap).
/// The previous implicit default spring was too brief; the movement was nearly invisible.
///
/// - SeeAlso: ``PlayerViewModel``, `RadioPlayerCoordinator.handleLanguageSelection(at:)`,
///   `DirectStreamingPlayer.availableStreams`, <doc:Architecture>,
///   CODING_AGENT.md (Single Source of Truth Principles + Cross-target shared files).
struct LanguageSelectorView: View {
    @Bindable var viewModel: PlayerViewModel

    @Namespace private var needleNamespace

    private var streams: [DirectStreamingPlayer.Stream] {
        DirectStreamingPlayer.availableStreams
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(streams.enumerated()), id: \.offset) { index, stream in
                flagView(for: stream, at: index)
            }
        }
        // Explicit animation drives matchedGeometryEffect. Without it the geometry change
        // uses an extremely fast implicit spring and the needle "teleports" rather than sweeps.
        // Value-driven animation ensures the sweep only occurs when selection actually changes.
        // The parameters were selected after evaluating the radio-tuner feel against the
        // duration of playTuningSound; the sweep now visibly overlaps the sound playback.
        .animation(.spring(response: 0.62, dampingFraction: 0.80), value: viewModel.selectedStreamIndex)
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: 56)
    }
    
    private func flagView(for stream: DirectStreamingPlayer.Stream, at index: Int) -> some View {
        let isSelected = index == viewModel.selectedStreamIndex

        return VStack(spacing: 0) {
            Button {
                viewModel.selectLanguage(at: index)
            } label: {
                Text(stream.flag)
                    .font(.system(size: 30))
                    .frame(width: 50, height: 50)
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(makeAccessibilityLabel(for: stream))
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            // Reserve vertical space for the needle indicator (does not affect flag layout).
            // The 6 pt clear area + the overlay + the negative offset together place the needle
            // so it sits just below the flag glyphs, exactly as the original UIKit design required.
            Color.clear
                .frame(height: 6)
        }
        .overlay(alignment: .bottom) {
            if isSelected {
                // The animated "tuning needle" — thin red vertical indicator.
                // `matchedGeometryEffect(id: "needle", ...)` marks this view so that when the
                // identical id moves to a different flag's overlay (as selectedStreamIndex changes),
                // SwiftUI animates its frame/position. The actual timing and curve come from the
                // .animation modifier on the parent HStack (see body above). This keeps the
                // declarative matched-geometry contract while making the sweep pronounced.
                Rectangle()
                    .fill(Color.red.opacity(0.7))
                    .frame(width: 4, height: 38)
                    // Empirically tuned vertical registration. -11 pt pulls the needle up from the
                    // overlay attachment point so its top aligns with the visual baseline of the
                    // flag emoji row. Changing this value requires visual verification on device/sim.
                    .offset(y: -11)
                    .matchedGeometryEffect(id: "needle", in: needleNamespace)
            }
        }
    }

    private func makeAccessibilityLabel(for stream: DirectStreamingPlayer.Stream) -> String {
        // SAFETY: String(format:) with a catalog-provided format string is the established
        // pattern for placeholder-bearing VoiceOver strings across the 21-language catalog.
        // The format originates from Localizable.xcstrings (trusted) and the argument is a
        // plain String. This is required to satisfy SWIFT_STRICT_MEMORY_SAFETY while keeping
        // correct pluralization/positioning per language. See identical pattern in
        // PlaybackControlsView.swift and RadioPlayerCoordinator.
        unsafe String(
            format: String(localized: "select_language_accessibility", defaultValue: "Select %@", table: "Localizable", comment: "Accessibility label for language flag button. %@ is the language name."),
            stream.language
        )
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Language Selector") {
    LanguageSelectorView(viewModel: .makeMock(selectedStreamIndex: 2))
        .padding()
}
#endif
