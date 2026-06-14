//
//  PlaybackControlsView.swift
//  Lutheran Radio
//
//  Encapsulates the playback controls bar: play/pause button, sleep timer button (menu attachment point for owner),
//  and the playback status (colored rounded label driven by PlayerVisualState).
//
//  Created by Jari Lammi on 13.6.2026.
//

import UIKit

/// Self-contained presentational view for the top controls row (play/pause + sleep timer + playback status).
///
/// Responsibilities (moved verbatim from ViewController):
/// - Creation and configuration of the three sub-elements (initial images, colors, corner styling for playback status, accessibility).
/// - Internal horizontal UIStackView + sizing constraints (50x50 play, 44x44 sleep, playback status min-width + height + relative max).
/// - Dumb update APIs: applyVisualState (main path from updateUI), setStatus (legacy/error paths), setPlayPause (with optional cross-dissolve), applySleepTimerButtonAppearance (image/tint/accValue for countdown).
///
/// The owner (ViewController) retains:
/// - All sleep timer menu construction + countdown Task state + interaction flags (deep coupling to SharedPlayerManager + SleepTimer).
/// - Press animation + rate-limiting in togglePlayback (targets the exposed playPauseButton).
/// - Attachment of UIMenu to the exposed sleepTimerButton.
/// - Accessibility custom actions and any higher-level orchestration.
///
/// All observable behavior (initial appearance, status color/text changes, play/pause icon swap with/without animation,
/// sleep timer icon + indigo tint + remaining minutes acc value, playback status cornerRadius=8) must remain pixel- and timing-identical.
///
/// No new Localizable strings. No force-unwraps on production paths. No security or intent logic here.
@MainActor
final class PlaybackControlsView: UIView {

    // MARK: - Public surface (exposed for owner wiring only; no decision logic here)
    /// Exposed so owner can attach the dynamic UIMenu (configureSleepTimerButtonMenu) and showsMenuAsPrimaryAction.
    public private(set) var sleepTimerButton: UIButton

    /// Exposed so owner can drive press animation + temporary isUserInteractionEnabled rate-limit inside togglePlayback.
    public private(set) var playPauseButton: UIButton

    /// Exposed for any remaining direct-site compatibility (prefer the setters below).
    public private(set) var statusLabel: UILabel

    // MARK: - Sleep timer images (moved verbatim from ViewController)
    private lazy var sleepTimerSymbolConfig = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
    private lazy var sleepTimerInactiveImage = UIImage(systemName: "moon.zzz", withConfiguration: sleepTimerSymbolConfig)
    private lazy var sleepTimerActiveImage = UIImage(systemName: "moon.zzz.fill", withConfiguration: sleepTimerSymbolConfig)

    // MARK: - Initialization
    override init(frame: CGRect) {
        // Create the three elements exactly as they were in the monolithic ViewController (initial state + styling + localization + accessibility).
        let playConfig = UIImage.SymbolConfiguration(weight: .bold)
        let playButton = UIButton(type: .system)
        playButton.setImage(UIImage(systemName: "play.fill", withConfiguration: playConfig), for: .normal)
        playButton.tintColor = .tintColor
        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.isAccessibilityElement = true
        playButton.accessibilityTraits = .button
        playButton.accessibilityHint = String(localized: "accessibility_hint_play_pause", table: "Localizable")
        self.playPauseButton = playButton

        let sleepConfig = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        let sleepButton = UIButton(type: .system)
        sleepButton.setImage(UIImage(systemName: "moon.zzz", withConfiguration: sleepConfig), for: .normal)
        sleepButton.tintColor = .secondaryLabel
        sleepButton.translatesAutoresizingMaskIntoConstraints = false
        sleepButton.isAccessibilityElement = true
        sleepButton.accessibilityTraits = .button
        sleepButton.accessibilityLabel = String(localized: "accessibility_label_sleep_timer", table: "Localizable")
        sleepButton.accessibilityHint = String(localized: "accessibility_hint_sleep_timer", table: "Localizable")
        self.sleepTimerButton = sleepButton

        let status = UILabel()
        status.text = String(localized: "status_connecting", table: "Localizable")
        status.textAlignment = .center
        status.font = UIFont.preferredFont(forTextStyle: .body)
        status.adjustsFontForContentSizeCategory = true
        status.backgroundColor = .systemYellow
        status.textColor = .black
        status.layer.cornerRadius = 8
        status.clipsToBounds = true
        status.translatesAutoresizingMaskIntoConstraints = false
        status.adjustsFontSizeToFitWidth = true
        status.minimumScaleFactor = 0.75
        status.lineBreakMode = .byTruncatingTail
        status.isAccessibilityElement = true
        self.statusLabel = status

        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setupStack()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupStack() {
        let stack = UIStackView(arrangedSubviews: [playPauseButton, sleepTimerButton, statusLabel])
        stack.axis = .horizontal
        stack.spacing = 20
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Sizing moved from ViewController setupUI (preserved verbatim for identical layout)
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.4),
            statusLabel.heightAnchor.constraint(equalToConstant: 40),
            playPauseButton.widthAnchor.constraint(equalToConstant: 50),
            playPauseButton.heightAnchor.constraint(equalToConstant: 50),
            sleepTimerButton.widthAnchor.constraint(equalToConstant: 44),
            sleepTimerButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    // MARK: - Public drive API (dumb presentational updates — owner owns visual state + sleep logic)

    /// Primary path from ViewController.updateUI(for:). Sets playback status text/color (from PlayerVisualState) + play/pause icon.
    /// Security alert side-effect for .securityLocked remains in the owner.
    func applyVisualState(_ visualState: PlayerVisualState) {
        // Text (exact cases from the original single source of truth in updateUI)
        switch visualState {
        case .playing:
            statusLabel.text = String(localized: "status_playing", table: "Localizable")
        case .userPaused:
            statusLabel.text = String(localized: "status_paused", table: "Localizable")
        case .thermalPaused:
            statusLabel.text = String(localized: "status_thermal_paused", table: "Localizable")
        case .prePlay:
            statusLabel.text = String(localized: "status_connecting", table: "Localizable")
        case .securityLocked:
            statusLabel.text = String(localized: "status_security_failed", table: "Localizable")
        }

        statusLabel.backgroundColor = visualState.backgroundColor
        statusLabel.textColor = visualState.textColor
        statusLabel.accessibilityLabel = statusLabel.text

        // Play/pause icon (matches the non-animated path in original updateUI)
        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .bold)
        let imageName = visualState.isActivelyPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: imageName, withConfiguration: config), for: .normal)

        #if DEBUG
        print("[PlaybackControlsView] applyVisualState → \(visualState)")
        #endif
    }

    /// For legacy / error / no-internet paths that compute explicit text + colors (safeUpdateStatusLabel, updateStatusLabel, etc.).
    func setStatus(text: String, backgroundColor: UIColor, textColor: UIColor) {
        if statusLabel.text == text { return }
        statusLabel.text = text
        statusLabel.backgroundColor = backgroundColor
        statusLabel.textColor = textColor
        statusLabel.accessibilityLabel = text
    }

    /// Supports the animated and non-animated play/pause icon swaps (moved from updatePlayPauseButton).
    /// Used by stream-switch optimistic updates and other direct call sites.
    func setPlayPause(isPlaying: Bool, animated: Bool = false) {
        let imageName = isPlaying ? "pause.fill" : "play.fill"
        let config = UIImage.SymbolConfiguration(weight: .bold)
        let newImage = UIImage(systemName: imageName, withConfiguration: config)

        if animated {
            UIView.transition(with: playPauseButton, duration: 0.22, options: .transitionCrossDissolve, animations: {
                self.playPauseButton.setImage(newImage, for: .normal)
            })
        } else {
            playPauseButton.setImage(newImage, for: .normal)
        }

        playPauseButton.accessibilityLabel = isPlaying
            ? String(localized: "accessibility_label_play_pause", table: "Localizable")
            : String(localized: "accessibility_label_play", table: "Localizable")
    }

    /// Sleep timer button appearance (icon swap + tint + accessibility value with remaining minutes).
    /// Called by owner's begin/stopLocalSleepTimerDisplay and finish paths (menu config + countdown state stays in owner).
    func applySleepTimerButtonAppearance(remaining: Int?, deferImageSwap: Bool = false) {
        if let remaining, remaining > 0 {
            if !deferImageSwap {
                sleepTimerButton.setImage(sleepTimerActiveImage, for: .normal)
            }
            sleepTimerButton.tintColor = .systemIndigo
            let minutes = max(1, (remaining + 59) / 60)
            sleepTimerButton.accessibilityValue = unsafe String(
                format: String(localized: "sleep_timer_accessibility_remaining", table: "Localizable"),
                minutes
            )
        } else {
            sleepTimerButton.setImage(sleepTimerInactiveImage, for: .normal)
            sleepTimerButton.tintColor = .secondaryLabel
            sleepTimerButton.accessibilityValue = nil
        }
    }
}
