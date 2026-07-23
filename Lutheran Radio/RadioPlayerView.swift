//
//  RadioPlayerView.swift
//  Lutheran Radio
//
//  Main player screen as a pure SwiftUI view.
//  Composition root for the modern player chrome (title, playback controls, metadata,
//  language tuner, and volume + AirPlay row). The decorative background remains in UIKit
//  ownership (BackgroundImageController) and is visible through a large central spacer.
//
//  This replaced the prior hybrid UIKit layout. All vertical rhythm is now expressed
//  declaratively with VStack + explicit paddings so that future layout experiments are cheap.
//
//  Role in event-driven architecture:
//  - Hosts the primary SwiftUI player surface (via UIHostingController in ViewController).
//  - Owns a lightweight additive `PlayerEventSubscriber` (via @State + modern Observation)
//    that consumes `SharedPlayerManager.events` for UI-only side effects.
//  - All direct @Bindable bindings to `PlayerViewModel`, subview inputs, and imperative
//    coordinator paths remain the primary mechanism and are untouched.
//
//  Key invariants (UI layer only):
//  - No security, certificate, DNS, or Core/ logic lives here or is called from here.
//  - The subscriber is strictly additive and non-forcing; existing state bindings and
//    visual derivation in PlayerViewModel continue to drive all rendering.
//  - Observation lifetime is tied to the view via `.task` / `.onDisappear` (no leaks,
//    auto-cancel on disappearance).
//  - Value-type driven updates preferred: @State + onChange(of: subscriber.prop) +
//    local @State for any animation/refresh coordination.
//
//  - SeeAlso: `PlayerEventSubscriber` (the new subscriber helper defined in this file),
//    `PlayerViewModel`, `ViewController`, `SharedPlayerManager` (``events``, ``PlayerEvent``),
//    `WidgetEventObserver` (reused internally for task management),
//    `PlaybackControlsView`, `LanguageSelectorView`, `NowPlayingMetadataView`,
//    CODING_AGENT.md (Documentation & Comment Standards, Single Source of Truth Principles,
//    "Cross-target shared source files (non-Core)", Defensive Swift Practices, event-driven direction),
//    docs/Event-Driven-Refactor-Roadmap.md (Tier 2 UI subscriber item),
//    <doc:Architecture>.
//
//  Created by Jari Lammi on 19.6.2026.
//

import SwiftUI
import AVKit
import MediaPlayer
import UIKit
import Observation
import WidgetSurface
// Observation provides @Observable for the lightweight subscriber helper below.
// Swift 6 strict concurrency + SWIFT_STRICT_MEMORY_SAFETY = YES are inherited from target settings.

/// The main player interface built in SwiftUI.
///
/// Composes `NowPlayingMetadataView`, `LanguageSelectorView`, `PlaybackControlsView` and
/// `VolumeAndAirPlayRow` under a single composition root (`UIHostingController` in ViewController).
///
/// Role of this type:
/// - Holds the `@Bindable PlayerViewModel`.
/// - Projects **narrow** value types and closures to the three primary subviews so that
///   leaf views depend on the smallest possible inputs (following the pattern first
///   demonstrated by `StatusPill`).
/// - Does not perform derivation itself.
///
/// See the "Main Player Presentation Dataflow" section in `PlayerViewModel.swift`
/// for the authoritative description of the three cached surfaces and narrow contract
/// (aligned with widget/Live Activity patterns).
///
/// Current visual order (top to bottom):
/// 1. Localized app title (establishes identity immediately under the status bar).
/// 2. Primary playback controls (play/pause, sleep timer, status pill) — placed high for reachability.
/// 3. Now-playing metadata + conditional speaker photo.
/// 4. Language/flag "tuner" row with animated red needle (`LanguageSelectorView`).
/// 5. Large spacer that leaves the central screen area visually open.
/// 6. Native system volume control (`SystemVolumeSlider` / `MPVolumeView`) + separate AirPlay row
///    anchored near the bottom safe area. The volume control directly manipulates system output
///    volume (AVAudioSession route volume) rather than AVPlayer internal gain.
///
/// The decorative map / logo background is deliberately kept in UIKit ownership
/// (`BackgroundImageController`) behind this transparent hosting controller. This preserves
/// parallax, energy-efficiency paths, CI filtering, and deferral logic without risk during
/// the incremental SwiftUI migration.
///
/// Sleep timer: The tap closure is forwarded for compatibility (it still reaches
/// `configureSleepTimerButtonMenu`). The actual presentation is a native
/// `.confirmationDialog` (15/30/45/60 + conditional Cancel + Clear local state) implemented inside
/// `PlaybackControlsView`. Timer choices are delivered via `PlayerViewModel.selectSleepTimer` /
/// `cancelSleepTimer` closures; the privacy clear action is delivered via the `onClearLocalStateTapped`
/// closure (both wired by the coordinator/VC). This preserves the complete existing timer logic,
/// countdown Task, notifications, `syncSleepTimerToViewModel`, interaction flags, and the
/// `confirmAndClearLocalState` flow unchanged.
///
/// String revival note: `sleep_timer_sheet_title` is materialized here (and also used directly
/// in the dialog) to keep the localization entry live across all 21 languages.
///
/// - SeeAlso: ``PlayerViewModel``, `PlaybackControlsView`, `LanguageSelectorView`,
///   `NowPlayingMetadataView`, `VolumeAndAirPlayRow`, `ViewController`,
///   `RadioPlayerCoordinator`, `BackgroundImageController`,
///   `configureSleepTimerButtonMenu()`, `confirmAndClearLocalState()`, CODING_AGENT.md (Single Source of Truth Principles + Cross-target shared files),
///   <doc:Architecture>.
// MARK: - PlayerEventSubscriber (lightweight UI-layer observer)

/// Lightweight subscriber / observer for `PlayerEvent` values emitted by the shared player layer.
///
/// Placed in the main app UI layer (inside the primary player hosting view `RadioPlayerView`).
/// Its sole responsibility is to react to `playbackIntentChanged` and other key domain events
/// (stream transitions, metadata, visual state, persisted state) and drive **UI-only** side effects
/// such as updating local `@State` values that can feed animations, subtree refreshes, or
/// additional coordination with WidgetKit / Live Activities — without ever mutating player state,
/// intents, or Core surfaces.
///
/// The subscriber consumes the replaying stream (`makeEventsStreamWithReplay`) so that
/// late appearance of the player UI receives the current state as initial events
/// before live updates.
///
/// Design choices (per requirements):
/// - Modern Observation: `@Observable` + `@State` ownership in the hosting `View`.
/// - Value-type driven: changes flow through published value properties; consumers use
///   `.onChange(of: ...)` rather than imperative callbacks where possible.
/// - Additive only: the primary `@Bindable viewModel` and all existing direct bindings in
///   `PlaybackControlsView`, `LanguageSelectorView`, `NowPlayingMetadataView` etc. are
///   left 100% untouched.
/// - Reuses the established `WidgetEventObserver` internally for cancellable task management
///   and weak-self safe main-actor delivery (no duplicated observation boilerplate).
/// - Lifetime: started from a `.task` modifier in `RadioPlayerView.body`; cancelled on
///   disappear. The view's `@State` preserves the instance across SwiftUI updates.
///
/// Why a dedicated helper in the UI layer (not inside `PlayerViewModel` or coordinator):
/// `RadioPlayerView` is the composition root for the visible player chrome. Keeping a
/// narrow event subscriber here allows future local animation state or view-refresh
/// triggers to live close to the rendering site while the VM/coordinator retain their
/// existing responsibilities for authoritative visual + action wiring.
///
/// Actor isolation / Sendable:
/// - The whole type is `@MainActor`.
/// - `PlayerEvent` and `PlaybackIntent` are `Sendable`.
/// - The observation Task hops to main actor for all handler delivery.
/// - No `@unchecked Sendable`, no `nonisolated(unsafe)`, no force-unwraps.
///
/// Security Invariant:
/// This type and all call sites live exclusively in the Lutheran Radio (main app) target
/// UI layer. It performs zero certificate validation, DNS lookups, security model checks,
/// or credential handling. All such logic is isolated inside `Core/`. See
/// CODING_AGENT.md "Core Framework Surface Area".
///
/// - SeeAlso: ``beginObserving()``, ``handle(_:)``,
///   `SharedPlayerManager.makeEventsStreamWithReplay()`, `SharedPlayerManager.events`,
///   `SharedPlayerManager.currentState`, `PlayerCurrentState`,
///   `PlayerCurrentState.isActivelyPlaying`,
///   `PlayerCurrentState.isBlockedByStickyIntent`,
///   `PlayerCurrentState.isInPermanentError`,
///   ``PlayerEvent``, `PlaybackIntent`, `WidgetEventObserver`,
///   `RadioPlayerView`, `PlayerViewModel`,
///   docs/Event-Driven-Refactor-Roadmap.md,
///   `PlayerEventSubscriberEventTests` (consumer replay + observable-state contract),
///   CODING_AGENT.md (event-driven direction, Documentation & Comment Standards,
///   narrow inputs, Single Source of Truth),
///   <doc:Architecture>.
@MainActor
@Observable
final class PlayerEventSubscriber {

    // MARK: - Observable state (value-type driven updates)

    /// The most recent `PlaybackIntent` delivered via a `.playbackIntentChanged` event.
    ///
    /// Updated only on that specific case (other events only bump the count).
    /// Consumers in `RadioPlayerView` read this via `.onChange(of: ...)` to drive
    /// intent-specific UI-only reactions (e.g. animation phase, local derived state).
    ///
    /// - Note: Initial value is a safe default; the real value is seeded from
    ///   `currentPlaybackIntent` on `beginObserving` and then kept in sync by events.
    /// - SeeAlso: `playbackIntentChanged(PlaybackIntent)`, SharedPlayerManager.`currentPlaybackIntent`.
    private(set) var lastObservedIntent: PlaybackIntent = .shouldBePlaying

    /// Monotonic counter incremented on every observed `PlayerEvent`.
    ///
    /// Provides a simple value that changes for *any* key player-domain transition
    /// (intent, stream start/pause/stop/fail, metadata, visual, persisted state).
    /// Ideal attachment point for `.onChange` that wants to react to "something
    /// important happened in the player" for UI refresh or animation coordination
    /// without caring about the specific payload.
    ///
    /// - Complexity: O(1) per event.
    /// - Postcondition: Increments exactly once per delivered event (after begin).
    private(set) var eventCount: Int = 0

    // MARK: - Observation machinery (reuses established helper)

    /// Internal consolidated observer that owns the cancellable `Task`.
    ///
    /// Delegates the actual `for await` loop and main-actor handoff to
    /// `WidgetEventObserver`. The task reference is not exposed from this type
    /// (UI views do not need the white-box seam that the widget managers require).
    private let eventObserver = WidgetEventObserver<PlayerEvent>()

    /// Creates a new subscriber. Observation does not begin until `beginObserving()`
    /// is called from the owning view's `.task` modifier.
    init() {}

    // MARK: - Public API

    /// Begins (or restarts) observation of `SharedPlayerManager.events`.
    ///
    /// Any prior observation is cancelled first. Seeds `lastObservedIntent` from the
    /// actor's current value (non-blocking for late subscribers) then consumes the
    /// stream, delivering every element to ``handle(_:)``.
    ///
    /// Must be called from a `@MainActor` async context (e.g. SwiftUI `.task`).
    /// Safe to call multiple times; idempotent with respect to prior cancellation.
    ///
    /// - Postcondition: The subscriber is actively consuming events emitted after
    ///   this call. `eventCount` and `lastObservedIntent` will be updated on the
    ///   main actor as events arrive. Because the replaying stream is used, the
    ///   subscriber also receives synthetic events representing the state present
    ///   at the moment observation began.
    /// - Important: This is additive. Starting observation has no effect on the
    ///   emitter, on other subscribers (WidgetRefreshManager, etc.), or on any
    ///   imperative playback paths.
    /// - Precondition: Returns immediately without seeding observable state or attaching
    ///   a replay stream when ``SharedPlayerManager/isWidgetProcess()`` is `true`. Widget
    ///   extension processes cannot observe authoritative ``PlayerEvent`` emissions.
    /// - SeeAlso: `WidgetEventObserver.beginObserving(_:onElement:onTermination:)`,
    ///   `SharedPlayerManager.makeEventsStreamWithReplay()`, `SharedPlayerManager.events`,
    ///   `SharedPlayerManager.currentState`, ``SharedPlayerManager/isWidgetProcess()``,
    ///   ``PlayerEventSubscriberEventTests``.
    func beginObserving() async {
        eventObserver.cancel()

        guard !SharedPlayerManager.isWidgetProcess() else { return }

        // The replaying stream supplies current state as the initial events.
        // An additional direct seed of intent provides an observable value
        // immediately even before the first replay event is delivered.
        lastObservedIntent = await SharedPlayerManager.shared.currentPlaybackIntent

        let stream = await SharedPlayerManager.shared.makeEventsStreamWithReplay()
        eventObserver.beginObserving(stream) { [weak self] event in
            await self?.handle(event)
        }
    }

    /// Cancels active observation and releases the underlying task.
    ///
    /// Idempotent. Called from `.onDisappear` in `RadioPlayerView` and from
    /// `beginObserving` before restart. When the owning view is removed from the
    /// hierarchy the `.task` modifier also cancels its context, providing
    /// belt-and-suspenders cleanup.
    ///
    /// - Postcondition: No further events will be processed by this subscriber
    ///   instance until the next `beginObserving`. The replay live-forwarding attachment
    ///   on ``SharedPlayerManager/events`` is released so other observers can attach.
    /// - SeeAlso: ``SharedPlayerManager/cancelReplayForwarding()``.
    func cancel() {
        eventObserver.cancel()
        Task {
            await SharedPlayerManager.shared.cancelReplayForwarding()
        }
    }

    #if DEBUG
    /// Applies a ``PlayerEvent`` through the production ``handle(_:)`` path for white-box tests.
    ///
    /// Exercises ``eventCount`` and ``lastObservedIntent`` update rules without requiring a
    /// second ``AsyncStream`` iterator on the shared live ``events`` source.
    ///
    /// - Parameter event: Domain event to deliver.
    /// - SeeAlso: ``handle(_:)``, ``PlayerEventSubscriberEventTests``.
    func _test_applyPlayerEvent(_ event: PlayerEvent) async {
        await handle(event)
    }
    #endif

    // MARK: - Internal event handling (UI side effects only)

    /// Reacts to a single `PlayerEvent`.
    ///
    /// Updates the observable properties (`lastObservedIntent` and/or `eventCount`).
    /// All work here stays inside UI-only reactions; no calls are made into
    /// `SharedPlayerManager` mutating APIs, `DirectStreamingPlayer`, or Core.
    ///
    /// - Parameter event: The domain event yielded by the authoritative emitter.
    /// - Important: This method (and its callers) must never be used to bypass
    ///   the single sources of truth or to perform player control decisions.
    private func handle(_ event: PlayerEvent) async {
        switch event {
        case .playbackIntentChanged(let intent):
            lastObservedIntent = intent
            eventCount += 1

        case .streamDidStart, .streamDidPause, .streamDidStop,
             .streamDidFail, .metadataDidUpdate:
            // Stream verbs and metadata carry no `PlaybackIntent`; only bump the counter.
            eventCount += 1

        case .visualStateDidChange, .persistedWidgetStateDidUpdate:
            // Visual and persisted-snapshot signals drive generic UI refresh sites via
            // `.onChange(of: eventCount)` without overwriting `lastObservedIntent`.
            eventCount += 1

        @unknown default:
            // `PlayerEvent` is a `@frozen public` type in `WidgetSurface`; future SDK-linked
            // cases must not trap the subscriber if the framework gains additive events.
            eventCount += 1
        }
    }
}

// End of PlayerEventSubscriber

struct RadioPlayerView: View {
    @Bindable var viewModel: PlayerViewModel

    /// Lightweight subscriber that reacts to `playbackIntentChanged` (and other
    /// `PlayerEvent` cases) from `SharedPlayerManager.events`.
    ///
    /// Owned with `@State` so its `@Observable` properties participate in SwiftUI's
    /// Observation system and can drive additional local `@State` or `.onChange`
    /// side effects. This is deliberately separate from the primary
    /// `@Bindable viewModel` surface.
    ///
    /// - Important: All existing direct bindings and subview contracts remain
    ///   unchanged. The subscriber is purely additive.
    /// - SeeAlso: `PlayerEventSubscriber`, ``body``, CODING_AGENT.md.
    @State private var playerEventSubscriber = PlayerEventSubscriber()

    /// Called when the user taps the sleep timer button (compatibility / side-effect path).
    /// Primary presentation and choice handling for sleep timer now lives in
    /// `PlaybackControlsView` (`.confirmationDialog`) + `PlayerViewModel` action closures
    /// (wired to coordinator business logic). The closure is still invoked on tap so that
    /// `configureSleepTimerButtonMenu` call sites remain exercised.
    var onSleepTimerTapped: (() -> Void)? = nil

    /// Called when the user selects the destructive "Clear local state" option inside the
    /// sleep timer `.confirmationDialog` (PlaybackControlsView).
    /// Wired from ViewController to `radioPlayerCoordinator?.confirmAndClearLocalState()`.
    /// This restores the privacy feature lost in the UIMenu → confirmationDialog migration.
    /// The coordinator method shows a secondary confirmation and then calls the SSOT
    /// `SharedPlayerManager.clearAllLocalState()`.
    ///
    /// - SeeAlso: PlaybackControlsView.onClearLocalStateTapped, RadioPlayerCoordinator.confirmAndClearLocalState,
    ///   CODING_AGENT.md.
    var onClearLocalStateTapped: (() -> Void)? = nil

    /// Keeps the previously stale "sleep_timer_sheet_title" string active in the localization
    /// catalog. The value is evaluated once per instance (harmless cost). It is used directly
    /// as the title for the native `.confirmationDialog` sleep timer options (see PlaybackControlsView).
    private let sleepTimerSheetTitle = String(localized: "sleep_timer_sheet_title", table: "Localizable")

    var body: some View {
        ZStack {
            // Background is provided by BackgroundImageController behind this hosted view.
            // We deliberately keep the background layer in UIKit ownership for this phase
            // (parallax, energy efficiency, deferral, CI processing). The SwiftUI layer
            // is intentionally transparent so the processed map/logo artwork shows through
            // the central spacer region.
            Color.clear

            VStack(spacing: 0) {
                // Top title — localized app identity. Horizontal padding prevents the large title
                // from hugging screen edges. Top padding sized for Dynamic Island / status bar clearance.
                Text(String(localized: "lutheran_radio_title", defaultValue: "Lutheran Radio", table: "Localizable"))
                    .font(.largeTitle.weight(.semibold))
                    .padding(.top, 20)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)

                // Playback controls (play/pause + sleep timer moon + status pill).
                // Positioned early in the stack so the most frequent actions sit in a comfortable
                // thumb zone near the top of the content area.
                //
                // Narrow inputs only: the @Bindable is held here; children receive value types + closures.
                PlaybackControlsView(
                    controlPresentation: viewModel.controlPresentation,
                    isActivelyPlaying: viewModel.isActivelyPlaying,
                    sleepTimerRemaining: viewModel.sleepTimerRemaining,
                    sleepTimerAccessibilityValue: viewModel.sleepTimerAccessibilityValue,
                    statusPresentation: viewModel.statusPresentation,
                    onPlay: viewModel.play,
                    onPause: viewModel.pause,
                    onSelectSleepTimer: { minutes in viewModel.selectSleepTimer(minutes: minutes) },
                    onCancelSleepTimer: { viewModel.cancelSleepTimer() },
                    onSleepTimerTapped: onSleepTimerTapped,
                    onClearLocalStateTapped: onClearLocalStateTapped
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                
                // Volume + AirPlay row (native system volume via MPVolumeView + dedicated AirPlayButton).
                // Padding values chosen to feel anchored without colliding with the home indicator.
                VolumeAndAirPlayRow()
                    .padding(.horizontal, 32)
                    .padding(.top, 6)
                    .padding(.bottom, 34)
                
                // Flags row with red needle indicator.
                // The needle's vertical registration is handled inside LanguageSelectorView
                // via reserved clear space + .offset(y: -11).
                //
                // Narrow input: only the selected index value and the selection closure.
                LanguageSelectorView(
                    selectedStreamIndex: viewModel.selectedStreamIndex,
                    selectLanguage: { index in viewModel.selectLanguage(at: index) }
                )
                    .padding(.horizontal)
                    .padding(.bottom, 6)

                // Song / program metadata + optional speaker photo.
                // Placed directly above the language selector so current-stream context sits
                // adjacent to the tuner controls.
                //
                // Narrow input: the cached NowPlayingDisplayModel + the showPhoto layout flag.
                NowPlayingMetadataView(displayModel: viewModel.nowPlayingDisplay, showPhoto: true)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                // Spacer reserves vertical real-estate in the bottom of the screen.
                // This keeps the full-bleed decorative background (map / logo images owned by
                // BackgroundImageController) visible behind the transparent host. The minLength
                // is chosen so the artwork remains prominent even as the top chrome grows.
                Spacer(minLength: 80)
            }
        }
        .background(Color.clear)

        // --------------------------------------------------------------------
        // Additive PlayerEvent subscriber wiring (UI layer only)
        // --------------------------------------------------------------------
        // The `.task` starts the lightweight `PlayerEventSubscriber` when this
        // composition root appears. The subscriber consumes `SharedPlayerManager.events`
        // and updates its `@Observable` value properties.
        //
        // `.onChange` sites are the attachment points for UI-only side effects:
        // - updating local @State (for animations or derived values)
        // - triggering view refreshes on specific subtrees
        // - future coordination with WidgetKit timelines or Live Activity intents
        //   originating from the primary player view.
        //
        // All of the above run in parallel with (never instead of) the existing
        // @Bindable viewModel + coordinator-driven paths.
        //
        // - Precondition: The view is hosted on the main actor (guaranteed by
        //   UIHostingController in ViewController).
        // - SeeAlso: `playerEventSubscriber`, `PlayerEventSubscriber.beginObserving()`,
        //   `PlayerEventSubscriber.eventCount`, SharedPlayerManager.`events`,
        //   docs/Event-Driven-Refactor-Roadmap.md (this completes the listed Tier 2 UI item),
        //   CODING_AGENT.md.
        .task {
            await playerEventSubscriber.beginObserving()
        }
        .onDisappear {
            playerEventSubscriber.cancel()
        }
        .onChange(of: playerEventSubscriber.eventCount) { _, _ in
            // Reacts to *every* key player event (including playbackIntentChanged and
            // all state transitions). The count is a pure value change that can be
            // used to drive local @State updates or animation triggers without
            // depending on the specific event payload.
            //
            // Current implementation performs no mutation of other @State (to keep
            // the change minimal and non-visual). Future additive work can introduce
            //   @State private var uiAnimationPhase: Int = 0
            // inside RadioPlayerView (or on the subscriber) and update it here,
            // then consume via `.animation(..., value: uiAnimationPhase)` or
            // `.id(...)` on a narrow subtree.
            //
            // This site must never perform player control, intent changes, or
            // security work.
        }
        .onChange(of: playerEventSubscriber.lastObservedIntent) { _, newIntent in
            // Specific reaction to `playbackIntentChanged`.
            // Provides the value-type hook for intent-driven UI-only effects
            // (e.g. local animation state that follows "should the user expect audio"
            // without ever reading the actor directly from the view body).
            //
            // Existing playback visuals continue to flow exclusively through
            // viewModel.visualState / viewModel.controlPresentation etc.
            // This onChange is additive observation only.
            //
            // - SeeAlso: case `playbackIntentChanged(PlaybackIntent)` in PlayerEvent.
        }
    }
}

// MARK: - Volume + AirPlay Row

/// Bottom control row containing speaker icon, native system volume slider, and AirPlay picker.
///
/// Architecture decision (post UIKit → SwiftUI foundation migration):
/// We use a `MPVolumeView` wrapper (`SystemVolumeSlider`) rather than a SwiftUI `Slider` or
/// a binding to `DirectStreamingPlayer.setVolume`.
///
/// Why:
/// - `DirectStreamingPlayer.setVolume` only sets `AVPlayer.volume`, an internal per-player gain.
///   It has no effect on the actual audio output level delivered to the user, hardware volume
///   buttons, Control Center, the Lock Screen Now Playing, or per-route volumes (AirPlay, BT).
/// - Prior custom `@State` + `Slider` + UserDefaults "preferredVolume" was a transitional
///   workaround that accepted desync as a known limitation (explicitly documented in the
///   previous implementation).
/// - `MPVolumeView` is the Apple-provided native control for system output volume. It
///   automatically reflects and controls the current `AVAudioSession` output volume for the
///   active route. It stays in sync with all system surfaces by design.
///
/// Persistence layer decision:
/// The app-group UserDefaults read/write for "preferredVolume" (and the `sharedDefaultsSuite` /
/// `volumeKey` constants) is removed from this row. Once the native system volume view is used,
/// iOS is the single source of truth for current volume level and persists it across app
/// launches, device restarts, and audio route changes. Re-adding a parallel "preferred" value
/// would cause the UI to fight the system (e.g. user raises volume with side buttons while app
/// is backgrounded → our stale value would be wrong on foreground). This matches the guidance
/// in the task that "in most cases it is no longer the primary source of truth once we use
/// MPVolumeView".
///
/// The separate `AirPlayButton` (wrapping `AVRoutePickerView` with `prioritizesVideoDevices = false`)
/// is intentionally kept as an independent control. The `MPVolumeView` inside
/// `SystemVolumeSlider` therefore suppresses its internal route button (see
/// `SystemVolumeRepresentable` and `MPVolumeView.configureAsVolumeSliderOnly`).
///
/// Layout contract:
/// - Speaker icon: decorative, secondary, accessibility hidden.
/// - Volume: flexible width native slider.
/// - AirPlay: fixed 44×44 as defined in `AirPlayButton`.
/// - Row height 44 provides consistent touch targets.
///
/// Accessibility (VoiceOver / Switch Control volume cluster revival):
/// - `accessibilityIdentifier("volumeSlider")` is set on the inner `UISlider` of the
///   `MPVolumeView` (see `SystemVolumeRepresentable.makeUIView`) to keep the existing
///   `app.sliders["volumeSlider"]` / descendant UI tests passing without modification.
/// - Label (`accessibility_label_volume`) and hint (`accessibility_hint_volume`) on the
///   SwiftUI wrapper (all 21 languages).
/// - Value (`accessibility_value_volume`, e.g. "50 percent") kept live on the UIKit slider
///   and mirrored on the SwiftUI wrapper so VO speaks a localized percent.
/// - Named custom actions `increase_volume` / `decrease_volume` step system volume by 10%
///   and announce `volume_set_to` — the same cluster that lived on the pre-migration UIKit
///   `UISlider`, revived so the catalog entries stay live for blind users.
/// - AGENT NOTE: Step **system** route volume via the live `MPVolumeView` slider only.
///   Never call `DirectStreamingPlayer.setVolume` from this row (internal AVPlayer gain).
///
/// - Important: This is the canonical volume surface for the SwiftUI player chrome.
/// - Note: `DirectStreamingPlayer.setVolume` is intentionally not called from this row and
///   remains untouched for potential legacy or other internal gain uses.
/// - SeeAlso: `SystemVolumeSlider`, `SystemVolumeVoiceOver`, `AirPlayButton`, `RadioPlayerView`,
///   `PlaybackControlsView` (play/pause a11y revival), `MPVolumeView.configureAsVolumeSliderOnly`,
///   CODING_AGENT.md (Documentation & Comment Standards for AI Coding Agents),
///   <doc:Architecture>
struct VolumeAndAirPlayRow: View {
    /// Localized percent string for the SwiftUI accessibility value (mirrors the UIKit slider).
    /// Refreshed when VoiceOver custom actions step volume and when the representable posts
    /// ``Notification.Name.lutheranSystemVolumeAccessibilityDidChange``.
    @State private var volumeAccessibilityValue: String = SystemVolumeVoiceOver.accessibilityValueText(
        for: SystemVolumeVoiceOver.currentValue()
    )

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
                .font(.callout)
                .accessibilityHidden(true)

            SystemVolumeSlider()
                .accessibilityLabel(String(localized: "accessibility_label_volume", table: "Localizable"))
                .accessibilityHint(String(localized: "accessibility_hint_volume", table: "Localizable"))
                // Revives stale `accessibility_value_volume` on the SwiftUI wrapper (UIKit slider
                // also carries the same value — whichever element VO focuses, percent is spoken).
                .accessibilityValue(volumeAccessibilityValue)
                // Revives stale `increase_volume` / `decrease_volume` as discoverable named actions
                // (rotor / Switch Control). Steps match the historical UIKit ±0.1 (10%) behavior.
                .accessibilityAction(
                    named: String(
                        localized: "increase_volume",
                        defaultValue: "Increase Volume",
                        table: "Localizable",
                        comment: "Accessibility action to increase volume"
                    )
                ) {
                    SystemVolumeVoiceOver.step(by: SystemVolumeVoiceOver.stepAmount)
                    refreshVolumeAccessibilityValue()
                }
                .accessibilityAction(
                    named: String(
                        localized: "decrease_volume",
                        defaultValue: "Decrease Volume",
                        table: "Localizable",
                        comment: "Accessibility action to decrease volume"
                    )
                ) {
                    SystemVolumeVoiceOver.step(by: -SystemVolumeVoiceOver.stepAmount)
                    refreshVolumeAccessibilityValue()
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: .lutheranSystemVolumeAccessibilityDidChange
                    )
                ) { _ in
                    refreshVolumeAccessibilityValue()
                }
                .onAppear {
                    refreshVolumeAccessibilityValue()
                }

            // AirPlay route picker (native, kept exactly as implemented).
            AirPlayButton()
        }
        .frame(height: 44)
    }

    /// Re-reads the live system volume and updates the SwiftUI accessibility value string.
    private func refreshVolumeAccessibilityValue() {
        volumeAccessibilityValue = SystemVolumeVoiceOver.accessibilityValueText(
            for: SystemVolumeVoiceOver.currentValue()
        )
    }
}

// MARK: - System volume VoiceOver helpers

/// Steps and reports **system** route volume for VoiceOver / Switch Control.
///
/// Revives the localization cluster orphaned when the UIKit `volumeSlider` was removed in
/// favor of ``MPVolumeView`` (`accessibility_value_volume`, `increase_volume`,
/// `decrease_volume`, `volume_set_to`). All 21 language translations remain in
/// `Localizable.xcstrings`.
///
/// - Important: Never routes through `DirectStreamingPlayer.setVolume` (AVPlayer internal
///   gain only). Always drives the live `MPVolumeView` `UISlider` when attached.
/// - Note: `liveSlider` is set by ``SystemVolumeRepresentable`` after the slider subview
///   appears; custom actions no-op safely if the representable is not yet in the hierarchy.
/// - SeeAlso: ``VolumeAndAirPlayRow``, ``SystemVolumeRepresentable``, `PlaybackControlsView`
///   (same revival pattern for `toggle_playback`), CODING_AGENT.md, <doc:Architecture>.
@MainActor
enum SystemVolumeVoiceOver {
    /// Historical UIKit step size (10% of full scale per custom action invocation).
    static let stepAmount: Float = 0.1

    /// Weak reference to the on-screen `MPVolumeView` volume slider.
    /// Set exclusively by ``SystemVolumeRepresentable``; cleared when the view is torn down.
    static weak var liveSlider: UISlider?

    /// Current system volume in 0...1, preferring the live slider when available.
    ///
    /// - Returns: The live slider value when attached; otherwise a best-effort read from a
    ///   transient `MPVolumeView` slider (same public path as programmatic volume set).
    static func currentValue() -> Float {
        if let liveSlider {
            return liveSlider.value
        }
        return resolveTransientSlider()?.value ?? 0
    }

    /// Localized accessibility value for a volume in 0...1 (e.g. "50 percent").
    ///
    /// - Parameter value: System volume in unit interval.
    /// - Returns: Catalog-formatted percent string via `accessibility_value_volume`.
    static func accessibilityValueText(for value: Float) -> String {
        let percent = percent(for: value)
        // SAFETY: `String(format:)` with a catalog-provided format containing `%d` is the
        // established VoiceOver format pattern (see `sleepTimerAccessibilityValue` on
        // `PlayerViewModel` and `announceSwitchedToLanguage` on `RadioPlayerCoordinator`).
        // The format is trusted (`Localizable.xcstrings`) and the argument is a simple `Int`.
        // Required under `SWIFT_STRICT_MEMORY_SAFETY = YES`.
        return unsafe String(
            format: String(localized: "accessibility_value_volume", table: "Localizable"),
            percent
        )
    }

    /// Steps system volume by `delta` (clamped to 0...1), syncs a11y value, and announces
    /// the new level via `volume_set_to`.
    ///
    /// - Parameter delta: Signed step in unit interval (typically ±``stepAmount``).
    /// - Postcondition: Live slider (when attached) reflects the clamped value; VoiceOver
    ///   receives a localized "Volume set to N percent" announcement.
    static func step(by delta: Float) {
        let newValue = min(1.0, max(0.0, currentValue() + delta))
        applySystemVolume(newValue)
        announceVolumeSet(to: newValue)
        NotificationCenter.default.post(name: .lutheranSystemVolumeAccessibilityDidChange, object: nil)
    }

    /// Applies a unit-interval system volume through the live (or transient) `MPVolumeView` slider.
    ///
    /// - Parameter value: Target volume in 0...1 (caller should clamp).
    static func applySystemVolume(_ value: Float) {
        if let slider = liveSlider {
            slider.setValue(value, animated: true)
            slider.accessibilityValue = accessibilityValueText(for: value)
            return
        }
        // Representable not attached yet (rare: action before layout). Drive a retained
        // transient MPVolumeView so the step still affects system volume. Not kept in the
        // visible hierarchy; only used as a write path fallback.
        if let slider = resolveTransientSlider() {
            slider.setValue(value, animated: false)
        }
    }

    /// Posts a localized VoiceOver announcement for the new volume percent.
    ///
    /// - Parameter value: System volume in 0...1 after the step.
    static func announceVolumeSet(to value: Float) {
        let percent = percent(for: value)
        // SAFETY: catalog format string with `%d` + Int argument (same pattern as
        // `accessibilityValueText(for:)` and sleep-timer VoiceOver formatting).
        let message = unsafe String(
            format: String(
                localized: "volume_set_to",
                defaultValue: "Volume set to %d percent",
                table: "Localizable"
            ),
            percent
        )
        // SAFETY: `UIAccessibility.post` is the established announcement API for VoiceOver
        // in this codebase (see `announceSwitchedToLanguage` / post-clear revival).
        unsafe UIAccessibility.post(notification: .announcement, argument: message)
    }

    /// Converts unit-interval volume to a whole-number percent for catalog format strings.
    static func percent(for value: Float) -> Int {
        Int((value * 100).rounded())
    }

    /// Retained fallback `MPVolumeView` used only when `liveSlider` is nil (pre-attach).
    /// Avoids creating a new view on every fallback read/write.
    private static var transientVolumeView: MPVolumeView?

    /// Returns the live slider, or the volume slider inside a retained transient `MPVolumeView`.
    private static func resolveTransientSlider() -> UISlider? {
        if let liveSlider { return liveSlider }
        let view = transientVolumeView ?? MPVolumeView(frame: .zero)
        transientVolumeView = view
        return view.subviews.first(where: { $0 is UISlider }) as? UISlider
    }
}

extension Notification.Name {
    /// Posted when system volume is stepped via VoiceOver custom actions (or the UIKit
    /// slider path updates accessibility value). ``VolumeAndAirPlayRow`` listens to refresh
    /// its SwiftUI `accessibilityValue`.
    ///
    /// - SeeAlso: ``SystemVolumeVoiceOver/step(by:)``, ``VolumeAndAirPlayRow``
    static let lutheranSystemVolumeAccessibilityDidChange = Notification.Name(
        "LutheranRadioSystemVolumeAccessibilityDidChange"
    )
}

/// A reusable SwiftUI wrapper presenting the native system volume slider backed by `MPVolumeView`.
///
/// Primary goal of this type (and the reason for the volume upgrade):
/// Deliver the experience users expect — volume changes from the app are identical to
/// hardware buttons, Control Center, and route-specific volumes, with no drift.
///
/// `SystemVolumeSlider` suppresses the route button on its backing `MPVolumeView`
/// (see `configureAsVolumeSliderOnly`) because the app already supplies a dedicated,
/// styled `AirPlayButton` (AVRoutePickerView) next to it. This keeps visual balance
/// and control ownership clear, following the iOS 13+ guidance to use AVRoutePickerView
/// for routing surfaces.
///
/// Sizing:
/// The representable is given a modest intrinsic height (32 pt) suitable for the slider
/// track and thumb. The containing `HStack` + `.frame(height: 44)` in `VolumeAndAirPlayRow`
/// supplies the full-row tap target and alignment.
///
/// Tint:
/// The accent color previously applied via the custom `Slider.tint(.accentColor)` is
/// forwarded by bridging `Color.accentColor` (sourced from the app's AccentColor asset)
/// into `MPVolumeView.tintColor`. The minimum track and thumb therefore adopt the brand
/// tint consistently.
///
/// No additional state, observers, or UserDefaults wiring is present or required.
/// `MPVolumeView` manages observation of `AVAudioSession` and route volume internally.
///
/// Accessibility for the inner `UISlider` (identifier, localized value, increase/decrease
/// custom actions) is installed by ``SystemVolumeRepresentable`` so VoiceOver focuses the
/// same control UITests query. Label/hint/value/actions are also applied on the SwiftUI
/// wrapper by ``VolumeAndAirPlayRow`` so either focus target speaks the revived catalog keys.
///
/// - Precondition: Must be used on the main actor / main thread (standard for all
///   UIViewRepresentable in SwiftUI). The hosting `UIHostingController` guarantees this.
/// - Postcondition: After insertion, user gestures and external volume changes are reflected
///   live in the slider and affect audible output level for the current route.
/// - Note: Subview walk attaches a11y + ``SystemVolumeVoiceOver/liveSlider``; no KVO and no
///   extra on-screen `MPVolumeView` instances in the normal path.
/// - SeeAlso: `VolumeAndAirPlayRow`, `SystemVolumeVoiceOver`, `AirPlayButton`,
///   `MPVolumeView` (MediaPlayer), CODING_AGENT.md, <doc:Architecture>
struct SystemVolumeSlider: View {
    var body: some View {
        SystemVolumeRepresentable()
            // The 32 pt height gives the track/knob correct proportions. The 44 pt row frame
            // around the whole HStack guarantees hit area and vertical alignment with the
            // adjacent icon and AirPlay button.
            .frame(height: 32)
    }
}

/// Extension to encapsulate the (only available) mechanism for hiding MPVolumeView's
/// internal route button without triggering a deprecation diagnostic.
///
/// - Important: This exists solely because `MPVolumeView.showsRouteButton` has been
///   deprecated since iOS 13.0 with guidance to "Use AVRoutePickerView instead".
///   MPVolumeView itself exposes no non-deprecated typed API to suppress the button.
///   We use KVC on the stable key to achieve identical runtime effect.
/// - Note: The app already provides a first-class `AirPlayButton` (AVRoutePickerView
///   with `prioritizesVideoDevices = false`). Duplicating the picker inside the volume
///   control would be both visually redundant and confusing.
/// - SeeAlso: `SystemVolumeRepresentable`, `VolumeAndAirPlayRow`, `AirPlayButton`,
///   CODING_AGENT.md, <doc:Architecture>
private extension MPVolumeView {
    /// Hides the route button on this volume view using KVC.
    ///
    /// - Precondition: Must be called on the main actor (guaranteed by UIViewRepresentable.makeUIView).
    /// - Postcondition: The receiver will not display its own route picker button.
    ///   Routing UI is provided exclusively by a sibling `AirPlayButton`.
    /// - Complexity: O(1). The key is a documented stable identifier for the flag.
    func configureAsVolumeSliderOnly() {
        // KVC with string key intentionally bypasses the Swift deprecation attribute
        // on the typed property while setting the exact same backing flag that
        // `showsRouteButton = false` would have set.
        //
        // This pattern has been the community/Apple-forums workaround since iOS 13
        // (no official typed replacement on MPVolumeView has been added as of iOS 26).
        // If the key ever stops working in a future OS, the (harmless) consequence
        // is a second route button appearing; users would still have functional
        // routing and the separate styled button remains the primary one.
        setValue(false, forKey: "showsRouteButton")
    }
}

/// `UIViewRepresentable` bridge to `MPVolumeView` configured for in-app use without its own
/// route button.
///
/// The route button is suppressed via `configureAsVolumeSliderOnly` (KVC on the
/// well-known key) so that a single, consistently-styled `AirPlayButton` owns all
/// routing UI. This implements the "Use AVRoutePickerView instead" guidance from
/// the deprecation while preserving the native volume slider behavior that is
/// required for system-wide volume sync (see `VolumeAndAirPlayRow`).
///
/// VoiceOver cluster (Tier A revival):
/// After the volume `UISlider` subview appears, ``Coordinator`` attaches:
/// - `accessibilityIdentifier("volumeSlider")` (UITest contract)
/// - Localized `accessibilityValue` via `accessibility_value_volume`
/// - Custom actions `increase_volume` / `decrease_volume` (10% steps + `volume_set_to` announce)
/// - ``SystemVolumeVoiceOver/liveSlider`` so SwiftUI-named actions drive the same control
///
/// Implementation notes:
/// - Route button suppressed via dedicated helper (no direct use of deprecated `showsRouteButton` property at the call site).
/// - Tint applied once in `makeUIView`; `MPVolumeView` does not require per-update tint pushes.
/// - `updateUIView` re-attempts slider attachment if the private subview is late.
/// - `dismantleUIView` clears ``SystemVolumeVoiceOver/liveSlider`` when it still points at this instance.
/// - No force-unwraps, no `!`. Volume format/announce paths use documented `// SAFETY:` markers.
///
/// This type is file-private; the public surface is `SystemVolumeSlider`.
///
/// - SeeAlso: ``SystemVolumeVoiceOver``, ``VolumeAndAirPlayRow``, CODING_AGENT.md, <doc:Architecture>
private struct SystemVolumeRepresentable: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView()
        volumeView.configureAsVolumeSliderOnly()
        // Bridge SwiftUI accentColor (AccentColor.colorset) to match the visual treatment
        // that the prior custom Slider received from .tint(.accentColor).
        volumeView.tintColor = UIColor(Color.accentColor)

        // Make the MPVolumeView itself carry the identifier (for otherElements / descendant queries)
        // and attempt to forward to its child UISlider (for legacy slider queries).
        volumeView.accessibilityIdentifier = "volumeSlider"

        // Attach a11y + liveSlider bridge as soon as the private UISlider exists.
        // MPVolumeView sometimes materializes the slider one runloop later — `updateUIView`
        // and a deferred attach cover that race without KVO on private hierarchy.
        context.coordinator.attachVolumeSliderIfNeeded(from: volumeView)
        DispatchQueue.main.async {
            context.coordinator.attachVolumeSliderIfNeeded(from: volumeView)
        }
        return volumeView
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        // MPVolumeView is self-managed for volume; we only ensure VoiceOver attachment.
        context.coordinator.attachVolumeSliderIfNeeded(from: uiView)
    }

    static func dismantleUIView(_ uiView: MPVolumeView, coordinator: Coordinator) {
        coordinator.detachIfNeeded(from: uiView)
    }

    /// Owns VoiceOver custom actions and the ``SystemVolumeVoiceOver/liveSlider`` bridge.
    ///
    /// Isolated to the main actor because it mutates UIKit controls and
    /// ``SystemVolumeVoiceOver`` (itself `@MainActor`). `UIViewRepresentable` lifecycle
    /// and `UISlider` target/action callbacks run on the main thread.
    ///
    /// - SeeAlso: ``SystemVolumeVoiceOver``, ``VolumeAndAirPlayRow``
    @MainActor
    final class Coordinator: NSObject {
        private weak var attachedSlider: UISlider?

        /// Locates the private volume `UISlider` and installs identifier, value, and custom actions.
        ///
        /// - Parameter volumeView: The hosting `MPVolumeView`.
        /// - Note: Safe to call repeatedly; no-ops when already attached to the same slider.
        func attachVolumeSliderIfNeeded(from volumeView: MPVolumeView) {
            guard let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider else {
                return
            }
            if attachedSlider === slider {
                // Keep percent value current when SwiftUI re-renders.
                refreshAccessibilityValue(on: slider)
                return
            }
            detachTargets(from: attachedSlider)
            attachedSlider = slider
            SystemVolumeVoiceOver.liveSlider = slider

            // UITest contract: `app.sliders["volumeSlider"]` / descendant queries.
            slider.accessibilityIdentifier = "volumeSlider"
            // Localized label/hint also on the UIKit control so VO focus on the slider
            // (not only the SwiftUI wrapper) still speaks the catalog strings.
            slider.accessibilityLabel = String(localized: "accessibility_label_volume", table: "Localizable")
            slider.accessibilityHint = String(localized: "accessibility_hint_volume", table: "Localizable")
            refreshAccessibilityValue(on: slider)

            // Custom actions revive `increase_volume` / `decrease_volume` on the element
            // VoiceOver typically focuses for adjustable volume (the private UISlider).
            slider.accessibilityCustomActions = [
                UIAccessibilityCustomAction(
                    name: String(
                        localized: "increase_volume",
                        defaultValue: "Increase Volume",
                        table: "Localizable",
                        comment: "Accessibility action to increase volume"
                    )
                ) { [weak self] _ in
                    self?.performStep(by: SystemVolumeVoiceOver.stepAmount) ?? false
                },
                UIAccessibilityCustomAction(
                    name: String(
                        localized: "decrease_volume",
                        defaultValue: "Decrease Volume",
                        table: "Localizable",
                        comment: "Accessibility action to decrease volume"
                    )
                ) { [weak self] _ in
                    self?.performStep(by: -SystemVolumeVoiceOver.stepAmount) ?? false
                }
            ]

            slider.addTarget(self, action: #selector(sliderValueChanged(_:)), for: .valueChanged)
        }

        /// Clears the bridge when this representable's slider is going away.
        func detachIfNeeded(from volumeView: MPVolumeView) {
            let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider
            if let slider, SystemVolumeVoiceOver.liveSlider === slider {
                SystemVolumeVoiceOver.liveSlider = nil
            } else if let attachedSlider, SystemVolumeVoiceOver.liveSlider === attachedSlider {
                SystemVolumeVoiceOver.liveSlider = nil
            }
            detachTargets(from: attachedSlider)
            attachedSlider = nil
        }

        @objc private func sliderValueChanged(_ sender: UISlider) {
            refreshAccessibilityValue(on: sender)
            NotificationCenter.default.post(
                name: .lutheranSystemVolumeAccessibilityDidChange,
                object: nil
            )
        }

        private func performStep(by delta: Float) -> Bool {
            SystemVolumeVoiceOver.step(by: delta)
            return true
        }

        private func refreshAccessibilityValue(on slider: UISlider) {
            slider.accessibilityValue = SystemVolumeVoiceOver.accessibilityValueText(for: slider.value)
        }

        private func detachTargets(from slider: UISlider?) {
            slider?.removeTarget(self, action: #selector(sliderValueChanged(_:)), for: .valueChanged)
            slider?.accessibilityCustomActions = nil
        }
    }
}

/// Native AirPlay route-picker control for the SwiftUI player chrome.
///
/// Sole user-facing AirPlay surface in the main app. Wraps `AVRoutePickerView` via
/// `AirPlayPickerView` and applies localized accessibility label/hint.
///
/// **Why construction stays here (not on `ViewController`):**
/// `AVRoutePickerView` init triggers `AVOutputContext` + CoreMedia preference work that can
/// block the main thread on CFPreferences/XPC. Building it during `ViewController` stored
/// property init ran on the scene-create callout and could exhaust the Background scene-create
/// watchdog (0x8BADF00D) under cold Simulator / post-reboot load. This type only materializes
/// the picker inside `UIViewRepresentable.makeUIView` after the hosting hierarchy is attached —
/// after scene connect returns and off that critical path.
///
/// Prioritizes audio-only routes (`prioritizesVideoDevices = false`) to match historical behavior.
///
/// - Important: Do not move `AVRoutePickerView` construction into `ViewController.init`,
///   stored property initializers, or any other scene-create-synchronous path.
/// - SeeAlso: `VolumeAndAirPlayRow`, `AirPlayPickerView`, `ViewController` (AirPlay ownership note),
///   CODING_AGENT.md, <doc:Architecture>
struct AirPlayButton: View {
    var body: some View {
        AirPlayPickerView()
            .frame(width: 44, height: 44)
            .accessibilityLabel(String(localized: "accessibility_label_airplay", table: "Localizable"))
            .accessibilityHint(String(localized: "accessibility_hint_airplay", table: "Localizable"))
    }
}

/// Bridges `AVRoutePickerView` into SwiftUI.
///
/// Construction of the underlying picker happens only in `makeUIView`, which SwiftUI invokes
/// when the representable is inserted into an active hierarchy — intentionally later than
/// `ViewController` / scene-create init (see `AirPlayButton` docs).
///
/// - SeeAlso: `AirPlayButton`, `VolumeAndAirPlayRow`
private struct AirPlayPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        // Safe to construct here: not on the scene-create critical path (see AirPlayButton).
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = UIColor.secondaryLabel
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        // No dynamic state to push in this simple wrapper.
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Radio Player - Playing") {
    RadioPlayerView(viewModel: .makeMock(visualState: .playing))
        .background(Color(UIColor.systemBackground))
}

#Preview("Radio Player - PrePlay + Sleep") {
    RadioPlayerView(
        viewModel: .makeMock(
            visualState: .prePlay,
            currentMetadata: nil,
            sleepTimerRemaining: 14 * 60
        )
    )
    .background(Color(UIColor.systemBackground))
}
#endif
