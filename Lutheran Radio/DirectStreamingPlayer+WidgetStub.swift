//
//  DirectStreamingPlayer+WidgetStub.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 23.7.2026.
//
//  Widget-extension / LutheranRadioWidgetTests type surface for DirectStreamingPlayer.
//  Compiled into the extension and widget-test targets via membershipExceptions
//  (see project.pbxproj). The main-app engine lives only in DirectStreamingPlayer.swift.
//
//  Purpose:
//  Provides the minimal surface SharedPlayerManager and widget code need to type-check
//  references such as DirectStreamingPlayer.Stream, .availableStreams, stream lookup,
//  selectedStream, prepareStreamChoice, attachAndPlay, switchToStream, stop, isActuallyPlaying,
//  player, audio no-op methods (including local-clip start), and StreamErrorType.
//
//  Single source of truth for the stream *list* remains DirectStreamingPlayer.swift (main).
//  Keep this stub list + lookup logic in sync with DirectStreamingPlayer+StreamCatalog.swift.
//
//  SECURITY: This stub contains no certificate, DNS, or validation logic.
//  All security flows are in Core/ and only execute in the main app process.
//
//  - SeeAlso: DirectStreamingPlayer.swift, SharedPlayerManager.swift,
//    CODING_AGENT.md (cross-target membership exceptions).
//

import Foundation
import WidgetSurface
// SAFETY: `@unsafe @preconcurrency` required under SWIFT_STRICT_MEMORY_SAFETY for AVFoundation;
// widget stub only needs `AVAudioPlayer` in the local-clip no-op signature for type parity with main.
@unsafe @preconcurrency import AVFoundation

#if !LUTHERAN_MAIN_APP
final class DirectStreamingPlayer: NSObject, @unchecked Sendable {
    /// A radio stream configuration (display + lookup only in widget/extension).
    /// url is a placeholder here; widget paths never access stream URLs.
    struct Stream: Sendable {
        let title: String
        let language: String
        let languageCode: String
        let flag: String

        var url: URL {
            // Placeholder only. Real URL construction (security_model + optimal server)
            // is performed exclusively inside DirectStreamingPlayer in the main target.
            URL(string: "https://livestream.lutheran.radio")!
        }
    }

    /// Must be kept identical to the list in DirectStreamingPlayer.swift
    static let availableStreams: [Stream] = [
        Stream(title: String(localized: "lutheran_radio_title", defaultValue: "Lutheran Radio", table: "Localizable", comment: "Title for Lutheran Radio") + " - " +
               String(localized: "language_english", defaultValue: "English", table: "Localizable", comment: "English language option"),
               language: String(localized: "language_english", defaultValue: "English", table: "Localizable", comment: "English language option"),
               languageCode: "en",
               flag: "🇺🇸"),
        Stream(title: String(localized: "lutheran_radio_title", defaultValue: "Lutheran Radio", table: "Localizable", comment: "Title for Lutheran Radio") + " - " +
               String(localized: "language_german", defaultValue: "German", table: "Localizable", comment: "German language option"),
               language: String(localized: "language_german", defaultValue: "German", table: "Localizable", comment: "German language option"),
               languageCode: "de",
               flag: "🇩🇪"),
        Stream(title: String(localized: "lutheran_radio_title", defaultValue: "Lutheran Radio", table: "Localizable", comment: "Title for Lutheran Radio") + " - " +
               String(localized: "language_finnish", defaultValue: "Finnish", table: "Localizable", comment: "Finnish language option"),
               language: String(localized: "language_finnish", defaultValue: "Finnish", table: "Localizable", comment: "Finnish language option"),
               languageCode: "fi",
               flag: "🇫🇮"),
        Stream(title: String(localized: "lutheran_radio_title", defaultValue: "Lutheran Radio", table: "Localizable", comment: "Title for Lutheran Radio") + " - " +
               String(localized: "language_swedish", defaultValue: "Swedish", table: "Localizable", comment: "Swedish language option"),
               language: String(localized: "language_swedish", defaultValue: "Swedish", table: "Localizable", comment: "Swedish language option"),
               languageCode: "sv",
               flag: "🇸🇪"),
        Stream(title: String(localized: "lutheran_radio_title", defaultValue: "Lutheran Radio", table: "Localizable", comment: "Title for Lutheran Radio") + " - " +
               String(localized: "language_estonian", defaultValue: "Estonian", table: "Localizable", comment: "Estonian language option"),
               language: String(localized: "language_estonian", defaultValue: "Estonian", table: "Localizable", comment: "Estonian language option"),
               languageCode: "et",
               flag: "🇪🇪"),
    ]

    static func bestInitialLanguageCode() -> String {
        let supported = Set(Self.availableStreams.map { $0.languageCode })

        for raw in Bundle.main.preferredLocalizations {
            let candidate = raw.split(separator: "-").first.map(String.init) ?? raw
            if supported.contains(candidate) {
                return candidate
            }
        }

        for raw in Locale.preferredLanguages {
            let candidate = raw.split(separator: "-").first.map(String.init) ?? raw
            if supported.contains(candidate) {
                return candidate
            }
        }

        if let current = Locale.current.language.languageCode?.identifier,
           supported.contains(current) {
            return current
        }

        return "en"
    }

    static func indexForLanguageCode(_ languageCode: String) -> Int {
        availableStreams.firstIndex(where: { $0.languageCode == languageCode }) ?? 0
    }

    static func streamForLanguageCode(_ languageCode: String) -> Stream {
        availableStreams.first(where: { $0.languageCode == languageCode }) ?? availableStreams[0]
    }

    static let shared = DirectStreamingPlayer()

    private override init() {
        selectedStream = Self.streamForLanguageCode(Self.bestInitialLanguageCode())
        super.init()
    }

    var selectedStream: Stream

    func prepareStreamChoice(_ stream: Stream, preparation: StreamChoicePreparation) async {
        selectedStream = stream
    }

    func setSelectedStreamModelOnly(to stream: Stream) async {
        await prepareStreamChoice(stream, preparation: .modelOnly)
    }

    func switchToStream(_ stream: Stream) async {
        await prepareStreamChoice(stream, preparation: .switchPrep)
    }

    func attachAndPlay(to stream: Stream, context: PlaybackAttachContext = .coldLaunch) async {
        selectedStream = stream
    }

    func setStreamAndPlay(to stream: Stream, context: PlaybackAttachContext = .coldLaunch) async {
        await attachAndPlay(to: stream, context: context)
    }

    func stop() {}

    func stop(
        reason: StopReason = .userAction,
        completion: (@MainActor @Sendable () -> Void)? = nil,
        silent: Bool = false,
        applyUserPauseVisualLock: Bool = true
    ) {
        // Widget stub: no engine work. Resume completion on MainActor to match the real
        // DirectStreamingPlayer contract (completion is MainActor-isolated).
        guard let completion else { return }
        Task { @MainActor in
            completion()
        }
    }

    func stopAndWait(
        reason: StopReason = .userAction,
        silent: Bool = false,
        applyUserPauseVisualLock: Bool = true
    ) async {
        // Widget stub: no soft-pause engine; return immediately.
    }

    func isActuallyPlaying() -> Bool { false }

    var player: Any? { nil }

    func resumeFromSoftPauseIfAvailable() async -> Bool { false }

    func softPauseResumeRequiresStreamReattach() async -> Bool { false }

    func resetInitialPlaybackCountersForNewStream() {}

    func isLastErrorPermanent() async -> Bool { false }

    var hasPermanentError: Bool { false }

    // Lightweight no-op paths for audio session when this stub is used (widget extension).
    // The real implementations (with #available(iOS 27.0, *) + setActive paths + off-main dispatch
    // + local-clip start) live only in the main-target DirectStreamingPlayer.swift and are
    // never compiled into the widget target.
    @MainActor
    func configureAudioSessionAsync() async -> Bool { false }

    @MainActor
    func setupAudioSession() async {}

    @MainActor
    func deactivateAudioSessionAsync() async -> Bool { true }

    /// Widget stub: no local `AVAudioPlayer` work in the extension process.
    /// - SeeAlso: Main-target ``DirectStreamingPlayer/startLocalClipPlayer(contentsOf:volume:numberOfLoops:)``.
    @MainActor
    func startLocalClipPlayer(
        contentsOf url: URL,
        volume: Float = 1.0,
        numberOfLoops: Int = 0
    ) async throws -> (player: AVAudioPlayer, didStart: Bool)? {
        nil
    }

}
#endif
