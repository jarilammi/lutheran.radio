//
//  PlayerViewModel.swift
//  Lutheran Radio
//
//  @Observable ViewModel (Observation framework, Swift 6 style) for the main player UI.
//
//  Purpose:
//  Provides a single observable surface for SwiftUI views (current or future) that need to
//  react to playback visual state, language selection, ICY program metadata, sleep timer
//  countdown (and dialog conditional), stream switching in-flight flag, and basic error/security surface.
//
//  This is a *presentation adapter*, not a source of truth.
//  - Visual state + playback intent authority remains in SharedPlayerManager (actor).
//  - `SharedPlayerManager` is the authoritative emitter of `PlayerEvent`; the coordinator
//    currently pushes state derived from those transitions (and direct surfaces) into this VM.
//    Future surfaces may subscribe to the event stream directly (additive, non-forcing).
//  - Complex orchestration (debounce, tuning sound sequencing, optimistic prePlay timing,
//    intent guards, widget reconciliation) remains exclusively in RadioPlayerCoordinator.
//  - The coordinator (orchestrator) pushes updates into this VM so SwiftUI can observe.
//
//  Bridging strategy (see RadioPlayerCoordinator):
//  - Direct optional reference from coordinator (fast, keeps timing control in one place).
//  - Sleep timer uses existing SleepTimerNotification + coordinator's local countdown glue
//    (pushed here too). Presentation (confirmationDialog) + choices live in SwiftUI;
//    all set/cancel + sync logic remains in coordinator.
//  - Metadata arrives via DirectStreamingPlayer.onMetadataChange (forwarded here).
//  - selectedStreamIndex and isSwitchingStream are mirrored from coordinator / player.
//
//  Action methods (`play()`, `pause()`, `selectLanguage(at:)`) forward via injected
//  closures. This lets SwiftUI call them without a direct dependency on the UIKit coordinator
//  or having to know about SharedPlayerManager actor hops. All explicit play requests
//  ultimately reach `SharedPlayerManager.userRequestedPlay()` (the designated path).
//
//  Presentation concerns:
//  - The three narrow cached presentation surfaces (`statusPresentation`,
//    `controlPresentation`, `nowPlayingDisplay`) are derived here and supplied to
//    leaf views. Derivation and ownership stay on the model; views receive only what
//    they render. See the "Main Player Presentation Dataflow" section below.
//  - Other derived values (e.g. `sleepTimerAccessibilityValue`) also live here as
//    cached/computed properties so that SwiftUI view bodies contain layout + modifiers only.
//
//  Previews:
//  Use `PlayerViewModel.makeMock(...)` to obtain an isolated instance for #Preview and tests.
//  No side effects or actor access from the mock path.
//
//  - Important: Do not duplicate resurrection rules, intent logic, or security decisions here.
//  - SeeAlso: RadioPlayerCoordinator (the driver), SharedPlayerManager (SSOT + ``events``),
//    ``PlayerVisualState``, ``PlayerEvent``, StreamProgramMetadata.swift,
//    (see "Main Player Presentation Dataflow" section in this file for the three cached surfaces),
//    `WidgetNowPlayingDisplayModel` + docs/Widget-Presentation-Dataflow.md (widget/LA alignment),
//    CODING_AGENT.md (Single Source of Truth Principles + Cross-target shared files +
//    Documentation & Comment Standards + narrow inputs + event-driven direction),
//    <doc:Architecture>, docs/Event-Driven-Refactor-Roadmap.md.
//
//  Created by Jari Lammi on 19.6.2026.
//

import Foundation
import Observation
import SwiftUI

// MARK: - Main Player Presentation Dataflow
//
// The main player UI is built around three narrow, cached presentation surfaces
// owned by `PlayerViewModel` (live @Observable @MainActor model). This is the
// in-process counterpart to the snapshot-driven contract used for widgets and
// Live Activities.
//
// The three narrow presentation surfaces cached on this model are:
//
//   • `statusPresentation: PlayerStatusPresentation`
//     — background/foreground/text (and optional glyph) for the status indicator.
//     Derived via `visualState.makeStatusPresentation()`. Consumed by `StatusPill`.
//
//   • `controlPresentation: PlayerControlPresentation`
//     — `systemImage` + `tint` for the primary play/pause control.
//     Derived via `visualState.makeControlPresentation()`.
//
//   • `nowPlayingDisplay: NowPlayingDisplayModel`
//     — pre-formatted `displayText`, resolved `photoName` (Jari Lammi special case),
//       `speakerVisible`, and accessibility strings. Derived via
//       `makeNowPlayingDisplayModel(metadata:)`.
//
// Derivation is performed exclusively in didSet observers on `visualState` and
// `currentMetadata` (via the private `recompute*` methods) so that no view body
// or initializer ever performs formatting, regex, or photo resolution.
//
// Leaf views receive only the narrow `let` values they render + action closures:
// `PlaybackControlsView`, `NowPlayingMetadataView`, `LanguageSelectorView`, and
// `StatusPill` never see the full model. `RadioPlayerView` is a thin composition
// root that holds the `@Bindable` and projects the slices at call sites.
//
// This architecture aligns the main player with the patterns established for
// widgets / Live Activities (see `WidgetNowPlayingDisplayModel`,
// `widgetNowPlayingDisplayModel(...)`, and docs/Widget-Presentation-Dataflow.md).
//
// - SeeAlso: `PlayerViewModel` (the cache owner), `NowPlayingDisplayModel`,
//   `PlayerStatusPresentation`, `PlayerControlPresentation`,
//   CODING_AGENT.md (narrow inputs for separate View types + cached derived values
//   on @Observable models + Documentation & Comment Standards).
//

// MARK: - NowPlayingDisplayModel (narrow presentation type for main player)

/// Narrow value type carrying the derived content for the main player's now-playing block.
///
/// Consumers (primarily `NowPlayingMetadataView`) should depend only on these fields.
/// The model is `Equatable` so that Observation and view diffs are cheap when content
/// is unchanged.
///
/// - Important: `PlayerViewModel` is the cache owner. Views must receive the
///   model as `let displayModel` (or equivalent) rather than re-deriving.
/// - SeeAlso: ``PlayerViewModel/nowPlayingDisplay``, `makeNowPlayingDisplayModel(metadata:)`,
///   `NowPlayingMetadataView`, `WidgetNowPlayingDisplayModel` (widget/LA parity),
///   docs/Widget-Presentation-Dataflow.md, CODING_AGENT.md (narrow inputs + cached derived values).
struct NowPlayingDisplayModel: Equatable {
    /// The formatted line to display (e.g. "Jari Lammi — Sunday Sermon", a title only,
    /// a speaker only, or the localized "No track information" placeholder).
    let displayText: String

    /// Resolved asset name for a special speaker photo, or nil when the standard
    /// radio placeholder should be used.
    ///
    /// Currently the only named special case is `"jari_lammi_photo"`.
    let photoName: String?

    /// Whether a speaker line is considered present for emphasis/visibility purposes.
    /// Retained for parity with the widget metadata model and future use.
    let speakerVisible: Bool

    /// Full accessibility label for the text content (includes "Now Playing:" prefix
    /// when real content is present).
    let accessibilityText: String

    /// Accessibility label for the photo (or placeholder logo) area.
    let photoAccessibilityLabel: String
}

/// Produces a `NowPlayingDisplayModel` by applying the canonical formatting,
/// Jari Lammi photo special-case, and accessibility rules to the supplied metadata.
///
/// This is the single source of truth for the main-player metadata/now-playing
/// presentation axis. It is called from `PlayerViewModel`'s didSet observers.
///
/// The special-case photo logic ("Jari Lammi") is implemented here via a small
/// pure helper (`potentialNames`) so that no View body or init ever performs
/// regex or name matching.
///
/// This mirrors the widget/Live Activity resolver `widgetNowPlayingDisplayModel(...)`
/// that produces `WidgetNowPlayingDisplayModel`.
///
/// - Parameter metadata: Optional program metadata from the stream.
/// - Returns: A complete narrow model. All strings are localized via the
///   "Localizable" table.
/// - SeeAlso: `WidgetNowPlayingDisplayModel`, `widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)`,
///   docs/Widget-Presentation-Dataflow.md.
func makeNowPlayingDisplayModel(metadata: StreamProgramMetadata?) -> NowPlayingDisplayModel {
    let displayText = makeDisplayText(from: metadata)
    let photoName = resolvedSpeakerPhotoName(from: displayText, metadata: metadata)
    let speakerVisible = (metadata?.speaker?.isEmpty == false)
    let accessibilityText = makeAccessibilityText(displayText: displayText)
    let photoAccessibilityLabel = makePhotoAccessibilityLabel(speaker: metadata?.speaker)

    return NowPlayingDisplayModel(
        displayText: displayText,
        photoName: photoName,
        speakerVisible: speakerVisible,
        accessibilityText: accessibilityText,
        photoAccessibilityLabel: photoAccessibilityLabel
    )
}

// MARK: - Pure derivation helpers (outside all view bodies)

private func makeDisplayText(from metadata: StreamProgramMetadata?) -> String {
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

/// Resolves the special "jari_lammi_photo" asset when the constructed display text
/// contains the recognized speaker name. All other cases (including other speakers
/// or no metadata) return nil so the caller shows the standard placeholder.
private func resolvedSpeakerPhotoName(from displayText: String, metadata: StreamProgramMetadata?) -> String? {
    guard let meta = metadata, meta.hasDisplayableContent else { return nil }
    let names = potentialNames(from: displayText)
    if names.contains("Jari Lammi") {
        return "jari_lammi_photo"
    }
    return nil
}

private func makeAccessibilityText(displayText: String) -> String {
    let noTrack = String(localized: "no_track_info", table: "Localizable")
    if displayText != noTrack {
        let prefix = String(localized: "Now Playing", defaultValue: "Now Playing", table: "Localizable")
        return "\(prefix): \(displayText)"
    }
    return displayText
}

private func makePhotoAccessibilityLabel(speaker: String?) -> String {
    if let s = speaker, !s.isEmpty {
        // SAFETY: String(format:) with a catalog-provided format string containing %@.
        // The format is trusted (Localizable.xcstrings) and the argument is the speaker name
        // taken directly from ICY metadata. Required under SWIFT_STRICT_MEMORY_SAFETY=YES.
        // This is the established pattern for speaker-specific VoiceOver labels.
        return unsafe String(
            format: String(localized: "accessibility_label_photo_of_format", defaultValue: "Photo of %@", table: "Localizable", comment: "Accessibility label for speaker photo. %@ is the speaker or program name."),
            s
        )
    }
    return String(localized: "accessibility_label_lutheran_radio_logo", defaultValue: "Lutheran Radio Logo", table: "Localizable")
}

/// Best-effort extraction of capitalized name-like tokens from the display text.
/// Used exclusively to implement the Jari Lammi special photo case.
/// Pure function with no side effects.
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

/// Observable presentation model for the player screen.
///
/// All properties are mutated on the @MainActor by the RadioPlayerCoordinator (or test/preview code).
/// SwiftUI views observe them directly via the Observation framework (no @Published needed).
///
/// Thread-safety: @MainActor isolation + coordinator is the only writer in production.
///
/// This VM is a narrow presentation adapter. State flows from the SSOTs in
/// `SharedPlayerManager` (visual + intent + `PlayerEvent` emissions). The coordinator
/// is responsible for observing authoritative changes (directly or via future event
/// subscription) and pushing the relevant slices here. Direct mutation of
/// `visualState`, `currentMetadata`, etc. is the current bridge mechanism only.
///
/// Sleep timer surface:
/// - `sleepTimerRemaining` is pushed by coordinator (via `syncSleepTimerToViewModel`).
/// - `selectSleepTimer(minutes:)` and `cancelSleepTimer()` forward to coordinator-owned logic
///   (the SwiftUI dialog in PlaybackControlsView is the caller). This keeps set/cancel, countdown
///   glue, and state sync in the single source of truth (coordinator + SharedPlayerManager).
///
/// Presentation derivation (cached / computed out of bodies):
/// - `statusPresentation` (stored, recomputed on visualState) follows the narrow value-type
///   input pattern for leaf views.
/// - `controlPresentation` (stored) provides glyph + tint for the primary play/pause control.
/// - `nowPlayingDisplay` (stored) owns the fully derived title/speaker text, Jari Lammi photo decision,
///   speaker visibility, and accessibility strings. Recomputed on `currentMetadata` changes and
///   relevant `visualState` changes so that `NowPlayingMetadataView` receives a narrow `let`.
/// - `sleepTimerAccessibilityValue` (computed) owns the a11y string derivation for the timer
///   button so that `PlaybackControlsView.body` contains only layout + modifiers.
///
/// - SeeAlso: `NowPlayingDisplayModel`, `makeNowPlayingDisplayModel(metadata:)`, `NowPlayingMetadataView`,
///   `PlayerStatusPresentation`, `PlayerControlPresentation`,
///   (see the "Main Player Presentation Dataflow" section at the top of this file),
///   `WidgetNowPlayingDisplayModel` (for widget/LA parity),
///   SharedPlayerManager (``events``, visual/intent SSOT),
///   ``PlayerEvent``, ``PlayerVisualState``,
///   CODING_AGENT.md (cached derived values on @Observable models,
///   narrow inputs for separate View types, Documentation & Comment Standards,
///   event-driven direction),
///   docs/Widget-Presentation-Dataflow.md,
///   docs/Event-Driven-Refactor-Roadmap.md.
@Observable
@MainActor
final class PlayerViewModel {

    // MARK: - Core observable state (as specified)

    /// Current visual appearance / status of playback (drives colors, labels, play/pause glyph).
    ///
    /// Setting this automatically recomputes the cached `statusPresentation` via didSet.
    /// The coordinator is the only writer in production.
    var visualState: PlayerVisualState = .prePlay {
        didSet {
            recomputePresentation()
            recomputeNowPlayingDisplay()
        }
    }

    // MARK: - Cached narrow presentation (derived)

    // The three narrow presentation surfaces cached on this model.
    // These are the authoritative derived values for the main player's UI:
    // - statusPresentation (for StatusPill and status text)
    // - controlPresentation (for play/pause glyph + tint)
    // - nowPlayingDisplay (for metadata text, photo decision, a11y)
    //
    // All three are recomputed in didSet observers and handed as narrow `let` values
    // to leaf views. This is the live-@Observable realization of the same three-axis
    // contract used by widgets / Live Activities (status + control + WidgetNowPlayingDisplayModel).

    /// Narrow, presentation-only snapshot for status UI.
    ///
    /// Populated from `visualState.makeStatusPresentation()` whenever `visualState` mutates.
    /// Leaf views (e.g. a `StatusPill`) should read this (or receive it directly as a `let`)
    /// rather than the full model or the policy enum when they only need colors + text.
    ///
    /// - Note: Stored + Equatable → Observation short-circuits when identical after a set.
    /// - SeeAlso: ``PlayerVisualState/makeStatusPresentation()``, dataflow guidance on caching derived.
    private(set) var statusPresentation: PlayerStatusPresentation = PlayerVisualState.prePlay.makeStatusPresentation()

    private(set) var controlPresentation: PlayerControlPresentation = PlayerVisualState.prePlay.makeControlPresentation()

    /// Narrow, pre-derived display model for the now-playing metadata region (title/speaker text,
    /// resolved photo asset decision for the Jari Lammi special case, accessibility strings).
    ///
    /// Updated via `recomputeNowPlayingDisplay()` on assignment to `currentMetadata` and on
    /// `visualState` changes (to cover any fallback text that may depend on state).
    /// Consuming views receive this as a `let` rather than performing derivation.
    ///
    /// - SeeAlso: `makeNowPlayingDisplayModel(metadata:)`, `NowPlayingMetadataView`.
    private(set) var nowPlayingDisplay: NowPlayingDisplayModel = makeNowPlayingDisplayModel(metadata: nil)

    /// Index into `DirectStreamingPlayer.availableStreams` that the UI believes is selected.
    /// Kept in sync by the coordinator (owner of selection math + needle).
    var selectedStreamIndex: Int = 0

    /// Parsed program / speaker metadata from the active ICY stream (if any).
    ///
    /// Assignment triggers recomputation of `nowPlayingDisplay`.
    var currentMetadata: StreamProgramMetadata? {
        didSet {
            recomputeNowPlayingDisplay()
        }
    }

    /// Remaining sleep timer duration in seconds. Nil when no timer is active.
    ///
    /// Updated by the coordinator's local countdown (beginLocalSleepTimerDisplay / Task)
    /// which also drives sync + icon state in PlaybackControlsView.
    /// The SwiftUI confirmationDialog reads this to decide whether to show the Cancel action.
    ///
    /// Derived presentation: `sleepTimerAccessibilityValue` consumes this to produce the
    /// VoiceOver string when active, keeping derivation logic out of SwiftUI bodies.
    var sleepTimerRemaining: TimeInterval?

    /// True while a user- or widget-initiated stream change is in progress (engine prep + potential tuning).
    /// Used by UI to suppress certain transitions or show activity.
    var isSwitchingStream: Bool = false

    // MARK: - Error / security alert surface

    /// When non-nil, a security or permanent error description is available for the UI to surface
    /// (e.g. via alert or banner). The coordinator sets this on transition to .securityLocked.
    /// The actual alert presentation for the current UIKit path remains in the coordinator.
    var lastErrorMessage: String?

    /// Convenience flag derived for SwiftUI consumers that want a simple boolean to drive .sheet / .alert.
    /// Coordinator sets this true when presenting the security retry alert.
    var isShowingSecurityError: Bool = false

    // MARK: - Action forwarding (injected by host)

    /// Injected by the coordinator (or a SwiftUI host) to perform an explicit user play/resume.
    /// Should ultimately call through to `SharedPlayerManager.userRequestedPlay()` (the designated path).
    var onPlayRequested: (() -> Void)?

    /// Injected to request an explicit pause/stop.
    var onPauseRequested: (() -> Void)?

    /// Injected when the user (or SwiftUI control) selects a language flag at the given index.
    /// Coordinator wires this to its full `handleLanguageSelection` + debounce + completeStreamSwitch path.
    var onLanguageSelected: ((Int) -> Void)?

    /// Injected to request a sleep timer preset (minutes). Routed by coordinator to
    /// handleSleepTimerPresetSelected + full interaction glue (flags, settles, display task,
    /// SharedPlayerManager.setSleepTimer, sync, notifications).
    var onSleepTimerPresetSelected: ((Int) -> Void)?

    /// Injected to request cancellation of an active sleep timer. Routed to coordinator's
    /// handleSleepTimerCancelSelected (preserves all existing stop + restore + UI sync paths).
    var onSleepTimerCancelSelected: (() -> Void)?

    // MARK: - Public convenience API (callable from SwiftUI)

    /// Request playback start/resume. Forwards to the injected closure.
    ///
    /// The injected closure is wired by the coordinator to `SharedPlayerManager.userRequestedPlay()`
    /// (the designated explicit-play entry that sets intent then drives `play()`).
    ///
    /// - SeeAlso: ``onPlayRequested``, SharedPlayerManager.userRequestedPlay, CODING_AGENT.md.
    func play() {
        onPlayRequested?()
    }

    /// Request pause/stop. Forwards to the injected closure.
    ///
    /// - SeeAlso: ``onPauseRequested``, SharedPlayerManager.stop, SharedPlayerManager.markAsUserPaused.
    func pause() {
        onPauseRequested?()
    }

    /// Select a stream/language by index in the canonical availableStreams array.
    /// Forwards to the injected closure (coordinator performs optimistic UI + timing).
    ///
    /// - Parameter index: Index into `DirectStreamingPlayer.availableStreams`.
    /// - SeeAlso: ``onLanguageSelected``, RadioPlayerCoordinator.completeStreamSwitch.
    func selectLanguage(at index: Int) {
        onLanguageSelected?(index)
    }

    /// Request a sleep timer preset (e.g. 15, 30, 45 or 60 minutes).
    /// Forwards to the injected closure so coordinator retains ownership of setSleepTimer,
    /// isSleepTimerInteractionActive, background deferral, beginLocalSleepTimerDisplay,
    /// and syncSleepTimerToViewModel.
    ///
    /// - Parameter minutes: Duration in minutes for the timer.
    /// - SeeAlso: ``onSleepTimerPresetSelected``.
    func selectSleepTimer(minutes: Int) {
        onSleepTimerPresetSelected?(minutes)
    }

    /// Request cancellation of the current sleep timer (if any).
    /// Forwards to the injected closure; coordinator owns cancel + display stop + notification paths.
    ///
    /// - SeeAlso: ``onSleepTimerCancelSelected``.
    func cancelSleepTimer() {
        onSleepTimerCancelSelected?()
    }

    // MARK: - Derived convenience (no side effects)

    /// True only while actively streaming audio.
    var isActivelyPlaying: Bool {
        visualState.isActivelyPlaying
    }

    /// Whether the current visual state permits auto-resume on foreground / recovery.
    var shouldAutoResume: Bool {
        visualState.shouldAutoPlayOrResume
    }

    /// Localized accessibility value for the sleep timer control when a timer is active.
    ///
    /// Returns a formatted string such as "12 minutes remaining" (via the catalog key
    /// "sleep_timer_accessibility_remaining") when `sleepTimerRemaining > 0`; otherwise nil.
    ///
    /// - Note: This computed property owns the derivation so view bodies stay focused on
    ///   layout and modifiers only. The rounding (remaining + 59)/60 to whole minutes and
    ///   the unsafe String(format:) pattern match the prior inline implementation and the
    ///   established VoiceOver revival approach used elsewhere for catalog strings.
    /// - SeeAlso: `sleepTimerRemaining`, PlaybackControlsView (the .accessibilityValue site),
    ///   `String(localized: "sleep_timer_accessibility_remaining"...)`, CODING_AGENT.md
    ///   (Documentation & Comment Standards, cached derived values on @Observable models).
    var sleepTimerAccessibilityValue: String? {
        guard let remaining = sleepTimerRemaining, remaining > 0 else { return nil }
        let minutes = max(1, Int((remaining + 59) / 60))
        // SAFETY: String(format:) with a catalog-provided format string containing %d
        // is the established pattern in this codebase for placeholder-bearing VoiceOver
        // strings (see announceSwitchedToLanguage in RadioPlayerCoordinator.swift and the
        // previous inline site in PlaybackControlsView). The format is trusted
        // (Localizable.xcstrings) and the argument is a simple Int. Required under
        // SWIFT_STRICT_MEMORY_SAFETY=YES; the `unsafe` marker satisfies the compiler while
        // preserving localized pluralization/positioning across all 21 languages.
        return unsafe String(
            format: String(localized: "sleep_timer_accessibility_remaining", table: "Localizable"),
            minutes
        )
    }

    // MARK: - Presentation recompute (kept out of view bodies)

    private func recomputePresentation() {
        statusPresentation = visualState.makeStatusPresentation()
        controlPresentation = visualState.makeControlPresentation()
    }

    /// Recomputes the narrow `nowPlayingDisplay` from current metadata (and visual state
    /// when fallbacks are relevant). Called from the didSet observers so that derivation
    /// never occurs inside a SwiftUI view body or initializer.
    private func recomputeNowPlayingDisplay() {
        nowPlayingDisplay = makeNowPlayingDisplayModel(metadata: currentMetadata)
    }
}

// MARK: - Preview / Test Support

extension PlayerViewModel {

    /// Creates a fully populated mock instance for SwiftUI `#Preview` and unit tests.
    ///
    /// - No actor access or side effects occur.
    /// - Action closures are wired to simple prints so you can exercise buttons in the canvas.
    /// - All 21 languages and all visual states are valid; the mock does not enforce stream count.
    ///
    /// - Parameters:
    ///   - visualState: Initial `PlayerVisualState` for the mock.
    ///   - selectedStreamIndex: Initial selected language/stream index.
    ///   - currentMetadata: Optional program metadata.
    ///   - sleepTimerRemaining: Optional remaining timer interval.
    ///   - isSwitchingStream: Whether to simulate an in-flight switch.
    ///   - lastErrorMessage: Optional error string for security/error previews.
    ///   - isShowingSecurityError: Initial flag for the error surface.
    /// - Returns: A configured `PlayerViewModel` ready for observation and interaction in previews/tests.
    ///
    /// Example:
    /// ```swift
    /// #Preview {
    ///     let vm = PlayerViewModel.makeMock(visualState: .playing)
    ///     PlayerMainPreview(viewModel: vm)
    /// }
    /// ```
    ///
    /// - SeeAlso: ``PlayerViewModel``, PlayerMainPreview, CODING_AGENT.md (preview support).
    static func makeMock(
        visualState: PlayerVisualState = .playing,
        selectedStreamIndex: Int = 2,
        currentMetadata: StreamProgramMetadata? = StreamProgramMetadata(programTitle: "Sunday Sermon", speaker: "Jari Lammi"),
        sleepTimerRemaining: TimeInterval? = nil,
        isSwitchingStream: Bool = false,
        lastErrorMessage: String? = nil,
        isShowingSecurityError: Bool = false
    ) -> PlayerViewModel {
        let vm = PlayerViewModel()
        vm.visualState = visualState
        vm.selectedStreamIndex = selectedStreamIndex
        vm.currentMetadata = currentMetadata
        vm.sleepTimerRemaining = sleepTimerRemaining
        vm.isSwitchingStream = isSwitchingStream
        vm.lastErrorMessage = lastErrorMessage
        vm.isShowingSecurityError = isShowingSecurityError

        // Wire no-op (but observable) closures for interactive previews
        vm.onPlayRequested = {
            #if DEBUG
            print("[PlayerViewModel Preview] play() requested")
            #endif
            // In a real preview host you could mutate vm.visualState here to simulate response.
        }
        vm.onPauseRequested = {
            #if DEBUG
            print("[PlayerViewModel Preview] pause() requested")
            #endif
        }
        vm.onLanguageSelected = { index in
            #if DEBUG
            print("[PlayerViewModel Preview] selectLanguage(at: \(index))")
            #endif
            vm.selectedStreamIndex = index
            // A more advanced preview could also flip to .prePlay briefly.
        }
        vm.onSleepTimerPresetSelected = { mins in
            #if DEBUG
            print("[PlayerViewModel Preview] selectSleepTimer(minutes: \(mins))")
            #endif
        }
        vm.onSleepTimerCancelSelected = {
            #if DEBUG
            print("[PlayerViewModel Preview] cancelSleepTimer()")
            #endif
        }

        return vm
    }
}

// MARK: - Minimal self-contained SwiftUI preview host (for the new main view)
//
// This struct (and its supporting modifier) exists so that we can immediately provide
// working #Preview surfaces for the VM without depending on the legacy UIKit components
// being converted yet. It demonstrates how a future pure-SwiftUI RadioPlayerView would
// consume the model.
//
// Design note on side effects:
// The `.onChange` that auto-sets `isShowingSecurityError` on .securityLocked transition
// was extracted into `SecurityErrorFlagOnLockModifier` so the preview body contains only
// layout declarations. The modifier is intentionally small, DEBUG-scoped, and
// self-documenting.

#if DEBUG
import SwiftUI

/// Lightweight SwiftUI preview surface that exercises the observable PlayerViewModel.
///
/// Used both for standalone preview of the VM and as a template for a future main view.
///
/// The view applies `.securityErrorFlagOnLock(viewModel:)` (a minimal extracted modifier)
/// rather than inlining an .onChange in the body, following the goal of keeping derivation
/// and side-effect logic outside view bodies even in preview scaffolding.
struct PlayerMainPreview: View {
    @State var viewModel: PlayerViewModel

    var body: some View {
        VStack(spacing: 24) {
            // Title area
            Text("Lutheran Radio")
                .font(.largeTitle.weight(.semibold))

            // Status pill driven from narrow cached presentation (demo of the pattern).
            // Leaf views in production should receive `viewModel.statusPresentation` (or a let binding to it)
            // instead of the whole view model when only colors + text are required.
            let pres = viewModel.statusPresentation
            Text(pres.text)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(pres.background)
                .foregroundStyle(pres.foreground)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            // Simulated language "flags" row (selectedIndex drives highlight)
            HStack(spacing: 12) {
                ForEach(0..<5, id: \.self) { idx in
                    Button {
                        viewModel.selectLanguage(at: idx)
                    } label: {
                        Text(flagEmoji(for: idx))
                            .font(.title)
                            .padding(8)
                            .background(idx == viewModel.selectedStreamIndex ? Color.yellow.opacity(0.3) : Color.clear)
                            .clipShape(Circle())
                    }
                }
            }

            // Metadata
            Group {
                if let meta = viewModel.currentMetadata, meta.hasDisplayableContent {
                    VStack {
                        if let speaker = meta.speaker {
                            Text(speaker).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let title = meta.programTitle {
                            Text(title).font(.body)
                        }
                    }
                } else {
                    Text("No track info")
                        .foregroundStyle(.secondary)
                }
            }

            // Sleep timer
            if let remaining = viewModel.sleepTimerRemaining, remaining > 0 {
                Label("\(Int(remaining))s remaining", systemImage: "moon.zzz.fill")
                    .foregroundStyle(.indigo)
            }

            if viewModel.isSwitchingStream {
                ProgressView("Switching stream…")
            }

            // Controls
            HStack(spacing: 32) {
                Button {
                    viewModel.pause()
                } label: {
                    Image(systemName: "pause.fill")
                        .font(.largeTitle)
                }
                .disabled(!viewModel.isActivelyPlaying)

                Button {
                    viewModel.play()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.largeTitle)
                }
                .disabled(viewModel.isActivelyPlaying)
            }

            // Error surface (for securityLocked previews)
            if let msg = viewModel.lastErrorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding()
        .securityErrorFlagOnLock(viewModel: viewModel)
    }

    private func flagEmoji(for index: Int) -> String {
        // Approximate mapping for preview (real app uses actual flag assets + DirectStreamingPlayer data)
        let codes = ["🇩🇰", "🇩🇪", "🇬🇧", "🇪🇪", "🇫🇮"]
        return codes[safe: index] ?? "🏳️"
    }
}

// MARK: - Preview-only side-effect extraction (DEBUG)

/// DEBUG-only ViewModifier that encapsulates the side-effect previously embedded in
/// `PlayerMainPreview.body`.
///
/// When `visualState` becomes `.securityLocked` it sets `isShowingSecurityError` so the
/// error surface in the preview is exercised. This keeps the preview body declarative
/// (focused on layout) while isolating the one-time "set flag on transition" logic.
///
/// The entire block lives under the outer `#if DEBUG` that gates `PlayerMainPreview` and
/// all preview support. The modifier is intentionally minimal and has zero production surface.
///
/// - SeeAlso: PlayerMainPreview, the "Security Locked" #Preview,
///   CODING_AGENT.md (Documentation & Comment Standards, preview scaffolding).
struct SecurityErrorFlagOnLockModifier: ViewModifier {
    @Bindable var viewModel: PlayerViewModel

    func body(content: Content) -> some View {
        content
            .onChange(of: viewModel.visualState) { _, newState in
                if newState == .securityLocked && !viewModel.isShowingSecurityError {
                    viewModel.isShowingSecurityError = true
                }
            }
    }
}

extension View {
    /// Applies the debug security-locked flag side-effect for preview surfaces only.
    fileprivate func securityErrorFlagOnLock(viewModel: PlayerViewModel) -> some View {
        modifier(SecurityErrorFlagOnLockModifier(viewModel: viewModel))
    }
}


private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#Preview("Playing") {
    PlayerMainPreview(viewModel: .makeMock(visualState: .playing))
}

#Preview("Pre-play / Connecting") {
    PlayerMainPreview(viewModel: .makeMock(visualState: .prePlay, currentMetadata: nil))
}

#Preview("User Paused + Sleep") {
    PlayerMainPreview(viewModel: .makeMock(visualState: .userPaused, sleepTimerRemaining: 14 * 60))
}

#Preview("Security Locked") {
    PlayerMainPreview(viewModel: .makeMock(
        visualState: .securityLocked,
        lastErrorMessage: String(localized: "security_model_error_message", table: "Localizable"),
        isShowingSecurityError: true
    ))
}

#Preview("Switching Stream") {
    PlayerMainPreview(viewModel: .makeMock(visualState: .prePlay, currentMetadata: nil, isSwitchingStream: true))
}
#endif
