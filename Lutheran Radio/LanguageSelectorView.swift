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

/// Pure idiomatic SwiftUI view for the horizontal flag selector row.
///
/// - Renders the five radio streams using their emoji flags from `DirectStreamingPlayer.availableStreams`.
/// - Selection is bound directly to `PlayerViewModel.selectedStreamIndex`.
/// - User taps call `viewModel.selectLanguage(at:)` (wired in coordinator to the full
///   `handleLanguageSelection` + debounce + completeStreamSwitch + tuning sound path).
/// - The "tuning needle" is a thin red indicator animated with `matchedGeometryEffect` + spring
///   for the beautiful sweep that previously required complex layoutAttributes + centerX math.
/// - Scroll is disabled (exact visual match to the prior non-scrolling centered row).
/// - Selected flag receives accent tint (blue) to match prior `LanguageCell.isSelected` behavior.
///
/// - SeeAlso: ``PlayerViewModel``, `RadioPlayerCoordinator.handleLanguageSelection(at:)`,
///   <doc:Architecture>, CODING_AGENT.md (Single Source of Truth Principles).
struct LanguageSelectorView: View {
    @Bindable var viewModel: PlayerViewModel

    @Namespace private var needleNamespace

    private var streams: [DirectStreamingPlayer.Stream] {
        DirectStreamingPlayer.availableStreams
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(Array(streams.enumerated()), id: \.offset) { index, stream in
                    flagView(for: stream, at: index)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollDisabled(true)
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

            // Reserve vertical space for the needle indicator (does not affect flag layout)
            Color.clear
                .frame(height: 6)
        }
        .overlay(alignment: .bottom) {
            if isSelected {
                // The animated "tuning needle" — thin red vertical indicator.
                // matchedGeometryEffect + spring animation produces the smooth sweep previously
                // implemented with manual centerX constraints, layoutAttributes, and pulse.
                Rectangle()
                    .fill(Color.red.opacity(0.7))
                    .frame(width: 4, height: 38)
                    .matchedGeometryEffect(id: "needle", in: needleNamespace)
            }
        }
    }

    private func makeAccessibilityLabel(for stream: DirectStreamingPlayer.Stream) -> String {
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
