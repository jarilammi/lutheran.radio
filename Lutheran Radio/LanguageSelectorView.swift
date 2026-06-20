//
//  LanguageSelectorView.swift
//  Lutheran Radio
//
//  Pure SwiftUI horizontal language/flag "tuning" selector with an animated red needle indicator.
//  Replaces the prior UIKit UICollectionView + manual Auto Layout needle math.
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
/// The animated red "tuning needle" uses `matchedGeometryEffect` + the implicit spring to
/// reproduce the classic sweep behavior that previously required manual Auto Layout math and
/// collection-view layoutAttributes.
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
                // `matchedGeometryEffect` + the container's spring animation produces the smooth
                // sweep that previously required manual centerX constraints + layoutAttributes.
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
