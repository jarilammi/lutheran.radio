//
//  PlaybackKeyboardMenu.swift
//  Lutheran Radio
//
//  Localized titles and adjacent-stream index math for the main-menu / keyboard
//  playback verbs. Menu insertion and @objc actions live on AppDelegate so
//  UIMenuBuilder does not fall back to a Main storyboard (see
//  ``AppDelegate/buildMenu(with:)``). Execution stays on existing SSOTs:
//  ``ViewController/handleTogglePlayback()`` → ``userRequestedPlay()`` / ``stop()``,
//  and ``RadioPlayerCoordinator/handleLanguageSelection(at:)`` → ``completeStreamSwitch``.
//
//  Does not own audio session, volume, ActivityKit, or a new play entry.
//  Not Mac Catalyst. Designed-for-iPhone Mac and iPad hardware keyboards share
//  the same UIKit menu builder.
//
//  - SeeAlso: ``AppDelegate/buildMenu(with:)``,
//    ``RadioPlayerCoordinator/handleUserTogglePlayback()``,
//    ``RadioPlayerCoordinator/handleLanguageSelection(at:)``,
//    ``SharedPlayerManager/userRequestedPlay()``,
//    ``SharedPlayerManager/stop()``,
//    README.md (iOS App Store binary on Apple Silicon),
//    CODING_AGENT.md (Single Source of Truth Principles).
//
//  Created by Jari Lammi on 15.8.2026.
//

import UIKit

/// Localized main-menu titles and wrapping adjacent-stream index math for keyboard verbs.
///
/// ``AppDelegate/buildMenu(with:)`` inserts a Playback sibling after `.view` using these
/// titles. Space toggles play/pause; ⌘[ / ⌘] move one slot in
/// ``DirectStreamingPlayer/availableStreams``. Index wrap is pure so unit tests do not
/// need a coordinator or engine.
///
/// - Important: Do not call ``play()`` from these verbs. Play goes through
///   ``userRequestedPlay()`` via ``handleTogglePlayback()``. Language uses
///   ``handleLanguageSelection(at:)`` (main-app flag-tap orchestration), not a
///   second switch path.
/// - SeeAlso: ``AppDelegate/buildMenu(with:)``,
///   ``RadioPlayerCoordinator/handleAdjacentLanguageSelection(offset:)``,
///   ``DirectStreamingPlayer/availableStreams``.
enum PlaybackKeyboardMenu: Sendable {

    /// UIMenu identifier for the Playback sibling inserted by ``AppDelegate/buildMenu(with:)``.
    static let menuIdentifier = UIMenu.Identifier("net.siikkari.lutheranradio.menu.playback")

    /// Menu bar title for the Playback sibling.
    static var playbackMenuTitle: String {
        String(
            localized: "menu_playback",
            defaultValue: "Playback",
            table: "Localizable",
            comment: "Main menu title for play/pause and previous/next language keyboard verbs"
        )
    }

    /// Play/Pause command title (Space).
    static var playPauseTitle: String {
        String(
            localized: "menu_play_pause",
            defaultValue: "Play/Pause",
            table: "Localizable",
            comment: "Menu and keyboard shortcut that toggles play or pause"
        )
    }

    /// Previous-language command title (⌘[).
    static var previousLanguageTitle: String {
        String(
            localized: "menu_previous_language",
            defaultValue: "Previous Language",
            table: "Localizable",
            comment: "Menu and keyboard shortcut that selects the previous radio language stream"
        )
    }

    /// Next-language command title (⌘]).
    static var nextLanguageTitle: String {
        String(
            localized: "menu_next_language",
            defaultValue: "Next Language",
            table: "Localizable",
            comment: "Menu and keyboard shortcut that selects the next radio language stream"
        )
    }

    /// Returns the wrapping catalog index for a previous/next language verb.
    ///
    /// - Parameters:
    ///   - current: Current index into ``DirectStreamingPlayer/availableStreams``.
    ///   - offset: Signed step (`-1` previous, `+1` next). Other magnitudes wrap the same way.
    ///   - count: Catalog length. Empty catalogs return `nil`.
    /// - Returns: Wrapped index in `0 ..< count`, or `nil` when `count` is not positive.
    /// - Note: A current index outside `0 ..< count` is normalized before applying `offset`.
    /// - SeeAlso: ``RadioPlayerCoordinator/handleAdjacentLanguageSelection(offset:)``
    static func adjacentStreamIndex(current: Int, offset: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let normalizedCurrent = ((current % count) + count) % count
        return ((normalizedCurrent + offset) % count + count) % count
    }
}
