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
//  ForEach uses `streams.indices` (with stable index as identity) rather than
//  `enumerated()` + offset. The index is captured only where required for the
//  `at:` parameter passed to flagView (selection and needle highlighting). This
//  form is idiomatic for a fixed-order static collection and keeps the matched-
//  geometry needle animation contract identical.
//
//  Created by Jari Lammi on 12.6.2026.
//

import SwiftUI

/// Pure idiomatic SwiftUI view for the horizontal flag selector row ("tuner").
///
/// Renders the available streams as emoji flags using `DirectStreamingPlayer.availableStreams`
/// (the single source of truth for the 21-language set and their visual order).
///
/// Receives only the current selected index (as a plain `let`) and a selection closure.
/// The stream list is read directly from the static `DirectStreamingPlayer.availableStreams`
/// (canonical constant data, no VM state).
///
/// Taps are forwarded via the supplied closure and ultimately reach the full stream-switch
/// path in `RadioPlayerCoordinator`.
///
/// The row is implemented as a plain `HStack` (no `ScrollView`) because the selector must remain
/// a fixed, non-scrollable, perfectly centered set of five flags.
///
/// The animated red "tuning needle" uses `matchedGeometryEffect` + explicit spring animation
/// on the container, keyed by the selected index value.
///
/// This view receives only the minimal slice (`selectedStreamIndex` + closure) consistent
/// with the narrow-input contract now used for all main-player leaf views and the widget
/// / Live Activity surfaces.
///
/// - SeeAlso: ``PlayerViewModel``, `RadioPlayerCoordinator.handleLanguageSelection(at:)`,
///   `DirectStreamingPlayer.availableStreams`, `RadioPlayerView`,
///   CODING_AGENT.md (narrow inputs for separate View types),
///   PlayerViewModel.swift (Main Player Presentation Dataflow).
struct LanguageSelectorView: View {
    let selectedStreamIndex: Int
    let selectLanguage: (Int) -> Void

    @Namespace private var needleNamespace

    /// Local view of the canonical stream list (static; order defines selection indices).
    ///
    /// Direct access to `DirectStreamingPlayer.availableStreams` (SSOT) is intentional and
    /// acceptable here: the list is a small constant with no VM-derived state.
    private var streams: [DirectStreamingPlayer.Stream] {
        DirectStreamingPlayer.availableStreams
    }

    var body: some View {
        HStack(spacing: 10) {
            // Use the array's own indices for stable identity.
            // - `streams` is the static `DirectStreamingPlayer.availableStreams` (never mutated at runtime).
            // - Index values (0..<5) serve as stable, position-based identifiers.
            // - We still pass the index to `flagView` because `selectLanguage(at:)` and the
            //   selectedStreamIndex comparison use the canonical position in the array.
            // This form avoids `enumerated()`/offset identity while preserving exact
            // behavior and the matchedGeometry needle animation keyed by index.
            ForEach(streams.indices, id: \.self) { index in
                flagView(for: streams[index], at: index)
            }
        }
        // Explicit animation drives matchedGeometryEffect. Without it the geometry change
        // uses an extremely fast implicit spring and the needle "teleports" rather than sweeps.
        // Value-driven animation ensures the sweep only occurs when selection actually changes.
        // The parameters were selected after evaluating the radio-tuner feel against the
        // duration of playTuningSound; the sweep now visibly overlaps the sound playback.
        .animation(.spring(response: 0.62, dampingFraction: 0.80), value: selectedStreamIndex)
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: 56)
    }
    
    private func flagView(for stream: DirectStreamingPlayer.Stream, at index: Int) -> some View {
        let isSelected = index == selectedStreamIndex

        return VStack(spacing: 0) {
            Button {
                selectLanguage(index)
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
    let vm = PlayerViewModel.makeMock(selectedStreamIndex: 2)
    LanguageSelectorView(
        selectedStreamIndex: vm.selectedStreamIndex,
        selectLanguage: vm.selectLanguage
    )
    .padding()
}
#endif
