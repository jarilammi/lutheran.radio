//
//  NowPlayingMetadataView.swift
//  Lutheran Radio
//
//  Pure SwiftUI presentation of the Now Playing metadata (program title + speaker) plus
//  conditional speaker / program photo (Jari Lammi special case + placeholder).
//
//  Replaces the prior vended-UILabel + UIImageView holder.
//
//  The view is intentionally a leaf: it receives a narrow `NowPlayingDisplayModel` value
//  (Equatable) and a boolean flag. Derivation responsibility lives exclusively on
//  PlayerViewModel (via cached `nowPlayingDisplay` + `makeNowPlayingDisplayModel`).
//
//  This follows the same narrow contract as `StatusPill` and widget/Live Activity
//  metadata regions (no full model, no derivation inside the view).
//
//  Created by Jari Lammi on 13.6.2026.
//

import SwiftUI
import WidgetSurface

/// Pure SwiftUI representation of the now-playing text block + speaker/program photo.
///
/// Receives only the narrow pre-computed `displayModel`. No `PlayerViewModel`,
/// no `StreamProgramMetadata`, and no derivation inside the view body or init.
///
/// - `showPhoto`: retained as a simple layout flag from the composition root
///   so the same view can be used with/without the photo block.
///
/// Uses `.contentTransition(.numericText())` on the main text for smooth updates.
///
/// All formatting, "Jari Lammi" photo resolution, and accessibility derivation
/// are performed in `makeNowPlayingDisplayModel` (cached on the view model).
///
/// - SeeAlso: ``NowPlayingDisplayModel``, ``makeNowPlayingDisplayModel(metadata:)``,
///   ``PlayerViewModel/nowPlayingDisplay``, `RadioPlayerView`, `StatusPill`,
///   `WidgetNowPlayingDisplayModel` (widget/LA parity),
///   CODING_AGENT.md (narrow inputs for separate View types, cached derived values on @Observable models),
///   docs/Widget-Presentation-Dataflow.md.
///
/// The narrow-input pattern here (receive only `displayModel: NowPlayingDisplayModel` +
/// a simple `showPhoto` flag) is now consistent with `StatusPill` (receives only
/// `PlayerStatusPresentation`) and the widget/Live Activity leaf surfaces.
struct NowPlayingMetadataView: View {
    /// The complete narrow model for this region.
    /// All text, photo decision, and a11y strings are supplied ready to use.
    let displayModel: NowPlayingDisplayModel

    /// Whether the photo (or placeholder) block is shown.
    /// Controlled by the composition root; keeps the leaf view focused on rendering.
    var showPhoto: Bool = true

    var body: some View {
        VStack(spacing: 8) {
            // The display text is already fully formatted by the model.
            Text(displayModel.displayText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .contentTransition(.numericText())
                .accessibilityLabel(displayModel.accessibilityText)
                .accessibilityHint(String(localized: "accessibility_hint_metadata", table: "Localizable"))

            // Photo block (shown below language selector in classic layout).
            // When `photoName` is non-nil we use the special asset (Jari Lammi case).
            // Otherwise the standard radio placeholder is shown.
            if showPhoto {
                if let imageName = displayModel.photoName,
                   let uiImage = UIImage(named: imageName) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel(displayModel.photoAccessibilityLabel)
                        .transition(.opacity.combined(with: .scale))
                } else if let placeholder = UIImage(named: "radio-placeholder") {
                    Image(uiImage: placeholder)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel(
                            String(localized: "accessibility_label_lutheran_radio_logo",
                                   defaultValue: "Lutheran Radio Logo",
                                   table: "Localizable")
                        )
                        .transition(.opacity)
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Metadata + Photo") {
    let vm = PlayerViewModel.makeMock(currentMetadata: StreamProgramMetadata(programTitle: "Sunday Sermon", speaker: "Jari Lammi"))
    NowPlayingMetadataView(displayModel: vm.nowPlayingDisplay)
        .padding()
}

#Preview("No track info") {
    let vm = PlayerViewModel.makeMock(currentMetadata: nil)
    NowPlayingMetadataView(displayModel: vm.nowPlayingDisplay)
        .padding()
}
#endif
