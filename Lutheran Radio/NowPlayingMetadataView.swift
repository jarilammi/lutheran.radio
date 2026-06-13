//
//  NowPlayingMetadataView.swift
//  Lutheran Radio
//
//  Encapsulates the Now Playing metadata label (with full hyphenation + accessibility) and the speaker/
/// program image view (specific-speaker photo matching for "Jari Lammi", placeholder fallback, cross-dissolve
//  transitions, height constraint management).
//
//  The two elements are owned here even though placed at different points in the vertical layout (metadata label
//  above the language selector, speaker photo below it). Owner (ViewController) performs addSubview + constraints
//  using the vended elements (identical to BackgroundImageController pattern).
//
//  Created by Jari Lammi on 13.6.2026.
//

import UIKit

/// Presentational owner for the metadata label + speaker image (and their update/apply logic).
///
/// Responsibilities (moved verbatim from ViewController):
/// - Creation and initial configuration of metadataLabel (callout font, secondary color, numberOfLines=0, hyphenation support) and speakerImageView (cornerRadius=10, clipsToBounds, hidden by default).
/// - The pure regex helper `potentialNames(from:)` (small pure helper as requested; removes duplication).
/// - `setMetadata(_:)` — attributed text with hyphenation, accessibility prefixing ("Now Playing"), announcement.
/// - `applySpeakerVisuals(for:potentialNames:animated:)` — exact "Jari Lammi" match + asset name mangling, cross-dissolve or immediate, height constant = 100, placeholder "radio-placeholder", accessibility labels, fallback hide + debug.
///
/// Owner retains:
/// - All call-site timing (onMetadataChange, finishSleepTimerInteraction, cold-launch completeStreamSwitch, no-internet, etc.).
/// - Sleep timer suppression via isSleepTimerInteractionActive + pendingMetadataVisualRefresh.
/// - updateNowPlayingInfo() and widget save side effects.
/// - Layout (add + the existing vertical constraints between volume / contentStack / language / speaker / airplay).
///
/// All observable behavior (text updates, hyphenation, speaker photo appear/disappear for the specific name,
/// animated vs non-animated transitions, accessibility strings, radio-placeholder fallback) must remain identical.
/// No new Localizable strings. No force-unwraps introduced.
@MainActor
final class NowPlayingMetadataView {

    // MARK: - Public surface (vended elements + drive methods)
    let metadataLabel: UILabel
    let speakerImageView: UIImageView

    /// Stored so applySpeakerVisuals can mutate the constant (owner activates the initial =50 constraint after addSubview).
    var speakerImageHeightConstraint: NSLayoutConstraint?

    // MARK: - Init
    init() {
        // Metadata label (exact creation from ViewController)
        let label = UILabel()
        label.text = String(localized: "no_track_info", table: "Localizable")
        label.textAlignment = .center
        label.font = UIFont.preferredFont(forTextStyle: .callout)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        self.metadataLabel = label

        // Speaker image (exact creation from ViewController)
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isHidden = true // Hidden by default
        imageView.layer.cornerRadius = 10
        imageView.clipsToBounds = true
        imageView.isAccessibilityElement = false
        self.speakerImageView = imageView
    }

    // MARK: - Pure helper (regex moved here; used by owner for pre-compute in onMetadataChange and by apply)
    func potentialNames(from metadata: String) -> [String] {
        do {
            let regex = try NSRegularExpression(pattern: "\\b[A-Z][a-z]+(?:\\s[A-Z][a-z]+)*\\b")
            let matches = regex.matches(in: metadata, range: NSRange(metadata.startIndex..., in: metadata))
            return matches.compactMap { match in
                Range(match.range, in: metadata).map { String(metadata[$0]) }
            }
        } catch {
            return []
        }
    }

    // MARK: - Public drive API

    /// Hyphenation + attributed text + accessibility (moved from updateMetadataLabel).
    /// Skip if unchanged. "Now Playing" prefix only for VoiceOver when real track info.
    func setMetadata(_ text: String) {
        if metadataLabel.text == text { return }

        // Enable hyphenation via attributed text
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.hyphenationFactor = 1.0  // Full hyphenation

        let attributes: [NSAttributedString.Key: Any] = [
            .font: metadataLabel.font ?? UIFont.preferredFont(forTextStyle: .callout),
            .foregroundColor: metadataLabel.textColor ?? .secondaryLabel,
            .paragraphStyle: paragraphStyle
        ]

        let attributedText = NSAttributedString(string: text, attributes: attributes)
        metadataLabel.attributedText = attributedText

        // Accessibility reads full text regardless of truncation.
        // Visible text stays as track info only; prefix "Now Playing" for VoiceOver when streaming.
        let noTrackInfo = String(localized: "no_track_info", table: "Localizable")
        if text != noTrackInfo {
            let nowPlaying = String(localized: "Now Playing", defaultValue: "Now Playing", table: "Localizable")
            metadataLabel.accessibilityLabel = "\(nowPlaying): \(text)"
        } else {
            metadataLabel.accessibilityLabel = text
        }

        // Announce metadata changes if significant
        if text != noTrackInfo {
            unsafe UIAccessibility.post(notification: .announcement, argument: text)
        }
    }

    /// Speaker photo logic (moved verbatim from ViewController.applySpeakerVisuals).
    /// Hard-coded specific speaker set + asset naming convention + animated/non-animated paths + placeholder.
    /// Mutates the vended speakerImageView and the height constraint owned here.
    func applySpeakerVisuals(for metadata: String, potentialNames: [String], animated: Bool = true) {
        let specificSpeakers = Set(["Jari Lammi"])
        let matchedSpeaker = potentialNames.first(where: { specificSpeakers.contains($0) })

        if let speaker = matchedSpeaker,
           let speakerImage = UIImage(named: "\(speaker.lowercased().replacingOccurrences(of: " ", with: "_"))_photo") {
            if animated {
                UIView.transition(with: speakerImageView, duration: 0.3, options: .transitionCrossDissolve, animations: {
                    self.speakerImageView.image = speakerImage
                    self.speakerImageView.isHidden = false
                    self.speakerImageHeightConstraint?.constant = 100
                    self.speakerImageView.accessibilityLabel = unsafe String(format: String(localized: "accessibility_label_photo_of_format", defaultValue: "Photo of %@", table: "Localizable", comment: "Accessibility label for speaker photo. %@ is the speaker or program name."), speaker)
                }, completion: nil)
            } else {
                speakerImageView.image = speakerImage
                speakerImageView.isHidden = false
                speakerImageHeightConstraint?.constant = 100
                speakerImageView.accessibilityLabel = unsafe String(format: String(localized: "accessibility_label_photo_of_format", defaultValue: "Photo of %@", table: "Localizable", comment: "Accessibility label for speaker photo. %@ is the speaker or program name."), speaker)
            }
        } else if let placeholderImage = UIImage(named: "radio-placeholder") {
            if animated {
                UIView.transition(with: speakerImageView, duration: 0.3, options: .transitionCrossDissolve, animations: {
                    self.speakerImageView.image = placeholderImage
                    self.speakerImageView.isHidden = false
                    self.speakerImageHeightConstraint?.constant = 100
                    self.speakerImageView.accessibilityLabel = String(localized: "accessibility_label_lutheran_radio_logo", defaultValue: "Lutheran Radio Logo", table: "Localizable", comment: "Accessibility label for the placeholder logo image.")
                }, completion: nil)
            } else {
                speakerImageView.image = placeholderImage
                speakerImageView.isHidden = false
                speakerImageHeightConstraint?.constant = 100
                speakerImageView.accessibilityLabel = String(localized: "accessibility_label_lutheran_radio_logo", defaultValue: "Lutheran Radio Logo", table: "Localizable", comment: "Accessibility label for the placeholder logo image.")
            }
        } else {
            #if DEBUG
            print("[NowPlayingMetadataView] Still failed to load radio-placeholder from Assets.xcassets")
            #endif
            speakerImageView.isHidden = true
        }
    }
}
