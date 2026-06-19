//
//  NowPlayingMetadataView.swift
//  Lutheran Radio
//
//  Pure SwiftUI presentation of the Now Playing metadata (program title + speaker) plus
//  conditional speaker / program photo (Jari Lammi special case + placeholder).
//
//  Replaces the prior vended-UILabel + UIImageView holder.
//
//  Created by Jari Lammi on 13.6.2026.
//

import SwiftUI

/// Pure SwiftUI representation of the now-playing text block + speaker/program photo.
///
/// Consumes `StreamProgramMetadata` from the view model.
/// Replicates the previous name-detection logic for the special photo case.
///
/// Uses `.contentTransition(.numericText())` on the main text for smooth updates (as specified).
///
/// - SeeAlso: ``StreamProgramMetadata``, ``PlayerViewModel``, CODING_AGENT.md.
struct NowPlayingMetadataView: View {
    let viewModel: PlayerViewModel
    var showPhoto: Bool = true

    private var metadata: StreamProgramMetadata? { viewModel.currentMetadata }

    private var speakerPhotoName: String? {
        guard let meta = metadata, meta.hasDisplayableContent else { return nil }
        let names = potentialNames(from: displayText)
        if names.contains("Jari Lammi") { return "jari_lammi_photo" }
        return nil
    }

    private var displayText: String {
        guard let m = metadata else {
            return String(localized: "no_track_info", table: "Localizable")
        }
        if let title = m.programTitle, let speaker = m.speaker {
            return "\(speaker) — \(title)"
        } else if let title = m.programTitle {
            return title
        } else if let speaker = m.speaker {
            return speaker
        } else {
            return String(localized: "no_track_info", table: "Localizable")
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            // Clean metadata text
            Text(displayText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .contentTransition(.numericText())
                .accessibilityLabel(accessibilityText)
                .accessibilityHint(String(localized: "accessibility_hint_metadata", table: "Localizable"))

            // Photo block (shown below language selector in classic layout)
            if showPhoto {
                if let imageName = speakerPhotoName, let uiImage = UIImage(named: imageName) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel(photoAccessibilityLabel)
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

    private var accessibilityText: String {
        let noTrack = String(localized: "no_track_info", table: "Localizable")
        if displayText != noTrack {
            let prefix = String(localized: "Now Playing", defaultValue: "Now Playing", table: "Localizable")
            return "\(prefix): \(displayText)"
        }
        return displayText
    }

    private var photoAccessibilityLabel: String {
        if let s = metadata?.speaker {
            return unsafe String(
                format: String(localized: "accessibility_label_photo_of_format", defaultValue: "Photo of %@", table: "Localizable", comment: "Accessibility label for speaker photo. %@ is the speaker or program name."),
                s
            )
        }
        return String(localized: "accessibility_label_lutheran_radio_logo", defaultValue: "Lutheran Radio Logo", table: "Localizable")
    }

    // Port of the small pure regex helper for speaker name detection (used only for photo logic).
    private func potentialNames(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        do {
            let regex = try NSRegularExpression(pattern: "\\b[A-Z][a-z]+(?:\\s[A-Z][a-z]+)*\\b")
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            return matches.compactMap { match in
                Range(match.range, in: text).map { String(text[$0]) }
            }
        } catch {
            return []
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Metadata + Photo") {
    NowPlayingMetadataView(
        viewModel: .makeMock(currentMetadata: StreamProgramMetadata(programTitle: "Sunday Sermon", speaker: "Jari Lammi"))
    )
    .padding()
}

#Preview("No track info") {
    NowPlayingMetadataView(viewModel: .makeMock(currentMetadata: nil))
    .padding()
}
#endif
